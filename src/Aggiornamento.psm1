Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Stato.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Worktree.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Impostazioni.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Sessioni.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Supervisione.psm1') -Global

# D53: l'aggiornamento automatico della suite (smistatore, vista, supervisore, hook, skill). Chi lo esegue e il supervisore (src/Supervisore.ps1),
# che chiama Invoke-AggiornamentoSuite a ogni giro. Il modulo ha due strati. Le regole pure (sopra): il canale, il confronto delle versioni,
# il passo da fare data l'osservazione, il parsing delle PR, la forma della versione. Lo strato di I/O (sotto): git, i processi, l'attivita
# pianificata dello smistatore, i file dati. Le regole si provano con osservazioni finte, l'I/O con repo git temporanei.
#
# La copia della suite non si tocca a mano e si avanza solo in fast-forward, mai su lavoro non committato. Le impostazioni locali (canale,
# aggiornamento automatico, override di limiti e supervisore) stanno fuori dal repo, in impostazioni.json (Impostazioni.psm1).
# Lo stato per chi lo guarda (la vista) sta in aggiornamento.json nella cartella dati; la richiesta "aggiorna adesso" della vista e il file
# aggiorna-suite.richiesta, nella stessa cartella.

# I file di config che una persona puo avere modificato a mano e che l'aggiornamento sa migrare in impostazioni.json: file -> sezione.
$script:FileMigrabili = [ordered]@{ 'config/limiti.json' = 'limiti'; 'config/supervisore.json' = 'supervisore' }
$script:TimeoutInstallazioneSecondi = 300
$script:TimeoutGiroProvaSecondi = 300
# Gli esiti che chiudono una richiesta "aggiorna adesso": l'unico che la tiene viva e l'attesa delle sessioni.
$script:EsitiCheTengonoLaRichiesta = @('inAttesaSessioni')

# ---- le regole pure ----------------------------------------------------------------------------------------------

# Il canale da seguire: quello delle impostazioni se c'e; altrimenti il ramo gia estratto nella copia se e main o develop; altrimenti main.
function Get-CanaleAggiornamento([string]$Canale, [string]$RamoEstratto) {
    $ammessi = Get-CanaliAmmessi
    if ($Canale -and $Canale -in $ammessi) { return $Canale }
    if ($RamoEstratto -in $ammessi) { return $RamoEstratto }
    'main'
}

# La prima versione (numeri separati da punti, almeno due) in un testo come "2.1.328 (Claude Code)" o "azure-cli 2.87.0 *"; $null se non c'e.
function ConvertTo-VersioneConfrontabile([string]$Testo) {
    if ($Testo -match '(\d+(?:\.\d+){1,3})') { try { return [version]$Matches[1] } catch { } }
    $null
}

# I requisiti non soddisfatti. $Requisiti e il contenuto di config/requisiti.json (nome -> versione minima), $Trovate nome -> testo della
# versione installata ($null se il programma non c'e o non risponde). Si controllano solo i nomi che chi chiama sa leggere (le chiavi di
# $Trovate): un requisito nuovo che questa versione non sa misurare non blocca niente. Ogni mancanza e @{ Nome; Richiesta; Trovata }.
function Get-RequisitiMancanti($Requisiti, [hashtable]$Trovate) {
    $mancanti = @()
    if ($null -eq $Requisiti) { return $mancanti }
    foreach ($p in @($Requisiti.PSObject.Properties)) {
        if (-not $Trovate.ContainsKey($p.Name)) { continue }
        $minima = ConvertTo-VersioneConfrontabile ([string]$p.Value)
        if ($null -eq $minima) { continue }
        $trovata = ConvertTo-VersioneConfrontabile ([string]$Trovate[$p.Name])
        if ($null -eq $trovata -or $trovata -lt $minima) {
            $mancanti += @{ Nome = $p.Name; Richiesta = [string]$p.Value; Trovata = $(if ($null -ne $trovata) { $trovata.ToString() } else { $null }) }
        }
    }
    $mancanti
}

# Le PR entrate nel canale, dai messaggi dei commit sul primo genitore (dal piu nuovo): "Merged PR <n>: <titolo>" (Azure DevOps con
# squash) e "Merge pull request <n> from <ramo> into <ramo>" (merge). Nella seconda forma il titolo e il ramo di partenza: e l'unico
# nome che il messaggio porta. Un commit che non e una PR (un merge a mano) non e una voce.
function ConvertFrom-RigheLogPr([string[]]$Righe) {
    foreach ($r in @($Righe | Where-Object { $_ })) {
        if ($r -match '^Merged PR (\d+):\s*(.*?)\s*$') { [pscustomobject]@{ Numero = [int]$Matches[1]; Titolo = $Matches[2] } }
        elseif ($r -match '^Merge pull request (\d+) from (\S+)') { [pscustomobject]@{ Numero = [int]$Matches[1]; Titolo = $Matches[2] } }
    }
}

# Come sta la copia rispetto all'origine del canale, dai quattro fatti di git: uguale, indietro (si puo avanzare in fast-forward), avanti
# (la copia ha commit che origine non ha) o divergente. senzaOrigine se origin/<canale> non c'e.
function Get-RelazioneCopia([string]$Testa, [string]$Punta, [bool]$TestaAntenataDellaPunta, [bool]$PuntaAntenataDellaTesta) {
    if (-not $Punta) { return 'senzaOrigine' }
    if ($Testa -eq $Punta) { return 'uguale' }
    if ($TestaAntenataDellaPunta) { return 'indietro' }
    if ($PuntaAntenataDellaTesta) { return 'avanti' }
    'divergente'
}

# I percorsi dall'uscita di `git status --porcelain` (anche i non tracciati: una copia con file suoi non si tocca). Un rinominato da due
# percorsi; le virgolette di git per i nomi con spazi si tolgono.
function Get-FileModificati([string]$Porcelain) {
    foreach ($riga in @($Porcelain -split "`r?`n" | Where-Object { $_.Trim() })) {
        if ($riga.Length -lt 4) { continue }
        foreach ($parte in ($riga.Substring(3) -split ' -> ')) { $parte.Trim().Trim('"') }
    }
}

# Il passo da fare. L'osservazione ($Oss) ha: Testa, Punta (commit di origin/<canale>, $null se non c'e), Scartato (l'ultimo commit scartato),
# Automatico, Richiesta ("aggiorna adesso" dalla vista), Relazione (Get-RelazioneCopia), Modifiche (i file di git status), e due blocchi di
# codice che costano (processi, disco) e si chiamano solo se si arriva a quel punto: Requisiti (le mancanze) e Occupazione (@{ Sessioni; Processi }).
# RamoCanaleLocaleDivergente: il ramo locale con il nome del canale esiste, non e quello estratto e non e antenato di origin/<canale>.
# Ritorna @{ Azione = niente|avanza; Esito; Migra; File; Requisiti; Occupazione }. Esito e il nome da scrivere in aggiornamento.json;
# 'invariato' lascia l'esito di prima. I casi sono in ordine: il primo che vale decide.
function Get-PassoAggiornamento($Oss) {
    $niente = {
        param($Esito, $Extra = @{})
        $r = @{ Azione = 'niente'; Esito = $Esito; Migra = $false; File = @(); Requisiti = @(); Occupazione = $null }
        foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] }
        $r
    }
    if ($Oss.Relazione -eq 'senzaOrigine') { return (& $niente 'invariato') }
    if ($Oss.Relazione -eq 'uguale') { return (& $niente 'aggiornato') }
    # lo stesso commit che gia ha fallito non si riprova finche origine non va oltre; una richiesta esplicita "Aggiorna adesso" lo riprova
    if ($Oss.Scartato -and [string]$Oss.Scartato -eq [string]$Oss.Punta -and -not $Oss.Richiesta) { return (& $niente 'invariato') }
    # una copia avanti o divergente non ha una versione "nuova" da prendere: lo si dice con o senza automatico e con o senza richiesta
    if ($Oss.Relazione -eq 'avanti') { return (& $niente 'copiaAvanti') }
    if ($Oss.Relazione -eq 'divergente') { return (& $niente 'divergente') }
    if (-not ($Oss.Automatico -or $Oss.Richiesta)) { return (& $niente 'daAggiornare') }
    # passare al ramo del canale con `checkout -B` lo porta su origin: se il ramo locale di quel nome ha commit che origin non ha, li perderebbe
    if ([bool](Get-Campo $Oss 'RamoCanaleLocaleDivergente')) { return (& $niente 'ramoCanaleDivergente') }
    $file = @($Oss.Modifiche | Where-Object { $_ })
    $migra = $false
    if ($file.Count -gt 0) {
        if (@($file | Where-Object { $_ -notin $script:FileMigrabili.Keys }).Count -gt 0) { return (& $niente 'modificheLocali' @{ File = $file }) }
        $migra = $true
    }
    $mancanti = @(& $Oss.Requisiti)
    if ($mancanti.Count -gt 0) { return (& $niente 'requisitiMancanti' @{ Requisiti = $mancanti }) }
    $occ = & $Oss.Occupazione
    if ([int]$occ.Sessioni -gt 0 -or [int]$occ.Processi -gt 0) { return (& $niente 'inAttesaSessioni' @{ Occupazione = $occ }) }
    @{ Azione = 'avanza'; Esito = 'aggiornato'; Migra = $migra; File = $file; Requisiti = @(); Occupazione = $occ }
}

# Il prossimo controllo con fetch e dovuto? Subito se c'e una richiesta dalla vista, se non c'e un controllo di prima o se sono passati i minuti.
function Test-ControlloDovuto($UltimoControllo, [int]$Minuti, [datetime]$Adesso, [bool]$Richiesta) {
    if ($Richiesta) { return $true }
    $u = ConvertTo-DataUtc $UltimoControllo
    if ($null -eq $u) { return $true }
    ($Adesso.ToUniversalTime() - $u).TotalMinutes -ge $Minuti
}

# L'attesa delle sessioni dura da troppo? $Da e l'inizio dell'attesa.
function Test-AttesaOltre($Da, [datetime]$Adesso, [double]$Ore) {
    $d = ConvertTo-DataUtc $Da
    if ($null -eq $d) { return $false }
    ($Adesso.ToUniversalTime() - $d).TotalHours -ge $Ore
}

# La versione come si legge: "main 4f3a2b1 (25/11/2026)". $Versione e @{ canale; hash; data } come in aggiornamento.json.
function Format-VersioneSuite($Versione) {
    if ($null -eq $Versione) { return 'non nota' }
    $hash = [string](Get-Campo $Versione 'hash')
    $d = ConvertTo-DataUtc (Get-Campo $Versione 'data')
    $data = if ($d) { $d.ToLocalTime().ToString('dd/MM/yyyy', [cultureinfo]::InvariantCulture) } else { 'data non nota' }
    "$([string](Get-Campo $Versione 'canale')) $hash ($data)".Trim()
}

# Dall'indirizzo di origin (https://<org>.visualstudio.com/<progetto>/_git/<repo>, con o senza utente) l'indirizzo base del repo, da cui si
# fanno i link alle PR; $null se non ha la forma di un repo di Azure DevOps.
function ConvertTo-UrlRepoAdo([string]$Origine) {
    if ($Origine -notmatch '^(https://)(?:[^/@]+@)?([^/]+/.+?/_git/[^/]+?)/?$') { return $null }
    $Matches[1] + $Matches[2]
}

# I file di config che l'aggiornamento migra in impostazioni.json (nome del file -> sezione).
function Get-FileMigrabili { $script:FileMigrabili }

# ---- i file dati -------------------------------------------------------------------------------------------------

function Get-PercorsoAggiornamento([string]$CartellaDati = (Get-CartellaDati)) { Join-Path $CartellaDati 'aggiornamento.json' }
function Get-PercorsoRichiestaAggiornamento([string]$CartellaDati = (Get-CartellaDati)) { Join-Path $CartellaDati 'aggiorna-suite.richiesta' }

# La richiesta "aggiorna adesso" della vista: un file con l'ora. Il supervisore la legge a ogni giro e la toglie quando ha un esito.
function Write-RichiestaAggiornamento([string]$CartellaDati = (Get-CartellaDati), [datetime]$Adesso = [datetime]::UtcNow) {
    if (-not (Test-Path -LiteralPath $CartellaDati)) { New-Item -ItemType Directory -Path $CartellaDati -Force | Out-Null }
    [IO.File]::WriteAllText((Get-PercorsoRichiestaAggiornamento $CartellaDati), $Adesso.ToUniversalTime().ToString('o'), [Text.UTF8Encoding]::new($false))
}

# Lo stato dell'aggiornamento per chi lo guarda (la vista): un file che manca o non si legge e uno stato vuoto, non un errore.
function Read-StatoAggiornamento([string]$CartellaDati = (Get-CartellaDati)) {
    try { Get-Stato -Percorso (Get-PercorsoAggiornamento $CartellaDati) -Tentativi 3 -AttesaMs 50 } catch { @{} }
}

# ---- l'I/O: git --------------------------------------------------------------------------------------------------

# Ramo, commit, data del commit e file modificati della copia.
function Get-CopiaLocale([string]$Radice) {
    $st = Invoke-Git $Radice 'status', '--porcelain' -ConsentiErrore
    if ($st.Codice -ne 0) { throw "git status in ${Radice} e fallito: $($st.Uscita)" }
    [pscustomobject]@{
        Ramo = Invoke-Git $Radice 'rev-parse', '--abbrev-ref', 'HEAD'
        Testa = Invoke-Git $Radice 'rev-parse', 'HEAD'
        Data = Invoke-Git $Radice 'log', '-1', '--format=%cI', 'HEAD'
        Modifiche = @(Get-FileModificati ([string]$st.Uscita))
    }
}

function Get-PuntaOrigine([string]$Radice, [string]$Canale) {
    $h = Invoke-Git $Radice 'rev-parse', '--verify', '--quiet', "refs/remotes/origin/$Canale^{commit}" -ConsentiErrore
    if ($h.Codice -ne 0 -or -not $h.Uscita.Trim()) { return $null }
    [pscustomobject]@{ Hash = $h.Uscita.Trim(); Data = (Invoke-Git $Radice 'log', '-1', '--format=%cI', "refs/remotes/origin/$Canale") }
}

function Test-Antenato([string]$Radice, [string]$Antenato, [string]$Discendente) {
    (Invoke-Git $Radice 'merge-base', '--is-ancestor', $Antenato, $Discendente -ConsentiErrore).Codice -eq 0
}

function Get-PrInArrivo([string]$Radice, [string]$Canale) {
    $righe = Invoke-Git $Radice 'log', "HEAD..refs/remotes/origin/$Canale", '--first-parent', '--format=%s'
    @(ConvertFrom-RigheLogPr @($righe -split "`r?`n"))
}

# I requisiti della versione nuova, letti dal commit di origine senza estrarlo. Nessun file: nessun requisito ($null).
function Get-RequisitiVersioneNuova([string]$Radice, [string]$Canale) {
    $r = Invoke-Git $Radice 'show', "refs/remotes/origin/${Canale}:config/requisiti.json" -ConsentiErrore
    if ($r.Codice -ne 0) { return $null }
    try { $r.Uscita | ConvertFrom-Json } catch { throw "config/requisiti.json di origin/$Canale non e un JSON valido: $($_.Exception.Message)" }
}

# ---- l'I/O: processi, attivita pianificata, versioni installate ----------------------------------------------------

# L'attivita dello smistatore si disabilita solo se e abilitata e si riabilita solo se l'ha disabilitata questo codice: una disabilitata da
# una persona resta com'e. Ritorna $true se l'ha disabilitata. Senza l'attivita (PC senza pianificazione) non fa niente.
function Disable-AttivitaSmistatore {
    $o = Get-OperazionePianificata
    $t = Get-ScheduledTask -TaskPath $o.Percorso -TaskName $o.Nome -ErrorAction SilentlyContinue
    if ($null -eq $t -or [string]$t.State -eq 'Disabled') { return $false }
    Disable-ScheduledTask -TaskPath $o.Percorso -TaskName $o.Nome -ErrorAction Stop | Out-Null
    $true
}

function Enable-AttivitaSmistatore {
    $o = Get-OperazionePianificata
    Enable-ScheduledTask -TaskPath $o.Percorso -TaskName $o.Nome -ErrorAction Stop | Out-Null
}

# Cosa tiene ferma la copia: le card con una sessione aperta (la stessa definizione della vista, Get-IdCardConSessione), i mentori in corso
# (stato.json), le sessioni di diagnosi del supervisore (supervisore.json) e i giri dello smistatore di questa radice in esecuzione. Sono tutte
# sessioni di modelli che leggono gli script di questa copia. Uno stato che non si legge solleva: nel dubbio non si aggiorna.
function Get-OccupazioneSuite([string]$Radice, [string]$CartellaDati) {
    $stato = Get-Stato -Percorso (Join-Path $CartellaDati 'stato.json')
    $sup = Get-Stato -Percorso (Join-Path $CartellaDati (Split-Path -Leaf (Get-PercorsoSupervisorePredefinito)))
    $diagnosi = @(@(Get-Campo $sup 'sessioniDiagnosi') | Where-Object { $null -ne $_ }).Count
    [pscustomobject]@{ Sessioni = (@(Get-IdCardConSessione $stato).Count + (Get-NumeroMentoriInCorso $stato) + $diagnosi); Processi = @(Get-ProcessiSmistatoreRadice $Radice).Count }
}

# Le versioni installate dei programmi che i requisiti possono chiedere: nome -> testo della versione, $null se non c'e. Un nome che non si
# sa leggere non c'e nella tabella (Get-RequisitiMancanti lo ignora).
function Get-VersioniInstallate {
    $v = @{ powershell = $PSVersionTable.PSVersion.ToString(); claude = $null }
    # claude si trova come lo trovano le sessioni (Get-EseguibileClaude, Sessioni.psm1): lo shim di npm non e l'eseguibile vero
    try { $v.claude = (@(& (Get-EseguibileClaude) --version 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() }) | Select-Object -First 1) }
    catch { $v.claude = $null }
    $v
}

# Un processo figlio `pwsh -NoProfile -File <script> <argomenti>` con un tempo massimo: scaduto, si chiude con i suoi figli. Ritorna
# @{ Codice; Timeout; Uscita } (Uscita: la coda dell'uscita standard e degli errori).
function Invoke-ProcessoFiglio([Parameter(Mandatory)][string]$Script, [string[]]$Argomenti = @(), [Parameter(Mandatory)][int]$TimeoutSecondi) {
    $pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $psi = [Diagnostics.ProcessStartInfo]::new($pwsh)
    foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $Script) + @($Argomenti)) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    $finito = $p.WaitForExit($TimeoutSecondi * 1000)
    if (-not $finito) { try { $p.Kill($true) } catch { }; [void]$p.WaitForExit(5000) }
    $testo = (@($out.Result, $err.Result) -join "`n").Trim()
    if ($testo.Length -gt 2000) { $testo = $testo.Substring($testo.Length - 2000) }
    [pscustomobject]@{ Codice = $(if ($finito) { $p.ExitCode } else { -1 }); Timeout = (-not $finito); Uscita = $testo }
}

# ---- l'I/O: la migrazione e l'avanzamento ------------------------------------------------------------------------------

# Se le uniche modifiche locali sono in config/limiti.json e config/supervisore.json: le chiavi di primo livello che differiscono da HEAD
# vanno in impostazioni.json (senza sovrascrivere un override gia presente), poi il file si ripristina com'e in HEAD.
# La migrazione e definitiva: se poi l'aggiornamento torna indietro il file resta ripristinato, perche la versione a cui si torna ha gia D53
# e legge impostazioni.json.
function Invoke-MigrazioneImpostazioni([string]$Radice, [string]$CartellaDati, [string[]]$File) {
    foreach ($f in $File) {
        $sezione = $script:FileMigrabili[$f]
        $percorso = Join-Path $Radice $f
        $testo = [IO.File]::ReadAllText($percorso, [Text.UTF8Encoding]::new($false))
        $attuale = try { $testo | ConvertFrom-Json } catch { throw "$f ha modifiche locali che non sono un JSON valido ($($_.Exception.Message)): non le migro" }
        $inHead = Invoke-Git $Radice 'show', "HEAD:$f"
        $diverse = Get-ChiaviDiverse -Attuale $attuale -Riferimento ($inHead | ConvertFrom-Json)
        if ($diverse.Count -gt 0) { [void](Add-OverrideNuovi -Sezione $sezione -Valori ([hashtable]$diverse) -CartellaDati $CartellaDati) }
        [void](Invoke-Git $Radice 'checkout', '--', $f)
    }
}

# Riporta la copia com'era prima dell'avanzamento: sullo stesso ramo `reset --keep` (la copia era pulita), altrimenti torna al ramo di prima
# (o al commit, se non era su un ramo) e rimette il ramo del canale dov'era ($CanalePrima: il suo commit, o $null se non esisteva).
function Restore-CopiaPrecedente([string]$Radice, [string]$Prima, [string]$RamoPrima, [string]$Canale, [string]$CanalePrima) {
    if ($RamoPrima -eq $Canale) { [void](Invoke-Git $Radice 'reset', '--keep', $Prima); return }
    if ($RamoPrima -eq 'HEAD') { [void](Invoke-Git $Radice 'checkout', '--detach', $Prima) }
    else { [void](Invoke-Git $Radice 'checkout', $RamoPrima) }
    if ($CanalePrima) { [void](Invoke-Git $Radice 'branch', '-f', $Canale, $CanalePrima) }
    elseif ((Invoke-Git $Radice 'rev-parse', '--verify', '--quiet', "refs/heads/$Canale" -ConsentiErrore).Codice -eq 0) { [void](Invoke-Git $Radice 'branch', '-D', $Canale) }
}

# La radice come la vuole Install-Attrezzi.ps1: con le barre in avanti, come sta scritta negli hook di settings.json.
function ConvertTo-RadiceInstallazione([string]$Radice) { $Radice.Replace('\', '/') }

# I passi di verifica di una versione appena avanzata, come processi figli della copia aggiornata: l'installazione e un giro a vuoto dello
# smistatore e del supervisore (con -WhatIf escono con codice diverso da 0 se il giro si interrompe). Ritorna $null se vanno, altrimenti il testo dell'errore.
function Test-VersioneInstallata([string]$Radice) {
    $i = Invoke-ProcessoFiglio -Script (Join-Path $Radice 'setup/Install-Attrezzi.ps1') -Argomenti @('-Regole', '-Hook', '-Pianificazione', '-RadicePrincipale', (ConvertTo-RadiceInstallazione $Radice)) -TimeoutSecondi $script:TimeoutInstallazioneSecondi
    if ($i.Timeout) { return "Install-Attrezzi.ps1 non e finito entro $($script:TimeoutInstallazioneSecondi) secondi" }
    if ($i.Codice -ne 0) { return "Install-Attrezzi.ps1 e uscito con codice $($i.Codice): $($i.Uscita)" }
    $g = Invoke-ProcessoFiglio -Script (Join-Path $Radice 'src/Smistatore.ps1') -Argomenti @('-WhatIf') -TimeoutSecondi $script:TimeoutGiroProvaSecondi
    if ($g.Timeout) { return "il giro di prova dello smistatore non e finito entro $($script:TimeoutGiroProvaSecondi) secondi" }
    if ($g.Codice -ne 0) { return "il giro di prova dello smistatore e uscito con codice $($g.Codice): $($g.Uscita)" }
    # il supervisore della copia nuova: con -WhatIf non scrive niente e non aggiorna (Invoke-AggiornamentoSuite -WhatIf non fa fetch ne avanza)
    $s = Invoke-ProcessoFiglio -Script (Join-Path $Radice 'src/Supervisore.ps1') -Argomenti @('-WhatIf') -TimeoutSecondi $script:TimeoutGiroProvaSecondi
    if ($s.Timeout) { return "il giro di prova del supervisore non e finito entro $($script:TimeoutGiroProvaSecondi) secondi" }
    if ($s.Codice -ne 0) { return "il giro di prova del supervisore e uscito con codice $($s.Codice): $($s.Uscita)" }
    $null
}

# ---- il giro dell'aggiornamento ----------------------------------------------------------------------------------

# La versione come si salva in aggiornamento.json: canale, hash corto (7), data del commit.
function ConvertTo-VersioneStato($Canale, $Hash, $Data) {
    [ordered]@{ canale = [string]$Canale; hash = ([string]$Hash).Substring(0, [math]::Min(7, ([string]$Hash).Length)); data = [string]$Data }
}

# Un giro: controlla se c'e una versione nuova e, se le regole dicono di si, avanza la copia e verifica. Scrive aggiornamento.json (tranne
# con -WhatIf, dove dice soltanto cosa farebbe e non scrive niente, nemmeno i refs di git). $Log riceve (livello, messaggio), $Prova (messaggio)
# per -WhatIf, $Invia (tipo, dati) per Telegram: lo script del supervisore li collega al suo log e ai suoi topic.
# Ritorna lo stato scritto (o che si scriverebbe).
function Invoke-AggiornamentoSuite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Radice, [Parameter(Mandatory)][string]$CartellaDati, [Parameter(Mandatory)]$ConfigSupervisore,
        [datetime]$Adesso = [datetime]::UtcNow, [switch]$WhatIf,
        [scriptblock]$Log = { param($Livello, $Messaggio) }, [scriptblock]$Prova = { param($Messaggio) }, [scriptblock]$Invia = { param($Tipo, $Dati) }
    )
    $Adesso = $Adesso.ToUniversalTime()
    $percorso = Get-PercorsoAggiornamento $CartellaDati
    $richiestaFile = Get-PercorsoRichiestaAggiornamento $CartellaDati
    $stato = Get-Stato -Percorso $percorso
    $imp = Get-Impostazioni $CartellaDati
    $loc = Get-CopiaLocale $Radice
    $canale = Get-CanaleAggiornamento $imp.Canale $loc.Ramo
    $richiesta = Test-Path -LiteralPath $richiestaFile

    # il controllo con fetch ogni minutiControlloAggiornamenti, o subito se la vista l'ha chiesto; fra un controllo e l'altro si valuta lo
    # stesso quello che c'e (un'attesa di sessioni si scioglie al giro dopo, senza rete)
    $ultimoControllo = Get-Campo $stato 'ultimoControllo'; $erroreControllo = Get-Campo $stato 'erroreControllo'
    if (Test-ControlloDovuto $ultimoControllo ([int]$ConfigSupervisore.minutiControlloAggiornamenti) $Adesso $richiesta) {
        if ($WhatIf) { & $Prova 'aggiornamento: git fetch origin (controllo dovuto)' }
        else {
            $f = Invoke-Git $Radice 'fetch', 'origin', '--quiet' -ConsentiErrore
            $ultimoControllo = $Adesso.ToString('o')
            $erroreControllo = if ($f.Codice -eq 0) { $null } else { "git fetch origin e fallito: $($f.Uscita)" }
            if ($erroreControllo) { & $Log 'AVVISO' "aggiornamento: $erroreControllo" }
        }
    }

    $punta = Get-PuntaOrigine $Radice $canale
    $relazione = Get-RelazioneCopia $loc.Testa $(if ($punta) { $punta.Hash } else { $null }) `
        $(if ($punta) { Test-Antenato $Radice $loc.Testa $punta.Hash } else { $false }) $(if ($punta) { Test-Antenato $Radice $punta.Hash $loc.Testa } else { $false })
    $pr = @()
    if ($relazione -eq 'indietro') {
        # l'indirizzo come e scritto in config, non quello riscritto da insteadOf (`remote get-url` lo espande)
        $base = ConvertTo-UrlRepoAdo (Invoke-Git $Radice 'config', '--get', 'remote.origin.url' -ConsentiErrore).Uscita.Trim()
        $pr = @(Get-PrInArrivo $Radice $canale | ForEach-Object { [ordered]@{ numero = $_.Numero; titolo = $_.Titolo; url = $(if ($base) { "$base/pullrequest/$($_.Numero)" } else { $null }) } })
    }

    # C4: il ramo locale con il nome del canale, se non e quello estratto, deve essere antenato di origin/<canale>
    $canaleLocale = $null; $canaleLocaleDivergente = $false
    if ($punta -and $loc.Ramo -ne $canale) {
        $h = Invoke-Git $Radice 'rev-parse', '--verify', '--quiet', "refs/heads/$canale^{commit}" -ConsentiErrore
        if ($h.Codice -eq 0 -and $h.Uscita.Trim()) {
            $canaleLocale = $h.Uscita.Trim()
            $canaleLocaleDivergente = -not (Test-Antenato $Radice $canaleLocale $punta.Hash)
        }
    }

    $oss = @{
        RamoCanaleLocaleDivergente = $canaleLocaleDivergente
        Testa = $loc.Testa; Punta = $(if ($punta) { $punta.Hash } else { $null }); Scartato = Get-Campo $stato 'scartato'
        Automatico = $imp.Automatico; Richiesta = $richiesta; Relazione = $relazione; Modifiche = $loc.Modifiche
        # blocchi senza chiusura: leggono Radice, canale e CartellaDati di questa funzione (visibili a chi e chiamato da qui) e restano nel modulo,
        # dove i test sostituiscono git, i processi e le versioni
        Requisiti = { @(Get-RequisitiMancanti (Get-RequisitiVersioneNuova $Radice $canale) (Get-VersioniInstallate)) }
        Occupazione = { Get-OccupazioneSuite $Radice $CartellaDati }
    }
    $passo = $null; $errore = $null
    try { $passo = Get-PassoAggiornamento $oss }
    catch { $errore = $_.Exception.Message; & $Log 'ERRORE' "aggiornamento: $errore" }

    $installata = ConvertTo-VersioneStato $canale $loc.Testa $loc.Data
    $disponibile = if ($punta -and $relazione -ne 'uguale') { ConvertTo-VersioneStato $canale $punta.Hash $punta.Data } else { $null }
    $esito = [ordered]@{ esito = 'errore'; quando = $Adesso.ToString('o'); errore = $errore }
    $scartato = Get-Campo $stato 'scartato'
    $attesaSegnalata = [bool](Get-Campo $stato 'attesaSegnalata')

    if ($passo) {
        $precedente = Get-Campo $stato 'ultimoEsito'
        switch ($passo.Esito) {
            'invariato' { $esito = if ($precedente) { $precedente } else { [ordered]@{ esito = 'aggiornato'; quando = $Adesso.ToString('o') } } }
            'modificheLocali' { $esito = [ordered]@{ esito = 'modificheLocali'; quando = $Adesso.ToString('o'); file = @($passo.File) } }
            'requisitiMancanti' {
                $esito = [ordered]@{ esito = 'requisitiMancanti'; quando = $Adesso.ToString('o')
                    elenco = @($passo.Requisiti | ForEach-Object { [ordered]@{ nome = $_.Nome; richiesta = $_.Richiesta; trovata = $_.Trovata } }) }
            }
            'inAttesaSessioni' {
                # l'attesa conta dal primo giro in cui c'e stata, finche il commit da installare e lo stesso
                $stessa = $precedente -and (Get-Campo $precedente 'esito') -eq 'inAttesaSessioni' -and (Get-Campo $precedente 'commit') -eq $punta.Hash
                # il file riletto da una data fa un DateTime: si rimette in testo ISO UTC, com'era scritto
                $dal = if ($stessa) { (ConvertTo-DataUtc (Get-Campo $precedente 'da')).ToString('o') } else { $Adesso.ToString('o') }
                $esito = [ordered]@{ esito = 'inAttesaSessioni'; quando = $Adesso.ToString('o'); da = $dal; commit = $punta.Hash
                    sessioni = [int]$passo.Occupazione.Sessioni; processi = [int]$passo.Occupazione.Processi
                    oltreSoglia = (Test-AttesaOltre $dal $Adesso ([double]$ConfigSupervisore.oreAttesaAggiornamento)) }
            }
            default { $esito = [ordered]@{ esito = $passo.Esito; quando = $Adesso.ToString('o') } }
        }
        # gia aggiornato e gia detto: la data dell'esito e quella dell'aggiornamento, non dell'ultimo controllo
        if ($passo.Esito -eq 'aggiornato' -and $precedente -and (Get-Campo $precedente 'esito') -eq 'aggiornato') { $esito = $precedente }
    }

    if ($passo -and $passo.Azione -eq 'avanza') {
        if ($WhatIf) {
            $migra = if ($passo.Migra) { ', migrando prima le modifiche locali di ' + (@($passo.File) -join ', ') + ' in impostazioni.json' } else { '' }
            & $Prova "aggiornamento: avanzerei $($loc.Ramo) da $($loc.Testa.Substring(0, 7)) a $($punta.Hash.Substring(0, 7)) (canale $canale)$migra, poi Install-Attrezzi.ps1 e un giro di prova dello smistatore"
        }
        else {
            $r = Invoke-Avanzamento -Radice $Radice -CartellaDati $CartellaDati -Canale $canale -Loc $loc -CanaleLocale $canaleLocale -Punta $punta -Passo $passo -Pr $pr -Adesso $Adesso -Log $Log -Invia $Invia
            $esito = $r.Esito
            if ($r.Scartato) { $scartato = $r.Scartato }
            if ($r.Esito.esito -eq 'aggiornato') { $attesaSegnalata = $false }
            $loc = Get-CopiaLocale $Radice
            $installata = ConvertTo-VersioneStato $canale $loc.Testa $loc.Data
            $punta2 = Get-PuntaOrigine $Radice $canale
            $disponibile = if ($punta2 -and $punta2.Hash -ne $loc.Testa) { ConvertTo-VersioneStato $canale $punta2.Hash $punta2.Data } else { $null }
            if ($r.Esito.esito -eq 'aggiornato') { $pr = @() }
        }
    }
    elseif ($WhatIf -and $passo) {
        $dettaglio = if ($passo.Esito -eq 'inAttesaSessioni') { " ($($passo.Occupazione.Sessioni) sessioni, $($passo.Occupazione.Processi) processi dello smistatore)" } else { '' }
        & $Prova "aggiornamento: $($passo.Esito)$dettaglio"
    }

    # attesa oltre soglia: lo dice la vista (oltreSoglia nell'esito) e Telegram una volta
    if (-not $WhatIf -and (Get-Campo $esito 'esito') -eq 'inAttesaSessioni' -and (Get-Campo $esito 'oltreSoglia') -and -not $attesaSegnalata) {
        try { & $Invia 'attesa' @{ A = Format-VersioneSuite $disponibile; Ore = [int]$ConfigSupervisore.oreAttesaAggiornamento }; $attesaSegnalata = $true }
        catch { & $Log 'ERRORE' "aggiornamento: avviso dell'attesa non mandato: $($_.Exception.Message)" }
    }

    $nuovo = [ordered]@{
        canale = $canale; automatico = [bool]$imp.Automatico; installata = $installata; disponibile = $disponibile
        ultimoControllo = $ultimoControllo; erroreControllo = $erroreControllo; ultimoEsito = $esito
        scartato = $scartato; attesaSegnalata = $attesaSegnalata; prInArrivo = @($pr)
    }
    if (-not $WhatIf) {
        Save-Stato -Stato $nuovo -Percorso $percorso
        # una richiesta si chiude con un esito, tranne l'attesa delle sessioni: finche aspetta resta, anche con l'automatico spento
        if ($richiesta -and (Get-Campo $esito 'esito') -notin $script:EsitiCheTengonoLaRichiesta) { Remove-Item -LiteralPath $richiestaFile -Force -ErrorAction SilentlyContinue }
    }
    $nuovo
}

# L'avanzamento vero. Ritorna @{ Esito; Scartato }: Esito e il record per aggiornamento.json. Disabilita l'attivita dello smistatore per il
# tempo dell'operazione e la riabilita in finally (solo se l'ha disabilitata lei); dopo aver disabilitato ricontrolla sessioni e processi,
# perche un giro poteva partire fra la decisione e la disabilitazione.
function Invoke-Avanzamento {
    [CmdletBinding()]
    param($Radice, $CartellaDati, $Canale, $Loc, $CanaleLocale, $Punta, $Passo, $Pr, [datetime]$Adesso, [scriptblock]$Log, [scriptblock]$Invia)
    $quando = $Adesso.ToString('o')
    $prima = $Loc.Testa; $ramoPrima = $Loc.Ramo
    $disabilitata = $false
    try {
        try {
            $disabilitata = Disable-AttivitaSmistatore
            $occ = Get-OccupazioneSuite $Radice $CartellaDati
            if ([int]$occ.Sessioni -gt 0 -or [int]$occ.Processi -gt 0) {
                & $Log 'INFO' 'aggiornamento: nel frattempo e partita una sessione, aspetto'
                return @{ Esito = [ordered]@{ esito = 'inAttesaSessioni'; quando = $quando; da = $quando; commit = $Punta.Hash; sessioni = [int]$occ.Sessioni; processi = [int]$occ.Processi; oltreSoglia = $false }; Scartato = $null }
            }
            if ($Passo.Migra) {
                try { Invoke-MigrazioneImpostazioni $Radice $CartellaDati @($Passo.File) }
                catch {
                    & $Log 'ERRORE' "aggiornamento: migrazione delle modifiche locali non riuscita: $($_.Exception.Message)"
                    return @{ Esito = [ordered]@{ esito = 'modificheLocali'; quando = $quando; file = @($Passo.File); errore = $_.Exception.Message }; Scartato = $null }
                }
                & $Log 'INFO' "aggiornamento: le modifiche locali di $(@($Passo.File) -join ', ') sono in impostazioni.json, i file sono ripristinati"
            }
            if ($ramoPrima -eq $Canale) { [void](Invoke-Git $Radice 'merge', '--ff-only', "refs/remotes/origin/$Canale") }
            else { [void](Invoke-Git $Radice 'checkout', '-B', $Canale, "refs/remotes/origin/$Canale") }
            $errore = Test-VersioneInstallata $Radice
        }
        catch { $errore = $_.Exception.Message }
        if ($errore) {
            $testaOra = (Invoke-Git $Radice 'rev-parse', 'HEAD' -ConsentiErrore).Uscita.Trim()
            $ramoOra = (Invoke-Git $Radice 'rev-parse', '--abbrev-ref', 'HEAD' -ConsentiErrore).Uscita.Trim()
            if ($testaOra -ne $prima -or $ramoOra -ne $ramoPrima) {
                try { Restore-CopiaPrecedente $Radice $prima $ramoPrima $Canale $CanaleLocale }
                catch {
                    # la copia non e tornata: non e verificata e non e quella di prima. Mai "aggiornato": errore, con dove e rimasta, e un avviso urgente
                    $ora = (Invoke-Git $Radice 'rev-parse', 'HEAD' -ConsentiErrore).Uscita.Trim()
                    $msg = "il ritorno alla versione di prima non e riuscito ($($_.Exception.Message)); copia lasciata a $ora, dopo l'errore: $errore"
                    & $Log 'ERRORE' "aggiornamento: $msg"
                    try { & $Invia 'copiaRotta' @{ Hash = $ora; Prima = $prima; Errore = $msg } } catch { & $Log 'ERRORE' "aggiornamento: avviso urgente non mandato: $($_.Exception.Message)" }
                    return @{ Esito = [ordered]@{ esito = 'errore'; quando = $quando; errore = $msg; copiaLasciataA = $ora; commitScartato = $Punta.Hash }; Scartato = $Punta.Hash }
                }
                # la versione di prima si reinstalla: l'installazione della nuova poteva aver cambiato giunzioni, hook o pianificazione
                $re = Invoke-ProcessoFiglio -Script (Join-Path $Radice 'setup/Install-Attrezzi.ps1') -Argomenti @('-Regole', '-Hook', '-Pianificazione', '-RadicePrincipale', (ConvertTo-RadiceInstallazione $Radice)) -TimeoutSecondi $script:TimeoutInstallazioneSecondi
                if ($re.Timeout -or $re.Codice -ne 0) { $errore += " | anche la reinstallazione della versione di prima non e riuscita: $(if ($re.Timeout) { 'timeout' } else { "codice $($re.Codice) $($re.Uscita)" })" }
            }
            & $Log 'ERRORE' "aggiornamento a $($Punta.Hash.Substring(0, 7)) fallito, tornato a $($prima.Substring(0, 7)): $errore"
            try { & $Invia 'fallito' @{ A = $Punta.Hash.Substring(0, 7); Errore = $errore } } catch { & $Log 'ERRORE' "aggiornamento: avviso del fallimento non mandato: $($_.Exception.Message)" }
            return @{ Esito = [ordered]@{ esito = 'fallitoTornatoIndietro'; quando = $quando; errore = $errore; commitScartato = $Punta.Hash }; Scartato = $Punta.Hash }
        }
        & $Log 'INFO' "aggiornamento: $($prima.Substring(0, 7)) -> $($Punta.Hash.Substring(0, 7)) (canale $Canale), $(@($Pr).Count) PR"
        try {
            & $Invia 'aggiornato' @{
                Da = (Format-VersioneSuite (ConvertTo-VersioneStato $Canale $prima $Loc.Data)); A = (Format-VersioneSuite (ConvertTo-VersioneStato $Canale $Punta.Hash $Punta.Data))
                Pr = @($Pr | ForEach-Object { [pscustomobject]@{ Numero = $_.numero; Titolo = $_.titolo; Url = $_.url } })
            }
        }
        catch { & $Log 'ERRORE' "aggiornamento: avviso dell'aggiornamento non mandato: $($_.Exception.Message)" }
        @{ Esito = [ordered]@{ esito = 'aggiornato'; quando = $quando; da = $prima.Substring(0, 7); a = $Punta.Hash.Substring(0, 7) }; Scartato = $null }
    }
    finally {
        if ($disabilitata) {
            try { Enable-AttivitaSmistatore }
            catch { & $Log 'ERRORE' "aggiornamento: l'attivita dello smistatore non si riabilita (riabilitala da Utilita di pianificazione): $($_.Exception.Message)" }
        }
    }
}

Export-ModuleMember -Function Get-CanaleAggiornamento, ConvertTo-VersioneConfrontabile, Get-RequisitiMancanti, ConvertFrom-RigheLogPr, Get-RelazioneCopia,
    Get-FileModificati, Get-PassoAggiornamento, Test-ControlloDovuto, Test-AttesaOltre, Format-VersioneSuite, ConvertTo-UrlRepoAdo, Get-FileMigrabili,
    Get-PercorsoAggiornamento, Get-PercorsoRichiestaAggiornamento, Write-RichiestaAggiornamento, Read-StatoAggiornamento,
    Get-CopiaLocale, Get-PuntaOrigine, Test-Antenato, Get-PrInArrivo, Get-RequisitiVersioneNuova, Disable-AttivitaSmistatore, Enable-AttivitaSmistatore,
    Get-OccupazioneSuite, Get-VersioniInstallate, Invoke-ProcessoFiglio, Invoke-MigrazioneImpostazioni, Restore-CopiaPrecedente, ConvertTo-RadiceInstallazione, Test-VersioneInstallata,
    Invoke-AggiornamentoSuite, Invoke-Avanzamento
