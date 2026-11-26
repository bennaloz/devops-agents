# Ecosistema di agenti: piano di implementazione

> **Per chi esegue con agenti:** usare `superpowers:subagent-driven-development` oppure
> `superpowers:executing-plans`, un task alla volta. I passi hanno la casella (`- [ ]`) per segnare l'avanzamento.

**Obiettivo:** portare una card vera di `Acme.AI` da New fino al merge in `develop`, guidata dallo smistatore,
con consumi registrati.

**Architettura:** uno script PowerShell senza modelli (lo smistatore) legge le card di Azure DevOps, decide con una
funzione pura cosa fare e lancia sessioni `claude -p` per ruolo. Gli agenti toccano la card solo attraverso lo script
`card`. Tutto vive nel repo `DevOps.Agents`.

**Strumenti:** PowerShell 7.6, Pester 6.2, REST API di Azure DevOps 7.1, Claude Code 2.1 da riga di comando,
Utilità di pianificazione di Windows.

**Spec:** `docs/superpowers/specs/2026-11-16-ecosistema-agenti-design.md`. Chi esegue legge anche quella.

Il piano dettaglia le fasi 1 e 2 della spec. Le fasi 3, 4 e 5 sono in fondo come elenco di task, da dettagliare dopo
il pilota: dipendono da valori che il pilota misura.

Il piano non riporta il codice completo di ogni passo: dà file, firme, casi di test e comandi. È una scelta: ogni
agente che apre il piano lo rilegge per intero.

## Vincoli globali

- Si scrive solo in un worktree `C:\develop\GIT\_wt\<repo>\<slug>` creato da `origin/develop`. Unica eccezione
  dichiarata: il primo commit del repo vuoto (task 1).
- Mai `rebase`, `reset`, `commit --amend`. `git branch --show-current` prima di ogni commit.
- Le PR vanno verso `develop` e le completa il titolare. Due PR per il repo degli attrezzi (dopo il task 10 e dopo il
  task 17), una per `Acme.AI` (task 9).
- Commit in stile Conventional Commits, messaggi multi-riga con `git commit -F - <<'EOF'`. L'ultima riga è
  `Co-Authored-By: <nome del modello> <noreply@anthropic.com>`, dove il nome è quello del modello che ha scritto il
  commit, mai un nome fisso.
- Modelli per l'esecuzione: Sonnet o Opus. Fable non si usa per i task.
- Il PAT si legge da `~/.claude/pat.txt` dentro il processo che fa la chiamata. Mai stampato, mai in un argomento,
  mai in un file del repo, mai in un test.
- Nessun nome di stato scritto nel codice: si usano le chiavi di `config/stati.json`.
- I file con percorsi Windows si scrivono con lo strumento Write, non con un heredoc di Bash (tronca e toglie le
  barre rovesciate).
- I test non chiamano né Azure DevOps né un modello: le chiamate REST e `claude` sono sostituiti da finti.
- Esecuzione: un task alla volta. Sonnet per i task di codice, Haiku per quelli meccanici. Una revisione Sonnet alla
  fine di ogni gruppo (task 4–6, 7–10, 11–14, 15–17), una revisione Opus per ciascuna delle due PR.
- Comando dei test: `Import-Module Pester -MinimumVersion 5.0`, poi `Invoke-Pester -Path tests -Output Detailed`,
  dalla radice del worktree. Atteso: 0 falliti, 0 saltati.

## Struttura dei file

Repo `DevOps.Agents`, working copy in `C:\develop\GIT\DevOps.Agents`.

| File | Responsabilità |
|---|---|
| `config/stati.json` | I nomi degli stati e dei tag, sotto chiavi stabili |
| `config/ruoli.json` | Per ruolo: modello, sforzo, strumenti, transizioni permesse, brief |
| `config/limiti.json` | I limiti della sezione 12 della spec e l'intervallo del giro |
| `config/mappa.json` | Area della card → repo, cartella, componente, pipeline e parametro di deploy |
| `src/Config.psm1` | Carica e convalida i quattro file |
| `src/Ado.psm1` | Le chiamate REST ad Azure DevOps. Nessuna regola |
| `src/Card.psm1` | Lettura compatta, commenti con prefisso, transizioni permesse al ruolo |
| `src/card.ps1` | Riga di comando su `Card.psm1`: è ciò che usano gli agenti |
| `src/Stato.psm1` | Il file di stato locale e il blocco di un giro |
| `src/Decisioni.psm1` | Funzione pura: istantanea di una card → elenco di azioni |
| `src/Worktree.psm1` | Crea e rimuove il worktree di una card |
| `src/Sessioni.psm1` | Lancia `claude -p`, legge l'esito, scrive il registro |
| `src/Smistatore.ps1` | Un giro: raccoglie, decide, esegue |
| `ruoli/responsabile.md`, `ruoli/dev.md`, `ruoli/reviewer.md` | I brief dei ruoli |
| `regole/SKILL.md` | La fonte unica delle regole di sviluppo |
| `hooks/*.ps1` | I due hook e le loro prove |
| `setup/Install-Attrezzi.ps1` | Collega regole e hook in `~/.claude`, registra l'operazione pianificata |
| `tests/*.Tests.ps1` | Un file di test per modulo |
| `docs/verifiche-pilota.md` | Gli esiti delle verifiche della sezione 14 della spec |

Dati locali, fuori da git, in `%LOCALAPPDATA%\DevOps.Agents\`: `stato.json`, `registro-sessioni.jsonl`,
`sessioni\<id>.jsonl`, `log\smistatore-<data>.log`.

---

## Fase 1: fondamenta

### Task 1: primo commit del repo degli attrezzi

**File:** crea `README.md`, `.gitignore`; sposta spec e piano da `C:\develop\GIT\docs\superpowers\`.

- [ ] **Passo 1:** clona il repo vuoto.

```bash
git clone https://acme.visualstudio.com/DevOps.Agents/_git/DevOps.Agents /c/develop/GIT/DevOps.Agents
```

- [ ] **Passo 2:** scrivi `README.md` (cos'è il repo in cinque righe, rimando alla spec) e `.gitignore` (`*.local.json`,
  `TestResults/`).
- [ ] **Passo 3:** copia `docs/superpowers/specs/` e `docs/superpowers/plans/` nel repo. Verifica con `diff -r` che le
  copie siano identiche, poi rimuovi `C:\develop\GIT\docs`.
- [ ] **Passo 4:** commit su `main` (`chore: primo commit con spec e piano`), `git push -u origin main`, poi
  `git branch develop && git push -u origin develop`.
- [ ] **Passo 5:** verifica: `git ls-remote --heads origin` mostra `main` e `develop`.

Da qui in poi vale la regola del worktree. Per i task 2–10:

```bash
git -C /c/develop/GIT/DevOps.Agents fetch origin
git -C /c/develop/GIT/DevOps.Agents worktree add /c/develop/GIT/_wt/DevOps.Agents/fondamenta -b feature/fondamenta origin/develop
```

### Task 2: verifiche su `claude -p`

Chiude le verifiche 3, 4, 5, 6, 8 e 9 della spec. Gli altri task dipendono dai nomi dei campi che escono da qui.

**File:** crea `docs/verifiche-pilota.md`.

**Produce:** per i task 14 e 15, i nomi esatti dei campi dell'evento finale e la combinazione di opzioni che lancia
una sessione senza richieste di permesso.

- [ ] **Passo 1:** lancia una sessione minima e salva l'uscita.

```bash
claude -p "Rispondi solo: ok" --model haiku --output-format json --strict-mcp-config --mcp-config '{"mcpServers":{}}'
```

  Annota i campi presenti. Attesi: `session_id`, `num_turns`, `duration_ms`, `is_error`, `result`, e sotto `usage`
  `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`.
- [ ] **Passo 2:** ripeti senza `--strict-mcp-config`. La differenza di `input_tokens` più `cache_creation_input_tokens`
  è il peso dei connettori sull'innesco.
- [ ] **Passo 3:** ripeti con `--output-format stream-json --verbose` e una richiesta che lancia un comando
  (`"Esegui: git --version"`). Annota i tipi di evento e se ne arriva uno per ogni chiamata di strumento.
- [ ] **Passo 4:** `claude --help` per i valori accettati da `--effort` e da `--permission-mode`. Poi trova la
  combinazione minima di `--allowedTools` e `--permission-mode` con cui una sessione esegue `git status` e modifica un
  file in una cartella di prova senza fermarsi. `--dangerously-skip-permissions` non è ammesso.
- [ ] **Passo 5:** riprendi la sessione del passo 1 con `--resume <id>` dopo 6 minuti e una seconda volta dopo 50.
  `cache_read_input_tokens` maggiore di zero dice che la cache era ancora calda.
- [ ] **Passo 6:** chiedi al titolare se le sessioni dei passi precedenti compaiono nell'app desktop.
- [ ] **Passo 7:** scrivi gli esiti in `docs/verifiche-pilota.md`, una riga per verifica della spec, con il valore
  misurato. Commit: `docs: esiti delle verifiche su claude -p`.

### Task 3: stati, campi e aree su Azure DevOps

Chiude la verifica 1. Si fa con chiamate REST dirette dalla sessione, senza lasciare uno script nel repo: è
un'operazione sola su un processo solo.

Processo `Custom.Agile`, id `00000000-0000-0000-0000-000000000000`. Prima di scrivere le chiamate, conferma i
percorsi sulla documentazione REST 7.1 ("Processes" → "Work Item Types", "States", "Fields").

| Stato | Categoria | Note |
|---|---|---|
| Draft | Proposed | Nuovo. Deve essere lo stato iniziale |
| New | Proposed | Di sistema |
| Needs clarification, Ready to develop, In development, In review, In test, Ready to merge | InProgress | Nuovi |
| Ready to release, Releasing | Resolved | Nuovi |
| Active, Resolved | | Di sistema, da nascondere |
| Closed | Completed | Di sistema |

- [ ] **Passo 1:** leggi i tipi del processo. Se User Story e Bug non sono ancora derivati, la prima chiamata è la
  derivazione: `POST _apis/work/processes/{id}/workitemtypes` con `inheritsFrom`.
- [ ] **Passo 2:** prepara l'elenco completo delle chiamate (stati da aggiungere, stati da nascondere, campi
  `Custom.TotalTokens` e `Custom.AgentMinutes` di tipo intero, area `DevOps.Agents\AI\Stime`) e mostralo
  al titolare. **Aspetta il suo sì.**
- [ ] **Passo 3:** esegui le chiamate per User Story, poi per Bug.
- [ ] **Passo 4:** rileggi gli stati dei due tipi e confrontali con la tabella.
- [ ] **Passo 5:** crea una User Story di prova nel progetto e guarda in che stato nasce. Se nasce in Draft, la
  verifica 1 è chiusa. Se nasce in New, applica il ripiego della spec: in `config/stati.json` (task 4) `bozza` vale
  `New` e `nuova` vale `Richiesta`, e lo stato Draft si rinomina di conseguenza.
- [ ] **Passo 6:** apri la board del progetto e controlla che ogni stato abbia la sua colonna nell'ordine della spec.
  Le colonne mancanti si aggiungono dalle impostazioni della board.
- [ ] **Passo 7:** annota l'esito in `docs/verifiche-pilota.md`. Commit: `docs: stati e campi del processo`.

### Task 4: configurazione

**File:** crea `config/stati.json`, `config/ruoli.json`, `config/limiti.json`, `config/mappa.json`,
`src/Config.psm1`, `tests/Config.Tests.ps1`.

**Produce:** `Get-Config` → oggetto con `Stati`, `Ruoli`, `Limiti`, `Mappa`. `Get-VoceMappa -Area <string>` → la riga
della mappa per quell'area, errore se manca.

```json
// config/stati.json
{ "bozza": "Draft", "nuova": "New", "daChiarire": "Needs clarification", "pronto": "Ready to develop",
  "inSviluppo": "In development", "inRevisione": "In review", "inTest": "In test",
  "daUnire": "Ready to merge", "daRilasciare": "Ready to release", "inRilascio": "Releasing",
  "chiusa": "Closed", "tagAgenti": "agents", "tagAttesa": "on-hold" }
```

```json
// config/ruoli.json
{ "responsabile": { "modello": "opus", "sforzo": "high", "brief": "ruoli/responsabile.md",
    "strumenti": ["Read", "Grep", "Glob", "Bash"],
    "transizioni": [["nuova", "pronto"], ["nuova", "daChiarire"], ["daChiarire", "pronto"],
                    ["inSviluppo", "daChiarire"], ["inTest", "daUnire"], ["inTest", "inSviluppo"]] },
  "dev": { "modello": "sonnet", "sforzo": null, "brief": "ruoli/dev.md",
    "strumenti": ["Read", "Write", "Edit", "Grep", "Glob", "Bash"], "transizioni": [] },
  "reviewer": { "modello": "opus", "sforzo": "high", "brief": "ruoli/reviewer.md",
    "strumenti": ["Read", "Grep", "Glob", "Bash"], "transizioni": [] } }
```

```json
// config/limiti.json
{ "sessioniAttive": 1, "cardInSviluppoPerRepo": 1, "cardInTestPerComponente": 1, "giriRevisione": 2,
  "rosseDiFila": 3, "silenzioMinuti": 15, "intervalloMinuti": 2, "sogliaResumeMinuti": 0 }
```

```json
// config/mappa.json
{ "aree": [ { "area": "DevOps.Agents\\AI\\Stime", "repo": "Acme.AI",
    "cartella": "C:/develop/GIT/Acme.AI", "progettoAdo": "Acme.AI",
    "componente": "stime", "pipelineDeploy": 115, "parametroDeploy": "deployStime" } ] }
```

`sogliaResumeMinuti` a 0 vuol dire "mai riprendere": resta così finché il task 2 non ha misurato la cache. `scout`
non è tra i ruoli: non serve al pilota.

- [ ] **Passo 1:** scrivi i test. Casi: carica i quattro file; errore se in `ruoli.json` una transizione usa una
  chiave assente da `stati.json`; errore se un `brief` non esiste; `Get-VoceMappa` restituisce la riga giusta; errore
  con area sconosciuta.
- [ ] **Passo 2:** lancia i test, attesi falliti (`Get-Config` non esiste).
- [ ] **Passo 3:** scrivi i file di configurazione e `Config.psm1`.
- [ ] **Passo 4:** lancia i test, attesi verdi.
- [ ] **Passo 5:** commit: `feat: configurazione di stati, ruoli, limiti e mappa`.

### Task 5: chiamate ad Azure DevOps

Chiude la verifica 2 per la parte di scrittura sulle card.

**File:** crea `src/Ado.psm1`, `tests/Ado.Tests.ps1`.

**Produce** (nessuna funzione riceve il PAT: lo carica una funzione privata del modulo):

```powershell
Get-AdoCardAttive                      # card con tag `agents`, non Draft né Closed → [Card]
Get-AdoCard -Id <int>                  # → Card: Id, Rev, Tipo, Titolo, Descrizione, Criteri, Stato, Tag, Area, CreataDa
Set-AdoCard -Id -Stato -AggiungiTag -TogliTag -Criteri -Campi   # tutti facoltativi → nuova Rev
Get-AdoStoriaStato -Id <int>           # → [{ Rev, Da, A, Chi, Quando }]
Get-AdoCommenti -Id <int> -DopoId <int>  # → [{ Id, Autore, Testo, Quando }]
Add-AdoCommento -Id -Testo -Menziona   # Menziona: id utente, facoltativo → Id del commento
Get-AdoPr -Progetto -Repo -Ramo        # → $null oppure { Id, Stato, Validazione, BuildId, UrlLog }
New-AdoPr -Progetto -Repo -Ramo -Titolo -Descrizione -CardId   # verso develop → Id
Complete-AdoPr -Progetto -Repo -Id
Start-AdoDeployTest -Progetto -PipelineId -Ramo -Parametro     # → RunId
Get-AdoRun -Progetto -RunId            # → { Stato, Esito }
Get-AdoUtenteCorrente                  # → { Id, Nome }: il titolare del PAT
```

`Validazione` vale `verde`, `rossa`, `inCorso` o `assente`, e riguarda sempre l'ultimo commit del ramo: se la build
più recente è di un commit precedente vale `inCorso`. Così un esito vecchio non fa partire niente dopo un nuovo push.
La descrizione di una PR finisce con `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

- [ ] **Passo 1:** scrivi i test con `Mock Invoke-RestMethod`. Un caso per funzione, che controlla metodo, percorso
  e corpo della chiamata e la forma dell'oggetto restituito. In più: `Get-AdoPr` traduce gli esiti delle policy nei
  quattro valori di `Validazione`; una build verde di un commit precedente dà `inCorso`; nessuna funzione scrive il
  PAT in un messaggio di errore.
- [ ] **Passo 2:** lancia i test, attesi falliti.
- [ ] **Passo 3:** scrivi `Ado.psm1`.
- [ ] **Passo 4:** lancia i test, attesi verdi.
- [ ] **Passo 5:** prova vera sulla card di prova del task 3: leggi, commenta, aggiungi e togli un tag, scrivi
  `Custom.TotalTokens`, sposta di stato, rileggi. Se una scrittura è rifiutata per permessi, fermati e dillo a
  Il titolare: manca uno scope al PAT. Annota l'esito in `docs/verifiche-pilota.md`.
- [ ] **Passo 6:** commit: `feat: chiamate ad Azure DevOps`.

### Task 6: lo script `card`

**File:** crea `src/Card.psm1`, `src/card.ps1`, `tests/Card.Tests.ps1`.

**Consuma:** `Get-Config`, le funzioni di `Ado.psm1`, `Add-RevNostra` di `Stato.psm1` (task 11; fino ad allora è
sostituita da un finto nei test).

**Produce:**

```powershell
Read-Card -Id <int>                          # testo compatto: titolo, descrizione, criteri, ultimi 10 commenti
Add-CardCommento -Id -Ruolo -Testo           # scrive "[ruolo] testo" più la riga di attribuzione
Set-CardCriteri -Id -Ruolo -Testo            # solo responsabile
Move-Card -Id -Ruolo -Stato                  # Stato è una chiave di stati.json; errore se la transizione non è del ruolo
```

```
pwsh -NoProfile -File C:/develop/GIT/DevOps.Agents/src/card.ps1 leggi
pwsh -NoProfile -File C:/develop/GIT/DevOps.Agents/src/card.ps1 sposta <chiave dello stato>
@'
<testo>
'@ | pwsh -NoProfile -File C:/develop/GIT/DevOps.Agents/src/card.ps1 commenta
@'
<testo>
'@ | pwsh -NoProfile -File C:/develop/GIT/DevOps.Agents/src/card.ps1 criteri
```

Il testo di `commenta` e `criteri` arriva solo da stdin, mai come argomento: passato dall'interprete dei comandi, `$`, i
backtick e un trattino iniziale lo alterano, e un argomento dà errore con l'indicazione di usare stdin.

`card.ps1` non prende né l'id né il ruolo dagli argomenti: li legge dalle variabili d'ambiente `ATTREZZI_CARD` e
`ATTREZZI_RUOLO`, che imposta lo smistatore al lancio. Così una sessione non può scrivere su un'altra card. La riga di
attribuzione è `— scritto da Claude (<ruolo>)`.

- [ ] **Passo 1:** scrivi i test. Casi: `Read-Card` non supera i 10 commenti e li mette dal più vecchio al più nuovo;
  `Add-CardCommento` aggiunge prefisso e attribuzione; `Move-Card` accetta `nuova → pronto` per `responsabile`;
  `Move-Card` rifiuta `inRevisione → inTest` per `responsabile` e qualunque transizione per `dev`; `Move-Card`
  registra la revisione scritta con `Add-RevNostra`; `Set-CardCriteri` rifiuta `dev`; `card.ps1` esce con codice 1 e
  un messaggio se manca una variabile d'ambiente.
- [ ] **Passo 2:** lancia i test, attesi falliti.
- [ ] **Passo 3:** scrivi `Card.psm1` e `card.ps1`.
- [ ] **Passo 4:** lancia i test, attesi verdi.
- [ ] **Passo 5:** commit: `feat: script card con transizioni per ruolo`.

### Task 7: la fonte delle regole

**File:** crea `regole/SKILL.md`.

**Fonti da leggere:** `C:\develop\personal\bb-project\docs\app-behaviours-rules.md` (Parte 1),
`C:\develop\personal\bb-project\docs\notes\code-craft-senior-solid.md`, le regole G1–G7 in
`docs/audit/2026-11-16-best-practice.md` del ramo `origin/fix/audit-hardening` di `Acme.AI`, la sezione 8 della
spec.

Intestazione: `name: regole-sviluppo`, `description:` che la fa caricare a chi scrive o rivede codice in un repo di
Il titolare.

- [ ] **Passo 1:** scrivi la skill. Contenuto, nell'ordine: regola zero; R1 con i cinque principi, ciascuno in una
  riga più la domanda che lo verifica; i quattro passi da fare prima di scrivere; R2; le regole G1–G7 che non sono già
  coperte dai punti precedenti; il controllo della responsabilità singola con l'esito scritto richiesto a `reviewer`.
- [ ] **Passo 2:** controlla che non contenga nomi di tipi, tabelle o file di `bb-project` o di `Acme.AI`: i
  guasti specifici restano nei `CLAUDE.md` dei repo. `grep -n -i 'bb-project\|Acme.AI\|Stime' regole/SKILL.md`
  non deve restituire righe.
- [ ] **Passo 3:** passa il file a Vale con le regole della skill `manual-writing`. Zero errori.
- [ ] **Passo 4:** commit: `docs: fonte unica delle regole di sviluppo`.

Il documento di `bb-project` non si tocca in questo piano: la sostituzione della sua Parte 1 con un rimando è una
delle ipotesi ancora da confermare nella spec.

### Task 8: i brief dei ruoli

**File:** crea `ruoli/responsabile.md`, `ruoli/dev.md`, `ruoli/reviewer.md`.

**Fonti:** `~/.claude/skills/responsabile/SKILL.md`, `~/.claude/agents/dev.md`, `~/.claude/agents/reviewer.md`. Si
conserva il contenuto e si adatta alla card.

**Produce**, per il task 12: ogni sessione finisce con una riga `ESITO=<valore>` come ultima riga della risposta.

| Ruolo | Valori di `ESITO` |
|---|---|
| `responsabile` | `fatto`, `domande` |
| `dev` | `fatto`, `bivio`, `bloccato` |
| `reviewer` | `superata`, `bloccante` |

Ogni brief dice, oltre a ciò che già dicono le fonti:

- come si legge e si scrive la card: i quattro comandi di `card.ps1` del task 6, e niente altro;
- che le regole di sviluppo stanno nella skill `regole-sviluppo`, da caricare prima di scrivere o rivedere;
- che nei commenti e nelle domande non vanno codice né dati di clienti: si cita `file:riga`;
- che l'ultima riga di ogni commit è `Co-Authored-By:` con il nome del modello della sessione;
- la riga `ESITO` e cosa significa ciascun valore.

Specifico per ruolo: `responsabile` legge il repo da `origin/develop` con `git show` e `git grep`, mai dalla working
copy, scrive i criteri con `card criteri` e ogni decisione come una riga con il suo riferimento. `dev` committa e fa
`git push` del ramo, non apre la PR (la apre lo smistatore) e con `ESITO=bivio` scrive il bivio e le ipotesi in un
commento. `reviewer` scrive un commento solo, con una riga per file toccato che ne dichiara la ragione per cambiare,
poi i rilievi con `file:riga`.

- [ ] **Passo 1:** scrivi i tre brief.
- [ ] **Passo 2:** controlla che ognuno nomini i quattro comandi, la skill `regole-sviluppo` e i suoi valori di
  `ESITO`: `grep -c 'ESITO=' ruoli/*.md` dà almeno 2 per file.
- [ ] **Passo 3:** passa i file a Vale. Zero errori.
- [ ] **Passo 4:** commit: `docs: brief dei ruoli`.

### Task 9: `CLAUDE.md` di `Acme.AI`

Si fa nel repo `Acme.AI`, in un worktree suo: `C:\develop\GIT\_wt\Acme.AI\claude-md`, ramo
`docs/claude-md`.

**File:** crea `CLAUDE.md` nella radice.

**Fonti:** `azure-pipelines/build-paths.json`, `docs/test-condizionati-preventivi.md`,
`.claude/skills/deploy-test/SKILL.md` della working copy principale, il registro dell'audit sul ramo
`origin/fix/audit-hardening`.

- [ ] **Passo 1:** scrivi il file, al più 60 righe. Sezioni: il recinto (rimando a `build-paths.json`, con la regola
  che fuori non si tocca); come si lanciano i test e quanti ne devono girare per progetto; come si va in Test; le
  guardie a macchina che esistono oggi, ciascuna con il test che la verifica; l'elenco delle eccezioni dichiarate (le
  violazioni di M2 e M5 che l'audit ha trovato, con `file:riga`).
- [ ] **Passo 2:** per ogni guardia citata, verifica che il test esista: `git grep -n '<nome del test>' origin/develop`.
  Una regola dell'audit che non ha ancora una guardia si elenca come "senza guardia", non come verificata.
- [ ] **Passo 3:** commit, `git push`, apri la PR verso `develop` con la skill `pr-ado`. La completa il titolare.

### Task 10: hook e regole a livello utente

**File:** crea `hooks/deny-commit-outside-worktree.ps1`, `hooks/deny-secrets-in-repo.ps1`, `hooks/Test-Hooks.ps1`
(copiati da `C:\develop\GIT\Acme.AI\.claude\hooks\`), `hooks/deny-pat.ps1`, `setup/Install-Attrezzi.ps1`,
`tests/Install.Tests.ps1`.

`deny-pat.ps1` è un hook nuovo su `Bash` e `Read`: rifiuta un comando o una lettura che nomina `pat.txt` o
`AZURE_DEVOPS_EXT_PAT`, a meno che il comando sia una chiamata a `card.ps1`. È un presidio, non una recinzione: tiene
il PAT fuori dal contesto di un modello che non lo sta cercando apposta.

**Produce:** `Install-Attrezzi.ps1 -Hook -Regole` (il parametro `-Pianificazione` arriva con il task 17).

- `-Regole` crea la giunzione `~/.claude/skills/regole-sviluppo` → `regole/` del repo.
- `-Hook` aggiunge a `~/.claude/settings.json` le tre voci `PreToolUse`, senza toccare le altre chiavi e senza
  duplicare una voce già presente. Prima salva una copia del file accanto all'originale.

- [ ] **Passo 1:** scrivi i test. Casi per `Install-Attrezzi` su una cartella finta al posto di `~/.claude`: aggiunge
  le tre voci a un file che ha solo `Notification`; lanciato due volte non duplica; conserva le altre chiavi; crea la
  copia di salvataggio. Casi nuovi in `Test-Hooks.ps1`: `cat ~/.claude/pat.txt` rifiutato; una chiamata a `card.ps1`
  passa; un commit nella working copy di un repo diverso da `Acme.AI` è rifiutato.
- [ ] **Passo 2:** lancia i test, attesi falliti.
- [ ] **Passo 3:** copia i due hook, scrivi `deny-pat.ps1` e `Install-Attrezzi.ps1`.
- [ ] **Passo 4:** lancia i test e `pwsh -NoProfile -File hooks/Test-Hooks.ps1`, attesi verdi.
- [ ] **Passo 5:** commit: `feat: hook e regole a livello utente`.
- [ ] **Passo 6:** revisione Opus del ramo, `git push`, PR verso `develop`. **Aspetta che il titolare la completi.**
- [ ] **Passo 7:** dopo il merge: aggiorna la working copy principale (`git -C ... pull`), poi chiedi al titolare il sì
  per lanciare `Install-Attrezzi.ps1 -Hook -Regole`. L'hook sui commit varrà in ogni repo aperto con Claude Code,
  `bb-project` compreso. Dopo l'installazione togli le due voci da `C:\develop\GIT\Acme.AI\.claude\settings.json`,
  che altrimenti scatterebbero due volte.
- [ ] **Passo 8:** rimuovi il worktree `fondamenta` e il ramo, locale e remoto.

---

## Fase 2: smistatore minimo e pilota

Worktree: `C:\develop\GIT\_wt\DevOps.Agents\smistatore`, ramo `feature/smistatore`, da `origin/develop`
dopo il merge della prima PR.

### Task 11: stato locale

**File:** crea `src/Stato.psm1`, `tests/Stato.Tests.ps1`.

**Produce:**

```powershell
Get-Stato [-Percorso]                 # → tabella: id card → StatoCard. File assente → tabella vuota
Save-Stato -Stato [-Percorso]         # scrittura atomica: file temporaneo, poi sostituzione
Get-StatoCard -Stato -Id              # → StatoCard, creato vuoto se manca
Add-RevNostra -Id -Rev                # registra una revisione scritta da noi
Enter-Giro / Exit-Giro                # mutex con nome: un giro alla volta. Enter-Giro → $false se già preso
```

```json
// StatoCard
{ "ultimoCommento": 0, "revNostre": [], "giriRevisione": 0, "rosseDiFila": 0, "rossaGestita": null,
  "inAttesaPer": null, "avvisi": [], "ramo": null, "cartella": null, "prId": null,
  "runId": null, "runDopoRev": null, "sessione": null, "ultimoRuolo": null, "ultimaSessione": {} }
```

`sessione` è `null` oppure `{ id, ruolo, pid, avviata, ripresa }`. `ultimaSessione` ha una voce per ruolo:
`{ id, fine, esito, testo }`; `ultimoRuolo` è il ruolo della sessione finita per ultima. `rossaGestita` è il `BuildId`
dell'ultima validazione rossa per cui è già partito un `dev`. `inAttesaPer` vale `null`, `sessione` o `limite`.
`runDopoRev` è la revisione con cui la card è entrata in In test quando è stato accodato `runId`. Ogni voce di
`avvisi` è `<tipo>@<revisione dell'ultimo cambio di stato>`, così un avviso riparte se la card rifà il giro.

- [ ] **Passo 1:** scrivi i test. Casi: file assente dà tabella vuota; salva e rilegge senza perdite;
  `Get-StatoCard` crea la voce con i valori predefiniti; `Add-RevNostra` non duplica; `Enter-Giro` chiamato due volte
  restituisce `$false` la seconda; un salvataggio interrotto non lascia un file a metà.
- [ ] **Passo 2:** lancia i test, attesi falliti.
- [ ] **Passo 3:** scrivi `Stato.psm1`.
- [ ] **Passo 4:** lancia i test, attesi verdi.
- [ ] **Passo 5:** commit: `feat: stato locale dello smistatore`.

### Task 12: le decisioni

Il cuore dello smistatore: una funzione pura, senza chiamate esterne.

**File:** crea `src/Decisioni.psm1`, `tests/Decisioni.Tests.ps1`.

**Produce:**

```powershell
Get-Azioni -Istantanea <hashtable> -Contesto <hashtable>    # → [Azione], nell'ordine in cui vanno eseguite
```

`Istantanea`: `Card`, `Commenti` (quelli dopo `ultimoCommento`), `Storia`, `Pr`, `Run`, `StatoCard`, `Voce` (la riga
della mappa). `Contesto`: `Stati`, `Limiti`, `SessioniAttive`, `InSviluppoPerRepo`, `InTestPerComponente`,
`il titolare` (id utente).

Azioni, ciascuna una tabella con `Tipo` e i suoi campi:

| `Tipo` | Campi |
|---|---|
| `LanciaSessione` | `Ruolo`, `Motivo`, `Allegato`, `Riprendi` (forza `--resume`) |
| `SpostaCard` | `Stato` |
| `CreaWorktree`, `RimuoviWorktree`, `ApriPr`, `CompletaPr`, `AccodaDeployTest` | nessuno |
| `RiportaIndietro` | `Stato`, `Motivo` |
| `MettiInAttesa` | `Motivo` |
| `Avvisa` | `Chi` (`titolare` o `richiedente`), `Testo` |

Le definizioni che la funzione usa:

- un commento è "di una persona" se il testo non comincia con `[responsabile]`, `[dev]`, `[reviewer]` o
  `[smistatore]`;
- uno spostamento è "un gesto del titolare" se la revisione che l'ha fatto ha `Chi` uguale a `il titolare` e non è in
  `revNostre`;
- la revisione è "superata" se l'ultima sessione di `reviewer` ha esito `superata` ed è finita dopo l'ultima di `dev`.
  Non è un valore salvato: si ricava, così decade da sola quando `dev` rimette mano al codice;
- un run "vale" se `runDopoRev` è la revisione dell'ultimo ingresso della card in In test.

Casi di test, uno per riga. Dove non è detto, la card ha il tag `agents`, non ha `on-hold` e non ha una sessione
attiva.

| # | Situazione | Azioni attese |
|---|---|---|
| 1 | Draft | nessuna |
| 2 | Tag `on-hold` | nessuna |
| 3 | Sessione attiva sulla card | nessuna |
| 4 | New | `LanciaSessione responsabile` |
| 5 | New, limite di sessioni attive raggiunto | nessuna |
| 6 | Needs clarification, commento nuovo di una persona | `LanciaSessione responsabile` |
| 7 | Needs clarification, commento nuovo `[responsabile] …` | nessuna |
| 8 | Ready to develop | `CreaWorktree`, `SpostaCard inSviluppo`, `LanciaSessione dev` |
| 9 | Ready to develop, un'altra card dello stesso repo è In development | nessuna |
| 10 | In development, `dev` finito con `fatto`, PR assente | `ApriPr` |
| 11 | In development, `dev` finito con `bivio` | `LanciaSessione responsabile` con il testo del bivio |
| 12 | In development, `dev` finito con `bloccato` | `MettiInAttesa` |
| 13 | In development, validazione rossa di una build non gestita, `rosseDiFila` 1 | `LanciaSessione dev` con l'indirizzo del log |
| 13b | In development, validazione rossa di una build già gestita | nessuna |
| 14 | In development, validazione rossa di una build non gestita, `rosseDiFila` 3 | `MettiInAttesa` |
| 15 | In development, validazione in corso | nessuna |
| 16 | In development, validazione verde | `SpostaCard inRevisione`, `LanciaSessione reviewer` |
| 17 | In review, `reviewer` `bloccante`, `giriRevisione` 1 | `SpostaCard inSviluppo`, `LanciaSessione dev` con i rilievi |
| 18 | In review, `reviewer` `bloccante`, `giriRevisione` 2 | `MettiInAttesa` |
| 19 | In review, `reviewer` `superata`, avviso non ancora mandato | `Avvisa titolare` |
| 20 | In review, `reviewer` `superata`, avviso già mandato | nessuna |
| 21 | In test per gesto del titolare, revisione superata, nessun run | `AccodaDeployTest` |
| 22 | In test spostata da un altro utente | `RiportaIndietro inRevisione` |
| 23 | In test, revisione non superata | `RiportaIndietro` allo stato precedente |
| 24 | In test, un'altra card dello stesso componente è in test | `RiportaIndietro inRevisione` |
| 25 | In test, run riuscito, avviso non ancora mandato | `Avvisa richiedente` |
| 26 | In test, run fallito | `MettiInAttesa` |
| 27 | In test, run riuscito, commento nuovo di una persona | `LanciaSessione responsabile` |
| 28 | Ready to release per gesto del titolare, PR aperta | `CompletaPr` |
| 29 | Ready to release spostata da un altro utente | `RiportaIndietro daUnire` |
| 30 | Ready to release, PR completata, worktree presente | `RimuoviWorktree` |
| 31 | Ultima sessione finita senza riga `ESITO` | `MettiInAttesa` |
| 32 | New, `responsabile` finito e card ancora in New | `MettiInAttesa` |
| 33 | In development, l'ultima sessione finita è di `responsabile` con `fatto` | `LanciaSessione dev` con l'ultimo commento di `responsabile` |
| 34 | Tag `on-hold` tolto, `inAttesaPer` vale `sessione` | `LanciaSessione` dello stesso ruolo con `Riprendi` |
| 35 | Tag `on-hold` tolto, `inAttesaPer` vale `limite` | contatori azzerati, poi le azioni normali dello stato |

Il caso 33 copre due percorsi: `responsabile` che risolve un bivio di `dev` con una decisione, e una verifica in Test
non confermata che riporta la card in sviluppo.

- [ ] **Passo 1:** scrivi i casi della tabella come test guidati da tabella, con un costruttore di istantanee che parte da una
  card valida e cambia solo ciò che il caso richiede.
- [ ] **Passo 2:** lancia i test, attesi falliti.
- [ ] **Passo 3:** scrivi `Decisioni.psm1`. Una funzione privata per stato; `Get-Azioni` sceglie quale chiamare.
- [ ] **Passo 4:** lancia i test, attesi verdi.
- [ ] **Passo 5:** commit: `feat: decisioni dello smistatore`.

### Task 13: worktree della card

**File:** crea `src/Worktree.psm1`, `tests/Worktree.Tests.ps1`.

**Produce:**

```powershell
New-WorktreeCard -Voce -Card       # → { Cartella, Ramo }. Se esiste già lo restituisce senza rifarlo
Remove-WorktreeCard -Voce -Ramo -Cartella    # errore se git status --porcelain non è vuoto
```

Cartella: `C:\develop\GIT\_wt\<repo>\card-<id>`. Ramo: `feature/<id>-<slug>` per una User Story, `fix/<id>-<slug>`
per un Bug; `<slug>` sono le prime cinque parole del titolo in minuscolo, senza accenti, unite da trattini. La base è
sempre `origin/develop`, dopo `git fetch origin`.

- [ ] **Passo 1:** scrivi i test su un repo git temporaneo con un remote locale. Casi: crea cartella e ramo da
  `origin/develop`; chiamata due volte non fallisce e non crea un secondo ramo; lo slug di "Aggiungi l'età minima al
  preventivo" è `aggiungi-l-eta-minima-al`; un Bug dà `fix/`; `Remove-WorktreeCard` si rifiuta con un file non
  tracciato; con il worktree pulito rimuove cartella e ramo locale.
- [ ] **Passo 2:** lancia i test, attesi falliti.
- [ ] **Passo 3:** scrivi `Worktree.psm1`.
- [ ] **Passo 4:** lancia i test, attesi verdi.
- [ ] **Passo 5:** commit: `feat: worktree per card`.

### Task 14: sessioni e registro

**File:** crea `src/Sessioni.psm1`, `tests/Sessioni.Tests.ps1`, `tests/finti/claude-finto.ps1`.

**Consuma:** i nomi dei campi e le opzioni di permesso annotati nel task 2.

**Produce:**

```powershell
Start-SessioneRuolo -Card -Ruolo -Messaggio -Cartella -Riprendi <id|$null>   # → { Id, Pid, Ripresa }
Get-EsitoSessione -Id       # → { Finita, Errore, Esito, Testo, UltimoEvento, Turni, DurataMs,
                            #     TokenIn, TokenOut, CacheLetti, CacheScritti }
Stop-Sessione -Pid
Write-RegistroSessione -Riga    # aggiunge una riga a registro-sessioni.jsonl
Test-Riprendibile -UltimaSessione -Limiti    # → $true se la fine è entro sogliaResumeMinuti
```

`Start-SessioneRuolo` lancia `claude` come processo separato, con l'uscita su `sessioni\<id>.jsonl`:

```
claude -p "<messaggio>" --model <modello> [--effort <sforzo>] --output-format stream-json --verbose
  --session-id <uuid nuovo> | --resume <id>
  --append-system-prompt-file <brief> --allowedTools <strumenti> --strict-mcp-config --mcp-config {"mcpServers":{}}
  <le opzioni di permesso trovate nel task 2>
```

con le variabili d'ambiente `ATTREZZI_CARD` e `ATTREZZI_RUOLO`. Il percorso dell'eseguibile è un parametro del
modulo: i test lo puntano a `claude-finto.ps1`, che scrive sull'uscita gli eventi letti da un file.

`Esito` è il valore dell'ultima riga `ESITO=` del testo finale, `$null` se manca. Riga del registro:

```json
{ "card": 0, "repo": "", "ruolo": "", "modello": "", "sforzo": null, "sessione": "", "ripresa": false,
  "inizio": "", "fine": "", "turni": 0, "esito": "", "tokenIn": 0, "tokenOut": 0, "cacheLetti": 0, "cacheScritti": 0 }
```

- [ ] **Passo 1:** scrivi il finto e i test. Casi: la riga di comando contiene modello, sforzo e brief del ruolo;
  `--effort` è assente quando lo sforzo è `null`; con `-Riprendi` c'è `--resume` e non `--session-id`;
  `Get-EsitoSessione` su una sessione in corso dà `Finita` falso e `UltimoEvento` valorizzato; su una finita dà esito
  e i quattro numeri di token; su un testo senza `ESITO=` dà `Esito` nullo; su un evento finale con errore dà `Errore`
  vero; `Write-RegistroSessione` aggiunge una riga JSON valida senza riscrivere le precedenti; `Test-Riprendibile` è
  falso con soglia 0.
- [ ] **Passo 2:** lancia i test, attesi falliti.
- [ ] **Passo 3:** scrivi `Sessioni.psm1`.
- [ ] **Passo 4:** lancia i test, attesi verdi.
- [ ] **Passo 5:** commit: `feat: sessioni dei ruoli e registro dei consumi`.

### Task 15: il giro dello smistatore

**File:** crea `src/Smistatore.ps1`, `tests/Smistatore.Tests.ps1`.

**Consuma:** tutti i moduli precedenti.

**Produce:** `pwsh -NoProfile -File src/Smistatore.ps1 [-Card <id>] [-WhatIf]`. Con `-WhatIf` stampa le azioni e non
esegue niente. Codice di uscita 0 anche se una card fallisce: l'errore va nel log e sulla card.

Un giro, nell'ordine:

1. `Enter-Giro`; se è già preso, esce.
2. Per ogni card con una sessione nello stato: `Get-EsitoSessione`. Se è finita scrive il registro, somma token e
   minuti nei campi della card, sposta la sessione in `ultimaSessione`, aggiorna `ultimoRuolo` e i contatori
   (`giriRevisione` dopo un `reviewer` `bloccante`). Se `UltimoEvento` è più vecchio di `silenzioMinuti`,
   `Stop-Sessione` e tag `on-hold`.
3. Per ogni card attiva, o per quella di `-Card`: costruisce l'istantanea, chiama `Get-Azioni`, esegue le azioni
   nell'ordine. Un'azione che fallisce ferma le successive della stessa card e la mette in `on-hold` con il motivo.
4. `Save-Stato`, `Exit-Giro`.

Come si esegue ogni azione:

| Azione | Esecuzione |
|---|---|
| `LanciaSessione` | `Start-SessioneRuolo`, con `-Riprendi` se l'azione lo chiede o se `Test-Riprendibile`. Cartella: il worktree se c'è, altrimenti la cartella del repo. Poi un commento `[smistatore]` con id della sessione, ruolo e cartella. Con ruolo `dev` dopo una rossa salva `rossaGestita` |
| `SpostaCard`, `RiportaIndietro` | `Set-AdoCard`, poi `Add-RevNostra`. `RiportaIndietro` aggiunge un commento `[smistatore]` con il motivo |
| `CreaWorktree`, `RimuoviWorktree` | `Worktree.psm1`; salva o azzera `ramo` e `cartella` nello stato |
| `ApriPr` | `New-AdoPr`, titolo dalla card; salva `prId` |
| `MettiInAttesa` | Tag `on-hold`, commento `[smistatore]` con il motivo e menzione al titolare; salva `inAttesaPer` |
| `AccodaDeployTest` | Salva anche `runDopoRev` |
| `Avvisa` | Commento `[smistatore]` con menzione; segna l'avviso in `avvisi` |
| `AccodaDeployTest`, `CompletaPr` | Task 16. Fino ad allora: errore "non ancora disponibile" |

Il messaggio passato a una sessione ha tre righe: `Card <id> nel repo <repo>.`, `Motivo: <motivo>.`, l'allegato.

- [ ] **Passo 1:** scrivi i test con `Ado.psm1` e `Sessioni.psm1` sostituiti da finti. Casi: una card in New fa
  partire `responsabile` e salva la sessione nello stato; al giro dopo, a sessione finita, il registro ha una riga e i
  campi della card sono aggiornati; una sessione silenziosa viene chiusa e la card va in `on-hold`; `-WhatIf` non
  chiama nessuna funzione che scrive; `-Card` tocca solo quella card; un'azione che lancia un errore mette la card in
  `on-hold` e il giro continua con le altre; due giri sovrapposti: il secondo esce subito.
- [ ] **Passo 2:** lancia i test, attesi falliti.
- [ ] **Passo 3:** scrivi `Smistatore.ps1`.
- [ ] **Passo 4:** lancia i test, attesi verdi.
- [ ] **Passo 5:** commit: `feat: giro dello smistatore`.

### Task 16: deploy in Test e merge

Le due azioni che partono solo da un gesto del titolare. Chiude le verifiche 2 (completare una PR) e 7.

**File:** modifica `src/Smistatore.ps1` (le due righe della tabella del task 15), `tests/Smistatore.Tests.ps1`.

- `AccodaDeployTest`: `Start-AdoDeployTest` con pipeline e parametro presi dalla voce della mappa e il ramo della
  card; salva `runId`. Passa solo il parametro del componente: nessun altro parametro dell'orchestratore viene
  toccato.
- `CompletaPr`: `Complete-AdoPr`. Se Azure DevOps rifiuta per una policy non soddisfatta, la card va in `on-hold` con
  il testo dell'errore.

- [ ] **Passo 1:** scrivi i test. Casi: `AccodaDeployTest` chiama `Start-AdoDeployTest` con pipeline 115, parametro
  `deployStime` e il ramo della card, e salva il run; `CompletaPr` chiama `Complete-AdoPr` con il `prId` dello
  stato; un rifiuto di `Complete-AdoPr` mette la card in `on-hold`.
- [ ] **Passo 2:** lancia i test, attesi falliti.
- [ ] **Passo 3:** sostituisci i due errori "non ancora disponibile" con l'esecuzione.
- [ ] **Passo 4:** lancia i test, attesi verdi.
- [ ] **Passo 5:** commit: `feat: deploy in Test e merge dai gesti del titolare`.

### Task 17: operazione pianificata

**File:** modifica `setup/Install-Attrezzi.ps1`, `tests/Install.Tests.ps1`, `README.md`.

**Produce:** `Install-Attrezzi.ps1 -Pianificazione` registra l'operazione `DevOps.Agents\Smistatore`, che
lancia `Smistatore.ps1` dalla working copy principale ogni `intervalloMinuti`, solo a utente collegato, senza
finestra. `-RimuoviPianificazione` la toglie.

- [ ] **Passo 1:** scrivi i test con `Mock Register-ScheduledTask`. Casi: l'azione punta a `src/Smistatore.ps1` della
  working copy principale e non di un worktree; l'intervallo viene da `limiti.json`; lanciato due volte aggiorna
  l'operazione esistente.
- [ ] **Passo 2:** lancia i test, attesi falliti.
- [ ] **Passo 3:** aggiungi i due parametri. Nel `README.md` aggiungi come si lancia un giro a mano, come si ferma
  la pianificazione, dove stanno log, stato e registro.
- [ ] **Passo 4:** lancia tutti i test del repo, attesi verdi.
- [ ] **Passo 5:** commit: `feat: operazione pianificata dello smistatore`.
- [ ] **Passo 6:** revisione Opus del ramo, `git push`, PR verso `develop`. **Aspetta che il titolare la completi.**
  Poi aggiorna la working copy principale e rimuovi worktree e ramo.

### Task 18: il pilota

Nessun file di codice. La pianificazione resta spenta: ogni giro si lancia a mano, prima con `-WhatIf`.

- [ ] **Passo 1: prova a secco.** Crea una User Story di prova in `DevOps.Agents` con il tag `agents`, in
  Draft. `Smistatore.ps1 -WhatIf`: nessuna azione. Spostala in New, `-WhatIf`: `LanciaSessione responsabile`.
- [ ] **Passo 2: la card vera.** Il titolare sceglie e scrive la card pilota, nell'area `AI\Stime`. Una
  candidata è allineare `stime pr-validation` a `stime build-ci`; la scelta è sua.
- [ ] **Passo 3: da New a In review.** Un giro alla volta, guardando dopo ognuno il log, la card e il registro.
  A ogni sessione finita annota in `docs/verifiche-pilota.md` ruolo, token e minuti.
- [ ] **Passo 4: il via al deploy in Test.** Il titolare sposta la card in In test. Dopo il giro, guarda se il run si
  ferma allo stadio `Approval`: è l'esito della verifica 7.
- [ ] **Passo 5: la verifica in Test e il merge.** Il titolare, da richiedente, conferma sulla card; poi sposta la card
  in Ready to release. Controlla che la PR sia completata e il worktree rimosso.
- [ ] **Passo 6: i conti.** Dal registro: token e minuti per ruolo, peso dell'innesco, numero di turni. Con la durata
  della cache misurata nel task 2, proponi al titolare il valore di `sogliaResumeMinuti`.
- [ ] **Passo 7: accendere la pianificazione.** Solo dopo il sì del titolare: `Install-Attrezzi.ps1 -Pianificazione`.
- [ ] **Passo 8:** scrivi in `docs/verifiche-pilota.md` cosa ha funzionato, cosa no e cosa cambia nella spec. Commit
  in un worktree, PR verso `develop`.

---

## Fasi successive

Da dettagliare in un piano proprio dopo il pilota.

**Fase 3, Telegram.** `src/Telegram.psm1` (invio, lettura degli aggiornamenti, apertura di un argomento);
`config/gruppi.local.json` fuori da git (gruppo, utente Telegram, nome su Azure DevOps); token del bot in un file del
profilo utente. In `Decisioni.psm1` l'azione `Avvisa` resta com'è: cambia solo chi la esegue. Nuovi ingressi del
giro: un messaggio in un argomento diventa un commento sulla card, un comando diventa uno spostamento. I comandi sono
quelli della sezione 9 della spec.

**Fase 4, più card e altri repo.** `sessioniAttive` a 2 o 3; un `CLAUDE.md` e una riga di mappa per ogni repo
aggiunto; una pipeline di validazione per il repo degli attrezzi che lancia Pester; il ruolo `scout`.
Funzionalità divise in task (sezione 18 della spec): Task figli della card creati da `responsabile`, due comandi
nuovi in `card`, in `Decisioni.psm1` una sessione `dev` per task aperto, id del task nel registro delle sessioni.
Le funzionalità su più repo vanno disegnate con il titolare prima di dettagliarle.

**Fase 5, rilascio in produzione.** Tipo `Release` nel processo, card di rilascio per prodotto, comando
`/rilascia`. Da rivedere con il titolare prima di dettagliarla: sezione 10 della spec.

## Aggiunte dopo l'approvazione

Tre aggiunte decise dal proprietario dopo l'approvazione del piano. I task esistenti non cambiano.

1. **`card crea`.** Il comando crea una card completa in Draft da un file markdown con quattro sezioni, ed è vietato
   in una sessione di ruolo. File: `src/card.ps1`, `src/Card.psm1` (`New-Card`), `src/Ado.psm1` (`New-AdoCard`),
   `tests/Card.Tests.ps1`, `tests/Ado.Tests.ps1`; spec sezione 7.
2. **I test girano sempre tutti.** La validazione della PR fallisce con un test saltato o con un progetto di test non
   eseguito. File: `regole/SKILL.md`; spec sezione 8. I due lavori di `Acme.AI` che ne sono il prerequisito
   (142 test condizionati, `stime pr-validation`) restano da decidere: `<DA DECIDERE dal titolare: prima del pilota
   o come prime card>`.
3. **TDD obbligatorio.** `dev` riporta il run rosso, `reviewer` controlla il test che fallirebbe senza la modifica.
   File: `regole/SKILL.md`, `ruoli/dev.md`, `ruoli/reviewer.md`; spec sezione 8.

Le sezioni della spec dal vecchio 7 in poi sono scalate di una: i rimandi del piano sono aggiornati.

## Cosa non copre questo piano

- La sostituzione della Parte 1 del documento di `bb-project` con un rimando alla fonte unica.
- I lavori elencati nella sezione 15 della spec.
