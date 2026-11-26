#requires -Version 7
# Il server locale della vista (con -Html -Segui): serve vista.html, sessione-*.html e brief-*.html dalla cartella dove la vista
# li scrive e accetta sei comandi: POST /giro, che avvia subito lo smistatore, POST /aggiorna, che fa rileggere alla vista agenti e
# card da Azure DevOps, POST /togli-attesa?id=<card>, che toglie il tag on-hold a una card (D37), POST /soglia, che alza la soglia
# della quota o ignora la riserva fino al reset settimanale (D51), POST /aggiorna-suite, che scrive la richiesta di aggiornamento
# della suite e avvia subito il supervisore, e POST /automatico?attivo=0|1, che accende o spegne l'aggiornamento automatico (D53).
# Ascolta solo su localhost.
# La logica (instradamento, controlli) sta in funzioni che non toccano la rete: Get-RispostaVista riceve i dati della richiesta e
# ritorna la risposta. Solo Start-ServerVista, Invoke-RichiesteVista e Stop-ServerVista parlano con HttpListener.
# Sicurezza: ogni pagina web aperta nel browser puo fare richieste a localhost, quindi (1) i due POST vogliono il token generato
# all'avvio della vista e scritto nella pagina (header X-Vista-Token), (2) l'header Host deve essere localhost sulla nostra
# porta (contro il DNS rebinding), (3) si servono solo tre nomi di file noti e si risponde solo a GET e ai POST dei comandi,
# (4) il corpo della richiesta non si legge. L'unico dato che arriva a un comando e l'id della card di /togli-attesa, in query:
# un intero, che deve essere fra le card che la vista, nell'ultima lettura di Azure DevOps, mostra in on-hold (lista bianca lato server).
# Fa eccezione anche /soglia, che porta nella query tre parametri noti (soglia, ignoraRiserva, ripristina), passati come stringhe
# e validati da Get-OverrideSogliaQuota (Decisioni.psm1). /automatico porta un solo parametro, attivo, che e 0 o 1 (D53); /aggiorna-suite
# nessuno.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global

# La porta di default della vista. Cambia con -Porta.
# 18799: le porte intorno a 8787 (8695-8794 su questo PC) sono riservate da Windows (Hyper-V/WinNAT) e HttpListener non le apre.
function Get-PortaVista { 18799 }

# Un token casuale (32 byte, in esadecimale): vale finche vive il processo della vista.
function New-TokenVista {
    $b = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($b)
    [Convert]::ToHexString($b).ToLowerInvariant()
}

# Confronto a tempo costante. Un token atteso vuoto non e mai valido.
function Test-TokenVista([string]$Atteso, [string]$Ricevuto) {
    if ([string]::IsNullOrEmpty($Atteso) -or [string]::IsNullOrEmpty($Ricevuto)) { return $false }
    $a = [Text.Encoding]::UTF8.GetBytes($Atteso); $r = [Text.Encoding]::UTF8.GetBytes($Ricevuto)
    if ($a.Length -ne $r.Length) { return $false }
    [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($a, $r)
}

# Il nome del file per un percorso della richiesta, o null se non e uno dei cinque ammessi: vista.html, ufficio.html, ufficio.json, sessione-<id>.html,
# brief-<ruolo>.html. Il nome e fatto solo di lettere, cifre, punto, trattino e underscore, senza "..": niente directory.
function Resolve-FileVista([string]$Percorso) {
    if ($Percorso -match '^/(vista\.html|ufficio\.html|ufficio\.json|sessione-[\w.-]+\.html|brief-[\w.-]+\.html)\z' -and $Percorso -notmatch '\.\.') { return $Matches[1] }
    $null
}

function New-RispostaVista([int]$Codice, [string]$Tipo, [byte[]]$Corpo) {
    [pscustomobject]@{ Codice = $Codice; Tipo = $Tipo; Corpo = $Corpo }
}
function New-RispostaTesto([int]$Codice, [string]$Testo) {
    New-RispostaVista $Codice 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($Testo))
}
function New-RispostaGiro([int]$Codice, [string]$Esito, [string]$Messaggio) {
    $json = [ordered]@{ esito = $Esito; messaggio = $Messaggio } | ConvertTo-Json -Compress
    New-RispostaVista $Codice 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

# La risposta a una richiesta. $AvviaGiro e uno scriptblock che ritorna @{ Esito = avviato|inEsecuzione|errore; Messaggio };
# $Aggiorna chiede alla vista di rileggere subito Azure DevOps e ridisegnare (POST /aggiorna), senza dati della richiesta.
# $TogliAttesa (param $Id) toglie il tag on-hold a una card e $InAttesa sono gli id che la vista mostra in on-hold (POST /togli-attesa).
# $Percorso e quello della richiesta (con l'eventuale query, che si ignora); $TokenRicevuto e l'header X-Vista-Token.
function Get-RispostaVista {
    [CmdletBinding()]
    param([string]$Metodo, [string]$Percorso, [string]$TokenRicevuto, [string]$Token, [string]$Cartella,
          [scriptblock]$AvviaGiro, [scriptblock]$Aggiorna, [string]$HostHeader, [int]$Porta, [bool]$Locale, [scriptblock]$AggiornaPipeline, [scriptblock]$TogliAttesa, [int[]]$InAttesa, [scriptblock]$ImpostaSoglia, [scriptblock]$AggiornaSuite, [scriptblock]$ImpostaAutomatico,
          [scriptblock]$ImpostaOrdine, [scriptblock]$ImpostaPausa, [int[]]$Feature, [scriptblock]$ImpostaPausaSistema)
    # http.sys con il prefisso localhost puo accettare connessioni da altre interfacce: chi non e locale non ha risposta (default: rifiuta)
    if (-not $Locale) { return New-RispostaTesto 403 'solo richieste locali' }
    # con il prefisso localhost http.sys rifiuta gia Host 127.0.0.1 e [::1]: l'unico Host ammesso e localhost sulla nostra porta
    if ([string]::IsNullOrEmpty($HostHeader) -or $HostHeader -ne "localhost:$Porta") { return New-RispostaTesto 403 'host non ammesso' }
    $solo = if ($Percorso) { ($Percorso -split '\?', 2)[0] } else { '' }
    if ($solo -eq '/giro') {
        if ($Metodo -ne 'POST') { return New-RispostaTesto 405 'metodo non ammesso' }
        if (-not (Test-TokenVista $Token $TokenRicevuto)) { return New-RispostaGiro 403 'errore' 'token non valido: ricarica la pagina' }
        try { $r = & $AvviaGiro }
        catch { $r = [pscustomobject]@{ Esito = 'errore'; Messaggio = "errore: $($_.Exception.Message)" } }
        if ($null -eq $r) { $r = [pscustomobject]@{ Esito = 'errore'; Messaggio = 'errore: nessuna risposta dall avvio' } }
        $codice = switch ("$($r.Esito)") { 'avviato' { 200 } 'inEsecuzione' { 409 } default { 500 } }
        $esito = if ($codice -eq 500) { 'errore' } else { "$($r.Esito)" }
        return New-RispostaGiro $codice $esito "$($r.Messaggio)"
    }
    # POST /aggiorna-pipeline: rilegge solo le pipeline di tutti i progetti, come /aggiorna fa per agenti e card
    if ($solo -eq '/aggiorna-pipeline' -and $AggiornaPipeline) {
        if ($Metodo -ne 'POST') { return New-RispostaTesto 405 'metodo non ammesso' }
        if (-not (Test-TokenVista $Token $TokenRicevuto)) { return New-RispostaGiro 403 'errore' 'token non valido: ricarica la pagina' }
        & $AggiornaPipeline
        return New-RispostaGiro 202 'accodato' 'rilettura delle pipeline in corso...'
    }
    # POST /soglia?soglia=0.8&ignoraRiserva=1 o ?ripristina=1: $ImpostaSoglia riceve i parametri noti e ritorna @{ Esito = ok|errore; Messaggio };
    # se e ok la pagina si ridisegna come per /aggiorna
    if ($solo -eq '/soglia' -and $ImpostaSoglia) {
        if ($Metodo -ne 'POST') { return New-RispostaTesto 405 'metodo non ammesso' }
        if (-not (Test-TokenVista $Token $TokenRicevuto)) { return New-RispostaGiro 403 'errore' 'token non valido: ricarica la pagina' }
        $q = @{}
        $query = if ($Percorso -match '\?(.*)$') { $Matches[1] } else { '' }
        foreach ($coppia in ($query -split '&')) {
            $kv = $coppia -split '=', 2
            if ($kv[0] -in 'soglia', 'ignoraRiserva', 'ripristina', 'soglia5Ore') { $q[$kv[0]] = $(if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1]) } else { '' }) }
        }
        try { $r = & $ImpostaSoglia $q }
        catch { $r = @{ Esito = 'errore'; Messaggio = "errore: $($_.Exception.Message)" } }
        if ($null -eq $r -or "$(Get-Campo $r 'Esito')" -ne 'ok') {
            $m = if ($null -eq $r) { 'errore: nessuna risposta' } else { "$(Get-Campo $r 'Messaggio')" }
            return New-RispostaGiro 400 'errore' $m
        }
        if ($Aggiorna) { & $Aggiorna }
        return New-RispostaGiro 202 'accodato' "$(Get-Campo $r 'Messaggio')"
    }
    # D60: POST /ordine?id=<feature>&dopo=<feature|0> sposta una Feature subito dopo un'altra (0 = in cima); POST /pausa?id=<feature>&attiva=0|1
    # mette o toglie il tag di pausa. Gli id sono interi e devono stare fra le Feature aperte dell'ultima lettura ($Feature, lista bianca).
    if ($solo -in '/ordine', '/pausa' -and (($solo -eq '/ordine' -and $ImpostaOrdine) -or ($solo -eq '/pausa' -and $ImpostaPausa))) {
        if ($Metodo -ne 'POST') { return New-RispostaTesto 405 'metodo non ammesso' }
        if (-not (Test-TokenVista $Token $TokenRicevuto)) { return New-RispostaGiro 403 'errore' 'token non valido: ricarica la pagina' }
        $q = @{}
        $query = if ($Percorso -match '\?(.*)$') { $Matches[1] } else { '' }
        foreach ($coppia in ($query -split '&')) { $kv = $coppia -split '=', 2; if ($kv.Count -eq 2) { $q[$kv[0]] = $kv[1] } }
        $id = 0; $altro = 0
        if (-not [int]::TryParse("$($q['id'])", [ref]$id) -or @($Feature) -notcontains $id) { return New-RispostaGiro 400 'errore' 'Feature non valida: ricarica la pagina' }
        try {
            if ($solo -eq '/ordine') {
                if (-not [int]::TryParse("$($q['dopo'])", [ref]$altro) -or ($altro -ne 0 -and @($Feature) -notcontains $altro)) { return New-RispostaGiro 400 'errore' 'posizione non valida: ricarica la pagina' }
                $r = & $ImpostaOrdine $id $altro
            }
            else {
                if ("$($q['attiva'])" -notin '0', '1') { return New-RispostaGiro 400 'errore' "attiva vale 0 o 1" }
                $r = & $ImpostaPausa $id ("$($q['attiva'])" -eq '1')
            }
        }
        catch { $r = @{ Esito = 'errore'; Messaggio = "errore: $($_.Exception.Message)" } }
        if ($null -eq $r -or "$(Get-Campo $r 'Esito')" -ne 'ok') {
            $m = if ($null -eq $r) { 'errore: nessuna risposta' } else { "$(Get-Campo $r 'Messaggio')" }
            return New-RispostaGiro 500 'errore' $m
        }
        if ($Aggiorna) { & $Aggiorna }
        return New-RispostaGiro 202 'accodato' "$(Get-Campo $r 'Messaggio')"
    }
    # POST /aggiorna-suite (D53): nessun dato dalla richiesta; $AggiornaSuite scrive la richiesta e avvia il supervisore e ritorna @{ Esito = ok|errore; Messaggio }.
    # Non ridisegna: lo stato lo scrive il supervisore, e la pagina lo mostra al prossimo disegno.
    if ($solo -eq '/aggiorna-suite' -and $AggiornaSuite) {
        if ($Metodo -ne 'POST') { return New-RispostaTesto 405 'metodo non ammesso' }
        if (-not (Test-TokenVista $Token $TokenRicevuto)) { return New-RispostaGiro 403 'errore' 'token non valido: ricarica la pagina' }
        try { $r = & $AggiornaSuite }
        catch { $r = @{ Esito = 'errore'; Messaggio = "errore: $($_.Exception.Message)" } }
        if ($null -eq $r -or "$(Get-Campo $r 'Esito')" -ne 'ok') {
            $m = if ($null -eq $r) { 'errore: nessuna risposta' } else { "$(Get-Campo $r 'Messaggio')" }
            return New-RispostaGiro 500 'errore' $m
        }
        return New-RispostaGiro 202 'accodato' "$(Get-Campo $r 'Messaggio')"
    }
    # POST /automatico?attivo=0|1 (D53): l'unico dato e attivo, 0 o 1; $ImpostaAutomatico (param $Attivo, bool) scrive impostazioni.json; poi rilegge come /aggiorna.
    # POST /pausa-sistema?attivo=0|1 (D60) e lo stesso per la pausa di tutto il sistema ($ImpostaPausaSistema).
    $comandoSiNo = if ($solo -eq '/automatico') { $ImpostaAutomatico } elseif ($solo -eq '/pausa-sistema') { $ImpostaPausaSistema } else { $null }
    if ($solo -in '/automatico', '/pausa-sistema' -and $comandoSiNo) {
        if ($Metodo -ne 'POST') { return New-RispostaTesto 405 'metodo non ammesso' }
        if (-not (Test-TokenVista $Token $TokenRicevuto)) { return New-RispostaGiro 403 'errore' 'token non valido: ricarica la pagina' }
        $query = if ($Percorso -match '\?(.*)$') { $Matches[1] } else { '' }
        if ($query -notmatch '\Aattivo=([01])\z') { return New-RispostaGiro 400 'errore' 'serve un solo parametro attivo, 0 o 1' }
        $attivo = $Matches[1] -eq '1'
        try { $r = & $comandoSiNo $attivo }
        catch { $r = @{ Esito = 'errore'; Messaggio = "errore: $($_.Exception.Message)" } }
        if ($null -eq $r -or "$(Get-Campo $r 'Esito')" -ne 'ok') {
            $m = if ($null -eq $r) { 'errore: nessuna risposta' } else { "$(Get-Campo $r 'Messaggio')" }
            return New-RispostaGiro 400 'errore' $m
        }
        if ($Aggiorna) { & $Aggiorna }
        return New-RispostaGiro 202 'accodato' "$(Get-Campo $r 'Messaggio')"
    }
    # POST /togli-attesa?id=<card>: l'unico dato e l'id, un intero fra le card che la vista mostra in on-hold; poi rilegge come /aggiorna
    if ($solo -eq '/togli-attesa' -and $TogliAttesa) {
        if ($Metodo -ne 'POST') { return New-RispostaTesto 405 'metodo non ammesso' }
        if (-not (Test-TokenVista $Token $TokenRicevuto)) { return New-RispostaGiro 403 'errore' 'token non valido: ricarica la pagina' }
        $query = if ($Percorso -match '\?(.*)$') { $Matches[1] } else { '' }
        if ($query -notmatch '\Aid=([0-9]{1,9})\z') { return New-RispostaGiro 400 'errore' 'serve un solo id di card intero' }
        $id = [int]$Matches[1]
        if ($id -notin @($InAttesa)) { return New-RispostaGiro 403 'errore' 'la card non risulta in on-hold nella vista: aggiorna la pagina' }
        try { & $TogliAttesa $id }
        catch { return New-RispostaGiro 500 'errore' "on-hold non tolto: $($_.Exception.Message)" }
        if ($Aggiorna) { & $Aggiorna }
        return New-RispostaGiro 202 'accodato' "on-hold tolto dalla card $id, rilettura in corso..."
    }
    if ($solo -eq '/aggiorna' -and $Aggiorna) {
        if ($Metodo -ne 'POST') { return New-RispostaTesto 405 'metodo non ammesso' }
        if (-not (Test-TokenVista $Token $TokenRicevuto)) { return New-RispostaGiro 403 'errore' 'token non valido: ricarica la pagina' }
        & $Aggiorna
        return New-RispostaGiro 202 'accodato' 'rilettura di agenti e card in corso...'
    }
    $nome = Resolve-FileVista $solo
    if ($nome) {
        if ($Metodo -ne 'GET') { return New-RispostaTesto 405 'metodo non ammesso' }
        $file = Join-Path $Cartella $nome
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return New-RispostaTesto 404 'non trovato' }
        $tipo = if ($nome.EndsWith('.json')) { 'application/json; charset=utf-8' } else { 'text/html; charset=utf-8' }
        try { return New-RispostaVista 200 $tipo ([IO.File]::ReadAllBytes($file)) }
        catch { return New-RispostaTesto 404 'non trovato' }
    }
    if ($Metodo -notin 'GET', 'POST') { return New-RispostaTesto 405 'metodo non ammesso' }
    New-RispostaTesto 404 'non trovato'
}

# L'avvio anticipato di un'attivita pianificata di DevOps.Agents: lo stesso giro di sempre. Se gira gia non ne avvia un'altra.
function Start-AttivitaAnticipata([string]$Nome, [string]$MessaggioGiaInEsecuzione, [string]$MessaggioAvviata) {
    $percorso = (Get-OperazionePianificata).Percorso
    try {
        $t = Get-ScheduledTask -TaskPath $percorso -TaskName $Nome -ErrorAction Stop
        if ("$($t.State)" -eq 'Running') { return [pscustomobject]@{ Esito = 'inEsecuzione'; Messaggio = $MessaggioGiaInEsecuzione } }
        Start-ScheduledTask -TaskPath $percorso -TaskName $Nome -ErrorAction Stop
        [pscustomobject]@{ Esito = 'avviato'; Messaggio = $MessaggioAvviata }
    }
    catch { [pscustomobject]@{ Esito = 'errore'; Messaggio = "errore: $($_.Exception.Message)" } }
}

# L'avvio del giro: l'attivita pianificata dello smistatore, lo stesso giro di sempre anticipato.
function Start-GiroPianificato { Start-AttivitaAnticipata (Get-OperazionePianificata).Nome 'lo smistatore e gia in esecuzione' 'smistatore avviato' }

# L'avvio anticipato del supervisore, che e chi aggiorna la suite (D53).
function Start-SupervisorePianificato { Start-AttivitaAnticipata (Get-NomiOperazioniPianificate).Supervisore 'il supervisore e gia in esecuzione' 'supervisore avviato' }

# ---- la rete -----------------------------------------------------------------------------------------------------

# Il browser ha chiuso la connessione prima della risposta (una pagina ricaricata, una scheda chiusa): non e un errore della
# vista e non va in console. HttpListener lo segnala con ERROR_NETNAME_DELETED (64) o ERROR_CONNECTION_ABORTED (1229).
function Test-ClienteAndato([Exception]$Errore) {
    for ($e = $Errore; $null -ne $e; $e = $e.InnerException) {
        if ($e -is [System.Net.HttpListenerException] -and $e.ErrorCode -in 64, 1229) { return $true }
    }
    $false
}

# Una richiesta di HttpListener: la passa alla logica pura e scrive la risposta. Separata da Start-ServerVista per provarla con un
# contesto finto, senza porta. Un errore non si inghiotte: va in console e il client riceve 500 con un testo.
function Invoke-GestioneRichiesta($Ctx, [string]$Token, [string]$Cartella, [scriptblock]$AvviaGiro, [int]$Porta, [scriptblock]$Aggiorna = $null, [scriptblock]$AggiornaPipeline = $null, [scriptblock]$TogliAttesa = $null, $Segnali = $null, [scriptblock]$ImpostaSoglia = $null, [scriptblock]$AggiornaSuite = $null, [scriptblock]$ImpostaAutomatico = $null, [scriptblock]$ImpostaOrdine = $null, [scriptblock]$ImpostaPausa = $null, [scriptblock]$ImpostaPausaSistema = $null) {
    try {
        try {
            $rq = $Ctx.Request
            $r = Get-RispostaVista -Metodo $rq.HttpMethod -Percorso $rq.RawUrl -TokenRicevuto $rq.Headers['X-Vista-Token'] -Token $Token `
                -Cartella $Cartella -AvviaGiro $AvviaGiro -Aggiorna $Aggiorna -HostHeader $rq.Headers['Host'] -Porta $Porta -Locale ([bool]$rq.IsLocal) -AggiornaPipeline $AggiornaPipeline `
                -TogliAttesa $TogliAttesa -InAttesa $(if ($Segnali -and $Segnali.PSObject.Properties['InAttesa']) { [int[]]@($Segnali.InAttesa) } else { [int[]]@() }) -ImpostaSoglia $ImpostaSoglia -AggiornaSuite $AggiornaSuite -ImpostaAutomatico $ImpostaAutomatico `
                -ImpostaOrdine $ImpostaOrdine -ImpostaPausa $ImpostaPausa -ImpostaPausaSistema $ImpostaPausaSistema -Feature $(if ($Segnali -and $Segnali.PSObject.Properties['Feature']) { [int[]]@($Segnali.Feature) } else { [int[]]@() })
        }
        catch {
            Write-Host "vista: errore nella richiesta: $($_.Exception.Message)"
            $r = New-RispostaTesto 500 'errore interno della vista'
        }
        try {
            $Ctx.Response.StatusCode = $r.Codice
            $Ctx.Response.ContentType = $r.Tipo
            $Ctx.Response.Headers['Cache-Control'] = 'no-store'
            $Ctx.Response.Headers['X-Content-Type-Options'] = 'nosniff'
            $Ctx.Response.ContentLength64 = $r.Corpo.Length
            $Ctx.Response.OutputStream.Write($r.Corpo, 0, $r.Corpo.Length)
        }
        catch { if (-not (Test-ClienteAndato $_.Exception)) { Write-Host "vista: risposta non scritta: $($_.Exception.Message)" } }
    }
    finally { try { $Ctx.Response.Close() } catch { } }
}
# Apre il listener su http://localhost:<porta>/. Ritorna l'oggetto del server; se la porta e occupata lancia.
# Prendi e Gestisci sono i due scriptblock che Invoke-RichiesteVista usa: cosi il ciclo si prova senza una porta vera.
function Start-ServerVista([int]$Porta, [string]$Cartella, [string]$Token, [scriptblock]$AvviaGiro, [scriptblock]$TogliAttesa = $null, [scriptblock]$ImpostaSoglia = $null, [scriptblock]$AggiornaSuite = $null, [scriptblock]$ImpostaAutomatico = $null, [scriptblock]$ImpostaOrdine = $null, [scriptblock]$ImpostaPausa = $null, [scriptblock]$ImpostaPausaSistema = $null) {
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Porta/")
    $l.Start()
    # Segnali.Aggiorna: POST /aggiorna lo accende, Invoke-RichiesteVista ritorna subito e la vista rilegge Azure DevOps e lo spegne.
    # Segnali.AggiornaPipeline: lo stesso per POST /aggiorna-pipeline, che fa rileggere solo le pipeline.
    # Segnali.InAttesa: gli id delle card che la vista mostra in on-hold, la lista bianca di POST /togli-attesa; la vista la riscrive a ogni lettura di Azure DevOps.
    # Segnali.Feature (D60): gli id delle Feature aperte dell'ultima lettura, la lista bianca di POST /ordine e /pausa.
    $segnali = [pscustomobject]@{ Aggiorna = $false; AggiornaPipeline = $false; InAttesa = @(); Feature = @() }
    $aggiorna = { $segnali.Aggiorna = $true }.GetNewClosure()
    $aggiornaPipeline = { $segnali.AggiornaPipeline = $true }.GetNewClosure()
    $gestisci = { param($Ctx) Invoke-GestioneRichiesta $Ctx $Token $Cartella $AvviaGiro $Porta $aggiorna $aggiornaPipeline $TogliAttesa $segnali $ImpostaSoglia $AggiornaSuite $ImpostaAutomatico $ImpostaOrdine $ImpostaPausa $ImpostaPausaSistema }.GetNewClosure()
    [pscustomobject]@{ Listener = $l; Porta = $Porta; Attesa = $null; Segnali = $segnali; Prendi = { $l.GetContextAsync() }.GetNewClosure(); Gestisci = $gestisci }
}

# Serve le richieste che arrivano per $Secondi, poi ritorna: sostituisce l'attesa fra un disegno e l'altro. Non blocca mai piu
# di 200 ms su una richiesta sola, quindi il disegno riparte sempre in orario (a meno di quanto dura una richiesta).
function Invoke-RichiesteVista($Server, [int]$Secondi) {
    $fine = (Get-Date).AddSeconds($Secondi)
    while ($true) {
        $resto = ($fine - (Get-Date)).TotalMilliseconds
        if ($resto -le 0) { break }
        try {
            if ($null -eq $Server.Attesa) { $Server.Attesa = & $Server.Prendi }
            if ($Server.Attesa.Wait([int][math]::Min(200, [math]::Ceiling($resto)))) {
                $ctx = $Server.Attesa.Result
                $Server.Attesa = $null
                & $Server.Gestisci $ctx
                # una rilettura chiesta dalla pagina non aspetta la fine dei secondi
                if ($Server.PSObject.Properties['Segnali'] -and ($Server.Segnali.Aggiorna -or ($Server.Segnali.PSObject.Properties['AggiornaPipeline'] -and $Server.Segnali.AggiornaPipeline))) { break }
            }
        }
        catch {
            # il listener e chiuso o la richiesta e fallita: si riprova al prossimo giro d'attesa senza girare a vuoto
            $Server.Attesa = $null
            Start-Sleep -Milliseconds ([int][math]::Min(200, [math]::Max(1, $resto)))
        }
    }
}

# Libera la porta: Stop e Close. Sicuro se chiamato piu volte.
function Stop-ServerVista($Server) {
    if ($null -eq $Server) { return }
    try { $Server.Listener.Stop() } catch { }
    try { $Server.Listener.Close() } catch { }
}

Export-ModuleMember -Function Get-PortaVista, New-TokenVista, Test-TokenVista, Resolve-FileVista, Get-RispostaVista, Start-GiroPianificato, Start-SupervisorePianificato, Start-AttivitaAnticipata,
    Invoke-GestioneRichiesta, Start-ServerVista, Invoke-RichiesteVista, Stop-ServerVista
