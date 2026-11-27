Set-StrictMode -Version Latest

# I fatti che servono a piu moduli e stanno qui una volta sola: la cartella dei dati locali, la lettura di un campo,
# la lettura di una data, il passaggio dal nome di uno stato alla sua chiave di config/stati.json.

# La cartella dati e una sola per lo smistatore, per card.ps1 e per gli avvisi. Chi lancia una sessione imposta
# ATTREZZI_DATI nel processo figlio: cosi card.ps1 scrive dove lo smistatore legge, anche con -CartellaDati.
function Get-CartellaDati {
    if (-not [string]::IsNullOrWhiteSpace($env:ATTREZZI_DATI)) { return $env:ATTREZZI_DATI }
    Join-Path $env:LOCALAPPDATA 'DevOps.Agents'
}

# Un campo di un oggetto o di un dizionario; null se non c'e.
function Get-Campo($Oggetto, [string]$Nome) {
    if ($null -eq $Oggetto) { return $null }
    if ($Oggetto -is [System.Collections.IDictionary]) {
        if ($Oggetto.Contains($Nome)) { return $Oggetto[$Nome] }
        return $null
    }
    $p = $Oggetto.PSObject.Properties[$Nome]
    if ($p) { return $p.Value }
    $null
}

# Una data come DateTime UTC; una stringa senza fuso si legge come UTC. Null se vuota o illeggibile.
function ConvertTo-DataUtc($Valore) {
    if ($null -eq $Valore -or "$Valore" -eq '') { return $null }
    if ($Valore -is [datetime]) { return $Valore.ToUniversalTime() }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse("$Valore", [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d }
    $null
}

# I ruoli che lavorano una card, nell'ordine del flusso: chi la prende per primo e chi per ultimo. La vista ne fa le colonne degli agenti;
# l'ufficio ci riconosce una consegna in avanti da un rimando indietro. Un ruolo fuori da qui (mentore, supervisore) non e nel flusso.
function Get-RuoliFlusso { @('responsabile', 'dev', 'reviewer', 'collaudatore') }

# Dal nome vero di uno stato alla chiave di stati.json. Le chiavi tag* sono nomi di tag e le task* stati dei task: non sono stati di card.
function Get-ChiaveStato($Stati, [string]$Nome) {
    if (-not $Nome) { return $null }
    $chiavi = if ($Stati -is [System.Collections.IDictionary]) { @($Stati.Keys) } else { @($Stati.PSObject.Properties.Name) }
    foreach ($k in $chiavi) {
        if ($k -like 'tag*' -or $k -like 'task*' -or $k -like 'feature*') { continue }
        if ((Get-Campo $Stati $k) -ieq $Nome) { return $k }
    }
    $null
}

# I tre stati in cui una card sta sull'ambiente di Test (chiavi di config/stati.json), nell'ordine del flusso: il deploy, la
# prova del collaudatore, la prova di una persona. L'ambiente e uno, quindi per i limiti contano tutti e tre allo stesso modo.
# E la sola definizione: chi deve chiedere "e in Test?" usa questa.
function Get-StatiInTest { @('inDeployTest', 'inCollaudo', 'inProvaUmana') }

# Gli stati in cui la card ha un ramo (e un worktree) che avanza verso develop: da In development a Ready to release. In feature
# branch (D52) e la card della funzionalita con la PR gia unita nel ramo della funzionalita: il worktree c'e ancora finche
# RimuoviWorktree non lo toglie.
function Get-StatiConRamo { @('inSviluppo', 'inRevisione') + @(Get-StatiInTest) + @('daUnire', 'inFeature', 'daDeployTest', 'daRilasciare') }

# Il ramo verso cui va la PR della card (D52): quello salvato nello stato della card alla creazione del worktree (il ramo della
# funzionalita), develop per le card isolate e per lo stato di prima di D52, che non lo ha. E il solo posto da cui ApriPr, la lettura
# della PR, RimuoviWorktree e la sessione di dev e reviewer (ATTREZZI_BASE) sanno la destinazione.
function Get-DestinazioneCard($Sc) {
    $d = Get-Campo $Sc 'destinazione'
    if ([string]::IsNullOrWhiteSpace("$d")) { 'develop' } else { [string]$d }
}

# D52: il nome dei rami della funzionalita, in un posto solo: feature/f<id Feature>-<slug>, o bugfix/f<id>-<slug> per una correzione.
# Chi crea il nome (Worktree), chi lo cerca su origin per id (Ado, Worktree) e chi lo riconosce parte da qui.
function Get-PrefissiRamoFunzionalita { @('feature', 'bugfix') }
function Get-PrefissoRamoFunzionalita([switch]$Correzione) { if ($Correzione) { 'bugfix' } else { 'feature' } }
function Get-SiglaFunzionalita([int]$IdFeature) { "f$IdFeature" }
# La regex del nome completo di un ramo della Feature (con o senza slug). -Radice: un testo prima del nome (es. 'origin/').
function Get-RegexRamoFunzionalita([int]$IdFeature, [string]$Radice = '') {
    "^$([regex]::Escape($Radice))($((Get-PrefissiRamoFunzionalita) -join '|'))/$(Get-SiglaFunzionalita $IdFeature)(-.*)?$"
}

# D52: com'e fatta una funzionalita, dalle figlie della Feature (id, stato, tag). La card di chiusura e la figlia con il tag
# tagChiusura (la prima per id, se ce ne fosse piu d'una) fra quelle non Removed; le sorelle sono le altre figlie non Removed.
# Null senza card di chiusura: la Feature non e una funzionalita D52 (e una Feature della spec, sezione 18). E il solo posto
# dove si decide cos'e la chiusura: lo usano chi legge la funzionalita di una card e chi crea le card della funzionalita.
function Get-ComposizioneFunzionalita($Stati, $Figli) {
    $vive = @(@($Figli) | Where-Object { $null -ne $_ -and $_.Stato -ine $Stati.rimossa })
    $chiusura = $vive | Where-Object { @($_.Tag) -contains [string]$Stati.tagChiusura } | Sort-Object Id | Select-Object -First 1
    if ($null -eq $chiusura) { return $null }
    # le sorelle sono card: una figlia di un altro tipo (un Task, un Issue) non va in nessuno stato che la card di chiusura aspetta
    @{ Chiusura = $chiusura; Sorelle = @($vive | Where-Object { $_.Id -ne $chiusura.Id -and $_.Tipo -in 'User Story', 'Bug' }) }
}

# L'operazione pianificata che lancia lo smistatore: un solo posto per il suo nome, per chi la registra, la toglie e ne legge
# il prossimo giro.
function Get-OperazionePianificata {
    @{ Percorso = '\DevOps.Agents\'; Nome = 'Smistatore' }
}

# I nomi delle attivita pianificate nello stesso percorso: lo smistatore, la vista e il supervisore (D51). Chi le registra, le
# toglie o le controlla li prende da qui.
function Get-NomiOperazioniPianificate {
    @{ Smistatore = 'Smistatore'; Vista = 'Vista'; Supervisore = 'Supervisore' }
}

# ---- le righe di log che il supervisore riconosce ------------------------------------------------------------------
# Chi le scrive (lo smistatore) e chi le legge (il supervisore, D51) usano gli stessi modelli: {0}, {1}... sono i valori. Il
# lettore ne ricava l'espressione regolare dal modello stesso, cosi un testo cambiato da una parte cambia anche dall'altra
# (tests/Supervisione.Tests.ps1 lega i due).
$script:ModelliRigheLog = [ordered]@{
    OnHold             = 'card {0}: on-hold: {1} (per {2})'
    OnHoldFallito      = "card {0}: nemmeno l'on-hold e riuscito: {1}"
    LetturaNonRiuscita = 'card {0}: lettura non riuscita, la salto in questo giro: {1}'
    AzioneFallita      = "card {0}: l'azione {1} e fallita: {2}"
    GiroInterrotto     = 'giro interrotto: {0}'
    GiroFermato        = 'giro fermato: {0}'
    PatInScadenza      = 'il PAT scade il {0}: rilancia setup/Install-Attrezzi.ps1 -Pat'
}
# Il messaggio di un 401 (lo scrive Invoke-Ado) e come lo si riconosce nel log (anche nel testo originale di .NET).
$script:TestoPatScaduto = 'PAT scaduto o revocato: rilancia setup/Install-Attrezzi.ps1 -Pat'
$script:RegexPatRifiutato = 'PAT scaduto o revocato|401 \(Unauthorized\)'

function Get-TestoPatScaduto { $script:TestoPatScaduto }
function Get-RegexPatRifiutato { $script:RegexPatRifiutato }

# Il testo di una riga di log (senza data e livello) dal suo modello.
function Format-RigaLog([Parameter(Mandatory)][string]$Modello, [object[]]$Valori = @()) {
    if (-not $script:ModelliRigheLog.Contains($Modello)) { throw "Modello di riga di log sconosciuto: '$Modello'" }
    $script:ModelliRigheLog[$Modello] -f @($Valori | ForEach-Object { [string]$_ })
}

# L'espressione regolare che riconosce quel modello (con un gruppo per ogni valore), ancorata all'inizio del testo.
function Get-RegexRigaLog([Parameter(Mandatory)][string]$Modello) {
    if (-not $script:ModelliRigheLog.Contains($Modello)) { throw "Modello di riga di log sconosciuto: '$Modello'" }
    $m = $script:ModelliRigheLog[$Modello]
    $pezzi = [regex]::Split($m, '(\{\d+\})')
    $re = ($pezzi | ForEach-Object { if ($_ -match '^\{\d+\}$') { '(.*?)' } else { [regex]::Escape($_) } }) -join ''
    "^$re$"
}

function Get-NomiModelliRigaLog { @($script:ModelliRigheLog.Keys) }

# Il file di un PAT: cifrato con DPAPI (ConvertFrom-SecureString senza chiave, legato all'utente Windows) oppure in chiaro.
# Prova a decifrarlo; se non e cifrato usa il contenuto com'e, cosi il pat.txt in chiaro di prima continua a funzionare.
# Restituisce il valore, o una stringa vuota se il file non c'e. Il valore non si stampa mai: chi chiama lo tiene in memoria.
function Read-FilePat([string]$Percorso) {
    if (-not (Test-Path -LiteralPath $Percorso)) { return '' }
    $testo = (Get-Content -LiteralPath $Percorso -Raw)
    if ($null -eq $testo) { return '' }
    $testo = $testo.Trim()
    if ($testo -eq '') { return '' }
    try {
        $sicuro = ConvertTo-SecureString -String $testo -ErrorAction Stop
        return (New-Object System.Net.NetworkCredential('', $sicuro)).Password
    }
    catch {
        # l'intestazione DPAPI: un file cifrato che non si decifra (altro utente Windows, altro PC) non e un PAT in chiaro
        if ($testo -match '^01000000d08c9ddf') {
            throw 'file PAT cifrato ma non decifrabile da questo utente Windows: rilancia setup/Install-Attrezzi.ps1 -Pat'
        }
        return $testo
    }
}

# I registri jsonl (registro-sessioni.jsonl, registro-apprendimento.jsonl): una riga JSON per evento, solo aggiunta, perche li
# scrivono processi diversi (smistatore, card.ps1, mentore) e due processi che riscrivono lo stesso file si cancellano le
# scritture. Chi scrive passa la riga gia in JSON; la cartella si crea se manca.
function Add-RigaRegistro([string]$Percorso, [string]$Json) {
    $cartella = Split-Path -Parent $Percorso
    if ($cartella -and -not (Test-Path -LiteralPath $cartella)) { New-Item -ItemType Directory -Path $cartella -Force | Out-Null }
    [IO.File]::AppendAllText($Percorso, $Json + "`n", [Text.UTF8Encoding]::new($false))
}

# Le righe di un file letto mentre il processo che lo scrive lo tiene ancora aperto (l'uscita di una sessione, un registro).
function Read-RigheCondivise([string]$Percorso) {
    $fs = [IO.File]::Open($Percorso, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $sr = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
        $sr.ReadToEnd() -split "`r?`n"
    }
    finally { $fs.Dispose() }
}

# I file dei PAT: -Pat scrive pat-smistatore.txt e pat-smistatore-lettura.txt e non tocca mai pat.txt (dell'utente, anche in
# chiaro, per i suoi az interattivi) ne pat-read-only.txt. Chi legge prende il nome nuovo se c'e, altrimenti quello di prima,
# cosi le installazioni di oggi continuano a funzionare. E la sola scelta: tipo 'smistatore' o 'lettura'.
function Get-NomiFilePat([ValidateSet('smistatore', 'lettura')][string]$Tipo) {
    if ($Tipo -eq 'smistatore') { [pscustomobject]@{ Nuovo = 'pat-smistatore.txt'; Vecchio = 'pat.txt' } }
    else { [pscustomobject]@{ Nuovo = 'pat-smistatore-lettura.txt'; Vecchio = 'pat-read-only.txt' } }
}
function Get-PercorsoFilePat([ValidateSet('smistatore', 'lettura')][string]$Tipo, [string]$ClaudeDir = (Join-Path $HOME '.claude')) {
    $n = Get-NomiFilePat $Tipo
    $nuovo = Join-Path $ClaudeDir $n.Nuovo
    if (Test-Path -LiteralPath $nuovo) { return $nuovo }
    Join-Path $ClaudeDir $n.Vecchio
}

# Scrive un PAT cifrato con DPAPI: solo l'utente Windows che lo scrive lo puo rileggere, su questo PC.
function Write-FilePat([string]$Percorso, [string]$Valore) {
    $dir = Split-Path -Parent $Percorso
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $cifrato = ConvertTo-SecureString -String $Valore -AsPlainText -Force | ConvertFrom-SecureString
    [IO.File]::WriteAllText($Percorso, $cifrato, [Text.UTF8Encoding]::new($false))
}

# Il file di log dello smistatore per un giorno: uno per giorno, nella cartella log dei dati. Lo scrive lo smistatore, lo legge la vista.
function Get-FileLog([string]$CartellaDati, [datetime]$Giorno) {
    Join-Path (Join-Path $CartellaDati 'log') ('smistatore-{0}.log' -f $Giorno.ToString('yyyy-MM-dd'))
}

# ---- il deploy in Test scelto dal responsabile (D43) -------------------------------------------------------------
# Il responsabile sceglie i parametri del deploy in Test con card.ps1 deploy, che scrive un commento sulla card; lo smistatore
# lo rilegge per accodare la run. Il commento e il solo posto in cui la scelta vive: si vede sulla card e vale da ogni PC.
# Il formato sta qui, una volta sola: la prima riga dopo il prefisso [responsabile] e la marca seguita dai nomi, poi il perche.
$script:MarcaDeploy = 'Parametri del deploy in Test:'

# Il testo del commento, senza prefisso e firma (li mette Add-CardCommento).
function ConvertTo-TestoCommentoDeploy([string[]]$Parametri, [string]$Perche) {
    "$script:MarcaDeploy $(@($Parametri) -join ', ')`n`nPerche: $($Perche.Trim())"
}

# D59: gli URL dell'ambiente di collaudo di una card, "nome: url" uno per riga (da una tabella nome -> url, o dal suo salvataggio nello stato). Una
# riga sola per tutti i punti che li mostrano: il commento sulla card e l'allegato del collaudatore.
function ConvertTo-ElencoUrlCollaudo($Url) {
    if ($null -eq $Url) { return '' }
    $chiavi = if ($Url -is [System.Collections.IDictionary]) { @($Url.Keys) } else { @($Url.PSObject.Properties.Name) }
    (@($chiavi | ForEach-Object { "- ${_}: $(Get-Campo $Url $_)" })) -join "`n"
}

# D59: la voce della mappa ha l'ambiente di collaudo: il Test non e un deploy ma un ambiente Docker per card. Una definizione sola, per
# le decisioni (Decisioni.psm1) e per card.ps1 (che non chiede una scelta di deploy a un componente cosi).
function Test-AmbienteCollaudo($Voce) { $null -ne (Get-Campo $Voce 'collaudo') }

# D59: il processo e quello che abbiamo lanciato noi: stesso PID e stesso orario di avvio (margine di due secondi per gli arrotondamenti).
# Un PID da solo non basta: dopo un riavvio del PC puo essere di un altro programma. Chi vuole anche l'eseguibile lo controlla dopo.
function Test-ProcessoAvviato([int]$ProcessoId, $Avvio) {
    if ($ProcessoId -le 0 -or "$Avvio" -eq '') { return $false }
    $atteso = ConvertTo-DataUtc $Avvio
    if ($null -eq $atteso) { return $false }
    $p = Get-Process -Id $ProcessoId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    try {
        if ($p.HasExited) { return $false }
        [math]::Abs(($p.StartTime.ToUniversalTime() - $atteso).TotalSeconds) -le 2
    }
    catch { $false }   # processo scomparso nel frattempo, o non leggibile: non e il nostro
}

# I parametri dell'ultimo commento di deploy del responsabile (nell'ordine degli id), niente se non ce n'e o se non ha nomi:
# chi lo legge lo racchiude in @(). Il testo puo arrivare in html: si toglie, come in Get-UltimoCommentoDiRuolo.
# Valgono solo i commenti [responsabile] che si aprono con la marca: la scelta e sua, non dello smistatore ne di una persona.
function Get-SceltaDeploy($Commenti) {
    $marca = [regex]::Escape($script:MarcaDeploy)
    $scelta = $null
    foreach ($c in @(@($Commenti) | Where-Object { $null -ne $_ } | Sort-Object { [int](Get-Campo $_ 'Id') })) {
        $t = ConvertTo-TestoSempliceCommento (Get-Campo $c 'Testo')
        $prima = ($t -split '\r?\n', 2)[0]
        if ($prima -notmatch "^\[responsabile\]\s*$marca(.*)$") { continue }
        $scelta = @(($Matches[1] -replace '[`*]', '') -split '[,\s]+' | Where-Object { $_ })
    }
    if ($null -ne $scelta) { $scelta }   # niente, e non un $null: @() di un $null avrebbe un elemento
}

# Il testo di un commento come semplice testo: Azure DevOps puo restituirlo in html (a capo e blocchi diventano righe, i tag spariscono).
function ConvertTo-TestoSempliceCommento($Testo) {
    $h = "$Testo" -replace '(?i)<br\s*/?>', "`n" -replace '(?i)</(?:div|p|li|ul|ol|h[1-6]|tr|table|blockquote|pre)\s*>', "`n"
    [System.Net.WebUtility]::HtmlDecode(($h -replace '<[^>]*>', '')).TrimStart()
}

# ---- la descrizione della PR scritta prima che la PR esista ---------------------------------------------------------
# card.ps1 descrizione-pr senza una PR attiva salva il testo in un commento sulla card, con la marca; lo smistatore, aprendo
# la PR, lo mette sotto il link alla card. Il commento e il solo posto in cui il testo vive (come per il deploy).
$script:MarcaDescrizionePr = 'Descrizione della PR:'

# Il testo del commento, senza prefisso e firma (li mette Add-CardCommento).
function ConvertTo-TestoCommentoDescrizionePr([string]$Testo) {
    "$script:MarcaDescrizionePr`n`n$($Testo.Trim())"
}

# L'ultimo testo salvato (nell'ordine degli id) da dev o responsabile, senza marca ne firma; niente se non ce n'e.
function Get-DescrizionePrSalvata($Commenti) {
    $marca = [regex]::Escape($script:MarcaDescrizionePr)
    $testo = $null
    foreach ($c in @(@($Commenti) | Where-Object { $null -ne $_ } | Sort-Object { [int](Get-Campo $_ 'Id') })) {
        $t = ConvertTo-TestoSempliceCommento (Get-Campo $c 'Testo')
        foreach ($ruolo in 'dev', 'responsabile') {
            if ($t -notmatch "^\[$ruolo\]\s*$marca\s*\r?\n+") { continue }
            $corpo = $t.Substring($Matches[0].Length).TrimEnd()
            $firma = Get-FirmaCommento $ruolo
            if ($corpo.EndsWith($firma)) { $corpo = $corpo.Substring(0, $corpo.Length - $firma.Length).TrimEnd() }
            if ($corpo) { $testo = $corpo }
        }
    }
    if ($null -ne $testo) { $testo }
}

# ---- la correzione scritta dal responsabile della card di chiusura (D52, gruppo 5) -------------------------------------
# Il responsabile scrive la correzione con card.ps1 correzione, che lascia un commento sulla card di chiusura; lo smistatore lo
# rilegge e ne fa una Bug figlia della Feature. Come per il deploy il formato sta qui, una volta sola: la prima riga dopo il
# prefisso [responsabile] e la marca seguita dalla natura (tecnico o prodotto), la seconda il titolo, poi la descrizione.
$script:MarcaCorrezione = 'Correzione:'
$script:MarcaTitoloCorrezione = 'Titolo:'
$script:NatureCorrezione = @('tecnico', 'prodotto')

function Get-NatureCorrezione { $script:NatureCorrezione }

# Il testo del commento, senza prefisso e firma (li mette Add-CardCommento).
function ConvertTo-TestoCommentoCorrezione([string]$Tipo, [string]$Titolo, [string]$Descrizione) {
    "$script:MarcaCorrezione $Tipo`n$script:MarcaTitoloCorrezione $($Titolo.Trim())`n`n$($Descrizione.Trim())"
}

# Le correzioni scritte nei commenti, nell'ordine degli id: Id del commento (la chiave con cui si ricorda che la Bug c'e), Tipo,
# Titolo e Descrizione. Niente se non ce n'e: chi le legge le racchiude in @(). Valgono solo i commenti [responsabile] che si aprono
# con la marca e hanno una natura valida e un titolo: la correzione e sua, non dello smistatore ne di una persona.
function Get-CorrezioniScritte($Commenti) {
    $marca = [regex]::Escape($script:MarcaCorrezione)
    $marcaTitolo = [regex]::Escape($script:MarcaTitoloCorrezione)
    $nature = $script:NatureCorrezione -join '|'
    $firma = '^\s*' + [regex]::Escape((Get-FirmaCommento 'responsabile')) + '\s*$'
    foreach ($c in @(@($Commenti) | Where-Object { $null -ne $_ } | Sort-Object { [int](Get-Campo $_ 'Id') })) {
        $righe = @((ConvertTo-TestoSempliceCommento (Get-Campo $c 'Testo')) -split '\r?\n')
        if ($righe[0] -notmatch "^\[responsabile\]\s*$marca\s*($nature)\s*$") { continue }
        $tipo = $Matches[1]
        $resto = @($righe | Select-Object -Skip 1)
        # le righe vuote prima del titolo non contano (l'html puo portarne)
        $iTitolo = 0
        while ($iTitolo -lt $resto.Count -and [string]::IsNullOrWhiteSpace($resto[$iTitolo])) { $iTitolo++ }
        if ($iTitolo -ge $resto.Count -or $resto[$iTitolo] -notmatch "^$marcaTitolo\s*(\S.*?)\s*$") { continue }
        $titolo = $Matches[1]
        # la firma che Add-CardCommento mette in fondo non e parte della descrizione
        $corpo = @($resto | Select-Object -Skip ($iTitolo + 1) | Where-Object { $_ -notmatch $firma })
        [pscustomobject]@{ Id = [int](Get-Campo $c 'Id'); Tipo = $tipo; Titolo = $titolo; Descrizione = (($corpo -join "`n").Trim()) }
    }
}

# La firma che Add-CardCommento mette in fondo a ogni commento di un ruolo: un posto solo, per chi la scrive e per chi la toglie leggendo.
function Get-FirmaCommento([string]$Ruolo) { "$([char]0x2014) scritto da Claude ($Ruolo)" }

# ---- la Bug creata dallo smistatore, segnata sulla card di chiusura (D52, gruppo 5) ------------------------------------
# Lo stato locale dello smistatore e di un PC solo: l'idempotenza di una Bug non puo stare li. Appena la Bug esiste, lo smistatore
# scrive sulla card di chiusura un commento [smistatore] con la marca: la chiave (l'id del commento della correzione, o il commit di
# testa della PR per allinea-develop) e l'id della Bug. Chi decide se farla rilegge i commenti: vale da ogni PC e dopo uno stato perso.
$script:MarcheBugCreata = @{ correzione = 'Correzione #'; allinea = 'Allinea-develop @' }

# Il testo, senza il prefisso [smistatore] (lo mette chi lo scrive).
function ConvertTo-TestoCommentoBugCreata([ValidateSet('correzione', 'allinea')][string]$Tipo, [string]$Chiave, [int]$Bug) {
    "$($script:MarcheBugCreata[$Tipo])$Chiave -> Bug $Bug"
}

# Le chiavi delle Bug gia create di un tipo, dai commenti [smistatore] che si aprono con la marca. Chi le legge le racchiude in @().
function Get-BugCreate($Commenti, [ValidateSet('correzione', 'allinea')][string]$Tipo) {
    $marca = [regex]::Escape($script:MarcheBugCreata[$Tipo])
    foreach ($c in @(@($Commenti) | Where-Object { $null -ne $_ })) {
        $prima = ((ConvertTo-TestoSempliceCommento (Get-Campo $c 'Testo')) -split '\r?\n', 2)[0]
        if ($prima -match "^\[smistatore\]\s*$marca(\S+)\s+->\s+Bug\s+\d+\s*$") { $Matches[1] }
    }
}

# ---- i processi della vista ---------------------------------------------------------------------------------------

# I processi pwsh in esecuzione con la riga di comando (l'unico punto che parla con Win32_Process: i test lo sostituiscono).
function Get-ProcessiPwsh {
    @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ ProcessId = [int]$_.ProcessId; ParentProcessId = [int]$_.ParentProcessId; CommandLine = [string]$_.CommandLine } })
}

# I processi pwsh che fanno girare uno script di QUESTA radice (percorso relativo, es. src/Vista.ps1): la riga di comando puo avere / o \ e
# maiuscole diverse, e il percorso deve cominciare dopo uno spazio o un apice (un'altra radice che finisce allo stesso modo non conta).
# Con -DiversiDa esclude quel processo e i suoi figli diretti (la vista che si guarda intorno non conta se stessa).
function Get-ProcessiScriptRadice([Parameter(Mandatory)][string]$Radice, [Parameter(Mandatory)][string]$Script, [int]$DiversiDa = 0) {
    $percorso = ($Radice.TrimEnd([char]92, '/') -replace [regex]::Escape([string][char]92), '/') + '/' + $Script
    $re = '(?i)(?<=^|[\s"''])' + [regex]::Escape($percorso) + '(?=$|[\s"''])'
    @(Get-ProcessiPwsh | Where-Object {
        $riga = $_.CommandLine -replace [regex]::Escape([string][char]92), '/'
        $riga -match $re -and
        -not ($DiversiDa -and ($_.ProcessId -eq $DiversiDa -or $_.ParentProcessId -eq $DiversiDa))
    })
}

# I processi pwsh che fanno girare src/Vista.ps1 -Segui di QUESTA radice.
function Get-ProcessiVistaRadice([Parameter(Mandatory)][string]$Radice, [int]$DiversiDa = 0) {
    @(Get-ProcessiScriptRadice -Radice $Radice -Script 'src/Vista.ps1' -DiversiDa $DiversiDa |
        Where-Object { ($_.CommandLine -replace [regex]::Escape([string][char]92), '/') -match '(?i)\s-Segui(\s|$)' })
}

# I processi pwsh che fanno girare src/Smistatore.ps1 di QUESTA radice: un giro dello smistatore in corso.
function Get-ProcessiSmistatoreRadice([Parameter(Mandatory)][string]$Radice) {
    @(Get-ProcessiScriptRadice -Radice $Radice -Script 'src/Smistatore.ps1')
}

Export-ModuleMember -Function Test-AmbienteCollaudo, ConvertTo-ElencoUrlCollaudo, Test-ProcessoAvviato, Add-RigaRegistro, Read-RigheCondivise, ConvertTo-TestoCommentoDeploy, Get-SceltaDeploy, ConvertTo-TestoCommentoDescrizionePr, Get-DescrizionePrSalvata, ConvertTo-TestoCommentoCorrezione, Get-CorrezioniScritte, Get-FirmaCommento, ConvertTo-TestoCommentoBugCreata, Get-BugCreate, Get-NatureCorrezione, Get-StatiInTest, Get-StatiConRamo, Get-DestinazioneCard, Get-PrefissiRamoFunzionalita, Get-PrefissoRamoFunzionalita, Get-SiglaFunzionalita, Get-RegexRamoFunzionalita, Get-ComposizioneFunzionalita, Get-FileLog, Get-OperazionePianificata, Get-NomiOperazioniPianificate, Get-TestoPatScaduto, Get-RegexPatRifiutato, Format-RigaLog, Get-RegexRigaLog, Get-NomiModelliRigaLog, Get-CartellaDati, Get-Campo, ConvertTo-DataUtc, Get-ChiaveStato, Get-RuoliFlusso, Read-FilePat, Write-FilePat, Get-NomiFilePat, Get-PercorsoFilePat, Get-ProcessiPwsh, Get-ProcessiScriptRadice, Get-ProcessiVistaRadice, Get-ProcessiSmistatoreRadice
