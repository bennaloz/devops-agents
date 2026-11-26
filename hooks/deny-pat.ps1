# Hook PreToolUse su Bash, PowerShell e Read: rifiuta un comando o una lettura che nomina un file pat[-nome].txt (pat.txt, pat-smistatore.txt, pat-read-only.txt...) o
# AZURE_DEVOPS_EXT_PAT o GH_TOKEN (il token di GitHub in lettura, pat-github-lettura.txt), oppure il login di az (get-access-token, AZURE_CONFIG_DIR, la cartella .azure: con un login attivo la sessione non lo eredita), a meno che il comando sia una chiamata a card.ps1. La sessione il PAT in lettura lo usa
# dall'ambiente (az e gli script lo trovano da soli), non lo vede.
# E' un presidio, non una recinzione: tiene il PAT fuori dal contesto di un modello che non lo sta cercando apposta.
# Vale solo dentro una sessione di ruolo, cioe' con ATTREZZI_RUOLO nell'ambiente (lo imposta lo smistatore). Nelle
# sessioni normali non fa niente: li' caricare il PAT nello stesso comando di `az` e' l'uso previsto.
# Exit 2 = chiamata bloccata, lo stderr torna al modello. Exit 0 = passa.
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:ATTREZZI_RUOLO)) { exit 0 }

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

$testo = (@([string] $payload.tool_input.command, [string] $payload.tool_input.file_path) |
    Where-Object { $_ }) -join "`n"
if ([string]::IsNullOrWhiteSpace($testo)) { exit 0 }

# pat.txt e pat-smistatore.txt sono il PAT pieno; pat-read-only.txt e pat-smistatore-lettura.txt quello in lettura, che la
# sessione riceve gia nell'ambiente. Qualunque pat[-nome].txt. Anche az login (darebbe un login che resterebbe a tutte le
# sessioni dopo) e msal_token_cache (la cache dei token).
# .claude/collaudo: le credenziali di prova del collaudatore, che le riceve nell'ambiente (COLLAUDO_*) senza leggere il file.
# Il login di az: get-access-token darebbe alla sessione un token con i permessi della persona; AZURE_CONFIG_DIR e la
# cartella .azure (la cache dei token) sono il modo di arrivarci senza chiamarlo. Alla sessione basta card.ps1.
if ($testo -notmatch '(?i)pat(-[\w-]+)?\.txt|AZURE_DEVOPS_EXT_PAT|\bGH_TOKEN\b|\bGITHUB_TOKEN\b|\bgh\s+auth\s+(token|login)\b|\.claude[\\/]collaudo|get-access-token|\baz(\.cmd)?\s+login\b|msal_token_cache|AZURE_CONFIG_DIR|(^|[\s\\/~"''=:])\.azure([\s\\/"'']|$)') { exit 0 }

# Una chiamata a card.ps1 puo nominare il file nel testo di un commento: passa solo se il comando e' una sola
# invocazione di pwsh su card.ps1, senza altri comandi in coda (nessun ; & | ne' a capo fuori dal testo).
$command = [string] $payload.tool_input.command
# card.ps1 vuole i testi lunghi su stdin. Un testo letterale (here-string a apici singoli in testa con una pipe,
# oppure heredoc Bash con il delimitatore quotato in coda) non espande variabili: si toglie, e il resto deve essere
# comunque la sola chiamata a card.ps1. Le forme che espandono (@"..."@, <<EOF) restano bloccate.
if ($command -match "(?s)^\s*@'\r?\n.*?\r?\n'@\s*\|(?<resto>.*)$") { $command = $Matches['resto'] }
elseif ($command -match "(?s)^(?<resto>[^\r\n]*?)\s*<<-?\s*'(?<fine>\w+)'\r?\n.*\r?\n\k<fine>\s*$") { $command = $Matches['resto'] + ' ' }
if ($command -match '(?i)^\s*(pwsh|powershell)(\.exe)?\s+(-\w+\s+)*-File\s+"?[^\s"]*card\.ps1"?\s' -and
    ($command -replace '"[^"]*"', '' -replace "'[^']*'", '') -notmatch '[;&|`\r\n]') {
    exit 0
}

Deny @"
Bloccato: il PAT di Azure DevOps e il login di az non si leggono ne si nominano.

Le chiamate ad Azure DevOps passano da card.ps1 (leggi, commenta, criteri, sposta), che carica il PAT da solo
dentro il suo processo. Non chiamare az per prendere un token e non toccare AZURE_CONFIG_DIR ne la cartella .azure. Se ti serve qualcosa che card.ps1 non fa, chiedilo all'utente.
"@
