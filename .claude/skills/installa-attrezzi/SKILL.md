---
name: installa-attrezzi
description: Installare su un PC Windows gli attrezzi del sistema di agenti di DevOps.Agents (smistatore, vista, supervisore, skill, hook e PAT) e portare l'utente fino al primo giro funzionante. Usala quando un collega deve mettere in piedi il suo smistatore, o quando un'installazione esistente va rifatta o verificata.
---

# Installare gli attrezzi degli agenti

Lo smistatore fa avanzare le card della board `DevOps.Agents` assegnate all'utente, con il suo abbonamento
Claude e con PAT creati a suo nome. Ogni collega ha il suo. Questa skill guida l'utente dall'inizio alla fine:
prerequisiti, repo, skill e hook, PAT, giro di prova, attività pianificate. Il riferimento completo è `README.md`
di questo repo: leggilo prima di cominciare, perché i dettagli che seguono lo riassumono e non lo sostituiscono.

## Come lavori

- Un passo alla volta, nell'ordine sotto. A ogni passo dici all'utente cosa hai fatto, l'esito e qual è il prossimo.
  Un passo fallito non si salta: il successivo dipende da lui.
- I percorsi sono fissi, perché script, brief dei ruoli e hook li danno per scontati: i repo in `C:\develop\GIT\<repo>`,
  i worktree in `C:\develop\GIT\_wt`. Non ne scegli altri, anche se l'utente tiene i repo altrove: in quel caso glielo
  dici e decide lui se spostarli.
- La copia principale di `DevOps.Agents` sta sul ramo `main`, il canale dei colleghi (il titolare segue `develop`).
  Da lei girano le attività pianificate: non la modifichi e non ci fai `git pull`, perché si aggiorna da sola (D53): lo
  fa il supervisore, solo a sessioni ferme e solo se la copia è pulita.
- Se un comando fallisce ti fermi, mostri l'errore e proponi la causa probabile. Non lo aggiri e non correggi gli
  script del repo: un difetto dell'installatore si segnala, non si rattoppa sul PC del collega.
- Prima di toccare qualcosa che c'è già (un repo clonato altrove, una skill con lo stesso nome in `~/.claude/skills`,
  attività pianificate esistenti) dici cosa hai trovato e chiedi.
- I PAT li crea l'installatore. Non chiedi PAT all'utente, non li crei a mano, non ne stampi né copi il contenuto.

## I passi

1. **Prerequisiti.** Controlla uno per uno i programmi della tabella in `README.md` ("Prerequisiti") e mostra
   all'utente cosa c'è e cosa manca. Per ciò che manca proponi il comando della tabella e lo lanci tu dopo il suo sì;
   se `winget` chiede di accettare dei termini o un'elevazione, lo dici all'utente e aspetti che li accetti lui. Dopo
   ogni installazione rileggi il PATH dal registro prima di ricontrollare, perché la shell in cui lavori non lo vede.
   Poi la CLI di Claude Code: l'utente può guidare l'installazione da Claude Desktop, ma le sessioni degli agenti le
   lancia lo smistatore con la CLI installata da npm, che ha il suo accesso. Controllalo con
   `claude -p "rispondi solo ok" --model haiku`. Se non risponde perché manca l'accesso, chiedi all'utente di aprire un
   terminale, lanciare `claude` e fare l'accesso con il suo account; l'accesso lo fa lui, non tu. Ricontrolla prima di
   andare avanti.
2. **Accesso ad Azure DevOps.** L'utente deve vedere i progetti `DevOps.Agents` (la board) e quelli in
   `config/mappa.json` (`progettoAdo`). Se un clone del passo 3 risponde con un errore di autorizzazione, fermati: i
   permessi li dà chi amministra l'organizzazione, non si aggirano.
3. **I repo.** Questo repo deve stare in `C:\develop\GIT\DevOps.Agents`, sul ramo `main` e allineato a
   `origin/main` (un collega nuovo lo clona con `git clone -b main`). Se c'è già su un altro ramo non lo cambi: dici
   all'utente cosa hai trovato e chiedi. Per ogni area di `config/mappa.json` clona il repo nella sua `cartella`, se non c'è già, da
   `https://acme.visualstudio.com/<progettoAdo>/_git/<repo>`. Le cartelle che esistono già non le tocchi.
4. **Skill e hook.** Dalla copia principale:

   ```powershell
   pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Regole -Hook
   ```

   Crea in `~/.claude/skills` le giunzioni `regole-sviluppo` e `devops-agents` verso questo repo e aggiunge gli hook a
   `~/.claude/settings.json`, dopo averne salvato una copia accanto. Poi prova gli hook:
   `pwsh -NoProfile -File hooks/Test-Hooks.ps1`. Tutti i casi devono passare.
5. **I PAT.**

   ```powershell
   pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Pat
   ```

   Fa `az login` se non c'è (si apre il browser: avvisa l'utente e aspetta), crea i due PAT con scope e durata di
   `config/pat.json`, li salva cifrati in `~/.claude/pat-smistatore.txt` e `pat-smistatore-lettura.txt` e toglie il
   login se l'aveva fatto lui. A fine passo controlla che i due file e `~/.claude/pat-info.json` ci siano, senza aprirli.
6. **Il giro di prova.**

   ```powershell
   pwsh -NoProfile -File src/Smistatore.ps1 -WhatIf
   ```

   Non scrive niente. Deve finire senza errori e stampare le azioni previste per le card con il tag `agents` assegnate
   all'utente, oppure niente se non ne ha. Spiega all'utente cosa vuol dire ciò che è uscito.
7. **Le attività pianificate.** Chiedi il via all'utente, perché da qui lo smistatore lavora da solo e consuma la sua
   quota Claude sulle card assegnate a lui. Poi:

   ```powershell
   pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Pianificazione
   ```

   Registra in Utilità di pianificazione, cartella `DevOps.Agents`, lo smistatore (un giro ogni
   `intervalloMinuti` di `config/limiti.json`), la vista (all'accesso) e il supervisore. Controlla che le tre attività
   ci siano e che la vista risponda su `http://localhost:18799/vista.html`; se non è ancora partita, avviala da
   "Esegui" sull'attività `Vista` e riprova.
8. **Telegram, facoltativo.** Gli avvisi del supervisore vanno su Telegram solo se ci sono il token del bot in
   `~/.claude/telegram-token.txt` e l'id della chat in `%LOCALAPPDATA%\DevOps.Agents\telegram-chat.txt`.
   Chiedi all'utente se ha un bot; se no, salta il passo: gli avvisi restano nel log del supervisore e il resto
   funziona. Il token lo scrive l'utente nel file, non tu.

## Alla fine

Riassumi cosa è installato e dove: le due skill, gli hook, i PAT e la loro scadenza (da `pat-info.json`), le tre
attività pianificate, la cartella dati `%LOCALAPPDATA%\DevOps.Agents` con log e stato. Poi spiega all'utente
come si usa:

- un lavoro nuovo in un repo della mappa si porta agli agenti con la skill `devops-agents`, che guida l'analisi e crea la
  card; la card è assegnata a chi la crea, e il suo smistatore la prende quando l'utente la porta in New;
- la vista su `http://localhost:18799/vista.html` mostra cosa fanno gli agenti e ha il pulsante **giro adesso**;
- quando i PAT stanno per scadere si rilancia `setup/Install-Attrezzi.ps1 -Pat`;
- per fermare tutto si lancia `setup/Install-Attrezzi.ps1 -RimuoviPianificazione`, oppure si disabilitano le attività
  da Utilità di pianificazione;
- gli attrezzi si aggiornano da soli (D53): il supervisore controlla origin ogni 30 minuti e aggiorna la copia principale
  quando non ci sono sessioni di agenti in corso, poi rilancia l'installazione e un giro di prova; se qualcosa non va torna
  alla versione di prima e lo dice su Telegram. L'utente non fa `git pull`. La versione installata e quella disponibile si
  vedono nella vista (`http://localhost:18799/vista.html`, scheda Agenti, riquadro **Suite**), che ha anche il pulsante
  **Aggiorna adesso** e l'interruttore **Aggiornamento automatico**;
- il canale si cambia in `impostazioni.json`, nella cartella dati (`%LOCALAPPDATA%\DevOps.Agents`): `"canale": "main"`
  (predefinito per i colleghi) o `"develop"`. Le impostazioni personali (canale, aggiornamento automatico e le modifiche ai
  valori di `config/limiti.json` e `config/supervisore.json`) vanno lì e non nei file del repo: una copia con modifiche
  locali non si aggiorna. Il README ("L'aggiornamento automatico della suite") spiega il resto;
- se cambia `intervalloMinuti` si rilancia `-Pianificazione`.
