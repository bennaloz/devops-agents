#requires -Version 7
# Un giro dello smistatore: legge le card con il tag degli agenti, costruisce per ognuna un'istantanea, chiede ad
# Get-Azioni cosa fare ed esegue le azioni. Nessun modello: se non c'e niente da fare non spende niente.
#   pwsh -NoProfile -File src/Smistatore.ps1 [-Card <id>] [-WhatIf]
# Con -WhatIf stampa le azioni e non scrive da nessuna parte (Azure DevOps, stato, registro, log, processi).
# Il codice di uscita e 0 anche se una card fallisce: l'errore va nel log e sulla card.
[CmdletBinding()]
param(
    [int]$Card = 0,
    [switch]$WhatIf,
    [string]$CartellaDati,
    [string]$Radice,
    # Il file non segreto che l'installatore scrive con la scadenza dei PAT; serve ai test.
    [string]$PercorsoPatInfo = (Join-Path $HOME '.claude/pat-info.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Radice) { $Radice = Split-Path -Parent $PSScriptRoot }
foreach ($m in 'Comune', 'Config', 'Ado', 'Stato', 'Decisioni', 'Collaudo', 'Sessioni', 'Worktree', 'Card') {
    Import-Module (Join-Path $PSScriptRoot "$m.psm1") -Global
}
# La stessa cartella dati di card.ps1: le sessioni lanciate la ricevono in ATTREZZI_DATI (la imposta Start-SessioneRuolo).
if (-not $CartellaDati) { $CartellaDati = Get-CartellaDati }
$script:PercorsoStato = Join-Path $CartellaDati 'stato.json'
$script:PercorsoQuota = Join-Path $CartellaDati 'quota.json'
$script:PercorsoSoglia = Get-PercorsoSogliaQuotaPredefinito $CartellaDati
# Come Get-FaseSessione (Sessioni.psm1) chiede se un processo e vivo: da qui, dove i test sostituiscono Test-SessioneViva.
$script:TestViva = { param($ProcessoId, $Avvio) Test-SessioneViva -ProcessoId $ProcessoId -Avvio $Avvio }
. (Join-Path $PSScriptRoot 'Istantanea.ps1')

# ---- log ---------------------------------------------------------------------------------------------------------

function Write-Log([string]$Livello, [string]$Messaggio) {
    $riga = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Livello, $Messaggio
    Write-Host $riga
    if ($WhatIf) { return }
    $file = Get-FileLog $CartellaDati (Get-Date)
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::AppendAllText($file, $riga + "`n", [Text.UTF8Encoding]::new($false))
}

function Write-Prova([string]$Messaggio) { Write-Host "[WhatIf] $Messaggio" }

# ---- piccoli aiuti -----------------------------------------------------------------------------------------------

function Get-NomeStato($Cfg, [string]$Chiave) { [string]$Cfg.Stati.$Chiave }

# Una riga nel registro dell'apprendimento (D46). Il registro e un di piu: se non si scrive il giro prosegue. Con -WhatIf
# non si scrive.
function Write-Apprendimento([int]$Id, [string]$Repo, [string]$Tipo, [string]$Ruolo, [string]$Motivo, [string]$Lezione, [string]$Esito) {
    if ($WhatIf) { return }
    try { Add-RigaApprendimento -CartellaDati $CartellaDati -Card $Id -Repo $Repo -Tipo $Tipo -Ruolo $Ruolo -Motivo $Motivo -Lezione $Lezione -Esito $Esito }
    catch { Write-Log 'WARN' "card ${Id}: riga '$Tipo' non scritta nel registro dell'apprendimento: $($_.Exception.Message)" }
}

# Tag di attesa, commento [smistatore] con la menzione a Titolare e una riga di log. Telegram lo manda il supervisore (D51), che
# ritrova l'on-hold dalla card. Per e il valore di inAttesaPer.
# Causa: perche si e fermata la sessione, per chi deve decidere se l'on-hold si toglie da solo (D51): silenzio, morta,
# fallita, scritture. Senza Causa (ogni altra attesa) il segno si cancella, cosi non resta quello di un on-hold di prima.
# D57: il commento finisce con "Cosa fare". Il gesto viene dalle righe "Per Titolare:" dell'ultima sessione (di solito il
# responsabile, nella passata D42), altrimenti e quello predefinito; si tiene in indicazioniAttesa per vista e supervisore.
function Set-InAttesa($Cfg, $CardAdo, $Sc, [string]$Titolare, [string]$Motivo, $Per, [string]$Causa = '') {
    $ultima = Get-UltimaSessioneCard $Sc
    $indicazioni = Get-IndicazioniAttesa ([string](Get-Campo (Get-Campo $ultima 'Sessione') 'testo')) $Motivo $Per $Causa
    $cosaFare = Format-CosaFare $indicazioni $Per
    [void](Set-AdoCard -Id $CardAdo.Id -AggiungiTag @([string]$Cfg.Stati.tagAttesa))
    [void](Add-AdoCommento -Id $CardAdo.Id -Testo "[smistatore] $Motivo`n`n$cosaFare" -Menziona $Titolare)
    $Sc['indicazioniAttesa'] = $indicazioni
    $Sc['inAttesaPer'] = $Per
    $Sc['causaAttesa'] = if ($Causa) { $Causa } else { $null }
    $Sc['attesaToltaDaSmistatore'] = $null
    # un on-hold e un fatto che qualcuno deve poter ritrovare nel log
    Write-Log 'INFO' (Format-RigaLog 'OnHold' @($CardAdo.Id, $Motivo, $Per))
    $CardAdo.Tag = @($CardAdo.Tag) + [string]$Cfg.Stati.tagAttesa
    # chi si e fermato e l'ultimo ruolo che ha lavorato sulla card; il repo dalla mappa, qui la voce non c'e
    Write-Apprendimento ([int]$CardAdo.Id) ([string](Get-Campo (Find-VoceMappa -Mappa $Cfg.Mappa -Area $CardAdo.Area) 'repo')) 'onHold' ([string](Get-Campo $Sc 'ultimoRuolo')) $Motivo
}

# D42: annulla la passata appena avviata (il responsabile non e partito): il tipo esce dall'elenco delle passate fatte e
# l'attesa in esame si dimentica, cosi la prossima volta la passata riparte invece di contare come fatta.
function Undo-PassataAttesa($Sc) {
    $chiave = [string](Get-Campo (Get-Campo $Sc 'attesaInEsame') 'chiave')
    $Sc['passateFatte'] = @(@(Get-Campo $Sc 'passateFatte') | Where-Object { $null -ne $_ -and [string]$_ -ne $chiave })
    $Sc['attesaInEsame'] = $null
}

# ---- sessioni finite o silenziose (passo 2) ----------------------------------------------------------------------

# Cosa ha cambiato nel worktree della card una sessione di un ruolo in sola lettura, come frase per il commento; $null
# se niente, o se la sessione e partita senza impronta (dev, la copia principale, una sessione nata prima del controllo).
# Togliere Write ed Edit a un ruolo non gli toglie la shell: questo e il punto che se ne accorge. Se il worktree non si
# riesce a leggere lo dice, perche un controllo che salta in silenzio vale come se non ci fosse.
function Get-ScrittureSolaLettura($S) {
    $prima = Get-Campo $S 'impronta'
    if ($null -eq $prima) { return $null }
    $ruolo = [string]$S['ruolo']
    $cartella = [string](Get-Campo $S 'cartella')
    try { $differenze = @(Compare-ImprontaWorktree -Prima $prima -Dopo (Get-ImprontaWorktree -Cartella $cartella)) }
    catch { return "$ruolo lavora in sola lettura, ma non sono riuscito a controllare che il worktree $cartella sia rimasto com'era: $($_.Exception.Message)." }
    if ($differenze.Count -eq 0) { return $null }
    "$ruolo lavora in sola lettura, ma durante la sua sessione il worktree $cartella e cambiato: $($differenze -join '; ')."
}

# D51: a sessione finita con un result si tiene l'ultima lettura dell'uso delle finestre di token. Se la sessione e
# finita sul limite si scrive anche la pausa (reset piu margine). La pausa gia scritta resta se questa sessione non ne porta una.
function Save-QuotaSessione($Esito, $Adesso, $Limite, $Margine) {
    Update-QuotaDaEsito -Esito $Esito -Adesso $Adesso -Limite $Limite -Margine $Margine -Percorso $script:PercorsoQuota
}

# La sessione chiusa senza risultato: se e viva (silenzio) si ferma, altrimenti si logga com'e finita; poi la riga nel
# registro dei consumi, vuota, con la causa al posto dell'esito.
function Write-ChiusuraSenzaRisultato([int]$Id, $Voce, $S, $Esito, $Fase) {
    $ruolo = [string]$S['ruolo']
    if ($Fase.Viva) {
        Write-Log 'WARN' "card ${Id}: sessione $($S['id']) ($ruolo) in silenzio da piu di $($Fase.Silenzio) minuti, la chiudo"
        Stop-Sessione -Pid ([int]$S['pid']) -Avvio (Get-Campo $S 'avvio')
    }
    else {
        Write-Log 'WARN' "card ${Id}: sessione $($S['id']) ($ruolo) terminata senza un result, la chiudo come errore"
        $ultimeRighe = Get-ErroriSessione -Id $S['id'] -CartellaDati $CartellaDati
        if ($ultimeRighe) { Write-Log 'WARN' "card ${Id}: ultime righe degli errori della sessione $($S['id']): $ultimeRighe" }
    }
    $vuoto = [pscustomobject]@{ Turni = 0; TokenIn = 0; TokenOut = 0; CacheLetti = 0; CacheScritti = 0 }
    Write-RegistroSessione -CartellaDati $CartellaDati -Riga (New-RigaRegistro $Id $Voce $S $vuoto (Get-Adesso).ToString('o') $Fase.Causa)
}

# I consumi di una sessione finita come si scrivono sulla card: token totali e minuti (per eccesso).
function Get-ConsumiSessione($Esito) {
    [pscustomobject]@{ Somma = (Get-TotaleToken $Esito); Minuti = [int64][math]::Ceiling([double]$Esito.DurataMs / 60000) }
}

# La sessione finita: la riga nel registro dei consumi e i consumi sommati alla card (se si legge e sta nella mappa).
function Write-ChiusuraFinita([int]$Id, $CardAdo, $Voce, $S, $Esito, [string]$Fine, [bool]$PerLimite = $false) {
    $esitoRegistro = if ($PerLimite) { 'limite' } elseif ($Esito.Errore) { 'errore' } elseif ($Esito.Esito) { [string]$Esito.Esito } else { '' }
    Write-RegistroSessione -CartellaDati $CartellaDati -Riga (New-RigaRegistro $Id $Voce $S $Esito $Fine $esitoRegistro)
    if ($null -ne $CardAdo -and $null -ne $Voce) {
        $c = Get-ConsumiSessione $Esito
        try {
            $campi = Get-AdoCampiConsumi
            [void](Set-AdoCard -Id $Id -Campi @{
                $campi.Totale = [int64]$CardAdo.ConsumoTotale + $c.Somma
                $campi.Minuti = [int64]$CardAdo.MinutiAgente + $c.Minuti
            })
            $CardAdo.ConsumoTotale = [int64]$CardAdo.ConsumoTotale + $c.Somma
            $CardAdo.MinutiAgente = [int64]$CardAdo.MinutiAgente + $c.Minuti
        }
        catch { Write-Log 'ERRORE' "card ${Id}: consumi non scritti sulla card: $($_.Exception.Message)" }
    }
    else { Write-Log 'WARN' "card ${Id}: consumi non scritti sulla card (non leggibile o non nella mappa); restano nel registro" }
}

# Le lezioni che il ruolo dice di aver seguito (righe LEZIONE: <id> del testo finale): una riga ciascuna nel registro
# dell'apprendimento, da cui si vede quali lezioni lavorano.
# La riga porta l'esito della sessione (bloccato, bivio, finito...): e da li che si sa se la lezione e stata applicata in una
# sessione che poi si e fermata.
function Write-LezioniApplicate([int]$Id, $Voce, [string]$Ruolo, $Esito) {
    foreach ($lezione in @(Get-Campo $Esito 'Lezioni')) {
        Write-Apprendimento $Id ([string](Get-Campo $Voce 'repo')) 'lezioneApplicata' $Ruolo '' ([string]$lezione) ([string](Get-Campo $Esito 'Esito'))
    }
}

# Chiude la sessione di una card. CardAdo e Voce possono mancare (card cancellata o non leggibile, area uscita dalla mappa):
# la sessione si chiude e si registra lo stesso, altrimenti resterebbe valorizzata e terrebbe occupato un posto per sempre.
# Senza l'una o l'altra la card non si tocca: niente consumi, niente on-hold, solo il log.
function Close-Sessione($Cfg, [int]$Id, $CardAdo, $Voce, $Sc, [string]$Titolare) {
    $s = $Sc['sessione']
    $ruolo = [string]$s['ruolo']
    $esito = Get-EsitoSessione -Id $s['id'] -CartellaDati $CartellaDati
    $adesso = Get-Adesso
    $suCard = $null -ne $CardAdo -and $null -ne $Voce
    $fase = Get-FaseSessione $Cfg $s $esito $script:TestViva (Get-Adesso)
    if ($fase.Fase -eq 'inCorso') { return }

    if ($fase.Fase -eq 'senzaRisultato') {
        $viva = $fase.Viva
        $silenzio = $fase.Silenzio
        $causa = $fase.Causa
        $motivo = if ($viva) { "La sessione di $ruolo e rimasta in silenzio per piu di $silenzio minuti ed e stata chiusa. Si puo riprendere togliendo il tag $($Cfg.Stati.tagAttesa)." }
        else { "La sessione di $ruolo e terminata senza dare un risultato (il processo non c'e piu): non riprovo da solo. Gli ultimi errori sono nel log dello smistatore." }
        if ($WhatIf) { Write-Prova "card ${Id}: la sessione $($s['id']) ($ruolo) $(if ($viva) { "e in silenzio da piu di $silenzio minuti" } else { 'e terminata senza risultato' }): la chiuderei$(if ($suCard) { $(if ([int](Get-Campo $Sc 'ripreseAutomatiche') -lt 1) { ' e la riprenderei da sola, senza on-hold (se non ci sono scritture D39)' } else { ' e metterei la card in on-hold' }) })"; return }
        # la card va gia in on-hold: se il ruolo era in sola lettura e ha cambiato il worktree, il motivo lo dice
        $scritture = Get-ScrittureSolaLettura $s
        if ($scritture) { $motivo += " $scritture" }
        Write-ChiusuraSenzaRisultato $Id $Voce $s $esito $fase
        # ultimaSessione tiene l'id (serve a riprenderla) ma non ha una fine. Se il processo e morto senza scrivere un solo
        # evento la sessione non e mai nata: senza id, chi riprende la card ne lancia una nuova invece di un --resume a vuoto.
        $nata = $viva -or ($null -ne $esito -and [int](Get-Campo $esito 'Eventi') -gt 0)
        $Sc['ultimaSessione'][$ruolo] = @{ id = $(if ($nata) { $s['id'] } else { $null }); ruolo = $ruolo; inizio = $s['inizio']; fine = $null; esito = $null; testo = $null; errore = ($causa -eq 'errore'); task = (Get-Campo $s 'task'); motivo = (Get-Campo $s 'motivo') }
        $Sc['ultimoRuolo'] = $ruolo
        $Sc['sessione'] = $null
        # D51: la prima volta per card (e senza scritture D39) silenzio o processo morto non e un on-hold: la sessione si
        # riprende da sola, con un commento senza menzione. Dal secondo fermo si ferma come sempre.
        if ($suCard -and -not $scritture -and [int](Get-Campo $Sc 'ripreseAutomatiche') -lt 1) {
            $Sc['inAttesaPer'] = 'sessione'
            $Sc['attesaToltaDaSmistatore'] = $true
            $Sc['ripreseAutomatiche'] = [int](Get-Campo $Sc 'ripreseAutomatiche') + 1
            $Sc['causaAttesa'] = $null
            $cosa = if ($causa -eq 'silenzio') { "e rimasta in silenzio per piu di $silenzio minuti ed e stata chiusa" } else { "e terminata senza dare un risultato (il processo non c'e piu)" }
            Write-Log 'INFO' "card ${Id}: sessione $($s['id']) ($ruolo) ${cosa}: la riprendo da sola, una volta, senza on-hold"
            try { [void](Add-AdoCommento -Id $CardAdo.Id -Testo "[smistatore] La sessione di $ruolo $cosa. La riprendo da sola, una volta: se si ferma di nuovo la card va in on-hold.") }
            catch { Write-Log 'WARN' "card ${Id}: commento della ripresa automatica non scritto: $($_.Exception.Message)" }
        }
        elseif ($suCard) { Set-InAttesa $Cfg $CardAdo $Sc $Titolare $motivo 'sessione' -Causa $(if ($scritture) { 'scritture' } elseif ($causa -eq 'silenzio') { 'silenzio' } else { 'morta' }) }
        else { Write-Log 'WARN' "card ${Id}: sessione chiusa ($causa), ma la card non e leggibile o non e nella mappa: nessun on-hold" }
        return
    }

    $consumi = Get-ConsumiSessione $esito
    $somma = $consumi.Somma
    $minuti = $consumi.Minuti
    # D51: il limite di token non e una sessione fallita ma una pausa. Un limite senza reset (Limite null) resta un errore normale.
    $limite = Get-Campo $esito 'Limite'
    $perLimite = $null -ne $limite -and $null -ne (Get-Campo $limite 'Reset')
    $margine = [double](Get-Campo $Cfg.Limiti 'margineQuotaMinuti')
    if ($WhatIf) {
        if ($perLimite) { Write-Prova "card ${Id}: la sessione $($s['id']) ($ruolo) si e fermata sul limite di token (finestra $($limite.Finestra), reset $(([datetime]$limite.Reset).ToString('o'))): scriverei la pausa in quota.json, il registro, sommerei $somma e $minuti min alla card, niente on-hold" }
        else { Write-Prova "card ${Id}: la sessione $($s['id']) ($ruolo) e finita (esito $($esito.Esito), errore $($esito.Errore)): scriverei il registro, sommerei $somma e $minuti min alla card" }
        return
    }
    $fine = $adesso.ToString('o')
    try { Save-QuotaSessione $esito $adesso $(if ($perLimite) { $limite } else { $null }) $margine }
    catch { Write-Log 'ERRORE' "card ${Id}: quota.json non scritto: $($_.Exception.Message)" }
    Write-ChiusuraFinita $Id $CardAdo $Voce $s $esito $fine -PerLimite $perLimite
    # un blocco o un bivio e il segno che al ruolo mancava qualcosa: e da qui che il mentore, poi, sa dove guardare
    if (-not $esito.Errore -and $esito.Esito -in 'bloccato', 'bivio') { Write-Apprendimento $Id ([string](Get-Campo $Voce 'repo')) 'blocco' $ruolo "$($esito.Esito): $($esito.Testo)" }
    Write-LezioniApplicate $Id $Voce $ruolo $esito

    # una sessione fallita non lascia un esito: chi riprende la card ricomincia da li
    $Sc['ultimaSessione'][$ruolo] = @{
        id = $s['id']; ruolo = $ruolo; inizio = $s['inizio']; fine = $fine; turni = $esito.Turni; task = (Get-Campo $s 'task'); motivo = (Get-Campo $s 'motivo')
        esito = $(if ($esito.Errore -or $perLimite) { $null } else { $esito.Esito }); testo = $esito.Testo; errore = [bool]($esito.Errore -and -not $perLimite)
    }
    $Sc['ultimoRuolo'] = $ruolo
    $Sc['sessione'] = $null
    # il log dice anche se la sessione e fallita: con l'esito soltanto sembrava riuscita mentre la card andava in on-hold
    $comeFinita = if ($esito.Errore) { 'FALLITA' } else { 'finita' }
    $negatiLog = if (@($esito.Negati).Count -gt 0) { ", comandi negati: $(@($esito.Negati).Count)" } else { '' }
    $pausaFino = ([datetime]$(if ($perLimite) { $limite.Reset } else { $adesso })).ToUniversalTime().AddMinutes($margine)
    if ($perLimite) { Write-Log 'INFO' "card ${Id}: sessione $($s['id']) ($ruolo) ferma sul limite di token (finestra $($limite.Finestra)), nessun lancio fino al $($pausaFino.ToString('o')), poi riprende; $somma token, $minuti min" }
    else { Write-Log 'INFO' "card ${Id}: sessione $($s['id']) ($ruolo) $comeFinita, esito '$($esito.Esito)'$negatiLog, $somma token, $minuti min" }
    $scritture = Get-ScrittureSolaLettura $s
    if ($scritture) { Write-Log 'WARN' "card ${Id}: $scritture" }
    # Un ruolo in sola lettura che ha cambiato il worktree si ferma anche se poi ha trovato il limite (D39): niente pausa
    # con ripresa, va nel ramo dell'errore qui sotto, che mette l'on-hold con l'elenco delle scritture.
    if ($perLimite -and $scritture) { $perLimite = $false; $Sc['ultimaSessione'][$ruolo]['errore'] = $true }
    if ($perLimite) {
        # Niente on-hold ne Telegram: la pausa e in quota.json e Get-Decisione riprende la sessione dopo. Il segno resta
        # senza il tag: e la strada della ripresa dopo un on-hold per 'sessione', ma senza persona di mezzo.
        $Sc['inAttesaPer'] = 'quota'
        if ($suCard) {
            $locale = $pausaFino.ToLocalTime()
            $quando = if ($locale.Date -eq (Get-Date).Date) { $locale.ToString('HH:mm') } else { $locale.ToString('HH:mm') + ' del ' + $locale.ToString('dd/MM') }
            try { [void](Add-AdoCommento -Id $CardAdo.Id -Testo "[smistatore] La sessione di $ruolo si e fermata sul limite di token e riprende da sola dopo le $quando.") }
            catch { Write-Log 'WARN' "card ${Id}: commento sul limite di token non scritto: $($_.Exception.Message)" }
        }
    }
    elseif ($esito.Errore -and $suCard) {
        Set-InAttesa $Cfg $CardAdo $Sc $Titolare "La sessione di $ruolo e fallita (errore, oppure comandi negati dai permessi): non riprovo da solo. Il registro delle sessioni ha i dettagli.$(if ($scritture) { " $scritture" })" 'sessione' -Causa 'fallita'
    }
    elseif ($scritture -and $suCard) {
        # Il giudizio di chi ha toccato cio che doveva solo leggere non si applica: la card si ferma, e tolto l'on-hold
        # il ruolo riparte sul worktree che la persona ha lasciato.
        $detto = if ($esito.Esito) { "L'esito '$($esito.Esito)' della sessione non lo applico. " } else { '' }
        Set-InAttesa $Cfg $CardAdo $Sc $Titolare "$scritture ${detto}Guarda il worktree, rimettilo com'era o tieni cio che serve, poi togli il tag $($Cfg.Stati.tagAttesa): $ruolo riparte." 'sessione' -Causa 'scritture'
    }
    elseif ($suCard) {
        # L'esito sta sempre sulla card, nello stesso formato: il commento dell'agente non sempre lo dice in chiaro (card 23)
        $esitoTesto = if ($esito.Esito) { "**$($esito.Esito)**" } else { 'senza riga ESITO' }
        $testo = "[smistatore] Sessione $($s['id']) finita: ruolo $ruolo, esito $esitoTesto."
        $conNegati = @($esito.Negati).Count -gt 0
        if ($conNegati) {
            # la card prosegue con l'esito della sessione; la persona sa che qualcosa ha provato a uscire dai permessi
            $strumenti = (@($esito.Negati) | Sort-Object -Unique) -join ', '
            $testo += " Le sono stati negati $(@($esito.Negati).Count) comandi ($strumenti): la card prosegue, il dettaglio e nella sessione. Se servivano, vanno rivisti i permessi del ruolo."
        }
        try {
            if ($conNegati) { [void](Add-AdoCommento -Id $CardAdo.Id -Testo $testo -Menziona $Titolare) }
            else { [void](Add-AdoCommento -Id $CardAdo.Id -Testo $testo) }
        }
        catch { Write-Log 'WARN' "card ${Id}: commento di fine sessione non scritto: $($_.Exception.Message)" }
    }
}
# La cartella in cui lavora un mentore (vuota, sua: non e ne il worktree della card ne la copia del repo) sta sotto
# <dati>/mentori. Si toglie solo li dentro: lo stato e un file che qualcuno puo aver toccato, e un percorso letto da li non
# deve poter cancellare altro. Best effort: una cartella che resta e solo spazio, non ferma la chiusura.
function Remove-CartellaMentore([string]$Cartella) {
    if (-not $Cartella -or $WhatIf) { return }
    try {
        $dentro = [IO.Path]::GetFullPath((Join-Path $CartellaDati 'mentori')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $questa = [IO.Path]::GetFullPath($Cartella)
        if ($questa.StartsWith($dentro, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $questa)) { Remove-Item -LiteralPath $questa -Recurse -Force -ErrorAction Stop }
    }
    catch { Write-Log 'WARN' "la cartella del mentore '$Cartella' non si e potuta togliere: $($_.Exception.Message)" }
}

# Un mentore e un di piu: finito (bene, male o morto) si registra e sparisce, ma la card non si ferma e non cambia
# stato. Restituisce vero se la sessione e chiusa. Il mentore non chiude con una riga ESITO utile al flusso: conta solo
# che sia finito, per il registro e per i consumi.
function Close-Mentore($Cfg, [int]$Id, $CardAdo, $Voce, $M) {
    $esito = Get-EsitoSessione -Id $M['id'] -CartellaDati $CartellaDati
    $fase = Get-FaseSessione $Cfg $M $esito $script:TestViva (Get-Adesso)
    if ($fase.Fase -eq 'inCorso') { return $false }
    if ($WhatIf) { Write-Prova "card ${Id}: il mentore $($M['id']) e finito o fermo: lo chiuderei e scriverei il registro"; return $false }
    if ($fase.Fase -eq 'senzaRisultato') { Write-ChiusuraSenzaRisultato $Id $Voce $M $esito $fase; Remove-CartellaMentore (Get-Campo $M 'cartella'); return $true }
    Write-ChiusuraFinita $Id $CardAdo $Voce $M $esito (Get-Adesso).ToString('o')
    # D51: la quota e una sola, anche la sessione di un mentore ne porta la lettura. Niente pausa: un mentore che trova il
    # limite e un mentore fallito, la card non si tocca.
    try { Save-QuotaSessione $esito (Get-Adesso) $null ([double](Get-Campo $Cfg.Limiti 'margineQuotaMinuti')) }
    catch { Write-Log 'ERRORE' "card ${Id}: quota.json non scritto: $($_.Exception.Message)" }
    $consumi = Get-ConsumiSessione $esito
    $comeFinita = if ($esito.Errore) { 'FALLITO' } else { 'finito' }
    Write-Log $(if ($esito.Errore) { 'WARN' } else { 'INFO' }) "card ${Id}: mentore $($M['id']) $comeFinita, $($consumi.Somma) token, $($consumi.Minuti) min"
    Remove-CartellaMentore (Get-Campo $M 'cartella')
    $true
}

# I mentori in corso di una card: quelli chiusi escono da mentori, gli altri restano. Uno alla volta: se la chiusura del
# secondo lancia, il primo e gia fuori dall'elenco (il giro salva lo stato anche dopo l'errore) e il giro dopo non lo
# registra una seconda volta, con i consumi sommati due volte alla card.
function Close-Mentori($Cfg, [int]$Id, $CardAdo, $Voce, $Sc) {
    $restanti = [System.Collections.Generic.List[object]]::new()
    foreach ($m in @($Sc['mentori'])) { if ($null -ne $m) { $restanti.Add($m) } }
    foreach ($m in @($restanti)) {
        if (-not (Close-Mentore $Cfg $Id $CardAdo $Voce $m)) { continue }
        [void]$restanti.Remove($m)
        if (-not $WhatIf) { $Sc['mentori'] = @($restanti) }
    }
}

# ---- le azioni (passo 3) -----------------------------------------------------------------------------------------

function Invoke-Azione($Cfg, $K, $Az) {
    $card = $K.Card; $sc = $K.Sc; $voce = $K.Voce
    switch ($Az.Tipo) {
        'LanciaSessione' {
            $ruolo = [string]$Az.Ruolo
            # dev scrive il codice e reviewer rivede il ramo: tutti e due lavorano solo nel worktree della card. Se non c'e
            # (tolto a mano, o rimosso dopo la PR) l'azione fallisce e la card va in on-hold: mai nella copia principale.
            # responsabile non ha strumenti di scrittura dei file e puo leggere la copia principale.
            # D52: la card di chiusura ha un worktree in sola lettura (detached su origin/<ramo della funzionalita>): lo crea, o lo riporta al
            # ramo aggiornato, ogni lancio che Decisioni segna con WorktreeChiusura (il collaudatore, anche alla ripresa). Poi vale come
            # ogni worktree di card: il ruolo ci lavora e l'impronta (D39) controlla che non lo cambi.
            if (Get-Campo $Az 'WorktreeChiusura') {
                if (-not $sc['ramo']) { throw 'La card di chiusura non ha un ramo salvato: non posso preparare il worktree in sola lettura' }
                $sc['cartella'] = [string](Update-WorktreeChiusura -Voce $voce -Card $card -Ramo ([string]$sc['ramo'])).Cartella
            }
            $haWorktree = $sc['cartella'] -and (Test-Path -LiteralPath $sc['cartella'])
            if ($haWorktree) { $cartella = [string]$sc['cartella'] }
            elseif ($ruolo -in 'dev', 'reviewer', 'collaudatore') {
                throw "La card non ha un worktree utilizzabile (cartella salvata: '$($sc['cartella'])'): $ruolo non parte nella copia principale di $($voce.repo)"
            }
            else { $cartella = [string]$voce.cartella }
            $ultima = if ($sc['ultimaSessione'].Contains($ruolo)) { $sc['ultimaSessione'][$ruolo] } else { $null }
            $idTask = if ($Az.Task) { [int]$Az.Task } else { 0 }
            # un task parte con contesto pulito: la sessione di un altro task non si riprende, qualunque sia la cache
            $altroTask = $idTask -gt 0 -and $ultima -and [int](Get-Campo $ultima 'task') -ne $idTask
            $riprendi = $null
            if ($ultima -and $ultima['id'] -and -not $altroTask -and ($Az.Riprendi -or (Test-Riprendibile -UltimaSessione $ultima -Limiti $Cfg.Limiti))) { $riprendi = [string]$ultima['id'] }
            elseif ($Az.Riprendi) { Write-Log 'WARN' "card $($card.Id): non c'e una sessione di $ruolo da riprendere, ne parte una nuova" }

            # L'allegato (rilievi, bivio, log della build) non va nel messaggio: Start-SessioneRuolo lo scrive in un file e passa il percorso.
            $righe = @("Card $($card.Id) nel repo $($voce.repo).", "Motivo: $($Az.Motivo).")
            # Una ripresa dopo l'on-hold continua una conversazione che si era fermata su una conclusione: senza dirle che
            # qualcosa e cambiato la ripete (card 23). Il brief va riletto dal file, che puo essere stato corretto nel frattempo.
            if ($Az.Motivo -eq 'ripresa') {
                # dopo il fatto della passata del responsabile (D42) l'on-hold non c'e mai stato: a cambiare la causa e stato lui
                $chi = if ($Az.Contains('DopoRipresaAutomatica') -and $Az['DopoRipresaAutomatica']) { "La tua sessione era stata chiusa dallo smistatore (in silenzio da troppo, oppure il processo era terminato senza risultato): nessuno ha tolto un on-hold. Riprendi da dove eri arrivato." }
                elseif ($Az.Contains('DopoQuota') -and $Az['DopoQuota']) { "La tua sessione si era fermata per il limite di token: nessuno ha tolto un on-hold e non e cambiato niente, la quota e tornata. Continua da dove eri arrivato." }
                elseif ($Az.Contains('DopoPassata') -and $Az['DopoPassata']) { "Il responsabile ha esaminato l'attesa per cui la card si stava fermando e ha sistemato la causa: leggi il suo commento sulla card, dice cosa ha cambiato." }
                    else { "Chi ha la card ha tolto l'on-hold: qualcosa e cambiato da quando ti sei fermato." }
                $righe += "$chi Prima di concludere rileggi con Read il brief del tuo ruolo, $(Join-Path $Radice ([string]$Cfg.Ruoli.$ruolo.brief)), perche le regole possono essere state corrette, e i commenti sulla card dopo il tuo ultimo, che possono contenere una risposta o una decisione. Poi riprendi il lavoro con le regole di adesso."
            }
            # Validazione rossa: il log lo scarica lo smistatore, perche dev non ha il PAT. Se non si legge, dev parte lo
            # stesso con il link e il motivo, e decide lui se fermarsi.
            $allegato = $Az.Allegato
            if ($ruolo -eq 'dev' -and $Az.Motivo -eq 'rossa' -and $K.Pr -and (Get-Campo $K.Pr 'BuildId')) {
                $errori = try { Get-AdoErroriBuild -Progetto $voce.progettoAdo -BuildId ([int]$K.Pr.BuildId) }
                catch { "Il log della build non e stato letto: $($_.Exception.Message)" }
                $allegato = "Build fallita: $($Az.Allegato)`n`n$errori"
            }
            # D52, gruppo 5: la card che allinea il ramo della funzionalita a develop ha come base quel ramo (la PR va li) ma il lavoro e unire
            # origin/develop: il brief lo dice per il tag, e il messaggio lo ricorda a ogni lancio di dev (il primo e conflitti)
            if ($ruolo -eq 'dev' -and @($card.Tag) -contains [string]$Cfg.Stati.tagAllinea) {
                $righe += "La card ha il tag $($Cfg.Stati.tagAllinea): il tuo lavoro e unire origin/develop nel ramo della card (non origin/$((Get-DestinazioneCard $sc))), come dice il brief."
            }
            # La sessione di un task lo sa dal messaggio e da ATTREZZI_TASK (la imposta Start-SessioneRuolo).
            if ($idTask -gt 0) {
                $tt = @($K.Task | Where-Object { [int](Get-Campo $_ 'Id') -eq $idTask }) | Select-Object -First 1
                $titolo = if ($tt) { ": $(Get-Campo $tt 'Titolo')" } else { '' }
                $righe += "Task $idTask$titolo."
            }
            # Base: il ramo verso cui va la PR della card (ATTREZZI_BASE: dev e reviewer fanno il diff e il merge li, D52)
            $p = @{ Card = [int]$card.Id; Ruolo = $ruolo; Messaggio = ($righe -join "`n"); Cartella = $cartella
                Config = $Cfg; Radice = $Radice; CartellaDati = $CartellaDati; Repo = [string]$voce.repo; Base = (Get-DestinazioneCard $sc) }
            # il collaudatore riceve le credenziali di prova del repo, se ci sono (spec, sezione 20)
            if ($ruolo -eq 'collaudatore') { $p['FileCollaudo'] = Join-Path $HOME ".claude/collaudo/$($voce.repo).json" }
            if ($allegato) { $p['Allegato'] = [string]$allegato }
            if ($idTask -gt 0) { $p['Task'] = $idTask }
            if ($riprendi) { $p['Riprendi'] = $riprendi }
            # Un ruolo in sola lettura non deve cambiare il worktree della card: se ne prende l'impronta prima di lanciarlo
            # e Close-Sessione la confronta a sessione finita. Nella copia principale no: quella la cambia anche Titolare.
            $impronta = if ($haWorktree -and (Test-RuoloSolaLettura -RuoloConfig $Cfg.Ruoli.$ruolo)) { Get-ImprontaWorktree -Cartella $cartella } else { $null }
            $r = Start-SessioneRuolo @p
            # la memoria dei ruoli e un di piu: se ha ripiegato (git, Azure DevOps) la sessione e partita lo stesso, e qui si dice perche
            foreach ($m in @(Get-Campo $r 'AvvisiMemoria')) { Write-Log 'WARN' "card $($card.Id): memoria dei ruoli, $ruolo parte senza il suo meglio: $m" }

            $rc = $Cfg.Ruoli.$ruolo
            $inizio = (Get-Adesso).ToString('o')
            # il motivo resta con la sessione: una ripresa continua il lavoro di prima, con il suo motivo
            $motivo = if ($Az.Motivo -eq 'ripresa' -and $ultima -and (Get-Campo $ultima 'motivo')) { [string](Get-Campo $ultima 'motivo') } else { [string]$Az.Motivo }
            $sc['sessione'] = @{ id = $r.Id; pid = $r.Pid; avvio = $r.Avvio; ruolo = $ruolo; inizio = $inizio; ripresa = [bool]$r.Ripresa; cartella = $cartella; modello = $rc.modello; sforzo = $rc.sforzo; task = $(if ($idTask -gt 0) { $idTask } else { $null }); motivo = $motivo; impronta = $impronta }
            $sc['ultimaSessione'][$ruolo] = @{ id = $r.Id; ruolo = $ruolo; inizio = $inizio; fine = $null; esito = $null; testo = $null; errore = $false; task = $(if ($idTask -gt 0) { $idTask } else { $null }); motivo = $motivo }
            $sc['ultimoRuolo'] = $ruolo
            $sc['inAttesaPer'] = $null
            $sc['attesaToltaDaSmistatore'] = $null
            $K.Lanciata = $true
            if ($ruolo -eq 'dev' -and $Az.Motivo -eq 'rossa') {
                $sc['rossaGestita'] = Get-Campo $K.Pr 'BuildId'
                $sc['rosseDiFila'] = [int]$sc['rosseDiFila'] + 1
            }
            # un giro di revisione e un ritorno da reviewer a dev: si conta quando dev riparte con i rilievi
            if ($ruolo -eq 'dev' -and $Az.Motivo -eq 'rilievi') { $sc['giriRevisione'] = [int]$sc['giriRevisione'] + 1 }
            # un giro di collaudo e un collaudo respinto: si conta quando responsabile ne legge il resoconto
            if ($ruolo -eq 'responsabile' -and $Az.Motivo -eq 'collaudoRespinto') { $sc['giriCollaudo'] = [int](Get-Campo $sc 'giriCollaudo') + 1 }
            # D52, gruppo 5: il responsabile guarda la CI rossa della card di chiusura una volta per build
            if ($ruolo -eq 'responsabile' -and $Az.Motivo -eq 'ciRossa') { $sc['ciRossaGestita'] = [string]$Az.Build; $sc['ciRosseDiFila'] = [int](Get-Campo $sc 'ciRosseDiFila') + 1 }
            Write-Log 'INFO' "card $($card.Id): lanciata la sessione $($r.Id) ($ruolo$(if ($r.Ripresa) { ', ripresa' }))"
            # Il commento e un di piu: a sessione gia partita un suo errore non mette la card in on-hold, va solo nel log.
            try {
                $verbo = if ($r.Ripresa) { 'ripresa' } else { 'avviata' }
                [void](Add-AdoCommento -Id $card.Id -Testo "[smistatore] Sessione $($r.Id) $verbo`: ruolo $ruolo, cartella $cartella.")
            }
            catch { Write-Log 'ERRORE' "card $($card.Id): commento di avvio della sessione $($r.Id) non scritto: $($_.Exception.Message)" }
            # Il task su cui parte dev va in Active, cosi dalla board si vede quale e in lavorazione. Come il commento e un
            # di piu: un suo errore va nel log e non ferma la card.
            if ($ruolo -eq 'dev' -and $idTask -gt 0) {
                $attivo = $Cfg.Stati.taskAttivo
                $tt = @($K.Task | Where-Object { [int](Get-Campo $_ 'Id') -eq $idTask }) | Select-Object -First 1
                if ($tt -and "$(Get-Campo $tt 'Stato')" -ine $attivo) {
                    try { [void](Set-AdoTaskStato -Id $idTask -Stato $attivo) }
                    catch { Write-Log 'ERRORE' "card $($card.Id): il task $idTask non e passato in $attivo`: $($_.Exception.Message)" }
                }
            }
        }
        { $_ -in 'SpostaCard', 'RiportaIndietro' } {
            $nome = Get-NomeStato $Cfg $Az.Stato
            $prima = Get-ChiaveStato $Cfg.Stati $card.Stato
            $rev = Set-AdoCard -Id $card.Id -Stato $nome
            Add-RevNostra -Id $card.Id -Rev ([int]$rev) -Percorso $script:PercorsoStato
            if ($Az.Stato -eq 'inRevisione') { $sc['rosseDiFila'] = 0 }
            # in Ready to merge il collaudo e superato (o saltato): i respinti di prima non contano piu
            if ($Az.Stato -eq 'daUnire') { $sc['giriCollaudo'] = 0 }
            # due card che vorrebbero entrare nello stesso giro in uno stato a posto singolo: la seconda deve vedere la prima
            $card.Stato = $nome
            if ($Az.Stato -eq 'inSviluppo') { Add-AInTabella $K.Contesto.InSviluppoPerRepo $voce.repo $card.Id }
            if ($Az.Stato -in (Get-StatiInTest)) { Add-CardAlContestoTest $K.Contesto $voce $card.Id }
            # D59: l'ambiente di collaudo e pronto (la card esce da Deploying to test per il collaudo): gli URL e dove stanno gli utenti di prova
            if ($prima -eq 'inDeployTest' -and $Az.Stato -in 'inCollaudo', 'inProvaUmana' -and $sc['collaudoProgetto']) {
                try { [void](Add-AdoCommento -Id $card.Id -Testo "[smistatore] Ambiente di collaudo pronto:`n$(ConvertTo-ElencoUrlCollaudo $sc['collaudoUrl'])`nUtenti di prova: le chiavi COLLAUDO_* del file ~/.claude/collaudo/$($voce.repo).json (i valori non si scrivono qui).") }
                catch { Write-Log 'WARN' "card $($card.Id): commento con gli indirizzi dell'ambiente di collaudo non scritto: $($_.Exception.Message)" }
            }
            if ($Az.Tipo -eq 'RiportaIndietro') {
                # D52: il commit di testa della PR con cui la card di chiusura e tornata indietro: un secondo ritorno per la stessa testa e un on-hold
                if (Get-Campo $Az 'Commit') { $sc['ritornoCommit'] = [string]$Az.Commit }
                [void](Add-AdoCommento -Id $card.Id -Testo "[smistatore] $($Az.Motivo)")
            }
        }
        # D52: il ramo della funzionalita su origin (lo crea da origin/develop se non c'e; se un altro smistatore e arrivato prima, e il suo). La
        # Feature l'ha letta il giro, nella cache del contesto: li si scrive anche il ramo, cosi la card dopo della stessa Feature,
        # nello stesso giro, non lo ricrea. Il ramo resta anche in K, per il CreaWorktree che segue.
        'CreaRamoFunzionalita' {
            $entrata = $K.Contesto.Funzionalita["$($Az.FeatureId)"]
            if ($null -eq $entrata -or -not $entrata.ContainsKey('Feature')) { throw "La Feature $($Az.FeatureId) non e fra quelle lette dal giro: non posso creare il ramo della funzionalita" }
            $ramo = Publish-RamoFunzionalita -Principale ([string]$voce.cartella) -Feature $entrata.Feature -TagBug ([string]$Cfg.Stati.tagBugFeature)
            $entrata.Ramo = $ramo
            $K['RamoFunzionalita'] = $ramo
            Write-Log 'INFO' "card $($card.Id): ramo della funzionalita $ramo (Feature $($Az.FeatureId))"
        }
        # D52: lo stato della Feature (la chiave di stati.json), anche nella cache del giro: la card dopo non lo riscrive.
        'AggiornaFeature' {
            # Lo stato della Feature e un riepilogo per chi guarda il backlog: se non si scrive la card non si ferma. Un errore va nel log, e
            # il giro dopo ritenta perche la Feature risulta ancora New.
            $nome = Get-NomeStato $Cfg $Az.Stato
            try {
                [void](Set-AdoStatoFeature -FeatureId ([int]$Az.FeatureId) -Stato $nome)
                # la card di chiusura ricorda la Feature da chiudere quando lei sara Closed (Close-FeatureConcluse); solo a scrittura riuscita,
                # cosi il giro dopo la riprova
                if (Get-Campo $Az 'DaChiudere') { $sc['featureDaChiudere'] = [int]$Az.FeatureId }
                $entrata = $K.Contesto.Funzionalita["$($Az.FeatureId)"]
                if ($null -ne $entrata -and $entrata.ContainsKey('Feature')) { $entrata.Feature.Stato = $nome }
                Write-Log 'INFO' "card $($card.Id): la Feature $($Az.FeatureId) e ora $nome"
            }
            catch { Write-Log 'ERRORE' "card $($card.Id): la Feature $($Az.FeatureId) non e passata in ${nome}: $($_.Exception.Message)" }
        }
        # D52, gruppo 5: la correzione che il responsabile ha scritto sulla card di chiusura diventa una Bug figlia della Feature (nell'area della
        # Feature, assegnata all'utente dello smistatore). Tecnica: nasce in New con il tag agenti. Di prodotto: resta in Draft e un commento che
        # menziona Titolare, come un on-hold, dice che la scelta e sua. La chiave (l'id del commento) si ricorda solo a Bug creata: se non si crea
        # la card va in on-hold (l'errore generico di Invoke-Azione) e, tolto il tag, si riprova.
        'CreaCorrezione' {
            $entrata = $K.Contesto.Funzionalita["$($Az.FeatureId)"]
            if ($null -eq $entrata -or -not $entrata.ContainsKey('Feature')) { throw "La Feature $($Az.FeatureId) non e fra quelle lette dal giro: non posso creare la Bug della correzione" }
            $correzione = [pscustomobject]@{ Id = [int]$Az.Chiave; Tipo = [string]$Az.Natura; Titolo = [string]$Az.Titolo; Descrizione = [string]$Az.Descrizione }
            # appena la Bug esiste (prima di tag e stato) la card di chiusura lo dice in un commento: l'idempotenza vale da ogni PC, e dopo
            # un errore a meta il nuovo tentativo non ne crea una seconda (stato locale: solo una scorciatoia)
            $segna = { param($b) Add-AdoCommento -Id $card.Id -Testo "[smistatore] $(ConvertTo-TestoCommentoBugCreata -Tipo 'correzione' -Chiave ([string]$Az.Chiave) -Bug ([int]$b.Id))" }
            $bug = New-CardCorrezioneFunzionalita -Config $Cfg -Feature $entrata.Feature -Chiusura ([int]$card.Id) -Correzione $correzione -AssegnataA ([string](Get-Campo $K.Io 'Email')) -DopoNascita $segna
            $sc['correzioniFatte'] = @(@($sc['correzioniFatte']) | Where-Object { $null -ne $_ }) + [string]$Az.Chiave
            Write-Log 'INFO' "card $($card.Id): correzione $($Az.Natura) '$($Az.Titolo)' (commento $($Az.Chiave)): creata la Bug $($bug.Id), figlia della Feature $($Az.FeatureId)"
            if ($Az.Natura -eq 'prodotto') {
                # un di piu: la Bug c'e e la chiave e salvata, un errore del commento va solo nel log
                try { [void](Add-AdoCommento -Id $bug.Id -Testo "[smistatore] Correzione di prodotto dalla card di chiusura #$($card.Id) (Feature $($Az.FeatureId)): richiede una scelta tua. La Bug resta in Draft: quando hai deciso, completa descrizione e criteri e portala in New." -Menziona $K.Titolare) }
                catch { Write-Log 'ERRORE' "card $($card.Id): commento sulla Bug $($bug.Id) non scritto: $($_.Exception.Message)" }
            }
        }
        # D52, gruppo 5: la PR della funzionalita verso develop e in conflitto: la Bug allinea-develop la crea lo smistatore, senza responsabile. Il
        # commit di testa della PR si ricorda (allineaFatti): una sola Bug per testa, anche se la validazione tarda ad aggiornarsi.
        'CreaAllineaDevelop' {
            $entrata = $K.Contesto.Funzionalita["$($Az.FeatureId)"]
            if ($null -eq $entrata -or -not $entrata.ContainsKey('Feature')) { throw "La Feature $($Az.FeatureId) non e fra quelle lette dal giro: non posso creare la Bug allinea-develop" }
            $segna = { param($b) Add-AdoCommento -Id $card.Id -Testo "[smistatore] $(ConvertTo-TestoCommentoBugCreata -Tipo 'allinea' -Chiave ([string]$Az.Commit) -Bug ([int]$b.Id))" }
            $bug = New-CardAllineaDevelop -Config $Cfg -Feature $entrata.Feature -Ramo ([string]$Az.Ramo) -AssegnataA ([string](Get-Campo $K.Io 'Email')) -DopoNascita $segna
            if ($Az.Commit) { $sc['allineaFatti'] = @(@($sc['allineaFatti']) | Where-Object { $null -ne $_ }) + [string]$Az.Commit }
            Write-Log 'INFO' "card $($card.Id): la PR $($Az.Ramo) verso develop ha conflitti: creata la card allinea-develop, Bug $($bug.Id), figlia della Feature $($Az.FeatureId)"
        }
        'CreaWorktree' {
            if ($Az.Contains('Base')) {
                # D52: card della funzionalita. Con Base vuota il ramo l'ha appena creato CreaRamoFunzionalita. La destinazione della PR
                # si salva qui: da questo momento e il solo posto in cui la si sa.
                $base = if ($Az.Base) { [string]$Az.Base } else { [string]$K['RamoFunzionalita'] }
                if (-not $base) { throw 'Il ramo della funzionalita non c e: non posso creare il worktree della card' }
                $wt = New-WorktreeCard -Voce $voce -Card $card -Base $base
                $sc['destinazione'] = $base
            }
            else { $wt = New-WorktreeCard -Voce $voce -Card $card }
            $sc['ramo'] = $wt.Ramo
            $sc['cartella'] = $wt.Cartella
        }
        # D52: la card di chiusura non ha un worktree: il suo ramo e quello della funzionalita, la destinazione develop, la cartella vuota.
        # Niente creazione ne rimozione di worktree, mai.
        'ImpostaRamoChiusura' {
            $ramo = [string]$Az.Ramo
            if (Get-Campo $Az 'DaPrCollegata') {
                # Ready to release senza stato locale: il ramo della funzionalita e gia cancellato dal merge, la PR collegata alla card lo ricorda
                $pr = Get-AdoPrCollegata -CardId $card.Id
                if ($null -eq $pr -or $pr.Stato -ne 'completed') { throw "La card di chiusura $($card.Id) e in Ready to release ma non ha una PR collegata completata: non so quale ramo guardare" }
                $ramo = [string]$pr.Ramo
                $sc['prId'] = [int]$pr.Id
            }
            $sc['ramo'] = $ramo
            $sc['destinazione'] = 'develop'
            $sc['cartella'] = $null
            Write-Log 'INFO' "card $($card.Id): card di chiusura, ramo $ramo (il worktree in sola lettura lo crea il lancio di un ruolo)"
        }
        'AdottaCard' {
            # card presa in carico da un altro PC: il lavoro e sul ramo pubblicato (spec, sezione 19)
            $chiaveStato = Get-ChiaveStato $Cfg.Stati $card.Stato
            # D52: una card della funzionalita porta la base (il ramo della funzionalita, vuota se non c'e su origin): il suo ramo
            # parte da li e la PR deve andarci, non su develop. In feature branch il worktree non c'e piu e non si ricrea.
            $conBase = $Az.Contains('Base')
            $wt = if ($chiaveStato -eq 'inFeature') { $null } else { New-WorktreeDaRemoto -Voce $voce -Card $card }
            if ($null -eq $wt) {
                # nessun ramo pubblicato della card
                if ($chiaveStato -in 'daRilasciare', 'inFeature') {
                    # dopo il merge Azure DevOps cancella il ramo: la card ricorda la sua PR
                    $pr = Get-AdoPrCollegata -CardId $card.Id
                    if ($null -eq $pr -or $pr.Stato -ne 'completed') { throw "Su origin non c'e nessun ramo della card $($card.Id) e nessuna PR collegata completata: non so cosa rilasciare" }
                    $sc['prId'] = [int]$pr.Id
                    # In feature branch la destinazione resta: il giro dopo la riconosce come card della funzionalita
                    if ($chiaveStato -eq 'inFeature' -and $conBase -and $Az.Base) { $sc['destinazione'] = [string]$Az.Base }
                    Write-Log 'INFO' "card $($card.Id): presa in carico gia $(if ($chiaveStato -eq 'inFeature') { 'unita nel ramo della funzionalita' } else { 'rilasciata' }) (PR $($pr.Id) completata), niente da fare"
                    return
                }
                if ($chiaveStato -ne 'inSviluppo') { throw "Su origin non c'e nessun ramo della card $($card.Id): in $($card.Stato) non c'e lavoro da riprendere. Riportare la card in Ready to develop" }
                # In development senza ramo pubblicato: non c'e lavoro da perdere, si riparte da develop (o dal ramo della funzionalita)
                if ($conBase -and -not $Az.Base) { throw "Il ramo della funzionalita non e su origin: non posso riprendere la card $($card.Id) da li" }
                $wt = if ($conBase) { New-WorktreeCard -Voce $voce -Card $card -Base ([string]$Az.Base) } else { New-WorktreeCard -Voce $voce -Card $card }
                $nota = "nessun ramo pubblicato: worktree nuovo da origin/$(if ($conBase) { $Az.Base } else { 'develop' }), ramo ``$($wt.Ramo)``."
            }
            else {
                # il ramo della card c'e su origin ma non quello della funzionalita: la PR andrebbe su develop, non si riprende cosi
                if ($conBase -and -not $Az.Base) { throw "Il ramo della funzionalita non e su origin: non posso riprendere la card $($card.Id), la sua PR andrebbe su develop" }
                $nota = "worktree ricreato dal ramo ``$($wt.Ramo)`` pubblicato su origin."
            }
            if ($conBase) { $sc['destinazione'] = [string]$Az.Base }
            $sc['ramo'] = $wt.Ramo
            $sc['cartella'] = $wt.Cartella
            Write-Log 'INFO' "card $($card.Id): presa in carico, $nota"
            # il commento e un di piu: il worktree c'e e lo stato e salvato, un suo errore va solo nel log
            try { [void](Add-AdoCommento -Id $card.Id -Testo "[smistatore] Card presa in carico da $($K.Io.Nome): $nota") }
            catch { Write-Log 'ERRORE' "card $($card.Id): commento della presa in carico non scritto: $($_.Exception.Message)" }
        }
        'RimuoviWorktree' {
            $destinazione = Get-DestinazioneCard $sc
            $r = Remove-WorktreeCard -Voce $voce -Id ([int]$card.Id) -Ramo ([string]$sc['ramo']) -Cartella ([string]$sc['cartella']) -Destinazione $destinazione
            $sc['cartella'] = $null
            # D52: la card di chiusura tiene il ramo salvato (serve a leggere la PR dopo il merge): il suo worktree e solo in sola lettura
            if (-not (Get-Campo $Az 'Chiusura')) { $sc['ramo'] = $null }
            Write-Log 'INFO' "card $($card.Id): worktree rimosso$(if (-not $r.RamoCancellato) { ", il ramo locale resta (non e in origin/$destinazione)" })"
        }
        'AccodaDeployTest' {
            if (-not $sc['ramo']) { throw 'La card non ha un ramo salvato: non posso accodare il deploy in Test' }
            if (-not (Get-Campo $voce 'pipelineDeploy')) { throw "La voce della mappa per $($voce.area) non ha 'pipelineDeploy': non posso accodare il deploy in Test" }
            # i parametri scelti dal responsabile e verificati da Decisioni sullo YAML del ramo (D43) a true, gli altri deploy* a false
            $parametri = @(@($Az.Parametri) | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object { [string]$_ })
            if ($parametri.Count -eq 0) { throw 'Nessun parametro di deploy scelto dal responsabile: non posso accodare il deploy in Test' }
            $spenti = @(@(Get-Campo $Az 'Spenti') | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object { [string]$_ })
            $run = Start-AdoDeployTest -Progetto $voce.progettoAdo -PipelineId ([int]$voce.pipelineDeploy) -Ramo ([string]$sc['ramo']) -Parametri $parametri -Spenti $spenti
            $sc['runId'] = [int]$run
            $sc['runDopoRev'] = [int]$Az.Rev
            # chi guarda la card trova il run da seguire (e un'eventuale approvazione che lo aspetta) e con quali parametri e partito
            [void](Add-AdoCommento -Id $card.Id -Testo "[smistatore] Deploy in Test accodato con $($parametri -join ', '): [run $run]($(Get-AdoUrlBuild -Progetto $voce.progettoAdo -Id ([int]$run)))")
        }
        # D59: l'ambiente Docker della card al posto del deploy in Test. Lo slot e il primo libero fra quelli delle altre card (una card che ha gia il suo
        # lo tiene: l'ambiente si ricrea sulle stesse porte). Il compose parte dal worktree della card; per la card di chiusura dal worktree in sola
        # lettura aggiornato al ramo della funzionalita (come per il collaudatore). Il processo che lo crea e staccato: l'esito si legge ai giri dopo.
        'CreaAmbienteCollaudo' {
            if ($Az.Chiusura) {
                if (-not $sc['ramo']) { throw 'La card di chiusura non ha un ramo salvato: non posso preparare il worktree dell ambiente di collaudo' }
                $sc['cartella'] = [string](Update-WorktreeChiusura -Voce $voce -Card $card -Ramo ([string]$sc['ramo'])).Cartella
            }
            $cartella = [string]$sc['cartella']
            if (-not $cartella -or -not (Test-Path -LiteralPath $cartella)) { throw "La card non ha un worktree utilizzabile (cartella salvata: '$cartella'): non posso creare l'ambiente di collaudo" }
            $slot = if ($sc['collaudoSlot']) { [int]$sc['collaudoSlot'] } else {
                $usati = @($K.Stato.Keys | Where-Object { $_ -ne "$($card.Id)" } | ForEach-Object { Get-Campo $K.Stato[$_] 'collaudoSlot' } | Where-Object { $null -ne $_ })
                Get-SlotCollaudoLibero -Usati $usati -Massimo ([int]$Cfg.Limiti.ambientiCollaudo)
            }
            if (-not $slot) { throw 'Nessuno slot libero per l ambiente di collaudo' }
            $credenziali = Join-Path $HOME ".claude/collaudo/$($voce.repo).json"
            $richiesta = New-RichiestaCollaudo -Config $Cfg.Collaudo -Voce $voce -Card ([int]$card.Id) -Slot $slot -Cartella $cartella -FileCollaudo $credenziali -CartellaDati $CartellaDati
            $avviato = Start-AmbienteCollaudo -Richiesta $richiesta
            $sc['collaudoSlot'] = [int]$slot
            $sc['collaudoProgetto'] = [string]$avviato.Progetto
            $sc['collaudoPid'] = [int]$avviato.Pid
            $sc['collaudoAvvio'] = [string]$avviato.Avvio
            $sc['collaudoUrl'] = $avviato.Url
            $sc['runDopoRev'] = [int]$Az.Rev
            Write-Log 'INFO' "card $($card.Id): ambiente di collaudo $($avviato.Progetto) in creazione (slot $slot), log $($avviato.Log)"
            [void](Add-AdoCommento -Id $card.Id -Testo '[smistatore] Ambiente di collaudo in creazione...')
        }
        'ButtaAmbienteCollaudo' {
            $progetto = if ($sc['collaudoProgetto']) { [string]$sc['collaudoProgetto'] } else { "card-$($card.Id)" }
            if (Remove-AmbienteCard $Cfg ([int]$card.Id) $sc) {
                Write-Log 'INFO' "card $($card.Id): ambiente di collaudo $progetto buttato"
                try { [void](Add-AdoCommento -Id $card.Id -Testo "[smistatore] Ambiente di collaudo buttato ($progetto).") }
                catch { Write-Log 'WARN' "card $($card.Id): commento dell'ambiente buttato non scritto: $($_.Exception.Message)" }
            }
            # un docker che non risponde non ferma la card: i campi restano e al giro dopo si riprova
            else { Write-Log 'WARN' "card $($card.Id): ambiente di collaudo $progetto non buttato (docker non risponde o ha dato un errore, vedi il log del progetto): riprovo al giro dopo" }
        }
        'CompletaPr' {
            # la PR su cui ha deciso Decisioni (attiva sul ramo); il prId salvato puo essere di una PR abbandonata
            $idPr = Get-Campo $K.Pr 'Id'
            if (-not $idPr) { $idPr = $sc['prId'] }
            if (-not $idPr) { throw 'Non so quale PR completare: la card non ha un prId salvato e nessuna PR attiva sul ramo' }
            # D52: sul commit di testa che Decisioni ha verificato (e, per la card di chiusura, confrontato con il deploy): se e cambiato dopo,
            # Azure DevOps rifiuta il completamento invece di unire un commit mai provato
            if (Get-Campo $Az 'Commit') { Complete-AdoPr -Progetto $voce.progettoAdo -Repo $voce.repo -Id ([int]$idPr) -Commit ([string]$Az.Commit) }
            else { Complete-AdoPr -Progetto $voce.progettoAdo -Repo $voce.repo -Id ([int]$idPr) }
            # Il completamento e asincrono: la card si sposta al giro in cui la PR risulta completata. Si ricorda la richiesta
            # per questo ingresso nello stato: se al giro dopo la PR e ancora aperta, la card si ferma con il motivo.
            $sc['completaPr'] = "$idPr@$($Az.Rev)"
            Write-Log 'INFO' "card $($card.Id): chiesto il completamento della PR $idPr"
        }
        'ApriPr' {
            if (-not $sc['ramo']) { throw 'La card non ha un ramo salvato: non posso aprire la PR' }
            # Sotto il link, il testo che dev ha salvato sulla card con descrizione-pr prima che la PR esistesse (se ci sta nel tetto)
            $descrizionePr = "[Card $($card.Id)]($(Get-AdoUrlCard -Id $card.Id)): $($card.Titolo)"
            $salvata = Get-DescrizionePrSalvata @(Get-AdoCommenti -Id $card.Id)
            if ($salvata) {
                $unita = "$descrizionePr`n`n$salvata"
                if ($unita.Length -le (Get-AdoLimiteTestoPr)) { $descrizionePr = $unita }
                else { Write-Log 'WARN' "card $($card.Id): la descrizione salvata sulla card non sta nel tetto della PR, la PR si apre senza" }
            }
            $id = New-AdoPr -Progetto $voce.progettoAdo -Repo $voce.repo -Ramo ([string]$sc['ramo']) -Titolo (Get-TitoloPr ([string]$sc['ramo']) $card.Titolo) `
                -Descrizione $descrizionePr -CardId $card.Id -Destinazione (Get-DestinazioneCard $sc)
            $sc['prId'] = [int]$id
        }
        'MettiInAttesa' {
            # La passata del responsabile in corso (attesaInEsame) e l'elenco delle passate fatte non si toccano: una passata
            # finita senza ESITO va in on-hold ma resta aperta, e la ripresa del responsabile la chiude (D42).
            Set-InAttesa $Cfg $card $sc $K.Titolare ([string]$Az.Motivo) $Az.Per
        }
        # D42: l'attesa che il responsabile sta guardando. Resta fino alla chiusura della passata: servono il motivo e il per
        # di prima, il ruolo che aveva lavorato per ultimo (la sessione del responsabile gli passa davanti) e la chiave del
        # tipo, che entra nell'elenco delle passate fatte.
        'AvviaPassataAttesa' {
            $sc['attesaInEsame'] = @{ motivo = [string]$Az.Motivo; per = $Az.Per; ruolo = $Az.Ruolo; chiave = [string]$Az.Chiave }
            $sc['passateFatte'] = @(@(Get-Campo $sc 'passateFatte') | Where-Object { $null -ne $_ }) + [string]$Az.Chiave
        }
        'ChiudiPassataAttesa' {
            $sc['attesaInEsame'] = $null
            $sc['ultimoRuolo'] = if ($Az.Ruolo) { [string]$Az.Ruolo } else { $null }
        }
        # una persona ha tolto l'on-hold: ogni tipo di attesa ha di nuovo la sua passata, e la sessione chiusa per silenzio o
        # morta ha di nuovo la sua ripresa automatica (D51)
        'AzzeraPassateAttesa' { $sc['passateFatte'] = @(); $sc['ripreseAutomatiche'] = 0 }
        # D51: l'on-hold che si toglie da solo perche la causa non c'e piu. Il giro dopo trova il tag tolto e riparte dalla
        # strada di sempre, con attesaToltaDaSmistatore che dice che non e stata una persona (le passate fatte restano).
        'TogliAttesa' {
            $tagAttesa = [string]$Cfg.Stati.tagAttesa
            [void](Set-AdoCard -Id $card.Id -TogliTag @($tagAttesa))
            [void](Add-AdoCommento -Id $card.Id -Testo "[smistatore] tolgo l'on-hold: $($Az.Causa)")
            $sc['inAttesaPer'] = $Az.Per
            $sc['attesaToltaDaSmistatore'] = $true
            $sc['causaAttesa'] = $null
            $card.Tag = @(@($card.Tag) | Where-Object { $_ -ne $tagAttesa })
            Write-Log 'INFO' "card $($card.Id): tolgo l'on-hold: $($Az.Causa) (ora inAttesaPer $($Az.Per))"
        }
        'Avvisa' {
            $chi = if ($Az.Chi -eq 'richiedente' -and $card.CreataDa -and $card.CreataDa.Id) { $card.CreataDa.Id } else { $K.Titolare }
            [void](Add-AdoCommento -Id $card.Id -Testo "[smistatore] $($Az.Testo)" -Menziona $chi)
            $sc['avvisi'] = @($sc['avvisi']) + [string]$Az.Chiave
        }
        'RilanciaScadute' {
            # D47: validazioni scadute perche develop e cambiato. Meccanica pura: nessun limite e nessun conto dei rilanci
            # di D38 (quello e per le rosse); al giro dopo la validazione risulta in corso e si aspetta.
            if (-not $sc['ramo']) { throw 'La card non ha un ramo salvato: non posso rilanciare le validazioni scadute della PR' }
            $n = Start-AdoRivalutazione -Progetto $voce.progettoAdo -Repo $voce.repo -Ramo ([string]$sc['ramo']) -Scadute -Destinazione (Get-DestinazioneCard $sc)
            Write-Log 'INFO' "card $($card.Id): rilanciate $n validazioni scadute della PR"
        }
        'RilanciaValidazione' {
            # D38: dev giudica instabile la validazione rossa. Lo smistatore ha il PAT pieno e la rilancia; dev no.
            if (-not $sc['ramo']) { throw 'La card non ha un ramo salvato: non posso rilanciare la validazione della PR' }
            $n = Start-AdoRivalutazione -Progetto $voce.progettoAdo -Repo $voce.repo -Ramo ([string]$sc['ramo']) -Destinazione (Get-DestinazioneCard $sc)
            # Anche con zero (qualcuno l'ha gia rilanciata a mano) si segna il rilancio: da qui si segue la PR.
            $sc['rilanci'] = [int](Get-Campo $sc 'rilanci') + 1
            $sc['rilancioDi'] = [string]$Az.Sessione
            $pr = Get-Campo $K.Pr 'Id'
            $link = if ($pr) { " della [PR $pr]($(Get-AdoUrlPr -Progetto $voce.progettoAdo -Repo $voce.repo -Id ([int]$pr)))" } else { '' }
            $testo = if ($n -gt 0) { "[smistatore] dev giudica instabile il test che ha fatto fallire la validazione$link`: validazione rilanciata ($n). Se torna rossa riparte dev." }
                else { "[smistatore] dev chiede di rilanciare la validazione$link, ma non c'era niente di rosso da rilanciare: si segue la PR." }
            try { [void](Add-AdoCommento -Id $card.Id -Testo $testo) }
            catch { Write-Log 'WARN' "card $($card.Id): commento del rilancio non scritto: $($_.Exception.Message)" }
            Write-Log 'INFO' "card $($card.Id): validazione rilanciata ($n valutazioni)"
        }
        # Il mentore non e la sessione della card: non tocca sessione, ultimoRuolo, ultimaSessione, inAttesaPer e non conta come
        # lancio (K.Lanciata). E un di piu: se non parte la card non va in on-hold, e la chiave non si segna cosi il giro dopo
        # riprova. Parte in una cartella sua e vuota (<dati>/mentori/<guid>), non nel worktree della card (per l'innesco bug il
        # giro dopo lo toglie, e su Windows la cartella di lavoro di un processo vivo non si cancella: la card andrebbe in
        # on-hold) ne nella copia principale del repo (e di chi ci lavora): il repo lo legge da la, con git -C in sola lettura.
        'LanciaMentore' {
            $cartella = Join-Path (Join-Path $CartellaDati 'mentori') ([guid]::NewGuid().ToString('N'))
            try {
                New-Item -ItemType Directory -Path $cartella -Force | Out-Null
                $righe = @("Card $($card.Id) nel repo $($voce.repo).", "Ruoli da istruire: $(@($Az.Ruoli) -join ', ').", "Chi ha corretto: $($Az.Correttore).",
                    "Innesco: $($Az.Innesco).", "memoria.ps1: $(Join-Path $Radice 'src/memoria.ps1')",
                    "Copia principale del repo (da leggere solo con git -C): $($voce.cartella)")
                $p = @{ Card = [int]$card.Id; Ruolo = 'mentore'; Messaggio = ($righe -join "`n"); Cartella = $cartella; Config = $Cfg; Radice = $Radice; CartellaDati = $CartellaDati }
                if ($Az.Testo) { $p['Allegato'] = [string]$Az.Testo }
                $r = Start-SessioneRuolo @p
            }
            catch {
                Remove-CartellaMentore $cartella
                Write-Log 'ERRORE' "card $($card.Id): il mentore ($($Az.Innesco), chiave $($Az.Chiave)) non e partito, riprovo al giro dopo: $($_.Exception.Message)"; return
            }
            $rc = $Cfg.Ruoli.mentore
            $sc['mentori'] = @(@($sc['mentori']) | Where-Object { $null -ne $_ }) + @(, @{ id = $r.Id; pid = $r.Pid; avvio = $r.Avvio; ruolo = 'mentore'; inizio = (Get-Adesso).ToString('o'); ripresa = $false; cartella = $cartella; modello = $rc.modello; sforzo = $rc.sforzo; motivo = [string]$Az.Innesco })
            $sc['mentoriFatti'] = @(@($sc['mentoriFatti']) | Where-Object { $null -ne $_ }) + [string]$Az.Chiave
            foreach ($ruoloIstruito in @($Az.Ruoli)) {
                Write-Apprendimento ([int]$card.Id) ([string]$voce.repo) 'correzione' ([string]$ruoloIstruito) "$($Az.Innesco): corretto da $($Az.Correttore)"
            }
            Write-Log 'INFO' "card $($card.Id): lanciato il mentore $($r.Id) ($($Az.Innesco), per $(@($Az.Ruoli) -join ', '))"
        }
        # i campi sono quelli che Get-Decisione ha gia azzerato per decidere (Get-CampiContatori): un elenco solo
        'AzzeraContatori' { $campi = Get-CampiContatori; foreach ($k in $campi.Keys) { $sc[$k] = $campi[$k] }; $sc['attesaToltaDaSmistatore'] = $null }
        # D52, gruppo 5: la CI della card di chiusura e tornata verde
        'AzzeraCiRosse' { $sc['ciRosseDiFila'] = 0 }
        # il run di deploy fallito si dimentica: l'azione dopo (AccodaDeployTest) ne salva uno nuovo
        'AzzeraDeploy' { $sc['runId'] = $null; $sc['runDopoRev'] = $null }
        default { throw "Azione sconosciuta: $($Az.Tipo)" }
    }
}

# D59: butta l'ambiente di una card: ferma il processo che lo sta creando (pid e avvio dello stato), poi down -v e i volumi. Solo a riuscita
# azzera i campi dello stato (lo slot resta suo finche docker non conferma). Vero se e stato buttato.
function Remove-AmbienteCard($Cfg, [int]$Id, $Sc) {
    $progetto = if ($Sc['collaudoProgetto']) { [string]$Sc['collaudoProgetto'] } else { "card-$Id" }
    if (-not (Remove-AmbienteCollaudo -Config $Cfg.Collaudo -Progetto $progetto -CartellaDati $CartellaDati -ProcessoId ([int]$Sc['collaudoPid']) -Avvio $Sc['collaudoAvvio'])) { return $false }
    Clear-StatoAmbienteCollaudo $Sc
    $true
}

# D59: i campi dello stato che dicono che la card ha un ambiente di collaudo; runDopoRev si dimentica con loro (valeva per quell'ambiente)
function Clear-StatoAmbienteCollaudo($Sc) {
    foreach ($k in 'collaudoSlot', 'collaudoProgetto', 'collaudoPid', 'collaudoAvvio', 'collaudoUrl', 'runDopoRev') { $Sc[$k] = $null }
}

# D59: a fine giro si buttano i progetti di collaudo (card-<id>) la cui card non e in uno stato di Test, o non c'e piu fra le attive. I progetti sono
# quelli che docker conosce (contenitori e volumi) e quelli che lo stato locale ricorda con uno slot (una build fallita e la card chiusa: niente
# contenitori, ma lo slot resta occupato finche non si libera qui). Gli ambienti sono sulla macchina di chi esegue, ma lo stato della card e quello di
# Azure DevOps. Senza voci collaudo nella mappa e senza ambienti nello stato non si chiede niente a docker. Un docker che non risponde e un avviso
# nel log: il giro non fallisce.
function Remove-AmbientiOrfani($Cfg, $Attive, $Stato) {
    $conStato = @($Stato.Keys | Where-Object { $null -ne $Stato[$_] -and ($Stato[$_]['collaudoSlot'] -or $Stato[$_]['collaudoProgetto']) })
    $conVoci = @($Cfg.Mappa.aree | Where-Object { Test-AmbienteCollaudo $_ }).Count -gt 0
    if (-not $conVoci -and $conStato.Count -eq 0) { return }
    $progetti = [System.Collections.Generic.SortedSet[string]]::new()
    if ($conVoci) {
        try { foreach ($p in @(Get-ProgettiCollaudo -Config $Cfg.Collaudo -CartellaDati $CartellaDati)) { [void]$progetti.Add([string]$p) } }
        catch { Write-Log 'WARN' "ambienti di collaudo orfani: non so quali ce ne sono in docker, non risponde ($($_.Exception.Message))" }
    }
    foreach ($k in $conStato) { [void]$progetti.Add("card-$k") }
    $inTest = @($Attive | Where-Object { (Get-ChiaveStato $Cfg.Stati $_.Stato) -in (Get-StatiInTest) } | ForEach-Object { [int]$_.Id })
    foreach ($progetto in $progetti) {
        $id = [int]($progetto -replace '^card-', '')
        if ($id -in $inTest) { continue }
        Write-Log 'INFO' "ambiente di collaudo orfano $progetto (la card $id non e in Test): lo butto"
        $buttato = if ($Stato.Contains("$id")) { Remove-AmbienteCard $Cfg $id $Stato["$id"] }
            else { Remove-AmbienteCollaudo -Config $Cfg.Collaudo -Progetto $progetto -CartellaDati $CartellaDati }
        if (-not $buttato) { Write-Log 'WARN' "ambiente di collaudo orfano $progetto non buttato: riprovo al giro dopo" }
    }
}

# Il worktree di una card ceduta a un collega (o tornata dopo una cessione): si toglie solo se pulito e pubblicato, e con
# lui il ramo locale se un ramo remoto lo contiene. Lancia un errore se non si puo.
function Remove-WorktreeCeduta($Cfg, $CardAdo, $VoceStato) {
    if (-not $VoceStato['cartella']) { return }
    $v = Find-VoceMappa -Mappa $Cfg.Mappa -Area $CardAdo.Area
    if (-not $v) { throw "l'area '$($CardAdo.Area)' non e nella mappa" }
    [void](Remove-WorktreeCard -Voce $v -Id ([int]$CardAdo.Id) -Ramo ([string]$VoceStato['ramo']) -Cartella ([string]$VoceStato['cartella']) -CancellaRamoPubblicato -Destinazione (Get-DestinazioneCard $VoceStato))
}

# D52: le card Closed non sono fra le attive, quindi il giro non le vede: la Feature di una card di chiusura unita in develop (Resolved) la
# ricorda featureDaChiudere nello stato della card, e qui, a ogni giro, si legge (una GET ciascuna) solo la card di chiusura di quelle
# Feature che non e piu fra le attive. Closed: anche la Feature passa Closed e esce dall'elenco. Removed: non c'e piu niente da chiudere.
# Un errore non ferma il giro: si riprova al prossimo.
function Close-FeatureConcluse($Cfg, $Stato, $PerId) {
    $cambiato = $false
    foreach ($chiave in @($Stato.Keys)) {
        if ($Card -and $chiave -ne "$Card") { continue }
        $voce = $Stato[$chiave]
        $featureId = if ($null -ne $voce) { Get-Campo $voce 'featureDaChiudere' } else { $null }
        if (-not $featureId -or $PerId.ContainsKey($chiave)) { continue }
        try {
            $c = Get-AdoCard -Id ([int]$chiave)
            $k = if ($c) { Get-ChiaveStato $Cfg.Stati ([string]$c.Stato) } else { $null }
            if ($k -notin 'chiusa', 'rimossa') {
                # ne attiva ne Closed (per esempio rimessa in Draft): la Feature resta Resolved e lo si dice una volta, non a ogni giro
                if ($c -and (Get-Campo $voce 'featureDaChiudereAvvisata') -ne [string]$c.Stato) {
                    if (-not $WhatIf) { $voce['featureDaChiudereAvvisata'] = [string]$c.Stato; $cambiato = $true }
                    Write-Log 'WARN' "card ${chiave}: e $($c.Stato), non Closed ne attiva: la Feature $featureId resta com'e finche la card non e Closed"
                }
                continue
            }
            if ($WhatIf) { Write-Prova "card ${chiave}: e $($c.Stato): $(if ($k -eq 'chiusa') { "chiuderei la Feature $featureId" } else { "smetterei di aspettare la chiusura della Feature $featureId" })"; continue }
            if ($k -eq 'chiusa') {
                # una Feature gia Removed (o gia Closed) non si riscrive
                $f = Get-AdoFeature -Id ([int]$featureId)
                if ($f.Stato -ieq [string]$Cfg.Stati.featureRimossa -or $f.Stato -ieq [string]$Cfg.Stati.featureChiusa) {
                    Write-Log 'INFO' "card ${chiave}: Closed, la Feature $featureId e gia $($f.Stato): non la tocco"
                }
                else {
                    [void](Set-AdoStatoFeature -FeatureId ([int]$featureId) -Stato ([string]$Cfg.Stati.featureChiusa))
                    Write-Log 'INFO' "card ${chiave}: Closed, la Feature $featureId e ora $($Cfg.Stati.featureChiusa)"
                }
            }
            else { Write-Log 'INFO' "card ${chiave}: Removed, la Feature $featureId non si chiude piu da qui" }
            $voce['featureDaChiudere'] = $null
            $voce['featureDaChiudereAvvisata'] = $null
            $cambiato = $true
        }
        catch { Write-Log 'WARN' "card ${chiave}: la Feature $featureId non si e potuta chiudere, riprovo al giro dopo: $($_.Exception.Message)" }
    }
    if ($cambiato) { Save-Stato -Stato $Stato -Percorso $script:PercorsoStato }
}

function Format-Azione($Az) {
    $campi = foreach ($k in $Az.Keys) { if ($k -ne 'Tipo' -and $null -ne $Az[$k] -and "$($Az[$k])" -ne '') { "$k=$($Az[$k])" } }
    "$($Az.Tipo) $(@($campi) -join ' ')".Trim()
}

# ---- il giro -----------------------------------------------------------------------------------------------------

function Invoke-GiroCompleto {
    $cfg = Get-Config -Radice $Radice -CartellaDati $CartellaDati
    if (-not $WhatIf) {
        $nomeGiro = Get-NomeGiro -CartellaDati $CartellaDati
        if (-not (Enter-Giro -Nome $nomeGiro)) { Write-Log 'INFO' 'Un altro giro e gia in corso: esco.'; return }
    }
    try {
        # L'utente dello smistatore: le card che fa avanzare sono solo le sue (spec, sezione 19). Il nome $titolare resta per
        # storia: e chi ha installato lo smistatore.
        $io = Get-AdoUtenteCorrente
        $titolare = [string]$io.Id
        Test-ScadenzaPat
        $stato = Get-Stato -Percorso $script:PercorsoStato
        $attive = @(Get-AdoCardAttive)
        $perId = @{}
        foreach ($c in $attive) { $perId["$($c.Id)"] = $c }
        $diMe = { param($c) Test-CardMia $c $titolare }

        # Passo 2: le sessioni che risultano nello stato
        foreach ($chiave in @($stato.Keys)) {
            if ($Card -and $chiave -ne "$Card") { continue }
            $voceStato = $stato[$chiave]
            if ($null -eq $voceStato) { continue }
            $haSessione = $null -ne $voceStato['sessione']
            $haMentori = @(@($voceStato['mentori']) | Where-Object { $null -ne $_ }).Count -gt 0
            if (-not $haSessione -and -not $haMentori) { continue }
            try {
                # Una card che non si legge (cancellata) o che non e piu nella mappa non impedisce di chiudere la sua sessione.
                $voce = $null
                $cardAdo = if ($perId.ContainsKey($chiave)) { $perId[$chiave] }
                else {
                    try { Get-AdoCard -Id ([int]$chiave) }
                    catch { Write-Log 'WARN' "card ${chiave}: non si legge ($($_.Exception.Message)): la sessione si chiude senza toccare la card"; $null }
                }
                $sc = Get-StatoCard -Stato $stato -Id ([int]$chiave)
                if ($cardAdo -and -not (& $diMe $cardAdo)) {
                    # La card ora e di un altro: niente on-hold, commenti o consumi su una card altrui. Una sessione ancora
                    # viva si ferma, perche il nuovo assegnatario lavora sullo stesso ramo (spec, sezione 19).
                    $s = $sc['sessione']
                    if ($haSessione -and -not $WhatIf -and (Test-SessioneViva -ProcessoId ([int]$s['pid']) -Avvio (Get-Campo $s 'avvio'))) {
                        Write-Log 'WARN' "card ${chiave}: non e piu assegnata a $($io.Nome): fermo la sessione $($s['id'])"
                        Stop-Sessione -ProcessoId ([int]$s['pid']) -Avvio (Get-Campo $s 'avvio')
                    }
                    $cardAdo = $null
                }
                if ($cardAdo) {
                    $voce = Find-VoceMappa -Mappa $cfg.Mappa -Area $cardAdo.Area
                    if (-not $voce) { Write-Log 'WARN' "card ${chiave}: l'area '$($cardAdo.Area)' non e nella mappa: la sessione si chiude senza toccare la card" }
                }
                if ($haSessione) { Close-Sessione $cfg ([int]$chiave) $cardAdo $voce $sc $titolare }
                if ($haMentori) { Close-Mentori $cfg ([int]$chiave) $cardAdo $voce $sc }
            }
            catch { Write-Log 'ERRORE' "card ${chiave}: chiusura della sessione non riuscita: $($_.Exception.Message)" }
            if (-not $WhatIf) { Save-Stato -Stato $stato -Percorso $script:PercorsoStato }
        }

        # Passo 2b: le card che erano mie e ora sono assegnate a un altro. Il worktree si toglie solo se pulito e
        # pubblicato, poi si dimentica la card: se torna mia, si riprende dal ramo remoto. Sulla card non si scrive
        # niente, non e piu mia. Una card senza assegnatario e ferma, non ceduta: il suo stato resta.
        foreach ($chiave in @($stato.Keys)) {
            if ($Card -and $chiave -ne "$Card") { continue }
            $voceStato = $stato[$chiave]
            if ($null -eq $voceStato -or -not $perId.ContainsKey($chiave)) { continue }
            $altra = $perId[$chiave]
            if ($null -eq (Get-Campo $altra 'AssegnataA') -or (& $diMe $altra)) { continue }
            if ($null -ne $voceStato['sessione']) { continue }   # una sessione ancora aperta si chiude prima, al passo 2
            if ($voceStato['ceduta']) { continue }              # pulizia gia tentata e fallita: si riprova se la card torna
            $chi = $altra.AssegnataA.Nome
            if ($WhatIf) { Write-Prova "card ${chiave}: ora e assegnata a ${chi}: toglierei il worktree e lo stato locale"; continue }
            try {
                # D59: l'ambiente di collaudo e sulla mia macchina e la card non e piu mia: si butta prima del worktree. Se non si butta il worktree resta e la
                # voce si segna ceduta (lo slot resta suo: le sue porte sono ancora occupate)
                if (($voceStato['collaudoSlot'] -or $voceStato['collaudoProgetto']) -and -not (Remove-AmbienteCard $cfg ([int]$chiave) $voceStato)) {
                    throw "l'ambiente di collaudo non si butta (docker non risponde o ha dato un errore)"
                }
                Remove-WorktreeCeduta $cfg $altra $voceStato
                # un mentore ancora aperto non si ferma (e in sola lettura), ma togliendo la voce i suoi consumi non
                # arriveranno piu sulla card: il log e l'unica traccia che ne resta
                foreach ($mentore in @($voceStato['mentori'] | Where-Object { $null -ne $_ })) {
                    Write-Log 'WARN' "card ${chiave}: ora e assegnata a ${chi}: il mentore $($mentore['id']) e ancora aperto e lo lascio andare, i suoi consumi non arriveranno sulla card"
                }
                $stato.Remove($chiave)
                Write-Log 'INFO' "card ${chiave}: ora e assegnata a ${chi}: tolti worktree e stato locale"
            }
            catch {
                # una volta sola: la voce resta, segnata, e al ritorno della card si decide li
                $voceStato['ceduta'] = $true
                Write-Log 'WARN' "card ${chiave}: ora e assegnata a ${chi}, ma il worktree resta: $($_.Exception.Message)"
            }
            Save-Stato -Stato $stato -Percorso $script:PercorsoStato
        }

        # Passo 2c (D52): le Feature la cui card di chiusura e Closed si chiudono.
        Close-FeatureConcluse $cfg $stato $perId

        # Le tabelle dei limiti per repo e per componente, su tutte le card attive (anche degli altri: le risorse sono comuni).
        # D60: le Feature aperte, per la pausa e per l'ordine. Se non si leggono il giro si ferma come per le card: senza, una
        # Feature in pausa ripartirebbe.
        $feature = @(Get-AdoFeatureAperte)
        $ctx = New-ContestoGiro $cfg $attive $titolare $script:PercorsoQuota $script:PercorsoSoglia $feature

        # D60: il sistema in pausa (impostazioni.json, dal pulsante della vista): le sessioni finite si sono chiuse al passo 2, ma non parte
        # niente e nessuna card si sposta. Lo dice il log a ogni giro.
        if ((Get-Impostazioni -CartellaDati $CartellaDati).Pausa) {
            Write-Log 'INFO' 'sistema in pausa (vista o impostazioni.json): nessuna card avanza'
            return
        }
        # Passo 3: le card
        # @() fuori dall'if: l'assegnazione di un if srotola l'array, e con zero card $daFare sarebbe $null.
        # D60: nell'ordine delle Feature nel backlog, cosi un posto libero va alla card della Feature piu in alto
        $daFare = @(if ($Card) { $attive | Where-Object { $_.Id -eq $Card } } else { Get-OrdineCard $attive $ctx.Feature })
        if ($Card -and $daFare.Count -eq 0) {
            $una = Get-AdoCard -Id $Card
            if ($una) { $daFare = @($una) }
        }
        foreach ($cardAdo in $daFare) {
            # solo le mie: una card di un altro la fa avanzare il suo smistatore, una senza assegnatario nessuno
            if (-not (& $diMe $cardAdo)) {
                if ($Card) { Write-Log 'INFO' "card $($cardAdo.Id): non e assegnata a $($io.Nome), non la tocco" }
                elseif ($null -eq (Get-Campo $cardAdo 'AssegnataA') -and $stato.Contains("$($cardAdo.Id)")) {
                    Write-Log 'WARN' "card $($cardAdo.Id): non ha un assegnatario, quindi e ferma: va assegnata dalla board"
                }
                continue
            }
            # tornata mia dopo una cessione la cui pulizia era fallita: il worktree vecchio non vale piu
            $vecchia = if ($stato.Contains("$($cardAdo.Id)")) { $stato["$($cardAdo.Id)"] } else { $null }
            if ($vecchia -and $vecchia['ceduta']) {
                if ($WhatIf) { Write-Prova "card $($cardAdo.Id): tornata assegnata a me dopo una cessione: toglierei il worktree vecchio"; continue }
                try {
                    Remove-WorktreeCeduta $cfg $cardAdo $vecchia
                    $stato.Remove("$($cardAdo.Id)")
                    Write-Log 'INFO' "card $($cardAdo.Id): tornata assegnata a me: tolto il worktree vecchio, al prossimo giro la riprendo dal ramo remoto"
                }
                catch {
                    try { Set-InAttesa $cfg $cardAdo $vecchia $titolare "La card e tornata assegnata a me, ma il worktree lasciato quando era passata a un altro non si puo togliere: $($_.Exception.Message)" $null }
                    catch { Write-Log 'ERRORE' (Format-RigaLog 'OnHoldFallito' @($cardAdo.Id, $_.Exception.Message)) }
                }
                Save-Stato -Stato $stato -Percorso $script:PercorsoStato
                continue
            }
            $voce = Find-VoceMappa -Mappa $cfg.Mappa -Area $cardAdo.Area
            if (-not $voce) {
                Write-Log 'INFO' "card $($cardAdo.Id): l'area '$($cardAdo.Area)' non e in config/mappa.json, non la tocco"
                continue
            }
            try {
                $sc = Get-StatoCard -Stato $stato -Id $cardAdo.Id
                Update-SessioniContesto $ctx $stato
                $snap = Get-IstantaneaCard $cfg $cardAdo $voce $sc $stato $script:PercorsoStato $ctx
                # la PR trovata si ricorda anche se non l'ha aperta questo smistatore (card presa in carico): serve a
                # riconoscere una card rilasciata, e alle card che la seguono
                if ($snap.Pr -and (Get-Campo $snap.Pr 'Id') -and -not $WhatIf) { $sc['prId'] = [int]$snap.Pr.Id }
                $decisione = Get-Decisione -Istantanea $snap -Contesto $ctx
                $azioni = @($decisione.Azioni)
                # una card che non parte per i predecessori, per il limite in Test o per quello di sessioni lascia una riga: dice perche
                # (il motivo quota no: vale per tutte le card e a ogni giro sarebbe rumore, lo dice una volta Close-Sessione)
                if ($decisione.Motivo -and $decisione.Motivo.Tipo -in 'predecessori', 'limiteTest', 'limiteAmbienti', 'limiteSessioni', 'funzionalitaIllegibile', 'funzionalitaPerduta', 'inFeatureSenzaPrUnita', 'senzaSorelle', 'conflittiFunzionalita', 'ciRossaFunzionalita', 'chiusuraInBozza') {
                    Write-Log 'INFO' "card $($cardAdo.Id): $(Format-MotivoCoda $decisione.Motivo)"
                }
            }
            catch { Write-Log 'ERRORE' (Format-RigaLog 'LetturaNonRiuscita' @($cardAdo.Id, $_.Exception.Message)); continue }

            if ($WhatIf) {
                foreach ($a in $azioni) { Write-Prova "card $($cardAdo.Id) ($($cardAdo.Stato)): $(Format-Azione $a)" }
                continue
            }

            $k = @{ Card = $cardAdo; Sc = $sc; Stato = $stato; Voce = $voce; Pr = $snap.Pr; Task = $snap.Task; Contesto = $ctx; Titolare = $titolare; Io = $io; Lanciata = $false }
            foreach ($a in $azioni) {
                try { Invoke-Azione $cfg $k $a }
                catch {
                    $msg = $_.Exception.Message
                    Write-Log 'ERRORE' (Format-RigaLog 'AzioneFallita' @($cardAdo.Id, $a.Tipo, $msg))
                    # D42: il responsabile della passata non e partito. La passata non conta: al giro dopo riparte.
                    if ($a.Tipo -eq 'LanciaSessione' -and $a.Motivo -eq 'attesa') { Undo-PassataAttesa $sc }
                    try { Set-InAttesa $cfg $cardAdo $sc $titolare "L'azione $($a.Tipo) e fallita: $msg" $null }
                    catch { Write-Log 'ERRORE' (Format-RigaLog 'OnHoldFallito' @($cardAdo.Id, $_.Exception.Message)) }
                    break
                }
            }

            # ultimoCommento avanza solo se i commenti nuovi sono stati consumati: una sessione lanciata sulla card,
            # oppure tutti di agenti. Se un limite ha bloccato le azioni, il commento di una persona resta nuovo.
            $nuovi = @($snap.Commenti)
            if ($nuovi.Count -gt 0) {
                $tuttiDiAgenti = @($nuovi | Where-Object { Test-CommentoDiPersona $_ }).Count -eq 0
                if ($k.Lanciata -or $tuttiDiAgenti) {
                    $sc['ultimoCommento'] = [int](($nuovi | ForEach-Object { [int]$_.Id } | Measure-Object -Maximum).Maximum)
                }
            }
            Save-Stato -Stato $stato -Percorso $script:PercorsoStato
        }
        if (-not $WhatIf) {
            if (-not $Card) { Remove-AmbientiOrfani $cfg $attive $stato }
            Save-Stato -Stato $stato -Percorso $script:PercorsoStato
        }
    }
    finally {
        if (-not $WhatIf) { Exit-Giro -Nome $nomeGiro }
    }
}

# Il PAT dello smistatore in scadenza: se pat-info.json dice che scade entro 7 giorni, una riga di log una volta sola per quella
# scadenza (il file pat-scadenza-avvisata ne tiene la data: dopo il rinnovo la data cambia e la riga riparte). L'avviso a
# Titolare lo manda il supervisore (D51), che legge pat-info.json da solo: questa riga e solo traccia nel log. Un errore qui non
# ferma il giro.
function Test-ScadenzaPat {
    try {
        if (-not (Test-Path -LiteralPath $PercorsoPatInfo)) { return }
        $info = Get-Content -LiteralPath $PercorsoPatInfo -Raw | ConvertFrom-Json
        $validTo = [string](Get-Campo (Get-Campo $info 'smistatore') 'validTo')
        $scadenza = ConvertTo-DataUtc $validTo
        if ($null -eq $scadenza -or $scadenza -gt [datetime]::UtcNow.AddDays(7)) { return }
        if ($WhatIf) { return }
        $segno = Join-Path $CartellaDati 'pat-scadenza-avvisata'
        if ((Test-Path -LiteralPath $segno) -and ((Get-Content -LiteralPath $segno -Raw).Trim() -eq $validTo)) { return }
        $data = $scadenza.ToLocalTime().ToString('dd/MM/yyyy')
        Write-Log 'AVVISO' (Format-RigaLog 'PatInScadenza' @($data))
        if (-not (Test-Path -LiteralPath $CartellaDati)) { New-Item -ItemType Directory -Path $CartellaDati -Force | Out-Null }
        [IO.File]::WriteAllText($segno, $validTo, [Text.UTF8Encoding]::new($false))
    }
    catch { Write-Log 'ERRORE' "controllo della scadenza del PAT: $($_.Exception.Message)" }
}

try { Invoke-GiroCompleto }
catch {
    # un 401 e un PAT scaduto o revocato: il messaggio dice gia cosa fare
    if ($_.Exception.Message -match 'PAT scaduto o revocato') {
        # il supervisore (D51) riconosce questa riga e avvisa: qui basta che nel log ci sia, con il testo che dice cosa fare
        Write-Log 'ERRORE' (Format-RigaLog 'GiroFermato' @($_.Exception.Message))
    }
    else { Write-Log 'ERRORE' (Format-RigaLog 'GiroInterrotto' @($_.Exception.Message)) }
    # D53: il giro di prova a vuoto e la verifica di una versione appena aggiornata: un giro che si interrompe non deve uscire con 0.
    # Fuori da -WhatIf il codice resta quello di sempre (l'attivita pianificata non segna in errore un giro che ha scritto il suo log).
    if ($WhatIf) { exit 1 }
}
