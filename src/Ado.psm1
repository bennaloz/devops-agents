Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global
# Il codice sorgente puo stare su GitHub (area con "sorgente": "github"): le funzioni sui repo qui sotto passano da GitHub.psm1.
Import-Module (Join-Path $PSScriptRoot 'GitHub.psm1') -Global

# Le chiamate REST ad Azure DevOps. Nessuna regola: solo lettura e scrittura.
# Il PAT lo carica soltanto Get-AdoIntestazione, dentro il processo che fa la chiamata.

# L'organizzazione Azure DevOps: la chiave 'organizzazione' di config/mappa.json (https://dev.azure.com/<org> oppure
# https://<org>.visualstudio.com). Senza la chiave vale l'esempio, cosi i test girano anche su una mappa minima.
function Read-AdoOrganizzazione {
    $p = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/mappa.json'
    try { $m = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $m = $null }
    if ($m -and $m.PSObject.Properties['organizzazione'] -and -not [string]::IsNullOrWhiteSpace($m.organizzazione)) {
        return ([string]$m.organizzazione).TrimEnd('/')
    }
    'https://acme.visualstudio.com'
}
$script:Org = Read-AdoOrganizzazione
$script:TimeoutSec = 30
$script:PaginaRevisioni = 200
# Il messaggio di un 401: chi lo legge (smistatore, card.ps1) sa cosa fare.
$script:MessaggioPatScaduto = Get-TestoPatScaduto
# I campi interi dei consumi sulla card: il nome sta qui e in nessun altro posto.
$script:CampoTotale = 'Custom.TotalTokens'
$script:CampoMinuti = 'Custom.AgentMinutes'
$script:Firma = '🤖 Generated with [Claude Code](https://claude.com/claude-code)'
# Il limite di Azure DevOps alla descrizione di una PR, firma compresa: la firma la aggiunge questo modulo, quindi e qui che
# si sa quanto resta al testo.
$script:LimiteDescrizionePr = 4000
$script:SeparatoreFirma = "`n`n"

# La descrizione come arriva ad Azure DevOps: il testo e la firma.
function Add-FirmaPr([string]$Descrizione) { "$Descrizione$script:SeparatoreFirma$script:Firma" }

# Il massimo di caratteri che chi compone la descrizione di una PR puo usare: il limite meno la firma e il suo separatore.
function Get-AdoLimiteTestoPr { $script:LimiteDescrizionePr - $script:SeparatoreFirma.Length - $script:Firma.Length }

function Get-AdoCampiConsumi {
    @{ Totale = $script:CampoTotale; Minuti = $script:CampoMinuti }
}

function Get-AdoStati {
    $p = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/stati.json'
    Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
}

# Il progetto della board: i commenti e la ricerca delle card attive vogliono il progetto prima di _apis.
function Get-AdoProgettoBoard {
    $p = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/mappa.json'
    $m = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $m.PSObject.Properties['progettoBoard'] -or [string]::IsNullOrWhiteSpace($m.progettoBoard)) {
        throw "config/mappa.json: manca 'progettoBoard'"
    }
    [string]$m.progettoBoard
}

# Il link alla card sulla board: l'indirizzo dell'organizzazione sta solo qui.
function Get-AdoUrlCard {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id, [string]$Progetto)
    if (-not $Progetto) { $Progetto = Get-AdoProgettoBoard }
    "$script:Org/$([uri]::EscapeDataString($Progetto))/_workitems/edit/$Id"
}

# L'indirizzo dell'organizzazione, per chi deve ricavarne il nome (l'installatore dei PAT).
function Get-AdoUrlOrganizzazione { $script:Org }

function Get-AdoIntestazione {
    # il file puo essere cifrato con DPAPI o in chiaro: lo decide Read-FilePat
    $pat = Read-FilePat (Get-PercorsoFilePat 'smistatore')
    if ([string]::IsNullOrWhiteSpace($pat)) { throw 'PAT mancante: lancia setup/Install-Attrezzi.ps1 -Pat' }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    @{ Authorization = "Basic $b64" }
}

function Invoke-Ado {
    param(
        [Parameter(Mandatory)][string]$Metodo,
        [Parameter(Mandatory)][string]$Url,
        $Corpo = $null,
        [string]$ContentType = 'application/json'
    )
    $intest = Get-AdoIntestazione
    $chiamata = @{ Method = $Metodo; Uri = $Url; Headers = $intest; TimeoutSec = $script:TimeoutSec }
    if ($null -ne $Corpo) {
        $chiamata.Body = if ($Corpo -is [string]) { $Corpo } else { $Corpo | ConvertTo-Json -Depth 10 -Compress }
        $chiamata.ContentType = $ContentType
    }
    try {
        Invoke-RestMethod @chiamata
    }
    catch {
        $msg = [string]$_.Exception.Message
        # Il corpo della risposta porta il motivo (scope mancante, campo non valido, ...).
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $corpoErrore = [string]$_.ErrorDetails.Message
            if ($corpoErrore.Length -gt 500) { $corpoErrore = $corpoErrore.Substring(0, 500) + '...' }
            $msg = "$msg - $corpoErrore"
        }
        # 401: il PAT non vale piu (scaduto o revocato); il rimedio e rinnovarlo, non cercare altrove
        $risposta = if ($_.Exception.PSObject.Properties['Response']) { $_.Exception.Response } else { $null }
        if ($risposta -and $risposta.PSObject.Properties['StatusCode'] -and [int]$risposta.StatusCode -eq 401) {
            $msg = "$msg - $script:MessaggioPatScaduto"
        }
        $auth = [string]$intest.Authorization
        foreach ($segreto in @($auth, ($auth -replace '^Basic ', ''))) {
            if ($segreto) { $msg = $msg.Replace($segreto, '***') }
        }
        throw "Chiamata ad Azure DevOps fallita ($Metodo $Url): $msg"
    }
}

function ConvertTo-AdoUtente($u) {
    if ($null -eq $u) { return $null }
    [pscustomobject]@{ Id = $u.id; Nome = $u.displayName }
}

# In un Bug la descrizione e nel campo dei passi per riprodurre: System.Description non c'e. Lo scrive anche New-AdoCard.
function Get-CampoDescrizione([string]$Tipo) {
    if ($Tipo -eq 'Bug') { 'Microsoft.VSTS.TCM.ReproSteps' } else { 'System.Description' }
}

# Il campo dei criteri di accettazione: la Feature non lo ha (verificato sull'org), le card si. Null per il tipo che non lo ha.
# Il solo posto che ne sa il nome: lo leggono ConvertTo-Card, New-AdoCard e Set-AdoCard.
$script:CampoCriteri = 'Microsoft.VSTS.Common.AcceptanceCriteria'
function Get-CampoCriteri([string]$Tipo) {
    if ($Tipo -eq 'Feature') { $null } else { $script:CampoCriteri }
}

# I tag di un work item (il testo di System.Tags, separato da punto e virgola) come elenco: il solo posto dove si leggono.
function ConvertTo-ElencoTag($Testo) {
    @(if ($Testo) { ([string]$Testo) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
}

function ConvertTo-Card($wi) {
    $f = $wi.fields
    $campo = { param($n) if ($f.PSObject.Properties[$n]) { $f.$n } else { $null } }
    $tipo = & $campo 'System.WorkItemType'
    [pscustomobject]@{
        Id          = [int]$wi.id
        Rev         = [int]$wi.rev
        Tipo        = $tipo
        Titolo      = & $campo 'System.Title'
        Descrizione = & $campo (Get-CampoDescrizione $tipo)
        Criteri     = & $campo $script:CampoCriteri
        Stato       = & $campo 'System.State'
        Tag         = @(ConvertTo-ElencoTag (& $campo 'System.Tags'))
        Area        = & $campo 'System.AreaPath'
        CreataDa    = ConvertTo-AdoUtente (& $campo 'System.CreatedBy')
        # il padrone della card: solo lo smistatore del suo utente la fa avanzare (spec, sezione 19)
        AssegnataA  = ConvertTo-AdoUtente (& $campo 'System.AssignedTo')
        ConsumoTotale = [int64](& $campo $script:CampoTotale)
        MinutiAgente  = [int64](& $campo $script:CampoMinuti)
        # D52: l'id del padre (link Parent), dalle relazioni che Get-AdoCard legge con la card; null senza padre
        PadreId       = (Get-IdPadre $wi)
    }
}

function Get-AdoCard {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id)
    ConvertTo-Card (Invoke-Ado -Metodo Get -Url "$script:Org/_apis/wit/workitems/$($Id)?`$expand=relations&api-version=7.1")
}

# I campi lunghi (descrizione, criteri, passi) si scrivono in Markdown: in html un testo con a capo ed elenchi diventa
# una riga sola. Il formato vale solo se nella stessa patch il valore del campo cambia (verificato il 2026-11-17 sulla
# card 9), e su un campo gia in Markdown non torna indietro.
function New-OpMarkdown([string]$Campo) {
    [ordered]@{ op = 'add'; path = "/multilineFieldsFormat/$Campo"; value = 'Markdown' }
}

# Crea una card. Non imposta lo stato: lo decide Azure DevOps. Il progetto e il primo segmento dell'area.
# Per un Bug la descrizione va nei passi di riproduzione. <DA VERIFICARE: campo e uso dei criteri su un Bug, dal vivo>
function New-AdoCard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tipo,
        [Parameter(Mandatory)][string]$Titolo,
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Descrizione,
        # i criteri di accettazione: non per una Feature, che non ha il campo (errore se dati)
        [string]$Criteri,
        [string[]]$Tag,
        # l'identita a cui assegnare la card (l'indirizzo, come lo da Get-AdoUtenteCorrente)
        [string]$AssegnataA,
        # Gli id delle card che devono essere unite prima di questa: relazioni Predecessor, scritte nella stessa creazione.
        [int[]]$Dopo,
        # L'id della Feature padre (D52): relazione Parent, scritta nella stessa creazione.
        [int]$Padre
    )
    $progetto = ($Area -split '\\')[0]
    $campoDescrizione = Get-CampoDescrizione $Tipo
    $ops = @(
        [ordered]@{ op = 'add'; path = '/fields/System.Title'; value = $Titolo }
        [ordered]@{ op = 'add'; path = '/fields/System.AreaPath'; value = $Area }
        New-OpMarkdown $campoDescrizione
        [ordered]@{ op = 'add'; path = "/fields/$campoDescrizione"; value = $Descrizione }
    )
    $campoCriteri = Get-CampoCriteri $Tipo
    if ($Criteri -and -not $campoCriteri) { throw "il tipo '$Tipo' non ha il campo dei criteri di accettazione: i criteri non si possono dare" }
    if ($Criteri) {
        $ops += New-OpMarkdown $campoCriteri
        $ops += [ordered]@{ op = 'add'; path = "/fields/$campoCriteri"; value = $Criteri }
    }
    if ($Tag) { $ops += [ordered]@{ op = 'add'; path = '/fields/System.Tags'; value = (@($Tag) -join '; ') } }
    if ($AssegnataA) { $ops += [ordered]@{ op = 'add'; path = '/fields/System.AssignedTo'; value = $AssegnataA } }
    foreach ($id in $Dopo) {
        $ops += [ordered]@{ op = 'add'; path = '/relations/-'; value = [ordered]@{ rel = $script:RelazioneVersoPredecessore; url = "$script:Org/_apis/wit/workItems/$id" } }
    }
    if ($Padre) {
        $ops += [ordered]@{ op = 'add'; path = '/relations/-'; value = [ordered]@{ rel = $script:RelazioneVersoPadre; url = "$script:Org/_apis/wit/workItems/$Padre" } }
    }
    $url = "$script:Org/$([uri]::EscapeDataString($progetto))/_apis/wit/workitems/`$$([uri]::EscapeDataString($Tipo))?api-version=7.1"
    ConvertTo-Card (Invoke-Ado -Metodo Post -Url $url -ContentType 'application/json-patch+json' `
        -Corpo (ConvertTo-Json -InputObject @($ops) -Depth 10 -Compress))
}

function Get-AdoCardAttive {
    [CmdletBinding()]
    param()
    $s = Get-AdoStati
    $progetto = Get-AdoProgettoBoard
    $q = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$progetto' " +
         "AND [System.WorkItemType] IN ('User Story', 'Bug') AND [System.Tags] CONTAINS '$($s.tagAgenti)' " +
         "AND [System.State] <> '$($s.bozza)' AND [System.State] <> '$($s.chiusa)' ORDER BY [System.Id]"
    $r = Invoke-Ado -Metodo Post -Url "$script:Org/$([uri]::EscapeDataString($progetto))/_apis/wit/wiql?api-version=7.1" -Corpo @{ query = $q }
    # Le card rimosse si scartano qui, non nella query: un valore di stato che il processo non conosce romperebbe la WIQL.
    @(foreach ($w in @($r.workItems)) {
        if ($w) { $c = Get-AdoCard -Id $w.id; if ($c.Stato -ne $s.rimossa) { $c } }
    })
}

function Set-AdoCard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Stato,
        [string[]]$AggiungiTag,
        [string[]]$TogliTag,
        [string]$Criteri,
        [hashtable]$Campi
    )
    $ops = [System.Collections.Generic.List[object]]::new()
    $imposta = { param($campo, $valore) $ops.Add([ordered]@{ op = 'add'; path = "/fields/$campo"; value = $valore }) }

    if ($PSBoundParameters.ContainsKey('Stato')) { & $imposta 'System.State' $Stato }
    if ($PSBoundParameters.ContainsKey('Criteri')) {
        $ops.Add((New-OpMarkdown $script:CampoCriteri))
        & $imposta $script:CampoCriteri $Criteri
    }
    if ($Campi) { foreach ($k in $Campi.Keys) { & $imposta $k $Campi[$k] } }
    $tagRichiesti = [bool]($AggiungiTag -or $TogliTag)
    $revAttuale = $null
    if ($tagRichiesti) {
        $attuale = Get-AdoCard -Id $Id
        $revAttuale = $attuale.Rev
        $tag = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $attuale.Tag) { $tag.Add($t) }
        foreach ($t in @($AggiungiTag)) { if ($t -and ($tag -notcontains $t)) { $tag.Add($t) } }
        foreach ($t in @($TogliTag)) { [void]$tag.RemoveAll([Predicate[string]] { param($x) $x -ieq $t }) }
        $cambiati = (($tag -join '; ') -ne (@($attuale.Tag) -join '; '))
        # 'replace' e non 'add': su System.Tags ADO tratta 'add' come un'unione, aggiunge i tag che mancano e non toglie gli
        # altri. Con 'add' -TogliTag non toglieva niente (card 11, 2026-11-19: on-hold rimasto dopo Set-AdoCard -TogliTag).
        if ($cambiati -and $tag.Count -gt 0) { $ops.Add([ordered]@{ op = 'replace'; path = '/fields/System.Tags'; value = ($tag -join '; ') }) }
        # Un valore vuoto in una op add non svuota il campo: serve una op remove.
        elseif ($cambiati) { $ops.Add([ordered]@{ op = 'remove'; path = '/fields/System.Tags' }) }
        # I tag si riscrivono tutti, partendo da quelli letti: se nel frattempo qualcuno ne ha aggiunto uno, la revisione non
        # e piu quella letta e la patch fallisce invece di cancellarlo senza dirlo.
        if ($cambiati) { $ops.Insert(0, [ordered]@{ op = 'test'; path = '/rev'; value = [int]$revAttuale }) }
    }
    if ($ops.Count -eq 0) {
        if ($tagRichiesti) { return [int]$revAttuale }
        throw 'Set-AdoCard: nessuna modifica richiesta'
    }

    $r = Invoke-Ado -Metodo Patch -Url "$script:Org/_apis/wit/workitems/$($Id)?api-version=7.1" `
        -Corpo (ConvertTo-Json -InputObject @($ops) -Depth 10 -Compress) -ContentType 'application/json-patch+json'
    [int]$r.rev
}

function Get-AdoStoriaStato {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id)
    # Tutte le pagine: le revisioni piu' recenti sono in fondo, proprio quelle che un taglio perderebbe.
    $revisioni = [System.Collections.Generic.List[object]]::new()
    $skip = 0
    do {
        $r = Invoke-Ado -Metodo Get -Url "$script:Org/_apis/wit/workitems/$Id/revisions?`$top=$script:PaginaRevisioni&`$skip=$skip&api-version=7.1"
        $pagina = @($r.value)
        foreach ($x in $pagina) { $revisioni.Add($x) }
        $skip += $pagina.Count
    } while ($pagina.Count -ge $script:PaginaRevisioni)
    $prec = $null
    foreach ($rev in $revisioni) {
        $stato = $rev.fields.'System.State'
        $cb = $rev.fields.'System.ChangedBy'
        # Chi e l'id dell'identita: lo stesso tipo di valore di Id in Get-AdoUtenteCorrente (il nome non e confrontabile).
        $chi = if ($cb.PSObject.Properties['id']) { $cb.id } else { $null }
        if ($stato -ne $prec) {
            [pscustomobject]@{
                Rev    = [int]$rev.rev
                Da     = $prec
                A      = $stato
                Chi    = $chi
                ChiNome = $cb.displayName
                Quando = $rev.fields.'System.ChangedDate'
            }
        }
        $prec = $stato
    }
}

function Get-AdoCommenti {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id, [int]$DopoId = 0)
    $base = "$script:Org/$([uri]::EscapeDataString((Get-AdoProgettoBoard)))/_apis/wit/workItems/$Id/comments"
    $url = "$base`?order=asc&api-version=7.1-preview.4"
    $tutti = [System.Collections.Generic.List[object]]::new()
    $vistiToken = @{}
    while ($true) {
        $r = Invoke-Ado -Metodo Get -Url $url
        foreach ($c in @($r.comments)) { $tutti.Add($c) }
        $tok = if ($r.PSObject.Properties['continuationToken']) { [string]$r.continuationToken } else { '' }
        if (-not $tok -or $vistiToken.Contains($tok)) { break }
        $vistiToken[$tok] = $true
        $url = "$base`?order=asc&continuationToken=$([uri]::EscapeDataString($tok))&api-version=7.1-preview.4"
    }
    @(foreach ($c in $tutti) {
        if ($c.id -gt $DopoId) {
            [pscustomobject]@{ Id = [int]$c.id; Autore = $c.createdBy.displayName; Testo = $c.text; Quando = $c.createdDate }
        }
    })
}

function Add-AdoCommento {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][string]$Testo, [string]$Menziona)
    # In Markdown: in html a capo ed elenchi diventano una riga sola. La menzione in Markdown e @<id>, che Azure DevOps
    # rende come menzione e notifica (verificato il 2026-11-17 sulla card 9).
    if ($Menziona) { $Testo = "@<$Menziona> $Testo" }
    $r = Invoke-Ado -Metodo Post -Url "$script:Org/$([uri]::EscapeDataString((Get-AdoProgettoBoard)))/_apis/wit/workItems/$Id/comments?format=markdown&api-version=7.1-preview.4" -Corpo @{ text = $Testo }
    [int]$r.id
}

# ---- sorgente del codice -------------------------------------------------------------------------------------------
# La board e sempre Azure DevOps; il codice di un'area sta su Azure Repos (il default) o su GitHub. La sorgente e un fatto
# della mappa: chiave "sorgente" ("ado" o "github") e, per GitHub, "repoGithub" (<owner>/<repo>) nella voce dell'area, o
# nella voce "attrezzi" per il repo di questa suite (la PR della memoria, D46). Un repo che la mappa non conosce e su Azure Repos.
function Get-AdoMappaLetta {
    $p = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/mappa.json'
    try { Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

function Get-VociRepoMappa($Mappa) {
    if (-not $Mappa) { return @() }
    $voci = @(if ($Mappa.PSObject.Properties['aree']) { @($Mappa.aree) })
    if ($Mappa.PSObject.Properties['attrezzi'] -and $Mappa.attrezzi) {
        $a = $Mappa.attrezzi
        $progetto = if ($a.PSObject.Properties['progettoAdo'] -and $a.progettoAdo) { $a.progettoAdo } elseif ($Mappa.PSObject.Properties['progettoBoard']) { $Mappa.progettoBoard } else { $null }
        $voci += [pscustomobject]@{ repo = (Get-Campo $a 'repo'); progettoAdo = $progetto; sorgente = (Get-Campo $a 'sorgente'); repoGithub = (Get-Campo $a 'repoGithub') }
    }
    @($voci | Where-Object { $_ })
}

function Get-SorgenteRepo {
    [CmdletBinding()]
    param([string]$Progetto, [Parameter(Mandatory)][string]$Repo)
    $voce = Get-VociRepoMappa (Get-AdoMappaLetta) |
        Where-Object { [string](Get-Campo $_ 'repo') -eq $Repo -and (-not $Progetto -or [string](Get-Campo $_ 'progettoAdo') -eq $Progetto) } |
        Select-Object -First 1
    if ($voce -and [string](Get-Campo $voce 'sorgente') -eq 'github') {
        $gh = [string](Get-Campo $voce 'repoGithub')
        if (-not $gh) { throw "config/mappa.json: il repo $Repo ha sorgente github ma manca 'repoGithub'" }
        return [pscustomobject]@{ Tipo = 'github'; RepoGh = $gh }
    }
    [pscustomobject]@{ Tipo = 'ado'; RepoGh = $null }
}

# Il contrario: da owner/repo di GitHub il progetto e il nome del repo come li conosce la mappa (null se non c'e).
function Find-RepoDaGitHub([string]$RepoGh) {
    Get-VociRepoMappa (Get-AdoMappaLetta) |
        Where-Object { [string](Get-Campo $_ 'sorgente') -eq 'github' -and [string](Get-Campo $_ 'repoGithub') -eq $RepoGh } |
        Select-Object -First 1 | ForEach-Object { [pscustomobject]@{ Progetto = [string]$_.progettoAdo; Repo = [string]$_.repo } }
}

function Get-AdoRepoUrl($Progetto, $Repo) {
    "$script:Org/$([uri]::EscapeDataString($Progetto))/_apis/git/repositories/$([uri]::EscapeDataString($Repo))"
}

# Tutte le PR di un ramo verso develop, di ogni stato, dalla piu recente: id, stato e commit sorgente. Serve a chi deve
# capire se le commit di un ramo sono gia coperte da una PR chiusa (la memoria dei ruoli, D46): Get-AdoPr ricorda solo
# l'attiva e la completata, e dell'abbandonata niente. Un errore non diventa una lista vuota.
function Get-AdoPrDelRamo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Ramo,
        # il ramo verso cui vanno le PR: develop, o il ramo della funzionalita (D52)
        [string]$Destinazione = 'develop'
    )
    $src = Get-SorgenteRepo -Progetto $Progetto -Repo $Repo
    if ($src.Tipo -eq 'github') { return @(Get-GhPrDelRamo $src.RepoGh $Ramo $Destinazione) }
    $url = (Get-AdoRepoUrl $Progetto $Repo) + "/pullrequests?searchCriteria.sourceRefName=refs/heads/$Ramo" +
        "&searchCriteria.targetRefName=refs/heads/$Destinazione&searchCriteria.status=all&api-version=7.1"
    $r = Invoke-Ado -Metodo Get -Url $url
    @(@($r.value) | Where-Object { $_ } | Sort-Object { [int]$_.pullRequestId } -Descending | ForEach-Object {
            [pscustomobject]@{ Id = [int]$_.pullRequestId; Stato = [string]$_.status; CommitSorgente = (Get-CommitPr $_) }
        })
}

# Il commit di testa del ramo sorgente di una PR (lastMergeSourceCommit), o null se la PR non lo porta.
function Get-CommitPr($Pr) {
    $c = Get-CampoAdo $Pr 'lastMergeSourceCommit'
    if ($c) { [string](Get-CampoAdo $c 'commitId') } else { $null }
}

function Get-AdoPr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Ramo,
        # Dopo il merge la PR non e piu attiva: chi deve pulire (worktree, ramo) la cerca anche tra le completate.
        [switch]$AncheCompletate,
        # il ramo verso cui va la PR: develop, o il ramo della funzionalita (D52)
        [string]$Destinazione = 'develop'
    )
    $src = Get-SorgenteRepo -Progetto $Progetto -Repo $Repo
    if ($src.Tipo -eq 'github') {
        $g = Get-GhPr $src.RepoGh $Ramo -AncheCompletate:$AncheCompletate -Destinazione $Destinazione
        # il log di un controllo di Azure Pipelines si apre sulla pagina della build, come per Azure Repos
        if ($g -and $g.BuildId) { $g.UrlLog = Get-AdoUrlBuild -Progetto $Progetto -Id $g.BuildId }
        return $g
    }
    $stato = if ($AncheCompletate) { 'all' } else { 'active' }
    $url = (Get-AdoRepoUrl $Progetto $Repo) + "/pullrequests?searchCriteria.sourceRefName=refs/heads/$Ramo" +
        "&searchCriteria.targetRefName=refs/heads/$Destinazione&searchCriteria.status=$stato&api-version=7.1"
    $r = Invoke-Ado -Metodo Get -Url $url
    $trovate = @($r.value)
    $pr = $trovate | Where-Object { $_.status -eq 'active' } | Select-Object -First 1
    if (-not $pr -and $AncheCompletate) {
        $completata = $trovate | Where-Object { $_.status -eq 'completed' } | Select-Object -First 1
        # Le policy di una PR chiusa non servono a nessuno: solo identita e stato.
        if ($completata) {
            # D61: il commit di merge in develop serve a riconoscere il deploy di develop che contiene la card
            $merge = Get-CampoAdo $completata 'lastMergeCommit'
            return [pscustomobject]@{ Id = [int]$completata.pullRequestId; Stato = $completata.status; Validazione = 'assente'; BuildId = $null; UrlLog = $null; UltimoCommit = (Get-CommitPr $completata)
                CommitMerge = $(if ($merge) { [string](Get-CampoAdo $merge 'commitId') } else { $null }) }
        }
    }
    if (-not $pr) { return $null }

    $idProgetto = $pr.repository.project.id
    $testa = Get-CommitPr $pr
    $art = [uri]::EscapeDataString("vstfs:///CodeReview/CodeReviewId/$idProgetto/$($pr.pullRequestId)")
    $ev = Invoke-Ado -Metodo Get -Url "$script:Org/$idProgetto/_apis/policy/evaluations?artifactId=$art&api-version=7.1-preview.1"
    $build = @(@($ev.value) | Where-Object { $_.configuration.type.displayName -eq 'Build' -and $_.status -ne 'notApplicable' })

    # Ogni valutazione diventa verde / rossa / inCorso. Una build che non e' girata sul commit di testa del ramo
    # vale inCorso, qualunque sia il suo esito: un esito vecchio non fa partire niente dopo un nuovo push.
    # Il commit su cui e' girata la build e' nel contesto della valutazione (lastMergeSourceCommitId): la build stessa
    # porta in sourceVersion il commit di merge, mai la testa del ramo (verificato il 2026-11-17 sulla PR 967).
    $esiti = foreach ($e in $build) {
        $ctx = if ($e.PSObject.Properties['context']) { $e.context } else { $null }
        $campo = { param($n) if ($ctx -and $ctx.PSObject.Properties[$n]) { $ctx.$n } else { $null } }
        $bid = & $campo 'buildId'
        # D47: una valutazione scaduta (develop e cambiato, la policy scade subito) torna in queued con isExpired: non e
        # in corso, nessuno la rifa da sola. Vale scaduta, e la rilancia lo smistatore quando serve (revisione, merge).
        $v = if ((& $campo 'isExpired') -eq $true) { 'scaduta' }
             else { switch ($e.status) { 'approved' { 'verde' } { $_ -in 'rejected', 'broken' } { 'rossa' } default { 'inCorso' } } }
        if ($v -in 'verde', 'rossa') {
            $commit = & $campo 'lastMergeSourceCommitId'
            if (-not $bid -or -not $commit -or $commit -ne $testa -or (& $campo 'buildIsNotCurrent') -eq $true) { $v = 'inCorso' }
        }
        [pscustomobject]@{ Validazione = $v; BuildId = $bid }
    }
    $esiti = @($esiti)
    # Il giudice e' la PR unibile: conflitti verso develop fermano tutto; senza build applicabili (una modifica
    # fuori dai percorsi di ogni pipeline) la PR e' unibile appena il controllo di unione di ADO ha finito.
    $unione = if ($pr.PSObject.Properties['mergeStatus']) { [string]$pr.mergeStatus } else { '' }
    $validazione = if ($unione -eq 'succeeded') { 'verde' } else { 'inCorso' }
    $buildId = $null
    if ($unione -eq 'conflicts') { $validazione = 'conflitti' }
    elseif ($esiti.Count -gt 0) {
        # Prima si aspetta chi gira, poi una rossa (dev rifa il push e riparte tutto), poi le scadute da rilanciare.
        $inCorso = @($esiti | Where-Object Validazione -eq 'inCorso')
        $rosse = @($esiti | Where-Object Validazione -eq 'rossa')
        $scadute = @($esiti | Where-Object Validazione -eq 'scaduta')
        if ($inCorso.Count -gt 0) { $validazione = 'inCorso'; $buildId = $inCorso[-1].BuildId }
        elseif ($rosse.Count -gt 0) { $validazione = 'rossa'; $buildId = $rosse[-1].BuildId }
        elseif ($scadute.Count -gt 0) { $validazione = 'scaduta'; $buildId = $scadute[-1].BuildId }
        else { $validazione = 'verde'; $buildId = $esiti[-1].BuildId }
    }
    $urlLog = if ($buildId) { Get-AdoUrlBuild -Progetto $Progetto -Id $buildId } else { $null }
    [pscustomobject]@{
        Id          = [int]$pr.pullRequestId
        Stato       = $pr.status
        Validazione = $validazione
        BuildId     = $buildId
        UrlLog      = $urlLog
        UltimoCommit = $testa
    }
}

function New-AdoPr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Ramo,
        [Parameter(Mandatory)][string]$Titolo, [Parameter(Mandatory)][string]$Descrizione,
        # 0 = nessuna card: la PR della memoria (D46) non e di una card.
        [int]$CardId = 0,
        # il ramo verso cui va la PR: develop, o il ramo della funzionalita (D52)
        [string]$Destinazione = 'develop'
    )
    $src = Get-SorgenteRepo -Progetto $Progetto -Repo $Repo
    if ($src.Tipo -eq 'github') {
        $g = New-GhPr $src.RepoGh $Ramo $Titolo (Add-FirmaPr $Descrizione) $CardId $Destinazione
        # Il collegamento fra la card e la PR, che Get-AdoPrCollegata ritrova: un link sulla card (sulle PR di Azure Repos lo fa workItemRefs).
        if ($CardId -gt 0) { Add-AdoLinkCard -Id $CardId -Url $g.Url -Commento "PR $($g.Id) su GitHub" }
        return [int]$g.Id
    }
    $corpo = @{
        sourceRefName = "refs/heads/$Ramo"
        targetRefName = "refs/heads/$Destinazione"
        title         = $Titolo
        description   = Add-FirmaPr $Descrizione
    }
    if ($CardId -gt 0) { $corpo.workItemRefs = @(@{ id = "$CardId" }) }
    $r = Invoke-Ado -Metodo Post -Url ((Get-AdoRepoUrl $Progetto $Repo) + '/pullrequests?api-version=7.1') -Corpo $corpo
    [int]$r.pullRequestId
}

function Get-AdoDescrizionePr {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][int]$Id)
    $src = Get-SorgenteRepo -Progetto $Progetto -Repo $Repo
    if ($src.Tipo -eq 'github') { return Get-GhDescrizionePr $src.RepoGh $Id }
    $r = Invoke-Ado -Metodo Get -Url ((Get-AdoRepoUrl $Progetto $Repo) + "/pullrequests/$($Id)?api-version=7.1")
    [string]$r.description
}

function Set-AdoDescrizionePr {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][string]$Descrizione)
    $src = Get-SorgenteRepo -Progetto $Progetto -Repo $Repo
    if ($src.Tipo -eq 'github') { return Set-GhPr $src.RepoGh $Id @{ body = (Add-FirmaPr $Descrizione) } }
    [void](Invoke-Ado -Metodo Patch -Url ((Get-AdoRepoUrl $Progetto $Repo) + "/pullrequests/$($Id)?api-version=7.1") -Corpo @{ description = (Add-FirmaPr $Descrizione) })
}

function Set-AdoTitoloPr {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][string]$Titolo)
    $src = Get-SorgenteRepo -Progetto $Progetto -Repo $Repo
    if ($src.Tipo -eq 'github') { return Set-GhPr $src.RepoGh $Id @{ title = $Titolo } }
    [void](Invoke-Ado -Metodo Patch -Url ((Get-AdoRepoUrl $Progetto $Repo) + "/pullrequests/$($Id)?api-version=7.1") -Corpo @{ title = $Titolo })
}

function Complete-AdoPr {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][int]$Id,
        # D52: il commit di testa che chi decide ha verificato. Se la testa e cambiata dopo, Azure DevOps rifiuta il completamento: il
        # commit riletto qui non deve prendere il posto di quello verificato. Senza, si legge l'ultimo (come prima).
        [string]$Commit)
    $src = Get-SorgenteRepo -Progetto $Progetto -Repo $Repo
    if ($src.Tipo -eq 'github') { return Complete-GhPr $src.RepoGh $Id $Commit }
    $url = (Get-AdoRepoUrl $Progetto $Repo) + "/pullrequests/$($Id)?api-version=7.1"
    if (-not $Commit) { $Commit = [string](Invoke-Ado -Metodo Get -Url $url).lastMergeSourceCommit.commitId }
    # Il ramo sorgente lo cancella Azure DevOps al completamento: niente push di cancellazione da fare da noi.
    $corpo = @{
        status = 'completed'; lastMergeSourceCommit = @{ commitId = $Commit }
        # noFastForward = merge commit: Remove-WorktreeCard riconosce il ramo assorbito con merge-base --is-ancestor, e
        # con squash o rebase il ramo non risulterebbe mai contenuto. Non si lascia al default dell'API.
        completionOptions = @{ deleteSourceBranch = $true; mergeStrategy = 'noFastForward' }
    }
    [void](Invoke-Ado -Metodo Patch -Url $url -Corpo $corpo)
}

# Rilancia le validazioni di build rosse (rejected o broken) della PR attiva del ramo: la stessa cosa del pulsante
# "Re-queue" della policy. Restituisce quante ne ha rilanciate (0 senza PR attiva o senza rosse). D38.
# Con -Scadute rilancia invece solo quelle scadute (context.isExpired), e nessun'altra. D47.
function Start-AdoRivalutazione {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Ramo,
        [switch]$Scadute,
        # il ramo verso cui va la PR: develop, o il ramo della funzionalita (D52)
        [string]$Destinazione = 'develop')
    $src = Get-SorgenteRepo -Progetto $Progetto -Repo $Repo
    if ($src.Tipo -eq 'github') {
        # GitHub Actions li rilancia GitHub.psm1; le build di Azure Pipelines che validano un repo GitHub si rilanciano qui
        # (retry dei job falliti), con il PAT di Azure DevOps.
        $g = Start-GhRivalutazione $src.RepoGh $Ramo -Scadute:$Scadute -Destinazione $Destinazione
        foreach ($b in @($g.BuildAdo)) {
            [void](Invoke-Ado -Metodo Patch -Url "$script:Org/$([uri]::EscapeDataString($Progetto))/_apis/build/builds/$($b)?retry=true&api-version=7.1")
        }
        return ([int]$g.Actions + @($g.BuildAdo).Count)
    }
    $url = (Get-AdoRepoUrl $Progetto $Repo) + "/pullrequests?searchCriteria.sourceRefName=refs/heads/$Ramo" +
        "&searchCriteria.targetRefName=refs/heads/$Destinazione&searchCriteria.status=active&api-version=7.1"
    $pr = @((Invoke-Ado -Metodo Get -Url $url).value) | Where-Object { $_.status -eq 'active' } | Select-Object -First 1
    if (-not $pr) { return 0 }
    $idProgetto = $pr.repository.project.id
    $art = [uri]::EscapeDataString("vstfs:///CodeReview/CodeReviewId/$idProgetto/$($pr.pullRequestId)")
    $ev = Invoke-Ado -Metodo Get -Url "$script:Org/$idProgetto/_apis/policy/evaluations?artifactId=$art&api-version=7.1-preview.1"
    $build = @(@($ev.value) | Where-Object { $_.configuration.type.displayName -eq 'Build' })
    # @(if ...): un elenco vuoto assegnato da un if diventa null, e `.Count` su null in StrictMode lancia un errore
    $daRilanciare = @(if ($Scadute) {
        @($build | Where-Object { $_.PSObject.Properties['context'] -and $_.context -and $_.context.PSObject.Properties['isExpired'] -and $_.context.isExpired -eq $true })
    } else { @($build | Where-Object { $_.status -in 'rejected', 'broken' }) })
    foreach ($e in $daRilanciare) {
        [void](Invoke-Ado -Metodo Patch -Url "$script:Org/$idProgetto/_apis/policy/evaluations/$($e.evaluationId)?api-version=7.1-preview.1")
    }
    $daRilanciare.Count
}

# Accoda la pipeline di deploy sul ramo con i parametri scelti dal responsabile a true (D43) e gli altri deploy* dello YAML
# (Spenti) a false: un default true non fa partire un componente che nessuno ha scelto. Gli altri parametri non si toccano.
function Start-AdoDeployTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][int]$PipelineId,
        [Parameter(Mandatory)][string]$Ramo, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Parametri,
        [string[]]$Spenti = @()
    )
    $nomi = @($Parametri | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($nomi.Count -eq 0) { throw 'Start-AdoDeployTest: nessun parametro di deploy, non accodo niente' }
    $template = @{}
    foreach ($n in @($Spenti | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) { $template[$n] = 'false' }
    foreach ($n in $nomi) { $template[$n] = 'true' }
    $corpo = @{
        resources          = @{ repositories = @{ self = @{ refName = "refs/heads/$Ramo" } } }
        templateParameters = $template
    }
    $r = Invoke-Ado -Metodo Post -Url "$script:Org/$([uri]::EscapeDataString($Progetto))/_apis/pipelines/$PipelineId/runs?api-version=7.1" -Corpo $corpo
    [int]$r.id
}

# I nomi dei parametri booleani della sezione parameters di uno YAML di pipeline che cominciano con deploy, nell'ordine.
# Niente parser YAML: la sezione va da "parameters:" a inizio riga alla chiave successiva a inizio riga; ogni elemento comincia
# con un trattino al rientro del primo, e vale se ha name e type: boolean (in qualunque ordine) al rientro delle sue chiavi,
# cioe quello del testo dopo il trattino: un type annidato (nel default di un object) non conta. Gli altri booleani
# (allowDatabaseDataLoss, forceRedeploy, ...) agiscono, non scelgono un componente: restano esclusi, sempre.
function ConvertFrom-YamlParametriDeploy([string]$Yaml) {
    $dentro = $false; $rientro = $null; $voce = $null
    $voci = [System.Collections.Generic.List[hashtable]]::new()
    $valore = { param($v) (($v -replace '\s+#.*$', '').Trim()).Trim('"', "'") }
    $chiave = { param($testo, [int]$colonna)
        if ($testo -match '^(name|type):\s*(.+)$' -and $colonna -eq $voce['_rientro'] -and -not $voce.Contains($Matches[1])) { $voce[$Matches[1]] = & $valore $Matches[2] }
    }
    # il BOM di un file salvato con UTF-8 con firma starebbe davanti a "parameters:"
    foreach ($riga in ($Yaml.TrimStart([char]0xFEFF) -split '\r?\n')) {
        if (-not $dentro) { if ($riga -match '^parameters:\s*(#.*)?$') { $dentro = $true }; continue }
        if ($riga -match '^\s*(#.*)?$') { continue }
        if ($riga -match '^[^\s#-]') { break }   # la chiave successiva a inizio riga chiude la sezione
        if ($riga -match '^((\s*)-\s+)(.*)$' -and ($null -eq $rientro -or $Matches[2].Length -eq $rientro)) {
            if ($null -eq $rientro) { $rientro = $Matches[2].Length }
            $voce = @{ _rientro = $Matches[1].Length }; $voci.Add($voce)
            & $chiave $Matches[3] $Matches[1].Length
            continue
        }
        if ($null -eq $voce) { continue }
        if ($riga -match '^(\s*)(\S.*)$') { & $chiave $Matches[2] $Matches[1].Length }
    }
    @(foreach ($v in $voci) { if ($v['type'] -eq 'boolean' -and "$($v['name'])" -clike 'deploy*') { [string]$v['name'] } })
}

# I parametri che il responsabile puo scegliere per il deploy in Test (D43): i booleani deploy* dello YAML della pipeline,
# letto sul ramo dato. Il percorso dello YAML e il repo vengono dalla definizione della pipeline, il contenuto dal repo.
function Get-AdoParametriDeploy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][int]$PipelineId, [Parameter(Mandatory)][string]$Ramo)
    $base = "$script:Org/$([uri]::EscapeDataString($Progetto))"
    $def = Invoke-Ado -Metodo Get -Url "$base/_apis/pipelines/$($PipelineId)?api-version=7.1"
    $conf = Get-Campo $def 'configuration'
    $percorso = [string](Get-Campo $conf 'path')
    $repo = [string](Get-Campo (Get-Campo $conf 'repository') 'id')
    if (-not $percorso -or -not $repo) {
        throw "La pipeline $PipelineId non dice dove sta il suo YAML (configuration.path e repository): non so quali parametri di deploy ha"
    }
    $url = "$base/_apis/git/repositories/$([uri]::EscapeDataString($repo))/items?path=$([uri]::EscapeDataString($percorso))" +
        "&versionDescriptor.version=$([uri]::EscapeDataString($Ramo))&versionDescriptor.versionType=branch&includeContent=true&`$format=json&api-version=7.1"
    # Una pipeline di Azure Pipelines su un repo GitHub: lo YAML si legge da GitHub (repository.type gitHub, id = owner/repo).
    if ([string](Get-Campo (Get-Campo $conf 'repository') 'type') -eq 'gitHub') {
        $full = [string](Get-Campo (Get-Campo $conf 'repository') 'fullName')
        if (-not $full) { $full = $repo }
        return ConvertFrom-YamlParametriDeploy (Get-GhFile $full $percorso $Ramo)
    }
    $item = Invoke-Ado -Metodo Get -Url $url
    ConvertFrom-YamlParametriDeploy ([string](Get-Campo $item 'content'))
}

# Il ramo della card pubblicato su origin, trovato per id come fa New-WorktreeDaRemoto (feature/<id>-... o fix/<id>-...);
# null se non c'e. Piu di uno e un errore: quale valga lo decide una persona.
# Con -FeatureId (D52) il ramo e quello della funzionalita, feature/f<id>-... o bugfix/f<id>-...: l'id e quello della Feature.
function Get-AdoRamoCard {
    [CmdletBinding(DefaultParameterSetName = 'DaCard')]
    param(
        [Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory, ParameterSetName = 'DaCard')][int]$CardId,
        [Parameter(Mandatory, ParameterSetName = 'DaFeature')][int]$FeatureId
    )
    $daFeature = $PSCmdlet.ParameterSetName -eq 'DaFeature'
    $prefissi = if ($daFeature) { Get-PrefissiRamoFunzionalita } else { 'feature', 'fix' }
    $nomeId = if ($daFeature) { Get-SiglaFunzionalita $FeatureId } else { "$CardId" }
    $src = Get-SorgenteRepo -Progetto $Progetto -Repo $Repo
    $rami = @(foreach ($tipo in $prefissi) {
        $nomi = if ($src.Tipo -eq 'github') { @(Get-GhRami $src.RepoGh "$tipo/$nomeId") }
                else {
                    $r = Invoke-Ado -Metodo Get -Url ((Get-AdoRepoUrl $Progetto $Repo) + "/refs?filter=$([uri]::EscapeDataString("heads/$tipo/$nomeId"))&api-version=7.1")
                    @(@($r.value) | ForEach-Object { [string](Get-Campo $_ 'name') -replace '^refs/heads/', '' })
                }
        foreach ($nome in $nomi) {
            if ($daFeature) { if ($nome -match (Get-RegexRamoFunzionalita $FeatureId)) { $nome } }
            elseif ($nome -match "^($($prefissi -join '|'))/$nomeId(-.*)?$") { $nome }
        }
    })
    $di = if ($daFeature) { "della funzionalita $FeatureId" } else { "della card $CardId" }
    if ($rami.Count -gt 1) { throw "Su origin c'e piu di un ramo ${di}: $($rami -join ', '). Quale vale lo decide una persona" }
    if ($rami.Count -eq 1) { return $rami[0] }
    $null
}

function Get-AdoRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][int]$RunId)
    $r = Invoke-Ado -Metodo Get -Url "$script:Org/$([uri]::EscapeDataString($Progetto))/_apis/build/builds/$($RunId)?api-version=7.1"
    # una run ancora in corso non ha il campo result: con StrictMode leggerlo direttamente rompe la lettura della card
    $esito = if ($r.PSObject.Properties['result']) { $r.result } else { $null }
    # il commit su cui e girata la run (D52: il merge della card di chiusura lo confronta con la testa della PR)
    $commit = if ($r.PSObject.Properties['sourceVersion']) { [string]$r.sourceVersion } else { $null }
    [pscustomobject]@{ Stato = $r.status; Esito = $esito; Url = (Get-AdoUrlBuild -Progetto $Progetto -Id $RunId); SourceVersion = $commit }
}

# La pagina di un run (build o pipeline YAML) per chi legge la card: un link, non l'URL delle API.
function Get-AdoUrlBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][int]$Id)
    "$script:Org/$([uri]::EscapeDataString($Progetto))/_build/results?buildId=$Id"
}

# La pagina di una PR per chi legge la vista: un link, non l'URL delle API.
function Get-AdoUrlPr {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][int]$Id)
    $src = Get-SorgenteRepo -Progetto $Progetto -Repo $Repo
    if ($src.Tipo -eq 'github') { return Get-GhUrlPr $src.RepoGh $Id }
    "$script:Org/$([uri]::EscapeDataString($Progetto))/_git/$([uri]::EscapeDataString($Repo))/pullrequest/$Id"
}

# ---- task figli della card -----------------------------------------------------------------------------------------
# Il tipo e le relazioni sono quelli del processo (verificati dal vivo); gli stati dei task stanno in config/stati.json.
$script:TipoTask = 'Task'
$script:RelazioneVersoPadre = 'System.LinkTypes.Hierarchy-Reverse'
$script:RelazioneVersoFigli = 'System.LinkTypes.Hierarchy-Forward'
# La dipendenza fra card e il link standard Predecessor: sulla card successiva, verso la precedente.
$script:RelazioneVersoPredecessore = 'System.LinkTypes.Dependency-Reverse'

function ConvertTo-Task($wi) {
    $f = $wi.fields
    $campo = { param($n) if ($f.PSObject.Properties[$n]) { $f.$n } else { $null } }
    [pscustomobject]@{
        Id          = [int]$wi.id
        Titolo      = & $campo 'System.Title'
        Descrizione = & $campo 'System.Description'
        Stato       = & $campo 'System.State'
        Tipo        = & $campo 'System.WorkItemType'
    }
}

# Crea un Task figlio della card, con la stessa area. Non imposta lo stato: nasce in quello iniziale del processo.
function New-AdoTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$CardId,
        [Parameter(Mandatory)][string]$Titolo,
        [Parameter(Mandatory)][string]$Descrizione,
        [Parameter(Mandatory)][string]$Area
    )
    $progetto = ($Area -split '\\')[0]
    $ops = @(
        [ordered]@{ op = 'add'; path = '/fields/System.Title'; value = $Titolo }
        [ordered]@{ op = 'add'; path = '/fields/System.AreaPath'; value = $Area }
        New-OpMarkdown 'System.Description'
        [ordered]@{ op = 'add'; path = '/fields/System.Description'; value = $Descrizione }
        [ordered]@{ op = 'add'; path = '/relations/-'; value = [ordered]@{ rel = $script:RelazioneVersoPadre; url = "$script:Org/_apis/wit/workItems/$CardId" } }
    )
    $url = "$script:Org/$([uri]::EscapeDataString($progetto))/_apis/wit/workitems/`$$([uri]::EscapeDataString($script:TipoTask))?api-version=7.1"
    ConvertTo-Task (Invoke-Ado -Metodo Post -Url $url -ContentType 'application/json-patch+json' `
        -Corpo (ConvertTo-Json -InputObject @($ops) -Depth 10 -Compress))
}

# I work item che la card collega con una relazione, nell'ordine dei loro id: prima la card con le relazioni, poi il batch.
# Con -ConRelazioni anche i work item letti portano le loro relazioni ($expand=relations nella stessa lettura).
function Get-AdoRelati([int]$CardId, [string]$Relazione, [switch]$ConRelazioni) {
    $card = Invoke-Ado -Metodo Get -Url "$script:Org/_apis/wit/workitems/$($CardId)?`$expand=relations&api-version=7.1"
    $rel = if ($card.PSObject.Properties['relations']) { @($card.relations) } else { @() }
    $ids = @(foreach ($r in $rel) {
        if ($r -and $r.rel -eq $Relazione) { [int](([string]$r.url -split '/')[-1]) }
    }) | Sort-Object
    Get-AdoLotto @($ids) -ConRelazioni:$ConRelazioni
}

# Un lotto di work item per id. Con -Omit (errorPolicy=Omit) un work item che non si legge e omesso invece di far fallire il lotto.
function Get-AdoLotto([int[]]$Ids, [switch]$ConRelazioni, [switch]$Omit) {
    if (@($Ids).Count -eq 0) { return @() }
    $url = "$script:Org/_apis/wit/workitems?ids=$(@($Ids) -join ',')$(if ($ConRelazioni) { '&$expand=relations' })$(if ($Omit) { '&errorPolicy=Omit' })&api-version=7.1"
    @((Invoke-Ado -Metodo Get -Url $url).value | Where-Object { $null -ne $_ })
}

# I Task figli della card, in ordine di id (e l'ordine in cui sono stati creati). Gli altri figli si scartano.
function Get-AdoTaskFigli {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$CardId)
    @(Get-AdoRelati $CardId $script:RelazioneVersoFigli | ForEach-Object { ConvertTo-Task $_ } | Where-Object { $_.Tipo -eq $script:TipoTask } | Sort-Object Id)
}

# L'id del padre (link Parent) di un work item letto con le relazioni, o null senza padre.
function Get-IdPadre($Wi) {
    $rel = Get-CampoAdo $Wi 'relations'
    $padre = @(@($rel) | Where-Object { $_ -and $_.rel -eq $script:RelazioneVersoPadre }) | Select-Object -First 1
    if ($padre) { [int](([string]$padre.url -split '/')[-1]) } else { $null }
}

# Le card che devono essere unite prima di questa (link Predecessor), con id, stato, tag (elenco) e l'id del padre (PadreId, null
# senza padre; il tipo del padre non si controlla), in ordine di id. Nessuna = elenco vuoto. Il padre viene dalle relazioni lette con il batch: niente chiamata in piu.
# I tag servono alla vista: una predecessora in New senza il tag agenti non la prende nessuno smistatore.
function Get-AdoCardPredecessori {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$CardId)
    @(Get-AdoRelati $CardId $script:RelazioneVersoPredecessore -ConRelazioni | ForEach-Object {
        [pscustomobject]@{ Id = [int]$_.id; Stato = $_.fields.'System.State'; Tag = @(ConvertTo-ElencoTag (Get-CampoAdo $_.fields 'System.Tags')); PadreId = (Get-IdPadre $_) }
    } | Sort-Object Id)
}

# ---- Feature (D52) -------------------------------------------------------------------------------------------------
$script:TipoFeature = 'Feature'

# Il padre di una card, in una lettura sola: i campi del work item (tipo, titolo, stato, tag, area) e, dalle sue relazioni, gli id
# delle figlie (link Child, in ordine di id). Il tipo dice se e una Feature: chi legge lo controlla.
function Get-AdoFeature {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id)
    $wi = Invoke-Ado -Metodo Get -Url "$script:Org/_apis/wit/workitems/$($Id)?`$expand=relations&api-version=7.1"
    $rel = @(@(Get-CampoAdo $wi 'relations') | Where-Object { $_ -and $_.rel -eq $script:RelazioneVersoFigli })
    [pscustomobject]@{
        Id = [int]$wi.id; Tipo = (Get-CampoAdo $wi.fields 'System.WorkItemType'); Titolo = (Get-CampoAdo $wi.fields 'System.Title')
        Stato = (Get-CampoAdo $wi.fields 'System.State'); Tag = @(ConvertTo-ElencoTag (Get-CampoAdo $wi.fields 'System.Tags'))
        Area = (Get-CampoAdo $wi.fields 'System.AreaPath')
        FigliIds = @(@($rel | ForEach-Object { [int](([string]$_.url -split '/')[-1]) }) | Sort-Object)
    }
}

# Le figlie della Feature (link Child), di ogni tipo e stato, con id, stato, tag e tipo, in ordine di id. Con -FigliIds (gli id
# che Get-AdoFeature ha gia letto) e una chiamata sola, a lotto con errorPolicy=Omit: una figlia che non si legge manca dall'elenco.
function Get-AdoFigliFeature {
    [CmdletBinding(DefaultParameterSetName = 'DaFeature')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'DaFeature')][int]$FeatureId,
        [Parameter(Mandatory, ParameterSetName = 'DaIds')][AllowEmptyCollection()][int[]]$FigliIds
    )
    $wi = if ($PSCmdlet.ParameterSetName -eq 'DaIds') { Get-AdoLotto $FigliIds -Omit } else { Get-AdoRelati $FeatureId $script:RelazioneVersoFigli }
    @($wi | ForEach-Object {
        [pscustomobject]@{ Id = [int]$_.id; Stato = (Get-CampoAdo $_.fields 'System.State'); Tag = @(ConvertTo-ElencoTag (Get-CampoAdo $_.fields 'System.Tags')); Tipo = (Get-CampoAdo $_.fields 'System.WorkItemType'); Titolo = (Get-CampoAdo $_.fields 'System.Title') }
    } | Sort-Object Id)
}

# D60: il campo dell'ordine del backlog (lo stesso che Azure DevOps cambia quando si trascina una riga del backlog o una card dentro una colonna).
$script:CampoRank = 'Microsoft.VSTS.Common.StackRank'

# D60: le Feature aperte (non Closed, non Removed) nelle aree della mappa, con Id, Titolo, Stato, Tag, Area e Rank (null se mai ordinata).
# Solo le aree della mappa: le Feature di altri gruppi del progetto non si mostrano e non si riordinano. Letture a lotti di 200 (il massimo di ADO).
function Get-AdoFeatureAperte {
    [CmdletBinding()]
    param()
    $s = Get-AdoStati
    $progetto = Get-AdoProgettoBoard
    $mappa = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/mappa.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $aree = @($mappa.aree) | ForEach-Object { "[System.AreaPath] UNDER '$($_.area -replace "'", "''")'" }
    $q = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$progetto' AND [System.WorkItemType] = '$script:TipoFeature' " +
         "AND [System.State] <> '$($s.featureChiusa)' AND [System.State] <> '$($s.featureRimossa)' AND ($(@($aree) -join ' OR ')) ORDER BY [System.Id]"
    $r = Invoke-Ado -Metodo Post -Url "$script:Org/$([uri]::EscapeDataString($progetto))/_apis/wit/wiql?api-version=7.1" -Corpo @{ query = $q }
    $ids = @(@($r.workItems) | Where-Object { $_ } | ForEach-Object { [int]$_.id })
    $letti = @(for ($i = 0; $i -lt $ids.Count; $i += 200) { Get-AdoLotto @($ids[$i..([math]::Min($i + 199, $ids.Count - 1))]) -Omit })
    @($letti | ForEach-Object {
        $rank = Get-CampoAdo $_.fields $script:CampoRank
        [pscustomobject]@{
            Id = [int]$_.id; Titolo = (Get-CampoAdo $_.fields 'System.Title'); Stato = (Get-CampoAdo $_.fields 'System.State')
            Tag = @(ConvertTo-ElencoTag (Get-CampoAdo $_.fields 'System.Tags')); Area = (Get-CampoAdo $_.fields 'System.AreaPath')
            Rank = $(if ($null -ne $rank -and "$rank" -ne '') { [double]$rank } else { $null })
        }
    })
}

# D60: scrive l'ordine del backlog di un work item.
function Set-AdoRank {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][double]$Rank)
    [void](Set-AdoCard -Id $Id -Campi @{ $script:CampoRank = $Rank })
}

# Lo stato di una Feature: lo scrive come quello di una card.
function Set-AdoStatoFeature {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$FeatureId, [Parameter(Mandatory)][string]$Stato)
    Set-AdoCard -Id $FeatureId -Stato $Stato
}

function Set-AdoTaskStato {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][string]$Stato)
    $ops = @([ordered]@{ op = 'add'; path = '/fields/System.State'; value = $Stato })
    $r = Invoke-Ado -Metodo Patch -Url "$script:Org/_apis/wit/workitems/$($Id)?api-version=7.1" `
        -Corpo (ConvertTo-Json -InputObject @($ops) -Depth 10 -Compress) -ContentType 'application/json-patch+json'
    [int]$r.rev
}

# Gli errori di una build fallita, come testo da dare a dev: i passi falliti, i test falliti con messaggio e stack, le
# righe ##[error]. dev non ha il PAT e non puo leggere il log da solo (card 9, 2026-11-17). Senza orari e senza i test
# passati: il log di "Run tests" ha centinaia di righe e quelle utili sono poche.
function Get-AdoErroriBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][int]$BuildId, [int]$MaxRighe = 400,
        # D52: restituisce gli errori solo se un passo fallito ha test falliti o errori di compilazione (Test-RigaErroreCodice), altrimenti
        # null: un timeout, un agente perso, un passo di deploy sono infrastruttura, non codice. Senza passi falliti, null.
        [switch]$SoloCodice)
    $t = Invoke-Ado -Metodo Get -Url "$script:Org/$([uri]::EscapeDataString($Progetto))/_apis/build/builds/$BuildId/timeline?api-version=7.1"
    $falliti = @(@($t.records) | Where-Object { $_.type -eq 'Task' -and $_.result -eq 'failed' })
    if ($falliti.Count -eq 0) { if ($SoloCodice) { return $null }; return "La build $BuildId non ha nessun passo fallito nella timeline." }
    $out = [System.Collections.Generic.List[string]]::new()
    $codice = $false
    foreach ($r in $falliti) {
        $out.Add("Passo '$($r.name)' fallito.")
        $url = if ($r.PSObject.Properties['log'] -and $r.log -and $r.log.PSObject.Properties['url']) { [string]$r.log.url } else { $null }
        if (-not $url) { $out.Add('(nessun log per questo passo)'); continue }
        $righe = @(([string](Invoke-Ado -Metodo Get -Url "$url`?api-version=7.1")) -split "`r?`n" | ForEach-Object { $_ -replace '^\d{4}-\d\d-\d\dT[\d:.]+Z ?', '' })
        $dentro = $false
        foreach ($riga in $righe) {
            if (Test-RigaErroreCodice $riga) { $codice = $true }
            if (Test-RigaTestFallito $riga) { $dentro = $true; $out.Add(''); $out.Add($riga.TrimEnd()); continue }
            if ($riga -match '^\s*(Passed|Skipped) ' -or $riga -match '^\[xUnit\.net') { $dentro = $false; continue }
            if ($riga -match '##\[error\]') { $dentro = $false; $out.Add($riga.TrimEnd()); continue }
            if ($dentro) { $out.Add($riga.TrimEnd()) }
        }
        if ($out.Count -ge $MaxRighe) { break }
    }
    if ($SoloCodice -and -not $codice) { return $null }
    (@($out) | Select-Object -First $MaxRighe) -join "`n"
}

# Una riga di log che dice che il difetto e nel codice: un test fallito ("Failed <nome>") o un errore di compilazione (C#, MSBuild, NuGet,
# TypeScript). E il solo posto dove le espressioni stanno: Get-AdoErroriBuild le usa per estrarre gli errori e per -SoloCodice.
function Test-RigaTestFallito([string]$Riga) { $Riga -match '^\s*Failed ' }
function Test-RigaErroreCodice([string]$Riga) { (Test-RigaTestFallito $Riga) -or $Riga -match 'error (CS|MSB|NU|TS)\d+' }

# Perche e fallito un run, in poche righe: i messaggi delle issues dei record falliti della timeline e le ultime righe del log
# del primo passo fallito. Serve al supervisore (D51) per distinguere un guasto dell'infrastruttura (agente perso, timeout) da
# un errore del codice. Solo GET; il testo e tagliato a $MaxCaratteri.
function Get-AdoMotivoFallimento {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][int]$BuildId, [int]$RigheLog = 15, [int]$MaxCaratteri = 2000)
    $base = "$script:Org/$([uri]::EscapeDataString($Progetto))/_apis/build/builds/$BuildId"
    $t = Invoke-Ado -Metodo Get -Url "$base/timeline?api-version=7.1"
    $falliti = @(@($t.records) | Where-Object { (Get-CampoAdo $_ 'result') -eq 'failed' })
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $falliti) {
        foreach ($i in @(Get-CampoAdo $r 'issues')) {
            $m = [string](Get-CampoAdo $i 'message')
            if ($m) { $out.Add($m.Trim()) }
        }
    }
    # le ultime righe del log del primo passo fallito (un Task): li' c'e il testo dell'errore quando le issues non lo dicono
    $passo = @($falliti | Where-Object { (Get-CampoAdo $_ 'type') -eq 'Task' }) | Select-Object -First 1
    $url = if ($passo) { [string](Get-CampoAdo (Get-CampoAdo $passo 'log') 'url') } else { '' }
    if ($url) {
        try {
            $righe = @(([string](Invoke-Ado -Metodo Get -Url "$url`?api-version=7.1")) -split "`r?`n" | ForEach-Object { ($_ -replace '^\d{4}-\d\d-\d\dT[\d:.]+Z ?', '').TrimEnd() } | Where-Object { $_ })
            foreach ($riga in @($righe | Select-Object -Last $RigheLog)) { $out.Add($riga) }
        }
        catch { }
    }
    $testo = @($out) -join "`n"
    if ($testo.Length -gt $MaxCaratteri) { $testo = $testo.Substring(0, $MaxCaratteri) }
    $testo
}

# L'ultimo run di una definizione su un ramo (qualunque stato), o $null: serve a sapere se un run fallito e ancora l'ultimo e se uno
# piu recente e riuscito. Solo GET.
function Get-AdoUltimoRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][int]$DefinizioneId, [Parameter(Mandatory)][string]$Ramo)
    $url = "$script:Org/$([uri]::EscapeDataString($Progetto))/_apis/build/builds?definitions=$DefinizioneId&branchName=$([uri]::EscapeDataString("refs/heads/$Ramo"))&queryOrder=queueTimeDescending" + '&$top=1&api-version=7.1'
    $b = @((Invoke-Ado -Metodo Get -Url $url).value) | Select-Object -First 1
    if (-not $b) { return $null }
    [pscustomobject]@{ Id = [int]$b.id; Stato = [string](Get-CampoAdo $b 'status'); Esito = [string](Get-CampoAdo $b 'result') }
}

# D61: l'ultimo run riuscito di una pipeline su un ramo (il deploy di develop in Test): id, commit deployato, fine, link; null se non ce n'e.
function Get-AdoUltimoRunRiuscito {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][int]$DefinizioneId, [Parameter(Mandatory)][string]$Ramo)
    $url = "$script:Org/$([uri]::EscapeDataString($Progetto))/_apis/build/builds?definitions=$DefinizioneId&branchName=$([uri]::EscapeDataString("refs/heads/$Ramo"))" +
        '&statusFilter=completed&resultFilter=succeeded&queryOrder=finishTimeDescending&$top=1&api-version=7.1'
    $b = @((Invoke-Ado -Metodo Get -Url $url).value) | Select-Object -First 1
    if (-not $b) { return $null }
    [pscustomobject]@{ Id = [int]$b.id; Commit = [string](Get-CampoAdo $b 'sourceVersion'); Fine = (ConvertTo-DataUtc (Get-CampoAdo $b 'finishTime')); Url = (Get-AdoUrlBuild -Progetto $Progetto -Id ([int]$b.id)) }
}

# D61: vero se il commit Commit e contenuto in In (e un suo antenato, o e lui): l'antenato comune dei due e Commit stesso.
function Test-AdoCommitContenuto {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Commit, [Parameter(Mandatory)][string]$In)
    if ($Commit -ieq $In) { return $true }
    $src = Get-SorgenteRepo -Progetto $Progetto -Repo $Repo
    if ($src.Tipo -eq 'github') { return Test-GhCommitContenuto $src.RepoGh $Commit $In }
    $url = (Get-AdoRepoUrl $Progetto $Repo) + "/diffs/commits?baseVersion=$Commit&baseVersionType=commit&targetVersion=$In&targetVersionType=commit" + '&$top=1&api-version=7.1'
    $r = Invoke-Ado -Metodo Get -Url $url
    [string](Get-CampoAdo $r 'commonCommit') -ieq $Commit
}

# Accoda un run nuovo della stessa definizione sullo stesso ramo, con la stessa versione di sorgente e gli stessi parametri del
# run originale (il rilancio di un run fallito per infrastruttura, D51: rifa quello che e fallito, non un'altra cosa). Non e un
# deploy ne un'approvazione: e la stessa POST del pulsante "Run new". Un ramo che non e un ramo (la validazione di una PR,
# "PR #12") non si rilancia da qui. Restituisce l'id del run nuovo.
function Start-AdoRilancioRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Progetto, [Parameter(Mandatory)][int]$DefinizioneId, [Parameter(Mandatory)][string]$Ramo,
        [string]$SourceVersion, $ParametriTemplate = $null)
    if ($Ramo -match '^PR #' -or [string]::IsNullOrWhiteSpace($Ramo)) { throw "Start-AdoRilancioRun: '$Ramo' non e un ramo, non rilancio niente" }
    $corpo = @{ definition = @{ id = $DefinizioneId }; sourceBranch = "refs/heads/$Ramo" }
    if (-not [string]::IsNullOrWhiteSpace($SourceVersion)) { $corpo['sourceVersion'] = $SourceVersion }
    if ($null -ne $ParametriTemplate) {
        $t = @{}
        foreach ($p in @($ParametriTemplate.PSObject.Properties)) { $t[$p.Name] = [string]$p.Value }
        if ($t.Count -gt 0) { $corpo['templateParameters'] = $t }
    }
    $r = Invoke-Ado -Metodo Post -Url "$script:Org/$([uri]::EscapeDataString($Progetto))/_apis/build/builds?api-version=7.1" -Corpo $corpo
    [int]$r.id
}

# La PR collegata alla card piu recente (la crea New-AdoPr con il collegamento al work item), con il suo stato, o
# $null. Serve quando il ramo non c'e piu, per esempio dopo il merge: la card la ricorda comunque.
# Un link (relazione Hyperlink) sulla card: la PR di GitHub collegata. Un link che c'e gia non si aggiunge due volte.
function Add-AdoLinkCard {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][string]$Url, [string]$Commento)
    $w = Invoke-Ado -Metodo Get -Url "$script:Org/_apis/wit/workitems/$($Id)?`$expand=relations&api-version=7.1"
    $rel = if ($w.PSObject.Properties['relations']) { @($w.relations) } else { @() }
    if (@($rel | Where-Object { $_ -and $_.rel -eq 'Hyperlink' -and [string]$_.url -eq $Url }).Count -gt 0) { return }
    $valore = [ordered]@{ rel = 'Hyperlink'; url = $Url }
    if ($Commento) { $valore.attributes = @{ comment = $Commento } }
    [void](Invoke-Ado -Metodo Patch -Url "$script:Org/_apis/wit/workitems/$($Id)?api-version=7.1" -ContentType 'application/json-patch+json' `
        -Corpo (ConvertTo-Json -InputObject @([ordered]@{ op = 'add'; path = '/relations/-'; value = $valore }) -Depth 10 -Compress))
}

function Get-AdoPrCollegata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$CardId)
    $w = Invoke-Ado -Metodo Get -Url "$script:Org/_apis/wit/workitems/$($CardId)?`$expand=relations&api-version=7.1"
    $rel = if ($w.PSObject.Properties['relations']) { @($w.relations) } else { @() }
    $ids = @($rel | Where-Object { $_ -and $_.rel -eq 'ArtifactLink' -and [string]$_.url -match '^vstfs:///Git/PullRequestId/.*%2[fF](\d+)$' } |
            ForEach-Object { [int]([regex]::Match([string]$_.url, '%2[fF](\d+)$').Groups[1].Value) } | Sort-Object)
    if ($ids.Count -eq 0) {
        # Le PR di GitHub sono collegate con un link sulla card (New-AdoPr): l'ultima, per numero.
        $gh = @($rel | Where-Object { $_ -and $_.rel -eq 'Hyperlink' } | ForEach-Object { ConvertFrom-GhUrlPr ([string]$_.url) } | Where-Object { $_ } | Sort-Object Id)
        if ($gh.Count -eq 0) { return $null }
        $ultimo = $gh[-1]
        $dove = Find-RepoDaGitHub $ultimo.RepoGh
        if (-not $dove) { throw "La card $CardId e collegata alla PR $($ultimo.Id) di $($ultimo.RepoGh), che non e un repo di config/mappa.json" }
        $p = Get-GhPrSingola $ultimo.RepoGh $ultimo.Id
        return [pscustomobject]@{ Id = [int]$p.number; Stato = (ConvertTo-StatoPrGh $p); Titolo = [string]$p.title
            Progetto = $dove.Progetto; Repo = $dove.Repo; Ramo = [string](Get-Campo (Get-Campo $p 'head') 'ref')
            CommitMerge = $(if (Get-Campo $p 'merge_commit_sha') { [string]$p.merge_commit_sha } else { $null }) }
    }
    $pr = Invoke-Ado -Metodo Get -Url "$script:Org/_apis/git/pullrequests/$($ids[-1])?api-version=7.1"
    [pscustomobject]@{ Id = [int]$pr.pullRequestId; Stato = [string]$pr.status; Titolo = [string]$pr.title
        Progetto = [string]$pr.repository.project.name; Repo = [string]$pr.repository.name; Ramo = ([string]$pr.sourceRefName -replace '^refs/heads/', '')
        CommitMerge = $(if (Get-CampoAdo $pr 'lastMergeCommit') { [string](Get-CampoAdo (Get-CampoAdo $pr 'lastMergeCommit') 'commitId') } else { $null }) }
}

function Get-AdoUtenteCorrente {
    [CmdletBinding()]
    param()
    $r = Invoke-Ado -Metodo Get -Url "$script:Org/_apis/connectionData?api-version=7.1-preview"
    $u = $r.authenticatedUser
    $conto = if ($u.PSObject.Properties['properties'] -and $u.properties.PSObject.Properties['Account']) { [string]$u.properties.Account.'$value' } else { $null }
    [pscustomobject]@{ Id = $u.id; Nome = $u.providerDisplayName; Email = $conto }
}

# ---- le pipeline di tutta l'organizzazione (solo lettura, per la vista) --------------------------------------------

# Un campo che puo mancare nella risposta (con StrictMode leggerlo direttamente rompe): il valore o $null.
function Get-CampoAdo($Oggetto, [string]$Nome) {
    if ($null -ne $Oggetto -and $Oggetto.PSObject.Properties[$Nome]) { $Oggetto.PSObject.Properties[$Nome].Value } else { $null }
}

# Una data di Azure DevOps in UTC: Invoke-RestMethod la da gia come DateTime, ma un testo ISO e ammesso.
function ConvertTo-DataUtc($Valore) {
    if ($null -eq $Valore -or "$Valore" -eq '') { return $null }
    if ($Valore -is [datetime]) { return $Valore.ToUniversalTime() }
    $stili = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    $d = [datetime]::MinValue
    if ([datetime]::TryParse("$Valore", [Globalization.CultureInfo]::InvariantCulture, $stili, [ref]$d)) { $d } else { $null }
}

# Dove e fermo un run in corso, dalla timeline: l'approvazione o la validazione manuale che aspetta (con la fase che la richiede) oppure la fase che gira.
# Ritorna @{ Approvazione = bool; Fase = nome o $null }.
function Get-FaseRun($Record) {
    $per = @{}
    $lav = @($Record | Where-Object { (Get-CampoAdo $_ 'type') -eq 'Job' } | ForEach-Object { [string](Get-CampoAdo $_ 'workerName') } | Where-Object { $_ })
    foreach ($r in $Record) { $per["$(Get-CampoAdo $r 'id')"] = $r }
    $inCorso = { param($r, $tipo) (Get-CampoAdo $r 'type') -eq $tipo -and (Get-CampoAdo $r 'state') -eq 'inProgress' }
    # un'attesa di una persona: l'approvazione di un environment (Checkpoint.Approval) o il task ManualValidation di un job agentless
    $app = @($Record | Where-Object { (& $inCorso $_ 'Checkpoint.Approval') -or ((& $inCorso $_ 'Task') -and "$(Get-CampoAdo (Get-CampoAdo $_ 'task') 'name')" -eq 'ManualValidation') }) | Select-Object -First 1
    if ($app) {
        # si sale dai genitori (approvazione, checkpoint) fino alla fase che l'ha chiesta
        $r = $app
        for ($i = 0; $i -lt 6 -and $null -ne $r -and (Get-CampoAdo $r 'type') -ne 'Stage'; $i++) { $r = $per["$(Get-CampoAdo $r 'parentId')"] }
        return @{ Approvazione = $true; Fase = $(if ($r) { [string](Get-CampoAdo $r 'name') } else { $null }); Lavoratori = $lav }
    }
    # un controllo dell'environment in corso (lock esclusivo, finestra oraria, funzione esterna: un Checkpoint che non e
    # un'approvazione) senza job che girano: il run aspetta di partire, non occupa un agente
    if (@($Record | Where-Object { & $inCorso $_ 'Job' }).Count -eq 0) {
        $chk = @($Record | Where-Object { "$(Get-CampoAdo $_ 'type')" -like 'Checkpoint*' -and (Get-CampoAdo $_ 'state') -eq 'inProgress' }) | Select-Object -First 1
        if ($chk) {
            $r = $chk
            for ($i = 0; $i -lt 6 -and $null -ne $r -and (Get-CampoAdo $r 'type') -ne 'Stage'; $i++) { $r = $per["$(Get-CampoAdo $r 'parentId')"] }
            # se il controllo non sta sotto uno stage, lo stage in attesa e quello che non e ancora partito per primo
            if ($null -eq $r) { $r = @($Record | Where-Object { (Get-CampoAdo $_ 'type') -eq 'Stage' -and (Get-CampoAdo $_ 'state') -ne 'completed' } | Sort-Object { [int](Get-CampoAdo $_ 'order') }) | Select-Object -First 1 }
            return @{ Approvazione = $false; Attende = 'controllo'; Fase = $(if ($r) { [string](Get-CampoAdo $r 'name') } else { $null }); Lavoratori = $lav }
        }
    }
    # un run "in corso" senza job che girano, con un job in attesa sotto uno stage gia partito: quel job aspetta un agente,
    # quindi per chi guarda il run e in coda (succede ai rilasci quando gli agenti sono tutti occupati)
    if (@($Record | Where-Object { & $inCorso $_ 'Job' }).Count -eq 0) {
        $stageVivi = @($Record | Where-Object { & $inCorso $_ 'Stage' } | ForEach-Object { [string](Get-CampoAdo $_ 'id') })
        $attesa = @($Record | Where-Object { (Get-CampoAdo $_ 'type') -eq 'Job' -and (Get-CampoAdo $_ 'state') -eq 'pending' } | Where-Object {
                $r = $_
                for ($i = 0; $i -lt 4 -and $null -ne $r -and (Get-CampoAdo $r 'type') -ne 'Stage'; $i++) { $r = $per["$(Get-CampoAdo $r 'parentId')"] }
                $null -ne $r -and [string](Get-CampoAdo $r 'id') -in $stageVivi
            }) | Select-Object -First 1
        if ($attesa) { return @{ Approvazione = $false; Attende = 'agente'; Fase = [string](Get-CampoAdo $attesa 'name'); Lavoratori = $lav } }
    }
    # lo stage "__default" e quello implicito delle pipeline senza stage: non dice niente, si mostra il job
    $stage = @($Record | Where-Object { (& $inCorso $_ 'Stage') -and "$(Get-CampoAdo $_ 'name')" -notlike '__*' }) | Select-Object -First 1
    $job = if (-not $stage) { @($Record | Where-Object { & $inCorso $_ 'Job' }) | Select-Object -First 1 } else { $null }
    $x = if ($stage) { $stage } else { $job }
    @{ Approvazione = $false; Fase = $(if ($x) { [string](Get-CampoAdo $x 'name') } else { $null }); Lavoratori = $lav }
}

# Su che agenti gira un run, dai nomi degli agenti dei suoi job (workerName della timeline): "Azure Pipelines N" e "Hosted Agent"
# sono i Microsoft-hosted (cloud), ogni altro nome e un agente nostro (interno); job su tutti e due = misto. La coda del run non
# basta: e il pool predefinito della pipeline, e lo YAML lo sostituisce (una build-ci in coda su "Hosted Ubuntu" gira su un agente interno).
function Get-AgenteDaLavoratori([string[]]$Nomi) {
    $n = @($Nomi | Where-Object { $_ } | Sort-Object -Unique)
    if ($n.Count -eq 0) { return @{ Agente = ''; Nome = '' } }
    $cloud = @($n | Where-Object { $_ -like 'Azure Pipelines*' -or $_ -like 'Hosted Agent*' })
    $tipo = if ($cloud.Count -eq $n.Count) { 'cloud' } elseif ($cloud.Count -eq 0) { 'interno' } else { 'misto' }
    $nomi = @($n | Where-Object { $_ -notin $cloud }) + @(if ($cloud.Count) { 'Microsoft-hosted' })
    @{ Agente = $tipo; Nome = ($nomi -join ', ') }
}

# L'agente abituale di una pipeline, per i run che non hanno ancora (o non si legge) la timeline: quello dell'ultimo run concluso
# che ha girato davvero (fra gli ultimi cinque).
# Si ricorda per un'ora, per non leggere due volte al minuto le stesse timeline.
$script:AgentiDefinizione = @{}
function Get-AgenteAbituale([string]$Progetto, [int]$DefinizioneId, [datetime]$Adesso) {
    $k = "$Progetto/$DefinizioneId"
    $c = $script:AgentiDefinizione[$k]
    if ($c -and ($Adesso - $c.Letto).TotalMinutes -lt 60) { return $c }
    $base = "$script:Org/$([uri]::EscapeDataString($Progetto))/_apis/build/builds"
    $v = @{ Agente = ''; Nome = ''; Letto = $Adesso }
    try {
        # il primo degli ultimi run conclusi che un agente l'ha preso davvero: un run annullato in coda non ha job con un agente
        $u = @((Invoke-Ado -Metodo Get -Url ($base + "?definitions=$DefinizioneId&statusFilter=completed" + '&$top=5&api-version=7.1')).value)
        foreach ($r in $u) {
            $rec = @((Invoke-Ado -Metodo Get -Url "$base/$([int]$r.id)/timeline?api-version=7.1").records)
            $a = Get-AgenteDaLavoratori @($rec | Where-Object { (Get-CampoAdo $_ 'type') -eq 'Job' } | ForEach-Object { [string](Get-CampoAdo $_ 'workerName') })
            if ($a.Agente) { $v.Agente = $a.Agente; $v.Nome = $a.Nome; break }
        }
    }
    catch { }
    $script:AgentiDefinizione[$k] = $v
    $v
}

# La posizione vera in coda, dalle richieste dei pool di agenti (scope vso.agentpools del PAT): per ogni build con un job non
# ancora assegnato a un agente, la posizione nel suo pool (ordine di accodamento, come la serve ADO) e il nome del pool.
# Ritorna @{ <build id> = @{ Posizione; Pool } }. Senza permesso, o se un pool non risponde, quel pool non c'e: niente numeri inventati.
function Get-AdoCodaPool {
    $esito = @{}
    try { $pool = @((Invoke-Ado -Metodo Get -Url "$script:Org/_apis/distributedtask/pools?api-version=7.1").value) } catch { return $esito }
    foreach ($p in $pool) {
        try { $rq = @((Invoke-Ado -Metodo Get -Url "$script:Org/_apis/distributedtask/pools/$([int]$p.id)/jobrequests?completedRequestCount=0&api-version=7.1").value) }
        catch { continue }
        $attesa = @($rq | Where-Object { -not (Get-CampoAdo $_ 'assignTime') -and -not (Get-CampoAdo $_ 'result') } |
            Sort-Object @{ e = { ConvertTo-DataUtc (Get-CampoAdo $_ 'queueTime') } }, @{ e = { [int64](Get-CampoAdo $_ 'requestId') } })
        $i = 0
        foreach ($r in $attesa) {
            $i++
            $id = [int](Get-CampoAdo (Get-CampoAdo $r 'owner') 'id')
            if ($id -and -not $esito.ContainsKey($id)) { $esito[$id] = @{ Posizione = $i; Pool = [string](Get-CampoAdo $p 'name'); Ospitato = ((Get-CampoAdo $p 'isHosted') -eq $true) } }
        }
    }
    $esito
}

# Gli agenti dei pool interni (non ospitati da Microsoft), con lo stato e il lavoro che stanno facendo (scope vso.agentpools).
# I pool senza agenti non ci sono. Senza permesso, o se un pool non risponde, quel pool non c'e.
function Get-AdoAgentiPool {
    # -Errori: chi vuole sapere se la lettura e riuscita (il supervisore, D51) passa una lista, e ci trova cosa non si e letto. Senza,
    # niente cambia: un pool che non risponde non c'e, come per la vista.
    param([System.Collections.Generic.List[string]]$Errori)
    $out = [System.Collections.Generic.List[object]]::new()
    try { $pool = @((Invoke-Ado -Metodo Get -Url "$script:Org/_apis/distributedtask/pools?api-version=7.1").value | Where-Object { (Get-CampoAdo $_ 'isHosted') -ne $true }) }
    catch { if ($null -ne $Errori) { $Errori.Add("pool degli agenti: $($_.Exception.Message)") }; return @() }
    foreach ($p in $pool) {
        try { $ag = @((Invoke-Ado -Metodo Get -Url "$script:Org/_apis/distributedtask/pools/$([int]$p.id)/agents?includeAssignedRequest=true&api-version=7.1").value) }
        catch { if ($null -ne $Errori) { $Errori.Add("agenti del pool $(Get-CampoAdo $p 'name'): $($_.Exception.Message)") }; continue }
        if ($ag.Count -eq 0) { continue }
        $agenti = foreach ($a in ($ag | Sort-Object { [string](Get-CampoAdo $_ 'name') })) {
            $rq = Get-CampoAdo $a 'assignedRequest'
            $lavoro = $null
            if ($rq) {
                $own = Get-CampoAdo $rq 'owner'
                $url = [string](Get-CampoAdo (Get-CampoAdo (Get-CampoAdo $own '_links') 'web') 'href')
                $lavoro = [pscustomobject]@{ BuildId = [int](Get-CampoAdo $own 'id'); Pipeline = [string](Get-CampoAdo (Get-CampoAdo $rq 'definition') 'name'); Url = $url }
            }
            [pscustomobject]@{ Nome = [string](Get-CampoAdo $a 'name'); Online = ((Get-CampoAdo $a 'status') -eq 'online'); Abilitato = ((Get-CampoAdo $a 'enabled') -ne $false); Lavoro = $lavoro }
        }
        $out.Add([pscustomobject]@{ Pool = [string](Get-CampoAdo $p 'name'); Agenti = @($agenti) })
    }
    @($out)
}

# Il tipo di un run: rilascio (orchestrator o pipeline di deploy/release), PR (validazione), CI (build), pianificato, manuale.
function Get-TipoRun([string]$Nome, [string]$Motivo, [bool]$Orchestratore) {
    if ($Orchestratore) { return 'rilascio' }
    if ($Motivo -eq 'pullRequest') { return 'pr' }
    if ($Nome -match '(?i)release|deploy|rilascio') { return 'rilascio' }
    if ($Motivo -eq 'pullRequest' -or $Nome -match '(?i)pr-validation|\bpr\b') { return 'pr' }
    if ($Motivo -in 'individualCI', 'batchedCI' -or $Nome -match '(?i)build-ci|\bci\b') { return 'ci' }
    if ($Motivo -eq 'schedule') { return 'pianificato' }
    if ($Motivo -eq 'manual') { return 'manuale' }
    'altro'
}

# I run di build/pipeline di TUTTI i progetti: quelli in corso, in coda o in attesa di approvazione e i falliti o annullati
# nelle ultime $Ore ore. Un progetto che non risponde non ferma gli altri: finisce in Errori. Solo GET.
# Stato di ogni run attivo: inCorso | inCoda | inAttesa (approvazione). La timeline si legge solo per i run in corso.
function Get-AdoBuildPipeline {
    [CmdletBinding()]
    param([int]$Ore = 24, [datetime]$Adesso = (Get-Date), [int]$UltimiOrchestratore = 5)
    $org = $script:Org
    $da = [uri]::EscapeDataString($Adesso.ToUniversalTime().AddHours(-$Ore).ToString('o'))
    $progetti = @((Invoke-Ado -Metodo Get -Url ($org + '/_apis/projects?$top=500&api-version=7.1')).value | ForEach-Object { [string]$_.name })
    $attivi = [System.Collections.Generic.List[object]]::new(); $falliti = [System.Collections.Generic.List[object]]::new()
    $errori = [System.Collections.Generic.List[string]]::new(); $orch = [System.Collections.Generic.List[object]]::new()
    $nuovo = {
        param($b, $p, $stato, $fase, $lavoratori = @(), [bool]$orchestratore = $false, [string]$attende = '')
        $rif = Get-CampoAdo $b 'sourceBranch'
        $def = Get-CampoAdo $b 'definition'; $chi = Get-CampoAdo $b 'requestedFor'
        # i componenti rilasciati dall'orchestratore: i parametri deploy* a true
        $tp = Get-CampoAdo $b 'templateParameters'
        $comp = @(if ($tp) { $tp.PSObject.Properties | Where-Object { $_.Name -like 'deploy*' -and "$($_.Value)" -eq 'true' } | ForEach-Object { $_.Name } })
        # dove gira: dagli agenti dei job (solo per i run di cui si legge la timeline); gli altri li completa l'agente abituale
        $ag = Get-AgenteDaLavoratori @($lavoratori)
        $inizio = if ($stato -eq 'inCoda') { Get-CampoAdo $b 'queueTime' } else { Get-CampoAdo $b 'startTime' }
        if (-not $inizio) { $inizio = Get-CampoAdo $b 'queueTime' }
        [pscustomobject]@{
            Id = [int]$b.id; Progetto = $p; Pipeline = [string](Get-CampoAdo $def 'name'); Ramo = ([string]$rif -replace '^refs/heads/', '' -replace '^refs/pull/(\d+)/merge$', 'PR #$1')
            Autore = [string](Get-CampoAdo $chi 'displayName'); Stato = $stato; Fase = $fase
            Inizio = (ConvertTo-DataUtc $inizio); Fine = (ConvertTo-DataUtc (Get-CampoAdo $b 'finishTime'))
            Esito = [string](Get-CampoAdo $b 'result'); Componenti = $comp; Pool = $ag.Nome; Agente = $ag.Agente; AgenteStimato = $false; Attende = $attende
            SourceVersion = [string](Get-CampoAdo $b 'sourceVersion'); ParametriTemplate = $tp
            Numero = [string](Get-CampoAdo $b 'buildNumber'); DefinizioneId = [int](Get-CampoAdo $def 'id')
            Tipo = (Get-TipoRun ([string](Get-CampoAdo $def 'name')) ([string](Get-CampoAdo $b 'reason')) $orchestratore); Url = (Get-AdoUrlBuild -Progetto $p -Id ([int]$b.id))
        }
    }
    foreach ($p in $progetti) {
        $base = "$org/$([uri]::EscapeDataString($p))/_apis/build/builds"
        try {
            $vivi = @((Invoke-Ado -Metodo Get -Url ($base + '?statusFilter=inProgress,notStarted,postponed&$top=100&api-version=7.1')).value)
            $chiusi = @((Invoke-Ado -Metodo Get -Url ($base + "?statusFilter=completed&resultFilter=failed,canceled&minTime=$da" + '&$top=100&api-version=7.1')).value)
        }
        catch { $errori.Add("${p}: $($_.Exception.Message)"); continue }
        # i release-orchestrator (cercati per nome, in ogni progetto) hanno il loro blocco: gli ultimi run, in corso o conclusi
        $idOrch = @()
        try { $idOrch = @((Invoke-Ado -Metodo Get -Url ($base -replace '/builds$', '/definitions?name=*orchestrator*&api-version=7.1')).value | Where-Object { $_.name -match 'orchestrator' } | ForEach-Object { [int]$_.id }) } catch { }
        if ($idOrch.Count -gt 0) {
            try {
                $ob = @((Invoke-Ado -Metodo Get -Url ($base + "?definitions=$($idOrch -join ',')&queryOrder=queueTimeDescending" + '&$top=' + $UltimiOrchestratore + '&api-version=7.1')).value)
                $ids = @($ob | ForEach-Object { [int]$_.id })
                $vivi = @($vivi | Where-Object { [int]$_.id -notin $ids }); $chiusi = @($chiusi | Where-Object { [int]$_.id -notin $ids })
                foreach ($b in $ob) {
                    $st = Get-CampoAdo $b 'status'
                    if ($st -eq 'completed') { $orch.Add((& $nuovo $b $p 'concluso' $null @() $true)); continue }
                    if ($st -ne 'inProgress') { $orch.Add((& $nuovo $b $p 'inCoda' $null @() $true)); continue }
                    $f = @{ Approvazione = $false; Fase = $null; Lavoratori = @() }
                    try { $f = Get-FaseRun @((Invoke-Ado -Metodo Get -Url "$base/$([int]$b.id)/timeline?api-version=7.1").records) } catch { }
                    $orch.Add((& $nuovo $b $p $(if ($f.Approvazione) { 'inAttesa' } elseif ($f['Attende']) { 'inCoda' } else { 'inCorso' }) $f.Fase $f.Lavoratori $true ([string]$f['Attende'])))
                }
            }
            catch { $errori.Add("${p} (orchestrator): $($_.Exception.Message)") }
        }
        foreach ($b in $vivi) {
            if ((Get-CampoAdo $b 'status') -ne 'inProgress') { $attivi.Add((& $nuovo $b $p 'inCoda' $null)); continue }
            $f = @{ Approvazione = $false; Fase = $null; Lavoratori = @() }
            try { $f = Get-FaseRun @((Invoke-Ado -Metodo Get -Url "$base/$([int]$b.id)/timeline?api-version=7.1").records) } catch { }
            $attivi.Add((& $nuovo $b $p $(if ($f.Approvazione) { 'inAttesa' } elseif ($f['Attende']) { 'inCoda' } else { 'inCorso' }) $f.Fase $f.Lavoratori $false ([string]$f['Attende'])))
        }
        foreach ($b in $chiusi) { $falliti.Add((& $nuovo $b $p 'concluso' $null)) }
    }
    # i run senza agenti letti (in coda, conclusi, o in corso ma senza job partiti): l'agente abituale della pipeline, segnato come stima
    foreach ($b in @(@($attivi) + @($orch) + @($falliti) | Where-Object { -not $_.Agente -and $_.DefinizioneId -gt 0 })) {
        $a = Get-AgenteAbituale $b.Progetto $b.DefinizioneId $Adesso
        if ($a.Agente) { $b.Agente = $a.Agente; $b.Pool = $a.Nome; $b.AgenteStimato = $true }
    }
    # la posizione in coda la dice ADO (richieste dei pool); si chiede solo se c'e qualcosa in coda
    $inCoda = @(@($attivi) + @($orch) | Where-Object Stato -eq 'inCoda')
    if ($inCoda.Count -gt 0) {
        $coda = Get-AdoCodaPool
        foreach ($b in $inCoda) {
            if (-not $coda.ContainsKey([int]$b.Id)) { continue }
            $q = $coda[[int]$b.Id]
            $b | Add-Member PosizioneCoda $q.Posizione -Force; $b | Add-Member PoolCoda $q.Pool -Force
            # il pool in cui il run aspetta e certo: vale piu dell'agente abituale stimato dall'ultimo run concluso (un orchestrator
            # fa i primi stage su agenti cloud e il deploy su quelli interni: la stima diceva cloud mentre aspettava un agente interno)
            $b.Agente = $(if ($q.Ospitato) { 'cloud' } else { 'interno' }); $b.Pool = $q.Pool; $b.AgenteStimato = $false
        }
    }
    $f24 = @($falliti | Sort-Object Fine -Descending)
    $limite = $Adesso.ToUniversalTime().AddHours(-$Ore)
    $orchOrdinati = @(@($orch | Where-Object Stato -ne 'concluso' | Sort-Object Inizio) + @($orch | Where-Object Stato -eq 'concluso' | Sort-Object Fine -Descending))
    $tutti = @($attivi) + @($orch)
    $orchFalliti = @($orch | Where-Object { $_.Esito -eq 'failed' -and $_.Fine -and $_.Fine -ge $limite }).Count
    $erroriAgenti = [System.Collections.Generic.List[string]]::new()
    $agentiPool = @(Get-AdoAgentiPool -Errori $erroriAgenti)
    [pscustomobject]@{
        AgentiLetti = ($erroriAgenti.Count -eq 0); ErroriAgenti = @($erroriAgenti)
        Attivi = @($attivi | Sort-Object Inizio); Orchestratori = $orchOrdinati; AgentiPool = $agentiPool; Falliti = $f24; Errori = @($errori); Ore = $Ore
        InCorso = @($tutti | Where-Object Stato -eq 'inCorso').Count; InCoda = @($tutti | Where-Object Stato -eq 'inCoda').Count
        InAttesa = @($tutti | Where-Object Stato -eq 'inAttesa').Count; NumFalliti = (@($f24 | Where-Object Esito -eq 'failed').Count + $orchFalliti)
    }
}

Export-ModuleMember -Function Get-AdoUltimoRunRiuscito, Test-AdoCommitContenuto, Get-SorgenteRepo, Find-RepoDaGitHub, Add-AdoLinkCard, Get-AdoMotivoFallimento, Start-AdoRilancioRun, Get-AdoUltimoRun, Get-AdoAgentiPool, Get-AdoBuildPipeline, Get-AdoLimiteTestoPr, Set-AdoTitoloPr, Get-AdoDescrizionePr, Set-AdoDescrizionePr, Start-AdoRivalutazione, Get-AdoPrCollegata, Get-AdoErroriBuild, Get-AdoCampiConsumi, Get-AdoUrlCard, New-AdoCard, Get-AdoCardAttive, Get-AdoCard, Set-AdoCard, Get-AdoStoriaStato, Get-AdoCommenti,
    Add-AdoCommento, Get-AdoPr, Get-AdoPrDelRamo, New-AdoPr, Complete-AdoPr, Start-AdoDeployTest, Get-AdoParametriDeploy, Get-AdoRamoCard, Get-AdoRun, Get-AdoUrlBuild, Get-AdoUrlPr, Get-AdoUtenteCorrente, Get-AdoUrlOrganizzazione,
    New-AdoTask, Get-AdoTaskFigli, Get-AdoCardPredecessori, Set-AdoTaskStato, Get-AdoFeature, Get-AdoFigliFeature, Set-AdoStatoFeature, Get-AdoFeatureAperte, Set-AdoRank
