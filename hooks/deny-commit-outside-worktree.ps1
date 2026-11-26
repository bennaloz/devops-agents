# Hook PreToolUse su Bash e PowerShell: rifiuta un git commit che non avvenga in un worktree sotto _wt.
# Exit 2 = chiamata bloccata, lo stderr torna al modello. Exit 0 = passa.
$ErrorActionPreference = 'Stop'

function Deny([string] $message) {
    # Non Write-Error: con ErrorActionPreference='Stop' terminerebbe con exit 1, non 2.
    [Console]::Error.WriteLine($message)
    exit 2
}

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
}
catch {
    # Input illeggibile: si lascia passare (l'hook non deve bloccare il lavoro), ma si dice perche'.
    [Console]::Error.WriteLine("hook: input non interpretabile, controllo saltato - $_")
    exit 0
}

$command = [string] $payload.tool_input.command
if ([string]::IsNullOrWhiteSpace($command)) { exit 0 }

# Solo i comandi che creano un commit. 'commit-tree' e '--dry-run' non contano.
# git deve essere un comando (a inizio riga o dopo ; & | ( {), seguito solo dalle sue opzioni globali (-C <dir>, -c <k=v>,
# --qualcosa) e poi dal sottocomando commit. Le parole "git" e "commit" dentro un testo (i criteri di una card passati a
# card.ps1 con una here-string) non sono un commit: prima l'hook le bloccava e il testo andava riscritto senza quella parola.
if ($command -notmatch '(?im)(?:^|[;&|({])\s*git(?:\.exe)?(?:\s+(?:-[Cc]\s+(?:"[^"]*"|''[^'']*''|\S+)|--\S+))*\s+commit\b') { exit 0 }
if ($command -match '(?i)\bcommit-tree\b') { exit 0 }
if ($command -match '(?i)--dry-run') { exit 0 }

# Dove avverrebbe: un -C esplicito, un cd (o Set-Location) dentro il comando, altrimenti la cwd della sessione.
$target = [string] $payload.cwd
if ($command -match '(?i)\bgit\s+-C\s+"?([^"\s]+)"?') {
    $target = $Matches[1]
}
elseif ($command -match '(?i)(?:^|&&|;)\s*(?:cd|chdir|pushd|sl|Push-Location|Set-Location)(?:\s+-(?:LiteralPath|Path))?\s+"?([^"&;]+?)"?\s*(?:&&|;|$)') {
    $target = $Matches[1].Trim()
}

# Percorsi sia Windows sia git-bash: si confronta su un unico separatore.
$normalized = ($target -replace '/', '\')
$worktreeMarker = '\_wt\'
if ($normalized.ToLowerInvariant().Contains($worktreeMarker)) { exit 0 }

Deny @"
Commit bloccato: non sei in un worktree.

  percorso rilevato: $target

La working copy principale non e' nostra - l'utente ha altre sessioni aperte e cambia ramo
mentre lavoriamo. Si committa solo sotto C:\develop\GIT\_wt\<repo>\<slug>.

  git fetch origin
  git worktree add "C:\develop\GIT\_wt\<repo>\<slug>" -b <ramo> origin/develop

Vedi la skill 'worktree'. Se il commit deve davvero avvenire qui, chiedilo all'utente.
"@
