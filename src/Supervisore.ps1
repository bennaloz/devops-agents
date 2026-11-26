#requires -Version 7
# Il supervisore (D51): controlla al posto di Titolare lo smistatore, la vista, le card, le pipeline, la quota e il PAT, e lo avvisa
# su Telegram solo per cio che serve a lui. Gira in un'attivita pianificata a parte (DevOps.Agents\Supervisore, ogni
# intervalloMinuti di config/supervisore.json) perche deve vedere anche uno smistatore che non gira. Il modello serve solo per la
# diagnosi dei problemi che nessuna regola sa spiegare (Invoke-DiagnosiProblemi).
#   pwsh -NoProfile -File src/Supervisore.ps1 [-WhatIf]
# Con -WhatIf stampa problemi, gesti e messaggi che manderebbe e non scrive da nessuna parte (supervisore.json, log, Telegram,
# attivita pianificate, Azure DevOps, sessioni).
# La raccolta (I/O) sta qui; i controlli sono funzioni pure in Supervisione.psm1, provate senza rete.
# Cosa fa da solo: riavviare l'attivita della vista; rilanciare un run fallito per infrastruttura, solo per le pipeline di
# pipelineRilanciabili e solo su develop. Mai: riattivare un'attivita disabilitata, spegnere il PC, usare pat.txt (il PAT e solo
# pat-smistatore.txt), scrivere sulle card, toccare deploy, approvazioni o merge.
# Lo stato (supervisore.json) si salva subito dopo ogni gesto, ogni lancio di diagnosi e ogni invio: se non si riesce a salvare il
# giro si ferma, perche un gesto non ricordato si rifarebbe a ogni giro.
[CmdletBinding()]
param(
    [switch]$WhatIf,
    [string]$CartellaDati,
    [string]$Radice,
    # La cartella dei PAT e di pat-info.json (la scadenza, non segreta): serve ai test.
    [string]$ClaudeDir = (Join-Path $HOME '.claude'),
    [string]$PercorsoPatInfo = (Join-Path $ClaudeDir 'pat-info.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Radice) { $Radice = Split-Path -Parent $PSScriptRoot }
foreach ($m in 'Comune', 'Config', 'Ado', 'Stato', 'Decisioni', 'Sessioni', 'Telegram', 'Worktree', 'Supervisione', 'Impostazioni', 'Aggiornamento') {
    Import-Module (Join-Path $PSScriptRoot "$m.psm1") -Global
}
if (-not $CartellaDati) { $CartellaDati = Get-CartellaDati }
$script:PercorsoStato = Join-Path $CartellaDati 'stato.json'
$script:PercorsoQuota = Join-Path $CartellaDati 'quota.json'
$script:PercorsoSoglia = Get-PercorsoSogliaQuotaPredefinito $CartellaDati
$script:PercorsoSupervisore = Join-Path $CartellaDati 'supervisore.json'
$script:SegnoMorto = Join-Path $CartellaDati 'supervisore-morto'
# Come Get-FaseSessione (Sessioni.psm1) chiede se un processo e vivo: da qui, dove i test sostituiscono Test-SessioneViva.
# La chiave del problema "dai al bot il permesso Gestisci topic": non sta in supervisore.json come gli altri, si ricostruisce dal file dei topic.
$script:ChiavePermessoTopic = 'telegram-topic-permesso'
$script:TestViva = { param($ProcessoId, $Avvio) Test-SessioneViva -ProcessoId $ProcessoId -Avvio $Avvio }
. (Join-Path $PSScriptRoot 'Istantanea.ps1')

# ---- log ---------------------------------------------------------------------------------------------------------

function Write-Log([string]$Livello, [string]$Messaggio) {
    $riga = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Livello, $Messaggio
    Write-Host $riga
    if ($WhatIf) { return }
    $dir = Join-Path $CartellaDati 'log'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::AppendAllText((Join-Path $dir ('supervisore-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))), $riga + "`n", [Text.UTF8Encoding]::new($false))
}

function Write-Prova([string]$Messaggio) { Write-Host "[WhatIf] $Messaggio" }

# Salva supervisore.json. Se non si riesce lancia: il giro si ferma (nessun altro gesto, lancio o invio), perche quello che e
# appena successo non e ricordato e al giro dopo si rifarebbe.
function Save-Sup($Sup) {
    if ($WhatIf) { return }
    try { Save-StatoSupervisore -Stato $Sup -Percorso $script:PercorsoSupervisore }
    catch { throw "supervisore.json non si salva: $($_.Exception.Message)" }
}

# ---- la raccolta (tutto l'I/O) -----------------------------------------------------------------------------------

# Una lettura che fallisce non ferma il giro: la sezione dice Letto = $false e l'errore, e il controllo ne fa un problema.
function Read-Sezione([scriptblock]$Lettura) {
    try { $r = & $Lettura; $r['Letto'] = $true; $r['Errore'] = $null; $r }
    catch { @{ Letto = $false; Errore = $_.Exception.Message } }
}

function Read-Attivita([string]$Nome) {
    Read-Sezione {
        $percorso = (Get-OperazionePianificata).Percorso
        $t = Get-ScheduledTask -TaskPath $percorso -TaskName $Nome -ErrorAction Stop
        $i = Get-ScheduledTaskInfo -TaskPath $percorso -TaskName $Nome -ErrorAction Stop
        $ultimo = if ($i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { $i.LastRunTime.ToUniversalTime() } else { $null }
        @{ Abilitata = ([string]$t.State -ne 'Disabled'); Stato = [string]$t.State; UltimoGiro = $ultimo; Esito = [int]$i.LastTaskResult }
    }
}

function Read-Card($Cfg, $Stato) {
    Read-Sezione {
        $io = Get-AdoUtenteCorrente
        $idUtente = [string]$io.Id
        $attive = @(Get-AdoCardAttive)
        # D60: le Feature aperte, perche le card in pausa risultino ferme come le vede lo smistatore
        $ctx = New-ContestoGiro $Cfg $attive $idUtente $script:PercorsoQuota $script:PercorsoSoglia @(Get-AdoFeatureAperte)
        Update-SessioniContesto $ctx $Stato
        $righe = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $attive) {
            if (-not (Test-CardMia $c $idUtente)) { continue }
            $voce = Find-VoceMappa -Mappa $Cfg.Mappa -Area $c.Area
            if (-not $voce) { continue }
            $sc = Get-StatoCard -Stato $Stato -Id $c.Id
            # una card con la sessione non ha una riga in coda: lavora un agente
            if ($null -ne $sc['sessione']) { continue }
            # la stessa lettura della vista: Get-Decisione, Get-AttivitaOperatore
            $riga = Get-RigaCoda $Cfg $c $voce $sc $Stato $script:PercorsoStato $ctx
            $riga['Url'] = Get-AdoUrlCard -Id $c.Id
            $riga['Area'] = [string]$c.Area
            # D52: il link alla Feature, per la voce dei rilasci (una funzionalita e una voce sola)
            $riga['UrlFeature'] = if ($riga['Funzionalita']) { Get-AdoUrlCard -Id ([int]$riga['Funzionalita'].Feature) } else { $null }
            $riga['Firma'] = Get-FirmaCard $riga $sc
            # il punto da cui Decisioni misura la validazione in corso da troppo: la fine dell'ultima sessione
            $ultima = Get-Campo (Get-Campo $sc 'ultimaSessione') ([string](Get-Campo $sc 'ultimoRuolo'))
            $riga['ValidazioneFine'] = ConvertTo-DataUtc (Get-Campo $ultima 'fine')
            # un on-hold nato da un bloccato del collaudatore o del responsabile: il loro resoconto (Get-ProblemiCard)
            $riga['Bloccato'] = Get-ResocontoBloccato $sc
            $righe.Add([pscustomobject]$riga)
        }
        @{ Righe = @($righe); FermaDaOre = @{} }
    }
}

function Read-Pipeline($Cfg) {
    Read-Sezione {
        $b = Get-AdoBuildPipeline
        $progetti = @($Cfg.Mappa.aree | ForEach-Object { [string]$_.progettoAdo } | Select-Object -Unique)
        $deploy = @($Cfg.Mappa.aree | ForEach-Object { Get-Campo $_ 'pipelineDeploy' } | Where-Object { $_ })
        # il motivo e l'ultimo run di quella definizione e ramo si leggono solo per i falliti che il supervisore guarda, e al piu per
        # i dieci piu recenti: poche letture ciascuno
        $motivi = @{}; $ultimi = @{}
        foreach ($f in @(Select-FallitiDaEsaminare $b.Falliti $progetti $deploy | Select-Object -First 10)) {
            try { $motivi["$($f.Id)"] = Get-AdoMotivoFallimento -Progetto $f.Progetto -BuildId $f.Id }
            catch { $motivi["$($f.Id)"] = '' }
            $k = Get-ChiaveUltimoRun $f
            if (-not $ultimi.ContainsKey($k) -and $f.Ramo -notmatch '^PR #') {
                try { $u = Get-AdoUltimoRun -Progetto $f.Progetto -DefinizioneId $f.DefinizioneId -Ramo $f.Ramo; if ($u) { $ultimi[$k] = @{ Id = $u.Id; Stato = $u.Stato; Esito = $u.Esito } } } catch { }
            }
        }
        @{ Attivi = @($b.Attivi); Orchestratori = @($b.Orchestratori); AgentiPool = @($b.AgentiPool); AgentiLetti = [bool](Get-Campo $b 'AgentiLetti'); ErroriAgenti = @(Get-Campo $b 'ErroriAgenti')
            Falliti = @($b.Falliti); Errori = @($b.Errori); Motivi = $motivi; Ultimi = $ultimi }
    }
}

function Read-Osservazione($Cfg, $CfgSup, [datetime]$Adesso) {
    $o = @{
        Adesso = $Adesso; AvvioPc = $null; UrlOrganizzazione = (Get-AdoUrlOrganizzazione); UrlVista = [string]$CfgSup.urlVista
        UrlBaseCard = ((Get-AdoUrlCard -Id 1 -Progetto ([string]$Cfg.Mappa.progettoBoard)) -replace '/1$', '/')
        TagAttesa = [string]$Cfg.Stati.tagAttesa; Limiti = $Cfg.Limiti
        ProgettiMappa = @($Cfg.Mappa.aree | ForEach-Object { [string]$_.progettoAdo } | Select-Object -Unique)
        DefinizioniDeploy = @($Cfg.Mappa.aree | ForEach-Object { Get-Campo $_ 'pipelineDeploy' } | Where-Object { $_ })
        SenzaPat = $false; SessioniAttive = 0; VistaMancate = 0
    }
    try { $o.AvvioPc = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime() } catch { }
    $nomi = Get-NomiOperazioniPianificate
    $o.Smistatore = Read-Attivita $nomi.Smistatore
    $o.VistaAttivita = Read-Attivita $nomi.Vista
    $o.VistaRisponde = $false; $o.VistaErrore = $null
    try { $r = Invoke-WebRequest -Uri $CfgSup.urlVista -TimeoutSec ([int]$CfgSup.timeoutVistaSecondi) -UseBasicParsing; $o.VistaRisponde = ([int]$r.StatusCode -eq 200); if (-not $o.VistaRisponde) { $o.VistaErrore = "HTTP $($r.StatusCode)" } }
    catch { $o.VistaErrore = $_.Exception.Message }
    $o.Log = Read-Sezione {
        $f = Get-FileLog $CartellaDati (Get-Date)
        @{ Righe = $(if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f -Encoding UTF8) } else { @() }) }
    }
    if (-not $o.Log.Letto) { $o.Log.Righe = @() }
    $o.Quota = Read-Sezione { @{ Dati = (Get-Quota -Percorso $script:PercorsoQuota); Override = (Get-SogliaQuota -Percorso $script:PercorsoSoglia) } }
    $o.Pat = Read-Sezione {
        $sc = $null
        if (Test-Path -LiteralPath $PercorsoPatInfo) {
            $info = Get-Content -LiteralPath $PercorsoPatInfo -Raw | ConvertFrom-Json
            $sc = ConvertTo-DataUtc ([string](Get-Campo (Get-Campo $info 'smistatore') 'validTo'))
        }
        @{ Scadenza = $sc }
    }
    $vuotaCard = { @{ Letto = $false; Errore = $null; Righe = @(); FermaDaOre = @{} } }
    $vuotaPipe = { @{ Letto = $false; Errore = $null; Attivi = @(); Orchestratori = @(); AgentiPool = @(); AgentiLetti = $false; ErroriAgenti = @(); Falliti = @(); Errori = @(); Motivi = @{}; Ultimi = @{} } }
    # Il supervisore usa solo il PAT dello smistatore, mai pat.txt (di una persona): senza, nessuna chiamata ad Azure DevOps.
    if (-not (Test-Path -LiteralPath (Join-Path $ClaudeDir 'pat-smistatore.txt'))) {
        $o.SenzaPat = $true
        $o.Card = & $vuotaCard; $o.Card.Errore = 'manca pat-smistatore.txt'
        $o.Pipeline = & $vuotaPipe; $o.Pipeline.Errore = 'manca pat-smistatore.txt'
        return $o
    }
    $stato = $null
    try { $stato = Get-Stato -Percorso $script:PercorsoStato } catch { $o.Card = & $vuotaCard; $o.Card.Errore = $_.Exception.Message }
    if ($null -ne $stato) {
        # le sessioni vive dello smistatore (card e mentori): la diagnosi non le supera
        $o.SessioniAttive = @(Get-IdCardConSessione $stato).Count
        $o.Card = Read-Card $Cfg $stato
    }
    if (-not $o.Card.Letto) { $o.Card.Righe = @(); $o.Card.FermaDaOre = @{} }
    $o.Pipeline = Read-Pipeline $Cfg
    if (-not $o.Pipeline.Letto) { foreach ($k in 'Attivi', 'Orchestratori', 'AgentiPool', 'Falliti', 'Errori', 'ErroriAgenti') { $o.Pipeline[$k] = @() }; $o.Pipeline.AgentiLetti = $false; $o.Pipeline.Motivi = @{}; $o.Pipeline.Ultimi = @{} }
    $o
}

# ---- i gesti -----------------------------------------------------------------------------------------------------

# Esegue un gesto e lo ricorda subito in supervisore.json; restituisce $null se e andato, altrimenti il testo dell'errore. Con
# -WhatIf lo dice soltanto. Un errore di salvataggio lancia: il giro si ferma.
function Invoke-Gesto($Gesto, $Sup, [datetime]$Adesso) {
    $nomi = Get-NomiOperazioniPianificate
    switch ($Gesto.Tipo) {
        'RiavviaVista' {
            if ($WhatIf) { Write-Prova "gesto: $(if ($Gesto.Ferma) { 'fermo e ' })avvio l'attivita pianificata della Vista (non risponde), chiudo prima le pwsh della vista di questa radice ($(@(Get-ProcessiVistaRadice $Radice).Count) ora)"; return $null }
            $percorso = (Get-OperazionePianificata).Percorso
            try {
                if ($Gesto.Ferma) { Stop-ScheduledTask -TaskPath $percorso -TaskName $nomi.Vista -ErrorAction Stop }
                # Stop-ScheduledTask chiude solo conhost: le pwsh della vista vecchia restano vive e tengono la porta.
                $vecchie = @(Get-ProcessiVistaRadice $Radice)
                foreach ($p in $vecchie) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
                Write-Log 'INFO' "vista: chiusi $($vecchie.Count) processi della vista vecchia"
                Start-ScheduledTask -TaskPath $percorso -TaskName $nomi.Vista -ErrorAction Stop
                $errore = $null
                Write-Log 'INFO' "la vista non risponde: ho $(if ($Gesto.Ferma) { 'fermato e ' })avviato la sua attivita pianificata"
            }
            catch { Write-Log 'ERRORE' "riavvio della vista non riuscito: $($_.Exception.Message)"; $errore = $_.Exception.Message }
            # anche un tentativo fallito conta: non si riprova a ogni giro
            $Sup.gesti.riavviiVista = @(@($Sup.gesti.riavviiVista) + $Adesso.ToString('o') | Select-Object -Last 10)
            Save-Sup $Sup
            $errore
        }
        'RilanciaRun' {
            $r = $Gesto.Run
            if ($WhatIf) { Write-Prova "gesto: rilancio il run $($r.Id) ($($r.Pipeline), ramo $($r.Ramo)): fallito per infrastruttura"; return $null }
            # Si ricorda PRIMA di rilanciare: se il salvataggio non riesce non si rilancia, e se dopo il rilancio qualcosa va storto il run
            # non si rilancia una seconda volta (una volta per run).
            $Sup.gesti.rilanciati["$($r.Id)"] = @{ quando = $Adesso.ToString('o'); nuovo = $null }
            Save-Sup $Sup
            try {
                $nuovo = Start-AdoRilancioRun -Progetto $r.Progetto -DefinizioneId $r.DefinizioneId -Ramo $r.Ramo -SourceVersion $r.SourceVersion -ParametriTemplate $r.ParametriTemplate
                $Sup.gesti.rilanciati["$($r.Id)"] = @{ quando = $Adesso.ToString('o'); nuovo = $nuovo }
                Write-Log 'INFO' "run $($r.Id) ($($r.Pipeline), ramo $($r.Ramo)) fallito per infrastruttura: rilanciato come $nuovo"
                Save-Sup $Sup
                $null
            }
            catch {
                if ($_.Exception.Message -like 'supervisore.json non si salva*') { throw }
                Write-Log 'ERRORE' "rilancio del run $($r.Id) non riuscito: $($_.Exception.Message)"; $_.Exception.Message
            }
        }
    }
}

# ---- la diagnosi con il modello ----------------------------------------------------------------------------------

# Le righe del log che riguardano il problema: per l'errore di una card (chiave errore-card-N) le righe di quella card, altrimenti
# le ultime di errore e di avviso. Vanno alla sessione in un allegato (la riga di comando ha un limite).
function Get-RigheLogDelProblema([string]$Chiave, $Righe) {
    $tutte = @($Righe | Where-Object { $_ })
    if ($Chiave -match '^errore-card-(\d+)$') {
        $n = $Matches[1]
        return @($tutte | Where-Object { $_ -match "^\S+ \S+ \S+ card ${n}:" } | Select-Object -Last 15)
    }
    @($tutte | Where-Object { $_ -match '^\S+ \S+ (ERRORE|WARN|AVVISO) ' } | Select-Object -Last 15)
}

function Get-HashFile([string]$Percorso) {
    if (-not (Test-Path -LiteralPath $Percorso)) { return '' }
    try { (Get-FileHash -LiteralPath $Percorso -Algorithm SHA256).Hash } catch { '?' }
}

# Cio che una sessione di diagnosi (di sola lettura) non deve cambiare: stato.json e quota.json, HEAD e git status della copia
# principale degli attrezzi. $null se git non si legge: allora si controlla solo il resto.
function Get-ImprontaDiagnosi {
    $i = @{ stato = (Get-HashFile $script:PercorsoStato); quota = (Get-HashFile $script:PercorsoQuota); testa = ''; gitStato = '' }
    try { $w = Get-ImprontaWorktree -Cartella $Radice; $i.testa = [string]$w['testa']; $i.gitStato = [string]$w['stato'] }
    catch { Write-Log 'WARN' "diagnosi: la copia principale non si legge con git, controllo solo i file dati: $($_.Exception.Message)" }
    $i
}

# Scrive quota.json dentro il mutex del giro dello smistatore (che lo riscrive a fine sessione), con una breve attesa. Se non lo
# ottiene salta: non e grave, la quota si rilegge alla prossima sessione.
function Save-QuotaDiagnosi($Esito, [datetime]$Adesso, $Cfg) {
    $nome = Get-NomeGiro -CartellaDati $CartellaDati
    $preso = $false
    for ($t = 0; $t -lt 10 -and -not $preso; $t++) { $preso = Enter-Giro -Nome $nome; if (-not $preso) { Start-Sleep -Milliseconds 300 } }
    if (-not $preso) { Write-Log 'WARN' 'diagnosi: lo smistatore ha il giro in corso, la quota di questa sessione non si scrive'; return }
    try { Update-QuotaDaEsito -Esito $Esito -Adesso $Adesso -Limite $Esito.Limite -Margine ([double](Get-Campo $Cfg.Limiti 'margineQuotaMinuti')) -Percorso $script:PercorsoQuota }
    catch { Write-Log 'ERRORE' "diagnosi: quota.json non scritto: $($_.Exception.Message)" }
    finally { Exit-Giro -Nome $nome }
}

# D51: per i problemi con DaDiagnosi che non hanno ancora una diagnosi lancia una sessione del ruolo supervisore (Sonnet, sola
# lettura), una per problema, al piu una alla volta e diagnosiAlGiorno al giorno, mai con la quota che blocca o con le sessioni dello
# smistatore al limite. Le sessioni lanciate stanno in supervisore.json: a ogni esecuzione se ne legge l'esito. Con ESITO=diagnosi
# il testo va nel campo diagnosi del problema; senza esito, fallita o in silenzio oltre silenzioMinuti (e allora si ferma) la
# diagnosi e "diagnosi non riuscita" e non si riprova. Un problema chiuso nel frattempo: la sessione finisce lo stesso e il risultato
# si scarta. Con -WhatIf dice soltanto cosa lancerebbe. La sessione non e di una card: Card 0, una cartella sua e vuota. Prima e dopo
# si prende l'impronta di stato.json, quota.json e della copia principale (Compare-ImprontaDiagnosi): se la sessione ha scritto
# qualcosa e un problema urgente e la diagnosi si scarta (D39).
function Invoke-DiagnosiProblemi($Sup, $Cfg, $CfgSup, $Oss, [datetime]$Adesso) {
    if (-not $WhatIf) {
        foreach ($sess in @(@($Sup.sessioniDiagnosi) | Where-Object { $null -ne $_ })) {
            try {
                $esito = Get-EsitoSessione -Id ([string]$sess['id']) -CartellaDati $CartellaDati
                $fase = Get-FaseSessione $Cfg $sess $esito $script:TestViva $Adesso
            }
            catch { Write-Log 'ERRORE' "diagnosi $($sess['id']): esito non leggibile, riprovo al prossimo giro: $($_.Exception.Message)"; continue }
            $r = ConvertTo-EsitoDiagnosi -Fase $fase -Esito $esito
            if ($r.Stato -eq 'inCorso') { continue }
            if ($fase.Fase -eq 'senzaRisultato' -and $fase.Viva) {
                try { Stop-Sessione -ProcessoId ([int]$sess['pid']) -Avvio $sess['avvio'] } catch { Write-Log 'ERRORE' "diagnosi $($sess['id']): sessione non fermata: $($_.Exception.Message)" }
            }
            # sola lettura: prima della quota, che la scriviamo noi
            $giroInMezzo = $true
            if ($Oss.Smistatore.Letto -and -not [bool](Get-Campo $sess 'giroInCorso') -and [string]$Oss.Smistatore.Stato -ne 'Running') {
                $primo = ConvertTo-DataUtc (Get-Campo $sess 'giroAlLancio'); $ora = $Oss.Smistatore.UltimoGiro
                $giroInMezzo = -not (($null -eq $primo -and $null -eq $ora) -or ($primo -and $ora -and [math]::Abs(($ora - $primo).TotalSeconds) -le 1))
            }
            $cambiato = @(Compare-ImprontaDiagnosi -Prima (Get-Campo $sess 'impronta') -Dopo (Get-ImprontaDiagnosi) -GiroInMezzo $giroInMezzo)
            if ($cambiato.Count -gt 0) {
                $cosa = $cambiato -join ', '
                Add-EventoSupervisore -Supervisore $Sup -Problema (New-Problema "diagnosi-ha-scritto-$($sess['id'])" "La diagnosi ha scritto: $cosa. Una sessione di sola lettura non deve cambiare niente." 'guarda che cosa e cambiato (git status e git log nella copia principale degli attrezzi) e annulla a mano se serve' '' -Urgente $true) -Adesso $Adesso
                $r = [pscustomobject]@{ Stato = 'scartata'; Testo = 'diagnosi scartata' }
                Write-Log 'ERRORE' "diagnosi $($sess['id']) ($($sess['chiave'])): ha scritto: $cosa; scartata"
            }
            # la quota e una sola: la sessione di diagnosi ne consuma come le altre, e se trova il limite la pausa vale per tutti
            if ($esito.Finita -or $null -ne $esito.Quota) { Save-QuotaDiagnosi $esito $Adesso $Cfg }
            # il registro dei consumi, come per le altre sessioni (card 0: non e di una card)
            try {
                $s = @{ ruolo = 'supervisore'; modello = $sess['modello']; sforzo = $sess['sforzo']; id = $sess['id']; ripresa = $false; inizio = $sess['inizio'] }
                $dati = if ($esito.Finita) { $esito } else { [pscustomobject]@{ Turni = 0; TokenIn = 0; TokenOut = 0; CacheLetti = 0; CacheScritti = 0 } }
                $et = if ($r.Stato -eq 'finita') { 'diagnosi' } elseif ($esito.Finita -and $esito.Limite) { 'limite' } elseif ($esito.Finita -and $esito.Errore) { 'errore' } else { [string]$r.Stato }
                Write-RegistroSessione -CartellaDati $CartellaDati -Riga (New-RigaRegistro 0 $null $s $dati $Adesso.ToString('o') $et)
            }
            catch { Write-Log 'WARN' "diagnosi $($sess['id']): riga del registro non scritta: $($_.Exception.Message)" }
            $applicata = Complete-Diagnosi -Supervisore $Sup -Sessione $sess -Testo $r.Testo
            if ($sess['cartella'] -and (Test-Path -LiteralPath $sess['cartella'])) { try { Remove-Item -LiteralPath $sess['cartella'] -Recurse -Force } catch { } }
            Write-Log $(if ($r.Stato -eq 'finita') { 'INFO' } else { 'WARN' }) "diagnosi $($sess['id']) ($($sess['chiave'])): $($r.Stato)$(if (-not $applicata) { ', il problema e chiuso: scartata' })"
            # appena pronta, nel suo topic (anche "diagnosi non riuscita": la voce del riepilogo rimanda li)
            if ($applicata) { Send-Diagnosi ([string]$Sup.problemi[[string]$sess['chiave']]['testo']) ([string]$r.Testo) $Adesso }
            Save-Sup $Sup
        }
    }
    $bloccata = $true   # se la quota non si legge non si lancia niente
    try { $quota = Get-Quota -Percorso $script:PercorsoQuota; $bloccata = $null -ne (Get-BloccoQuota @{ Quota = $quota; Adesso = $Adesso.ToString('o'); Limiti = $Cfg.Limiti; OverrideQuota = (Get-SogliaQuota -Percorso $script:PercorsoSoglia) }) }
    catch { Write-Log 'WARN' "diagnosi: quota.json non si legge, non lancio niente: $($_.Exception.Message)" }
    $chiave = Get-DiagnosiDaLanciare -Supervisore $Sup -Adesso $Adesso -Config $CfgSup -QuotaBloccata $bloccata -SessioniAttive ([int]$Oss.SessioniAttive) -LimiteSessioni ([int](Get-Campo $Cfg.Limiti 'sessioniAttive'))
    if (-not $chiave) { return }
    if ($WhatIf) { Write-Prova "diagnosi: lancerei una sessione del ruolo supervisore per [$chiave]"; return }
    # conta nel tetto del giorno prima di partire: se poi il giro va in errore il conteggio resta
    Add-ConteggioDiagnosi -Supervisore $Sup -Adesso $Adesso
    Save-Sup $Sup
    $e = $Sup.problemi[$chiave]
    $impronta = Get-ImprontaDiagnosi
    $giroInCorso = $Oss.Smistatore.Letto -and [string]$Oss.Smistatore.Stato -eq 'Running'
    $cartella = Join-Path (Join-Path $CartellaDati 'diagnosi') ([guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $cartella -Force | Out-Null
        $righe = @("Problema: $($e['testo'])", "Chiave: $chiave", "Link: $($e['link'])",
            "Cartella dati (log in log/smistatore-<data>.log, stato.json, quota.json): $CartellaDati",
            "Copia principale degli attrezzi (da leggere solo con git -C): $Radice")
        $log = @(Get-RigheLogDelProblema $chiave $Oss.Log.Righe) -join "`n"
        $r = Start-SessioneRuolo -Card 0 -Ruolo 'supervisore' -Messaggio ($righe -join "`n") -Cartella $cartella -Config $Cfg -Radice $Radice -CartellaDati $CartellaDati -Allegato "Righe di log del problema:`n$log"
    }
    catch {
        try { Remove-Item -LiteralPath $cartella -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        Write-Log 'ERRORE' "diagnosi di [$chiave] non partita: $($_.Exception.Message)"; return
    }
    $rc = $Cfg.Ruoli.supervisore
    Add-SessioneDiagnosi -Supervisore $Sup -Chiave $chiave -Sessione ([pscustomobject]@{ Id = $r.Id; Pid = $r.Pid; Avvio = $r.Avvio; Cartella = $cartella }) -Adesso $Adesso -Impronta $impronta -GiroAlLancio $(if ($giroInCorso) { $null } else { Get-Campo $Oss.Smistatore 'UltimoGiro' })
    $Sup.sessioniDiagnosi[-1]['modello'] = $rc.modello; $Sup.sessioniDiagnosi[-1]['sforzo'] = $rc.sforzo; $Sup.sessioniDiagnosi[-1]['giroInCorso'] = [bool]$giroInCorso
    Write-Log 'INFO' "diagnosi: lanciata la sessione $($r.Id) per [$chiave]"
    Save-Sup $Sup
}

# ---- gli avvisi --------------------------------------------------------------------------------------------------

# Come Telegram dice al log che un topic non si crea o non esiste piu.
$script:LogTelegram = { param($Messaggio) Write-Log 'WARN' $Messaggio }

# Manda un messaggio nel topic indicato. $true se e partito (o se Telegram non e configurato: resta nel log), $false se l'invio e fallito.
function Send-Messaggio([string]$Topic, [string]$Testo, [string]$Descrizione, [bool]$Configurato) {
    if ($WhatIf) { Write-Prova "Telegram [topic $Topic] $Descrizione`:`n$Testo"; return $true }
    Write-Log 'AVVISO' $Descrizione
    if (-not $Configurato) { return $true }
    try { [void](Send-TelegramMessaggio -Testo $Testo -Topic $Topic -CartellaDati $CartellaDati -Log $script:LogTelegram); $true }
    catch { Write-Log 'ERRORE' "Telegram, $Descrizione`: $($_.Exception.Message)"; $false }
}

# Il link di una voce che non ne ha: la pagina dell'organizzazione.
function Send-Urgente($Voce, [string]$LinkPredefinito, [bool]$Configurato, [datetime]$Adesso) {
    $testo = Format-UrgenteTelegram -Voce $Voce -Adesso $Adesso -LinkPredefinito $LinkPredefinito
    $link = if ($Voce.Link) { $Voce.Link } else { $LinkPredefinito }
    Send-Messaggio 'urgenti' $testo "urgente $($Voce.Chiave): $($Voce.Testo) Cosa fare: $($Voce.Azione) $link" $Configurato
}

function Send-Riepilogo($Voci, [bool]$Configurato, [datetime]$Adesso) {
    $testo = Format-RiepilogoTelegram -Voci $Voci -Adesso $Adesso
    Send-Messaggio 'riepilogo' $testo "riepilogo di $(@($Voci).Count) voci" $Configurato
}

# I rilasci in attesa: un messaggio a se nel topic Rilasci. Per ogni area il link alla pipeline orchestrator del suo progetto ADO, trovata
# come la trova la vista (D44: Get-AdoBuildPipeline, Orchestratori), cioe la pipeline con "orchestrator" nel nome.
function Send-Rilasci($Gruppi, $Cfg, $Oss, [bool]$Configurato, [datetime]$Adesso) {
    foreach ($g in @($Gruppi)) {
        $voce = Find-VoceMappa -Mappa $Cfg.Mappa -Area ([string]$g.Area)
        $progetto = if ($voce) { [string]$voce.progettoAdo } else { '' }
        $orch = @(@($Oss.Pipeline.Orchestratori) | Where-Object { $_ -and [string]$_.Progetto -eq $progetto -and [string]$_.Pipeline -match 'orchestrator' -and [int]$_.DefinizioneId -gt 0 }) | Select-Object -First 1
        $link = if ($orch) { "$($Oss.UrlOrganizzazione.TrimEnd('/'))/$([uri]::EscapeDataString($progetto))/_build?definitionId=$([int]$orch.DefinizioneId)" } else { '' }
        Add-Member -InputObject $g -NotePropertyName Progetto -NotePropertyValue $progetto -Force
        Add-Member -InputObject $g -NotePropertyName LinkRilascio -NotePropertyValue $link -Force
    }
    $testo = Format-RilasciTelegram -Gruppi $Gruppi -Adesso $Adesso
    Send-Messaggio 'rilasci' $testo "rilasci in attesa: $(@($Gruppi | ForEach-Object { @($_.Card).Count } | Measure-Object -Sum).Sum) card in $(@($Gruppi).Count) aree" $Configurato
}

# La diagnosi appena pronta: un messaggio per diagnosi nel topic Diagnosi. Se non parte resta in supervisore.json e nel log.
function Send-Diagnosi([string]$Problema, [string]$Diagnosi, [datetime]$Adesso) {
    if ($WhatIf -or -not (Test-TelegramConfigurato -CartellaDati $CartellaDati)) { return }
    try { [void](Send-TelegramMessaggio -Testo (Format-DiagnosiTelegram -Problema $Problema -Diagnosi $Diagnosi -Adesso $Adesso) -Topic 'diagnosi' -CartellaDati $CartellaDati -Log $script:LogTelegram) }
    catch { Write-Log 'ERRORE' "Telegram, diagnosi: $($_.Exception.Message)" }
}
# ---- l'aggiornamento della suite (D53) ---------------------------------------------------------------------------

# I messaggi dell'aggiornamento, nel topic Aggiornamenti: la forma del testo e di Telegram.psm1, qui solo l'invio. Il lancio lo ricorda il
# modulo (aggiornamento.json): se l'invio fallisce lo dice il log e non ferma il giro.
function Send-Aggiornamento([string]$Tipo, $Dati, [datetime]$Adesso) {
    $parametri = @{ Tipo = $Tipo; Adesso = $Adesso }
    $topic = 'aggiornamenti'
    switch ($Tipo) {
        'aggiornato' { $parametri.Da = [string]$Dati.Da; $parametri.A = [string]$Dati.A; $parametri.Pr = @($Dati.Pr); $d = "suite aggiornata: $($Dati.Da) -> $($Dati.A), $(@($Dati.Pr).Count) PR" }
        'fallito' { $parametri.A = [string]$Dati.A; $parametri.Errore = [string]$Dati.Errore; $d = "aggiornamento della suite fallito, tornato indietro: $($Dati.Errore)" }
        'attesa' { $parametri.A = [string]$Dati.A; $parametri.Ore = [int]$Dati.Ore; $d = "aggiornamento della suite in attesa da oltre $($Dati.Ore) ore" }
        # la copia non e tornata com'era: e urgente, nel topic degli urgenti (le altre voci stanno nel topic Aggiornamenti)
        'copiaRotta' { $parametri.Tipo = 'copiaRotta'; $parametri.A = [string]$Dati.Hash; $parametri.Errore = [string]$Dati.Errore; $d = "aggiornamento della suite: copia lasciata a meta: $($Dati.Errore)"; $topic = 'urgenti' }
    }
    $ok = Send-Messaggio $topic (Format-AggiornamentoTelegram @parametri) $d (Test-TelegramConfigurato -CartellaDati $CartellaDati)
    if (-not $ok) { throw 'invio su Telegram non riuscito' }
}

# Un giro dell'aggiornamento (le regole sono in Aggiornamento.psm1). Mai fatale per il giro del supervisore: una copia senza git (non si
# aggiorna) non fa niente, un errore si scrive nel log.
function Invoke-AggiornamentoSupervisore($CfgSup, [datetime]$Adesso) {
    if (-not (Test-Path -LiteralPath (Join-Path $Radice '.git'))) { return }
    try {
        # uno scriptblock semplice (non una chiusura): una chiusura non vede le funzioni di questo script
        $script:AdessoAggiornamento = $Adesso
        $invia = { param($Tipo, $Dati) Send-Aggiornamento $Tipo $Dati $script:AdessoAggiornamento }
        [void](Invoke-AggiornamentoSuite -Radice $Radice -CartellaDati $CartellaDati -ConfigSupervisore $CfgSup -Adesso $Adesso -WhatIf:$WhatIf `
            -Log { param($Livello, $Messaggio) Write-Log $Livello $Messaggio } -Prova { param($Messaggio) Write-Prova $Messaggio } -Invia $invia)
    }
    catch { Write-Log 'ERRORE' "aggiornamento della suite non riuscito: $($_.Exception.Message)" }
}

# ---- il giro -----------------------------------------------------------------------------------------------------

function Invoke-Supervisore {
    $cfg = Get-Config -Radice $Radice -CartellaDati $CartellaDati
    $cs = Get-ConfigSupervisore -Radice $Radice -CartellaDati $CartellaDati
    $adesso = (Get-Date).ToUniversalTime()
    $sup = Get-StatoSupervisore -Percorso $script:PercorsoSupervisore
    $oss = Read-Osservazione $cfg $cs $adesso
    # le esecuzioni di prima di questa: dicono se il supervisore girava (un PC sospeso non e uno smistatore fermo)
    $oss.EsecuzioniPrecedenti = @($sup.esecuzioni)
    # la vista e giu dopo due mancate risposte di fila
    $sup.vistaMancate = if ($oss.VistaRisponde) { 0 } else { 1 + [int]$sup.vistaMancate }
    $oss.VistaMancate = [int]$sup.vistaMancate
    Remove-RilanciatiVecchi -Supervisore $sup -Adesso $adesso

    $nonLette = @(Get-SezioniNonLette $oss)
    # le firme si aggiornano solo se le card si sono lette: un giro senza lettura non e un giro in cui nessuna card si e mossa
    if ($oss.Card.Letto) {
        $f = Update-FirmeCard $sup.firme $oss.Card.Righe $adesso
        $sup.firme = $f.Firme
        $oss.Card.FermaDaOre = $f.FermaDaOre
    }

    # i rilasci in attesa: da quando, se la storia della card non lo dice, dal primo visto del supervisore
    if ($oss.Card.Letto) { Set-RilasciDa -Supervisore $sup -Righe $oss.Card.Righe -Adesso $adesso }
    $problemi = @(Get-ProblemiSupervisore $oss $sup $cs) + @(Get-ProblemiEventi -Supervisore $sup -Adesso $adesso)
    # i topic non si creano (al bot manca il permesso, o la chat non e un forum): una voce nel riepilogo, una volta sola
    $topic = Get-TelegramProblemaTopic -CartellaDati $CartellaDati
    if ($topic -and -not $topic.Avvisato) {
        $problemi += New-Problema $script:ChiavePermessoTopic 'Telegram: il bot non riesce a creare i topic del gruppo, e tutti i messaggi vanno nel topic generale.' 'dai al bot il permesso "Gestisci topic" nel gruppo (impostazioni del gruppo, amministratori)' '' -Elementi @('permesso') -Ricorda $false
    }
    # i rilasci hanno un messaggio a parte nel topic Rilasci: i gruppi per area si prendono dalla voce di questo giro
    $gruppiRilasci = @(@($problemi | Where-Object { $_.Chiave -eq 'rilasci' } | Select-Object -First 1) | ForEach-Object { Get-Campo $_ 'Gruppi' })

    # i gesti, e solo quelli, ricordati subito: un gesto che non riesce e un problema in piu
    foreach ($g in @(Get-GestiSupervisore $oss $sup $cs)) {
        $errore = Invoke-Gesto $g $sup $adesso
        if ($errore) { $problemi += New-Problema "gesto-$($g.Tipo)" "Il gesto automatico '$($g.Tipo)' non e riuscito: $errore" 'controlla l''attivita pianificata o il run a mano' }
    }

    $prima = $sup.problemi
    $sup.problemi = Update-ProblemiAperti $prima $problemi $adesso -SezioniNonLette $nonLette
    Sync-DiagnosiConservate -Supervisore $sup -Prima $prima -Adesso $adesso
    if ($WhatIf) {
        foreach ($k in @($sup.problemi.Keys | Sort-Object)) {
            $e = $sup.problemi[$k]
            if ([int]$e.assenze -gt 0) { continue }
            Write-Prova "problema $(if ($e.urgente) { 'URGENTE' } else { 'riepilogo' })$(if ($e.daDiagnosi) { ' (da diagnosi)' }) [$k]: $($e.testo) -> $($e.azione) $($e.link)"
        }
        if (@($sup.problemi.Values | Where-Object { [int]$_.assenze -eq 0 }).Count -eq 0) { Write-Prova 'nessun problema aperto' }
    }
    Save-Sup $sup

    # prima degli avvisi: una diagnosi appena arrivata finisce nel riepilogo
    Invoke-DiagnosiProblemi $sup $cfg $cs $oss $adesso

    $piano = Get-PianoAvvisi -Supervisore $sup -Adesso $adesso -Config $cs -AvvioPc $oss.AvvioPc
    $configurato = Test-TelegramConfigurato -CartellaDati $CartellaDati
    if (-not $configurato) { Write-Log 'WARN' 'Telegram non configurato: gli avvisi vanno solo nel log' }
    # ogni invio si ricorda subito: un salvataggio che non riesce non deve far rispedire gli urgenti a ogni giro
    foreach ($u in @($piano.Urgenti)) {
        if (Send-Urgente $u $oss.UrlOrganizzazione $configurato $adesso) {
            Register-AvvisiMandati -Supervisore $sup -Chiavi @($u.Chiave) -Adesso $adesso
            Save-Sup $sup
        }
    }
    if ($piano.MandaRiepilogo) {
        # i rilasci escono dal riepilogo e vanno nel loro topic, con lo stesso ritmo (stesse regole di ricordo, stessa fascia)
        $rilasci = @($piano.Riepilogo | Where-Object { $_.Chiave -eq 'rilasci' })
        $altre = @($piano.Riepilogo | Where-Object { $_.Chiave -ne 'rilasci' })
        $tuttoPartito = $true
        if ($altre.Count -gt 0) {
            if (Send-Riepilogo $altre $configurato $adesso) {
                Register-AvvisiMandati -Supervisore $sup -Chiavi @($altre | ForEach-Object { $_.Chiave }) -Adesso $adesso
                if ($configurato -and -not $WhatIf -and $script:ChiavePermessoTopic -in @($altre | ForEach-Object { $_.Chiave })) {
                    try { Set-TelegramPermessoAvvisato -CartellaDati $CartellaDati } catch { Write-Log 'ERRORE' "telegram-topic.json non si salva: $($_.Exception.Message)" }
                }
                Save-Sup $sup
            }
            else { $tuttoPartito = $false }
        }
        if ($rilasci.Count -gt 0) {
            if ($gruppiRilasci.Count -eq 0) { Write-Log 'WARN' 'rilasci in attesa: le card non si sono lette in questo giro, il messaggio aspetta' ; $tuttoPartito = $false }
            elseif (Send-Rilasci $gruppiRilasci $cfg $oss $configurato $adesso) {
                Register-AvvisiMandati -Supervisore $sup -Chiavi @('rilasci') -Adesso $adesso
                Save-Sup $sup
            }
            else { $tuttoPartito = $false }
        }
        # la fascia si consuma solo se tutto e partito: quello che non e partito si rimanda, il resto e gia ricordato come detto
        if ($tuttoPartito) {
            Register-AvvisiMandati -Supervisore $sup -Chiavi @() -Fasce @($piano.Fasce) -Adesso $adesso
            Save-Sup $sup
        }
    }
    else {
        # niente da dire: la fascia si consuma lo stesso, senza messaggio
        if ($WhatIf) { Write-Prova "riepilogo non dovuto ora o vuoto ($($piano.InSospeso) voci da dire alla prossima fascia)" }
        Register-AvvisiMandati -Supervisore $sup -Chiavi @() -Fasce @($piano.Fasce) -Adesso $adesso
    }
    $sup.ultimaEsecuzione = $adesso.ToString('o')
    Add-EsecuzioneSupervisore -Supervisore $sup -Adesso $adesso
    Save-Sup $sup

    # D53: in fondo, dopo tutti i controlli e gli avvisi di questo giro: una suite che si aggiorna cambia il codice sotto i piedi
    Invoke-AggiornamentoSupervisore $cs $adesso
}

# Il supervisore stesso si e fermato: lo dice, una volta, finche il giro non torna a funzionare (il segno su file). Prima prova
# l'invio, poi scrive il segno: se Telegram non c'e o fallisce, resta solo il log e si riprova al giro dopo.
function Send-SupervisoreMorto([string]$Errore) {
    try {
        if (Test-Path -LiteralPath $script:SegnoMorto) { return }
        $voce = [pscustomobject]@{ Testo = "Il supervisore si è fermato: il giro è finito in errore. $Errore"; Azione = 'guarda il log del supervisore (cartella dati, log/supervisore-AAAA-MM-GG.log) e lancia src/Supervisore.ps1 -WhatIf'; Link = ''; Ricordo = $false; Attesa = '' }
        $url = Get-AdoUrlOrganizzazione
        $testo = Format-UrgenteTelegram -Voce $voce -Adesso ([datetime]::UtcNow) -LinkPredefinito $url
        if ($WhatIf) { Write-Prova "Telegram [topic urgenti] il supervisore si e fermato:`n$testo"; return }
        if (-not (Test-TelegramConfigurato -CartellaDati $CartellaDati)) { return }
        [void](Send-TelegramMessaggio -Testo $testo -Topic 'urgenti' -CartellaDati $CartellaDati -Log $script:LogTelegram)
        [IO.File]::WriteAllText($script:SegnoMorto, [datetime]::UtcNow.ToString('o'), [Text.UTF8Encoding]::new($false))
    }
    catch { Write-Log 'ERRORE' "avviso del supervisore fermo non mandato: $($_.Exception.Message)" }
}

try {
    Invoke-Supervisore
    # il giro e tornato a funzionare: un prossimo guasto si dira di nuovo
    if (-not $WhatIf) { Remove-Item -LiteralPath $script:SegnoMorto -Force -ErrorAction SilentlyContinue }
}
catch {
    Write-Log 'ERRORE' "giro del supervisore interrotto: $($_.Exception.Message)"
    Send-SupervisoreMorto (Get-RigaBreve ([string]$_.Exception.Message) 250)
    # D53: come lo smistatore, un giro a vuoto (-WhatIf) che si interrompe esce con un codice che la verifica dell'aggiornamento vede
    if ($WhatIf) { exit 1 }
}
