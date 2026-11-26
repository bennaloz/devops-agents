# Supervisore e pausa per quota (D51): piano

La decisione, con il perché e le alternative scartate, è D51 in `docs/decisioni.md`. Qui c'è solo il come. Si costruisce
in tre gruppi, uno dopo l'altro, ciascuno in una PR. Ogni gruppo ha una revisione Opus; il primo gruppo è quello che
sblocca subito più card.

## Gruppo 1: la quota nello smistatore

1. **Leggere la quota.** In `src/Sessioni.psm1`, `Get-EsitoSessione` porta anche l'ultimo `rate_limit_event` del jsonl
   (`five_hour` e `seven_day` con `utilization`, `resetsAt`, `status`). Porta anche `LimiteRaggiunto`: un evento
   `rejected`, oppure il testo "hit your … limit" nel risultato, con l'orario del reset.
2. **`quota.json`** nella cartella dati, scritto da `Close-Sessione` (`src/Smistatore.ps1`). Contiene l'ultima lettura,
   la pausa fino a (`resetsAt` più `margineQuotaMinuti`, 5) e le sessioni da riprendere (card, ruolo, id). Si legge e si
   scrive con lo stesso schema di `Stato.psm1` (sostituzione del file, ritentativi come in D45).
3. **Sessione finita sul limite.** In `Close-Sessione` si controlla prima di `esito.Errore`. Non chiama `Set-InAttesa`:
   scrive la pausa, una riga di log, un commento sulla card ("ferma per il limite di token fino alle …, riprende da
   sola") e salva `ultimaSessione` con `limite = $true`.
4. **Decisioni.** `Get-Decisione` riceve la quota nell'istantanea.
   - Con la pausa attiva, o con `seven_day` oltre `sogliaQuotaSettimanale` e reset non ancora passato, ogni
     `LanciaSessione` diventa il motivo `quota`, con il `Ruolo` (D31) e l'ora di ripresa.
   - Dopo la pausa, una card con `ultimaSessione.limite` riprende con `Riprendi`. È la stessa strada della ripresa dopo
     un on-hold per `sessione`, ma senza on-hold.
   - `Format-MotivoCoda` e la vista mostrano `quota`.
5. **Config.** In `config/limiti.json`: `sogliaQuotaSettimanale: 0.70` e `margineQuotaMinuti: 5`; `Config.psm1` li
   valida.
6. **Test** in `Sessioni.Tests.ps1` (jsonl finti con `rate_limit_event`, uno `rejected` e uno con il testo),
   `Decisioni.Tests.ps1` (pausa, soglia, ripresa, nessun lancio con la pausa) e `Smistatore.Tests.ps1` (Close-Sessione
   sul limite: niente on-hold).

## Gruppo 2: gli on-hold che si tolgono da soli

1. **Le regole** in `Get-Decisione`, nel ramo `onHold`, che oggi esce subito. Prima di uscire una funzione pura
   `Get-AttesaSciolta` guarda tre casi:
   - `ultimaSessione` con il testo del limite e il reset passato;
   - `inAttesaPer = limite` per validazioni rosse e `Pr.Validazione = verde`;
   - un on-hold da `Close-Sessione` (silenzio o morta) con `ripreseAutomatiche` a 0.
   Se una vale, l'azione è `TogliAttesa` con la causa. Senza un dato certo la card resta in on-hold.
2. **`TogliAttesa`** in `Invoke-Azione`: toglie il tag, scrive `[smistatore] tolgo l'on-hold: <causa>` e segna nello
   stato `attesaToltaDaSmistatore`. Al giro dopo, il ramo "una persona ha tolto l'on-hold" (`AzzeraPassateAttesa`) vede
   il segno: riparte come oggi ma non svuota `passateFatte`, e incrementa `ripreseAutomatiche` quando la causa era il
   silenzio.
3. **`Set-InAttesa`** scrive anche una riga di log `on-hold: <motivo> (per <inAttesaPer>)`. Il supervisore la legge.
4. **Test** in `Decisioni.Tests.ps1` (i tre casi, il deploy escluso, la seconda ripresa negata, `passateFatte`
   conservato).

## Gruppo 3: il supervisore

1. **`src/Supervisore.ps1`**, senza modello, con `-WhatIf` come lo smistatore. Ogni controllo è una funzione pura che
   da quello che legge (`stato.json`, `quota.json`, log del giorno, `registro-sessioni.jsonl`, informazioni
   sull'attività pianificata, una GET a `http://localhost:18799/vista.html`, ADO con il PAT dello smistatore attraverso
   le funzioni di `Ado.psm1` già usate dalla vista: `Get-AdoBuildPipeline`, agenti dei pool) produce dei **problemi**:
   chiave, urgente sì/no, testo, azione esatta, link.
   - Gli N e le soglie stanno in `config/supervisore.json`: minuti senza giro, ore di on-hold, ore senza movimento,
     errori di fila per card, testi dei fallimenti per infrastruttura, orari del riepilogo, ore del ricordo urgente,
     `diagnosiAlGiorno`.
   - Le card ferme si leggono con `Get-Decisione` (D30), non con un'altra logica.
2. **I gesti:**
   - `Start-ScheduledTask` della Vista se non risponde, al più una volta all'ora;
   - rilancio di un run fallito per infrastruttura, una volta per run (`Ado.psm1`, la stessa POST della rivalutazione o
     una `builds` nuova sullo stesso ramo). Le validazioni delle PR delle card restano fuori.
3. **`supervisore.json`** nella cartella dati: problemi aperti (primo visto, ultimo avviso, chiuso), gesti fatti,
   diagnosi del giorno. Un problema che non si vede più si chiude, senza messaggi.
4. **Avvisi** con `Telegram.psm1`.
   - Urgenti subito, poi ricordati ogni 4 ore se restano aperti.
   - Riepilogo alle 8:30 e alle 14:00 nei feriali, solo con voci nuove o da ricordare (una volta al giorno).
   - Alla prima esecuzione dopo l'accensione, il riepilogo di cosa è in sospeso.
   - `Send-AvvisoTelegram` esce da `Set-InAttesa`; gli avvisi del PAT (`Test-ScadenzaPat`, 401) diventano problemi del
     supervisore, che li legge dal log e da `pat-info.json`.
5. **Diagnosi.**
   - Ruolo `supervisore` in `config/ruoli.json` (`sonnet`, sforzo medium, Read, Grep, Glob, PowerShell; nessuna
     transizione) e brief `ruoli/supervisore.md`: leggi log, stato e codice, scrivi causa probabile e azione esatta, non
     correggere.
   - Lancio con `Start-SessioneRuolo` (stesso PAT in lettura, stessi hook), nella copia principale.
   - Il testo finisce nel riepilogo.
6. **Pianificazione.** `setup/Install-Attrezzi.ps1 -Pianificazione` registra anche `DevOps.Agents\Supervisore`
   ogni 5 minuti; `-RimuoviPianificazione` la toglie. Aggiornare il README (sezione Lo smistatore, avvisi Telegram).
7. **Test** in `tests/Supervisore.Tests.ps1` (ogni controllo con dati finti; dedup e ricordo; riepilogo vuoto che non
   parte; PC appena acceso), `Install.Tests.ps1` e `Telegram.Tests.ps1` se cambia la firma.

## Ordine e prove

- Gruppo 1 prima: toglie il fermo più frequente e serve al gruppo 3 (la quota fra i problemi).
- Dopo ogni gruppo: `Invoke-Pester tests`, un giro `-WhatIf` sulla working copy, e per il gruppo 3 un `Supervisore.ps1
  -WhatIf` che stampi i problemi di oggi. Deve trovare almeno la card 11 in on-hold per `deploy` e, se è ancora ferma, la
  40.
- La card 40 è la prova vera del gruppo 2: dopo il merge l'on-hold si deve togliere da solo e il reviewer deve
  riprendere.

## Costo

- Sviluppo: tre gruppi con `dev`; ciascuno vale circa una card media. Una revisione Opus per gruppo.
- Esercizio: lo script non spende token. Una diagnosi Sonnet costa circa 0,5-1 M token, quasi tutti di cache, al più 3
  al giorno, attese poche al mese.

## Fuori da qui

- Lo spegnimento del PC (decisione dopo il primo periodo, con i dati di `quota.json` e del registro).
- Una scheda "Supervisore" nella vista con i problemi aperti: si può aggiungere dopo, leggendo `supervisore.json`.
