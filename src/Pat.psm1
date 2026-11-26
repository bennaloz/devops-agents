Set-StrictMode -Version Latest

# La creazione dei PAT dell'installazione (setup/Install-Attrezzi.ps1 -Pat). Il login di az serve solo qui: un token Entra
# per Azure DevOps, tenuto in memoria, con cui l'API dei PAT crea i due PAT che lo smistatore usera' poi senza az.
# Nessun token o PAT va mai in un messaggio, in un log o nell'output.

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Ado.psm1') -Global

$script:IdRisorsaAdo = '499b84ac-1321-427f-aa17-267ca6975798'
$script:ApiVersione = '7.1-preview.1'

# ---- i punti che toccano il mondo fuori (i test li sostituiscono) -------------------------------------------------

function Test-AzPresente { [bool](Get-Command az -ErrorAction SilentlyContinue) }

# L'unico punto che lancia az. Lo stdout si cattura (puo essere il token: mai stamparlo); lo stderr va al terminale, dove
# az chiede il login. Con -Silenzioso lo stderr si scarta (account show senza login scrive un avviso inutile).
function Invoke-Az([string[]]$Argomenti, [switch]$Silenzioso) {
    if ($Silenzioso) { $uscita = & az @Argomenti 2>$null } else { $uscita = & az @Argomenti }
    [pscustomobject]@{ Codice = $LASTEXITCODE; Uscita = (@($uscita) -join "`n").Trim() }
}

# L'unico punto che chiama l'API dei PAT. Il token entra solo nell'header; nel messaggio d'errore non finisce (e non
# finisce nemmeno il PAT creato: la risposta non e nell'errore).
function Invoke-ApiPat([string]$Metodo, [string]$Url, [string]$Token, $Corpo = $null) {
    $chiamata = @{ Method = $Metodo; Uri = $Url; Headers = @{ Authorization = "Bearer $Token" }; TimeoutSec = 30 }
    if ($null -ne $Corpo) { $chiamata.Body = ($Corpo | ConvertTo-Json -Depth 5 -Compress); $chiamata.ContentType = 'application/json' }
    try { Invoke-RestMethod @chiamata }
    catch {
        $msg = [string]$_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $corpoErrore = [string]$_.ErrorDetails.Message
            if ($corpoErrore.Length -gt 500) { $corpoErrore = $corpoErrore.Substring(0, 500) + '...' }
            $msg = "$msg - $corpoErrore"
        }
        if ($Token) { $msg = $msg.Replace($Token, '***') }
        $e = [Exception]::new("Chiamata all'API dei PAT fallita ($Metodo $Url): $msg")
        # il codice HTTP serve a chi chiama: un DELETE su un PAT gia sparito (404) non e un errore
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $e.Data['Stato'] = [int]$_.Exception.Response.StatusCode }
        throw $e
    }
}

# ---- la procedura ------------------------------------------------------------------------------------------------

# Il nome dell'organizzazione dall'URL che Ado.psm1 conosce: <org>.visualstudio.com oppure dev.azure.com/<org>.
function Get-NomeOrganizzazione {
    $uri = [uri](Get-AdoUrlOrganizzazione)
    if ($uri.Host -like '*.visualstudio.com') { return $uri.Host.Split('.')[0] }
    $primo = @($uri.AbsolutePath.Trim('/').Split('/'))[0]
    if ($primo) { return $primo }
    throw "Non riesco a ricavare il nome dell'organizzazione da $uri"
}

function Get-UrlApiPat([string]$Org) { "https://vssps.dev.azure.com/$Org/_apis/tokens/pats" }

# La scadenza in ISO UTC, qualunque sia la forma in cui arriva (l'API la da come data, i test anche come stringa).
function ConvertTo-ScadenzaIso($Valore) {
    $d = ConvertTo-DataUtc $Valore
    if ($null -eq $d) { return [string]$Valore }
    $d.ToString('o')
}

function New-PatAdo([string]$Org, [string]$Token, [string]$Nome, [string[]]$Scope, [datetime]$ValidTo) {
    $corpo = [ordered]@{ displayName = $Nome; scope = ($Scope -join ' '); validTo = $ValidTo.ToUniversalTime().ToString('o'); allOrgs = $false }
    $r = Invoke-ApiPat 'POST' ((Get-UrlApiPat $Org) + "?api-version=$script:ApiVersione") $Token $corpo
    $t = if ($r -and $r.PSObject.Properties['patToken']) { $r.patToken } else { $null }
    if ($null -eq $t -or -not $t.PSObject.Properties['token'] -or [string]::IsNullOrWhiteSpace([string]$t.token)) {
        throw "L'API dei PAT non ha restituito il PAT '$Nome'."
    }
    [pscustomobject]@{ Valore = [string]$t.token; AuthorizationId = [string]$t.authorizationId; ValidTo = (ConvertTo-ScadenzaIso $t.validTo) }
}

# Un PAT gia sparito (revocato a mano, scaduto da tempo) risponde 404: e gia l'esito voluto, non si riprova.
function Remove-PatAdo([string]$Org, [string]$Token, [string]$AuthorizationId) {
    try { [void](Invoke-ApiPat 'DELETE' ((Get-UrlApiPat $Org) + "?authorizationId=$([uri]::EscapeDataString($AuthorizationId))&api-version=$script:ApiVersione") $Token) }
    catch { if ($_.Exception.Data['Stato'] -ne 404) { throw } }
}

function Write-InfoPat([string]$Percorso, [string]$Json) {
    [IO.File]::WriteAllText($Percorso, $Json, [Text.UTF8Encoding]::new($false))
}

# La config letta e controllata prima di qualunque login: durata, e per ciascun PAT nome e scope.
function Read-ConfigPat([string]$Percorso) {
    $cfg = try { Get-Content -LiteralPath $Percorso -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Config dei PAT illeggibile ($Percorso): $($_.Exception.Message)" }
    $durata = 0
    if (-not [int]::TryParse([string](Get-Campo $cfg 'durataGiorni'), [ref]$durata) -or $durata -le 0) {
        throw "Config dei PAT ($Percorso): durataGiorni manca o non e un numero maggiore di zero. Nessun login fatto."
    }
    foreach ($chiave in 'smistatore', 'solaLettura') {
        $voce = Get-Campo $cfg $chiave
        if ([string]::IsNullOrWhiteSpace([string](Get-Campo $voce 'nome'))) { throw "Config dei PAT ($Percorso): manca il nome di '$chiave'. Nessun login fatto." }
        $scope = @(Get-Campo $voce 'scope' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($scope.Count -eq 0) { throw "Config dei PAT ($Percorso): mancano gli scope di '$chiave'. Nessun login fatto." }
    }
    $cfg
}

# Mette al loro posto i file nuovi (gia scritti con estensione .nuovo accanto alla destinazione). Se uno spostamento
# fallisce, i file gia sostituiti tornano com'erano: o tutto o niente.
function Publish-FileNuovi([string[]]$Destinazioni) {
    $fatti = @()
    try {
        foreach ($d in $Destinazioni) {
            $prec = $null
            if (Test-Path -LiteralPath $d) { $prec = "$d.prec"; Move-Item -LiteralPath $d -Destination $prec -Force }
            try { Move-Item -LiteralPath "$d.nuovo" -Destination $d -Force }
            catch { if ($prec) { Move-Item -LiteralPath $prec -Destination $d -Force }; throw }
            $fatti += [pscustomobject]@{ Destinazione = $d; Precedente = $prec }
        }
    }
    catch {
        foreach ($f in $fatti) {
            Remove-Item -LiteralPath $f.Destinazione -Force -ErrorAction SilentlyContinue
            if ($f.Precedente) { Move-Item -LiteralPath $f.Precedente -Destination $f.Destinazione -Force -ErrorAction SilentlyContinue }
        }
        throw
    }
    foreach ($f in $fatti) { if ($f.Precedente) { Remove-Item -LiteralPath $f.Precedente -Force -ErrorAction SilentlyContinue } }
}

# Crea i due PAT e li scrive cifrati (DPAPI) in <ClaudeDir>/pat-smistatore.txt e pat-smistatore-lettura.txt, con la scadenza
# non segreta in pat-info.json. pat.txt e pat-read-only.txt sono dell'utente e non si toccano mai. Se il login di az l'ha
# fatto questa procedura, lo toglie alla fine (anche se qualcosa fallisce); se c'era gia, non lo tocca. Al giro dopo revoca i
# PAT vecchi elencati in pat-info.json (e quelli rimasti in daRevocare), dopo aver salvato i nuovi.
function Install-Pat {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClaudeDir, [Parameter(Mandatory)][string]$PercorsoConfig)

    # la config prima di tutto: un errore qui non deve aprire il browser
    $cfg = Read-ConfigPat $PercorsoConfig
    if (-not (Test-AzPresente)) {
        throw 'Azure CLI (az) non c''e. Installala (https://aka.ms/installazurecliwindows), poi rilancia setup/Install-Attrezzi.ps1 -Pat.'
    }
    $loginFatto = $false
    $creati = [ordered]@{}
    $token = $null
    $org = Get-NomeOrganizzazione
    try {
        if ((Invoke-Az @('account', 'show', '--output', 'none') -Silenzioso).Codice -ne 0) {
            Write-Host 'Pat: nessun login az: lo faccio ora (serve solo per creare i PAT, poi lo tolgo).'
            $loginFatto = $true   # da qui il logout spetta a noi, anche se il login resta a meta
            # senza subscription Azure il login standard fallisce: l'API dei PAT non ne ha bisogno
            if ((Invoke-Az @('login', '--allow-no-subscriptions', '--output', 'none')).Codice -ne 0) { throw 'az login non riuscito: nessun PAT creato.' }
        }
        $r = Invoke-Az @('account', 'get-access-token', '--resource', $script:IdRisorsaAdo, '--query', 'accessToken', '--output', 'tsv')
        if ($r.Codice -ne 0 -or [string]::IsNullOrWhiteSpace($r.Uscita)) { throw 'az non ha dato il token per Azure DevOps: nessun PAT creato.' }
        $token = $r.Uscita

        $revocaNuovi = {
            foreach ($c in @($creati.Keys)) {
                try { Remove-PatAdo $org $token $creati[$c].AuthorizationId }
                catch { Write-Warning "Pat: non sono riuscito a revocare il PAT appena creato '$c' (authorizationId $($creati[$c].AuthorizationId))." }
            }
        }

        $validTo = [datetime]::UtcNow.AddDays([int]$cfg.durataGiorni)
        try {
            foreach ($chiave in 'smistatore', 'solaLettura') {
                $voce = $cfg.$chiave
                $creati[$chiave] = New-PatAdo $org $token ([string]$voce.nome) @($voce.scope) $validTo
                Write-Host "Pat: creato '$($voce.nome)' (scade $($creati[$chiave].ValidTo))"
            }
        }
        catch {
            # i due PAT vanno insieme: se il secondo non nasce, il primo non serve a nessuno e non si lascia attivo
            & $revocaNuovi
            throw
        }

        # i vecchi: letti prima di sovrascrivere pat-info.json
        $percorsoInfo = Join-Path $ClaudeDir 'pat-info.json'
        $vecchi = @()
        if (Test-Path -LiteralPath $percorsoInfo) {
            try {
                $info = Get-Content -LiteralPath $percorsoInfo -Raw | ConvertFrom-Json
                foreach ($chiave in 'smistatore', 'solaLettura') {
                    $id = [string](Get-Campo (Get-Campo $info $chiave) 'authorizationId')
                    if ($id) { $vecchi += $id }
                }
                foreach ($id in @(Get-Campo $info 'daRevocare')) { if ($id) { $vecchi += [string]$id } }
            }
            catch { Write-Warning 'Pat: pat-info.json illeggibile, i PAT vecchi non si revocano da qui.' }
        }
        $vecchi = @($vecchi | Select-Object -Unique)

        $nomi = @{ smistatore = (Get-NomiFilePat 'smistatore').Nuovo; solaLettura = (Get-NomiFilePat 'lettura').Nuovo }
        $infoJson = {
            param($DaRevocare)
            $n = [ordered]@{}
            foreach ($chiave in $creati.Keys) { $n[$chiave] = [ordered]@{ authorizationId = $creati[$chiave].AuthorizationId; validTo = $creati[$chiave].ValidTo } }
            if (@($DaRevocare).Count -gt 0) { $n['daRevocare'] = @($DaRevocare) }
            $n | ConvertTo-Json -Depth 4
        }

        # solo ora, con entrambi i PAT in mano, si scrive su disco: prima tutto in file .nuovo, poi si mettono al posto
        # dei veri. Se qualcosa fallisce i file di prima restano come erano e i PAT nuovi si revocano.
        $destinazioni = @((Join-Path $ClaudeDir $nomi.smistatore), (Join-Path $ClaudeDir $nomi.solaLettura), $percorsoInfo)
        try {
            Write-FilePat "$($destinazioni[0]).nuovo" $creati['smistatore'].Valore
            Write-FilePat "$($destinazioni[1]).nuovo" $creati['solaLettura'].Valore
            # i vecchi da revocare stanno gia nel file nuovo: se il processo muore a meta, il giro dopo li riprova
            Write-InfoPat "$($destinazioni[2]).nuovo" (& $infoJson $vecchi)
            Publish-FileNuovi $destinazioni
        }
        catch {
            $errore = $_.Exception.Message
            foreach ($d in $destinazioni) { Remove-Item -LiteralPath "$d.nuovo" -Force -ErrorAction SilentlyContinue }
            & $revocaNuovi
            throw "Pat: scrittura dei file fallita, i PAT appena creati sono stati revocati e i file di prima sono rimasti com'erano: $errore"
        }
        Write-Host "Pat: scritti $($nomi.smistatore) e $($nomi.solaLettura) (cifrati con DPAPI) e pat-info.json. pat.txt resta tuo, -Pat non lo tocca."

        $nonRevocati = @()
        foreach ($id in $vecchi) {
            try { Remove-PatAdo $org $token $id; Write-Host "Pat: revocato il PAT vecchio $id" }
            catch {
                $nonRevocati += $id
                Write-Warning "Pat: il PAT vecchio $id non si e revocato ($($_.Exception.Message)). Resta in pat-info.json (daRevocare): il prossimo -Pat lo riprova."
            }
        }
        if ($vecchi.Count -gt 0 -and $nonRevocati.Count -ne $vecchi.Count) {
            try { Write-InfoPat $percorsoInfo (& $infoJson $nonRevocati) }
            catch { Write-Warning "Pat: non sono riuscito ad aggiornare daRevocare in pat-info.json: $($_.Exception.Message)" }
        }
    }
    finally {
        $token = $null
        if ($loginFatto) {
            if ((Invoke-Az @('logout') -Silenzioso).Codice -eq 0) { Write-Host 'Pat: login az tolto.' }
            else { Write-Warning 'Pat: az logout non e riuscito: il login az e ancora attivo. Fai az logout a mano.' }
        }
    }
}

Export-ModuleMember -Function Install-Pat, Test-AzPresente, Invoke-Az, Invoke-ApiPat, Get-NomeOrganizzazione
