Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global

# La memoria dei ruoli (D46): le funzioni pure sul formato delle lezioni. Nessun git, nessun Azure DevOps, nessun file:
# lavorano su testi. Chi legge e scrive i file e memoria.ps1; qui sta cio che il formato e le regole decidono.
#
# Un file e una sequenza di blocchi separati da una riga vuota:
#   ### <ruolo>-<NNN>
#   - Situazione: ...
#   - Cosa fare: ...
#   - Perché: ...
#   - Card: <id>

# I quattro campi: la chiave del JSON che arriva su stdin e l'etichetta nel file. Il nome di un campo sta solo qui.
$script:Campi = @(
    @{ Chiave = 'situazione'; Etichetta = 'Situazione'; Proprieta = 'Situazione' }
    @{ Chiave = 'cosaFare'; Etichetta = 'Cosa fare'; Proprieta = 'CosaFare' }
    @{ Chiave = 'perche'; Etichetta = 'Perché'; Proprieta = 'Perche' }
    @{ Chiave = 'card'; Etichetta = 'Card'; Proprieta = 'Card' }
)
$script:EtichettaInProva = '(in prova)'
# L'etichetta serve anche a chi riconosce le righe LEZIONE: del ruolo (Sessioni.psm1), che copia il titolo come lo vede.
function Get-EtichettaInProva { $script:EtichettaInProva }
$script:TitoloConflitti = '## Conflitti con le regole scritte'

function ConvertTo-TestoLezione {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Situazione, [Parameter(Mandatory)][string]$CosaFare,
        [Parameter(Mandatory)][string]$Perche, [Parameter(Mandatory)][string]$Card
    )
    $valori = @{ Situazione = $Situazione; CosaFare = $CosaFare; Perche = $Perche; Card = $Card }
    $righe = @("### $Id") + @($script:Campi | ForEach-Object { "- $($_.Etichetta): $($valori[$_.Proprieta])" })
    $righe -join "`n"
}

# Un testo in lezioni. Un blocco comincia con "### <ruolo>-<NNN>"; un titolo che non ha quella forma non e una lezione
# e il suo testo non si attribuisce alla lezione prima. Testo e il blocco com'e, senza spazi a fine riga: serve a
# riconoscere una lezione identica su develop.
function Read-Lezioni {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Testo)
    if ([string]::IsNullOrWhiteSpace($Testo)) { return @() }
    $blocchi = [System.Collections.Generic.List[object]]::new()
    $corrente = $null
    foreach ($riga in ($Testo -split "`r?`n")) {
        $r = $riga.TrimEnd()
        if ($r -match '^###\s') {
            $corrente = [System.Collections.Generic.List[string]]::new()
            $blocchi.Add($corrente)
        }
        if ($null -ne $corrente) { $corrente.Add($r) }
    }
    foreach ($b in $blocchi) {
        if ($b[0] -notmatch '^###\s+(.+)-(\d+)\s*$') { continue }
        $ruolo = $Matches[1]; $numero = [int]$Matches[2]
        $righe = @($b)
        while ($righe.Count -gt 1 -and $righe[-1] -eq '') { $righe = @($righe[0..($righe.Count - 2)]) }
        $lezione = [ordered]@{ Id = "$ruolo-$($Matches[2])"; Ruolo = $ruolo; Numero = $numero }
        foreach ($c in $script:Campi) {
            $trovata = $righe | Where-Object { $_ -match ('^- ' + [regex]::Escape($c.Etichetta) + ':\s*(.*)$') } | Select-Object -First 1
            $lezione[$c.Proprieta] = if ($trovata) { ($trovata -replace ('^- ' + [regex]::Escape($c.Etichetta) + ':\s*'), '') } else { '' }
        }
        $lezione.Testo = $righe -join "`n"
        [pscustomobject]$lezione
    }
}

# Gli errori dei quattro campi, uno per campo; nessuno se la lezione e a posto. Una riga per campo perche il formato ne
# ha una: un a capo dentro un campo spezzerebbe il blocco.
function Test-CampiLezione {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Campi)
    foreach ($c in $script:Campi) {
        $v = Get-Campo $Campi $c.Chiave
        if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { "manca il campo '$($c.Chiave)' o e vuoto" }
        elseif (([string]$v) -match '[\r\n]') { "il campo '$($c.Chiave)' va scritto su una riga sola" }
    }
}

# Il massimo fra le lezioni del ruolo nei testi dati (tutti i file del ruolo, anche su develop) piu uno.
function Get-ProssimoIdLezione {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Ruolo, [AllowNull()][AllowEmptyCollection()][string[]]$Testi)
    $massimo = 0
    foreach ($t in @($Testi)) {
        foreach ($l in @(Read-Lezioni $t)) {
            if ($l.Ruolo -eq $Ruolo -and $l.Numero -gt $massimo) { $massimo = $l.Numero }
        }
    }
    '{0}-{1:000}' -f $Ruolo, ($massimo + 1)
}

# Vero se il file ha gia il numero di lezioni del tetto: una in piu e oltre.
function Test-MemoriaPiena {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Testo, [Parameter(Mandatory)][int]$Tetto)
    @(Read-Lezioni $Testo).Count -ge $Tetto
}

function Join-Blocchi($Blocchi) {
    $b = @($Blocchi)
    if ($b.Count -eq 0) { return '' }
    ($b -join "`n`n") + "`n"
}

function Add-LezioneAlTesto {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Testo, [Parameter(Mandatory)][string]$Lezione)
    Join-Blocchi (@(Read-Lezioni $Testo | ForEach-Object { $_.Testo }) + @($Lezione))
}

# Null se l'id non c'e: decide chi chiama quale errore dare.
function Set-LezioneNelTesto {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Testo, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Lezione)
    $l = @(Read-Lezioni $Testo)
    if (-not ($l | Where-Object Id -eq $Id)) { return $null }
    Join-Blocchi @($l | ForEach-Object { if ($_.Id -eq $Id) { $Lezione } else { $_.Testo } })
}

function Remove-LezioneDalTesto {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Testo, [Parameter(Mandatory)][string]$Id)
    $l = @(Read-Lezioni $Testo)
    if (-not ($l | Where-Object Id -eq $Id)) { return $null }
    Join-Blocchi @($l | Where-Object Id -ne $Id | ForEach-Object { $_.Testo })
}

# Le lezioni di un file con l'etichetta in prova. Si parte dalla versione del ramo in prova se c'e ($null = il ramo o il
# file non c'e), altrimenti da develop: una lezione tolta sul ramo non si mostra piu. In prova e una lezione il cui
# blocco (id + testo) non c'e identico su develop; il confronto distingue le maiuscole (-cnotin: -notin non le distingue). Prende testi, non legge git: la compone anche chi avvia le sessioni.
function Get-LezioniConEtichetta {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Develop, [AllowNull()][AllowEmptyString()]$InProva)
    $stabili = @(Read-Lezioni $Develop | ForEach-Object { $_.Testo })
    $base = if ($null -eq $InProva) { $Develop } else { $InProva }
    foreach ($l in @(Read-Lezioni $base)) {
        Add-Member -InputObject $l -NotePropertyName InProva -NotePropertyValue ($l.Testo -cnotin $stabili) -PassThru
    }
}

# Le lezioni come testo da leggere: il titolo di una lezione in prova porta l'etichetta.
function ConvertTo-TestoLezioni {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()]$Lezioni)
    Join-Blocchi @(@($Lezioni) | ForEach-Object {
            if ($_.InProva) { ($_.Testo -replace '^([^\n]*)', "`$1 $script:EtichettaInProva") } else { $_.Testo }
        })
}

# Il brief di un ruolo con in fondo le sue lezioni: prima quelle di comune, poi quelle del repo, le in prova marcate.
# File e l'elenco {Nome, Develop, InProva} di Get-MemoriaDelRuolo (testi, $null dove il file o il ramo non c'e). Senza
# nessuna lezione restituisce il brief com'e: la sezione Memoria non compare nemmeno vuota. Cosa sia la sezione e come
# si usa lo dice il brief del ruolo, qui ci sono solo i titoli.
function New-BriefConMemoria {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Brief, [AllowNull()][AllowEmptyCollection()]$File)
    $comune = @(@($File) | Where-Object { $null -ne $_ -and $_.Nome -eq 'comune' })
    $repo = @(@($File) | Where-Object { $null -ne $_ -and $_.Nome -ne 'comune' })
    $sezioni = foreach ($f in @($comune) + @($repo)) {
        $lezioni = @(Get-LezioniConEtichetta -Develop $f.Develop -InProva $f.InProva)
        if ($lezioni.Count -eq 0) { continue }
        $titolo = if ($f.Nome -eq 'comune') { '## Lezioni comuni a tutti i repo' } else { "## Lezioni del repo $($f.Nome)" }
        "$titolo`n`n$((ConvertTo-TestoLezioni $lezioni).TrimEnd())"
    }
    if (@($sezioni).Count -eq 0) { return $Brief }
    "$($Brief.TrimEnd())`n`n# Memoria`n`n$(@($sezioni) -join "`n`n")`n"
}

# ---- il riassunto dell'apprendimento (D46, "Misura") ----------------------------------------------------------------
# Dalle righe del registro (Get-RigheApprendimento) a quello che mostrano la vista e la descrizione della PR della memoria:
# e il solo posto del calcolo, i due lo leggono da qui.
#
# Per ruolo e per settimana ISO (da lunedi, in UTC come le date del registro): blocchi, on-hold, correzioni e lezioni
# applicate. La finestra e di $script:SettimaneRiassunto settimane intere prima di quella di $Adesso, piu quella di $Adesso:
# una sola costante: vista e PR non passano -Settimane, e il testo da mostrare e nel riassunto (Finestra). Una riga di tipo
# sconosciuto, senza ruolo, con la data illeggibile o con la card non numerica o vuota si ignora: il registro lo scrivono altri
# (anche a mano) e una riga rotta non deve far sparire la tabella.
#
# Una lezione L ha "evitato un blocco" quando una riga lezioneApplicata (ruolo R, card C) rispetta tutte e tre:
#  - C non e la card d'origine di L (il campo Card della lezione): sulla card d'origine il blocco e stato visto, su un'altra
#    la lezione l'ha anticipato. Le origini arrivano in $LezioniConosciute (id -> card, ConvertTo-LezioniConosciute): una
#    lezione di cui non si conosce l'origine non conta;
#  - la sessione in cui e stata applicata non e finita 'bloccato' o 'bivio': lo dice il campo esito della riga, scritto da chi
#    chiude la sessione, perche l'ordine dei millisecondi fra la riga di blocco e questa non e un criterio;
#  - dopo di lei R non ha su C una riga blocco, onHold o correzione (la correzione del reviewer e proprio il fallimento che
#    la lezione doveva evitare).
# Non prova che sia stata la lezione: dice che dove e stata seguita il ruolo non si e fermato. Il conto e "finora": una card
# ancora aperta puo cambiarlo. Una lezione applicata piu volte sulla stessa card conta una volta.
$script:TipiApprendimento = @('blocco', 'onHold', 'correzione', 'lezioneApplicata')
$script:TipiStop = @('blocco', 'onHold', 'correzione')
$script:EsitiBloccati = @('bloccato', 'bivio')
$script:SettimaneRiassunto = 4

function Get-TestoFinestraRiassunto([int]$Settimane) { "ultime $Settimane settimane intere piu quella in corso" }

function Get-LunediIso([datetime]$Data) { $d = $Data.Date; $d.AddDays(-(([int]$d.DayOfWeek + 6) % 7)) }

# Id -> card d'origine di ogni lezione data (stabili e in prova, di tutti i ruoli). Un'origine che non e un numero non entra:
# la lezione resta sconosciuta e non conta come evitata.
function ConvertTo-LezioniConosciute {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()]$Lezioni)
    $conosciute = @{}
    foreach ($l in @($Lezioni)) {
        if ($null -eq $l) { continue }
        $card = 0
        if ([int]::TryParse(([string](Get-Campo $l 'Card')).Trim(), [ref]$card)) { $conosciute[[string](Get-Campo $l 'Id')] = $card }
    }
    $conosciute
}

# Il valore calcolato per $Chiave, ricalcolato solo se la chiave cambia: chi ridisegna a ogni giro non rifa il conto sullo stesso
# registro. $Cache e un hashtable di chi chiama (uno per processo di vista, niente stato nel modulo che un altro processo o un
# altro test si ritrovi); $Calcola riceve $Argomenti. Se lancia, niente si memorizza.
function Get-RiassuntoDallaCache([hashtable]$Cache, [string]$Chiave, [scriptblock]$Calcola, [object[]]$Argomenti = @()) {
    if ($Cache.ContainsKey('Chiave') -and $Cache.Chiave -ceq $Chiave) { return $Cache.Valore }
    $valore = & $Calcola @Argomenti
    $Cache.Chiave = $Chiave; $Cache.Valore = $valore
    $valore
}

function Get-RiassuntoApprendimento {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()]$Righe,
        [datetime]$Adesso = [datetime]::UtcNow,
        [int]$Settimane = $script:SettimaneRiassunto,
        [AllowNull()][System.Collections.IDictionary]$LezioniConosciute = $null
    )
    $valide = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($Righe)) {
        if ($null -eq $r) { continue }
        $tipo = [string](Get-Campo $r 'tipo'); $ruolo = [string](Get-Campo $r 'ruolo')
        $data = ConvertTo-DataUtc (Get-Campo $r 'data')
        $card = 0
        if ($tipo -notin $script:TipiApprendimento -or [string]::IsNullOrWhiteSpace($ruolo) -or $null -eq $data) { continue }
        if (-not [int]::TryParse(([string](Get-Campo $r 'card')).Trim(), [ref]$card)) { continue }
        $valide.Add([pscustomobject]@{ Tipo = $tipo; Ruolo = $ruolo; Data = $data; Card = $card; Lezione = [string](Get-Campo $r 'lezione'); Esito = [string](Get-Campo $r 'esito') })
    }
    # L'ultimo stop di ogni ruolo|card, costruito una volta: la ricerca per ogni lezione applicata e un accesso al dizionario.
    $ultimoStop = @{}
    foreach ($v in $valide) {
        if ($v.Tipo -notin $script:TipiStop) { continue }
        $k = "$($v.Ruolo)|$($v.Card)"
        if (-not $ultimoStop.ContainsKey($k) -or $v.Data -gt $ultimoStop[$k]) { $ultimoStop[$k] = $v.Data }
    }
    $primo = (Get-LunediIso $Adesso.ToUniversalTime()).AddDays(-7 * [math]::Max($Settimane, 0))
    $celle = @{}
    $evitati = @{}
    foreach ($v in $valide) {
        if ($v.Data -lt $primo) { continue }
        $lunedi = Get-LunediIso $v.Data
        $k = '{0:yyyy-MM-dd}|{1}' -f $lunedi, $v.Ruolo
        if (-not $celle.ContainsKey($k)) {
            $celle[$k] = [pscustomobject]@{
                Lunedi = $lunedi.ToString('yyyy-MM-dd')
                Settimana = ('{0}-W{1:00}' -f [Globalization.ISOWeek]::GetYear($lunedi), [Globalization.ISOWeek]::GetWeekOfYear($lunedi))
                Ruolo = $v.Ruolo; Blocchi = 0; OnHold = 0; Correzioni = 0; LezioniApplicate = 0
            }
        }
        $cella = $celle[$k]
        switch ($v.Tipo) {
            'blocco' { $cella.Blocchi++ }
            'onHold' { $cella.OnHold++ }
            'correzione' { $cella.Correzioni++ }
            'lezioneApplicata' { $cella.LezioniApplicate++ }
        }
        if ($v.Tipo -ne 'lezioneApplicata' -or -not $v.Lezione) { continue }
        if ($null -eq $LezioniConosciute -or -not $LezioniConosciute.Contains($v.Lezione)) { continue }
        if ($v.Card -eq [int]$LezioniConosciute[$v.Lezione]) { continue }
        if ($v.Esito -in $script:EsitiBloccati) { continue }
        $stop = $ultimoStop["$($v.Ruolo)|$($v.Card)"]
        if ($null -ne $stop -and $stop -gt $v.Data) { continue }
        $ek = "$($v.Ruolo)|$($v.Lezione)"
        if (-not $evitati.ContainsKey($ek)) { $evitati[$ek] = [pscustomobject]@{ Ruolo = $v.Ruolo; Lezione = $v.Lezione; Card = [System.Collections.Generic.SortedSet[int]]::new() } }
        [void]$evitati[$ek].Card.Add($v.Card)
    }
    [pscustomobject]@{
        Settimane = $Settimane; Finestra = (Get-TestoFinestraRiassunto $Settimane)
        Righe = @($celle.Values | Sort-Object @{ e = 'Lunedi'; Descending = $true }, Ruolo)
        Evitati = @($evitati.Values | ForEach-Object { [pscustomobject]@{ Ruolo = $_.Ruolo; Lezione = $_.Lezione; Card = @($_.Card) } } | Sort-Object Ruolo, Lezione)
    }
}

# Il riassunto in righe di testo per la descrizione della PR: i totali per ruolo sulle settimane del riassunto e le lezioni
# che hanno evitato un blocco. Prima la testata e i totali, poi gli evitati: chi taglia lo fa dalla coda.
function Get-RigheRiassuntoPr($Riassunto) {
    if ($null -eq $Riassunto -or (@($Riassunto.Righe).Count -eq 0 -and @($Riassunto.Evitati).Count -eq 0)) { return @() }
    $righe = [System.Collections.Generic.List[string]]::new()
    $righe.Add("## Apprendimento ($($Riassunto.Finestra))")
    foreach ($g in @($Riassunto.Righe | Group-Object Ruolo | Sort-Object Name)) {
        $somma = { param($p) [int](($g.Group | Measure-Object $p -Sum).Sum) }
        $righe.Add("- $($g.Name): $(& $somma 'Blocchi') blocchi, $(& $somma 'OnHold') on-hold, $(& $somma 'Correzioni') correzioni, $(& $somma 'LezioniApplicate') lezioni applicate")
    }
    if (@($Riassunto.Evitati).Count -gt 0) {
        $righe.Add('Lezioni che hanno evitato un blocco finora (applicate su una card diversa da quella d''origine, e il ruolo non si e fermato):')
        foreach ($e in @($Riassunto.Evitati)) { $righe.Add("- $($e.Lezione) ($($e.Ruolo)): card $(@($e.Card) -join ', ')") }
    }
    $righe
}

# Aggiunge in coda al testo le righe del riassunto finche stanno nel limite: la testata da sola non dice niente, quindi si
# parte da testata piu una riga, e se nemmeno quelle ci stanno non si aggiunge nulla.
function Add-RiassuntoAllaDescrizione([string]$Testo, [string[]]$Righe, [int]$Limite) {
    $out = $Testo
    for ($n = 2; $n -le @($Righe).Count; $n++) {
        $candidato = "$Testo`n`n" + (@($Righe)[0..($n - 1)] -join "`n")
        if ($candidato.Length -gt $Limite) { break }
        $out = $candidato
    }
    $out
}

# La descrizione della PR della memoria: le lezioni in prova (id e situazione) e le note di conflitto con le regole
# scritte, una riga ciascuna, e in coda il riassunto dell'apprendimento (Get-RiassuntoApprendimento) se c'e.
# Azure DevOps rifiuta una descrizione oltre il suo limite, e una PR che non si aggiorna e una lezione che nessuno vede:
# $Limite e il massimo del testo, lo dice Ado.psm1 (Get-AdoLimiteTestoPr) perche e lui ad aggiungere la firma. Se non ci
# sta, si omettono le lezioni piu vecchie (numero piu basso) e la descrizione lo dice. Le note di conflitto restano
# sempre, perche sono la parte che un umano deve leggere; le identiche non si ripetono. Il riassunto ha la priorita piu
# bassa: entra solo con lo spazio che resta, riga per riga dall'alto.
function New-DescrizionePrMemoria {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()]$LezioniInProva, [AllowNull()][AllowEmptyCollection()][string[]]$Conflitti, $Riassunto = $null, [Parameter(Mandatory)][int]$Limite)
    $note = @($Conflitti | Where-Object { $_ } | ForEach-Object { (($_ -split '\s*\r?\n\s*') -join ' ').Trim() } | Select-Object -Unique)
    $tutte = @($LezioniInProva)
    $costruisci = {
        param($mostrate, [int]$omesse)
        $righe = [System.Collections.Generic.List[string]]::new()
        $righe.Add('Lezioni dei ruoli in prova (D46): alla fusione diventano stabili.')
        $righe.Add('')
        $righe.Add('## Lezioni in prova')
        if ($tutte.Count -eq 0) { $righe.Add('Nessuna lezione in prova.') }
        foreach ($x in $mostrate) { $righe.Add("- $($x.Id): $($x.Situazione)") }
        if ($omesse -gt 0) { $righe.Add("- (altre $omesse lezioni in prova, le piu vecchie, non elencate: la descrizione ha un limite di $Limite caratteri)") }
        if ($note.Count -gt 0) {
            $righe.Add('')
            $righe.Add($script:TitoloConflitti)
            foreach ($n in $note) { $righe.Add("- $n") }
        }
        $righe -join "`n"
    }
    $mostrate = [System.Collections.Generic.List[object]]::new($tutte)
    $testo = & $costruisci $mostrate 0
    $riassunto = Get-RigheRiassuntoPr $Riassunto
    if ($testo.Length -le $Limite) { return (Add-RiassuntoAllaDescrizione $testo $riassunto $Limite) }
    # dalla piu vecchia: a parita di numero (ruoli diversi) resta l'ordine in cui sono arrivate
    $ordine = @($tutte | ForEach-Object -Begin { $i = 0 } -Process { [pscustomobject]@{ L = $_; I = $i++ } } | Sort-Object { [int]$_.L.Numero }, I)
    $omesse = 0
    foreach ($o in $ordine) {
        [void]$mostrate.Remove($o.L)
        $omesse++
        $testo = & $costruisci $mostrate $omesse
        if ($testo.Length -le $Limite) { break }
    }
    Add-RiassuntoAllaDescrizione $testo $riassunto $Limite
}

# Le note di conflitto gia nella descrizione di una PR: le righe "- ..." sotto il titolo della sezione.
function Get-NoteConflitto {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Descrizione)
    if ([string]::IsNullOrWhiteSpace($Descrizione)) { return @() }
    $dentro = $false
    foreach ($riga in ($Descrizione -split "`r?`n")) {
        if ($riga.Trim() -eq $script:TitoloConflitti) { $dentro = $true; continue }
        if (-not $dentro) { continue }
        if ($riga -match '^- (.+)$') { $Matches[1].Trim() } else { break }
    }
}

Export-ModuleMember -Function Get-EtichettaInProva, ConvertTo-TestoLezione, Read-Lezioni, Test-CampiLezione, Get-ProssimoIdLezione, Test-MemoriaPiena,
    Add-LezioneAlTesto, Set-LezioneNelTesto, Remove-LezioneDalTesto, Get-LezioniConEtichetta, ConvertTo-TestoLezioni, New-BriefConMemoria,
    New-DescrizionePrMemoria, Get-NoteConflitto, Get-RiassuntoApprendimento, ConvertTo-LezioniConosciute, Get-RiassuntoDallaCache
