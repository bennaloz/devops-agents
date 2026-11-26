# L'istantanea di una card e il contesto del giro, per chi deve chiedere a Decisioni.psm1 cosa fare di una card: lo
# smistatore (src/Smistatore.ps1) e la vista (src/Vista.ps1). Non e un modulo: si carica con il punto (`. Istantanea.ps1`)
# perche le funzioni di Azure DevOps che chiama vanno trovate nello scope di chi la carica (cosi i test le sostituiscono).
# Solo letture: niente scrive in Azure DevOps ne nello stato.

function Get-Adesso { (Get-Date).ToUniversalTime() }

# Le card dell'utente dello smistatore: solo quelle fa avanzare, e i gesti che valgono sono i suoi (spec, sezione 19).
function Test-CardMia($Card, [string]$IdUtente) {
    $null -ne $Card -and $null -ne (Get-Campo $Card 'AssegnataA') -and [string]$Card.AssegnataA.Id -eq $IdUtente
}

function Add-AInTabella($Tabella, [string]$Chiave, $Id) {
    if (-not $Tabella.Contains($Chiave)) { $Tabella[$Chiave] = [System.Collections.Generic.List[int]]::new() }
    if ($Tabella[$Chiave] -notcontains [int]$Id) { $Tabella[$Chiave].Add([int]$Id) }
}

# Le tabelle dei limiti per repo e per componente, e la quota (quota.json), su tutte le card attive (anche degli altri: le risorse sono comuni).
function New-ContestoGiro($Cfg, $Attive, [string]$IdUtente, [string]$PercorsoQuota = (Join-Path (Get-CartellaDati) 'quota.json'), [string]$PercorsoSoglia = (Get-PercorsoSogliaQuotaPredefinito)) {
    $ctx = @{
        Stati = $Cfg.Stati; Limiti = $Cfg.Limiti; SessioniAttive = 0; ConSessione = @(); Titolare = $IdUtente; Adesso = (Get-Adesso).ToString('o')
        InSviluppoPerRepo = @{}; InTestPerComponente = @{}
        # D51: l'ultima lettura della quota e la pausa per il limite, uguali per tutte le card (la quota e una sola)
        Quota = (Get-Quota -Percorso $PercorsoQuota)
        # l'override della soglia dalla vista, valido fino al reset: Get-BloccoQuota lo applica (e lo ignora se scaduto)
        OverrideQuota = (Get-SogliaQuota -Percorso $PercorsoSoglia)
        # D52: i padri delle card, letti una volta per giro per padre (id padre -> @{ Feature; Figli; Ramo; ErroreRamo } | @{ NonFeature } | @{ Errore })
        Funzionalita = @{}
    }
    foreach ($c in @($Attive)) {
        $v = Find-VoceMappa -Mappa $Cfg.Mappa -Area $c.Area
        if (-not $v) { continue }
        $k = Get-ChiaveStato $Cfg.Stati $c.Stato
        if ($k -eq 'inSviluppo') { Add-AInTabella $ctx.InSviluppoPerRepo $v.repo $c.Id }
        if ($k -in (Get-StatiInTest)) { Add-AInTabella $ctx.InTestPerComponente $v.componente $c.Id }
    }
    $ctx
}

# Le sessioni aperte oggi, dallo stato: il numero e le card che le tengono. Da rifare prima di ogni card, perche
# un lancio le cambia.
function Update-SessioniContesto($Ctx, $Stato) {
    $ids = @(Get-IdCardConSessione $Stato)
    $Ctx.ConSessione = @($ids)
    $Ctx.SessioniAttive = @($ids).Count
}

# I predecessori della card, ognuno con prId e cartella che lo stato locale conosce di lui. Lo stato si legge senza crearvi
# voci: una card che lo smistatore non ha mai toccato non ha prId ne cartella.
function Get-PredecessoriCard($CardAdo, $Stato) {
    @(Get-AdoCardPredecessori -CardId $CardAdo.Id | ForEach-Object {
        $locale = $Stato["$($_.Id)"]
        [pscustomobject]@{
            Id = $_.Id; Stato = $_.Stato; Tag = @(Get-Campo $_ 'Tag')
            prId = if ($locale) { $locale['prId'] } else { $null }
            cartella = if ($locale) { $locale['cartella'] } else { $null }
            # D52: il padre del predecessore (se e la stessa Feature della card che aspetta lo dice chi decide)
            PadreId = Get-Campo $_ 'PadreId'
        }
    })
}

# Il deploy in Test della card (D43), solo in Deploying to test, per un componente con il deploy in Test e prima di accodare
# il deploy (Test-DeployDaLeggere: mentre la run vale non si legge niente). Scelta: i parametri dell'ultimo commento di deploy
# del responsabile, da tutti i commenti (anche quelli gia letti). AmmessiLetti e Ammessi: i parametri deploy* dello YAML della
# pipeline sul ramo della card, letti solo se c'e una scelta da verificare e un ramo; un elenco letto puo essere vuoto.
# ErroreAmmessi: se lo YAML o la definizione non si leggono la card non salta il giro, Decisioni ne fa un'attesa.
function Get-DeployCard($CardAdo, $Voce, $Sc, [string]$Chiave, $Tutti, $Storia, $Run) {
    if ($Chiave -ne 'inDeployTest' -or -not (Get-Campo $Voce 'pipelineDeploy')) { return $null }
    if (-not (Test-DeployDaLeggere -Card $CardAdo -Storia $Storia -StatoCard $Sc -Run $Run)) { return $null }
    $deploy = @{ Scelta = @(Get-SceltaDeploy $Tutti); AmmessiLetti = $false; Ammessi = @(); ErroreAmmessi = $null }
    if ($deploy.Scelta.Count -gt 0 -and $Sc['ramo']) {
        try {
            $deploy.Ammessi = @(Get-AdoParametriDeploy -Progetto $Voce.progettoAdo -PipelineId ([int]$Voce.pipelineDeploy) -Ramo ([string]$Sc['ramo']))
            $deploy.AmmessiLetti = $true
        }
        catch { $deploy.ErroreAmmessi = $_.Exception.Message }
    }
    $deploy
}

# D52: la funzionalita a cui appartiene la card. E la sola funzione che risponde alla domanda "questa card e della funzionalita?".
# Null per una card isolata: senza padre (PadreId, che la card porta dalla lettura delle card attive: nessuna chiamata), con un padre
# che non e una Feature, o con una Feature senza card di chiusura (tag tagChiusura, non Removed: e una Feature della spec, sezione 18).
# Altrimenti: la Feature, l'id della card di chiusura, le sorelle (le figlie senza la chiusura e senza le Removed), il ramo della
# funzionalita su origin (Ramo: null se non e ancora stato pubblicato), se questa card e la chiusura e lo stato della card di
# chiusura (StatoChiusura, il nome ADO: lo leggono l'attesa del collaudo e il passaggio In feature branch, senza chiamate in piu).
# Se il padre o le figlie non si leggono: @{ Errore = <messaggio> }, mai null (una card della funzionalita non e una isolata).
# Il padre e le figlie si leggono una volta per giro per padre (due chiamate), con la cache del contesto; nessuna per card.
# Una Feature Removed e come nessuna Feature: la card e isolata.
# Il ramo si cerca su origin (Get-AdoRamoCard -FeatureId: REST nel repo della Voce, niente git) solo per una vera funzionalita, una volta
# per giro per Feature, nella stessa cache (anche se non c'e); senza Voce non si cerca e Ramo resta null. Se la ricerca fallisce: @{ Errore }, perche un
# Ramo null vorrebbe dire "da creare" e non e quello che si sa.
function Get-FunzionalitaCard($Cfg, $CardAdo, $Ctx = $null, $Voce = $null) {
    # L'interruttore funzionalitaAttive (config/limiti.json) vale anche qui: spento, nessuna card e della funzionalita, cosi una chiusura
    # taggata a mano in ADO non accende niente, e non si legge niente.
    if (-not [bool](Get-Campo $Cfg.Limiti 'funzionalitaAttive')) { return $null }
    $padreId = Get-Campo $CardAdo 'PadreId'
    if (-not $padreId) { return $null }
    $cache = if ($null -ne $Ctx -and $Ctx.ContainsKey('Funzionalita')) { $Ctx.Funzionalita } else { @{} }
    $chiave = [string]$padreId
    if (-not $cache.ContainsKey($chiave)) {
        try {
            $padre = Get-AdoFeature -Id ([int]$padreId)
            if ($padre.Tipo -ne 'Feature') { $cache[$chiave] = @{ NonFeature = $true } }
            else {
                $figli = @(Get-AdoFigliFeature -FigliIds @($padre.FigliIds))
                # una figlia che non si legge (la lettura a lotto la omette) non e una figlia che non c'e: la card di chiusura partirebbe senza di lei
                if ($figli.Count -lt @($padre.FigliIds).Count) { throw "delle $(@($padre.FigliIds).Count) figlie della Feature #$($padre.Id) se ne leggono $($figli.Count)" }
                $cache[$chiave] = @{ Feature = $padre; Figli = $figli }
            }
        }
        catch {
            $cache[$chiave] = @{ Errore = $_.Exception.Message }
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log 'WARN' "funzionalita: il padre #$padreId della card $($CardAdo.Id) non si legge ($($_.Exception.Message))" }
        }
    }
    $entrata = $cache[$chiave]
    if ($entrata.ContainsKey('NonFeature')) { return $null }
    if ($entrata.ContainsKey('Errore')) { return @{ Errore = $entrata.Errore } }
    if ($entrata.Feature.Stato -ieq $Cfg.Stati.featureRimossa) { return $null }
    $parti = Get-ComposizioneFunzionalita $Cfg.Stati $entrata.Figli
    if ($null -eq $parti) { return $null }
    if ($null -ne $Voce -and -not $entrata.ContainsKey('Ramo')) {
        try { $entrata.Ramo = Get-AdoRamoCard -Progetto $Voce.progettoAdo -Repo $Voce.repo -FeatureId ([int]$entrata.Feature.Id) }
        catch {
            $entrata.Ramo = $null; $entrata.ErroreRamo = $_.Exception.Message
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log 'WARN' "funzionalita: il ramo della Feature #$($entrata.Feature.Id) non si legge ($($_.Exception.Message))" }
        }
    }
    if ($entrata.ContainsKey('ErroreRamo')) { return @{ Errore = "il ramo della funzionalita non si legge: $($entrata.ErroreRamo)" } }
    @{
        Feature = $entrata.Feature
        Chiusura = [int]$parti.Chiusura.Id
        TitoloChiusura = [string](Get-Campo $parti.Chiusura 'Titolo')
        Sorelle = $parti.Sorelle
        Ramo = if ($entrata.ContainsKey('Ramo')) { $entrata.Ramo } else { $null }
        EChiusura = ([int]$CardAdo.Id -eq [int]$parti.Chiusura.Id)
        StatoChiusura = [string]$parti.Chiusura.Stato
    }
}
# D52: gli errori di codice della build rossa della card di chiusura, che non ha dev a cui dare il log: servono a decidere (codice o
# infrastruttura), alla correzione che il responsabile scrive (gruppo 5) e al motivo con cui la card aspetta (Format-MotivoCoda). Due fonti: la
# validazione rossa della PR in Ready to develop e in Ready to merge, e il run del deploy fallito in Deploying to test. Solo errori di codice (Get-AdoErroriBuild -SoloCodice: test falliti, compilazione);
# altrimenti, o se il log non si legge, null: nel dubbio e infrastruttura. Altrove, e per le card isolate, non si legge niente.
# Si legge una volta per build: l'esito (anche "nessun errore di codice") sta nello stato della card, accanto al BuildId, e dal giro
# dopo non si rilegge. Una lettura fallita non si ricorda: si riprova.
function Get-ErroriBuildChiusura($Voce, [string]$Chiave, $Pr, $Run, $Sc) {
    $buildId = $null
    # D52, gruppo 5: la validazione rossa vale anche in Ready to merge (dopo un rilancio di scadute la PR puo tornare rossa), con la PR attiva
    if ($Chiave -in 'pronto', 'daUnire' -and $null -ne $Pr -and (Get-Campo $Pr 'Stato') -eq 'active' -and (Get-Campo $Pr 'Validazione') -eq 'rossa' -and (Get-Campo $Pr 'BuildId')) { $buildId = [int]$Pr.BuildId }
    elseif ($Chiave -eq 'inDeployTest' -and $null -ne $Run -and (Get-Campo $Run 'Stato') -eq 'completed' -and (Get-Campo $Run 'Esito') -ne 'succeeded' -and $Sc['runId']) { $buildId = [int]$Sc['runId'] }
    if ($null -eq $buildId) { return $null }
    $letto = Get-Campo $Sc 'erroriBuild'
    if ($null -ne $letto -and [int](Get-Campo $letto 'build') -eq $buildId) { return Get-Campo $letto 'testo' }
    try { $testo = Get-AdoErroriBuild -Progetto $Voce.progettoAdo -BuildId $buildId -SoloCodice }
    catch { return $null }
    $Sc['erroriBuild'] = @{ build = $buildId; testo = $testo }
    $testo
}

function Get-IstantaneaCard($Cfg, $CardAdo, $Voce, $Sc, $Stato, [string]$PercorsoStato, $Ctx = $null) {
    $chiave = Get-ChiaveStato $Cfg.Stati $CardAdo.Stato
    $pr = $null; $run = $null
    # D52: null per una card isolata; le funzioni di Decisioni.psm1 leggono solo questo campo (e la card di chiusura ha qui EChiusura)
    $funzionalita = Get-FunzionalitaCard $Cfg $CardAdo $Ctx $Voce
    $eChiusura = $null -ne $funzionalita -and -not (Get-Campo $funzionalita 'Errore') -and [bool](Get-Campo $funzionalita 'EChiusura')
    # La card di chiusura in Ready to develop ha gia il ramo salvato e ne segue la PR: in quello stato le altre card non hanno un ramo
    if ($Sc['ramo'] -and ($chiave -in (Get-StatiConRamo) -or ($eChiusura -and $chiave -eq 'pronto'))) {
        # In Ready to merge serve la PR attiva da completare. In Ready to release (e, D52, In feature branch) la PR puo essere gia
        # completata (la completa CompletaPr): serve a RimuoviWorktree vederla. La PR va verso la destinazione salvata nello stato
        # della card: il ramo della funzionalita, o develop.
        $pr = Get-AdoPr -Progetto $Voce.progettoAdo -Repo $Voce.repo -Ramo ([string]$Sc['ramo']) -Destinazione (Get-DestinazioneCard $Sc) `
            -AncheCompletate:($chiave -in 'daUnire', 'inFeature', 'daRilasciare')
    }
    # I task servono dove si lancia dev su un task (Ready to develop, In development) e dove un task aggiunto dopo lo
    # sviluppo riporta la card In development (da In review a Ready to release, finche il worktree c'e). In feature branch (D52) un
    # task aperto non riporta indietro la card ma si segnala, e anche li i task si leggono solo finche il worktree c'e.
    $conTask = $chiave -in 'pronto', 'inSviluppo' -or ($Sc['cartella'] -and $chiave -in (Get-StatiConRamo))
    $task = if ($conTask) { @(Get-AdoTaskFigli -CardId $CardAdo.Id) } else { @() }
    # L'ordine fra le card conta solo prima che parta il lavoro: Get-Azioni decide se la card puo partire.
    $predecessori = if ($chiave -in 'nuova', 'pronto') { @(Get-PredecessoriCard $CardAdo $Stato) } else { @() }
    if ($Sc['runId']) { $run = Get-AdoRun -Progetto $Voce.progettoAdo -RunId ([int]$Sc['runId']) }
    $erroriBuild = if ($eChiusura) { Get-ErroriBuildChiusura $Voce $chiave $pr $run $Sc } else { $null }
    # i commenti si scaricano una volta: il deploy li vuole tutti, le decisioni solo quelli dopo ultimoCommento
    $tutti = @(Get-AdoCommenti -Id $CardAdo.Id)
    $dopo = [int]$Sc['ultimoCommento']
    $storia = @(Get-AdoStoriaStato -Id $CardAdo.Id)
    $deploy = Get-DeployCard $CardAdo $Voce $Sc $chiave $tutti $storia $run
    # D51: un on-hold per il limite di token di prima di D51 si scioglie quando il reset e passato, e il reset sta solo nel
    # jsonl della sessione. Si legge solo per quella card (tag di on-hold e le condizioni di Test-OnHoldPerLimite): niente
    # lettura del jsonl per le altre. Se non si legge, o non ha un reset, la card resta in on-hold.
    $limiteUltima = $null
    if (@($CardAdo.Tag) -contains [string]$Cfg.Stati.tagAttesa -and (Test-OnHoldPerLimite $Sc)) {
        $dati = if (Get-Variable CartellaDati -ErrorAction SilentlyContinue) { $CartellaDati } else { $null }
        if (-not $dati) { $dati = Get-CartellaDati }
        $idSessione = Get-Campo (Get-Campo (Get-Campo $Sc 'ultimaSessione') ([string]$Sc['ultimoRuolo'])) 'id'
        if ($idSessione) {
            try { $limiteUltima = Get-Campo (Get-EsitoSessione -Id ([string]$idSessione) -CartellaDati $dati) 'Limite' }
            catch { $limiteUltima = $null }
        }
    }
    @{
        Card = $CardAdo
        Commenti = @($tutti | Where-Object { $null -ne $_ -and [int]$_.Id -gt $dopo })
        # tutti, letti e no: il mentore della prova umana (D46) legge anche quelli che il lancio del responsabile ha gia consumato
        CommentiTutti = $tutti
        Storia = $storia
        Pr = $pr; Run = $run; StatoCard = $Sc; Voce = $Voce; Task = $task; Predecessori = $predecessori; Deploy = $deploy
        RevNostre = @(Get-RevNostre -Id $CardAdo.Id -Percorso $PercorsoStato)
        LimiteUltimaSessione = $limiteUltima
        Funzionalita = $funzionalita
        ErroriBuild = $erroriBuild
    }
}

# La PR di una card come la mostra la vista: quello che serve alla riga (numero, validazione, link alla PR e al log), o null.
function New-PrVista($Pr, $Voce) {
    if ($null -eq $Pr) { return $null }
    [pscustomobject]@{
        Id = [int]$Pr.Id; Validazione = [string]$Pr.Validazione; UrlLog = $Pr.UrlLog
        Url = (Get-AdoUrlPr -Progetto $Voce.progettoAdo -Repo $Voce.repo -Id ([int]$Pr.Id))
    }
}

# I task chiusi sul totale (i rimossi non contano), dai task che l'istantanea ha gia letto; null se non se ne conosce nessuno.
function Get-AvanzamentoTask($Cfg, $Task) {
    $validi = @(@($Task) | Where-Object { $null -ne $_ -and $_.Stato -ine $Cfg.Stati.taskRimosso })
    if ($validi.Count -eq 0) { return $null }
    [pscustomobject]@{ Chiusi = @($validi | Where-Object { $_.Stato -ieq $Cfg.Stati.taskChiuso }).Count; Totali = $validi.Count }
}

# D52: la funzionalita di una card come la mostrano la vista e il supervisore, dai dati che Get-FunzionalitaCard ha gia letto (nessuna
# chiamata): la Feature (id, titolo, stato), la card di chiusura (id, stato) e le sorelle (id, titolo, stato, tag). Null per una card
# isolata e, se la funzionalita non si e letta (Errore), anche li: il motivo funzionalitaIllegibile lo dice gia.
function New-FunzionalitaVista($Funzionalita) {
    if ($null -eq $Funzionalita -or (Get-Campo $Funzionalita 'Errore')) { return $null }
    $feature = Get-Campo $Funzionalita 'Feature'
    [pscustomobject]@{
        Feature = [int](Get-Campo $feature 'Id'); Titolo = [string](Get-Campo $feature 'Titolo'); StatoFeature = [string](Get-Campo $feature 'Stato')
        Chiusura = [int](Get-Campo $Funzionalita 'Chiusura'); TitoloChiusura = [string](Get-Campo $Funzionalita 'TitoloChiusura'); StatoChiusura = [string](Get-Campo $Funzionalita 'StatoChiusura'); EChiusura = [bool](Get-Campo $Funzionalita 'EChiusura')
        Sorelle = @(@(Get-Campo $Funzionalita 'Sorelle') | Where-Object { $null -ne $_ } | ForEach-Object {
            [pscustomobject]@{ Id = [int]$_.Id; Titolo = [string](Get-Campo $_ 'Titolo'); Stato = [string](Get-Campo $_ 'Stato'); Tag = @(Get-Campo $_ 'Tag') }
        })
    }
}

# La riga di una card senza sessione, come la vista la mostra in coda: cosa ne pensa Decisioni (azioni, motivo, gesto, attivita
# dell'operatore), il ruolo a cui andra, la PR. E la stessa lettura per la vista (Get-DatiAdo) e per il supervisore
# (src/Supervisore.ps1): una regola sola. Se la lettura fallisce l'errore sta nella riga (Errore) e il resto e vuoto.
# $Collegamenti, se c'e, riceve i predecessori della card (le catene della vista).
function Get-RigaCoda($Cfg, $c, $voce, $sc, $Stato, [string]$PercorsoStato, $ctx, $Collegamenti = $null) {
    $riga = [ordered]@{ Id = [int]$c.Id; Titolo = [string]$c.Titolo; Stato = [string]$c.Stato; Azioni = 0; Ruolo = $null; Motivo = $null; Gesto = $null; Attivita = $null; Domanda = $null; Errore = $null; Avanzamento = $null; Predecessori = @(); Pr = $null; TogliAttesa = $false; InStatoDa = $null; Funzionalita = $null; AspettaFunzionalita = $false }
    try {
        $snap = Get-IstantaneaCard $Cfg $c $voce $sc $Stato $PercorsoStato $ctx
        $d = Get-Decisione -Istantanea $snap -Contesto $ctx
        # il mentore non muove la card: non e un lavoro pronto per il giro
        $riga.Azioni = @(@($d.Azioni) | Where-Object { $_.Tipo -ne 'LanciaMentore' }).Count
        $riga.Motivo = $d.Motivo
        # un on-hold che lo smistatore sta per togliere non e una cosa per una persona (D51)
        $riga.TogliAttesa = @(@($d.Azioni) | Where-Object { $_.Tipo -eq 'TogliAttesa' }).Count -gt 0
        $lanci = @(@($d.Azioni) | Where-Object { $_.Tipo -eq 'LanciaSessione' })
        $riga.Ruolo = if ($lanci.Count -gt 0) { [string]$lanci[0].Ruolo } elseif ($d.Motivo) { Get-Campo $d.Motivo 'Ruolo' } else { $null }
        $riga.Gesto = Get-GestoAtteso -Istantanea $snap -Contesto $ctx
        $riga.Attivita = Get-AttivitaOperatore -Istantanea $snap -Contesto $ctx -Decisione $d
        # la domanda del responsabile puo essere piu vecchia di ultimoCommento (che l'istantanea salta): si rilegge tutto
        if ($riga.Attivita -and $riga.Attivita.Attivita -eq 'rispondi') {
            try { $riga.Domanda = Format-DomandaOperatore (Get-UltimoCommentoDiRuolo @(Get-AdoCommenti -Id $c.Id) 'responsabile') } catch { }
        }
        $riga.Avanzamento = Get-AvanzamentoTask $Cfg $snap.Task
        $riga.Predecessori = @($snap.Predecessori)
        $riga.Pr = New-PrVista $snap.Pr $voce
        # D52: la funzionalita della card (null se isolata). AspettaFunzionalita: una card In feature branch ha il lavoro nel ramo e segue la
        # chiusura: non ha niente da fare e non e un problema da segnalare. La chiusura in Draft, New o Ready to develop no: ha i suoi motivi
        # (le sorelle, la persona che la sposta in New), e senza un motivo deve restare segnalabile come ferma.
        $riga.Funzionalita = New-FunzionalitaVista $snap.Funzionalita
        if ($riga.Funzionalita) {
            $chiave = Get-ChiaveStato $Cfg.Stati ([string]$c.Stato)
            $riga.AspettaFunzionalita = ($chiave -eq 'inFeature')
        }
        # da quando la card e nello stato in cui sta (l'ultimo ingresso nella storia): il supervisore lo usa per i rilasci in attesa
        $ingresso = @(@($snap.Storia) | Where-Object { $null -ne $_ -and [string]$_.A -ieq [string]$c.Stato }) | Select-Object -Last 1
        if ($ingresso) { $riga.InStatoDa = ConvertTo-DataUtc $ingresso.Quando }
        # l'istantanea legge i predecessori solo in New e Ready to develop: per le catene la card gia oltre li rilegge, senza toccare la decisione.
        # In un try suo, dopo la PR: se non si legge la card resta nella sua colonna e la catena non la mostra.
        try {
            $pc = @(if ((Get-ChiaveStato $Cfg.Stati ([string]$c.Stato)) -in 'nuova', 'pronto') { $snap.Predecessori } else { Get-PredecessoriCard $c $Stato })
            # FeatureId: una predecessora In feature branch della stessa Feature e unita (Test-PredecessoreUnito); le catene lo vogliono come lo smistatore
            if ($pc.Count -gt 0 -and $null -ne $Collegamenti) { $Collegamenti.Add([pscustomobject]@{ Id = [int]$c.Id; Stato = [string]$c.Stato; Predecessori = $pc; FeatureId = $(if ($riga.Funzionalita) { $riga.Funzionalita.Feature } else { $null }) }) }
        } catch { }
    }
    catch { $riga.Errore = $_.Exception.Message }
    $riga
}
