Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Impostazioni.psm1') -Global

function Get-RadiceAttrezzi {
    Split-Path -Parent $PSScriptRoot
}

function Get-Config {
    [CmdletBinding()]
    # D53: limiti.json si legge con gli override di impostazioni.json (cartella dati); gli script passano la loro cartella dati.
    param([string]$Radice = (Get-RadiceAttrezzi), [string]$CartellaDati = (Get-CartellaDati))

    $imp = Get-Impostazioni $CartellaDati
    $leggi = {
        param($nome)
        $p = Join-Path $Radice "config/$nome.json"
        if (-not (Test-Path -LiteralPath $p)) { throw "File di configurazione mancante: $p" }
        Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $stati  = & $leggi 'stati'
    $ruoli  = & $leggi 'ruoli'
    $limiti = Read-ConfigConOverride -Radice $Radice -Nome 'limiti' -CartellaDati $CartellaDati -Impostazioni $imp
    $chiaviOverride = @($imp.Limiti.PSObject.Properties | ForEach-Object Name)
    $mappa  = & $leggi 'mappa'

    if (-not $mappa.PSObject.Properties['progettoBoard'] -or [string]::IsNullOrWhiteSpace($mappa.progettoBoard)) {
        throw "mappa.json: manca 'progettoBoard' (il progetto della board)"
    }

    # Un valore che viene da impostazioni.json e invalido: l'errore lo dice, perche il file di config del repo e a posto.
    try {
        # D51: la riserva settimanale e il margine dopo il reset della quota. Senza, la pausa per il limite non si calcola.
        # D60: la soglia sulla finestra di 5 ore, come la settimanale ma fino al reset della finestra.
        foreach ($n in 'sogliaQuotaSettimanale', 'sogliaQuota5Ore', 'margineQuotaMinuti') {
            if (-not $limiti.PSObject.Properties[$n] -or $limiti.$n -isnot [ValueType]) { throw "limiti.json: manca '$n' o non e un numero" }
        }
        if ($limiti.sogliaQuotaSettimanale -le 0 -or $limiti.sogliaQuotaSettimanale -gt 1) { throw "limiti.json: 'sogliaQuotaSettimanale' deve essere fra 0 (escluso) e 1" }
        if ($limiti.sogliaQuota5Ore -le 0 -or $limiti.sogliaQuota5Ore -gt 1) { throw "limiti.json: 'sogliaQuota5Ore' deve essere fra 0 (escluso) e 1" }
        if ($limiti.margineQuotaMinuti -lt 0) { throw "limiti.json: 'margineQuotaMinuti' non puo essere negativo" }

        # D59: quanti ambienti di collaudo Docker possono esistere insieme
        if (-not $limiti.PSObject.Properties['ambientiCollaudo'] -or $limiti.ambientiCollaudo -isnot [ValueType] -or $limiti.ambientiCollaudo -lt 1) { throw "limiti.json: manca 'ambientiCollaudo' o non e un numero di almeno 1" }

        # D52: l'interruttore delle funzionalita. Spento, `card crea -Tipo Feature` e `-Feature` si rifiutano.
        if (-not $limiti.PSObject.Properties['funzionalitaAttive'] -or $limiti.funzionalitaAttive -isnot [bool]) { throw "limiti.json: manca 'funzionalitaAttive' o non e vero/falso" }
    }
    catch {
        if ($chiaviOverride.Count -gt 0) { throw "$($_.Exception.Message) (override in impostazioni.json: $($chiaviOverride -join ', '))" }
        throw
    }

    # D59: come si raggiunge docker e dove stanno gli ambienti di collaudo
    $collaudo = & $leggi 'collaudo'
    if (@($collaudo.comandoDocker | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { throw "collaudo.json: 'comandoDocker' manca o e vuoto" }
    if ([string]::IsNullOrWhiteSpace([string]$collaudo.host)) { throw "collaudo.json: manca 'host'" }
    foreach ($n in 'portaBase', 'minutiCreazione', 'minutiComandi') {
        if (-not $collaudo.PSObject.Properties[$n] -or $collaudo.$n -isnot [ValueType] -or $collaudo.$n -le 0) { throw "collaudo.json: manca '$n' o non e un numero positivo" }
    }

    # D52: gli stati della Feature (il processo li ha diversi dalle card): chi scrive o legge lo stato di una Feature li prende da qui.
    foreach ($n in 'featureNuova', 'featureAttiva', 'featureRisolta', 'featureChiusa', 'featureRimossa') {
        if (-not $stati.PSObject.Properties[$n] -or [string]::IsNullOrWhiteSpace($stati.$n)) { throw "stati.json: manca '$n' (uno stato della Feature)" }
    }

    $chiaviStati = @($stati.PSObject.Properties.Name)
    foreach ($r in $ruoli.PSObject.Properties) {
        foreach ($t in @($r.Value.transizioni)) {
            foreach ($chiave in @($t)) {
                if ($chiave -notin $chiaviStati) {
                    throw "Ruolo '$($r.Name)': la transizione usa la chiave '$chiave', assente da stati.json"
                }
            }
        }
        $brief = Join-Path $Radice $r.Value.brief
        if (-not (Test-Path -LiteralPath $brief)) {
            throw "Ruolo '$($r.Name)': il brief '$($r.Value.brief)' non esiste"
        }
    }

    # La sorgente del codice di un'area (e del repo degli attrezzi): Azure Repos se manca, GitHub con il suo owner/repo.
    $vociRepo = @(@($mappa.aree) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Nome = "l'area '$($_.area)'"; Voce = $_ } })
    if ($mappa.PSObject.Properties['attrezzi'] -and $mappa.attrezzi) { $vociRepo += [pscustomobject]@{ Nome = "la voce 'attrezzi'"; Voce = $mappa.attrezzi } }
    foreach ($v in $vociRepo) {
        $sorgente = if ($v.Voce.PSObject.Properties['sorgente']) { [string]$v.Voce.sorgente } else { 'ado' }
        if ($sorgente -notin 'ado', 'github') { throw "mappa.json: $($v.Nome) ha sorgente '$sorgente': valori ammessi ado o github" }
        if ($sorgente -eq 'github' -and -not ($v.Voce.PSObject.Properties['repoGithub'] -and [string]$v.Voce.repoGithub -match '^[\w.-]+/[\w.-]+$')) {
            throw "mappa.json: $($v.Nome) ha sorgente github ma 'repoGithub' manca o non e nella forma <owner>/<repo>"
        }
    }

    [pscustomobject]@{ Stati = $stati; Ruoli = $ruoli; Limiti = $limiti; Mappa = $mappa; Collaudo = $collaudo }
}

# La riga della mappa per un'area, dalla mappa gia letta; null se l'area non c'e.
function Find-VoceMappa {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mappa, [Parameter(Mandatory)][string]$Area)
    @($Mappa.aree | Where-Object { $_.area -eq $Area }) | Select-Object -First 1
}

# Come Find-VoceMappa ma con errore se l'area non c'e. Senza -Mappa legge config/mappa.json.
function Get-VoceMappa {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Area,
        $Mappa,
        [string]$Radice = (Get-RadiceAttrezzi)
    )
    if (-not $Mappa) { $Mappa = Get-Content -LiteralPath (Join-Path $Radice 'config/mappa.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
    $voce = Find-VoceMappa -Mappa $Mappa -Area $Area
    if (-not $voce) { throw "Area sconosciuta nella mappa: '$Area'" }
    $voce
}

# Un ruolo e in sola lettura quando fra i suoi strumenti (ruoli.json, gli stessi che Sessioni passa a --tools) non ce
# n'e uno che scrive file. Chi vuole sapere se un ruolo puo modificare il worktree lo chiede qui.
$script:StrumentiCheScrivono = @('Write', 'Edit')
function Test-RuoloSolaLettura {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$RuoloConfig)
    @(@($RuoloConfig.strumenti) | Where-Object { $_ -in $script:StrumentiCheScrivono }).Count -eq 0
}

Export-ModuleMember -Function Get-Config, Get-VoceMappa, Find-VoceMappa, Test-RuoloSolaLettura