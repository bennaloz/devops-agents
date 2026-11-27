# DevOps.Agents in .NET e Angular

Prima versione del sistema di agenti come prodotto: backend ASP.NET Core (.NET 8) e dashboard Angular 18. Legge la stessa
configurazione della versione PowerShell (`config/*.json` e `ruoli/*.md` nella radice del repo) e lavora sulla stessa board con
le stesse regole, quindi le due versioni si possono confrontare sulle stesse card.

```
app/
  backend/
    src/DevOpsAgents.Core            dominio, motore decisionale (puro), porte, orchestratore del giro
    src/DevOpsAgents.Infrastructure  configurazione, token, Azure DevOps (board, repos, pipeline), GitHub, git, claude -p, stato su file
    src/DevOpsAgents.Api             API, SignalR, smistatore come servizio, modalita demo
    tests/                           xUnit: motore e orchestratore, provider con HTTP finto, git e claude finti
  frontend/                          dashboard Angular (kanban per stato, log del giro, giri a richiesta, aggiornamenti live)
```

## Come e fatto

- **Il motore decisionale** (`DecisionEngine`) e la conversione di `Get-Decisione` di `src/Decisioni.psm1`: funzione pura, dato lo
  stato della card e il contesto del giro restituisce le azioni e il motivo di un fermo. Le azioni hanno lo stesso nome
  dell'originale (`LanciaSessione`, `SpostaCard`, `MettiInAttesa`, ...).
- **Le porte** (`Core/Ports`) separano il motore dal mondo: `IBoard` (Azure DevOps Boards), `ICodeHost` (Azure Repos o GitHub,
  scelto per area con `"sorgente"` in `config/mappa.json`), `ICiService` (Azure Pipelines), `IWorkspace` (worktree git),
  `ISessionRunner` (claude -p), `IStateStore` (stato locale delle card).
- **L'orchestratore** (`Dispatcher`) fa il giro dello smistatore: chiude le sessioni finite, legge le card assegnate all'utente
  del PAT, costruisce l'istantanea, decide ed esegue. Con il giro di prova non scrive niente, come `-WhatIf`.
- **L'API** ascolta solo su `localhost:18800`. Le scritture (`POST /api/round`) vogliono l'intestazione `X-DevOps-Agents`; ogni
  giro arriva alla dashboard via SignalR (`/hub`).

## Avviare

Servono .NET 8 SDK e Node 20 o piu recente.

```bash
cd app/frontend && npm ci && npm run build
```

```bash
cd app/backend && dotnet run --project src/DevOpsAgents.Api
```

Si apre `http://localhost:18800`. Di default parte in **modalita demo**: un mondo simulato in memoria (board, PR, pipeline,
sessioni che finiscono al giro dopo con l'esito tipico del ruolo), per vedere il flusso senza toccare niente. La scrittura e
spenta: ogni giro e di prova. Per far avanzare la demo:

```bash
cd app/backend && dotnet run --project src/DevOpsAgents.Api -- --DevOpsAgents:AllowWrites=true
```

Per lo sviluppo della dashboard, con il backend avviato: `cd app/frontend && npx ng serve` (proxy verso l'API su 4200).

### Contro la board vera

In `src/DevOpsAgents.Api/appsettings.json`, sezione `DevOpsAgents`:

| Chiave | Default | Cosa fa |
| --- | --- | --- |
| `Mode` | `demo` | `live`: Azure DevOps, Azure Repos o GitHub, git e claude veri |
| `AllowWrites` | `false` | Spento, ogni giro e di prova. Accenderlo solo dopo aver confrontato i giri di prova con lo smistatore PowerShell |
| `AutoRun` | `false` | Il giro automatico ogni `intervalloMinuti` di `config/limiti.json` |
| `OnlyMine` | `true` | Solo le card assegnate all'utente del PAT, come lo smistatore PowerShell |
| `WorktreeRoot` | `C:/develop/GIT/_wt` | Dove nascono i worktree delle card |
| `DataDir` | `%LOCALAPPDATA%/DevOps.Agents.Net` | Stato locale e flussi delle sessioni (separati da quelli del PowerShell) |
| `ClaudeExecutable` | `claude` | La CLI di Claude Code |
| `HookCommand` | accanto all'API | Gli hook .NET (`devops-agents-hook`), passati a ogni sessione con `--settings`. `off`: solo quelli installati in `~/.claude/settings.json` |
| `McpServer` | accanto all'API | Il server MCP degli agenti (`devops-agents-mcp`, eseguibile o dll). `off`: le sessioni usano `card.ps1` come la versione PowerShell |

I token si leggono dalle variabili `DEVOPS_AGENTS_ADO_PAT` e `DEVOPS_AGENTS_GITHUB_TOKEN`, altrimenti dagli stessi file della
versione PowerShell in `~/.claude` (`pat-smistatore.txt`, `pat-github.txt`, cifrati DPAPI su Windows o in chiaro). Le sessioni
ricevono solo i token in lettura (`AZURE_DEVOPS_EXT_PAT`, `GH_TOKEN`), mai quelli di chi lancia.

Il modo sicuro per provarla dal vivo: `Mode=live`, `AllowWrites=false`, e confrontare con la dashboard i giri di prova con
`pwsh -NoProfile -File src/Smistatore.ps1 -WhatIf` sulle stesse card. Le due versioni non vanno accese in scrittura insieme:
hanno stati locali separati e farebbero partire due volte le stesse sessioni.

## La riga di comando

`devops-agents` parla con il servizio avviato (di default `http://localhost:18800`, altrimenti `DEVOPS_AGENTS_URL`):

| Comando | Cosa fa |
| --- | --- |
| `devops-agents stato` | Modalita, scrittura, giro automatico, pausa del sistema, ultimo giro |
| `devops-agents giro [--prova] [--card <id>]` | Un giro adesso (di prova con `--prova`, o con la scrittura spenta) |
| `devops-agents pausa` / `riprendi` | Pausa di sistema (D60): nessuna sessione nuova, le card restano dove sono |
| `devops-agents feature` | Le Feature in ordine di priorita, con le pause |
| `devops-agents feature pausa <id>` / `riprendi <id>` | Pausa di una Feature |
| `devops-agents feature sposta <id> <dopo>` | Riordino: `<dopo>` e l'id della Feature che la precede, 0 la mette in cima |
| `devops-agents da-fare` | I problemi aperti del supervisore: cosa aspetta te |

Esce con 3 se il servizio non risponde. Si installa come strumento .NET:

```bash
cd app/backend && dotnet pack src/DevOpsAgents.Cli -o ../nupkg && dotnet tool install -g devops-agents --add-source ../nupkg
```

## Gli strumenti degli agenti (MCP)

Nella versione .NET gli agenti non usano `card.ps1`: ogni sessione `claude -p` riceve un solo server MCP, `devops-agents-mcp`
(`src/DevOpsAgents.Mcp`), lanciato su stdio con la card, il ruolo e il task della sessione:

```bash
devops-agents-mcp --card 42 --ruolo dev --task 57 --root <repo degli attrezzi> --dati <cartella dati>
```

- **Ogni ruolo vede solo i suoi strumenti.** `card_leggi` e `card_commenta` per tutti; `card_sposta` per chi ha transizioni in
  `config/ruoli.json` (la descrizione dello strumento le elenca); `card_criteri`, `card_crea_task`, `card_senza_test`,
  `card_prova_umana`, `card_deploy`, `card_correzione` per il responsabile; `card_chiudi_task` per il dev di un task;
  `card_titolo_pr` e `card_descrizione_pr` per dev e responsabile; `memoria_leggi`, `memoria_scrivi`, `memoria_rivedi`,
  `memoria_togli`, `memoria_conflitto` per il mentore. Uno strumento che il ruolo non ha non esiste, invece di rifiutare a runtime.
  `devops-agents-mcp --card 1 --ruolo <ruolo> --elenca` stampa l'elenco.
- **La card non e un argomento**: e fissata all'avvio, come `ATTREZZI_CARD` per `card.ps1`. Una sessione non scrive su un'altra card.
- **Parametri strutturati**: il testo va nei parametri dello strumento, niente stdin ne here-string (che la shell alterava: `$`,
  backtick, trattino iniziale). `card_deploy` prende l'elenco dei parametri e il perche, `card_correzione` natura, titolo e descrizione.
- **Stessi controlli e stessi testi sulla board** di `card.ps1` (`Core/Agents/CardTools.cs`): prefisso `[ruolo]` e firma, marche del
  deploy, della descrizione della PR e della correzione, tetto della descrizione, doppioni dei task, ramo della card per lo YAML del
  deploy. Lo smistatore PowerShell e quello .NET leggono gli stessi commenti. Un rifiuto torna all'agente come errore dello strumento,
  con lo stesso messaggio.
- **I token li legge il server** (variabili `DEVOPS_AGENTS_*` o i file in `~/.claude`), non la sessione, che continua a ricevere solo
  quelli in lettura. Il file del PAT resta raggiungibile dall'utente che fa girare le sessioni: lo protegge l'hook `deny-pat`, come prima.

I brief dei ruoli restano uno per le due versioni: descrivono `card.ps1`, e per una sessione con MCP lo smistatore aggiunge in fondo una
tabella "comando di `card.ps1` -> strumento" con i soli strumenti del ruolo (`Core/Agents/AgentBrief.cs`). Il server finisce accanto
all'API (riferimento di progetto) e l'API lo trova da sola; `McpServer=off` torna a `card.ps1`.

Restano in PowerShell: la scrittura della memoria (gli strumenti `memoria_*` chiamano `src/memoria.ps1`, che fa worktree, commit, push e
PR della memoria; il mentore pero non usa piu la shell per questo) e `card.ps1 crea` (si usa fuori dai ruoli).

## Gli hook

I cinque hook PreToolUse di `hooks/*.ps1` sono anche in .NET (`Core/Hooks/HookRules.cs`, eseguibile `devops-agents-hook`), con le
stesse regole e gli stessi messaggi:

```bash
echo '{"tool_input":{"command":"cat ~/.claude/pat.txt"}}' | ATTREZZI_RUOLO=dev devops-agents-hook deny-pat
```

Exit 2 blocca e il messaggio su stderr torna al modello; in circa un decimo di secondo. Lo smistatore .NET li passa a ogni sessione con
`--settings`, cosi valgono per i ruoli anche dove non sono installati. I test girano sugli stessi 119 casi di `hooks/Test-Hooks.ps1`,
esportati in `tests/DevOpsAgents.Core.Tests/Hooks/casi-hook.json`: un caso nuovo si aggiunge a `Test-Hooks.ps1` e si riesporta.

## Come servizio

Il servizio e lo stesso eseguibile: su Windows si registra come servizio (nome `DevOps.Agents`), su Linux parla con systemd.

**Windows** (PowerShell da amministratore). Il servizio gira con l'utente indicato, perche i token in `~/.claude` sono cifrati
DPAPI per quell'utente:

```powershell
dotnet publish app/backend/src/DevOpsAgents.Api -c Release -o C:/DevOps.Agents/server
cd app/frontend; npm ci; npm run build; Copy-Item -Recurse ../backend/src/DevOpsAgents.Api/wwwroot C:/DevOps.Agents/server/
sc.exe create DevOps.Agents binPath= "C:\DevOps.Agents\server\DevOpsAgents.Api.exe --DevOpsAgents:Mode=live --DevOpsAgents:Root=C:\develop\GIT\devops-agents" obj= ".\<utente>" password= "<password>" start= delayed-auto
sc.exe start DevOps.Agents
```

**Linux** (systemd, unita utente):

```ini
# ~/.config/systemd/user/devops-agents.service
[Unit]
Description=DevOps.Agents
[Service]
Type=notify
ExecStart=/opt/devops-agents/server/DevOpsAgents.Api --DevOpsAgents:Mode=live --DevOpsAgents:Root=%h/devops-agents
Restart=on-failure
[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload && systemctl --user enable --now devops-agents
```

**Container**. `app/Dockerfile` mette in un'immagine il servizio con la dashboard, la CLI, gli attrezzi del repo (config, ruoli,
regole, skill, hook, `card.ps1`, `memoria.ps1`) e quello che usano le sessioni: git, Claude Code e PowerShell 7. Gira con un
utente senza privilegi e la porta si pubblica solo su localhost:

```bash
cd app && docker compose up -d --build
```

```bash
DEVOPS_AGENTS_MODE=live docker compose up -d
```

`docker-compose.yml` monta `~/.claude` (token e accesso di Claude Code: nel container vanno in chiaro, DPAPI e solo Windows),
`./dati` (stato, quota, impostazioni, flussi) e `./repos` (cloni e worktree: in `config/mappa.json` le cartelle diventano
`/repos/<repo>`). Per usare la propria `config/` invece di quella dell'immagine si monta il repo e si imposta
`DevOpsAgents__Root`. Dietro un proxy con certificato proprio la build accetta `--secret id=ca,src=<certificato.pem>`.
Il collaudo su Docker della card (D59) dal container richiede il socket di Docker dell'host: e una scelta da fare consapevolmente
(chi ha il socket comanda l'host), per questo non e montato di default.

## Test

```bash
cd app/backend && dotnet test
```

I test coprono il motore decisionale (i casi di `tests/Decisioni.Tests.ps1` e `tests/Priorita.Tests.ps1`), l'orchestratore con un
mondo finto e l'infrastruttura (Azure DevOps e GitHub con un server HTTP finto, un repo git vero in una cartella temporanea, uno
script al posto di claude).

## Cosa c'e e cosa manca rispetto alla versione PowerShell

| Parte | Stato |
| --- | --- |
| Flusso di una card isolata: New, Needs clarification, Ready, In development (task, rossa, conflitti, bivio, rilancia), In review, Deploying to test, Automated test, Human test, Ready to merge, Ready to release | portato, con test |
| Limiti: sessioni attive, card per repo, card in Test per componente, giri di revisione e collaudo, rosse di fila; predecessori; on-hold e ripresa della sessione; quota (pausa e riserva) | portato |
| Board Azure DevOps, Azure Repos, Azure Pipelines, GitHub (PR, controlli, merge, rilanci, link sulla card) | portato |
| Worktree, sessioni claude -p con brief, strumenti, advisor e token in lettura; silenzio; esito dalla riga ESITO | portato, semplificato |
| Pausa e priorita delle Feature, pausa di sistema, soglia sulla finestra di 5 ore, Feature obbligatoria in New (D60) | portato, con test; dashboard con ordine, pausa/riprendi e pausa del sistema |
| Collaudo nell'ambiente Docker della card (D59): creazione da compose nel worktree, slot e porte, limite `ambientiCollaudo`, URL al collaudatore, ambiente buttato all'uscita dal Test e orfani; credenziali di prova `COLLAUDO_*` al collaudatore | portato, con test (docker finto) |
| Cosa fare negli on-hold (D57): gesto del ruolo o testo predefinito nel commento, nello stato e nella dashboard; descrizione della PR salvata prima della PR (D58) e titolo dal ramo | portato, con test |
| Quota letta dai `rate_limit_event` delle sessioni, pausa dopo il limite di token (D51) | portato |
| Funzionalita di piu card con card di chiusura (D52): ramo della funzionalita, card In feature branch, card di chiusura con PR verso develop, sorelle, vincolo sul commit, CI rossa al responsabile, Bug di correzione e allinea-develop, Feature Active e Resolved, worktree in sola lettura del collaudatore | portato, con test. Manca: la Feature che passa Closed quando la card di chiusura si chiude |
| Passata del responsabile prima di un on-hold (D42), on-hold sciolti da soli quando la validazione torna verde (D51), ripresa automatica una volta dopo silenzio o processo morto, sessione fallita in on-hold | portato, con test |
| Presa in carico da un altro PC (`AdottaCard`): worktree dal ramo pubblicato, PR collegata per le card gia unite, attesa se la sessione dell'altro PC e recente; commenti di avvio e fine sessione compatibili con il PowerShell | portato, con test. Manca: togliere i worktree delle card cedute a un collega |
| Mentore e memoria dei ruoli (D46): il mentore parte dopo una decisione del responsabile su un blocco o un bivio, dopo i rilievi, dopo un commento o un on-hold tolto da una persona, dopo la prova umana e per una Bug rilasciata, una volta per correzione e fuori dal limite di sessioni; le lezioni stabili e in prova entrano nel brief del ruolo | portato, con test. Le lezioni le scrive il mentore con `memoria.ps1`, come nella versione PowerShell. Manca: il registro dell'apprendimento e la sua sezione nella vista |
| Supervisore (D51): smistatore fermo o che si interrompe, PAT rifiutato o in scadenza, card in on-hold con il gesto e le card che tiene ferme, prove in Test, domande del responsabile, card ferme da ore senza motivo, card che saltano per errore, rilasci in attesa per area con le soglie, quota; problemi aperti con primo visto e ricordi; urgenti subito, riepilogo ai feriali, rilasci a parte; Telegram con i topic | portato, con test; la dashboard ha il riquadro "Da fare per te". Manca: la diagnosi con un modello e i controlli sulle pipeline |
| Aggiornamento automatico della suite (D53) | **manca** |
| Vista: sezione Pipeline, Apprendimento, Ufficio, Suite | **manca**: la dashboard ha kanban, log e giri |
| `card.ps1` e `memoria.ps1` (gli attrezzi degli agenti sulla board) | portati come server MCP (`devops-agents-mcp`), strumenti filtrati per ruolo, con test e una prova con la CLI di Claude Code. Restano PowerShell: la scrittura della memoria (chiamata dal server), `card.ps1 crea` |
| Hook di Claude Code (`hooks/*.ps1`) | portati (`devops-agents-hook`), sugli stessi 119 casi di `Test-Hooks.ps1`, passati alle sessioni con `--settings` |
| Riga di comando, servizio Windows e systemd, container | portato: `devops-agents` (CLI), `UseWindowsService`/`UseSystemd`, `app/Dockerfile` e `app/docker-compose.yml` |
