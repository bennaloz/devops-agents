Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Stato.psm1') -Global

# D53: le impostazioni locali di chi usa la suite, fuori dal repo: impostazioni.json nella cartella dati (Get-CartellaDati, che
# rispetta ATTREZZI_DATI). Cosi la copia della suite resta pulita e si aggiorna in fast-forward. Contiene:
#   canale                    main o develop: da quale ramo la suite si aggiorna (assente: lo decide Get-CanaleAggiornamento)
#   aggiornamentoAutomatico   vero/falso, predefinito vero
#   pausaSistema              vero/falso, predefinito falso (D60): lo smistatore chiude le sessioni finite ma non lancia e non sposta niente
#   limiti, supervisore       override delle chiavi di primo livello di config/limiti.json e config/supervisore.json
# Qui solo lettura, scrittura e applicazione degli override: le regole di validazione restano a chi legge il file di config
# (Get-Config, Get-ConfigSupervisore), che le applica al valore finale, override compresi.

$script:CanaliAmmessi = @('main', 'develop')
$script:SezioniOverride = @('limiti', 'supervisore')

function Get-PercorsoImpostazioni([string]$CartellaDati = (Get-CartellaDati)) {
    Join-Path $CartellaDati 'impostazioni.json'
}

function Get-CanaliAmmessi { $script:CanaliAmmessi }

# Il file com'e, come oggetto (vuoto se non c'e). Un file che non e un oggetto JSON e un errore chiaro.
function Read-ImpostazioniGrezze([string]$CartellaDati = (Get-CartellaDati)) {
    $p = Get-PercorsoImpostazioni $CartellaDati
    if (-not (Test-Path -LiteralPath $p)) { return [pscustomobject]@{} }
    $testo = [IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false))
    if ([string]::IsNullOrWhiteSpace($testo)) { return [pscustomobject]@{} }
    try { $o = $testo | ConvertFrom-Json } catch { throw "impostazioni.json non e un JSON valido ($p): $($_.Exception.Message)" }
    if ($o -isnot [pscustomobject]) { throw "impostazioni.json non e un oggetto JSON ($p)" }
    $o
}

# Le impostazioni validate, con i predefiniti: Canale ($null se non impostato), Automatico (vero se non impostato), Limiti e Supervisore
# (gli override, oggetti anche vuoti).
function Get-Impostazioni([string]$CartellaDati = (Get-CartellaDati)) {
    $o = Read-ImpostazioniGrezze $CartellaDati
    $canale = Get-Campo $o 'canale'
    if ($null -ne $canale -and "$canale" -notin $script:CanaliAmmessi) { throw "impostazioni.json: 'canale' deve essere $($script:CanaliAmmessi -join ' o '), non '$canale'" }
    $auto = Get-Campo $o 'aggiornamentoAutomatico'
    if ($null -ne $auto -and $auto -isnot [bool]) { throw "impostazioni.json: 'aggiornamentoAutomatico' deve essere vero o falso" }
    $pausa = Get-Campo $o 'pausaSistema'
    if ($null -ne $pausa -and $pausa -isnot [bool]) { throw "impostazioni.json: 'pausaSistema' deve essere vero o falso" }
    $sezioni = @{}
    foreach ($n in $script:SezioniOverride) {
        $v = Get-Campo $o $n
        if ($null -ne $v -and $v -isnot [pscustomobject]) { throw "impostazioni.json: '$n' deve essere un oggetto con le chiavi da cambiare" }
        $sezioni[$n] = if ($null -ne $v) { $v } else { [pscustomobject]@{} }
    }
    [pscustomobject]@{
        Canale = $(if ($null -ne $canale) { [string]$canale } else { $null })
        Automatico = $(if ($null -ne $auto) { [bool]$auto } else { $true })
        Pausa = [bool]$pausa
        Limiti = $sezioni['limiti']; Supervisore = $sezioni['supervisore']
    }
}

# Scrive il file per sostituzione atomica (come gli altri file dati).
function Save-ImpostazioniGrezze($Oggetto, [string]$CartellaDati = (Get-CartellaDati)) {
    Save-Stato -Stato $Oggetto -Percorso (Get-PercorsoImpostazioni $CartellaDati)
}

# Lettura, modifica e scrittura di impostazioni.json sono un passo solo: la vista (l'interruttore) e il supervisore (la migrazione) lo scrivono da
# processi diversi, e senza un blocco l'ultimo che scrive cancellerebbe la modifica dell'altro. Il blocco e un mutex con il nome derivato dal
# percorso del file (come Get-NomeGiro per il giro dello smistatore).
function Invoke-ConBloccoImpostazioni([string]$CartellaDati, [scriptblock]$Azione) {
    $chiave = [IO.Path]::GetFullPath((Get-PercorsoImpostazioni $CartellaDati)).Replace('\', '/').ToLowerInvariant()
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($chiave))
    $m = [Threading.Mutex]::new($false, 'Global\DevOps.Agents.Impostazioni-' + [Convert]::ToHexString($hash).Substring(0, 16).ToLowerInvariant())
    $preso = $false
    try {
        try { $preso = $m.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $preso = $true }
        if (-not $preso) { throw 'impostazioni.json e bloccato da un altro processo da oltre 15 secondi' }
        & $Azione
    }
    finally { if ($preso) { $m.ReleaseMutex() }; $m.Dispose() }
}

# Cambia una chiave di primo livello (canale, aggiornamentoAutomatico) e lascia il resto com'e.
function Set-Impostazione([Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)]$Valore, [string]$CartellaDati = (Get-CartellaDati)) {
    Invoke-ConBloccoImpostazioni $CartellaDati {
        $o = Read-ImpostazioniGrezze $CartellaDati
        Add-Member -InputObject $o -NotePropertyName $Nome -NotePropertyValue $Valore -Force
        Save-ImpostazioniGrezze $o $CartellaDati
    }
}

# Aggiunge override a una sezione (limiti o supervisore) senza sovrascrivere uno gia presente: chi lo ha scelto a mano vince.
# $Valori e un hashtable chiave -> valore. Ritorna le chiavi davvero aggiunte.
function Add-OverrideNuovi([Parameter(Mandatory)][ValidateSet('limiti', 'supervisore')][string]$Sezione, [Parameter(Mandatory)][hashtable]$Valori, [string]$CartellaDati = (Get-CartellaDati)) {
    Invoke-ConBloccoImpostazioni $CartellaDati {
        $o = Read-ImpostazioniGrezze $CartellaDati
        $s = Get-Campo $o $Sezione
        if ($null -eq $s) { $s = [pscustomobject]@{}; Add-Member -InputObject $o -NotePropertyName $Sezione -NotePropertyValue $s }
        $aggiunte = @()
        foreach ($k in $Valori.Keys) {
            if ($s.PSObject.Properties[$k]) { continue }
            Add-Member -InputObject $s -NotePropertyName $k -NotePropertyValue $Valori[$k]
            $aggiunte += $k
        }
        if ($aggiunte.Count -gt 0) { Save-ImpostazioniGrezze $o $CartellaDati }
        $aggiunte
    }
}

# Applica gli override di una sezione a un file di config letto: le chiavi di primo livello si sostituiscono. Una chiave che il file non ha
# e un errore (un refuso non deve passare per una chiave valida).
function Merge-OverrideConfig([Parameter(Mandatory)]$Base, [Parameter(Mandatory)]$Override, [Parameter(Mandatory)][string]$Nome) {
    foreach ($p in @($Override.PSObject.Properties)) {
        if (-not $Base.PSObject.Properties[$p.Name]) { throw "impostazioni.json: '$Nome.$($p.Name)' non esiste in config/$Nome.json" }
        Add-Member -InputObject $Base -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
    }
    $Base
}

# Un file di config con gli override di impostazioni.json applicati, senza validarlo (la validazione e di chi lo usa).
# $Nome: limiti o supervisore. Con $Impostazioni gia lette non rilegge il file.
function Read-ConfigConOverride([Parameter(Mandatory)][string]$Radice, [Parameter(Mandatory)][ValidateSet('limiti', 'supervisore')][string]$Nome, [string]$CartellaDati = (Get-CartellaDati), $Impostazioni = $null) {
    $p = Join-Path $Radice "config/$Nome.json"
    if (-not (Test-Path -LiteralPath $p)) { throw "File di configurazione mancante: $p" }
    $c = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $Impostazioni) { $Impostazioni = Get-Impostazioni $CartellaDati }
    $ov = if ($Nome -eq 'limiti') { $Impostazioni.Limiti } else { $Impostazioni.Supervisore }
    Merge-OverrideConfig $c $ov $Nome | Out-Null
    $c
}

# Due valori letti da JSON sono lo stesso valore? I numeri si confrontano come numeri (1 e 1.0 sono uguali), il resto sul JSON compatto.
function Test-ValoreUguale($A, $B) {
    if ($A -is [ValueType] -and $A -isnot [bool] -and $B -is [ValueType] -and $B -isnot [bool]) { return [double]$A -eq [double]$B }
    ($A | ConvertTo-Json -Compress -Depth 10) -eq ($B | ConvertTo-Json -Compress -Depth 10)
}

# Le chiavi di primo livello di un file di config che differiscono dalla versione di riferimento (HEAD): chiave -> valore attuale.
function Get-ChiaviDiverse([Parameter(Mandatory)]$Attuale, [Parameter(Mandatory)]$Riferimento) {
    $r = [ordered]@{}
    foreach ($p in @($Attuale.PSObject.Properties)) {
        $rif = $Riferimento.PSObject.Properties[$p.Name]
        if (-not ($rif -and (Test-ValoreUguale $p.Value $rif.Value))) { $r[$p.Name] = $p.Value }
    }
    $r
}

Export-ModuleMember -Function Get-PercorsoImpostazioni, Get-CanaliAmmessi, Read-ImpostazioniGrezze, Get-Impostazioni, Set-Impostazione, Add-OverrideNuovi, Merge-OverrideConfig, Read-ConfigConOverride, Get-ChiaviDiverse
