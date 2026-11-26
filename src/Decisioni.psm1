Set-StrictMode -Version Latest

# Le decisioni dello smistatore: una funzione pura. Riceve l'istantanea di una card e il contesto del giro e restituisce
# le azioni da eseguire, nell'ordine. Non legge ne scrive niente fuori da se': niente moduli di Azure DevOps, di stato o
# di sessioni (solo i piccoli aiuti di Comune.psm1). Nessun nome di stato o di tag e' scritto qui: si usano le chiavi di config/stati.json, tradotte nei nomi
# veri da Contesto.Stati.
#
# Istantanea: Card, Commenti (dopo ultimoCommento), Storia (cambi di stato), Pr, Run, StatoCard, Voce, RevNostre
#             (revisioni scritte da noi, da Get-RevNostre), Task (i task figli della card: Id, Stato; assente = nessuno).
#             Un task e aperto se il suo stato non e taskChiuso ne taskRimosso (chiavi di config/stati.json).
#             Predecessori (solo per le card in New e in Ready to develop; assente = nessuno): le card che devono essere unite
#             prima, ognuna con Id, Stato (nome ADO) e prId e cartella dello stato locale dello smistatore (null se non li conosce).
#             La card aspetta, senza azioni, finche ce n'e uno non unito (vedi Get-PredecessoriInAttesa).
#             Deploy (solo in Deploying to test prima di accodare il deploy, per un componente con il deploy in Test): Scelta,
#             i parametri dell'ultimo commento di deploy del responsabile (vuoto se non c'e); AmmessiLetti e Ammessi, i
#             parametri deploy* dello YAML della pipeline sul ramo della card; ErroreAmmessi, il messaggio se non si sono
#             potuti leggere. Vedi Get-SceltaDeployValida e Test-DeployDaLeggere.
#             Funzionalita (D52): null per una card isolata; altrimenti Feature, Chiusura (id della card di chiusura), Sorelle, Ramo
#             (il ramo della funzionalita su origin, null se non c'e ancora), EChiusura e StatoChiusura (il nome ADO dello stato della
#             card di chiusura); oppure @{ Errore } se la funzionalita non si e letta (la card allora non fa niente). E il solo campo
#             da cui si sa se una card e della funzionalita: vedi Test-CardFunzionalita. La card di chiusura ha EChiusura vero: vedi Test-CardChiusura.
#             ErroriBuild (solo card di chiusura): il testo degli errori della build rossa (la validazione della PR, o il run del deploy
#             in Test fallito); assente o vuoto se non ci sono passi falliti da leggere.
# Contesto:   Stati, Limiti, SessioniAttive (numero) e ConSessione (gli id di quelle card), InSviluppoPerRepo e InTestPerComponente (tabelle repo/componente ->
#             elenco di id delle card oggi in quello stato, anche quella in esame), AmbientiCollaudo (D59: gli id delle card in uno stato di Test il cui
#             componente ha la voce collaudo, anche quella in esame; assente = nessuna), Titolare (id utente), Adesso (l'ora
#             del giro, UTC; senza, i controlli sul tempo non scattano).

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global
# D57: il testo "Cosa fare" di un on-hold, per chi importa Decisioni (smistatore, supervisore, vista)
Import-Module (Join-Path $PSScriptRoot 'CosaFare.psm1') -Global

$script:RuoliAgente = 'responsabile|dev|reviewer|collaudatore|mentore|smistatore'
# Davanti al [ruolo] di un commento di agente puo esserci un involucro html e la menzione: l'ancora con dentro la sola
# chiocciola o il nome, i tag, gli spazi, &nbsp; e la chiocciola nuda.
$script:PrefissoCommento = '(?:\s|&nbsp;|<a\b[^>]*>[^<]*</a>|<[^>]*>|@)*'

function New-Azione([string]$Tipo, [hashtable]$Campi = @{}) {
    $a = [ordered]@{ Tipo = $Tipo }
    foreach ($k in $Campi.Keys) { $a[$k] = $Campi[$k] }
    $a
}

# Task: l'id del task su cui lavora la sessione (solo dev), null se non e legata a un task.
function New-Lancia([string]$Ruolo, [string]$Motivo, $Allegato = $null, [bool]$Riprendi = $false, $Task = $null) {
    New-Azione 'LanciaSessione' @{ Ruolo = $Ruolo; Motivo = $Motivo; Allegato = $Allegato; Riprendi = $Riprendi; Task = $Task }
}

# L'id del primo task aperto (l'elenco e nell'ordine di esecuzione), null se non ce ne sono.
function Get-PrimoTaskAperto($a) {
    if ($a.TaskAperti.Count -eq 0) { return $null }
    [int](Get-Campo $a.TaskAperti[0] 'Id')
}

function Test-TaskAperto($a, $Id) {
    $null -ne $Id -and @($a.TaskAperti | Where-Object { [int](Get-Campo $_ 'Id') -eq [int]$Id }).Count -gt 0
}

# Per = sessione (si riprende la sessione), limite (si azzerano i contatori) oppure deploy (si dimentica il run fallito e si
# riaccoda il deploy): e' il valore da scrivere in inAttesaPer.
# Una MettiInAttesa non arriva quasi mai sola alla persona: Get-Decisione la passa prima al responsabile (D42, vedi
# Convert-AttesePerResponsabile). Diretta la esclude dalla passata: la persona la deve vedere subito. Tipo e la chiave della
# passata quando il motivo ha parti che cambiano (un id, un ruolo, un esito); senza, la chiave e il motivo stesso.
function New-Attesa([string]$Motivo, [string]$Per, [switch]$Diretta, [string]$Tipo) {
    $campi = @{ Motivo = $Motivo; Per = $Per }
    if ($Diretta) { $campi['Diretta'] = $true }
    if ($Tipo) { $campi['TipoAttesa'] = $Tipo }
    New-Azione 'MettiInAttesa' $campi
}

# ---- la passata del responsabile prima dell'on-hold (D42) --------------------------------------------------------

# Una passata per tipo di attesa, finche una persona non interviene: passateFatte tiene le chiavi dei tipi gia esaminati e
# si svuota solo quando una persona toglie l'on-hold. Una chiave legata allo stato non bastava: i giri di revisione e di
# collaudo e le validazioni rosse attraversano piu stati, e dopo il fatto del responsabile il ciclo ripartiva.
function Get-ChiavePassata($Az) {
    if ($Az.Contains('TipoAttesa') -and $Az['TipoAttesa']) { return [string]$Az['TipoAttesa'] }
    [string]$Az.Motivo
}

function Test-PassataGiaFatta($a, [string]$Chiave) { @(Get-Campo $a.SC 'passateFatte') -contains $Chiave }

# Cio che il responsabile riceve: il motivo dell'attesa e i dettagli che l'istantanea gia ha (il testo dell'ultima sessione,
# il link del run di deploy e della build della PR).
function New-AllegatoAttesa($a, $Az) {
    $righe = @("La card stava per andare in on-hold per una persona. Motivo: $($Az.Motivo)")
    $testo = "$(Get-Campo $a.Ultima 'testo')"
    if ($a.UltimoRuolo -and -not [string]::IsNullOrWhiteSpace($testo)) {
        $esito = "$(Get-Campo $a.Ultima 'esito')"
        $righe += "Ultima sessione ($($a.UltimoRuolo)$(if ($esito) { ", esito $esito" })):`n$testo"
    }
    $run = Get-Campo $a.Run 'Url'
    if ($run) { $righe += "Run del deploy in Test: $run" }
    $build = Get-Campo $a.Pr 'UrlLog'
    if ($build) { $righe += "Build della PR: $build" }
    $righe -join "`n`n"
}

# Il punto unico: ogni MettiInAttesa decisa dallo stato diventa, la prima volta per il suo tipo, la passata del responsabile
# (si ricorda cosa si e evitato, poi parte il responsabile con il motivo 'attesa'). Restano on-hold dritte: le attese
# marcate Diretta, quelle nate da una sessione del responsabile, e quelle il cui tipo ha gia avuto la sua passata da quando
# una persona e intervenuta l'ultima volta.
function Convert-AttesePerResponsabile($a, $Azioni) {
    foreach ($az in @($Azioni)) {
        if ($az.Tipo -ne 'MettiInAttesa') { $az; continue }
        $diretta = $az.Contains('Diretta') -and $az['Diretta']
        $chiave = Get-ChiavePassata $az
        $az.Remove('Diretta'); $az.Remove('TipoAttesa')
        if ($diretta -or $a.UltimoRuolo -eq 'responsabile' -or (Test-PassataGiaFatta $a $chiave)) { $az; continue }
        New-Azione 'AvviaPassataAttesa' @{ Motivo = $az.Motivo; Per = $az.Per; Ruolo = $a.UltimoRuolo; Chiave = $chiave }
        New-Lancia 'responsabile' 'attesa' (New-AllegatoAttesa $a $az)
    }
}

# La rete di sicurezza: il responsabile ha finito (sessione chiusa, motivo attesa, bloccato o bivio) e nessuna regola sa
# come proseguire. Senza, la card restava ferma senza on-hold e senza nessuno che la muovesse: una passata chiusa con
# l'attesa in esame persa, delle domande su un bivio di dev senza la card in Needs clarification. Non vale quando la card
# aspetta altro: in Needs clarification aspetta le risposte di una persona, e un blocco di partenza ha gia il suo motivo.
function Test-ResponsabileSenzaSeguito($a) {
    $a.UltimoRuolo -eq 'responsabile' -and (Test-Finita $a.Ultima) -and
        (Get-Campo $a.Ultima 'motivo') -in 'attesa', 'bloccato', 'bivio' -and
        $a.Chiave -ne 'daChiarire' -and $null -eq (Get-BloccoPartenza $a)
}

# I gesti che una persona deve fare e lo smistatore le segnala con un avviso, per stato della card: tipo dell'avviso, a chi
# va e testo. Sono la sola definizione, usata da chi emette l'avviso e da Get-GestoAtteso per riconoscerlo gia registrato.
# Resta solo la prova in Test del richiedente (stato inProvaUmana): test e merge in develop vanno da soli, a mano resta il
# rilascio in produzione.
$script:GestiAttesi = @{
    inProvaUmana = @{ Tipo = 'testPronto'; Chi = 'richiedente'; Testo = 'Il deploy in Test e riuscito: la card aspetta la tua verifica.' }
}

# Chiave = <tipo>@<revisione dell'ultimo cambio di stato>: e' la voce da aggiungere a StatoCard.avvisi.
function New-Avviso($a, $Gesto) {
    New-Azione 'Avvisa' @{ Chi = $Gesto.Chi; Testo = $Gesto.Testo; Chiave = "$($Gesto.Tipo)@$($a.RevIngresso)" }
}

function Test-CommentoDiPersona($Commento) {
    $t = "$(Get-Campo $Commento 'Testo')"
    # il testo puo arrivare con un involucro html e con la menzione davanti: si guarda il primo [ruolo] vero
    $t -notmatch "^$script:PrefissoCommento\[(?:$script:RuoliAgente)\]"
}

function Test-Finita($Sessione) { $null -ne $Sessione -and $null -ne (Get-Campo $Sessione 'fine') }

function Test-RevisioneSuperata($a) {
    $rev = $a.UltimaPerRuolo['reviewer']
    if (-not (Test-Finita $rev) -or (Get-Campo $rev 'esito') -ne 'superata') { return $false }
    $dev = $a.UltimaPerRuolo['dev']
    if (-not (Test-Finita $dev)) { return $true }
    $fr = ConvertTo-DataUtc (Get-Campo $rev 'fine'); $fd = ConvertTo-DataUtc (Get-Campo $dev 'fine')
    if ($null -eq $fr -or $null -eq $fd) { return $false }
    $fr -gt $fd
}

# Il run vale se e stato accodato dopo l'ultimo ingresso in inDeployTest: runDopoRev e la revisione di quell'ingresso.
function Test-RunValido($a) { Test-RunValidoDa $a.SC $a.Ingresso }

# D59: la card ha un run da seguire: quello del deploy in Test, o l'ambiente di collaudo che si sta creando (stessa forma, stesso runDopoRev).
function Test-RunSalvato($SC) { $null -ne (Get-Campo $SC 'runId') -or $null -ne (Get-Campo $SC 'collaudoProgetto') }

function Test-RunValidoDa($SC, $Ingresso) {
    $r = Get-Campo $SC 'runDopoRev'
    (Test-RunSalvato $SC) -and $null -ne $r -and $null -ne $Ingresso -and [int]$r -eq [int](Get-Campo $Ingresso 'Rev')
}

# L'ultimo ingresso della card nello stato in cui si trova, dalla storia dei cambi di stato; null se non c'e.
function Get-IngressoStato($Card, $Storia) {
    $stato = Get-Campo $Card 'Stato'
    $ordinata = @(@($Storia) | Where-Object { $null -ne $_ } | Sort-Object { [int](Get-Campo $_ 'Rev') })
    @($ordinata | Where-Object { (Get-Campo $_ 'A') -ieq $stato }) | Select-Object -Last 1
}

# Per l'istantanea (D43): i commenti di deploy e lo YAML della pipeline servono solo prima di accodare il deploy, cioe quando
# la run non vale per l'ingresso attuale, o quando e fallita (tolto l'on-hold si riaccoda). Mentre la run vale non si leggono.
function Test-DeployDaLeggere {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Card, $Storia, [Parameter(Mandatory)]$StatoCard, $Run)
    if (-not (Test-RunValidoDa $StatoCard (Get-IngressoStato $Card $Storia))) { return $true }
    $null -ne $Run -and (Get-Campo $Run 'Stato') -eq 'completed' -and (Get-Campo $Run 'Esito') -ne 'succeeded'
}

# Le altre card (id) che occupano un posto in una tabella dei limiti, senza quella in esame.
function Get-AltreCard($Tabella, $Chiave, [int]$Id) {
    $l = Get-Campo $Tabella "$Chiave"
    if ($null -eq $l) { return @() }
    @(@($l) | Where-Object { [int]$_ -ne $Id } | ForEach-Object { [int]$_ })
}

function Get-Altre($Tabella, $Chiave, [int]$Id) { @(Get-AltreCard $Tabella $Chiave $Id).Count }

# Dove riportare una card che sta sull'ambiente di Test: lo stato da cui e entrata. Se quello e uno dei tre stati di Test
# (per esempio in Automated test si arriva da Deploying to test) si va In review: tornare nello stato di Test precedente
# rifarebbe lo stesso giro all'indietro senza mai uscirne.
function Get-StatoPrecedente($a) {
    if ($null -eq $a.Ingresso) { return $null }
    $prima = Get-ChiaveStato $a.Stati (Get-Campo $a.Ingresso 'Da')
    if ($prima -in (Get-StatiInTest)) { return 'inRevisione' }
    $prima
}

# Un predecessore e unito quando il suo lavoro e in develop: Releasing e Closed, oppure Ready to release con la PR completata
# (prId noto) e il worktree gia tolto da RimuoviWorktree (cartella vuota). Tutto il resto no, anche la card rimossa:
# finche una persona non toglie il link la card dipendente aspetta.
# D52: In feature branch (il lavoro e nel ramo della funzionalita, non in develop) vale come unito solo per una card della stessa
# Feature, cioe se il predecessore ha come padre FeatureId, quella della card che aspetta: solo il suo ramo contiene quel lavoro.
# Per tutte le altre (FeatureId nullo: una card isolata) unito vuol dire in develop.
function Test-PredecessoreUnito($Stati, $P, $FeatureId = $null) {
    switch (Get-ChiaveStato $Stati (Get-Campo $P 'Stato')) {
        'inRilascio' { return $true }
        'chiusa' { return $true }
        'inFeature' {
            $padre = Get-Campo $P 'PadreId'
            return $null -ne $FeatureId -and $null -ne $padre -and [int]$padre -eq [int]$FeatureId
        }
        'daRilasciare' { return $null -ne (Get-Campo $P 'prId') -and [string]::IsNullOrWhiteSpace("$(Get-Campo $P 'cartella')") }
        default { return $false }
    }
}

# I predecessori non ancora uniti: e la sola definizione di "aspetta", usata anche dal giro per scriverla nel log.
function Get-PredecessoriInAttesa($Stati, $Predecessori, $FeatureId = $null) {
    @(@($Predecessori) | Where-Object { $null -ne $_ -and -not (Test-PredecessoreUnito $Stati $_ $FeatureId) })
}

# D52: a quale percorso appartiene la card, una fonte sola per tutto il modulo. 'funzionalita': la card e della funzionalita (non la card
# di chiusura, e la lettura non e fallita); 'isolata': il percorso di sempre; 'perduta': la card ha la destinazione sul ramo della
# funzionalita ma la funzionalita non c'e piu (Feature rimossa, chiusura tolta o senza tag), e nessuna regola sa dove portarla.
# Prima del worktree decide la gerarchia di ADO (Funzionalita): negli stati di partenza, o se la card non ha nessuna traccia locale
# (e da prendere in carico). Dal worktree in poi decide la destinazione salvata nello stato (Get-DestinazioneCard, scritta da
# CreaWorktree e da AdottaCard): con develop la card e isolata anche se nel frattempo e stata legata a una Feature; con il ramo della
# funzionalita lo e solo se la funzionalita c'e ancora. In feature branch ha senso solo per la funzionalita. Negli stati dopo il merge
# (Ready to release e oltre) non conta: li la perdita non ferma niente.
function Get-PercorsoCard($a) {
    $f = $a.Funzionalita
    $valida = $null -ne $f -and -not (Get-Campo $f 'Errore') -and -not (Get-Campo $f 'EChiusura')
    $traccia = (Get-Campo $a.SC 'ramo') -or (Get-Campo $a.SC 'cartella') -or (Get-Campo $a.SC 'prId') -or (Get-Campo $a.SC 'destinazione')
    if ($a.Chiave -in 'nuova', 'daChiarire', 'pronto' -or -not $traccia) { return $(if ($valida) { 'funzionalita' } else { 'isolata' }) }
    $sulRamo = (Get-DestinazioneCard $a.SC) -ne 'develop'
    if ($sulRamo -and $valida) { return 'funzionalita' }
    $incorso = $a.Chiave -in 'inSviluppo', 'inRevisione', 'inDeployTest', 'inCollaudo', 'inProvaUmana', 'daUnire', 'inFeature'
    if ($incorso -and ($sulRamo -or $a.Chiave -eq 'inFeature')) { return 'perduta' }
    'isolata'
}

# D52: la card e della funzionalita. Per le funzioni di questo modulo la domanda ha questa risposta sola: Get-PercorsoCard.
function Test-CardFunzionalita($a) { (Get-PercorsoCard $a) -eq 'funzionalita' }

# D52: la card di chiusura della funzionalita (non ha worktree: il suo ramo e quello della funzionalita, la destinazione develop). Per
# Get-PercorsoCard e un percorso isolato (non e una card della funzionalita): passa dai Test e dal merge in develop con le regole sue.
# La domanda ha questa risposta sola.
function Test-CardChiusura($a) {
    $f = $a.Funzionalita
    $null -ne $f -and -not (Get-Campo $f 'Errore') -and [bool](Get-Campo $f 'EChiusura')
}

# D52: una sorella e unita quando il suo lavoro e nel ramo della funzionalita: In feature branch o oltre. Sono figlie della stessa Feature
# per definizione, quindi non serve altro (Test-PredecessoreUnito, per i predecessori veri, chiede lo stato locale).
function Test-SorellaUnita($Stati, $S) {
    (Get-ChiaveStato $Stati (Get-Campo $S 'Stato')) -in 'inFeature', 'daRilasciare', 'inRilascio', 'chiusa'
}

# D52: le sorelle della card di chiusura non ancora unite nel ramo (Sorelle non porta mai le Removed: Get-ComposizioneFunzionalita).
function Get-SorelleNonUnite($a) {
    @(@(Get-Campo $a.Funzionalita 'Sorelle') | Where-Object { $null -ne $_ -and -not (Test-SorellaUnita $a.Stati $_) })
}

# La prova di una persona (tag human-test): la card non passa dal collaudatore ma dal richiedente. Una definizione sola.
function Test-ProvaUmana($a) {
    $umana = Get-Campo $a.Stati 'tagProvaUmana'
    [bool]($umana -and @($a.Tag) -contains $umana)
}

# Niente da provare in Test: la card ha il tag no-test-deploy (deciso nell'analisi o da responsabile, con il motivo sulla
# card), oppure il suo componente non ha un deploy in Test, oppure e della funzionalita (D52: il Test lo fa la card di chiusura
# sul ramo della funzionalita). Dalla revisione superata va dritta in Ready to merge.
function Test-SenzaTest($a) {
    $tag = Get-Campo $a.Stati 'tagSenzaTest'
    ($tag -and @($a.Tag) -contains $tag) -or -not (Test-HaTest $a.Voce) -or (Test-CardFunzionalita $a)
}

# D59: il componente ha un Test: o il deploy in Test (pipelineDeploy) o l'ambiente Docker della card (collaudo).
function Test-HaTest($Voce) { [bool](Get-Campo $Voce 'pipelineDeploy') -or (Test-AmbienteCollaudo $Voce) }

# D59: lo slot di un ambiente nuovo, il piu piccolo da 1 a Massimo che le altre card non usano; 0 se sono tutti presi. Lo slot decide le porte.
function Get-SlotCollaudoLibero($Usati, [int]$Massimo) {
    $presi = @(@($Usati) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
    foreach ($n in 1..$Massimo) { if ($n -notin $presi) { return $n } }
    0
}


# Una card In review con la revisione superata passa da sola In Deploying to test. Se un'altra card dello stesso componente
# e gia in uno dei tre stati di Test (l'ambiente e uno) resta In review: e il blocco, con le card che tengono il posto. Null se la card non e pronta
# a passare o se il posto e libero.
function Get-BloccoIngressoInTest($a) {
    if (Test-SenzaTest $a) { return $null }   # non entra in Test: il posto occupato non la ferma
    if ($a.UltimoRuolo -ne 'reviewer' -or (Get-Campo $a.Ultima 'esito') -ne 'superata' -or -not (Test-RevisioneSuperata $a)) { return $null }
    if ($a.TaskAperti.Count -gt 0) { return $null }
    # Ruolo: chi prendera la card quando il blocco cade. Qui e il collaudatore, che la prova dopo il deploy in Test; con
    # human-test la prova e di una persona e il collaudatore non la tocchera mai, quindi nessun ruolo.
    Get-BloccoLimiteTest $a $(if (Test-ProvaUmana $a) { $null } else { 'collaudatore' })
}

# Il posto in Test e uno per componente (cardInTestPerComponente), o uno degli ambienti di collaudo (D59): il blocco se le altre card dello stesso componente lo occupano, null
# se e libero. E la sola definizione: la usano l'ingresso in Test di una card isolata e quello della card di chiusura.
function Get-BloccoLimiteTest($a, $Ruolo) {
    # D59: con l'ambiente di collaudo il posto non e del componente ma di uno degli ambienti (ambientiCollaudo), comuni a tutti i componenti
    if (Test-AmbienteCollaudo $a.Voce) {
        $l = [int](Get-Campo $a.Limiti 'ambientiCollaudo')
        $altre = @(@(Get-Campo $a.Contesto 'AmbientiCollaudo') | Where-Object { $null -ne $_ -and [int]$_ -ne $a.Id } | ForEach-Object { [int]$_ })
        if ($altre.Count -ge $l) { return @{ Tipo = 'limiteAmbienti'; Ruolo = $Ruolo; Limite = $l; Card = $altre } }
        return $null
    }
    $l = [int](Get-Campo $a.Limiti 'cardInTestPerComponente')
    $componente = Get-Campo $a.Voce 'componente'
    $altre = @(Get-AltreCard $a.Contesto.InTestPerComponente $componente $a.Id)
    if ($altre.Count -ge $l) { return @{ Tipo = 'limiteTest'; Ruolo = $Ruolo; Componente = $componente; Limite = $l; Card = $altre } }
    $null
}

# D52: In feature branch il worktree si toglie solo con la PR completata nel ramo della funzionalita (come in Ready to release): un
# worktree con la PR ancora aperta, o non trovata, ha lavoro che nessuno ha unito. Null se non c'e da aspettare.
function Get-BloccoInFeature($a) {
    if ($null -eq (Get-Campo $a.SC 'cartella')) { return $null }
    if ($null -ne $a.Pr -and (Get-Campo $a.Pr 'Stato') -eq 'completed') { return $null }
    @{ Tipo = 'inFeatureSenzaPrUnita'; Ruolo = $null; Destinazione = (Get-DestinazioneCard $a.SC) }
}

# D52: la card della funzionalita in Ready to merge non completa la PR finche la card di chiusura prova il ramo della funzionalita
# (Deploying to test, Automated test, Human test, Ready to merge): il ramo in prova non cambia sotto il collaudo. Lo stato della
# chiusura e quello che l'istantanea ha gia letto con le figlie della Feature, nessuna chiamata in piu. Null se non c'e da aspettare.
function Get-BloccoCollaudoFunzionalita($a) {
    if (-not (Test-CardFunzionalita $a)) { return $null }
    $nome = Get-Campo $a.Funzionalita 'StatoChiusura'
    if ((Get-ChiaveStato $a.Stati $nome) -notin ((Get-StatiInTest) + @('daUnire'))) { return $null }
    @{ Tipo = 'attesaCollaudoFunzionalita'; Ruolo = $null; Chiusura = [int](Get-Campo $a.Funzionalita 'Chiusura'); Stato = [string]$nome }
}

# D52: la card di chiusura in Draft non la legge nessuno (Get-AdoCardAttive scarta le Draft, come lo smistatore e la vista): quando tutte le
# sorelle sono unite nel ramo e lei aspetta ancora una persona che la sposti in New, lo dice una sorella In feature branch, che la legge.
# Non e un blocco di partenza (non ferma le azioni della sorella, come togliere il worktree): e il motivo di una card senza altro da fare.
# Null se la card non e una sorella In feature branch, se la chiusura non e in Draft o se una sorella non e ancora unita.
function Get-BloccoChiusuraInBozza($a) {
    if ($a.Chiave -ne 'inFeature' -or -not (Test-CardFunzionalita $a)) { return $null }
    if ((Get-ChiaveStato $a.Stati (Get-Campo $a.Funzionalita 'StatoChiusura')) -ne 'bozza') { return $null }
    $sorelle = @(@(Get-Campo $a.Funzionalita 'Sorelle') | Where-Object { $null -ne $_ })
    if ($sorelle.Count -eq 0 -or @($sorelle | Where-Object { -not (Test-SorellaUnita $a.Stati $_) }).Count -gt 0) { return $null }
    $chiusura = [int](Get-Campo $a.Funzionalita 'Chiusura')
    @{ Tipo = 'chiusuraInBozza'; Ruolo = $null; Chiusura = $chiusura; Gesto = "sposta la card #$chiusura in New" }
}

# Perche una card non parte, se non parte per un blocco proprio dello stato: in New e in Ready to develop i predecessori
# non uniti, poi (solo Ready to develop) il limite di card in sviluppo per repo; In review il limite di card in Test per
# componente. Null se nessun blocco. E la sola definizione, usata sia da Get-AzioniNuova/Get-AzioniPronto/
# Get-AzioniInRevisione sia da Get-Decisione per dire il motivo.
function Get-BloccoPartenza($a) {
    if ((Get-PercorsoCard $a) -eq 'perduta') { return @{ Tipo = 'funzionalitaPerduta'; Ruolo = $null; Stato = [string](Get-Campo $a.Card 'Stato'); Destinazione = (Get-DestinazioneCard $a.SC) } }
    if ($a.Chiave -eq 'inFeature') { return Get-BloccoInFeature $a }
    if ($a.Chiave -eq 'inRevisione') { return Get-BloccoIngressoInTest $a }
    $chiusura = Test-CardChiusura $a
    if ($a.Chiave -eq 'daUnire') { return $(if ($chiusura) { Get-BloccoCiChiusura $a } else { Get-BloccoCollaudoFunzionalita $a }) }
    if ($chiusura -and $a.Chiave -eq 'inDeployTest') { return Get-BloccoCiChiusura $a }
    if ($a.Chiave -notin 'nuova', 'pronto') { return $null }
    $inAttesa = @(Get-PredecessoriInAttesa $a.Stati $a.Predecessori $(if ((Test-CardFunzionalita $a) -or $chiusura) { [int]$a.Funzionalita.Feature.Id } else { $null }))
    # Ruolo: chi prendera la card quando il blocco cade, dedotto dallo stato (e l'unico punto in cui si deduce, la vista lo
    # legge da qui): in New la prende responsabile, in Ready to develop dev; la card di chiusura in Ready to develop non la prende nessuno.
    $ruolo = if ($a.Chiave -eq 'nuova') { 'responsabile' } elseif ($chiusura) { $null } else { 'dev' }
    if ($chiusura) {
        # D52: i predecessori della card di chiusura sono le sue sorelle non unite (e gli eventuali predecessori veri). Senza sorelle non c'e da provare niente.
        if (@(@(Get-Campo $a.Funzionalita 'Sorelle') | Where-Object { $null -ne $_ }).Count -eq 0) { return @{ Tipo = 'senzaSorelle'; Ruolo = $ruolo; Feature = [int]$a.Funzionalita.Feature.Id } }
        $inAttesa = @(Get-SorelleNonUnite $a) + $inAttesa
        if ($inAttesa.Count -gt 0) { return @{ Tipo = 'predecessori'; Ruolo = $ruolo; Predecessori = $inAttesa; Sorelle = $true } }
        if ($a.Chiave -eq 'pronto') { return Get-BloccoCiChiusura $a }
        return $null
    }
    if ($inAttesa.Count -gt 0) { return @{ Tipo = 'predecessori'; Ruolo = $ruolo; Predecessori = $inAttesa } }
    if ($a.Chiave -ne 'pronto') { return $null }
    $l = [int](Get-Campo $a.Limiti 'cardInSviluppoPerRepo')
    $repo = Get-Campo $a.Voce 'repo'
    $altre = @(Get-AltreCard $a.Contesto.InSviluppoPerRepo $repo $a.Id)
    if ($altre.Count -ge $l) { return @{ Tipo = 'limiteRepo'; Ruolo = 'dev'; Repo = $repo; Limite = $l; Card = $altre } }
    $null
}

# D52: cosa ferma la card di chiusura oltre alle sorelle: la PR ramo della funzionalita -> develop in conflitto (Ready to develop, Ready to
# merge), la CI rossa (la validazione della PR in Ready to develop e in Ready to merge; il run del deploy in Deploying to test), solo con
# errori di codice (ErroriBuild: test falliti o errori di compilazione; senza, nel dubbio e infrastruttura: un rilancio della validazione,
# o il deploy fallito di sempre), il posto in Test occupato (PR verde). Null se niente la ferma. Ruolo e sempre null: e un'attesa. Le
# prime due non sono pero solo attese: Get-AzioneBloccoChiusura ne ricava il lavoro (il responsabile scrive la correzione, lo smistatore
# crea la Bug allinea-develop), una volta; poi la card aspetta le sorelle (la Bug) e, se non cambia niente, questo motivo.
function Get-BloccoCiChiusura($a) {
    $pr = $a.Pr
    switch ($a.Chiave) {
        'pronto' {
            if ($null -eq $pr) { return $null }
            switch (Get-Campo $pr 'Validazione') {
                'conflitti' { return (New-BloccoConflittiFunzionalita $a) }
                # solo con errori di codice (test falliti, compilazione): senza, nel dubbio e infrastruttura e si rilancia (Get-AzioniProntoChiusura)
                'rossa' { if (-not [string]::IsNullOrWhiteSpace("$($a.ErroriBuild)")) { return (New-BloccoCiRossaFunzionalita $a 'validazione' (Get-Campo $pr 'BuildId') (Get-Campo $pr 'UrlLog')) } }
                'verde' { if (-not (Test-SenzaTest $a)) { return (Get-BloccoLimiteTest $a $null) } }
            }
        }
        'inDeployTest' {
            $run = $a.Run
            if (-not (Test-RunValido $a) -or $null -eq $run -or (Get-Campo $run 'Stato') -ne 'completed' -or (Get-Campo $run 'Esito') -eq 'succeeded') { return $null }
            if ([string]::IsNullOrWhiteSpace("$($a.ErroriBuild)")) { return $null }
            return (New-BloccoCiRossaFunzionalita $a 'deploy' (Get-Campo $a.SC 'runId') (Get-Campo $run 'Url'))
        }
        'daUnire' {
            if ($null -eq $pr -or (Get-Campo $pr 'Stato') -ne 'active') { return $null }
            switch (Get-Campo $pr 'Validazione') {
                'conflitti' { return (New-BloccoConflittiFunzionalita $a) }
                # la validazione rossa dopo un rilancio di scadute: come in Ready to develop, non e un completamento che non riesce
                'rossa' { if (-not [string]::IsNullOrWhiteSpace("$($a.ErroriBuild)")) { return (New-BloccoCiRossaFunzionalita $a 'validazione' (Get-Campo $pr 'BuildId') (Get-Campo $pr 'UrlLog')) } }
            }
        }
    }
    $null
}

function New-BloccoConflittiFunzionalita($a) {
    @{ Tipo = 'conflittiFunzionalita'; Ruolo = $null; Ramo = [string](Get-Campo $a.SC 'ramo'); Destinazione = (Get-DestinazioneCard $a.SC) }
}

# Build: l'id della build rossa (della PR, o del run del deploy): e la chiave con cui si ricorda che il responsabile l'ha gia vista.
function New-BloccoCiRossaFunzionalita($a, [string]$Fonte, $Build, $Url) {
    @{ Tipo = 'ciRossaFunzionalita'; Ruolo = $null; Fonte = $Fonte; Build = $Build; Url = $Url; Errori = [string]$a.ErroriBuild }
}

# I campi che una persona azzera togliendo un on-hold per limite: un elenco solo, per Get-Decisione (che decide come se fossero gia a zero) e
# per l'azione AzzeraContatori di chi esegue. ciRosseDiFila e il contatore delle sessioni del responsabile per la CI rossa.
function Get-CampiContatori {
    [ordered]@{ giriRevisione = 0; rosseDiFila = 0; giriCollaudo = 0; rilanci = 0; ciRosseDiFila = 0; completaPr = $null; ritornoCommit = $null; inAttesaPer = $null }
}

# La CI della card di chiusura e verde: la validazione della PR, o il run del deploy riuscito.
function Test-CiChiusuraVerde($a) {
    if ($null -ne $a.Pr -and (Get-Campo $a.Pr 'Validazione') -eq 'verde') { return $true }
    $run = $a.Run
    $a.Chiave -in (Get-StatiInTest) -and (Test-RunValido $a) -and $null -ne $run -and (Get-Campo $run 'Stato') -eq 'completed' -and (Get-Campo $run 'Esito') -eq 'succeeded'
}

# D52, gruppo 5: il lavoro che un blocco della card di chiusura porta con se, una volta sola; altrimenti niente, e la card aspetta con il
# motivo del blocco (Get-Decisione).
# La CI rossa con errori di codice: il responsabile (motivo ciRossa, gli errori come allegato) scrive la correzione; una volta per build
# (ciRossaGestita), e al piu rosseDiFila volte di fila (ciRosseDiFila, azzerato dalla CI verde). Se ha guardato la build e non ha scritto
# una correzione, qualunque sia il suo esito, serve una persona: on-hold, non un'attesa muta. Quando una persona toglie quell'on-hold, per
# la validazione si rilancia la validazione invece di rilanciare il responsabile sulla stessa build.
# I conflitti con develop: lo smistatore crea la Bug allinea-develop, da se (la decisione e meccanica), una volta per commit di testa
# della PR; se per quel commit la Bug c'e gia ma nessuna sorella allinea-develop e viva (rimossa senza unirla), serve una persona.
function Get-AzioneBloccoChiusura($a, $Blocco) {
    switch ($Blocco.Tipo) {
        'ciRossaFunzionalita' {
            $build = [string]$Blocco.Build
            if ([string]::IsNullOrWhiteSpace($build)) { return }
            if ([string](Get-Campo $a.SC 'ciRossaGestita') -eq $build) {
                if ((Get-Campo $a.SC 'ciRossaRiprova') -and $Blocco.Fonte -eq 'validazione') { return New-Azione 'RilanciaValidazione' @{ Sessione = '' } }
                $u = $a.Ultima
                if ($a.UltimoRuolo -eq 'responsabile' -and (Test-Finita $u) -and (Get-Campo $u 'motivo') -eq 'ciRossa') {
                    return New-Attesa "il responsabile ha guardato la CI rossa della card di chiusura (build $build) e non ha scritto una correzione: serve una persona, la sua diagnosi e nel commento sulla card" 'limite' -Diretta
                }
                return
            }
            $limite = [int](Get-Campo $a.Limiti 'rosseDiFila')
            if ($limite -gt 0 -and [int](Get-Campo $a.SC 'ciRosseDiFila') -ge $limite) {
                return New-Attesa "troppe sessioni del responsabile per la CI rossa della card di chiusura ($limite di fila): una persona guarda la build ($($Blocco.Url))" 'limite' -Diretta
            }
            $dove = if ($Blocco.Fonte -eq 'deploy') { 'Il deploy in Test della card di chiusura ha la build o i test falliti' } else { 'La validazione della PR della card di chiusura e rossa' }
            $allegato = "$dove (build $build$(if ($Blocco.Url) { ", $($Blocco.Url)" })), con errori di codice. Scrivi la correzione (card.ps1 correzione) se la causa e nel codice della funzionalita.`n`nErrori:`n$($Blocco.Errori)"
            $lancio = New-Lancia 'responsabile' 'ciRossa' $allegato
            $lancio['Build'] = $build
            $lancio
        }
        'conflittiFunzionalita' {
            $commit = [string](Get-Campo $a.Pr 'UltimoCommit')
            $fatti = @(@(Get-Campo $a.SC 'allineaFatti') | Where-Object { $null -ne $_ }) + @(Get-BugCreate $a.CommentiTutti 'allinea')
            if ($commit -and $fatti -contains $commit) {
                $viva = @(@(Get-Campo $a.Funzionalita 'Sorelle') | Where-Object { $null -ne $_ -and @($_.Tag) -contains [string]$a.Stati.tagAllinea })
                if ($viva.Count -eq 0) {
                    return New-Attesa "la PR $($Blocco.Ramo) verso $($Blocco.Destinazione) ha ancora conflitti e la Bug allinea-develop per questo commit non c'e piu (rimossa senza unirla?): una persona decide" 'limite' -Diretta
                }
                return
            }
            New-Azione 'CreaAllineaDevelop' @{ FeatureId = [int]$a.Funzionalita.Feature.Id; Ramo = $Blocco.Ramo; Commit = $commit }
        }
    }
}
# D52, gruppo 5: la prossima correzione scritta dal responsabile sulla card di chiusura di cui non c'e ancora la Bug. La chiave e l'id del
# commento (correzioniFatte): una correzione, una Bug. Si leggono tutti i commenti, non solo i nuovi: la chiave basta a non rifarla.
function Get-CorrezioneDaFare($a) {
    # fatta = la chiave e nello stato locale (scorciatoia) o c'e il commento dello smistatore sulla card (vale da ogni PC e a stato perso)
    $fatte = @(@(Get-Campo $a.SC 'correzioniFatte') | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) + @(Get-BugCreate $a.CommentiTutti 'correzione')
    @(Get-CorrezioniScritte $a.CommentiTutti | Where-Object { [string]$_.Id -notin $fatte }) | Select-Object -First 1
}

# ---- una funzione per stato --------------------------------------------------------------------------------------

function Get-AzioniNuova($a) {
    if (Get-BloccoPartenza $a) { return }
    # responsabile ha gia' finito su questa card e la card e' ancora in New: non ha portato avanti niente
    if ($a.UltimoRuolo -eq 'responsabile' -and (Test-Finita $a.Ultima)) {
        $fine = ConvertTo-DataUtc (Get-Campo $a.Ultima 'fine')
        $dal = if ($a.Ingresso) { ConvertTo-DataUtc (Get-Campo $a.Ingresso 'Quando') } else { $null }
        if ($null -eq $fine -or $null -eq $dal -or $fine -ge $dal) {
            return New-Attesa 'responsabile ha finito ma la card e rimasta in New' 'sessione'
        }
    }
    New-Lancia 'responsabile' 'nuova'
}

function Get-AzioniDaChiarire($a) {
    if (@($a.Commenti | Where-Object { Test-CommentoDiPersona $_ }).Count -gt 0) {
        return New-Lancia 'responsabile' 'commento'
    }
}

# D52: la card di chiusura in Ready to develop non sviluppa niente e non ha un worktree: apre la PR ramo della funzionalita -> develop e
# ne segue la validazione. Il ramo salvato c'e gia (ImpostaRamoChiusura, prima dello switch di Get-AzioniDelloStato); le sorelle, la PR
# in conflitto, la CI rossa e il posto in Test occupato sono un motivo (Get-BloccoPartenza) e arrivano qui gia filtrati.
function Get-AzioniProntoChiusura($a) {
    if ($null -eq $a.Pr) { return New-Azione 'ApriPr' }
    switch (Get-Campo $a.Pr 'Validazione') {
        'verde' { New-Azione 'SpostaCard' @{ Stato = 'inDeployTest' } }
        # D47: develop e cambiato e la validazione e scaduta
        'scaduta' { New-Azione 'RilanciaScadute' }
        # rossa con errori di codice e gia un motivo (Get-BloccoPartenza). Senza, nel dubbio e infrastruttura: un rilancio (conta in rilanci),
        # e se resta rossa decide una persona
        'rossa' {
            if ([int](Get-Campo $a.SC 'rilanci') -ge 1) {
                New-Attesa "la validazione della PR e rossa senza errori di codice anche dopo un rilancio: sembra infrastruttura, guarda la build ($(Get-Campo $a.Pr 'UrlLog'))" 'limite'
            }
            else { New-Azione 'RilanciaValidazione' @{ Sessione = '' } }
        }
    }
}

function Get-AzioniPronto($a) {
    $blocco = Get-BloccoPartenza $a
    # D52: dei blocchi della card di chiusura due portano un lavoro (la correzione per la CI rossa, la Bug allinea-develop per i conflitti)
    if ($blocco) { if (Test-CardChiusura $a) { return Get-AzioneBloccoChiusura $a $blocco }; return }
    if (Test-CardChiusura $a) { return Get-AzioniProntoChiusura $a }
    if (Test-CardFunzionalita $a) {
        # D52: il worktree parte dal ramo della funzionalita, che si crea prima se su origin non c'e ancora (Ramo nullo: la base la
        # riempie chi esegue, con il ramo appena creato). La Feature passa Active con la prima card che entra in sviluppo.
        $f = $a.Funzionalita
        if ($null -eq (Get-Campo $f 'Ramo')) { New-Azione 'CreaRamoFunzionalita' @{ FeatureId = [int]$f.Feature.Id } }
        New-Azione 'CreaWorktree' @{ Base = (Get-Campo $f 'Ramo') }
        if ((Get-Campo $f.Feature 'Stato') -ieq (Get-Campo $a.Stati 'featureNuova')) {
            New-Azione 'AggiornaFeature' @{ FeatureId = [int]$f.Feature.Id; Stato = 'featureAttiva' }
        }
    }
    else { New-Azione 'CreaWorktree' }
    New-Azione 'SpostaCard' @{ Stato = 'inSviluppo' }
    New-Lancia 'dev' 'pronto' $null $false (Get-PrimoTaskAperto $a)
}

# Il titolo con cui si apre la PR. La pr-validation dei repo vuole un tipo conventional-commit coerente col prefisso
# del ramo (feature/* -> feat, rami di bug -> fix), perche develop ricava la versione dai titoli delle PR unite.
function Get-TitoloPr([string]$Ramo, [string]$Titolo) {
    $titolo = $Titolo.Trim()
    if ($titolo -cmatch '^[a-z]+(\([^)]*\))?!?:') { return $titolo }
    $tipo = if ($Ramo -match '^feature[/-]') { 'feat' } elseif ($Ramo -match '^(bug)?fix[/-]') { 'fix' } else { $null }
    if ($tipo) { "${tipo}: $titolo" } else { $titolo }
}

# Il percorso della PR, dopo che dev ha finito: aprirla, poi seguirne la validazione fino a reviewer.
function Get-AzioniPr($a) {
    if ($null -eq $a.Pr) { return New-Azione 'ApriPr' }
    switch (Get-Campo $a.Pr 'Validazione') {
        'rossa' {
            if ((Get-Campo $a.Pr 'BuildId') -eq (Get-Campo $a.SC 'rossaGestita')) { return }
            if ([int](Get-Campo $a.SC 'rosseDiFila') -ge [int](Get-Campo $a.Limiti 'rosseDiFila')) {
                return New-Attesa 'troppe validazioni rosse di fila' 'limite'
            }
            return New-Lancia 'dev' 'rossa' (Get-Campo $a.Pr 'UrlLog')
        }
        'verde' {
            New-Azione 'SpostaCard' @{ Stato = 'inRevisione' }
            New-Lancia 'reviewer' 'verde'
        }
        # D47: develop e cambiato e la validazione e scaduta; per andare dal reviewer serve, quindi si rilancia.
        'scaduta' { return New-Azione 'RilanciaScadute' }
        'conflitti' {
            # I conflitti con develop li risolve dev e li racconta sulla card; una scelta che non sa fare diventa un bivio
            # per responsabile. Se dev ci ha gia provato e restano, decide una persona.
            if ($a.UltimoRuolo -eq 'dev' -and (Get-Campo $a.Ultima 'motivo') -eq 'conflitti') {
                return New-Attesa "la PR ha ancora conflitti con $(Get-DestinazioneCard $a.SC) dopo che dev ha provato a risolverli" $null
            }
            return New-Lancia 'dev' 'conflitti'
        }
        'inCorso' {
            # Una validazione in corso da troppo dopo la fine di dev e un segnale (build bloccata, esito non letto):
            # un avviso, una volta per sessione di dev, senza fermare la card.
            $limite = Get-Campo $a.Limiti 'validazioneMinuti'
            $ora = ConvertTo-DataUtc (Get-Campo $a.Contesto 'Adesso')
            $fine = ConvertTo-DataUtc (Get-Campo $a.Ultima 'fine')
            if ($null -eq $limite -or $null -eq $ora -or $null -eq $fine -or ($ora - $fine).TotalMinutes -le [double]$limite) { return }
            $chiave = "validazioneLunga@$(Get-Campo $a.Ultima 'id')"
            if (@(Get-Campo $a.SC 'avvisi') -contains $chiave) { return }
            return New-Azione 'Avvisa' @{ Chi = 'titolare'; Chiave = $chiave
                Testo = "La validazione della PR e in corso da piu di $limite minuti dalla fine di dev: controlla la build ($(Get-Campo $a.Pr 'UrlLog'))." }
        }
    }
}

function Get-AzioniInSviluppo($a) {
    $esito = Get-Campo $a.Ultima 'esito'
    if ($a.UltimoRuolo -eq 'responsabile' -and $esito -eq 'fatto') {
        # ha risolto un bivio di dev, o ha riportato qui la card da Automated test o Human test con un brief
        $suoi = @($a.Commenti | Where-Object { "$(Get-Campo $_ 'Testo')" -match "^$script:PrefissoCommento\[responsabile\]" })
        $testo = if ($suoi.Count -gt 0) { Get-Campo $suoi[-1] 'Testo' } else { Get-Campo $a.Ultima 'testo' }
        return New-Lancia 'dev' 'decisione' $testo $false (Get-PrimoTaskAperto $a)
    }
    # Il responsabile che non riesce a sbloccare un blocco o un bivio di dev (D40) si ferma per una persona. Senza questa
    # regola la card restava In development senza on-hold e senza nessuno che la muovesse. La passata prima dell'on-hold
    # (motivo 'attesa', D42) la chiude Get-Decisione. Va dritta alla persona: nasce da una sessione del responsabile.
    if ($a.UltimoRuolo -eq 'responsabile' -and $esito -eq 'bloccato' -and (Get-Campo $a.Ultima 'motivo') -ne 'attesa') {
        return New-Attesa 'il responsabile non riesce a sbloccare la card: la sua diagnosi e nel commento' 'sessione'
    }
    # una card con task aperti e nessuna sessione ancora: parte dev sul primo task aperto
    if (-not $a.UltimoRuolo -and $a.TaskAperti.Count -gt 0) { return New-Lancia 'dev' 'task' $null $false (Get-PrimoTaskAperto $a) }
    # Nessuna sessione da qui: la card e stata presa in carico da un altro PC (spec, sezione 19). Con la PR si segue la
    # PR; senza, dev riprende il lavoro dal ramo.
    if (-not $a.UltimoRuolo) {
        if ($null -eq $a.Pr) { return New-Lancia 'dev' 'presaInCarico' }
        return Get-AzioniPr $a
    }
    # D49: la card e tornata In development da uno stato successivo (revisione, Test, collaudo). La riporta il responsabile
    # nella passata prima di un on-hold (D42), che non cambia l'ultimo ruolo, o una persona. Senza questa regola restava ferma
    # in silenzio (card 11, 20/11: ultimo ruolo collaudatore, task #45 aperto, nessuno partiva).
    if ($a.UltimoRuolo -notin 'dev', 'responsabile') {
        $resp = Get-Campo $a.UltimaPerRuolo 'responsabile'
        $fineResp = ConvertTo-DataUtc (Get-Campo $resp 'fine')
        $fineUltima = ConvertTo-DataUtc (Get-Campo $a.Ultima 'fine')
        if ((Get-Campo $resp 'esito') -eq 'fatto' -and $null -ne $fineResp -and ($null -eq $fineUltima -or $fineResp -gt $fineUltima)) {
            $suoi = @($a.Commenti | Where-Object { "$(Get-Campo $_ 'Testo')" -match "^$script:PrefissoCommento\[responsabile\]" })
            $testo = if ($suoi.Count -gt 0) { Get-Campo $suoi[-1] 'Testo' } else { Get-Campo $resp 'testo' }
            return New-Lancia 'dev' 'decisione' $testo $false (Get-PrimoTaskAperto $a)
        }
        if ($a.TaskAperti.Count -gt 0) { return New-Lancia 'dev' 'taskAggiunto' $null $false (Get-PrimoTaskAperto $a) }
        return New-Attesa "la card e tornata In development dopo $($a.UltimoRuolo), senza task aperti ne indicazioni del responsabile" 'limite'
    }
    if ($a.UltimoRuolo -ne 'dev') { return }
    switch ($esito) {
        'bloccato' {
            # D40: prima di fermarsi per una persona guarda il responsabile, che ha piu attrezzi di dev e puo sbloccare
            # (rinominare la PR, chiarire un criterio) o decidere che serve davvero Titolare. Una volta sola: se dev si
            # blocca di nuovo subito dopo la sua decisione, decide una persona.
            $resp = Get-Campo (Get-Campo $a.SC 'ultimaSessione') 'responsabile'
            if ((Get-Campo $a.Ultima 'motivo') -eq 'decisione' -and (Get-Campo $resp 'motivo') -eq 'bloccato') {
                return New-Attesa 'dev e ancora bloccato dopo la decisione del responsabile' 'sessione' -Diretta
            }
            return New-Lancia 'responsabile' 'bloccato' (Get-Campo $a.Ultima 'testo')
        }
        'rilancia' {
            # D38: dev, partito per una validazione rossa, giudica instabile il test che fallisce (non si riproduce e non
            # c'entra con la card). La validazione si rilancia una volta per card; dopo il rilancio si segue la PR come
            # sempre. Un secondo rilancio lo decide una persona: il test va guardato.
            if ((Get-Campo $a.Ultima 'motivo') -ne 'rossa') {
                return New-Attesa 'dev chiede di rilanciare la validazione, ma non era partito per una validazione rossa' 'sessione'
            }
            if ((Get-Campo $a.SC 'rilancioDi') -eq (Get-Campo $a.Ultima 'id')) { return Get-AzioniPr $a }
            if ([int](Get-Campo $a.SC 'rilanci') -ge 1) {
                return New-Attesa 'dev chiede di nuovo di rilanciare la validazione: il test che fallisce va guardato da una persona' 'limite'
            }
            return New-Azione 'RilanciaValidazione' @{ Sessione = [string](Get-Campo $a.Ultima 'id') }
        }
        'bivio' { return New-Lancia 'responsabile' 'bivio' (Get-Campo $a.Ultima 'testo') }
        'fatto' {
            # Il percorso della PR parte solo senza task aperti. Se il task della sessione e ancora aperto dev non l'ha chiuso:
            # non si passa al successivo (la card non gira a vuoto), si aspetta una persona.
            if ($a.TaskAperti.Count -gt 0) {
                $suo = Get-Campo $a.Ultima 'task'
                if (Test-TaskAperto $a $suo) { return New-Attesa "dev ha finito ma il task $suo e ancora aperto: non l'ha chiuso" 'sessione' -Tipo 'taskNonChiuso' }
                return New-Lancia 'dev' 'taskSuccessivo' $null $false (Get-PrimoTaskAperto $a)
            }
            return Get-AzioniPr $a
        }
    }
}

# Un task aperto dopo lo sviluppo (aggiunto da In revisione in poi) riporta la card In development con dev sul primo
# task aperto: la revisione fatta non copre il lavoro nuovo e la rifa il giro normale, dopo la PR aggiornata.
function Get-AzioniTaskAggiunto($a) {
    if ($a.TaskAperti.Count -eq 0) { return }
    New-Azione 'RiportaIndietro' @{ Stato = 'inSviluppo'; Motivo = "C'e un task aperto aggiunto dopo lo sviluppo: la card torna In development" }
    New-Lancia 'dev' 'taskAggiunto' $null $false (Get-PrimoTaskAperto $a)
}

function Get-AzioniInRevisione($a) {
    # presa in carico da un altro PC: la revisione fatta la non si vede da qui, reviewer la rifa
    if (-not $a.UltimoRuolo) { return New-Lancia 'reviewer' 'presaInCarico' }
    if ($a.UltimoRuolo -eq 'dev' -and (Get-Campo $a.Ultima 'esito') -eq 'fatto' -and $a.TaskAperti.Count -eq 0 -and
        $null -ne $a.Pr -and (Get-Campo $a.Pr 'Validazione') -eq 'verde') {
        # tornata qui da uno stato di Test perche la revisione non era piu superata: dev ha finito dopo il reviewer e la PR e
        # verde, la revisione si rifa
        return New-Lancia 'reviewer' 'verde'
    }
    if ($a.UltimoRuolo -ne 'reviewer') { return }
    $esito = Get-Campo $a.Ultima 'esito'
    # con i rilievi la card torna comunque In development: prima i rilievi, il task lo prende il giro dopo
    if ($esito -ne 'bloccante' -and $a.TaskAperti.Count -gt 0) { return Get-AzioniTaskAggiunto $a }
    switch ($esito) {
        'bloccante' {
            if ([int](Get-Campo $a.SC 'giriRevisione') -ge [int](Get-Campo $a.Limiti 'giriRevisione')) {
                return New-Attesa 'troppi giri di revisione' 'limite'
            }
            New-Azione 'SpostaCard' @{ Stato = 'inSviluppo' }
            New-Lancia 'dev' 'rilievi' (Get-Campo $a.Ultima 'testo')
        }
        'superata' {
            if (-not (Test-RevisioneSuperata $a)) { return }
            # nessun gesto da aspettare: la card passa da sola In Deploying to test, dove il giro dopo accoda il deploy; senza
            # niente da provare in Test va dritta in Ready to merge
            if (Get-BloccoPartenza $a) { return }
            New-Azione 'SpostaCard' @{ Stato = $(if (Test-SenzaTest $a) { 'daUnire' } else { 'inDeployTest' }) }
        }
    }
}

# Cio che vale in tutti e tre gli stati di Test: un task aggiunto riporta la card In development, una revisione non piu
# superata la riporta indietro, e con no-test-deploy (messo a card gia in Test) non c'e niente da provare. Restituisce le
# azioni da fare (in Azioni, anche nessuna), o $null se la card puo proseguire con la logica del suo stato.
function Get-AzioniComuniInTest($a) {
    if ($null -eq $a.Ingresso) { return @{ Azioni = @() } }
    if ($a.TaskAperti.Count -gt 0) { return @{ Azioni = @(Get-AzioniTaskAggiunto $a) } }
    # D52: la card di chiusura non ha reviewer, quindi nessuna revisione che possa non essere piu superata
    if (-not (Test-CardChiusura $a) -and -not (Test-RevisioneSuperata $a)) {
        $prima = Get-StatoPrecedente $a
        if (-not $prima) { return @{ Azioni = @() } }
        return @{ Azioni = @(New-Azione 'RiportaIndietro' @{ Stato = $prima; Motivo = 'La revisione non e superata' }) }
    }
    if (Test-SenzaTest $a) { return @{ Azioni = @(New-Azione 'SpostaCard' @{ Stato = 'daUnire' }) } }
    $null
}

# I parametri del deploy in Test li sceglie il responsabile (D43): l'ultimo suo commento di deploy, che l'istantanea porta in
# Deploy.Scelta. Si verificano di nuovo sull'elenco dei parametri deploy* dello YAML della pipeline sul ramo della card
# (Deploy.Ammessi, valido solo con Deploy.AmmessiLetti: un elenco letto puo essere vuoto). Senza scelta, con un nome che lo
# YAML non ha piu o con l'elenco che non si e potuto leggere (Deploy.ErroreAmmessi) niente deploy: un'attesa, che passa prima
# dal responsabile (D42). Elenco non letto e senza errore (nessun ramo): decide l'azione, che senza ramo si ferma.
# Restituisce Parametri e Spenti (i deploy* dell'elenco non scelti, che la run mette a false), oppure Attesa.
function Get-SceltaDeployValida($a) {
    $parametri = @(@(Get-Campo $a.Deploy 'Scelta') | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object { [string]$_ })
    if ($parametri.Count -eq 0) { return @{ Attesa = (New-Attesa 'manca la scelta del deploy in Test del responsabile' 'deploy') } }
    $errore = "$(Get-Campo $a.Deploy 'ErroreAmmessi')"
    if ($errore) {
        return @{ Attesa = (New-Attesa "non riesco a leggere i parametri del deploy in Test: $errore" 'deploy' -Tipo 'parametriDeployIlleggibili') }
    }
    $spenti = @()
    if (Get-Campo $a.Deploy 'AmmessiLetti') {
        # Get-Campo srotolerebbe un elenco vuoto in null: qui l'elenco letto resta un elenco, anche vuoto
        $ammessi = @(@(Get-Campo $a.Deploy 'Ammessi') | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $ignoti = @($parametri | Where-Object { $_ -cnotin $ammessi })
        if ($ignoti.Count -gt 0) {
            return @{ Attesa = (New-Attesa "parametro di deploy sconosciuto: $($ignoti -join ', ')" 'deploy' -Tipo 'parametroDeploySconosciuto') }
        }
        $spenti = @($ammessi | Where-Object { $_ -cnotin $parametri })
    }
    @{ Parametri = $parametri; Spenti = $spenti; Attesa = $null }
}

# Deploying to test: si accoda il deploy e se ne aspetta l'esito; riuscito, la card va dalla persona (human-test) o dal
# collaudatore.
function Get-AzioniInDeployTest($a) {
    $comuni = Get-AzioniComuniInTest $a
    if ($comuni) { return $comuni.Azioni }
    if (-not (Test-RunValido $a)) {
        $blocco = Get-BloccoLimiteTest $a $null
        if ($blocco) {
            # la card di chiusura non e passata da In review: aspetta in Ready to develop
            $motivo = if ($blocco.Tipo -eq 'limiteAmbienti') { 'Gli ambienti di collaudo sono tutti occupati' } else { 'Un altra card dello stesso componente e gia in test' }
            return New-Azione 'RiportaIndietro' @{ Stato = $(if (Test-CardChiusura $a) { 'pronto' } else { 'inRevisione' }); Motivo = $motivo }
        }
        # D59: l'ambiente Docker della card al posto del deploy: nessun parametro da scegliere. Chiusura: l'ambiente si crea dal worktree
        # della card di chiusura, aggiornato al ramo della funzionalita (come per il collaudatore).
        if (Test-AmbienteCollaudo $a.Voce) { return New-Azione 'CreaAmbienteCollaudo' @{ Rev = $a.RevIngresso; Chiusura = [bool](Test-CardChiusura $a) } }
        $scelta = Get-SceltaDeployValida $a
        if ($scelta.Attesa) { return $scelta.Attesa }
        # Rev: la revisione d'ingresso in Deploying to test, che il giro salva come runDopoRev (vale per Test-RunValido)
        return New-Azione 'AccodaDeployTest' @{ Rev = $a.RevIngresso; Parametri = $scelta.Parametri; Spenti = $scelta.Spenti }
    }
    if ($null -eq $a.Run -or (Get-Campo $a.Run 'Stato') -ne 'completed') { return }
    if ((Get-Campo $a.Run 'Esito') -ne 'succeeded') {
        # D52: la card di chiusura con la build o i test falliti non e un deploy da rilanciare: il responsabile scrive la correzione (una
        # volta per build), poi attesa con il suo motivo
        if (Test-CardChiusura $a) {
            $blocco = Get-BloccoCiChiusura $a
            if ($blocco) { return Get-AzioneBloccoChiusura $a $blocco }
        }
        if (Test-AmbienteCollaudo $a.Voce) {
            return New-Attesa "ambiente di collaudo non creato, log: $(Get-Campo $a.Run 'Log'): sistemata la causa, togli il tag e l ambiente si ricrea" 'deploy' -Tipo 'deployFallito'
        }
        $url = Get-Campo $a.Run 'Url'
        $run = if ($url) { "[run $(Get-Campo $a.SC 'runId')]($url)" } else { "run $(Get-Campo $a.SC 'runId')" }
        return New-Attesa "deploy in Test fallito ($run): sistemata la causa, togli il tag e il deploy si rilancia" 'deploy' -Tipo 'deployFallito'
    }
    # la prova di una persona solo se la card la chiede (tag human-test); la card di chiusura passa sempre dal collaudo automatico
    $stato = if ((Test-ProvaUmana $a) -and -not (Test-CardChiusura $a)) { 'inProvaUmana' } else { 'inCollaudo' }
    New-Azione 'SpostaCard' @{ Stato = $stato }
}

# Human test: all'ingresso l'avviso al richiedente (una volta per ingresso); un commento di una persona va a responsabile.
function Get-AzioniInProvaUmana($a) {
    $comuni = Get-AzioniComuniInTest $a
    if ($comuni) { return $comuni.Azioni }
    if (@($a.Commenti | Where-Object { Test-CommentoDiPersona $_ }).Count -gt 0) { return New-Lancia 'responsabile' 'verificaInTest' }
    $gesto = $script:GestiAttesi['inProvaUmana']
    $chiave = "$($gesto.Tipo)@$($a.RevIngresso)"
    if (@(Get-Campo $a.SC 'avvisi') -contains $chiave) { return }
    New-Avviso $a $gesto
}

# Automated test: prova il collaudatore. Un commento di una persona non ancora letto conta piu dell'esito del collaudo: prima
# lo legge responsabile (una sessione alla volta: se il collaudatore lavora, Get-Decisione non decide niente finche non ha
# finito). Il commento resta non letto fino al lancio di responsabile, perche lo smistatore lo segna letto solo a sessione lanciata.
function Get-AzioniInCollaudo($a) {
    $comuni = Get-AzioniComuniInTest $a
    if ($comuni) { return $comuni.Azioni }
    if (@($a.Commenti | Where-Object { Test-CommentoDiPersona $_ }).Count -gt 0) { return New-Lancia 'responsabile' 'commentoInCollaudo' }
    Get-AzioniCollaudo $a
}

# In Automated test prova un modello, il collaudatore (spec, sezione 20). Lo smistatore sposta la card in base al suo
# esito: superata -> Ready to merge; respinta -> il resoconto a responsabile, che crea i task e riporta la card In
# development; bloccato -> on-hold. Al piu giriCollaudo collaudi respinti di fila.
function Get-AzioniCollaudo($a) {
    # Il collaudo che vale e quello partito dopo l'ultimo ingresso In Automated test: uno di prima riguarda un altro deploy.
    $collaudo = $a.UltimaPerRuolo['collaudatore']
    $dal = if ($a.Ingresso) { ConvertTo-DataUtc (Get-Campo $a.Ingresso 'Quando') } else { $null }
    $quando = ConvertTo-DataUtc $(if (Get-Campo $collaudo 'inizio') { Get-Campo $collaudo 'inizio' } else { Get-Campo $collaudo 'fine' })
    $valido = (Test-Finita $collaudo) -and ($null -eq $dal -or ($null -ne $quando -and $quando -ge $dal))

    # responsabile ha gia letto un collaudo respinto (doveva riportare la card In development con i task): non si rifa il
    # collaudo sullo stesso deploy.
    if ($a.UltimoRuolo -eq 'responsabile' -and (Test-Finita $a.Ultima) -and (Get-Campo $a.Ultima 'motivo') -eq 'collaudoRespinto') {
        return New-Attesa 'responsabile ha letto il collaudo respinto ma la card e rimasta In Automated test' 'sessione'
    }
    # L'esito vale anche se dopo il collaudo e passato responsabile a leggere un commento di una persona senza trovare niente
    # da fare (se avesse trovato un difetto la card sarebbe tornata in sviluppo e questo collaudo non varrebbe piu).
    if ($valido -and $a.UltimoRuolo -in 'collaudatore', 'responsabile') {
        $esito = Get-Campo $collaudo 'esito'
        switch ($esito) {
            # la card di chiusura con human-test, dopo il collaudo automatico, passa alla prova di una persona
            'superata' { return New-Azione 'SpostaCard' @{ Stato = $(if ((Test-CardChiusura $a) -and (Test-ProvaUmana $a)) { 'inProvaUmana' } else { 'daUnire' }) } }
            'respinta' {
                if ([int](Get-Campo $a.SC 'giriCollaudo') -ge [int](Get-Campo $a.Limiti 'giriCollaudo')) {
                    return New-Attesa 'troppi collaudi respinti di fila' 'limite'
                }
                return New-Lancia 'responsabile' 'collaudoRespinto' (Get-Campo $collaudo 'testo')
            }
            # il testo del modello (corpi di risposta, dati) non va nel commento di on-hold ne su Telegram
            'bloccato' { return New-Attesa 'il collaudatore non riesce a provare: il suo resoconto e nel commento sulla card' 'sessione' }
            default { return New-Attesa "il collaudatore ha chiuso con un esito che non conosco ('$esito')" 'sessione' -Tipo 'esitoCollaudoSconosciuto' }
        }
    }
    if (Test-AmbienteCollaudo $a.Voce) {
        # D59: l'ambiente e quello della card, creato in Deploying to test: gli URL stanno nello stato
        $elenco = ConvertTo-ElencoUrlCollaudo (Get-Campo $a.SC 'collaudoUrl')
        $allegato = if ($elenco) { "Ambiente di collaudo della card:`n$elenco" } else {
            "Nello stato della card non ci sono gli indirizzi dell'ambiente di collaudo. Non provare a ricavarli: chiudi con ESITO=bloccato e scrivi che mancano gli indirizzi dell'ambiente di collaudo della card." }
        $lancio = New-Lancia 'collaudatore' 'collaudo' $allegato
        if (Test-CardChiusura $a) { $lancio['WorktreeChiusura'] = $true }
        return $lancio
    }
    $url = Get-Campo $a.Voce 'urlTest'
    # senza indirizzo il collaudatore si ferma: cercarlo nei file di configurazione del repo vuol dire leggere file che in
    # qualche repo hanno password
    $allegato = if ($url) { "Ambiente di Test: $url" } else {
        "Nella mappa non c'e l'indirizzo dell'ambiente di Test (urlTest) per questo repo. Non provare a ricavarlo: chiudi con ESITO=bloccato e scrivi che manca urlTest nella mappa." }
    $lancio = New-Lancia 'collaudatore' 'collaudo' $allegato
    # D52: il collaudatore della card di chiusura legge il codice del ramo della funzionalita in un worktree in sola lettura (detached): chi
    # esegue lo crea, o lo riporta a origin/<ramo> aggiornato, a ogni lancio (Update-WorktreeChiusura)
    if (Test-CardChiusura $a) { $lancio['WorktreeChiusura'] = $true }
    $lancio
}

# D52: la Feature passa Resolved quando la card di chiusura e unita in develop; DaChiudere dice a chi esegue di ricordarla nello stato
# della card (featureDaChiudere): quando la card sara Closed, la Feature si chiude anche lei. Idempotente: si riprova finche non e Resolved
# e ricordata (un errore di AggiornaFeature va solo nel log).
function Get-AzioneFeatureRisolta($a) {
    $f = Get-Campo $a.Funzionalita 'Feature'
    $stato = Get-Campo $f 'Stato'
    # la Feature e gia Closed, o e Resolved e la card se la ricorda gia: niente. Resolved senza memoria (stato locale perso) si riscrive, e la ricorda.
    if ($stato -ieq (Get-Campo $a.Stati 'featureChiusa')) { return }
    if ($stato -ieq (Get-Campo $a.Stati 'featureRisolta') -and $null -ne (Get-Campo $a.SC 'featureDaChiudere')) { return }
    New-Azione 'AggiornaFeature' @{ FeatureId = [int]$f.Id; Stato = 'featureRisolta'; DaChiudere = $true }
}

# Ready to release: la PR e unita in develop e la card aspetta il rilascio in produzione, che resta a mano. Qui si toglie
# solo il worktree, a PR completata.
function Get-AzioniDaRilasciare($a) {
    # D52: la card di chiusura non ha worktree da togliere. Se la Feature non e passata Resolved (AggiornaFeature e un di piu, un errore va
    # solo nel log) si riprova, ma solo a PR completata: una card spostata a mano qui senza il merge non risolve niente.
    if (Test-CardChiusura $a) {
        if ($null -ne $a.Pr -and (Get-Campo $a.Pr 'Stato') -eq 'completed') {
            # il worktree in sola lettura del collaudo si toglie qui; il ramo salvato resta, serve a leggere la PR
            if ($null -ne (Get-Campo $a.SC 'cartella')) { New-Azione 'RimuoviWorktree' @{ Chiusura = $true } }
            Get-AzioneFeatureRisolta $a
        }
        return
    }
    if ($null -ne $a.Pr -and (Get-Campo $a.Pr 'Stato') -eq 'completed') {
        if ($null -ne (Get-Campo $a.SC 'cartella')) { return New-Azione 'RimuoviWorktree' }
        return
    }
    # RimuoviWorktree ha gia fatto il suo lavoro (ramo e cartella azzerati dopo la PR completata): la card e rilasciata,
    # non c'e piu una PR da cercare e niente da fare
    if ($null -eq $a.Pr -and $null -ne (Get-Campo $a.SC 'prId') -and -not (Get-Campo $a.SC 'ramo') -and -not (Get-Campo $a.SC 'cartella')) { return }
    if ($null -eq $a.Ingresso) { return }
    # PR non ancora completata (il completamento e in corso) e un task aggiunto nel frattempo: il ramo e ancora aperto
    if ($a.TaskAperti.Count -gt 0) { return Get-AzioniTaskAggiunto $a }
}

# In feature branch (D52): la card della funzionalita ha la PR unita nel ramo della funzionalita e aspetta la card di chiusura. Si
# toglie il worktree; quando la card di chiusura e in Ready to release o oltre (il ramo e in develop) la card la segue. Un task
# aperto qui non riporta indietro la card, come fa Get-AzioniTaskAggiunto: il lavoro e gia nel ramo, e il lavoro nuovo va in una
# card nuova. Se ne avvisa una volta per ingresso nello stato.
function Get-AzioniInFeature($a) {
    # la card e della funzionalita (altrimenti Get-AzioniDelloStato e fermo prima); col worktree si toglie solo a PR completata
    if (Get-BloccoPartenza $a) { return }
    if ($null -ne (Get-Campo $a.SC 'cartella')) { New-Azione 'RimuoviWorktree' }
    if ((Get-ChiaveStato $a.Stati (Get-Campo $a.Funzionalita 'StatoChiusura')) -in 'daRilasciare', 'inRilascio', 'chiusa') {
        New-Azione 'SpostaCard' @{ Stato = 'daRilasciare' }
    }
    # i task si leggono solo finche c'e il worktree: l'avviso vale solo in quel tratto
    if ($a.TaskAperti.Count -gt 0 -and $null -ne (Get-Campo $a.SC 'cartella')) {
        $chiave = "taskInFeature@$($a.RevIngresso)"
        if (@(Get-Campo $a.SC 'avvisi') -notcontains $chiave) {
            New-Azione 'Avvisa' @{ Chi = 'titolare'; Chiave = $chiave
                Testo = "C'e un task aperto su una card In feature branch: il suo lavoro e gia nel ramo della funzionalita, il lavoro nuovo va in una card nuova della funzionalita." }
        }
    }
}

# Ready to merge: il lavoro e rivisto e provato in Test (o la prova e stata saltata a mano). Si chiede il completamento della
# PR attiva sul ramo della card; la card passa in Ready to release solo quando la PR risulta completata (card 23: la PR in
# conflitto restava aperta e la card era gia in Ready to release, ferma in silenzio). Una PR in conflitto con develop torna
# a dev, che allinea il ramo: il merge cambia il codice, che rifa revisione e Test. Un completamento chiesto in questo
# ingresso nello stato che non e riuscito ferma la card con il motivo. Senza PR da completare non resta ferma in silenzio.
function Get-AzioniDaUnire($a) {
    if ($null -eq $a.Ingresso) { return }
    # un task aggiunto prima del merge riporta la card In development: il lavoro nuovo non e rivisto ne provato
    if ($a.TaskAperti.Count -gt 0) { return Get-AzioniTaskAggiunto $a }
    $statoPr = if ($null -ne $a.Pr) { Get-Campo $a.Pr 'Stato' } else { $null }
    $chiusura = Test-CardChiusura $a
    # D52: la PR di una card della funzionalita e unita nel ramo della funzionalita, non in develop: la card aspetta In feature branch.
    # La card di chiusura, a PR completata, va in Ready to release e la Feature passa Resolved.
    if ($statoPr -eq 'completed') {
        if ($chiusura) { New-Azione 'SpostaCard' @{ Stato = 'daRilasciare' }; Get-AzioneFeatureRisolta $a; return }
        return New-Azione 'SpostaCard' @{ Stato = $(if (Test-CardFunzionalita $a) { 'inFeature' } else { 'daRilasciare' }) }
    }
    if ($statoPr -eq 'active') {
        # D52: la card di chiusura non torna a dev (non ha worktree ne sviluppo): i conflitti con develop li risolve la Bug sorella
        # allinea-develop (creata da Get-AzioneBloccoChiusura, una volta), e una validazione rossa con errori di codice e la correzione del
        # responsabile: poi la card aspetta con il motivo, senza chiedere un completamento che non puo riuscire
        if ($chiusura) {
            $blocco = Get-BloccoCiChiusura $a
            if ($blocco -and $blocco.Tipo -in 'conflittiFunzionalita', 'ciRossaFunzionalita') { return Get-AzioneBloccoChiusura $a $blocco }
        }
        if ((Get-Campo $a.Pr 'Validazione') -eq 'conflitti') {
            New-Azione 'RiportaIndietro' @{ Stato = 'inSviluppo'; Motivo = "La PR e in conflitto con $(Get-DestinazioneCard $a.SC): la card torna In development e dev allinea il ramo" }
            return New-Lancia 'dev' 'conflitti'
        }
        # D47: le validazioni scadute si rilanciano qui, al merge, e non prima (in collaudo develop cambia ancora e
        # scadrebbero di nuovo). Si completa solo a validazione chiusa: con una in corso o scaduta ADO rifiuta il merge.
        switch (Get-Campo $a.Pr 'Validazione') {
            'scaduta' { return New-Azione 'RilanciaScadute' }
            'inCorso' { return }
        }
        # D52: con il ramo della funzionalita in prova la PR non si completa (il motivo lo da Get-BloccoPartenza)
        if (Get-BloccoPartenza $a) { return }
        # D52: la card di chiusura unisce in develop solo cio che ha provato: il commit di testa della PR deve essere quello su cui e girato il
        # deploy. Diverso (una sorella e entrata dopo, o qualcuno ha spinto sul ramo): si rifa il giro dal deploy. Senza deploy (senza test) non
        # c'e un commit da confrontare.
        if ($chiusura -and -not (Test-SenzaTest $a)) {
            $provato = Get-Campo $a.Run 'SourceVersion'
            $testa = Get-Campo $a.Pr 'UltimoCommit'
            if ([string]::IsNullOrWhiteSpace("$provato") -or [string]::IsNullOrWhiteSpace("$testa") -or $provato -ne $testa) {
                # un solo ritorno per ogni testa della PR: se e gia tornata per questa e il commit provato non coincide ancora, rifare il giro
                # non serve (il deploy parte da un'altra testa, o la PR e ferma): decide una persona
                if ("$testa" -and (Get-Campo $a.SC 'ritornoCommit') -eq "$testa") {
                    return New-Attesa "la card e gia tornata in Ready to develop per la testa $testa della PR e il commit del deploy ($provato) non coincide ancora: guarda il ramo della funzionalita e il run del deploy" 'limite'
                }
                return New-Azione 'RiportaIndietro' @{ Commit = $testa; Stato = 'pronto'; Motivo = 'Il ramo della funzionalita e cambiato dopo il deploy in Test (il commit della PR non e quello provato): la card torna in Ready to develop e si rifa il deploy' }
            }
        }
        $id = Get-Campo $a.Pr 'Id'
        if ($null -ne $id -and (Get-Campo $a.SC 'completaPr') -eq "$id@$($a.RevIngresso)") {
            return New-Attesa "il completamento della PR $id e stato chiesto ma la PR e ancora aperta (validazione: $(Get-Campo $a.Pr 'Validazione'))" 'limite' -Tipo 'prNonCompletata'
        }
        # il commit verificato (la testa della PR letta in questo giro): Azure DevOps rifiuta il completamento se nel frattempo e cambiata
        return New-Azione 'CompletaPr' @{ Rev = $a.RevIngresso; Commit = (Get-Campo $a.Pr 'UltimoCommit') }
    }
    New-Attesa 'nessuna PR da completare sul ramo della card' 'limite'
}

# ---- il mentore (D46) -------------------------------------------------------------------------------------------

# Quando un superiore corregge un ruolo, il mentore ne ricava una lezione. Qui si decide solo se lanciarlo e con quali dati;
# il lancio e di Smistatore.ps1. Una correzione lancia il mentore una volta sola: StatoCard.mentoriFatti tiene le chiavi
# gia usate, e ogni chiave porta l'id che identifica la correzione (una sessione, un commento, una PR).
function New-LancioMentore([string[]]$Ruoli, [string]$Correttore, [string]$Innesco, $Testo, [string]$Chiave) {
    New-Azione 'LanciaMentore' @{ Ruoli = @($Ruoli); Correttore = $Correttore; Innesco = $Innesco; Testo = $Testo; Chiave = $Chiave }
}

function Format-CommentiPersona($Commenti) {
    $righe = @(@($Commenti) | ForEach-Object { $autore = Get-Campo $_ 'Autore'; "$(if ($autore) { "${autore}: " })$(Get-Campo $_ 'Testo')" })
    $righe -join "`n`n"
}

# Gli stati in cui un commento di persona e un intervento sul lavoro degli agenti: li gli agenti portano la card. Fuori:
# nuova e daChiarire (la persona risponde a domande di prodotto), inProvaUmana (lo copre l'innesco provaUmana), da
# daRilasciare in poi (nessun agente lavora piu la card). E il solo posto dove l'elenco e scritto.
$script:StatiCorrezioneDaCommento = 'pronto', 'inSviluppo', 'inRevisione', 'inDeployTest', 'inCollaudo', 'daUnire'

# Il commento di persona che fa partire il mentore: la chiave e la stessa sia che la correzione l'abbia portata un on-hold
# tolto sia che l'abbia portata il commento da solo. Cosi l'on-hold tolto al giro N e il commento ancora non letto al
# giro N+1 hanno la stessa chiave e il mentore parte una volta.
function Get-ChiaveCommentoPersona($Persona) {
    $ultimo = ($Persona | ForEach-Object { [int](Get-Campo $_ 'Id') } | Measure-Object -Maximum).Maximum
    "commento@$ultimo"
}

# I commenti del giro di prova fallito: di persona, scritti dopo l'ultima entrata in Human test, letti o no (il lancio del
# responsabile li ha gia consumati), piu l'ultimo commento del responsabile. Senza l'entrata nella storia non si sa da
# dove iniziare: tutti i commenti di persona.
function Get-TestoProvaUmana($a) {
    $prova = Get-Campo $a.Stati 'inProvaUmana'
    $entrata = @($a.Storia | Where-Object { (Get-Campo $_ 'A') -ieq $prova -and [int](Get-Campo $_ 'Rev') -lt $a.RevIngresso }) | Select-Object -Last 1
    $dal = if ($entrata) { ConvertTo-DataUtc (Get-Campo $entrata 'Quando') } else { $null }
    $persona = @($a.CommentiTutti | Where-Object {
        if (-not (Test-CommentoDiPersona $_)) { return $false }
        $quando = ConvertTo-DataUtc (Get-Campo $_ 'Quando')
        $null -eq $dal -or $null -eq $quando -or $quando -ge $dal
    })
    $testo = Format-CommentiPersona $persona
    $resp = Get-UltimoCommentoDiRuolo $a.CommentiTutti 'responsabile'
    if ($resp) { $testo = (@($testo, "Ultimo commento del responsabile:`n$resp") | Where-Object { $_ }) -join "`n`n" }
    $testo
}

# I commenti di persona non letti che contano per il mentore: quelli scritti dopo l'ingresso della card nello stato in cui
# e, come fa Get-TestoProvaUmana con la storia. Un commento non letto scritto prima non e una correzione di questo stato:
# una card presa in carico con ultimoCommento=0 ha tutta la sua storia non letta, e la risposta data in daChiarire resta non
# letta quando la card passa in pronto. Senza ingresso nella storia, o senza data, si tiene il commento.
function Get-CommentiPersonaDelloStato($a) {
    $dal = if ($a.Ingresso) { ConvertTo-DataUtc (Get-Campo $a.Ingresso 'Quando') } else { $null }
    @($a.Commenti | Where-Object {
            if (-not (Test-CommentoDiPersona $_)) { return $false }
            $quando = ConvertTo-DataUtc (Get-Campo $_ 'Quando')
            $null -eq $dal -or $null -eq $quando -or $quando -ge $dal
        })
}

# Le azioni del mentore per questo giro. $Azioni sono quelle gia decise (i lanci correttivi e gli spostamenti), $OnHoldTolto
# vale quando una persona ha tolto l'on-hold in questo giro (non il fatto del responsabile dopo la sua passata).
function Get-AzioniMentore($a, $Azioni, [bool]$OnHoldTolto) {
    $fatti = @(Get-Campo $a.SC 'mentoriFatti')
    $persona = @(Get-CommentiPersonaDelloStato $a)
    $proposte = @()

    $lancio = @($Azioni | Where-Object { $_.Tipo -eq 'LanciaSessione' -and $_.Ruolo -eq 'dev' })
    foreach ($l in $lancio) {
        # Il responsabile corregge dev solo se lo sblocca (D40, D46): bloccato o al bivio. Quando riporta la card da
        # Automated test o Human test non e una correzione di dev da parte sua.
        if ($l.Motivo -eq 'decisione' -and (Get-Campo $a.UltimaPerRuolo['responsabile'] 'motivo') -in 'bloccato', 'bivio') {
            $proposte += New-LancioMentore @('dev') 'responsabile' 'decisione' $l.Allegato "decisione@$(Get-Campo $a.UltimaPerRuolo['responsabile'] 'id')"
        }
        elseif ($l.Motivo -eq 'rilievi') {
            $proposte += New-LancioMentore @('dev') 'reviewer' 'rilievi' $l.Allegato "rilievi@$(Get-Campo $a.UltimaPerRuolo['reviewer'] 'id')"
        }
    }

    # Un innesco solo, guidato dal commento di persona: un on-hold tolto senza commento non insegna niente (deploy
    # sistemato, chiusure D39) e non lancia.
    if ($persona.Count -gt 0 -and $a.Chiave -in $script:StatiCorrezioneDaCommento) {
        $chiave = Get-ChiaveCommentoPersona $persona
        if ($OnHoldTolto) {
            # corregge chi si era fermato; senza una sessione alle spalle e il responsabile
            $ruolo = if ($a.UltimoRuolo) { $a.UltimoRuolo } else { 'responsabile' }
            $proposte += New-LancioMentore @($ruolo) 'persona' 'onHoldTolto' (Format-CommentiPersona $persona) $chiave
        }
        else {
            $proposte += New-LancioMentore @('responsabile') 'persona' 'commento' (Format-CommentiPersona $persona) $chiave
        }
    }

    if ($a.Chiave -eq 'inSviluppo' -and $null -ne $a.Ingresso -and (Get-ChiaveStato $a.Stati (Get-Campo $a.Ingresso 'Da')) -eq 'inProvaUmana') {
        $proposte += New-LancioMentore @('collaudatore', 'reviewer') 'persona' 'provaUmana' (Get-TestoProvaUmana $a) "provaUmana@$($a.RevIngresso)"
    }

    # la PR unita di un Bug: e li che il diff (e il blame) mostrano dove il difetto e passato
    $prId = Get-Campo $a.Pr 'Id'
    if ((Get-Campo $a.Card 'Tipo') -eq 'Bug' -and $null -ne $prId -and @($Azioni | Where-Object { $_.Tipo -eq 'SpostaCard' -and $_.Stato -eq 'daRilasciare' }).Count -gt 0) {
        $testo = "$(Get-Campo $a.Card 'Titolo')`n`n$(Get-Campo $a.Card 'Descrizione')`n`nPR $prId"
        $proposte += New-LancioMentore @('dev', 'collaudatore', 'reviewer') 'bug' 'bug' $testo "bug@$prId"
    }

    @($proposte | Where-Object { $fatti -notcontains $_.Chiave })
}

# ---- il punto d'ingresso -----------------------------------------------------------------------------------------

# Una card oltre Ready to develop senza stato locale (ne ramo, ne cartella, ne PR salvata) e stata presa in carico da
# un altro PC, o non e mai partita da qui: prima si ricrea il worktree dal ramo della card su origin (spec, sezione 19).
# Una card rilasciata ha la PR salvata e non si riprende.
# Vergine vuol dire nessuna traccia locale: ne ramo, ne cartella, ne PR, ne una sessione mai lanciata da qui. Una card
# rilasciata qui (worktree tolto dopo il merge) ha la sua storia di sessioni e non si riprende.
function Test-DaPrendereInCarico($a) {
    $per = Get-Campo $a.SC 'ultimaSessione'
    $sessioni = if ($null -eq $per) { 0 } elseif ($per -is [System.Collections.IDictionary]) { $per.Count } else { @($per.PSObject.Properties).Count }
    # D52: la card di chiusura non ha mai un worktree da ricreare: il suo ramo lo imposta ImpostaRamoChiusura
    -not (Test-CardChiusura $a) -and $a.Chiave -in (Get-StatiConRamo) -and -not (Get-Campo $a.SC 'ramo') -and
        -not (Get-Campo $a.SC 'cartella') -and $null -eq (Get-Campo $a.SC 'prId') -and -not $a.UltimoRuolo -and $sessioni -eq 0
}

# Una sessione avviata sulla card dall'altro smistatore meno di silenzioMinuti fa potrebbe essere ancora viva (il suo PC
# acceso): prendere in carico adesso vorrebbe dire due sessioni sullo stesso ramo. Si aspetta. Il commento d'avvio e
# l'unica traccia che un altro PC lascia sulla card.
function Test-SessioneAltruiRecente($a) {
    $ora = ConvertTo-DataUtc (Get-Campo $a.Contesto 'Adesso')
    $limite = Get-Campo $a.Limiti 'silenzioMinuti'
    if ($null -eq $ora -or $null -eq $limite) { return $false }
    $avvii = @($a.Commenti | Where-Object { "$(Get-Campo $_ 'Testo')" -match "^$script:PrefissoCommento\[smistatore\] Sessione \S+ (avviata|ripresa)" })
    foreach ($c in $avvii) {
        $quando = ConvertTo-DataUtc (Get-Campo $c 'Quando')
        if ($null -ne $quando -and ($ora - $quando).TotalMinutes -lt [double]$limite) { return $true }
    }
    $false
}

function Get-AzioniDelloStato($a) {
    # D52: la funzionalita non c'e piu: nessuna regola sa dove portare la card, e il motivo (Get-BloccoPartenza) lo dice a una persona
    if ((Get-PercorsoCard $a) -eq 'perduta') { return }
    if (Test-DaPrendereInCarico $a) {
        if (Test-SessioneAltruiRecente $a) { return }
        # D52: una card della funzionalita si riprende dal ramo della funzionalita (Base, vuota se su origin non c'e): chi esegue ne salva
        # la destinazione, perche la sua PR non finisca su develop. In feature branch non si ricrea il worktree: AdottaCard salva solo il prId.
        if (Test-CardFunzionalita $a) { return New-Azione 'AdottaCard' @{ Base = (Get-Campo $a.Funzionalita 'Ramo') } }
        return New-Azione 'AdottaCard'
    }
    if (Test-CardChiusura $a) {
        # D52, gruppo 5: la correzione che il responsabile ha scritto diventa una Bug figlia della Feature, da sola in questo giro. Il giro
        # dopo la Bug e una sorella non unita, e la regola qui sotto riporta la card in Ready to develop: la correzione la prende prima
        # di tutto, anche prima dell'attesa che la card avrebbe scritto per il collaudo respinto.
        $correzione = Get-CorrezioneDaFare $a
        if ($correzione) {
            return New-Azione 'CreaCorrezione' @{ Chiave = [string]$correzione.Id; Natura = [string]$correzione.Tipo; Titolo = [string]$correzione.Titolo
                Descrizione = [string]$correzione.Descrizione; FeatureId = [int]$a.Funzionalita.Feature.Id; Chiusura = [int]$a.Id }
        }
        $inTest = $a.Chiave -in (Get-StatiInTest) -or $a.Chiave -eq 'daUnire'
        # D52, il ritorno indietro: una sorella non ancora unita cambierebbe il ramo sotto il collaudo (o dopo, sotto il merge): la card
        # torna in Ready to develop e rifa il giro dal deploy. In on-hold Get-Decisione non arriva qui: ci riesce al primo giro senza.
        if ($inTest) {
            $sorelle = @(Get-SorelleNonUnite $a)
            if ($sorelle.Count -gt 0) {
                return New-Azione 'RiportaIndietro' @{ Stato = 'pronto'; Motivo = "La sorella $((@($sorelle | ForEach-Object { "#$($_.Id)" })) -join ', ') non e ancora unita nel ramo della funzionalita: il ramo cambierebbe sotto il collaudo, la card di chiusura torna in Ready to develop e aspetta" }
            }
        }
        # D52: in Ready to release senza stato locale il ramo della funzionalita non c'e piu (lo cancella il merge): il ramo e la PR si
        # prendono dalla PR collegata alla card, cosi la Feature passa Resolved e nasce featureDaChiudere anche dopo una presa in carico.
        if ($a.Chiave -eq 'daRilasciare' -and -not (Get-Campo $a.SC 'ramo')) { return New-Azione 'ImpostaRamoChiusura' @{ Ramo = $null; DaPrCollegata = $true } }
        # D52: senza ramo salvato (card mai passata da qui, o presa in carico da un altro PC) la chiusura lo prende dalla funzionalita; non ha un
        # worktree da creare. In Ready to develop prima le sorelle: finche aspetta non serve.
        if (($inTest -or $a.Chiave -eq 'pronto') -and -not (Get-Campo $a.SC 'ramo') -and -not ($a.Chiave -eq 'pronto' -and (Get-BloccoPartenza $a))) {
            $ramo = Get-Campo $a.Funzionalita 'Ramo'
            if (-not $ramo) { return New-Attesa 'il ramo della funzionalita non c e su origin: la card di chiusura non sa quale ramo provare' 'limite' }
            return New-Azione 'ImpostaRamoChiusura' @{ Ramo = [string]$ramo }
        }
    }
    switch ($a.Chiave) {
        'nuova' { Get-AzioniNuova $a }
        'daChiarire' { Get-AzioniDaChiarire $a }
        'pronto' { Get-AzioniPronto $a }
        'inSviluppo' { Get-AzioniInSviluppo $a }
        'inRevisione' { Get-AzioniInRevisione $a }
        'inDeployTest' { Get-AzioniInDeployTest $a }
        'inCollaudo' { Get-AzioniInCollaudo $a }
        'inProvaUmana' { Get-AzioniInProvaUmana $a }
        'daUnire' { Get-AzioniDaUnire $a }
        'inFeature' { Get-AzioniInFeature $a }
        'daRilasciare' { Get-AzioniDaRilasciare $a }
        default { }   # bozza, inRilascio, chiusa, rimossa: niente da fare
    }
}

# Vero se la card e entrata nello stato in cui si trova dopo la fine (o l'inizio) dell'ultima sessione: lo stato l'ha
# cambiato qualcun altro mentre la card era ferma.
function Test-StatoCambiatoDopoSessione($Istantanea, $SC) {
    $ruolo = Get-Campo $SC 'ultimoRuolo'
    if (-not $ruolo) { return $false }
    $s = Get-Campo (Get-Campo $SC 'ultimaSessione') $ruolo
    $quando = ConvertTo-DataUtc $(if (Get-Campo $s 'fine') { Get-Campo $s 'fine' } else { Get-Campo $s 'inizio' })
    if ($null -eq $quando) { return $false }
    $stato = Get-Campo (Get-Campo $Istantanea 'Card') 'Stato'
    $storia = @(@(Get-Campo $Istantanea 'Storia') | Where-Object { $null -ne $_ } | Sort-Object { [int](Get-Campo $_ 'Rev') })
    $ingresso = @($storia | Where-Object { (Get-Campo $_ 'A') -ieq $stato }) | Select-Object -Last 1
    if ($null -eq $ingresso) { return $false }
    $entrata = ConvertTo-DataUtc (Get-Campo $ingresso 'Quando')
    $null -ne $entrata -and $entrata -gt $quando
}

function New-Ambiente($Istantanea, $Contesto, $SC) {
    $card = Get-Campo $Istantanea 'Card'
    $stati = Get-Campo $Contesto 'Stati'
    $storia = @(@(Get-Campo $Istantanea 'Storia') | Where-Object { $null -ne $_ } | Sort-Object { [int](Get-Campo $_ 'Rev') })
    $stato = Get-Campo $card 'Stato'
    $ingresso = @($storia | Where-Object { (Get-Campo $_ 'A') -ieq $stato }) | Select-Object -Last 1
    $per = Get-Campo $SC 'ultimaSessione'
    $perRuolo = @{}
    if ($per) {
        $chiavi = if ($per -is [System.Collections.IDictionary]) { @($per.Keys) } else { @($per.PSObject.Properties.Name) }
        foreach ($k in $chiavi) { $perRuolo[$k] = Get-Campo $per $k }
    }
    $ruolo = Get-Campo $SC 'ultimoRuolo'
    $chiusi = @((Get-Campo $stati 'taskChiuso'), (Get-Campo $stati 'taskRimosso')) | Where-Object { $_ }
    $aperti = @(@(Get-Campo $Istantanea 'Task') | Where-Object { $null -ne $_ -and (Get-Campo $_ 'Stato') -notin $chiusi } | Sort-Object { [int](Get-Campo $_ 'Id') })
    @{
        Contesto = $Contesto; Stati = $stati; Limiti = Get-Campo $Contesto 'Limiti'; Card = $card
        Id = [int](Get-Campo $card 'Id'); Tag = @(Get-Campo $card 'Tag')
        Chiave = Get-ChiaveStato $stati $stato
        Commenti = @(@(Get-Campo $Istantanea 'Commenti') | Where-Object { $null -ne $_ })
        Pr = Get-Campo $Istantanea 'Pr'; Run = Get-Campo $Istantanea 'Run'
        SC = $SC; Voce = Get-Campo $Istantanea 'Voce'
        RevNostre = @(@(Get-Campo $Istantanea 'RevNostre') | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
        Storia = $storia; CommentiTutti = @(@(Get-Campo $Istantanea 'CommentiTutti') | Where-Object { $null -ne $_ })
        Ingresso = $ingresso
        RevIngresso = if ($ingresso) { [int](Get-Campo $ingresso 'Rev') } else { [int](Get-Campo $card 'Rev') }
        UltimoRuolo = $ruolo; UltimaPerRuolo = $perRuolo
        Ultima = if ($ruolo) { $perRuolo[$ruolo] } else { $null }
        TaskAperti = $aperti
        Predecessori = @(@(Get-Campo $Istantanea 'Predecessori') | Where-Object { $null -ne $_ })
        Deploy = Get-Campo $Istantanea 'Deploy'
        Funzionalita = Get-Campo $Istantanea 'Funzionalita'
        ErroriBuild = Get-Campo $Istantanea 'ErroriBuild'
    }
}

# D51: il testo con cui una sessione e finita sul limite di token, come lo scrive claude ("You've hit your 5-hour limit").
# Serve alle card ferme da prima di D51, che non hanno altro segno: errore vero, nessun causaAttesa (Close-Sessione lo scrive
# a ogni on-hold di oggi) e questo testo. Condivisa con Get-IstantaneaCard, che legge il reset dal jsonl solo se vale.
function Test-OnHoldPerLimite($Sc) {
    if ((Get-Campo $Sc 'inAttesaPer') -ne 'sessione' -or (Get-Campo $Sc 'causaAttesa')) { return $false }
    $ruolo = Get-Campo $Sc 'ultimoRuolo'
    if (-not $ruolo) { return $false }
    $u = Get-Campo (Get-Campo $Sc 'ultimaSessione') $ruolo
    $null -ne $u -and (Get-Campo $u 'errore') -eq $true -and "$(Get-Campo $u 'testo')" -match '(?is)hit your.*limit'
}

# D51: un on-hold che lo smistatore toglie da solo. Funzione pura: $null se la card resta in on-hold, altrimenti
# @{ Causa; Per } con il testo per il commento e il nuovo inAttesaPer. Solo due casi (il terzo di D51, silenzio o morta, alla prima volta non ha l'on-hold: lo gestisce Close-Sessione), ognuno con un dato che dice che la
# causa non c'e piu; il deploy, i fermi di D39, le sessioni fallite con un result e ogni altra attesa non si toccano mai.
function Get-AttesaSciolta {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Istantanea, [Parameter(Mandatory)]$Contesto)
    $sc = Get-Campo $Istantanea 'StatoCard'
    $per = Get-Campo $sc 'inAttesaPer'
    $adesso = ConvertTo-DataUtc (Get-Campo $Contesto 'Adesso')
    if ($per -eq 'sessione') {
        # limite di token di prima di D51: il reset si legge dal jsonl (Istantanea.LimiteUltimaSessione)
        if (Test-OnHoldPerLimite $sc) {
            $limite = Get-Campo $Istantanea 'LimiteUltimaSessione'
            $reset = ConvertTo-DataUtc (Get-Campo $limite 'Reset')
            if ($null -eq $reset -or $null -eq $adesso) { return $null }
            $margine = [double](Get-Campo (Get-Campo $Contesto 'Limiti') 'margineQuotaMinuti')
            if ($reset.AddMinutes($margine) -gt $adesso) { return $null }
            return @{ Causa = "il limite di token e passato (reset alle $($reset.ToLocalTime().ToString('HH:mm')))"; Per = 'quota' }
        }
        return $null
    }
    if ($per -eq 'limite') {
        # validazioni rosse (troppe di fila, o il secondo rilancio di D38) e ora la validazione della PR e verde
        # Solo se l'on-hold e nato dalle rosse: i giri di revisione o di collaudo al limite non si sciolgono con la validazione
        # verde. Il secondo rilancio e vero solo se l'ultima sessione di dev ha chiesto il rilancio (D38).
        $limiti = Get-Campo $Contesto 'Limiti'
        $limRosse = Get-Campo $limiti 'rosseDiFila'; $limRev = Get-Campo $limiti 'giriRevisione'; $limColl = Get-Campo $limiti 'giriCollaudo'
        if ($null -eq $limRev -or $null -eq $limColl) { return $null }
        if ([int](Get-Campo $sc 'giriRevisione') -ge [int]$limRev -or [int](Get-Campo $sc 'giriCollaudo') -ge [int]$limColl) { return $null }
        $dev = Get-Campo (Get-Campo $sc 'ultimaSessione') 'dev'
        $perRosse = ($null -ne $limRosse -and [int](Get-Campo $sc 'rosseDiFila') -ge [int]$limRosse) -or
            ([int](Get-Campo $sc 'rilanci') -ge 1 -and (Get-Campo $dev 'esito') -eq 'rilancia')
        if ($perRosse -and (Get-Campo (Get-Campo $Istantanea 'Pr') 'Validazione') -eq 'verde') {
            return @{ Causa = 'la validazione della PR ora e verde'; Per = 'limite' }
        }
    }
    $null
}

# Cosa fare di una card e, se non parte, perche. Azioni sono quelle di Get-Azioni. Motivo e null se la card parte, se la
# sessione e gia in corso o se aspetta soltanto un evento (PR, build, revisione); altrimenti un blocco con Tipo:
#   onHold (InAttesaPer), predecessori (Predecessori), limiteRepo (Repo, Limite, Card),
#   limiteTest (Componente, Limite, Card), limiteAmbienti (Limite, Card: D59), limiteSessioni (Attive, Limite, Card),
#   quota (Fino, Causa 'limite' = pausa dopo il limite di token, 'riserva' = riserva settimanale per Titolare; Uso e la
#   utilization di seven_day letta). La quota e una sola per tutti i ruoli: blocca ogni lancio, su ogni card (D51).
# Tutti, tranne onHold, portano anche Ruolo: il ruolo a cui andra la card quando il blocco cade (null se nessun agente).
# Contesto.ConSessione: gli id delle card che hanno una sessione aperta (SessioniAttive ne e il numero).
# Una card in on-hold esce con il motivo onHold, tranne i tre casi di Get-AttesaSciolta (D51): l'azione e TogliAttesa
# (Causa, Per), senza motivo; al giro dopo il tag non c'e piu e la card riparte dalla strada di sempre.
# D59: l'ambiente Docker di collaudo di una card che non e piu in uno stato di Test (qualunque altro stato, card chiusa o rimossa) si butta,
# prima di tutto il resto e anche se la card e in on-hold, ha una sessione o ha perso il tag: l'ambiente occupa un posto e porte.
function Get-AzioneButtaAmbiente($Istantanea, $Contesto) {
    $sc = Get-Campo $Istantanea 'StatoCard'
    if ($null -eq (Get-Campo $sc 'collaudoProgetto') -and $null -eq (Get-Campo $sc 'collaudoSlot')) { return $null }
    $chiave = Get-ChiaveStato (Get-Campo $Contesto 'Stati') (Get-Campo (Get-Campo $Istantanea 'Card') 'Stato')
    if ($null -eq $chiave -or $chiave -in (Get-StatiInTest)) { return $null }
    New-Azione 'ButtaAmbienteCollaudo'
}

function Get-Decisione {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Istantanea, [Parameter(Mandatory)]$Contesto)
    $d = Get-DecisioneCard -Istantanea $Istantanea -Contesto $Contesto
    $butta = Get-AzioneButtaAmbiente $Istantanea $Contesto
    if ($butta) { $d.Azioni = @($butta) + @($d.Azioni) }
    $d
}

function Get-DecisioneCard {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Istantanea, [Parameter(Mandatory)]$Contesto)

    $card = Get-Campo $Istantanea 'Card'
    $stati = Get-Campo $Contesto 'Stati'
    $sc = Get-Campo $Istantanea 'StatoCard'
    $tag = @(Get-Campo $card 'Tag')
    $niente = @{ Azioni = @(); Motivo = $null }

    if ($tag -notcontains (Get-Campo $stati 'tagAgenti')) { return $niente }
    if ($tag -contains (Get-Campo $stati 'tagAttesa')) {
        # D51: tre on-hold si tolgono da soli, solo se un dato dice che la causa non c'e piu. Senza quel dato resta on-hold.
        $sciolta = Get-AttesaSciolta -Istantanea $Istantanea -Contesto $Contesto
        if ($sciolta) { return @{ Azioni = @(New-Azione 'TogliAttesa' @{ Causa = $sciolta.Causa; Per = $sciolta.Per }); Motivo = $null } }
        return @{ Azioni = @(); Motivo = @{ Tipo = 'onHold'; InAttesaPer = Get-Campo $sc 'inAttesaPer' } }
    }
    if ($null -ne (Get-Campo $sc 'sessione')) { return $niente }
    # D60: una card in pausa (tag sulla card o sulla sua Feature) e una card nuova senza Feature restano ferme. La sessione in corso
    # finisce (la chiude il passo 2 dello smistatore), ma non ne parte un'altra e la card non si sposta.
    $ferma = Get-FermoPriorita $card $Contesto
    if ($ferma) { return @{ Azioni = @(); Motivo = $ferma } }
    # D52: la funzionalita della card non si e letta. Non e una card isolata (partirebbe dal ramo sbagliato): non fa niente finche
    # una lettura non riesce, e il motivo dice perche.
    $erroreFunzionalita = Get-Campo (Get-Campo $Istantanea 'Funzionalita') 'Errore'
    if ($erroreFunzionalita) { return @{ Azioni = @(); Motivo = @{ Tipo = 'funzionalitaIllegibile'; Ruolo = $null; Errore = [string]$erroreFunzionalita } } }

    $a = $null
    $azzera = $false
    $attesa = Get-Campo $sc 'inAttesaPer'
    # la persona che toglie il tag e il solo caso da ricordare qui: sotto $attesa puo diventare quella del responsabile.
    # Non lo e' un on-hold tolto dallo smistatore (D51, attesaToltaDaSmistatore) ne' la ripresa dopo la pausa di quota: non
    # sono una persona, e il mentore (D46) non deve imparare da loro.
    $daSmistatore = [bool](Get-Campo $sc 'attesaToltaDaSmistatore')
    $onHoldTolto = $null -ne $attesa -and $attesa -ne 'quota' -and -not $daSmistatore
    # Una persona ha tolto l'on-hold: il tag non c'e piu e inAttesaPer dice come ripartire. E l'unico punto in cui l'elenco
    # delle passate fatte si svuota (D42): da qui ogni tipo di attesa ha di nuovo la sua passata. Il fatto del responsabile
    # sotto cambia $attesa ma non e una persona.
    # 'quota' non e una persona (D51): la sessione si riprende da sola dopo la pausa e le passate fatte restano.
    # Nemmeno quando l'on-hold lo ha tolto lo smistatore (D51, attesaToltaDaSmistatore): non e stata una persona. Quando e una
    # persona, AzzeraPassateAttesa azzera anche ripreseAutomatiche (il contatore delle riprese automatiche di Close-Sessione),
    # per questo scatta anche con le passate vuote se il contatore e acceso.
    $azzeraPassate = $null -ne $attesa -and $attesa -ne 'quota' -and -not $daSmistatore -and
        (@(@(Get-Campo $sc 'passateFatte') | Where-Object { $null -ne $_ }).Count -gt 0 -or [int](Get-Campo $sc 'ripreseAutomatiche') -gt 0)
    $dopoPassata = $false
    # Il responsabile ha finito la passata prima di un on-hold (D42, motivo 'attesa'): cosa succede dipende dal suo esito.
    # Non se la sua sessione e stata fermata da Close-Sessione (D39, silenzio, errore, comandi negati) e la persona ha tolto
    # il tag: allora, come per ogni inAttesaPer 'sessione', si riprende lui, e la ripresa chiude la passata quando finisce.
    $chiusura = $null
    $esame = Get-Campo $sc 'attesaInEsame'
    if ($null -ne $esame -and $attesa -ne 'sessione' -and (Get-Campo $sc 'ultimoRuolo') -eq 'responsabile') {
        $resp = Get-Campo (Get-Campo $sc 'ultimaSessione') 'responsabile'
        $esitoResp = "$(Get-Campo $resp 'esito')"
        if ((Test-Finita $resp) -and (Get-Campo $resp 'motivo') -eq 'attesa' -and -not [string]::IsNullOrWhiteSpace($esitoResp)) {
            $ruoloPrima = Get-Campo $esame 'ruolo'
            $chiusura = New-Azione 'ChiudiPassataAttesa' @{ Ruolo = $ruoloPrima }
            $motivoPrima = "$(Get-Campo $esame 'motivo')"
            $perPrima = Get-Campo $esame 'per'
            # Le transizioni del responsabile verso daChiarire valgono solo da nuova e inSviluppo (config/ruoli.json): fuori
            # da li le sue domande non spostano la card, e senza on-hold resterebbe ferma in silenzio.
            if ($esitoResp -eq 'domande' -and (Get-ChiaveStato $stati (Get-Campo $card 'Stato')) -ne 'daChiarire') { $esitoResp = 'domandeFuori' }
            switch ($esitoResp) {
                'fatto' {
                    # Si fa come se Titolare avesse tolto l'on-hold con quell'inAttesaPer, con l'ultimo ruolo di prima della passata.
                    $attesa = $perPrima
                    $dopoPassata = $true
                    $copia = [hashtable]::new($sc)
                    $copia['ultimoRuolo'] = $ruoloPrima
                    $sc = $copia
                }
                # le domande le ha scritte lui e la card e in daChiarire: la persona risponde li, nessun on-hold
                'domande' { return @{ Azioni = @($chiusura); Motivo = $null } }
                'domandeFuori' {
                    $fermo = New-Attesa "$motivoPrima (il responsabile ha domande per te: sono nel commento sulla card)" $perPrima
                    return @{ Azioni = @($chiusura, $fermo); Motivo = $null }
                }
                # bloccato (o un esito che non conosco): serve una persona, con il motivo di prima e la diagnosi sulla card
                default {
                    $fermo = New-Attesa "$motivoPrima (il responsabile ha guardato: la sua diagnosi e nel commento sulla card)" $perPrima
                    return @{ Azioni = @($chiusura, $fermo); Motivo = $null }
                }
            }
        }
    }
    # Se mentre era in on-hold qualcuno ha spostato la card in un altro stato, la sessione rimasta a meta non c'entra piu
    # (card 10: portata a mano in Ready to merge, lo smistatore aveva ripreso il collaudatore). Si decide dallo stato
    # nuovo, come dopo un on-hold per limite.
    if ($attesa -in 'sessione', 'quota' -and (Test-StatoCambiatoDopoSessione $Istantanea $sc)) { $attesa = 'limite' }
    if ($attesa -in 'sessione', 'quota') {
        # il tag di attesa e stato tolto: si riprende la sessione che era rimasta a meta
        $ruolo = Get-Campo $sc 'ultimoRuolo'
        if (-not $ruolo) { return $niente }
        # la sessione ripresa resta sul suo task, se ne aveva uno
        $task = Get-Campo (Get-Campo (Get-Campo $sc 'ultimaSessione') $ruolo) 'task'
        $lancio = New-Lancia $ruolo 'ripresa' $null $true $task
        # la ripresa del collaudatore della card di chiusura legge il worktree in sola lettura, riportato al ramo aggiornato come al primo lancio
        if ($ruolo -eq 'collaudatore' -and (Get-Campo (Get-Campo $Istantanea 'Funzionalita') 'EChiusura')) { $lancio['WorktreeChiusura'] = $true }
        # la ripresa segue il fatto del responsabile, non un tag tolto da una persona: il messaggio della sessione lo dice
        if ($dopoPassata) { $lancio['DopoPassata'] = $true }
        # dopo la pausa per il limite di token (D51) non c'e stato un on-hold: il messaggio dice che si era fermata per quello
        if ($attesa -eq 'quota') { $lancio['DopoQuota'] = $true }
        # la sessione l'ha chiusa lo smistatore (silenzio o processo morto, D51) e riprende da sola, senza on-hold
        elseif ($attesa -eq 'sessione' -and $daSmistatore) { $lancio['DopoRipresaAutomatica'] = $true }
        $azioni = @($lancio)
    }
    else {
        $azzeraDeploy = $false
        if ($attesa -in 'limite', 'deploy') {
            # contatori a zero, poi si decide come se non fossero mai stati raggiunti
            $copia = [hashtable]::new($sc)
            $campi = Get-CampiContatori
            foreach ($k in $campi.Keys) { $copia[$k] = $campi[$k] }
            # D52, gruppo 5: la persona ha tolto un on-hold. Per la CI rossa della validazione non si rilancia il responsabile sulla stessa build:
            # si rilancia la validazione (Get-AzioneBloccoChiusura), come per il deploy si rifa il deploy.
            $copia['ciRossaRiprova'] = $true
            # la persona e intervenuta: si decide gia con l'elenco delle passate vuoto
            if ($azzeraPassate) { $copia['passateFatte'] = @() }
            # Dopo un deploy fallito chi toglie il tag ha sistemato la causa: si dimentica il run, cosi si riaccoda il deploy.
            # Conta il run fallito e non solo inAttesaPer: le card messe in on-hold prima di 'deploy' hanno 'limite'.
            $run = Get-Campo $Istantanea 'Run'
            if ((Test-RunSalvato $sc) -and $null -ne $run -and (Get-Campo $run 'Stato') -eq 'completed' -and (Get-Campo $run 'Esito') -ne 'succeeded') {
                $copia['runId'] = $null; $copia['runDopoRev'] = $null
                $azzeraDeploy = $true
            }
            $sc = $copia
            $azzera = $true
        }
        $a = New-Ambiente $Istantanea $Contesto $sc
        if ($null -eq $a.Chiave) { return $niente }
        $azioni = @()
        if ($a.UltimoRuolo -and (Test-Finita $a.Ultima) -and [string]::IsNullOrWhiteSpace("$(Get-Campo $a.Ultima 'esito')")) {
            $azioni = @(New-Attesa "La sessione di $($a.UltimoRuolo) e finita senza riga ESITO" 'sessione' -Tipo 'senzaEsito')
        }
        else {
            $azioni = @(Get-AzioniDelloStato $a)
            if ($azioni.Count -eq 0 -and (Test-ResponsabileSenzaSeguito $a)) {
                $azioni = @(New-Attesa 'il responsabile ha finito ma nessuna regola sa come proseguire: leggi il suo commento' 'sessione')
            }
        }
        $azioni = @(Convert-AttesePerResponsabile $a $azioni)
        if ($azzeraDeploy) { $azioni = @(New-Azione 'AzzeraDeploy') + $azioni }
        # D52, gruppo 5: la CI della card di chiusura e tornata verde: i giri del responsabile per la CI rossa ripartono da zero
        if ($null -ne $a -and (Test-CardChiusura $a) -and [int](Get-Campo $a.SC 'ciRosseDiFila') -gt 0 -and (Test-CiChiusuraVerde $a)) { $azioni = @(New-Azione 'AzzeraCiRosse') + $azioni }
        if ($azzera) { $azioni = @(New-Azione 'AzzeraContatori') + $azioni }
    }

    if ($chiusura) { $azioni = @($chiusura) + $azioni }
    if ($azzeraPassate) { $azioni = @(New-Azione 'AzzeraPassateAttesa') + $azioni }

    # al limite di sessioni attive non parte niente, nemmeno gli spostamenti legati al lancio: al giro dopo si riprova
    $limite = [int](Get-Campo (Get-Campo $Contesto 'Limiti') 'sessioniAttive')
    $attive = [int](Get-Campo $Contesto 'SessioniAttive')
    $lanci = @($azioni | Where-Object { $_.Tipo -eq 'LanciaSessione' })
    if ($lanci.Count -gt 0 -and $attive -ge $limite) {
        # Ruolo: quello del primo lancio fermato, perche le azioni qui si scartano e la vista non lo saprebbe piu
        return @{ Azioni = @(); Motivo = @{ Tipo = 'limiteSessioni'; Ruolo = $lanci[0].Ruolo; Attive = $attive; Limite = $limite; Card = @(@(Get-Campo $Contesto 'ConSessione') | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ }) } }
    }
    # D51: la quota e una sola per tutti i ruoli. In pausa dopo il limite, o oltre la riserva settimanale, non parte
    # nessuna sessione nuova (quelle avviate finiscono); una resetsAt gia passata non blocca.
    if ($lanci.Count -gt 0) {
        $blocco = Get-BloccoQuota $Contesto
        if ($blocco) { $blocco['Ruolo'] = $lanci[0].Ruolo; return @{ Azioni = @(); Motivo = $blocco } }
    }
    # Il mentore parte dopo il limite: se il limite ferma il lancio correttivo, non parte neanche lui, e riparte al giro dopo
    # insieme al lancio. Non fa parte del lavoro della card: non conta nel limite e non cambia il motivo di un blocco.
    $amb = if ($null -ne $a) { $a } else { New-Ambiente $Istantanea $Contesto $sc }
    if ($null -ne $amb.Chiave) { $azioni = @($azioni) + @(Get-AzioniMentore $amb $azioni ($onHoldTolto -and -not $dopoPassata)) }
    # Senza azioni vere (AzzeraContatori da solo non e un lavoro) il blocco di partenza, se c'e, e il motivo.
    $motivo = $null
    if ($null -ne $a -and @($azioni | Where-Object { $_.Tipo -notin 'AzzeraContatori', 'AzzeraCiRosse', 'ChiudiPassataAttesa', 'AzzeraPassateAttesa', 'LanciaMentore' }).Count -eq 0) {
        $motivo = Get-BloccoPartenza $a
        if (-not $motivo) { $motivo = Get-BloccoChiusuraInBozza $a }
    }
    @{ Azioni = $azioni; Motivo = $motivo }
}

# Integrazione di D51 (2026-11-24): la soglia e il bypass che valgono adesso. Un posto solo: lo smistatore, la vista e il supervisore
# passano da qui (Get-BloccoQuota e Get-RiepilogoQuota). $Override e il contenuto di soglia-quota.json (Get-SogliaQuota). Vale solo se
# e leggibile, ha un `fino` nel futuro e una soglia assente (null) o dentro il range; altrimenti si ignora per intero e vale
# limiti.json. `Override` dice perche: nessuno, valido, scaduto, illeggibile, fuoriRange (la vista lo mostra).
# Il range della soglia e questo e basta: la vista lo riceve da Get-RiepilogoQuota (SogliaMin, SogliaMax).
$script:SogliaQuotaMin = 0.05
$script:SogliaQuotaMax = 0.95

function Get-SogliaQuotaEffettiva($Limiti, $Override, $Adesso) {
    $base = Get-Campo $Limiti 'sogliaQuotaSettimanale'
    $r = @{ Soglia = $(if ($null -ne $base) { [double]$base } else { $null }); IgnoraRiserva = $false; DaOverride = $false; Fino = $null; Override = 'nessuno' }
    if ($null -eq $Override -or ($Override -is [System.Collections.IDictionary] -and $Override.Count -eq 0)) { return $r }
    if ($null -ne (Get-Campo $Override 'errore')) { $r.Override = 'illeggibile'; return $r }
    $fino = ConvertTo-DataUtc (Get-Campo $Override 'fino')
    $s = Get-Campo $Override 'soglia'
    $soglia = $null
    if ($null -eq $fino) { $r.Override = 'illeggibile'; return $r }
    if ($null -ne $s) {
        if ($s -isnot [double] -and $s -isnot [int] -and $s -isnot [long] -and $s -isnot [decimal]) { $r.Override = 'illeggibile'; return $r }
        $soglia = [double]$s
        if ([double]::IsNaN($soglia) -or $soglia -lt $script:SogliaQuotaMin -or $soglia -gt $script:SogliaQuotaMax) { $r.Override = 'fuoriRange'; return $r }
    }
    $ign = Get-Campo $Override 'ignoraRiserva'
    if ($null -ne $ign -and $ign -isnot [bool]) { $r.Override = 'illeggibile'; return $r }
    $adesso = ConvertTo-DataUtc $Adesso
    if ($null -eq $adesso -or $adesso -ge $fino) { $r.Override = 'scaduto'; return $r }
    $r.Override = 'valido'; $r.Fino = $fino.ToString('o'); $r.IgnoraRiserva = [bool]$ign
    if ($null -ne $soglia) { $r.Soglia = $soglia; $r.DaOverride = $true }
    $r
}

# D60: la soglia sulla finestra di 5 ore che vale adesso. L'override della vista (soglia5Ore, valido fino a fino5Ore, il reset della
# finestra letto quando e stato impostato) o, se manca, e scaduto o non vale, sogliaQuota5Ore di limiti.json. Lo stesso range della settimanale.
function Get-Soglia5OreEffettiva($Limiti, $Override, $Adesso) {
    $base = Get-Campo $Limiti 'sogliaQuota5Ore'
    $r = @{ Soglia = $(if ($null -ne $base) { [double]$base } else { $null }); DaOverride = $false; Fino = $null }
    if ($null -eq $Override -or $null -ne (Get-Campo $Override 'errore')) { return $r }
    $s = Get-Campo $Override 'soglia5Ore'
    $fino = ConvertTo-DataUtc (Get-Campo $Override 'fino5Ore')
    $adesso = ConvertTo-DataUtc $Adesso
    if ($null -eq $s -or $null -eq $fino -or $null -eq $adesso -or $adesso -ge $fino) { return $r }
    if ($s -isnot [double] -and $s -isnot [int] -and $s -isnot [long] -and $s -isnot [decimal]) { return $r }
    $v = [double]$s
    if ([double]::IsNaN($v) -or $v -lt $script:SogliaQuotaMin -or $v -gt $script:SogliaQuotaMax) { return $r }
    $r.Soglia = $v; $r.DaOverride = $true; $r.Fino = $fino.ToString('o')
    $r
}

# Una soglia scritta dalla vista (stringa, frazione): @{ Valore }, o @{ Errore } se non e un numero dentro il range.
function ConvertFrom-TestoSoglia([string]$Testo) {
    $t = $Testo.Trim()
    $v = 0.0
    if (-not [double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -or [double]::IsNaN($v)) {
        return @{ Errore = "soglia non valida: '$t'" }
    }
    if ($v -lt $script:SogliaQuotaMin -or $v -gt $script:SogliaQuotaMax) {
        return @{ Errore = "la soglia deve stare fra $([math]::Round($script:SogliaQuotaMin * 100))% e $([math]::Round($script:SogliaQuotaMax * 100))%" }
    }
    @{ Valore = $v }
}

# Il comando della vista (POST /soglia): da cosa ha chiesto Titolare e dall'override di adesso, il nuovo override. Funzione pura, niente
# file: chi la chiama legge quota.json e soglia-quota.json e scrive il risultato. $Parametri (stringhe, dalla query): soglia ('' o 'null'
# = nessuna soglia alzata, altrimenti una frazione dentro il range), ignoraRiserva ('1'/'0'/'true'/'false'), ripristina ('1'),
# soglia5Ore (D60: come soglia, per la finestra di 5 ore; vale fino al fiveHour.resetsAt di $Quota, che deve essere nel futuro).
# Un parametro assente lascia com'e quello dell'override ancora valido (stesso `fino`). L'override vale fino al sevenDay.resetsAt di
# $Quota: senza (o gia passato) si rifiuta, perche non si saprebbe quando farlo scadere.
# Ritorna @{ Esito = 'ok'|'errore'; Messaggio; Override } (Override $null con ripristina: il file si cancella).
function Get-OverrideSogliaQuota($Parametri, $Quota, $Corrente, $Adesso) {
    $errore = { param($m) @{ Esito = 'errore'; Messaggio = $m; Override = $null } }
    $p = if ($Parametri -is [System.Collections.IDictionary]) { $Parametri } else { @{} }
    if ("$($p['ripristina'])" -eq '1') { return @{ Esito = 'ok'; Messaggio = 'soglia ripristinata a limiti.json'; Override = $null } }
    if (-not $p.Contains('soglia') -and -not $p.Contains('ignoraRiserva') -and -not $p.Contains('soglia5Ore')) { return (& $errore 'niente da impostare: serve soglia, soglia5Ore o ignoraRiserva') }
    $adesso = ConvertTo-DataUtc $Adesso
    $sette = Get-Campo $Quota 'sevenDay'
    $reset = if ($sette) { ConvertTo-DataUtc (Get-Campo $sette 'resetsAt') } else { $null }
    if ($null -eq $reset -or $null -eq $adesso -or $reset -le $adesso) {
        return (& $errore 'il reset settimanale non e noto (o e gia passato) in quota.json: senza non so fino a quando far valere la soglia, riprova dopo la prossima sessione')
    }
    $fino = ConvertTo-DataUtc (Get-Campo $Corrente 'fino')
    $valido = $null -ne $fino -and $fino -eq $reset
    $soglia = if ($valido) { Get-Campo $Corrente 'soglia' } else { $null }
    $ignora = if ($valido) { [bool](Get-Campo $Corrente 'ignoraRiserva') } else { $false }
    # D60: la soglia delle 5 ore resta finche vale (stesso fino5Ore del reset di adesso), qualunque cosa si cambi della settimanale
    $cinque = Get-Campo $Quota 'fiveHour'
    $reset5 = if ($cinque) { ConvertTo-DataUtc (Get-Campo $cinque 'resetsAt') } else { $null }
    $fino5 = ConvertTo-DataUtc (Get-Campo $Corrente 'fino5Ore')
    $valido5 = $null -ne $fino5 -and $null -ne $reset5 -and $fino5 -eq $reset5 -and $reset5 -gt $adesso
    $soglia5 = if ($valido5) { Get-Campo $Corrente 'soglia5Ore' } else { $null }
    if ($p.Contains('soglia')) {
        $t = "$($p['soglia'])".Trim()
        if ($t -eq '' -or $t -eq 'null') { $soglia = $null }
        else {
            $v = ConvertFrom-TestoSoglia $t
            if ($v.ContainsKey('Errore')) { return (& $errore $v.Errore) }
            $soglia = $v.Valore
        }
    }
    if ($p.Contains('soglia5Ore')) {
        $t = "$($p['soglia5Ore'])".Trim()
        if ($t -eq '' -or $t -eq 'null') { $soglia5 = $null }
        else {
            if ($null -eq $reset5 -or $reset5 -le $adesso) {
                return (& $errore 'il reset della finestra di 5 ore non e noto (o e gia passato) in quota.json: riprova dopo la prossima sessione')
            }
            $v = ConvertFrom-TestoSoglia $t
            if ($v.ContainsKey('Errore')) { return (& $errore $v.Errore) }
            $soglia5 = $v.Valore
        }
    }
    if ($p.Contains('ignoraRiserva')) {
        $t = "$($p['ignoraRiserva'])".Trim().ToLowerInvariant()
        if ($t -in '1', 'true') { $ignora = $true }
        elseif ($t -in '0', 'false') { $ignora = $false }
        else { return (& $errore "ignoraRiserva non valido: '$t'") }
    }
    $override = @{ soglia = $soglia; ignoraRiserva = $ignora; fino = $reset.ToString('o'); impostata = $adesso.ToString('o') }
    if ($null -ne $soglia5) { $override['soglia5Ore'] = $soglia5; $override['fino5Ore'] = $reset5.ToString('o') }
    $messaggio = if ($p.Contains('soglia5Ore') -and -not $p.Contains('soglia') -and -not $p.Contains('ignoraRiserva')) { 'soglia delle 5 ore aggiornata, vale fino al reset della finestra' }
                 else { 'soglia aggiornata, vale fino al reset settimanale' }
    @{ Esito = 'ok'; Messaggio = $messaggio; Override = $override }
}

# La situazione della quota per la vista: uso settimanale, reset, soglia e bypass effettivi, il range della soglia e il blocco
# (Get-BloccoQuota) se c'e. $Contesto e quello di Get-BloccoQuota (Quota, Adesso, Limiti, OverrideQuota).
function Get-RiepilogoQuota($Contesto) {
    $quota = Get-Campo $Contesto 'Quota'
    $sette = Get-Campo $quota 'sevenDay'
    $uso = if ($sette -and $null -ne (Get-Campo $sette 'utilization')) { [double](Get-Campo $sette 'utilization') } else { $null }
    $reset = if ($sette) { ConvertTo-DataUtc (Get-Campo $sette 'resetsAt') } else { $null }
    $adesso = ConvertTo-DataUtc (Get-Campo $Contesto 'Adesso')
    $eff = Get-SogliaQuotaEffettiva (Get-Campo $Contesto 'Limiti') (Get-Campo $Contesto 'OverrideQuota') $adesso
    # D60: la finestra di 5 ore. Un uso letto prima di un reset gia passato non vale piu: la finestra e ripartita da zero.
    $cinque = Get-Campo $quota 'fiveHour'
    $reset5 = if ($cinque) { ConvertTo-DataUtc (Get-Campo $cinque 'resetsAt') } else { $null }
    $uso5 = if ($cinque -and $null -ne (Get-Campo $cinque 'utilization')) { [double](Get-Campo $cinque 'utilization') } else { $null }
    if ($null -ne $uso5 -and $null -ne $reset5 -and $null -ne $adesso -and $reset5 -le $adesso) { $uso5 = 0.0; $reset5 = $null }
    $eff5 = Get-Soglia5OreEffettiva (Get-Campo $Contesto 'Limiti') (Get-Campo $Contesto 'OverrideQuota') $adesso
    @{
        Uso5Ore = $uso5; Soglia5Ore = $eff5.Soglia; DaOverride5Ore = $eff5.DaOverride
        Reset5Ore = $(if ($null -ne $reset5) { $reset5.ToString('o') } else { $null })
        PuoImpostare5Ore = ($null -ne $reset5 -and $null -ne $adesso -and $reset5 -gt $adesso)
        Uso = $uso; Soglia = $eff.Soglia; DaOverride = $eff.DaOverride; IgnoraRiserva = $eff.IgnoraRiserva; Override = $eff.Override
        SogliaMin = $script:SogliaQuotaMin; SogliaMax = $script:SogliaQuotaMax
        Reset = $(if ($null -ne $reset) { $reset.ToString('o') } else { $null })
        # i comandi della vista valgono solo con un reset futuro noto: l'override scade li
        PuoImpostare = ($null -ne $reset -and $null -ne $adesso -and $reset -gt $adesso)
        Blocco = (Get-BloccoQuota $Contesto $eff)
    }
}

# Il cancello della quota (D51): $null se si puo lanciare, altrimenti il motivo (senza Ruolo). $Effettiva e la soglia effettiva gia
# calcolata da chi la sta usando (Get-RiepilogoQuota): se manca si calcola qui.
function Get-BloccoQuota($Contesto, $Effettiva = $null) {
    $quota = Get-Campo $Contesto 'Quota'
    if ($null -eq $quota) { return $null }
    $adesso = ConvertTo-DataUtc (Get-Campo $Contesto 'Adesso')
    if ($null -eq $adesso) { return $null }
    $pausa = ConvertTo-DataUtc (Get-Campo $quota 'pausaFino')
    $sette = Get-Campo $quota 'sevenDay'
    $uso = if ($sette -and $null -ne (Get-Campo $sette 'utilization')) { [double](Get-Campo $sette 'utilization') } else { $null }
    if ($null -ne $pausa -and $pausa -gt $adesso) { return @{ Tipo = 'quota'; Ruolo = $null; Fino = $pausa.ToString('o'); Causa = 'limite'; Uso = $uso } }
    # D60: la finestra di 5 ore oltre la sua soglia ferma i lanci fino al suo reset. Ignorare la riserva settimanale non la salta.
    $cinque = Get-Campo $quota 'fiveHour'
    $uso5 = if ($cinque -and $null -ne (Get-Campo $cinque 'utilization')) { [double](Get-Campo $cinque 'utilization') } else { $null }
    $reset5 = if ($cinque) { ConvertTo-DataUtc (Get-Campo $cinque 'resetsAt') } else { $null }
    $soglia5 = (Get-Soglia5OreEffettiva (Get-Campo $Contesto 'Limiti') (Get-Campo $Contesto 'OverrideQuota') $adesso).Soglia
    if ($null -ne $soglia5 -and $null -ne $uso5 -and $uso5 -ge [double]$soglia5 -and $null -ne $reset5 -and $reset5 -gt $adesso) {
        return @{ Tipo = 'quota'; Ruolo = $null; Fino = $reset5.ToString('o'); Causa = 'cinqueOre'; Uso = $uso5; Soglia = [double]$soglia5 }
    }
    # la soglia e il bypass che valgono adesso (l'override della vista fino al reset, altrimenti limiti.json): il bypass salta solo la riserva, mai la pausa
    $eff = if ($null -ne $Effettiva) { $Effettiva } else { Get-SogliaQuotaEffettiva (Get-Campo $Contesto 'Limiti') (Get-Campo $Contesto 'OverrideQuota') $adesso }
    $soglia = $eff.Soglia
    $reset = if ($sette) { ConvertTo-DataUtc (Get-Campo $sette 'resetsAt') } else { $null }
    if (-not $eff.IgnoraRiserva -and $null -ne $soglia -and $null -ne $uso -and $uso -ge [double]$soglia -and $null -ne $reset -and $reset -gt $adesso) {
        return @{ Tipo = 'quota'; Ruolo = $null; Fino = $reset.ToString('o'); Causa = 'riserva'; Uso = $uso; Soglia = [double]$soglia }
    }
    $null
}

# D60: perche una card resta ferma per la priorita, o $null. 'pausa': il tag di pausa sulla card, o sulla Feature padre ($Contesto.Feature,
# la mappa id -> @{ Rank; Pausa; Titolo } delle Feature aperte, Get-MappaFeature). 'senzaFeature': una card in New senza Feature padre non
# parte: d'ora in poi ogni card sta in una funzionalita. Le card senza Feature gia oltre New finiscono il loro giro.
function Get-FermoPriorita($Card, $Contesto) {
    $stati = Get-Campo $Contesto 'Stati'
    $tagPausa = Get-Campo $stati 'tagPausa'
    if ($tagPausa -and @(Get-Campo $Card 'Tag') -contains $tagPausa) { return @{ Tipo = 'pausa'; Feature = $null; Titolo = $null } }
    $padre = Get-Campo $Card 'PadreId'
    $f = if ($null -ne $padre) { Get-Campo (Get-Campo $Contesto 'Feature') "$padre" } else { $null }
    if ($f -and (Get-Campo $f 'Pausa')) { return @{ Tipo = 'pausa'; Feature = [int]$padre; Titolo = (Get-Campo $f 'Titolo') } }
    # in New serve una Feature aperta: un padre che non lo e (Epic, Feature chiusa o fuori dalle aree della mappa) e come nessun padre
    if ($null -eq $f -and (Get-ChiaveStato $stati (Get-Campo $Card 'Stato')) -eq 'nuova') { return @{ Tipo = 'senzaFeature' } }
    $null
}

# D60: vero se la card e in pausa (sua o della Feature). Una card in pausa non tiene il posto in sviluppo del suo repo.
function Test-CardInPausa($Card, $Contesto) {
    $f = Get-FermoPriorita $Card $Contesto
    $null -ne $f -and $f.Tipo -eq 'pausa'
}

# D60: le Feature aperte come mappa id (stringa) -> @{ Rank; Pausa; Titolo }, per Get-FermoPriorita e Get-OrdineCard.
function Get-MappaFeature($Feature, $Stati) {
    $m = @{}
    $tag = Get-Campo $Stati 'tagPausa'
    foreach ($f in @($Feature | Where-Object { $null -ne $_ })) {
        $m["$($f.Id)"] = @{ Rank = (Get-Campo $f 'Rank'); Pausa = [bool]($tag -and @(Get-Campo $f 'Tag') -contains $tag); Titolo = (Get-Campo $f 'Titolo') }
    }
    $m
}

# D60: le Feature nell'ordine del backlog di Azure DevOps (Stack Rank crescente); quelle mai ordinate vanno in fondo, per id.
function Get-OrdineFeature($Feature) {
    @(@($Feature | Where-Object { $null -ne $_ }) | Sort-Object @{ Expression = { $null -eq (Get-Campo $_ 'Rank') } }, @{ Expression = { [double](Get-Campo $_ 'Rank') } }, @{ Expression = { [int]$_.Id } })
}

# D60: l'ordine in cui lo smistatore guarda le card, che decide chi prende un posto libero (sessioni, repo, Test): prima le card della
# Feature piu in alto, poi quelle delle Feature mai ordinate, poi le card senza Feature; a parita, per id. $Mappa e Get-MappaFeature.
function Get-OrdineCard($Card, $Mappa) {
    $posizione = @{}
    $i = 0
    foreach ($f in (Get-OrdineFeature @(foreach ($k in @($Mappa.Keys)) { [pscustomobject]@{ Id = [int]$k; Rank = $Mappa[$k].Rank } }))) { $posizione["$($f.Id)"] = $i++ }
    @(@($Card | Where-Object { $null -ne $_ }) | Sort-Object @{ Expression = {
            $p = Get-Campo $_ 'PadreId'
            if ($null -ne $p -and $posizione.ContainsKey("$p")) { $posizione["$p"] } else { [int]::MaxValue }
        } }, @{ Expression = { [int]$_.Id } })
}

# D60: lo spostamento di una Feature dalla vista: $Id va subito dopo $Dopo (0 = in cima). Se tutte hanno un rank si scrive solo la Feature
# spostata, a meta fra le due vicine (in cima o in fondo: 1000 oltre la vicina). Se qualcuna non e mai stata ordinata, o fra le vicine non c'e
# spazio, si rinumerano tutte 1000, 2000, ... e si scrivono solo quelle che cambiano. Ritorna @(@{ Id; Rank }). Errore se $Id o $Dopo non sono fra le Feature.
function Get-RankRiordino($Feature, [int]$Id, [int]$Dopo) {
    $ordine = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (Get-OrdineFeature $Feature)) { $ordine.Add($f) }
    $mossa = @($ordine | Where-Object { [int]$_.Id -eq $Id }) | Select-Object -First 1
    if ($null -eq $mossa) { throw "la Feature $Id non e fra quelle aperte" }
    if ($Dopo -eq $Id) { throw 'una Feature non va dopo se stessa' }
    [void]$ordine.Remove($mossa)
    $indice = 0
    if ($Dopo -ne 0) {
        $prima = -1
        for ($j = 0; $j -lt $ordine.Count; $j++) { if ([int]$ordine[$j].Id -eq $Dopo) { $prima = $j } }
        if ($prima -lt 0) { throw "la Feature $Dopo non e fra quelle aperte" }
        $indice = $prima + 1
    }
    $ordine.Insert($indice, $mossa)
    $conRank = @($ordine | Where-Object { $null -ne (Get-Campo $_ 'Rank') }).Count -eq $ordine.Count
    if ($conRank) {
        $rankPrima = if ($indice -gt 0) { [double](Get-Campo $ordine[$indice - 1] 'Rank') } else { $null }
        $rankDopo = if ($indice -lt $ordine.Count - 1) { [double](Get-Campo $ordine[$indice + 1] 'Rank') } else { $null }
        $nuovo = if ($null -eq $rankPrima -and $null -eq $rankDopo) { [double](Get-Campo $mossa 'Rank') }
                 elseif ($null -eq $rankPrima) { $rankDopo - 1000 } elseif ($null -eq $rankDopo) { $rankPrima + 1000 } else { ($rankPrima + $rankDopo) / 2 }
        if (($null -eq $rankPrima -or $nuovo -gt $rankPrima) -and ($null -eq $rankDopo -or $nuovo -lt $rankDopo)) {
            if ([double](Get-Campo $mossa 'Rank') -eq $nuovo) { return @() }
            return @(@{ Id = [int]$mossa.Id; Rank = $nuovo })
        }
    }
    @(for ($j = 0; $j -lt $ordine.Count; $j++) {
        $nuovo = [double](($j + 1) * 1000)
        $vecchio = Get-Campo $ordine[$j] 'Rank'
        if ($null -eq $vecchio -or [double]$vecchio -ne $nuovo) { @{ Id = [int]$ordine[$j].Id; Rank = $nuovo } }
    })
}

function Get-Azioni {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Istantanea, [Parameter(Mandatory)]$Contesto)
    @((Get-Decisione -Istantanea $Istantanea -Contesto $Contesto).Azioni)
}

# La riga che dice perche una card non parte: la stessa per il log dello smistatore e per la vista.
function Format-MotivoCoda($Motivo) {
    switch (Get-Campo $Motivo 'Tipo') {
        'onHold' {
            $per = Get-Campo $Motivo 'InAttesaPer'
            $come = switch ($per) {
                'sessione' { ', togliendo il tag si riprende la sessione' }
                'limite' { ', togliendo il tag i contatori ripartono da zero' }
                'deploy' { ', togliendo il tag si rilancia il deploy in Test' }
                default { '' }
            }
            "in on-hold$come"
        }
        'predecessori' {
            $elenco = (@(Get-Campo $Motivo 'Predecessori') | ForEach-Object { "#$($_.Id) ($($_.Stato))" }) -join ', '
            if (Get-Campo $Motivo 'Sorelle') { "aspetta che le sorelle della funzionalita (e le card precedenti) siano unite nel ramo: $elenco" }
            else { "aspetta le card precedenti non ancora unite: $elenco" }
        }
        'senzaSorelle' {
            "ferma, la funzionalita non ha ancora card sorelle (le altre figlie della Feature #$(Get-Campo $Motivo 'Feature')): la card di chiusura parte quando ce n'e almeno una e sono tutte unite nel ramo"
        }
        'conflittiFunzionalita' {
            "ferma, la PR $(Get-Campo $Motivo 'Ramo') verso $(Get-Campo $Motivo 'Destinazione') ha conflitti: finche non sono risolti la card aspetta"
        }
        'ciRossaFunzionalita' {
            $dove = if ((Get-Campo $Motivo 'Fonte') -eq 'deploy') { 'il deploy in Test ha la build o i test falliti' } else { 'la validazione della PR e rossa' }
            $url = Get-Campo $Motivo 'Url'
            # gli errori su una riga sola e corti: il motivo finisce nel log a ogni giro
            $errori = ([string](Get-Campo $Motivo 'Errori') -replace '\s*\r?\n\s*', ' | ').Trim()
            "ferma, $dove$(if ($url) { " ($url)" }): finche la CI non e verde la card aspetta$(if ($errori) { ". Errori: $(Limit-Riga $errori 400)" })"
        }
        'limiteSessioni' {
            $card = @(Get-Campo $Motivo 'Card')
            $chi = if ($card.Count -gt 0) { ": card $($card -join ', ')" } else { '' }
            "in coda, posto occupato (sessioni attive $(Get-Campo $Motivo 'Attive')/$(Get-Campo $Motivo 'Limite')$chi)"
        }
        'quota' {
            $fino = (ConvertTo-DataUtc (Get-Campo $Motivo 'Fino')).ToLocalTime().ToString('HH:mm')
            if ((Get-Campo $Motivo 'Causa') -eq 'limite') { "in coda, pausa per il limite di token fino alle $fino" }
            elseif ((Get-Campo $Motivo 'Causa') -eq 'cinqueOre') {
                "in coda, soglia delle 5 ore raggiunta: uso $([math]::Round([double](Get-Campo $Motivo 'Uso') * 100))%, soglia $([math]::Round([double](Get-Campo $Motivo 'Soglia') * 100))%, fino alle $fino"
            }
            else {
                $soglia = Get-Campo $Motivo 'Soglia'
                "in coda, riserva settimanale raggiunta: uso $([math]::Round([double](Get-Campo $Motivo 'Uso') * 100))%, soglia $([math]::Round([double]$soglia * 100))%, fino a $fino"
            }
        }
        'limiteTest' {
            $card = @(Get-Campo $Motivo 'Card')
            "in coda, un altra card dello stesso componente e in Test ($(Get-Campo $Motivo 'Componente'), $($card.Count)/$(Get-Campo $Motivo 'Limite'): card $($card -join ', '))"
        }
        'limiteAmbienti' {
            $card = @(Get-Campo $Motivo 'Card')
            "in coda, gli ambienti di collaudo sono tutti occupati ($($card.Count)/$(Get-Campo $Motivo 'Limite'): card $($card -join ', '))"
        }
        'funzionalitaPerduta' {
            "ferma, la card e $(Get-Campo $Motivo 'Stato') con la PR verso $(Get-Campo $Motivo 'Destinazione') ma non risulta piu della funzionalita (Feature rimossa, card di chiusura tolta o senza tag): una persona la rimette nella funzionalita o decide cosa farne"
        }
        'inFeatureSenzaPrUnita' {
            "ferma, il worktree c'e ma la PR verso $(Get-Campo $Motivo 'Destinazione') non risulta completata: il worktree non si toglie finche il lavoro non e unito, una persona guarda la PR"
        }
        'funzionalitaIllegibile' { "ferma, la funzionalita della card non si legge ($(Get-Campo $Motivo 'Errore')): riparte appena si legge" }
        'chiusuraInBozza' {
            "la card di chiusura della funzionalita (#$(Get-Campo $Motivo 'Chiusura')) e in Draft e le sorelle sono tutte unite nel ramo: aspetta una persona che la porti in New"
        }
        'attesaCollaudoFunzionalita' {
            "aspetta il collaudo della funzionalita: la card di chiusura #$(Get-Campo $Motivo 'Chiusura') e in $(Get-Campo $Motivo 'Stato'), la PR non si completa finche il ramo e in prova"
        }
        'pausa' {
            if ($null -ne (Get-Campo $Motivo 'Feature')) { "in pausa con la sua funzionalita (Feature #$(Get-Campo $Motivo 'Feature')): togliendo il tag dalla Feature riparte" }
            else { 'in pausa (tag sulla card): togliendo il tag riparte' }
        }
        'senzaFeature' { 'ferma, non e figlia di una Feature: ogni card nuova sta in una funzionalita, collegala a una Feature dalla board' }
        'limiteRepo' {
            $card = @(Get-Campo $Motivo 'Card')
            "in coda, un altra card e in sviluppo su $(Get-Campo $Motivo 'Repo') ($($card.Count)/$(Get-Campo $Motivo 'Limite'): card $($card -join ', '))"
        }
        default { $null }
    }
}

# Cosa aspetta da una persona una card che nessun agente prendera: sblocca (on-hold), prova (il gesto di GestiAttesi),
# rispondi (da chiarire, nessun commento di persona gia arrivato), rilascia (pronta per la produzione); null altrimenti.
# Se la decisione ha un LanciaSessione o il motivo ha un ruolo la card e di quell'agente e qui non e mai un'attivita
# (per esempio limiteSessioni, o un task aggiunto in Ready to release). Ferma: finche la persona non agisce il flusso della
# card non va avanti. Restituisce Attivita, Ferma e Testo; i nomi mostrati e l'ordine sono della vista.
function Get-AttivitaOperatore {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Istantanea, [Parameter(Mandatory)]$Contesto, [Parameter(Mandatory)]$Decisione)
    $stati = Get-Campo $Contesto 'Stati'
    $card = Get-Campo $Istantanea 'Card'
    if (@(Get-Campo $card 'Tag') -notcontains (Get-Campo $stati 'tagAgenti')) { return $null }
    $azioni = @(Get-Campo $Decisione 'Azioni')
    $motivo = Get-Campo $Decisione 'Motivo'
    if (@($azioni | Where-Object { $_.Tipo -eq 'LanciaSessione' }).Count -gt 0) { return $null }
    if ($motivo -and (Get-Campo $motivo 'Ruolo')) { return $null }
    # un on-hold che lo smistatore sta per togliere (D51) si mostra ancora come on-hold fino al giro
    if (@($azioni | Where-Object { $_.Tipo -eq 'TogliAttesa' }).Count -gt 0) {
        return @{ Attivita = 'sblocca'; Ferma = $true; Testo = (Format-MotivoCoda @{ Tipo = 'onHold'; InAttesaPer = (Get-Campo (Get-Campo $Istantanea 'StatoCard') 'inAttesaPer') }) }
    }
    if ($motivo -and (Get-Campo $motivo 'Tipo') -eq 'onHold') { return @{ Attivita = 'sblocca'; Ferma = $true; Testo = (Format-MotivoCoda $motivo) } }
    $gesto = Get-GestoAtteso -Istantanea $Istantanea -Contesto $Contesto
    if ($gesto -and $gesto.Tipo -eq 'testPronto') { return @{ Attivita = 'prova'; Ferma = $true; Testo = $gesto.Testo } }
    $a = New-Ambiente $Istantanea $Contesto (Get-Campo $Istantanea 'StatoCard')
    if ($a.Chiave -eq 'daChiarire' -and $azioni.Count -eq 0 -and -not $motivo) {
        return @{ Attivita = 'rispondi'; Ferma = $true; Testo = 'responsabile aspetta una tua risposta sulla card' }
    }
    if ($a.Chiave -eq 'daRilasciare') { return @{ Attivita = 'rilascia'; Ferma = $false; Testo = 'unita in develop: aspetta il rilascio in produzione' } }
    $null
}

# L'ultimo commento firmato [ruolo] fra quelli dati, come testo semplice (senza html, menzioni e firma); null se non ce n'e.
# Gli a capo dei blocchi (br, div, p, li...) restano come righe, gli spazi in eccesso e le righe vuote no.
# Serve alla vista per mostrare la domanda che responsabile ha fatto: il formato della firma sta qui, con Test-CommentoDiPersona.
function Get-UltimoCommentoDiRuolo($Commenti, [string]$Ruolo) {
    $ultimo = @(@($Commenti) | Where-Object { $null -ne $_ -and "$(Get-Campo $_ 'Testo')" -match "^$script:PrefissoCommento\[$Ruolo\]" }) | Select-Object -Last 1
    if (-not $ultimo) { return $null }
    $h = "$(Get-Campo $ultimo 'Testo')" -replace '(?i)<br\s*/?>', "`n" -replace '(?i)</(?:div|p|li|ul|ol|h[1-6]|tr|table|blockquote|pre)\s*>', "`n"
    $t = [System.Net.WebUtility]::HtmlDecode(($h -replace '<[^>]*>', ''))
    $t = $t -replace "(?s)^.*?\[$Ruolo\]\s*", ''
    $righe = @($t -split '\r?\n' | ForEach-Object { ($_ -replace '[ \t\u00a0]+', ' ').Trim() } | Where-Object { $_ })
    $righe -join "`n"
}

# Quante righe e quanti caratteri mostra la vista di una domanda di responsabile prima di rimandare alla card.
$script:DomandaMaxRighe = 12
$script:DomandaMaxCaratteri = 1000
# Nella forma compatta: quanto e lungo al piu il titolo di una domanda, e la riga della proposta o di un'opzione.
$script:DomandaMaxTitolo = 90
$script:DomandaMaxOpzione = 110

# Una riga che apre una voce: D1, D2..., un elenco puntato o numerato, un'opzione a) b).
function Test-RigaVoce([string]$Riga) { $Riga -cmatch '^(?:D\d+\b|[-*\u2022\u2013]\s|\d+[.)]\s|[a-zA-Z][.)]\s)' }

# Una riga che chiude la parte di domande e apre un'altra sezione: il registro delle decisioni, o un titolo tutto maiuscolo.
function Test-RigaTitolo([string]$Riga) {
    if (Test-RigaVoce $Riga) { return $false }
    ($Riga -match '^\W*(?:registro|decisioni)\b') -or ($Riga -cmatch '^[^a-z]*[A-Z\u00C0-\u00DD][^a-z]{3,}$')
}

# Le righe della parte di domande di un commento, o null se non si riconosce: quelle dopo un'intestazione "Domande" (corta, da
# sola su una riga) oppure, senza intestazione, dalla prima voce D1, fino al titolo della sezione dopo (registro delle decisioni).
function Get-RigheDomande($Righe) {
    $inizio = -1
    for ($i = 0; $i -lt $Righe.Count; $i++) {
        if ($Righe[$i] -notmatch '^\W*domand[ae]\b') { continue }
        # un'intestazione sola (con al piu un qualificatore o una parentesi) non e una domanda; con del testo sulla stessa riga si parte da li
        $inizio = if ($Righe[$i] -match '^\W*domand[ae](?:\s+[^\s?:.]+){0,3}\W*(?:\(.*\))?\W*$') { $i + 1 } else { $i }
        break
    }
    if ($inizio -lt 0) {
        for ($i = 0; $i -lt $Righe.Count; $i++) { if ($Righe[$i] -cmatch '^\W*D\d+\b') { $inizio = $i; break } }
    }
    if ($inizio -lt 0) { return $null }
    $sel = [System.Collections.Generic.List[string]]::new()
    for ($i = $inizio; $i -lt $Righe.Count; $i++) {
        if ($sel.Count -gt 0 -and (Test-RigaTitolo $Righe[$i])) { break }
        $sel.Add($Righe[$i])
    }
    if ($sel.Count -eq 0) { return $null }
    , $sel.ToArray()
}

# Una riga accorciata a $Max caratteri, tagliata a una parola e chiusa da "...".
function Limit-Riga([string]$Riga, [int]$Max) {
    if ($Riga.Length -le $Max) { return $Riga }
    $pezzo = $Riga.Substring(0, $Max - 1)
    $sp = $pezzo.LastIndexOf(' ')
    if ($sp -gt 0) { $pezzo = $pezzo.Substring(0, $sp) }
    $pezzo.TrimEnd(' ', ',', ';', ':') + [char]0x2026
}

# La forma compatta delle domande D1, D2...: per ognuna il titolo (la prima frase) e, se responsabile ha indicato la sua
# scelta ("<- la mia scelta"), solo quella come "proposta: a) ..."; altrimenti le opzioni, una per riga. Le motivazioni e le
# altre opzioni restano sulla card. Null se le righe non hanno voci D1, D2...
function Format-DomandeCompatte($Righe) {
    $primo = -1
    for ($i = 0; $i -lt $Righe.Count; $i++) { if ($Righe[$i] -cmatch '^\W*D\d+\b') { $primo = $i; break } }
    if ($primo -lt 0) { return $null }
    $fuori = [System.Collections.Generic.List[string]]::new()
    $opzioni = [System.Collections.Generic.List[string]]::new(); $proposta = $null
    $chiudi = {
        if ($proposta) { $fuori.Add((Limit-Riga "proposta: $proposta" $script:DomandaMaxOpzione)) }
        else { foreach ($o in $opzioni) { $fuori.Add((Limit-Riga $o $script:DomandaMaxOpzione)) } }
    }
    for ($i = $primo; $i -lt $Righe.Count; $i++) {
        $r = $Righe[$i]
        if ($r -cmatch '^\W*D\d+\b') {
            . $chiudi
            $opzioni.Clear(); $proposta = $null
            # il titolo e la prima frase: "D2. Chi scrive. La descrizione dice..." -> "D2. Chi scrive."
            $titolo = if ($r -match '^(\W*D\d+\W*.*?[.?!])(?:\s|$)') { $Matches[1] } else { $r }
            $fuori.Add((Limit-Riga $titolo $script:DomandaMaxTitolo))
        }
        elseif ($r -cmatch '^[a-zA-Z][.)]\s') {
            if ($r -match '^(.*?)\s*(?:<-|←)') { if (-not $proposta) { $proposta = $Matches[1] } }
            else { $opzioni.Add($r) }
        }
    }
    . $chiudi
    , $fuori.ToArray()
}

# Il testo di un commento di responsabile come lo mostra la voce "Rispondi": solo la parte di domande (una per riga, le opzioni
# sotto la loro domanda), oppure, se non la si riconosce, l'inizio del commento. Oltre $MaxRighe righe o $MaxCaratteri caratteri
# taglia e aggiunge "... continua sulla card". $Testo e quello di Get-UltimoCommentoDiRuolo; senza testo da null.
function Format-DomandaOperatore([string]$Testo, [int]$MaxRighe = $script:DomandaMaxRighe, [int]$MaxCaratteri = $script:DomandaMaxCaratteri) {
    if ([string]::IsNullOrWhiteSpace($Testo)) { return $null }
    # il Markdown del commento (grassetto) non si mostra e non deve nascondere le voci "**D1.**"
    $righe = @(($Testo -replace '\*\*', '') -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($righe.Count -eq 0) { return $null }
    $sel = Get-RigheDomande $righe
    if ($null -eq $sel) { $sel = $righe }
    $compatte = Format-DomandeCompatte @($sel)
    if ($null -ne $compatte) { $sel = $compatte }
    $fuori = [System.Collections.Generic.List[string]]::new()
    $car = 0; $tagliato = $false
    foreach ($r in @($sel)) {
        if ($fuori.Count -ge $MaxRighe) { $tagliato = $true; break }
        $spazio = $MaxCaratteri - $car - $(if ($fuori.Count -gt 0) { 1 } else { 0 })
        if ($r.Length -gt $spazio) {
            # la riga non ci sta: se e la prima (o resta posto per un pezzo utile) se ne tiene l'inizio, tagliato a una parola
            if ($spazio -ge 40 -or $fuori.Count -eq 0) {
                $pezzo = $r.Substring(0, [math]::Max(0, [math]::Min($spazio, $r.Length)))
                $sp = $pezzo.LastIndexOf(' ')
                if ($sp -gt 0) { $pezzo = $pezzo.Substring(0, $sp) }
                if ($pezzo) { $fuori.Add($pezzo) }
            }
            $tagliato = $true; break
        }
        $fuori.Add($r); $car += $r.Length + $(if ($fuori.Count -gt 1) { 1 } else { 0 })
    }
    if ($tagliato) { $fuori.Add([string][char]0x2026 + ' continua sulla card') }
    $fuori -join "`n"
}
# Il gesto che aspetta da una persona la card in esame, riconosciuto dall'avviso gia registrato nello stato per
# l'ingresso corrente nello stato; null se non c'e. Restituisce Tipo e Testo dell'avviso (vedi GestiAttesi).
function Get-GestoAtteso {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Istantanea, [Parameter(Mandatory)]$Contesto)
    $sc = Get-Campo $Istantanea 'StatoCard'
    $a = New-Ambiente $Istantanea $Contesto $sc
    if ($null -eq $a.Chiave -or -not $script:GestiAttesi.ContainsKey($a.Chiave)) { return $null }
    $g = $script:GestiAttesi[$a.Chiave]
    if (@(Get-Campo $sc 'avvisi') -notcontains "$($g.Tipo)@$($a.RevIngresso)") { return $null }
    @{ Tipo = $g.Tipo; Testo = $g.Testo }
}

Export-ModuleMember -Function Get-FermoPriorita, Test-CardInPausa, Get-MappaFeature, Get-OrdineFeature, Get-OrdineCard, Get-RankRiordino, Get-Soglia5OreEffettiva, Get-SlotCollaudoLibero, Get-CampiContatori, Test-OnHoldPerLimite, Get-AttesaSciolta, Test-DeployDaLeggere, Get-TitoloPr, Format-DomandaOperatore, Get-AttivitaOperatore, Get-Azioni, Get-Decisione, Get-BloccoQuota, Get-SogliaQuotaEffettiva, Get-OverrideSogliaQuota, Get-RiepilogoQuota, Format-MotivoCoda, Get-GestoAtteso, Get-UltimoCommentoDiRuolo, Test-CommentoDiPersona, Get-PredecessoriInAttesa, Test-PredecessoreUnito
