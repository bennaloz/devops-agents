Set-StrictMode -Version Latest

# D59: l'ambiente Docker di collaudo di una card. Solo gli effetti (lanciare docker, il processo che crea l'ambiente, leggerne
# l'esito): nessuna decisione, che sta in Decisioni.psm1. Docker si raggiunge da un solo punto, Invoke-Docker, che costruisce la
# riga di comando da `comandoDocker` di config/collaudo.json (oggi wsl -d <distro> --cd {cartella} -- docker, domani anche
# docker --context <server>): i test sostituiscono quel punto e non lanciano mai docker.
# Mai un valore di variabile d'ambiente nei log, nei commenti o nei file salvati: le variabili si ricalcolano dal file delle
# credenziali di prova (~/.claude/collaudo/<repo>.json) ogni volta che servono.

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global

function Get-CartellaCollaudo([string]$CartellaDati = (Get-CartellaDati)) { Join-Path $CartellaDati 'collaudo' }

# I file di una card: log di docker, esito del processo che crea l'ambiente, richiesta con cui il processo e partito.
function Get-PercorsiCollaudo([int]$Card, [string]$CartellaDati = (Get-CartellaDati)) {
    $dir = Get-CartellaCollaudo $CartellaDati
    [pscustomobject]@{
        Progetto = "card-$Card"
        Log = Join-Path $dir "card-$Card.log"
        Esito = Join-Path $dir "card-$Card.json"
        FileRichiesta = Join-Path $dir "card-$Card.richiesta.json"
    }
}

# Le credenziali di prova di un repo: chiave -> COLLAUDO_<CHIAVE>. Le legge anche Start-SessioneRuolo per il collaudatore: una
# lettura sola. Il messaggio di errore non cita il contenuto del file.
function Read-CredenzialiCollaudo([string]$File) {
    if (-not $File -or -not (Test-Path -LiteralPath $File)) { return @() }
    $cred = try { Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Il file delle credenziali di collaudo $File non e un JSON valido" }
    @(@($cred.PSObject.Properties | Where-Object { $null -eq $_.Value -or $_.Value -is [string] -or $_.Value -is [ValueType] }) | ForEach-Object {
        [pscustomobject]@{ Nome = 'COLLAUDO_' + ($_.Name.ToUpperInvariant() -replace '[^A-Z0-9_]', '_'); Valore = [string]$_.Value }
    })
}

# Tutto cio che serve a creare l'ambiente di una card, in una forma che si salva su file per il processo staccato (senza valori
# segreti: solo il percorso del file delle credenziali).
function New-RichiestaCollaudo {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Voce, [Parameter(Mandatory)][int]$Card, [Parameter(Mandatory)][int]$Slot,
        [Parameter(Mandatory)][string]$Cartella, [string]$FileCollaudo, [string]$CartellaDati = (Get-CartellaDati))
    $p = Get-PercorsiCollaudo $Card $CartellaDati
    $urls = Get-Campo $Voce.collaudo 'url'
    [pscustomobject]@{
        Card = $Card; Progetto = $p.Progetto; Slot = $Slot; Cartella = $Cartella
        Compose = [string]$Voce.collaudo.compose
        Porte = @($Voce.collaudo.porte | ForEach-Object { [string]$_ })
        Url = @(if ($urls) { $urls.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Nome = $_.Name; Porta = [string]$_.Value } } })
        Config = [pscustomobject]@{ comandoDocker = @($Config.comandoDocker | ForEach-Object { [string]$_ }); host = [string]$Config.host; portaBase = [int]$Config.portaBase; minutiCreazione = [double]$Config.minutiCreazione; minutiComandi = [double]$Config.minutiComandi }
        FileCredenziali = $FileCollaudo
        Log = $p.Log; Esito = $p.Esito; FileRichiesta = $p.FileRichiesta
    }
}

# portaBase + slot*100 + indice del nome in porte
function Get-PorteCollaudo($Richiesta) {
    $porte = [ordered]@{}
    $i = 0
    foreach ($nome in @($Richiesta.Porte)) { $porte[[string]$nome] = [int]$Richiesta.Config.portaBase + [int]$Richiesta.Slot * 100 + $i; $i++ }
    $porte
}

# nome dell'URL -> http://<host>:<porta>
function Get-UrlCollaudo($Richiesta) {
    $porte = Get-PorteCollaudo $Richiesta
    $url = [ordered]@{}
    foreach ($u in @($Richiesta.Url)) { $url[[string]$u.Nome] = "http://$($Richiesta.Config.host):$($porte[[string]$u.Porta])" }
    $url
}

# COLLAUDO_HOST, COLLAUDO_PORTA_<NOME> e le chiavi del file delle credenziali come COLLAUDO_<CHIAVE>
function Get-VariabiliCollaudo($Richiesta) {
    $v = [ordered]@{ COLLAUDO_HOST = [string]$Richiesta.Config.host }
    $porte = Get-PorteCollaudo $Richiesta
    foreach ($n in $porte.Keys) { $v["COLLAUDO_PORTA_$(($n.ToUpperInvariant() -replace '[^A-Z0-9_]', '_'))"] = [string]$porte[$n] }
    foreach ($c in @(Read-CredenzialiCollaudo $Richiesta.FileCredenziali)) { $v[$c.Nome] = $c.Valore }
    $v
}

# La riga di comando per docker: il comando configurato con {cartella} sostituita, poi gli argomenti. Senza {cartella} nel comando
# si lavora nella cartella indicata (cartella di lavoro del processo).
function Get-RigaComandoDocker($Config, [string]$Cartella, [string[]]$Argomenti) {
    $comando = @($Config.comandoDocker | ForEach-Object { [string]$_ })
    if ($comando.Count -eq 0) { throw "config/collaudo.json: 'comandoDocker' e vuoto" }
    $conCartella = @($comando | Where-Object { $_.Contains('{cartella}') }).Count -gt 0
    $parti = @($comando | ForEach-Object { $_.Replace('{cartella}', $Cartella) })
    [pscustomobject]@{
        File = $parti[0]
        Argomenti = @(@($parti | Select-Object -Skip 1) + @($Argomenti))
        CartellaLavoro = $(if ($conCartella) { $null } else { $Cartella })
    }
}

# L'unico punto che lancia docker. Le variabili vanno solo al processo figlio; wsl.exe non passa alla distro le variabili di Windows
# se non sono elencate in WSLENV, quindi i loro nomi (mai i valori) si aggiungono a WSLENV dello stesso figlio. L'uscita (standard
# e errori) si aggiunge a FileLog se c'e. Ritorna Codice, Uscita, Scaduto; lancia se il comando non si avvia.
function Invoke-Docker {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Cartella, [Parameter(Mandatory)][string[]]$Argomenti,
        [System.Collections.IDictionary]$Variabili, [string]$FileLog, [double]$TimeoutMinuti = 0)
    $riga = Get-RigaComandoDocker $Config $Cartella $Argomenti
    $psi = [System.Diagnostics.ProcessStartInfo]::new($riga.File)
    foreach ($a in $riga.Argomenti) { $psi.ArgumentList.Add([string]$a) }
    if ($riga.CartellaLavoro) { $psi.WorkingDirectory = $riga.CartellaLavoro }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    if ($Variabili -and $Variabili.Count -gt 0) {
        foreach ($k in $Variabili.Keys) { $psi.Environment[[string]$k] = [string]$Variabili[$k] }
        $wslenv = @(@($psi.Environment['WSLENV']) | Where-Object { $_ }) + @($Variabili.Keys | ForEach-Object { "$_/u" })
        $psi.Environment['WSLENV'] = $wslenv -join ':'
    }
    if ($FileLog) {
        $dir = Split-Path -Parent $FileLog
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::AppendAllText($FileLog, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') > $($riga.File) $($riga.Argomenti -join ' ')`n", [Text.UTF8Encoding]::new($false))
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    $ms = if ($TimeoutMinuti -gt 0) { [int][math]::Ceiling($TimeoutMinuti * 60000) } else { -1 }
    $scaduto = -not $p.WaitForExit($ms)
    if ($scaduto) { try { $p.Kill($true) } catch { $null = $_ }; $p.WaitForExit() }
    $uscita = ($out.Result + $err.Result).TrimEnd()
    if ($FileLog -and $uscita) { [IO.File]::AppendAllText($FileLog, $uscita + "`n", [Text.UTF8Encoding]::new($false)) }
    [pscustomobject]@{ Codice = $(if ($scaduto) { -1 } else { $p.ExitCode }); Uscita = $uscita; Scaduto = $scaduto }
}

function Add-RigaLogCollaudo([string]$Log, [string]$Riga) {
    $dir = Split-Path -Parent $Log
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::AppendAllText($Log, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Riga`n", [Text.UTF8Encoding]::new($false))
}

# Il lavoro del processo staccato (l'avvio nel file di esito e quello del processo stesso: la card lo confronta con quello che ha salvato, cosi un
# esito di un tentativo precedente non vale per quello nuovo): down -v (un ambiente rimasto di un tentativo prima), poi up -d --build --wait, con il tempo
# massimo di minutiCreazione. Scrive il file di esito (succeeded o failed) alla fine, qualunque cosa sia successa.
function Invoke-CreazioneAmbiente($Richiesta) {
    $esito = 'failed'
    try {
        $v = Get-VariabiliCollaudo $Richiesta
        $base = @('compose', '-p', [string]$Richiesta.Progetto, '-f', [string]$Richiesta.Compose)
        $giu = Invoke-Docker -Config $Richiesta.Config -Cartella $Richiesta.Cartella -Argomenti ($base + @('down', '-v')) -Variabili $v -FileLog $Richiesta.Log -TimeoutMinuti $Richiesta.Config.minutiComandi
        if ($giu.Codice -ne 0) { Add-RigaLogCollaudo $Richiesta.Log "compose down: codice $($giu.Codice), si prosegue" }
        $su = Invoke-Docker -Config $Richiesta.Config -Cartella $Richiesta.Cartella -Argomenti ($base + @('up', '-d', '--build', '--wait')) -Variabili $v -FileLog $Richiesta.Log -TimeoutMinuti $Richiesta.Config.minutiCreazione
        if ($su.Scaduto) { Add-RigaLogCollaudo $Richiesta.Log "compose up: tempo scaduto dopo $($Richiesta.Config.minutiCreazione) minuti" }
        elseif ($su.Codice -ne 0) { Add-RigaLogCollaudo $Richiesta.Log "compose up: codice $($su.Codice)" }
        else { $esito = 'succeeded' }
    }
    catch { Add-RigaLogCollaudo $Richiesta.Log "creazione dell'ambiente non riuscita: $($_.Exception.Message)" }
    $dir = Split-Path -Parent $Richiesta.Esito
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Richiesta.Esito + '.tmp'
    [IO.File]::WriteAllText($tmp, ([pscustomobject]@{ esito = $esito; avvio = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o'); fine = [datetime]::UtcNow.ToString('o'); log = $Richiesta.Log } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Richiesta.Esito -Force
}

# Avvia il processo staccato che crea l'ambiente (src/Collaudo-Crea.ps1) e ritorna pid e avvio (come una sessione), il log e gli URL.
function Start-AmbienteCollaudo {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Richiesta)
    $dir = Split-Path -Parent $Richiesta.FileRichiesta
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Remove-Item -LiteralPath $Richiesta.Esito -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Richiesta.Log -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($Richiesta.FileRichiesta, ($Richiesta | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $script = Join-Path $PSScriptRoot 'Collaudo-Crea.ps1'
    $pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $p = Start-Process -FilePath $pwsh -ArgumentList "-NoProfile -File `"$script`" -Richiesta `"$($Richiesta.FileRichiesta)`"" -WindowStyle Hidden -PassThru
    [pscustomobject]@{ Progetto = $Richiesta.Progetto; Pid = $p.Id; Avvio = $p.StartTime.ToUniversalTime().ToString('o'); Log = $Richiesta.Log; Url = (Get-UrlCollaudo $Richiesta) }
}

# Stato ed esito dell'ambiente di una card, nella forma del run di deploy (Stato inProgress/completed, Esito succeeded/failed) piu il
# percorso del log. Dal file di esito, se e del processo che la card ha salvato (stesso avvio); senza file, il processo vivo e in corso,
# morto e un fallimento, ma prima di dichiararlo si rilegge il file (il processo puo aver scritto l'esito e chiuso fra le due letture).
function Get-EsitoAmbienteCollaudo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Card, [string]$CartellaDati = (Get-CartellaDati), [int]$ProcessoId, $Avvio)
    $p = Get-PercorsiCollaudo $Card $CartellaDati
    $leggi = {
        if (-not (Test-Path -LiteralPath $p.Esito)) { return $null }
        $e = try { Get-Content -LiteralPath $p.Esito -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
        $atteso = ConvertTo-DataUtc $Avvio; $nelFile = ConvertTo-DataUtc (Get-Campo $e 'avvio')
        if ($null -ne $atteso -and $null -ne $nelFile -and [math]::Abs(($atteso - $nelFile).TotalSeconds) -gt 2) { return $null }
        [pscustomobject]@{ Stato = 'completed'; Esito = $(if ($e -and (Get-Campo $e 'esito') -eq 'succeeded') { 'succeeded' } else { 'failed' }); Log = $p.Log; Url = $null }
    }
    $fatto = & $leggi
    if ($fatto) { return $fatto }
    if ($ProcessoId -gt 0 -and (Test-ProcessoAvviato -ProcessoId $ProcessoId -Avvio $Avvio)) {
        return [pscustomobject]@{ Stato = 'inProgress'; Esito = $null; Log = $p.Log; Url = $null }
    }
    $fatto = & $leggi
    if ($fatto) { return $fatto }
    [pscustomobject]@{ Stato = 'completed'; Esito = 'failed'; Log = $p.Log; Url = $null }
}

# Ferma il processo che crea l'ambiente (e i suoi figli: docker, build), solo se e quello che abbiamo lanciato noi.
function Stop-ProcessoCollaudo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessoId, $Avvio)
    if (-not (Test-ProcessoAvviato -ProcessoId $ProcessoId -Avvio $Avvio)) { return }
    $p = Get-Process -Id $ProcessoId -ErrorAction SilentlyContinue
    if (-not $p) { return }
    try { $p.Kill($true) } catch { if (Get-Process -Id $ProcessoId -ErrorAction SilentlyContinue) { throw } }
}

# Butta l'ambiente: ferma il processo di creazione se vive (ProcessoId e Avvio dallo stato della card), poi compose -p <progetto> down -v e
# i volumi rimasti con l'etichetta del progetto (un down interrotto o un build fallito ne lasciano). Sincrono; vero se e andato, falso (con
# l'errore nel log del progetto) se docker non risponde o esce con un errore: mai un'eccezione, il giro non si ferma per questo.
function Remove-AmbienteCollaudo {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Progetto, [string]$CartellaDati = (Get-CartellaDati), [string]$Cartella,
        [int]$ProcessoId, $Avvio)
    $dir = Get-CartellaCollaudo $CartellaDati
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not $Cartella) { $Cartella = $dir }
    $log = Join-Path $dir "$Progetto.log"
    try {
        if ($ProcessoId -gt 0) { Stop-ProcessoCollaudo -ProcessoId $ProcessoId -Avvio $Avvio }
        $minuti = [double]$Config.minutiComandi
        $r = Invoke-Docker -Config $Config -Cartella $Cartella -Argomenti @('compose', '-p', $Progetto, 'down', '-v') -FileLog $log -TimeoutMinuti $minuti
        if ($r.Codice -ne 0) { Add-RigaLogCollaudo $log "compose down -v: codice $($r.Codice)"; return $false }
        $v = Invoke-Docker -Config $Config -Cartella $Cartella -Argomenti @('volume', 'ls', '-q', '--filter', "label=com.docker.compose.project=$Progetto") -FileLog $log -TimeoutMinuti $minuti
        if ($v.Codice -ne 0) { Add-RigaLogCollaudo $log "volume ls: codice $($v.Codice)"; return $false }
        $volumi = @(@($v.Uscita -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($volumi.Count -gt 0) {
            $rm = Invoke-Docker -Config $Config -Cartella $Cartella -Argomenti (@('volume', 'rm') + $volumi) -FileLog $log -TimeoutMinuti $minuti
            if ($rm.Codice -ne 0) { Add-RigaLogCollaudo $log "volume rm: codice $($rm.Codice)"; return $false }
        }
        $true
    }
    catch { Add-RigaLogCollaudo $log "compose down -v non riuscito: $($_.Exception.Message)"; $false }
}

# I progetti di collaudo che docker conosce: i nomi card-<id> dei contenitori con l'etichetta acme.collaudo e dei volumi con l'etichetta di
# progetto compose (un build fallito lascia volumi senza contenitori). Lancia se docker non risponde: lo smistatore ne fa un avviso nel log.
function Get-ProgettiCollaudo {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [string]$CartellaDati = (Get-CartellaDati))
    $dir = Get-CartellaCollaudo $CartellaDati
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $minuti = [double]$Config.minutiComandi
    $progetti = [System.Collections.Generic.List[string]]::new()
    foreach ($comando in @(
            @('ps', '-a', '--filter', 'label=acme.collaudo', '--format', '{{.Labels}}'),
            @('volume', 'ls', '--filter', 'label=com.docker.compose.project', '--format', '{{.Labels}}'))) {
        $r = Invoke-Docker -Config $Config -Cartella $dir -Argomenti $comando -TimeoutMinuti $minuti
        if ($r.Codice -ne 0) { throw "docker $($comando[0]) e uscito con codice $($r.Codice)" }
        foreach ($riga in @($r.Uscita -split "`r?`n")) { if ($riga -match 'com\.docker\.compose\.project=(card-\d+)(?:,|$)') { $progetti.Add($Matches[1]) } }
    }
    @($progetti | Sort-Object -Unique)
}

Export-ModuleMember -Function Get-CartellaCollaudo, Get-PercorsiCollaudo, Read-CredenzialiCollaudo, New-RichiestaCollaudo, Get-PorteCollaudo, Get-UrlCollaudo, Get-VariabiliCollaudo, Get-RigaComandoDocker, Invoke-Docker, Invoke-CreazioneAmbiente, Start-AmbienteCollaudo, Get-EsitoAmbienteCollaudo, Stop-ProcessoCollaudo, Remove-AmbienteCollaudo, Get-ProgettiCollaudo
