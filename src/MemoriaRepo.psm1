Set-StrictMode -Version Latest

foreach ($m in 'Comune', 'Config', 'Ado', 'Worktree', 'Memoria') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") -Global }

# La memoria dei ruoli (D46) letta da git e da Azure DevOps. Lo usano memoria.ps1 (leggi e scrivi), la composizione del
# brief all'avvio di una sessione (gruppo C) e la vista (gruppo D): per questo qui sta tutto cio che dice dove sta la
# memoria e quale parte vale. Il formato dei file e in Memoria.psm1 (pure funzioni sui testi), qui non si legge un file.

# Il ramo e la PR della memoria sono uno solo: le lezioni in prova stanno tutte sul ramo, nella stessa PR verso develop.
$script:RamoMemoria = 'memoria/in-prova'
# La PR della memoria sta nel repo degli attrezzi, non in quello di un prodotto.
$script:RepoAdoMemoria = 'DevOps.Agents'
$script:CartellaMemoria = 'memoria'

function Get-RamoMemoria { $script:RamoMemoria }
function Get-RifInProva { "origin/$script:RamoMemoria" }
function Get-RepoAdoMemoria { $script:RepoAdoMemoria }
# Il repo della memoria sta nel progetto della board.
function Get-ProgettoMemoria { [string](Get-Config).Mappa.progettoBoard }

function Get-CartellaMemoria([string]$Ruolo) { if ($Ruolo) { "$script:CartellaMemoria/$Ruolo" } else { $script:CartellaMemoria } }
# Il percorso (relativo alla radice git) del file di un ruolo: <nome> e "comune" o il nome di un repo.
function Get-PercorsoMemoria([Parameter(Mandatory)][string]$Ruolo, [Parameter(Mandatory)][string]$Nome) { "$(Get-CartellaMemoria $Ruolo)/$Nome.md" }

# ---- git ----------------------------------------------------------------------------------------------------------

# Il testo di un file a un riferimento git, o $null se non c'e. L'uscita di git si decodifica in UTF-8: le lezioni hanno
# accenti, e con la tabella di caratteri della console "Perché" non si riconoscerebbe piu.
function Get-TestoGit([string]$Cartella, [string]$Ref, [string]$Percorso) {
    $prima = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $r = Invoke-Git $Cartella 'show', "${Ref}:$Percorso" -ConsentiErrore
    }
    finally { [Console]::OutputEncoding = $prima }
    if ($r.Codice -eq 0) { $r.Uscita } else { $null }
}

function Test-RifGit([string]$Cartella, [string]$Ref) {
    (Invoke-Git $Cartella 'rev-parse', '--verify', '--quiet', $Ref -ConsentiErrore).Codice -eq 0
}

# Gli id che il ruolo ha avuto in tutta la storia: develop, il ramo in prova su origin e il reflog del ramo locale (dove
# restano le lezioni di una PR abbandonata, dopo che il ramo e ripartito da develop). Un id non si riusa: la card o il
# commento che lo citano punterebbero a un'altra lezione. Restituisce le righe "### <id>" trovate, in modo che si possano
# dare a Get-ProssimoIdLezione come testo. Il reflog di git scade (30 giorni per i commit non raggiungibili): oltre,
# un id di una lezione abbandonata puo tornare, ed e il limite noto.
function Get-IntestazioniStoricheRuolo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cartella, [Parameter(Mandatory)][string]$Ruolo)
    $dir = Get-CartellaMemoria $Ruolo
    $testo = [System.Text.StringBuilder]::new()
    $refs = @('origin/develop', (Get-RifInProva)) | Where-Object { Test-RifGit $Cartella $_ }
    if ($refs) {
        [void]$testo.AppendLine((Invoke-Git $Cartella (@('log', '--format=', '-p', '--no-renames') + $refs + @('--', $dir)) -ConsentiErrore).Uscita)
    }
    $locale = "refs/heads/$script:RamoMemoria"
    if (Test-RifGit $Cartella $locale) {
        [void]$testo.AppendLine((Invoke-Git $Cartella 'log', '-g', '--format=', '-p', '--no-renames', $locale, '--', $dir -ConsentiErrore).Uscita)
    }
    $trovate = [regex]::Matches($testo.ToString(), '(?m)^[ +-](###\s+' + [regex]::Escape($Ruolo) + '-\d+)\s*$')
    @($trovate | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join "`n"
}

# ---- Azure DevOps --------------------------------------------------------------------------------------------------

# Le PR della memoria, di ogni stato. Un errore si propaga: chi legge ripiega su develop, chi scrive si ferma.
function Get-PrMemoria {
    [CmdletBinding()]
    param([string]$Progetto, [string]$RepoAdo)
    if (-not $Progetto) { $Progetto = Get-ProgettoMemoria }
    if (-not $RepoAdo) { $RepoAdo = Get-RepoAdoMemoria }
    @(Get-AdoPrDelRamo -Progetto $Progetto -Repo $RepoAdo -Ramo $script:RamoMemoria)
}

# Da dove parte una scrittura (cartella = un clone con i riferimenti aggiornati da un fetch). Restituisce
#   Base   il riferimento da cui ripartire: origin/memoria/in-prova oppure origin/develop
#   Forza  vero se il push dovra riscrivere il ramo remoto (--force-with-lease): si riparte da develop e il ramo vecchio
#          e stato unito o bocciato
#   Pr     la PR attiva del ramo, o $null (la scrittura la crea)
#   Motivo perche questa base
# Le lezioni di un ramo si buttano solo se qualcuno le ha chiuse: PR unita (la testa e in develop) o chiusa su quella
# testa. Un ramo con commit non in develop e nessuna PR che li copra (il push era riuscito e la creazione della PR no)
# riparte dal ramo, e la scrittura crea la PR. Se le PR non si leggono, lancia: meglio non scrivere che indovinare.
function Get-BaseScrittura {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cartella, [string]$Progetto, [string]$RepoAdo)
    $prs = @(Get-PrMemoria -Progetto $Progetto -RepoAdo $RepoAdo)
    $attiva = $prs | Where-Object Stato -eq 'active' | Select-Object -First 1
    $rif = Get-RifInProva
    $risultato = { param($base, $forza, $pr, $motivo) [pscustomobject]@{ Base = $base; Forza = $forza; Pr = $pr; Motivo = $motivo } }

    if (-not (Test-RifGit $Cartella $rif)) { return & $risultato 'origin/develop' $false $attiva 'il ramo in prova non c e su origin' }
    if ($attiva) { return & $risultato $rif $false $attiva 'c e una PR attiva' }
    if ((Invoke-Git $Cartella 'merge-base', '--is-ancestor', $rif, 'origin/develop' -ConsentiErrore).Codice -eq 0) {
        return & $risultato 'origin/develop' $true $null 'la testa del ramo in prova e gia in develop'
    }
    $testa = Invoke-Git $Cartella 'rev-parse', $rif
    $chiusa = $prs | Where-Object { $_.Stato -ne 'active' -and $_.CommitSorgente -eq $testa } | Select-Object -First 1
    if ($chiusa) { return & $risultato 'origin/develop' $true $null "la PR $($chiusa.Id) ($($chiusa.Stato)) ha chiuso la testa del ramo" }
    & $risultato $rif $false $null 'il ramo ha commit che nessuna PR copre: si riparte da li e la PR si crea'
}

# ---- la lettura per chi serve la memoria a una sessione --------------------------------------------------------------

# Il fetch e la lettura delle PR sono le due chiamate lente (rete) e non dipendono dal ruolo ne dal repo: si fanno al piu una
# volta ogni 4 minuti per radice nello stesso processo. Lo smistatore e un processo per giro (la cache gli vale per tutti i
# lanci del giro, uno per card), la vista e un processo lungo che rilegge ogni ruolo e ogni repo al suo ritmo. Dentro i 4
# minuti una lezione appena unita o una PR appena aperta puo non vedersi: per l'avvio di una sessione e un ritardo accettabile.
# Sono 4 e non 5 perche la vista rilegge le lezioni ogni 300 secondi: con la stessa durata un ciclo potrebbe cadere ancora
# dentro la cache e vedere i dati nuovi solo dieci minuti dopo; con meno di 300 secondi ogni ciclo trova la cache scaduta.
# Le scritture (Get-BaseScrittura) non passano di qui: decidono su Get-PrMemoria, sempre fresco.
$script:DurataLetturaRemota = [timespan]::FromMinutes(4)
$script:LettureRemote = @{}
# Il solo punto in cui si legge l'ora: i test la sostituiscono per far passare i 4 minuti.
function Get-AdessoMemoria { [datetime]::UtcNow }

# L'esito di fetch e PR per una radice: Fetch (il motivo se e fallito, o $null), PrAttiva (vero se c'e una PR attiva del ramo in
# prova) ed ErrorePr (il motivo se le PR non si sono lette). Si ricorda anche un fallimento: riprovare a ogni lettura una rete
# che non risponde allungherebbe ogni lancio. Se il fetch stesso lancia (radice inesistente) non si ricorda niente.
function Get-LetturaRemota {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Radice, [string]$Progetto, [string]$RepoAdo)
    $chiave = "$Radice|$Progetto|$RepoAdo"
    $adesso = Get-AdessoMemoria
    $nota = $script:LettureRemote[$chiave]
    if ($nota -and ($adesso - $nota.Quando) -lt $script:DurataLetturaRemota) { return $nota }
    $fetch = Invoke-Git $Radice 'fetch', '--prune', 'origin' -ConsentiErrore
    $nota = @{ Quando = $adesso; Fetch = $null; PrAttiva = $false; ErrorePr = $null }
    if ($fetch.Codice -ne 0) { $nota.Fetch = "fetch fallito, letti i riferimenti git che ci sono: $($fetch.Uscita)" }
    # le PR si leggono solo se develop c'e: senza non c'e memoria da servire e la chiamata sarebbe sprecata
    if (Test-RifGit $Radice 'origin/develop') {
        try { $nota.PrAttiva = $null -ne (Get-PrMemoria -Progetto $Progetto -RepoAdo $RepoAdo | Where-Object Stato -eq 'active' | Select-Object -First 1) }
        catch { $nota.ErrorePr = "le PR della memoria non si leggono, solo develop: $($_.Exception.Message)" }
    }
    $script:LettureRemote[$chiave] = $nota
    $nota
}

# I testi di comune.md e <repo>.md del ruolo, su develop e sul ramo in prova. Il ramo in prova si legge solo se c'e una PR
# attiva da li verso develop: una PR abbandonata vuol dire lezioni bocciate, e una lezione non confermata, in dubbio,
# non si serve. Non lancia mai: se git o Azure DevOps falliscono ripiega (solo develop, e se anche develop non si legge,
# niente memoria) e lo dice nel risultato.
#   Disponibile   falso se develop non si legge: File e vuoto
#   InProvaUsato  vero se i testi in prova sono quelli del ramo; falso e normale senza PR attiva
#   Motivi        i guasti che hanno ridotto la lettura (fetch, PR illeggibili, develop assente); vuoto se tutto e andato
#   File          Nome ('comune' o il repo), Develop, InProva (testi, $null se il file o il ramo non ci sono): si
#                 compongono con Get-LezioniConEtichetta
function Get-MemoriaDelRuolo {
    [CmdletBinding()]
    param(
        # la radice git da cui leggere (un clone con origin): la copia principale degli attrezzi
        [Parameter(Mandatory)][string]$Radice, [Parameter(Mandatory)][string]$Ruolo, [Parameter(Mandatory)][string]$Repo,
        [string]$Progetto, [string]$RepoAdo
    )
    $motivi = [System.Collections.Generic.List[string]]::new()
    $file = @()
    $disponibile = $false
    $inProva = $false
    try {
        $lettura = Get-LetturaRemota -Radice $Radice -Progetto $Progetto -RepoAdo $RepoAdo
        if ($lettura.Fetch) { $motivi.Add($lettura.Fetch) }
        if (-not (Test-RifGit $Radice 'origin/develop')) {
            $motivi.Add("origin/develop non si legge in ${Radice}: niente memoria")
        }
        else {
            $disponibile = $true
            if ($lettura.ErrorePr) { $motivi.Add($lettura.ErrorePr) }
            elseif ($lettura.PrAttiva) {
                if (Test-RifGit $Radice (Get-RifInProva)) { $inProva = $true }
                else { $motivi.Add("c'e una PR attiva ma $(Get-RifInProva) non si legge: solo develop") }
            }
            $file = @(foreach ($nome in @('comune', $Repo) | Select-Object -Unique) {
                    $p = Get-PercorsoMemoria -Ruolo $Ruolo -Nome $nome
                    [pscustomobject]@{
                        Nome    = $nome
                        Develop = Get-TestoGit $Radice 'origin/develop' $p
                        InProva = $(if ($inProva) { Get-TestoGit $Radice (Get-RifInProva) $p } else { $null })
                    }
                })
        }
    }
    catch { $motivi.Add("la memoria non si legge: $($_.Exception.Message)"); $disponibile = $false; $inProva = $false; $file = @() }
    [pscustomobject]@{ Ruolo = $Ruolo; Repo = $Repo; Disponibile = $disponibile; InProvaUsato = $inProva; Motivi = @($motivi); File = $file }
}

Export-ModuleMember -Function Get-RamoMemoria, Get-RifInProva, Get-RepoAdoMemoria, Get-ProgettoMemoria, Get-CartellaMemoria, Get-PercorsoMemoria,
    Get-TestoGit, Test-RifGit, Get-IntestazioniStoricheRuolo, Get-PrMemoria, Get-BaseScrittura, Get-MemoriaDelRuolo
