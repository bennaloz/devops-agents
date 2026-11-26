---
name: devops-agents
description: Passare un lavoro di sviluppo al sistema di agenti (smistatore di DevOps.Agents) creando una card sulla board, e predisporre l'area quando manca. Usala ogni volta che si ragiona su un nuovo lavoro in un repo della mappa, prima di scrivere codice: il lavoro si fa con una card, non nella sessione, salvo le due eccezioni scritte qui.
---

# Card per gli agenti

Lo sviluppo nei repo della mappa lo fanno gli agenti: una card sulla board `DevOps.Agents`, che lo smistatore
(`C:\develop\GIT\DevOps.Agents`) porta da `responsabile` a `dev` a `reviewer` fino alla PR. La sessione
interattiva fa l'analisi con l'utente, prepara la card e lascia il codice agli agenti. Una regola sola scala meglio
di una scelta caso per caso, e il lavoro degli agenti lascia traccia sulla card.

## Quando non serve una card

Solo in due casi il lavoro si fa nella sessione, con le regole di sempre (worktree, TDD, PR):

- **Il repo `DevOps.Agents`.** È il sistema stesso: un errore in una PR degli agenti potrebbe fermare lo
  smistatore che la deve portare avanti.
- **Una modifica minuscola:** non richiede decisioni, non ha bisogno di test nuovi e sta in un file (una riga di
  configurazione, un refuso). Una card costa almeno `responsabile`, `dev` e `reviewer`, 1,5-2 milioni di token; qui
  costerebbe più del lavoro.

Nel dubbio è una card.

## Il percorso

Quando parti da questa skill guidi l'utente passo per passo, in quest'ordine, e a ogni passo dici a che punto siete
e qual è il prossimo. Non saltare l'analisi anche se il lavoro sembra chiaro: le scelte che non si prendono qui le
prende `responsabile` con una domanda, o peggio `dev` senza dirlo.

1. **Analisi con `grill-me`.** Carica la skill `grill-me` (se non è installata, fai tu l'interrogatorio con lo stesso metodo: una domanda alla volta, ognuna con la tua risposta consigliata) e interroga l'utente sul lavoro finché le scelte di prodotto
   sono prese: cosa deve succedere, quali casi contano, cosa resta fuori, l'obiettivo e come si verifica. Il codice
   lo leggi tu per non fare domande a cui il repo già risponde.
2. **Divisione in card.** Una card per repo e per PR. Se il lavoro è troppo grosso per una revisione sola, più card.
3. **L'area** di ogni card (sezione sotto): se manca, la predisponi prima di andare avanti.
4. **Il testo della card,** con ciò che è deciso scritto come deciso. Lo fai leggere all'utente. Chiedigli anche se la
   card ha qualcosa da provare nell'ambiente di Test: se no (una pipeline, i test, uno script di CI) la crei con
   `-SenzaTest`, e dopo la revisione andrà dritta in `develop` senza deploy in Test. Di norma in Test prova il
   collaudatore; se l'utente vuole provarla di persona (per esempio l'ultima card di una catena), la crei con `-ProvaUmana`.
5. **La creazione** con `card crea`, dopo il suo sì. L'utente la porta in New.
6. **Il primo giro:** `-WhatIf`, poi il giro vero con il suo via.

## Prima della card: l'area

Lo smistatore lavora solo sulle card di un'area mappata in `config/mappa.json`, una per repo. Un'area che non c'è non
dà errori sulla board: `card crea` si rifiuta, e una card creata a mano dalla board resta ferma per sempre senza
avvisi. Quindi controlla la mappa all'inizio di ogni nuovo lavoro.

Se l'area manca la predispone questa sessione, non gli agenti (finché l'area non è mappata non vedono la card):

1. L'area sulla board `DevOps.Agents`: è una modifica ad Azure DevOps, si fa solo con il sì dell'utente e la fa chi amministra il progetto ADO.
2. La voce in `config/mappa.json` (repo, cartella, progetto ADO, componente, pipeline di deploy in Test e suo
   parametro, `urlTest` cioè l'indirizzo dell'ambiente di Test che il collaudatore prova; se il codice sta su GitHub,
   anche `"sorgente": "github"` e `"repoGithub": "<owner>/<repo>"`), con una PR in `DevOps.Agents`.
   Se l'app di Test vuole un login, prepara insieme all'utente un account di prova dedicato all'ambiente di Test e salvane le
   credenziali in `~/.claude/collaudo/<repo>.json` (chiave e valore, per esempio `utente`, `password`, `urlLogin`), fuori
   da ogni repo: il collaudatore le riceve come `COLLAUDO_<CHIAVE>`. Senza, ogni collaudo che chiede il login finisce
   `bloccato`.
3. Se il repo non ha il corredo (build-ci, pr-validation agganciata alla policy, deploy in Test nell'orchestratore),
   la prima card dell'area è quella del corredo. Senza corredo una card arriva comunque a revisione e merge, perché
   il giudice è la PR unibile, ma non al deploy in Test. L'agente scrive gli YAML e uno script idempotente che crea
   pipeline e policy; a card finita lo esegue la sessione interattiva, su ordine dell'utente. Pipeline e policy non
   le crea mai un agente.
4. I permessi del progetto ADO li dà a mano chi lo amministra, nella configurazione iniziale: né un agente né la sessione
   interattiva hanno diritti sulla sicurezza. Prima del primo deploy in Test, con l'orchestratore:
   - **Queue builds: Allow** a `<progetto> Build Service (<org>)` su ogni build-ci che l'orchestratore accoda (Manage
     security della pipeline), solo su quelle e non su "All pipelines";
   - l'environment e la service connection che usa l'attesa delle build, con il loro script di provisioning, lanciato
     da chi amministra il progetto, con il suo PAT, e il token Build (Read) nella service connection.

   Un componente nuovo nell'orchestratore vuol dire ripetere il primo punto per la sua build-ci. Il segno che manca è un
   deploy fallito con `TF215106: Access denied ... needs Queue builds permissions`.

## Scrivere la card

La card nasce dall'analisi fatta con l'utente: ciò che si è deciso va scritto come deciso, perché `responsabile` non
lo richiede e non lo rimette in discussione. Chiede solo ciò che la descrizione non copre o che il repo contraddice.
Una scelta lasciata implicita diventa una domanda, cioè un giro in più.

Il file per `card crea` ha quattro sezioni `##`, tutte obbligatorie: `Descrizione`, `Criteri di accettazione`,
`Recinto`, `Riferimenti`. Nella descrizione: il problema, cosa è già deciso, l'obiettivo. I criteri sono una bozza:
li riscrive `responsabile`. Il recinto dice quali file si toccano e quali no. Una funzionalità su più repo è più
card, una per repo.

```
pwsh -NoProfile -File C:/develop/GIT/DevOps.Agents/src/card.ps1 crea -Tipo 'User Story' -Titolo '<titolo>' -Area 'DevOps.Agents\<area>' -File <file.md>
```

Le card di una funzionalità divisa si creano con `-Dopo <id>[,<id>...]` (gli id delle card che devono essere unite
prima): si possono portare tutte in New, partono una alla volta, quando la precedente è unita.

Fai leggere il testo all'utente prima di crearla. La card nasce in Draft con il tag `agents`: gli agenti la ignorano
finché l'utente non la porta in New.

## Far girare lo smistatore

Finché la pianificazione è spenta un giro lo lancia la sessione: prima sempre `src/Smistatore.ps1 -WhatIf`, e il giro
vero solo con il via dell'utente. Un giro fa solo le azioni che il `-WhatIf` ha mostrato. Lo stato delle card sta in
`%LOCALAPPDATA%\DevOps.Agents`, il log in `log\smistatore-<data>.log`, l'uscita di ogni sessione in
`sessioni\<id>.jsonl`.

## Le decisioni

Le regole del sistema, chi le ha decise e perché stanno in `docs/decisioni.md` del repo `DevOps.Agents`.
Una decisione nuova presa con l'utente su come funziona il sistema (non sul prodotto di una card, che va sulla card) si
scrive lì, nella stessa PR in cui si applica.
