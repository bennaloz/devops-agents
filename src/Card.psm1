Set-StrictMode -Version Latest

# -Global e niente -Force: i moduli restano visibili al chiamante, e un modulo che il chiamante ha gia caricato
# non viene scaricato e ricaricato (un import annidato con -Force gli toglieva le funzioni).
foreach ($m in 'Comune', 'Config', 'Ado', 'Stato') {
    Import-Module (Join-Path $PSScriptRoot "$m.psm1") -Global
}

$script:MaxCommenti = 10
# D59: cosa dicono `leggi` e `deploy` per un componente con l'ambiente di collaudo
$script:TestoSenzaDeployCollaudo = 'si prova nell''ambiente Docker della card (D59): nessun parametro da scegliere, non e un motivo per senza-test'

function Get-RuoloConfig($Config, $Ruolo) {
    $r = $Config.Ruoli.PSObject.Properties[$Ruolo]
    if (-not $r) { throw "Ruolo sconosciuto: '$Ruolo'" }
    $r.Value
}

# D52: se la card e figlia di una Feature con una card di chiusura (una funzionalita, la regola e in Get-ComposizioneFunzionalita), la
# sezione FUNZIONALITA di `leggi`: la Feature (id, stato, titolo), la card di chiusura, le sorelle (id, stato, titolo, tag) e se questa
# card e la chiusura o una sorella. Niente per una card isolata (nessuna lettura in piu). Se la Feature non si legge lo dice, e la
# lettura della card non salta.
function Get-RigheFunzionalita($Card) {
    $padre = Get-Campo $Card 'PadreId'
    if (-not $padre) { return @() }
    try {
        $config = Get-Config
        $f = Get-AdoFeature -Id ([int]$padre)
        if ($f.Tipo -ne 'Feature') { return @() }
        $parti = Get-ComposizioneFunzionalita $config.Stati @(Get-AdoFigliFeature -FigliIds @($f.FigliIds))
        if ($null -eq $parti) { return @() }
        $righe = @('FUNZIONALITA', "Feature $($f.Id) [$($f.Stato)] $($f.Titolo)", "card di chiusura: #$($parti.Chiusura.Id)")
        $righe += $(if ([int]$parti.Chiusura.Id -eq [int]$Card.Id) { 'questa card e la card di chiusura: prova in Test le sorelle gia unite nel ramo della funzionalita' } else { 'questa card e una sorella' })
        $righe += "sorelle ($(@($parti.Sorelle).Count)):"
        foreach ($sorella in @($parti.Sorelle)) {
            $righe += "#$($sorella.Id) [$($sorella.Stato)] $($sorella.Titolo) ($(@($sorella.Tag) -join ', '))"
        }
        $righe + @('')
    }
    catch { @('FUNZIONALITA', "la Feature $padre non si legge: $($_.Exception.Message)", '') }
}

function Read-Card {
    [CmdletBinding()]
    # TaskSessione: il task della sessione che legge (0 = nessuno), per segnarlo nell'elenco.
    param([Parameter(Mandatory)][int]$Id, [int]$TaskSessione = 0)
    $card = Get-AdoCard -Id $Id
    $tutti = @(Get-AdoCommenti -Id $Id | Sort-Object Id)
    $commenti = @($tutti | Select-Object -Last $script:MaxCommenti)
    # la scelta del deploy in Test puo essere piu vecchia degli ultimi commenti: si legge su tutti (D43)
    $deploy = @(Get-SceltaDeploy $tutti)
    $task = @(Get-AdoTaskFigli -CardId $Id)
    $righe = [System.Collections.Generic.List[string]]::new()
    $righe.Add("Card $($card.Id) - $($card.Titolo)")
    $righe.Add("Tipo: $($card.Tipo) | Stato: $($card.Stato) | Area: $($card.Area)")
    $righe.Add('')
    $righe.Add('TAG')
    $righe.Add($(if (@($card.Tag).Count -gt 0) { @($card.Tag) -join ', ' } else { '(nessuno)' }))
    $righe.Add('')
    foreach ($r in @(Get-RigheFunzionalita $card)) { $righe.Add($r) }
    $righe.Add('DESCRIZIONE')
    $righe.Add([string]$card.Descrizione)
    $righe.Add('')
    $righe.Add('CRITERI DI ACCETTAZIONE')
    $righe.Add([string]$card.Criteri)
    $righe.Add('')
    $righe.Add('DEPLOY IN TEST')
    # D59: un componente con l'ambiente di collaudo non ha un deploy in Test da scegliere
    $voceCard = try { Find-VoceMappa -Mappa (Get-Config).Mappa -Area $card.Area } catch { $null }
    $righe.Add($(if (Test-AmbienteCollaudo $voceCard) { $script:TestoSenzaDeployCollaudo }
        elseif ($deploy.Count -gt 0) { $deploy -join ', ' } else { 'nessuna scelta del responsabile (card.ps1 deploy)' }))
    $righe.Add('')
    if ($task.Count -gt 0) {
        $righe.Add("TASK ($($task.Count), nell'ordine di esecuzione)")
        foreach ($t in $task) {
            $tuo = if ($TaskSessione -gt 0 -and $t.Id -eq $TaskSessione) { ' <- il tuo task' } else { '' }
            $righe.Add("#$($t.Id) [$($t.Stato)] $($t.Titolo)$tuo")
            $righe.Add([string]$t.Descrizione)
            $righe.Add('')
        }
    }
    $righe.Add("COMMENTI (ultimi $($commenti.Count), dal piu vecchio al piu nuovo)")
    foreach ($c in $commenti) {
        $righe.Add("#$($c.Id) $($c.Autore) $($c.Quando)")
        $righe.Add([string]$c.Testo)
        $righe.Add('')
    }
    $righe -join "`n"
}

function Add-CardCommento {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Ruolo,
        [Parameter(Mandatory)][string]$Testo
    )
    # Prefisso e firma li mette lo script; un modello che li imita non deve trovarli due volte.
    $prefisso = "[$Ruolo]"; $firma = Get-FirmaCommento $Ruolo
    $t = $Testo.Trim()
    while ($t.StartsWith($prefisso)) { $t = $t.Substring($prefisso.Length).TrimStart() }
    while ($t.EndsWith($firma)) { $t = $t.Substring(0, $t.Length - $firma.Length).TrimEnd() }
    $corpo = "$prefisso $t`n`n$firma"
    Add-AdoCommento -Id $Id -Testo $corpo
}

function Set-CardCriteri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Ruolo,
        [Parameter(Mandatory)][string]$Testo
    )
    if ($Ruolo -ne 'responsabile') { throw "Il ruolo '$Ruolo' non puo scrivere i criteri: solo responsabile" }
    Set-AdoCard -Id $Id -Criteri $Testo
}

# Il testo dei task: ogni task comincia con una riga "=== <titolo>", il testo e quello che segue fino al titolo dopo.
# Si valida tutto prima di creare qualunque cosa: un testo malformato non lascia task a meta.
function ConvertFrom-TestoTask([string]$Testo) {
    $task = [System.Collections.Generic.List[object]]::new()
    $corrente = $null
    $prima = [System.Collections.Generic.List[string]]::new()
    foreach ($riga in ($Testo -split "`r?`n")) {
        if ($riga -match '^===\s+(\S.*?)\s*$') {
            $corrente = @{ Titolo = $Matches[1]; Righe = [System.Collections.Generic.List[string]]::new() }
            $task.Add($corrente)
        }
        elseif ($null -eq $corrente) { $prima.Add($riga) }
        else { $corrente.Righe.Add($riga) }
    }
    if (-not [string]::IsNullOrWhiteSpace(($prima -join ''))) {
        throw "il testo dei task deve cominciare con una riga '=== <titolo>': c'e testo prima del primo titolo"
    }
    if ($task.Count -eq 0) { throw "nessun task nel testo: ogni task comincia con una riga '=== <titolo>'" }
    $n = 0
    @(foreach ($t in $task) {
        $n++
        $corpo = ($t.Righe -join "`n").Trim()
        if (-not $corpo) { throw "il task $n ('$($t.Titolo)') non ha testo: serve cosa fare e da cosa si vede che e fatto" }
        [pscustomobject]@{ Titolo = $t.Titolo; Testo = $corpo }
    })
}

# Crea i task figli della card, nell'ordine in cui sono scritti (l'ordine degli id e l'ordine di esecuzione).
function New-CardTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Ruolo,
        [Parameter(Mandatory)][string]$Testo
    )
    if ($Ruolo -ne 'responsabile') { throw "Il ruolo '$Ruolo' non puo creare i task: solo responsabile" }
    $voci = @(ConvertFrom-TestoTask $Testo)
    # Aggiungere task e permesso; un doppione no. Il confronto e sul titolo, senza maiuscole e spazi ai lati;
    # un task rimosso non conta. Si controlla tutto prima di creare, cosi un doppione non lascia task a meta.
    $chiave = { param($t) ([string]$t).Trim().ToLowerInvariant() -replace '\s+', ' ' }
    $config = Get-Config
    $esistenti = @(Get-AdoTaskFigli -CardId $Id) | Where-Object { $_.Stato -ine $config.Stati.taskRimosso }
    $doppi = foreach ($v in $voci) {
        $e = $esistenti | Where-Object { (& $chiave $_.Titolo) -eq (& $chiave $v.Titolo) } | Select-Object -First 1
        if ($e) { "'$($v.Titolo)' esiste gia come #$($e.Id)" }
    }
    $ripetuti = @($voci | Group-Object { & $chiave $_.Titolo } | Where-Object Count -gt 1 | ForEach-Object { "'$($_.Group[0].Titolo)' compare $($_.Count) volte" })
    $tutti = @($doppi) + $ripetuti
    if ($tutti.Count -gt 0) { throw "nessun task creato, doppioni: $($tutti -join '; ')" }
    $card = Get-AdoCard -Id $Id
    $creati = [System.Collections.Generic.List[object]]::new()
    foreach ($v in $voci) {
        try { $creati.Add((New-AdoTask -CardId $Id -Titolo $v.Titolo -Descrizione $v.Testo -Area $card.Area)) }
        catch {
            $gia = if ($creati.Count -gt 0) { "gia creati: $((@($creati | ForEach-Object { "#$($_.Id)" })) -join ', ')" } else { 'nessuno creato prima' }
            throw "creazione del task '$($v.Titolo)' non riuscita ($gia; i task dopo questo non sono stati creati): $($_.Exception.Message)"
        }
    }
    @($creati)
}

# Chiude il task della sessione di dev. Il task e quello di ATTREZZI_TASK (TaskSessione): un id diverso si rifiuta.
function Close-CardTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Ruolo,
        [string]$TaskSessione,
        [string]$TaskRichiesto
    )
    if ($Ruolo -ne 'dev') { throw "Il ruolo '$Ruolo' non puo chiudere un task: solo dev" }
    $idTask = 0
    if (-not [int]::TryParse($TaskSessione, [ref]$idTask) -or $idTask -le 0) {
        throw 'questa sessione non e di un task: non c''e niente da chiudere'
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskRichiesto) -and "$TaskRichiesto".Trim() -ne "$idTask") {
        throw "il task $TaskRichiesto non e quello di questa sessione ($idTask): si chiude solo il proprio"
    }
    $config = Get-Config
    $t = @(Get-AdoTaskFigli -CardId $Id) | Where-Object { $_.Id -eq $idTask } | Select-Object -First 1
    if (-not $t) { throw "il task $idTask non e figlio della card $Id" }
    if ($t.Stato -ieq $config.Stati.taskChiuso) { return "Il task $idTask era gia chiuso." }
    if ($t.Stato -ieq $config.Stati.taskRimosso) { throw "il task $idTask e rimosso: non si chiude" }
    [void](Set-AdoTaskStato -Id $idTask -Stato $config.Stati.taskChiuso)
    "Task $idTask chiuso."
}

function Move-Card {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Ruolo,
        [Parameter(Mandatory)][string]$Stato
    )
    $config = Get-Config
    $cfgRuolo = Get-RuoloConfig $config $Ruolo
    $chiaviStati = @($config.Stati.PSObject.Properties.Name | Where-Object { $_ -notlike 'tag*' -and $_ -notlike 'task*' -and $_ -notlike 'feature*' })
    if ($Stato -notin $chiaviStati) { throw "Stato sconosciuto: '$Stato' non e una chiave di stati.json" }

    $card = Get-AdoCard -Id $Id
    $da = Get-ChiaveStato $config.Stati $card.Stato
    if (-not $da) { throw "La card $Id e in uno stato non previsto da stati.json: '$($card.Stato)'" }

    $permessa = @($cfgRuolo.transizioni) | Where-Object { $_[0] -eq $da -and $_[1] -eq $Stato }
    if (-not $permessa) { throw "Il ruolo '$Ruolo' non puo spostare una card da '$da' a '$Stato'" }

    $rev = Set-AdoCard -Id $Id -Stato $config.Stati.$Stato
    Add-RevNostra -Id $Id -Rev $rev
    $rev
}

# Crea una card da un file markdown con le quattro sezioni richieste. Vietato dentro una sessione di ruolo:
# un ruolo che crea card da solo aggirerebbe il via di una persona.
# Niente prova in Test per questa card: la decide responsabile quando nessun criterio si verifica nell'ambiente di Test,
# e scrive il motivo sulla card. Dopo la revisione la card va dritta in Ready to merge.
function Set-CardSenzaTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Ruolo,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Motivo
    )
    if ($Ruolo -ne 'responsabile') { throw "Il ruolo '$Ruolo' non puo togliere la prova in Test: solo responsabile" }
    if ([string]::IsNullOrWhiteSpace($Motivo)) { throw 'manca il motivo: perche nessun criterio si verifica in Test (va dato su stdin)' }
    $config = Get-Config
    [void](Set-AdoCard -Id $Id -AggiungiTag @($config.Stati.tagSenzaTest))
    Add-CardCommento -Id $Id -Ruolo $Ruolo -Testo "Niente prova in Test (tag $($config.Stati.tagSenzaTest)): $Motivo"
}

# Una parte della card la prova una persona (D52, per la card di chiusura; vale per ogni card): lo decide responsabile quando un criterio lo giudica una persona (colore, layout,
# un'impressione), e scrive il motivo sulla card. Il tag human-test fa passare la card dalla prova di una persona (Human test).
function Set-CardProvaUmana {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Ruolo,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Motivo
    )
    if ($Ruolo -ne 'responsabile') { throw "Il ruolo '$Ruolo' non puo chiedere la prova di una persona: solo responsabile" }
    if ([string]::IsNullOrWhiteSpace($Motivo)) { throw 'manca il motivo: quale criterio lo giudica una persona (va dato su stdin)' }
    $config = Get-Config
    [void](Set-AdoCard -Id $Id -AggiungiTag @($config.Stati.tagProvaUmana))
    Add-CardCommento -Id $Id -Ruolo $Ruolo -Testo "Prova di una persona in Human test (tag $($config.Stati.tagProvaUmana)): $Motivo"
}

# D52, gruppo 5: la correzione che il responsabile scrive sulla card di chiusura dopo un collaudo respinto o una CI rossa. Il testo: sulla
# prima riga la natura (tecnico: il comportamento atteso e gia scritto nei criteri; prodotto: la correzione richiede una scelta che spetta a
# una persona), poi "=== <titolo>" e sotto la descrizione, come un task di crea-task. Non crea niente: scrive un commento con la marca
# (ConvertTo-TestoCommentoCorrezione) e la Bug la fa lo smistatore, una per commento. Solo sulla card di chiusura.
function Add-CardCorrezione {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Ruolo,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Testo
    )
    if ($Ruolo -ne 'responsabile') { throw "Il ruolo '$Ruolo' non puo scrivere una correzione: solo responsabile" }
    $righe = @($Testo -split '\r?\n')
    $natura = "$($righe[0])".Trim()
    if ($natura -notin (Get-NatureCorrezione)) {
        throw "la prima riga deve essere la natura della correzione, '$((Get-NatureCorrezione) -join "' o '")': tecnico se il comportamento atteso e gia scritto nei criteri, prodotto se serve una scelta che spetta a una persona"
    }
    try { $voci = @(ConvertFrom-TestoTask ((@($righe | Select-Object -Skip 1)) -join "`n")) }
    catch { throw "la correzione non e scritta come serve (dopo la natura: '=== <titolo>' e sotto la descrizione): $($_.Exception.Message)" }
    if ($voci.Count -gt 1) { throw 'una sola correzione per comando: ogni correzione ha il suo titolo e il suo testo, e fa una Bug' }
    $config = Get-Config
    $card = Get-AdoCard -Id $Id
    if ($null -eq (Get-FeatureDiChiusura $config $card)) {
        throw "la correzione si scrive solo sulla card di chiusura di una funzionalita: la card $Id non lo e"
    }
    [void](Add-CardCommento -Id $Id -Ruolo $Ruolo -Testo (ConvertTo-TestoCommentoCorrezione -Tipo $natura -Titolo $voci[0].Titolo -Descrizione $voci[0].Testo))
    "Correzione $natura scritta: '$($voci[0].Titolo)'. Lo smistatore ne fa una Bug figlia della Feature."
}

# D52: l'id della Feature di cui la card e la card di chiusura, o null (card isolata, sorella, o padre che non e una Feature).
# Una card senza padre non costa nessuna lettura. La regola di cos'e la chiusura sta in Get-ComposizioneFunzionalita.
function Get-FeatureDiChiusura($Config, $Card) {
    $padre = Get-Campo $Card 'PadreId'
    if (-not $padre) { return $null }
    $f = Get-AdoFeature -Id ([int]$padre)
    if ($f.Tipo -ne 'Feature') { return $null }
    $parti = Get-ComposizioneFunzionalita $Config.Stati @(Get-AdoFigliFeature -FigliIds @($f.FigliIds))
    if ($null -ne $parti -and [int]$parti.Chiusura.Id -eq [int]$Card.Id) { return [int]$f.Id }
    $null
}

# I parametri del deploy in Test della card (D43): li sceglie il responsabile, che conosce il recinto della card, fra i
# booleani deploy* dello YAML della pipeline di deploy del componente, letto sul ramo della card se e pubblicato, altrimenti
# su develop (per la card di chiusura di una funzionalita D52, sul ramo della funzionalita). Il testo: sulla prima riga i nomi (separati da virgole o spazi), sotto il perche. Un nome che lo YAML non ha si
# rifiuta e non si scrive niente. La scelta va in un commento sulla card (vale l'ultimo): lo smistatore lo rilegge al deploy.
function Set-CardDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Ruolo,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Testo
    )
    if ($Ruolo -ne 'responsabile') { throw "Il ruolo '$Ruolo' non puo scegliere il deploy in Test: solo responsabile" }
    $righe = @($Testo -split '\r?\n')
    $nomi = [System.Collections.Generic.List[string]]::new()
    foreach ($n in @($righe[0] -split '[,\s]+' | Where-Object { $_ })) { if (-not $nomi.Contains($n)) { $nomi.Add($n) } }
    if ($nomi.Count -eq 0) { throw 'mancano i parametri del deploy: sulla prima riga i nomi, sotto il perche (su stdin)' }
    $perche = (@($righe | Select-Object -Skip 1) -join "`n").Trim()
    if (-not $perche) { throw 'manca il perche: sotto la riga dei parametri, cosa della card tocca quei componenti (su stdin)' }
    $config = Get-Config
    $card = Get-AdoCard -Id $Id
    $voce = Get-VoceMappa -Area $card.Area -Mappa $config.Mappa
    if (Test-AmbienteCollaudo $voce) { return $script:TestoSenzaDeployCollaudo }
    if (-not (Get-Campo $voce 'pipelineDeploy')) {
        throw "il componente '$($voce.componente)' non ha un deploy in Test (pipelineDeploy nella mappa): se nessun criterio si prova in Test usa senza-test"
    }
    # D52: la card di chiusura non ha un ramo suo, il suo codice e nel ramo della funzionalita
    $featureId = Get-FeatureDiChiusura $config $card
    $ramo = if ($featureId) { Get-AdoRamoCard -Progetto $voce.progettoAdo -Repo $voce.repo -FeatureId $featureId }
            else { Get-AdoRamoCard -Progetto $voce.progettoAdo -Repo $voce.repo -CardId $Id }
    if (-not $ramo) { $ramo = 'develop' }
    $ammessi = @(Get-AdoParametriDeploy -Progetto $voce.progettoAdo -PipelineId ([int]$voce.pipelineDeploy) -Ramo $ramo)
    $ignoti = @($nomi | Where-Object { $_ -cnotin $ammessi })
    if ($ignoti.Count -gt 0) {
        $quali = if ($ammessi.Count -gt 0) { $ammessi -join ', ' } else { 'nessuno' }
        throw "parametro di deploy sconosciuto: $($ignoti -join ', '). Sul ramo $ramo la pipeline $($voce.pipelineDeploy) ha questi parametri deploy*: $quali"
    }
    [void](Add-CardCommento -Id $Id -Ruolo $Ruolo -Testo (ConvertTo-TestoCommentoDeploy -Parametri @($nomi) -Perche $perche))
    "Deploy in Test: $($nomi -join ', ') (parametri letti sul ramo $ramo)."
}

# Il titolo della PR della card, l'unica che un ruolo puo toccare: la cerca dai link della card, non da un id dato da fuori.
# Una validazione rossa per il titolo si rilancia subito, perche il nuovo titolo conti.
function Set-CardTitoloPr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Ruolo,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Titolo
    )
    if ($Ruolo -notin 'dev', 'responsabile') { throw "Il ruolo '$Ruolo' non puo cambiare il titolo della PR: solo dev e responsabile" }
    $titolo = $Titolo.Trim()
    if (-not $titolo) { throw 'manca il titolo nuovo della PR' }
    $pr = Get-AdoPrCollegata -CardId $Id
    if (-not $pr -or $pr.Stato -ne 'active') { throw "la card $Id non ha una PR attiva" }
    Set-AdoTitoloPr -Progetto $pr.Progetto -Repo $pr.Repo -Id $pr.Id -Titolo $titolo
    $n = Start-AdoRivalutazione -Progetto $pr.Progetto -Repo $pr.Repo -Ramo $pr.Ramo
    "Titolo della PR $($pr.Id) cambiato in '$titolo'. Validazioni rilanciate: $n."
}

# La descrizione della PR della card: il testo del file va dopo la riga con il link alla card che lo smistatore ha messo
# in testa, che resta. Il tetto di Azure DevOps (firma compresa) si controlla qui, prima di scrivere: un testo troppo lungo
# si rifiuta, non si tronca. Il file si legge in UTF-8 e la scrittura passa dalla REST, non da az (che perde gli accenti).
function Set-CardDescrizionePr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Ruolo,
        [Parameter(Mandatory)][string]$File
    )
    if ($Ruolo -notin 'dev', 'responsabile') { throw "Il ruolo '$Ruolo' non puo scrivere la descrizione della PR: solo dev e responsabile" }
    if (-not (Test-Path -LiteralPath $File)) { throw "File non trovato: '$File'" }
    $testo = (Get-Content -LiteralPath $File -Raw -Encoding UTF8).Trim()
    if (-not $testo) { throw 'il file della descrizione e vuoto' }
    $pr = Get-AdoPrCollegata -CardId $Id
    if (-not $pr -or $pr.Stato -ne 'active') {
        # Niente PR ancora: il testo resta sulla card e lo smistatore lo mette nella PR quando la apre. Il tetto si controlla
        # gia qui, con la riga del link che avra la PR, perche un testo che poi non ci sta si scoprirebbe solo all'apertura.
        $tettoSenzaLink = (Get-AdoLimiteTestoPr) - ("[Card $Id](" + (Get-AdoUrlCard -Id $Id) + ")").Length - 2
        if ($testo.Length -gt $tettoSenzaLink) {
            throw "la descrizione e di $($testo.Length) caratteri: con il link alla card ne restano al massimo $tettoSenzaLink per il testo. Accorciala"
        }
        [void](Add-CardCommento -Id $Id -Ruolo $Ruolo -Testo (ConvertTo-TestoCommentoDescrizionePr $testo))
        return "La card $Id non ha ancora una PR: descrizione salvata sulla card ($($testo.Length) caratteri), la metto nella PR quando lo smistatore la apre."
    }
    $attuale = Get-AdoDescrizionePr -Progetto $pr.Progetto -Repo $pr.Repo -Id $pr.Id
    $testa = ([string]$attuale -split "`r?`n")[0].Trim()
    if ($testa -notmatch "^\[Card $Id\]\(") { $testa = "[Card $Id]($(Get-AdoUrlCard -Id $Id))" }
    $descrizione = "$testa`n`n$testo"
    $tetto = Get-AdoLimiteTestoPr
    if ($descrizione.Length -gt $tetto) {
        throw "la descrizione e di $($descrizione.Length) caratteri, compreso il link alla card: Azure DevOps ne ammette al massimo $tetto. Accorciala"
    }
    Set-AdoDescrizionePr -Progetto $pr.Progetto -Repo $pr.Repo -Id $pr.Id -Descrizione $descrizione
    "Descrizione della PR $($pr.Id) scritta ($($descrizione.Length) caratteri su $tetto)."
}

# Legge la Feature a cui si vuole aggiungere una card e rifiuta quello che D52 non ammette: un work item che non e una
# Feature, un'area diversa, una Feature Removed o gia in develop (Resolved o Closed), una Feature senza card di chiusura (e una Feature
# della spec, sezione 18: la sua card si crea senza -Feature).
function Assert-FeatureAccetta($Config, [int]$Feature, [string]$Area) {
    $f = Get-AdoFeature -Id $Feature
    if ($f.Tipo -ne 'Feature') { throw "il work item $Feature non e una Feature (e: $($f.Tipo))" }
    if ($f.Stato -ieq $Config.Stati.featureRimossa) { throw "la Feature $Feature e $($f.Stato): non si aggiungono card a una Feature rimossa" }
    if ($f.Stato -ieq $Config.Stati.featureRisolta -or $f.Stato -ieq $Config.Stati.featureChiusa) {
        throw "la Feature $Feature e $($f.Stato): la funzionalita e gia in develop, il lavoro nuovo va in una Feature nuova"
    }
    # D60: una Feature senza card di chiusura raggruppa le card per priorita e pausa, e le sue card vanno in develop una per una, come le
    # isolate: possono stare in aree (repo) diverse. Con la card di chiusura e una funzionalita D52 e sta in un'area sola.
    $d52 = $null -ne (Get-ComposizioneFunzionalita $Config.Stati @(Get-AdoFigliFeature -FigliIds @($f.FigliIds)))
    if ($d52 -and $f.Area -ine $Area) { throw "l'area '$Area' e diversa da quella della Feature $Feature ('$($f.Area)'): una funzionalita con la card di chiusura sta in un'area sola" }
}

# Una card appena nata deve essere in bozza: solo allora le si da il tag agenti (e gli altri), cioe il via agli agenti.
# StatoIniziale (D52, gruppo 5): la chiave dello stato in cui la card nasce, nella stessa scrittura dei tag (nuova: la correzione tecnica,
# che il responsabile prende da New; pronto: la Bug allinea-develop, che parte da dev). Lo usano solo le Bug che crea lo smistatore:
# New-Card, cioe card.ps1 crea, non lo espone. Senza, resta in bozza e il via lo da una persona.
function Set-TagCardNata($Config, $Card, [string[]]$Tag, [string]$StatoIniziale) {
    if ($Card.Stato -ne $Config.Stati.bozza) {
        throw "La card $($Card.Id) e nata nello stato '$($Card.Stato)' invece di '$($Config.Stati.bozza)': non la sposto e non le do il tag $($Config.Stati.tagAgenti), controllare a mano"
    }
    if ($StatoIniziale) { [void](Set-AdoCard -Id $Card.Id -AggiungiTag $Tag -Stato $Config.Stati.$StatoIniziale) }
    else { [void](Set-AdoCard -Id $Card.Id -AggiungiTag $Tag) }
}

function New-Card {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tipo,
        [Parameter(Mandatory)][string]$Titolo,
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$File,
        # Gli id delle card che devono essere unite prima di questa (link Predecessor).
        [int[]]$Dopo,
        # Niente da provare nell'ambiente di Test: dopo la revisione la card va dritta in Ready to merge.
        [switch]$SenzaTest,
        # In Human test la prova una persona (il richiedente), non il collaudatore.
        [switch]$ProvaUmana,
        # D52, con -Tipo Feature: la funzionalita e una correzione (tag bug sulla Feature, ramo bugfix/...).
        [switch]$Bug,
        # D60, con -Tipo Feature: la Feature raggruppa soltanto (priorita e pausa), senza card di chiusura: le sue card vanno in develop una per una.
        [switch]$Raggruppa,
        # D52: l'id della Feature di cui la card e una figlia.
        [int]$Feature
    )
    if (-not [string]::IsNullOrWhiteSpace($env:ATTREZZI_RUOLO)) {
        throw "'crea' non e permesso dentro una sessione di ruolo"
    }
    $config = Get-Config
    $creaFeature = $Tipo -eq 'Feature'
    $figlia = $PSBoundParameters.ContainsKey('Feature')
    # D52 e costruita a gruppi: finche l'interruttore e spento nessuna Feature nasce e nessuna card si lega a una Feature.
    if (($creaFeature -or $figlia) -and -not $config.Limiti.funzionalitaAttive) {
        throw 'D52 non è ancora attiva: nessuna Feature si crea e nessuna card si lega a una Feature (funzionalitaAttive in config/limiti.json)'
    }
    if ($Tipo -notin @('User Story', 'Bug', 'Feature')) { throw "Tipo non valido: '$Tipo' (User Story | Bug | Feature)" }
    if ($Bug -and -not $creaFeature) { throw '-Bug vale solo con -Tipo Feature: segna la funzionalita come correzione' }
    if ($Raggruppa -and -not $creaFeature) { throw '-Raggruppa vale solo con -Tipo Feature' }
    if ($Raggruppa -and $Bug) { throw '-Raggruppa e -Bug non vanno insieme: -Bug riguarda il ramo della funzionalita, che una Feature che raggruppa non ha' }
    if ($figlia -and $Feature -le 0) { throw "-Feature vuole l'id di una Feature: '$Feature'" }
    if ($creaFeature) {
        if ($figlia) { throw 'una Feature non ha una Feature padre: -Feature non vale con -Tipo Feature' }
        foreach ($n in 'Dopo', 'SenzaTest', 'ProvaUmana') {
            if ($PSBoundParameters.ContainsKey($n)) { throw "-$n non vale con -Tipo Feature: la Feature non ha ne un ordine ne una prova sua" }
        }
    }
    if (-not (Test-Path -LiteralPath $File)) { throw "File non trovato: '$File'" }

    $sezioni = @{}
    $corrente = $null
    foreach ($riga in (Get-Content -LiteralPath $File -Encoding UTF8)) {
        if ($riga -match '^##\s+(.+?)\s*$') { $corrente = $Matches[1]; $sezioni[$corrente] = [System.Collections.Generic.List[string]]::new(); continue }
        if ($null -ne $corrente) { $sezioni[$corrente].Add($riga) }
    }
    $testo = @{}
    foreach ($nome in 'Descrizione', 'Criteri di accettazione', 'Recinto', 'Riferimenti') {
        if (-not $sezioni.ContainsKey($nome)) { throw "Manca la sezione '## $nome' nel file" }
        $t = ($sezioni[$nome] -join "`n").Trim()
        if (-not $t) { throw "La sezione '## $nome' e vuota" }
        $testo[$nome] = $t
    }

    [void](Get-VoceMappa -Area $Area -Mappa $config.Mappa)
    # D60: ogni card sta in una funzionalita. Una card senza Feature lo smistatore non la fa partire da New.
    if (-not $creaFeature -and -not $figlia) { throw "ogni card sta in una Feature: serve -Feature <id>. Se la Feature non c'e, creala prima: -Tipo Feature -Raggruppa per raggruppare card che vanno in develop una per una, -Tipo Feature per una funzionalita D52 da provare intera" }
    if ($figlia) { Assert-FeatureAccetta $config $Feature $Area }

    $descrizione = "## Descrizione`n$($testo['Descrizione'])`n`n## Recinto`n$($testo['Recinto'])`n`n## Riferimenti`n$($testo['Riferimenti'])"
    # Senza tag: il tag agenti e il via agli agenti, lo si da solo dopo aver visto che la card e nata in bozza.
    # Assegnata a chi la crea: solo lo smistatore del suo utente la fa avanzare, con il suo traffico (spec, sezione 19).
    $io = Get-AdoUtenteCorrente
    if ([string]::IsNullOrWhiteSpace($io.Email)) {
        throw "Non trovo l'indirizzo dell'utente del PAT: la card nascerebbe senza assegnatario e nessuno smistatore la prenderebbe. Non la creo"
    }
    $criteri = $testo['Criteri di accettazione']

    if ($creaFeature) {
        # La Feature non si fa avanzare da uno smistatore: niente tag agenti. Il tag bug (con -Bug) c'e fin dalla nascita.
        $tagFeature = @(if ($Bug) { $config.Stati.tagBugFeature })
        $f = New-AdoCard -Tipo 'Feature' -Titolo $Titolo -Area $Area -Descrizione $descrizione -AssegnataA $io.Email -Tag $tagFeature
        if ($Raggruppa) { return [pscustomobject]@{ Id = $f.Id; Chiusura = $null } }
        # La card di chiusura: figlia della Feature, senza codice suo, con i criteri della funzionalita intera (la Feature non ha il campo).
        $chiusura = $null
        try {
            $chiusura = New-AdoCard -Tipo 'User Story' -Titolo "Collaudo funzionalità: $Titolo" -Area $Area -Descrizione $descrizione `
                -Criteri $criteri -AssegnataA $io.Email -Padre $f.Id
            Set-TagCardNata $config $chiusura @($config.Stati.tagAgenti, $config.Stati.tagChiusura)
        }
        catch {
            $stato = if ($chiusura) { "la card di chiusura $($chiusura.Id) e nata ma non e a posto" } else { 'la sua card di chiusura no' }
            throw "La Feature $($f.Id) e nata ma ${stato}: $($_.Exception.Message). Non creare un'altra Feature: la card di chiusura va completata a mano (figlia della Feature $($f.Id), tag $($config.Stati.tagAgenti) e $($config.Stati.tagChiusura))"
        }
        return [pscustomobject]@{ Id = $f.Id; Chiusura = $chiusura }
    }

    $padre = @{}
    if ($figlia) { $padre.Padre = $Feature }
    $card = New-AdoCard -Tipo $Tipo -Titolo $Titolo -Area $Area -Descrizione $descrizione `
        -Criteri $criteri -AssegnataA $io.Email -Dopo $Dopo @padre
    # no-test-deploy deciso nell'analisi: niente da provare nell'ambiente di Test, dopo la revisione dritta in Ready to merge
    $tag = @($config.Stati.tagAgenti) + @(if ($SenzaTest) { $config.Stati.tagSenzaTest }) + @(if ($ProvaUmana) { $config.Stati.tagProvaUmana })
    Set-TagCardNata $config $card $tag
    $card
}

# D52, gruppo 5: le Bug che crea lo smistatore, figlie della Feature e nell'area della Feature (una funzionalita sta in un'area sola).
# Senza l'indirizzo dell'utente la Bug nascerebbe senza padrone e nessuno smistatore la prenderebbe: non si crea (come New-Card).
# DopoNascita (un blocco, riceve la Bug): gira appena la Bug esiste, prima di tag e stato. Lo smistatore ci scrive il commento che segna
# la Bug sulla card di chiusura: se tag o stato falliscono la Bug resta a meta, ma il nuovo tentativo sa che c'e e non ne crea un'altra;
# l'errore dice cosa completare a mano. La configurazione la da chi chiama.
function New-BugDellaFunzionalita($Config, $Feature, [string]$Titolo, [string]$Descrizione, [string]$Criteri, [string]$AssegnataA, [string[]]$Tag, [string]$StatoIniziale, [scriptblock]$DopoNascita) {
    if ([string]::IsNullOrWhiteSpace($AssegnataA)) {
        throw "Non trovo l'indirizzo dell'utente dello smistatore: la Bug nascerebbe senza assegnatario e nessuno smistatore la prenderebbe. Non la creo"
    }
    $parametri = @{ Tipo = 'Bug'; Titolo = $Titolo; Area = [string]$Feature.Area; Descrizione = $Descrizione; AssegnataA = $AssegnataA; Padre = [int]$Feature.Id }
    if ($Criteri) { $parametri.Criteri = $Criteri }
    $bug = New-AdoCard @parametri
    try {
        if ($DopoNascita) { [void](& $DopoNascita $bug) }
        Set-TagCardNata $Config $bug $Tag -StatoIniziale $StatoIniziale
    }
    catch {
        $stato = if ($StatoIniziale) { $Config.Stati.$StatoIniziale } else { $Config.Stati.bozza }
        throw "La Bug $($bug.Id) e nata ma non e a posto: $($_.Exception.Message). Non ricrearla: completarla a mano (tag $($Tag -join ' e '), stato $stato)"
    }
    $bug
}

# La Bug di una correzione scritta dal responsabile (Get-CorrezioniScritte): titolo e descrizione sono i suoi. Tecnica: nasce in New con il tag
# agenti, il responsabile della Bug ne scrive i criteri. Di prodotto: resta in bozza (con il tag agenti, come ogni card appena nata) finche
# la persona che deve scegliere non la porta in New.
function New-CardCorrezioneFunzionalita {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Feature,
        [Parameter(Mandatory)][int]$Chiusura,
        [Parameter(Mandatory)]$Correzione,
        [string]$AssegnataA,
        [scriptblock]$DopoNascita
    )
    $descrizione = "## Descrizione`n$($Correzione.Descrizione)`n`n## Riferimenti`nCorrezione della funzionalita '$($Feature.Titolo)' (Feature #$($Feature.Id)), scritta dal responsabile sulla card di chiusura #$Chiusura."
    $iniziale = if ($Correzione.Tipo -eq 'tecnico') { 'nuova' } else { '' }
    New-BugDellaFunzionalita $Config $Feature ([string]$Correzione.Titolo) $descrizione $null $AssegnataA @($Config.Stati.tagAgenti) $iniziale $DopoNascita
}

# La Bug che allinea il ramo della funzionalita a develop quando la PR ramo -> develop e in conflitto: tecnica, con i tag agenti e
# allinea-develop, e nasce in Ready to develop: ha gia i criteri e non serve il responsabile, parte dev (il suo dev unisce origin/develop
# nel ramo della card, il reviewer ne guarda solo la risoluzione).
function New-CardAllineaDevelop {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Feature, [Parameter(Mandatory)][string]$Ramo, [string]$AssegnataA, [scriptblock]$DopoNascita)
    $descrizione = "## Descrizione`nLa PR $Ramo → develop della funzionalita (Feature #$($Feature.Id)) ha conflitti con develop e non si puo unire.`n`n" +
        "Unisci origin/develop nel ramo di questa card (nato da $Ramo) con un merge, mai con rebase, e risolvi i conflitti tenendo il comportamento di tutte e due le parti. " +
        "La PR di questa card va verso $Ramo."
    New-BugDellaFunzionalita $Config $Feature "Allinea $Ramo a develop" $descrizione "la PR $Ramo → develop non ha conflitti" $AssegnataA `
        @($Config.Stati.tagAgenti, $Config.Stati.tagAllinea) 'pronto' $DopoNascita
}
Export-ModuleMember -Function Add-CardCorrezione, New-CardCorrezioneFunzionalita, New-CardAllineaDevelop, Set-CardDeploy, Set-CardTitoloPr, Set-CardDescrizionePr, Read-Card, Add-CardCommento, Set-CardCriteri, Set-CardSenzaTest, Set-CardProvaUmana, Move-Card, New-Card, New-CardTask, Close-CardTask
