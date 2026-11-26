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

I token si leggono dalle variabili `DEVOPS_AGENTS_ADO_PAT` e `DEVOPS_AGENTS_GITHUB_TOKEN`, altrimenti dagli stessi file della
versione PowerShell in `~/.claude` (`pat-smistatore.txt`, `pat-github.txt`, cifrati DPAPI su Windows o in chiaro). Le sessioni
ricevono solo i token in lettura (`AZURE_DEVOPS_EXT_PAT`, `GH_TOKEN`), mai quelli di chi lancia.

Il modo sicuro per provarla dal vivo: `Mode=live`, `AllowWrites=false`, e confrontare con la dashboard i giri di prova con
`pwsh -NoProfile -File src/Smistatore.ps1 -WhatIf` sulle stesse card. Le due versioni non vanno accese in scrittura insieme:
hanno stati locali separati e farebbero partire due volte le stesse sessioni.

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
| Funzionalita di piu card con card di chiusura (D52) | **manca**: le card di una Feature sono trattate come isolate |
| Passata del responsabile prima di un on-hold (D42), on-hold sciolti da soli (D51), riprese automatiche dopo silenzio | **manca** |
| Mentore e memoria dei ruoli (D46), presa in carico da un altro PC (`AdottaCard`), sessione altrui recente | **manca** |
| Supervisore, Telegram, aggiornamento automatico della suite (D53) | **manca** |
| Vista: sezione Pipeline, Apprendimento, Ufficio, Suite | **manca**: la dashboard ha kanban, log e giri |
| `card.ps1` (il punto d'ingresso degli agenti sulla board) | resta quello PowerShell, che i brief usano gia |
| Installazione come servizio Windows / container | **manca** |
