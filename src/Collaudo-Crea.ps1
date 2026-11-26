#requires -Version 7
# Il processo staccato che crea l'ambiente di collaudo di una card (D59): lo lancia Start-AmbienteCollaudo con la richiesta salvata
# su file. Scrive il log di docker e il file di esito, poi esce.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Richiesta)
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Collaudo.psm1') -Force
Invoke-CreazioneAmbiente (Get-Content -LiteralPath $Richiesta -Raw -Encoding UTF8 | ConvertFrom-Json)
