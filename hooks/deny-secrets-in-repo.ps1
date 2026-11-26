# Hook PreToolUse su Write/Edit: rifiuta di scrivere un segreto in un file del repo.
# I segreti stanno in un ADO Library Variable Group o in user-secrets, mai in git.
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
    [Console]::Error.WriteLine("hook: input non interpretabile, controllo saltato - $_")
    exit 0
}

$path = [string] $payload.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($path)) { exit 0 }

# I template con i segnaposto sono il modo giusto: passano.
if ($path -match '(?i)\.template\.') { exit 0 }
# Solo configurazione e script: il codice che nomina 'password' va lasciato stare.
if ($path -notmatch '(?i)\.(json|config|xml|yml|yaml|ps1|psm1|env|ini|sh)$') { exit 0 }

$content = ''
foreach ($field in 'content', 'new_string', 'new_str') {
    $value = $payload.tool_input.$field
    if ($value) { $content += "`n" + [string] $value }
}
if ([string]::IsNullOrWhiteSpace($content)) { exit 0 }

# Una chiave sensibile con accanto un valore vero. I segnaposto non contano.
$pattern = '(?i)(password|pwd|apikey|api_key|clientsecret|client_secret|accesskey|token)' +
           '[a-z_]*\s*["'']?\s*[:=]\s*(["'']?)([^"''\s,;}]{6,})'
$placeholder = '(?i)^(\{\{|<|\$\(|%|\*{3}|changeme|placeholder|your|xxx|todo|secret|env:)'
$notASecret = '(?i)^(true|false|null|none|empty|0)$'
# Un indirizzo dice dove chiedere il segreto (tokenUrl, tokenEndpoint), non lo contiene. Con utente e password prima
# della @ invece lo contiene. Un token nella query non arriva qui come indirizzo: lo prende la sua chiave (?token=...).
$plainUrl = '(?i)^https?://[^/@\s]+(/|$)'

# Un nome con "token" seguito da codice non e un segreto: un segreto e un valore scritto nel file. Nel codice
# (ps1, psm1, sh) il valore e codice solo se la riga lo mostra senza ambiguita:
#  - la chiave non sta dentro una stringa (sulla riga, prima del nome, apici e virgolette sono in numero pari): in
#    'Server=a;Password=...' il valore e un letterale, qualunque forma abbia;
#  - un riferimento a variabile e intero ($x, ${x}, $x.Campo, $env:X; non tra apici singoli) e il resto della riga non
#    ha apici: dopo `$env:X ?? 'valore'` c'e un letterale di ripiego, e ${X:-valore} non e un riferimento intero;
#  - senza apici, in PowerShell, ha la forma di un'espressione: cast, gruppo, sottoespressione, comando con verbo
#    approvato (Get-Content) o chiamata di metodo.
# Un valore tra apici e sempre un letterale, e nei file di dati (json, yaml, ini, env, xml) non si guarda la forma.
$isPowerShell = $path -match '(?i)\.(ps1|psm1)$'
$isCode = $isPowerShell -or $path -match '(?i)\.sh$'
$approvedVerbs = if ($isPowerShell) { @(Get-Verb | ForEach-Object { $_.Verb }) } else { @() }

function Test-LooksLikeCode([string] $quote, [string] $value, [string] $before, [string] $after) {
    if (-not $isCode) { return $false }
    if ((@($before.ToCharArray() | Where-Object { $_ -eq "'" }).Count % 2) -ne 0) { return $false }
    if ((@($before.ToCharArray() | Where-Object { $_ -eq '"' }).Count % 2) -ne 0) { return $false }
    if ($quote -ne "'" -and $value -match '^\$\{?[\w:]+\}?(\.\w+(\(\w*\))?)*$') { return $after -notmatch '["'']' }
    if ($quote -ne "'" -and $value -match '^\$') { return $false }
    if (-not $isPowerShell -or $quote -ne '') { return $false }
    if ($value -match '^[\[(@{]') { return $true }
    if ($value -match '^[A-Za-z_][\w.:]*\(') { return $true }
    if ($value -match '^([A-Za-z]+)-[A-Za-z]\w*$' -and $Matches[1] -in $approvedVerbs) { return $true }
    $false
}

foreach ($match in [regex]::Matches($content, $pattern)) {
    $value = $match.Groups[3].Value
    if ($value -match $placeholder) { continue }
    if ($value -match $notASecret) { continue }
    if ($value -match $plainUrl -and $value -notmatch '@') { continue }
    $lineStart = if ($match.Index -eq 0) { 0 } else { $content.LastIndexOf("`n", $match.Index - 1) + 1 }
    $before = $content.Substring($lineStart, $match.Index - $lineStart)
    $end = $match.Index + $match.Length
    $lineEnd = $content.IndexOf("`n", $end)
    if ($lineEnd -lt 0) { $lineEnd = $content.Length }
    $after = $content.Substring($end, $lineEnd - $end)
    if (Test-LooksLikeCode $match.Groups[2].Value $value $before $after) { continue }

    Deny @"
Scrittura bloccata: sembra un segreto in un file del repo.

  file:   $path
  chiave: $($match.Groups[1].Value)

I segreti non si committano mai. Nei file del repo solo valori non segreti (endpoint,
livelli di log, host senza password). Il segreto va in un ADO Library Variable Group
dell'ambiente (variabile SECRET, iniettata al deploy come variabile d'ambiente del
servizio), oppure in 'dotnet user-secrets' per lo sviluppo locale. Al suo posto si committa
un appsettings.{Env}.template.json con il segnaposto.

Se e' un falso positivo, dillo all'utente invece di aggirare l'hook.
"@
}

exit 0
