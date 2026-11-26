#requires -Version 7
# La vista di cosa fanno gli agenti, da lasciare aperta in un terminale. Solo lettura: non scrive ne lo stato, ne il log,
# ne Azure DevOps, e non lancia ne ferma sessioni.
#   pwsh -NoProfile -File src/Vista.ps1             # stampa una volta
#   pwsh -NoProfile -File src/Vista.ps1 -Segui      # ridisegna ogni -Secondi (10)
#   pwsh -NoProfile -File src/Vista.ps1 -Html -Segui -Apri   # la stessa vista come pagina HTML (vedi sotto)
# Nel terminale tre blocchi: In corso (le sessioni aperte, con le ultime azioni dell'agente), In coda / ferme (le card senza
# sessione e il perche, con il ruolo a cui andranno) e Da fare tu (i gesti che aspettano una persona). Nella pagina HTML una
# kanban per agente: una colonna per ruolo (sessioni in corso in cima, coda sotto), la colonna dell'operatore e quella della
# pipeline. Il perche e il ruolo li decide Decisioni.psm1, la stessa funzione che usa lo smistatore: qui non c'e nessuna regola.
# La parte locale (stato, uscita delle sessioni) si rilegge a ogni disegno; Azure DevOps ogni -SecondiAdo, per non
# interrogarlo a ogni disegno. Se non risponde, la vista mostra la parte locale con un avviso.
# Sotto la kanban la sezione "Pipeline di build": i run di tutti i progetti dell'organizzazione (in corso, in coda, in attesa di
# approvazione, falliti nelle ultime 24 ore) con il link a ogni run, e un link alle PR di tutti i progetti. Stessa lettura e stesso
# ritmo di Azure DevOps (-SecondiAdo), ma indipendente: se non risponde la sezione lo dice e gli agenti restano.
# Nella scheda Agenti, sotto kanban e catene, la sezione "Apprendimento" (D46): per ruolo e per settimana i blocchi, gli on-hold, le correzioni
# e le lezioni applicate (dal registro dello smistatore: un file, e il riassunto si ricalcola solo se il file e cambiato), le lezioni che
# hanno evitato un blocco finora e le lezioni in prova in attesa di conferma. Le lezioni sono git piu Azure DevOps, una lettura per ruolo
# e per repo (dentro MemoriaRepo fetch e PR si pagano una volta ogni pochi minuti): hanno il loro timer (-SecondiMemoria, piu lento di
# -SecondiAdo) e si leggono solo con -Html. Con -Segui il primo disegno non le aspetta (la sezione dice "lettura in corso"). Se una lettura
# fallisce la sezione lo dice e il resto della pagina si disegna.
# Su ogni scheda con una PR c'e una riga: numero col link, stato della validazione (verde, rossa, in corso, in conflitto, assente) e,
# se rossa o in corso, il link al log della build. Sono gli stessi dati dello smistatore (Get-AdoPr); senza PR niente riga.
# Con -Segui, a ogni giro la vista guarda se src/*.ps1, src/*.psm1 o config/*.json sono cambiati dall'avvio: se lo stesso cambio si
# vede in due giri di fila (un pull a meta scrittura no) esce con il codice 75: il supervisore (il processo dell'utente, che con
# -Segui non disegna) lo rilancia nella stessa finestra con gli stessi parametri, -Apri solo la prima volta.
# I dati e il disegno sono separati: Get-ModelloVista costruisce il modello (oggetti), Get-TestoVista lo disegna nel
# terminale e New-PaginaVista (VistaHtml.psm1) in una pagina. Con -Html la pagina e scritta in <cartella dati>ista.html
# (-PercorsoHtml per cambiarlo) con un file temporaneo e un rename, cosi il browser non ne legge mai meta; si ricarica da
# sola ogni -Secondi. -Apri la apre nel browser predefinito alla prima scrittura.
# Con -Html accanto a vista.html la vista scrive ufficio.html e ufficio.json: l'ufficio come mini videogioco su canvas (personaggi alla scrivania,
# in pausa, in fila alla porta di Titolare, consegne fra ruoli), letto dagli stessi dati. Il dato vero lo traduce Get-ModelloUfficio
# (VistaUfficio.psm1), il gioco sta in src/ufficio/ e lo compone VistaUfficioPagina.psm1; la pagina rilegge ufficio.json da sola.
# Sempre con -Html, accanto a vista.html la vista scrive una pagina sessione-<id>.html per ogni sessione in corso: lo stream
# dell'agente (testo, strumenti, risultati, esito), linkata dalla sua scheda. Quando la sessione finisce la pagina resta, con
# "sessione finita" in cima (scritta all'ultimo disegno); le pagine piu vecchie di 7 giorni si cancellano.
# Scrive anche una pagina brief-<ruolo>.html per ogni ruolo di config/ruoli.json: il brief (il Markdown che la sessione riceve
# come istruzioni) convertito in HTML, linkata dall'intestazione della colonna del ruolo. Si riscrive solo se il file del brief
# e piu recente della pagina o se la pagina manca. Sono i soli file che la vista scrive: dati e stato dello smistatore non si toccano.
# Con -Html -Segui la vista e anche un server locale (VistaServer.psm1, HttpListener solo su http://localhost:<-Porta>/, default
# 18799): serve vista.html, sessione-*.html e brief-*.html dalla cartella dove li scrive (e li scrive su disco come sempre), e
# ha due comandi. POST /giro: il pulsante "Avvia smistatore" in testa alla pagina avvia l'attivita pianificata dello smistatore. POST
# /aggiorna: il pulsante "Aggiorna agenti e card" fa rileggere subito Azure DevOps (di solito ogni -SecondiAdo). Lo smistatore
# parte con Start-ScheduledTask; se gira gia lo dice e non ne avvia un altro. Ogni avvio della vista genera un token casuale,
# scritto nella pagina, che i due POST vogliono in un header (senza: 403). Il server vive nel processo figlio e si serve fra un disegno e
# l'altro (Invoke-RichiesteVista), senza fermare il ciclo; prima del riavvio per codice cambiato la porta si libera.
# POST /soglia (D51, integrazione 2026-11-24): i comandi della riga quota alzano la soglia o ignorano la riserva fino al reset settimanale
# (soglia-quota.json nella cartella dati, scritto da Vista.ps1 con Get-OverrideSogliaQuota); la riga quota e il banner di blocco ci sono anche senza server.
# POST /aggiorna-suite e POST /automatico?attivo=0|1 (D53): il riquadro Suite della scheda Agenti ha "Aggiorna adesso" (scrive la richiesta
# aggiorna-suite.richiesta e avvia l'attivita del supervisore, che e chi aggiorna) e l'interruttore dell'aggiornamento automatico
# (impostazioni.json). La vista legge soltanto aggiornamento.json; non aggiorna mai.
# -Apri apre http://localhost:<porta>/vista.html. Senza server (porta occupata, o senza -Segui) la pagina si apre da file, senza
# pulsante. Il testo nel terminale non cambia e non ha server.
[CmdletBinding()]
param(
    [switch]$Segui,
    [switch]$Html,
    [switch]$Apri,
    [string]$PercorsoHtml,
    [int]$Secondi = 10,
    [int]$SecondiAdo = 60,
    [int]$SecondiMemoria = 300,
    [int]$Porta,
    [string]$CartellaDati,
    [string]$Radice
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Radice) { $Radice = Split-Path -Parent $PSScriptRoot }
Import-Module (Join-Path $PSScriptRoot 'VistaCodice.psm1') -Global
# Con -Segui il processo dell'utente e solo un supervisore: lancia la vista come figlio (VISTA_FIGLIO lo segna) e lo rilancia
# finche esce col codice di riavvio. Cosi i processi sono sempre due, e il terminale resta quello. Senza -Segui niente supervisore.
if ($Segui -and -not $env:VISTA_FIGLIO) {
    # Se un'altra vista -Segui di questa radice e gia viva (non io, non i miei figli) non ne parte una seconda: tengono la stessa porta.
    Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global
    $altre = @(Get-ProcessiVistaRadice $Radice -DiversiDa $PID)
    if ($altre.Count -gt 0) { Write-Host "Una vista di questa radice e gia in esecuzione (pid $($altre[0].ProcessId)): esco."; exit 0 }
    $env:VISTA_FIGLIO = '1'
    $pwsh = (Get-Process -Id $PID).Path
    $copia = $PSBoundParameters
    $self = $PSCommandPath
    $avvia = { param($primo) & $pwsh -NoProfile -File $self @(Get-ArgomentiFiglio $copia $primo) | Out-Host; $LASTEXITCODE }.GetNewClosure()
    $codice = Invoke-SupervisoreVista $avvia
    exit $codice
}
# Le date del codice si fissano prima di caricarlo: quello che cambia dopo e quello che la vista non ha ancora.
$dateCodiceAvvio = Get-DateCodice $Radice
foreach ($m in 'Comune', 'Config', 'Ado', 'Stato', 'Decisioni', 'Sessioni', 'Memoria', 'MemoriaRepo', 'Supervisione', 'Impostazioni', 'Aggiornamento', 'VistaSuite', 'VistaUfficioPannello', 'VistaHtml', 'VistaRitmo', 'VistaServer', 'VistaUfficio', 'VistaUfficioPagina') {
    Import-Module (Join-Path $PSScriptRoot "$m.psm1") -Global
}
. (Join-Path $PSScriptRoot 'Istantanea.ps1')
if (-not $CartellaDati) { $CartellaDati = Get-CartellaDati }
$script:PercorsoStato = Join-Path $CartellaDati 'stato.json'
$script:PercorsoQuota = Join-Path $CartellaDati 'quota.json'
$script:PercorsoSoglia = Get-PercorsoSogliaQuotaPredefinito $CartellaDati
if (-not $PercorsoHtml) { $PercorsoHtml = Join-Path $CartellaDati 'vista.html' }
if (-not $Porta) { $Porta = Get-PortaVista }

# ---- Azure DevOps ------------------------------------------------------------------------------------------------

# Per ogni card mia della board: il titolo e, se non ha una sessione, cosa ne pensa Decisioni (azioni, motivo, gesto) e il
# ruolo a cui andra (quello del primo LanciaSessione, o quello che porta il motivo).
# Lo stato e una copia in memoria: le voci nuove che Get-StatoCard vi crea non vengono mai salvate.
function Get-DatiAdo($Cfg, $Stato) {
    $io = Get-AdoUtenteCorrente
    $idUtente = [string]$io.Id
    $attive = @(Get-AdoCardAttive)
    $ctx = New-ContestoGiro $Cfg $attive $idUtente $script:PercorsoQuota $script:PercorsoSoglia
    Update-SessioniContesto $ctx $Stato
    $titoli = @{}; $titoliTask = @{}; $stati = @{}; $avanzamento = @{}; $prSessioni = @{}; $coda = @(); $collegamenti = [System.Collections.Generic.List[object]]::new(); $funzionalita = @{}
    foreach ($c in $attive) {
        $titoli["$($c.Id)"] = [string]$c.Titolo
        $stati["$($c.Id)"] = [string]$c.Stato
        if (-not (Test-CardMia $c $idUtente)) { continue }
        $voce = Find-VoceMappa -Mappa $Cfg.Mappa -Area $c.Area
        if (-not $voce) { continue }
        $sc = Get-StatoCard -Stato $Stato -Id $c.Id
        # D52: la funzionalita della card, per raggruppare le card sotto la Feature e per le catene. Get-FunzionalitaCard legge una volta per
        # Feature (la cache e quella del contesto, che la riga della card riusa); una card isolata non legge niente. Se non si legge niente.
        $fun = $null
        try { $fun = New-FunzionalitaVista (Get-FunzionalitaCard $Cfg $c $ctx $voce) } catch { }
        if ($fun -and -not $funzionalita.ContainsKey("$($fun.Feature)")) { $funzionalita["$($fun.Feature)"] = $fun }
        if ($null -ne $sc['sessione']) {
            # una card con la sessione non ha una riga in coda: i suoi predecessori si leggono qui, per le catene
            try { $pc = @(Get-PredecessoriCard $c $Stato); if ($pc.Count -gt 0) { $collegamenti.Add([pscustomobject]@{ Id = [int]$c.Id; Stato = [string]$c.Stato; Predecessori = $pc; FeatureId = $(if ($fun) { $fun.Feature } else { $null }) }) } } catch { }
            # l'istantanea per le card con sessione non si costruisce: la PR si legge sul ramo salvato; se non si legge, niente riga
            if ($sc['ramo']) {
                try { $p = New-PrVista (Get-AdoPr -Progetto $voce.progettoAdo -Repo $voce.repo -Ramo ([string]$sc['ramo']) -Destinazione (Get-DestinazioneCard $sc)) $voce; if ($p) { $prSessioni["$($c.Id)"] = $p } } catch { }
            }
            $task = Get-Campo $sc['sessione'] 'task'
            if ($task) {
                try {
                    $figli = @(Get-AdoTaskFigli -CardId $c.Id)
                    foreach ($t in $figli) { $titoliTask["$($t.Id)"] = [string]$t.Titolo }
                    $avanzamento["$($c.Id)"] = Get-AvanzamentoTask $Cfg $figli
                } catch { }
            }
            continue
        }
        $riga = Get-RigaCoda $Cfg $c $voce $sc $Stato $script:PercorsoStato $ctx $collegamenti
        $coda += [pscustomobject]$riga
    }
    # le card con una sessione che la board non elenca (altro assegnatario, area uscita dalla mappa): il titolo si prova a leggere
    foreach ($k in $Stato.Keys) {
        if ($null -eq $Stato[$k] -or $null -eq $Stato[$k]['sessione'] -or $titoli.ContainsKey($k)) { continue }
        try { $titoli[$k] = [string](Get-AdoCard -Id ([int]$k)).Titolo } catch { }
    }
    [pscustomobject]@{ Titoli = $titoli; TitoliTask = $titoliTask; Stati = $stati; Avanzamento = $avanzamento; Prs = $prSessioni; Coda = $coda; Collegamenti = @($collegamenti); Funzionalita = @($funzionalita.Values | Sort-Object Feature); Repo = (Get-RepoPerCard $Cfg $attive)
        # le card col tag on-hold in questa lettura: la lista bianca di POST /togli-attesa (D37) e il segno sulla voce
        InAttesa = @($attive | Where-Object { @($_.Tag) -contains [string]$Cfg.Stati.tagAttesa } | ForEach-Object { [int]$_.Id }) }
}

# Le lezioni in prova di ogni ruolo, per comune e per ogni repo della mappa: Get-MemoriaDelRuolo legge git e la PR della memoria e
# non lancia mai, dice nei Motivi cosa ha dovuto saltare. Una chiamata per ruolo e repo la da gia con comune: comune si tiene una
# volta per ruolo. Se una lettura lancia (non dovrebbe) si lascia salire: la sezione dice l'errore e le lezioni restano non lette.
# Ritorna Lezioni (le sole in prova: Id, Ruolo, Repo = comune o il repo, Situazione, Testo = il blocco intero), Stabili (le gia
# confermate, stessi campi: stessa lettura, nessun file in piu), Conosciute (id -> card d'origine di tutte le
# lezioni lette, stabili comprese: serve a dire quali hanno evitato un blocco) e Avvisi (i motivi distinti: lo stesso fetch fallito
# lo dicono tutti i ruoli e si mostra una volta).
function Get-LezioniInProvaVista($Cfg, [string]$Radice) {
    $progetto = Get-ProgettoMemoria; $repoAdo = Get-RepoAdoMemoria
    $repos = @($Cfg.Mappa.aree | ForEach-Object { [string]$_.repo } | Select-Object -Unique)
    if ($repos.Count -eq 0) { $repos = @('comune') }
    $lezioni = [System.Collections.Generic.List[object]]::new(); $stabili = [System.Collections.Generic.List[object]]::new(); $tutte = [System.Collections.Generic.List[object]]::new(); $avvisi = [System.Collections.Generic.List[string]]::new(); $visti = @{}
    foreach ($ruolo in @($Cfg.Ruoli.PSObject.Properties.Name)) {
        foreach ($repo in $repos) {
            $m = Get-MemoriaDelRuolo -Radice $Radice -Ruolo $ruolo -Repo $repo -Progetto $progetto -RepoAdo $repoAdo
            foreach ($motivo in @($m.Motivi)) { if ([string]$motivo -notin $avvisi) { $avvisi.Add([string]$motivo) } }
            foreach ($f in @($m.File)) {
                if ($visti.ContainsKey("$ruolo|$($f.Nome)")) { continue }
                $visti["$ruolo|$($f.Nome)"] = $true
                foreach ($l in @(Get-LezioniConEtichetta -Develop $f.Develop -InProva $f.InProva)) {
                    $tutte.Add($l)
                    $voce = [pscustomobject]@{ Id = $l.Id; Ruolo = $ruolo; Repo = [string]$f.Nome; Situazione = $l.Situazione; Testo = [string]$l.Testo }
                    if ($l.InProva) { $lezioni.Add($voce) } else { $stabili.Add($voce) }
                }
            }
        }
    }
    [pscustomobject]@{ Lezioni = @($lezioni); Stabili = @($stabili); Conosciute = (ConvertTo-LezioniConosciute $tutte); Avvisi = @($avvisi) }
}

# Il repo di ogni card attiva, dalla mappa: serve a dire dove lavora una sessione.
function Get-RepoPerCard($Cfg, $Attive) {
    $r = @{}
    foreach ($c in @($Attive)) {
        $v = Find-VoceMappa -Mappa $Cfg.Mappa -Area $c.Area
        if ($v) { $r["$($c.Id)"] = [string]$v.repo }
    }
    $r
}

# ---- il modello --------------------------------------------------------------------------------------------------
# Oggetti, non stringhe: i due disegnatori (testo e HTML) leggono da qui e non decidono niente.

function Format-Token([int64]$N) {
    if ($N -lt 1000) { return "$N token" }
    "$(([double]$N / 1000).ToString('0.0', [cultureinfo]::InvariantCulture))k token"
}

# Il link alla card sulla board, o null se non si sa calcolare (config illeggibile): il numero resta testo.
function Get-UrlCardVista($Id) {
    try { Get-AdoUrlCard -Id ([int]$Id) } catch { $null }
}

function Get-SessioniVista($Stato, $Dati) {
    foreach ($k in @(Get-IdCardConSessione $Stato | ForEach-Object { [string]$_ })) {
        $s = $Stato[$k]['sessione']
        $task = Get-Campo $s 'task'
        $inizio = ConvertTo-DataUtc (Get-Campo $s 'inizio')
        $p = Get-ProgressoSessione -Id ([string](Get-Campo $s 'id')) -CartellaDati $CartellaDati
        [pscustomobject]@{
            Id = [int]$k
            UrlCard = (Get-UrlCardVista $k)
            SessioneId = [string](Get-Campo $s 'id')
            Titolo = if ($Dati -and $Dati.Titoli.ContainsKey($k)) { $Dati.Titoli[$k] } else { $null }
            Repo = if ($Dati -and $Dati.Repo.ContainsKey($k)) { $Dati.Repo[$k] } else { $null }
            StatoAdo = if ($Dati -and $Dati.Stati.ContainsKey($k)) { $Dati.Stati[$k] } else { $null }
            Ruolo = [string](Get-Campo $s 'ruolo')
            Task = if ($task) { $task } else { $null }
            TitoloTask = if ($task -and $Dati -and $Dati.TitoliTask.ContainsKey("$task")) { $Dati.TitoliTask["$task"] } else { $null }
            Minuti = if ($inizio) { [int][math]::Floor(((Get-Adesso) - $inizio).TotalMinutes) } else { $null }
            Viva = [bool](Test-SessioneViva -ProcessoId ([int](Get-Campo $s 'pid')) -Avvio (Get-Campo $s 'avvio'))
            Token = [int64]$p.Token
            TokenTesto = if ($p.Token -gt 0) { Format-Token $p.Token } else { $null }
            Azioni = @($p.Azioni)
            Avanzamento = if ($Dati -and $Dati.Avanzamento.ContainsKey($k)) { $Dati.Avanzamento[$k] } else { $null }
            Pr = if ($Dati -and $Dati.Prs.ContainsKey($k)) { $Dati.Prs[$k] } else { $null }
        }
    }
}

# Il gruppo in cui sta una card in coda: il tipo del motivo che ha deciso Decisioni, poi i casi senza motivo.
function Get-TipoCoda($R) {
    if ($R.Errore) { return 'altro' }
    if ($R.Motivo) { return [string](Get-Campo $R.Motivo 'Tipo') }
    'altro'
}

# La fase del flusso in cui sta una card, dallo stato sulla board: e solo il nome mostrato accanto al verbo dell'operatore.
function Get-FaseFlusso($Stati, $R) {
    switch (Get-ChiaveStato $Stati ([string]$R.Stato)) {
        { $_ -in 'bozza', 'nuova', 'daChiarire' } { return 'analisi' }
        { $_ -in 'pronto', 'inSviluppo' } { return 'sviluppo' }
        { $_ -in 'inRevisione', 'daUnire' } { return 'revisione' }
        'inDeployTest' { return 'deploy in Test' }
        'inCollaudo' { return 'collaudo' }
        'inProvaUmana' { return 'prova in Test' }
        'inFeature' { return 'feature branch' }
        { $_ -in 'daRilasciare', 'inRilascio' } { return 'rilascio' }
        default { return $null }
    }
}

# Il verbo mostrato per ogni attivita dell'operatore (quale attivita e lo decide Get-AttivitaOperatore in Decisioni).
$script:VerbiAttivita = @{ sblocca = 'Sblocca'; rispondi = 'Rispondi'; prova = 'Prova in Test'; rilascia = 'Rilascia' }

function Get-TestoCoda($R) {
    if ($R.Errore) { "non letta: $($R.Errore)" }
    elseif ($R.Motivo) { Format-MotivoCoda $R.Motivo }
    elseif ($R.Azioni -gt 0) { 'pronta al prossimo giro' }
    elseif ($R.Gesto) { 'aspetta la prova in Test del richiedente' }
    else { 'nessuna azione prevista' }
}

# Cosa deve fare una persona perche una predecessora non ancora unita si muova; $null se avanza da sola. Una card in Draft
# non la prende nessuno (le card create dagli agenti nascono li: va spostata in New), una in New senza il tag agenti
# nemmeno, e una rimossa tiene ferma la dipendente finche non si toglie il link (Test-PredecessoreUnito).
function Get-GestoPredecessore($Stati, $P, [int]$Dipendente) {
    $tag = @(Get-Campo $P 'Tag')
    switch (Get-ChiaveStato $Stati ([string]$P.Stato)) {
        'bozza' { return 'spostala in New' }
        'nuova' { if ($Stati.tagAgenti -notin $tag) { return "dalle il tag $($Stati.tagAgenti)" } }
        'rimossa' { return "togli il link Predecessor dalla #$Dipendente" }
    }
    $null
}

# Le predecessore che tengono ferma la card (il motivo 'predecessori' di Decisioni), ognuna con link, stato e il gesto
# che tocca a una persona. Nessuna se la card non aspetta predecessori.
function Get-AttesePredecessori($Stati, $R) {
    if (-not $R.Motivo -or (Get-Campo $R.Motivo 'Tipo') -ne 'predecessori') { return @() }
    @(foreach ($p in @(Get-Campo $R.Motivo 'Predecessori')) {
        if ($null -eq $p) { continue }
        [pscustomobject]@{ Id = [int]$p.Id; UrlCard = (Get-UrlCardVista $p.Id); Stato = [string]$p.Stato; Chiave = (Get-ChiaveStato $Stati ([string]$p.Stato)); Gesto = (Get-GestoPredecessore $Stati $p ([int]$R.Id)) }
    })
}

# Come sta una card nella catena: unita (il suo lavoro e in develop, lo dice Decisioni), in lavorazione (ha un ramo che
# avanza verso develop o una sessione), in coda.
# FeatureId (D52): la Feature della card che aspetta, per cui una predecessora In feature branch della stessa Feature vale come unita.
function Get-StatoNodoCatena($Stati, $P, $ConSessione, $FeatureId = $null) {
    if (Test-PredecessoreUnito $Stati $P $FeatureId) { return 'unita' }
    if ([int]$P.Id -in $ConSessione) { return 'lavorazione' }
    if ((Get-ChiaveStato $Stati ([string]$P.Stato)) -in (Get-StatiConRamo)) { return 'lavorazione' }
    'coda'
}

# Le card collegate da predecessori formano una catena: i suoi nodi in ordine di profondita (prima i predecessori).
# $Righe: per ogni card mia con predecessori, in qualunque stato e con o senza sessione, Id, Stato e Predecessori (Get-DatiAdo).
# Una card unita resta nella catena; la catena sparisce solo quando non ha piu nessuna card aperta (tutti i nodi sono uniti).
# $Dove: per id, dove sta la stessa card nella kanban (chi ce l'ha adesso o chi la prendera); le card fuori dalle righe lette
# mostrano solo lo stato sulla board.
# $StatoLocale: lo stato dello smistatore, da cui una card con riga prende prId e cartella (servono a dire se Ready to release e unita).
function Get-CateneVista($Righe, $Dati, $Stati, $ConSessione, $Dove, $StatoLocale = @{}) {
    $nodi = @{}; $statoBoard = @{}; $archi = [System.Collections.Generic.List[object]]::new(); $inFeatureNonUnita = @{}
    foreach ($r in $Righe) {
        if (@($r.Predecessori).Count -eq 0) { continue }
        $statoBoard["$($r.Id)"] = [string]$r.Stato
        $locale = if ($StatoLocale.ContainsKey("$($r.Id)")) { $StatoLocale["$($r.Id)"] } else { $null }
        $proprio = Get-StatoNodoCatena $Stati ([pscustomobject]@{ Id = $r.Id; Stato = $r.Stato; prId = $(if ($locale) { $locale['prId'] } else { $null }); cartella = $(if ($locale) { $locale['cartella'] } else { $null }) }) $ConSessione
        # un nodo gia segnato unita (da un'altra riga che lo ha come predecessore) non si declassa: l'esito non dipende dall'ordine
        if (-not ($nodi.ContainsKey("$($r.Id)") -and $nodi["$($r.Id)"] -eq 'unita')) { $nodi["$($r.Id)"] = $proprio }
        foreach ($p in @($r.Predecessori)) {
            $stato = Get-StatoNodoCatena $Stati $p $ConSessione (Get-Campo $r 'FeatureId')
            # D52: In feature branch e unita per la dipendente della stessa Feature e non per le altre: basta una dipendente per cui non lo e
            if ($stato -ne 'unita' -and (Get-ChiaveStato $Stati ([string]$p.Stato)) -eq 'inFeature') { $inFeatureNonUnita["$($p.Id)"] = $true }
            if (-not $statoBoard.ContainsKey("$($p.Id)")) { $statoBoard["$($p.Id)"] = [string]$p.Stato }
            if (-not $nodi.ContainsKey("$($p.Id)") -or $stato -eq 'unita') { $nodi["$($p.Id)"] = $stato }
            $archi.Add(@([int]$p.Id, [int]$r.Id))
        }
    }
    if ($nodi.Count -eq 0) { return @() }
    # un nodo In feature branch e unita solo se lo e per tutte le sue dipendenti (l'unita di un altro stato non dipende da chi guarda)
    foreach ($k in $inFeatureNonUnita.Keys) { if ($nodi[$k] -eq 'unita') { $nodi[$k] = 'lavorazione' } }
    $gruppo = @{}; foreach ($k in $nodi.Keys) { $gruppo[$k] = [int]$k }
    do {
        $cambiato = $false
        foreach ($e in $archi) {
            $m = [math]::Min($gruppo["$($e[0])"], $gruppo["$($e[1])"])
            foreach ($i in 0, 1) { if ($gruppo["$($e[$i])"] -ne $m) { $gruppo["$($e[$i])"] = $m; $cambiato = $true } }
        }
    } while ($cambiato)
    $profondita = @{}; foreach ($k in $nodi.Keys) { $profondita[$k] = 0 }
    for ($giro = 0; $giro -lt $nodi.Count; $giro++) {
        foreach ($e in $archi) { $profondita["$($e[1])"] = [math]::Max($profondita["$($e[1])"], $profondita["$($e[0])"] + 1) }
    }
    foreach ($g in @($gruppo.Values | Sort-Object -Unique)) {
        $ids = @($nodi.Keys | Where-Object { $gruppo[$_] -eq $g } | Sort-Object { $profondita[$_] }, { [int]$_ })
        if (@($ids | Where-Object { $nodi[$_] -ne 'unita' }).Count -eq 0) { continue }
        [pscustomobject]@{
            Nodi = @($ids | ForEach-Object {
                [pscustomobject]@{
                    Id = [int]$_; UrlCard = (Get-UrlCardVista $_); Stato = $nodi[$_]
                    Titolo = $(if ($Dati -and $Dati.Titoli.ContainsKey($_)) { $Dati.Titoli[$_] } else { $null })
                    StatoBoard = $statoBoard[$_]
                    Dove = $(if ($nodi[$_] -eq 'unita') { 'unita' } elseif ($Dove.ContainsKey($_)) { $Dove[$_] } else { $null })
                }
            })
        }
    }
}

# D52: le funzionalita, ognuna con la sua Feature, la card di chiusura (con il suo stato) e le sorelle. $Funzionalita: le funzionalita lette
# da Get-DatiAdo (New-FunzionalitaVista, una per Feature). Lo stato di ogni card e quello della board se la card e fra le attive, altrimenti
# quello letto con le figlie della Feature; $Dove dice dove sta adesso nella kanban (come per le catene). La card di chiusura e la prima.
function Get-FunzionalitaVista($Funzionalita, $Dati, $Stati, $Dove) {
    $voce = {
        param($Id, $Titolo, $StatoLetto, [bool]$EChiusura)
        $k = "$Id"
        $stato = if ($Dati -and $Dati.Stati.ContainsKey($k)) { [string]$Dati.Stati[$k] } else { [string]$StatoLetto }
        [pscustomobject]@{
            Id = [int]$Id; UrlCard = (Get-UrlCardVista $Id); EChiusura = $EChiusura
            Titolo = $(if ($Dati -and $Dati.Titoli.ContainsKey($k)) { $Dati.Titoli[$k] } elseif ($Titolo) { $Titolo } else { $null })
            Stato = $stato; Chiave = (Get-ChiaveStato $Stati $stato)
            Dove = $(if ($Dove.ContainsKey($k)) { $Dove[$k] } else { $null })
        }
    }
    foreach ($f in @($Funzionalita | Where-Object { $null -ne $_ } | Sort-Object Feature)) {
        $sorelle = @(foreach ($s in @($f.Sorelle | Sort-Object Id)) { & $voce $s.Id $s.Titolo $s.Stato $false })
        $chiusura = & $voce $f.Chiusura $null $f.StatoChiusura $true
        [pscustomobject]@{
            Feature = [int]$f.Feature; UrlCard = (Get-UrlCardVista $f.Feature); Titolo = [string]$f.Titolo; StatoFeature = [string]$f.StatoFeature
            Chiusura = $chiusura; Card = @($chiusura) + $sorelle
        }
    }
}

# Il prossimo giro di un'attivita pianificata ($Operazione = @{ Percorso; Nome }): lo stesso calcolo per lo smistatore e per il supervisore.
function Get-ProssimoGiroAttivita($Operazione) {
    $n = try { (Get-ScheduledTaskInfo -TaskPath $Operazione.Percorso -TaskName $Operazione.Nome -ErrorAction Stop).NextRunTime }
    catch { $null }
    $leggibile = $n -and $n.Year -gt 1999
    # Iso (con il fuso) serve al contatore della pagina, che lo confronta con l'ora del browser
    [pscustomobject]@{ Prossimo = $(if ($leggibile) { $n.ToString('yyyy-MM-dd HH:mm') } else { 'non leggibile' })
        Iso = $(if ($leggibile) { ([datetimeoffset]$n).ToString('o') } else { $null }) }
}

# Lo smistatore sta girando adesso? Lo dice l'attivita pianificata: $true o $false, $null se non si sa (attivita non trovata, cmdlet assenti).
function Get-SmistatoreInGiro {
    try {
        $o = Get-OperazionePianificata
        "$((Get-ScheduledTask -TaskPath $o.Percorso -TaskName $o.Nome -ErrorAction Stop).State)" -eq 'Running'
    }
    catch { $null }
}

# La quota per l'ufficio: il riepilogo della riga quota della vista (lo stesso dato) piu il quota.json letto, da cui l'ufficio sa di quale
# finestra e la pausa per il limite (5 ore o settimana). Senza riepilogo (quota non letta) niente.
function Get-QuotaPerUfficio($Riepilogo, $Letta) {
    if ($null -eq $Riepilogo) { return $null }
    $q = @{ Letta = $Letta }
    foreach ($p in $Riepilogo.PSObject.Properties) { $q[$p.Name] = $p.Value }
    $q
}

function Get-DatiGiro {
    $f = Get-FileLog $CartellaDati (Get-Date)
    $ultimo = if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Tail 1 -Encoding UTF8 } else { $null }
    $quando = if ($ultimo -and "$ultimo" -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d') { $Matches[0] } else { 'nessun log di oggi' }
    $p = Get-ProssimoGiroAttivita (Get-OperazionePianificata)
    [pscustomobject]@{ Ultimo = $quando; Prossimo = $p.Prossimo; ProssimoIso = $p.Iso }
}

# Il supervisore (D51) e un agente a parte: gira ogni pochi minuti come attivita pianificata e tiene i suoi problemi in supervisore.json,
# che la vista legge e non scrive mai. Un file che manca o che il supervisore sta riscrivendo (Get-Stato lancia dopo i tentativi) e
# "stato non leggibile": la pagina si disegna lo stesso, col prossimo giro che viene dalla pianificazione e non dal file.
function Get-DatiSupervisore {
    $nomi = Get-NomiOperazioniPianificate
    $prossimo = Get-ProssimoGiroAttivita @{ Percorso = (Get-OperazionePianificata).Percorso; Nome = $nomi.Supervisore }
    $dati = [pscustomobject]@{ Letto = $false; Ultimo = $null; Prossimo = $prossimo.Prossimo; ProssimoIso = $prossimo.Iso; Problemi = @(); Diagnosi = @(); Brief = $null }
    # il nome del file viene da Supervisione, la cartella e quella della vista (-CartellaDati)
    $percorso = Join-Path $CartellaDati (Split-Path -Leaf (Get-PercorsoSupervisorePredefinito))
    if (-not (Test-Path -LiteralPath $percorso)) { return $dati }
    try {
        # Get-Stato da @{} per un file vuoto o sparito nel frattempo: non e uno stato, e il supervisore lo salva sempre con tutti i campi
        $sup = Get-Stato -Percorso $percorso
        if ($sup.Count -eq 0) { return $dati }
        $ultima = ConvertTo-DataUtc (Get-Campo $sup 'ultimaEsecuzione')
        $aperti = Get-Campo $sup 'problemi'
        # con assenze > 0 il problema e aperto ma non si dice (Get-PianoAvvisi): la vista non lo conta ne lo mostra
        $problemi = @(if ($aperti) { foreach ($k in $aperti.Keys) {
            $p = $aperti[$k]
            if ([int](Get-Campo $p 'assenze') -gt 0) { continue }
            [pscustomobject]@{ Chiave = [string]$k; Testo = [string](Get-Campo $p 'testo'); Urgente = [bool](Get-Campo $p 'urgente'); PrimoVisto = (ConvertTo-DataUtc (Get-Campo $p 'primoVisto')) }
        } })
        $diagnosi = @(foreach ($d in @(Get-Campo $sup 'sessioniDiagnosi' | Where-Object { $null -ne $_ })) {
            $chiave = [string](Get-Campo $d 'chiave')
            $aperto = $problemi | Where-Object { $_.Chiave -eq $chiave } | Select-Object -First 1
            [pscustomobject]@{ Chiave = $chiave; Testo = $(if ($aperto -and $aperto.Testo) { $aperto.Testo } else { $chiave }) }
        })
    }
    catch { return $dati }
    $dati.Letto = $true
    $dati.Ultimo = if ($ultima) { $ultima.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { 'nessuna esecuzione' }
    # gli urgenti in cima, poi dal piu vecchio
    $dati.Problemi = @($problemi | Sort-Object @{ Expression = { -not $_.Urgente } }, PrimoVisto, Chiave)
    $dati.Diagnosi = $diagnosi
    $dati
}

# D53: la suite. Lo stato dell'aggiornamento e di aggiornamento.json, che scrive il supervisore: la vista lo legge e basta. L'interruttore
# dell'aggiornamento automatico e in impostazioni.json, che la vista scrive solo dal suo comando POST /automatico (cosi il pulsante mostra
# subito il valore nuovo, senza aspettare il giro del supervisore). Un file che non si legge non ferma la pagina.
function Get-DatiSuite {
    $automatico = $true
    try { $automatico = [bool](Get-Impostazioni $CartellaDati).Automatico } catch { }
    ConvertTo-ModelloSuite (Read-StatoAggiornamento $CartellaDati) $automatico
}

# $Lezioni sono le lezioni in prova gia lette (Get-LezioniInProvaVista, $null se non ancora) e $ErroreLezioni cosa e andato storto leggendole.
# $Conosciute sono le origini delle lezioni (Get-LezioniInProvaVista), $LetturaLezioni quando sono state lette, $null se non ancora, e $Stabili le lezioni gia confermate.
# Il registro invece e un file, e serve solo alla pagina HTML ($ConApprendimento): il riassunto si ricalcola solo se il file e cambiato,
# se sono arrivate lezioni nuove o se e cambiato il giorno (la finestra si sposta), non a ogni disegno.
function Get-ModelloVista($Stato, $Dati, $ErroreAdo, $Stati, $Build = $null, [string]$ErroreBuild = '', $Lezioni = $null, [string]$ErroreLezioni = '', [bool]$ConApprendimento = $false, $Conosciute = $null, $LetturaLezioni = $null, $Stabili = $null) {
    $inCorso = @(Get-SessioniVista $Stato $Dati)
    # la chiave dello stato sulla board colora l'etichetta "Stato:" della scheda
    foreach ($s in $inCorso) { $s | Add-Member -NotePropertyName Chiave -NotePropertyValue (Get-ChiaveStato $Stati ([string]$s.StatoAdo)) -Force }
    $conSessione = @($inCorso | ForEach-Object { $_.Id })
    $coda = @(); $catene = @(); $funzionalita = @(); $codaRuolo = @(); $fermano = @(); $nonFermano = @(); $pipeline = @()
    $ruoliColonne = Get-RuoliFlusso
    # dove sta ogni card nella kanban, per le catene
    $dove = @{}
    foreach ($s in $inCorso) { $dove["$($s.Id)"] = "$($s.Ruolo) al lavoro" }
    # una sessione con un ruolo che non e una colonna non sparisce: sta in Pipeline, col ruolo scritto
    foreach ($s in @($inCorso | Where-Object { $_.Ruolo -notin $ruoliColonne })) {
        $pipeline += [pscustomobject]@{ Id = $s.Id; UrlCard = $s.UrlCard; Titolo = $s.Titolo; Stato = $s.StatoAdo; Chiave = (Get-ChiaveStato $Stati ([string]$s.StatoAdo)); Testo = "sessione di $($s.Ruolo)"; Pr = $s.Pr }
        $dove["$($s.Id)"] = 'pipeline'
    }
    if (-not $ErroreAdo) {
        # una card che nel frattempo ha aperto una sessione e gia fra quelle in corso
        $righe = @($Dati.Coda | Where-Object { $_.Id -notin $conSessione })
        $coda = @(foreach ($r in $righe) {
            [pscustomobject]@{
                Id = $r.Id; UrlCard = (Get-UrlCardVista $r.Id); Titolo = $r.Titolo; Stato = $r.Stato; Chiave = (Get-ChiaveStato $Stati ([string]$r.Stato)); Tipo = (Get-TipoCoda $r); Ruolo = $r.Ruolo; Testo = (Get-TestoCoda $r)
                Avanzamento = $r.Avanzamento; Pr = $r.Pr; Predecessori = @(@($r.Predecessori) | ForEach-Object { [int]$_.Id })
            }
        })

        # La kanban: ogni card finisce in un posto solo. Prima l'operatore, poi la coda del ruolo, poi la pipeline.
        $chiusureInBozza = @{}
        foreach ($r in $righe) {
            $att = $r.Attivita
            $attese = @(Get-AttesePredecessori $Stati $r)
            # una predecessora ferma su una persona (Draft, New senza tag, rimossa) e una cosa da sbloccare, come un on-hold
            if (-not $att -and @($attese | Where-Object { $_.Gesto }).Count -gt 0) {
                $att = [pscustomobject]@{ Attivita = 'sblocca'; Testo = 'aspetta le card precedenti, ferme su una persona'; Ferma = $true }
            }
            # D52: la card di chiusura in Draft non e fra le card attive (nessuno la legge): lo dice una sorella In feature branch, con il motivo
            # chiusuraInBozza di Decisioni. La voce per l'operatore e una sola per card di chiusura, qualunque sia il numero di sorelle che lo dicono.
            $mc = $r.Motivo
            if ($mc -and (Get-Campo $mc 'Tipo') -eq 'chiusuraInBozza' -and -not $chiusureInBozza.ContainsKey("$(Get-Campo $mc 'Chiusura')")) {
                $idChiusura = [int](Get-Campo $mc 'Chiusura')
                $fc = Get-Campo $r 'Funzionalita'
                $statoChiusura = [string](Get-Campo $fc 'StatoChiusura')
                $chiusureInBozza["$idChiusura"] = $true
                $fermano += [pscustomobject]@{ Id = $idChiusura; UrlCard = (Get-UrlCardVista $idChiusura); Titolo = [string](Get-Campo $fc 'TitoloChiusura'); Attivita = 'sblocca'; Verbo = $script:VerbiAttivita['sblocca']
                    Fase = (Get-FaseFlusso $Stati ([pscustomobject]@{ Stato = $statoChiusura })); Stato = $statoChiusura; Chiave = (Get-ChiaveStato $Stati $statoChiusura)
                    Testo = (Format-MotivoCoda $mc); Pr = $null; Aspetta = @(); Gesto = [string](Get-Campo $mc 'Gesto') }
                $dove["$idChiusura"] = "tocca a te: $($script:VerbiAttivita['sblocca'])"
            }
            if ($att) {
                $verbo = $script:VerbiAttivita["$($att.Attivita)"]
                $testo = if ($att.Attivita -eq 'rispondi' -and $r.Domanda) { $r.Domanda } else { $att.Testo }
                $voce = [pscustomobject]@{ Id = $r.Id; UrlCard = (Get-UrlCardVista $r.Id); Titolo = $r.Titolo; Attivita = $att.Attivita; Verbo = $verbo; Fase = (Get-FaseFlusso $Stati $r); Stato = $r.Stato; Chiave = (Get-ChiaveStato $Stati ([string]$r.Stato)); Testo = $testo; Pr = $r.Pr; Aspetta = $attese; Gesto = $null; InAttesa = (@($Dati.InAttesa) -contains [int]$r.Id) }
                if ($att.Ferma) { $fermano += $voce } else { $nonFermano += $voce }
                $dove["$($r.Id)"] = "tocca a te: $verbo"
            }
            elseif ($r.Ruolo -and -not $r.Errore -and $r.Ruolo -in $ruoliColonne) {
                $testo = if ($r.Motivo) { Format-MotivoCoda $r.Motivo } else { 'parte al prossimo giro' }
                $codaRuolo += [pscustomobject]@{ Id = $r.Id; UrlCard = (Get-UrlCardVista $r.Id); Titolo = $r.Titolo; Stato = $r.Stato; Chiave = (Get-ChiaveStato $Stati ([string]$r.Stato)); Ruolo = $r.Ruolo; Testo = $testo; Avanzamento = $r.Avanzamento; Pr = $r.Pr; Aspetta = $attese }
                $dove["$($r.Id)"] = "in coda per $($r.Ruolo)"
            }
            else {
                # nessun agente la prende e non tocca a te: aspetta una pipeline, un blocco senza ruolo o un ruolo fuori elenco
                $testo = if ($r.Errore) { "non letta: $($r.Errore)" }
                    elseif ($r.Ruolo) { "$($r.Ruolo): $(if ($r.Motivo) { Format-MotivoCoda $r.Motivo } else { 'parte al prossimo giro' })" }
                    elseif ($r.Motivo) { Format-MotivoCoda $r.Motivo }
                    else { $null }
                $pipeline += [pscustomobject]@{ Id = $r.Id; UrlCard = (Get-UrlCardVista $r.Id); Titolo = $r.Titolo; Stato = $r.Stato; Chiave = (Get-ChiaveStato $Stati ([string]$r.Stato)); Testo = $testo; Pr = $r.Pr; Aspetta = $attese }
                $dove["$($r.Id)"] = 'pipeline'
            }
        }
        $catene = @(Get-CateneVista $Dati.Collegamenti $Dati $Stati $conSessione $dove $Stato)
        $funzionalita = @(Get-FunzionalitaVista @(Get-Campo $Dati 'Funzionalita') $Dati $Stati $dove)
    }
    $agenti = @(foreach ($ruolo in $ruoliColonne) {
        [pscustomobject]@{
            Ruolo = $ruolo
            Sessioni = @($inCorso | Where-Object { $_.Ruolo -eq $ruolo })
            Coda = @($codaRuolo | Where-Object { $_.Ruolo -eq $ruolo })
            Brief = $null   # il nome della pagina del brief: lo mette il ciclo se l'ha scritta
        }
    })
    $apprendimento = $null
    if ($ConApprendimento) {
        $riassunto = $null; $erroreRegistro = ''
        $chiave = '{0}|{1:yyyy-MM-dd}|{2}' -f (Get-ImprontaRegistroApprendimento -CartellaDati $CartellaDati), (Get-Date).ToUniversalTime(), $(if ($LetturaLezioni) { ([datetime]$LetturaLezioni).Ticks } else { '' })
        $calcola = { param($cartella, $conosciute) Get-RiassuntoApprendimento -Righe @(Get-RigheApprendimento -CartellaDati $cartella) -LezioniConosciute $conosciute }
        try { $riassunto = Get-RiassuntoDallaCache $script:CacheRiassunto $chiave $calcola @($CartellaDati, $Conosciute) }
        catch { $erroreRegistro = $_.Exception.Message; $riassunto = Get-RiassuntoApprendimento -Righe @() }
        $apprendimento = [pscustomobject]@{ Settimane = $riassunto.Settimane; Finestra = $riassunto.Finestra; Righe = $riassunto.Righe; Evitati = $riassunto.Evitati; ErroreRegistro = $erroreRegistro; Lezioni = $Lezioni; Stabili = $Stabili; ErroreLezioni = $ErroreLezioni; LetturaLezioni = $LetturaLezioni }
    }
    $giro = Get-DatiGiro
    [pscustomobject]@{
        Generata = Get-Date; ErroreAdo = $ErroreAdo; InCorso = $inCorso; Coda = $coda; Catene = $catene; Funzionalita = $funzionalita
        Agenti = $agenti; Operatore = [pscustomobject]@{ Fermano = $fermano; NonFermano = $nonFermano }; Pipeline = $pipeline
        Supervisore = (Get-DatiSupervisore); Suite = (Get-DatiSuite)
        UltimoGiro = $giro.Ultimo; ProssimoGiro = $giro.Prossimo; ProssimoGiroIso = $giro.ProssimoIso
        BuildAdo = $Build; ErroreBuild = $ErroreBuild; UrlPullRequest = ((Get-AdoUrlOrganizzazione) + '/_pulls'); Apprendimento = $apprendimento
    }
}

# ---- il testo nel terminale --------------------------------------------------------------------------------------

function Get-RigheInCorso($Modello) {
    foreach ($s in @($Modello.InCorso)) {
        $titolo = if ($s.Titolo) { " $($s.Titolo)" } else { '' }
        $repo = if ($s.Repo) { " [$($s.Repo)]" } else { '' }
        "#$($s.Id)$titolo$repo"
        $parti = [System.Collections.Generic.List[string]]::new()
        $parti.Add($s.Ruolo)
        if ($s.Task) {
            $tt = if ($s.TitoloTask) { " `"$($s.TitoloTask)`"" } else { '' }
            $parti.Add("task $($s.Task)$tt")
        }
        if ($null -ne $s.Minuti) { $parti.Add("$($s.Minuti) min") }
        $parti.Add($(if ($s.Viva) { 'processo vivo' } else { 'processo non attivo' }))
        if ($s.TokenTesto) { $parti.Add($s.TokenTesto) }
        '    ' + ($parti -join ', ')
        foreach ($a in $s.Azioni) { "    - $a" }
    }
}

function Get-TestoVista($Modello) {
    $righe = [System.Collections.Generic.List[string]]::new()
    $inCorso = @(Get-RigheInCorso $Modello)
    $righe.Add("== In corso ($(@($Modello.InCorso).Count)) ==")
    if ($inCorso.Count -eq 0) { $righe.Add('(nessuna sessione aperta)') } else { $righe.AddRange([string[]]$inCorso) }
    $righe.Add('')

    if ($Modello.ErroreAdo) {
        $righe.Add("ATTENZIONE: Azure DevOps non risponde ($($Modello.ErroreAdo)): le card in coda e da fare non si vedono, resta la parte locale.")
        $righe.Add('')
    }
    else {
        $righe.Add("== In coda / ferme ($(@($Modello.Coda).Count)) ==")
        if (@($Modello.Coda).Count -eq 0) { $righe.Add('(nessuna)') }
        foreach ($r in @($Modello.Coda)) {
            $ruolo = if ($r.Ruolo) { " $([char]0x2192) $($r.Ruolo)" } else { '' }
            $righe.Add("#$($r.Id) $($r.Titolo) ($($r.Stato))${ruolo}: $($r.Testo)")
        }
        $righe.Add('')

        $fare = @(@($Modello.Operatore.Fermano) + @($Modello.Operatore.NonFermano))
        $righe.Add("== Da fare tu ($($fare.Count)) ==")
        if ($fare.Count -eq 0) { $righe.Add('(niente)') }
        foreach ($f in $fare) { $righe.Add("#$($f.Id) $($f.Titolo): $($f.Verbo) - $($f.Testo)") }
        $righe.Add('')
    }
    $righe.Add("Ultimo giro dello smistatore: $($Modello.UltimoGiro) | prossimo giro: $($Modello.ProssimoGiro)")
    $sup = $Modello.Supervisore
    if ($sup.Letto) {
        $urgenti = @($sup.Problemi | Where-Object { $_.Urgente }).Count
        $righe.Add("Ultimo giro del supervisore: $($sup.Ultimo) | prossimo giro: $($sup.Prossimo) | problemi aperti: $(@($sup.Problemi).Count) ($urgenti urgenti) | diagnosi in corso: $(@($sup.Diagnosi).Count)")
    }
    else { $righe.Add("Ultimo giro del supervisore: stato non leggibile | prossimo giro: $($sup.Prossimo)") }
    if ($Modello.PSObject.Properties['Suite'] -and $Modello.Suite.Letto) {
        $s = $Modello.Suite
        $righe.Add("Suite: installata $($s.Installata) | disponibile $(if ($s.Disponibile) { $s.Disponibile } else { 'nessuna' }) | ultimo controllo $($s.UltimoControllo) | automatico $(if ($s.Automatico) { 'acceso' } else { 'spento' }) | $($s.Stato)")
    }
    $righe
}

# ---- la pagina HTML ----------------------------------------------------------------------------------------------

# Scrive in un file temporaneo accanto alla destinazione e lo rinomina: il browser legge la pagina vecchia o la nuova.
function Save-PaginaHtml([string]$Percorso, [string]$Testo) {
    $dir = Split-Path -Parent $Percorso
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $tmp = "$Percorso.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp, $Testo, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tmp, $Percorso, $true)
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

# Le pagine dello stream: una per sessione in corso, piu un ultimo disegno "sessione finita" per quelle uscite dal modello dopo
# il disegno precedente ($Precedenti ricorda l'ultima scheda vista di ciascuna). Il nome del file viene dall'id della sessione:
# se non e un nome sicuro la pagina non si scrive.
function Write-PagineSessioni($Modello, [string]$Cartella, [int]$Secondi, [hashtable]$Precedenti) {
    $ora = @{}
    foreach ($s in @($Modello.InCorso)) { if ("$($s.SessioneId)" -match '^[\w.-]+$') { $ora[[string]$s.SessioneId] = $s } }
    foreach ($id in @($Precedenti.Keys | Where-Object { -not $ora.ContainsKey($_) })) {
        $ev = Get-EventiSessione -Id $id -CartellaDati $CartellaDati
        Save-PaginaHtml (Join-Path $Cartella "sessione-$id.html") (New-PaginaSessione $Precedenti[$id] $ev.Eventi $ev.Saltati $true $Secondi)
        $Precedenti.Remove($id)
    }
    foreach ($id in $ora.Keys) {
        $ev = Get-EventiSessione -Id $id -CartellaDati $CartellaDati
        Save-PaginaHtml (Join-Path $Cartella "sessione-$id.html") (New-PaginaSessione $ora[$id] $ev.Eventi $ev.Saltati $false $Secondi)
        $Precedenti[$id] = $ora[$id]
    }
    # Le pagine delle sessioni finite restano a lungo ma non per sempre: sono file della vista, non dati dello smistatore.
    $limite = (Get-Date).AddDays(-7)
    foreach ($f in @(Get-ChildItem -LiteralPath $Cartella -File -Filter 'sessione-*.html' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limite })) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
}

# Le pagine dei brief: una per ruolo, dal file indicato da `brief` in ruoli.json (nella radice da cui gira la vista). Ritorna
# i ruoli con la pagina pronta (ruolo -> nome del file). Un brief che non c'e o non si converte non ha pagina ne link: nessun
# errore, la vista va avanti. La pagina si riscrive solo se manca o se il file e piu recente.
function Write-PagineBrief($Cfg, [string]$Radice, [string]$Cartella) {
    $pronte = @{}
    foreach ($r in $Cfg.Ruoli.PSObject.Properties) {
        $ruolo = [string]$r.Name
        if ($ruolo -notmatch '^[\w.-]+$') { continue }
        try {
            $sorgente = Join-Path $Radice ([string]$r.Value.brief)
            $nome = "brief-$ruolo.html"
            $pagina = Join-Path $Cartella $nome
            $file = Get-Item -LiteralPath $sorgente -ErrorAction Stop
            if ($file -isnot [IO.FileInfo]) { continue }
            if (-not (Test-Path -LiteralPath $pagina) -or $file.LastWriteTimeUtc -gt (Get-Item -LiteralPath $pagina).LastWriteTimeUtc) {
                $md = ConvertFrom-Markdown -LiteralPath $file.FullName -ErrorAction Stop
                Save-PaginaHtml $pagina (New-PaginaBrief (Get-TitoloRuolo $ruolo) ([string]$r.Value.brief) $md.Html)
            }
            $pronte[$ruolo] = $nome
        }
        catch { }
    }
    $pronte
}

# ---- il ciclo ----------------------------------------------------------------------------------------------------

$cfg = Get-Config -Radice $Radice -CartellaDati $CartellaDati
$PercorsoHtml = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PercorsoHtml)
$dati = $null; $erroreAdo = $null; $letturaAdo = $null; $build = $null; $erroreBuild = ''; $letturaBuild = $null; $tentativoBuild = $null; $lezioni = $null; $conosciute = $null; $stabili = $null; $erroreLezioni = ''; $letturaLezioni = $null; $tentativoLezioni = $null; $primoDisegno = $true; $script:CacheRiassunto = @{}; $paginePrecedenti = @{}
$codiceAttesa = $null
$stato = $null; $erroreStato = $null
# Il server locale solo con -Html -Segui: il token nasce qui, a ogni avvio del processo (anche dopo un riavvio per codice cambiato).
# Se la porta e occupata o la pagina non si chiama vista.html la vista va avanti da file, senza pulsante.
$server = $null; $tokenVista = ''
if ($Html -and $Segui) {
    if ((Split-Path -Leaf $PercorsoHtml) -ne 'vista.html') {
        Write-Host "ATTENZIONE: il server serve vista.html e la pagina si chiama $(Split-Path -Leaf $PercorsoHtml): niente server, pagina da file."
    }
    else {
        try {
            $tokenVista = New-TokenVista
            $tagAttesa = [string]$cfg.Stati.tagAttesa
            $server = Start-ServerVista $Porta (Split-Path -Parent $PercorsoHtml) $tokenVista { Start-GiroPianificato } -TogliAttesa { param($Id) [void](Set-AdoCard -Id $Id -TogliTag @($tagAttesa)) }.GetNewClosure() -ImpostaSoglia {
                # POST /soglia: la regola e in Decisioni (Get-OverrideSogliaQuota), qui solo i file
                param($Parametri)
                $r = Get-OverrideSogliaQuota $Parametri (Get-Quota -Percorso $script:PercorsoQuota) (Get-SogliaQuota -Percorso $script:PercorsoSoglia) (Get-Adesso)
                if ($r.Esito -eq 'ok') {
                    if ($null -eq $r.Override) { Remove-SogliaQuota -Percorso $script:PercorsoSoglia } else { Save-SogliaQuota -Override $r.Override -Percorso $script:PercorsoSoglia }
                }
                $r
            } -AggiornaSuite {
                # POST /aggiorna-suite (D53): la vista non aggiorna, scrive la richiesta e fa partire il supervisore, che e chi aggiorna
                Write-RichiestaAggiornamento -CartellaDati $script:CartellaDati
                $s = Start-SupervisorePianificato
                if ($s.Esito -eq 'errore') { @{ Esito = 'errore'; Messaggio = "richiesta scritta, ma il supervisore non parte: $($s.Messaggio)" } }
                elseif ($s.Esito -eq 'inEsecuzione') { @{ Esito = 'ok'; Messaggio = 'richiesta inviata: il supervisore sta girando, la legge al giro dopo' } }
                else { @{ Esito = 'ok'; Messaggio = 'richiesta inviata: il supervisore parte adesso' } }
            } -ImpostaAutomatico {
                # POST /automatico?attivo=0|1 (D53): impostazioni.json, fuori dal repo
                param($Attivo)
                Set-Impostazione -Nome 'aggiornamentoAutomatico' -Valore ([bool]$Attivo) -CartellaDati $script:CartellaDati
                @{ Esito = 'ok'; Messaggio = $(if ($Attivo) { 'aggiornamento automatico acceso' } else { 'aggiornamento automatico spento' }) }
            }
        }
        catch {
            $tokenVista = ''
            Write-Host "ATTENZIONE: il server sulla porta $Porta non parte ($($_.Exception.Message)): niente pulsante, pagina da file."
        }
    }
}
try {
do {
    if ($Segui) {
        $esito = Get-EsitoRiavvio $dateCodiceAvvio (Get-DateCodice $Radice) $codiceAttesa
        $codiceAttesa = $esito.Cambio
        if ($esito.Riavvia) {
            Write-Host 'Codice cambiato: la vista si riavvia'
            # la porta si libera prima di uscire: il figlio nuovo la riprende
            Stop-ServerVista $server
            # non si rilancia da solo (annida processi): esce col codice che il supervisore rilancia
            exit (Get-CodiceRiavvio)
        }
    }
    # stato.json si legge a ogni disegno; se lo smistatore lo sta riscrivendo e resta bloccato anche dopo i tentativi di Get-Stato,
    # la vista tiene quello letto al giro prima e non si ferma (lo dice una volta in console, non a ogni giro)
    try { $stato = Get-Stato -Percorso $script:PercorsoStato; $erroreStato = $null }
    catch {
        if ($_.Exception.Message -ne $erroreStato) { Write-Host "ATTENZIONE: $($_.Exception.Message): resta lo stato letto prima" }
        $erroreStato = $_.Exception.Message
        if ($null -eq $stato) { $stato = @{} }
    }
    if ($null -eq $letturaAdo -or ((Get-Adesso) - $letturaAdo).TotalSeconds -ge $SecondiAdo) {
        try { $dati = Get-DatiAdo $cfg $stato; $erroreAdo = $null }
        catch { $dati = $null; $erroreAdo = $_.Exception.Message }
        $letturaAdo = Get-Adesso
        # la lista bianca di POST /togli-attesa e l'ultima lettura: se ADO non risponde e vuota
        if ($server) { $server.Segnali.InAttesa = @(if ($dati) { $dati.InAttesa }) }
    }
    # le pipeline di tutti i progetti hanno la loro lettura, con lo stesso ritmo ma il proprio pulsante: se fallisce restano gli agenti,
    # e viceversa; l'ultima buona resta
    if ($null -eq $tentativoBuild -or ((Get-Adesso) - $tentativoBuild).TotalSeconds -ge $SecondiAdo) {
        try { $build = Get-AdoBuildPipeline; $erroreBuild = ''; $letturaBuild = Get-Date }
        catch { $erroreBuild = $_.Exception.Message }
        $tentativoBuild = Get-Adesso
    }
    # le lezioni in prova (git e Azure DevOps, una lettura per ruolo e per repo) hanno il loro timer e si leggono solo per la pagina HTML;
    # con -Segui il primo disegno non le aspetta; se falliscono restano le ultime buone (o nessuna) e la sezione dice l'errore
    $trascorsi = if ($null -eq $tentativoLezioni) { $null } else { ((Get-Adesso) - $tentativoLezioni).TotalSeconds }
    if (Test-LeggiLezioniOra $Html.IsPresent $Segui.IsPresent $primoDisegno $trascorsi $SecondiMemoria) {
        try {
            $l = Get-LezioniInProvaVista $cfg $Radice
            $lezioni = $l.Lezioni; $stabili = $l.Stabili; $conosciute = $l.Conosciute; $erroreLezioni = (@($l.Avvisi) -join '; '); $letturaLezioni = Get-Date
        }
        catch { $erroreLezioni = $_.Exception.Message }
        $tentativoLezioni = Get-Adesso
    }
    $modello = Get-ModelloVista $stato $dati $erroreAdo $cfg.Stati $build $erroreBuild $lezioni $erroreLezioni $Html $conosciute $letturaLezioni $stabili
    $modello | Add-Member LetturaBuild $letturaBuild; $modello | Add-Member SecondiAdo $SecondiAdo
    # la quota (D51) si rilegge a ogni disegno: uso, soglia effettiva, bypass e blocco. Se non si legge la riga non c'e e la pagina va avanti.
    $quotaVista = $null
    $quotaLetta = $null
    try { $quotaLetta = Get-Quota -Percorso $script:PercorsoQuota; $quotaVista = [pscustomobject](Get-RiepilogoQuota @{ Quota = $quotaLetta; Adesso = (Get-Adesso).ToString('o'); Limiti = $cfg.Limiti; OverrideQuota = (Get-SogliaQuota -Percorso $script:PercorsoSoglia) }) }
    catch { Write-Host "ATTENZIONE: la quota non si legge: $($_.Exception.Message)" }
    $modello | Add-Member Quota $quotaVista
    if ($Html) {
        $brief = Write-PagineBrief $cfg $Radice (Split-Path -Parent $PercorsoHtml)
        foreach ($a in $modello.Agenti) { if ($brief.ContainsKey($a.Ruolo)) { $a.Brief = $brief[$a.Ruolo] } }
        if ($brief.ContainsKey('supervisore')) { $modello.Supervisore.Brief = $brief['supervisore'] }
        Save-PaginaHtml $PercorsoHtml (New-PaginaVista $modello $Secondi $tokenVista)
        # l'ufficio legge gli stessi dati della vista: sessioni, coda, voci per Titolare, stato locale, quota e se lo smistatore gira.
        # ufficio.json e il dato, che la pagina rilegge da sola; ufficio.html porta lo stesso dato incorporato (per il primo disegno)
        $ruoliUfficio = @($cfg.Ruoli.PSObject.Properties.Name | Where-Object { $_ -ne 'supervisore' })
        $modelloUfficio = Get-ModelloUfficio -Ruoli $ruoliUfficio -Flusso (Get-RuoliFlusso) -InCorso $modello.InCorso -Coda $modello.Coda -Agenti $modello.Agenti `
            -Operatore $modello.Operatore -Stato $stato -Adesso (Get-Adesso) -Quota (Get-QuotaPerUfficio $modello.Quota $quotaLetta) -ErroreAdo ([string]$modello.ErroreAdo) -Secondi $Secondi `
            -Smistatore @{ InGiro = (Get-SmistatoreInGiro); Ultimo = $modello.UltimoGiro; Prossimo = $modello.ProssimoGiro }
        $cartellaPagine = Split-Path -Parent $PercorsoHtml
        Save-PaginaHtml (Join-Path $cartellaPagine 'ufficio.json') (ConvertTo-JsonUfficio $modelloUfficio)
        Save-PaginaHtml (Join-Path $cartellaPagine 'ufficio.html') (New-PaginaUfficio $modelloUfficio)
        Write-PagineSessioni $modello (Split-Path -Parent $PercorsoHtml) $Secondi $paginePrecedenti
        if ($primoDisegno) {
            Write-Host "Pagina scritta in $PercorsoHtml$(if ($Segui) { ", si aggiorna ogni $Secondi secondi" })"
            $indirizzo = if ($server) { "http://localhost:$Porta/vista.html" } else { $PercorsoHtml }
            if ($server) { Write-Host "Pagina servita su $indirizzo" }
            if ($Apri) { Start-Process -FilePath $indirizzo }
        }
    }
    else {
        if ($Segui) { Clear-Host }
        foreach ($riga in (Get-TestoVista $modello)) { Write-Host $riga }
    }
    $primoDisegno = $false
    # le lezioni non lette al primo disegno si leggono subito, senza aspettare il prossimo giro
    if ($Segui -and $Html -and $null -eq $tentativoLezioni) { continue }
    # fra un disegno e l'altro il server serve le richieste in attesa (a scatti di 200 ms), poi si ridisegna in orario
    if ($Segui) { if ($server) { Invoke-RichiesteVista $server $Secondi } else { Start-Sleep -Seconds $Secondi } }
    # "Aggiorna agenti e card" dalla pagina: Azure DevOps e le lezioni in prova si rileggono al disegno subito dopo, senza aspettare -SecondiAdo e -SecondiMemoria
    if ($server -and $server.Segnali.Aggiorna) { $server.Segnali.Aggiorna = $false; $letturaAdo = $null; $tentativoLezioni = $null }
    # "Aggiorna pipeline": solo le pipeline
    if ($server -and $server.Segnali.AggiornaPipeline) { $server.Segnali.AggiornaPipeline = $false; $tentativoBuild = $null }
} while ($Segui)
}
finally { Stop-ServerVista $server }
