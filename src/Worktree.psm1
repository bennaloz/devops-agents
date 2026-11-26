Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global

# Il worktree di una card: una cartella isolata, creata sempre da origin/develop con git -C sulla copia principale del
# repo (la cartella della voce di config/mappa.json), che non si tocca mai. Nessuna scrittura su Azure DevOps.

$script:RadiceWorktree = 'C:\develop\GIT\_wt'
$script:ParoleSlug = 5

function Invoke-Git([string]$Cartella, [string[]]$Argomenti, [switch]$ConsentiErrore) {
    # stderr di git e informazione, non un errore PowerShell: la decisione la prende il codice di uscita.
    $ErrorActionPreference = 'Continue'
    # Nessun prompt di credenziali: un giro non scritto per aspettare una persona resterebbe appeso e fermerebbe tutte
    # le card. Senza credenziali git fallisce e la card va in on-hold.
    $prima = @{}
    foreach ($nome in 'GIT_TERMINAL_PROMPT', 'GCM_INTERACTIVE') { $prima[$nome] = [Environment]::GetEnvironmentVariable($nome) }
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'never'
    try {
        $out = & git -C $Cartella @Argomenti 2>&1
        $codice = $LASTEXITCODE
    }
    finally {
        foreach ($nome in $prima.Keys) { [Environment]::SetEnvironmentVariable($nome, $prima[$nome]) }
    }
    if ($ConsentiErrore) { return [pscustomobject]@{ Codice = $codice; Uscita = (@($out) -join "`n") } }
    if ($codice -ne 0) { throw "git $($Argomenti -join ' ') in ${Cartella} e fallito: $(@($out) -join ' ')" }
    (@($out) -join "`n").Trim()
}

# Le prime cinque parole del titolo, minuscole, senza accenti, unite da trattini.
function ConvertTo-SlugTitolo([string]$Titolo) {
    $senzaAccenti = (-join ($Titolo.Normalize([Text.NormalizationForm]::FormD).ToCharArray() |
            Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })).ToLowerInvariant()
    $parole = @($senzaAccenti -split '[^a-z0-9]+' | Where-Object { $_ })
    (@($parole | Select-Object -First $script:ParoleSlug)) -join '-'
}

function Get-RamoCard($Card) {
    $prefisso = if ("$($Card.Tipo)" -eq 'Bug') { 'fix' } else { 'feature' }
    $slug = ConvertTo-SlugTitolo "$($Card.Titolo)"
    if ($slug) { "$prefisso/$($Card.Id)-$slug" } else { "$prefisso/$($Card.Id)" }
}

# Il ramo della funzionalita (D52): feature/f<id Feature>-<slug>, o bugfix/f<id>-<slug> se la Feature ha il tag bug (il nome del tag
# lo da chi chiama, da stati.json). Prefissi e forma f<id> stanno in Comune. Il prefisso e il titolo possono cambiare dopo la
# creazione: la ricerca e per id.
function Get-NomeRamoFunzionalita($Feature, [Parameter(Mandatory)][string]$TagBug) {
    $prefisso = Get-PrefissoRamoFunzionalita -Correzione:(@($Feature.Tag) -contains $TagBug)
    $sigla = Get-SiglaFunzionalita ([int]$Feature.Id)
    $slug = ConvertTo-SlugTitolo "$($Feature.Titolo)"
    if ($slug) { "$prefisso/$sigla-$slug" } else { "$prefisso/$sigla" }
}

# Il ramo della funzionalita pubblicato su origin, trovato per id come New-WorktreeDaRemoto cerca il ramo di una card, dopo un fetch;
# null se non c'e. Piu di uno: errore, quale valga lo decide una persona. Serve a Publish-RamoFunzionalita, che deve sapere com'e
# origin adesso: per leggerlo in un giro senza toccare la copia principale c'e Get-AdoRamoCard -FeatureId (REST).
function Find-RamoFunzionalita {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Principale, [Parameter(Mandatory)][int]$IdFeature)
    Invoke-Git $Principale 'fetch', '--prune', 'origin' | Out-Null
    $cartelle = @(Get-PrefissiRamoFunzionalita | ForEach-Object { "refs/remotes/origin/$_/" })
    $remoti = @((Invoke-Git $Principale (@('for-each-ref', '--format=%(refname:short)') + $cartelle)) -split "`n" |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -match (Get-RegexRamoFunzionalita $IdFeature -Radice 'origin/') })
    if ($remoti.Count -gt 1) { throw "Su origin c'e piu di un ramo della funzionalita ${IdFeature}: $($remoti -join ', '). Quale continuare lo decide una persona" }
    if ($remoti.Count -eq 1) { return $remoti[0].Substring('origin/'.Length) }
    $null
}

# Il ramo della funzionalita su origin: se Find- non lo trova lo crea da origin/develop e lo pubblica, senza ramo locale (la
# copia principale non si tocca). Un push rifiutato perche il ramo esiste gia (un altro smistatore e arrivato prima) non e un
# errore: fetch e si usa quello. Se anche dopo il fetch il ramo non c'e, il rifiuto e un errore vero. Restituisce il nome del ramo.
function Publish-RamoFunzionalita {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Principale, [Parameter(Mandatory)]$Feature, [Parameter(Mandatory)][string]$TagBug)
    $trovato = Find-RamoFunzionalita -Principale $Principale -IdFeature ([int]$Feature.Id)
    if ($trovato) { return $trovato }
    $ramo = Get-NomeRamoFunzionalita $Feature -TagBug $TagBug
    $push = Invoke-Git $Principale 'push', 'origin', "refs/remotes/origin/develop:refs/heads/$ramo" -ConsentiErrore
    if ($push.Codice -eq 0) { return $ramo }
    $trovato = Find-RamoFunzionalita -Principale $Principale -IdFeature ([int]$Feature.Id)
    if ($trovato) { return $trovato }
    throw "git push del ramo $ramo della funzionalita $($Feature.Id) rifiutato: $($push.Uscita)"
}

# Con -Base (D52, il ramo della funzionalita) il ramo della card nasce con -B da origin/<base>, o da origin/<ramo della card> se e gia
# pubblicato (mai da un ramo locale). Un ramo locale rimasto da un tentativo di prima si riporta li solo se un ref remoto lo contiene:
# con commit non pubblicati ci si ferma. Senza base nasce da origin/develop.
function New-WorktreeCard {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Voce, [Parameter(Mandatory)]$Card, [string]$RadiceWorktree = $script:RadiceWorktree, [string]$Base)

    $cartella = Join-Path (Join-Path $RadiceWorktree ([string]$Voce.repo)) "card-$($Card.Id)"
    if (Test-Path -LiteralPath $cartella) {
        # gia creato: si restituisce quello che c'e, con il ramo che ha davvero
        return [pscustomobject]@{ Cartella = $cartella; Ramo = (Invoke-Git $cartella 'branch', '--show-current') }
    }
    $ramo = Get-RamoCard $Card
    $principale = [string]$Voce.cartella
    # Con la base si pota (--prune): il ramo della card gia unito e cancellato da Azure DevOps resterebbe come ref remoto vecchio, e il
    # worktree ripartirebbe da lui invece che dalla base. Senza base resta com'e.
    Invoke-Git $principale $(if ($Base) { 'fetch', '--prune', 'origin' } else { 'fetch', 'origin' }) | Out-Null
    if ($Base) {
        # Come New-WorktreeDaRemoto: un ramo locale della card con commit che nessun ref remoto contiene e lavoro non pubblicato, e -B
        # lo butterebbe via. Si riparte dal ramo della card su origin se c'e (il lavoro gia fatto), altrimenti dalla base.
        if ((Invoke-Git $principale 'rev-parse', '--verify', '--quiet', "refs/heads/$ramo" -ConsentiErrore).Codice -eq 0) {
            $punta = Invoke-Git $principale 'rev-parse', "refs/heads/$ramo"
            if (-not (Invoke-Git $principale 'for-each-ref', '--contains', $punta, 'refs/remotes/')) {
                throw "Il ramo locale $ramo ha commit non pubblicati (nessun ramo remoto li contiene): non lo riporto alla base $Base"
            }
        }
        $dalRemoto = (Invoke-Git $principale 'rev-parse', '--verify', '--quiet', "refs/remotes/origin/$ramo" -ConsentiErrore).Codice -eq 0
        $partenza = if ($dalRemoto) { "origin/$ramo" } else { "origin/$Base" }
        Invoke-Git $principale 'worktree', 'add', '--no-track', '-B', $ramo, $cartella, $partenza | Out-Null
        return [pscustomobject]@{ Cartella = $cartella; Ramo = $ramo }
    }
    $esiste = (Invoke-Git $principale 'rev-parse', '--verify', '--quiet', "refs/heads/$ramo" -ConsentiErrore).Codice -eq 0
    if ($esiste) { Invoke-Git $principale 'worktree', 'add', $cartella, $ramo | Out-Null }
    else { Invoke-Git $principale 'worktree', 'add', '--no-track', '-b', $ramo, $cartella, 'origin/develop' | Out-Null }
    [pscustomobject]@{ Cartella = $cartella; Ramo = $ramo }
}

# Il worktree di una card presa in carico da un altro PC: il lavoro e sul ramo della card pubblicato su origin, che si
# trova per id (feature/<id>-... o fix/<id>-...), non per titolo, che nel frattempo puo essere cambiato. Un ramo locale
# con lo stesso nome si porta al remoto solo se non ha commit non pubblicati: altrimenti ci si ferma.
function New-WorktreeDaRemoto {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Voce, [Parameter(Mandatory)]$Card, [string]$RadiceWorktree = $script:RadiceWorktree)

    $cartella = Join-Path (Join-Path $RadiceWorktree ([string]$Voce.repo)) "card-$($Card.Id)"
    $id = [int]$Card.Id
    if (Test-Path -LiteralPath $cartella) {
        # gia creato: va bene solo se e sul ramo di questa card
        $ramoAttuale = Invoke-Git $cartella 'branch', '--show-current'
        if ($ramoAttuale -notmatch "^(feature|fix)/$id(-.*)?$") { throw "La cartella $cartella e sul ramo '$ramoAttuale', che non e della card ${id}: non la uso" }
        return [pscustomobject]@{ Cartella = $cartella; Ramo = $ramoAttuale }
    }
    $principale = [string]$Voce.cartella
    Invoke-Git $principale 'fetch', '--prune', 'origin' | Out-Null
    $remoti = @((Invoke-Git $principale 'for-each-ref', '--format=%(refname:short)', 'refs/remotes/origin/feature/', 'refs/remotes/origin/fix/') -split "`n" |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -match "^origin/(feature|fix)/$id(-.*)?$" })
    # nessun ramo pubblicato: non c'e lavoro da riprendere, decide chi chiama (ripartire da develop, o la PR e gia unita)
    if ($remoti.Count -eq 0) { return $null }
    if ($remoti.Count -gt 1) { throw "Su origin c'e piu di un ramo della card ${id}: $($remoti -join ', '). Quale continuare lo decide una persona" }
    $remoto = $remoti[0]
    $ramo = $remoto.Substring('origin/'.Length)
    $locale = (Invoke-Git $principale 'rev-parse', '--verify', '--quiet', "refs/heads/$ramo" -ConsentiErrore).Codice -eq 0
    if ($locale -and (Invoke-Git $principale 'merge-base', '--is-ancestor', "refs/heads/$ramo", $remoto -ConsentiErrore).Codice -ne 0) {
        throw "Il ramo locale $ramo ha commit non pubblicati che $remoto non contiene: non lo sovrascrivo"
    }
    Invoke-Git $principale 'worktree', 'add', '-B', $ramo, $cartella, $remoto | Out-Null
    [pscustomobject]@{ Cartella = $cartella; Ramo = $ramo }
}

# Il worktree della card di chiusura (D52): in sola lettura, nella cartella standard delle card, detached su origin/<ramo della funzionalita>.
# Senza un ramo suo nessun commit si puo pubblicare per sbaglio. Lo crea chi lancia un ruolo che deve leggere il codice (il collaudatore)
# e a ogni lancio lo riporta a origin/<ramo> aggiornato (fetch --prune e checkout --detach --force): una sorella entrata nel ramo si
# vede, e cio che un ruolo ha toccato nei file tracciati non resta. Lo toglie Remove-WorktreeCard in Ready to release.
function Update-WorktreeChiusura {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Voce, [Parameter(Mandatory)]$Card, [Parameter(Mandatory)][string]$Ramo, [string]$RadiceWorktree = $script:RadiceWorktree)
    $cartella = Join-Path (Join-Path $RadiceWorktree ([string]$Voce.repo)) "card-$($Card.Id)"
    $principale = [string]$Voce.cartella
    Invoke-Git $principale 'fetch', '--prune', 'origin' | Out-Null
    if ((Invoke-Git $principale 'rev-parse', '--verify', '--quiet', "refs/remotes/origin/$Ramo" -ConsentiErrore).Codice -ne 0) {
        throw "Su origin non c'e il ramo $Ramo della funzionalita: il worktree della card di chiusura $($Card.Id) non si puo creare"
    }
    if (Test-Path -LiteralPath $cartella) {
        $registrato = Get-WorktreeRegistrato $principale $cartella
        if (-not $registrato) { throw "La cartella '$cartella' non e un worktree di ${principale}: non la uso per la card di chiusura" }
        if ($registrato.Ramo) { throw "Il worktree $cartella e sul ramo '$($registrato.Ramo)', non e detached: non e quello della card di chiusura, non lo uso" }
        Invoke-Git $cartella 'checkout', '--detach', '--force', "origin/$Ramo" | Out-Null
    }
    else { Invoke-Git $principale 'worktree', 'add', '--detach', $cartella, "origin/$Ramo" | Out-Null }
    [pscustomobject]@{ Cartella = $cartella; Ramo = $null }
}

function ConvertTo-PercorsoConfrontabile([string]$Percorso) {
    [IO.Path]::GetFullPath($Percorso).Replace('\', '/').TrimEnd('/').ToLowerInvariant()
}

# Il worktree collegato che git elenca con quel percorso, o $null: un clone, o una cartella qualunque, non c'e.
# Il primo blocco di `worktree list` e la copia principale, che non e mai un worktree collegato.
function Get-WorktreeRegistrato([string]$Principale, [string]$Cartella) {
    $righe = (Invoke-Git $Principale 'worktree', 'list', '--porcelain') -split "`n"
    $voci = @(); $corrente = $null
    foreach ($riga in $righe) {
        $riga = $riga.TrimEnd("`r")
        if ($riga -like 'worktree *') { $corrente = @{ Percorso = $riga.Substring(9); Ramo = $null }; $voci += , $corrente }
        elseif ($riga -like 'branch *' -and $corrente) { $corrente.Ramo = $riga.Substring(7) }
    }
    $voglio = ConvertTo-PercorsoConfrontabile $Cartella
    $trovata = @($voci | Select-Object -Skip 1 | Where-Object { (ConvertTo-PercorsoConfrontabile $_.Percorso) -eq $voglio }) | Select-Object -First 1
    if ($trovata) { [pscustomobject]$trovata }
}

# Rimuove worktree e ramo locale di una card. Si rifiuta se il worktree ha lavoro non salvato. Il ramo locale si
# cancella solo se origin/<destinazione> lo contiene (dopo un fetch; la destinazione e develop, o il ramo della funzionalita D52): git branch -d confronta col develop locale, che puo
# essere vecchio. Il ramo remoto lo cancella Azure DevOps al completamento della PR.
function Remove-WorktreeCard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Voce, [Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][string]$Ramo,
        [Parameter(Mandatory)][string]$Cartella, [string]$RadiceWorktree = $script:RadiceWorktree,
        # card ceduta a un collega: il ramo locale si toglie anche se non e in develop, purche un ramo remoto lo contenga.
        # Rimasto, al ritorno della card bloccherebbe la presa in carico se il collega ha riscritto il ramo.
        [switch]$CancellaRamoPubblicato,
        # il ramo in cui la PR della card e stata unita (D52: il ramo della funzionalita)
        [string]$Destinazione = 'develop'
    )
    # Si rimuove una cosa sola: il worktree della card, nel posto in cui lo crea New-WorktreeCard. Qualunque altra
    # cartella (un clone, il worktree di un altra card o di Titolare) e rifiutata, anche se sta sotto la radice.
    $atteso = Join-Path (Join-Path $RadiceWorktree ([string]$Voce.repo)) "card-$Id"
    if ((ConvertTo-PercorsoConfrontabile $Cartella) -ne (ConvertTo-PercorsoConfrontabile $atteso)) {
        throw "La cartella '$Cartella' non e il worktree della card ${Id}, che sta in '$atteso': non la rimuovo"
    }
    $principale = [string]$Voce.cartella
    # Il fetch prima di tutto: serve a sapere cosa e pubblicato, e --prune toglie i riferimenti ai rami che Azure
    # DevOps ha cancellato al completamento della PR (uno per card, altrimenti).
    Invoke-Git $principale 'fetch', '--prune', 'origin' | Out-Null
    $detached = $false
    if (Test-Path -LiteralPath $Cartella) {
        $registrato = Get-WorktreeRegistrato $principale $Cartella
        if (-not $registrato) {
            throw "La cartella '$Cartella' non e un worktree di ${principale} (git worktree list non la elenca): non la rimuovo"
        }
        # D52: un worktree detached e quello della card di chiusura, in sola lettura (Update-WorktreeChiusura): non ha un ramo suo ne lavoro da
        # salvare, e il ramo $Ramo e quello della funzionalita, che non e suo e non si cancella.
        $detached = -not $registrato.Ramo
        if (-not $detached -and $registrato.Ramo -ne "refs/heads/$Ramo") {
            throw "Il worktree $Cartella e sul ramo '$($registrato.Ramo)', non su '$Ramo': non lo rimuovo"
        }
        if (-not $detached) {
            if (Invoke-Git $Cartella 'status', '--porcelain') {
                throw "Il worktree $Cartella ha lavoro non salvato (git status non e vuoto): non lo rimuovo"
            }
            # Commit non pubblicati: il ramo non e contenuto in nessun ramo remoto (ne in origin/<destinazione> dopo il merge).
            $punta = Invoke-Git $principale 'rev-parse', "refs/heads/$Ramo"
            if (-not (Invoke-Git $principale 'for-each-ref', '--contains', $punta, 'refs/remotes/')) {
                throw "Il ramo $Ramo ha commit non pubblicati (nessun ramo remoto li contiene): non rimuovo il worktree $Cartella"
            }
        }
        # Stato pulito e commit pubblicati: restano al piu file ignorati (node_modules, bin, obj) che git non toglie sempre.
        [void](Invoke-Git $principale $(if ($detached) { 'worktree', 'remove', '--force', $Cartella } else { 'worktree', 'remove', $Cartella }) -ConsentiErrore)
        if (Get-WorktreeRegistrato $principale $Cartella) {
            throw "git non e riuscito a togliere il worktree $Cartella, che risulta ancora registrato: non cancello la cartella"
        }
        # Non piu registrato: quello che resta sono gli avanzi ignorati da git.
        if (Test-Path -LiteralPath $Cartella) { Remove-Item -LiteralPath $Cartella -Recurse -Force }
    }
    Invoke-Git $principale 'worktree', 'prune' | Out-Null

    $cancellato = $false
    $presente = -not $detached -and (Invoke-Git $principale 'rev-parse', '--verify', '--quiet', "refs/heads/$Ramo" -ConsentiErrore).Codice -eq 0
    $pubblicato = $presente -and $CancellaRamoPubblicato -and [bool](Invoke-Git $principale 'for-each-ref', '--contains', "refs/heads/$Ramo", 'refs/remotes/')
    if ($presente -and ($pubblicato -or (Invoke-Git $principale 'merge-base', '--is-ancestor', $Ramo, "origin/$Destinazione" -ConsentiErrore).Codice -eq 0)) {
        Invoke-Git $principale 'branch', '-D', $Ramo | Out-Null
        $cancellato = $true
    }
    [pscustomobject]@{ Cartella = $Cartella; Ramo = $Ramo; RamoCancellato = $cancellato }
}

# L'impronta di un worktree: ramo, commit di testa, elenco di git status e hash del diff dei file gia modificati. Due
# impronte uguali dicono che fra l'una e l'altra nessuno ha scritto un file tracciato o nuovo, ne fatto un commit, ne
# cambiato ramo. I file che git ignora (bin, obj, node_modules) non contano: una build o un giro di test li producono
# per mestiere. Sono solo stringhe, perche l'impronta si salva nello stato fra un giro e l'altro.
function Get-ImprontaWorktree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cartella)
    # git status va letto senza il Trim di Invoke-Git: le sue righe cominciano con uno spazio che fa parte del codice
    $stato = Invoke-Git $Cartella 'status', '--porcelain' -ConsentiErrore
    if ($stato.Codice -ne 0) { throw "git status in ${Cartella} e fallito: $($stato.Uscita)" }
    $diff = Invoke-Git $Cartella 'diff', 'HEAD'
    @{
        ramo  = Invoke-Git $Cartella 'rev-parse', '--abbrev-ref', 'HEAD'
        testa = Invoke-Git $Cartella 'rev-parse', 'HEAD'
        stato = [string]$stato.Uscita
        diff  = if ($diff) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($diff))) } else { '' }
    }
}

# Cosa e cambiato fra due impronte, una frase per differenza; nessuna se il worktree e com'era.
function Compare-ImprontaWorktree {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Prima, [Parameter(Mandatory)]$Dopo, [int]$MassimoFile = 10)
    $differenze = @()
    if ([string]$Prima['ramo'] -ne [string]$Dopo['ramo']) { $differenze += "il ramo e passato da '$($Prima['ramo'])' a '$($Dopo['ramo'])'" }
    if ([string]$Prima['testa'] -ne [string]$Dopo['testa']) {
        $corto = { param($c) $c = [string]$c; $c.Substring(0, [math]::Min(7, $c.Length)) }
        $differenze += "il commit di testa e passato da $(& $corto $Prima['testa']) a $(& $corto $Dopo['testa'])"
    }
    $righe = { param($t) @([string]$t -split "`r?`n" | Where-Object { $_.Trim() }) }
    $rPrima = & $righe $Prima['stato']; $rDopo = & $righe $Dopo['stato']
    $cambiate = @($rDopo | Where-Object { $_ -notin $rPrima }) + @($rPrima | Where-Object { $_ -notin $rDopo } | ForEach-Object { "$_ (com'era prima)" })
    if ($cambiate.Count -gt 0) {
        $elenco = (@($cambiate | Select-Object -First $MassimoFile) | ForEach-Object { $_.Trim() }) -join '; '
        $resto = $cambiate.Count - $MassimoFile
        $differenze += "git status e cambiato: $elenco$(if ($resto -gt 0) { " e altri $resto" })"
    }
    elseif ([string]$Prima['diff'] -ne [string]$Dopo['diff']) { $differenze += 'i file che erano gia modificati sono cambiati ancora' }
    $differenze
}

Export-ModuleMember -Function Invoke-Git, Get-WorktreeRegistrato, Get-NomeRamoFunzionalita, Find-RamoFunzionalita, Publish-RamoFunzionalita, New-WorktreeCard, New-WorktreeDaRemoto, Update-WorktreeChiusura, Remove-WorktreeCard, Get-ImprontaWorktree, Compare-ImprontaWorktree
