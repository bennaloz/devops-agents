# Registro delle decisioni

Le regole con cui funziona il sistema di agenti, chi le ha decise e perché. Il disegno completo sta nella spec
(`docs/superpowers/specs/2026-11-16-ecosistema-agenti-design.md`); qui c'è solo ciò che si è scelto, in una forma che
si rilegge in pochi minuti. Chi prende una decisione nuova, o ne cambia una, aggiunge o corregge la voce qui nella
stessa PR in cui la applica.

Ogni voce dice cosa si è deciso, chi e quando, perché, l'alternativa scartata quando c'era, e dove è applicata.

## Chi fa cosa

| Chi | Cosa fa | Cosa non fa |
|---|---|---|
| Il titolare (o l'assegnatario della card) | Le scelte di prodotto. Porta la card da Draft a New, anche la card di chiusura di una funzionalità (D52: la vista gliela mostra quando le sorelle sono tutte In feature branch). Prova in Test le card che lo chiedono. Approva il rilascio in produzione e le modifiche ad Azure DevOps (aree, pipeline, policy). Completa le PR del repo `DevOps.Agents` | Non scrive le card a mano: le prepara la sessione di sviluppo con lui. Non sposta più le card in Deploying to test né completa le PR dei prodotti: lo fa lo smistatore |
| Sessione di sviluppo (Claude con il titolare) | Analisi con `grill-me`, divisione in card, testo della card, area e mappa quando mancano, giri dello smistatore a mano, lavoro sul repo `DevOps.Agents` | Non scrive codice nei repo dei prodotti: lo fanno gli agenti |
| Smistatore | Fa avanzare le card del suo utente: lancia le sessioni, apre le PR, legge le validazioni e i log delle build, porta la card in Deploying to test e accoda il deploy (per i componenti con `collaudo`, D59, crea invece l'ambiente Docker della card e lo butta quando la card esce dal Test), completa la PR verso `develop` da Ready to merge, crea e toglie i worktree, avvisa sulla card e su Telegram. Per una funzionalità (D52): crea e pubblica il ramo della funzionalità, completa le PR delle card nel ramo e le porta In feature branch, apre la PR ramo della funzionalità verso `develop` per la card di chiusura, crea le Bug di correzione e `allinea-develop`, aggiorna lo stato della Feature | Non decide niente che non sia scritto in `src/Decisioni.psm1`: senza modelli. Non rilascia in produzione |
| `responsabile` | Criteri di accettazione verificabili, task, decisioni che il repo sa giustificare (con `file:riga`), bivi di `dev`, `no-test-deploy` quando nessun criterio si verifica in Test, esito della prova in Test (Ready to merge o di nuovo In development). Per la card di chiusura (D52): i parametri del deploy, `human-test` (`card.ps1 prova-umana`) e la correzione di un collaudo respinto, tecnica o di prodotto (`card.ps1 correzione`) | Non scrive codice e non fa commit. Non decide il prodotto: lo rimanda alla persona |
| `dev` | Codice e test nel worktree della card, un task alla volta; correzioni dopo validazioni rosse, rilievi e conflitti. In una funzionalità il worktree parte dal ramo della funzionalità e la PR va lì (D52) | Non decide: davanti a una scelta si ferma con un bivio |
| `reviewer` | Una passata sulla PR intera contro i criteri e le regole di sviluppo. In una funzionalità guarda il diff rispetto al ramo della funzionalità; sulla Bug `allinea-develop` solo la risoluzione del merge (D52) | Non corregge: segnala |
| `collaudatore` | Prova i criteri sull'ambiente di Test, o sull'ambiente Docker della card per i componenti con `collaudo` (D59), e scrive l'esito (D28). Per la card di chiusura (D52) i criteri della funzionalità intera | Non corregge: il resoconto va a `responsabile`. Non tocca la produzione |

## Uso del sistema

**D1. Ogni lavoro nei repo della mappa passa da una card.**
- Chi e quando: Il titolare, 2026-11-17.
- Perché: una regola sola scala meglio di una scelta caso per caso, e il lavoro degli agenti lascia traccia sulla card.
- Eccezioni: il repo `DevOps.Agents` (un errore in una PR degli agenti potrebbe fermare lo smistatore che la
  porta avanti) e le modifiche minuscole: niente decisioni, niente test nuovi, un file. Nel dubbio è una card.
- Dove: `skills/devops-agents/SKILL.md`.

**D2. L'analisi si fa prima, nella sessione di sviluppo, con `grill-me`; la card nasce in Draft.**
- Chi e quando: Il titolare, 2026-11-17.
- Perché: le scelte non prese nell'analisi le prenderebbe `responsabile` con una domanda, o `dev` senza dirlo. In
  Draft gli agenti non toccano la card finché il titolare non l'ha letta e portata in New.
- Dove: `skills/devops-agents/SKILL.md`, spec sezione 7.

**D3. Il richiedente di una card è chi apre la sessione di design.**
- Chi e quando: Il titolare, 2026-11-16.
- Perché: la card nasce con il PAT di chi usa Claude, quindi "creata da" coincide senza codice in più.
- Dove: spec sezione 7.

**D4. `responsabile` non riapre le decisioni già scritte nella descrizione.**
- Chi e quando: Il titolare, 2026-11-17.
- Perché: l'analisi con `grill-me` le ha già prese con la persona; richiederle costa un giro e token.
- Dove: `ruoli/responsabile.md`.

## Board e aree

**D5. Stati, tag e aree in inglese.**
- Chi e quando: Il titolare, 2026-11-16.
- Dove: processo ereditato su Azure DevOps, `config/stati.json`.

**D6. Un'area per repo; i componenti toccati li stabilisce la descrizione della card.**
- Chi e quando: Il titolare, 2026-11-17.
- Scartato: un'area per componente o per progetto verticale. Dei tag per componente si possono aggiungere più avanti.
- Dove: `config/mappa.json`.

**D7. Se l'area manca la predispone la sessione di sviluppo; il corredo del repo è la prima card dell'area.**
- Chi e quando: Il titolare, 2026-11-17.
- Cosa: l'area sulla board (con il sì del titolare) e la voce in `config/mappa.json` (con una PR) le fa la sessione,
  perché finché l'area non è mappata gli agenti non vedono la card. Il corredo (build-ci, pr-validation agganciata alla
  policy, deploy in Test) è una card: l'agente scrive gli YAML e uno script idempotente; lo script lo esegue la
  sessione, su ordine del titolare, a card finita. Pipeline e policy non le crea mai un agente.
- Dove: `skills/devops-agents/SKILL.md`.

**D8. Pipeline e policy si definiscono alla nascita del servizio, o in un task dedicato.**
- Chi e quando: Il titolare, 2026-11-17.
- Perché: non sono compito di chi lavora dopo su una card qualunque.
- Dove: card 7 (corredo di Refresh).

## Card e task

**D9. I task sono facoltativi e operativi: li crea `responsabile`, dalla specifica e dal codice.**
- Chi e quando: Il titolare, 2026-11-17.
- Perché: la specifica dice cosa fare, il task dice dove (`file:riga`) e come si verifica; quello si trova leggendo il
  repo. Un task divide i criteri, non li cambia. Una card che non si divide da sola resta senza task.
- Dove: spec sezione 18, `ruoli/responsabile.md`.

**D10. `crea-task` rifiuta i doppioni.**
- Chi e quando: Il titolare, 2026-11-17.
- Cosa: un titolo uguale a un task già presente (anche chiuso) o ripetuto nello stesso testo fa rifiutare tutto.
- Dove: `src/Card.psm1` (`New-CardTask`).

**D11. Un task aggiunto in corsa si esegue: in coda in In development, e da In review in poi riporta la card In development.**
- Chi e quando: Il titolare, 2026-11-17.
- Perché: la revisione fatta non copre il lavoro nuovo. Con i rilievi del reviewer vengono prima i rilievi; a PR
  completata il lavoro va in una card nuova.
- Scartato: fermare la card e chiedere.
- Dove: `src/Decisioni.psm1`, spec sezione 18.

**D12. Il task su cui parte `dev` va in Active.**
- Chi e quando: Il titolare, 2026-11-17.
- Perché: dalla board si vede quale task è in lavorazione.
- Dove: `src/Smistatore.ps1`.

## PR, validazione e revisione

**D13. Il giudice è la PR unibile, non la presenza di una build di validazione.**
- Chi e quando: Il titolare, 2026-11-17.
- Perché: un repo può non avere ancora la pr-validation. Senza build applicabili la PR è verde quando il controllo di
  unione di Azure DevOps è riuscito; con le build, vale il loro esito sul commit di testa.
- Dove: `src/Ado.psm1` (`Get-AdoPr`).

**D14. Una validazione rossa rilancia `dev` con gli errori della build; alla terza di fila la card va in on-hold.**
- Chi e quando: limite dalla spec; errori allegati dal 2026-11-18 (card 9).
- Perché: `dev` non ha permessi di scrittura su Azure DevOps e non deve cercarsi il log: lo smistatore estrae passi
  falliti, test falliti e righe di errore e li mette nell'allegato.
- Dove: `src/Ado.psm1` (`Get-AdoErroriBuild`), `config/limiti.json` (`rosseDiFila`).

**D15. Una validazione ancora in corso 60 minuti dopo la fine di `dev` dà un avviso, senza fermare la card.**
- Chi e quando: Il titolare, 2026-11-17.
- Perché: una PR bloccata in silenzio (build appesa, esito letto male) era passata inosservata sulla card 9.
- Dove: `config/limiti.json` (`validazioneMinuti`).

**D16. I conflitti con `develop` li risolve `dev`; le scelte le fa `responsabile`.**
- Chi e quando: Il titolare, 2026-11-18.
- Cosa: `dev` unisce `origin/develop` (merge, mai rebase) e scrive sulla card i file in conflitto e come li ha risolti.
  Se una risoluzione è una scelta, chiude con un bivio. Se dopo il suo tentativo i conflitti restano: on-hold.
- Scartato: farli risolvere a `responsabile`, che dovrebbe scrivere codice e romperebbe la separazione fra chi decide e
  chi scrive.
- Vale per le card isolate. Per una card di una funzionalità `dev` unisce il ramo della funzionalità, non `origin/develop`, e
  develop entra nella funzionalità solo alla chiusura (D52).
- Dove: `ruoli/dev.md`, `src/Decisioni.psm1`.

**D17. Al più due giri di revisione da `reviewer` a `dev`, poi on-hold.**
- Chi e quando: spec, 2026-11-16.
- Dove: `config/limiti.json` (`giriRevisione`).

**D26. Deploy in Test e merge in `develop` vanno da soli; a mano resta solo la produzione.**
- Chi e quando: Il titolare, 2026-11-18 (PR 983).
- Cosa: revisione superata, la card passa in Deploying to test e parte il deploy; dopo la prova (il collaudatore, o la persona con `human-test`)
  la card arriva in Ready to merge; lo smistatore completa la PR e la card arriva in Ready to release, cioè unita e pronta per la produzione. Un
  solo componente alla volta in Test, perché l'ambiente è uno.
- Vale per le card isolate. Una card di una funzionalità non passa dal Test e la sua PR si completa nel ramo della funzionalità;
  il Test e il merge in `develop` sono della card di chiusura (D52).
- Dove: `src/Decisioni.psm1`, spec sezione 5.

**D27. Una card che non ha niente da provare in Test salta il deploy: tag `no-test-deploy`.**
- Chi e quando: Il titolare, 2026-11-18.
- Cosa: con il tag, dopo la revisione la card va dritta in Ready to merge. Lo mette la sessione di sviluppo alla
  nascita (`card crea -SenzaTest`) oppure `responsabile` (`card.ps1 senza-test`) quando nessun criterio si verifica
  nell'ambiente di Test, scrivendo il motivo sulla card. Vale anche, senza tag, per un componente che non ha un deploy
  in Test. La revisione resta sempre.
- Perché: per una modifica a una pipeline o ai test il risultato si vede nella CI; un deploy in Test non verifica niente.
- Scartato: farlo decidere solo alla nascita della card.
- Dove: `config/stati.json` (`tagSenzaTest`), `src/Decisioni.psm1`, `ruoli/responsabile.md`.

**D28. Chi prova in Test, di norma, è un modello: il ruolo `collaudatore`.**
- Chi e quando: Il titolare, 2026-11-18.
- Cosa: dopo il deploy in Test un `collaudatore` (Sonnet) verifica i criteri sull'ambiente vero e scrive l'esito;
  superata, la card va in Ready to merge; non superata, il resoconto va a `responsabile`, che aggiunge un task e
  riporta la card In development. La prova di una persona resta per le card che la chiedono (tag `human-test`). Le
  credenziali di prova per entrare nell'app di Test sono configurazione iniziale del repo, come l'area: se il
  collaudatore non le ha, le predispone la sessione di sviluppo quando mappa il repo.
- Cosa può fare in Test: leggere, e creare dati di prova riconoscibili come tali (il nome dice collaudo e il numero
  della card) quando un criterio lo richiede; mai toccare la produzione. Al più due collaudi respinti di fila, poi
  on-hold. La persona prova solo con il tag `human-test` (`card crea -ProvaUmana`).
- Perché: le card intermedie di una catena non le può provare una persona, e aspettare la persona ferma la catena.
- Vale per le card isolate. Per una funzionalità il `collaudatore` prova la card di chiusura, cioè i criteri della funzionalità intera
  (quelli delle sorelle sono il suo contesto), e con `human-test` la prova di una persona viene dopo la sua, non al posto (D52).
- Dove: spec sezione 20, `ruoli/collaudatore.md`, `src/Decisioni.psm1`.

## Più smistatori

**D18. Ogni card ha un padrone: l'assegnatario. Ognuno ha il suo smistatore.**
- Chi e quando: Il titolare, 2026-11-17.
- Cosa: uno smistatore fa avanzare solo le card assegnate al suo utente, con il suo abbonamento a Claude; `card crea`
  assegna a chi crea; una card senza assegnatario non la prende nessuno. I limiti sulle risorse comuni (una card in
  sviluppo per repo, una in uno degli stati di Test per componente) si contano su tutta la board. Gli spostamenti che spettano a una
  persona li fa l'assegnatario; gli avvisi menzionano lui.
- Perché: due smistatori sulla stessa board non devono lanciare due sessioni sulla stessa card, e il traffico di
  ognuno resta suo.
- Dove: spec sezione 19, `src/Smistatore.ps1`.

**D19. Le card di chi è assente si prendono riassegnandole dalla board.**
- Chi e quando: Il titolare, 2026-11-17.
- Cosa: il nuovo assegnatario ricrea il worktree dal ramo pubblicato e riprende; si perde solo una sessione interrotta.
  Chi rientra toglie i worktree delle card che non sono più sue, se non hanno lavoro non pubblicato.
- Dove: spec sezione 19.

## Funzionamento

**D29. Le card di una funzionalità divisa si ordinano con il link Predecessor.**
- Chi e quando: Il titolare, 2026-11-17 (PR 973).
- Cosa: una card in New o Ready to develop resta ferma finché le card che la precedono non sono unite.
  `card crea -Dopo <id>`.
- Vale per le card isolate. Le card di una funzionalità D52 stanno sotto una Feature con una card di chiusura: la chiusura aspetta le
  sorelle senza link Predecessor, e In feature branch vale come «unita» solo fra sorelle della stessa Feature (D52).
- Dove: `src/Decisioni.psm1`, spec sezione 18.

**D30. Il motivo per cui una card è ferma si legge in un posto solo.**
- Chi e quando: PR 981, 2026-11-18.
- Cosa: `Get-Decisione` in `src/Decisioni.psm1` è la fonte unica del motivo (on-hold, predecessori, limite del repo,
  limite delle sessioni, limite del Test); `src/Vista.ps1` lo mostra.

**D31. La vista mostra la coda per agente, ricavata da Decisioni.**
- Chi e quando: Il titolare, 2026-11-18.
- Cosa: la pagina e una kanban con una colonna per ruolo (sessioni in corso in cima, coda sotto), la colonna dell'operatore
  (sblocca, rispondi, prova in Test, rilascia) e la pipeline. Lo stato sulla board compare solo come dettaglio: la pagina
  non e organizzata per stato. Anche cosa aspetta una persona (`Get-AttivitaOperatore`) lo decide Decisioni.
- Alternativa scartata: una board per stato delle card. Il titolare l'ha scartata perche replica quello che vede gia su ADO.
- Perche: il ruolo a cui andra una card non si decide nella vista. `Get-Decisione` lo da con la prima azione `LanciaSessione`;
  i motivi di attesa (`predecessori`, `limiteRepo`, `limiteTest`, `limiteSessioni`) portano un campo `Ruolo`.
- Dove: `src/Decisioni.psm1`, `src/Vista.ps1`, `src/VistaHtml.psm1`.

**D20. Lo smistatore gira dall'Utilità di pianificazione ogni 2 minuti, senza finestra.**
- Chi e quando: Il titolare, 2026-11-17, dopo la prova della card 9.
- Dove: `setup/Install-Attrezzi.ps1 -Pianificazione`, `config/limiti.json` (`intervalloMinuti`).

**D21. Fino a 3 sessioni di agente insieme per PC.**
- Chi e quando: PR 979, 2026-11-18.
- Dove: `config/limiti.json` (`sessioniAttive`).

**D22. Le sessioni di ruolo hanno un PAT in sola lettura, mai quello di chi le lancia.**
- Chi e quando: PR 977, 2026-11-18 (nata dalla card 10).
- Perché: `dev` e `reviewer` devono poter verificare contro Azure DevOps (un `-DryRun`, lo stato di una build) senza
  poter scrivere. Le verifiche che scrivono restano alla sessione interattiva.
- Dove: `~/.claude/pat-read-only.txt` (Build: Read, Code: Read), hook `deny-pat`, brief dei ruoli.

**D23. Un giro a mano si lancia sempre dopo un `-WhatIf`, e il giro vero solo con il via del titolare.**
- Chi e quando: Il titolare, 2026-11-17.
- Perché: il primo `reviewer` aveva portato al rilancio di `dev` nello stesso giro senza un via in mezzo.
- Dove: `skills/devops-agents/SKILL.md`.

## Costi

**D24. Modelli per ruolo: Opus a sforzo alto per `responsabile` e `reviewer`, Sonnet per `dev`.**
- Chi e quando: spec, 2026-11-16.
- Perché: `responsabile` sbaglia nel punto più costoso (un criterio capito male fa lavorare a vuoto tutti), con turni
  pochi e brevi; `reviewer` fa una passata sola per PR. `dev` fa il volume.
- Aggiornata il 2026-11-19 (il titolare):
  - `dev` passa a Opus con sforzo medio, e anche `collaudatore` è a Opus medio.
  - Motivo: con Sonnet le build di Stime sono finite con test lenti (da 5 a 25 minuti di pr-validation) e instabili (rosse una volta su due). Ogni rosso costa un giro di dev, e spesso uno di revisione.
- Dove: `config/ruoli.json`.

**D25. Lo sviluppo del sistema bada ai token.**
- Chi e quando: Il titolare, 2026-11-17 (e le istruzioni generali di Claude).
- Cosa: niente CLI di Claude per sviluppare il sistema; subagenti solo con un incarico chiuso che non debba rileggere
  il contesto, altrimenti in linea; una revisione Opus per ramo e un solo giro di correzioni. Il sistema invece usa
  `claude -p`, ed è lì che si spende.

**D32. Togliere l'on-hold dopo un deploy in Test fallito rilancia il deploy.**
- Chi e quando: Il titolare, 2026-11-18 (card 10: tolto l'on-hold dopo aver dato il permesso mancante, lo smistatore ha riletto
  lo stesso run fallito e ha rimesso l'on-hold).
- Cosa: un deploy fallito mette la card in on-hold con `inAttesaPer = deploy`. Chi toglie il tag ha sistemato la causa: lo
  smistatore azzera i contatori, dimentica il run fallito (`AzzeraDeploy`) e riaccoda il deploy. Vale anche per le card messe
  in on-hold prima, con `limite`: conta che il run salvato sia fallito.
- Perche: il deploy si rifa solo se non c'e un run valido per la revisione d'ingresso in Deploying to test; senza dimenticare il run,
  togliere il tag non serviva a niente.
- Dove: `src/Decisioni.psm1` (`Get-Decisione`, `Get-AzioniInDeployTest`), `src/Smistatore.ps1`.

**D33. Una validazione rossa la sistema `dev`, anche quando il test che fallisce è fuori dal recinto.**
- Chi e quando: Il titolare, 2026-11-18 (card 23: un test instabile di telemetria, fuori dal recinto, ha fatto chiudere
  `dev` con `bloccato` e la card è andata in on-hold a chiedere a lui).
- Cosa: con il motivo `rossa` `dev` trova la causa e la corregge, nel test o nel codice provato, anche fuori dal recinto.
  Non toglie, non salta e non allenta il test. Se la correzione è una scelta di comportamento chiude con un bivio e
  decide `responsabile`. `responsabile` coinvolge la persona che ha la card quando la scelta è di prodotto e anche
  quando ha un dubbio suo (vale per ogni bivio). I segreti restano esclusi.
- Perché: una PR rossa per un test altrui ferma la card quanto una rossa per colpa sua, e la correzione è lavoro di
  codice; chiederlo a una persona porta in on-hold una cosa che un agente sa fare.
- Dove: `ruoli/dev.md` (motivo `rossa`, il recinto, gli esiti), `ruoli/responsabile.md` (il bivio di `dev`).

**D34. Tre stati al posto di In test: Deploying to test, Automated test, Human test.**
- Chi e quando: Il titolare, 2026-11-18.
- Cosa: lo stato `In test` sparisce. Lo sostituiscono `inDeployTest` (Deploying to test: lo smistatore accoda il deploy e
  ne aspetta l'esito), `inCollaudo` (Automated test: prova il collaudatore) e `inProvaUmana` (Human test: prova la persona
  che ha chiesto la card, con il tag `human-test`). Da In review la card va in Deploying to test; a deploy riuscito va in
  Human test con il tag `human-test`, altrimenti in Automated test. Il run del deploy vale se accodato dopo l'ultimo
  ingresso in Deploying to test; il collaudo che vale è quello partito dopo l'ultimo ingresso in Automated test; l'avviso al
  richiedente si dà una volta per ingresso in Human test. In tutti e tre gli stati un task aggiunto riporta la card In
  development, una revisione non più superata la riporta indietro, e il limite `cardInTestPerComponente` conta le card che
  stanno in uno qualsiasi dei tre, perché l'ambiente di Test è uno. Una card rimasta nel vecchio `In test` non si gestisce e
  non c'è migrazione. Un commento di una persona in Automated test (deciso dal titolare, 2026-11-18) lancia `responsabile`
  con il motivo `commentoInCollaudo` e conta più dell'esito del collaudo: la card non va in Ready to merge finché
  `responsabile` non ha deciso. Se trova un difetto crea i task e la card torna in sviluppo (il collaudo di prima non vale
  più); se non trova niente vale l'esito del collaudo (superato: Ready to merge; respinto: `collaudoRespinto`). Una sessione
  alla volta: se il collaudatore lavora, `responsabile` parte quando ha finito, e il commento resta non letto finché
  `responsabile` non è lanciato.
- Perché: sulla board si vede se la card sta facendo il deploy, il collaudo del modello o aspetta una persona.
- Alternativa scartata: restare In test e mostrarlo solo nella pagina degli agenti.
- Dove: `config/stati.json`, `src/Decisioni.psm1` (`Get-AzioniInDeployTest`, `Get-AzioniInCollaudo`,
  `Get-AzioniInProvaUmana`), `src/Vista.ps1`, spec sezioni 5 e 20.

**D35. Un comando negato non ferma la card se la sessione chiude con un esito valido.**
- Chi e quando: Il titolare, 2026-11-18 (card 10: il reviewer ha tentato una controverifica, l'anteprima della pipeline,
  costruendo l'intestazione con il token; l'hook l'ha negata, lui ha concluso con `superata` e la card è andata in on-hold).
- Cosa: con comandi negati e una riga `ESITO=` valida vale l'esito, e lo smistatore scrive sulla card quanti comandi sono
  stati negati e con quale strumento (non il comando, che può contenere dati). Senza esito la sessione resta fallita.
  I brief di `dev`, `reviewer` e `collaudatore` dicono di chiamare Azure DevOps con `az`, che trova il token da solo, e
  che le controverifiche in lettura sono benvenute.
- Perché: il blocco è dell'hook ed è giusto; fermare la card dopo che l'agente si è adattato non aggiunge sicurezza. Un
  esito dichiarato ma falso (un `fatto` con il push negato) lo prendono i controlli dopo, che leggono ramo e PR su ADO.
- Dove: `src/Sessioni.psm1` (`Get-EsitoSessione`), `src/Smistatore.ps1`, `ruoli/`.

**D36. Il collaudatore chiama solo gli host di Test della mappa.**
- Chi e quando: Il titolare, 2026-11-18.
- Cosa: nelle sessioni del collaudatore (`ATTREZZI_RUOLO=collaudatore`) un hook nega il comando di `Bash`, `PowerShell` o
  `WebFetch` che nomina un host diverso da: gli host degli `urlTest` di `config/mappa.json` (qualunque porta), Azure
  DevOps (`acme.visualstudio.com`, `dev.azure.com`), `localhost`, `127.0.0.1`. L'elenco si legge dalla mappa a ogni
  chiamata. Il messaggio dice l'host trovato; se gli serviva davvero, il collaudatore chiude con `bloccato`.
- Perché: gli ambienti di Test sono ibridi e l'utente di prova è unico; il divieto scritto nel brief non basta.
- Limite: l'hook legge solo il testo del comando. Non vede un URL costruito in una variabile
  (`$env:COLLAUDO_URLLOGIN`, concatenazioni): è un presidio contro l'errore, non una difesa da un modello malevolo.
- Dove: `hooks/deny-host-collaudo.ps1` (casi in `hooks/Test-Hooks.ps1`), registrato da `setup/Install-Attrezzi.ps1`.

**D37. La vista e un server solo su localhost, con un token per le azioni.**
- Chi e quando: Il titolare, 2026-11-18; aggiornata dal titolare il 2026-11-24 (pulsante "Togli on-hold").
- Cosa: con `-Html -Segui` la vista serve le sue pagine con `HttpListener` su `http://localhost:<porta>/` (default 18799, `-Porta`; le porte riservate da Windows, come 8695-8794 su questo PC, non si aprono) e ha questi pulsanti: "Avvia smistatore" (`POST /giro`) avvia l'attivita pianificata dello smistatore, "Aggiorna agenti e card" (`POST /aggiorna`, dal 2026-11-19) fa rileggere subito Azure DevOps alla vista, e su ogni card in on-hold "Togli on-hold" (`POST /togli-attesa?id=<card>`, dal 2026-11-24): dopo una conferma toglie il tag `on-hold` con `Set-AdoCard -TogliTag` e fa rileggere ADO come `/aggiorna`; nient'altro, il seguito (per esempio il deploy rilanciato, D32) lo decide lo smistatore al giro dopo. I due contatori in testa dicono fra quanto si ricarica la pagina e fra quanto parte lo smistatore. I comandi vogliono un token casuale generato all'avvio e scritto nella pagina (header `X-Vista-Token`), l'header `Host` deve essere localhost sulla porta, si servono solo `vista.html`, `sessione-*.html` e `brief-*.html`, e il corpo della richiesta non si legge. L'unico dato che arriva a un comando è l'id di `/togli-attesa`, in query: un intero che deve stare fra le card che la vista, nella sua ultima lettura di ADO, mostra con il tag `on-hold` (lista bianca tenuta dal server, vuota se ADO non risponde); ogni altro valore è rifiutato (400 se non è un intero, 403 se non è in lista) senza chiamare ADO.
- Perche: il pulsante per anticipare un giro; il pulsante on-hold per togliere l'attesa dopo aver sistemato la causa, senza aprire la board.
- Alternativa scartata: la pagina da file, che non puo eseguire niente; per l'on-hold, nessun dato dalla richiesta, che obbligava a passare dalla board.
- Dove: `src/VistaServer.psm1`, `src/Vista.ps1`, `src/VistaHtml.psm1`.

**D38. Una validazione rossa per un test instabile si rilancia una volta, da sola.**
- Chi e quando: Il titolare, 2026-11-19 (card 26: `ConsentAuditTests` rosso in CI e verde in locale; `dev` ha chiuso con
  `bloccato`, la validazione rilanciata a mano è tornata verde alle 21:10, ma la card è rimasta in on-hold fino al
  mattino perché lo smistatore non guarda le card in on-hold).
- Cosa: con il motivo `rossa`, se il fallimento non si riproduce e non c'entra con la card, `dev` chiude con
  `ESITO=rilancia` e scrive nel commento il test e perché lo ritiene instabile. Lo smistatore rilancia le validazioni di
  build rosse della PR (come "Re-queue"), lo scrive sulla card e da lì segue la PR: verde → reviewer, rossa → `dev` con
  la rossa. Un secondo `rilancia` sulla stessa card la mette in on-hold `limite`; togliendolo il conto riparte.
- Perché: `dev` non ha il permesso di rilanciare una build, e un blocco che si scioglie da solo (la validazione torna
  verde) non lo vede nessuno finché la card è in on-hold.
- Alternativa scartata: togliere da solo un on-hold quando la condizione torna buona. L'on-hold è il tag di una
  persona; con il rilancio questo caso non ci arriva più.
- Dove: `src/Decisioni.psm1` (`Get-AzioniInSviluppo`), `src/Smistatore.ps1` (`RilanciaValidazione`),
  `src/Ado.psm1` (`Start-AdoRivalutazione`), `ruoli/dev.md`.

**D39. Un ruolo in sola lettura che cambia il worktree della card la ferma.**
- Chi e quando: Il titolare, 2026-11-19.
- Cosa: prima di lanciare nel worktree della card un ruolo senza `Write` ed `Edit` (`responsabile`, `reviewer`,
  `collaudatore`), lo smistatore ne prende l'impronta: ramo, commit di testa, `git status` e hash del diff. A sessione
  finita la confronta. Se è cambiata, la card va in on-hold con l'elenco di cosa è cambiato e l'esito della sessione
  non si applica; tolto l'on-hold, il ruolo riparte. Vale anche per una sessione morta o chiusa per silenzio, e se il
  worktree non si riesce a leggere. I file che git ignora (`bin`, `obj`, `node_modules`) non contano.
- Perché: togliere `Write` ed `Edit` non toglie la shell, che è approvata per intero, e l'hook sui commit lascia
  passare tutto ciò che sta sotto `_wt`. Senza questo controllo il "non corregge" del `reviewer` reggeva solo sul brief.
- Limiti: `responsabile` senza worktree lavora nella copia principale, che cambia anche il titolare, e lì il controllo non
  c'è. Un push non lascia traccia nel worktree e non si vede da qui.
- Alternativa scartata: restringere i comandi di shell del ruolo con un elenco di permessi. Un elenco così o blocca
  comandi legittimi di lettura o si aggira; il confronto guarda il risultato, non il comando.
- Dove: `src/Config.psm1` (`Test-RuoloSolaLettura`), `src/Worktree.psm1` (`Get-ImprontaWorktree`,
  `Compare-ImprontaWorktree`), `src/Smistatore.ps1` (`Get-ScrittureSolaLettura`, `Close-Sessione`).

**D40. Un blocco lo guarda prima un agente: dev e responsabile correggono il titolo della PR, e dev bloccato passa dal responsabile.**
- Chi e quando: Il titolare, 2026-11-19. Card 11: la validazione della PR 1019 era rossa solo perché il titolo non aveva
  `feat:`. `dev` non poteva rinominare la PR e ha chiuso `bloccato`, e la card è rimasta in on-hold ad aspettare una
  persona.
- Cosa:
  - Lo smistatore apre le PR con il tipo conventional-commit del ramo: `feat:` per `feature/`, `fix:` per `fix/` e
    `bugfix/`.
  - `card.ps1 titolo-pr` permette a `dev` e `responsabile` di rinominare la PR collegata alla card. Il comando rilancia
    anche la validazione.
  - Un `ESITO=bloccato` di `dev` lancia il `responsabile` con il resoconto in allegato. Il `responsabile` sblocca e chiude
    `fatto`, e `dev` riparte. Se invece serve una persona, si ferma lui. Se `dev` si blocca di nuovo subito dopo
    quella decisione, la card va in on-hold.
- Perché: un problema meccanico come un titolo sbagliato non deve aspettare il titolare.
- Alternativa scartata: far correggere il titolo allo smistatore a ogni giro. Una regola fissa copre solo il caso
  previsto, mentre un agente legge l'errore vero e, se non riesce a risolverlo, si ferma.
- Dove:
  - `src/Decisioni.psm1` (`Get-TitoloPr`, `Get-AzioniInSviluppo`)
  - `src/Smistatore.ps1` (`ApriPr`)
  - `src/Card.psm1` (`Set-CardTitoloPr`)
  - `src/card.ps1`
  - `src/Ado.psm1` (`Set-AdoTitoloPr`, `Get-AdoPrCollegata`)
  - `ruoli/dev.md`, `ruoli/responsabile.md`

**D41. I PAT si creano con `az login` solo durante l'installazione; poi login `az` fuori e lo smistatore lavora coi PAT.**
- Chi e quando: Il titolare, 2026-11-19.
- Cosa:
  - `setup/Install-Attrezzi.ps1 -Pat` fa `az login` (se non c'è già un login), prende un token Entra per Azure DevOps in
    memoria, crea due PAT con l'API dei PAT (`POST vssps.dev.azure.com/<org>/_apis/tokens/pats`): quello dello smistatore
    con gli scope minimi, quello in sola lettura (Build Read, Code Read). Poi `az logout`, anche se qualcosa fallisce; un
    login che c'era già non si tocca. Scope, durata (90 giorni) e nomi stanno in `config/pat.json`.
  - I PAT sono scritti cifrati con DPAPI in `~/.claude/pat-smistatore.txt` e `pat-smistatore-lettura.txt`, solo dopo che
    sono nati entrambi (prima in file temporanei, poi rinominati; se la scrittura fallisce i PAT nuovi si revocano e i file
    di prima restano com'erano). **`pat.txt` resta tuo, `-Pat` non lo tocca**, né `pat-read-only.txt`: l'utente li usa in
    chiaro per i suoi `az` interattivi, con scope più larghi. Chi legge (`Get-PercorsoFilePat`) prende il nome nuovo se
    c'è, altrimenti `pat.txt` / `pat-read-only.txt`, così le installazioni di oggi continuano a funzionare.
    `Read-FilePat` li legge, un file in chiaro funziona lo stesso, e un file cifrato non decifrabile da questo utente
    Windows è un errore chiaro, non un PAT in chiaro. `~/.claude/pat-info.json` (non segreto) tiene
    `authorizationId` e scadenza; al giro successivo di `-Pat` i vecchi si revocano dopo aver salvato i nuovi; quelli che non si revocano restano in
    `daRevocare` e il giro dopo li riprova. La config si valida prima del login; il login è con
    `--allow-no-subscriptions`; le scadenze sono in ISO UTC; se `az logout` fallisce lo script avvisa di farlo a mano.
  - Lo smistatore avvisa su Telegram, una volta per scadenza, quando il suo PAT scade entro 7 giorni; un 401 ferma il giro
    con "PAT scaduto o revocato: rilancia `-Pat`" e manda un avviso Telegram, una volta finché l'accesso non torna a
    funzionare (file `pat-401-avvisato`).
  - Le sessioni di ruolo partono con `AZURE_CONFIG_DIR` su una cartella loro (`<dati>/az/<id sessione>`, ricreata a ogni
    avvio, con solo il `config` con l'organizzazione di default), `AZURE_EXTENSION_DIR` sulle estensioni di `az` dell'utente
    (`az pipelines` e `az devops invoke` restano disponibili) e l'hook `deny-pat` blocca `get-access-token`, `az login`,
    `msal_token_cache`, `AZURE_CONFIG_DIR`, la cartella `.azure` e qualunque `pat*.txt`: un login `az` della persona non
    passa all'agente e uno fatto dall'agente non resta.
- Perché: il PAT di prima si creava a mano. Con l'installatore il collega non crea niente, ma `az` non deve restare
  loggato: un login permanente è un accesso completo con i permessi della persona.
- Alternative scartate:
  - un PAT full access usa e getta, creato dall'installazione: l'API dei PAT non accetta un PAT, solo un token Entra, quindi
    un PAT non può creare altri PAT né revocarsi, e se la procedura si rompe resta sulla macchina il PAT peggiore;
  - il login `az` permanente come autenticazione dello smistatore: equivale a un accesso completo, anche ad Azure Resource
    Manager, quindi più largo di un PAT.
- Dove: `src/Pat.psm1` (`Install-Pat`), `config/pat.json`, `setup/Install-Attrezzi.ps1` (`-Pat`), `src/Comune.psm1`
  (`Read-FilePat`, `Write-FilePat`), `src/Ado.psm1` (`Get-AdoIntestazione`), `src/Sessioni.psm1` (`Start-SessioneRuolo`),
  `src/Smistatore.ps1` (`Test-ScadenzaPat`), `hooks/deny-pat.ps1`.

**D42. Prima di ogni on-hold per una persona passa il responsabile, una volta per tipo di attesa finché una persona non interviene.**
- Chi e quando: Il titolare, 2026-11-19.
- Cosa:
  - Dove lo stato deciderebbe `New-Attesa` (deploy in Test fallito, collaudatore `bloccato`, troppe validazioni rosse o
    troppi giri di revisione e di collaudo, conflitti rimasti dopo dev, sessione finita senza `ESITO`, PR da completare
    che non si completa, ...) lo smistatore lancia il `responsabile` con il motivo `attesa`. L'allegato ha il motivo e i
    dettagli che l'istantanea già ha: testo dell'ultima sessione, link del run o della build. Nello stato della card
    restano `attesaInEsame` (motivo, `per`, ultimo ruolo, chiave del tipo) e `passateFatte`.
  - Il punto è uno solo: `Convert-AttesePerResponsabile`, chiamata da `Get-Decisione` sulle azioni delle funzioni di stato.
  - `fatto`: come se la persona avesse tolto l'on-hold con quell'`inAttesaPer`. Il codice è quello esistente
    (`limite` e `deploy` azzerano i contatori e il deploy si rilancia, `sessione` riprende la sessione del ruolo di prima,
    con un messaggio che dice che è passato il `responsabile` e rimanda al suo commento).
  - `bloccato`: on-hold con il motivo di prima e "(il responsabile ha guardato: la sua diagnosi e nel commento sulla
    card)". `domande`: con la card in `daChiarire` nessun on-hold, la persona risponde lì. Le transizioni del
    `responsabile` verso `daChiarire` valgono solo da `nuova` e `inSviluppo`: da ogni altro stato la card resta dov'è e va
    in on-hold con il motivo di prima e "(il responsabile ha domande per te: sono nel commento sulla card)".
  - Una passata per tipo di attesa, finché una persona non interviene. `passateFatte` tiene le chiavi dei tipi già
    esaminati: il motivo, se è un testo fisso, altrimenti una chiave data da `New-Attesa -Tipo` (`deployFallito`,
    `taskNonChiuso`, `senzaEsito`, `esitoCollaudoSconosciuto`, `prNonCompletata`). L'elenco si svuota solo quando una
    persona toglie un on-hold (inAttesaPer valorizzato e tag tolto): non al cambio di stato, non al `fatto` del
    `responsabile`, non quando la card va in on-hold. Una chiave legata allo stato non reggeva: i giri di revisione e di
    collaudo e le validazioni rosse attraversano più stati, e dopo il `fatto` (che azzera i contatori) il ciclo si ripeteva
    senza fine.
  - Vanno dritte in on-hold: la stessa attesa dopo la sua passata, le attese nate da una sessione del `responsabile`, i
    fermi di D39, l'attesa del richiedente in Human test, e le chiusure di sessione di `Close-Sessione` (silenzio, errore,
    comandi negati).
  - La passata resta aperta (`attesaInEsame`) finché non si chiude davvero: si azzera solo con la chiusura (`fatto`,
    `bloccato`, `domande`). Se la sessione del `responsabile` finisce senza `ESITO`, o la ferma `Close-Sessione`, la card va
    in on-hold per `sessione`; tolto il tag riprende il `responsabile` (mai l'esito vecchio della sessione fermata) e la
    ripresa chiude la passata. Se il `responsabile` della passata non parte, la passata si annulla e al giro dopo riparte.
  - Rete di sicurezza: se l'ultima sessione è del `responsabile`, è finita, il suo motivo è `attesa`, `bloccato` o `bivio`,
    nessuna regola produce azioni e la card non aspetta altro (non è in `daChiarire`, non ha un blocco di partenza), la
    card va in on-hold con "il responsabile ha finito ma nessuna regola sa come proseguire: leggi il suo commento".
  - D40 resta com'è: il dev `bloccato` ha un suo percorso (motivo `bloccato`, poi dev riparte con `decisione`) e i test di
    D40 lo fissano. Il brief del `responsabile` ha una sola descrizione di cosa si prova per sbloccare, e per D40 dice
    a parte gli esiti.
- Perché: Il titolare non deve leggere i log da zero. Un problema meccanico (un criterio, un titolo, un task scritto male) lo
  sistema il `responsabile`; se serve una persona, la diagnosi è già sulla card.
- Alternative scartate: tutto dritto al titolare, com'era (ogni blocco costava una lettura dei log); il `responsabile` senza
  limite di passate (la stessa attesa girerebbe a vuoto a ogni "fatto"); una passata per stato della card (i giri che
  attraversano gli stati ripartivano senza fine).
- Dove: `src/Decisioni.psm1` (`Convert-AttesePerResponsabile`, `Test-ResponsabileSenzaSeguito`, `Get-Decisione`),
  `src/Smistatore.ps1` (`Invoke-Azione`, `Undo-PassataAttesa`), `src/Stato.psm1`, `ruoli/responsabile.md`.

**D43. I parametri del deploy in Test li sceglie il responsabile, fra i booleani `deploy*` dello YAML della pipeline.**
- Chi e quando: Il titolare, 2026-11-19, dopo la card 11: cambiava anche lo schema `efficiency` (DACPAC), il deploy è partito
  solo con il parametro fisso della mappa (`deployForms`), lo schema non è arrivato in Test e il collaudatore si è fermato.
- Cosa:
  - Il `responsabile` scrive la scelta con `card.ps1 deploy`: sulla prima riga di stdin i nomi, sotto il perché. Il comando
    scrive un commento `[responsabile] Parametri del deploy in Test: <nomi separati da virgole>` seguito da
    `Perche: <testo>`. Vale l'ultimo commento di quel formato che comincia con il prefisso `[responsabile]`: è il prefisso
    che conta, perché gli agenti e lo smistatore scrivono tutti con lo stesso PAT e non c'è altro modo di distinguere chi
    l'ha scritto. Il commento è il solo posto in cui la scelta vive: lo vedono le persone e vale da ogni PC, niente stato locale. `card.ps1 leggi` la mostra.
  - I parametri ammessi sono i booleani della sezione `parameters` dello YAML della pipeline di deploy del componente
    (`pipelineDeploy` nella mappa) il cui nome comincia con `deploy`. Il confronto distingue maiuscole e minuscole, sul prefisso e sui nomi. Il percorso dello YAML e il
    repo vengono dalla definizione della pipeline (`_apis/pipelines/{id}`, `configuration`), il contenuto dal repo sul
    ramo. Gli altri restano esclusi, sempre: `allowDatabaseDataLoss`, `forceRedeploy`,
    `confirmProductionDatabasePublish` agiscono sul deploy, non scelgono un componente.
  - `card.ps1 deploy` rifiuta un nome che non è nell'elenco: lo legge sul ramo della card se è pubblicato
    (`feature/<id>-...` o `fix/<id>-...`), altrimenti su `develop`.
  - In Deploying to test, prima di accodare il deploy (nessuna run valida per l'ingresso, o la run fallita), l'istantanea
    porta l'ultima scelta (dai commenti, scaricati una volta per giro) e l'elenco del ramo della card; mentre la run vale
    non legge né l'una né l'altro. `Decisioni.psm1` verifica di nuovo i nomi e accoda la run con quei parametri a `true` e
    gli altri `deploy*` dell'elenco a `false`, così un default `true` dello YAML non porta in Test niente che nessuno abbia
    scelto. Senza scelta, con un nome che lo YAML del ramo non ha più (anche con un elenco letto e vuoto) o con lo YAML
    che non si legge, niente deploy: un'attesa per `deploy` con il motivo "manca la scelta del deploy in Test del
    responsabile", "parametro di deploy sconosciuto: X" o "non riesco a leggere i parametri del deploy in Test: <errore>"
    (un errore di lettura non fa saltare il giro alla card). Passa da D42: il `responsabile` riceve la passata,
    scrive la scelta, chiude `fatto` e il deploy parte. Vale anche per le card già in corso, che il commento non lo hanno.
  - Il `reviewer` dà un rilievo bloccante se il diff tocca un componente che la scelta non copre; la card torna indietro
    con i rilievi e da lì al `responsabile`, che riscrive la scelta.
  - `parametroDeploy` esce dalla mappa: nessun ripiego sul parametro fisso.
- Perché: chi conosce il recinto della card è il `responsabile`, e un componente aggiunto domani al repo lo vede da sé
  leggendo lo YAML, senza che nessuno aggiorni una tabella.
- Alternative scartate: il parametro fisso della mappa (un solo componente per area: la card 11 ne toccava due); una regola
  deterministica che indovina i parametri dai file toccati (va tenuta allineata a ogni componente nuovo, e sbaglia proprio
  sui casi che non ha previsto).
- Dove: `src/card.ps1` (`deploy`), `src/Card.psm1` (`Set-CardDeploy`, `Read-Card`), `src/Comune.psm1`
  (`ConvertTo-TestoCommentoDeploy`, `Get-SceltaDeploy`), `src/Ado.psm1` (`Get-AdoParametriDeploy`, `Get-AdoRamoCard`,
  `Start-AdoDeployTest`), `src/Istantanea.ps1` (`Get-DeployCard`), `src/Decisioni.psm1` (`Get-SceltaDeployValida`),
  `src/Smistatore.ps1` (`AccodaDeployTest`), `config/mappa.json`, `ruoli/responsabile.md`, `ruoli/reviewer.md`.

**D44. La vista mostra i run di build/pipeline di tutti i progetti dell'organizzazione, in sola lettura, con un link per ogni run.**
- Chi e quando: Il titolare, 2026-11-20.
- Cosa: sotto la kanban la sezione «Pipeline di build»: un riepilogo (in corso, in coda, in attesa di approvazione, falliti
  nelle ultime 24 ore), una riga per ogni run attivo (progetto, pipeline, ramo, chi l'ha lanciato, da quanto, fase o
  approvazione su cui è fermo, link a `_build/results?buildId=N`) e, in un riquadro chiuso, i falliti e gli annullati
  delle ultime 24 ore. Per le PR solo un link a `/_pulls`, la vista di ADO che le raccoglie tutte: la lista non si rifà.
  - La lettura (`Get-AdoBuildPipeline`, `src/Ado.psm1`) elenca i progetti con `_apis/projects` e per ciascuno chiede due
    volte `_apis/build/builds` (run attivi; conclusi `failed`/`canceled` con `minTime`). Solo `GET`, stesso PAT, stesso
    ritmo della lettura di ADO della vista (`-SecondiAdo`).
  - La fase e l'approvazione si leggono dalla timeline, solo dei run `inProgress`: un `Checkpoint.Approval` in corso
    vuol dire «in attesa», con la fase che lo chiede. Se la timeline non si legge il run resta «in corso» senza fase.
  - Un progetto che non risponde finisce in `Errori` e non ferma gli altri; una lettura fallita del tutto dà un avviso
    nella sezione e non nasconde gli agenti (e viceversa): le due letture non dipendono l'una dall'altra.
  - Il conteggio dei falliti non include gli annullati, che stanno comunque nel riquadro, etichettati.
  - I run dei `release-orchestrator` (pipeline con "orchestrator" nel nome, cercata per nome in ogni progetto: in
    Acme.AI è la 115) stanno in un blocco proprio sopra gli altri run, che non li ripetono. Per ciascuno: ramo,
    componenti rilasciati (i `templateParameters` `deploy*` a `true`), stage attuale, "ATTENDE APPROVAZIONE" in
    evidenza, esito finale e link. Il blocco mostra gli ultimi 5 run per progetto, in corso o conclusi (anche riusciti),
    non solo quelli attivi; i conteggi del riepilogo li includono.
  - L'agente di build si legge dai job del run (`workerName` della timeline): «Azure Pipelines N» e «Hosted Agent» sono
    cloud, ogni altro nome è un agente interno, job su tutti e due «misto». La coda del run non basta: è il pool predefinito
    della pipeline e lo YAML lo sostituisce (una build-ci «in coda su Hosted Ubuntu» gira su `acme-sh-agent`). Per i
    run senza job partiti (in coda, conclusi) l'agente è quello abituale della pipeline, preso dall'ultimo run concluso che
    ha girato davvero, ricordato per un'ora e segnato come stima (bordo tratteggiato, tooltip).
  - Un run che ADO dà «in corso» ma senza job che girano, con un job in attesa sotto uno stage già partito, è «in coda»:
    quel job aspetta un agente (succede ai rilasci quando gli agenti sono occupati). Il dettaglio dice quale job aspetta.
  - Anche un run fermo su un controllo dell'environment (un `Checkpoint` che non è un'approvazione: lock esclusivo,
    finestra oraria, funzione esterna) senza job che girano è «in coda», con il dettaglio «aspetta un controllo»: non
    occupa un agente. «In corso» resta solo per i run che hanno un job che gira.
  - In cima alla scheda i filtri per stato (tutti, in corso, in coda, da approvare, falliti o annullati, riusciti), con
    quanti run ha ciascuno; si vedono solo i blocchi e le tabelle con almeno una riga di quello stato. La scelta resta
    in `sessionStorage` come la scheda.
  - Sopra i filtri il riquadro «Agenti dei pool interni»: per ogni pool non ospitato quanti run ci aspettano e ogni agente
    con lo stato (online, offline, disabilitato) e il run che sta eseguendo, con il link (`pools/{id}/agents`, stesso
    scope della posizione in coda). Fa vedere subito quando la coda è lunga perché c'è un solo agente.
  - I minuti cloud rimasti nel mese non stanno nella vista: si guardano in Organization settings → Parallel jobs.
    L'API che li dà (`distributedtask/resourceusage`) non è pubblica e non è legata a uno scope: la accetta solo un
    PAT con accesso completo. Il PAT dello smistatore risponde 401 anche con Agent Pools (Read & manage) (prova del
    2026-11-20), e un PAT con accesso completo per la vista non vale la comodità.
  - La scheda Pipeline non ha il bollino rosso dei falliti, solo quello delle approvazioni: i falliti stanno nel
    riepilogo e nei filtri.
  - Le due schede si possono anche affiancare (in colonna sotto i 1200px di larghezza) o mettere una sotto l'altra:
    la scelta sta a destra della barra delle schede e resta in localStorage, perché è una preferenza di chi guarda e
    vale anche alla prossima apertura (la scheda aperta invece resta in sessionStorage).
    Affiancate o in colonna, fra i due pannelli c'è un divisore da trascinare (o da spostare con le frecce; doppio clic
    lo rimette com'era): affiancate cambia la quota della colonna di sinistra (fra 15% e 85%), in colonna l'altezza degli
    Agenti, che scorrono dentro. Anche le due misure restano in localStorage, una per disposizione.
    Affiancate o in colonna i pannelli sono tre (Agenti, Pipeline, Apprendimento) e le schede in alto non spariscono: diventano interruttori, un clic nasconde
    o fa tornare il pannello (2026-11-24, il titolare: «le si affianca tutte e poi si sceglie quali nascondere»). Quali sono nascosti resta in localStorage.
  - I filtri per stato sono a scelta multipla: un clic aggiunge o toglie uno stato, «Tutti» li azzera.
  - La posizione in coda è quella di ADO: le richieste dei pool di agenti (`distributedtask/pools/{id}/jobrequests`)
    non ancora assegnate, in ordine di accodamento, con il nome del pool. Vogliono lo scope «Agent Pools (Read)»
    (`vso.agentpools`), aggiunto al PAT dello smistatore in `config/pat.json`; senza, «in coda» senza numero.
    Per un run in coda il pool della richiesta dice anche l'agente (cloud se il pool è ospitato, altrimenti interno), e
    vale più della stima dall'ultimo run concluso. La posizione è quella della lettura: fra una lettura e l'altra (60 s)
    un run davanti può prendere l'agente, e ADO mostra già un posto in meno.
    Una stima fatta con l'ordine di accodamento dei soli run visti sbagliava (nella coda del pool ci sono anche job
    che la vista non vede, come le build-ci accodate dagli orchestrator) ed è stata tolta.
  - Ogni run ha il tipo (rilascio, pr, ci, pianificato, manuale: dall'orchestrator, dal motivo del run e dal nome della
    pipeline), il build id e la versione (`buildNumber`).
  - Disposizione: in cima il titolo con il pulsante delle PR (scheda nuova), «Aggiorna pipeline» e il riepilogo; poi
    «Da approvare» con i soli run fermi su un'approvazione; poi un blocco comprimibile per progetto (prima quelli con
    attese, poi con run attivi, poi con soli falliti), con i badge in corso, in coda, falliti, una tabella di rilasci e
    run attivi e i falliti in un riquadro chiuso. Tutta la riga apre il run in una scheda nuova, come il suo link.
  - «Aggiorna pipeline» (`POST /aggiorna-pipeline`) rilegge solo le pipeline; «Aggiorna agenti e card» solo agenti e card:
    le due letture hanno lo stesso ritmo ma timer separati.
  - La pagina ha due schede, «Agenti» (kanban e catene) e «Pipeline» (questa sezione), con la scelta ricordata in
    `sessionStorage` perché la pagina si ricarica da sola; sulla scheda Pipeline un numero dice le attese di approvazione
    (o, se non ce ne sono, i falliti). Senza lettura delle pipeline niente schede; senza JavaScript i pannelli si vedono uno
    sotto l'altro. I run stanno in tabelle (orchestrator, attivi, falliti), con l'attesa di approvazione su sfondo evidenziato.
  - «In attesa di approvazione» vale per un `Checkpoint.Approval` in corso e anche per un task `ManualValidation` in corso
    (il «Manual release approval» degli orchestrator): per chi guarda è la stessa cosa, una persona deve dire di sì.
- Perché: chi lavora su più repo non ha altrove un posto solo in cui vedere cosa gira e cosa è rosso.
- Alternative scartate: rifare la lista delle PR (ADO la fa già, per tutti i progetti); leggere la timeline di ogni run
  (molte chiamate per niente: serve solo a chi gira); una chiamata sola con `statusFilter=all` (porta anche tutti i
  successi delle 24 ore).
- Dove: `src/Ado.psm1` (`Get-AdoBuildPipeline`), `src/Vista.ps1` (`Get-ModelloVista`, il ciclo), `src/VistaHtml.psm1`
  (`Format-SezioneBuild`), `docs/vista-esempio.html`.

**D45. stato.json bloccato per un istante: chi lo legge riprova, e non lo scambia mai per uno stato vuoto.**
- Chi e quando: Il titolare, 2026-11-20.
- Cosa: `Get-Stato` riprova la lettura per circa un secondo (10 tentativi da 100 ms) se il file è bloccato; se resta
  bloccato lancia un errore. La vista, se la lettura fallisce lo stesso, tiene lo stato letto al giro prima, lo dice una
  volta in console e continua a disegnare.
- Perché: `Save-Stato` sostituisce il file con `File.Replace` e per un istante lo tiene in esclusiva; la vista che leggeva
  proprio allora si fermava con un errore di condivisione. Uno stato vuoto al posto dell'errore sarebbe peggio: lo
  smistatore lo salverebbe sopra quello vero.
- Dove: `src/Stato.psm1` (`Get-Stato`), `src/Vista.ps1` (il ciclo).

**D46. Ogni ruolo ha una memoria di lezioni, scritta da un agente mentore quando un superiore lo corregge.**
- Chi e quando: Il titolare, 2026-11-20, in un giro di domande. Un ruolo si comporta come una persona alle prime armi: si
  blocca, un superiore lo corregge, e la volta dopo deve sapere già cosa fare. Oggi ogni sessione parte da zero: la
  correzione resta nella card e la card dopo non la vede. Finora le lezioni le portavamo a mano nei brief (D40, D42, D43).
- Cosa:
  - **Chi scrive.** Un agente `mentore` (Opus), mai il ruolo che ha sbagliato: chi sbaglia non si dà le regole da solo.
    Lo smistatore lo lancia a ogni correzione, con chi ha sbagliato, chi ha corretto e come.
  - **Quando parte** (gli inneschi esistono già nello smistatore):
    - il `responsabile` sblocca il `dev` bloccato o al bivio (D40: `dev` riparte con motivo `decisione`): lezione per il dev;
    - il `reviewer` rimanda il dev a correggere (motivo `rilievi`): lezione per il dev;
    - una persona interviene sulla card, togliendo un on-hold o commentando (`AzzeraPassateAttesa`, motivo `commento`):
      lezione per il `responsabile`, o per il ruolo che la risposta indica;
    - un difetto emerge dopo il collaudo (`inProvaUmana` → `inSviluppo`, o un problema trovato in Test o in produzione):
      lezione per il `collaudatore`, e per il `reviewer` se il difetto stava nel diff che ha approvato;
    - una card di tipo Bug: il mentore risale alla card d'origine (git blame delle righe corrette → PR → card) e scrive
      le lezioni per `dev`, `collaudatore` e, se il difetto stava nel diff approvato, `reviewer`. Se l'origine non si
      trova (codice scritto a mano, errore di una persona) la lezione si scrive lo stesso, per `dev` e `collaudatore` di
      quel repo: serve a evitare il problema la prossima volta, non a dare la colpa.
  - **La lezione.** Situazione → cosa fare → perché → card d'origine, in poche righe. Mai un segreto o un valore di
    configurazione sensibile. Si scrive solo ciò che vale oltre la card: una scelta valida per una card sola non è una lezione.
  - **Dove.** `memoria/<ruolo>/<repo>.md` per ciò che vale in un repo, `memoria/<ruolo>/comune.md` per ciò che vale
    ovunque, in questo repo, versionati.
  - **In prova, poi stabile.** Una lezione nuova vale subito, marcata `in prova`. Il mentore la porta in un'unica PR della
    memoria che si aggiorna; quando il titolare la unisce la lezione diventa stabile. All'avvio di una sessione lo
    smistatore dà al ruolo le lezioni stabili (develop) e quelle in prova (ramo della PR della memoria).
  - **Una lezione sbagliata si toglie.** Se un ruolo segue una lezione in prova e viene corretto di nuovo per quella, il
    mentore la rivede o la toglie.
  - **Precedenza.** Regole scritte (brief del ruolo, `CLAUDE.md` del repo, decisioni D, skill), poi lezioni stabili, poi
    lezioni in prova. Se una correzione contraddice una regola scritta, il mentore non scrive la lezione: segnala il
    conflitto con un commento sulla card e una nota nella PR della memoria, e decide il titolare se cambiare la regola.
  - **Prima un controllo, poi una lezione** (il titolare, 2026-11-25). Se l'errore corretto lo avrebbe trovato una macchina
    (compilatore, analizzatore, test, hook, pipeline), il mentore propone il controllo per lo stesso canale del conflitto
    e decide il titolare se farlo. La lezione si scrive comunque e si toglie quando il controllo esiste. Motivo: una lezione
    costa token a ogni sessione e può non essere seguita, un controllo no. Il mentore non scrive il controllo e non apre
    card: resta un ruolo che non tocca codice né board.
  - **Tetto.** Circa 25 lezioni per file: ogni sessione le rilegge e costano token. Oltre il tetto il mentore consolida:
    unisce i doppioni e propone di promuovere a regola (`CLAUDE.md` del repo o brief del ruolo) le lezioni confermate più
    volte, togliendole dalla memoria. Anche il consolidamento passa dalla PR della memoria.
  - **Misura.** Lo smistatore registra ogni blocco, on-hold e correzione con ruolo e motivo. La vista mostra l'andamento per
    ruolo settimana per settimana; la PR della memoria dice quali lezioni hanno evitato un blocco già visto.
- Perché: una persona impara dalle correzioni dei superiori; un agente che riparte da zero ripete lo stesso blocco e
  richiama il titolare per cose che gli sono già state spiegate. Che scriva un mentore e non chi ha sbagliato, che le lezioni
  stiano sotto le regole e che passino da una PR evita il rischio opposto: una regola sbagliata, scritta da un agente,
  seguita poi da tutti.
- Alternative scartate: l'agente scrive le proprie lezioni (generalizza dal proprio errore senza un occhio esterno); le
  lezioni nei repo di prodotto (sparse e soggette alle policy di ogni repo); stato locale non versionato (nessuna storia,
  nessuna revisione); lezioni lette solo dopo la conferma (fino al merge lo stesso errore si ripete); una lezione che
  vince sulla regola scritta (le regole diventerebbero inaffidabili); nessun tetto con filtro per pertinenza (il filtro
  può sbagliare e nascondere proprio la lezione che serviva).
- Dove: `src/Decisioni.psm1` (`Get-AzioniMentore`), `src/Smistatore.ps1` (`LanciaMentore`, chiusura dei mentori, registro),
  `src/Memoria.psm1` (formato, in prova/stabile, brief composto, riassunto), `src/MemoriaRepo.psm1` (lettura da git e ADO),
  `src/memoria.ps1` (il comando del mentore), `src/Sessioni.psm1` (brief con la memoria), `src/Stato.psm1`
  (`registro-apprendimento.jsonl`), `src/Vista.ps1`/`src/VistaHtml.psm1` (sezione Apprendimento), `src/VistaRitmo.psm1` (ogni quanto si leggono le
  lezioni in prova), `ruoli/mentore.md`.
  Scelte fatte costruendola:
  - gli inneschi: `decisione` solo se il responsabile ha sbloccato un dev `bloccato` o al `bivio`; il commento di una
    persona (anche dopo un on-hold tolto) conta solo negli stati in cui gli agenti portano la card, non in `nuova` e
    `daChiarire` (risposte di prodotto) ne dopo il merge; un on-hold tolto senza commento non lancia; una correzione,
    una chiave in `mentoriFatti`;
  - il ramo `memoria/in-prova` si serve solo con una PR attiva: una PR abbandonata vuol dire lezioni bocciate;
  - il mentore lavora in una cartella sua e legge il repo della card solo con `git -C` sui riferimenti remoti;
  - la ripresa di una sessione riusa il brief composto al primo lancio (la cache del prompt);
  - "blocco evitato": lezione applicata su una card diversa da quella d'origine, in una sessione non bloccata, senza
    blocchi, on-hold o correzioni dello stesso ruolo dopo;
  - il registro si chiama `registro-apprendimento.jsonl` (accanto a `registro-sessioni.jsonl`); il tetto e
    `tettoMemoria` in `config/limiti.json`.

**D47. Una validazione scaduta non è "in corso": lo smistatore la rilancia quando serve, cioè prima della revisione e al merge.**
- Chi e quando: Il titolare, 2026-11-20. Con la scadenza "subito" della policy su develop (decisa il 19/11), ogni merge in
  develop fa scadere le validazioni delle altre PR aperte. Azure DevOps le rimette in `queued` con `context.isExpired` e
  non le rilancia da solo. Lo smistatore le contava "in corso" e aspettava per sempre (PR 1019 della card 11: la vista
  diceva "in corso" e nessuno la riaccodava).
- Cosa:
  - `Get-AdoPr` dà `scaduta` a una valutazione di build con `isExpired`. Nel riassunto della PR prevalgono, in
    quest'ordine: in corso, rossa, scaduta, verde. Si aspetta chi gira; una rossa fa ripartire tutto col push di dev.
  - Lo smistatore rilancia le scadute (azione `RilanciaScadute`, `Start-AdoRivalutazione -Scadute`) solo dove la
    validazione serve per andare avanti: dopo dev, prima del reviewer (`Get-AzioniPr`), e in Ready to merge
    (`Get-AzioniDaUnire`). Non durante revisione, deploy e collaudo: develop cambia ancora e scadrebbero di nuovo,
    intasando l'agente interno.
  - In Ready to merge la PR si completa solo a validazione chiusa: con una scaduta si rilancia, con una in corso si aspetta.
  - È meccanica pura, come D38, ma senza il limite dei rilanci di D38: quello conta le rosse, che possono essere un test
    rotto; una scaduta non dice niente sul codice.
  - La vista mostra "scaduta (si rilancia al merge)".
- Alternative scartate: rilanciare appena scade (rifà le validazioni a ogni merge in develop, per card che sono ancora
  in collaudo); lasciarle a una persona o a un agente (gli agenti non hanno il PAT pieno, e non è una scelta).
- Dove: `src/Ado.psm1` (`Get-AdoPr`, `Start-AdoRivalutazione`), `src/Decisioni.psm1` (`Get-AzioniPr`,
  `Get-AzioniDaUnire`), `src/Smistatore.ps1` (`RilanciaScadute`), `src/VistaHtml.psm1`.

**D48. Una passata di sicurezza separata dalla revisione, solo quando il diff tocca qualcosa di sensibile.**
- Chi e quando: Il titolare, 2026-11-20. Il `reviewer` guarda correttezza, test che non provano niente, fuori standard e
  regole di sviluppo; di sicurezza controlla solo i segreti nei file committati. I repo su cui lavorano gli agenti
  espongono API con ruoli Keycloak, scrivono su SQL e, in Acme.AI, eseguono strumenti per conto dell'utente.
- Cosa:
  - **Un ruolo nuovo, `sicurezza`.** Claude Fable 5.2 (`claude-fable-5-2`), sforzo high, sola lettura come il
    `reviewer` (Read, Grep, Glob, PowerShell, Skill), brief in `ruoli/sicurezza.md`. Usa la skill `security-review` e
    guarda il diff della card con una domanda sola: chi può fare cosa che non dovrebbe, a partire da questo cambiamento.
  - **Perché Fable e non Opus** (il titolare, 2026-11-20). Fable costa il doppio a token di Opus 5.5 ($8/$40 contro
    $4/$20 per milione) ed è il modello più capace sul ragionamento difficile: trovare un abuso vuol dire mettere
    insieme pezzi lontani del codice dal punto di vista di chi attacca. La passata gira solo sulle card sensibili,
    quindi il doppio pesa su poche sessioni. Il `reviewer`, che gira su ogni card, resta su Opus: lo si sposta solo se
    il registro di D46 mostra difetti sfuggiti alla revisione.
  - **Rifiuti del modello.** Una revisione che parla di iniezioni e abusi può far scattare i filtri "cyber" del
    modello. Il brief dice che è la revisione difensiva del codice del proprio repo. Una sessione rifiutata o senza
    `ESITO` non vale `superata`: la card si ferma come per una sessione senza esito, con il motivo.
  - **Cosa cerca:**
    - autorizzazione: un endpoint senza il controllo del ruolo o dell'area, un controllo fatto lato client, un `AllowAnonymous`;
    - input esterni non validati: iniezioni SQL, di comando, di percorso; deserializzazione;
    - dati sensibili: segreti e token nei log, nelle risposte di errore, nei file committati;
    - configurazione: CORS, audience e client Keycloak, header di sicurezza, cookie;
    - dipendenze nuove o aggiornate con vulnerabilità note;
    - per gli strumenti che agiscono per l'utente (Acme.AI): che lo strumento non possa fare più di quanto l'utente
      può fare da sé.
  - **Quando parte.** Dopo che il `reviewer` ha dato `superata`, prima del deploy in Test, così rivede il codice che
    andrà in Test e non uno che cambia ancora. Parte se almeno una delle due cose è vera:
    - **il `reviewer` lo chiede.** Nel suo commento scrive una riga `Sicurezza: serve` o `Sicurezza: non serve`, con il
      perché; è un giudizio sul diff, non una lista;
    - **il diff tocca un percorso sensibile del repo.** Un elenco di glob per area in `config/mappa.json` (`sicurezza`):
      autenticazione, endpoint, accesso ai dati, configurazione, dipendenze. È solo la rete di sicurezza sotto il
      giudizio del `reviewer`: un diff che la tocca passa comunque dalla passata.
  - **Esito.** `ESITO=superata` o `ESITO=bloccante`, come il `reviewer`. Un rilievo è bloccante solo con un percorso
    concreto: chi, con quale richiesta, ottiene cosa. Un sospetto che non si concretizza si scrive come sospetto, non
    blocca. Con `bloccante` la card torna al `dev` con i rilievi, come per la revisione; il giro dopo la correzione rifà
    revisione e sicurezza.
  - **Lezioni (D46).** Un rilievo di sicurezza è una correzione: il mentore scrive la lezione per il `dev` e, se il
    difetto stava nel diff che il `reviewer` aveva dato per `non serve`, anche per il `reviewer`. Un difetto di
    sicurezza trovato dopo (in Test, in produzione, con un Bug) dà una lezione anche al ruolo `sicurezza`.
  - **Costo.** Una sessione Fable in più solo sulle card che toccano qualcosa di sensibile. La vista conta le passate
    e i rilievi, come per gli altri ruoli.
- Perché: una sezione di sicurezza dentro la revisione costerebbe meno ma diluirebbe l'attenzione di una revisione che
  fa già quattro controlli, e la sicurezza vuole una domanda diversa (chi può abusarne) da quella della correttezza (fa
  ciò che deve). Lanciarla su ogni card spenderebbe una sessione Fable anche sulle card che cambiano un'etichetta.
- Alternative scartate: una sezione "Sicurezza" nel brief del `reviewer` (attenzione diluita); la passata su ogni
  card (costo senza motivo); solo il filtro sui percorsi, senza giudizio (sbaglia sui casi che non ha previsto); solo il
  giudizio del `reviewer`, senza filtro (un `non serve` sbagliato lascia passare proprio il caso che conta).
- Dove: da costruire dopo D46, che tocca gli stessi file. `ruoli/sicurezza.md`, `ruoli/reviewer.md` (la riga
  `Sicurezza:`), `config/ruoli.json`, `config/mappa.json` (`sicurezza` per area), `src/Decisioni.psm1` (dopo
  `superata` del `reviewer`), `src/Smistatore.ps1`, `src/Vista.ps1`, e i test di ciascuno.

**D49. Una card riportata In development da uno stato successivo riparte, invece di restare ferma in silenzio.**
- Chi e quando: 2026-11-20, card 11. Il collaudatore si blocca; nella passata prima dell'on-hold (D42) il responsabile
  riporta la card In development e aggiunge il task #45 (allineare il ramo a develop). La passata non cambia l'ultimo
  ruolo, che resta `collaudatore`, e `Get-AzioniInSviluppo` lanciava il dev solo dopo un dev o un responsabile: la card
  e rimasta ferma, senza on-hold e senza una riga di log.
- Cosa: In development, con un ultimo ruolo diverso da `dev` e `responsabile` (la card torna da revisione, Test o
  collaudo, per mano del responsabile in una passata o di una persona):
  - se l'ultima sessione del responsabile e finita dopo quella dell'ultimo ruolo con `fatto`, parte il dev con motivo
    `decisione`, il commento del responsabile e il primo task aperto, come quando il responsabile risolve un bivio;
  - altrimenti, con un task aperto, parte il dev con motivo `taskAggiunto` sul primo task aperto;
  - altrimenti la card va in on-hold per `limite` con il motivo: niente fermo silenzioso.
- Dove: `src/Decisioni.psm1` (`Get-AzioniInSviluppo`), `tests/Decisioni.Tests.ps1` (casi 10f, 10g, 10h).

**D50. Una card ferma per una card precedente lo dice sulla card, e se la precedente aspetta una persona tocca all'operatore.**
- Chi e quando: Il titolare, 2026-11-20, dalla card 40: era in Ready to develop e lo smistatore non la faceva partire perché
  aspettava la #46, creata dal suo responsabile come prerequisito e quindi nata in Draft. Il motivo stava solo nel log e
  nelle catene in fondo alla pagina, dove non lo guardava nessuno.
- Cosa: nella vista una card ferma per predecessori (il motivo `predecessori` di Decisioni) mostra, al posto del motivo,
  un riquadro con una riga «aspetta la card #N» per ogni card precedente non ancora unita: link, stato sulla board
  come etichetta colorata per fase e, se serve una persona, il gesto. Serve una persona quando la precedente è in Draft («spostala in New»: le card create dagli agenti nascono lì),
  in New senza il tag agents («dalle il tag agents»: nessuno smistatore la prende) o rimossa («togli il link
  Predecessor»). In quei casi la card va nella colonna dell'operatore, fra quelle che fermano il flusso, con Sblocca;
  altrimenti resta nella coda del suo ruolo. Le catene delle card stanno in cima alla scheda Agenti, chiuse:
  si aprono al bisogno e sessionStorage ricorda se sono aperte.
- Dove: `src/Vista.ps1` (`Get-GestoPredecessore`, `Get-AttesePredecessori`, la kanban), `src/VistaHtml.psm1`
  (`Format-Aspetta`, le catene), `src/Ado.psm1` (`Get-AdoCardPredecessori` legge anche i tag).

**D51. Un supervisore controlla al posto del titolare e lo chiama solo per ciò che serve a lui; il limite di token diventa una pausa con ripresa.**
- Chi e quando: Il titolare, 2026-11-23, in un giro di domande. Il titolare controllava a mano vista, log, card ferme, PR e
  pipeline. Casi veri: la card 40 è in on-hold dal 20/11 perché la sessione del `reviewer` è finita su "You've hit your
  5-hour limit · resets 9pm", come la card 11 il 19/11. Bastava riprenderla dopo il reset, e invece ha aspettato lui. La
  card 9 è stata saltata 11 volte per un errore dello smistatore senza che nessuno lo sapesse. Ogni on-hold manda un
  Telegram, anche quando si scioglie da solo.
- Cosa, in tre parti:
  - **La quota nello smistatore, senza modello.**
    - Ogni sessione scrive nel suo jsonl dei `rate_limit_event` con l'uso delle finestre `five_hour` e `seven_day` e il
      loro `resetsAt`. A fine sessione lo smistatore ne tiene l'ultimo in `quota.json`, nella cartella dati.
    - Una sessione finita sul limite non è più una sessione fallita. Lo smistatore lo riconosce dall'evento con
      `status` `rejected` o dal testo "hit your … limit". Allora scrive in `quota.json` una pausa fino al `resetsAt`, più
      un margine, e tiene la sessione da riprendere. Niente on-hold e niente Telegram: solo una riga di log e un
      commento sulla card.
    - Durante la pausa nessuna sessione nuova parte, su nessuna card, perché la quota è una sola per tutti i ruoli. La
      vista lo dice con il motivo `quota`. Finita la pausa, la sessione interrotta riprende con `--resume`.
    - Vale per la finestra di 5 ore e per quella settimanale. Fra due pause vale la più lunga. Un ruolo in sola lettura
      che ha cambiato il worktree si ferma comunque come in D39, anche se poi ha trovato il limite.
    - **Riserva per il titolare.** Se l'ultimo `seven_day` letto supera `sogliaQuotaSettimanale` (`config/limiti.json`,
      partenza 0.70), le sessioni nuove non partono fino al reset settimanale. Quelle avviate finiscono il loro lavoro.
      Il valore si aggiorna solo quando finisce una sessione, quindi non vede le sessioni interattive del titolare: è
      una riserva, non un conto esatto.
    - **Integrazione del 2026-11-24: la soglia dalla vista.** Per sbloccare non serve più cambiare `limiti.json` nel repo.
      Dalla vista il titolare può alzare la soglia (tetto 0.95, minimo 0.05) e attivare un bypass che salta la sola riserva.
      Entrambi valgono fino al reset settimanale letto in quel momento (`sevenDay.resetsAt` di `quota.json`) e poi si
      torna da soli a `limiti.json`. La pausa dopo il limite di token non si salta: lì le sessioni fallirebbero comunque.
      L'override sta in `soglia-quota.json` nella cartella dati, non nel repo; se è scaduto, illeggibile o fuori range si
      ignora. Quando gli agenti sono fermi per la quota la vista mostra un banner a tutta larghezza con la causa, l'uso, la
      soglia e fino a quando, e i comandi accanto; la riga quota in testata c'è sempre. Il supervisore non apre
      `quota-riserva` con il bypass attivo.
  - **Tre on-hold che lo smistatore toglie da solo**, solo quando un dato dice che la causa non c'è più. Lo scrive nel
    commento sulla card, `[smistatore] tolgo l'on-hold: …`:
    - la sessione è finita sul limite di token e il reset è passato. Riguarda le card ferme da prima di D51, come la 40;
    - on-hold per validazioni rosse, e ora la validazione della PR è verde. Vale solo se l'on-hold è nato dalle rosse:
      `giriRevisione` e `giriCollaudo` sotto il loro limite, e `rosseDiFila` al limite oppure `rilanci` a 1 con l'ultima
      sessione di `dev` con esito `rilancia` (il secondo rilancio di D38). Un on-hold per troppi giri di revisione o di
      collaudo non si scioglie con la PR verde;
    - sessione chiusa per silenzio o morta senza risultato: alla prima volta per card non c'è proprio l'on-hold. Lo
      smistatore la riprende da solo nello stesso giro, con un commento senza menzione e senza Telegram, e segna la
      ripresa in `ripreseAutomatiche`. Dal secondo fermo (o con scritture D39) l'on-hold c'è, come prima. Questo caso non
      passa da `TogliAttesa`: lo fa `Close-Sessione`.

    Tolto così (limite e rosse), l'on-hold non vale come intervento di una persona: `passateFatte` (D42) non si svuota. Lo stato lo segna
    con `attesaToltaDaSmistatore`, che si cancella quando la card riparte (dove si azzera `inAttesaPer`: il lancio della
    sessione e `AzzeraContatori`); `ripreseAutomatiche` non si azzera, lo azzera solo una persona che toglie il tag.
    Lo stesso segno vale per la ripresa automatica di silenzio e morta, e la sessione riprende con un messaggio che dice
    che l'ha chiusa lo smistatore. Un on-hold di `Close-Sessione` lascia `causaAttesa` (silenzio, morta, fallita,
    scritture): nessuno si scioglie da solo, e l'on-hold del limite di prima di D51 si riconosce proprio dall'assenza di
    `causaAttesa`. Il deploy fallito
    no: lo sistema chi ha l'accesso, e togliere il tag rilancia il deploy (D32).
  - **Il supervisore, uno script senza modello in un'attività pianificata a parte** (`DevOps.Agents\Supervisore`,
    ogni 5 minuti, registrata con `-Pianificazione`). È a parte perché deve vedere anche uno smistatore che non gira.
    - **Cosa controlla:**
      - la salute dello smistatore e della vista: giro fermo da troppo, un errore a ogni giro, la stessa card saltata
        per errore N volte di fila, la vista che non risponde su :18799;
      - le card ferme: on-hold che aspettano il titolare da più di N ore, e card senza on-hold che non si muovono da più di
        N ore;
      - PR e pipeline: run in attesa di approvazione, deploy in Test falliti, validazioni in coda da troppo, agenti dei
        pool interni offline, run falliti per infrastruttura;
      - quota e PAT: pausa in corso, riserva raggiunta, PAT in scadenza o rifiutato.
    - **Cosa fa da solo:**
      - riavvia l'attività della vista se non risponde;
      - rilancia una volta un run fallito per infrastruttura, cioè agente perso o timeout LocalDB, riconosciuti dai testi
        in `config/supervisore.json`. Le validazioni delle PR delle card restano a D38.
    - **Cosa non fa mai:** non tocca deploy, merge, approvazioni o produzione; non riattiva un'attività disabilitata (può
      averla fermata il titolare); non spegne il PC; non usa `pat.txt` (lavora con il PAT dello smistatore); non aggira un
      diniego.
    - **Come chiama il titolare.** Il supervisore diventa l'unico che scrive su Telegram: lo smistatore smette di mandare
      un Telegram a ogni on-hold. Il commento con la menzione sulla card resta, e ogni on-hold lascia anche una riga nel
      log.
      - Subito: smistatore fermo, PAT rifiutato, run in attesa di approvazione, agente interno offline. Se è ancora
        aperto, si ricorda dopo 4 ore.
      - Il resto va in un riepilogo alle 8:30 e alle 14:00 dei giorni feriali, solo se c'è qualcosa. Un problema aperto
        torna una volta al giorno, con da quanto tempo aspetta.
      - Le card pronte da rilasciare in produzione sono una voce sola, «Rilasci in attesa», con una riga per area (quante card, i
        numeri, da quanti giorni aspetta la più vecchia). Il titolare, 2026-11-23: dieci voci «rilascia» ogni giorno erano rumore, ma
        alcune aree possono essere più urgenti di altre. Un'area oltre soglia (`rilasci.predefinito`, 5 card o 7 giorni, o
        `rilasci.perArea` per quell'area, in `config/supervisore.json`) è segnata «OLTRE SOGLIA» con il motivo e va in cima; non è un
        urgente. La voce torna quando entra una card nuova in rilascio, e ogni giorno solo se almeno un'area è oltre soglia.
      - Ogni voce dice l'azione esatta da fare e ha il link. Lo stato degli avvisi (primo visto, ultimo avviso) sta in
        `supervisore.json` nella cartella dati.
      - **Quattro topic, creati dal bot.** Il titolare, 2026-11-23: la chat è un gruppo con i topic, e il primo riepilogo vero non l'ha
        capito. I messaggi vanno in quattro topic, Urgenti, Riepilogo, Rilasci e Diagnosi, creati dal bot al primo invio (gli id
        stanno in `telegram-topic.json`, nella cartella dati). Sono per tipo di notifica e non per card perché il supervisore manda
        messaggi che raccolgono più card insieme o che non riguardano una card; il tipo corrisponde a come si leggono gli avvisi (gli
        urgenti con il suono, il riepilogo silenziato). I rilasci escono dal riepilogo e diventano un messaggio a sé nel topic
        Rilasci, con lo stesso ritmo di prima; ogni diagnosi è un messaggio nel topic Diagnosi appena è pronta. Al bot serve il
        permesso «Gestisci topic» nel gruppo: senza di esso (o se la chat non è un forum) tutto va nel topic generale, una voce del
        riepilogo lo dice una volta sola e la creazione si riprova solo dopo un'ora dall'ultimo tentativo. I messaggi sono in HTML,
        con i link corti e cliccabili.
    - **PC spento.** Uno smistatore che non gira perché il PC era spento non è un allarme: alla prima esecuzione dopo
      l'accensione parte il riepilogo di cosa è rimasto in sospeso. Lo spegnimento fra un giorno e l'altro e nel weekend
      lo decide il titolare dopo il primo periodo, con i dati di consumo.
    - **Il modello, solo per ciò che non sa classificare:** un errore dello smistatore che si ripete, un on-hold che non
      rientra in nessuna regola, un run fallito senza una causa riconosciuta.
      - Lancia una sessione del ruolo `supervisore` (`config/ruoli.json`, Sonnet per ora, configurabile; sola lettura,
        PAT in lettura come gli altri ruoli, brief `ruoli/supervisore.md`). Scrive la causa probabile e l'azione esatta,
        e il testo va nel riepilogo.
      - Una sola volta per problema, al più `diagnosiAlGiorno` (partenza 3), mai in pausa quota o oltre la riserva.
      - Non corregge niente: le modifiche a questo repo passano dal titolare (D1).
      - Per le card la diagnosi resta al `responsabile` (D42).
    - **Integrazione del 2026-11-24: l'on-hold nato da un bloccato.** Il titolare, 2026-11-24, card 56: il supervisore la
      dava come on-hold generico, "risolvi la causa e togli il tag". Ma togliere il tag riprendeva il collaudatore, che si
      è bloccato di nuovo: il deploy in Test non aveva installato la versione della card. Il responsabile aveva già
      scritto la causa e i passi, compreso "togliere l'on-hold solo dopo il passo 3".
      - La regola: se la sessione finita per ultima sulla card (per `fine` in `ultimaSessione`, o `inizio` se la sessione
        non ha `fine`) è del `collaudatore` o del `responsabile` con esito `bloccato`, l'on-hold non è generico. Vale
        qualunque sia `inAttesaPer`: dopo la passata del responsabile (D42) `ultimoRuolo` torna al ruolo di prima e non lo
        dice. Non vale se l'on-hold l'ha messo `Close-Sessione` (`causaAttesa` valorizzata: scritture, silenzio, morta,
        fallita): allora la causa è quella del suo commento, anche se la sessione ha scritto `ESITO=bloccato`.
      - La voce è `card-<id>-bloccato`. Il testo dice chi ha chiuso bloccato, l'azione è "fai i suoi passi e togli il tag
        solo dopo". Sotto ci sono le righe del suo resoconto, al più 12. Dal resoconto si tolgono i blocchi di codice
        recintati (log e stack non vanno su Telegram), i segni di titolo, citazione ed elenco, il grassetto e la riga
        ESITO. Il testo fra apici inversi resta intero, perché nomi di pipeline e parametri sono i passi. Il resoconto si
        legge da `stato.json`, senza leggere i commenti della card.
      - Se il resoconto è vuoto, la voce va alla diagnosi del modello, con la chiave `card-<id>-bloccato-senza-resoconto`:
        una diagnosi conservata di quella voce non si riattacca a una voce con il resoconto.
      - Scartata la diagnosi del modello per ogni on-hold da bloccato: rifarebbe con meno contesto il lavoro appena
        fatto dal responsabile e consumerebbe una delle diagnosi del giorno. Il prezzo è che, se il responsabile
        sbaglia, il supervisore ripete il suo errore.
- Perché: Il titolare vuole essere chiamato solo per ciò che serve a lui (accessi, scelte di prodotto, approvazioni,
  rilascio), con l'azione già scritta. Il limite di token è il fermo più frequente ed è pura meccanica. Uno smistatore che
  si controlla da solo non si accorge di essere fermo.
- Alternative scartate:
  - tutto dentro lo smistatore: se non gira, nessuno avvisa;
  - un ruolo con modello lanciato a intervalli: spende token anche quando va tutto bene;
  - solo avvisi, senza togliere on-hold: lascia ferme card la cui causa è già sparita. Qui si riprende per tre casi
    misurabili l'alternativa che D38 aveva scartato;
  - togliere anche l'on-hold del deploy fallito: la causa la sistema una persona;
  - tutto subito su Telegram, o solo un riepilogo: il primo fa rumore, il secondo ritarda le urgenze;
  - riprendere guardia.ps1 (spegnimento) adesso: si decide con i consumi del primo periodo.
- Dove: gruppo 1 costruito: `Get-EsitoSessione` (Quota, Limite) in `src/Sessioni.psm1`; `Get-Quota`/`Save-Quota` in
  `src/Stato.psm1`; `Close-Sessione` e `Save-QuotaSessione` in `src/Smistatore.ps1`; `New-ContestoGiro` in
  `src/Istantanea.ps1`; `Get-Decisione`, `Get-BloccoQuota` e `Format-MotivoCoda` in `src/Decisioni.psm1`;
  `sogliaQuotaSettimanale` e `margineQuotaMinuti` in `config/limiti.json`, validati da `src/Config.psm1`. Integrazione 2026-11-24: `Get-SogliaQuotaEffettiva` e `Get-RiepilogoQuota` in `src/Decisioni.psm1`, `Get-OverrideSogliaQuota` (la regola del comando) in `src/Decisioni.psm1`, `Get-SogliaQuota`/`Save-SogliaQuota` in `src/Stato.psm1`, `POST /soglia` in `src/VistaServer.psm1`, riga, banner e comandi in `src/VistaHtml.psm1`. Gruppo 2 costruito:
  `Get-AttesaSciolta` e `Test-OnHoldPerLimite` in `src/Decisioni.psm1` (chiamate dal ramo on-hold di `Get-Decisione`),
  `LimiteUltimaSessione` in `src/Istantanea.ps1`, `TogliAttesa`, `Set-InAttesa` (riga di log, `causaAttesa`) e
  `Close-Sessione` in `src/Smistatore.ps1`. Gruppo 3 costruito, senza la diagnosi con il modello: `src/Supervisore.ps1` (la raccolta e i gesti), `src/Supervisione.psm1` (i controlli, gli avvisi e lo stato), `config/supervisore.json`, `Get-RigaCoda` in `src/Istantanea.ps1` (la lettura delle card, in comune con la vista), `Get-AdoMotivoFallimento` e `Start-AdoRilancioRun` in `src/Ado.psm1`, `Format-RiepilogoTelegram` e `Send-TelegramRiepilogo` in `src/Telegram.psm1`, la registrazione in `setup/Install-Attrezzi.ps1`. Lo smistatore non scrive piu su Telegram. Gruppo 3b, la diagnosi con il modello: ruolo `supervisore` in `config/ruoli.json` e brief `ruoli/supervisore.md`; `Invoke-DiagnosiProblemi` in `src/Supervisore.ps1` (lancio con `Start-SessioneRuolo -Card 0` in `<dati>/diagnosi/<guid>`, esito con `Get-EsitoSessione`, quota con `Update-QuotaDaEsito` di `src/Stato.psm1`, la stessa funzione dello smistatore); `Get-DiagnosiDaLanciare`, `Resolve-StatoDiagnosi`, `Complete-Diagnosi`, `Register-DiagnosiLanciata` in `src/Supervisione.psm1`; la diagnosi sotto la voce in `Format-RiepilogoTelegram`. Dopo una sospensione del PC: `Test-SupervisoreContinuo` (niente falso urgente di smistatore fermo) e il riepilogo di ripartenza anche quando l'ultima esecuzione e piu vecchia di tre intervalli. Correzioni della revisione: il rilancio dei run e solo per le pipeline di `pipelineRilanciabili` (`config/supervisore.json`, vuoto di default), solo `develop`, solo l'ultimo run di quella definizione e ramo, con `sourceVersion` e `templateParameters` del run (`Get-AdoUltimoRun`, `Start-AdoRilancioRun`); il supervisore usa solo `pat-smistatore.txt` (senza, nessuna chiamata ad ADO e un urgente con il comando `-Pat`); la sessione di diagnosi e controllata come D39 (`Compare-ImprontaDiagnosi`: stato.json e quota.json se nessun giro dello smistatore e passato in mezzo, HEAD e `git status` della copia principale sempre; se e cambiato qualcosa la diagnosi si scarta e parte un urgente); le righe di log che il supervisore riconosce hanno i modelli in `src/Comune.psm1` (`Format-RigaLog`, `Get-RegexRigaLog`), usati da chi scrive e da chi legge; `Get-FaseSessione` e `New-RigaRegistro` stanno in `src/Sessioni.psm1`. Piano in `docs/superpowers/plans/2026-11-23-supervisore.md`.

**D52. In Test va una funzionalità intera, non ogni card: le card si uniscono nel ramo della funzionalità e una card di chiusura la porta in Test e in develop.**
- Chi e quando: Il titolare, 2026-11-23, in un giro di domande. Oggi ogni card fa il suo deploy in Test dal proprio ramo
  (con l'orchestratore del repo, come la pipeline 58 di Acme.Workflow), il suo collaudo e il suo merge in
  develop. Ogni card costa quindi un deploy, i minuti di pipeline e una sessione di collaudo, e una card intermedia di una
  catena porta in Test una funzionalità a metà, che non ha senso provare. Lo stesso giorno il deploy della card 11 ha
  aspettato un'ora l'unico slot dell'agente interno, occupato dalle pr-validation di Acme.AI. Con parole sue: le
  card sono pezzi della stessa funzionalità ed entrano tutte in un ramo `feat` o `bug`; alla fine si fa il collaudo
  automatico, seguito se serve da un collaudo umano.
- Cosa:
  - **La funzionalità è una Feature padre con una card di chiusura.**
    - Le card della funzionalità sono figlie della Feature (link Parent). Fra loro c'è la **card di chiusura**: una User
      Story con il tag `collaudo-funzionalita`, senza codice suo, i cui criteri sono quelli della funzionalità intera.
    - È una funzionalità D52 solo una Feature che ha una card di chiusura. Una Feature senza, come quella che lega card
      di repo diversi (spec, sezione 18), resta com'è, e le sue card seguono il flusso per card.
    - Una funzionalità sta in un repo solo. `card crea -Tipo Feature` crea la Feature e la sua card di chiusura;
      `card crea -Feature <id>` crea una card figlia e rifiuta un'area diversa da quella della Feature o una Feature
      già in develop (Resolved o Closed). Il lavoro nuovo su una funzionalità già unita è una funzionalità nuova o una
      card isolata.
    - Tutte nascono in Draft come oggi; la card di chiusura la sposta in New il titolare, insieme alle altre.
  - **La vista Features.** Il titolare controlla la funzionalità anche dall'alto, dal backlog Features di Azure DevOps (già
    acceso in Acme.Workflow ed Acme.AI), che mostra ogni Feature con le sue card. Perché lo stato della
    Feature dica il vero lo aggiorna lo smistatore, con gli stati standard del tipo, senza cambiare il processo:
    - Active quando la prima card entra in sviluppo;
    - Resolved quando la funzionalità è unita in develop;
    - Closed quando la card di chiusura è chiusa.
  - **Il ramo della funzionalità.**
    - Il nome è `feature/f<id Feature>-<titolo>`, oppure `bugfix/f<id Feature>-<titolo>` se la Feature nasce con il tag
      `bug`. Sono i prefissi che `scripts/Calculate-Version.ps1` dei repo di prodotto conosce già (alpha per il deploy in
      Test) e da cui `Get-TitoloPr` ricava già `feat:` e `fix:`; la `f` davanti all'id distingue il ramo della funzionalità
      da quello di una card (`feature/<id card>-…`). Il prefisso si fissa alla creazione del ramo, e il ramo si cerca per
      id, come quello delle card: rinominare la Feature o cambiarle i tag a lavoro avviato non crea un secondo ramo.
    - Lo crea lo smistatore da `origin/develop` e lo pubblica quando la prima card della funzionalità entra in sviluppo,
      se su origin non c'è ancora. Se un altro smistatore l'ha pubblicato nel frattempo, il push rifiutato non è un
      errore: si usa quello.
    - Nel ramo della funzionalità si entra solo con una PR, mai con un push diretto.
  - **Le card della funzionalità.**
    - Il worktree della card parte da `origin/<ramo della funzionalità>`, mai da un ramo locale. La PR punta lì invece
      che a develop.
    - Fino alla revisione il percorso è quello di oggi, tranne la pr-validation: dev, `reviewer`, la passata di
      sicurezza quando serve (D48). `dev` allinea il ramo della card al ramo della funzionalità (D16), e `reviewer`
      guarda il diff rispetto al ramo della funzionalità, quindi la sola card e non le sorelle già unite.
    - **Niente pr-validation verso il ramo della funzionalità** (il titolare, 2026-11-23). La policy resta solo su develop
      e main. Il codice della funzionalità passa comunque dalla CI almeno due volte: nel deploy in Test dal ramo della
      funzionalità e nella pr-validation della PR verso develop. Senza build la PR della card risulta unibile per D13,
      e i test li ha già fatti girare `dev` nel worktree.
    - Poi la card salta il Test e va in Ready to merge, dove lo smistatore completa la PR verso il ramo della
      funzionalità. Non la completa mentre la card di chiusura è fra Deploying to test e Ready to merge: il ramo in prova
      non cambia sotto il collaudo.
    - Completata la PR, la card passa nello stato nuovo **In feature branch** (il suo lavoro è nel ramo della
      funzionalità, non ancora in develop) e il worktree si toglie.
    - Quando la card di chiusura arriva in Ready to release, ogni smistatore porta le sue card In feature branch della
      stessa Feature in Ready to release (D18: ciascuno muove solo le card del suo utente).
  - **Predecessori.**
    - In feature branch vale come «unita» solo per una sorella della stessa Feature: solo lei parte dal ramo che
      contiene quel lavoro.
    - Per una card di un'altra funzionalità, o per una card isolata, unita vuol dire in develop, come oggi. Lo stesso
      vale per una card della funzionalità che dipende da una card isolata: aspetta che la isolata sia in develop e che
      develop sia entrato nel ramo della funzionalità, cosa che succede solo alla chiusura. Una dipendenza così di solito
      dice che le due card andavano nella stessa funzionalità.
  - **Cosa fa scattare la fine.**
    - La card di chiusura usa come precedenti tutte le sue sorelle sotto la Feature, tranne le Removed, senza link
      Predecessor messi a mano. Passa da `Get-PredecessoriInAttesa` come ogni card ferma per predecessori, e la vista lo
      mostra come in D50: una sorella in Draft o in New senza il tag agents ha i gesti di D50.
    - Così la card di chiusura è davvero l'ultima anche quando una card si aggiunge a metà lavoro.
    - Se una sorella non unita compare dopo che la card di chiusura è partita, la card di chiusura torna in Ready to
      develop, da qualunque stato fino a Ready to merge. Lo smistatore lo decide prima delle azioni dello stato.
    - Il vincolo vero però è sul commit: la PR verso develop si completa solo se la testa del ramo della funzionalità è
      il commit deployato in Test, cioè la `sourceVersion` del run uguale all'ultimo commit sorgente della PR. Se il ramo
      è cambiato, la card di chiusura torna in Ready to develop e rifà deploy e collaudo. Questo vale anche quando la
      card è rimasta ferma, per esempio in Human test o in on-hold, mentre una sorella entrava nel ramo.
    - Una card di chiusura senza sorelle non parte.
    - Una card di chiusura rimasta in Draft con tutte le sorelle In feature branch è una card ferma per una persona. Nessuno
      smistatore la legge (le card in Draft non sono fra le card attive), quindi lo dice una sorella In feature branch, con il motivo
      `chiusuraInBozza` di Decisioni e il gesto «sposta la card #<chiusura> in New». La vista mette la card di chiusura, una volta
      sola, nella colonna dell'operatore con quel gesto, e il supervisore ne fa una voce per la persona.
  - **Il percorso della card di chiusura.** Ferma in New finché tutte le sorelle non sono unite. Poi:
    - il `responsabile` legge la Feature e i suoi criteri e sceglie i parametri del deploy (D43), letti dallo YAML del
      ramo della funzionalità. Può mettere `human-test` o `no-test-deploy` (D27);
    - in Ready to develop lo smistatore apre la PR ramo della funzionalità → develop, senza worktree;
    - con la validazione verde la card va in Deploying to test senza `dev` né `reviewer`: il codice è già stato rivisto
      card per card;
    - con la PR in conflitto con develop lo smistatore crea una Bug tecnica sorella, con il tag `allinea-develop` (variante
      del piano, 2026-11-24: la prima stesura voleva un ramo proprio della card di chiusura e una seconda PR, ma una card con
      due PR rompe «una card, un ramo, una PR» su cui stanno lo stato locale, l'istantanea e la vista). Il suo `dev` parte
      da un ramo nato dal ramo della funzionalità, ci unisce `origin/develop` (D16), scrive i file in conflitto e apre la
      PR verso il ramo della funzionalità. Il `reviewer` di una card con quel tag guarda solo la risoluzione del merge
      (`git show --remerge-diff`), non le modifiche di develop. La card di chiusura aspetta la Bug come una sorella non
      unita e poi rifà deploy e collaudo. Una sola Bug `allinea-develop` alla volta;
    - il deploy in Test parte dal ramo della funzionalità con l'orchestratore, come oggi. Resta una funzionalità alla
      volta per componente in Test (`cardInTestPerComponente`), contata sulle card di chiusura;
    - il `collaudatore` (D28) prova i criteri della funzionalità e legge quelli delle sorelle come contesto. Con
      `human-test`, superato il collaudo automatico, prova una persona in Human test. Per la card di chiusura le due prove
      sono in fila, non in alternativa come per una card isolata;
    - superate le prove, con il vincolo sul commit rispettato, la PR verso develop si completa da sola (D26). La card va
      in Ready to release, e la Feature in Resolved.
  - **Collaudo fallito**, del `collaudatore` o della persona in Human test. Vale lo stesso per una build o dei test
    falliti nella CI del deploy in Test, o per la pr-validation rossa della PR verso develop: sono il primo punto in
    cui girano sul codice della funzionalità, e il resoconto per il `responsabile` sono gli errori estratti come in
    D14. Un deploy fallito per l'ambiente, con la build riuscita, resta un on-hold come oggi.
    - Il `responsabile` della card di chiusura legge il resoconto e scrive la correzione con un comando nuovo di
      `card.ps1`. Oggi nessun ruolo può creare card: la Bug, figlia della Feature, la crea lo smistatore con quel testo.
    - Il `responsabile` dice anche se il difetto è tecnico o nasce da una scelta di prodotto (il titolare, 2026-11-23):
      - tecnico: la Bug nasce in New con il tag `agents` e parte da sola;
      - scelta di prodotto: la Bug nasce in Draft con la menzione al titolare e aspetta lui. La distinzione è la stessa con cui il
        `responsabile` decide già cosa chiedere al titolare.
    - Per la card di chiusura la Bug è una sorella non unita, quindi torna in Ready to develop e aspetta. Quando la Bug è
      In feature branch, la card di chiusura rifà deploy e collaudo. Il limite `giriCollaudo` conta sulla card di
      chiusura.
  - **Card isolate.** Una card senza Feature padre, o figlia di una Feature senza card di chiusura, segue il flusso di
    oggi senza cambiamenti: ramo da develop, deploy, collaudo, merge. Costa un deploy, quanto una funzionalità di una
    card sola, senza il work item e la PR in più.
  - **Cosa cambia nel codice attuale.**
    - Il limite di una card alla volta in Test conta solo le card di chiusura e le card isolate.
    - Il deploy dall'orchestratore resta, con il ramo della funzionalità al posto del ramo della card.
    - D47 vale solo per la PR della funzionalità verso develop, tale e quale: le PR delle card non hanno validazioni
      che scadono.
    - Il merge di develop nel ramo della card (D16) diventa il merge del ramo della funzionalità. Develop entra nella
      funzionalità solo alla chiusura.
  - **Le altre voci.** D16, D26, D28 e D29, la tabella «Chi fa cosa» e la spec (sezioni 4, 5 e 18) descrivono il flusso
    per card. Restano valide per le card isolate: ciascuna lo dice e rimanda qui per le card di una funzionalità. L'ultimo
    gruppo della costruzione le ha corrette, come chiede la regola di questo registro.
- Risparmio e costo, per una funzionalità di N card:
  - deploy in Test e sessioni del `collaudatore`: da N a 1, più uno per ogni collaudo respinto. Con N = 4 sono tre deploy
    e tre collaudi in meno, e tre attese in meno per lo slot dell'agente interno;
  - pr-validation: 1 invece di N, più i rilanci di D47 sulla sola PR della funzionalità. Calano anche le validazioni
    scadute nelle altre PR aperte, perché develop cambia una volta per funzionalità invece che una per card. È il carico
    che il 23/11 occupava l'agente interno;
  - un test rotto da una card si scopre nella CI del deploy, non sulla sua PR: la correzione è una card Bug, e le
    sorelle unite dopo di lei ci hanno già costruito sopra;
  - un difetto che una card intermedia avrebbe mostrato in Test si scopre alla fine. Correggerlo costa una card Bug e
    un altro giro di deploy e collaudo;
  - develop entra nella funzionalità solo alla chiusura: più a lungo dura la funzionalità, più conflitti si accumulano,
    e `dev` li risolve in una volta sola (D16);
  - mentre la funzionalità è in prova, le sorelle pronte aspettano in Ready to merge;
  - il collaudo prova la funzionalità intera, non i criteri di ciascuna card. Quelli delle card li verificano i test e
    la revisione.
- Perché: si prova in Test ciò che ha senso provare, cioè una funzionalità finita, e si paga un deploy per funzionalità
  invece che per card. Il legame con la Feature padre fa sì che la card di chiusura sia sempre l'ultima senza che
  nessuno debba ricordarsi un link. Il vincolo sul commit fa sì che in develop entri solo ciò che è stato provato.
- Alternative scartate:
  - la Feature che scorre la board da sola, senza card di chiusura: vuole gli stati di Test sul tipo Feature, cioè un
    cambio al processo. La Feature resta visibile dal backlog Features, con gli stati standard aggiornati dallo
    smistatore;
  - solo predecessori, senza Feature: un tag comune e una card di collaudo con i link Predecessor verso ogni card. Una
    card aggiunta dopo va collegata a mano, e se nessuno lo fa il collaudo parte senza di lei;
  - un tag sulla card che fa scattare il deploy (la prima proposta del titolare): è un gesto in più da ricordare, e può
    scattare prima che l'ultima card sia unita;
  - la correzione di un collaudo respinto come task della card di chiusura, scritta direttamente sul ramo della
    funzionalità: non avrebbe una sua PR né una revisione circoscritta;
  - i conflitti con develop risolti su un ramo proprio della card di chiusura, con una seconda PR (la prima stesura di
    D52): la card di chiusura avrebbe due PR, e `ramo`, `prId`, `Get-IstantaneaCard` e la vista ne assumono una. La Bug
    `allinea-develop` usa la strada della correzione, che c'è già;
  - la pr-validation anche sulle PR delle card verso il ramo della funzionalità, con una policy su `feature/f*` e
    `bugfix/f*`: troverebbe un test rotto sulla card che lo rompe, ma rifà per ogni card una CI che gira comunque al
    deploy e verso develop (il titolare, 2026-11-23);
  - allineare il ramo della funzionalità a develop a ogni merge in develop: rifà le validazioni di tutte le card aperte,
    lo stesso costo che D47 evita;
  - le card unite nel ramo della funzionalità lasciate in Ready to merge, o chiuse: la prima confonde «da completare»
    con «già nel ramo», la seconda le toglie dalla board prima che il lavoro sia in develop;
  - accorgersi di una sorella nuova solo dallo stato: la card di chiusura ferma in Human test o in on-hold non la vede
    entrare nel ramo. Il vincolo sul commit la vede.
- Già fatto (2026-11-23, su richiesta del titolare): lo stato **In feature branch** nel processo `Custom.Agile` (lo usa
  solo il progetto DevOps.Agents), per User Story e Bug, categoria In progress, fra Ready to merge e Ready to
  release, con la sua colonna sulla board Stories.
- Fuori da D52: le funzionalità su più repo, perché il collaudo congiunto non è disegnato.
- Dove, costruito in sei gruppi, con i test di ciascuno. Piano in `docs/superpowers/plans/2026-11-23-collaudo-funzionalita.md`:
  - `config/limiti.json`: `funzionalitaAttive` (l'interruttore: spento, `card crea -Tipo Feature` e `-Feature` si rifiutano e
    nessuna card risulta della funzionalità), validato da `src/Config.psm1`. `config/stati.json`: `inFeature`, `tagChiusura`,
    `tagBugFeature`, `tagAllinea` e gli stati della Feature (`featureNuova`, `featureAttiva`, `featureRisolta`, `featureChiusa`,
    `featureRimossa`);
  - `src/Ado.psm1`: `PadreId` (con `Get-IdPadre`) letto con la card e con i predecessori; `Get-AdoFeature`, `Get-AdoFigliFeature`
    (le figlie, anche in un lotto solo con `-FigliIds`), `Set-AdoStatoFeature`; `-Destinazione` in `Get-AdoPr`, `New-AdoPr` e
    `Get-AdoPrDelRamo`; `Get-AdoRamoCard -FeatureId` (il ramo della funzionalità cercato per id via REST); la `sourceVersion` del
    run; `New-AdoCard -Padre`; `Get-AdoErroriBuild -SoloCodice`;
  - `src/Comune.psm1`: `Get-StatiConRamo` con In feature branch; `Get-DestinazioneCard`; i nomi dei rami della funzionalità
    (`Get-RegexRamoFunzionalita` e le altre); `Get-ComposizioneFunzionalita` (la chiusura e le sorelle, la definizione sola);
    le marche dei commenti della correzione e delle Bug create (`ConvertTo-TestoCommentoCorrezione`, `Get-CorrezioniScritte`,
    `ConvertTo-TestoCommentoBugCreata`, `Get-BugCreate`);
  - `src/Card.psm1` e `src/card.ps1`: `crea -Tipo Feature [-Bug]` (con la card di chiusura), `crea -Feature` con i controlli su area
    e stato; `card.ps1 correzione` (`Add-CardCorrezione`) e `card.ps1 prova-umana` (`Set-CardProvaUmana`) per il `responsabile`;
    `New-CardCorrezioneFunzionalita` e `New-CardAllineaDevelop` (le Bug dello smistatore, con `New-BugDellaFunzionalita`);
    `Get-AdoRamoCard` e `Set-CardDeploy` leggono lo YAML dal ramo della funzionalità per la card di chiusura;
  - `src/Worktree.psm1`: `Get-NomeRamoFunzionalita`, `Find-RamoFunzionalita`, `Publish-RamoFunzionalita`; `New-WorktreeCard -Base`
    con `-B` da `origin/<base>`; `Remove-WorktreeCard -Destinazione`; `Update-WorktreeChiusura`;
  - `src/Istantanea.ps1`: `Get-FunzionalitaCard` (la domanda «questa card è della funzionalità?» ha qui una risposta sola; una
    lettura per Feature per giro), `Get-ErroriBuildChiusura`, `New-FunzionalitaVista`; `Get-RigaCoda` porta la funzionalità e
    `AspettaFunzionalita`;
  - `src/Decisioni.psm1`: `Get-PercorsoCard`, `Test-CardFunzionalita`, `Test-CardChiusura`, `Test-SorellaUnita`,
    `Get-SorelleNonUnite`; `Test-PredecessoreUnito` e `Get-PredecessoriInAttesa` con `$FeatureId`; i blocchi (`Get-BloccoPartenza`,
    `Get-BloccoInFeature`, `Get-BloccoCollaudoFunzionalita`, `Get-BloccoCiChiusura`) e i loro motivi in `Format-MotivoCoda`
    (`senzaSorelle`, `attesaCollaudoFunzionalita`, `conflittiFunzionalita`, `ciRossaFunzionalita`, `inFeatureSenzaPrUnita`,
    `funzionalitaPerduta`, `funzionalitaIllegibile`, `chiusuraInBozza`); `Get-AzioniProntoChiusura`, `Get-AzioniInFeature`, il ritorno in Ready to
    develop, `Get-AzioneBloccoChiusura`, `Get-CorrezioneDaFare`, `Get-AzioneFeatureRisolta`, il vincolo sul commit in
    `Get-AzioniDaUnire`;
  - `src/Smistatore.ps1`: `CreaRamoFunzionalita`, `AggiornaFeature`, `CreaCorrezione`, `CreaAllineaDevelop`, `ImpostaRamoChiusura`,
    `AzzeraCiRosse`, `CreaWorktree` e `ApriPr` con base e destinazione, `Close-FeatureConcluse` (la Feature Closed);
  - `ruoli/responsabile.md`, `ruoli/collaudatore.md`, `ruoli/dev.md`, `ruoli/reviewer.md`;
  - `src/Supervisione.psm1`: una card In feature branch non è «ferma senza on-hold» (`AspettaFunzionalita` della riga: la chiusura in
    Draft, New o Ready to develop ha i suoi motivi, e senza un motivo resta segnalabile); la card di chiusura in Draft con le sorelle
    unite è una voce per la persona (`chiusura-<id>-bozza`, una per card di chiusura); in «Rilasci in attesa» una funzionalità è una
    voce sola, con il numero delle sue card e il link della Feature, e conta una volta per la soglia dell'area, mentre il testo conta le
    card vere e dice le voci. `src/Supervisore.ps1` porta il link alla Feature nella riga, `src/Telegram.psm1` conta le card vere;
  - `src/Vista.ps1` e `src/VistaHtml.psm1`: la sezione «Funzionalita» (`Get-FunzionalitaVista`, `Format-Funzionalita`), con la Feature,
    la card di chiusura e il suo stato, le sorelle e dove sta ciascuna; la card di chiusura in Draft fra le cose da fare dell'operatore, con
    il gesto del motivo `chiusuraInBozza` (`Get-BloccoChiusuraInBozza` in `src/Decisioni.psm1`, detto da una sorella In feature branch);
    le catene con `Test-PredecessoreUnito` e la Feature di ciascuna card dipendente. I motivi si leggono da `Get-Decisione`, la vista non
    li ricalcola. `docs/vista-esempio.html` rigenerata.
- Differenze fra il piano e ciò che è costruito:
  - niente `Get-AdoFeaturePadre`: il padre arriva come `PadreId`, letto con la card e con i suoi predecessori (le relazioni sono già
    nella stessa lettura); la Feature e le figlie si leggono una volta per giro per Feature (`Get-AdoFeature`, `Get-AdoFigliFeature`);
  - il ramo della funzionalità si legge via REST (`Get-AdoRamoCard -FeatureId`, nel repo della card), non con git sulla copia principale;
  - l'interruttore `funzionalitaAttive` in `config/limiti.json`, previsto dal piano per i gruppi 2-3, è rimasto: il gruppo 5 lo ha
    acceso, e a `false` D52 non fa niente (nemmeno una chiusura taggata a mano la accende);
  - la card di chiusura non ha un worktree suo: usa uno in sola lettura, detached su `origin/<ramo della funzionalità>`, riportato
    all'ultimo commit a ogni lancio (`Update-WorktreeChiusura`);
  - `card.ps1 prova-umana` (il `responsabile` mette `human-test` con il motivo sulla card) e `card.ps1 correzione` sono comandi nuovi;
  - le Bug create dallo smistatore portano nel commento sulla card la marca `[smistatore]` con la chiave della correzione o del
    commit, e quel commento è ciò che impedisce di crearle due volte;
  - la Bug `allinea-develop` nasce in Ready to develop, non in New: ha già i criteri e il `responsabile` non serve;
  - la card di chiusura con la CI rossa fa lavorare il `responsabile` al più `rosseDiFila` volte di fila (`ciRosseDiFila`, azzerato dalla
    CI verde), poi on-hold;
  - la vista mostra le funzionalità in una sezione a sé («Funzionalita», sopra la kanban), non raggruppando le schede dentro le
    colonne: ogni card sta in un posto solo della kanban e la sezione dice dove;
  - la card di chiusura in Draft non ha mai una riga (`Get-AdoCardAttive` scarta le Draft, e la legge nessuno): il motivo
    `chiusuraInBozza` lo dice una sorella In feature branch, e la vista e il supervisore mostrano la chiusura una volta sola;
  - una sorella è una figlia di tipo User Story o Bug (`Get-ComposizioneFunzionalita`): un Task o un altro tipo sotto la Feature non è
    una card che la chiusura aspetta;
  - se le figlie lette sono meno di quelle che la Feature elenca (la lettura a lotto omette quelle che non si leggono), la funzionalità non
    si legge: `funzionalitaIllegibile`, e le sue card aspettano, perché una chiusura senza una figlia partirebbe senza di lei. Vale anche
    per una card figlia di una Feature senza card di chiusura, se la Feature o le figlie non si leggono: si ferma con
    `funzionalitaIllegibile` e riparte appena si legge, perché da isolata partirebbe dal ramo sbagliato;
  - il costo per giro è di tre chiamate per Feature, per ognuno dei tre processi (smistatore, vista, supervisore): la Feature, le figlie in
    un lotto e il ramo della funzionalità (REST, una per Feature e per giro, anche se non c'è). Il padre di una card si legge una volta per giro
    anche quando non è una Feature (il risultato «non è una Feature» sta nella stessa cache). `Get-AdoCard` chiede `$expand=relations` per
    avere il padre, senza una chiamata in più per card.

**D53. La suite si aggiorna da sola, senza mai lasciare un collega con una suite rotta o a metà.**
- Chi e quando: Il titolare, 2026-11-25. Un collega che ha installato la suite (smistatore, vista, supervisore, hook, skill) deve
  ricevere le versioni nuove senza fare niente e vedere a che versione è. Oggi la suite gira dalla copia principale
  `C:\develop\GIT\DevOps.Agents` (attività pianificate, giunzioni delle skill e hook puntano lì) e si aggiorna solo con un
  `git pull` a mano.
- Cosa:
  - **Il canale.** I colleghi seguono `main`, il titolare `develop`. Il canale sta in `impostazioni.json` (sotto). Se non è impostato vale
    il ramo già estratto nella copia, se è `main` o `develop`, altrimenti `main`. Promuovere `develop` su `main` resta un gesto di
    Il titolare: PR con merge, non squash (così le PR entrate si leggono dai messaggi dei commit).
  - **La copia non si tocca a mano e si avanza solo in fast-forward.** Si porta la copia a `origin/<canale>` solo se HEAD è antenato di
    quel commit (`git merge-base --is-ancestor`); se la copia è avanti o divergente non si fa niente e lo si dice. Se il ramo estratto
    non è il canale e il passaggio è un fast-forward, si passa al ramo del canale (`git checkout -B <canale> origin/<canale>`, solo in
    quel caso). Mai un reset di lavoro non committato: con modifiche locali (`git status --porcelain` non vuoto, anche file non
    tracciati) non si aggiorna, salvo la migrazione sotto.
  - **Impostazioni locali fuori dal repo.** `impostazioni.json` nella cartella dati (`Get-CartellaDati`, che rispetta `ATTREZZI_DATI`):
    `canale`, `aggiornamentoAutomatico` (predefinito vero) e gli override di `limiti` e `supervisore` (chiavi di primo livello di
    `config/limiti.json` e `config/supervisore.json`). `Get-Config` e `Get-ConfigSupervisore` applicano gli override sopra i file del
    repo e li validano con le stesse regole: un override invalido o una chiave che il file non ha è un errore chiaro. Così la copia
    resta pulita. **Migrazione:** se le uniche modifiche locali sono in `config/limiti.json` e/o `config/supervisore.json`,
    l'aggiornamento copia in `impostazioni.json` le chiavi di primo livello che differiscono dalla versione di HEAD (senza
    sovrascrivere un override già presente), poi ripristina il file (`git checkout -- <file>`) e prosegue. Caso reale: Il titolare ha
    `sogliaQuotaSettimanale` 0.85 a mano in `config/limiti.json` (nel repo è 0.70): dopo la migrazione vale ancora 0.85 e il file è
    pulito. **La migrazione è definitiva**: se poi l'aggiornamento torna indietro il file resta ripristinato, perché la versione a cui
    si torna ha già D53 e legge `impostazioni.json`. La scrittura di `impostazioni.json` (la vista per l'interruttore, il supervisore per
    la migrazione) è una lettura-modifica-scrittura sotto un mutex con nome. L'override della soglia dalla vista (`soglia-quota.json`,
    D51) resta com'è e prevale ancora, fino al reset.
  - **Chi aggiorna: il supervisore** (`src/Supervisore.ps1`, ogni 5 minuti, senza modelli). Controlla origin ogni
    `minutiControlloAggiornamenti` (30) con `git fetch`; aggiorna se c'è un commit nuovo e l'automatico è acceso, oppure se la vista ha
    scritto una richiesta «aggiorna adesso» (`aggiorna-suite.richiesta`, cartella dati), anche con l'automatico spento. Aggiorna
    **solo quando non ci sono sessioni in corso** (le card con il campo `sessione` in `stato.json`, la stessa definizione della vista,
    `Get-IdCardConSessione`; i mentori vivi in `stato.json`; le sessioni di diagnosi del supervisore in `supervisore.json`) e nessun
    processo dello smistatore della stessa radice sta girando. Durante l'aggiornamento disabilita
    l'attività `\DevOps.Agents\Smistatore` e la riabilita in un `finally` (solo se l'ha disabilitata lui: una disabilitata da una
    persona resta com'è); dopo averla disabilitata ricontrolla sessioni e processi, perché un giro poteva partire nel mezzo. Resta
    disabilitata per tutta la verifica e il ritorno indietro: `Install-Attrezzi.ps1 -Pianificazione` conserva lo stato disabilitato di
    un'attività già registrata (registrarla con `-Force` la rifaceva abilitata), quindi nessun giro vero parte sul codice non verificato. Se
    l'attesa supera `oreAttesaAggiornamento` (6) lo dice la vista e una volta Telegram, senza forzare.
  - **Requisiti.** `config/requisiti.json` ha le versioni minime di Claude Code, PowerShell e `az`. Prima di aggiornare si legge il file
    **della versione nuova** (`git show origin/<canale>:config/requisiti.json`; se manca, nessun requisito): se qualcosa è più vecchio
    non si aggiorna e si dice cosa manca e quale versione serve. Un requisito che la versione in esecuzione non sa misurare non blocca.
    Oggi sono Claude Code (2.1, trovato con `Get-EseguibileClaude` come lo trovano le sessioni) e PowerShell (7.4); `az` non c'è: serve
    solo durante l'installazione dei PAT.
  - **Dopo l'avanzamento** si rilancia `setup/Install-Attrezzi.ps1 -Regole -Hook -Pianificazione` (mai `-Pat`, con la radice a barre in
    avanti: gli hook si confrontano senza badare a barre e maiuscole, e non si duplicano) e un giro di prova a vuoto di
    `src/Smistatore.ps1 -WhatIf` e di `src/Supervisore.ps1 -WhatIf`, come processi figli `pwsh -NoProfile -File` della copia aggiornata,
    ciascuno con un timeout. Con `-WhatIf` un giro che si interrompe esce con un codice diverso da 0 (senza, il codice resta 0): è ciò
    che fa vedere alla verifica un errore a runtime. Il supervisore di prova non scrive niente e non aggiorna.
    Se uno fallisce (codice di uscita diverso da 0 o timeout) si torna al commit di prima (`git reset --keep`, la copia era pulita),
    si rilancia l'installazione della versione di prima, si segna il commit come scartato (non si riprova finché origin non va oltre,
    ma una richiesta esplicita «Aggiorna adesso» lo riprova) e si segnala. Se anche il ritorno indietro fallisce l'esito è `errore` con
    «copia lasciata a <hash>», mai `aggiornato`, e parte un avviso urgente. Il ramo del canale che il passaggio aveva spostato
    (`checkout -B`) torna dov'era; e se il ramo locale con il nome del canale ha commit che origin non ha l'aggiornamento non parte
    (`ramoCanaleDivergente`), perché li perderebbe. La vista si riavvia da sola quando cambia il codice (`VistaCodice`).
  - **Stato.** `aggiornamento.json` nella cartella dati: versione installata (canale, hash corto, data del commit), versione
    disponibile, ultimo controllo, ultimo esito (`aggiornato`, `daAggiornare`, `inAttesaSessioni` con da quando,
    `fallitoTornatoIndietro` con errore e commit scartato, `requisitiMancanti` con l'elenco, `modificheLocali` con i file,
    `copiaAvanti`, `divergente`, `ramoCanaleDivergente`, `errore`) e le PR in arrivo (`git log HEAD..origin/<canale> --first-parent`, dai messaggi
    «Merged PR n: titolo» e «Merge pull request n from ramo»: numero e titolo, nella seconda forma il ramo).
  - **La vista.** Un riquadro «Suite» nella scheda Agenti: versione installata e disponibile, ultimo controllo, stato, PR in arrivo
    (con il link alla PR), il pulsante «Aggiorna adesso» e l'interruttore «Aggiornamento automatico». Due comandi nuovi nel server
    (`src/VistaServer.psm1`), con lo schema e la sicurezza degli altri: `POST /aggiorna-suite` (scrive la richiesta e avvia
    subito l'attività del supervisore) e `POST /automatico?attivo=0|1` (scrive `aggiornamentoAutomatico` in `impostazioni.json`). La
    vista non aggiorna: legge `aggiornamento.json` e, per l'interruttore, `impostazioni.json`.
  - **Telegram.** Un messaggio a ogni aggiornamento riuscito (da quale a quale versione, le PR entrate), a ogni fallimento con
    ritorno indietro e, una volta, all'attesa oltre soglia, nel topic nuovo `aggiornamenti`.
  - **Installazione.** La skill `installa-attrezzi` mette i colleghi nuovi sul ramo `main` e non dice più di fare `git pull`: spiega
    dove si vede la versione e come cambiare canale. Il README spiega l'aggiornamento automatico, il canale e `impostazioni.json`.
- Perché: un collega non deve né ricordarsi di fare `git pull` né ritrovarsi con una suite a metà. Per questo si aggiorna solo a copia
  pulita, in fast-forward, a sessioni ferme, e si verifica (installazione e giro di prova) prima di dichiarare riuscito: se la
  verifica non passa si torna indietro da soli. Le impostazioni personali fuori dal repo sono ciò che permette alla copia di restare
  pulita.
- Alternative scartate: far fare il `pull` alla vista (la vista è di sola lettura e muore a ogni cambio di codice); un aggiornamento
  anche con sessioni in corso (una sessione che cambia gli script a metà lavoro è una sessione rotta); `reset --hard` su una copia
  sporca (perde il lavoro di chi l'ha toccata: meglio fermarsi e dirlo).
- Dove: `src/Aggiornamento.psm1` (regole pure e I/O), `src/Impostazioni.psm1`, `src/Config.psm1` e `src/Supervisione.psm1`
  (override), `src/Supervisore.ps1`, `src/Comune.psm1` (`Get-ProcessiSmistatoreRadice`), `src/Stato.psm1` (`Get-IdCardConSessione`),
  `src/Telegram.psm1`, `src/VistaServer.psm1`, `src/VistaHtml.psm1`, `src/VistaSuite.psm1` (le frasi e gli allarmi del riquadro), `src/Vista.ps1`, `setup/Install-Attrezzi.ps1` (gli intervalli
  con gli override), `config/requisiti.json`, `config/supervisore.json`, la skill `installa-attrezzi` e il README. Test:
  `tests/Aggiornamento.Tests.ps1`, `tests/Impostazioni.Tests.ps1` e le aggiunte a `Config`, `Supervisione`, `SupervisoreGiro`,
  `Telegram`, `VistaServer`, `Vista`, `Comune`, `Stato`.
- Non coperto: una pipeline vera su una macchina vera (le attività pianificate si provano con mock, git con repo temporanei), e cosa
  fa `Install-Attrezzi.ps1` della versione nuova oltre al suo codice di uscita.

**D54. Regole su come si scrive un test, in `regole-sviluppo`: deterministico, isolato, il costoso preparato una volta, al livello più basso che basta.**
- Chi e quando: Il titolare, 2026-11-25.
- Perché: il TDD obbligatorio dice quando scrivere un test ma non come. Con D24 il `dev` era passato a Opus perché i test di
  Stime erano lenti e instabili; il problema stava in un punto che le regole non coprivano, e un modello più grande non è
  la risposta giusta a una regola mancante. Con le regole scritte si può riprovare `dev` su Sonnet e confrontare.
- Cosa: le quattro regole sopra; `dev` riporta la durata del run accanto al conteggio e giustifica un test nuovo che dura più di
  qualche secondo; `reviewer` tratta la violazione come le altre di `regole-sviluppo`.
- Dove: `regole/SKILL.md` (sezione «Come si scrive un test»), rimando in `ruoli/dev.md`.

**D55. `responsabile` e `dev` hanno Fable come advisor, e lo consultano prima di chiudere.**
- Chi e quando: Il titolare, 2026-11-25. Il piano Max include Fable.
- Perché: `responsabile` sbaglia nel punto più costoso (D24) e ha sessioni brevi, quindi una consultazione costa poco
  anche a tariffa Fable. A `dev` serve un parere sul lavoro finito visto da chi userà il prodotto, che i test non danno.
  Un advisor deve valere almeno quanto il modello della sessione: su Opus le scelte sono Opus o Fable, e un Opus che
  consiglia un Opus aggiunge poco.
- Cosa: campo `advisor` per ruolo in `config/ruoli.json`, passato a `claude -p` come `--advisor`; il ruolo senza campo
  parte senza. L'effort dell'advisor non si imposta (né Claude Code né l'API lo prevedono). Non c'è un modo di forzare
  la consultazione a macchina: la regola sta nel brief («Il secondo parere» in `ruoli/responsabile.md` e
  `ruoli/dev.md`). Il parere non è un riferimento per il registro e non risolve un bivio di prodotto.
- Da verificare: il consumo nel registro dopo qualche card; se `dev` torna su Sonnet (D54) l'advisor può restare Fable
  o scendere a Opus.
- Dove: `config/ruoli.json`, `src/Sessioni.psm1` (`Get-ArgomentiClaude`), i due brief.

**D56. `dev` e `responsabile` scrivono la descrizione della PR con `card.ps1 descrizione-pr`.**
- Chi e quando: Il titolare, 2026-11-26. La card 111 chiede misure e passi dopo il merge nella descrizione della PR, ma lo
  smistatore apre la PR col solo link alla card e `card.ps1` non aveva un comando per cambiarla.
- Cosa: `card.ps1 descrizione-pr -File <markdown>` trova la PR attiva della card dai suoi link (come `titolo-pr`, mai da
  un id dato da fuori), tiene la riga col link alla card che lo smistatore mette in testa e ci mette sotto il testo del
  file. Il file si legge in UTF-8 e la scrittura passa dalla REST (`Set-AdoDescrizionePr`), perché `az` da PowerShell
  tronca le righe multiple e perde gli accenti. Il tetto di 4000 caratteri vale con link e firma: un testo più lungo si
  rifiuta, non si tronca. Si può riscrivere: ogni volta sostituisce il testo precedente.
- Perché un file e non stdin: la descrizione è lunga e con tabelle, e `crea -File` funziona già così.
- Dove: `src/Card.psm1` (`Set-CardDescrizionePr`), `src/card.ps1`, `ruoli/dev.md`, `ruoli/responsabile.md`.

**D58. `descrizione-pr` funziona anche prima che la PR esista: il testo aspetta in un commento.**
- Chi e quando: Il titolare, 2026-11-26, scelta del responsabile della card 111. La PR la apre lo smistatore dopo il `fatto`
  di `dev`, quindi durante il lavoro `dev` non ha una PR su cui scrivere (D56).
- Cosa: senza una PR attiva `card.ps1 descrizione-pr` salva il testo in un commento della card con la marca
  «Descrizione della PR:», come `deploy`; vale l'ultimo di `dev` o `responsabile`. `ApriPr` lo rilegge e lo mette sotto
  il link alla card. Con la PR già aperta il comando scrive direttamente, come in D56.
- Tetto: il comando controlla subito che il testo ci stia (con un link alla card di lunghezza media); se all'apertura
  non ci sta lo stesso, la PR si apre col solo link e lo smistatore lo scrive nel log.
- Dove: `src/Card.psm1` (`Set-CardDescrizionePr`), `src/Comune.psm1` (`Get-DescrizionePrSalvata`), `src/Smistatore.ps1` (`ApriPr`).

**D57. Ogni on-hold dice al titolare cosa fare, perché e perché non l'hanno fatto gli agenti.**
- Chi e quando: Il titolare, 2026-11-26. La card 86 era in on-hold `limite` dopo il secondo `rilancia` (D38). Il gesto
  ("rilancia la validazione del gateway sulla PR 1146, poi togli l'on-hold") era sepolto nella diagnosi lunga del
  responsabile, e non era chiaro che la 74 aspettasse proprio la 86. Il titolare ha riportato la card in Draft e poi in New:
  togliendo l'on-hold lo smistatore l'avrebbe trattata come nuova, con PR e ramo già aperti.
- Cosa:
  - Il gesto lo scrive il ruolo che ha visto la causa, di solito il responsabile nella passata D42. Con `ESITO=bloccato`
    il suo commento e il testo finale cominciano con `Per il titolare:` (il gesto, in ordine, con i nomi veri), `Perché:` e
    `Perché non gli agenti:` (il permesso, la regola o l'accesso che manca, per esempio D38 e D51). Sono righe sole,
    prima della diagnosi.
  - `Set-InAttesa` legge queste righe dall'ultima sessione e chiude il commento di on-hold con la sezione **Cosa fare**:
    1) il gesto, 2) togliere l'on-hold, con l'effetto che dipende da `inAttesaPer` (`sessione`, `limite`, `deploy`), poi
    il perché, il perché non gli agenti e l'avviso di non riportare la card in Draft o in New. Senza le righe del ruolo,
    o per un on-hold di `Close-Sessione` (causaAttesa), vale un testo predefinito per inAttesaPer e causa. Le
    indicazioni restano nello stato della card (`indicazioniAttesa`).
  - Il supervisore mette il gesto come azione della voce Telegram e il resto come righe, con le card che la aspettano.
    Un bloccato con resoconto ma senza le righe del ruolo resta al resoconto, che dice più del testo predefinito.
  - La vista mostra il riquadro "Cosa fare" sulla card in on-hold. Una card che aspetta una predecessora in on-hold
    mostra, sotto "Aspetta la card #86", il gesto di quella, e va fra le card da sbloccare.
- Perché: un on-hold è un gesto per una persona. Se il gesto non è la prima cosa che si legge, la persona fa altro, e
  spostare la card di stato fa perdere allo smistatore il filo della PR. Dire perché gli agenti non l'hanno fatto evita
  di chiedersi se basti aspettare. Il supervisore continua a non rilanciare le validazioni delle PR delle card (D38/D51).
- Alternativa scartata: riassumere la diagnosi con un modello nello smistatore o nel supervisore, che sono senza modello.
  Il gesto lo sa chi ha letto i log.
- Dove: `src/CosaFare.psm1`, `src/Smistatore.ps1` (`Set-InAttesa`), `src/Istantanea.ps1` (`Get-RigaCoda`,
  `Get-PredecessoriCard`), `src/Supervisione.psm1` (`Get-ProblemiCard`), `src/Vista.ps1` (`Get-GestoPredecessore`),
  `src/VistaHtml.psm1`, `ruoli/responsabile.md` ("Quando serve una persona").

**D59. In Test va solo `develop`; una card si collauda nel suo ambiente Docker, costruito dal ramo e poi buttato via.**
- Chi e quando: Il titolare, 2026-11-26.
- Perché: con un solo ambiente di Test per componente (D26, D34) le card si bloccavano a vicenda (la card 56 di
  Acme.AI ferma in coda dietro la 59 in on-hold) o si sovrascrivevano la build (la 55 e la 56). Un ambiente per card
  toglie il posto da contendere; Test torna a essere lo specchio di `develop`.
- Cosa:
  - Un componente con la voce `collaudo` in `config/mappa.json` non fa più deploy in Test: in Deploying to test lo
    smistatore crea l'ambiente con `docker compose` dal worktree della card (progetto `card-<id>`, etichetta
    `acme.collaudo`), con le porte di uno slot libero. Lo stesso per la card di chiusura di una funzionalità (D52),
    dal ramo della funzionalità. Il componente senza `collaudo` resta col giro di prima (deploy del ramo in Test, un posto per
    componente) finché il suo repo non ha l'ambiente.
  - Il contratto col repo prodotto: un file compose per componente, indicato dalla mappa, che costruisce le immagini dal
    sorgente del ramo, crea il database dagli schemi con i seed del repo, avvia un Keycloak con realm e utenti di prova, e
    si considera pronto quando `docker compose up --wait` torna. Le porte, gli utenti di prova e i segreti arrivano come
    variabili d'ambiente; nel repo nessun segreto né password.
  - Gli URL dell'ambiente vanno in un commento sulla card e al collaudatore al posto di `urlTest`; per `human-test`
    l'ambiente resta su finché la card è in Human test.
  - L'ambiente si butta (`docker compose down -v`) quando la card lascia Automated test e Human test per qualunque
    stato, o si chiude. A ogni giro lo smistatore butta anche i progetti `acme.collaudo` di card che non sono più in
    collaudo (orfani).
  - Limite: `ambientiCollaudo` in `config/limiti.json` (3) al posto di `cardInTestPerComponente` per i componenti con
    `collaudo`. Oltre il limite la card aspetta in In review, senza on-hold.
  - Dati: schema e seed del repo, mai copie del database di Test. Servizi esterni: Keycloak è locale e muore con
    l'ambiente; Models.Api e gli altri servizi esterni sono quelli di Test.
  - Segreti per l'ambiente (chiavi dei servizi esterni, password degli utenti di prova): `~/.claude/collaudo/<repo>.json`,
    fuori da ogni repo, lo stesso file da cui il collaudatore riceve `COLLAUDO_*`.
  - Docker (Engine, senza Docker Desktop) gira per ora in WSL2 sulla macchina degli agenti (distro Ubuntu-26.04). Il
    comando che lo raggiunge (`comandoDocker`, con `{cartella}` = cartella Windows del worktree), l'host e la porta base
    stanno in `config/collaudo.json`: per spostarlo su un server si cambia il comando (per esempio
    `docker --context server`), senza toccare il codice. `wsl.exe` non passa le variabili di Windows alla distro: le
    `COLLAUDO_*` viaggiano con `WSLENV`, solo nel processo figlio. Il compose si indica con un percorso relativo alla cartella.
    La distro resta accesa grazie all'operazione pianificata di Windows "WSL Ubuntu sempre acceso" (all'accesso,
    `wsl.exe -d Ubuntu-26.04 --exec sleep infinity`): senza, WSL spegne la distro e con lei gli ambienti.
  - `develop` in Test per ora lo porta il titolare a mano; l'orchestratore di Acme.AI rifiuta in Test i rami che non
    sono `develop`. Automatizzarlo dopo ogni merge è rimandato: rischio di troppe CI e pipeline.
- Alternative scartate: VM Linux dedicata subito (serve una macchina; si migra dopo); copia del database di Test (dati
  pesanti e potenzialmente sensibili sul PC); Keycloak di Test (un redirect URI da registrare per ogni ambiente).
- Cambia: D26 e D34 (il limite per componente vale solo per i componenti senza `collaudo`), D28 (il collaudatore prova
  l'ambiente della card, non Test).
- Dove: `config/mappa.json` (la voce `collaudo`: `compose`, `porte`, `url`; non ancora nelle voci vere), `config/collaudo.json`,
  `config/limiti.json` (`ambientiCollaudo`), `src/Decisioni.psm1` (`Test-AmbienteCollaudo`, `Get-BloccoLimiteTest`,
  `Get-AzioniInDeployTest`, `Get-AzioneButtaAmbiente`, `Get-SlotCollaudoLibero`), `src/Istantanea.ps1`
  (`Add-CardAlContestoTest`, l'esito dell'ambiente nel `Run`), `src/Smistatore.ps1` (`CreaAmbienteCollaudo`,
  `ButtaAmbienteCollaudo`, `Remove-AmbientiOrfani`), `src/Collaudo.psm1` e `src/Collaudo-Crea.ps1` (il punto unico `Invoke-Docker`, il
  processo staccato), `hooks/deny-host-collaudo.ps1`, `src/Card.psm1` (`deploy` e `leggi` su un componente con `collaudo`), `ruoli/collaudatore.md`, `ruoli/responsabile.md`; nei repo prodotto la cartella `collaudo/` e
  l'orchestratore.

**D60. Le card stanno in una Feature; le Feature hanno una priorità e si mettono in pausa; anche il sistema intero; la finestra di 5 ore ha la sua soglia.**
- Chi e quando: Il titolare, 2026-11-26. Il lavoro va concentrato sui preventivi, e per farlo oggi l'unico modo era fermare
  lo smistatore disabilitando l'attività pianificata. Il limite settimanale non basta: la finestra di 5 ore si consumava
  troppo in fretta.
- Ogni card nuova sta in una Feature. `card crea` senza `-Feature` si rifiuta. Una card in New senza una Feature aperta
  come padre lo smistatore non la fa partire (motivo `senzaFeature`, lo dice la vista). Le card senza Feature già oltre New
  finiscono il loro giro. Una Feature senza card di chiusura (`card crea -Tipo Feature -Raggruppa`) serve solo a
  raggruppare: le sue card vanno in `develop` una per una e possono stare in repo diversi. Con la card di chiusura resta
  una funzionalità D52, in un'area sola.
- La priorità è l'ordine del backlog delle Feature in Azure DevOps (`Microsoft.VSTS.Common.StackRank`), lo stesso che
  cambia trascinando una riga del backlog. Non il campo Priority, che va da 1 a 4. Lo smistatore guarda le card nell'ordine
  delle loro Feature (`Get-OrdineCard`), così un posto libero (sessioni, repo, Test) va alla card della Feature più in alto.
  Le Feature mai ordinate vengono dopo, per id; dentro la stessa Feature le card vanno per id. Si leggono solo le Feature
  delle aree della mappa: quelle di altri gruppi del progetto non si mostrano e non si riordinano.
- Nella vista la sezione Funzionalità ha una scheda per ogni Feature aperta, in ordine di priorità. Una scheda si trascina
  (POST `/ordine?id=&dopo=`): se tutte le Feature hanno un rank si scrive solo quella spostata, a metà fra le vicine;
  altrimenti si rinumerano 1000, 2000, ... e si scrivono solo quelle che cambiano (`Get-RankRiordino`).
- La pausa di una Feature è il tag `paused` (`tagPausa`), che vale anche su una card sola. Una card in pausa non lancia
  sessioni e non si sposta: la sessione in corso finisce, poi la card resta ferma finché il tag c'è. Non tiene il posto
  in sviluppo del suo repo; in Test sì, perché l'ambiente resta occupato. Non si riusa `on-hold`: toglierlo vuol dire "una
  persona ha sbloccato la card" e azzera le passate (D42, D51). Ogni scheda della vista ha il pulsante pausa/riprendi
  (POST `/pausa?id=&attiva=`). Se le Feature non si leggono il giro si ferma: senza, una Feature in pausa ripartirebbe.
- Il sistema intero si mette in pausa dalla testata della vista (POST `/pausa-sistema?attivo=`, `pausaSistema` in
  `impostazioni.json`). Lo smistatore gira ancora e chiude le sessioni che finiscono, ma non lancia niente e non sposta
  card. Disabilitare l'attività pianificata lasciava le sessioni finite senza esito fino alla ripresa.
- La finestra di 5 ore ha una soglia sua, `sogliaQuota5Ore` in `config/limiti.json` (partenza 60%). Oltre la soglia non
  parte nessuna sessione nuova fino al reset della finestra (motivo `quota`, causa `cinqueOre`). Ignorare la riserva
  settimanale non la salta. Dalla vista la si alza fino al reset della finestra (`soglia5Ore`, `fino5Ore` in
  `soglia-quota.json`). Il supervisore non la segnala: è un freno voluto, che passa da solo a ogni reset.
- La vista risponde fra un disegno e l'altro: mentre rilegge Azure DevOps (40-50 secondi) una richiesta può cadere e il
  browser dice "Failed to fetch", anche se il comando era arrivato. I pulsanti ora riprovano da soli (5 volte, ogni 10 s).
- Dove: `src/Decisioni.psm1` (`Get-FermoPriorita`, `Test-CardInPausa`, `Get-OrdineCard`, `Get-RankRiordino`,
  `Get-Soglia5OreEffettiva`, `Get-BloccoQuota`), `src/Ado.psm1` (`Get-AdoFeatureAperte`, `Set-AdoRank`),
  `src/Smistatore.ps1`, `src/Istantanea.ps1`, `src/Supervisore.ps1`, `src/Card.psm1`, `src/card.ps1`,
  `src/Impostazioni.psm1`, `src/Vista.ps1`, `src/VistaServer.psm1`, `src/VistaHtml.psm1`, `config/stati.json`,
  `config/limiti.json`.
