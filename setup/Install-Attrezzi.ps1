#requires -Version 7
<#
.SYNOPSIS
    Collega regole e hook degli attrezzi nella cartella ~/.claude dell'utente.
.DESCRIPTION
    -Regole  crea le giunzioni delle skill del sistema: <ClaudeDir>/skills/regole-sviluppo -> regole/ e
             <ClaudeDir>/skills/devops-agents -> skills/devops-agents/ di questo repo. Toglie la giunzione del nome
             che la skill aveva prima (card-agenti), se puntava a questo repo.
    -Hook    aggiunge a <ClaudeDir>/settings.json le cinque voci PreToolUse (senza toccare le altre chiavi, senza
             duplicare una voce gia presente) dopo aver salvato una copia del file accanto all'originale.
    -Pianificazione  registra l'operazione pianificata DevOps.Agents\Smistatore: lancia src/Smistatore.ps1 della
             working copy principale ogni intervalloMinuti (config/limiti.json), a utente collegato, senza finestra.
             Rilanciato, aggiorna l'operazione esistente. Registra anche DevOps.Agents\Vista: all'accesso
             dell'utente lancia src/Vista.ps1 -Html -Segui -Apri della stessa copia, senza finestra e senza limite di durata,
             cosi la pagina della vista c'e tutte le volte che c'e lo smistatore.
             Registra anche DevOps.Agents\Supervisore (D51): lancia src/Supervisore.ps1 ogni intervalloMinuti di
             config/supervisore.json, a utente collegato e senza finestra, come lo smistatore: controlla lo smistatore, la vista,
             le card, le pipeline, la quota e il PAT, e avvisa su Telegram solo per cio che serve.
    -RimuoviPianificazione  le toglie tutte e tre.
    -Pat     crea i due PAT di Azure DevOps (config/pat.json: scope, durata, nomi) e li salva cifrati con DPAPI in
             <ClaudeDir>/pat-smistatore.txt e pat-smistatore-lettura.txt, con la scadenza in pat-info.json. pat.txt resta
             tuo: -Pat non lo tocca. Gira per ultimo, cosi un login interrotto non blocca -Regole e -Hook.
             Serve az: se non c'e un login lo fa lo script e alla fine lo toglie; se c'era, lo lascia com'e. Rilanciato,
             crea PAT nuovi e revoca i vecchi. Il login az non resta mai: lo smistatore lavora coi PAT.
    -PatGitHub  salva i due token di GitHub per le aree con il codice su GitHub (config/mappa.json, "sorgente": "github"),
             cifrati come i PAT: <ClaudeDir>/pat-github.txt (lo smistatore: Contents, Pull requests, Checks e Actions in
             scrittura sui repo della mappa) e pat-github-lettura.txt (le sessioni, come GH_TOKEN: gli stessi permessi in
             lettura). GitHub non li crea via API: si creano a mano come fine-grained PAT e lo script li chiede senza mostrarli.
             -TokenGitHub e -TokenGitHubLettura servono ai test.
    -ClaudeDir serve ai test (cartella finta); di norma e' ~/.claude. Hook e operazione pianificata puntano sempre
    alla working copy principale, -RadicePrincipale.
#>
[CmdletBinding()]
param(
    [switch]$Hook,
    [switch]$Regole,
    [switch]$Pianificazione,
    [switch]$RimuoviPianificazione,
    [switch]$Pat,
    [switch]$PatGitHub,
    [securestring]$TokenGitHub,
    [securestring]$TokenGitHubLettura,
    [string]$ClaudeDir = (Join-Path $HOME '.claude'),
    # Scope, durata e nomi dei PAT; serve ai test.
    [string]$ConfigPat = (Join-Path $PSScriptRoot '../config/pat.json'),
    # La working copy principale: mai un worktree, che sparisce a PR mergiata.
    [string]$RadicePrincipale = 'C:/develop/GIT/DevOps.Agents',
    [string]$HooksDir = "$RadicePrincipale/hooks"
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

if (-not ($Hook -or $Regole -or $Pianificazione -or $RimuoviPianificazione -or $Pat -or $PatGitHub)) { throw 'Indica cosa installare: -Hook, -Regole, -Pianificazione, -RimuoviPianificazione, -Pat o -PatGitHub' }


if ($Regole) {
    $skills = Join-Path $ClaudeDir 'skills'
    if (-not (Test-Path -LiteralPath $skills)) { New-Item -ItemType Directory -Path $skills -Force | Out-Null }
    # nome della skill -> cartella del repo con il suo SKILL.md
    foreach ($voce in @(@('regole-sviluppo', 'regole'), @('devops-agents', 'skills/devops-agents'))) {
        $giunzione = Join-Path $skills $voce[0]
        $bersaglio = (Resolve-Path (Join-Path $repo $voce[1])).Path
        if (Test-Path -LiteralPath $giunzione) {
            $esistente = Get-Item -LiteralPath $giunzione -Force
            if ($esistente.LinkType -eq 'Junction' -and (Resolve-Path $esistente.Target).Path -eq $bersaglio) {
                Write-Host "Regole: giunzione gia presente ($giunzione)"
            }
            else { throw "Esiste gia $giunzione e non e la giunzione attesa verso ${bersaglio}: non la tocco" }
        }
        else {
            New-Item -ItemType Junction -Path $giunzione -Target $bersaglio | Out-Null
            Write-Host "Regole: creata la giunzione $giunzione -> $bersaglio"
        }
    }
    # Una skill rinominata lascia la giunzione del nome vecchio, che punta a una cartella sparita dal repo. Si toglie
    # solo se e una giunzione verso questo repo: una cartella con quel nome messa da altri non e nostra.
    # Get-Item e non Test-Path: per Test-Path una giunzione senza bersaglio non esiste.
    $radiceRepo = [IO.Path]::GetFullPath($repo).TrimEnd('\') + '\'
    foreach ($vecchio in @('card-agenti')) {
        $esistente = Get-Item -LiteralPath (Join-Path $skills $vecchio) -Force -ErrorAction SilentlyContinue
        if (-not $esistente -or $esistente.LinkType -ne 'Junction') { continue }
        $punta = [IO.Path]::GetFullPath([string]@($esistente.Target)[0])
        if (-not $punta.StartsWith($radiceRepo, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $esistente.Delete()
        Write-Host "Regole: tolta la giunzione del nome vecchio $($esistente.FullName)"
    }
}

if ($Hook) {
    $voci = @(
        @{ Matcher = 'Bash|PowerShell'; File = 'deny-commit-outside-worktree.ps1' }
        @{ Matcher = 'Write|Edit'; File = 'deny-secrets-in-repo.ps1' }
        @{ Matcher = 'Bash|PowerShell|Read'; File = 'deny-pat.ps1' }
        @{ Matcher = 'Bash|PowerShell'; File = 'deny-identita.ps1' }
        @{ Matcher = 'Bash|PowerShell|WebFetch'; File = 'deny-host-collaudo.ps1' }
    )
    $file = Join-Path $ClaudeDir 'settings.json'
    if (-not (Test-Path -LiteralPath $ClaudeDir)) { New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null }

    $settings = [ordered]@{}
    if (Test-Path -LiteralPath $file) {
        $testo = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($testo)) { $settings = $testo | ConvertFrom-Json -AsHashtable }
    }
    if (-not $settings.Contains('hooks') -or $null -eq $settings['hooks']) { $settings['hooks'] = [ordered]@{} }
    if (-not $settings['hooks'].Contains('PreToolUse') -or $null -eq $settings['hooks']['PreToolUse']) {
        $settings['hooks']['PreToolUse'] = @()
    }
    $pre = [System.Collections.Generic.List[object]]::new()
    foreach ($v in @($settings['hooks']['PreToolUse'])) { $pre.Add($v) }

    # Il confronto non guarda le barre ne' le maiuscole: C:\x e c:/X sono lo stesso percorso (D53: l'aggiornamento puo' rilanciare l'installazione
    # con la radice in forma Windows, e settings.json ha la forma con le barre in avanti). Le voci nuove si scrivono con le barre in avanti.
    $normalizza = { param($c) ([string]$c).Replace('\', '/').ToLowerInvariant() }
    $esistenti = @($pre | ForEach-Object { @($_['hooks']) } | ForEach-Object { & $normalizza $_['command'] })
    $aggiunte = 0
    foreach ($v in $voci) {
        $comando = "pwsh -NoProfile -File `"$($HooksDir.Replace('\', '/').TrimEnd('/'))/$($v.File)`""
        if ((& $normalizza $comando) -in $esistenti) { continue }
        $pre.Add([ordered]@{ matcher = $v.Matcher; hooks = @([ordered]@{ type = 'command'; command = $comando }) })
        $aggiunte++
    }

    if ($aggiunte -eq 0) { Write-Host 'Hook: tutte le voci erano gia presenti, niente da fare' }
    else {
        if (Test-Path -LiteralPath $file) {
            $copia = "$file.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')"
            Copy-Item -LiteralPath $file -Destination $copia
            Write-Host "Hook: copia di salvataggio in $copia"
        }
        $settings['hooks']['PreToolUse'] = @($pre)
        $json = $settings | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($file, $json, [Text.UTF8Encoding]::new($false))
        Write-Host "Hook: aggiunte $aggiunte voci a $file"
    }
}

# Registrare un'attivita che c'e gia con -Force la rifa abilitata. Una disabilitata da una persona (o dall'aggiornamento, D53, per il tempo della
# verifica) deve restare com'era: si guarda prima e si rimette dopo.
function Test-AttivitaDisabilitata([string]$Nome, [string]$Percorso) {
    $t = Get-ScheduledTask -TaskName $Nome -TaskPath $Percorso -ErrorAction SilentlyContinue
    [bool]($t -and "$($t.State)" -eq 'Disabled')
}
function Restore-AttivitaDisabilitata([string]$Nome, [string]$Percorso, [bool]$EraDisabilitata) {
    if ($EraDisabilitata) { Disable-ScheduledTask -TaskName $Nome -TaskPath $Percorso | Out-Null; Write-Host "Pianificazione: $Percorso$Nome era disabilitata e resta disabilitata" }
}

# L'operazione pianificata: stesso nome per registrarla e per toglierla.
Import-Module (Join-Path $repo 'src/Comune.psm1')
$percorsoOperazione = (Get-OperazionePianificata).Percorso
$nomeOperazione = (Get-OperazionePianificata).Nome
$nomeVista = (Get-NomiOperazioniPianificate).Vista
$nomeSupervisore = (Get-NomiOperazioniPianificate).Supervisore

if ($Pianificazione) {
    # Tutto si legge dalla copia principale: e l'unico posto da cui l'operazione girera, non il repo da cui si lancia
    # l'installazione (che puo essere un worktree con file diversi).
    $radice = $RadicePrincipale.TrimEnd('/', '\')
    $script = "$radice/src/Smistatore.ps1"
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Manca ${script}: la copia principale non ha ancora lo smistatore (il ramo non e in develop?). L'operazione non si registra: girerebbe ogni giro senza fare niente e senza un log."
    }
    # D53: gli intervalli sono quelli di config con gli override di impostazioni.json (cartella dati) sopra: lo stesso valore che leggono i servizi.
    Import-Module (Join-Path $repo 'src/Impostazioni.psm1')
    $minuti = [int](Read-ConfigConOverride -Radice $radice -Nome 'limiti').intervalloMinuti
    if ($minuti -lt 1) { throw "$radice/config/limiti.json: intervalloMinuti deve essere almeno 1" }
    # Percorso completo: l'Utilita di pianificazione non ha il PATH della shell dell'utente.
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    # Senza finestra: pwsh -WindowStyle Hidden apre comunque la console per un istante a ogni giro. conhost --headless
    # ospita il processo senza crearne nessuna.
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $azione = New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$pwsh`" -NoProfile -NonInteractive -File `"$script`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $minuti)
    # Interactive = solo a utente collegato, con i suoi permessi; niente password salvata.
    $principale = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    # IgnoreNew: se un giro e ancora in corso quello nuovo non parte (lo smistatore ha anche un suo blocco).
    $impostazioni = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    # -Force: se l'operazione esiste la sostituisce con questa definizione.
    $eraSmistatore = Test-AttivitaDisabilitata $nomeOperazione $percorsoOperazione
    Register-ScheduledTask -TaskName $nomeOperazione -TaskPath $percorsoOperazione -Action $azione -Trigger $trigger `
        -Principal $principale -Settings $impostazioni -Description 'Un giro dello smistatore: fa avanzare le card degli agenti.' -Force | Out-Null
    Restore-AttivitaDisabilitata $nomeOperazione $percorsoOperazione $eraSmistatore
    Write-Host "Pianificazione: $percorsoOperazione$nomeOperazione ogni $minuti min -> $script"

    # La vista: parte all'accesso, come lo smistatore che a utente collegato riprende i suoi giri, e resta accesa finche
    # l'utente e collegato (-Segui non finisce mai: niente limite di durata). Se e gia accesa non ne parte un'altra.
    $vista = "$radice/src/Vista.ps1"
    if (-not (Test-Path -LiteralPath $vista)) { throw "Manca ${vista}: la copia principale non ha la vista. Lo smistatore e registrato, la vista no." }
    $azioneVista = New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$pwsh`" -NoProfile -NonInteractive -File `"$vista`" -Html -Segui -Apri"
    $triggerVista = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $impostazioniVista = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    $eraVista = Test-AttivitaDisabilitata $nomeVista $percorsoOperazione
    Register-ScheduledTask -TaskName $nomeVista -TaskPath $percorsoOperazione -Action $azioneVista -Trigger $triggerVista `
        -Principal $principale -Settings $impostazioniVista -Description 'La vista degli agenti (http://localhost:18799/vista.html), accesa all''accesso.' -Force | Out-Null
    Restore-AttivitaDisabilitata $nomeVista $percorsoOperazione $eraVista
    Write-Host "Pianificazione: $percorsoOperazione$nomeVista all'accesso -> $vista"

    # Il supervisore (D51): attivita a parte, perche deve vedere anche uno smistatore che non gira. Stesso modo dello smistatore.
    $supervisore = "$radice/src/Supervisore.ps1"
    if (-not (Test-Path -LiteralPath $supervisore)) { throw "Manca ${supervisore}: la copia principale non ha ancora il supervisore (il ramo non e in develop?). Lo smistatore e la vista sono registrati, il supervisore no." }
    $minutiSup = [int](Read-ConfigConOverride -Radice $radice -Nome 'supervisore').intervalloMinuti
    if ($minutiSup -lt 1) { throw "$radice/config/supervisore.json: intervalloMinuti deve essere almeno 1" }
    $azioneSup = New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$pwsh`" -NoProfile -NonInteractive -File `"$supervisore`""
    $triggerSup = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $minutiSup)
    $eraSupervisore = Test-AttivitaDisabilitata $nomeSupervisore $percorsoOperazione
    Register-ScheduledTask -TaskName $nomeSupervisore -TaskPath $percorsoOperazione -Action $azioneSup -Trigger $triggerSup `
        -Principal $principale -Settings $impostazioni -Description 'Il supervisore: controlla smistatore, vista, card, pipeline, quota e PAT e avvisa su Telegram solo per cio che serve.' -Force | Out-Null
    Restore-AttivitaDisabilitata $nomeSupervisore $percorsoOperazione $eraSupervisore
    Write-Host "Pianificazione: $percorsoOperazione$nomeSupervisore ogni $minutiSup min -> $supervisore"
}

if ($RimuoviPianificazione) {
    foreach ($nome in $nomeOperazione, $nomeVista, $nomeSupervisore) {
        if (Get-ScheduledTask -TaskName $nome -TaskPath $percorsoOperazione -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $nome -TaskPath $percorsoOperazione -Confirm:$false
            Write-Host "Pianificazione: tolta $percorsoOperazione$nome"
        }
        else { Write-Host "Pianificazione: $percorsoOperazione$nome non c'era, niente da fare" }
    }
}

# -Pat per ultimo: apre il browser per il login di az, e un login interrotto non deve bloccare -Regole e -Hook.
if ($Pat) {
    Import-Module (Join-Path $repo 'src/Pat.psm1') -Force
    Install-Pat -ClaudeDir $ClaudeDir -PercorsoConfig $ConfigPat
}

# -PatGitHub: i token di GitHub non si creano via API. Si chiedono senza eco e si salvano cifrati come i PAT; niente si stampa.
if ($PatGitHub) {
    Import-Module (Join-Path $repo 'src/GitHub.psm1') -Force
    $chiedi = { param($gia, [string]$cosa) if ($gia) { $gia } else { Read-Host -AsSecureString "Incolla il token di GitHub $cosa (non si vede)" } }
    foreach ($t in @(
            @{ Tipo = 'smistatore'; Valore = (& $chiedi $TokenGitHub 'per lo smistatore (scrittura)') },
            @{ Tipo = 'lettura'; Valore = (& $chiedi $TokenGitHubLettura 'per le sessioni (sola lettura)') })) {
        $chiaro = [System.Net.NetworkCredential]::new('', $t.Valore).Password
        if ([string]::IsNullOrWhiteSpace($chiaro)) { throw "Token di GitHub ($($t.Tipo)) vuoto: niente salvato" }
        $dove = Get-PercorsoFilePatGitHub $t.Tipo -ClaudeDir $ClaudeDir
        Write-FilePat $dove $chiaro.Trim()
        Write-Host "PatGitHub: salvato $dove"
    }
}
