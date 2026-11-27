# Hook PreToolUse su Edit e Write, attivo in ogni sessione: quando il contesto della sessione supera una soglia di
# token, avvisa l'utente che e' un buon momento per /compact. Non blocca niente.
#
# Ogni chiamata al modello rilegge tutto il contesto: una sessione lunga costa di piu' a ogni passo. Compattare a
# fine fase (dopo l'esplorazione, a un pezzo finito) costa meno che lasciar decidere l'auto-compattazione a meta'
# lavoro. Idea presa da suggest-compact.js di ECC: si misura il contesto vero, non il numero di chiamate ai tool.
#
# Il contesto e' l'ultimo "usage" del transcript: input_tokens + cache_read_input_tokens + cache_creation_input_tokens.
# Avviso alla prima soglia, poi a ogni intervallo in piu'. Lo stato per sessione sta in un file nella cartella temp.
#   COMPACT_SOGLIA_TOKEN     prima soglia (default 150000)
#   COMPACT_INTERVALLO_TOKEN crescita fra un avviso e il successivo (default 75000)
# Exit sempre 0: un errore qui non deve fermare il lavoro.
$ErrorActionPreference = 'Stop'

function Get-Intero([string]$valore, [int]$default) {
    $n = 0
    if ([int]::TryParse($valore, [ref]$n) -and $n -gt 0) { $n } else { $default }
}

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $transcript = [string] $payload.transcript_path
    $sessione = [string] $payload.session_id
    if ([string]::IsNullOrWhiteSpace($transcript) -or -not (Test-Path -LiteralPath $transcript)) { exit 0 }
    if ([string]::IsNullOrWhiteSpace($sessione)) { $sessione = [IO.Path]::GetFileNameWithoutExtension($transcript) }

    $soglia = Get-Intero $env:COMPACT_SOGLIA_TOKEN 150000
    $intervallo = Get-Intero $env:COMPACT_INTERVALLO_TOKEN 75000

    # Si legge solo la coda del file: il transcript arriva a decine di MB.
    $coda = 512KB
    $stream = [IO.File]::Open($transcript, 'Open', 'Read', 'ReadWrite')
    try {
        $inizio = [Math]::Max(0, $stream.Length - $coda)
        $stream.Seek($inizio, 'Begin') | Out-Null
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        $testo = $reader.ReadToEnd()
    }
    finally { $stream.Dispose() }

    $token = 0
    $righe = $testo -split "`n"
    for ($i = $righe.Count - 1; $i -ge 0; $i--) {
        $riga = $righe[$i]
        if ($riga -notmatch '"usage"' -or $riga -match '"isSidechain":true') { continue }
        try { $voce = $riga | ConvertFrom-Json } catch { continue }  # la prima riga della coda puo' essere tagliata
        $u = $voce.message.usage
        if (-not $u) { continue }
        $token = [int64]$u.input_tokens + [int64]$u.cache_read_input_tokens + [int64]$u.cache_creation_input_tokens
        break
    }
    if ($token -lt $soglia) { exit 0 }

    # Gradino raggiunto: 0 alla soglia, 1 a soglia+intervallo, ... Si avvisa una volta per gradino.
    $gradino = [Math]::Floor(($token - $soglia) / $intervallo)
    $nomeSicuro = $sessione -replace '[^\w-]', '_'
    $stato = Join-Path ([IO.Path]::GetTempPath()) "claude-compact-$nomeSicuro.txt"
    $ultimo = -1
    $letto = 0
    if ((Test-Path -LiteralPath $stato) -and [int]::TryParse((Get-Content -LiteralPath $stato -Raw).Trim(), [ref]$letto)) { $ultimo = $letto }
    if ($gradino -le $ultimo) { exit 0 }
    Set-Content -LiteralPath $stato -Value $gradino -NoNewline

    # I file di stato delle sessioni vecchie si tolgono dopo 14 giorni.
    Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'claude-compact-*.txt' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $k = [Math]::Round($token / 1000)
    $messaggio = "Contesto a ${k}k token: se hai chiuso una fase, e' un buon momento per /compact."
    @{ systemMessage = $messaggio } | ConvertTo-Json -Compress
}
catch {
    [Console]::Error.WriteLine("suggest-compact: controllo saltato - $_")
}
exit 0
