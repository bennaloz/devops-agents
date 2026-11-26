<#
.SYNOPSIS
    Controlli di una PR su questo repo: test Pester, test degli hook, analisi statica. Si ferma al primo rosso.
    Li lancia la pipeline (azure-pipelines/pr-validation.yml) e li si lancia uguali in locale:
        pwsh -NoProfile -File ci/Invoke-PrValidation.ps1
.PARAMETER Step
    Uno solo dei passi (Pester, Hooks, Analyzer); senza, li fa tutti in fila.
.PARAMETER TestPath
    Cartella o file dei test Pester (default: tests). Serve a provare un file solo senza aspettare la suite intera.
.PARAMETER ResultsPath
    Dove scrivere il risultato dei test Pester (NUnit), per la pagina Tests della pipeline.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Pester', 'Hooks', 'Analyzer')][string]$Step = 'All',
    [string]$TestPath = (Join-Path $PSScriptRoot '..\tests'),
    [string]$ResultsPath = (Join-Path $PSScriptRoot '..\TestResults\pester.xml')
)
$ErrorActionPreference = 'Stop'
# Non chiamarla $repo: i filtri dei mock nei test leggono $Repo (case-insensitive) e la troverebbero valorizzata.
$raiz = Split-Path $PSScriptRoot -Parent

# Versioni fissate: i test sono scritti per questa Pester e una PSScriptAnalyzer piu' nuova puo' accendere regole nuove.
$pesterVersion = '6.2.0'
$analyzerVersion = '1.25.0'

function Use-Module([string]$Name, [string]$Version) {
    if (-not (Get-Module -ListAvailable $Name | Where-Object Version -eq ([version]$Version))) {
        Install-Module $Name -RequiredVersion $Version -Scope CurrentUser -Force -SkipPublisherCheck -AllowPrerelease:$false
    }
    Import-Module $Name -RequiredVersion $Version -Force
}

if ($Step -in 'All', 'Pester') {
    Use-Module Pester $pesterVersion
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $TestPath
    $cfg.Run.Exit = $false
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Minimal'
    $cfg.TestResult.Enabled = $true
    $cfg.TestResult.OutputFormat = 'NUnitXml'
    $cfg.TestResult.OutputPath = $ResultsPath
    $r = Invoke-Pester -Configuration $cfg
    if ($r.Result -ne 'Passed' -or $r.FailedCount -gt 0 -or $r.FailedBlocksCount -gt 0 -or $r.FailedContainersCount -gt 0) {
        throw "Pester: $($r.FailedCount) test rossi, $($r.FailedBlocksCount) blocchi e $($r.FailedContainersCount) file non eseguiti."
    }
    Write-Host "Pester: $($r.PassedCount) test verdi."
}

if ($Step -in 'All', 'Hooks') {
    # Test-Hooks.ps1 esce con codice diverso da 0 se un caso non da' l'exit code atteso.
    & pwsh -NoProfile -File (Join-Path $raiz 'hooks\Test-Hooks.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Test-Hooks.ps1 e' uscito con codice $LASTEXITCODE." }
}

if ($Step -in 'All', 'Analyzer') {
    Use-Module PSScriptAnalyzer $analyzerVersion
    $found = Invoke-ScriptAnalyzer -Path $raiz -Recurse -Settings (Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1')
    if ($found) {
        $found | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 250 | Write-Host
        throw "PSScriptAnalyzer: $(@($found).Count) violazioni."
    }
    Write-Host 'PSScriptAnalyzer: nessuna violazione.'
}
