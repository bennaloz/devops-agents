#requires -Version 7
# L'ufficio: cosa fa ogni personaggio (al PC, alla macchinetta del caffe, a parlare con un altro). Funzione pura: riceve
# le stesse righe che la vista usa (sessioni in corso, coda) e lo stato locale (stato.json), non legge disco ne rete e non
# guarda l'orologio: l'ora la riceve. La pagina (VistaUfficioPagina.psm1) la disegna e non decide nulla da sola.
#
# Le regole, in breve:
#  - un ruolo con una sessione sta al PC, sulla card della sessione piu piccola; le altre sessioni dello stesso ruolo si contano;
#  - un ruolo senza sessione sta al caffe;
#  - una consegna e una card il cui ultimo ruolo che l'ha lavorata (ultimoRuolo nello stato) e diverso da quello che la lavora
#    adesso (la sessione in corso, o il ruolo in coda): la sessione di quell'ultimo ruolo e finita, e finita entro la finestra;
#  - in una consegna i due si parlano: chi non ha una sessione sta a parlare, chi ha la sessione sulla card sta al PC con
#    l'altro accanto. Una consegna non si fa se uno dei due e occupato su un'altra card (non puo lasciare il suo PC);
#  - un ruolo gia in una consegna non ne apre una seconda: la prima vince, in ordine di card.
#  - un ruolo fuori dall'elenco (il supervisore, per esempio) non ha personaggio e non entra nelle consegne.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global

# $Ruoli: i ruoli con un personaggio, nell'ordine in cui stanno in pagina. $InCorso: righe con Id, Ruolo, Titolo, Task, TitoloTask
# (Get-SessioniVista). $Coda: righe con Id, Ruolo, Titolo (Get-ModelloVista). $Stato: stato.json (chiave = id della card, come
# stringa). $Adesso: l'ora del disegno, in UTC. $FinestraMinuti: per quanti minuti dopo la fine della sessione di A la consegna
# resta visibile.
function Get-PostazioniUfficio {
    [CmdletBinding()]
    param(
        [string[]]$Ruoli,
        [object[]]$InCorso = @(),
        [object[]]$Coda = @(),
        [hashtable]$Stato = @{},
        [datetime]$Adesso,
        [int]$FinestraMinuti = 60
    )
    $ruoliOk = @($Ruoli)
    $sessioniPer = @{}                       # ruolo -> id delle card su cui siede, in ordine
    foreach ($r in $ruoliOk) { $sessioniPer[$r] = @() }
    $titoli = @{}                            # id card -> titolo
    $lavoratore = @{}                        # id card -> ruolo che la lavora adesso (sessione) o la prende (coda)
    foreach ($s in @($InCorso | Sort-Object { [int](Get-Campo $_ 'Id') })) {
        $r = [string](Get-Campo $s 'Ruolo'); $k = "$(Get-Campo $s 'Id')"
        $titoli[$k] = Get-Campo $s 'Titolo'
        if ($r -notin $ruoliOk) { continue }
        if (-not $sessioniPer.ContainsKey($r)) { $sessioniPer[$r] = @() }
        $sessioniPer[$r] += [int]$k
        $lavoratore[$k] = $r
    }
    foreach ($c in @($Coda)) {
        $k = "$(Get-Campo $c 'Id')"
        if (-not $titoli.ContainsKey($k)) { $titoli[$k] = Get-Campo $c 'Titolo' }
        if (-not $lavoratore.ContainsKey($k)) { $lavoratore[$k] = [string](Get-Campo $c 'Ruolo') }
    }

    # le consegne: in ordine di card, una per card; un ruolo gia in una consegna non ne apre un'altra
    $consegne = @()
    $impegnato = @{}
    foreach ($k in @($lavoratore.Keys | Sort-Object { [int]$_ })) {
        $b = $lavoratore[$k]
        if ($b -notin $ruoliOk) { continue }
        $sc = Get-Campo $Stato $k
        $a = [string](Get-Campo $sc 'ultimoRuolo')
        if ($a -eq '' -or $a -eq $b -or $a -notin $ruoliOk) { continue }
        $fine = ConvertTo-DataUtc (Get-Campo (Get-Campo (Get-Campo $sc 'ultimaSessione') $a) 'fine')
        if ($null -eq $fine) { continue }
        if (($Adesso - $fine).TotalMinutes -gt $FinestraMinuti) { continue }
        if ($impegnato.ContainsKey($a) -or $impegnato.ContainsKey($b)) { continue }
        # ognuno dei due puo lasciare il suo PC solo se non siede su un'altra card
        if (@($sessioniPer[$a] | Where-Object { $_ -ne [int]$k }).Count -gt 0) { continue }
        if (@($sessioniPer[$b] | Where-Object { $_ -ne [int]$k }).Count -gt 0) { continue }
        $impegnato[$a] = $true; $impegnato[$b] = $true
        $consegne += [pscustomobject]@{ Id = [int]$k; Titolo = $titoli[$k]; Da = $a; A = $b }
    }

    $personaggi = @(foreach ($r in $ruoliOk) {
        $ids = @($sessioniPer[$r])
        $seduto = if ($ids.Count -gt 0) { $ids[0] } else { $null }
        $posto = [pscustomobject]@{
            Ruolo = $r; Posto = 'caffe'; Id = $null; Titolo = $null; Task = $null; Altre = 0; Con = $null; Fumetto = $null; Verso = $null
        }
        if ($null -ne $seduto) {
            $posto.Posto = 'pc'; $posto.Id = $seduto; $posto.Titolo = $titoli["$seduto"]
            $posto.Altre = $ids.Count - 1
            $sessione = @($InCorso | Where-Object { [int](Get-Campo $_ 'Id') -eq $seduto })[0]
            $posto.Task = Get-Campo $sessione 'Task'
        }
        $posto
    })

    # ogni parte di una consegna: chi siede sulla card resta al PC con l'altro accanto, l'altro va a parlare
    foreach ($c in $consegne) {
        $coppia = @(@{ Chi = $c.Da; Con = $c.A; Verso = 'da' }, @{ Chi = $c.A; Con = $c.Da; Verso = 'a' })
        foreach ($x in $coppia) {
            $p = @($personaggi | Where-Object Ruolo -eq $x.Chi)[0]
            $p.Con = $x.Con; $p.Verso = $x.Verso
            $p.Fumetto = "#$($c.Id) $($c.Titolo)"
            if ($p.Posto -eq 'pc' -and $p.Id -eq $c.Id) { continue }
            $p.Posto = 'parla'; $p.Id = $c.Id; $p.Titolo = $c.Titolo; $p.Task = $null; $p.Altre = 0
        }
    }

    [pscustomobject]@{ Personaggi = $personaggi; Passaggi = $consegne }
}

# Le colonne della bacheca a muro: le fasi di una card sulla board, nell'ordine del flusso. La chiave e quella di Get-ChiaveStato
# (config/stati.json); titolo e sigla (al massimo 5 lettere, la bacheca disegna in pixel) sono solo il nome da mostrare.
$script:ColonneBacheca = @(
    @{ chiave = 'nuova'; titolo = 'Nuove'; sigla = 'NEW' }
    @{ chiave = 'daChiarire'; titolo = 'Da chiarire'; sigla = 'CHIAR' }
    @{ chiave = 'pronto'; titolo = 'Pronte da sviluppare'; sigla = 'PRONT' }
    @{ chiave = 'inSviluppo'; titolo = 'In sviluppo'; sigla = 'DEV' }
    @{ chiave = 'inRevisione'; titolo = 'In revisione'; sigla = 'REV' }
    @{ chiave = 'inDeployTest'; titolo = 'Deploy in Test'; sigla = 'DEPL' }
    @{ chiave = 'inCollaudo'; titolo = 'Collaudo automatico'; sigla = 'COLL' }
    @{ chiave = 'inProvaUmana'; titolo = 'Prova in Test'; sigla = 'TEST' }
    @{ chiave = 'daUnire'; titolo = 'Da unire'; sigla = 'MERGE' }
    @{ chiave = 'daRilasciare'; titolo = 'Da rilasciare'; sigla = 'REL' }
)

# Chi consegna e chi riceve: avanti se il ricevente sta dopo nel flusso, indietro se sta prima (un rimando), laterale se uno dei due
# non e nel flusso (il mentore): la direzione non si inventa.
function Get-VersoConsegna([string]$Da, [string]$A, [string[]]$Flusso) {
    $i = [array]::IndexOf(@($Flusso), $Da); $j = [array]::IndexOf(@($Flusso), $A)
    if ($i -lt 0 -or $j -lt 0) { return 'laterale' }
    if ($j -gt $i) { 'avanti' } else { 'indietro' }
}

# La quota come la mostra la pagina. $Quota e il riepilogo che la vista calcola per la sua riga quota (Get-RiepilogoQuota in Decisioni:
# Blocco, Uso, Soglia EFFETTIVA, DaOverride, IgnoraRiserva), piu Letta: il quota.json letto, per sapere di quale finestra e la pausa per il limite: l'ufficio e la vista dicono la stessa cosa perche leggono lo stesso dato.
# La regola del blocco e della soglia sta in Decisioni: qui non si ricalcola, si traduce.
function Get-QuotaUfficio($Quota) {
    $b = Get-Campo $Quota 'Blocco'
    $uso = Get-Campo $Quota 'Uso'; $soglia = Get-Campo $Quota 'Soglia'
    # la soglia alzata dalla vista e la riserva ignorata fino al reset: la pagina li dice, non li deduce
    $alzata = [bool](Get-Campo $Quota 'DaOverride'); $ignorata = [bool](Get-Campo $Quota 'IgnoraRiserva')
    if ($null -ne $b) {
        $stato = if ([string](Get-Campo $b 'Causa') -eq 'riserva') { 'riserva' } else { 'limite' }
        $fino = Get-Campo $b 'Fino'
        if ($null -ne (Get-Campo $b 'Uso')) { $uso = Get-Campo $b 'Uso' }
        if ($null -ne (Get-Campo $b 'Soglia')) { $soglia = Get-Campo $b 'Soglia' }
        # la pausa per il limite: di quale finestra (quota.json, finestraPausa) e quanto e usata. Senza il dato non si inventa: null.
        $finestra = $null; $usoFinestra = $null
        if ($stato -eq 'limite') {
            $letta = Get-Campo $Quota 'Letta'
            $f = switch ([string](Get-Campo $letta 'finestraPausa')) { 'five_hour' { 'cinqueOre' } 'seven_day' { 'settimana' } default { $null } }
            if ($f) {
                $finestra = $f
                $usoFinestra = Get-Campo (Get-Campo $letta $(if ($f -eq 'cinqueOre') { 'fiveHour' } else { 'sevenDay' })) 'utilization'
            }
        }
        return [pscustomobject][ordered]@{ stato = $stato; uso = $uso; soglia = $soglia; fino = $fino; alzata = $alzata; ignorata = $ignorata; finestra = $finestra; usoFinestra = $usoFinestra }
    }
    [pscustomobject][ordered]@{ stato = $(if ($null -eq $uso) { 'sconosciuta' } else { 'libera' }); uso = $uso; soglia = $soglia; fino = $null; alzata = $alzata; ignorata = $ignorata; finestra = $null; usoFinestra = $null }
}

# Una sessione in corso come la mostra la pagina: card (id, titolo, link), task, da quanti minuti e i token usati (se letti).
function ConvertTo-SessioneUfficio($S) {
    $usati = [int64](Get-Campo $S 'Token')
    $testoUsati = $(if ($usati -gt 0) { Get-Campo $S 'TokenTesto' } else { $null })
    [pscustomobject][ordered]@{
        id = [int](Get-Campo $S 'Id'); titolo = (Get-Campo $S 'Titolo'); urlCard = (Get-Campo $S 'UrlCard')
        task = (Get-Campo $S 'Task'); titoloTask = (Get-Campo $S 'TitoloTask'); minuti = (Get-Campo $S 'Minuti')
        tokenTesto = $testoUsati
        tokenUsati = $usati
    }
}

# Tutto cio che la pagina dell'ufficio mostra come vero, in un oggetto che si scrive in JSON (ufficio.json e l'incorporato nella
# pagina). Funzione pura: non legge disco, rete ne orologio. Gli argomenti sono le stesse righe della vista (Get-ModelloVista):
#  $Ruoli i ruoli con un personaggio; $Flusso l'ordine del flusso (per il verso delle consegne); $InCorso, $Coda, $Agenti (Ruolo, Coda),
#  $Operatore (Fermano, NonFermano), $Stato (stato.json), $Adesso (UTC), $Quota (Blocco, Uso, Soglia), $Smistatore (InGiro, Ultimo,
#  Prossimo; InGiro $null se non si sa), $ErroreAdo (testo; con un errore la coda, le voci per Titolare e la bacheca non si conoscono).
# Il resto della pagina (la pausa, le chiacchiere, il meteo) non e dato: non passa di qui e non ha un id di card.
function Get-ModelloUfficio {
    [CmdletBinding()]
    param(
        [string[]]$Ruoli, [string[]]$Flusso,
        [object[]]$InCorso = @(), [object[]]$Coda = @(), [object[]]$Agenti = @(), $Operatore = $null,
        [hashtable]$Stato = @{}, [datetime]$Adesso, $Quota = $null, $Smistatore = $null, [string]$ErroreAdo = '',
        [int]$Secondi = 5, [int]$FinestraMinuti = 60
    )
    $adessoUtc = $Adesso.ToUniversalTime()
    # i personaggi stanno nell'ordine del flusso, poi gli altri ruoli nell'ordine della configurazione
    $ordine = @(@($Flusso | Where-Object { $_ -in $Ruoli }) + @($Ruoli | Where-Object { $_ -notin $Flusso }))
    $postazioni = Get-PostazioniUfficio -Ruoli $ordine -InCorso $InCorso -Coda $Coda -Stato $Stato -Adesso $adessoUtc -FinestraMinuti $FinestraMinuti

    # una persona per sessione: la prima (card piu piccola) e il personaggio del ruolo alla sua scrivania, le altre siedono al tavolo
    # dei portatili (altreSessioni). Stesso dato per tutte, dalla stessa funzione.
    $altreSessioni = @()
    $personaggi = @(foreach ($r in $ordine) {
        $mie = @($InCorso | Where-Object { [string](Get-Campo $_ 'Ruolo') -eq $r } | Sort-Object { [int](Get-Campo $_ 'Id') })
        $sessione = $null
        if ($mie.Count -gt 0) {
            $sessione = ConvertTo-SessioneUfficio $mie[0]
            $sessione | Add-Member -NotePropertyName altre -NotePropertyValue ($mie.Count - 1)
            foreach ($s in @($mie | Select-Object -Skip 1)) {
                $altra = ConvertTo-SessioneUfficio $s
                $altra | Add-Member -NotePropertyName ruolo -NotePropertyValue $r
                $altreSessioni += $altra
            }
        }
        $agente = $Agenti | Where-Object { [string](Get-Campo $_ 'Ruolo') -eq $r } | Select-Object -First 1
        $attese = @(if ($agente) { @(Get-Campo $agente 'Coda') | Where-Object { $null -ne $_ } })
        [pscustomobject][ordered]@{
            ruolo = $r; sessione = $sessione; codaTotale = $attese.Count
            coda = @($attese | ForEach-Object { [pscustomobject][ordered]@{ id = [int](Get-Campo $_ 'Id'); titolo = (Get-Campo $_ 'Titolo'); urlCard = (Get-Campo $_ 'UrlCard') } })
        }
    })

    $consegne = @(foreach ($c in @($postazioni.Passaggi)) {
        $riga = (@($InCorso) + @($Coda) | Where-Object { $null -ne $_ -and [int](Get-Campo $_ 'Id') -eq $c.Id } | Select-Object -First 1)
        [pscustomobject][ordered]@{
            id = $c.Id; titolo = $c.Titolo; urlCard = (Get-Campo $riga 'UrlCard'); da = $c.Da; a = $c.A; verso = (Get-VersoConsegna $c.Da $c.A $Flusso)
        }
    })

    $fermi = @(if ($Operatore) { @(Get-Campo $Operatore 'Fermano') | Where-Object { $null -ne $_ } | ForEach-Object { [int](Get-Campo $_ 'Id') } })
    $voci = @(if ($Operatore) { (@(Get-Campo $Operatore 'Fermano') + @(Get-Campo $Operatore 'NonFermano')) | Where-Object { $null -ne $_ } })
    $daFareTu = @(foreach ($v in $voci) {
        [pscustomobject][ordered]@{
            id = [int](Get-Campo $v 'Id'); titolo = (Get-Campo $v 'Titolo'); urlCard = (Get-Campo $v 'UrlCard')
            verbo = (Get-Campo $v 'Verbo'); testo = (Get-Campo $v 'Testo'); ferma = ([int](Get-Campo $v 'Id') -in $fermi)
        }
    })

    # la fila alla porta di Titolare: chi ha lavorato per ultimo una card FERMA su di lui (la vista le separa: Operatore.Fermano), se
    # non ha una sessione e non e gia in fila. Una card che aspetta Titolare senza fermare il flusso (rilascio, prova in Test) non mette
    # nessuno in fila: il lavoro di quel ruolo e finito, non e in attesa. Le voci restano tutte in daFareTu (i fogli sulla scrivania).
    $conSessione = @($InCorso | ForEach-Object { [string](Get-Campo $_ 'Ruolo') })
    $fila = @(); $inFila = @{}
    foreach ($v in @($daFareTu | Where-Object ferma | Sort-Object id)) {
        $ultimo = [string](Get-Campo (Get-Campo $Stato "$($v.id)") 'ultimoRuolo')
        if ($ultimo -eq '' -or $ultimo -notin $ordine -or $ultimo -in $conSessione -or $inFila.ContainsKey($ultimo)) { continue }
        $inFila[$ultimo] = $true
        $fila += [pscustomobject][ordered]@{ ruolo = $ultimo; id = $v.id }
    }

    # la bacheca: le card per colonna, ognuna una volta (le sessioni e la coda sono insiemi disgiunti in Get-ModelloVista). Senza la
    # lettura di Azure DevOps un conteggio sarebbe parziale, quindi non c'e.
    $board = $null
    if (-not $ErroreAdo) {
        $tutte = @(@($InCorso) + @($Coda) | Where-Object { $null -ne $_ })
        $board = @(foreach ($col in $script:ColonneBacheca) {
            [pscustomobject][ordered]@{
                chiave = $col.chiave; titolo = $col.titolo; sigla = $col.sigla
                conteggio = @($tutte | Where-Object { [string](Get-Campo $_ 'Chiave') -eq $col.chiave }).Count
            }
        })
    }

    [pscustomobject][ordered]@{
        generata = $adessoUtc.ToString('o'); secondi = $Secondi; esempio = $false; erroreAdo = $ErroreAdo
        personaggi = $personaggi; altreSessioni = @($altreSessioni); consegne = $consegne; daFareTu = @($(if ($ErroreAdo) { @() } else { $daFareTu })); fila = @($(if ($ErroreAdo) { @() } else { $fila }))
        board = $board; quota = (Get-QuotaUfficio $Quota)
        smistatore = [pscustomobject][ordered]@{
            inGiro = (Get-Campo $Smistatore 'InGiro'); ultimoGiro = (Get-Campo $Smistatore 'Ultimo'); prossimoGiro = (Get-Campo $Smistatore 'Prossimo')
        }
    }
}

Export-ModuleMember -Function Get-PostazioniUfficio, Get-ModelloUfficio
