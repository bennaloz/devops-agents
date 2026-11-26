# Hook PreToolUse su Bash, PowerShell e WebFetch: nelle sessioni del collaudatore rifiuta un comando che nomina un host
# diverso da quelli ammessi. Ammessi: gli host degli urlTest di config/mappa.json (qualunque porta: sullo stesso host
# gira anche Keycloak di Test), Azure DevOps (per az in lettura), localhost e 127.0.0.1.
# L'elenco si ricava a ogni chiamata dalla mappa del repo da cui gira l'hook: una voce nuova vale subito.
# E' un presidio contro l'errore (un indirizzo di produzione copiato da una configurazione), non una recinzione: legge
# solo il testo del comando, quindi un URL costruito in una variabile non lo vede.
# Vale solo con ATTREZZI_RUOLO=collaudatore (lo imposta Start-SessioneRuolo). Altrove non fa niente.
# Exit 2 = chiamata bloccata, lo stderr torna al modello. Exit 0 = passa.
$ErrorActionPreference = 'Stop'

if ($env:ATTREZZI_RUOLO -ne 'collaudatore') { exit 0 }

function Deny([string] $message) {
    [Console]::Error.WriteLine($message)
    exit 2
}

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
}
catch {
    [Console]::Error.WriteLine("hook: input non interpretabile, controllo saltato - $_")
    exit 0
}

$testo = (@([string] $payload.tool_input.command, [string] $payload.tool_input.url) | Where-Object { $_ }) -join "`n"
if ([string]::IsNullOrWhiteSpace($testo)) { exit 0 }

$mappa = Join-Path (Split-Path $PSScriptRoot -Parent) 'config/mappa.json'
$ammessi = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($h in 'acme.visualstudio.com', 'dev.azure.com', 'localhost', '127.0.0.1') { [void] $ammessi.Add($h) }
try {
    $mp = Get-Content -LiteralPath $mappa -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($mp.PSObject.Properties['organizzazione'] -and $mp.organizzazione -and ([uri] $mp.organizzazione).Host) { [void] $ammessi.Add(([uri] $mp.organizzazione).Host) }
    foreach ($a in $mp.aree) {
        if ($a.urlTest -and ([uri] $a.urlTest).Host) { [void] $ammessi.Add(([uri] $a.urlTest).Host) }
    }
}
catch {
    Deny "Bloccato: non riesco a leggere gli host di Test da $mappa ($_). Chiudi con ESITO=bloccato."
}

$trovati = [System.Collections.Generic.List[string]]::new()
# http(s)://[utente@]host[:porta]
foreach ($m in [regex]::Matches($testo, '(?i)\bhttps?://(?:[^/\s@"''`]*@)?(?<h>[^/:\s"''`?#\)\]]+)')) { $trovati.Add($m.Groups['h'].Value) }
# host senza schema: dopo -Uri, o come primo argomento non-opzione di curl / wget
$senza = '(?i)(?:-Uri\s+|\b(?:curl|wget)(?:\.exe)?\s+(?:-\S+\s+)*)["'']?(?<h>[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)+)(?::\d+)?(?:[/"''\s;|&]|$)'
foreach ($m in [regex]::Matches($testo, $senza)) {
    $h = $m.Groups['h'].Value
    if ($h -match '^(?i)https?$') { continue }
    $trovati.Add($h)
}

foreach ($h in $trovati) {
    # un host costruito con variabili ($, {, %) non si puo valutare: passa
    if ($h -match '[${}%]') { continue }
    if (-not $ammessi.Contains($h.TrimEnd('.'))) {
        Deny @"
Bloccato: l'host '$h' non e' tra quelli che il collaudatore puo chiamare.

Gli host ammessi sono quelli degli urlTest di config/mappa.json (ambiente di Test, qualunque porta), Azure DevOps,
localhost e 127.0.0.1. Se per provare la card ti serviva davvero questo indirizzo, chiudi con ESITO=bloccato e scrivi
il motivo sulla card.
"@
    }
}
exit 0
