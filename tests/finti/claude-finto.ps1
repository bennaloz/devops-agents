# Finto di `claude` per i test. Non chiama nessun modello.
#   CLAUDE_FINTO_ARGV    file dove scrivere gli argomenti ricevuti e le variabili ATTREZZI_* viste (JSON)
#   CLAUDE_FINTO_EVENTI  file con gli eventi (una riga JSON per evento) da scrivere sull'uscita
#   CLAUDE_FINTO_ATTESA  millisecondi di attesa prima di uscire (per provare Stop-Sessione)
$ErrorActionPreference = 'Stop'

if ($env:CLAUDE_FINTO_ARGV) {
    [pscustomobject]@{
        args = @($args)
        card = $env:ATTREZZI_CARD
        task = $env:ATTREZZI_TASK
        base = $env:ATTREZZI_BASE
        ruolo = $env:ATTREZZI_RUOLO
        dati = $env:ATTREZZI_DATI
        adoLettura = $env:AZURE_DEVOPS_EXT_PAT
        configAz = $env:AZURE_CONFIG_DIR
        estensioniAz = $env:AZURE_EXTENSION_DIR
        configAzFile = $(if ($env:AZURE_CONFIG_DIR -and (Test-Path (Join-Path $env:AZURE_CONFIG_DIR 'config'))) { Get-Content (Join-Path $env:AZURE_CONFIG_DIR 'config') -Raw } else { $null })
        configAzElenco = @(if ($env:AZURE_CONFIG_DIR -and (Test-Path $env:AZURE_CONFIG_DIR)) { Get-ChildItem $env:AZURE_CONFIG_DIR -Force | ForEach-Object Name })
        collaudo = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'COLLAUDO_*' } | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" })
        cwd = (Get-Location).Path
    } | ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath $env:CLAUDE_FINTO_ARGV -Encoding utf8
}

if ($env:CLAUDE_FINTO_EVENTI) {
    foreach ($riga in (Get-Content -LiteralPath $env:CLAUDE_FINTO_EVENTI -Encoding utf8)) {
        [Console]::Out.WriteLine($riga)
        [Console]::Out.Flush()
    }
}

if ($env:CLAUDE_FINTO_ATTESA) { Start-Sleep -Milliseconds ([int]$env:CLAUDE_FINTO_ATTESA) }
