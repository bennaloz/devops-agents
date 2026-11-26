# Esiti delle verifiche su `claude -p`

Misurato il 2026-11-16 con Claude Code 2.1.312, sempre `--model haiku`, da `.superpowers/prove/` (fuori da git, qui
stanno le uscite grezze). Le sessioni sono partite da quella cartella (o da `.superpowers/prove/repo` per il passo 4).

Nota per chi rifà le prove: lanciato da dentro una sessione di Claude Code, `claude -p` è partito senza rifiuti di
annidamento, quindi non è servito togliere nessuna variabile dall'ambiente.

Nota sull'ambiente: in questa installazione gli strumenti di shell di `claude -p` sono `PowerShell`, non `Bash`
(campo `tools` dell'evento `init`). I pattern di `--allowedTools` vanno scritti su `PowerShell(...)`.

## Tabella (verifiche della spec, sezione 14)

| # | Verifica | Esito misurato |
|---|----------|----------------|
| 3 | Campi di `--output-format json` | Presenti tutti: `session_id`, `num_turns`, `duration_ms`, `is_error`, `result`, e in `usage` `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`. In più: `total_cost_usd`, `duration_api_ms`, `stop_reason`, `subtype` (`success`), `terminal_reason`, `permission_denials` (array di `{tool_name, tool_use_id, tool_input}`), `modelUsage`, `type` (`result`). |
| 4 | Sforzo | `--effort <level>` con valori `low`, `medium`, `high`, `xhigh`, `max` (da `claude --help`). Accettato in pratica: `--effort low` (sessione G, nessun errore). Gli altri valori non sono stati provati uno per uno. Permessi: `--permission-mode` accetta `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`. |
| 5 | Eventi mentre lavora | Con `--output-format stream-json --verbose` arrivano righe JSON, una per evento. Tipi visti: `system` (sottotipi `hook_started`, `hook_response`, `init`, `task_summary`, `permission_denied`, `thinking_tokens`, `post_turn_summary`), `assistant` (blocchi `thinking`, `tool_use`, `text`), `user` (`tool_result`), `rate_limit_event`, `result`. Arriva un `assistant` con `tool_use` e un `user` con `tool_result` per ogni chiamata di strumento: il silenzio è misurabile. Dopo `result` può arrivare ancora un `system/task_summary`: l'evento finale va cercato con `type == "result"`, non è l'ultima riga. |
| 6 | Durata cache | **Superato** dalla sezione "Cache alla ripresa" qui sotto (dettagli in `.superpowers/prove/cache-ripresa.md`): la conclusione "a 6 minuti la cache è fredda" non regge. Misura originale, tenuta per memoria: Dopo 6 minuti: `--resume` della sessione del passo 1 (stesso `session_id` `80cfb2da-522a-4d32-926a-7cfb1c85f9bd`, stesse opzioni) ha dato `cache_read_input_tokens` = 0 e `cache_creation_input_tokens` = 46713: la cache NON era usata alla ripresa, pur con TTL di 1 ora dichiarato alla creazione. Una sessione nuova senza `--resume` (passo 2) invece leggeva 35929 token dalla cache comune. Quindi la ripresa con `--resume` rifà quasi tutto l'innesco; la soglia dei 6 minuti va trattata come cache fredda. Dopo 50 minuti: <DA VERIFICARE: in corso, esito in `.superpowers/prove/resume-50.json` (parte alle 16:14 circa).> Causa dello zero non indagata: <DA VERIFICARE: non e' noto perche' la ripresa non riusa il prefisso.> |
| 8 | Visibilità nell'app desktop | <DA VERIFICARE: non verificabile da questa sessione. Chiedere al proprietario di cercare nell'app le sessioni elencate sotto.> |
| 9 | Peso dell'innesco | Sessione minima senza connettori (`--strict-mcp-config` con `{}`), senza ruolo: `input_tokens` 2 + `cache_creation_input_tokens` 47482 + `cache_read_input_tokens` 0 = 47484 token. Per ruolo: <DA VERIFICARE: i ruoli non esistono ancora, è stata misurata solo la sessione senza ruolo.> |

## Passo 2: peso dei connettori

Senza `--strict-mcp-config` (sessione `df2e14b6-836b-4931-a660-a2bbaf60dc74`): `input_tokens` 2,
`cache_creation_input_tokens` 9435, `cache_read_input_tokens` 35929, totale 45366 contro i 47484 del passo 1. Il
campo `mcp_servers` dell'evento `init` del passo 3 era vuoto: nella modalità `-p` di questa installazione non risultano
connettori che aggiungano token. Differenza `input_tokens + cache_creation_input_tokens`: 9437 contro 47484, ma è
solo l'effetto della cache già calda (35929 letti); a parità di cache il totale non cresce. Peso dei connettori
misurato: nessuno rilevabile (differenza di totale -2118, nel rumore). Il passo 2 non è stato ripetuto a freddo.

## Passo 4: permessi

Il compito: eseguire `git status` e modificare `a.txt` in una cartella di prova (repo git creato in `prove/repo`).

| Sessione | Opzioni | Esito |
|----------|---------|-------|
| A | `--allowedTools "PowerShell(git *)" Edit --permission-mode dontAsk` | NO: `git status` negato, anche la modifica (usa `Write`, non consentito) |
| B | `--allowedTools "PowerShell(git status*)" Edit --permission-mode acceptEdits` | NO: `git status` negato (modifica riuscita) |
| C | `--allowedTools PowerShell Edit --permission-mode dontAsk` | SI |
| D | `--allowedTools "PowerShell(git status)" --permission-mode acceptEdits` | SI, nessun `permission_denials` |
| E | `--allowedTools "PowerShell(git:*)" --permission-mode acceptEdits` | NO: `git status` negato |
| F | `--allowedTools PowerShell --permission-mode acceptEdits` | SI |
| G | `--allowedTools PowerShell Edit Write --permission-mode dontAsk --effort low` | SI |

Combinazione minima che funziona: `--allowedTools "PowerShell(git status)" --permission-mode acceptEdits`. `acceptEdits`
copre le modifiche ai file, `allowedTools` il comando di shell. I pattern con carattere jolly (`git *`, `git status*`,
`git:*`) sono stati respinti dal controllo dei permessi: nel passo 3 il messaggio di `permission_denied` era
"Command contains malformed syntax that cannot be parsed: pwsh exited with code 1: The command line is too long".
Per ogni comando serve quindi il pattern esatto, oppure `PowerShell` per intero (più largo). Con `dontAsk` va
consentito anche `Write`, perché il modello può preferirlo a `Edit`. Non è stato usato `--dangerously-skip-permissions`.
Senza regole di permesso (passo 3, `Bash(git *)` che qui non corrisponde a nessuno strumento) i comandi vengono
negati ma la sessione termina comunque con `subtype: success` e `is_error: false`: l'esito va letto da
`permission_denials`.

## Passo 6: id delle sessioni lanciate

Cartella di partenza: `C:\develop\GIT\_wt\DevOps.Agents\fondamenta\.superpowers\prove` (sessioni A-G dal
sottocartella `repo`).

- passo 1: `80cfb2da-522a-4d32-926a-7cfb1c85f9bd`
- passo 2: `df2e14b6-836b-4931-a660-a2bbaf60dc74`
- passo 3: `c0de616a-cd59-4360-a0f9-016817dd2c2f`
- passo 4: A `de60d9ea-8271-497e-be4d-45c591897080`, B `84fa58d4-b804-4902-a529-3349f5f2ec64`,
  C `d5e20d98-df93-4557-abe0-d78934e800b3`, D `2edc216a-b2cf-4d98-b8d7-722c95e39189`,
  E `2b51ccd0-ed55-4ffd-8699-2e77d85ea404`, F `df419247-4840-40cf-ab27-c40df9bbf2e2`,
  G `ce4911a7-bca8-4997-9dcf-7b65a770d00d`
- riprese del passo 5: stessa sessione del passo 1 (id invariato o copia, vedere `session_id` nei due file `resume-*`).

## Verifica 1: stato iniziale di una card (chiusa)

Chiusa il 2026-11-16 dopo aver applicato al processo `Custom.Agile` (tipi derivati `Custom.Agile.UserStory` e
`Custom.Agile.Bug`) gli stati della spec: una card nasce in `Draft`, quindi nessun ripiego e
`config/stati.json` resta com'è. Stati su entrambi i tipi, riletti da Azure DevOps: Draft, New, Needs clarification, Ready to develop,
In development, In review, In test, Ready to merge, Ready to release, Releasing, Closed; Active e Resolved nascosti.
Campi interi `Custom.TotalTokens` ("Total tokens") e `Custom.AgentMinutes` ("Agent minutes") su entrambi i tipi, nel gruppo
"Agenti" della scheda. Area `DevOps.Agents\Area\AI\Stime` (percorso della card:
`DevOps.Agents\AI\Stime`). Team con le sotto-aree incluse (senza, le card dell'area `AI\Stime` non
comparivano sulla board). Board Stories: 11 colonne, una per stato, mappate per User Story e Bug.
Card di prova: id 2, "Card di prova (da non usare)", progetto `DevOps.Agents`.

## Cache alla ripresa con `--resume` (verifica 6)

Con opzioni identiche la ripresa riusa la cache: calda a 5 secondi (`cache_read` 35974, `cache_creation` 9476) e a
circa 7 minuti (`cache_read` 45425, `cache_creation` 65, cioè 45425 su 45490). La ripresa fredda a 6 minuti
(`cache_read` 0) veniva dal modo di lancio diverso (processo staccato con `Start-Process`, `--mcp-config` con escape
diverso), non dal tempo. Conseguenza per il task 14: primo lancio e ripresa passano dalla stessa funzione, con la stessa
riga di comando, e un test lo verifica. Ancora da misurare: la ripresa a 50 minuti da un lancio identico
(`resume-50.json`), e se `--system-prompt-snapshot` (già `on` di default) cambia qualcosa. Dettagli:
`.superpowers/prove/cache-ripresa.md`.

## Prova dal vivo sulla card 2 (task 5, passo 5)

Funzionano: utente corrente, lettura della card, tag e campo personalizzato intero (allora con un nome italiano,
ora `Custom.TotalTokens`), WIQL (Draft esclusa, New inclusa), cambio di stato, criteri, rifiuto delle
transizioni non permesse. Guasti trovati e corretti nel commit `fix: rilievi della revisione del ramo e guasti dal vivo`:

- L1: i commenti davano 404: l'indirizzo vuole il progetto prima di `_apis` (`progettoBoard` di `config/mappa.json`).
  Rilettura dopo la correzione: `Get-AdoCommenti` e `Read-Card` sulla card 2 rispondono (0 commenti).
- L2: `Set-AdoCard -TogliTag` non toglieva il tag. Causa ipotizzata, NON verificata dal vivo: sull'ultimo tag la op `add`
  con valore vuoto non svuota il campo; ora si manda una op `remove`. Verificato dal vivo dopo la correzione: il tag
  `agents` si aggiunge e si toglie sulla card 2 (anche insieme a `-Stato`).
- L3: `Chi` di `Get-AdoStoriaStato` era il nome visualizzato ("Rossi Paolo - Acme S.p.A."), `Id` di
  `Get-AdoUtenteCorrente` un GUID. Ora `Chi` è l'id dell'identità (lo stesso GUID); il nome sta in `ChiNome`. Verificato
  dal vivo: `Chi` è uguale a `Id` su tutti i 4 cambi di stato della card 2.
- L4: `Card.psm1` caricato dopo `Ado.psm1` toglieva al chiamante le funzioni di `Ado.psm1` (import annidato con `-Force`).
  Ora l'import è `-Global`, senza `-Force`; un test lo verifica in cinque ordini di caricamento.

Verificati dal vivo dopo le correzioni: scrittura dei commenti, commento di due righe, commento con menzione,
`card.ps1 commenta` da stdin (conserva backtick, `$null` e virgolette; con il testo come argomento esce 1). Da guardare
nell'interfaccia di ADO: gli a capo dei commenti arrivano come `\n` e forse non vanno a capo nell'HTML; la menzione
mostra `@` senza il nome.

## Giro dello smistatore con `-WhatIf` sulla card 2 (fase 2)

Card 2 nell'area `DevOps.Agents\AI\Stime`, con il tag `agents`:

- in Draft: `Smistatore.ps1 -Card 2 -WhatIf` non propone niente;
- in New: propone `LanciaSessione Ruolo=responsabile Motivo=nuova Riprendi=False`, sia con `-Card 2` sia nel giro
  completo;
- nessuna scrittura locale: niente `stato.json` e niente log nella cartella dati.

La prima prova ha trovato un guasto: con `-Card` su una card fuori dalle attive (in Draft) il giro si interrompeva
(`.Count` su `$null` in StrictMode, perché l'assegnazione di un `if` srotolava l'array vuoto). È corretto nel commit
`fix(smistatore): -Card su una card fuori dalle attive non interrompe il giro`, con un test. Dopo la prova la card 2 è
tornata in Draft, senza tag.

## Peso dell'innesco e `--setting-sources` (task 14)

Misurato il 2026-11-16, Claude Code 2.1.312, `--model haiku`, prompt minimo che fa chiamare lo strumento `PowerShell`
(`Get-Date`), `--strict-mcp-config` con `{"mcpServers":{}}`, `--allowedTools PowerShell --permission-mode acceptEdits`,
da `.superpowers/prove/misura-setting-sources/` (uscite grezze `m*.jsonl`). Il "totale" e `input_tokens +
cache_creation + cache_read` dell'evento `result`, che somma i due giri della sessione (richiesta con lo strumento e
risposta): per questo e circa il doppio dei 47.000 del passo 9.

`claude --help`: `--setting-sources <sources>  Comma-separated list of setting sources to load (user, project, local).`
Non c'e un valore documentato che escluda tutto; non e stato provato `""`.

| Prova | Opzioni (oltre alle comuni) | Totale | Hook visti |
|---|---|---|---|
| m1 | nessuna | 89.768 | `SessionStart` (1 `hook_started`); i `PreToolUse` non compaiono senza `--include-hook-events` |
| m1b, m2, m4 | nessuna in pratica: un mio errore nello script passava `--include-hook-events` e `--setting-sources` come caratteri sparsi, quindi sono tre ripetizioni della base | 89.780, 89.782, 89.774 | come m1 |
| m5 | `--include-hook-events --setting-sources user` | 89.778 | `SessionStart` e `PreToolUse:PowerShell` (4 `hook_started`) |

Esito: `--setting-sources user` non riduce l'innesco (89.778 contro 89.768-89.782, differenza nel rumore) e tiene gli
hook di `~/.claude/settings.json`. Nessuna variante misurata riduce l'innesco, quindi **`Start-SessioneRuolo` non usa
`--setting-sources`**. Non provate: `project,local` senza `user` (toglierebbe gli hook, che stanno in `user`) e
`--setting-sources ""`. Sessioni spese: 5 (tre sono ripetizioni della base per l'errore dello script).
Nota: gli eventi `PreToolUse` si vedono solo con `--include-hook-events`; per controllare che gli hook scattino in una
sessione di ruolo quel flag va aggiunto alla prova, non al lancio vero.

## Primo lancio e ripresa dalla stessa funzione (task 14)

Verificato con claude vero (haiku, ruolo di prova, `Start-SessioneRuolo` per entrambi i lanci, ripresa dopo 5 secondi):
primo lancio `cache_read` 0 e `cache_creation` 44.834 (prefisso nuovo), ripresa `cache_read` 35.583 e
`cache_creation` 9.291: la cache e calda alla ripresa. Conferma che la ripresa fredda della verifica 6 veniva dal modo di
lancio diverso e non dal tempo. Lo stesso eseguibile (`claude.exe`, non lo shim `.cmd`/`.ps1` di npm), lo stesso
`Start-Process`, gli stessi argomenti nello stesso ordine e con lo stesso escape da una sola funzione
(`Get-ArgomentiClaude`); un test confronta le righe di comando dei due lanci. Una ripresa scrive su
`sessioni\<id>.r<N>.jsonl`, il primo lancio su `sessioni\<id>.jsonl`: `Get-EsitoSessione` legge il piu recente. Un
evento finale con `permission_denials` non vuoto vale come errore anche se `is_error` e falso. Permessi: strumenti del
ruolo per nome (senza pattern con jolly) e `--permission-mode acceptEdits`, come nel passo 4. Resta da misurare la
ripresa dopo molti minuti da un lancio identico.

## Primo giro vero: `responsabile` sulla card 6 (fase 2)

Il 2026-11-16 sulla card 6, "Refresh: validare EveryDays delle fonti all'avvio" (Acme.AI, area `AI\Stime`,
tag `agents`), portata in New dal titolare, lanciata con `Smistatore.ps1 -Card 6` senza `-WhatIf`.

- Sessione `722d3369-2fe3-4d7b-8845-e06e1bd95534`, `opus`, sforzo `high`, nuova (non ripresa).
- 14 turni, 13 chiamate a strumenti, circa 2 minuti (17:29:36 → 17:31:21 UTC).
- Token: in 20, out 6.150, letti dalla cache 302.659, scritti in cache 36.804; totale 345.633. Riga del registro
  scritta e campi `Total tokens` e `Agent minutes` della card aggiornati al giro dopo.
- `permission_denials` vuoto. Strumenti visti dalla sessione (evento `init`): `Glob`, `Grep`, `PowerShell`, `Read`.
- Esito `fatto`: criteri scritti, card portata da `responsabile` in Ready to develop. Sul punto aperto (EveryDays=0
  ammesso o errore) ha deciso lui, errore, motivando con codice esistente (`RunOnce` e `Url` vuoto coprono già i casi
  d'uso), invece di portarlo come domanda.
- Giro dopo: `CreaWorktree` (task 13) non ancora disponibile → card in `on-hold` con commento e menzione, come atteso.

Guasto trovato: la sessione di ruolo non vede la skill `regole-sviluppo`. `--tools` limita gli strumenti a quelli di
`config/ruoli.json`, che non hanno `Skill`. Corretto aggiungendo `Skill` agli strumenti dei tre ruoli (PR 946): dal
`dev` in poi la skill compare nell'evento `init` ed è stata usata.

Non verificato in questo giro: che l'hook `deny-identita.ps1` veda `ATTREZZI_RUOLO` (gli eventi `PreToolUse` compaiono
solo con `--include-hook-events`, che il lancio vero non usa); la resa nell'interfaccia di ADO degli a capo e della
menzione nei commenti.

## Card 6 da Ready to develop al merge (fase 2, 17/11)

Ogni giro lanciato a mano con `Smistatore.ps1 -Card 6`, preceduto da `-WhatIf`. Sessioni, tutte su `Acme.AI`:

| Sessione | Ruolo | Modello | Turni | Minuti | Token | Costo (USD eq.) | Esito |
|---|---|---|---|---|---|---|---|
| `722d3369` | responsabile | opus, high | 14 | 2 | 345.633 | non registrato | fatto |
| `c269390e` | dev | sonnet | 17 | 2 | 404.091 | 0,30 | fatto |
| `9aa171a9` | reviewer | opus, high | 12 | 2 | 312.229 | 0,58 | bloccante |
| `15bff27e` | dev | sonnet | 20 | 1,3 | 564.245 | 0,27 | fatto |
| `f61589ba` | reviewer | opus, high | 11 | 1,3 | 383.282 | 0,53 | superata |

Sulla card: `Total tokens` 2.009.480, `Agent minutes` 10. I token sono quasi tutti letti dalla cache (es. `dev`
`c269390e`: out 6.214, letti 346.956, scritti 50.901). Nessuna `permission_denials` in nessuna sessione.

Cosa ha funzionato, nell'ordine:
- `CreaWorktree` ha creato `C:\develop\GIT\_wt\Acme.AI\card-6` da `origin/develop`, ramo
  `feature/6-refresh-validare-everydays-delle-fonti`; la card è passata In development.
- `dev` ha implementato, lanciato i test del progetto toccato e pubblicato il ramo; `ApriPr` ha aperto la PR 951.
- Il primo `reviewer` ha trovato un rilievo vero (nessun test copriva la registrazione del validatore); lo
  smistatore ha riportato la card In development e rilanciato `dev` con i rilievi (caso 17); il secondo `reviewer`
  ha dato `superata`.
- L'avviso "la revisione è superata" è arrivato come commento con menzione e su Telegram, nell'argomento generale.
- Spostata dal titolare in Ready to release: `CompletaPr` ha completato la PR 951 (merge commit, a nome del titolare
  del PAT); al giro dopo `RimuoviWorktree` ha tolto cartella, ramo locale e ramo remoto. Il completamento di ADO è
  asincrono: subito dopo il giro la PR risultava ancora attiva.

Cosa non ha funzionato o è cambiato:
- La PR 951 non aveva nessuna validazione: il servizio Refresh ha i YAML ma su Azure DevOps mancano pipeline, Build
  Validation e deploy nell'orchestratore. Lo smistatore aspettava in silenzio una build che non sarebbe mai partita.
  Deciso: il giudice è la PR unibile (PR 953); pipeline e policy nascono con il servizio o in un task dedicato
  (card 7 per Refresh).
- Il deploy in Test non è stato provato: la mappa collega l'area `AI\Stime` al componente `stime`, e per la
  card 6 avrebbe deployato il servizio sbagliato. Deciso: un'area per repo, i componenti li dice la descrizione della
  card; la mappa per ora resta com'è. Verifica 7 (stadio `Approval`) ancora aperta.
- Il `reviewer` ha scritto da sé prefisso `[reviewer]` e firma, e `card.ps1` li ha aggiunti di nuovo: ora lo script
  non li raddoppia.
- Un giro esegue tutte le azioni che decide: quello che ha chiuso il primo `reviewer` ha anche rilanciato `dev`
  senza un via in mezzo. Per i giri a mano si guarda sempre prima `-WhatIf`.
- Il costo di `responsabile` non è nel registro: la riga del registro non ha `total_cost_usd`.

Ancora da verificare dal vivo: che l'hook `deny-identita.ps1` veda `ATTREZZI_RUOLO`; il deploy in Test da una card
(verifica 7); la ripresa con `--resume` dopo molti minuti.
