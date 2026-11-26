# Collaudo per funzionalità (D52): piano

La decisione, con il perché e le alternative scartate, è D52 in `docs/decisioni.md`. Qui c'è solo il come. Si costruisce
in sei gruppi, uno dopo l'altro, ciascuno in una PR verso develop, con una revisione Opus per gruppo e una revisione Opus
finale del tutto. I primi tre gruppi non cambiano niente per le card isolate e nemmeno attivano D52: una card diventa
"della funzionalità" solo quando esiste una Feature con la card di chiusura, e quella si crea con il comando del gruppo 2.
Il flusso completo si accende con il gruppo 4. Fino ad allora nessuno deve creare una Feature con `card crea -Tipo
Feature`: il comando del gruppo 2 lo dice.

Regole per chi sviluppa (valgono per ogni task):

- Prima il test che fallisce, poi il codice (regole di sviluppo, TDD). Nel riepilogo il nome del test e l'errore del run rosso.
- `Invoke-Pester tests` tutto verde a fine task, nessun test saltato.
- Le card isolate non cambiano comportamento: i test esistenti di `Decisioni.Tests.ps1` restano verdi senza essere
  toccati, salvo dove il task dice di cambiarli.
- Ogni fatto ha un posto solo: la domanda "questa card è della funzionalità?" ha una funzione sola (gruppo 1, punto 3) e
  tutti la chiamano.

## Il modello in breve

- **Feature con card di chiusura** = funzionalità D52. Le figlie della Feature (link Parent) sono le card della
  funzionalità; una di loro, con il tag `collaudo-funzionalita`, è la card di chiusura. Le altre sono le "sorelle".
- **Ramo della funzionalità**: `feature/f<id Feature>-<slug>` o `bugfix/f<id Feature>-<slug>` (Feature con il tag `bug`).
- **Card della funzionalità**: worktree da `origin/<ramo della funzionalità>`, PR verso quel ramo, niente pr-validation,
  niente Test. Ready to merge → In feature branch → Ready to release insieme alla card di chiusura.
- **Card di chiusura**: aspetta le sorelle, apre la PR ramo della funzionalità → develop, deploy dal ramo della
  funzionalità, collaudo (poi Human test con `human-test`), merge in develop con il vincolo sul commit.

## Una variante rispetto al testo di D52, da scrivere in D52 nel gruppo 4

D52 risolve i conflitti della PR della funzionalità verso develop su un ramo proprio della card di chiusura, con una
seconda PR. Una card con due PR rompe l'assunto "una card, un ramo, una PR" su cui stanno `StatoCard.ramo`, `prId`,
`Get-IstantaneaCard` e la vista. Il piano usa invece la stessa strada della correzione: con la PR in conflitto lo
smistatore crea una card Bug tecnica sorella, con il tag `allinea-develop`, il cui `dev` unisce `origin/develop` nel suo
ramo (nato dal ramo della funzionalità) e apre la PR verso il ramo della funzionalità. Il `reviewer` di una card con quel
tag guarda solo la risoluzione del merge (`git show --remerge-diff`). La card di chiusura aspetta la sorella come per una
correzione. Il gruppo 4 corregge la voce D52 in questo senso.

## Gruppo 1: dati e lettura

Niente cambia nel comportamento: si aggiungono i dati che servono dopo.

1. **Configurazione.** In `config/stati.json`: `inFeature: "In feature branch"`, `tagChiusura: "collaudo-funzionalita"`,
   `tagBugFeature: "bug"`, `tagAllinea: "allinea-develop"`. Lo stato In feature branch esiste già nel processo
   `Custom.Agile` (User Story e Bug) e ha la sua colonna sulla board. `Get-StatiConRamo` (`src/Comune.psm1`) comprende
   `inFeature`, fra `daUnire` e `daRilasciare`.
2. **Azure DevOps** (`src/Ado.psm1`), ciascuna con il suo test in `Ado.Tests.ps1` sui finti:
   - `Get-AdoFeaturePadre -CardId`: la Feature padre (`System.LinkTypes.Hierarchy-Reverse`, solo se il tipo è Feature),
     con `Id`, `Titolo`, `Stato`, `Tag`, `Area`; `$null` senza padre;
   - `Get-AdoFigliFeature -FeatureId`: le figlie (`Hierarchy-Forward`) con `Id`, `Stato`, `Tag`, `Tipo`;
   - `Set-AdoStatoFeature -FeatureId -Stato`;
   - `Get-AdoPr`, `New-AdoPr`, `Get-AdoPrDelRamo`: parametro `-Destinazione`, predefinito `develop`. `Get-AdoPr` porta
     anche `UltimoCommit` (`lastMergeSourceCommit.commitId`);
   - `Get-AdoRun` porta anche `SourceVersion`;
   - `New-AdoCard` accetta `-Padre <id>` (relazione `Hierarchy-Reverse` nella stessa creazione, come `-Dopo`);
   - `Get-AdoCardPredecessori` porta anche l'id della Feature padre di ciascun predecessore, con `$expand=relations` nella
     stessa lettura (niente chiamata in più per predecessore).
3. **La funzionalità di una card** (`src/Istantanea.ps1`). Una funzione sola, `Get-FunzionalitaCard`, dà `$null` per una
   card isolata (senza Feature padre, o con una Feature senza card di chiusura) e altrimenti:
   `@{ Feature; Chiusura = <id card di chiusura>; Sorelle = <figlie tranne la chiusura e le Removed>; Ramo = <nome del
   ramo della funzionalità su origin, o $null>; EChiusura = <questa card è la chiusura> }`. La Feature e le figlie si
   leggono una volta per giro per Feature (cache nel contesto del giro, `New-ContestoGiro`), non una volta per card. Il
   campo `Ramo` lo riempie il gruppo 2 con `Find-RamoFunzionalita`; qui resta `$null`. `Get-IstantaneaCard` la mette in
   `Funzionalita`. In `Decisioni.psm1` le funzioni leggono solo `$a.Funzionalita`.
4. **Test**: `Ado.Tests.ps1` (le funzioni nuove, `-Destinazione` predefinita a develop), `Smistatore.Tests.ps1` o i test
   dell'istantanea dove stanno oggi (`Get-FunzionalitaCard`: isolata, Feature senza chiusura, card della funzionalità,
   card di chiusura, sorella Removed esclusa, una sola lettura per Feature in un giro con due card).

## Gruppo 2: creare Feature, card e rami

1. **`card crea`** (`src/card.ps1`, `New-Card` in `src/Card.psm1`):
   - `-Tipo Feature [-Bug]` crea la Feature (tag `bug` con `-Bug`) e la sua card di chiusura: User Story, figlia, tag
     `collaudo-funzionalita` e `agents`, in Draft, titolo `Collaudo funzionalità: <titolo>`, criteri dal file. Finché il
     gruppo 4 non è unito il comando si rifiuta con il messaggio "D52 non è ancora attiva": un interruttore
     `funzionalitaAttive` in `config/limiti.json`, `false`, che il gruppo 4 accende;
   - `-Feature <id>` crea una figlia. Rifiuta: un'area diversa da quella della Feature, una Feature Resolved o Closed,
     una Feature senza card di chiusura (allora è una Feature della spec, sezione 18, e la card va creata senza `-Feature`);
   - test in `Card.Tests.ps1` per ogni rifiuto e per la creazione.
2. **Il ramo della funzionalità** (`src/Worktree.psm1`):
   - `Get-NomeRamoFunzionalita($Feature)`: `feature/f<id>-<slug>` o `bugfix/f<id>-<slug>`, con `ConvertTo-SlugTitolo`;
   - `Find-RamoFunzionalita -Principale -IdFeature`: lo cerca su origin per id (`origin/feature/f<id>-*`,
     `origin/bugfix/f<id>-*`), come `New-WorktreeDaRemoto` cerca il ramo di una card. Il prefisso e il titolo possono
     essere cambiati dopo la creazione;
   - `Publish-RamoFunzionalita -Principale -Feature`: se `Find-` non lo trova, lo crea da `origin/develop` e lo pubblica.
     Un push rifiutato perché il ramo esiste già (un altro smistatore) non è un errore: fetch e si usa quello;
   - `New-WorktreeCard -Base <ramo>`: con la base il ramo della card nasce con `-B` da `origin/<base>`, mai da un ramo
     locale. Senza base resta com'è oggi (da `origin/develop`);
   - `Remove-WorktreeCard -Destinazione <ramo>`: il ramo locale si cancella se è contenuto in `origin/<destinazione>`
     (predefinito develop);
   - test in `Worktree.Tests.ps1` su un repo git temporaneo: nome, ricerca per id dopo un cambio di titolo, creazione,
     push rifiutato, worktree dalla base remota anche con un ramo locale vecchio, rimozione verso la destinazione.
3. **Il ramo dello YAML del deploy** (`Get-AdoRamoCard`, `Set-CardDeploy`): per la card di chiusura i parametri `deploy*`
   si leggono dal ramo della funzionalità. Test in `Card.Tests.ps1`.

## Gruppo 3: le card della funzionalità

Le card della funzionalità fanno il loro giro fino a In feature branch. La card di chiusura ancora non esiste (comando
spento), quindi i test costruiscono le istantanee a mano.

1. **Sviluppo** (`Get-AzioniPronto`): con `Funzionalita` e non chiusura, prima di `CreaWorktree` un'azione nuova
   `CreaRamoFunzionalita` se `Funzionalita.Ramo` è `$null`; `CreaWorktree` con `Base`; `AggiornaFeature @{ Stato =
   'Active' }` se la Feature è ancora New. `Invoke-Azione` in `src/Smistatore.ps1` esegue le due azioni nuove con le
   funzioni del gruppo 2 e `Set-AdoStatoFeature`.
2. **La base per dev e reviewer.** `Start-SessioneRuolo` (`src/Sessioni.psm1`) mette il ramo di base in `ATTREZZI_BASE`
   (`develop` per le card isolate). `ruoli/dev.md` (righe del merge D16) e `ruoli/reviewer.md` (il `git diff`) usano
   `origin/$env:ATTREZZI_BASE` al posto di `origin/develop`. Per una card con il tag `allinea-develop` il `reviewer`
   guarda solo la risoluzione del merge (`git show --remerge-diff`). Test in `Sessioni.Tests.ps1`.
3. **PR** (`ApriPr` in `src/Smistatore.ps1`, `Get-IstantaneaCard`): `New-AdoPr` e `Get-AdoPr` con `-Destinazione` =
   ramo della funzionalità. Lo stato della card salva `destinazione`. Senza build applicabili la PR è verde per D13, e
   la logica di `Get-AzioniPr` non cambia.
4. **Dopo la revisione** (`Get-AzioniInRevisione`, ramo `superata`): una card della funzionalità va in Ready to merge,
   come con `no-test-deploy`. Il ramo della sicurezza (D48) resta prima.
5. **Ready to merge** (`Get-AzioniDaUnire`): per una card della funzionalità non si completa la PR mentre la card di
   chiusura è in Deploying to test, Automated test, Human test o Ready to merge (lo stato si legge da
   `Funzionalita.Sorelle`/la chiusura, nessuna chiamata in più); il motivo `attesaCollaudoFunzionalita` va in
   `Format-MotivoCoda`. A PR completata la card va in **In feature branch**, non in Ready to release.
6. **In feature branch** (`Get-AzioniInFeature`, nuova, nel `switch` di `Get-AzioniDelloStato`): con il worktree,
   `RimuoviWorktree` (con la destinazione); quando la card di chiusura è in Ready to release o oltre, `SpostaCard
   daRilasciare`. Un task aperto aggiunto qui non riporta indietro la card (il lavoro è già nel ramo): un `Avvisa` una
   volta, "il lavoro nuovo va in una card nuova della funzionalità".
7. **Presa in carico** (`Test-DaPrendereInCarico`, `AdottaCard`): una card In feature branch senza stato locale non si
   adotta; si salva il `prId` dalla PR collegata, come per Ready to release.
8. **Predecessori** (`Test-PredecessoreUnito`): In feature branch è unito solo se il predecessore ha la stessa Feature
   della card che aspetta (l'id viene dal punto 2 del gruppo 1). Per tutte le altre resta "in develop".
9. **Test** in `Decisioni.Tests.ps1`, un caso per punto (1, 4, 5 con le quattro attese e il via libera, 6 con le tre
   uscite, 7, 8 nei due versi), e in `Smistatore.Tests.ps1` per `CreaRamoFunzionalita`, `AggiornaFeature` e `ApriPr`
   con la destinazione.

## Gruppo 4: la card di chiusura

Si accende D52: `funzionalitaAttive` a `true`.

1. **L'attesa delle sorelle** (`Get-BloccoPartenza`): per la card di chiusura i predecessori sono le sorelle non unite
   (In feature branch o oltre = unita, per definizione sono della stessa Feature). Senza sorelle il blocco è
   `senzaSorelle`. Il `Ruolo` è `responsabile` in New e nessuno (`$null`) in Ready to develop. La vista lo mostra come
   in D50 (`Get-AttesePredecessori`), con il gesto «togli il link Parent» al posto di «togli il link Predecessor».
2. **Il ritorno indietro**, in `Get-AzioniDelloStato` prima dello `switch`: una card di chiusura fra Deploying to test e
   Ready to merge con una sorella non unita torna in Ready to develop (`RiportaIndietro`, motivo con il numero della
   sorella).
3. **New**: il `responsabile` come oggi. `ruoli/responsabile.md` ha una sezione per la card di chiusura: legge la Feature
   e le sorelle, sceglie i parametri del deploy (D43), può mettere `human-test` o `no-test-deploy`, non crea task, sposta
   in Ready to develop.
4. **Ready to develop** (`Get-AzioniPronto` per la chiusura): niente worktree, e il limite `cardInSviluppoPerRepo` non
   la ferma né la conta (non sviluppa niente). Lo stato della card salva come `ramo` il
   ramo della funzionalità e come destinazione develop; `ApriPr` apre la PR ramo della funzionalità → develop, titolo
   con `Get-TitoloPr` (feature/ → feat, bugfix/ → fix: è già così). Poi, sulla validazione:
   - verde: `SpostaCard inDeployTest`;
   - scaduta: `RilanciaScadute` (D47);
   - in conflitto: la Bug `allinea-develop` (gruppo 5, punto 2), una sola per conflitto;
   - rossa: la correzione (gruppo 5, punto 1) con gli errori della build.
5. **Test** (`Get-AzioniComuniInTest`): per la card di chiusura `Test-RevisioneSuperata` non vale (non ha reviewer);
   restano il task aggiunto e `no-test-deploy`.
6. **Deploying to test** (`Get-AzioniInDeployTest`): il deploy parte dal `ramo` salvato, cioè quello della
   funzionalità. Run fallito: se `Get-AdoErroriBuild` trova passi di build o test falliti è una correzione (gruppo 5),
   altrimenti l'on-hold di oggi (D32). Run riuscito: sempre Automated test, anche con `human-test`.
7. **Automated test** (`Get-AzioniCollaudo`): superata, con `human-test` va in Human test, senza in Ready to merge.
   Respinta: il `responsabile` con motivo `collaudoRespinto` come oggi, ma per la card di chiusura il suo brief dice di
   scrivere la correzione (gruppo 5) invece di aggiungere task. La transizione del `responsabile` da `inCollaudo` a
   `inSviluppo` non serve alla chiusura: è lo smistatore a riportarla indietro (punto 2) quando nasce la Bug.
8. **Human test** (`Get-AzioniInProvaUmana`): un commento della persona va al `responsabile` come oggi; per la chiusura,
   correzione come al punto 7. Superata (la persona sposta in Ready to merge): come oggi.
9. **Ready to merge** (`Get-AzioniDaUnire` per la chiusura): la PR si completa solo se `Pr.UltimoCommit` è uguale a
   `Run.SourceVersion` del deploy (`runId` salvato). Diverso: `RiportaIndietro pronto`, "il ramo della funzionalità è
   cambiato dopo il deploy". A PR completata: Ready to release e `AggiornaFeature Resolved`; la Feature va in
   `featureDaChiudere` nello stato.
10. **Feature Closed**: le card Closed non sono fra le attive, quindi a ogni giro lo smistatore legge solo le card di
    chiusura delle Feature in `featureDaChiudere` (una GET ciascuna); con la chiusura Closed, `Set-AdoStatoFeature
    Closed` e la Feature esce dall'elenco.
11. **D52 nel registro**: la variante dei conflitti (sopra) e, nel "Dove", il rimando a questo piano.
12. **Test** in `Decisioni.Tests.ps1`: un caso per punto, e i casi di confine: chiusura senza sorelle, sorella Removed
    ignorata, sorella nuova in Human test con la card in on-hold (al primo giro senza on-hold torna indietro, e
    comunque il vincolo del commit al punto 9 la ferma), commit diverso al merge.

## Gruppo 5: correzioni

1. **La correzione dopo un collaudo respinto o una CI rossa.**
   - Comando nuovo `card.ps1 correzione` (solo `responsabile`, solo sulla card di chiusura): testo su stdin, prima riga
     `tecnico` o `prodotto`, poi titolo e descrizione. Lo salva in un commento con una marca (`Correzione:`), come fa
     `deploy` (`ConvertTo-TestoCommentoDeploy`/`Get-SceltaDeploy` in `src/Comune.psm1`: lo stesso schema, una funzione
     per scrivere e una per leggere).
   - Lo smistatore legge la marca nell'istantanea e fa `CreaCorrezione`: una Bug figlia della Feature, area della
     Feature. Tecnico: in New, tag `agents`. Prodotto: in Draft, con la menzione al titolare nel commento. Una correzione,
     una Bug: la chiave in `StatoCard.correzioniFatte`.
   - `New-Card` ammette la nascita in New solo per questa strada (un parametro che `card.ps1` non espone).
   - Dalla CI rossa (gruppo 4, punti 4 e 6) il `responsabile` parte con gli errori di `Get-AdoErroriBuild` come
     allegato, motivo `ciRossa`, e scrive la correzione allo stesso modo.
2. **La Bug `allinea-develop`.** Con la PR della funzionalità in conflitto lo smistatore crea da sé (senza
   `responsabile`) una Bug tecnica figlia, tag `allinea-develop` e `agents`, in New, titolo "Allinea <ramo> a develop",
   criteri "la PR <ramo> → develop non ha conflitti". Il suo `dev` riceve il motivo `conflitti` e unisce `origin/develop`
   (D16). Una sola alla volta: se ce n'è già una non unita, si aspetta.
3. **Test** in `Card.Tests.ps1` (il comando e i suoi rifiuti), `Decisioni.Tests.ps1` (respinta → responsabile → Bug →
   ritorno indietro → nuovo deploy; CI rossa; conflitti → una sola Bug; `giriCollaudo` contato sulla chiusura) e
   `Smistatore.Tests.ps1` (`CreaCorrezione` nei due casi).

## Gruppo 6: vista, supervisore, documenti

1. **Vista** (`src/Vista.ps1`, `src/VistaHtml.psm1`): le card della funzionalità raggruppate sotto la Feature, con lo
   stato della card di chiusura in testa; la card di chiusura in Draft con tutte le sorelle In feature branch va nella
   colonna dell'operatore con «spostala in New»; i motivi nuovi (`senzaSorelle`, `attesaCollaudoFunzionalita`). Test in
   `Vista.Tests.ps1`.
2. **Supervisore** (`src/Supervisione.psm1`): le card In feature branch e la card di chiusura che aspetta le sorelle non
   sono «ferme senza on-hold». La voce «Rilasci in attesa» conta una funzionalità come una voce, con il numero delle sue
   card. Test in `Supervisione.Tests.ps1`.
3. **Documenti**, nella stessa PR (la regola del registro):
   - `docs/decisioni.md`: D16, D26, D28 e D29 limitate alle card isolate, con il rimando a D52; la tabella «Chi fa cosa»;
   - la spec `docs/superpowers/specs/2026-11-16-ecosistema-agenti-design.md`: sezione 4 (lo stato In feature branch,
     Ready to release), sezione 5 (eventi: PR verso il ramo della funzionalità), sezione 18 (worktree dalla base,
     predecessore unito);
   - `README.md`: come si crea una funzionalità (`card crea -Tipo Feature`, poi `-Feature`).

## Ordine e prove

- I gruppi vanno in ordine: ciascuno usa le funzioni del precedente.
- Dopo ogni gruppo: `Invoke-Pester tests` e un giro `-WhatIf` dello smistatore sulla working copy, che non deve cambiare
  niente per le card in corso.
- Dopo il gruppo 4, la prova vera: una Feature piccola su Acme.Workflow con due card e la chiusura, creata da
  Il titolare con `card crea -Tipo Feature`. Si verificano il ramo `feature/f<id>-…`, le due PR verso di esso, un solo
  deploy dal ramo della funzionalità, il collaudo, il merge in develop e lo stato della Feature nel backlog Features.

## Costo

- Sviluppo: sei gruppi con `dev`. I gruppi 3 e 4 valgono ciascuno circa due card medie, gli altri circa una. Una
  revisione Opus per gruppo, una revisione Opus finale.
- Esercizio: una lettura in più per Feature per giro (Feature e figlie) e una GET per Feature in `featureDaChiudere`.

## Fuori da qui

- Le funzionalità su più repo (D52).
- Il riallineamento periodico del ramo della funzionalità a develop (scartato in D52).
