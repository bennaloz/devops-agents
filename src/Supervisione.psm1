Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Stato.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Decisioni.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Telegram.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Impostazioni.psm1') -Global

# D51: i controlli del supervisore. Ogni controllo e una funzione pura: riceve l'osservazione (quello che src/Supervisore.ps1 ha
# gia letto: attivita pianificate, log, card, ADO...) e restituisce dei problemi, senza toccare ne la rete ne il disco, cosi si
# prova con osservazioni finte. Un problema e @{ Chiave; Urgente; Testo; Azione; Link; DaDiagnosi }: la chiave lo identifica fra
# un giro e l'altro (e il modo di non avvisare due volte), Azione e il gesto esatto che tocca a Titolare, DaDiagnosi dice che
# nessuna regola lo sa spiegare (la diagnosi con il modello arriva con il passo successivo).
#
# L'osservazione (tutte le date in UTC, ogni sezione ha Letto/Errore: una lettura fallita e un problema, non uno stop):
#   Adesso, AvvioPc, UrlBaseCard, UrlOrganizzazione, UrlVista, TagAttesa, Limiti (limiti.json)
#   Smistatore, VistaAttivita: @{ Letto; Errore; Abilitata; Stato; UltimoGiro; Esito }
#   VistaRisponde: bool, VistaErrore
#   Log: @{ Letto; Errore; Righe }    Quota: @{ Letto; Errore; Dati; Override (soglia-quota.json) }    Pat: @{ Letto; Errore; Scadenza }
#   Card: @{ Letto; Errore; Righe (Get-RigaCoda + Url, Firma); FermaDaOre (id -> ore) }
#   Pipeline: @{ Letto; Errore; Attivi; Orchestratori; AgentiPool; Falliti; Errori; Motivi (id run -> testo) }
#   ProgettiMappa, DefinizioniDeploy: i progetti ADO e le pipeline di deploy di config/mappa.json

# ---- configurazione ----------------------------------------------------------------------------------------------

function Get-ConfigSupervisore {
    [CmdletBinding()]
    # D53: supervisore.json si legge con gli override di impostazioni.json (cartella dati).
    param([string]$Radice = (Split-Path -Parent $PSScriptRoot), [string]$CartellaDati = (Get-CartellaDati))
    $imp = Get-Impostazioni $CartellaDati
    $c = Read-ConfigConOverride -Radice $Radice -Nome 'supervisore' -CartellaDati $CartellaDati -Impostazioni $imp
    $chiaviOverride = @($imp.Supervisore.PSObject.Properties | ForEach-Object Name)
    try { Test-ConfigSupervisore $c }
    catch {
        if ($chiaviOverride.Count -gt 0) { throw "$($_.Exception.Message) (override in impostazioni.json: $($chiaviOverride -join ', '))" }
        throw
    }
    $c
}

# Le regole di validazione di supervisore.json, applicate al valore finale (file del repo con gli override sopra).
function Test-ConfigSupervisore($c) {
    foreach ($n in 'intervalloMinuti', 'minutiSenzaGiro', 'erroriDiFilaPerCard', 'oreSenzaMovimento', 'minutiInCoda', 'minutiFraRiavviiVista',
        'oreRicordoUrgente', 'diagnosiAlGiorno', 'giorniPreavvisoPat', 'timeoutVistaSecondi', 'minutiControlloAggiornamenti', 'oreAttesaAggiornamento') {
        $v = Get-Campo $c $n
        if ($null -eq $v -or $v -isnot [ValueType] -or $v -le 0) { throw "supervisore.json: '$n' manca o non e un numero maggiore di zero" }
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-Campo $c 'urlVista'))) { throw "supervisore.json: manca 'urlVista'" }
    $orari = @(Get-Campo $c 'orariRiepilogo')
    if ($orari.Count -eq 0) { throw "supervisore.json: 'orariRiepilogo' deve avere almeno un orario" }
    foreach ($o in $orari) { if ("$o" -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw "supervisore.json: l'orario '$o' non e nel formato HH:mm" } }
    # le sole pipeline che il supervisore puo rilanciare (D51): vuoto di default, le aggiunge una persona
    $ril = Get-Campo $c 'pipelineRilanciabili'
    if ($null -eq $ril -and -not ($c.PSObject.Properties['pipelineRilanciabili'])) { throw "supervisore.json: manca 'pipelineRilanciabili' (anche vuoto)" }
    foreach ($r in @($ril)) {
        if ($null -eq $r) { continue }
        if ([string]::IsNullOrWhiteSpace([string](Get-Campo $r 'progetto')) -or ([int](Get-Campo $r 'definizioneId')) -le 0) { throw "supervisore.json: ogni voce di 'pipelineRilanciabili' vuole 'progetto' e 'definizioneId'" }
    }
    # i rilasci in attesa (D51): quando un'area e oltre soglia (card o giorni), predefinita o per area
    $ril2 = Get-Campo $c 'rilasci'
    $soglie = @(Get-Campo $ril2 'predefinito') + @(@(Get-Campo $ril2 'perArea') | ForEach-Object { if ($_) { $_.PSObject.Properties | ForEach-Object { $_.Value } } })
    if ($null -eq (Get-Campo $ril2 'predefinito')) { throw "supervisore.json: manca 'rilasci.predefinito'" }
    foreach ($so in $soglie) {
        foreach ($n in 'card', 'giorni') { $v = Get-Campo $so $n; if ($null -eq $v -or $v -isnot [ValueType] -or $v -le 0) { throw "supervisore.json: 'rilasci' vuole '$n' maggiore di zero (predefinito e perArea)" } }
    }
    $testi = @(Get-Campo $c 'testiInfrastruttura')
    foreach ($t in $testi) {
        try { [void][regex]::new("$t") } catch { throw "supervisore.json: il testo '$t' di testiInfrastruttura non e un'espressione valida" }
    }
}

# ---- aiuti -------------------------------------------------------------------------------------------------------

function New-Problema {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Chiave, [Parameter(Mandatory)][string]$Testo, [Parameter(Mandatory)][string]$Azione,
        [string]$Link, [bool]$Urgente = $false, [bool]$DaDiagnosi = $false,
        # una voce raggruppata (i rilasci in attesa): le sue righe, gli elementi che contiene (per accorgersi di uno nuovo) e se si ricorda ogni giorno
        [string[]]$Righe = @(), [string[]]$Elementi = @(), [bool]$Ricorda = $true)
    [pscustomobject]@{ Chiave = $Chiave; Urgente = $Urgente; Testo = $Testo; Azione = $Azione; Link = $Link; DaDiagnosi = $DaDiagnosi; Righe = @($Righe); Elementi = @($Elementi); Ricorda = $Ricorda }
}

# "da 20 minuti", "da 3 ore", "da 2 giorni".
function Format-Attesa([timespan]$Durata) {
    if ($Durata.TotalMinutes -lt 1) { return 'da meno di un minuto' }
    if ($Durata.TotalHours -lt 1) { return "da $([int][math]::Floor($Durata.TotalMinutes)) minuti" }
    if ($Durata.TotalDays -lt 1) { $o = [int][math]::Floor($Durata.TotalHours); return "da $o " + $(if ($o -eq 1) { 'ora' } else { 'ore' }) }
    $g = [int][math]::Floor($Durata.TotalDays)
    "da $g " + $(if ($g -eq 1) { 'giorno' } else { 'giorni' })
}

# Il testo di un errore in una riga sola e senza lunghezze fuori misura.
function Get-RigaBreve([string]$Testo, [int]$Max = 200) {
    $t = ([regex]::Replace("$Testo", '\s+', ' ')).Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
    $t
}

# Le righe del log di oggi: data (UTC), livello, testo. Le righe che non cominciano con la data (code di un errore su piu righe) si saltano.
function ConvertFrom-RigheLog($Righe) {
    foreach ($r in @($Righe)) {
        $m = [regex]::Match([string]$r, '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (\S+) (.*)$')
        if (-not $m.Success) { continue }
        $d = [datetime]::MinValue
        $ok = [datetime]::TryParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$d)
        [pscustomobject]@{ Quando = $(if ($ok) { $d.ToUniversalTime() } else { $null }); Livello = $m.Groups[2].Value; Testo = $m.Groups[3].Value }
    }
}


# Il supervisore ha girato senza buchi negli ultimi minutiSenzaGiro minuti? Serve a distinguere uno smistatore fermo da un PC
# spento o sospeso (dopo una sospensione l'avvio del PC non cambia, e lo smistatore al risveglio sembrerebbe fermo): se anche il
# supervisore non girava, non e un problema. Vale se c'e almeno un'esecuzione precedente nella finestra e ogni esecuzione
# (l'attuale compresa) dista dalla precedente non piu di due intervalli.
function Test-SupervisoreContinuo {
    [CmdletBinding()]
    param([AllowNull()]$Esecuzioni, [Parameter(Mandatory)][datetime]$Adesso, [Parameter(Mandatory)]$Config)
    $da = $Adesso.AddMinutes(-[double]$Config.minutiSenzaGiro)
    $nella = @(@($Esecuzioni) | ForEach-Object { ConvertTo-DataUtc $_ } | Where-Object { $_ -and $_ -ge $da -and $_ -lt $Adesso } | Sort-Object)
    if ($nella.Count -eq 0) { return $false }
    $tutte = @($nella) + @($Adesso)
    for ($i = 1; $i -lt $tutte.Count; $i++) {
        if (($tutte[$i] - $tutte[$i - 1]).TotalMinutes -gt 2 * [double]$Config.intervalloMinuti) { return $false }
    }
    $true
}

# ---- sezioni dell'osservazione ------------------------------------------------------------------------------------
# Un problema nasce da una sezione dell'osservazione. Se la sezione non si e letta (Letto = $false) non si sa se il problema c'e
# ancora: resta com'e, non si chiude e non si aggiorna. Le chiavi dei problemi di ogni sezione stanno qui.
$script:SezioniProblemi = [ordered]@{
    smistatore = '^(smistatore-|lettura-smistatore)'
    log        = '^(errore-card-|lettura-log)'
    card       = '^(card-\d+-|ferma-|validazione-lunga-|rilasci$|deploy-test$|lettura-card)'
    pipeline   = '^(approvazione-|coda-|run-fallito-|lettura-pipeline)'
    agenti     = '^(agente-offline-|lettura-agenti)'
    quota      = '^(quota-|lettura-quota)'
    pat        = '^(pat-|lettura-pat)'
}
function Get-SezioneDelProblema([string]$Chiave) {
    foreach ($n in $script:SezioniProblemi.Keys) { if ($Chiave -match $script:SezioniProblemi[$n]) { return $n } }
    $null
}
# Le sezioni che in questo giro non si sono lette.
function Get-SezioniNonLette($Osservazione) {
    $o = $Osservazione; $n = @()
    if (-not $o.Smistatore.Letto) { $n += 'smistatore' }
    if (-not $o.Log.Letto) { $n += 'log' }
    if (-not $o.Card.Letto) { $n += 'card' }
    $pl = $o.Pipeline
    # un progetto che non risponde lascia la sezione a meta: meglio non chiudere niente
    if (-not $pl.Letto -or @($pl.Errori).Count -gt 0) { $n += 'pipeline' }
    if (-not $pl.Letto -or -not [bool](Get-Campo $pl 'AgentiLetti')) { $n += 'agenti' }
    if (-not $o.Quota.Letto) { $n += 'quota' }
    if (-not $o.Pat.Letto) { $n += 'pat' }
    $n
}

# ---- 1. lo smistatore --------------------------------------------------------------------------------------------

function Get-ProblemiSmistatore {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Osservazione, [Parameter(Mandatory)]$Config)
    $o = $Osservazione; $s = $o.Smistatore
    if (-not $s.Letto) {
        return @(New-Problema 'lettura-smistatore' "Non riesco a leggere l'attivita pianificata dello smistatore: $(Get-RigaBreve $s.Errore)" 'controlla in Utilita di pianificazione che DevOps.Agents\Smistatore esista; se manca: pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Pianificazione')
    }
    if (-not $s.Abilitata) {
        return @(New-Problema 'smistatore-disabilitato' 'Lo smistatore e disabilitato: nessuna card avanza.' "se non l'hai fermato tu, riabilitalo da Utilita di pianificazione (DevOps.Agents\Smistatore)")
    }
    $problemi = @()
    $minuti = [double]$Config.minutiSenzaGiro
    # un giro in corso non e un giro fermo, a meno che non duri da piu di silenzioMinuti
    $inEsecuzione = [string]$s.Stato -eq 'Running'
    $limite = if ($inEsecuzione -and $null -ne (Get-Campo $o.Limiti 'silenzioMinuti')) { [math]::Max($minuti, [double]$o.Limiti.silenzioMinuti) } else { $minuti }
    # un PC acceso da poco non ha ancora avuto il tempo di fare un giro: uno smistatore che non gira a PC spento non e un problema
    $pcAcceso = if ($o.AvvioPc) { ($o.Adesso - $o.AvvioPc).TotalMinutes } else { [double]::MaxValue }
    $daGiro = if ($s.UltimoGiro) { ($o.Adesso - $s.UltimoGiro).TotalMinutes } else { [double]::MaxValue }
    if ($pcAcceso -gt $minuti -and $daGiro -gt $limite -and (Test-SupervisoreContinuo $o.EsecuzioniPrecedenti $o.Adesso $Config)) {
        $quando = if ($s.UltimoGiro) { "ultimo giro alle $($s.UltimoGiro.ToLocalTime().ToString('HH:mm'))" } else { 'nessun giro registrato' }
        $problemi += New-Problema 'smistatore-fermo' "Lo smistatore non gira da piu di $([int]$limite) minuti ($quando)." "apri Utilita di pianificazione, controlla DevOps.Agents\Smistatore (stato: $($s.Stato)) e il log di oggi; avvialo a mano se serve" -Urgente $true
    }
    # Lo smistatore chiude con codice 0 anche quando il giro si interrompe: l'errore a ogni giro si vede nel log, non nel codice.
    # Un 401 ha il suo problema (il PAT): qui non si conta.
    $reInt = Get-RegexRigaLog 'GiroInterrotto'; $reFer = Get-RegexRigaLog 'GiroFermato'; $rePat = Get-RegexPatRifiutato
    $interrotti = @(ConvertFrom-RigheLog $o.Log.Righe | Where-Object {
        $_.Quando -and ($o.Adesso - $_.Quando).TotalMinutes -le $minuti -and ($_.Testo -match $reInt -or $_.Testo -match $reFer) -and $_.Testo -notmatch $rePat })
    if ($interrotti.Count -ge 2) {
        $ultimo = Get-RigaBreve $interrotti[-1].Testo 220
        $problemi += New-Problema 'smistatore-giro-interrotto' "Il giro dello smistatore si interrompe a ogni giro ($($interrotti.Count) volte negli ultimi $($Config.minutiSenzaGiro) minuti): $ultimo" 'leggi le righe ERRORE del log di oggi (cartella dati, log/smistatore-AAAA-MM-GG.log) e correggi la causa' -Urgente $true -DaDiagnosi $true
    }
    # il codice di uscita dell'attivita e solo un segnale in piu. 267009 e 267011: in esecuzione e mai partita, non sono errori
    if ($s.UltimoGiro -and $s.Esito -ne 0 -and $s.Esito -notin 267009, 267011) {
        $ultime = @(ConvertFrom-RigheLog $o.Log.Righe | Where-Object { $_.Livello -eq 'ERRORE' } | Select-Object -Last 3 | ForEach-Object { Get-RigaBreve $_.Testo 160 })
        $coda = if ($ultime.Count -gt 0) { " Ultimi errori: $($ultime -join ' | ')" } else { '' }
        $problemi += New-Problema 'smistatore-errore' "Il giro dello smistatore esce con errore (codice $($s.Esito)).$coda" 'leggi il log di oggi (cartella dati, log/smistatore-AAAA-MM-GG.log) e correggi la causa' -Urgente $true
    }
    $problemi
}

# ---- 2. errore ripetuto su una card ------------------------------------------------------------------------------

# Dal log di oggi: per ogni card, quante volte di fila lo smistatore l'ha saltata per errore (lettura non riuscita o azione fallita)
# senza altro che la riguardasse in mezzo. Le righe dell'on-hold sono la conseguenza di un'azione fallita e non spezzano la serie.
# I testi sono i modelli di Comune.psm1, gli stessi con cui li scrive lo smistatore.
function Get-ErroriDiFilaPerCard($RigheLog) {
    $reLettura = Get-RegexRigaLog 'LetturaNonRiuscita'; $reAzione = Get-RegexRigaLog 'AzioneFallita'
    $reOnHold = Get-RegexRigaLog 'OnHold'; $reOnHoldKo = Get-RegexRigaLog 'OnHoldFallito'
    $conto = @{}; $ultimo = @{}
    foreach ($r in @(ConvertFrom-RigheLog $RigheLog)) {
        if ($r.Testo -match $reLettura) { $id = $Matches[1]; $msg = "lettura non riuscita: $($Matches[2])" }
        elseif ($r.Testo -match $reAzione) { $id = $Matches[1]; $msg = "l'azione $($Matches[2]) e fallita: $($Matches[3])" }
        elseif ($r.Testo -match $reOnHold -or $r.Testo -match $reOnHoldKo) { continue }
        elseif ($r.Testo -match '^card (\d+): ') { $conto[$Matches[1]] = 0; continue }
        else { continue }
        $conto[$id] = 1 + $(if ($conto.ContainsKey($id)) { $conto[$id] } else { 0 }); $ultimo[$id] = $msg
    }
    foreach ($id in $conto.Keys) { if ($conto[$id] -gt 0) { [pscustomobject]@{ Card = [int]$id; Volte = $conto[$id]; Ultimo = $ultimo[$id] } } }
}

function Get-ProblemiErroriCard {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Osservazione, [Parameter(Mandatory)]$Config)
    $o = $Osservazione
    if (-not $o.Log.Letto) { return @(New-Problema 'lettura-log' "Non riesco a leggere il log di oggi: $(Get-RigaBreve $o.Log.Errore)" 'controlla che la cartella dati e il suo log siano leggibili') }
    foreach ($e in @(Get-ErroriDiFilaPerCard $o.Log.Righe | Where-Object { $_.Volte -ge $Config.erroriDiFilaPerCard } | Sort-Object Card)) {
        New-Problema "errore-card-$($e.Card)" "La card $($e.Card) e stata saltata dallo smistatore per errore in $($e.Volte) giri di fila: $(Get-RigaBreve $e.Ultimo)" "guarda le righe della card $($e.Card) nel log di oggi e correggi la causa negli attrezzi" "$($o.UrlBaseCard)$($e.Card)" -DaDiagnosi $true
    }
}

# ---- 3. la vista -------------------------------------------------------------------------------------------------

# La vista e "giu" dopo due mancate risposte di fila (VistaMancate, contate in supervisore.json): una sola puo essere un attimo.
# Il gesto (riavviare l'attivita) lo decide Get-GestiSupervisore; il problema resta aperto finche la vista non risponde di nuovo, e non
# si chiude e riapre a ogni riavvio.
function Get-ProblemiVista {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Osservazione, [Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)]$Config)
    $o = $Osservazione
    if ($o.VistaRisponde -or [int]$o.VistaMancate -lt 2) { return @() }
    $att = $o.VistaAttivita
    if ($att.Letto -and -not $att.Abilitata) {
        return @(New-Problema 'vista-giu' "La vista non risponde su $($o.UrlVista) e la sua attivita e disabilitata." 'se non l''hai fermata tu, riabilitala da Utilita di pianificazione (DevOps.Agents\Vista)')
    }
    @(New-Problema 'vista-giu' "La vista non risponde su $($o.UrlVista) da $($o.VistaMancate) controlli ($(Get-RigaBreve $o.VistaErrore 120))." 'avvia a mano l''attivita DevOps.Agents\Vista da Utilita di pianificazione, o lancia pwsh -NoProfile -File src/Vista.ps1 -Html -Segui')
}

# ---- 4. le card ---------------------------------------------------------------------------------------------------

# La firma di una card senza sessione: se non cambia, la card non si e mossa (stato ADO, ultima sessione, motivo dell'attesa, PR).
function Get-FirmaCard($Riga, $Sc) {
    $us = if ($null -ne $Sc) { Get-Campo $Sc 'ultimaSessione' } else { $null }
    $pr = Get-Campo $Riga 'Pr'
    $partiPr = if ($pr) { "$(Get-Campo $pr 'Id'):$(Get-Campo $pr 'Validazione')" } else { '' }
    "$(Get-Campo $Riga 'Stato')|$(if ($us) { $us | ConvertTo-Json -Compress -Depth 6 } else { '' })|$(if ($null -ne $Sc) { Get-Campo $Sc 'inAttesaPer' } else { '' })|$partiPr"
}

# Aggiorna le firme (id -> @{ firma; dal }) con le righe di adesso e dice da quante ore ogni card e ferma sulla stessa firma.
# Una card che non c'e piu fra le righe (ha una sessione, e passata a un altro) esce dalle firme.
function Update-FirmeCard {
    [CmdletBinding()]
    param([AllowNull()]$Firme, [Parameter(Mandatory)][AllowEmptyCollection()]$Righe, [Parameter(Mandatory)][datetime]$Adesso)
    $nuove = @{}; $ore = @{}
    foreach ($r in @($Righe | Where-Object { $null -ne $_ })) {
        $k = "$($r.Id)"
        $prima = Get-Campo $Firme $k
        $dal = $Adesso
        if ($prima -and (Get-Campo $prima 'firma') -ceq [string]$r.Firma) { $dal = (ConvertTo-DataUtc (Get-Campo $prima 'dal')); if (-not $dal) { $dal = $Adesso } }
        $nuove[$k] = @{ firma = [string]$r.Firma; dal = $dal.ToString('o') }
        $ore[$k] = ($Adesso - $dal).TotalHours
    }
    @{ Firme = $nuove; FermaDaOre = $ore }
}

# Un on-hold nato da un esito "bloccato" (Titolare, 2026-11-24, card 56): se la sessione finita per ultima sulla card e del
# collaudatore o del responsabile con esito bloccato, chi aveva il contesto ha gia scritto perche e cosa serve. Restituisce
# @{ Ruolo; Righe } con il resoconto ripulito in righe (al piu $Max), $null se l'ultima sessione non e un bloccato di quei due.
# Righe vuote: il resoconto non c'e (la voce va alla diagnosi del modello).
# Un on-hold messo da Close-Sessione (causaAttesa: scritture, silenzio, morta, fallita) non e nato dal bloccato, anche se
# l'ultima sessione ha scritto ESITO=bloccato: lo dice il suo commento, non il resoconto. Le attese di Decisioni, compresa la
# chiusura della passata D42, lasciano causaAttesa vuota. La sessione senza fine conta dal suo inizio, come in Decisioni.
function Get-ResocontoBloccato($Sc, [int]$Max = 12) {
    if (Get-Campo $Sc 'causaAttesa') { return $null }
    $u = Get-UltimaSessioneCard $Sc
    $ultima = Get-Campo $u 'Sessione'; $ultimo = Get-Campo $u 'Ruolo'
    if ($null -eq $ultima -or $ultimo -notin 'collaudatore', 'responsabile' -or "$(Get-Campo $ultima 'esito')" -ne 'bloccato') { return $null }
    # Via i blocchi di codice recintati (log, stack: non vanno su Telegram) e il markdown di righe e grassetto; il testo fra
    # apici inversi resta intero (nomi di pipeline e parametri sono il cuore dei passi), niente riga ESITO.
    $testo = [regex]::Replace([string](Get-Campo $ultima 'testo'), '(?s)(`{3}|~{3}).*?(\1|\z)', "`n")
    $righe = @($testo -split '\r?\n' | ForEach-Object {
            $t = $_ -replace '^\s*(#{1,6}\s+|>\s*|[-+*•]\s+)', ''
            $t = [regex]::Replace($t, '`([^`]*)`|\*\*|__', { param($m) $m.Groups[1].Value })
            $t = $t -replace '\[([^\]]+)\]\(([^)]+)\)', '$1 ($2)'
            $t = ([regex]::Replace($t, '\s+', ' ')).Trim()
            if ($t -and $t -notmatch '^ESITO=') { $t }
        } | Select-Object -First $Max)
    @{ Ruolo = $ultimo; Righe = $righe }
}

function Get-ProblemiCard {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Osservazione, [Parameter(Mandatory)]$Config)
    $o = $Osservazione; $c = $o.Card
    # senza il PAT dello smistatore non si legge niente: il problema e il PAT, non le card
    if ([bool](Get-Campo $o 'SenzaPat')) { return @() }
    if (-not $c.Letto) { return @(New-Problema 'lettura-card' "Non riesco a leggere le card: $(Get-RigaBreve $c.Errore)" 'controlla l''accesso ad Azure DevOps e il log di oggi') }
    $rilasci = @(); $deployTest = @(); $chiusureInBozza = @{}
    # D57: per ogni card, le card che la aspettano come predecessore (il motivo 'predecessori'): la voce del suo on-hold le nomina
    $aspettano = @{}
    foreach ($r in @($c.Righe | Where-Object { $null -ne $_ })) {
        $m = Get-Campo $r 'Motivo'
        if (-not $m -or (Get-Campo $m 'Tipo') -ne 'predecessori') { continue }
        foreach ($p in @(Get-Campo $m 'Predecessori') | Where-Object { $null -ne $_ }) {
            $k = "$([int](Get-Campo $p 'Id'))"
            if (-not $aspettano.ContainsKey($k)) { $aspettano[$k] = @() }
            $aspettano[$k] += [int]$r.Id
        }
    }
    foreach ($r in @($c.Righe | Where-Object { $null -ne $_ })) {
        $att = $r.Attivita
        $titolo = Get-RigaBreve $r.Titolo 70
        # D52: la card di chiusura in Draft non la legge nessuno (non e fra le card attive): lo dicono le sorelle In feature branch con il motivo
        # chiusuraInBozza, e una persona deve spostarla in New. Una voce per card di chiusura, qualunque sia il numero di sorelle che lo dicono.
        $motivo = Get-Campo $r 'Motivo'
        if ($motivo -and (Get-Campo $motivo 'Tipo') -eq 'chiusuraInBozza') {
            $idChiusura = [int](Get-Campo $motivo 'Chiusura')
            if (-not $chiusureInBozza.ContainsKey("$idChiusura")) {
                $chiusureInBozza["$idChiusura"] = $true
                New-Problema "chiusura-$idChiusura-bozza" "La card di chiusura #$idChiusura e in Draft e le sorelle della funzionalita sono tutte unite nel ramo: aspetta te." ([string](Get-Campo $motivo 'Gesto')) "$($o.UrlBaseCard)$idChiusura"
            }
            continue
        }
        # un on-hold che lo smistatore sta per togliere da solo non e una cosa per una persona
        if ($att -and -not [bool](Get-Campo $r 'TogliAttesa')) {
            # le card da rilasciare non sono una voce ciascuna: una voce sola per tutte (Get-ProblemaRilasci)
            if ($att.Attivita -eq 'rilascia') { $rilasci += $r; continue }
            # D61: le card unite che aspettano un deploy di develop in Test: una voce sola, il gesto e uno per tutte
            if ($att.Attivita -eq 'deployTest') { $deployTest += $r; continue }
            # on-hold nato da un bloccato del collaudatore o del responsabile: non la regola generica ("togli il tag", che
            # riprende la sessione e la riblocca) ma il suo resoconto; senza resoconto la diagnosi del modello
            $bloccato = Get-Campo $r 'Bloccato'
            # D57: la sezione "Cosa fare" di Set-InAttesa: il gesto e l'azione, il resto sono le righe, con le card che la aspettano.
            # Un bloccato con resoconto ma senza le righe "Per Titolare:" del ruolo resta al resoconto, che dice piu del predefinito.
            $cosaFare = @(Get-Campo $r 'CosaFare' | Where-Object { $_ })
            $indicazioni = Get-Campo $r 'Indicazioni'
            $soloResoconto = $bloccato -and @($bloccato.Righe).Count -gt 0 -and (Get-Campo $indicazioni 'Fonte') -ne 'agente'
            if ($att.Attivita -eq 'sblocca' -and $cosaFare.Count -gt 0 -and -not $soloResoconto) {
                $righe = @($cosaFare | Select-Object -Skip 1)
                $dipendenti = @($aspettano["$($r.Id)"])
                if ($dipendenti.Count -gt 0) { $righe += "Tiene ferme anche: $(($dipendenti | ForEach-Object { "#$_" }) -join ', ')" }
                New-Problema "card-$($r.Id)-sblocca" "Card #$($r.Id) ($titolo): in on-hold" ([string](Get-Campo $indicazioni 'Gesto')) $r.Url -Righe $righe
                continue
            }
            if ($att.Attivita -eq 'sblocca' -and $bloccato) {
                $chi = [string]$bloccato.Ruolo
                $righe = @($bloccato.Righe)
                if ($righe.Count -gt 0) {
                    New-Problema "card-$($r.Id)-bloccato" "Card #$($r.Id) ($titolo): in on-hold, il $chi ha chiuso bloccato e ha scritto cosa serve" "fai i passi del $chi (qui sotto e nel suo commento sulla card) e togli il tag $($o.TagAttesa) solo dopo" $r.Url -Righe $righe
                }
                else {
                    # chiave sua: una diagnosi conservata (Sync-DiagnosiConservate) non si riattacca alla voce con il resoconto
                    New-Problema "card-$($r.Id)-bloccato-senza-resoconto" "Card #$($r.Id) ($titolo): in on-hold, il $chi ha chiuso bloccato senza resoconto" "leggi i commenti della card e risolvi la causa prima di togliere il tag $($o.TagAttesa)" $r.Url -DaDiagnosi $true
                }
                continue
            }
            $azione = switch ($att.Attivita) {
                'sblocca' { "risolvi la causa e togli il tag $($o.TagAttesa) dalla card" }
                'prova' { 'prova la card in Test e scrivi l''esito in un commento sulla card' }
                'rispondi' { 'rispondi alla domanda del responsabile con un commento sulla card' }
                'rilascia' { 'rilascia la card in produzione' }
                default { 'apri la card' }
            }
            New-Problema "card-$($r.Id)-$($att.Attivita)" "Card #$($r.Id) ($titolo): $($att.Testo)" $azione $r.Url
            continue
        }
        # La validazione della PR in corso da troppo dopo la fine di dev: lo smistatore ne fa un avviso sulla card (Decisioni,
        # validazioneLunga), che non arriva piu su Telegram. Stesso dato: il limite e validazioneMinuti, il punto di partenza la fine
        # dell'ultima sessione.
        $pr = $r.Pr
        $fine = Get-Campo $r 'ValidazioneFine'
        $limiteVal = Get-Campo $o.Limiti 'validazioneMinuti'
        if ($pr -and $pr.Validazione -eq 'inCorso' -and $fine -and $limiteVal -and ($o.Adesso - $fine).TotalMinutes -gt [double]$limiteVal) {
            New-Problema "validazione-lunga-$($r.Id)" "La validazione della PR della card #$($r.Id) ($titolo) e in corso da piu di $limiteVal minuti dalla fine di dev." 'apri il log della build: e bloccata o l''esito non si legge' $(if ($pr.UrlLog) { [string]$pr.UrlLog } else { $r.Url })
        }
        if ($att) { continue }
        # senza on-hold, sessione, azioni, motivo ne gesto da una persona: nessuna regola la spiega. Le card che aspettano un
        # motivo noto (predecessori, limiti, quota) hanno un motivo e non arrivano qui.
        $ore = if ($c.FermaDaOre -and $c.FermaDaOre.ContainsKey("$($r.Id)")) { [double]$c.FermaDaOre["$($r.Id)"] } else { 0 }
        # D52: una card In feature branch, o la chiusura che aspetta il resto della funzionalita, sta dove deve (AspettaFunzionalita, da Get-RigaCoda)
        if (-not $r.Errore -and -not $r.Gesto -and -not $r.Motivo -and -not [bool](Get-Campo $r 'AspettaFunzionalita') -and [int]$r.Azioni -eq 0 -and $ore -ge $Config.oreSenzaMovimento) {
            New-Problema "ferma-$($r.Id)" "La card #$($r.Id) ($titolo) e ferma da $([int][math]::Floor($ore)) ore in $($r.Stato) e nessuna regola dice perche." 'apri la card e guarda perche non si muove' $r.Url -DaDiagnosi $true
        }
    }
    if ($rilasci.Count -gt 0) { Get-ProblemaRilasci -Righe $rilasci -Config $Config -Adesso $o.Adesso }
    if ($deployTest.Count -gt 0) { Get-ProblemaDeployTest -Righe $deployTest }
}

# D61: le card unite in develop che aspettano un deploy di develop in Test, come una voce sola (chiave deploy-test): il deploy lo lancia
# Titolare, uno per tutte. Una riga per card; la voce torna quando ne arriva una nuova (Elementi), non si ricorda ogni giorno.
function Get-ProblemaDeployTest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Righe)
    $card = @($Righe | Where-Object { $null -ne $_ } | Sort-Object { [int]$_.Id })
    $righeVoce = @($card | ForEach-Object { "#$($_.Id) $(Get-RigaBreve ([string](Get-Campo $_ 'Titolo')) 70)" })
    $n = $card.Count
    $testo = if ($n -eq 1) { "La card #$($card[0].Id) e unita in develop e aspetta un deploy di develop in Test." }
             else { "$n card unite in develop aspettano un deploy di develop in Test: $((@($card | ForEach-Object { "#$($_.Id)" })) -join ', ')." }
    New-Problema 'deploy-test' $testo 'lancia il deploy di develop in Test: lo smistatore porta le card in Ready to release quando e riuscito' ([string](Get-Campo $card[0] 'Url')) `
        -Righe $righeVoce -Elementi @($card | ForEach-Object { "$($_.Id)" }) -Ricorda $false
}

# Da quando una card in attesa di rilascio e li: l'ingresso nello stato dalla storia (InStatoDa) se l'istantanea lo ha, altrimenti il
# primo visto del supervisore (rilasciVisti in supervisore.json).
function Set-RilasciDa {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)][AllowEmptyCollection()]$Righe, [Parameter(Mandatory)][datetime]$Adesso)
    $vedi = Get-Campo $Supervisore 'rilasciVisti'
    if ($null -eq $vedi) { $vedi = @{} }
    $ora = @{}
    foreach ($r in @($Righe | Where-Object { $_ -and (Get-Campo (Get-Campo $_ 'Attivita') 'Attivita') -eq 'rilascia' })) {
        $k = "$($r.Id)"
        $visto = if ($vedi.ContainsKey($k)) { ConvertTo-DataUtc $vedi[$k] } else { $null }
        if (-not $visto) { $visto = $Adesso }
        $ora[$k] = $visto.ToString('o')
        if (-not (Get-Campo $r 'InStatoDa')) { Add-Member -InputObject $r -NotePropertyName InStatoDa -NotePropertyValue $visto -Force }
    }
    $Supervisore['rilasciVisti'] = $ora
}

# I rilasci in attesa come una voce sola (chiave rilasci): una riga per area, con quante card, i loro numeri e da quanti giorni aspetta
# la piu vecchia. Un'area e oltre soglia se ha almeno `card` card o la piu vecchia aspetta da `giorni` giorni (rilasci.predefinito,
# o rilasci.perArea per quell'area): la riga lo dice ("OLTRE SOGLIA" e il motivo) e va in cima. Non e mai un urgente. La voce si
# ricorda ogni giorno solo se almeno un'area e oltre soglia; una card nuova la fa ricomparire (Elementi).
# Le aree dei rilasci in attesa, con le soglie: per ogni area le sue card (Id, Titolo, Url), da quanti giorni aspetta la piu vecchia e
# se e oltre soglia per numero di card, per giorni o per tutti e due. In ordine: prima le oltre soglia, poi le piu numerose.
function Get-GruppiRilasci {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Righe, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][datetime]$Adesso)
    $ril = Get-Campo $Config 'rilasci'
    $pre = Get-Campo $ril 'predefinito'
    $sogliaPre = @{ card = $(if ($pre) { [int]$pre.card } else { 5 }); giorni = $(if ($pre) { [int]$pre.giorni } else { 7 }) }
    $perArea = Get-Campo $ril 'perArea'
    $gruppi = foreach ($g in @($Righe | Group-Object { [string](Get-Campo $_ 'Area') })) {
        $area = if ($g.Name) { $g.Name } else { '(area sconosciuta)' }
        $so = if ($g.Name) { Get-Campo $perArea $g.Name } else { $null }
        $maxCard = if ($so) { [int]$so.card } else { $sogliaPre.card }
        $maxGiorni = if ($so) { [int]$so.giorni } else { $sogliaPre.giorni }
        $giorni = 0
        foreach ($r in $g.Group) { $da = Get-Campo $r 'InStatoDa'; if ($da) { $giorni = [math]::Max($giorni, [int][math]::Floor(($Adesso - $da).TotalDays)) } }
        # D52: le card di una funzionalita sono una voce sola (Id = la Feature, con il numero delle sue card nel titolo): vanno in produzione insieme
        $voci = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $g.Group) {
            $fun = Get-Campo $r 'Funzionalita'
            if ($null -eq $fun) { $voci.Add([pscustomobject]@{ Id = [int]$r.Id; Titolo = [string](Get-Campo $r 'Titolo'); Url = [string](Get-Campo $r 'Url'); Funzionalita = $false; Numero = 1 }); continue }
            $esistente = $voci | Where-Object { $_.Funzionalita -and $_.Id -eq [int]$fun.Feature } | Select-Object -First 1
            if ($esistente) { $esistente.Numero++; continue }
            # il link e quello della Feature: se la riga non lo porta resta vuoto, non si ripiega sul link di una sua card
            $voci.Add([pscustomobject]@{ Id = [int]$fun.Feature; Titolo = [string]$fun.Titolo; Url = [string](Get-Campo $r 'UrlFeature'); Funzionalita = $true; Numero = 1 })
        }
        foreach ($v in $voci) { if ($v.Funzionalita) { $v.Titolo = "$($v.Titolo) ($($v.Numero) card)" } }
        $card = @($voci | Sort-Object { [int]$_.Id })
        $nCard = 0; foreach ($v in $card) { $nCard += [int]$v.Numero }
        [pscustomobject]@{ Area = $area; Card = $card; NumeroCard = $nCard; Giorni = $giorni; MaxCard = $maxCard; MaxGiorni = $maxGiorni
            OltreCard = ($card.Count -ge $maxCard); OltreGiorni = ($giorni -ge $maxGiorni) }
    }
    $ordinati = @($gruppi | ForEach-Object { Add-Member -InputObject $_ -NotePropertyName Oltre -NotePropertyValue ($_.OltreCard -or $_.OltreGiorni) -PassThru } |
        Sort-Object @{ Expression = { -[int]$_.Oltre } }, @{ Expression = { -$_.Card.Count } }, Area)
    $ordinati
}

# I rilasci in attesa come una voce sola (chiave rilasci): una riga per area, con quante card, i loro numeri e da quanti giorni aspetta
# la piu vecchia. Un'area e oltre soglia se ha almeno `card` card o la piu vecchia aspetta da `giorni` giorni (rilasci.predefinito,
# o rilasci.perArea per quell'area): la riga lo dice ("OLTRE SOGLIA" e il motivo) e va in cima. Non e mai un urgente. La voce si
# ricorda ogni giorno solo se almeno un'area e oltre soglia; una card nuova la fa ricomparire (Elementi). Le righe sono per il log e
# per -WhatIf: il messaggio nel topic Rilasci si compone da Get-GruppiRilasci (Format-RilasciTelegram).
function Get-ProblemaRilasci {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Righe, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][datetime]$Adesso)
    $ordinati = @(Get-GruppiRilasci -Righe $Righe -Config $Config -Adesso $Adesso)
    $righeVoce = foreach ($g in $ordinati) {
        $da = if ($g.Giorni -eq 0) { 'da meno di un giorno' } elseif ($g.Giorni -eq 1) { 'da 1 giorno' } else { "da $($g.Giorni) giorni" }
        $riga = "$($g.Area): $($g.Card.Count) card ($(($g.Card | ForEach-Object { if ($_.Funzionalita) { "funzionalita #$($_.Id) ($($_.Numero) card)" } else { "#$($_.Id)" } }) -join ', ')), la piu vecchia aspetta $da"
        if ($g.Oltre) {
            $motivi = @(); if ($g.OltreCard) { $motivi += "$($g.Card.Count) card (soglia $($g.MaxCard))" }; if ($g.OltreGiorni) { $motivi += "$($g.Giorni) giorni (soglia $($g.MaxGiorni))" }
            $riga = "OLTRE SOGLIA - $riga - $($motivi -join ' e ')"
        }
        $riga
    }
    $oltre = @($ordinati | Where-Object Oltre).Count
    $tutte = 0; $voci = 0; foreach ($g in $ordinati) { $tutte += [int]$g.NumeroCard; $voci += @($g.Card).Count }
    $testo = "Rilasci in attesa: $tutte card in $(@($ordinati).Count) " + $(if (@($ordinati).Count -eq 1) { 'area' } else { 'aree' }) + $(
        # le voci si dicono solo quando non sono le card (una funzionalita e una voce con piu card)
        $parti = @(); if ($voci -ne $tutte) { $parti += "$voci $(if ($voci -eq 1) { 'voce' } else { 'voci' })" }; if ($oltre -gt 0) { $parti += "$oltre oltre soglia" }
        if ($parti.Count -gt 0) { " ($($parti -join ', '))" } else { '' })
    $prima = @($Righe)[0]
    $url = if (Get-Campo $prima 'Funzionalita') { Get-Campo $prima 'UrlFeature' } else { Get-Campo $prima 'Url' }
    # Gruppi non finisce in supervisore.json: serve al giro che sta girando, per il messaggio nel topic Rilasci
    $p = New-Problema 'rilasci' $testo 'rilascia in produzione le card pronte, a partire dalle aree oltre soglia' ([string]$url) -Righe @($righeVoce) -Elementi @($ordinati | ForEach-Object { $_.Card } | ForEach-Object { if ($_.Funzionalita) { "f$($_.Id)" } else { "$($_.Id)" } }) -Ricorda ($oltre -gt 0)
    Add-Member -InputObject $p -NotePropertyName Gruppi -NotePropertyValue @($ordinati) -PassThru
}
# ---- 5. le pipeline ----------------------------------------------------------------------------------------------

function Test-FallimentoInfrastruttura([string]$Motivo, $Config) {
    if ([string]::IsNullOrWhiteSpace($Motivo)) { return $false }
    foreach ($t in @($Config.testiInfrastruttura)) { if ($Motivo -match "(?i)$t") { return $true } }
    $false
}

# I run falliti che il supervisore guarda: pipeline dei repo della mappa, solo esito failed, mai una validazione di PR (le
# gestisce D38), mai un rilascio o una pipeline di deploy (nessuno tocca il deploy), mai un ramo di una card (feature/, fix/).
function Select-FallitiDaEsaminare {
    [CmdletBinding()]
    param([AllowNull()]$Falliti, [Parameter(Mandatory)]$ProgettiMappa, $DefinizioniDeploy = @())
    @(@($Falliti) | Where-Object {
        $null -ne $_ -and $_.Esito -eq 'failed' -and $_.Progetto -in @($ProgettiMappa) -and
        $_.Tipo -notin 'pr', 'rilascio' -and [int]$_.DefinizioneId -notin @($DefinizioniDeploy | ForEach-Object { [int]$_ }) -and
        $_.Pipeline -notmatch '(?i)orchestrator|deploy|release|rilascio' -and $_.Ramo -notmatch '^(feature|fix)/'
    })
}

# La chiave con cui l'osservazione ricorda l'ultimo run di una definizione su un ramo.
function Get-ChiaveUltimoRun($Run) { "$($Run.Progetto)|$($Run.DefinizioneId)|$($Run.Ramo)" }

# Come stanno i run falliti che il supervisore guarda (Select-FallitiDaEsaminare):
#   Rilanciabili   fallito per infrastruttura, definizione in pipelineRilanciabili, ramo develop (mai main), ed e l'ultimo run di quella
#                  definizione e di quel ramo; non gia rilanciato, e non e esso stesso un nostro rilancio
#   DaConfigurare  fallito per infrastruttura, ma non rilanciabile: si potrebbe rilanciare (aggiungere la pipeline a pipelineRilanciabili)
#                  o va fatto a mano (altro ramo)
#   Ripetuti       un nostro rilancio fallito di nuovo per infrastruttura
#   SenzaCausa     fallito senza una causa che si riconosca: da diagnosi
#   Superati       un run piu recente della stessa definizione e dello stesso ramo e riuscito: non c'e piu niente da dire
#   GiaRilanciati  rilanciati da noi (una volta per run)
function Get-FallitiInfrastruttura {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Osservazione, [Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)]$Config)
    $p = $Osservazione.Pipeline
    $rilanciati = Get-Campo $Supervisore.gesti 'rilanciati'
    if ($null -eq $rilanciati) { $rilanciati = @{} }
    $nuoviNostri = @(@($rilanciati.Keys) | ForEach-Object { "$(Get-Campo $rilanciati[$_] 'nuovo')" } | Where-Object { $_ })
    $ultimi = Get-Campo $p 'Ultimi'
    $lista = @(Get-Campo $Config 'pipelineRilanciabili' | Where-Object { $null -ne $_ })
    $r = [ordered]@{ Rilanciabili = @(); DaConfigurare = @(); Ripetuti = @(); SenzaCausa = @(); Superati = @(); GiaRilanciati = @() }
    foreach ($f in @(Select-FallitiDaEsaminare $p.Falliti $Osservazione.ProgettiMappa $Osservazione.DefinizioniDeploy)) {
        $ult = if ($ultimi) { Get-Campo $ultimi (Get-ChiaveUltimoRun $f) } else { $null }
        if ($ult -and [int]$ult.Id -gt [int]$f.Id -and [string]$ult.Esito -eq 'succeeded') { $r.Superati += $f; continue }
        $motivo = if ($p.Motivi -and $p.Motivi.ContainsKey("$($f.Id)")) { [string]$p.Motivi["$($f.Id)"] } else { $null }
        if (-not (Test-FallimentoInfrastruttura $motivo $Config)) { $r.SenzaCausa += $f; continue }
        if ($rilanciati.Contains("$($f.Id)")) { $r.GiaRilanciati += $f; continue }
        if ("$($f.Id)" -in $nuoviNostri) { $r.Ripetuti += $f; continue }
        $inLista = @($lista | Where-Object { [string]$_.progetto -eq [string]$f.Progetto -and [int]$_.definizioneId -eq [int]$f.DefinizioneId }).Count -gt 0
        $ultimoDelRamo = $ult -and [int]$ult.Id -eq [int]$f.Id
        if ($inLista -and [string]$f.Ramo -eq 'develop' -and $ultimoDelRamo) { $r.Rilanciabili += $f } else { $r.DaConfigurare += $f }
    }
    [pscustomobject]$r
}

function Get-ProblemiPipeline {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Osservazione, [Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)]$Config)
    $o = $Osservazione; $p = $o.Pipeline
    if ([bool](Get-Campo $o 'SenzaPat')) { return @() }
    if (-not $p.Letto) { return @(New-Problema 'lettura-pipeline' "Non riesco a leggere le pipeline di Azure DevOps: $(Get-RigaBreve $p.Errore)" 'controlla l''accesso ad Azure DevOps e il log di oggi') }
    if (@($p.Errori).Count -gt 0) {
        New-Problema 'lettura-pipeline-progetti' "Non riesco a leggere le pipeline di alcuni progetti: $(Get-RigaBreve (@($p.Errori) | Select-Object -First 2 | Out-String) 240)" 'controlla l''accesso ad Azure DevOps e il log di oggi'
    }
    if (-not [bool](Get-Campo $p 'AgentiLetti')) {
        New-Problema 'lettura-agenti' "Non riesco a leggere gli agenti dei pool interni: $(Get-RigaBreve (@(Get-Campo $p 'ErroriAgenti') | Select-Object -First 2 | Out-String) 240)" 'controlla che il PAT dello smistatore abbia il permesso sui pool di agenti'
    }
    $tutti = @(@($p.Attivi) + @($p.Orchestratori) | Where-Object { $null -ne $_ })
    foreach ($r in @($tutti | Where-Object { $_.Stato -eq 'inAttesa' })) {
        $fase = if ($r.Fase) { " (fase $($r.Fase))" } else { '' }
        New-Problema "approvazione-$($r.Id)" "Il run $($r.Pipeline) sul ramo $($r.Ramo) aspetta la tua approvazione$fase." 'apri il run e approvalo o rifiutalo' $r.Url -Urgente $true
    }
    foreach ($pool in @($p.AgentiPool)) {
        foreach ($a in @($pool.Agenti | Where-Object { $_.Abilitato -and -not $_.Online })) {
            New-Problema "agente-offline-$($pool.Pool)-$($a.Nome)" "L'agente $($a.Nome) del pool $($pool.Pool) e offline." "riavvia il servizio dell'agente $($a.Nome) sul suo server (pool $($pool.Pool))" "$($o.UrlOrganizzazione)/_settings/agentpools" -Urgente $true
        }
    }
    foreach ($r in @($tutti | Where-Object { $_.Stato -eq 'inCoda' -and $_.Inizio -and ($o.Adesso - $_.Inizio).TotalMinutes -gt $Config.minutiInCoda })) {
        New-Problema "coda-$($r.Id)" "Il run $($r.Pipeline) ($($r.Ramo)) e in coda $(Format-Attesa ($o.Adesso - $r.Inizio))." 'controlla gli agenti del pool: se sono occupati o offline sbloccali' $r.Url
    }
    $f = Get-FallitiInfrastruttura $o $Supervisore $Config
    foreach ($r in @($f.Ripetuti)) {
        New-Problema "run-fallito-$($r.Id)" "Il run $($r.Pipeline) ($($r.Ramo)) e fallito di nuovo per infrastruttura dopo il rilancio automatico." 'controlla l''agente e rilancia a mano il run' $r.Url
    }
    foreach ($r in @($f.DaConfigurare)) {
        $azione = if ([string]$r.Ramo -eq 'develop') { "si potrebbe rilanciare: aggiungi la pipeline (progetto $($r.Progetto), definizioneId $($r.DefinizioneId)) a pipelineRilanciabili in config/supervisore.json, oppure rilancialo a mano" } else { 'rilancialo a mano (il supervisore rilancia solo develop)' }
        New-Problema "run-fallito-$($r.Id)" "Il run $($r.Pipeline) ($($r.Ramo)) e fallito per un guasto dell'infrastruttura." $azione $r.Url
    }
    foreach ($r in @($f.SenzaCausa)) {
        New-Problema "run-fallito-$($r.Id)" "Il run $($r.Pipeline) ($($r.Ramo)) e fallito e il motivo non e un guasto noto dell'infrastruttura." 'apri il run, leggi l''errore e decidi se rilanciarlo o correggere il codice' $r.Url -DaDiagnosi $true
    }
    # un rilancio che non e partito (o di cui non si sa): una volta per run, per un giorno
    $rilanciati = Get-Campo $Supervisore.gesti 'rilanciati'
    foreach ($id in @($rilanciati.Keys | Sort-Object)) {
        $e = $rilanciati[$id]
        $quando = ConvertTo-DataUtc (Get-Campo $e 'quando')
        if ($null -eq (Get-Campo $e 'nuovo') -and $quando -and ($o.Adesso - $quando).TotalHours -le 24) {
            New-Problema "rilancio-fallito-$id" "Il rilancio automatico del run $id non e riuscito (o non si sa se sia partito)." "guarda il run $id e le righe del log del supervisore, e rilancialo a mano se serve" "$($o.UrlOrganizzazione)"
        }
    }
}

# ---- 6. la quota -------------------------------------------------------------------------------------------------

function Get-ProblemiQuota {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Osservazione, [Parameter(Mandatory)]$Config)
    $o = $Osservazione
    if (-not $o.Quota.Letto) { return @(New-Problema 'lettura-quota' "Non riesco a leggere quota.json: $(Get-RigaBreve $o.Quota.Errore)" 'controlla il file quota.json nella cartella dati') }
    # la stessa regola dello smistatore: il cancello e Get-BloccoQuota. Mai urgente: D51 non mette la quota fra gli urgenti
    $b = Get-BloccoQuota @{ Quota = $o.Quota.Dati; Adesso = $o.Adesso.ToString('o'); Limiti = $o.Limiti; OverrideQuota = (Get-Campo $o.Quota 'Override') }
    if (-not $b) { return @() }
    $quando = (ConvertTo-DataUtc $b.Fino).ToLocalTime().ToString('dd/MM HH:mm')
    if ($b.Causa -eq 'limite') {
        return @(New-Problema 'quota-pausa' "Gli agenti sono fermi per il limite di token fino al $quando." 'niente da fare: riprendono da soli dopo il reset')
    }
    $uso = [math]::Round([double]$b.Uso * 100)
    # D60: la soglia delle 5 ore e un freno voluto, che passa da solo a ogni reset della finestra: non e un problema da segnalare
    if ($b.Causa -eq 'cinqueOre') { return @() }
    @(New-Problema 'quota-riserva' "Riserva settimanale raggiunta ($uso% di token usati): gli agenti non partono fino al $quando." 'alza la soglia o ignora la riserva dalla vista')
}

# ---- 7. il PAT ---------------------------------------------------------------------------------------------------

function Get-ProblemiPat {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Osservazione, [Parameter(Mandatory)]$Config)
    $o = $Osservazione
    $comando = 'pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Pat'
    $problemi = @()
    # Il supervisore usa solo pat-smistatore.txt (mai pat.txt, che e di una persona): senza, niente chiamate ad Azure DevOps.
    if ([bool](Get-Campo $o 'SenzaPat')) {
        $problemi += New-Problema 'pat-mancante' 'Manca il PAT dello smistatore (pat-smistatore.txt): il supervisore non puo leggere Azure DevOps.' $comando $o.UrlOrganizzazione -Urgente $true
    }
    # un PAT rifiutato si vede nel log del giro (riga "PAT scaduto o revocato", o un 401) e nelle nostre stesse letture. Nel log
    # contano solo le righe recenti: a PAT rinnovato il giro non le scrive piu, e la riga di stamattina resta nel file di oggi.
    $recenti = @(ConvertFrom-RigheLog $o.Log.Righe | Where-Object { $_.Quando -and ($o.Adesso - $_.Quando).TotalMinutes -le $Config.minutiSenzaGiro } | ForEach-Object { $_.Testo })
    $nostri = @($o.Card.Errore, $o.Pipeline.Errore) + @($o.Pipeline.Errori)
    $re = Get-RegexPatRifiutato
    if (@(@($recenti) + @($nostri) | Where-Object { $_ -and "$_" -match $re }).Count -gt 0) {
        $problemi += New-Problema 'pat-rifiutato' 'Azure DevOps rifiuta il PAT dello smistatore (scaduto o revocato): le card non avanzano.' $comando $o.UrlOrganizzazione -Urgente $true
    }
    if (-not $o.Pat.Letto) { return @($problemi) + @(New-Problema 'lettura-pat' "Non riesco a leggere pat-info.json: $(Get-RigaBreve $o.Pat.Errore)" 'controlla il file pat-info.json in ~/.claude') }
    $sc = $o.Pat.Scadenza
    if ($sc -and $sc -le $o.Adesso.AddDays($Config.giorniPreavvisoPat)) {
        $data = $sc.ToLocalTime().ToString('dd/MM/yyyy')
        $testo = if ($sc -le $o.Adesso) { "Il PAT dello smistatore e scaduto il $data." } else { "Il PAT dello smistatore scade il $data." }
        $problemi += New-Problema 'pat-scadenza' $testo $comando $o.UrlOrganizzazione
    }
    $problemi
}

# ---- tutti i controlli -------------------------------------------------------------------------------------------

# Un controllo che lancia non ferma gli altri: diventa un problema "il controllo X non e riuscito".
function Get-ProblemiSupervisore {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Osservazione, [Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)]$Config)
    $o = $Osservazione
    $controlli = [ordered]@{
        smistatore = { Get-ProblemiSmistatore $o $Config }
        erroriCard = { Get-ProblemiErroriCard $o $Config }
        vista      = { Get-ProblemiVista $o $Supervisore $Config }
        card       = { Get-ProblemiCard $o $Config }
        pipeline   = { Get-ProblemiPipeline $o $Supervisore $Config }
        quota      = { Get-ProblemiQuota $o $Config }
        pat        = { Get-ProblemiPat $o $Config }
    }
    $tutti = [System.Collections.Generic.List[object]]::new()
    foreach ($nome in $controlli.Keys) {
        try { foreach ($p in @(& $controlli[$nome])) { if ($null -ne $p) { $tutti.Add($p) } } }
        catch { $tutti.Add((New-Problema "controllo-$nome" "Il controllo '$nome' del supervisore non e riuscito: $(Get-RigaBreve $_.Exception.Message)" 'guarda il log del supervisore (cartella dati, log/supervisore-AAAA-MM-GG.log)')) }
    }
    @($tutti)
}

# ---- i gesti -----------------------------------------------------------------------------------------------------

# Cosa il supervisore fa da solo, e solo questo: riavviare la vista e rilanciare un run fallito per infrastruttura (solo le pipeline
# in pipelineRilanciabili, solo develop). Niente deploy, approvazioni, merge, e un'attivita disabilitata non si riattiva.
function Get-GestiSupervisore {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Osservazione, [Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)]$Config)
    $o = $Osservazione
    $gesti = @()
    # la vista e giu dopo due mancate risposte di fila
    if (-not $o.VistaRisponde -and [int]$o.VistaMancate -ge 2) {
        $att = $o.VistaAttivita
        $disabilitata = $att.Letto -and -not $att.Abilitata
        $ultimo = @(@($Supervisore.gesti.riavviiVista) | ForEach-Object { ConvertTo-DataUtc $_ } | Where-Object { $_ } | Sort-Object) | Select-Object -Last 1
        if (-not $disabilitata -and (-not $ultimo -or ($o.Adesso - $ultimo).TotalMinutes -ge $Config.minutiFraRiavviiVista)) {
            # se l'attivita risulta in esecuzione ma non risponde e bloccata: si ferma e si riavvia
            $gesti += [pscustomobject]@{ Tipo = 'RiavviaVista'; Ferma = ($att.Letto -and [string]$att.Stato -eq 'Running') }
        }
    }
    if ($o.Pipeline -and $o.Pipeline.Letto -and -not [bool](Get-Campo $o 'SenzaPat')) {
        foreach ($r in @((Get-FallitiInfrastruttura $o $Supervisore $Config).Rilanciabili)) { $gesti += [pscustomobject]@{ Tipo = 'RilanciaRun'; Run = $r } }
    }
    $gesti
}

# ---- supervisore.json --------------------------------------------------------------------------------------------

function Get-PercorsoSupervisorePredefinito { Join-Path (Get-CartellaDati) 'supervisore.json' }

# Problemi aperti per chiave, gesti fatti, riepiloghi mandati, ultima esecuzione, firme delle card. Il file che manca e uno stato vuoto.
function Get-StatoSupervisore {
    [CmdletBinding()]
    param([string]$Percorso = (Get-PercorsoSupervisorePredefinito))
    $s = Get-Stato -Percorso $Percorso
    foreach ($c in @{ problemi = { @{} }; riepiloghi = { @() }; ultimaEsecuzione = { $null }; firme = { @{} }; gesti = { @{} }
            esecuzioni = { @() }; sessioniDiagnosi = { @() }; diagnosiGiorno = { @{ data = ''; n = 0 } }; vistaMancate = { 0 }; eventi = { @() }
            diagnosiConservate = { @{} }; rilasciVisti = { @{} } }.GetEnumerator()) {
        if (-not $s.Contains($c.Key) -or $null -eq $s[$c.Key]) { $s[$c.Key] = & $c.Value }
    }
    if (-not $s.gesti.Contains('riavviiVista') -or $null -eq $s.gesti['riavviiVista']) { $s.gesti['riavviiVista'] = @() }
    if (-not $s.gesti.Contains('rilanciati') -or $null -eq $s.gesti['rilanciati']) { $s.gesti['rilanciati'] = @{} }
    $s
}

function Save-StatoSupervisore {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Stato, [string]$Percorso = (Get-PercorsoSupervisorePredefinito))
    Save-Stato -Stato $Stato -Percorso $Percorso
}

# ---- gli avvisi --------------------------------------------------------------------------------------------------

# I problemi di adesso sui problemi aperti: uno gia aperto conserva primo visto, ultimo avviso e diagnosi; uno nuovo comincia
# adesso; uno che non si vede piu sparisce, senza messaggi.
function Update-ProblemiAperti {
    [CmdletBinding()]
    param([AllowNull()]$Aperti, [Parameter(Mandatory)][AllowEmptyCollection()]$Problemi, [Parameter(Mandatory)][datetime]$Adesso,
        [string[]]$SezioniNonLette = @(), [int]$AssenzeMax = 2)
    $nuovi = @{}
    foreach ($p in @($Problemi | Where-Object { $null -ne $_ })) {
        $prima = Get-Campo $Aperti $p.Chiave
        $nuovi[$p.Chiave] = @{
            primoVisto = $(if ($prima -and (Get-Campo $prima 'primoVisto')) { (ConvertTo-DataUtc (Get-Campo $prima 'primoVisto')).ToString('o') } else { $Adesso.ToString('o') })
            ultimoVisto = $Adesso.ToString('o'); assenze = 0
            ultimoAvviso = $(if ($prima -and (Get-Campo $prima 'ultimoAvviso')) { (ConvertTo-DataUtc (Get-Campo $prima 'ultimoAvviso')).ToString('o') } else { $null })
            urgente = [bool]$p.Urgente; testo = [string]$p.Testo; azione = [string]$p.Azione; link = [string]$p.Link
            daDiagnosi = [bool]$p.DaDiagnosi; diagnosi = $(if ($prima) { [string](Get-Campo $prima 'diagnosi') } else { '' })
            righe = @($p.Righe); elementi = @($p.Elementi); ricorda = [bool]$p.Ricorda
            avvisati = $(if ($prima -and $null -ne (Get-Campo $prima 'avvisati')) { @(Get-Campo $prima 'avvisati') } else { @() })
        }
    }
    # Un problema che non si vede si chiude dopo $AssenzeMax giri senza vederlo (una lettura andata male per un giro non lo chiude e
    # lo riapre); se la sua sezione non si e letta non si sa niente: resta com'e.
    if ($null -ne $Aperti) {
        foreach ($k in @($Aperti.Keys)) {
            if ($nuovi.ContainsKey($k)) { continue }
            $e = $Aperti[$k]
            if ((Get-SezioneDelProblema $k) -in $SezioniNonLette -and $null -ne (Get-SezioneDelProblema $k)) { $nuovi[$k] = $e; continue }
            $a = 1 + [int](Get-Campo $e 'assenze')
            if ($a -ge $AssenzeMax) { continue }
            $copia = @{}; foreach ($c in $e.Keys) { $copia[$c] = $e[$c] }
            $copia['assenze'] = $a
            $nuovi[$k] = $copia
        }
    }
    $nuovi
}

# Cosa mandare adesso. Urgenti: appena compaiono e poi ogni oreRicordoUrgente. Riepilogo: se e passato un orario (feriali) non ancora
# servito oggi, o il PC e appena stato acceso (anche nel weekend), e c'e almeno una voce nuova o da ricordare (una volta al
# giorno); alla ripartenza del PC invece tutto cio che e aperto e non urgente. Una fascia senza voci si consuma lo stesso: una voce
# che compare alle 9 aspetta le 14, non parte a un orario che non e il suo.
function Get-PianoAvvisi {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)][datetime]$Adesso, [Parameter(Mandatory)]$Config, $AvvioPc = $null)
    $locale = $Adesso.ToLocalTime()
    $voce = {
        param($k, $e, $ricordo)
        $primo = ConvertTo-DataUtc (Get-Campo $e 'primoVisto')
        [pscustomobject]@{ Chiave = $k; Testo = [string]$e.testo; Azione = [string]$e.azione; Link = [string]$e.link; Urgente = [bool]$e.urgente
            Ricordo = $ricordo; Attesa = $(if ($ricordo -and $primo) { Format-Attesa ($Adesso - $primo) } else { '' }); DaDiagnosi = [bool](Get-Campo $e 'daDiagnosi'); Diagnosi = [string](Get-Campo $e 'diagnosi'); Righe = @(Get-Campo $e 'righe') }
    }
    $urgenti = @(); $voci = @()
    foreach ($k in @($Supervisore.problemi.Keys | Sort-Object)) {
        $e = $Supervisore.problemi[$k]
        # un problema che non si vede da un giro e ancora aperto ma non si dice: o torna, o si chiude
        if ([int](Get-Campo $e 'assenze') -gt 0) { continue }
        $ultimo = ConvertTo-DataUtc (Get-Campo $e 'ultimoAvviso')
        if ([bool]$e.urgente) {
            if (-not $ultimo -or ($Adesso - $ultimo).TotalHours -ge $Config.oreRicordoUrgente) { $urgenti += (& $voce $k $e ([bool]$ultimo)) }
            continue
        }
        # una voce raggruppata (i rilasci): torna quando contiene un elemento nuovo rispetto all'ultimo avviso; il ricordo di ogni giorno
        # solo se la voce lo vuole (Ricorda: per i rilasci, solo con un'area oltre soglia)
        $elementi = @(Get-Campo $e 'elementi' | ForEach-Object { "$_" })
        $nuovi = @($elementi | Where-Object { $_ -notin @(Get-Campo $e 'avvisati' | ForEach-Object { "$_" }) })
        if (-not $ultimo) { $voci += (& $voce $k $e $false) }
        elseif ($elementi.Count -gt 0 -and $nuovi.Count -gt 0) { $voci += (& $voce $k $e $false) }
        elseif ($elementi.Count -gt 0 -and -not [bool](Get-Campo $e 'ricorda')) { continue }
        elseif ($ultimo.ToLocalTime().Date -lt $locale.Date) { $voci += (& $voce $k $e $true) }
    }
    $feriale = $locale.DayOfWeek -notin [DayOfWeek]::Saturday, [DayOfWeek]::Sunday
    $fatte = @($Supervisore.riepiloghi | ForEach-Object { "$_" })
    $fasce = @()
    if ($feriale) {
        foreach ($orario in @($Config.orariRiepilogo)) {
            $h = [timespan]::Parse($orario)
            $chiave = '{0:yyyy-MM-dd} {1}' -f $locale, $orario
            if ($locale.TimeOfDay -ge $h -and $chiave -notin $fatte) { $fasce += $chiave }
        }
    }
    $ultimaEsec = ConvertTo-DataUtc $Supervisore.ultimaEsecuzione
    $avvio = ConvertTo-DataUtc $AvvioPc
    # appena acceso: l'ultima esecuzione e prima dell'avvio del PC, oppure (dopo una sospensione l'avvio non cambia) e piu vecchia
    # di tre intervalli
    $pcAppenaAcceso = [bool](($avvio -and (-not $ultimaEsec -or $ultimaEsec -lt $avvio)) -or ($ultimaEsec -and ($Adesso - $ultimaEsec).TotalMinutes -gt 3 * [double]$Config.intervalloMinuti))
    $dovuto = $fasce.Count -gt 0 -or $pcAppenaAcceso
    # anche alla ripartenza solo le voci non ancora avvisate oggi (nuove o da ricordare): il resto l'hai gia letto
    $elenco = $voci
    [pscustomobject]@{
        Urgenti = $urgenti; Riepilogo = $(if ($dovuto) { @($elenco) } else { @() }); MandaRiepilogo = ($dovuto -and @($elenco).Count -gt 0)
        Fasce = $fasce; PcAppenaAcceso = $pcAppenaAcceso; InSospeso = @($voci).Count
    }
}

# Segna come avvisate le voci mandate e le fasce servite; tiene solo le fasce degli ultimi giorni.
function Register-AvvisiMandati {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Chiavi, [AllowEmptyCollection()][string[]]$Fasce = @(), [Parameter(Mandatory)][datetime]$Adesso)
    foreach ($k in $Chiavi) {
        if (-not $Supervisore.problemi.Contains($k)) { continue }
        $Supervisore.problemi[$k]['ultimoAvviso'] = $Adesso.ToString('o')
        # gli elementi di una voce raggruppata che ora sono detti: uno nuovo la fara ricomparire
        $Supervisore.problemi[$k]['avvisati'] = @(Get-Campo $Supervisore.problemi[$k] 'elementi')
    }
    $Supervisore.riepiloghi = @(@($Supervisore.riepiloghi) + @($Fasce) | Select-Object -Unique | Select-Object -Last 20)
}

# ---- la diagnosi con il modello ----------------------------------------------------------------------------------
# Il supervisore lancia una sessione del ruolo "supervisore" solo per un problema con DaDiagnosi che nessuna regola sa spiegare.
# La decisione e qui (pura); il lancio, la lettura dell'esito e lo stop stanno in src/Supervisore.ps1.

# La chiave del problema da diagnosticare adesso, o $null: una sessione per volta, al piu diagnosiAlGiorno al giorno (data
# locale, contate in supervisore.json), mai con la quota che blocca, e un problema una volta sola (la diagnosi, anche "non
# riuscita", resta scritta e non si ripete finche il problema e aperto).
function Get-DiagnosiDaLanciare {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)][datetime]$Adesso, [Parameter(Mandatory)]$Config, [bool]$QuotaBloccata = $false,
        [int]$SessioniAttive = 0, [int]$LimiteSessioni = 0)
    if ($QuotaBloccata) { return $null }
    # la diagnosi e una sessione come le altre: se quelle dello smistatore sono gia al limite non se ne aggiunge una
    if ($LimiteSessioni -gt 0 -and $SessioniAttive -ge $LimiteSessioni) { return $null }
    if (@(@($Supervisore.sessioniDiagnosi) | Where-Object { $null -ne $_ }).Count -gt 0) { return $null }
    $oggi = $Adesso.ToLocalTime().ToString('yyyy-MM-dd')
    $g = $Supervisore.diagnosiGiorno
    if ("$(Get-Campo $g 'data')" -eq $oggi -and [int](Get-Campo $g 'n') -ge [int]$Config.diagnosiAlGiorno) { return $null }
    foreach ($k in @($Supervisore.problemi.Keys | Sort-Object)) {
        $e = $Supervisore.problemi[$k]
        if ([bool](Get-Campo $e 'daDiagnosi') -and [string]::IsNullOrWhiteSpace([string](Get-Campo $e 'diagnosi'))) { return $k }
    }
    $null
}

# Una diagnosi in lancio conta nel tetto del giorno, prima ancora di sapere se la sessione e partita: se poi il giro va in errore
# il conteggio resta (meglio una diagnosi in meno che una in piu).
function Add-ConteggioDiagnosi {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)][datetime]$Adesso)
    $oggi = $Adesso.ToLocalTime().ToString('yyyy-MM-dd')
    $n = if ("$(Get-Campo $Supervisore.diagnosiGiorno 'data')" -eq $oggi) { [int](Get-Campo $Supervisore.diagnosiGiorno 'n') } else { 0 }
    $Supervisore.diagnosiGiorno = @{ data = $oggi; n = $n + 1 }
}

# La sessione lanciata si ricorda (per leggerne l'esito dopo), con l'impronta di cio che non deve cambiare mentre lavora.
function Add-SessioneDiagnosi {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)][string]$Chiave, [Parameter(Mandatory)]$Sessione, [Parameter(Mandatory)][datetime]$Adesso, $Impronta = $null, $GiroAlLancio = $null)
    $Supervisore.sessioniDiagnosi = @(@($Supervisore.sessioniDiagnosi) | Where-Object { $null -ne $_ }) + @(, @{
        id = [string]$Sessione.Id; pid = [int]$Sessione.Pid; avvio = [string]$Sessione.Avvio; chiave = $Chiave; inizio = $Adesso.ToString('o'); cartella = [string]$Sessione.Cartella
        impronta = $Impronta; giroAlLancio = $(if ($GiroAlLancio) { ([datetime]$GiroAlLancio).ToUniversalTime().ToString('o') } else { $null }) })
}

function Register-DiagnosiLanciata {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)][string]$Chiave, [Parameter(Mandatory)]$Sessione, [Parameter(Mandatory)][datetime]$Adesso)
    Add-ConteggioDiagnosi -Supervisore $Supervisore -Adesso $Adesso
    Add-SessioneDiagnosi -Supervisore $Supervisore -Chiave $Chiave -Sessione $Sessione -Adesso $Adesso
}

# Il testo della diagnosi come va nel riepilogo: senza la riga ESITO, senza codice ne tag (le regole di Telegram), su una riga.
$script:DiagnosiMaxCaratteri = 600
$script:DiagnosiFallita = 'diagnosi non riuscita'
function ConvertTo-TestoDiagnosi([AllowNull()][string]$Testo) {
    if ([string]::IsNullOrWhiteSpace($Testo)) { return '' }
    $senza = [regex]::Replace($Testo, '(?m)^[\s`*]*ESITO=\S+[\s`*]*$', '')
    ConvertTo-AnteprimaTelegram -Testo $senza -Max $script:DiagnosiMaxCaratteri
}

# Dalla fase della sessione (Get-FaseSessione di Sessioni.psm1, la stessa dello smistatore) e dal suo esito: che ne e della diagnosi.
#   inCorso   si aspetta
#   finita    ESITO=diagnosi: Testo e la diagnosi
#   fallita   finita senza esito o con errore, processo sparito senza result, o in silenzio oltre silenzioMinuti
function ConvertTo-EsitoDiagnosi {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Fase, $Esito)
    if ($Fase.Fase -eq 'inCorso') { return [pscustomobject]@{ Stato = 'inCorso'; Testo = $null } }
    if ($Fase.Fase -eq 'finita' -and $null -ne $Esito -and -not [bool](Get-Campo $Esito 'Errore') -and [string](Get-Campo $Esito 'Esito') -eq 'diagnosi') {
        $t = ConvertTo-TestoDiagnosi ([string](Get-Campo $Esito 'Testo'))
        if ($t) { return [pscustomobject]@{ Stato = 'finita'; Testo = $t } }
    }
    [pscustomobject]@{ Stato = 'fallita'; Testo = $script:DiagnosiFallita }
}

# Cosa e cambiato per mano di una sessione di diagnosi, che e di sola lettura: HEAD e git status della copia principale degli
# attrezzi sempre; gli hash di stato.json e quota.json solo se nessun giro dello smistatore e passato nel frattempo (che li riscrive
# per mestiere). Limite: un giro dello smistatore a meta sessione ci fa perdere il controllo sui due file (resta git); e una modifica
# fatta da una persona alla copia principale mentre la sessione lavora sembra della sessione (D39, stesso principio e stesso limite).
function Compare-ImprontaDiagnosi {
    [CmdletBinding()]
    param($Prima, $Dopo, [bool]$GiroInMezzo = $false)
    $d = @()
    if ($null -eq $Prima -or $null -eq $Dopo) { return $d }
    if ([string](Get-Campo $Prima 'testa') -ne [string](Get-Campo $Dopo 'testa')) { $d += 'il commit di testa della copia principale degli attrezzi' }
    if ([string](Get-Campo $Prima 'gitStato') -ne [string](Get-Campo $Dopo 'gitStato')) { $d += 'i file della copia principale degli attrezzi (git status)' }
    if (-not $GiroInMezzo) {
        if ([string](Get-Campo $Prima 'stato') -ne [string](Get-Campo $Dopo 'stato')) { $d += 'stato.json' }
        if ([string](Get-Campo $Prima 'quota') -ne [string](Get-Campo $Dopo 'quota')) { $d += 'quota.json' }
    }
    $d
}

# Chiude una sessione di diagnosi: esce dall'elenco e, se il problema e ancora aperto, ne prende la diagnosi. Un problema chiuso
# nel frattempo non c'e piu: il risultato si scarta. La voce gia detta in un riepilogo torna "nuova", cosi la diagnosi arriva alla
# prossima fascia invece che fra un giorno.
function Complete-Diagnosi {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)]$Sessione, [Parameter(Mandatory)][string]$Testo)
    $id = [string](Get-Campo $Sessione 'id')
    $Supervisore.sessioniDiagnosi = @(@($Supervisore.sessioniDiagnosi) | Where-Object { $null -ne $_ -and [string](Get-Campo $_ 'id') -ne $id })
    $k = [string](Get-Campo $Sessione 'chiave')
    if (-not $Supervisore.problemi.Contains($k)) { return $false }
    $Supervisore.problemi[$k]['diagnosi'] = $Testo
    $Supervisore.problemi[$k]['ultimoAvviso'] = $null
    $true
}

# Le esecuzioni recenti (per Test-SupervisoreContinuo): si tiene un'ora.
function Add-EsecuzioneSupervisore {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)][datetime]$Adesso)
    $Supervisore.esecuzioni = @(@($Supervisore.esecuzioni) + $Adesso.ToString('o') | Where-Object { $d = ConvertTo-DataUtc $_; $d -and $d -ge $Adesso.AddMinutes(-60) } | Select-Object -Last 30)
}

# ---- eventi, diagnosi conservate, rilanci vecchi ---------------------------------------------------------------------------

# Un problema che nasce da un fatto e non da una condizione che si rilegge (la diagnosi che ha scritto, per esempio): entra subito fra
# i problemi aperti e resta fra quelli di ogni giro per 24 ore, cosi non si chiude prima di essere detto.
function Add-EventoSupervisore {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)]$Problema, [Parameter(Mandatory)][datetime]$Adesso)
    $Supervisore.eventi = @(@($Supervisore.eventi) | Where-Object { $null -ne $_ -and (Get-Campo $_ 'chiave') -ne $Problema.Chiave }) + @(, @{
        chiave = $Problema.Chiave; testo = $Problema.Testo; azione = $Problema.Azione; link = $Problema.Link; urgente = [bool]$Problema.Urgente
        daDiagnosi = [bool]$Problema.DaDiagnosi; scade = $Adesso.AddHours(24).ToString('o') })
    $prima = Get-Campo $Supervisore.problemi $Problema.Chiave
    $t = Update-ProblemiAperti $(if ($prima) { @{ $Problema.Chiave = $prima } } else { @{} }) @($Problema) $Adesso
    $Supervisore.problemi[$Problema.Chiave] = $t[$Problema.Chiave]
}

function Get-ProblemiEventi {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)][datetime]$Adesso)
    $vivi = @(@($Supervisore.eventi) | Where-Object { $null -ne $_ -and (ConvertTo-DataUtc (Get-Campo $_ 'scade')) -gt $Adesso })
    $Supervisore.eventi = $vivi
    foreach ($e in $vivi) { New-Problema ([string]$e.chiave) ([string]$e.testo) ([string]$e.azione) ([string]$e.link) -Urgente ([bool]$e.urgente) -DaDiagnosi ([bool]$e.daDiagnosi) }
}

# Una diagnosi si tiene 24 ore dopo la chiusura del problema: se lo stesso problema riappare (a mezzanotte, dopo un giro andato male)
# non si rilancia una sessione per lo stesso testo. $Prima sono i problemi aperti prima dell'aggiornamento di questo giro.
function Sync-DiagnosiConservate {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [AllowNull()]$Prima, [Parameter(Mandatory)][datetime]$Adesso)
    $c = $Supervisore.diagnosiConservate
    if ($null -ne $Prima) {
        foreach ($k in @($Prima.Keys)) {
            if ($Supervisore.problemi.Contains($k)) { continue }
            $d = [string](Get-Campo $Prima[$k] 'diagnosi')
            if (-not [string]::IsNullOrWhiteSpace($d)) { $c[$k] = @{ diagnosi = $d; quando = $Adesso.ToString('o') } }
        }
    }
    foreach ($k in @($c.Keys)) { if (-not (ConvertTo-DataUtc (Get-Campo $c[$k] 'quando')) -or ($Adesso - (ConvertTo-DataUtc (Get-Campo $c[$k] 'quando'))).TotalHours -gt 24) { $c.Remove($k) } }
    foreach ($k in @($Supervisore.problemi.Keys)) {
        $e = $Supervisore.problemi[$k]
        if ([string]::IsNullOrWhiteSpace([string](Get-Campo $e 'diagnosi')) -and $c.Contains($k)) { $e['diagnosi'] = [string]$c[$k]['diagnosi'] }
    }
    $Supervisore.diagnosiConservate = $c
}

# I rilanci vecchi escono da supervisore.json dopo qualche giorno.
function Remove-RilanciatiVecchi {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Supervisore, [Parameter(Mandatory)][datetime]$Adesso, [int]$Giorni = 3)
    $r = $Supervisore.gesti.rilanciati
    foreach ($k in @($r.Keys)) {
        $q = ConvertTo-DataUtc (Get-Campo $r[$k] 'quando')
        if (-not $q -or ($Adesso - $q).TotalDays -gt $Giorni) { $r.Remove($k) }
    }
}

Export-ModuleMember -Function Set-RilasciDa, Get-ProblemaRilasci, Get-ProblemaDeployTest, Get-GruppiRilasci, Get-RigaBreve, Get-SezioneDelProblema, Get-SezioniNonLette, Get-ChiaveUltimoRun, Add-ConteggioDiagnosi, Add-SessioneDiagnosi, ConvertTo-EsitoDiagnosi,
    Compare-ImprontaDiagnosi, Add-EventoSupervisore, Get-ProblemiEventi, Sync-DiagnosiConservate, Remove-RilanciatiVecchi,
    Test-SupervisoreContinuo, Get-DiagnosiDaLanciare, Register-DiagnosiLanciata, ConvertTo-TestoDiagnosi, Complete-Diagnosi, Add-EsecuzioneSupervisore, Get-ConfigSupervisore, New-Problema, Format-Attesa, ConvertFrom-RigheLog, Get-ErroriDiFilaPerCard,
    Get-ProblemiSmistatore, Get-ProblemiErroriCard, Get-ProblemiVista, Get-FirmaCard, Update-FirmeCard, Get-ResocontoBloccato, Get-ProblemiCard,
    Test-FallimentoInfrastruttura, Select-FallitiDaEsaminare, Get-FallitiInfrastruttura, Get-ProblemiPipeline, Get-ProblemiQuota,
    Get-ProblemiPat, Get-ProblemiSupervisore, Get-GestiSupervisore, Get-PercorsoSupervisorePredefinito, Get-StatoSupervisore,
    Save-StatoSupervisore, Update-ProblemiAperti, Get-PianoAvvisi, Register-AvvisiMandati
