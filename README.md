# DevOps.Agents

Un sistema di agenti di sviluppo basato su Claude Code che porta una card dalla board fino al merge, da solo: un
`responsabile` chiarisce la card e la divide in task, un `dev` li sviluppa in TDD in un worktree dedicato, un
`reviewer` rivede la PR, un `collaudatore` prova la build in Test, un `mentore` trasforma gli errori ricorrenti in
lezioni per i ruoli. A orchestrare non c'è un modello ma uno script deterministico, lo **smistatore**, che legge le card,
decide cosa fare (`src/Decisioni.psm1`) e lancia le sessioni `claude -p` con il brief del ruolo; un **supervisore**
controlla che tutto giri e avvisa su Telegram; una **vista** HTML locale mostra sessioni, code e pipeline.

> **Nota sull'origine.** Il sistema è nato in un contesto aziendale ed è stato anonimizzato per un uso personale:
> l'azienda, l'organizzazione Azure DevOps, i progetti, gli host e le persone sono stati sostituiti con nomi di esempio
> (`Acme.*`, `acme.visualstudio.com`, `srv-app-test`, «il titolare»). La storia git originale non è inclusa.

### Adattarlo al proprio ambiente

Tutto ciò che dipende dall'ambiente sta in `config/`:

| File | Cosa contiene | Cosa cambiare |
| --- | --- | --- |
| `config/mappa.json` | `organizzazione` (URL di Azure DevOps: `https://dev.azure.com/<org>` o `https://<org>.visualstudio.com`), `progettoBoard` (il progetto con la board delle card), `aree` (una per componente: area path, repo, cartella locale, progetto, pipeline di deploy, URL di Test) | Tutto: è la mappa dei tuoi repo |
| `config/stati.json` | I nomi degli stati e dei tag del processo della board | I nomi delle colonne se il tuo processo li chiama diversamente |
| `config/ruoli.json` | Modello, sforzo, strumenti e brief di ogni ruolo | Modelli e sforzo secondo il tuo abbonamento |
| `config/limiti.json` | Sessioni contemporanee, giri di revisione, soglie di quota | Secondo quanto vuoi spendere |
| `config/supervisore.json` | Soglie e orari del supervisore | Facoltativo |
| `config/pat.json` | Nome, scope e durata dei PAT | Facoltativo |

Il processo della board deve avere gli stati di `config/stati.json` (un processo ereditato da Agile, con le colonne
aggiunte: vedi la spec in `docs/superpowers/specs/`) e i campi interi `Custom.TotalTokens` e `Custom.AgentMinutes`.
I percorsi predefiniti (`C:\develop\GIT\...`, `%LOCALAPPDATA%\DevOps.Agents`) sono quelli di Windows: il sistema è
scritto in PowerShell 7 e usa le attività pianificate e DPAPI di Windows.

I test si lanciano con `pwsh -NoProfile -File ci/Invoke-PrValidation.ps1` (Pester, test degli hook, PSScriptAnalyzer).

In `app/` c'è una prima versione dello stesso sistema in .NET 8 e Angular, pensata come prodotto: stesso motore decisionale
per le card isolate, provider Azure DevOps e GitHub, dashboard con aggiornamenti live e una modalità demo. Cosa c'è e cosa
manca rispetto alla versione PowerShell è in `app/README.md`.

### Il codice su Azure Repos o su GitHub

La board resta sempre su Azure DevOps. Il codice di ogni area può stare su Azure Repos (il default) o su GitHub: lo dice
la voce dell'area in `config/mappa.json`.

```json
{
  "area": "DevOps.Agents\\Web",
  "repo": "Acme.Web",
  "cartella": "C:/develop/GIT/Acme.Web",
  "progettoAdo": "Acme.Web",
  "sorgente": "github",
  "repoGithub": "acme/web",
  "componente": "web",
  "pipelineDeploy": 120,
  "urlTest": "https://srv-app-test:5600"
}
```

Senza `sorgente`, o con `"ado"`, non cambia niente. Per il repo di questa suite (la PR della memoria dei ruoli) vale la
voce facoltativa `"attrezzi": { "repo": "DevOps.Agents", "sorgente": "github", "repoGithub": "<owner>/<repo>" }`.
Chi decide (`Decisioni.psm1`) non sa dove sta il codice: le funzioni sui repo di `src/Ado.psm1` guardano la sorgente
dell'area e passano da `src/GitHub.psm1`, che restituisce gli stessi oggetti.

| Cosa | Azure Repos | GitHub |
| --- | --- | --- |
| PR della card | `workItemRefs` la collega alla card | un link (Hyperlink) sulla card verso la PR, più `AB#<id>` nella descrizione per l'app Azure Boards |
| Validazione | le policy di build della PR | i check run e gli status sul commit di testa (GitHub Actions, Azure Pipelines o altre app) |
| Conflitti | `mergeStatus` | `mergeable` / `mergeable_state` |
| Errori per `dev` | il log della build di validazione | uguale se a validare è Azure Pipelines; con GitHub Actions il link al run, che `dev` legge con `gh run view --log-failed` |
| Rilancio delle validazioni rosse | re-queue della policy | `rerun-failed-jobs` per Actions, retry della build per Azure Pipelines |
| Validazioni scadute (D47) | rilanciate | non esistono: un controllo è legato al commit |
| Merge | merge commit, ramo cancellato | merge commit sul commit verificato, poi il ramo cancellato |
| Deploy in Test | pipeline di Azure Pipelines | la stessa: una pipeline di Azure Pipelines su un repo GitHub (lo YAML dei parametri si legge da GitHub) |

I token di GitHub non si creano via API: si creano a mano due fine-grained PAT sui repo della mappa, uno per lo
smistatore (Contents, Pull requests, Checks e Actions in scrittura) e uno per le sessioni (gli stessi in lettura), e si
salvano cifrati, da un terminale proprio perché lo script li chiede senza mostrarli:

```powershell
pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -PatGitHub
```

Finiscono in `~/.claude/pat-github.txt` e `pat-github-lettura.txt`; le sessioni ricevono il secondo come `GH_TOKEN` e
l'hook `deny-pat` impedisce di nominarlo. Limiti: il branch protection su `develop` non deve chiedere approvazioni umane
né il ramo aggiornato («Require branches to be up to date»), perché lo smistatore unisce da solo dopo la revisione; la
sezione Pipeline della vista e i controlli del supervisore sui run falliti guardano solo Azure Pipelines.

## Com'è fatto il repo

Repo degli attrezzi del sistema di agenti di sviluppo.
Contiene lo smistatore, che prende le card e le fa avanzare tra gli stati.
Contiene lo script `card`, che e' il punto d'ingresso per lavorare su una singola card.
Contiene i brief dei ruoli (chi fa cosa) e la fonte delle regole che gli agenti seguono.
Il disegno completo e' nella spec in `docs/superpowers/specs/`, il piano di realizzazione in `docs/superpowers/plans/`.
Chi fa cosa e perche, e le decisioni prese con il loro motivo: `docs/decisioni.md`.

## Installare su un PC

Il modo più semplice: clonare questo repo in `C:\develop\GIT\DevOps.Agents` (ramo `main`: i colleghi seguono `main`, il titolare `develop`), aprire Claude
(Desktop, scheda Code, o la CLI) in quella cartella e lanciare `/installa-attrezzi`. La skill
(`.claude/skills/installa-attrezzi`) controlla e installa i prerequisiti e guida tutti i passi che seguono, fino alle
attività pianificate. Per il clone serve solo git (`winget install --id Git.Git -e`); l'accesso al repo lo chiede Git
Credential Manager nel browser, senza PAT.

Ognuno può avere il suo smistatore sul suo PC. Uno smistatore fa avanzare solo le card assegnate al suo utente (il
proprietario del PAT), con l'abbonamento a Claude di quell'utente; una card senza assegnatario non la prende nessuno.
`card crea` assegna la card a chi la crea. I limiti sulle risorse comuni (una card in sviluppo per repo, una in uno degli stati di Test
per componente) si contano su tutta la board.

Deploy in Test e merge in `develop` vanno da soli: a revisione superata la card passa in Deploying to test e parte il deploy, poi in Automated test (prova il collaudatore) o, con `human-test`, in Human test; la prova
umana la fa chi ha chiesto la card, e il `responsabile` la porta in Ready to merge quando conferma (altrimenti torna In
development con un task). In Ready to merge lo smistatore completa la PR e porta la card in Ready to release. A mano
resta solo il rilascio in produzione.

Per prendere le card di chi è assente basta riassegnarle dalla board: lo smistatore del nuovo assegnatario ricrea il
worktree dal ramo pubblicato su origin e riprende da lì. Si perde solo una sessione interrotta a metà. Una card presa
in carico in In review o in uno stato di Test rifà la revisione, e una in Ready to merge ritrova la sua PR sul ramo ricreato. Se sulla card è
partita una sessione da meno di `silenzioMinuti`, la presa in carico aspetta: potrebbe essere ancora viva sull'altro
PC. Se quel PC è acceso, il suo smistatore ferma la sessione al primo giro dopo la riassegnazione.

Quando l'assente torna, il suo smistatore toglie i worktree delle card che non sono più sue, se non hanno lavoro non
pubblicato; altrimenti li lascia e lo scrive nel log, e se la card gli torna la mette in on-hold con il motivo. Una
card senza assegnatario resta ferma e conserva il suo stato: va assegnata dalla board.

Prerequisiti:

- Windows con i programmi qui sotto. Se manca qualcosa lo installa `/installa-attrezzi`, chiedendo prima, con
  `winget` (e `npm` per Claude Code):

  | Programma | Come si controlla | Come si installa |
  | --- | --- | --- |
  | git | `git --version` | `winget install --id Git.Git -e` |
  | PowerShell 7 | `pwsh --version` | `winget install --id Microsoft.PowerShell -e` |
  | Azure CLI | `az --version` | `winget install --id Microsoft.AzureCLI -e` |
  | Node.js (per npm) | `npm --version` | `winget install --id OpenJS.NodeJS.LTS -e` |
  | Claude Code da riga di comando | `claude --version` e `claude.exe` in `node_modules/@anthropic-ai/claude-code/bin` accanto allo shim | `npm install -g @anthropic-ai/claude-code` |

  Un programma appena installato non è nel PATH delle shell già aperte: si rilegge il PATH dal registro o si riapre
  la shell.
- **Claude Code da riga di comando, con l'accesso fatto.** L'installazione si può guidare da Claude Desktop, ma le
  sessioni degli agenti le lancia lo smistatore con la CLI installata da npm, e la CLI ha bisogno del suo accesso. Si
  controlla con una chiamata minima, `claude -p "rispondi solo ok" --model haiku`: se risponde, l'accesso c'è. Se no,
  l'utente apre un terminale, lancia `claude` e fa l'accesso con il suo account (lo smistatore usa l'abbonamento di
  quell'account).
- Il repo clonato in `C:\develop\GIT\DevOps.Agents`, e i repo di `config/mappa.json` ai percorsi indicati lì
  (`cartella`). I brief dei ruoli, l'installatore e i worktree (`C:\develop\GIT\_wt`) usano questi percorsi.
- Azure CLI (`az`). Serve **solo durante l'installazione**: `-Pat` fa `az login` (se non c'è già un login), crea i PAT con
  l'API dei PAT di Azure DevOps, che accetta un token Entra (il login è con `--allow-no-subscriptions`: serve anche a chi
  non ha subscription Azure), e fa `az logout`. Lo script gira per ultimo, dopo `-Regole` e `-Hook`. Lo smistatore lavora con i PAT, mai con
  `az`.
- I PAT li crea lo script, non si creano a mano. Sono due, con scope e durata in `config/pat.json`: quello dello
  smistatore (Work Items lettura e scrittura, Code lettura e scrittura, Build lettura ed esecuzione) in
  `~/.claude/pat-smistatore.txt` e uno **solo** Build (Read) e Code (Read) in `~/.claude/pat-smistatore-lettura.txt`.
  **`pat.txt` resta tuo, `-Pat` non lo tocca** (né `pat-read-only.txt`): chi ha già quei file continua a usarli finché
  non rilancia `-Pat`. Entrambi cifrati con DPAPI (legati
  all'utente Windows di quel PC), fuori da ogni repo. Le sessioni degli agenti ricevono il secondo come
  `AZURE_DEVOPS_EXT_PAT` e possono così leggere Azure DevOps (un `-DryRun`, lo stato delle build). Lo smistatore legge
  `pat-smistatore.txt` se c'è, altrimenti `pat.txt` (anche in chiaro, scritto a mano); le sessioni
  `pat-smistatore-lettura.txt`, altrimenti `pat-read-only.txt`. La scadenza, non segreta, sta in `~/.claude/pat-info.json`.
- Per gli avvisi Telegram, facoltativi: il token del bot in `~/.claude/telegram-token.txt` e l'id della chat in
  `%LOCALAPPDATA%\DevOps.Agents\telegram-chat.txt`. Senza i due file gli avvisi non partono (il supervisore li scrive
  solo nel suo log) e il resto funziona. Telegram lo scrive solo il supervisore (sotto), non lo smistatore. Il gruppo è un forum
  con i topic: il bot crea da solo Urgenti, Riepilogo, Rilasci, Diagnosi e Aggiornamenti (gli id stanno in `telegram-topic.json`, nella cartella
  dati) e per farlo gli serve il permesso «Gestisci topic» nel gruppo. Senza il permesso, o se la chat non è un forum, tutto va nel
  topic generale e una voce del riepilogo lo dice una volta.

Dalla working copy:

1. Collega skill e hook:

   ```powershell
   pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Regole -Hook -Pat
   ```

   `-Regole` crea in `~/.claude/skills` le giunzioni `regole-sviluppo` e `devops-agents` verso questo repo; `-Hook`
   aggiunge gli hook a `~/.claude/settings.json`, dopo averne salvato una copia. `-Pat` fa il login di `az` se non c'è
   (si apre il browser), crea i due PAT, li salva cifrati e toglie il login; se il login c'era già lo lascia com'è.
   Rilanciato crea PAT nuovi e revoca i vecchi.
2. Verifica con un giro che non scrive niente: `pwsh -NoProfile -File src/Smistatore.ps1 -WhatIf`. Deve stampare le
   azioni previste per le card con il tag `agents`, oppure niente, senza errori.

### Rinnovo dei PAT

Quando il PAT dello smistatore scade entro 7 giorni il supervisore lo mette nel riepilogo (se Telegram è configurato) con la
data: rilancia `pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Pat`. Un PAT scaduto o revocato fa fermare il giro con una
riga di log che dice la stessa cosa, e il supervisore lo manda subito come avviso urgente con lo stesso comando. Lo smistatore
scrive anche una riga di log per la scadenza vicina, una volta per scadenza, ma non manda più niente su Telegram.

## L'aggiornamento automatico della suite (D53)

La suite gira dalla copia principale `C:\develop\GIT\DevOps.Agents` e si aggiorna da sola: un collega non fa `git pull` e non
deve mai trovarsi con una suite rotta o a metà. Chi aggiorna è il supervisore (sopra), a ogni giro, senza modelli.

- **Il canale.** Si segue `main` (i colleghi) o `develop` (il titolare). Vale quello scritto in `impostazioni.json`; se non c'è, il ramo
  già estratto nella copia se è `main` o `develop`, altrimenti `main`. Per cambiare canale si scrive `"canale": "develop"` (o `"main"`) in
  `impostazioni.json`: la copia passa al ramo nuovo al primo aggiornamento, se è un avanzamento in fast-forward. Promuovere `develop` su
  `main` è un gesto del titolare, con una PR con merge (non squash).
- **Dove si vede la versione.** Nella vista (`http://localhost:18799/vista.html`), scheda Agenti, il riquadro **Suite**: versione
  installata (canale, hash corto, data), versione disponibile, ultimo controllo, stato, le PR in arrivo con il link, il pulsante
  **Aggiorna adesso** e l'interruttore **Aggiornamento automatico**. Lo stesso dato sta in `aggiornamento.json` nella cartella dati, e
  nel terminale `Vista.ps1` ha una riga `Suite:`. Un messaggio nel topic Aggiornamenti di Telegram dice a ogni aggiornamento da quale a
  quale versione e quali PR sono entrate, e quando un aggiornamento fallisce e torna indietro.
- **Quando aggiorna.** Ogni `minutiControlloAggiornamenti` (30, `config/supervisore.json`) fa un `git fetch`; se c'è un commit nuovo e
  l'automatico è acceso aggiorna, oppure subito se dalla vista si preme Aggiorna adesso (anche con l'automatico spento). Aggiorna **solo
  quando non c'è nessuna sessione di agenti in corso** e nessun giro dello smistatore sta girando; durante l'aggiornamento
  l'attività `Smistatore` è disabilitata e poi riabilitata. Se aspetta da oltre `oreAttesaAggiornamento` (6) lo dice la vista e, una volta,
  Telegram: non forza.
- **Quando non aggiorna, e lo dice.** La copia ha modifiche locali (qualunque file, anche non tracciato), è avanti o divergente da
  `origin/<canale>` (si avanza solo in fast-forward, mai con un reset), oppure la versione nuova chiede di più di quello che c'è: i
  minimi di Claude Code, PowerShell e `az` sono in `config/requisiti.json`, e si legge il file **della versione nuova**.
- **Dopo l'avanzamento** rilancia `setup/Install-Attrezzi.ps1 -Regole -Hook -Pianificazione` (mai `-Pat`) e un giro di prova a vuoto dello
  smistatore (`-WhatIf`), dalla copia aggiornata. Se uno dei due fallisce o non finisce in tempo, la copia torna al commit di prima, si
  reinstalla la versione di prima, il commit non si riprova finché origin non va oltre, e un messaggio su Telegram lo dice.
- **`impostazioni.json`** (cartella dati, fuori dal repo, così la copia resta pulita):

  ```json
  {
    "canale": "main",
    "aggiornamentoAutomatico": true,
    "limiti": { "sogliaQuotaSettimanale": 0.85 },
    "supervisore": { "diagnosiAlGiorno": 1 }
  }
  ```

  `limiti` e `supervisore` sono override delle chiavi di primo livello di `config/limiti.json` e `config/supervisore.json`: `Get-Config` e
  `Get-ConfigSupervisore` li applicano sopra il file del repo e li validano con le stesse regole (una chiave che il file non ha, o un
  valore invalido, è un errore che lo dice). Una modifica fatta a mano a quei due file non blocca l'aggiornamento: se sono le uniche
  modifiche locali, l'aggiornamento ne porta le chiavi cambiate in `impostazioni.json` (senza sovrascrivere un override che c'è già) e
  ripristina il file. L'override della soglia di quota dalla vista (`soglia-quota.json`, D51) resta com'è.

## Una funzionalità fatta di più card (D52)

Una funzionalità che ha senso provare solo intera si crea come una Feature con le sue card, non come card isolate. Si prova in
Test una volta sola, dal ramo della funzionalità, e poi entra in `develop` con una PR. Il flusso è in D52 (`docs/decisioni.md`).

1. Si crea la Feature con la sua card di chiusura: `card crea -Tipo Feature -Titolo <testo> -Area <area> -File <markdown>`, con
   `-Bug` se è una correzione (il ramo si chiamerà `bugfix/f<id>-...` invece di `feature/f<id>-...`). Il file dà i criteri della
   funzionalità intera, che prova il `collaudatore`. Il comando stampa gli id della Feature e della card di chiusura.
2. Si creano le card della funzionalità, una per volta: `card crea -Tipo <User Story|Bug> -Feature <id> -Titolo ... -Area ... -File ...`.
   L'area deve essere quella della Feature (una funzionalità sta in un repo solo), e la Feature non può essere già Resolved o Closed.
   Una Feature senza card di chiusura non è una funzionalità D52: raggruppa le card per priorità e pausa, e le sue card vanno in
   `develop` una per una (D60). Si crea con `card crea -Tipo Feature -Raggruppa`. Ogni card nuova sta in una Feature.
3. Le card nascono in Draft, la card di chiusura compresa. Si portano in New dopo averle lette. La card di chiusura aspetta che tutte le
   sorelle siano In feature branch; se resta in Draft con tutte le sorelle pronte, una sorella In feature branch lo dice e la vista
   mette la card di chiusura fra le cose da fare, con il gesto «sposta la card #<id> in New» (le card in Draft non le legge nessuno).
4. Per il resto lo smistatore fa da solo: il ramo della funzionalità nasce da `origin/develop` alla prima card in sviluppo, le PR delle
   card vanno lì, il collaudo e la PR verso `develop` sono della card di chiusura. Con D52 spenta (`funzionalitaAttive` a `false` in
   `config/limiti.json`) i due comandi si rifiutano.

La vista mostra le funzionalità in una sezione a sé, con la card di chiusura e lo stato di ogni card.

## Lo smistatore

Un giro legge le card con il tag `agents`, decide cosa fare (`src/Decisioni.psm1`, senza modelli) ed esegue le azioni.
Se non c'e' niente da fare non spende niente.

**Il limite di token e la riserva (D51).** Una sessione che finisce sul limite di token non mette la card in on-hold: lo
smistatore scrive in `quota.json` (cartella dati) una pausa fino al reset piu `margineQuotaMinuti`, lascia un commento sulla
card e, finita la pausa, riprende la sessione da dove era. Durante la pausa nessuna sessione nuova parte, su nessuna card.
Se l'uso settimanale letto a fine sessione supera `sogliaQuotaSettimanale` (`config/limiti.json`, 0.70) le sessioni nuove
aspettano il reset settimanale: e' una riserva per l'uso interattivo, non un conto esatto (le sessioni di una persona non
si vedono). La vista mostra entrambe come motivo `quota`, con un banner in cima quando gli agenti sono fermi e una riga quota in testata.
Dalla vista si puo alzare la soglia (fino a 0.95) o ignorare la riserva fino al reset settimanale, senza toccare `limiti.json`: l'override sta in
`soglia-quota.json` (cartella dati), vale solo fino a quel reset e salta la sola riserva, non la pausa dopo il limite di token.

**On-hold che lo smistatore toglie da solo (D51).** Solo quando un dato dice che la causa non c'e' piu': il limite di token di
prima di D51 con il reset passato, le validazioni rosse (non i giri di revisione o di collaudo) con la validazione della PR ora
verde. Toglie il tag e scrive `[smistatore] tolgo l'on-hold: ...`; il deploy e ogni altra attesa restano a una persona. Una
sessione chiusa per silenzio o morta senza risultato, la prima volta per card, non mette nemmeno l'on-hold: la riprende da sola
con un commento senza menzione; al secondo fermo l'on-hold c'e'.

Ogni on-hold lascia il commento con la menzione sulla card e una riga `on-hold: ...` nel log; lo smistatore non manda
Telegram (lo fa il supervisore, vedi "Il supervisore"). Il commento finisce con **Cosa fare** (D57): il gesto, togliere
l'on-hold e cosa succede dopo, perché serve e perché non l'hanno fatto gli agenti. La stessa sezione è nella vista e
su Telegram. Non riportare la card in Draft o in New: lo smistatore la tratterebbe come nuova.

**Un giro a mano** (dalla working copy principale, `C:\develop\GIT\DevOps.Agents`):

```powershell
pwsh -NoProfile -File src/Smistatore.ps1 -WhatIf      # stampa le azioni, non scrive da nessuna parte
pwsh -NoProfile -File src/Smistatore.ps1 -Card 1234   # tocca solo quella card
pwsh -NoProfile -File src/Smistatore.ps1              # un giro vero
```

**Pianificazione.** L'operazione `DevOps.Agents\Smistatore` lancia lo script della working copy principale ogni
`intervalloMinuti` (`config/limiti.json`), solo a utente collegato, senza finestra:

```powershell
pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Pianificazione          # registra o aggiorna
pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -RimuoviPianificazione   # la ferma e la toglie
```

Insieme registra `DevOps.Agents\Vista`, che a ogni accesso a Windows avvia la vista HTML (`Vista.ps1 -Html -Segui
-Apri`, sotto) senza finestra e apre `http://localhost:18799/vista.html` nel browser. Resta accesa finche si e collegati; per
riaprirla dopo averla chiusa basta "Esegui" sull'operazione. `-RimuoviPianificazione` toglie anche lei.

Registra anche `DevOps.Agents\Supervisore` (sotto), ogni `intervalloMinuti` di `config/supervisore.json`.

Per fermarla solo per un po': Utilita di pianificazione, cartella `DevOps.Agents`, "Disabilita".
Dopo aver cambiato `intervalloMinuti` si rilancia `-Pianificazione`.

## Il supervisore

Uno script senza modello (`src/Supervisore.ps1`, D51) in un'attivita pianificata a parte, `DevOps.Agents\Supervisore`,
ogni 5 minuti: controlla al posto di una persona e la chiama solo per cio che serve a lei. E' a parte perche deve vedere
anche uno smistatore che non gira. I controlli sono funzioni pure in `src/Supervisione.psm1`.

- **Cosa controlla.** Lo smistatore (giro fermo da troppo, attivita disabilitata, giro che esce con errore); la stessa card
  saltata per errore piu volte di fila nel log di oggi; la vista su `:18799`; le card che aspettano una persona (on-hold, prova
  in Test, risposta, rilascio) e quelle ferme da ore senza un motivo noto; le pipeline (run in attesa di approvazione, agenti dei
  pool interni offline, run in coda da troppo, run falliti nelle ultime 24 ore dei repo della mappa); la quota (pausa,
  riserva); il PAT (scadenza vicina, rifiutato).
- **Cosa fa da solo.** Solo due cose. Avvia l'attivita della vista dopo due mancate risposte di fila (se risulta in esecuzione
  ma non risponde la ferma e la riavvia; se e disabilitata non la tocca; al piu una volta all'ora). Rilancia un run fallito per
  infrastruttura (i testi in `testiInfrastruttura`, espressioni regolari senza distinzione di maiuscole) **solo** per le
  pipeline elencate in `pipelineRilanciabili` di `config/supervisore.json` (voci `{ "progetto": ..., "definizioneId": ... }`,
  **vuoto di default**), solo sul ramo `develop` (mai `main`), solo se e l'ultimo run di quella definizione e di quel ramo e
  con la stessa versione di sorgente e gli stessi parametri del run originale, una volta per run. Con l'elenco vuoto non
  rilancia niente: il run diventa una voce del riepilogo "si potrebbe rilanciare: aggiungi la pipeline a
  `pipelineRilanciabili`". Mai: deploy, approvazioni, merge, riattivare un'attivita disabilitata, spegnere il PC, scrivere
  sulle card, rilanciare le validazioni delle PR delle card (restano a D38).
- **Rilasci in attesa.** Le card pronte da rilasciare sono una voce sola, "Rilasci in attesa", con una riga per area: l'area di
  `config/mappa.json`, quante card, i loro numeri e da quanti giorni aspetta la piu vecchia (dall'ingresso nello stato di
  rilascio, o dal primo visto del supervisore). Un'area con almeno `rilasci.predefinito.card` card (5) o la cui piu vecchia aspetta
  da `rilasci.predefinito.giorni` giorni (7) e segnata "OLTRE SOGLIA" con il motivo e va in cima; `rilasci.perArea` (vuoto di
  default) cambia le soglie di un'area, per esempio `{ "DevOps.Agents\\AI\\Stime": { "card": 2, "giorni": 3 } }`.
  Non e un urgente. La voce compare quando entra una card nuova in rilascio; torna ogni giorno solo se un'area e oltre soglia.
- **Il PAT.** Il supervisore usa solo `pat-smistatore.txt`, mai `pat.txt` (e di una persona). Se manca non fa nessuna
  chiamata ad Azure DevOps e manda un urgente con il comando `pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Pat`.
- **Quando scrive su Telegram.** Gli urgenti (smistatore fermo o in errore, PAT rifiutato, run in attesa di approvazione,
  agente offline, il giro dello smistatore che si interrompe a ogni giro, il supervisore stesso che si ferma) subito, e si ricordano dopo `oreRicordoUrgente` (4) se ancora aperti. Il resto
  va in un riepilogo alle 8:30 e alle 14:00 dei giorni feriali, solo se c'e una voce nuova o da ricordare (una volta al
  giorno, con da quanto aspetta): un messaggio nel topic Riepilogo, una voce per punto con la cosa e, a capo, l'azione esatta
  con il link. I rilasci in attesa non sono nel riepilogo: sono un messaggio a parte nel topic Rilasci (con il link alla pipeline
  `release-orchestrator` del progetto), con lo stesso ritmo; le diagnosi sono un messaggio ciascuna nel topic Diagnosi. Alla prima esecuzione dopo
  l'accensione del PC parte subito il riepilogo di cio che e in sospeso. Uno smistatore che non gira a PC spento non e un
  problema. Senza Telegram configurato gli avvisi vanno solo nel log.
- **Cosa tiene.** `supervisore.json` nella cartella dati: i problemi aperti (primo visto, ultimo avviso), i gesti fatti, i
  riepiloghi mandati, l'ultima esecuzione. Un problema che non si vede piu si chiude senza messaggi. Il log e
  `log/supervisore-<data>.log`.
- **Soglie.** Tutte in `config/supervisore.json` (minuti senza giro, errori di fila per card, ore senza movimento, minuti in
  coda, ore del ricordo, orari del riepilogo, testi di infrastruttura...).
- **A mano.** `pwsh -NoProfile -File src/Supervisore.ps1 -WhatIf` stampa i problemi, i gesti e i messaggi che manderebbe, senza
  scrivere niente (nemmeno `supervisore.json`).
- **Diagnosi con il modello.** Solo per i problemi che nessuna regola sa spiegare (un errore dello smistatore che si ripete, una card ferma senza motivo, un run fallito senza causa nota): una sessione del ruolo `supervisore` (Sonnet, sola lettura, `ruoli/supervisore.md`) per problema, una alla volta, al piu `diagnosiAlGiorno` (3) al giorno, mai con la quota che blocca, con le sessioni dello smistatore al limite o con `-WhatIf`. La causa probabile e l'azione esatta vanno sotto la voce del riepilogo; una diagnosi si tiene 24 ore dopo la chiusura del problema. Non corregge niente, ed e controllato (D39): prima e dopo la sessione si prende l'impronta di `stato.json`, `quota.json` e della copia principale degli attrezzi (HEAD e `git status`); se qualcosa e cambiato la diagnosi si scarta e parte un urgente "la diagnosi ha scritto: ...". Limite: se in mezzo c'e stato un giro dello smistatore (che riscrive i due file per mestiere) si confronta solo git, e una modifica fatta da una persona alla copia principale mentre la sessione lavora sembra della sessione.
- Dopo una sospensione del PC lo smistatore non risulta fermo (conta solo se anche il supervisore girava) e il riepilogo di ripartenza parte se l'ultima esecuzione e piu vecchia di tre intervalli.

**Vedere cosa fanno gli agenti.** Un comando in sola lettura, da lasciare aperto in un terminale: non scrive ne lo stato,
ne il log, ne Azure DevOps.

```powershell
pwsh -NoProfile -File C:/develop/GIT/DevOps.Agents/src/Vista.ps1 -Segui
```

La stessa vista come pagina HTML, da tenere aperta nel browser (si ricarica da sola):

```powershell
pwsh -NoProfile -File C:/develop/GIT/DevOps.Agents/src/Vista.ps1 -Html -Segui -Apri
```

`-Html` scrive `vista.html` nella cartella dati (`-PercorsoHtml` per cambiarlo), a ogni `-Secondi` con `-Segui`, una volta
sola senza; `-Apri` la apre nel browser alla prima scrittura. E il solo file che la vista scrive. Un esempio con dati finti
e in `docs/vista-esempio.html`. Sotto la kanban c'e la sezione **Pipeline di build**: i run in corso, in coda e in attesa di approvazione di tutti i
progetti dell'organizzazione, i falliti delle ultime 24 ore e un link alle PR di tutti i progetti (vedi D44 in `docs/decisioni.md`).
Nella scheda Agenti, sotto kanban e catene, la sezione **Apprendimento** (D46): per ruolo e per settimana ISO i blocchi, gli on-hold, le correzioni e le
lezioni applicate (dal registro dello smistatore; ultime 4 settimane intere piu quella in corso, la stessa finestra del riassunto nella PR della memoria), le lezioni
che hanno evitato un blocco finora e le lezioni in prova in attesa di conferma; le lezioni si leggono da git e Azure DevOps ogni
`-SecondiMemoria` (300) e solo con `-Html`. Una lezione ha evitato un blocco se e stata applicata su una card diversa da quella d'origine, in una sessione non
finita bloccata o in bivio, e dopo non c'e un blocco, on-hold o correzione dello stesso ruolo sulla card.

Con `-Html -Segui` la vista e anche un server locale: la pagina si apre su `http://localhost:18799/vista.html` (`-Porta` per
cambiare la porta; `-Apri` apre gia quell'indirizzo) e in testa ha il pulsante **giro adesso**, che avvia subito l'attivita
pianificata dello smistatore (se sta girando lo dice e non ne avvia un'altra). Il server ascolta solo su localhost, serve solo
`vista.html`, `sessione-*.html` e `brief-*.html` e ha un solo comando, `POST /giro`, che vuole il token generato a ogni
avvio della vista (scritto nella pagina). Se la porta e occupata la vista parte lo stesso, con la pagina da file e senza pulsante.
Il riquadro Suite (D53) ha due comandi suoi, con lo stesso token e lo stesso controllo dell'host: `POST /aggiorna-suite` scrive la richiesta
di aggiornamento e avvia subito il supervisore, `POST /automatico?attivo=0|1` accende o spegne l'aggiornamento automatico in
`impostazioni.json`. La vista non aggiorna: legge `aggiornamento.json`.
Senza `-Html` o senza `-Segui` non c'e nessun server.

Senza `-Segui` stampa una volta; con `-Segui` ridisegna ogni `-Secondi` (10). Mostra le sessioni in corso (ruolo, task,
minuti, token e ultime 5 azioni dell'agente), le card ferme con il motivo (on-hold, card precedenti, posto occupato dal
limite `sessioniAttive`, limite per repo, con il ruolo a cui andranno) e i gesti che aspettano una persona, poi l'ora dell'ultimo giro.
La pagina HTML e una kanban per agente: una colonna per ruolo (sessioni in cima, coda sotto), la colonna dell'operatore e quella
della pipeline; le catene di card stanno in un blocco chiuso sotto. Azure DevOps
si rilegge ogni `-SecondiAdo` (60). Il motivo e quello che decide lo smistatore (`Get-Decisione` in `src/Decisioni.psm1`);
lo smistatore scrive nel log lo stesso motivo quando una card e ferma da card precedenti o dal limite di sessioni.
**Dove sta cosa.** Tutto in `%LOCALAPPDATA%\DevOps.Agents` (la cartella dati, una sola per smistatore e `card.ps1`):
`log\smistatore-<data>.log` (cosa ha fatto e gli errori), `stato.json` (lo stato di ogni card: ramo, cartella, PR, run,
sessione), `registro-sessioni.jsonl` (una riga per sessione, con i consumi). Il worktree di ogni card e' in
`C:\develop\GIT\_wt\<repo>\card-<id>`.
