Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global

# Il file di stato locale dello smistatore: lettura, scrittura atomica, voci per card, revisioni nostre, mutex del giro.

function Get-PercorsoStatoPredefinito {
    Join-Path (Get-CartellaDati) 'stato.json'
}

function New-StatoCard {
    [ordered]@{
        ultimoCommento = 0; giriRevisione = 0; rosseDiFila = 0; rossaGestita = $null; rilanci = 0; rilancioDi = $null; completaPr = $null
        inAttesaPer = $null; attesaInEsame = $null; passateFatte = @(); avvisi = @(); ramo = $null; cartella = $null; prId = $null
        runId = $null; runDopoRev = $null; sessione = $null; ultimoRuolo = $null; ultimaSessione = @{}
        # le chiavi dei lanci del mentore gia fatti (D46): una correzione lo lancia una volta sola
        mentoriFatti = @()
        # le sessioni dei mentori in corso (id, pid, avvio, inizio...): non sono la sessione della card, che resta una sola
        mentori = @()
    }
}

# Save-Stato sostituisce il file (File.Replace): per un istante il file e bloccato, e chi lo legge proprio allora (la vista,
# card.ps1) riceve un errore di condivisione. Get-Stato riprova per un po' (Tentativi x AttesaMs); se il file resta bloccato
# lancia, e non restituisce mai uno stato vuoto: lo smistatore lo salverebbe al posto di quello vero.
function Get-Stato {
    [CmdletBinding()]
    param([string]$Percorso = (Get-PercorsoStatoPredefinito), [int]$Tentativi = 10, [int]$AttesaMs = 100)
    if (-not (Test-Path -LiteralPath $Percorso)) { return @{} }
    for ($i = 1; ; $i++) {
        try { $testo = [IO.File]::ReadAllText($Percorso, [Text.UTF8Encoding]::new($false)); break }
        catch [System.IO.FileNotFoundException] { return @{} }
        catch [System.IO.IOException] {
            if ($i -ge $Tentativi) { throw "stato.json non si legge dopo $Tentativi tentativi (bloccato da un altro processo?): $($_.Exception.Message)" }
            Start-Sleep -Milliseconds $AttesaMs
        }
    }
    if ([string]::IsNullOrWhiteSpace($testo)) { return @{} }
    $t = $testo | ConvertFrom-Json -AsHashtable
    if ($null -eq $t) { return @{} }
    $t
}

function Save-Stato {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Stato, [string]$Percorso = (Get-PercorsoStatoPredefinito))
    $cartella = Split-Path -Parent $Percorso
    if ($cartella -and -not (Test-Path -LiteralPath $cartella)) { New-Item -ItemType Directory -Path $cartella | Out-Null }
    $json = $Stato | ConvertTo-Json -Depth 10
    $tmp = "$Percorso.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Percorso) { [IO.File]::Replace($tmp, $Percorso, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $Percorso) }
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# D51: quota.json, nella cartella dati, accanto a stato.json. L'ultima lettura dell'uso delle finestre di token e la pausa
# per il limite: letta (ora), fiveHour e sevenDay (utilization, resetsAt), pausaFino (ISO UTC o null), finestraPausa.
# Stesso schema di Get-Stato/Save-Stato: lettura con ritentativi, scrittura per sostituzione del file. Il file che manca
# e una quota vuota.
function Get-PercorsoQuotaPredefinito {
    Join-Path (Get-CartellaDati) 'quota.json'
}

function Get-Quota {
    [CmdletBinding()]
    param([string]$Percorso = (Get-PercorsoQuotaPredefinito), [int]$Tentativi = 10, [int]$AttesaMs = 100)
    if (-not (Test-Path -LiteralPath $Percorso)) { return @{} }
    for ($i = 1; ; $i++) {
        try { $testo = [IO.File]::ReadAllText($Percorso, [Text.UTF8Encoding]::new($false)); break }
        catch [System.IO.FileNotFoundException] { return @{} }
        catch [System.IO.IOException] {
            if ($i -ge $Tentativi) { throw "quota.json non si legge dopo $Tentativi tentativi (bloccato da un altro processo?): $($_.Exception.Message)" }
            Start-Sleep -Milliseconds $AttesaMs
        }
    }
    if ([string]::IsNullOrWhiteSpace($testo)) { return @{} }
    $q = $testo | ConvertFrom-Json -AsHashtable
    if ($null -eq $q) { return @{} }
    $q
}

function Save-Quota {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Quota, [string]$Percorso = (Get-PercorsoQuotaPredefinito))
    Save-Stato -Stato $Quota -Percorso $Percorso
}

# Integrazione di D51 (2026-11-24): soglia-quota.json, nella cartella dati, accanto a quota.json. L'override che Titolare imposta dalla
# vista, valido solo fino al reset settimanale letto in quel momento: soglia (numero o null), ignoraRiserva (bool), fino (resetsAt, ISO UTC),
# impostata (ISO). Non sta nel repo per non sporcare la copia principale. Che sia valido o scaduto, e cosa puo contenere, lo decide
# Decisioni.psm1 (Get-SogliaQuotaEffettiva, Get-OverrideSogliaQuota): qui solo lettura e scrittura. Un file che manca e un override vuoto; uno che non si
# legge (JSON rotto, blocco oltre i tentativi) non lancia: da @{ errore = ... }, e chi decide lo ignora (vale limiti.json).
# L'unico posto dove si scrive il nome del file: chi ha una cartella dati sua (smistatore, supervisore, vista) la passa.
function Get-PercorsoSogliaQuotaPredefinito([string]$Cartella = (Get-CartellaDati)) {
    Join-Path $Cartella 'soglia-quota.json'
}

function Get-SogliaQuota {
    [CmdletBinding()]
    param([string]$Percorso = (Get-PercorsoSogliaQuotaPredefinito), [int]$Tentativi = 10, [int]$AttesaMs = 100)
    if (-not (Test-Path -LiteralPath $Percorso)) { return @{} }
    for ($i = 1; ; $i++) {
        try { $testo = [IO.File]::ReadAllText($Percorso, [Text.UTF8Encoding]::new($false)); break }
        catch [System.IO.FileNotFoundException] { return @{} }
        catch [System.IO.IOException] {
            if ($i -ge $Tentativi) { return @{ errore = "soglia-quota.json non si legge dopo $Tentativi tentativi: $($_.Exception.Message)" } }
            Start-Sleep -Milliseconds $AttesaMs
        }
    }
    if ([string]::IsNullOrWhiteSpace($testo)) { return @{} }
    try { $o = $testo | ConvertFrom-Json -AsHashtable } catch { return @{ errore = "soglia-quota.json non e un JSON valido: $($_.Exception.Message)" } }
    if ($null -eq $o) { return @{} }
    if ($o -isnot [System.Collections.IDictionary]) { return @{ errore = 'soglia-quota.json non e un oggetto JSON' } }
    $o
}

function Save-SogliaQuota {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Override, [string]$Percorso = (Get-PercorsoSogliaQuotaPredefinito))
    Save-Stato -Stato $Override -Percorso $Percorso
}

function Remove-SogliaQuota {
    [CmdletBinding()]
    param([string]$Percorso = (Get-PercorsoSogliaQuotaPredefinito))
    if (Test-Path -LiteralPath $Percorso) { Remove-Item -LiteralPath $Percorso -Force }
}

# La quota di una sessione finita (dello smistatore o del supervisore: la quota e una sola): l'ultima lettura delle finestre e, se
# la sessione e finita sul limite, la pausa. Vale la pausa piu lunga.
function Update-QuotaDaEsito($Esito, $Adesso, $Limite, $Margine, [string]$Percorso = (Get-PercorsoQuotaPredefinito)) {
    $q = Get-Quota -Percorso $Percorso
    if ($null -ne (Get-Campo $Esito 'Quota')) {
        $q['letta'] = $Adesso.ToString('o')
        foreach ($f in @(@('fiveHour', 'five_hour'), @('sevenDay', 'seven_day'))) {
            $w = (Get-Campo $Esito 'Quota')[$f[1]]
            if ($w) { $q[$f[0]] = @{ utilization = $w.Utilization; resetsAt = $(if ($w.ResetsAt) { ([datetime]$w.ResetsAt).ToUniversalTime().ToString('o') } else { $null }) } }
        }
    }
    if ($null -ne $Limite) {
        # Vale la pausa piu lunga: una sessione che si ferma sulle 5 ore dopo un'altra fermata sulla settimana non deve
        # accorciare la pausa (gli agenti ripartirebbero e si fermerebbero di nuovo).
        $nuova = ([datetime]$Limite.Reset).ToUniversalTime().AddMinutes($Margine)
        $gia = ConvertTo-DataUtc (Get-Campo $q 'pausaFino')
        if ($null -eq $gia -or $nuova -gt $gia) {
            $q['pausaFino'] = $nuova.ToString('o')
            $q['finestraPausa'] = [string]$Limite.Finestra
        }
    }
    if ($q.Count -gt 0) { Save-Quota -Quota $q -Percorso $Percorso }
}

function Get-StatoCard {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Stato, [Parameter(Mandatory)][int]$Id)
    $k = "$Id"
    if (-not $Stato.Contains($k)) { $Stato[$k] = New-StatoCard }
    $voce = $Stato[$k]
    foreach ($campo in (New-StatoCard).GetEnumerator()) {
        if (-not $voce.Contains($campo.Key)) { $voce[$campo.Key] = $campo.Value }
    }
    $voce
}

function Get-FileRevNostre($Id, $Percorso) {
    Join-Path (Join-Path (Split-Path -Parent $Percorso) 'rev-nostre') "$Id.txt"
}

# Le revisioni scritte da noi stanno in un file per card, a sole aggiunte: card.ps1 gira in un processo diverso
# dallo smistatore e due processi che riscrivono lo stesso file si cancellano le scritture.
function Add-RevNostra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][int]$Rev,
        [string]$Percorso = (Get-PercorsoStatoPredefinito)
    )
    $f = Get-FileRevNostre $Id $Percorso
    $cartella = Split-Path -Parent $f
    if (-not (Test-Path -LiteralPath $cartella)) { New-Item -ItemType Directory -Path $cartella -Force | Out-Null }
    [IO.File]::AppendAllText($f, "$Rev`n", [Text.UTF8Encoding]::new($false))
}

function Get-RevNostre {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id, [string]$Percorso = (Get-PercorsoStatoPredefinito))
    $f = Get-FileRevNostre $Id $Percorso
    if (-not (Test-Path -LiteralPath $f)) { return }
    @(Get-Content -LiteralPath $f | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Select-Object -Unique)
}


# Il registro dell'apprendimento (D46): una riga JSON per evento, nella cartella dati accanto a registro-sessioni.jsonl (che
# resta dei consumi). Solo aggiunta, come rev-nostre: lo scrivono lo smistatore e il mentore in processi diversi, e due
# processi che riscrivono lo stesso file si cancellano le scritture.
# esito e quello della sessione in cui nasce la riga (lo sa chi la chiude): serve a non contare come lezione che ha evitato un
# blocco una lezione applicata in una sessione finita bloccata.
$script:NomeRegistroApprendimento = 'registro-apprendimento.jsonl'

function Add-RigaApprendimento {
    [CmdletBinding()]
    param(
        [string]$CartellaDati = (Get-CartellaDati),
        [Parameter(Mandatory)][int]$Card,
        [string]$Repo,
        [Parameter(Mandatory)][ValidateSet('blocco', 'onHold', 'correzione', 'lezioneApplicata')][string]$Tipo,
        [string]$Ruolo,
        [string]$Motivo,
        [string]$Lezione,
        [string]$Esito
    )
    $riga = [ordered]@{ data = [datetime]::UtcNow.ToString('o'); card = $Card; repo = $Repo; tipo = $Tipo; ruolo = $Ruolo; motivo = $Motivo; lezione = $Lezione; esito = $Esito }
    Add-RigaRegistro (Join-Path $CartellaDati $script:NomeRegistroApprendimento) ($riga | ConvertTo-Json -Compress)
}

# Lunghezza e ultima modifica del registro: cambiano se e solo se qualcuno ha aggiunto una riga. Chi ricalcola dal registro (la vista)
# lo fa solo quando cambiano. Senza file, vuota.
function Get-ImprontaRegistroApprendimento {
    [CmdletBinding()]
    param([string]$CartellaDati = (Get-CartellaDati))
    $i = Get-Item -LiteralPath (Join-Path $CartellaDati $script:NomeRegistroApprendimento) -ErrorAction SilentlyContinue
    if ($null -eq $i) { return '' }
    "$($i.Length)|$($i.LastWriteTimeUtc.Ticks)"
}

# Una riga che non si legge (scritta a meta, o a mano) non ferma chi legge il registro: si salta.
function Get-RigheApprendimento {
    [CmdletBinding()]
    param([string]$CartellaDati = (Get-CartellaDati))
    $f = Join-Path $CartellaDati $script:NomeRegistroApprendimento
    if (-not (Test-Path -LiteralPath $f)) { return }
    # la vista legge mentre lo smistatore aggiunge, e chi scrive tiene il file aperto: lettura condivisa
    foreach ($riga in (Read-RigheCondivise $f)) {
        if ([string]::IsNullOrWhiteSpace($riga)) { continue }
        try { $riga | ConvertFrom-Json -ErrorAction Stop } catch { }
    }
}

# Un giro alla volta: mutex con nome, valido fra processi. Il prefisso Global\ lo rende uno solo anche fra sessioni di
# Windows diverse (operazione pianificata senza utente connesso e lancio a mano). Lo stesso thread puo' riacquisire un mutex che gia' tiene,
# quindi si tiene a parte l'elenco dei nomi presi da questo processo.
$script:GiriPresi = @{}

# Il nome del lucchetto del giro: uno per cartella dati, perche e lo stato che due giri insieme rovinerebbero. Con un
# nome fisso i test, che lanciano lo smistatore su una cartella temporanea, si scontravano con lo smistatore vero.
function Get-NomeGiro {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CartellaDati)
    $chiave = [IO.Path]::GetFullPath($CartellaDati).Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($chiave))
    'Global\DevOps.Agents.Smistatore-' + ([Convert]::ToHexString($hash).Substring(0, 16).ToLowerInvariant())
}

function Enter-Giro {
    [CmdletBinding()]
    param([string]$Nome = 'Global\DevOps.Agents.Smistatore')
    if ($script:GiriPresi.Contains($Nome)) { return $false }
    $m = [System.Threading.Mutex]::new($false, $Nome)
    $preso = $false
    try { $preso = $m.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $preso = $true }   # il giro precedente e' morto senza rilasciare
    if (-not $preso) { $m.Dispose(); return $false }
    $script:GiriPresi[$Nome] = $m
    $true
}

function Exit-Giro {
    [CmdletBinding()]
    param([string]$Nome = 'Global\DevOps.Agents.Smistatore')
    if (-not $script:GiriPresi.Contains($Nome)) { return }
    $m = $script:GiriPresi[$Nome]
    $script:GiriPresi.Remove($Nome)
    try { $m.ReleaseMutex() } finally { $m.Dispose() }
}

# Le card con una sessione aperta, dallo stato: una card ha una sessione quando la voce ha il campo 'sessione' valorizzato. E la sola
# definizione di "sessione in corso": la usano lo smistatore (limite di sessioni), la vista, il supervisore e l'aggiornamento della suite.
function Get-IdCardConSessione($Stato) {
    @(foreach ($k in $Stato.Keys) { if ($null -ne $Stato[$k] -and $null -ne $Stato[$k]['sessione']) { [int]$k } }) | Sort-Object
}

# I mentori in corso, dallo stato: ogni card ha in `mentori` quelli lanciati e non ancora chiusi (lo smistatore ne toglie uno alla chiusura).
# Sono sessioni di modelli come quelle di `sessione`, e come quelle tengono ferma la suite quando si aggiorna.
function Get-NumeroMentoriInCorso($Stato) {
    $n = 0
    foreach ($k in $Stato.Keys) { if ($null -ne $Stato[$k] -and $Stato[$k].ContainsKey('mentori')) { $n += @(@($Stato[$k]['mentori']) | Where-Object { $null -ne $_ }).Count } }
    $n
}

Export-ModuleMember -Function Get-IdCardConSessione, Get-NumeroMentoriInCorso, Get-Stato, Save-Stato, Get-StatoCard, Get-Quota, Save-Quota, Get-PercorsoSogliaQuotaPredefinito, Get-SogliaQuota, Save-SogliaQuota, Remove-SogliaQuota, Update-QuotaDaEsito, Add-RevNostra, Get-RevNostre, Add-RigaApprendimento, Get-RigheApprendimento, Get-ImprontaRegistroApprendimento, Get-NomeGiro, Enter-Giro, Exit-Giro
