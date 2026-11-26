Set-StrictMode -Version Latest

# Le sessioni dei ruoli: lancia `claude -p` come processo separato, ne legge l'esito dall'uscita a eventi, scrive il
# registro dei consumi. Nessuna regola di flusso: quando lanciare lo decide Decisioni.psm1, il giro le esegue.

Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Ado.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Memoria.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'MemoriaRepo.psm1') -Global

$script:Eseguibile = $null
$script:ArgomentiIniziali = @()
# Un solo valore per tutti i lanci: la cache del prompt alla ripresa si riusa solo con opzioni identiche.
$script:McpConfig = '{"mcpServers":{}}'
$script:PermessiModalita = 'acceptEdits'

# Il binario vero di claude. `claude` sul PATH e uno shim (claude.cmd/.ps1 di npm) che Start-Process lancerebbe
# attraverso cmd, con un altro modo di passare gli argomenti: si usa il claude.exe accanto allo shim.
function Get-EseguibileClaude {
    if ($script:Eseguibile) { return $script:Eseguibile }
    foreach ($c in @(Get-Command claude -All -ErrorAction SilentlyContinue)) {
        $sorgente = [string]$c.Source
        if (-not $sorgente) { continue }
        if ($sorgente -match '\.exe$') { return $sorgente }
        $exe = Join-Path (Split-Path -Parent $sorgente) 'node_modules/@anthropic-ai/claude-code/bin/claude.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    throw 'claude.exe non trovato: installarlo o usare Set-SessioniEseguibile'
}

# Per i test: l'eseguibile (e gli argomenti che lo precedono, ad esempio -File claude-finto.ps1).
function Set-SessioniEseguibile {
    [CmdletBinding()]
    param([string]$Percorso, [string[]]$ArgomentiIniziali = @())
    $script:Eseguibile = if ($Percorso) { $Percorso } else { $null }
    $script:ArgomentiIniziali = @($ArgomentiIniziali)
}

# Una riga di comando di Windows e una stringa sola: l'escape e quello di CreateProcess (barre rovesciate prima delle
# virgolette raddoppiate). E il solo punto che costruisce la stringa, per il primo lancio e per la ripresa.
function ConvertTo-ArgomentoProcesso([string]$Valore) {
    if ($Valore -eq '') { return '""' }
    if ($Valore -notmatch '[\s"]') { return $Valore }
    $r = [regex]::Replace($Valore, '(\\*)"', '$1$1\"')
    $r = [regex]::Replace($r, '(\\+)$', '$1$1')
    '"' + $r + '"'
}

# Gli argomenti di claude, nell'ordine fisso. Primo lancio e ripresa passano da qui: cambia solo la coppia
# --session-id <id> / --resume <id>.
function Get-ArgomentiClaude {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Messaggio,
        [Parameter(Mandatory)]$RuoloConfig,
        [Parameter(Mandatory)][string]$Brief,
        [Parameter(Mandatory)][string]$SessioneId,
        [bool]$Ripresa = $false
    )
    $a = [System.Collections.Generic.List[string]]::new()
    $a.Add('-p'); $a.Add($Messaggio)
    $a.Add('--model'); $a.Add([string]$RuoloConfig.modello)
    if ($null -ne $RuoloConfig.sforzo -and "$($RuoloConfig.sforzo)" -ne '') { $a.Add('--effort'); $a.Add([string]$RuoloConfig.sforzo) }
    # L'advisor (D55): un modello piu forte che la sessione consulta nei punti decisivi. Il ruolo che non lo ha parte senza.
    $adv = $RuoloConfig.PSObject.Properties['advisor']; if ($null -ne $adv -and "$($adv.Value)" -ne '') { $a.Add('--advisor'); $a.Add([string]$adv.Value) }
    $a.Add('--output-format'); $a.Add('stream-json'); $a.Add('--verbose')
    $a.Add($(if ($Ripresa) { '--resume' } else { '--session-id' })); $a.Add($SessioneId)
    $a.Add('--append-system-prompt-file'); $a.Add($Brief)
    # --tools toglie gli strumenti che il ruolo non ha (Write ed Edit a responsabile e reviewer); --allowedTools li approva.
    $a.Add('--tools'); foreach ($s in @($RuoloConfig.strumenti)) { $a.Add([string]$s) }
    $a.Add('--allowedTools'); foreach ($s in @($RuoloConfig.strumenti)) { $a.Add([string]$s) }
    $a.Add('--strict-mcp-config'); $a.Add('--mcp-config'); $a.Add($script:McpConfig)
    $a.Add('--permission-mode'); $a.Add($script:PermessiModalita)
    , @($a)
}

# Il brief che la sessione riceve: quello del ruolo, e se il ruolo ha un repo (D46) un file composto accanto all'uscita
# della sessione, con il brief e in fondo la sezione Memoria. Il file si scrive sempre al primo lancio, anche senza lezioni
# (allora e il brief del ruolo e basta) o se la lettura non riesce: la memoria e un di piu e non ferma mai il lancio. I
# guasti della lettura tornano in Motivi.
# La lettura si fa dalla radice degli attrezzi, dove sta il clone con origin da cui si leggono develop e il ramo in prova.
# Il file composto si chiama <id>.brief.md, con l'id della sessione e non quello dell'uscita (che alla ripresa e <id>.r1):
# una ripresa lo riusa sempre cosi com'e se c'e, perche la cache del prompt vale solo con opzioni identiche e un brief
# diverso la butterebbe. Le lezioni nate nel frattempo arrivano alla sessione nuova, non alla ripresa. Se il file non c'e
# (sessione di prima della memoria, o tolto) la ripresa lo compone adesso.
function Get-BriefDellaSessione {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Brief, [Parameter(Mandatory)][string]$Ruolo, [string]$Repo, [Parameter(Mandatory)][string]$Radice, [Parameter(Mandatory)][string]$Uscita,
        [Parameter(Mandatory)][string]$SessioneId, [bool]$Ripresa)
    $motivi = @()
    if ([string]::IsNullOrWhiteSpace($Repo)) { return [pscustomobject]@{ File = $Brief; Motivi = $motivi } }
    $file = Join-Path (Split-Path -Parent $Uscita) "$SessioneId.brief.md"
    if ($Ripresa -and (Test-Path -LiteralPath $file)) { return [pscustomobject]@{ File = $file; Motivi = $motivi } }
    try {
        $testoBrief = [IO.File]::ReadAllText($Brief, [Text.UTF8Encoding]::new($false))
        $composto = $testoBrief
        try {
            $m = Get-MemoriaDelRuolo -Radice $Radice -Ruolo $Ruolo -Repo $Repo
            $motivi = @($m.Motivi)
            $composto = New-BriefConMemoria -Brief $testoBrief -File @($m.File)
        }
        catch { $motivi = @($motivi) + @("la memoria non si compone, il brief parte da solo: $($_.Exception.Message)") }
        [IO.File]::WriteAllText($file, $composto, [Text.UTF8Encoding]::new($false))
        [pscustomobject]@{ File = $file; Motivi = $motivi }
    }
    catch { [pscustomobject]@{ File = $Brief; Motivi = @($motivi) + @("il brief della sessione non si scrive, parte quello del ruolo: $($_.Exception.Message)") } }
}

function Get-FileUscita([string]$CartellaDati, [string]$Id, [bool]$Ripresa) {
    $dir = Join-Path $CartellaDati 'sessioni'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $base = Join-Path $dir "$Id.jsonl"
    if (-not (Test-Path -LiteralPath $base)) { return $base }
    $n = 1
    while (Test-Path -LiteralPath (Join-Path $dir "$Id.r$n.jsonl")) { $n++ }
    Join-Path $dir "$Id.r$n.jsonl"
}

function Start-SessioneRuolo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Card,
        [Parameter(Mandatory)][string]$Ruolo,
        [Parameter(Mandatory)][string]$Messaggio,
        [Parameter(Mandatory)][string]$Cartella,
        [string]$Riprendi,
        $Config,
        [string]$Radice = (Split-Path -Parent $PSScriptRoot),
        [string]$CartellaDati = (Get-CartellaDati),
        # Testo lungo (rilievi, bivio): sta in un file e nel messaggio va il percorso. La riga di comando ha un limite.
        [string]$Allegato,
        # Il task su cui lavora la sessione (solo dev), 0 = nessuno: va in ATTREZZI_TASK, che card.ps1 chiudi-task legge.
        [int]$Task = 0,
        # Il PAT in sola lettura (Build: Read, Code: Read) che la sessione riceve come AZURE_DEVOPS_EXT_PAT: con questo
        # az e gli script del repo leggono Azure DevOps (un -DryRun, lo stato delle build), ma non scrivono niente.
        # Le scritture passano da card.ps1, che legge da se il PAT pieno. Senza il file la sessione non ha nessun PAT.
        # Se manca: pat-smistatore-lettura.txt, altrimenti pat-read-only.txt (Get-PercorsoFilePat).
        [string]$PercorsoPatLettura = (Get-PercorsoFilePat 'lettura'),
        # Il token di GitHub in sola lettura, che la sessione riceve come GH_TOKEN (gh pr view, gh run view --log-failed) per i repo
        # delle aree su GitHub. Senza il file la sessione non ha nessun token di GitHub.
        [string]$PercorsoPatGitHubLettura = (Get-PercorsoFilePatGitHub 'lettura'),
        # Le credenziali di prova dell'ambiente di Test (JSON, chiave -> valore), solo per il collaudatore: ogni chiave
        # diventa COLLAUDO_<CHIAVE> nell'ambiente della sessione. Il file sta fuori da ogni repo e il modello non lo legge.
        [string]$FileCollaudo,
        # Il repo della card: con lui la sessione riceve in fondo al brief le lezioni del suo ruolo (D46). Senza, il brief da solo.
        [string]$Repo,
        # Il ramo verso cui va la PR della card (D52: il ramo della funzionalita; develop per le card isolate): va in ATTREZZI_BASE, e
        # dev e reviewer lo usano per il diff e per il merge dei conflitti al posto di origin/develop.
        [string]$Base = 'develop'
    )
    if (-not $Config) { $Config = Get-Config -Radice $Radice -CartellaDati $CartellaDati }
    $r = $Config.Ruoli.PSObject.Properties[$Ruolo]
    if (-not $r) { throw "Ruolo sconosciuto: '$Ruolo'" }
    $rc = $r.Value
    $brief = Join-Path $Radice $rc.brief

    $ripresa = -not [string]::IsNullOrWhiteSpace($Riprendi)
    $id = if ($ripresa) { $Riprendi } else { [guid]::NewGuid().ToString() }

    $uscita = Get-FileUscita $CartellaDati $id $ripresa
    $errori = [IO.Path]::ChangeExtension($uscita, 'err')
    if (-not [string]::IsNullOrEmpty($Allegato)) {
        $fileAllegato = [IO.Path]::ChangeExtension($uscita, 'allegato.txt')
        [IO.File]::WriteAllText($fileAllegato, $Allegato, [Text.UTF8Encoding]::new($false))
        $Messaggio = $Messaggio + "`n" + $fileAllegato
    }
    # Le credenziali si leggono qui per scrivere nel messaggio i nomi delle variabili (mai i valori): il collaudatore non
    # puo elencare l'ambiente, e senza i nomi non saprebbe quali usare.
    $credCollaudo = @()
    if ($Ruolo -eq 'collaudatore') {
        if ($FileCollaudo -and (Test-Path -LiteralPath $FileCollaudo)) {
            # il messaggio di ConvertFrom-Json citerebbe il contenuto: si riporta solo che il file non va
            $cred = try { Get-Content -LiteralPath $FileCollaudo -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
            catch { throw "Il file delle credenziali di collaudo $FileCollaudo non e un JSON valido" }
            foreach ($c in @($cred.PSObject.Properties | Where-Object { $null -eq $_.Value -or $_.Value -is [string] -or $_.Value -is [ValueType] })) {
                $credCollaudo += [pscustomobject]@{ Nome = 'COLLAUDO_' + ($c.Name.ToUpperInvariant() -replace '[^A-Z0-9_]', '_'); Valore = [string]$c.Value }
            }
        }
        $Messaggio += if ($credCollaudo.Count -gt 0) {
            "`nCredenziali di prova nell'ambiente: " + ((@($credCollaudo.Nome) | Sort-Object) -join ', ') + '.'
        } else { "`nCredenziali di prova: nessuna credenziale di prova per questo repo." }
    }
    $contenutoBrief = Get-BriefDellaSessione -Brief $brief -Ruolo $Ruolo -Repo $Repo -Radice $Radice -Uscita $uscita -SessioneId $id -Ripresa $ripresa
    $argomenti = Get-ArgomentiClaude -Messaggio $Messaggio -RuoloConfig $rc -Brief $contenutoBrief.File -SessioneId $id -Ripresa $ripresa
    $riga = (@($script:ArgomentiIniziali) + $argomenti | ForEach-Object { ConvertTo-ArgomentoProcesso ([string]$_) }) -join ' '

    # Le variabili per gli hook e per card.ps1 vanno nel processo lanciato. Start-Process eredita l'ambiente di chi lo
    # chiama: si impostano qui e si ripristinano subito dopo, cosi non restano nell'ambiente dello smistatore.
    $vecchie = @{ ATTREZZI_CARD = $env:ATTREZZI_CARD; ATTREZZI_RUOLO = $env:ATTREZZI_RUOLO; ATTREZZI_DATI = $env:ATTREZZI_DATI; ATTREZZI_TASK = $env:ATTREZZI_TASK; ATTREZZI_BASE = $env:ATTREZZI_BASE
        AZURE_DEVOPS_EXT_PAT = $env:AZURE_DEVOPS_EXT_PAT; GH_TOKEN = $env:GH_TOKEN; GITHUB_TOKEN = $env:GITHUB_TOKEN; AZURE_CONFIG_DIR = $env:AZURE_CONFIG_DIR; AZURE_EXTENSION_DIR = $env:AZURE_EXTENSION_DIR }
    # le COLLAUDO_* di chi lancia non passano mai: si tolgono e si rimettono dopo
    foreach ($v in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'COLLAUDO_*' })) { $vecchie[$v.Name] = $v.Value; Remove-Item "Env:$($v.Name)" }
    $nuoveCollaudo = @()
    try {
        # mai il PAT di chi lancia: o quello in lettura, o nessuno
        $lettura = if (Test-Path -LiteralPath $PercorsoPatLettura) { Read-FilePat $PercorsoPatLettura } else { '' }
        if ($lettura) { $env:AZURE_DEVOPS_EXT_PAT = $lettura } else { Remove-Item Env:AZURE_DEVOPS_EXT_PAT -ErrorAction SilentlyContinue }
        # come per Azure DevOps: mai il token GitHub di chi lancia, solo quello in lettura (o nessuno)
        Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
        $letturaGh = if (Test-Path -LiteralPath $PercorsoPatGitHubLettura) { Read-FilePat $PercorsoPatGitHubLettura } else { '' }
        if ($letturaGh) { $env:GH_TOKEN = $letturaGh } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
        $env:ATTREZZI_CARD = [string]$Card
        $env:ATTREZZI_RUOLO = $Ruolo
        $env:ATTREZZI_DATI = $CartellaDati   # card.ps1 scrive le revisioni nostre dove lo smistatore le legge
        $env:ATTREZZI_BASE = if ([string]::IsNullOrWhiteSpace($Base)) { 'develop' } else { $Base }
        # mai il login di az di chi lancia: la sessione parte con una cartella di configurazione sua, una per sessione e
        # ricreata vuota a ogni avvio (un az login fatto da un agente non resta alle sessioni dopo). Dentro, solo il
        # default dell'organizzazione (non segreto). Le estensioni di az (azure-devops: az pipelines, az devops invoke) si
        # cercano di solito in <config>/cliextensions, che qui e vuota: si punta alla cartella delle estensioni dell'utente.
        $cartellaAz = Join-Path (Join-Path $CartellaDati 'az') $id
        if (Test-Path -LiteralPath $cartellaAz) { Remove-Item -LiteralPath $cartellaAz -Recurse -Force }
        New-Item -ItemType Directory -Path $cartellaAz -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $cartellaAz 'config'), "[defaults]`norganization = $(Get-AdoUrlOrganizzazione)`n", [Text.UTF8Encoding]::new($false))
        $env:AZURE_CONFIG_DIR = $cartellaAz
        $estensioni = Join-Path $HOME '.azure/cliextensions'
        if (Test-Path -LiteralPath $estensioni -PathType Container) { $env:AZURE_EXTENSION_DIR = $estensioni }
        else { Remove-Item Env:AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue }
        # una sessione che non e di un task non deve ereditare il task di chi lancia
        if ($Task -gt 0) { $env:ATTREZZI_TASK = [string]$Task } else { Remove-Item Env:ATTREZZI_TASK -ErrorAction SilentlyContinue }
        foreach ($c in $credCollaudo) {
            Set-Item "Env:$($c.Nome)" $c.Valore
            $nuoveCollaudo += $c.Nome
        }
        $p = Start-Process -FilePath (Get-EseguibileClaude) -ArgumentList $riga -WorkingDirectory $Cartella `
            -RedirectStandardOutput $uscita -RedirectStandardError $errori -WindowStyle Hidden -PassThru
    }
    finally {
        foreach ($n in $nuoveCollaudo) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
        foreach ($k in $vecchie.Keys) {
            if ($null -eq $vecchie[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { Set-Item "Env:$k" $vecchie[$k] }
        }
    }
    # L'orario di avvio serve a riconoscere il processo piu tardi: un PID da solo, dopo un riavvio del PC, puo essere di un altro.
    [pscustomobject]@{ Id = $id; Pid = $p.Id; Avvio = $p.StartTime.ToUniversalTime().ToString('o'); Ripresa = $ripresa; AvvisiMemoria = @($contenutoBrief.Motivi) }
}

function Get-FileDiUnaSessione([string]$CartellaDati, [string]$Id) {
    $dir = Join-Path $CartellaDati 'sessioni'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $f = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.jsonl' |
        Where-Object { $_.Name -eq "$Id.jsonl" -or $_.Name -like "$Id.r*.jsonl" } |
        Sort-Object LastWriteTimeUtc, CreationTimeUtc, Name)
    if ($f.Count -eq 0) { return $null }
    $f[-1]
}

# I resetsAt dei rate_limit_event sono secondi dal 1970; null se il valore non c'e o non e un numero.
function ConvertFrom-EpochQuota($Valore) {
    if ($null -eq $Valore -or "$Valore" -eq '') { return $null }
    $n = 0.0
    if (-not [double]::TryParse("$Valore", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $null }
    [DateTimeOffset]::FromUnixTimeSeconds([int64]$n).UtcDateTime
}

function Get-EsitoSessione {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string]$CartellaDati = (Get-CartellaDati))
    $esito = [ordered]@{
        Finita = $false; Errore = $false; Esito = $null; Lezioni = @(); Testo = $null; UltimoEvento = $null; Eventi = 0; Negati = @()
        Turni = 0; DurataMs = 0; TokenIn = 0; TokenOut = 0; CacheLetti = 0; CacheScritti = 0; Quota = $null; Limite = $null
    }
    $file = Get-FileDiUnaSessione $CartellaDati $Id
    if (-not $file) { return [pscustomobject]$esito }
    $file.Refresh()
    $esito.UltimoEvento = $file.LastWriteTimeUtc

    # L'evento finale si cerca per tipo: dopo di lui puo arrivare ancora un system/task_summary.
    $finale = $null
    $rifiutato = $null
    foreach ($riga in (Read-RigheCondivise $file.FullName)) {
        if ([string]::IsNullOrWhiteSpace($riga)) { continue }
        try { $e = $riga | ConvertFrom-Json } catch { continue }
        $esito.Eventi++
        if ($e -and $e.PSObject.Properties['type'] -and $e.type -eq 'result') { $finale = $e }
        # D51: l'uso delle finestre di quota arriva nei rate_limit_event; vale l'ultimo. Un evento rejected dice che la
        # finestra e piena e quando si libera.
        elseif ($e -and $e.PSObject.Properties['type'] -and $e.type -eq 'rate_limit_event') {
            $info = Get-Campo $e 'rate_limit_info'
            $finestre = Get-Campo $info 'unifiedWindows'
            if ($finestre) {
                $q = @{}
                foreach ($nome in 'five_hour', 'seven_day') {
                    $w = Get-Campo $finestre $nome
                    if ($w) { $q[$nome] = @{ Utilization = [double](Get-Campo $w 'utilization'); ResetsAt = ConvertFrom-EpochQuota (Get-Campo $w 'resetsAt') } }
                }
                $esito.Quota = $q
            }
            if ((Get-Campo $info 'status') -eq 'rejected') { $rifiutato = $info }
        }
    }
    if (-not $finale) { return [pscustomobject]$esito }

    $esito.Finita = $true
    $testo = if ($finale.PSObject.Properties['result']) { [string]$finale.result } else { '' }
    $esito.Testo = $testo
    # La riga ESITO= puo arrivare tra backtick o in grassetto, come la mostrano i brief: si tollerano ` e * intorno.
    $m = [regex]::Matches($testo, '(?m)^[\s`*]*ESITO=([^\s`*]+)[\s`*]*$')
    if ($m.Count -gt 0) { $esito.Esito = $m[$m.Count - 1].Groups[1].Value }
    # Le lezioni che il ruolo dice di aver seguito (D46): una riga LEZIONE: <id> ciascuna, con la stessa tolleranza della riga ESITO; dopo l'id si accetta l'etichetta in prova di Memoria.psm1, perche e nel titolo che il ruolo vede e lo copia.
    $etichetta = [regex]::Escape((Get-EtichettaInProva))
    $esito.Lezioni = @([regex]::Matches($testo, "(?m)^[\s``*]*LEZIONE:\s*([A-Za-z]+-\d+)(?:\s*$etichetta)?[\s``*]*`$") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)

    $isError = $finale.PSObject.Properties['is_error'] -and $finale.is_error -eq $true
    $negati = @(if ($finale.PSObject.Properties['permission_denials']) { $finale.permission_denials | Where-Object { $null -ne $_ } })
    $sottotipoKo = $finale.PSObject.Properties['subtype'] -and $finale.subtype -and $finale.subtype -ne 'success'
    # Un comando negato non risulta come errore (is_error resta falso). Se la sessione ha chiuso lo stesso con un esito,
    # vale l'esito: spesso il comando negato era una controverifica e l'agente ha concluso senza (card 10). Lo smistatore
    # lo dice sulla card. Senza esito la sessione e fallita. Dei negati si tiene solo lo strumento: il comando puo
    # contenere dati che non vanno in un commento.
    $esito.Negati = @($negati | ForEach-Object { [string](Get-Campo $_ 'tool_name') })
    $esito.Errore = [bool]($isError -or $sottotipoKo -or ($negati.Count -gt 0 -and -not $esito.Esito))

    # Il limite di token: l'evento rejected, o in mancanza il testo "hit your ... limit" con il reset della finestra piena.
    # Un limite senza un reset che si sappia leggere resta $null: lo smistatore lo tratta come un errore normale.
    if ($rifiutato) {
        $reset = ConvertFrom-EpochQuota (Get-Campo $rifiutato 'resetsAt')
        if ($reset) { $esito.Limite = @{ Finestra = [string](Get-Campo $rifiutato 'rateLimitType'); Reset = $reset } }
    }
    elseif ($testo -match 'hit your' -and $testo -match 'limit' -and $esito.Quota) {
        foreach ($nome in 'five_hour', 'seven_day') {
            $w = $esito.Quota[$nome]
            if ($w -and $w.Utilization -ge 1 -and $w.ResetsAt) { $esito.Limite = @{ Finestra = $nome; Reset = $w.ResetsAt }; break }
        }
    }

    if ($finale.PSObject.Properties['num_turns']) { $esito.Turni = [int]$finale.num_turns }
    if ($finale.PSObject.Properties['duration_ms']) { $esito.DurataMs = [int64]$finale.duration_ms }
    if ($finale.PSObject.Properties['usage'] -and $finale.usage) {
        $u = $finale.usage
        $num = { param($n) if ($u.PSObject.Properties[$n] -and $null -ne $u.$n) { [int64]$u.$n } else { 0 } }
        $esito.TokenIn = & $num 'input_tokens'
        $esito.TokenOut = & $num 'output_tokens'
        $esito.CacheLetti = & $num 'cache_read_input_tokens'
        $esito.CacheScritti = & $num 'cache_creation_input_tokens'
    }
    [pscustomobject]$esito
}

# Il totale dei token di un esito (o di un progresso): ingresso, uscita e le due cache. E la somma che si scrive sulla card.
function Get-TotaleToken($Esito) {
    [int64]$Esito.TokenIn + [int64]$Esito.TokenOut + [int64]$Esito.CacheLetti + [int64]$Esito.CacheScritti
}

# Una riga per ogni strumento che l'agente ha chiamato: il nome, poi la descrizione se c'e, altrimenti il file, altrimenti
# la prima riga del comando (troncata). Un riassunto da leggere in un colpo d'occhio, non il comando intero.
function Format-AzioneSessione($Uso) {
    $in = Get-Campo $Uso 'input'
    $nome = [string](Get-Campo $Uso 'name')
    $dettaglio = [string](Get-Campo $in 'description')
    if (-not $dettaglio) { $dettaglio = [string](Get-Campo $in 'file_path') }
    if (-not $dettaglio) {
        $comando = [string](Get-Campo $in 'command')
        $prima = $comando -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1
        if ($prima) { $dettaglio = if ($prima.Length -gt 100) { $prima.Substring(0, 100) + '...' } else { $prima } }
    }
    if ($dettaglio) { "${nome}: $dettaglio" } else { $nome }
}

# Cosa sta facendo una sessione, letto dall'uscita a eventi senza toccarla: le ultime azioni (strumenti chiamati) e i token
# consumati finora. I token sono quelli dei messaggi dell'assistente, contati una volta per messaggio (lo stesso messaggio
# compare su piu righe, una per blocco di contenuto); il totale finale vero lo da Get-EsitoSessione a sessione chiusa.
function Get-ProgressoSessione {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string]$CartellaDati = (Get-CartellaDati), [int]$Ultime = 5)
    $r = [ordered]@{ Azioni = @(); TokenIn = 0; TokenOut = 0; CacheLetti = 0; CacheScritti = 0; Token = 0 }
    $file = Get-FileDiUnaSessione $CartellaDati $Id
    if (-not $file) { return [pscustomobject]$r }
    $azioni = [System.Collections.Generic.List[string]]::new()
    $uso = @{}
    $senzaId = 0
    foreach ($riga in (Read-RigheCondivise $file.FullName)) {
        if ([string]::IsNullOrWhiteSpace($riga)) { continue }
        try { $e = $riga | ConvertFrom-Json } catch { continue }
        if ((Get-Campo $e 'type') -ne 'assistant') { continue }
        $m = Get-Campo $e 'message'
        foreach ($c in @(Get-Campo $m 'content')) {
            if ((Get-Campo $c 'type') -eq 'tool_use') { $azioni.Add((Format-AzioneSessione $c)) }
        }
        $u = Get-Campo $m 'usage'
        if ($u) {
            $mid = [string](Get-Campo $m 'id')
            if (-not $mid) { $senzaId++; $mid = "senza-id-$senzaId" }
            $uso[$mid] = $u   # l'ultima riga di un messaggio ha i conti piu aggiornati
        }
    }
    foreach ($u in $uso.Values) {
        foreach ($coppia in @(@('TokenIn', 'input_tokens'), @('TokenOut', 'output_tokens'), @('CacheLetti', 'cache_read_input_tokens'), @('CacheScritti', 'cache_creation_input_tokens'))) {
            $v = Get-Campo $u $coppia[1]
            if ($null -ne $v) { $r[$coppia[0]] += [int64]$v }
        }
    }
    $r.Azioni = @($azioni | Select-Object -Last $Ultime)
    $r.Token = Get-TotaleToken ([pscustomobject]$r)
    [pscustomobject]$r
}

# I file dello stream di una sessione in ordine di lettura: prima il primo lancio, poi le riprese r1, r2... (in ordine
# numerico, non per nome: r10 viene dopo r2). Ogni elemento porta il numero della ripresa (0 = il primo lancio).
function Get-FileStreamSessione([string]$CartellaDati, [string]$Id) {
    $dir = Join-Path $CartellaDati 'sessioni'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $trovati = foreach ($f in Get-ChildItem -LiteralPath $dir -File -Filter '*.jsonl') {
        if ($f.Name -eq "$Id.jsonl") { [pscustomobject]@{ N = 0; File = $f } }
        elseif ($f.Name -match ('^' + [regex]::Escape($Id) + '\.r(\d+)\.jsonl$')) { [pscustomobject]@{ N = [int]$Matches[1]; File = $f } }
    }
    @($trovati | Sort-Object N)
}

# Il testo di un tool_result: una stringa, oppure un elenco di blocchi {type:text,text}.
function Get-TestoRisultato($Contenuto) {
    if ($Contenuto -is [string]) { return $Contenuto }
    $parti = foreach ($b in @($Contenuto)) {
        if ($b -is [string]) { $b }
        elseif ((Get-Campo $b 'type') -eq 'text') { [string](Get-Campo $b 'text') }
    }
    @($parti) -join "`n"
}

# I parametri di uno strumento, una riga per parametro: i comandi e i testi lunghi restano leggibili (un JSON li mostrerebbe con \n).
function Format-ParametriStrumento($Parametri) {
    if ($null -eq $Parametri) { return '' }
    $nomi = if ($Parametri -is [System.Collections.IDictionary]) { @($Parametri.Keys) } else { @($Parametri.PSObject.Properties.Name) }
    $righe = foreach ($n in $nomi) {
        $v = Get-Campo $Parametri $n
        $t = if ($v -is [string]) { $v } else { ConvertTo-Json $v -Depth 5 -Compress }
        "${n}: $t"
    }
    @($righe) -join "`n"
}

# Un risultato di strumento puo essere enorme (un file letto per intero): la pagina ne mostra l'inizio, e dice che e tagliato.
function Limit-TestoRisultato([string]$Testo, [int]$MaxCaratteri = 1500, [int]$MaxRighe = 15) {
    $tagliato = $false
    $righe = $Testo -split "`r?`n"
    if ($righe.Count -gt $MaxRighe) { $Testo = ($righe | Select-Object -First $MaxRighe) -join "`n"; $tagliato = $true }
    if ($Testo.Length -gt $MaxCaratteri) { $Testo = $Testo.Substring(0, $MaxCaratteri); $tagliato = $true }
    [pscustomobject]@{ Testo = $Testo; Tagliato = $tagliato }
}

# Lo stream di una sessione, evento per evento, dal piu vecchio al piu recente, letto senza toccare i file: il testo
# dell'agente, gli strumenti con i parametri, i risultati (accorciati), l'esito finale. Le riprese sono separate da una
# riga 'ripresa N'. Restituisce gli ultimi -Ultimi eventi e quanti ne ha lasciati fuori.
function Get-EventiSessione {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string]$CartellaDati = (Get-CartellaDati), [int]$Ultimi = 300)
    $ev = [System.Collections.Generic.List[object]]::new()
    $nuovo = { param($Tipo, $Testo, $Nome = $null, $Tagliato = $false, $Errore = $false)
        [pscustomobject]@{ Tipo = $Tipo; Testo = $Testo; Nome = $Nome; Tagliato = [bool]$Tagliato; Errore = [bool]$Errore } }
    foreach ($f in @(Get-FileStreamSessione $CartellaDati $Id)) {
        if ($f.N -gt 0) { $ev.Add((& $nuovo 'ripresa' "ripresa $($f.N)")) }
        foreach ($riga in (Read-RigheCondivise $f.File.FullName)) {
            if ([string]::IsNullOrWhiteSpace($riga)) { continue }
            try { $e = $riga | ConvertFrom-Json } catch { continue }
            $tipo = Get-Campo $e 'type'
            if ($tipo -eq 'result') {
                $ev.Add((& $nuovo 'esito' ([string](Get-Campo $e 'result')) $null $false ((Get-Campo $e 'is_error') -eq $true)))
                continue
            }
            if ($tipo -notin 'assistant', 'user') { continue }
            foreach ($c in @(Get-Campo (Get-Campo $e 'message') 'content')) {
                switch (Get-Campo $c 'type') {
                    'text' { if ($tipo -eq 'assistant') { $ev.Add((& $nuovo 'testo' ([string](Get-Campo $c 'text')))) } }
                    'tool_use' {
                        # un Write o un Edit porta il file intero nei parametri: la pagina ne mostra l'inizio, con piu margine dei risultati
                        $l = Limit-TestoRisultato (Format-ParametriStrumento (Get-Campo $c 'input')) 3000 30
                        $ev.Add((& $nuovo 'strumento' $l.Testo ([string](Get-Campo $c 'name')) $l.Tagliato))
                    }
                    'tool_result' {
                        $l = Limit-TestoRisultato (Get-TestoRisultato (Get-Campo $c 'content'))
                        $ev.Add((& $nuovo 'risultato' $l.Testo $null $l.Tagliato ((Get-Campo $c 'is_error') -eq $true)))
                    }
                }
            }
        }
    }
    $saltati = [math]::Max(0, $ev.Count - $Ultimi)
    [pscustomobject]@{ Eventi = @($ev | Select-Object -Skip $saltati); Saltati = $saltati }
}

# Il processo e quello che abbiamo lanciato noi: stesso PID, stesso orario di avvio (con un margine per gli arrotondamenti),
# stesso eseguibile. Un PID da solo non basta: dopo un riavvio del PC puo essere di un altro programma.
function Test-SessioneViva {
    [CmdletBinding()]
    param([int]$ProcessoId, $Avvio)   # una stringa ISO o un DateTime: lo stato rilegge le date come DateTime
    if ($ProcessoId -le 0 -or "$Avvio" -eq '') { return $false }
    $atteso = ConvertTo-DataUtc $Avvio
    if ($null -eq $atteso) { return $false }
    $p = Get-Process -Id $ProcessoId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    try {
        if ($p.HasExited) { return $false }
        if ([math]::Abs(($p.StartTime.ToUniversalTime() - $atteso).TotalSeconds) -gt 2) { return $false }
        [string]$p.Path -ieq [string](Get-EseguibileClaude)
    }
    catch { $false }   # processo scomparso nel frattempo, o non leggibile: non e il nostro
}

# Chiude il processo e i suoi figli, solo se Test-SessioneViva lo riconosce. Senza -Avvio non tocca niente.
function Stop-Sessione {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('Pid')][int]$ProcessoId, $Avvio)   # $Pid e una variabile automatica: il nome vero e un altro
    if (-not (Test-SessioneViva -ProcessoId $ProcessoId -Avvio $Avvio)) { return }
    $p = Get-Process -Id $ProcessoId -ErrorAction SilentlyContinue
    if (-not $p) { return }
    try { $p.Kill($true) } catch { if (Get-Process -Id $ProcessoId -ErrorAction SilentlyContinue) { throw } }
}

# Le ultime righe del file degli errori dell'uscita piu recente della sessione: per il log, non per la card.
function Get-ErroriSessione {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string]$CartellaDati = (Get-CartellaDati), [int]$Righe = 5)
    $file = Get-FileDiUnaSessione $CartellaDati $Id
    if (-not $file) { return '' }
    $err = [IO.Path]::ChangeExtension($file.FullName, 'err')
    if (-not (Test-Path -LiteralPath $err)) { return '' }
    $r = @(Read-RigheCondivise $err | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    ($r | Select-Object -Last $Righe) -join "`n"
}

function Write-RegistroSessione {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Riga, [string]$CartellaDati = (Get-CartellaDati))
    Add-RigaRegistro (Join-Path $CartellaDati 'registro-sessioni.jsonl') ($Riga | ConvertTo-Json -Compress -Depth 5)
}

# Dove e arrivata una sessione (della card o di un mentore), dall'uscita e dal processo:
#   inCorso         si aspetta
#   senzaRisultato  da chiudere senza un esito: Causa 'silenzio' (viva ma ferma da troppo) o 'errore' (il processo non c'e piu)
#   finita          c'e un result da registrare
# Un result senza riga ESITO con il processo ancora vivo e una pausa, non la fine: claude -p lo scrive quando la sessione
# aspetta un comando lanciato in background, e riprende quando il comando finisce. Si tratta come una sessione in corso,
# con il controllo del silenzio.
# $TestViva e $Adesso li passa chi chiama: i test dello smistatore sostituiscono Test-SessioneViva nel loro scope, e una funzione di
# questo modulo non vedrebbe la sostituzione.
function Get-FaseSessione($Cfg, $S, $Esito, [scriptblock]$TestViva = { param($ProcessoId, $Avvio) Test-SessioneViva -ProcessoId $ProcessoId -Avvio $Avvio }, [datetime]$Adesso = [datetime]::UtcNow) {
    $senzaResult = $null -eq $Esito -or -not $Esito.Finita
    $senzaRiga = -not $senzaResult -and [string]::IsNullOrWhiteSpace([string]$Esito.Esito)
    $viva = $false
    if ($senzaResult -or $senzaRiga) { $viva = [bool](& $TestViva ([int]$S['pid']) (Get-Campo $S 'avvio')) }
    $fase = { param($f, $causa, $silenzio) [pscustomobject]@{ Fase = $f; Causa = $causa; Viva = $viva; Silenzio = $silenzio } }
    if (-not $senzaResult -and -not ($senzaRiga -and $viva)) { return & $fase 'finita' $null 0 }
    if (-not $viva) { return & $fase 'senzaRisultato' 'errore' 0 }
    $silenzio = [double]$Cfg.Limiti.silenzioMinuti
    $ultimo = if ($Esito -and $Esito.UltimoEvento) { ([datetime]$Esito.UltimoEvento).ToUniversalTime() } else { ConvertTo-DataUtc $S['inizio'] }
    if ($null -eq $ultimo -or ($Adesso - $ultimo).TotalMinutes -le $silenzio) { return & $fase 'inCorso' $null $silenzio }
    & $fase 'senzaRisultato' 'silenzio' $silenzio
}

function New-RigaRegistro([int]$Id, $Voce, $S, $Esito, [string]$Fine, [string]$EsitoTesto) {
    $r = [ordered]@{}
    $r['card'] = $Id; $r['repo'] = Get-Campo $Voce 'repo'; $r['ruolo'] = $S['ruolo']; $r['task'] = Get-Campo $S 'task'; $r['modello'] = $S['modello']; $r['sforzo'] = $S['sforzo']
    $r['sessione'] = $S['id']; $r['ripresa'] = [bool]$S['ripresa']; $r['inizio'] = $S['inizio']; $r['fine'] = $Fine
    $r['turni'] = $Esito.Turni; $r['esito'] = $EsitoTesto
    $r['tokenIn'] = $Esito.TokenIn; $r['tokenOut'] = $Esito.TokenOut; $r['cacheLetti'] = $Esito.CacheLetti; $r['cacheScritti'] = $Esito.CacheScritti
    $r
}

function Test-Riprendibile {
    [CmdletBinding()]
    param($UltimaSessione, $Limiti)
    if ($null -eq $UltimaSessione) { return $false }
    $id = Get-Campo $UltimaSessione 'id'
    $fine = Get-Campo $UltimaSessione 'fine'
    if ([string]::IsNullOrWhiteSpace("$id") -or $null -eq $fine -or "$fine" -eq '') { return $false }
    $soglia = Get-Campo $Limiti 'sogliaResumeMinuti'
    if ($null -eq $soglia -or [double]$soglia -le 0) { return $false }
    $d = ConvertTo-DataUtc $fine
    if ($null -eq $d) { return $false }
    ((Get-Date).ToUniversalTime() - $d).TotalMinutes -le [double]$soglia
}

Export-ModuleMember -Function Start-SessioneRuolo, Get-EsitoSessione, Get-ProgressoSessione, Get-EventiSessione, Get-TotaleToken, Stop-Sessione, Test-SessioneViva, Get-ErroriSessione,
    Write-RegistroSessione, Test-Riprendibile, Set-SessioniEseguibile, Get-ArgomentiClaude, Get-EseguibileClaude, Get-FaseSessione, New-RigaRegistro
