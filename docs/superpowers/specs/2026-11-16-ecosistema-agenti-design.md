# Ecosistema di agenti per lo sviluppo: disegno

Data: 2026-11-16. Stato: bozza da rivedere, terza stesura.

Su Azure DevOps esistono già il progetto `DevOps.Agents`, con un repo vuoto dello stesso nome, e il processo
`Custom.Agile`, ereditato da Agile e predefinito dell'organizzazione. Gli stati sono ancora quelli di partenza. Il
resto è da costruire.

Questo file sta fuori da git finché il repo degli attrezzi (sezione 3) non ha il suo primo commit: lì va spostato.

## 1. Scopo

Una richiesta di sviluppo, scritta come card su una board di Azure DevOps, viene portata da agenti fino alla verifica
in Test da parte di chi l'ha chiesta, e da lì in produzione. Il titolare interviene solo per dare il via ai tre passaggi
che sono suoi: deploy in Test, merge, rilascio in produzione.

Il disegno è riuscito se valgono quattro cose:

1. Una card scritta bene arriva in Test senza domande: l'unico gesto del titolare è il via al deploy.
2. Il sistema a riposo non consuma token.
3. Ogni card riporta quanti token e quanti minuti di agente è costata.
4. Il codice prodotto rispetta le stesse regole in ogni repo, e la revisione le verifica con un esito scritto.

## 2. Vincoli

| Vincolo | Conseguenza nel disegno |
|---|---|
| Il traffico è limitato | Lo smistatore è uno script senza modelli. Ogni ruolo usa il modello adatto al suo lavoro. Il consumo si misura per card. |
| Chi sviluppa non decide | `dev` si ferma sui bivi. Decide `responsabile` se la scelta si giustifica con codice o dati esistenti, altrimenti il richiedente. |
| Si lavora in un worktree da `origin/develop` | Ogni card ha il suo worktree in `C:\develop\GIT\_wt\<repo>\<slug>`. Nessun agente scrive nella working copy principale. |
| Tutti i test girano, nessuno saltato | La validazione della PR è il giudice. Un test che non può girare fa fallire il run. |
| I segreti non entrano nei repo | PAT e token del bot stanno nel profilo utente. Gli agenti non li vedono. |
| Lo sviluppo lo avvia chi scrive la card | Portare la card in New è il via. Vale per chiunque abbia accesso al progetto. |
| Deploy in Test, merge e rilascio in produzione li avvia il titolare | Ognuno parte da un suo gesto esplicito: spostare una card o dare un comando su Telegram. Li esegue lo smistatore; le sessioni dei modelli non hanno gli strumenti per farlo. |

## 3. Componenti

| Componente | Cos'è | Dove sta |
|---|---|---|
| Board | Progetto Azure DevOps dedicato, con una board unica per tutti i prodotti | Org `acme`, progetto `DevOps.Agents` |
| Repo degli attrezzi | Smistatore, script `card`, brief dei ruoli, fonte delle regole, mappa da area a repo, questa spec | Repo `DevOps.Agents` dello stesso progetto |
| Smistatore | Script PowerShell senza modelli, pianificato e lanciabile a mano | PC del titolare, perché deve lanciare Claude Code |
| Agenti | Sessioni `claude -p` lanciate dallo smistatore, senza connettori | PC del titolare, nel worktree della card |
| Telegram | Un gruppo privato per richiedente, con lui e il bot, argomenti attivi | Gestito dallo smistatore |
| Registro delle sessioni | Una riga per sessione di agente | File locale accanto allo smistatore, fuori da git |

## 4. Board

Il progetto usa il processo `Custom.Agile`. I progetti esistenti restano sul processo Agile di sistema e non
cambiano; quelli creati da ora in poi nascono con questi stati, perché il processo è il predefinito.

Le card sono di tre tipi. User Story e Bug seguono lo stesso percorso: il tipo serve solo a tenere traccia della
natura del lavoro, una richiesta nuova o un difetto. Il terzo tipo, `Release`, è la card di rilascio di un prodotto
(sezione 10) e va aggiunto al processo nella fase 5. Il tipo `Task` di Azure DevOps non si usa: sta un livello sotto
la User Story e non compare come card sulla board.

Stati di User Story e Bug, nell'ordine delle colonne (`Active` e `Resolved` sono nascosti):

| Stato | Significato | Chi ci porta la card |
|---|---|---|
| Draft | Card in scrittura. Gli agenti la ignorano | Chi la crea |
| New | Richiesta completa: è il via allo sviluppo | Chi l'ha scritta |
| Needs clarification | `responsabile` ha domande per il richiedente | `responsabile` |
| Ready to develop | Criteri chiari, lo sviluppo parte | `responsabile`, oppure il richiedente |
| In development | Un `dev` ci sta lavorando | Smistatore |
| In review | Validazione verde, `reviewer` al lavoro | Smistatore |
| Deploying to test | Revisione superata: lo smistatore accoda il deploy in Test e ne aspetta l'esito | Smistatore |
| Automated test | Deploy riuscito: prova il collaudatore (sezione 20) | Smistatore |
| Human test | Deploy riuscito e tag `human-test`: prova la persona che ha chiesto la card | Smistatore |
| Ready to merge | Provata (dal collaudatore o dal richiedente), in attesa del merge | Smistatore (da Automated test) o `responsabile` (da Human test) |
| In feature branch | Una card di una funzionalità (D52): il suo lavoro è nel ramo della funzionalità, non ancora in `develop` | Smistatore (da Ready to merge) |
| Ready to release | Unita a `develop`, in attesa del rilascio in produzione. Una card della funzionalità ci arriva da In feature branch, quando la card di chiusura è unita | Smistatore |
| Releasing | Rilascio in produzione in corso | Smistatore |
| Closed | In produzione | Smistatore |

In feature branch è degli stati di una funzionalità (D52, sezione 18): vale solo per le card figlie di una Feature con una card di
chiusura. Una card di una funzionalità non passa dal Test: da Ready to merge lo smistatore completa la sua PR nel ramo della
funzionalità e la porta In feature branch; Ready to release la raggiunge insieme alla card di chiusura. Le card isolate non usano
questo stato.

I nomi di stati, colonne, tag e area sulla board sono in inglese per scelta del proprietario.

Il richiedente di una card è chi l'ha creata.

Lo stato Draft deve essere quello in cui nasce una card. `<DA VERIFICARE: che un processo ereditato permetta uno stato
iniziale diverso da New>`. Se Azure DevOps crea comunque le card in New, i nomi si scambiano: New fa da bozza e lo
stato che fa partire gli agenti si chiama `Richiesta`.

Needs clarification è un passaggio facoltativo. Se `responsabile` legge la card e non ha domande, la porta direttamente in
Ready to develop e lo sviluppo parte. Se ha domande la porta in Needs clarification; quando il richiedente ha risposto e non resta
niente di aperto, la porta in Ready to develop. Il richiedente può anche chiudere le domande spostando lui la card in Ready to develop:
`responsabile` procede allora con le ipotesi che aveva proposto e le registra come accettate dal richiedente.

Deploy in Test e merge in `develop` vanno da soli, senza gesti del titolare. A revisione superata lo smistatore porta la
card da In review a Deploying to test (se il componente non ha già un'altra card in uno dei tre stati di Test: in quel
caso la card aspetta In review) e accoda il deploy; a deploy riuscito la porta in Automated test, o in Human test se ha il
tag `human-test`. Cosa portare in Test lo sceglie il `responsabile` (D43): con `card.ps1 deploy` scrive sulla card i
parametri della pipeline di deploy e il perché, fra i booleani dello YAML il cui nome comincia con `deploy`; vale l'ultimo
commento di deploy. Lo smistatore rilegge la scelta, verifica i nomi sullo YAML del ramo della card e accoda la run con
tutti quei parametri a `true`. Senza scelta, o con un nome che lo YAML non ha più, non fa il deploy: l'attesa passa dal
`responsabile` (D42), che scrive la scelta, e la card riparte. In Human test la prova è del richiedente: quando commenta, `responsabile` porta la card in Ready to merge se
ha confermato (OK esplicito), oppure in In development con un task nuovo se servono modifiche; in dubbio fa una domanda e
la card resta in Human test. In Ready to merge lo smistatore completa la PR verso `develop` e porta la card in Ready to
release. Resta manuale un solo gesto del titolare, uno spostamento di colonna con un comando Telegram equivalente
(sezione 9):

| Gesto | Da | A | Cosa fa partire |
|---|---|---|---|
| Via al rilascio in produzione | Card di rilascio in Ready to release | Releasing | Il rilascio del prodotto (sezione 10) |

Una card spostata a mano in uno di questi stati funziona come se ci fosse arrivata da sola: in Ready to merge lo
smistatore completa la PR anche se la prova in Test è stata saltata.

Altre regole della board:

- Gli agenti toccano solo le card con il tag `agents`. Senza tag la card è lavoro di una persona.
- Il tag `on-hold` segna una card ferma: lo smistatore non lancia nulla finché c'è.
- Prima di mettere una card in `on-hold` per una persona passa il `responsabile` (D42), una volta per tipo di attesa
  finché una persona non toglie un `on-hold`. Se sistema la causa la card riparte da sola, altrimenti si ferma con la sua diagnosi scritta sulla card. Restano dritte
  in `on-hold` le attese nate da una sessione del `responsabile`, i fermi di sicurezza (un ruolo in sola lettura che
  cambia il worktree), le chiusure di sessioni silenziose o fallite e l'attesa del richiedente in Human test.
- L'area della card indica prodotto e repo. La corrispondenza sta in un file del repo degli attrezzi, con il
  componente e la pipeline di deploy dell'orchestratore. I parametri del deploy li sceglie il `responsabile` per ogni
  card (D43).
- Gli agenti scrivono con il PAT del titolare. Ogni commento comincia con `[ruolo]` e finisce con la riga di
  attribuzione a Claude.
- Due campi aggiunti al processo: `Total tokens` e `Agent minutes`.

## 5. Smistatore

Lo smistatore fa un giro alla volta: legge lo stato delle card con il tag `agents`, delle loro PR e dei messaggi
Telegram, e reagisce secondo la tabella. Non contiene modelli: se non c'è nulla da fare non spende niente.

Parte in due modi. Un'operazione pianificata lo lancia a intervalli (predefinito: 2 minuti). Il titolare può lanciarlo a
mano quando vuole, per tutte le card o per una sola. Gli eventi di Azure DevOps, come "card creata", richiedono un
indirizzo raggiungibile dal cloud e il PC non lo è: per questo lo smistatore interroga invece di essere chiamato.

| Evento | Azione |
|---|---|
| Card in Draft | Nessuna |
| Card in New | Lancia `responsabile`: verifica i criteri. Senza domande porta la card in Ready to develop, altrimenti in Needs clarification con le domande |
| Commento nuovo di una persona su una card in Needs clarification | Lancia `responsabile`: aggiorna i criteri. Se non resta niente di aperto porta la card in Ready to develop |
| Card in Ready to develop | Crea il worktree, porta la card in In development, lancia `dev` |
| `dev` ha finito e ha pubblicato il ramo | Apre la PR verso `develop` |
| `dev` si è fermato su un bivio | Lancia `responsabile` con il bivio: decide lui, oppure porta la card in Needs clarification con la domanda |
| Validazione della PR rossa | Lancia `dev` con il log dell'errore |
| Validazione della PR verde | Porta la card in In review, lancia `reviewer` |
| Rilievi bloccanti dal `reviewer` | Riporta la card in In development, lancia `dev` con i rilievi |
| Nessun rilievo bloccante | Porta la card in Deploying to test, se il componente non ha già un'altra card in uno stato di Test; senza avvisi. Con il tag `no-test-deploy`, o se il componente non ha un deploy in Test, la porta dritta in Ready to merge |
| Card in Deploying to test | Accoda l'orchestratore sul ramo della card con i parametri `deploy*` scelti dal `responsabile` (D43); senza scelta valida, l'attesa passa dal `responsabile`. A deploy riuscito la porta in Automated test, o in Human test con il tag `human-test`; se il deploy fallisce, tag `on-hold` |
| Card in Automated test | Lancia il collaudatore (sezione 20) e sposta la card in base al suo esito |
| Commento nuovo di una persona su una card in Automated test | Lancia `responsabile` (motivo `commentoInCollaudo`), prima dell'esito del collaudo: se trova un difetto crea i task e la card torna In development, altrimenti vale l'esito del collaudo |
| Card in Human test | All'ingresso avvisa il richiedente che può provare, una volta per ingresso |
| Commento nuovo di una persona su una card in Human test | Lancia `responsabile`: se è una conferma porta la card in Ready to merge, altrimenti la riporta in In development con un brief |
| Card in Ready to merge | Completa la PR attiva verso `develop` e porta la card in Ready to release. Senza una PR attiva da completare: tag `on-hold` |
| Card in Ready to release | A PR completata rimuove worktree e rami; il rilascio in produzione resta a mano |
| Card di una funzionalità (D52) in Ready to develop, `dev` ha finito | Il worktree nasce da `origin/<ramo della funzionalità>` (creato da `origin/develop` alla prima card), la PR si apre verso il ramo della funzionalità, senza validazione di pipeline; salta il Test |
| Card di una funzionalità in Ready to merge | Completa la PR verso il ramo della funzionalità, tranne mentre la card di chiusura prova la funzionalità (da Deploying to test a Ready to merge); poi la porta In feature branch e toglie il worktree |
| Card di chiusura di una funzionalità | Aspetta che le sorelle siano unite; in Ready to develop apre la PR ramo della funzionalità verso `develop` (senza worktree), poi Deploying to test dal ramo della funzionalità, collaudo, Human test se serve e completamento della PR, con il vincolo sul commit provato. In conflitto o con la CI rossa crea una Bug sorella (`allinea-develop` o la correzione). Alla fine le sorelle In feature branch vanno in Ready to release |
| Card di rilascio spostata in Releasing | Esegue il rilascio del prodotto (sezione 10) |

Lo smistatore sposta le card sugli eventi meccanici. L'unico ruolo che sposta una card per giudizio è `responsabile`.
`dev` e `reviewer` scrivono commenti e basta.

Gli avvisi passano da Telegram (sezione 9). Finché Telegram non c'è, sono menzioni sulla card.

Per non ripetere un'azione, lo smistatore tiene in un file locale l'ultima revisione e l'ultimo commento elaborati per
ogni card, e un blocco per card: una card ha al più una sessione attiva. Le sessioni girano come processi separati,
quindi un giro non aspetta che finiscano.

## 6. Ruoli e sessioni

| Ruolo | Modello | Sforzo | Cosa fa | Cosa può scrivere |
|---|---|---|---|---|
| `responsabile` | Opus | Alto | Trasforma la richiesta in criteri, classifica i bivi, parla con le persone, tiene il registro delle decisioni | Commenti sulla card, le transizioni della sezione 5 |
| `dev` | Opus | Medio | Implementa nel worktree, lancia i test, pubblica il ramo. La PR la apre lo smistatore | File nel recinto del componente, commenti sulla card |
| `reviewer` | Opus | Alto | Rivede la PR una volta, verifica le regole della sezione 8 | Commenti sulla card |
| `scout` | Haiku | Predefinito | Ricognizioni di sola lettura, a richiesta di un altro ruolo | Niente |

Modello e sforzo sono configurazione per ruolo, in un file del repo degli attrezzi: si cambiano senza toccare il
resto, guardando i consumi per ruolo nel registro. Le prove con Fable come `responsabile` si fanno a processo
definito, cambiando quella riga.

`responsabile` usa Opus perché sbaglia nel punto più costoso: un criterio capito male fa lavorare a vuoto tutti quelli
che vengono dopo. I suoi turni sono pochi e brevi, quindi il modello più capace pesa poco sul totale della card.
`reviewer` resta a sforzo alto perché i controlli deterministici li fanno già i test di guardia: a lui resta la parte
che richiede di ragionare sul codice, ed è una passata sola per PR.

I brief dei ruoli stanno in `ruoli/` e modello e sforzo in `config/ruoli.json`. Chi decide non scrive e chi scrive
non decide: `responsabile` non ha gli strumenti per il codice, `dev` davanti a una scelta si ferma con un bivio. La
tabella "chi fa cosa", con la persona, la sessione di sviluppo e lo smistatore, e le decisioni prese con il loro
perché stanno in `docs/decisioni.md`.

Ogni sessione parte con `claude -p` senza connettori e con l'elenco esplicito degli strumenti consentiti al ruolo.
Legge e scrive la card solo attraverso lo script `card`:

- `card leggi <id>` restituisce titolo, descrizione, criteri e ultimi commenti in forma compatta;
- `card commenta` aggiunge un commento con il prefisso del ruolo; il testo arriva solo da stdin, mai come argomento (l'interprete dei comandi altererebbe `$`, backtick e trattino iniziale);
- `card criteri` scrive i criteri di accettazione (testo da stdin), ed è permesso solo a `responsabile`;
- `card sposta <id> <stato>` accetta solo le transizioni permesse al ruolo che lo chiama;
- `card crea` crea una card completa in Draft, ed è vietato dentro una sessione di ruolo (sezione 7).

Lo script carica il PAT da sé, quindi il PAT non entra mai nel contesto di un modello.

Quando lo stesso ruolo torna sulla stessa card, lo smistatore riprende la sessione precedente con `--resume` se la
cache è ancora calda, altrimenti apre una sessione nuova che rilegge la card. La soglia è configurabile e si fissa
dopo la misura del pilota (sezione 14). Una sessione non passa mai da un ruolo a un altro.

Lo smistatore scrive sulla card l'id della sessione, il ruolo e la cartella. Per entrarci a mano: `/ferma <id>` sulla
card, poi `claude --resume <id della sessione>` da un terminale in quella cartella.

## 7. Lavoro di design

Il lavoro di design non parte da una card. Parte da una sessione di Claude in cui una persona chiarisce cosa vuole.
Quando tutto è chiaro, la sessione crea la card da sola con `card crea`, già completa, così chi la prende in carico
non ha domande.

Il comando è `card crea -Tipo <User Story|Bug> -Titolo <testo> -Area <area> -File <markdown>`. Il file ha quattro
sezioni di secondo livello: Descrizione, Criteri di accettazione, Recinto, Riferimenti. Una card creata a metà
vanificherebbe lo scopo, quindi il comando rifiuta un file in cui una sezione manca o è vuota, e dice quale. Rifiuta
anche un'area che non sta nella mappa.

- La card nasce con il tag `agents` e senza stato impostato: deve risultare in Draft. Se Azure DevOps la restituisce
  in un altro stato il comando dà errore e non la sposta. Il via allo sviluppo resta il gesto di chi porta la card
  in New.
- Descrizione, recinto e riferimenti vanno nel campo descrizione. I criteri vanno nel campo dei criteri di
  accettazione, lo stesso di `card criteri`. Per un Bug il testo della descrizione va nel campo dei passi di
  riproduzione. `<DA VERIFICARE: i campi di un Bug sul processo Custom.Agile, dal vivo>`
- `crea` è vietato dentro una sessione di ruolo, cioè se `ATTREZZI_RUOLO` è impostata. Un ruolo che crea card da solo
  aggirerebbe il via di una persona. È l'unico comando di `card` che non richiede `ATTREZZI_CARD` e `ATTREZZI_RUOLO`.
- Il comando stampa id e indirizzo della card creata.

Il richiedente di una card creata così è chi ha aperto la sessione di design. Non serve registrarlo a parte: la card
viene creata con il PAT di chi usa Claude su quella macchina, quindi risulta creata da lui, e la regola della
sezione 4 ("il richiedente è chi l'ha creata") dà il risultato giusto. Chi apre una sessione di design per conto di
un altro diventa lui il richiedente.

## 8. Regole di sviluppo

Le regole hanno una fonte sola: una skill a livello utente, versionata nel repo degli attrezzi, letta da `dev` prima
di scrivere e da `reviewer` prima di rivedere. Il contenuto è la Parte 1 di `bb-project/docs/app-behaviours-rules.md`
resa indipendente dal repo. Contiene la regola zero ("un fatto ha un posto solo dove è scritto"), R1 con i cinque
principi SOLID e i quattro passi da fare prima di scrivere, R2 sulla struttura dati che segue il comportamento. Le regole
G1–G7 proposte dall'audit di `Acme.AI` vi confluiscono, perché dicono le stesse cose.

Ogni repo ha un `CLAUDE.md` breve con ciò che è suo: il recinto dei componenti, come si lanciano i test, come si va in
Test. Elenca anche le guardie a macchina del repo e i guasti da cui sono nate. Per `Acme.AI` le guardie sono le
regole M1–M7 dell'audit.

Le regole si dividono per come si verificano:

- quelle verificabili a macchina sono test di guardia che girano nella validazione della PR, e la fanno fallire;
- quelle di giudizio le verifica `reviewer`, con un esito scritto per ciascuna.

Per la responsabilità singola l'esito scritto è questo: per ogni file toccato `reviewer` dichiara in una frase la
ragione per cui quel file cambia, cioè chi può chiederne la modifica. Se il diff ne aggiunge una seconda è un rilievo
bloccante, con le righe citate, e il pezzo nuovo va in un tipo suo. La dimensione del file non è un criterio. Su un
file che ha già più responsabilità la regola è non aggiungerne un'altra.

Due regole sui test valgono in ogni repo su cui il sistema lavora:

- La validazione della PR fallisce se anche un solo test risulta saltato.
- La validazione fallisce se nella soluzione esiste un progetto di test che la pipeline non esegue.

Un test saltato o un progetto dimenticato danno una validazione verde che non ha verificato niente.

Il TDD è obbligatorio: prima il test che fallisce, poi il codice. L'ordine di lavoro non si può verificare a
macchina, quindi la verifica è indiretta. `dev` riporta nel riepilogo il run rosso, cioè il nome del test e l'errore
con cui falliva prima dell'implementazione. `reviewer` controlla che ogni comportamento cambiato abbia nel diff un
test che fallirebbe senza la modifica. Se manca, è un rilievo bloccante.

Per `Acme.AI` le due regole sui test hanno due prerequisiti. Il primo: 142 test dei preventivi escono senza
asserire quando manca un prerequisito e risultano passati, quindi la prima regola non li vede finché non vengono
riscritti in test che falliscono. Il secondo: la pipeline `stime pr-validation` esegue meno progetti di test di
`stime build-ci`, quindi la seconda regola fallirebbe subito. Sono lavori di `Acme.AI` e non più fuori
ambito. `<DA DECIDERE dal titolare: prima del pilota o come prime card>`

Il codice esistente che viola una regola (oggi M2 e M5 in `Acme.AI`) sta in un elenco di eccezioni dichiarate
nel `CLAUDE.md` del repo. Le regole valgono su tutto il codice nuovo; l'elenco può solo accorciarsi.

## 9. Telegram

Telegram è un secondo modo di leggere e scrivere sulle card, non un canale a parte. Lo gestisce lo smistatore con la
Bot API, senza modelli.

Ogni richiedente ha un gruppo privato suo, con due soli membri: lui e il bot. All'inizio l'unico richiedente è
Il titolare, quindi il gruppo è uno. Un richiedente nuovo si aggiunge creando il suo gruppo e registrandolo nell'elenco
dei gruppi, che associa gruppo, utente Telegram e nome su Azure DevOps. Il bot ignora ogni altro gruppo e ogni altro
utente.

- Nell'argomento generale di un gruppo arrivano gli avvisi di quando tocca a quel richiedente: una verifica da fare
  in Test, una sua card finita in `on-hold`. Nel gruppo del titolare arrivano anche le card che aspettano un suo via.
- L'argomento di una card viene aperto nel gruppo del suo richiedente, e solo alla prima domanda. Una card che non ha
  domande non ne ha uno.
- Dentro l'argomento di una card, ciò che il richiedente scrive diventa un commento sulla card con il suo nome, e ogni
  commento degli agenti compare lì. Un messaggio libero fa partire un turno di `responsabile`.
- Ogni messaggio in uscita ha titolo della card, anteprima della domanda (300 caratteri) e link alla card.

Comandi, gestiti dallo script a zero token:

| Comando | Effetto | Chi può darlo |
|---|---|---|
| `/pronto <id>` | Porta la card in Ready to develop, accettando le ipotesi di `responsabile` sulle domande aperte | Il richiedente della card |
| `/stato` | Elenca le proprie card attive con stato e consumo | Ogni richiedente |
| `/rilascia <prodotto>` | Porta la card di rilascio del prodotto in Releasing | Il titolare |
| `/ferma <id>` | Mette il tag `on-hold` | Il titolare |
| `/riprendi <id>` | Toglie il tag `on-hold` | Il titolare |

Chi non ha un gruppo viene avvisato da Azure DevOps con una menzione sulla card.

I messaggi escono dalla rete aziendale, quindi nelle domande non vanno codice né dati di clienti. Il divieto sta nei
brief dei ruoli, e lo smistatore toglie comunque i blocchi di codice dall'anteprima.

## 10. Rilascio in produzione

Il rilascio in produzione è per prodotto e non per card: portare `develop` su `main` rilascia tutto quello che
`develop` contiene. Per questo il via del titolare sta su una card di rilascio, una per prodotto.

Quando la prima card di un prodotto arriva in Ready to release, lo smistatore crea la card di rilascio di quel prodotto,
di tipo `Release`, e la tiene aggiornata. La card elenca due cose:

- le card unite a `develop` e non ancora in produzione;
- i commit presenti in `develop` e non in `main` che non appartengono a nessuna card, cioè il lavoro fatto a mano che
  partirebbe insieme.

Quando il titolare dà il via, lo smistatore:

1. porta in Releasing le card elencate;
2. apre e completa la PR da `develop` a `main`;
3. fa partire il rilascio come lo prevede il repo. Per `Acme.AI` è l'orchestratore su `main`, il cui stadio
   `Approval` resta del titolare;
4. a rilascio riuscito chiude la card di rilascio e le card elencate, scrivendo su ognuna la versione rilasciata.

Un rilascio che tocca i progetti di database non parte in automatico: lo smistatore avvisa il titolare e si ferma. Se
un passo fallisce, la card di rilascio va in `on-hold` e le altre restano dove sono.

Le card arrivano in produzione verificate in Test una per una, ciascuna dal suo ramo, e mai tutte insieme.
`<DA DECIDERE nella fase 5: se prima di main serve un deploy di develop in Test>`.

Finché questa parte non è costruita, le card si fermano in Ready to release e il titolare le chiude dopo il rilascio fatto
a mano.

## 11. Statistiche

Lo smistatore lancia ogni sessione con `--output-format json` e a fine sessione scrive una riga nel registro. La riga
contiene card, repo, ruolo, modello, sforzo, inizio, fine, turni, esito e se la sessione è ripresa o nuova. I token
sono quattro numeri: in ingresso, in uscita, letti dalla cache, scritti in cache. Poi lo smistatore aggiorna i campi
`Total tokens` e `Agent minutes` della card.

I tempi di permanenza in ogni stato non si registrano: si leggono dalla storia della card in Azure DevOps, che è già
il posto dove sono scritti.

Token e durata non hanno un tetto: sono misure, non limiti.

## 12. Limiti ed errori

| Limite | Valore | Cosa succede al superamento |
|---|---|---|
| Sessioni attive in totale (per PC) | 3 dal 18/11/2026 (1 durante il pilota). È il freno sul traffico di chi ospita lo smistatore, e si cambia in `config/limiti.json` | Le altre card aspettano |
| Card in sviluppo per repo | 1 | Le altre card dello stesso repo aspettano |
| Card in Deploying to test, Automated test o Human test per componente | 1 | La card con la revisione superata resta In review finché il posto si libera |
| Giri da `reviewer` a `dev` per card | 2 | Passata del `responsabile`, poi tag `on-hold` e avviso con i rilievi rimasti |
| Validazioni rosse di fila per card | 3 | Passata del `responsabile`, poi tag `on-hold` e avviso con l'ultimo log |
| Silenzio di una sessione | 45 minuti senza eventi | La sessione viene chiusa, tag `on-hold`, avviso |
| Validazione della PR in corso dopo la fine di `dev` | 60 minuti | Avviso con il link alla build, una volta per sessione di `dev`; la card non si ferma |
| PR in conflitto con `develop` | 1 tentativo di `dev` | `dev` unisce `develop` e scrive sulla card i conflitti e come li ha risolti; una scelta diventa un bivio per `responsabile`. Se restano dopo il suo tentativo: tag `on-hold`, avviso |

Il limite sulle card nei tre stati di Test c'è perché l'ambiente di Test è uno: un secondo deploy dello stesso componente
sostituirebbe la versione che il primo richiedente sta verificando.

Chiunque abbia accesso al progetto può far partire sessioni, che consumano dal traffico del titolare. Il freno è il
numero di sessioni attive, non un controllo su chi le avvia.

Una sessione può durare quanto serve. Lo smistatore la chiude solo se resta in silenzio, cioè se si è bloccata. Un
comando in primo piano non può durare più di 10 minuti, ma uno lanciato in background sì: durante l'attesa la sessione
non scrive eventi, e i test dei preventivi durano più di 20 minuti. Per questo il limite è 45 minuti (verificato il
2026-11-17 sulla card 9). Mentre aspetta un comando in background `claude -p` scrive anche un risultato senza riga
`ESITO` e resta vivo: per lo smistatore è una pausa, non la fine della sessione. Una
sessione chiusa non perde niente: il worktree resta com'è e `/riprendi` la fa continuare con `--resume`.

Una sessione che fallisce mette la card in `on-hold` con un avviso: lo smistatore non riprova da solo. Un deploy in Test
che fallisce passa prima dal `responsabile` (D42) e, se lui non risolve, la card va in `on-hold`. Se il PC è spento non parte nulla, e alla riaccensione lo smistatore riparte dallo stato delle
card.

## 13. Sicurezza

- La configurazione minima di un collega: Claude Code, Azure CLI, `setup/Install-Attrezzi.ps1 ... -Pat`. Lo script fa
  `az login` (se non c'è già), crea i PAT con l'API dei PAT di Azure DevOps usando un token Entra tenuto solo in memoria, e
  fa `az logout`. Il login di `az` serve solo all'installazione: un login sempre attivo equivarrebbe a un accesso
  completo, anche ad Azure Resource Manager, più largo di un PAT (decisione D41).
- Il PAT dello smistatore (`~/.claude/pat-smistatore.txt`; se manca si legge `pat.txt`, che resta dell'utente: `-Pat` non lo
  tocca) ha gli scope minimi per le chiamate di `Ado.psm1`; il PAT in sola lettura
  è descritto sotto. Scope, durata e nomi stanno in `config/pat.json`. I file dei PAT sono cifrati con DPAPI
  (legati all'utente Windows), se in chiaro si leggono lo stesso. Lo smistatore e lo script `card` li caricano nella stessa
  invocazione del comando, senza stamparli né passarli sulla riga di comando.
- Rinnovo: `pat-info.json` (non segreto) tiene `authorizationId` e scadenza di ciascun PAT. Con la scadenza del PAT dello
  smistatore entro 7 giorni lo smistatore manda un avviso Telegram una volta; si rilancia `-Pat`, che crea i PAT nuovi, li
  salva e revoca i vecchi. Un 401 da Azure DevOps ferma il giro con un messaggio che dice di rilanciare `-Pat`.
- Le sessioni di ruolo partono con `AZURE_CONFIG_DIR` su una cartella loro (`az/<id sessione>` nella cartella dati,
  ricreata a ogni avvio, con un `config` che ha solo l'organizzazione di default) e `AZURE_EXTENSION_DIR` sulle estensioni
  dell'utente: se la persona ha un login `az` attivo, l'agente non lo eredita, e un `az login` dell'agente non resta. L'hook
  `deny-pat` blocca nelle sessioni di ruolo `get-access-token`, `az login`, `msal_token_cache`, `AZURE_CONFIG_DIR` e la
  cartella `.azure` (la cache dei token), come già i file dei PAT (`pat*.txt`).
- Le sessioni di ruolo non ricevono mai un PAT con scrittura. Ricevono come `AZURE_DEVOPS_EXT_PAT` il PAT in sola lettura di
  `~/.claude/pat-smistatore-lettura.txt` (o `pat-read-only.txt` se manca; Build: Read, Code: Read), se c'è, altrimenti nessuno: possono verificare contro il
  sistema vero (un `-DryRun`) senza poter scrivere. L'hook `deny-pat` impedisce di nominare variabile e file, così il
  token si usa senza entrare nel contesto. Deciso il 18/11/2026 dopo la card 10, ferma su un `-DryRun` che `dev` non
  poteva lanciare.
- Il token del bot sta in un file nel profilo utente, fuori da ogni repo.
- I due hook già scritti per `Acme.AI` (nessun commit fuori da un worktree, nessun segreto in un file del repo)
  passano a livello utente, così valgono in ogni repo.
- Il rilascio in produzione parte solo dal gesto del titolare della sezione 4. Deploy in Test e merge in `develop` vanno da
  soli (decisione del 18/11/2026): il merge aspetta la prova in Test: il collaudo superato (lo smistatore porta la card in Ready to merge) o, con `human-test`, la conferma del richiedente, che `responsabile` porta in Ready to merge.
- L'orchestratore deduce l'ambiente dal ramo, quindi da un ramo di lavoro non si arriva in produzione.
  In Test si accendono solo i parametri `deploy*` scelti dal `responsabile` (D43): `allowDatabaseDataLoss`,
  `forceRedeploy`, `confirmProductionDatabasePublish` e ogni altro parametro che non comincia con `deploy` restano al
  loro default.

## 14. Verifiche del pilota

Queste cose il disegno le dà per buone ma non sono state provate. Il pilota le verifica nell'ordine, prima di
costruirci sopra.

1. Il processo ereditato permette lo stato iniziale Draft.
2. Il PAT riesce a scrivere su work item, commenti e campi, e a completare una PR verso `develop` rispettando le
   policy del ramo. La lettura è già verificata.
3. `claude -p --output-format json` restituisce token, turni e durata nei campi che servono al registro.
4. Come si imposta lo sforzo di una sessione `claude -p`.
5. Una sessione `claude -p` emette eventi mentre lavora, così lo smistatore può misurare il silenzio.
6. Quanto dura la cache di una sessione `claude -p`: da qui esce la soglia per `--resume`.
7. Lo stadio `Approval` dell'orchestratore ferma anche un run in Test da un ramo di lavoro. Se sì, dopo il via sulla
   card serve anche quell'approvazione.
8. Le sessioni lanciate con `claude -p` compaiono o no nell'app desktop.
9. Quanto pesa l'innesco di una sessione senza connettori, per ruolo.

## 15. Fuori ambito

- Pulire i 28 worktree aperti.
- Spostare lo smistatore su un server.

## 16. Ordine di costruzione

Il lavoro è troppo per un piano solo. Si divide in cinque fasi, ognuna con il suo piano:

1. Fondamenta: stati e campi del processo, repo degli attrezzi, script `card`, fonte delle regole, `CLAUDE.md` di
   `Acme.AI`, hook a livello utente.
2. Smistatore minimo e pilota: una card vera di `Acme.AI` fino al merge in `develop`, una sessione alla volta,
   registro delle sessioni attivo, gesti e avvisi solo da Azure DevOps. Qui si fanno le verifiche della sezione 14.
3. Telegram.
4. Più card in parallelo e altri repo, ognuno con il suo `CLAUDE.md`. Funzionalità divise in task (sezione 18).
5. Rilascio in produzione con la card di rilascio.

Il primo piano copre le fasi 1 e 2.

## 17. Da confermare

| Punto | Ipotesi adottata nella spec |
|---|---|
| Rilascio in produzione | Una card di tipo `Release` per prodotto, con il merge per card automatico (dal 18/11/2026) e la produzione per prodotto a mano. Si rivede dopo il pilota in Test |
| Chi aggiunge stati e campi al processo | Claude via API, dopo l'approvazione del piano; in alternativa il titolare dall'interfaccia |
| Codice esistente che viola le regole | Elenco di eccezioni dichiarate per repo, regole obbligatorie sul codice nuovo |
| Parte 1 del documento di `bb-project` | Sostituita da un rimando alla fonte unica; in `bb-project` restano i guasti e le guardie del repo |
| Hook a livello utente | Spostati da `Acme.AI/.claude` a `~/.claude` |
| Funzionalità su più repo | Una card per repo, legate da una Feature padre che non scorre. L'ordine fra le card c'è: link Predecessor (sezione 18). La verifica in Test di una funzionalità in un repo solo è D52 (`docs/decisioni.md`); quella congiunta su più repo è ancora da disegnare |
| Funzionalità troppo grossa per una PR | `responsabile` propone di dividerla in più card. La soglia si fissa dopo aver misurato le prime funzionalità a task (sezione 18) |
| Prerequisiti dei test in `Acme.AI` | `<DA DECIDERE dal titolare: prima del pilota o come prime card>`: riscrivere i 142 test condizionati dei preventivi e allineare `stime pr-validation` a `stime build-ci` (sezione 8) |

## 18. Funzionalità divise in task

Si costruisce nella fase 4: il pilota gira su una card piccola e non ne ha bisogno.

La card resta l'unità che scorre sulla board. Una funzionalità ha un ramo, una PR, una verifica in Test del
richiedente e un merge, quindi è lei che attraversa gli stati. I task stanno sotto la card e non scorrono.

- Un task è un work item di tipo Task, figlio della card. Li crea `responsabile` quando porta la card in Ready to
  develop, nell'ordine in cui vanno eseguiti. Ognuno dice cosa fare e da cosa si vede che è fatto.
- I task sono facoltativi. Una card senza task va come oggi, con una sola sessione `dev`.
- In In development lo smistatore lancia una sessione `dev` per task, una alla volta, nello stesso worktree della
  card. Ogni sessione parte con contesto pulito, legge la card e il proprio task, committa e chiude il task.
  Quando lancia `dev` su un task lo smistatore lo porta in Active, così dalla board si vede quale è in lavorazione.
- Il primo task ancora aperto è il punto da cui si riparte. Una sessione che muore non fa perdere i task già chiusi.
- Chiuso l'ultimo task, la card passa a In review. `reviewer` fa una passata sola sulla PR intera.
- Un task si può aggiungere anche dopo, dalla board. In In development va in coda agli altri (l'ordine è quello
  degli id). Da In review a Ready to release riporta la card In development con `dev` sul task: la revisione già
  fatta non copre il lavoro nuovo e si rifà sulla PR aggiornata. Se ci sono rilievi del reviewer, prima i rilievi.
  A PR completata non riapre niente: il lavoro va in una card nuova.
- I limiti della sezione 12 restano riferiti alla card, non al singolo task.
- Il registro delle sessioni porta anche l'id del task, così i consumi si leggono per task.

Lo script `card` guadagna due comandi: uno crea i task ed è permesso solo a `responsabile`, l'altro chiude il
proprio task ed è permesso solo a `dev`. `card leggi` mostra anche l'elenco dei task con il loro stato.
Verificato il 2026-11-17 sulla card 2: la board mostra i Task figli come lista di spunte nella card, con il contatore
dei chiusi (es. "0/1").

### Ordine fra le card

Una funzionalità divisa in più card ha un ordine: la card successiva non deve partire finché la precedente non è unita,
perché il suo worktree nasce da `origin/develop` e senza il lavoro della prima sbaglierebbe. Il limite
`cardInSviluppoPerRepo` non basta: conta solo lo stato In development, e una card in revisione o in test lo libera.

- La dipendenza è il link standard **Predecessor** di Azure DevOps (`System.LinkTypes.Dependency-Reverse`), scritto sulla
  card successiva verso la precedente. `card crea -Dopo <id>[,<id>...]` lo scrive nella stessa creazione; dalla board si
  può aggiungere o togliere a mano.
- Le card successive si portano in New tutte insieme: lo smistatore legge i predecessori solo per le card in New e in
  Ready to develop. Finché uno non è unito la card non fa niente, non va on-hold e non riceve commenti; `responsabile`
  non la analizza (in New) e il worktree non nasce (in Ready to develop). Nel log e in `-WhatIf` una riga INFO dice quali
  predecessori aspetta.
- Un predecessore è unito se è in Releasing o Closed, oppure in Ready to release con la PR completata e il worktree già
  rimosso da `RimuoviWorktree`. Tutto il resto no, anche una card rimossa: finché una persona non toglie il link la card
  aspetta. La regola sta in `Decisioni.psm1` (`Get-PredecessoriInAttesa`), letta anche dal giro per il log.
- Il link funziona anche fra card di repo diversi, perché la regola guarda solo lo stato della card e quello locale dello
  smistatore. Non è stato progettato né provato per quel caso: l'ordine fra card di repo diversi resta fuori da questo
  intervento.

### Funzionalità con collaudo unico (D52)

Una funzionalità in un repo solo può essere una Feature padre con una **card di chiusura** (una User Story con il tag
`collaudo-funzionalita`), invece che card isolate legate da Predecessor. Le sue card (le figlie della Feature, link Parent) fanno
un percorso diverso, descritto in D52 (`docs/decisioni.md`):

- Il worktree di una card della funzionalità nasce da `origin/<ramo della funzionalità>`, mai da `origin/develop` e mai da un ramo
  locale; la PR punta al ramo della funzionalità. Il ramo (`feature/f<id Feature>-...` o `bugfix/f<id>-...`) lo crea lo smistatore alla
  prima card in sviluppo.
- Il predecessore «unito» ha un significato in più: una card In feature branch vale come unita solo per una card della stessa
  Feature (`Test-PredecessoreUnito` con la Feature), perché solo il ramo della funzionalità contiene quel lavoro. Per ogni altra card
  unita vuol dire ancora in `develop`.
- La card di chiusura usa come predecessori tutte le sorelle non Removed, senza link Predecessor a mano; senza sorelle non parte.
- Una Feature senza card di chiusura, e le funzionalità su più repo, restano come descritto sopra: card isolate, con l'ordine dato
  dal link Predecessor.

Due casi restano fuori da questo schema, e stanno nella sezione 17:

- **Funzionalità su più repo.** Una card ha un solo worktree e una sola PR. Servono più card, una per repo, legate
  da una Feature padre che non scorre.
- **Funzionalità troppo grossa.** Una sola passata di `reviewer` su una PR enorme vale poco. Sopra una certa
  dimensione `responsabile` propone di dividere la funzionalità in più card invece che in più task.
## 19. Più smistatori e passaggio di consegne

Oggi lo smistatore è uno, sul PC del titolare. Lo stato delle card sta nella sua cartella dati locale, quindi un
secondo smistatore sulla stessa board prenderebbe le stesse card e lancerebbe due sessioni sullo stesso lavoro. Questa
sezione descrive come più persone possono avere ciascuna il proprio smistatore, e come una persona prende le card di
un'altra che è assente con il PC spento. Costruita il 2026-11-17.

### Ogni card ha un padrone: l'assegnatario

Uno smistatore lavora solo sulle card assegnate all'utente del suo PAT (`[System.AssignedTo] = @Me` nella query delle
card attive). Una card ha un solo assegnatario, quindi due smistatori non toccano mai la stessa card, senza bisogno
di parlarsi. `card crea` assegna la card a chi la crea.

Ne seguono tre cose:

- Le sessioni di una card consumano dall'abbonamento a Claude dell'assegnatario, non da quello del titolare.
- Il freno sulle sessioni attive (`sessioniAttive`) resta per PC: ognuno decide quanto del proprio traffico usare.
- I limiti che proteggono una risorsa comune restano globali. `cardInTestPerComponente` esiste perché l'ambiente di
  Test è uno, e `cardInSviluppoPerRepo` perché due card dello stesso repo in sviluppo insieme si pestano i piedi:
  il conteggio si fa su tutte le card della board, non solo su quelle dell'assegnatario. La query del contesto quindi
  resta su tutta la board; il filtro per assegnatario vale solo per le card da far avanzare.

### Il passaggio di consegne

Si riassegna la card dalla board. Al giro dopo lo smistatore del nuovo assegnatario la vede, non trova uno stato
locale e lo ricostruisce da Azure DevOps e da git:

- il ramo dal nome convenzionale `feature/<id>-…`, cercato su origin;
- il worktree ricreato da quel ramo remoto, non da `origin/develop`;
- la PR dal ramo, come oggi;
- lo stato della card e la sua storia, come oggi.

Il lavoro passa intero solo se è su origin. `dev` pubblica già il ramo con `git push` alla fine di ogni sessione
(`ruoli/dev.md`), quindi resta indietro solo una sessione interrotta a metà dallo spegnimento del PC: quella è persa,
e il nuovo assegnatario riparte con un `dev` nuovo dall'ultimo commit pubblicato. I contatori (giri di revisione,
validazioni rosse) ripartono da zero: sono freni, non dati, e un freno azzerato al cambio di mano costa al più un giro.

Dopo la presa in carico, una card In development riparte da `dev` (motivo `presaInCarico`) o, se la PR c'è già,
dalla sua validazione. In In review `reviewer` rifà la revisione, perché quella fatta sull'altro PC non si vede da qui.
In Deploying to test, Automated test e Human test la revisione non risulta superata e la card torna In review. In Ready to merge lo smistatore ritrova la PR
sul ramo ricreato e la completa. Ognuno di questi casi costa al più un giro, ed evita di fidarsi di uno stato che non si vede.

Quando l'assente torna, il suo smistatore non vede più la card, perché non è più sua. Resta da togliere il worktree
sul suo PC: lo smistatore lo fa quando trova nello stato locale una card che non è più assegnata al suo utente, solo
se il worktree non ha modifiche non salvate né commit non pubblicati. Altrimenti lo lascia e lo scrive nel log.

Due cose restano fuori. Una card che dipende da quella di un collega (link Predecessor) la considera unita solo da
Releasing in poi, perche lo stato locale del predecessore non c'e: va letto da Azure DevOps (la PR collegata alla card,
`Get-AdoPrCollegata`). E si riassegna una card con l'altro PC acceso solo sapendo che la sua sessione viene fermata al
giro successivo: la presa in carico aspetta `silenzioMinuti` dall'ultimo avvio di sessione sulla card.

### Decisioni (il titolare, 2026-11-17)

- **Card senza assegnatario:** nessuno smistatore la prende, perché prenderla vorrebbe dire scegliere di chi è il
  traffico.
- **Chi approva Human test e Ready to release:** l'assegnatario della card, così ognuno porta avanti le proprie. Superata
  il 18/11/2026, vedi sotto.

### Decisioni (il titolare, 2026-11-18)

- **Solo la produzione è manuale:** deploy in Test e merge in `develop` vanno da soli. Il deploy in Test parte appena la
  revisione è superata; il merge in `develop` aspetta la prova in Test di chi ha chiesto la card, che `responsabile`
  porta in Ready to merge quando il richiedente conferma. Il controllo "chi ha spostato la card" sulla storia non c'è più
  per i tre stati di Test e Ready to release; resta per il rilascio in produzione, che non è dello smistatore.
- **Avvisi:** l'avviso sulla card menziona l'assegnatario; Telegram resta il gruppo di oggi fino alla fase 3 (un
  argomento per card).

## 20. Il collaudatore

Deciso dal titolare il 2026-11-18: chi prova in Test, di norma, è un modello. Una persona prova solo le card che lo
chiedono, perché le card intermedie di una catena non le può provare nessuno e aspettare la persona ferma la catena.

- **Il ruolo.** `collaudatore` (Sonnet), con il brief `ruoli/collaudatore.md`. Legge la card e il codice del ramo,
  verifica i criteri sull'ambiente di Test (salute del servizio, chiamate alle API, dati restituiti) e scrive l'esito in
  un commento. Non scrive codice, non crea task e non sposta la card: la sposta lo smistatore, in base all'esito.
- **Quando parte.** Una card in Automated test (ci arriva a deploy riuscito, senza il tag `human-test`) lancia il collaudatore, con
  l'indirizzo dell'ambiente di Test (`urlTest` della voce della mappa) nell'allegato. Con il tag `human-test` la card va in Human test: avviso al richiedente, e il suo commento va a `responsabile`. Il tag lo mette la sessione di sviluppo
  alla nascita della card (`card crea -ProvaUmana`).
- **Gli esiti.** `superata`: lo smistatore porta la card in Ready to merge. `respinta`: il resoconto va a
  `responsabile` (motivo `collaudoRespinto`), che crea un task per ogni cosa da correggere e riporta la card In
  development; poi la card rifà sviluppo, revisione, deploy e collaudo. `bloccato`: il collaudatore non riesce a provare
  (ambiente giù, credenziali mancanti) e la card va in on-hold con il motivo.
- **I commenti di una persona (decisione del titolare, 18/11/2026).** In Automated test un commento di una persona non ancora
  letto fa partire `responsabile` (motivo `commentoInCollaudo`) e conta più dell'esito del collaudo: con un collaudo
  superato la card non va in Ready to merge finché `responsabile` non ha deciso. Se trova un difetto crea i task e la card
  torna In development (il collaudo di prima non vale più); se non trova niente vale l'esito del collaudo (superato: Ready to
  merge; respinto: `collaudoRespinto`). Una sessione alla volta: se il collaudatore lavora, `responsabile` parte quando ha
  finito; il commento risulta letto solo quando `responsabile` è lanciato, non per un lancio del collaudatore.
- **Il freno.** Al più `giriCollaudo` (2) collaudi respinti di fila, poi on-hold. Togliere l'on-hold azzera il conto.
- **Le credenziali di prova.** Sono configurazione iniziale del repo, come l'area (decisione D28): se l'app di Test
  vuole un login, la sessione di sviluppo prepara un utente di prova dedicato all'ambiente di Test e ne salva le
  credenziali in `~/.claude/collaudo/<repo>.json`, fuori da ogni repo. Lo smistatore le passa alla sola sessione del
  collaudatore come variabili d'ambiente `COLLAUDO_<CHIAVE>`. Il brief gli chiede di usarle nei comandi senza stamparle;
  a differenza del PAT, un hook che ne impedisca la lettura dall'ambiente non c'è, perché il collaudatore deve poterle
  passare a un login: per questo sono credenziali di un utente di prova del solo ambiente di Test. L'hook `deny-pat`
  blocca la lettura del file in quella cartella.
- **Cosa può fare in Test.** Leggere, e creare dati di prova riconoscibili come tali quando un criterio lo richiede.
  Mai toccare la produzione. Confermato dal titolare il 2026-11-18.
