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
        foreach ($n in 'sogliaQuotaSettimanale', 'margineQuotaMinuti') {
            if (-not $limiti.PSObject.Properties[$n] -or $limiti.$n -isnot [ValueType]) { throw "limiti.json: manca '$n' o non e un numero" }
        }
        if ($limiti.sogliaQuotaSettimanale -le 0 -or $limiti.sogliaQuotaSettimanale -gt 1) { throw "limiti.json: 'sogliaQuotaSettimanale' deve essere fra 0 (escluso) e 1" }
        if ($limiti.margineQuotaMinuti -lt 0) { throw "limiti.json: 'margineQuotaMinuti' non puo essere negativo" }

        # D52: l'interruttore delle funzionalita. Spento, `card crea -Tipo Feature` e `-Feature` si rifiutano.
        if (-not $limiti.PSObject.Properties['funzionalitaAttive'] -or $limiti.funzionalitaAttive -isnot [bool]) { throw "limiti.json: manca 'funzionalitaAttive' o non e vero/falso" }
    }
    catch {
        if ($chiaviOverride.Count -gt 0) { throw "$($_.Exception.Message) (override in impostazioni.json: $($chiaviOverride -join ', '))" }
        throw
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

    [pscustomobject]@{ Stati = $stati; Ruoli = $ruoli; Limiti = $limiti; Mappa = $mappa }
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