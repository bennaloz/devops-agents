#requires -Version 7
# La riga di comando del mentore (D46): l'unico modo di toccare i file della memoria dei ruoli. Il formato, il tetto e gli
# id li decide Memoria.psm1; dove sta la memoria e da che base si scrive lo dice MemoriaRepo.psm1; qui ci sono i file del
# worktree, il commit, il push e la PR.
#   memoria.ps1 leggi <ruolo> <repo>       le lezioni di comune.md e <repo>.md, stabili e in prova
#   <JSON su stdin> | memoria.ps1 scrivi <ruolo> <repo|comune>     { "situazione", "cosaFare", "perche", "card" }
#   <JSON su stdin> | memoria.ps1 rivedi <id>                       gli stessi quattro campi, stesso id
#   memoria.ps1 togli <id>
#   <testo su stdin> | memoria.ps1 conflitto <card>   la correzione contraddice una regola scritta: nessuna lezione,
#                                                     un commento sulla card e una nota nella PR della memoria
# Il testo arriva solo da stdin (come per card.ps1): da argomento lo altererebbe l'interprete dei comandi.
# -Worktree e -Sorgente servono ai test: di norma stanno nei loro posti fissi.
param(
    [Parameter(Position = 0)][string]$Comando,
    [Parameter(Position = 1)][string]$Argomento,
    [Parameter(Position = 2)][string]$Argomento2,
    [string]$Worktree = 'C:\develop\GIT\_wt\DevOps.Agents\memoria',
    # Il repo da cui nasce il worktree se manca, e da cui si legge: la copia principale degli attrezzi.
    [string]$Sorgente
)

foreach ($m in 'Comune', 'Config', 'Ado', 'Card', 'Worktree', 'Memoria', 'MemoriaRepo', 'Stato') {
    Import-Module (Join-Path $PSScriptRoot "$m.psm1") -Global
}

$script:TitoloPr = 'memoria dei ruoli: lezioni in prova (D46)'
$script:RuoloCommento = 'mentore'

function New-ContestoMemoria {
    param([Parameter(Mandatory)][string]$Worktree, [string]$Sorgente)
    $config = Get-Config
    [pscustomobject]@{
        Worktree = $Worktree
        Sorgente = $(if ($Sorgente) { $Sorgente } else { (Split-Path -Parent $PSScriptRoot) })
        Progetto = Get-ProgettoMemoria
        Repo = Get-RepoAdoMemoria
        # <repo> di scrivi e leggi: comune o un repo di mappa.json, col nome esatto
        Repos = @($config.Mappa.aree | ForEach-Object { [string]$_.repo } | Select-Object -Unique)
        Ruoli = @($config.Ruoli.PSObject.Properties.Name)
        Tetto = [int]$config.Limiti.tettoMemoria
        AttesaMutexSecondi = 120
    }
}

# ---- controlli, prima di toccare git e Azure DevOps ---------------------------------------------------------------

function Assert-Ruolo($Ctx, [string]$Ruolo) {
    if ($Ruolo -notin $Ctx.Ruoli) { throw "ruolo sconosciuto: '$Ruolo' (i ruoli sono le chiavi di config/ruoli.json: $($Ctx.Ruoli -join ', '))" }
}

# <repo|comune> diventa il nome di un file: solo i repo di mappa.json (nome esatto, maiuscole comprese) e comune, cosi
# niente esce dalla cartella del ruolo e nessun file nasce da un refuso.
function Assert-DoveMemoria($Ctx, [string]$Nome) {
    if ($Nome -cne 'comune' -and $Nome -cnotin $Ctx.Repos) {
        throw "repo sconosciuto: '$Nome' (comune o un repo di config/mappa.json: $($Ctx.Repos -join ', '))"
    }
}

function Assert-Campi($Campi) {
    $errori = @(Test-CampiLezione $Campi)
    if ($errori.Count -gt 0) { throw "lezione rifiutata: $($errori -join '; ')" }
}

function Get-RuoloDaId($Ctx, [string]$Id) {
    if ($Id -notmatch '^(.+)-\d+$') { throw "id di lezione non valido: '$Id' (la forma e <ruolo>-<NNN>)" }
    Assert-Ruolo $Ctx $Matches[1]
    $Matches[1]
}

# ---- il worktree fisso e il mutex ---------------------------------------------------------------------------------

function Get-NomeMutexMemoria($Ctx) {
    $chiave = [IO.Path]::GetFullPath($Ctx.Worktree).Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($chiave))
    'Global\DevOps.Agents.Memoria-' + ([Convert]::ToHexString($hash).Substring(0, 16).ToLowerInvariant())
}

# Due mentori che scrivono insieme si metterebbero i piedi sul worktree: la seconda scrittura aspetta la prima.
function Invoke-ConMutex($Ctx, [scriptblock]$Blocco) {
    $m = [System.Threading.Mutex]::new($false, (Get-NomeMutexMemoria $Ctx))
    $preso = $false
    try {
        try { $preso = $m.WaitOne([TimeSpan]::FromSeconds($Ctx.AttesaMutexSecondi)) }
        catch [System.Threading.AbandonedMutexException] { $preso = $true }   # il mentore precedente e morto a meta
        if (-not $preso) { throw "un'altra scrittura della memoria e in corso da piu di $($Ctx.AttesaMutexSecondi) secondi: riprova fra poco" }
        & $Blocco
    }
    finally {
        if ($preso) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

# Il worktree fisso deve essere davvero un worktree registrato del repo sorgente: una cartella qualunque allo stesso
# percorso non e nostra e non la si tocca. Se la cartella e sparita ma git la ricorda, git worktree add si rifiuterebbe
# (il ramo risulta ancora in uso): si ripulisce con prune e si ricrea.
function Assert-WorktreeMemoria($Ctx) {
    $registrato = Get-WorktreeRegistrato $Ctx.Sorgente $Ctx.Worktree
    if (Test-Path -LiteralPath $Ctx.Worktree) {
        if (-not $registrato) { throw "la cartella $($Ctx.Worktree) esiste ma non e un worktree registrato di $($Ctx.Sorgente): non la tocco" }
        return
    }
    if ($registrato) { Invoke-Git $Ctx.Sorgente 'worktree', 'prune' | Out-Null }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Ctx.Worktree) | Out-Null
    Invoke-Git $Ctx.Sorgente 'fetch', 'origin' | Out-Null
    # il ramo lo posiziona Enter-BaseMemoria prima di ogni scrittura: qui basta un punto di partenza
    Invoke-Git $Ctx.Sorgente 'worktree', 'add', '--no-track', '-B', (Get-RamoMemoria), $Ctx.Worktree, 'origin/develop' | Out-Null
}

# Prepara il worktree per scrivere, dalla base che dice Get-BaseScrittura (PR attiva: il ramo pubblicato; ramo unito o
# chiuso da una PR: develop, e il push forza con --force-with-lease, che rifiuta se qualcuno ha toccato il ramo dopo il
# fetch; ramo con commit che nessuna PR copre: il ramo, e la PR si crea dopo). Se le PR non si leggono lancia, prima di
# toccare niente. Restituisce la PR attiva (o $null) e se il push deve forzare.
function Enter-BaseMemoria($Ctx) {
    Assert-WorktreeMemoria $Ctx
    Invoke-Git $Ctx.Worktree 'fetch', '--prune', 'origin' | Out-Null
    $base = Get-BaseScrittura -Cartella $Ctx.Worktree -Progetto $Ctx.Progetto -RepoAdo $Ctx.Repo
    # -f: un tentativo fallito prima potrebbe aver lasciato file modificati; la base buona e quella pubblicata
    Invoke-Git $Ctx.Worktree 'checkout', '-f', '--no-track', '-B', (Get-RamoMemoria), $base.Base | Out-Null
    Invoke-Git $Ctx.Worktree 'clean', '-fdq', '--', (Get-CartellaMemoria) | Out-Null
    $base
}

function Get-PercorsoFileMemoria($Ctx, [string]$Ruolo, [string]$Nome) { Join-Path $Ctx.Worktree (Get-PercorsoMemoria -Ruolo $Ruolo -Nome $Nome) }

function Read-FileMemoria([string]$Percorso) {
    if (Test-Path -LiteralPath $Percorso) { [IO.File]::ReadAllText($Percorso, [Text.UTF8Encoding]::new($false)) } else { $null }
}

function Write-FileMemoria([string]$Percorso, [string]$Testo) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Percorso) | Out-Null
    [IO.File]::WriteAllText($Percorso, $Testo, [Text.UTF8Encoding]::new($false))
}

# Il riassunto dell'apprendimento per la descrizione: la finestra e la costante di Get-RiassuntoApprendimento (la stessa della
# vista), sul registro nella cartella dati (il mentore parte con ATTREZZI_DATI, lo imposta Start-SessioneRuolo). Le origini
# delle lezioni, per dire quali hanno evitato un blocco, sono quelle di tutte le lezioni del worktree, stabili e in prova.
# Registro assente o illeggibile: nessun riassunto, e la lezione si scrive lo stesso: la descrizione e un contorno, non deve
# fermare la memoria.
function Get-RiassuntoPerPr($Ctx) {
    try {
        $radice = Join-Path $Ctx.Worktree (Get-CartellaMemoria)
        $lezioni = if (Test-Path -LiteralPath $radice) { @(Get-ChildItem -LiteralPath $radice -Filter '*.md' -File -Recurse | ForEach-Object { Read-Lezioni (Read-FileMemoria $_.FullName) }) } else { @() }
        Get-RiassuntoApprendimento -Righe @(Get-RigheApprendimento) -LezioniConosciute (ConvertTo-LezioniConosciute $lezioni)
    }
    catch { $null }
}

# Le lezioni del worktree che su develop non ci sono identiche: sono la parte in prova, che la descrizione della PR elenca.
function Get-LezioniInProvaWorktree($Ctx) {
    $radice = Join-Path $Ctx.Worktree (Get-CartellaMemoria)
    if (-not (Test-Path -LiteralPath $radice)) { return @() }
    foreach ($f in Get-ChildItem -LiteralPath $radice -Filter '*.md' -File -Recurse) {
        $rel = ($f.FullName.Substring($Ctx.Worktree.TrimEnd('\', '/').Length + 1)) -replace '\\', '/'
        Get-LezioniConEtichetta -Develop (Get-TestoGit $Ctx.Worktree 'origin/develop' $rel) -InProva (Read-FileMemoria $f.FullName) |
            Where-Object InProva
    }
}

# La parte comune delle tre scritture e di conflitto: base, modifica, commit, push, PR. $Modifica riceve il contesto e
# lancia un errore se non puo procedere (prima del commit: niente resta a meta). $Nota e la nota di conflitto, se c'e:
# in quel caso il commit puo essere vuoto, perche la PR ha bisogno di un commit sul ramo.
# Restituisce Id (quello che ha restituito $Modifica) e PrErrore. Un errore prima del push lancia; un errore dopo il push
# (la PR che non si crea o non si aggiorna) no: la lezione e pubblicata, e chi richiama deve poterlo dire senza far
# ripetere la scrittura. La PR si sistema alla scrittura dopo: il ramo con commit che nessuna PR copre riparte da li.
function Save-ModificaMemoria($Ctx, [scriptblock]$Modifica, [string]$Messaggio, [string]$Nota) {
    Invoke-ConMutex $Ctx {
        $base = Enter-BaseMemoria $Ctx
        $esito = & $Modifica $Ctx
        Invoke-Git $Ctx.Worktree 'add', '-A' | Out-Null
        $cambiato = (Invoke-Git $Ctx.Worktree 'diff', '--cached', '--quiet' -ConsentiErrore).Codice -ne 0
        if ($cambiato) { Invoke-Git $Ctx.Worktree 'commit', '-q', '-m', $Messaggio | Out-Null }
        elseif ($Nota) { Invoke-Git $Ctx.Worktree 'commit', '-q', '--allow-empty', '-m', $Messaggio | Out-Null }
        $refspec = "$(Get-RamoMemoria):$(Get-RamoMemoria)"
        $spinta = if ($base.Forza) { @('push', '-q', '--force-with-lease', 'origin', $refspec) } else { @('push', '-q', 'origin', $refspec) }
        Invoke-Git $Ctx.Worktree $spinta | Out-Null

        $prErrore = $null
        try {
            $note = @()
            if ($base.Pr) { $note += @(Get-NoteConflitto (Get-AdoDescrizionePr -Progetto $Ctx.Progetto -Repo $Ctx.Repo -Id $base.Pr.Id)) }
            if ($Nota) { $note += $Nota }
            $descrizione = New-DescrizionePrMemoria -Limite (Get-AdoLimiteTestoPr) -LezioniInProva @(Get-LezioniInProvaWorktree $Ctx) -Conflitti $note -Riassunto (Get-RiassuntoPerPr $Ctx)
            if ($base.Pr) { Set-AdoDescrizionePr -Progetto $Ctx.Progetto -Repo $Ctx.Repo -Id $base.Pr.Id -Descrizione $descrizione }
            else { [void](New-AdoPr -Progetto $Ctx.Progetto -Repo $Ctx.Repo -Ramo (Get-RamoMemoria) -Titolo $script:TitoloPr -Descrizione $descrizione) }
        }
        catch { $prErrore = ($_.Exception.Message -split '\s*\r?\n\s*') -join ' ' }
        [pscustomobject]@{ Id = $esito; PrErrore = $prErrore }
    }
}

# Il messaggio di scrivi, rivedi e togli. Con la PR non aggiornata dice comunque che la lezione e scritta, e il comando
# esce con 0: il mentore non deve riprovare, e creerebbe doppioni.
function Get-MessaggioEsito($Esito, [string]$Verbo) {
    if ($Esito.PrErrore) { "lezione $($Esito.Id) scritta; PR non aggiornata: $($Esito.PrErrore)" } else { "Lezione $($Esito.Id) $Verbo." }
}

# ---- i comandi ----------------------------------------------------------------------------------------------------

function Invoke-MemoriaScrivi($Ctx, [string]$Ruolo, [string]$Dove, $Campi) {
    Assert-Ruolo $Ctx $Ruolo
    Assert-DoveMemoria $Ctx $Dove
    Assert-Campi $Campi
    $modifica = {
        param($c)
        $percorso = Get-PercorsoFileMemoria $c $Ruolo $Dove
        $testo = Read-FileMemoria $percorso
        if (Test-MemoriaPiena -Testo $testo -Tetto $c.Tetto) {
            throw ("$(Get-PercorsoMemoria -Ruolo $Ruolo -Nome $Dove) ha gia $(@(Read-Lezioni $testo).Count) lezioni (tetto $($c.Tetto)): consolida prima di aggiungere. " +
                'Unisci i doppioni (rivedi e togli), e per le lezioni confermate piu volte proponi nella PR la promozione a regola ' +
                '(CLAUDE.md del repo o brief del ruolo) togliendole dalla memoria.')
        }
        # un id non si riusa: conta tutta la storia (develop, ramo in prova, reflog), non solo i file di oggi
        $id = Get-ProssimoIdLezione -Ruolo $Ruolo -Testi @(Get-IntestazioniStoricheRuolo -Cartella $c.Worktree -Ruolo $Ruolo)
        $blocco = ConvertTo-TestoLezione -Id $id -Situazione ([string]$Campi.situazione).Trim() -CosaFare ([string]$Campi.cosaFare).Trim() `
            -Perche ([string]$Campi.perche).Trim() -Card ([string]$Campi.card).Trim()
        Write-FileMemoria $percorso (Add-LezioneAlTesto -Testo $testo -Lezione $blocco)
        $id
    }
    Save-ModificaMemoria $Ctx $modifica "chore(memoria): lezione per $Ruolo in $Dove (card $(([string]$Campi.card).Trim()))" $null
}

# Rivedere e togliere cercano l'id in tutti i file del ruolo: la lezione puo stare in comune.md o in un <repo>.md.
function Find-FileDellaLezione($Ctx, [string]$Ruolo, [string]$Id) {
    $dir = Join-Path $Ctx.Worktree (Get-CartellaMemoria $Ruolo)
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.md' -File) {
        if (@(Read-Lezioni (Read-FileMemoria $f.FullName) | Where-Object Id -eq $Id).Count -gt 0) { return $f.FullName }
    }
    $null
}

function Invoke-MemoriaRivedi($Ctx, [string]$Id, $Campi) {
    $ruolo = Get-RuoloDaId $Ctx $Id
    Assert-Campi $Campi
    $modifica = {
        param($c)
        $file = Find-FileDellaLezione $c $ruolo $Id
        if (-not $file) { throw "non c'e nessuna lezione con id '$Id'" }
        $blocco = ConvertTo-TestoLezione -Id $Id -Situazione ([string]$Campi.situazione).Trim() -CosaFare ([string]$Campi.cosaFare).Trim() `
            -Perche ([string]$Campi.perche).Trim() -Card ([string]$Campi.card).Trim()
        Write-FileMemoria $file (Set-LezioneNelTesto -Testo (Read-FileMemoria $file) -Id $Id -Lezione $blocco)
        $Id
    }
    Save-ModificaMemoria $Ctx $modifica "chore(memoria): rivede la lezione $Id" $null
}

function Invoke-MemoriaTogli($Ctx, [string]$Id) {
    $ruolo = Get-RuoloDaId $Ctx $Id
    $modifica = {
        param($c)
        $file = Find-FileDellaLezione $c $ruolo $Id
        if (-not $file) { throw "non c'e nessuna lezione con id '$Id'" }
        Write-FileMemoria $file (Remove-LezioneDalTesto -Testo (Read-FileMemoria $file) -Id $Id)
        $Id
    }
    Save-ModificaMemoria $Ctx $modifica "chore(memoria): toglie la lezione $Id" $null
}

function Invoke-MemoriaConflitto($Ctx, [int]$Card, [string]$Testo) {
    if ([string]::IsNullOrWhiteSpace($Testo)) { throw 'manca il testo del conflitto (va dato su stdin): quale regola scritta contraddice la correzione' }
    $nota = "Card ${Card}: $(($Testo.Trim() -split '\s*\r?\n\s*') -join ' ')"
    $r = Save-ModificaMemoria $Ctx { param($c) } "chore(memoria): nota di conflitto per la card $Card" $nota
    # la nota vive solo nella PR: se non ci e arrivata si fallisce prima di commentare la card, e il tentativo dopo non fa doppioni
    if ($r.PrErrore) { throw "la nota di conflitto non e nella PR della memoria: $($r.PrErrore)" }
    [void](Add-CardCommento -Id $Card -Ruolo $script:RuoloCommento -Testo $Testo.Trim())
    "Nota aggiunta alla PR della memoria e commento sulla card $Card."
}

# Le lezioni di comune.md e <repo>.md del ruolo, come le serve MemoriaRepo (develop, e il ramo in prova solo con una PR
# attiva). Se ha dovuto ripiegare lo dice in coda: il mentore sa che sta leggendo meno di quanto c'e.
function Invoke-MemoriaLeggi($Ctx, [string]$Ruolo, [string]$Repo) {
    Assert-Ruolo $Ctx $Ruolo
    Assert-DoveMemoria $Ctx $Repo
    $m = Get-MemoriaDelRuolo -Radice $Ctx.Sorgente -Ruolo $Ruolo -Repo $Repo -Progetto $Ctx.Progetto -RepoAdo $Ctx.Repo
    $sezioni = @(foreach ($f in $m.File) {
            $lezioni = @(Get-LezioniConEtichetta -Develop $f.Develop -InProva $f.InProva)
            $corpo = if ($lezioni.Count -gt 0) { (ConvertTo-TestoLezioni $lezioni).TrimEnd() } else { '(nessuna lezione)' }
            "## memoria di $Ruolo, $($f.Nome):`n$corpo"
        })
    if (-not $m.Disponibile) { $sezioni = @('(memoria non disponibile)') }
    (@($sezioni) + @($m.Motivi | ForEach-Object { "($_)" })) -join "`n`n"
}

# ---- la riga di comando: non parte quando lo script e caricato con il punto (i test) ---------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    try {
        # stdin come UTF-8: le lezioni hanno accenti, e la tabella della console li altererebbe
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
        $leggiStdin = { ([Console]::In.ReadToEnd()).TrimEnd("`r", "`n") }
        $leggiCampi = {
            $t = & $leggiStdin
            if ([string]::IsNullOrWhiteSpace($t)) { throw 'manca il JSON della lezione su stdin: { "situazione", "cosaFare", "perche", "card" }' }
            try { $t | ConvertFrom-Json } catch { throw "stdin non e JSON valido: $($_.Exception.Message)" }
        }
        switch ($Comando) {
            'leggi' {
                if (-not $Argomento -or -not $Argomento2) { throw 'uso: leggi <ruolo> <repo>' }
                Invoke-MemoriaLeggi (New-ContestoMemoria -Worktree $Worktree -Sorgente $Sorgente) $Argomento $Argomento2
            }
            'scrivi' {
                if (-not $Argomento -or -not $Argomento2) { throw 'uso: scrivi <ruolo> <repo|comune> (il JSON su stdin)' }
                $ctx = New-ContestoMemoria -Worktree $Worktree -Sorgente $Sorgente
                # i controlli che non vogliono git ne rete vengono prima di tutto
                Assert-Ruolo $ctx $Argomento; Assert-DoveMemoria $ctx $Argomento2
                $campi = & $leggiCampi
                Assert-Campi $campi
                Get-MessaggioEsito (Invoke-MemoriaScrivi $ctx $Argomento $Argomento2 $campi) 'scritta'
            }
            'rivedi' {
                if (-not $Argomento) { throw 'uso: rivedi <id> (il JSON su stdin)' }
                $ctx = New-ContestoMemoria -Worktree $Worktree -Sorgente $Sorgente
                [void](Get-RuoloDaId $ctx $Argomento)
                $campi = & $leggiCampi
                Assert-Campi $campi
                Get-MessaggioEsito (Invoke-MemoriaRivedi $ctx $Argomento $campi) 'rivista'
            }
            'togli' {
                if (-not $Argomento) { throw 'uso: togli <id>' }
                Get-MessaggioEsito (Invoke-MemoriaTogli (New-ContestoMemoria -Worktree $Worktree -Sorgente $Sorgente) $Argomento) 'tolta'
            }
            'conflitto' {
                $card = 0
                if (-not [int]::TryParse($Argomento, [ref]$card) -or $card -le 0) { throw 'uso: conflitto <id della card> (il testo su stdin)' }
                # in una sessione di agente la card la imposta lo smistatore (ATTREZZI_CARD), come per card.ps1: una sessione non
                # commenta le card degli altri. Fuori da una sessione (Titolare a mano) la variabile non c'e e vale l'argomento.
                if (-not [string]::IsNullOrWhiteSpace($env:ATTREZZI_CARD) -and "$card" -ne $env:ATTREZZI_CARD.Trim()) {
                    throw "conflitto vale solo per la card della sessione (ATTREZZI_CARD=$($env:ATTREZZI_CARD)), non per la $card"
                }
                Invoke-MemoriaConflitto (New-ContestoMemoria -Worktree $Worktree -Sorgente $Sorgente) $card (& $leggiStdin)
            }
            default { throw "comando sconosciuto: '$Comando' (leggi | scrivi | rivedi | togli | conflitto)" }
        }
    }
    catch {
        [Console]::Error.WriteLine("memoria: $($_.Exception.Message)")
        exit 1
    }
}
