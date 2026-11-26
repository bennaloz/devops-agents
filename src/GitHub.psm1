Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global

# Il codice sorgente su GitHub: rami e PR di un repo, per le aree di config/mappa.json con "sorgente": "github".
# La board resta su Azure DevOps (Ado.psm1): qui non si legge ne si scrive nessuna card. Chi chiama non usa questo modulo
# direttamente: le funzioni di Ado.psm1 sui repo (Get-AdoPr, New-AdoPr, Complete-AdoPr, ...) guardano la sorgente dell'area
# e passano da qui, e restituiscono gli stessi oggetti per le due sorgenti.

$script:ApiGitHub = 'https://api.github.com'
$script:WebGitHub = 'https://github.com'
$script:TimeoutSec = 30
$script:VersioneApi = '2022-11-28'

# I file del token di GitHub, accanto ai PAT di Azure DevOps e con la stessa forma (pat-*.txt: l'hook deny-pat li copre).
# Il pieno (Contents e Pull requests in scrittura, Checks e Actions in lettura e scrittura) lo usa lo smistatore; quello in
# lettura le sessioni dei ruoli, come GH_TOKEN, per `gh pr view` o `gh run view --log-failed`.
function Get-PercorsoFilePatGitHub([ValidateSet('smistatore', 'lettura')][string]$Tipo, [string]$ClaudeDir = (Join-Path $HOME '.claude')) {
    $nome = if ($Tipo -eq 'smistatore') { 'pat-github.txt' } else { 'pat-github-lettura.txt' }
    Join-Path $ClaudeDir $nome
}

function Get-GhIntestazione {
    $token = Read-FilePat (Get-PercorsoFilePatGitHub 'smistatore')
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Token di GitHub mancante: scrivilo in $(Get-PercorsoFilePatGitHub 'smistatore') (un fine-grained PAT sui repo della mappa)"
    }
    @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = $script:VersioneApi; 'User-Agent' = 'DevOps.Agents' }
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory)][string]$Metodo,
        # il percorso dopo l'indirizzo delle API, con la barra iniziale: /repos/<owner>/<repo>/pulls
        [Parameter(Mandatory)][string]$Percorso,
        $Corpo = $null,
        [string]$Accept
    )
    $intest = Get-GhIntestazione
    if ($Accept) { $intest.Accept = $Accept }
    $url = "$script:ApiGitHub$Percorso"
    $chiamata = @{ Method = $Metodo; Uri = $url; Headers = $intest; TimeoutSec = $script:TimeoutSec }
    if ($null -ne $Corpo) {
        $chiamata.Body = $Corpo | ConvertTo-Json -Depth 10 -Compress
        $chiamata.ContentType = 'application/json'
    }
    try { Invoke-RestMethod @chiamata }
    catch {
        $msg = [string]$_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $corpoErrore = [string]$_.ErrorDetails.Message
            if ($corpoErrore.Length -gt 500) { $corpoErrore = $corpoErrore.Substring(0, 500) + '...' }
            $msg = "$msg - $corpoErrore"
        }
        $auth = [string]$intest.Authorization
        foreach ($segreto in @($auth, ($auth -replace '^Bearer ', ''))) { if ($segreto) { $msg = $msg.Replace($segreto, '***') } }
        throw "Chiamata a GitHub fallita ($Metodo $url): $msg"
    }
}

# owner/nome -> /repos/owner/nome, con le due parti controllate: un valore sbagliato in mappa.json si vede qui.
function Get-GhBaseRepo([string]$RepoGh) {
    if ($RepoGh -notmatch '^[\w.-]+/[\w.-]+$') { throw "repoGithub '$RepoGh' non e nella forma <owner>/<repo>" }
    "/repos/$RepoGh"
}

function Get-GhProprietario([string]$RepoGh) { $RepoGh.Split('/')[0] }

# Lo stato di una PR di GitHub con i nomi di Azure DevOps, che usa chi decide: aperta = active, unita = completed,
# chiusa senza merge = abandoned.
function ConvertTo-StatoPrGh($Pr) {
    if ([string](Get-Campo $Pr 'state') -eq 'open') { return 'active' }
    if (Get-Campo $Pr 'merged_at') { return 'completed' }
    'abandoned'
}

function Get-GhCommitTesta($Pr) { [string](Get-Campo (Get-Campo $Pr 'head') 'sha') }

# Le PR del ramo verso la destinazione, di ogni stato, dalla piu recente.
function Get-GhPrRamo([string]$RepoGh, [string]$Ramo, [string]$Destinazione, [ValidateSet('all', 'open')][string]$Stato = 'all') {
    $testa = [uri]::EscapeDataString("$(Get-GhProprietario $RepoGh):$Ramo")
    $r = Invoke-Gh -Metodo Get -Percorso "$(Get-GhBaseRepo $RepoGh)/pulls?head=$testa&base=$([uri]::EscapeDataString($Destinazione))&state=$Stato&per_page=100"
    @(@($r) | Where-Object { $_ } | Sort-Object { [int]$_.number } -Descending)
}

function Get-GhPrDelRamo([string]$RepoGh, [string]$Ramo, [string]$Destinazione = 'develop') {
    @(Get-GhPrRamo $RepoGh $Ramo $Destinazione 'all' | ForEach-Object {
            [pscustomobject]@{ Id = [int]$_.number; Stato = (ConvertTo-StatoPrGh $_); CommitSorgente = (Get-GhCommitTesta $_) }
        })
}

# Un controllo (check run o status) diventa verde / rossa / inCorso, come le valutazioni delle policy di Azure DevOps.
function Get-EsitoControlloGh($Controllo) {
    $stato = [string](Get-Campo $Controllo 'status')
    if (Get-Campo $Controllo 'state') {
        # status classico (commit status API): success, failure, error, pending
        switch ([string]$Controllo.state) { 'success' { return 'verde' } { $_ -in 'failure', 'error' } { return 'rossa' } default { return 'inCorso' } }
    }
    if ($stato -ne 'completed') { return 'inCorso' }
    switch ([string](Get-Campo $Controllo 'conclusion')) {
        { $_ -in 'success', 'neutral', 'skipped' } { return 'verde' }
        { $_ -in 'failure', 'timed_out', 'cancelled', 'action_required', 'startup_failure' } { return 'rossa' }
        default { return 'inCorso' }
    }
}

# Da dove viene un controllo, dal suo link: un run di Azure Pipelines (buildId, il log lo legge Get-AdoErroriBuild) o un run di
# GitHub Actions (si rilancia con rerun-failed-jobs). Altrimenti niente: si vede il link e basta.
function Get-OrigineControlloGh($Controllo) {
    $url = [string](@((Get-Campo $Controllo 'details_url'), (Get-Campo $Controllo 'target_url'), (Get-Campo $Controllo 'html_url')) | Where-Object { $_ } | Select-Object -First 1)
    $build = [regex]::Match($url, '[?&]buildId=(\d+)')
    $run = [regex]::Match($url, '/actions/runs/(\d+)')
    [pscustomobject]@{
        Url        = $url
        BuildIdAdo = if ($build.Success) { [int]$build.Groups[1].Value } else { $null }
        RunActions = if ($run.Success) { [long]$run.Groups[1].Value } else { $null }
    }
}

# Tutti i controlli sul commit di testa: i check run (Actions, Azure Pipelines, altre app) e gli status classici.
# Su GitHub un controllo e sempre legato a un commit: un esito vecchio non vale per un push nuovo, da solo.
function Get-GhControlli([string]$RepoGh, [string]$Commit) {
    $base = Get-GhBaseRepo $RepoGh
    $cr = Invoke-Gh -Metodo Get -Percorso "$base/commits/$Commit/check-runs?per_page=100"
    $st = Invoke-Gh -Metodo Get -Percorso "$base/commits/$Commit/status"
    @(@(Get-Campo $cr 'check_runs') + @(Get-Campo $st 'statuses') | Where-Object { $_ })
}

# La PR attiva del ramo con la sua validazione, nella stessa forma di Get-AdoPr: Id, Stato, Validazione (verde, rossa, inCorso,
# conflitti, assente), BuildId (solo per un controllo di Azure Pipelines), UrlLog, UltimoCommit. In piu RunActions, il run di
# GitHub Actions del controllo scelto.
function Get-GhPr([string]$RepoGh, [string]$Ramo, [switch]$AncheCompletate, [string]$Destinazione = 'develop') {
    $trovate = @(Get-GhPrRamo $RepoGh $Ramo $Destinazione $(if ($AncheCompletate) { 'all' } else { 'open' }))
    $pr = $trovate | Where-Object { (ConvertTo-StatoPrGh $_) -eq 'active' } | Select-Object -First 1
    if (-not $pr -and $AncheCompletate) {
        $unita = $trovate | Where-Object { (ConvertTo-StatoPrGh $_) -eq 'completed' } | Select-Object -First 1
        if ($unita) {
            return [pscustomobject]@{ Id = [int]$unita.number; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null; UltimoCommit = (Get-GhCommitTesta $unita); RunActions = $null }
        }
    }
    if (-not $pr) { return $null }

    # L'elenco non porta mergeable: si rilegge la PR. null = GitHub lo sta ancora calcolando.
    $pr = Invoke-Gh -Metodo Get -Percorso "$(Get-GhBaseRepo $RepoGh)/pulls/$([int]$pr.number)"
    $testa = Get-GhCommitTesta $pr
    $unibile = Get-Campo $pr 'mergeable'
    $statoUnione = [string](Get-Campo $pr 'mergeable_state')

    $esiti = @(foreach ($c in (Get-GhControlli $RepoGh $testa)) {
            $o = Get-OrigineControlloGh $c
            [pscustomobject]@{ Validazione = (Get-EsitoControlloGh $c); BuildId = $o.BuildIdAdo; RunActions = $o.RunActions; Url = $o.Url }
        })
    $scelto = $null
    if ($statoUnione -eq 'dirty' -or $unibile -eq $false) { $validazione = 'conflitti' }
    else {
        $inCorso = @($esiti | Where-Object Validazione -eq 'inCorso')
        $rosse = @($esiti | Where-Object Validazione -eq 'rossa')
        if ($inCorso.Count -gt 0) { $validazione = 'inCorso'; $scelto = $inCorso[-1] }
        elseif ($rosse.Count -gt 0) { $validazione = 'rossa'; $scelto = $rosse[-1] }
        elseif ($null -eq $unibile -or $statoUnione -eq 'unknown') { $validazione = 'inCorso' }
        else { $validazione = 'verde'; if ($esiti.Count -gt 0) { $scelto = $esiti[-1] } }
    }
    [pscustomobject]@{
        Id           = [int]$pr.number
        Stato        = 'active'
        Validazione  = $validazione
        BuildId      = if ($scelto) { $scelto.BuildId } else { $null }
        UrlLog       = if ($scelto -and $scelto.Url) { $scelto.Url } else { $null }
        UltimoCommit = $testa
        RunActions   = if ($scelto) { $scelto.RunActions } else { $null }
    }
}

# Apre la PR e restituisce numero e indirizzo. Con una card, AB#<id> nella descrizione: se sul repo c'e l'app Azure Boards
# la PR compare anche sulla card; il collegamento che usa lo smistatore e il link che aggiunge Ado.psm1.
function New-GhPr([string]$RepoGh, [string]$Ramo, [string]$Titolo, [string]$Descrizione, [int]$CardId = 0, [string]$Destinazione = 'develop') {
    $corpo = if ($CardId -gt 0) { "$Descrizione`n`nAB#$CardId" } else { $Descrizione }
    $r = Invoke-Gh -Metodo Post -Percorso "$(Get-GhBaseRepo $RepoGh)/pulls" -Corpo @{ title = $Titolo; head = $Ramo; base = $Destinazione; body = $corpo }
    [pscustomobject]@{ Id = [int]$r.number; Url = [string]$r.html_url }
}

function Get-GhPrSingola([string]$RepoGh, [int]$Id) { Invoke-Gh -Metodo Get -Percorso "$(Get-GhBaseRepo $RepoGh)/pulls/$Id" }

function Get-GhDescrizionePr([string]$RepoGh, [int]$Id) { [string](Get-Campo (Get-GhPrSingola $RepoGh $Id) 'body') }

function Set-GhPr([string]$RepoGh, [int]$Id, [hashtable]$Campi) {
    [void](Invoke-Gh -Metodo Patch -Percorso "$(Get-GhBaseRepo $RepoGh)/pulls/$Id" -Corpo $Campi)
}

# Merge con merge commit (come noFastForward su Azure DevOps: Remove-WorktreeCard riconosce il ramo assorbito con
# merge-base --is-ancestor) sul commit verificato, poi cancella il ramo sorgente. Un ramo gia cancellato da GitHub
# (l'opzione del repo) non e un errore.
function Complete-GhPr([string]$RepoGh, [int]$Id, [string]$Commit) {
    $pr = Get-GhPrSingola $RepoGh $Id
    if (-not $Commit) { $Commit = Get-GhCommitTesta $pr }
    $base = Get-GhBaseRepo $RepoGh
    [void](Invoke-Gh -Metodo Put -Percorso "$base/pulls/$Id/merge" -Corpo @{ merge_method = 'merge'; sha = $Commit })
    $ramo = [string](Get-Campo (Get-Campo $pr 'head') 'ref')
    if ($ramo) {
        try { [void](Invoke-Gh -Metodo Delete -Percorso "$base/git/refs/heads/$ramo") } catch { Write-Verbose "ramo $ramo non cancellato: $_" }
    }
}

# I controlli rossi della PR attiva del ramo da rilanciare: i run di GitHub Actions li rilancia qui (rerun-failed-jobs, una volta
# per run), le build di Azure Pipelines le restituisce a chi chiama, che le rilancia con il PAT di Azure DevOps.
# Su GitHub non ci sono validazioni scadute: con -Scadute non c'e niente da fare.
function Start-GhRivalutazione([string]$RepoGh, [string]$Ramo, [switch]$Scadute, [string]$Destinazione = 'develop') {
    $vuoto = [pscustomobject]@{ Actions = 0; BuildAdo = @() }
    if ($Scadute) { return $vuoto }
    $pr = Get-GhPrRamo $RepoGh $Ramo $Destinazione 'open' | Select-Object -First 1
    if (-not $pr) { return $vuoto }
    $rossi = @(Get-GhControlli $RepoGh (Get-GhCommitTesta $pr) | Where-Object { (Get-EsitoControlloGh $_) -eq 'rossa' } | ForEach-Object { Get-OrigineControlloGh $_ })
    $run = @($rossi | Where-Object RunActions | ForEach-Object RunActions | Sort-Object -Unique)
    foreach ($id in $run) { [void](Invoke-Gh -Metodo Post -Percorso "$(Get-GhBaseRepo $RepoGh)/actions/runs/$id/rerun-failed-jobs") }
    [pscustomobject]@{ Actions = $run.Count; BuildAdo = @($rossi | Where-Object BuildIdAdo | ForEach-Object BuildIdAdo | Sort-Object -Unique) }
}

# I nomi dei rami su origin che cominciano con il prefisso dato (heads/feature/42 trova feature/42 e feature/42-titolo).
function Get-GhRami([string]$RepoGh, [string]$Prefisso) {
    $r = Invoke-Gh -Metodo Get -Percorso "$(Get-GhBaseRepo $RepoGh)/git/matching-refs/heads/$Prefisso"
    @(@($r) | Where-Object { $_ } | ForEach-Object { [string](Get-Campo $_ 'ref') -replace '^refs/heads/', '' })
}

# Il contenuto di un file del repo sul ramo dato (lo YAML di una pipeline di Azure Pipelines che costruisce un repo GitHub).
function Get-GhFile([string]$RepoGh, [string]$Percorso, [string]$Ramo) {
    $p = (($Percorso.TrimStart('/') -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    [string](Invoke-Gh -Metodo Get -Percorso "$(Get-GhBaseRepo $RepoGh)/contents/$($p)?ref=$([uri]::EscapeDataString($Ramo))" -Accept 'application/vnd.github.raw+json')
}

function Get-GhUrlPr([string]$RepoGh, [int]$Id) { "$script:WebGitHub/$RepoGh/pull/$Id" }

# Il link alla PR salvato sulla card (relazione Hyperlink): repo e numero, o null se non e una PR di GitHub.
function ConvertFrom-GhUrlPr([string]$Url) {
    $m = [regex]::Match($Url, '^https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)/?$')
    if (-not $m.Success) { return $null }
    [pscustomobject]@{ RepoGh = $m.Groups[1].Value; Id = [int]$m.Groups[2].Value }
}

Export-ModuleMember -Function Get-PercorsoFilePatGitHub, Get-GhIntestazione, Invoke-Gh, ConvertTo-StatoPrGh, Get-GhPrDelRamo, Get-EsitoControlloGh,
    Get-OrigineControlloGh, Get-GhControlli, Get-GhPr, New-GhPr, Get-GhPrSingola, Get-GhDescrizionePr, Set-GhPr, Complete-GhPr, Start-GhRivalutazione,
    Get-GhRami, Get-GhFile, Get-GhUrlPr, ConvertFrom-GhUrlPr
