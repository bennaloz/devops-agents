### dev-001
- Situazione: Il task chiede di correggere un difetto su alcuni campi nominati, e trovi lo stesso difetto, con la stessa causa, in un altro campo dello stesso codice che stai toccando (stesso DTO, stessa proiezione, dentro il recinto), che nessun altro task copre.
- Cosa fare: Correggilo nello stesso task con la stessa correzione che il task prescrive, con il suo test rosso, e scrivilo nel riepilogo. Se non sei sicuro che sia lo stesso difetto o che rientri nel task, chiudi con ESITO=bivio: mai segnalarlo come 'da decidere' e chiudere con ESITO=fatto.
- Perché: Il task descrive il difetto con i casi che chi l'ha scritto conosceva, non con tutti: applicare la correzione già scelta a un caso gemello non è una scelta nuova. Segnalarlo e chiudere con fatto lascia la decisione a nessuno, e il difetto torna indietro come bloccante dalla revisione.
- Card: 11

### dev-002
- Situazione: Nel codice aggiungi un comportamento che conta solo quando un'azione si ripete sulla stessa istanza (azzerare stato, contatori, timer o dati della volta precedente quando ricomincia un'attesa, una valutazione, un caricamento), anche se non è un criterio della card e lo citi solo nel riepilogo.
- Cosa fare: Scrivi per quel comportamento un test che lo faccia fallire se togli le righe: lo scenario esegue l'azione una volta fino in fondo, lascia lo stato pieno, poi la ripete sulla stessa istanza e controlla cosa si vede prima del primo dato nuovo. Mettilo nel run rosso come gli altri.
- Perché: Un test che parte da una pagina o un oggetto nuovo trova lo stato già vuoto, quindi passa anche senza l'azzeramento: il comportamento resta senza test, il reviewer lo blocca per TDD e l'errore che previene (valori vecchi o negativi mostrati alla seconda esecuzione) torna senza che niente lo segnali.
- Card: 56

### dev-003
- Situazione: Scrivi o modifichi uno script, anche di sviluppo in dev/ e fuori dalla CI, anche se parla con un servizio esterno (Admin API di Keycloak, az, un database), e il task come verifica chiede solo il parsing o una prova a mano, oppure hai testato solo le funzioni che calcolano.
- Cosa fare: Dai a ogni comportamento nuovo un test che fallisce senza la modifica e mettilo nel run rosso: separa la logica dalle chiamate e sostituisci la funzione che chiama il servizio con un finto che registra le richieste (come i test Pester degli script di pipeline con un az finto), e prova cosa crea, che una seconda esecuzione non crea niente, i rami di ripiego con un input davvero rotto e l'uscita del punto d'ingresso con il codice d'uscita sugli argomenti sbagliati. Se ritieni che uno script non vada testato, non deciderlo tu: scrivilo nel commento e chiudi con ESITO=bivio, non con fatto.
- Perché: Il 'fatto quando' del task è la verifica minima, non un'esenzione dal TDD che il brief chiede per ogni comportamento: il parsing passa anche con la logica sbagliata e i test delle sole funzioni interne restano verdi se togli un ramo o una sezione dell'uscita. Il reviewer blocca la PR, e che una cartella di script resti senza test lo può decidere solo il responsabile nel registro delle decisioni.
- Card: 66

### dev-004
- Situazione: Un test controlla un invariante del tipo 'nessuna X' (nessuna scrittura al secondo giro, nessuna chiamata, nessun evento) e il codice ha un'eccezione voluta e già decisa (per esempio un reset che riscrive sempre lo stesso valore), e proponi o scrivi come trattarla.
- Cosa fare: Verifica in positivo: il test confronta l'elenco completo di ciò che succede con l'elenco esatto atteso (esattamente un'operazione eccezionale per ogni elemento previsto, nient'altro), invece di filtrare l'eccezione e controllare che il resto sia vuoto. Proponilo già così nelle strade del bivio.
- Perché: Un filtro 'tutto tranne X' resta verde se X si ripete, se manca per un elemento o se un'altra operazione si traveste da X: l'eccezione diventa un buco nel test. L'elenco esatto fa fallire il test per un'operazione in più, una che manca o una diversa, e il responsabile non deve riscrivere la strada proposta.
- Card: 66
