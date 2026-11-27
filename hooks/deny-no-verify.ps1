# Hook PreToolUse su Bash e PowerShell, attivo in ogni sessione: rifiuta un comando git che salta gli hook di git
# (--no-verify, commit -n, -c core.hooksPath=...). Gli hook di git sono controlli voluti dal repo: se uno fallisce si
# corregge la causa, non lo si aggira. Idea presa da block-no-verify.js di ECC, ridotta ai casi che un agente scrive.
#
# Prima del controllo si tolgono i corpi degli heredoc, delle here-string PowerShell e il testo fra virgolette:
# un messaggio di commit che nomina --no-verify non e' un aggiramento.
# E' un presidio contro l'uso distratto, non una recinzione: un flag costruito a runtime passa.
# Exit 2 = chiamata bloccata, lo stderr torna al modello. Exit 0 = passa.
$ErrorActionPreference = 'Stop'

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
}
catch {
    [Console]::Error.WriteLine("hook: input non interpretabile, controllo saltato - $_")
    exit 0
}

$command = [string] $payload.tool_input.command
if ([string]::IsNullOrWhiteSpace($command) -or $command -notmatch '(?i)\bgit\b') { exit 0 }

# Heredoc bash (<<EOF, <<'EOF', <<-EOF) fino alla riga del terminatore; here-string PowerShell @' '@ e @" "@.
$testo = [regex]::Replace($command, "(?s)<<-?\s*['""]?(\w+)['""]?.*?\n\s*\1\b", '')
$testo = [regex]::Replace($testo, "(?s)@'.*?\n'@", '')
$testo = [regex]::Replace($testo, '(?s)@".*?\n"@', '')
$senzaVirgolette = [regex]::Replace($testo, "(?s)'[^']*'|""[^""]*""", '""')

$motivo = $null
if ($senzaVirgolette -match '(?i)--no-verify\b') { $motivo = '--no-verify' }
elseif ($testo -match '(?i)\bcore\.hooksPath\b') { $motivo = 'core.hooksPath' }
else {
    # git commit -n (o -n dentro un gruppo di flag corti come -anm): per commit -n vuol dire --no-verify.
    # Si guarda solo il pezzo di comando fino al prossimo separatore.
    foreach ($pezzo in ($senzaVirgolette -split '&&|\|\||[;|\n]')) {
        if ($pezzo -match '(?i)\bgit\b.*\bcommit\b(.*)$' -and $Matches[1] -match '(?<=\s)-[a-zA-Z]*n[a-zA-Z]*\b') {
            $motivo = 'commit -n'
            break
        }
    }
}

if (-not $motivo) { exit 0 }

[Console]::Error.WriteLine(@"
Bloccato: il comando salta gli hook di git ($motivo).

Gli hook di git sono controlli del repo. Se uno fallisce, leggi l'errore e correggi la causa.
Se pensi che l'hook sbagli, dillo all'utente: saltarlo lo decide lui, e il comando lo lancia lui.
"@)
exit 2
