---
name: regole-sviluppo
description: "Le regole di sviluppo dei repo della mappa, valide in ognuno. Caricala prima di scrivere codice o di rivedere una PR: dice dove va scritta una decisione, come si applicano i cinque principi SOLID e cosa deve dichiarare chi rivede."
---

# Regole di sviluppo

Queste regole valgono su tutto il codice nuovo di ogni repo. Una modifica che le viola è sbagliata anche se compila e
anche se i test sono verdi, perché i test non vedono quasi mai due copie della stessa decisione che divergono. Ogni
repo ha un `CLAUDE.md` con ciò che è suo: recinto dei componenti, comando dei test, guardie a macchina e guasti da cui
sono nate. Il codice esistente che viola una regola sta nell'elenco di eccezioni di quel `CLAUDE.md`: l'elenco può solo
accorciarsi, e su un file che ha già più responsabilità non se ne aggiunge un'altra.

## Regola zero

Un fatto ha un posto solo dove è scritto, e tutti lo leggono da lì. Se lo stesso fatto sta in due posti che non si
parlano, prima o poi uno cambia senza l'altro e l'app fa due cose diverse nella stessa situazione, senza che nulla lo
segnali. Vale per le configurazioni, per i valori costanti, per i controlli di autorizzazione, per i calcoli e per i
vincoli di schema.

## R1: i principi SOLID si applicano

Si applicano sempre e senza chiedere il permesso. Servono a tenere uniformi i comportamenti: cinque copie identiche
oggi sono cinque comportamenti diversi domani. Ogni principio ha la domanda con cui si verifica.

KISS e YAGNI dicono quanto in grande costruire, non se dare una casa a una decisione. Si astrae dove c'è una decisione
da condividere, non per simmetria.

- **Responsabilità singola.** Un modulo ha una sola ragione per cambiare. Se due punti rispondono alla stessa domanda
  di dominio, la domanda ha un servizio solo. Domanda: chi può chiedere la modifica di questo file, e sono più
  soggetti?
- **Aperto/chiuso.** Un caso nuovo si aggiunge estendendo, non riaprendo N file esistenti. Domanda: se arriva un
  caso in più, quanti file già scritti devo modificare?
- **Sostituibilità.** Chi usa un'astrazione non deve sorprendersi dell'implementazione che trova. Un tipo che dichiara
  opzionale ciò che il sistema pretende promette il falso. Domanda: il tipo dice la verità su ciò che richiede?
- **Interfacce segregate.** Nessuno dipende da metodi che non usa. Domanda: ogni consumatore usa tutti i membri
  dell'interfaccia che riceve?
- **Dipendenza dalle astrazioni.** Si parla all'interfaccia, non alla classe concreta, e chi sta in alto non conosce
  l'accesso ai dati. Domanda: da quali tipi concreti dipende questo codice, e c'è un'interfaccia che li nasconde?

### Prima di scrivere

1. Se sto per scrivere un metodo privato che risponde a una domanda di dominio, cerco se la domanda esiste già. Se
   esiste la chiamo, altrimenti le creo una casa. Cerco per ciò che il codice decide, non per nome: chi copia spesso
   rinomina, e una ricerca del nome fa credere di aver finito.
2. Se sto per copiare del codice, mi fermo. La copia è giusta solo se le due parti devono poter divergere. Se devono
   restare uguali, copiare equivale ad averle già separate.
3. Se ho unificato qualcosa, guardo quali dipendenze sono diventate inutili e le tolgo: erano il sintomo di un pezzo
   nel posto sbagliato.
4. Se la regola che scrivo deve valere per tutti, scrivo la guardia: un test che fallisce se qualcuno la aggira. Una
   regola senza guardia vale solo finché qualcuno se ne ricorda, e va dichiarata come tale.

## R2: la struttura dati segue il comportamento

Un vincolo di schema è una decisione di prodotto, non un dettaglio tecnico: va rivisto come tale. Se un comportamento
voluto e la struttura dati non vanno d'accordo, si cambia la struttura. Convivere con il vincolo nasconde il problema e
lo lascia al prossimo.

## Regole di struttura

- Una configurazione condivisa da più processi (autenticazione, lettura dell'identità del chiamante, codici
  costanti) sta in un modulo comune, mai ricopiata in ciascun processo.
- Una dipendenza dichiarata opzionale ma sempre registrata si rende obbligatoria: il tipo non deve poter funzionare
  facendo meno in silenzio.
- Un progetto non dipende da un altro per codice che è comune a entrambi: il codice comune va in un progetto
  condiviso.
- Un endpoint contiene solo rotta, autorizzazione e forma della risposta. La logica sta in un servizio, e i dati si
  leggono attraverso di esso.
- Un valore che attraversa un confine tra processi o moduli è una costante condivisa, non una stringa ripetuta ai due
  lati.

## Sviluppo guidato dai test

Prima si scrive il test che fallisce, poi il codice che lo fa passare. Un test scritto dopo il codice descrive ciò
che il codice fa, non ciò che deve fare, e passa anche se il comportamento è sbagliato. L'ordine non si può
verificare a macchina, quindi la verifica è indiretta:

- `dev` riporta nel riepilogo il run rosso: il nome del test e l'errore con cui falliva prima dell'implementazione.
- `reviewer` controlla che ogni comportamento cambiato abbia nel diff un test che fallirebbe senza la modifica. Se
  manca, il rilievo è bloccante.

## Come si scrive un test

Un test lento o instabile non costa solo alla PR che lo introduce: la validazione gira su ogni PR successiva, e un
rosso a caso fa rifare un giro di sviluppo e uno di revisione a chi non c'entra. Il 2026-11-19 la validazione di
Stime era passata da 5 a 25 minuti e falliva una volta su due.

- **Deterministico.** L'esito dipende solo dal codice provato. Se il codice legge l'ora, il test gli passa un orologio
  controllato. Se il codice aspetta un evento, il test aspetta l'evento e non un intervallo fisso. Niente casualità
  senza seme, niente porte o file fissi che un altro test può usare nello stesso momento.
- **Isolato.** Ogni test prepara i dati che gli servono e non conta su quelli lasciati da un altro, perché l'ordine di
  esecuzione non è garantito. Fra test si condivide solo ciò che nessuno modifica.
- **Il costoso si prepara una volta.** Un database, un server di prova, un file grande da generare o caricare si
  creano una volta per classe o per collezione di test, non uno per test. Fra un test e l'altro si riporta allo stato
  iniziale ciò che è stato modificato, con un'operazione che costa poco.
- **Al livello più basso che basta.** Un comportamento che si prova su una classe non si prova avviando l'applicazione
  o il database. Il test di integrazione prova il collegamento fra le parti, non ogni ramo della logica.

`dev` riporta nel riepilogo, accanto al conteggio, quanto è durato il run dei test. Se un test nuovo dura più di
qualche secondo, scrive perché non si poteva fare più veloce. `reviewer` tratta un test che viola una di queste regole
come una violazione di `regole-sviluppo`.

## I test girano sempre tutti

Due controlli a macchina stanno nella validazione della PR di ogni repo su cui il sistema lavora:

- La validazione fallisce se anche un solo test risulta saltato.
- La validazione fallisce se nella soluzione esiste un progetto di test che la pipeline non esegue.

Un test saltato o un progetto dimenticato danno una validazione verde che non ha verificato niente. Un test che non
può girare per un prerequisito mancante deve fallire, non uscire senza asserire: un'uscita silenziosa risulta passata
e nessuno controllo la vede.

## Cosa verifica la macchina e cosa chi rivede

Le regole verificabili a macchina sono test di guardia nella validazione della PR, e la fanno fallire. Le altre le
verifica `reviewer`, che per ciascuna scrive un esito. Un esito scritto obbliga a guardare il punto: un "nessun
problema" senza motivazione si può dare senza aver letto.

### Controllo della responsabilità singola

Per ogni file toccato dal diff, `reviewer` scrive in una frase la ragione per cui quel file cambia, cioè chi può
chiederne la modifica. Se il diff ne introduce una seconda, il rilievo è bloccante, con le righe citate, e il pezzo
nuovo va in un tipo suo. La dimensione del file non è un criterio: un file lungo con una sola ragione è a posto, uno
breve con due no.
