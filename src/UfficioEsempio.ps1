#requires -Version 7
<#
.SYNOPSIS
    Scrive la pagina d'esempio dell'ufficio (docs/ufficio-esempio.html): dati inventati, tutti i comportamenti, nessuna sessione vera.
.DESCRIPTION
    La pagina e autosufficiente: si apre con un doppio clic, senza server. La scena si sceglie dalla pagina (consegna e rimando, giornata di
    lavoro, pausa per la riserva, Azure DevOps che non risponde, dati fermi). I dati veri si vedono con src/Vista.ps1 -Html -Segui, poi
    http://localhost:18799/ufficio.html.
#>
[CmdletBinding()]
param(
    [string]$Percorso = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/ufficio-esempio.html'),
    [switch]$Apri
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($m in 'Comune', 'VistaUfficio', 'VistaUfficioPagina', 'VistaUfficioEsempio') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") -Global -Force }

$pagina = New-PaginaUfficio (Get-EsempioUfficio)
[IO.File]::WriteAllText($Percorso, $pagina, [Text.UTF8Encoding]::new($false))
Write-Host "Pagina d'esempio scritta in $Percorso"
if ($Apri) { Start-Process -FilePath $Percorso }
