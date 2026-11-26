# Memoria dei ruoli (D46): piano

La decisione, con il perché e le alternative scartate, è D46 in `docs/decisioni.md`: qui c'è solo il come.

## Pezzi

1. **Il ruolo `mentore`.** `ruoli/mentore.md` e una voce in `config/ruoli.json`: Opus, sforzo high, strumenti Read,
   Grep, Glob, PowerShell e Skill. Niente Write e niente Edit: scrive solo con `memoria.ps1`, che controlla formato e tetto.
   Nessuna transizione di stato: il mentore non sposta card.
2. **Il comando `src/memoria.ps1`**, l'unico che tocca i file della memoria. Comandi:
   - `leggi <ruolo> <repo>` (stabili + in prova, con l'etichetta);
   - `scrivi <ruolo> <repo|comune>` (lezione da stdin);
   - `rivedi <id>`;
   - `togli <id>`;
   - `conflitto <card>` (commento sulla card e nota nella PR).

   Lavora in un worktree fisso dello smistatore (`_wt/DevOps.Agents/memoria`, ramo `memoria/in-prova`). Fa commit
   e push, e apre la PR della memoria verso develop se non c'è, o la aggiorna.

   Rifiuta:
   - una lezione senza i quattro campi (situazione, cosa fare, perché, card);
   - un file oltre il tetto (`memoria.tetto` in config, 25): in quel caso chiede il consolidamento.
3. **Gli inneschi, in `src/Decisioni.psm1`.** Una funzione pura `Get-AzioniMentore` che, dall'istantanea e dalle azioni
   del giro, produce `LanciaMentore` con un allegato: ruolo corretto, chi corregge, testo della correzione, card. Gli
   inneschi sono quelli di D46:
   - `dev` con motivo `decisione` o `rilievi`;
   - `AzzeraPassateAttesa`, o un commento di una persona;
   - `inProvaUmana` → `inSviluppo`;
   - un Bug unito (dopo la fix: serve il diff per il blame).

   Una correzione lancia il mentore una volta sola, come le passate di D42, con una chiave nello stato della card.
4. **Il lancio, in `src/Smistatore.ps1`.** `LanciaMentore` usa `Start-Sessione` come gli altri ruoli. La sessione non
   tiene la card: gira in parallelo al flusso e non lo blocca.
5. **La memoria all'avvio, in `src/Sessioni.psm1`.** Il brief passato con `--append-system-prompt-file` diventa un file
   composto: il brief del ruolo, poi `memoria/<ruolo>/comune.md`, poi `memoria/<ruolo>/<repo della card>.md`, ciascuno
   da develop e dal ramo `memoria/in-prova`, con le lezioni in prova marcate. Una funzione pura compone il testo; un
   wrapper legge i file.
6. **Il registro, in `src/Stato.psm1` + `src/Smistatore.ps1`.** Un `registro.jsonl` nella cartella di stato, solo in
   aggiunta. Ogni riga è un blocco, un on-hold o una correzione, con data, card, ruolo, motivo e, se c'è, la lezione
   applicata.
7. **La vista, in `src/Vista.ps1` + `src/VistaHtml.psm1`.** Una sezione «Apprendimento» con blocchi e correzioni per ruolo
   e per settimana, e le lezioni in prova in attesa di conferma. La PR della memoria ha in descrizione lo stesso
   riassunto.
8. **I brief.**
   - `ruoli/*.md`: una riga che dice cos'è la memoria e la precedenza (regole > stabili > in prova).
   - `ruoli/mentore.md`: cos'è una lezione, cosa non lo è, i conflitti con le regole, il consolidamento.

## Ordine e test

TDD come sempre: il test rosso prima, riportato nel riepilogo.

| Gruppo | Pezzi | Test Pester |
|---|---|---|
| A | 3, 6 | `Decisioni.Tests.ps1`: ogni innesco produce `LanciaMentore` una volta; nessun innesco, nessun lancio. `Stato.Tests.ps1`: il registro aggiunge e non riscrive. |
| B | 2 | `Memoria.Tests.ps1` (nuovo): formato rifiutato, tetto, scrivi/rivedi/togli su un repo git finto; push e PR con le API finte di `tests/finti/`. |
| C | 1, 4, 5, 8 | `Sessioni.Tests.ps1`: composizione del brief, ordine, etichetta in prova, file mancanti. `Smistatore.Tests.ps1`: `LanciaMentore` lancia senza toccare lo stato della card. `Config.Tests.ps1`: il ruolo `mentore` è valido. |
| D | 7 | `Vista.Tests.ps1`: aggregazione per ruolo e settimana. |

Una revisione Sonnet per gruppo, una revisione Opus finale del ramo. Poi la prova dal vivo: una card vera con un blocco
del dev, che deve far nascere la lezione e la PR della memoria.

Stima: mezza giornata di sviluppo agentico, quattro gruppi.

## Fuori da qui

- La promozione di una lezione a regola resta una proposta nella PR: il mentore non tocca brief né `CLAUDE.md` dei repo.
