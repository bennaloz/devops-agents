#requires -Version 7
# Il disegno HTML del modello della vista (vedi Get-ModelloVista in Vista.ps1). Funzione pura: riceve il modello, restituisce
# il testo della pagina, non legge ne scrive niente. Una pagina sola, CSS inline, nessuna risorsa esterna; l'unico script e quello che ricorda se le catene sono chiuse (la pagina di una sessione ne ha uno suo, per lo scorrimento).
# Ogni testo che viene da Azure DevOps o dalle sessioni passa da E (escape): la pagina non si fida di nessun dato.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'VistaUfficioPannello.psm1') -Global

function E($Testo) { [System.Net.WebUtility]::HtmlEncode([string]$Testo) }

# I nomi delle colonne degli agenti, nell'ordine del flusso. Il modello dice quali ruoli esistono (Agenti[].Ruolo): qui solo
# il titolo da mostrare.
$script:TitoliRuoli = @{ responsabile = 'Responsabile'; dev = 'Dev'; reviewer = 'Reviewer'; collaudatore = 'Collaudatore'; mentore = 'Mentore' }

$script:Css = @'
:root {
  --sfondo: #f4f5f7; --superficie: #ffffff; --testo: #1d2430; --attenuato: #667085; --bordo: #dde1e8;
  --accento: #2557d6; --accento-sfondo: #e8eefc;
  --verde: #1f9d55; --ambra: #c77a06; --rosso: #d03b3b; --grigio: #8a93a3;
  --codice-sfondo: #f0f2f6;
  --sblocca-sfondo: #fde8e8; --sblocca-testo: #8a1f1f; --rispondi-sfondo: #efe7fb; --rispondi-testo: #4b2a8a;
  --prova-sfondo: #fdf0d5; --prova-testo: #7a4a00; --rilascia-sfondo: #dcf5f1; --rilascia-testo: #0b5c52;
}
@media (prefers-color-scheme: dark) {
  :root {
    --sfondo: #12151b; --superficie: #1b2029; --testo: #e6e9ef; --attenuato: #98a1b3; --bordo: #2c3341;
    --accento: #7ba3ff; --accento-sfondo: #1d2a49;
    --verde: #3ec47c; --ambra: #e9a23b; --rosso: #f06a6a; --grigio: #7b8498;
    --codice-sfondo: #141922;
    --sblocca-sfondo: #3a1c1c; --sblocca-testo: #f6b4b4; --rispondi-sfondo: #2c2144; --rispondi-testo: #d2bdf7;
    --prova-sfondo: #3a2c10; --prova-testo: #f3cf8a; --rilascia-sfondo: #12332f; --rilascia-testo: #8fe0d4;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--sfondo); color: var(--testo); font: 15px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
main { padding: 20px 16px 48px; }
h1 { margin: 0; font-size: 28px; letter-spacing: -0.01em; }
.sotto { margin: 4px 0 18px; color: var(--attenuato); font-size: 13px; }
h2 { margin: 28px 0 10px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--attenuato); }
h2 .conta, h3 .conta { display: inline-block; min-width: 22px; padding: 0 7px; margin-left: 6px; border-radius: 11px; background: var(--bordo); color: var(--testo); font-size: 12px; text-align: center; letter-spacing: 0; }
h3 { margin: 16px 0 8px; font-size: 14px; }
.avviso { margin: 0 0 16px; padding: 10px 14px; border-radius: 8px; border: 1px solid var(--ambra); border-left-width: 5px; background: var(--superficie); color: var(--testo); }
.vuoto { color: var(--attenuato); font-style: italic; }
.kanban { display: grid; gap: 10px; align-items: start; overflow-x: auto; }
.colonna { min-width: 0; background: color-mix(in srgb, var(--superficie) 55%, var(--sfondo)); border: 1px solid var(--bordo); border-radius: 10px; padding: 4px 10px 12px; }
.colonna.pipeline { border-style: dashed; background: transparent; }
.colonna h2 { margin: 10px 0 8px; }
.colonna h3 { margin: 14px 0 6px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--attenuato); }
.colonna .scheda { margin-bottom: 10px; }
.giro-supervisore { margin: 0 0 10px; font-size: 13px; color: var(--attenuato); }
.voce.problema { border-left: 3px solid var(--ambra); }
.voce.problema.urgente { border-left-color: var(--rosso); background: color-mix(in srgb, var(--rosso) 10%, transparent); }
.etichetta.urgente { background: var(--rosso); color: #fff; }
.libero { margin: 0 0 10px; padding: 10px 12px; border: 1px dashed var(--bordo); border-radius: 8px; color: var(--attenuato); font-style: italic; }
.scheda { background: var(--superficie); border: 1px solid var(--bordo); border-left: 5px solid var(--verde); border-radius: 10px; padding: 12px 14px; min-width: 0; }
.scheda.pausa { border-left-color: var(--ambra); }
.scheda h3 { margin: 0 0 8px; font-size: 15px; overflow-wrap: anywhere; }
a.brief { margin-left: 8px; font-size: 11px; font-weight: 600; text-transform: none; letter-spacing: 0; color: var(--accento); opacity: 0.8; }
a.segui { margin-left: 6px; font-size: 12px; font-weight: 600; color: var(--accento); }
.giro { margin: 0 0 16px; display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.contatori { margin: -10px 0 14px; font-size: 13px; color: var(--attenuato); }
.contatori b { color: var(--testo); font-variant-numeric: tabular-nums; }
.giro button { padding: 6px 14px; border-radius: 8px; border: 1px solid var(--accento); background: var(--accento-sfondo); color: var(--accento); font: inherit; font-weight: 600; cursor: pointer; }
.giro button:disabled { opacity: 0.6; cursor: default; }
.quota-riga { margin: -6px 0 12px; font-size: 13px; color: var(--attenuato); }
.quota-riga b { color: var(--testo); font-variant-numeric: tabular-nums; }
.suite { margin: 0 0 16px; padding: 10px 14px; border-radius: 8px; border: 1px solid var(--bordo); background: var(--superficie); }
.suite h2 { margin: 0 0 6px; font-size: 16px; }
.suite p { margin: 4px 0; font-size: 13px; color: var(--attenuato); }
.suite p b { color: var(--testo); font-variant-numeric: tabular-nums; }
.suite .suite-stato.allarme { color: var(--rosso); }
.suite ul { margin: 4px 0; padding-left: 18px; font-size: 13px; }
.suite .giro { margin: 6px 0 0; }
/* la testata, in alto a destra e visibile da ogni scheda: la Suite compatta (si apre con tutto il riquadro) */
.testata { position: relative; z-index: 40; display: flex; justify-content: flex-end; align-items: center; gap: 10px; padding: 10px 16px 0; }
.testata > a { font-size: 13px; font-weight: 600; }
.suite-compatta > summary { list-style: none; cursor: pointer; padding: 4px 12px; border: 1px solid var(--bordo); border-radius: 8px; background: var(--superficie); font-size: 13px; color: var(--attenuato); }
.suite-compatta > summary::-webkit-details-marker { display: none; }
.suite-compatta > summary b { color: var(--testo); font-variant-numeric: tabular-nums; }
.suite-compatta .suite-nome { font-weight: 700; color: var(--testo); }
.suite-pillola { color: var(--testo); }
.suite-pillola.allarme { color: var(--rosso); font-weight: 700; }
.suite-compatta[open] > .suite { position: absolute; right: 16px; top: calc(100% + 6px); width: min(560px, 92vw); margin: 0; box-shadow: 0 6px 24px rgba(0, 0, 0, .25); }
.banner-quota { margin: 0 0 16px; padding: 12px 16px; width: 100%; box-sizing: border-box; border-radius: 8px; border: 1px solid var(--rispondi-testo); border-left-width: 6px; background: var(--rispondi-sfondo); color: var(--rispondi-testo); display: flex; flex-wrap: wrap; gap: 10px 20px; align-items: center; }
.banner-testo { flex: 1 1 320px; }
.quota-comandi { display: inline-flex; flex-wrap: wrap; gap: 8px; align-items: center; font-size: 13px; }
.quota-comandi input[type=number] { width: 4.5em; padding: 4px 6px; border-radius: 6px; border: 1px solid var(--bordo); background: var(--superficie); color: var(--testo); font: inherit; }
.quota-comandi button { padding: 5px 12px; border-radius: 8px; border: 1px solid var(--accento); background: var(--accento-sfondo); color: var(--accento); font: inherit; font-weight: 600; cursor: pointer; }
.quota-comandi button:disabled { opacity: 0.6; cursor: default; }
#giro-esito { margin-left: 10px; font-size: 13px; color: var(--attenuato); }
.num { color: var(--attenuato); font-weight: 600; margin-right: 4px; }
/* i link alle card: neri e in grassetto come il testo; al passaggio del mouse si evidenziano (blu, sottolineati) */
a.card, a.num { color: var(--testo); font-weight: 600; text-decoration: none; }
a.card:hover, a.num:hover { color: var(--accento); text-decoration: underline; text-underline-offset: 2px; }
a.card .num { color: inherit; }
.voce a.card { font-weight: 600; }
.riga-stato { margin: 4px 0 2px; font-size: 12.5px; color: var(--attenuato); }
.riga-stato .campo { font-weight: 600; }
.riga-stato .stato-board { white-space: normal; }
.nodo a.num { margin-right: 0; }
.chip { display: inline-block; margin: 0 6px 6px 0; padding: 1px 9px; border-radius: 10px; border: 1px solid var(--bordo); font-size: 12px; color: var(--attenuato); }
.meta { margin: 4px 0; font-size: 13px; color: var(--attenuato); overflow-wrap: anywhere; }
.meta b { color: var(--testo); font-weight: 600; }
.pallino { display: inline-block; width: 10px; height: 10px; margin-right: 6px; border-radius: 50%; background: var(--grigio); vertical-align: baseline; }
.pallino.viva { background: var(--verde); box-shadow: 0 0 0 3px color-mix(in srgb, var(--verde) 25%, transparent); }
.barra { height: 6px; margin: 8px 0 2px; border-radius: 3px; background: var(--bordo); overflow: hidden; }
.barra span { display: block; height: 100%; background: var(--verde); }
.etichetta-barra { font-size: 12px; color: var(--attenuato); }
pre.testo-lezione { margin: 6px 0 2px; padding: 8px 10px; border-radius: 6px; background: var(--codice-sfondo); color: var(--testo); font: 12px/1.5 ui-monospace, "Cascadia Mono", Consolas, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
details.lezione > summary, details.stabili > summary { cursor: pointer; }
details.stabili { margin: 0 0 12px; }
details.stabili > summary .conta { margin-left: 6px; }
pre.azioni { margin: 8px 0 0; padding: 8px 10px; border-radius: 6px; background: var(--codice-sfondo); color: var(--attenuato); font: 12px/1.5 ui-monospace, "Cascadia Mono", Consolas, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
.voce { background: var(--superficie); border: 1px solid var(--bordo); border-left: 4px solid var(--grigio); border-radius: 8px; padding: 7px 10px; margin: 6px 0; font-size: 14px; overflow-wrap: anywhere; }
.voce .azione { display: block; margin-top: 6px; }
.voce details.dettagli summary { cursor: pointer; font-size: 13px; color: var(--attenuato); list-style-position: inside; }
.voce details.dettagli summary .anteprima { display: inline-block; max-width: calc(100% - 22px); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; vertical-align: bottom; }
.voce details.dettagli[open] summary .anteprima { display: none; }
.voce details.dettagli[open] summary::after { content: "meno"; }
.voce.att-sblocca details.dettagli summary, .voce.att-rispondi details.dettagli summary, .voce.att-prova details.dettagli summary, .voce.att-rilascia details.dettagli summary { color: inherit; }
.voce .motivo { display: block; font-size: 13px; color: var(--attenuato); white-space: pre-line; }
.voce .stato { font-size: 12px; color: var(--attenuato); }
.aspetta { margin: 8px 0 2px; padding: 8px 10px; border: 1px solid var(--bordo); border-left: 4px solid var(--ambra); border-radius: 8px; background: var(--codice-sfondo); font-size: 14px; line-height: 1.35; }
.aspetta.persona { border-color: var(--sblocca-testo); background: var(--sblocca-sfondo); }
.aspetta ul { margin: 0; padding: 0; list-style: none; }
.aspetta li + li { margin-top: 8px; padding-top: 8px; border-top: 1px solid var(--bordo); }
.aspetta-testo { display: block; font-weight: 600; color: var(--testo); }
.aspetta-testo .num { font-weight: 700; }
.aspetta-stato { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin-top: 5px; }
.aspetta-stato .stato-board { white-space: normal; max-width: 100%; }
.aspetta-stato .campo { font-size: 12.5px; font-weight: 600; color: var(--attenuato); }
.stato-board { display: inline-block; padding: 1px 10px; border-radius: 10px; font-size: 12.5px; font-weight: 600; white-space: nowrap; }
.stato-board.analisi, .stato-board.altro { background: color-mix(in srgb, var(--grigio) 22%, transparent); color: var(--testo); }
.stato-board.sviluppo { background: var(--accento-sfondo); color: var(--accento); }
.stato-board.verifica { background: color-mix(in srgb, var(--ambra) 20%, transparent); color: var(--ambra); }
.stato-board.unione { background: color-mix(in srgb, var(--verde) 18%, transparent); color: var(--verde); }
.stato-board.rimossa { background: color-mix(in srgb, var(--rosso) 16%, transparent); color: var(--rosso); }
.aspetta .gesto { display: block; margin-top: 6px; font-weight: 700; color: var(--sblocca-testo); }
.aspetta .gesto::before { content: "\2192  "; }
.pipeline .voce { border-left-color: var(--bordo); font-size: 13px; overflow-wrap: break-word; hyphens: auto; }
.pipeline .voce .titolo { display: block; font-weight: 600; }
.etichetta { display: inline-block; margin: 0 6px 4px 0; padding: 1px 9px; border-radius: 10px; font-size: 12px; font-weight: 600; }
.fase { font-size: 12px; color: var(--attenuato); }
.pr { margin: 4px 0; font-size: 12px; color: var(--attenuato); }
.pr .pr-stato { font-weight: 600; }
.pr-verde .pr-stato { color: var(--verde); }
.pr-rossa .pr-stato { color: var(--rosso); }
.pr-inCorso .pr-stato, .pr-scaduta .pr-stato, .pr-conflitti .pr-stato { color: var(--ambra); }
.pr a { color: var(--accento); }
.att-sblocca { background: var(--sblocca-sfondo); color: var(--sblocca-testo); }
.att-rispondi { background: var(--rispondi-sfondo); color: var(--rispondi-testo); }
.att-prova { background: var(--prova-sfondo); color: var(--prova-testo); }
.att-rilascia { background: var(--rilascia-sfondo); color: var(--rilascia-testo); }
.voce.att-sblocca, .voce.att-rispondi, .voce.att-prova, .voce.att-rilascia { border-left-width: 4px; }
.voce.att-sblocca { border-left-color: var(--sblocca-testo); }
.voce.att-rispondi { border-left-color: var(--rispondi-testo); }
.voce.att-prova { border-left-color: var(--prova-testo); }
.voce.att-rilascia { border-left-color: var(--rilascia-testo); }
.voce.att-sblocca .motivo, .voce.att-rispondi .motivo, .voce.att-prova .motivo, .voce.att-rilascia .motivo, .voce.att-sblocca .fase, .voce.att-rispondi .fase, .voce.att-prova .fase, .voce.att-rilascia .fase { color: inherit; }
.voce.att-rispondi .motivo { margin-top: 4px; line-height: 1.45; }
.voce.att-rispondi .motivo b { display: inline-block; margin-top: 6px; }
.proposta { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .03em; opacity: .75; }
.funzionalita { margin: 0 0 18px; padding: 9px 14px; border: 1px solid var(--bordo); border-left: 5px solid var(--verde); border-radius: 10px; background: var(--superficie); }
.funzionalita > summary { cursor: pointer; list-style-position: inside; }
.funzionalita:not([open]) h2 { margin-bottom: 0; }
.funzionalita h2 { display: inline; margin: 0 0 10px; font-size: 15px; font-weight: 700; color: var(--testo); }
.funzionalita h2 .pillola { margin-left: 6px; background: color-mix(in srgb, var(--verde) 18%, transparent); color: var(--verde); }
.funzionalita h2 .nota { margin-left: 8px; font-size: 13px; font-weight: 400; color: var(--attenuato); }
.funzionalita-lista { display: grid; gap: 10px; margin-top: 10px; }
.funzionalita-voce[draggable=true] { cursor: grab; }
.funzionalita-voce.trascinata { opacity: 0.4; }
.funzionalita-voce.sopra { border-color: var(--accento); box-shadow: 0 0 0 2px var(--accento-sfondo); }
.funzionalita-voce.in-pausa { opacity: 0.6; }
.funzionalita-voce h3 { display: flex; align-items: center; gap: 8px; }
.funzionalita-voce .posizione { min-width: 1.4em; font-weight: 700; color: var(--attenuato); }
.funzionalita-voce .pausa-segno { font-size: 12px; font-weight: 700; color: var(--accento); }
.funzionalita-voce .vuota { font-size: 12.5px; color: var(--attenuato); }
button.pausa { margin-left: auto; padding: 2px 10px; border-radius: 8px; border: 1px solid var(--accento); background: var(--accento-sfondo); color: var(--accento); font: inherit; font-size: 13px; font-weight: 700; cursor: pointer; }
button.pausa:disabled, button#pausa-sistema:disabled { opacity: 0.6; cursor: default; }
.banner-pausa { margin: 8px 0; padding: 10px 14px; border-radius: 10px; border: 1px solid var(--accento); background: var(--accento-sfondo); font-weight: 600; }
.funzionalita-voce { padding: 10px 14px; background: var(--superficie); border: 1px solid var(--bordo); border-radius: 10px; font-size: 13px; }
.funzionalita-voce h3 { margin: 0 0 6px; font-size: 14px; }
.funzionalita-voce h3 .stato, .funzionalita-voce .campo { font-size: 12.5px; font-weight: 600; color: var(--attenuato); }
.funzionalita-voce .chiusura { margin-bottom: 6px; padding-bottom: 6px; border-bottom: 1px solid var(--bordo); }
.funzionalita-voce ul { margin: 0; padding: 0; list-style: none; display: grid; gap: 4px; }
.funzionalita-voce .dove { margin-left: 6px; font-size: 12px; color: var(--testo); }
details.catene { margin: 0 0 18px; padding: 9px 14px; border: 1px solid var(--bordo); border-left: 5px solid var(--accento); border-radius: 10px; background: var(--superficie); }
details.catene summary { cursor: pointer; font-size: 15px; font-weight: 700; color: var(--testo); }
details.catene summary .pillola { margin-left: 6px; background: var(--accento-sfondo); color: var(--accento); }
details.catene summary .nota { margin-left: 8px; font-size: 13px; font-weight: 400; color: var(--attenuato); }
details.catene[open] summary { margin-bottom: 10px; }
section.apprendimento { margin-top: 24px; }
section.apprendimento h2 { margin-top: 0; }
section.apprendimento h3 { margin: 16px 0 8px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.07em; color: var(--attenuato); }
section.apprendimento td.num { text-align: right; font-variant-numeric: tabular-nums; }
.catene-lista { display: grid; gap: 10px; }
.catena { display: flex; flex-wrap: wrap; align-items: stretch; gap: 6px; padding: 10px 14px; background: var(--superficie); border: 1px solid var(--bordo); border-radius: 10px; }
.catena .nodo { min-width: 130px; max-width: 220px; padding: 6px 10px; border-radius: 8px; border: 1px solid var(--bordo); border-left: 5px solid var(--grigio); background: var(--superficie); font-size: 13px; overflow-wrap: anywhere; }
.catena .nodo b { display: block; font-size: 13px; }
.catena .nodo .stato, .catena .nodo .dove { display: block; font-size: 12px; color: var(--attenuato); }
.catena .nodo .dove { color: var(--testo); }
.catena .nodo.stato-unita { border-left-color: var(--verde); }
.catena .nodo .spunta { color: var(--verde); font-weight: 700; }
.catena .nodo.stato-lavorazione { border-left-color: var(--ambra); }
.catena .nodo.stato-coda { border-left-color: var(--grigio); }
.catena .freccia { align-self: center; color: var(--attenuato); font-size: 18px; }
.legenda { list-style: none; margin: 12px 0 0; padding: 0; font-size: 12px; color: var(--attenuato); }
.legenda li { display: flex; align-items: baseline; gap: 8px; margin: 4px 0; }
.campione { flex: none; width: 14px; height: 14px; border-radius: 4px; border: 1px solid var(--bordo); transform: translateY(2px); }
.campione.att-sblocca { background: var(--sblocca-sfondo); border-color: var(--sblocca-testo); }
.campione.att-rispondi { background: var(--rispondi-sfondo); border-color: var(--rispondi-testo); }
.campione.att-prova { background: var(--prova-sfondo); border-color: var(--prova-testo); }
.campione.att-rilascia { background: var(--rilascia-sfondo); border-color: var(--rilascia-testo); }
.campione.stato-unita { background: var(--verde); border-color: var(--verde); }
.campione.stato-lavorazione { background: var(--ambra); border-color: var(--ambra); }
.campione.stato-coda { background: var(--superficie); border-color: var(--grigio); }
.build { margin-top: 0; }
.build h2 { margin-top: 0; }
.build-testa { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px 16px; margin: 0 0 12px; }
.build-testa h1 { margin: 0; }
a.build-pr { display: inline-block; padding: 6px 14px; border-radius: 8px; border: 1px solid var(--accento); background: var(--accento-sfondo); color: var(--accento); font-weight: 600; text-decoration: none; }
.orch { margin: 0 0 16px; padding: 10px 12px; border: 1px solid var(--accento); border-radius: 10px; background: var(--accento-sfondo); }
.orch h3 { margin: 0 0 6px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--accento); }
details.falliti { margin-top: 10px; }
details.falliti summary { cursor: pointer; font-size: 13px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--attenuato); }
.schede { display: flex; gap: 4px; margin: 0 0 18px; border-bottom: 1px solid var(--bordo); }
.schede button { padding: 8px 16px; border: 0; border-bottom: 3px solid transparent; background: none; color: var(--attenuato); font: inherit; font-weight: 600; cursor: pointer; }
.schede button[aria-selected="true"] { color: var(--accento); border-bottom-color: var(--accento); }
.schede .disposizione { display: flex; gap: 2px; margin-left: auto; align-self: center; padding: 2px; border: 1px solid var(--bordo); border-radius: 8px; }
.schede .disposizione button { padding: 3px 10px; border: 0; border-radius: 6px; font-size: 13px; font-weight: 600; }
.schede .disposizione button[aria-pressed="true"] { background: var(--accento); color: var(--superficie); }
.pannelli > [data-pannello] { min-width: 0; }
.pannelli[data-disposizione="affiancate"] { display: grid; grid-template-columns: minmax(0, var(--quota, 50%)) 16px minmax(0, 1fr); column-gap: 10px; align-items: start; }
.pannelli[data-disposizione="affiancate"] > [data-pannello] { overflow-x: auto; }
.pannelli[data-disposizione="affiancate"] [data-pannello="pipeline"] table { min-width: 760px; }
.pannelli[data-disposizione="colonna"] > [data-pannello="agenti"] { height: var(--alto, auto); overflow: auto; }
.divisore { display: none; position: relative; touch-action: none; }
.divisore::before { content: ""; position: absolute; background: var(--bordo); border-radius: 2px; }
.divisore::after { content: ""; position: absolute; border-radius: 4px; background: var(--attenuato); opacity: .55; }
.divisore:hover::before, .divisore:focus-visible::before, body.trascina .divisore::before { background: var(--accento); }
.divisore:focus-visible { outline: 2px solid var(--accento); outline-offset: 2px; }
.pannelli[data-disposizione="affiancate"] > .divisore { display: block; align-self: stretch; cursor: col-resize; }
.pannelli[data-disposizione="affiancate"] > .divisore::before { left: 7px; top: 0; bottom: 0; width: 2px; }
.pannelli[data-disposizione="affiancate"] > .divisore::after { left: 5px; top: 120px; width: 6px; height: 44px; }
.pannelli[data-disposizione="colonna"] > .divisore { display: block; height: 16px; margin: 14px 0; cursor: row-resize; }
.pannelli[data-disposizione="colonna"] > .divisore.secondo { display: none; }
.pannelli[data-disposizione="colonna"] > .divisore.terzo { display: none; }
.pannelli[data-disposizione="colonna"] > .divisore::before { top: 7px; left: 0; right: 0; height: 2px; }
.pannelli[data-disposizione="colonna"] > .divisore::after { top: 5px; left: calc(50% - 22px); width: 44px; height: 6px; }
body.trascina { user-select: none; }
@media (max-width: 1200px) { .pannelli[data-disposizione="affiancate"] { display: block; } .pannelli[data-disposizione="affiancate"] > .divisore { display: none; } .pannelli[data-disposizione="affiancate"] > [data-pannello="pipeline"], .pannelli[data-disposizione="affiancate"] > [data-pannello="apprendimento"] { margin-top: 28px; padding-top: 18px; border-top: 2px solid var(--bordo); } }
.schede .conta { display: inline-block; min-width: 20px; margin-left: 6px; padding: 0 6px; border-radius: 10px; background: var(--bordo); color: var(--testo); font-size: 12px; text-align: center; }
.schede .conta.allarme { background: var(--rosso); color: #fff; }
.schede .conta.attenzione { background: var(--ambra); color: #fff; }
.build-riepilogo { display: flex; flex-wrap: wrap; gap: 10px; margin: 0 0 16px; }
.build-riepilogo .dato { min-width: 120px; padding: 8px 14px; border-radius: 10px; border: 1px solid var(--bordo); background: var(--superficie); font-size: 12px; text-transform: uppercase; letter-spacing: .05em; color: var(--attenuato); }
.build-riepilogo .dato b { display: block; font-size: 26px; line-height: 1.15; letter-spacing: 0; color: var(--testo); font-variant-numeric: tabular-nums; }
.build-riepilogo .dato.attesa b { color: var(--ambra); }
.build-riepilogo .dato.fallito b { color: var(--rosso); }
.build h3 { margin: 22px 0 8px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.07em; color: var(--attenuato); }
.tabella { overflow-x: auto; border: 1px solid var(--bordo); border-radius: 10px; background: var(--superficie); }
table.build-tab { width: 100%; border-collapse: collapse; font-size: 14px; }
table.build-tab th { padding: 8px 12px; text-align: left; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; color: var(--attenuato); border-bottom: 1px solid var(--bordo); white-space: nowrap; }
table.build-tab td { padding: 8px 12px; border-bottom: 1px solid var(--bordo); vertical-align: top; }
table.build-tab tr:last-child td { border-bottom: 0; }
table.build-tab tbody tr[data-url] { cursor: pointer; }
table.build-tab tbody tr:hover { background: color-mix(in srgb, var(--accento-sfondo) 50%, transparent); }
table.build-tab td.prog, table.build-tab td.chi, table.build-tab td.dove { color: var(--attenuato); }
table.build-tab td.chi { white-space: nowrap; }
table.build-tab td.dove { white-space: nowrap; }
table.build-tab td.nome { font-weight: 600; overflow-wrap: anywhere; }
table.build-tab td.ramo { font: 13px ui-monospace, "Cascadia Mono", Consolas, monospace; white-space: nowrap; }
table.build-tab td.azione { text-align: right; white-space: nowrap; }
table.build-tab td.azione a { color: var(--accento); font-weight: 600; text-decoration: none; }
table.build-tab td.azione a:hover { text-decoration: underline; }
.pillola { display: inline-block; padding: 1px 10px; border-radius: 10px; font-size: 12px; font-weight: 600; white-space: nowrap; background: var(--codice-sfondo); color: var(--attenuato); }
.pillola.inCorso { background: var(--accento-sfondo); color: var(--accento); }
.pillola.inCorso::before { content: ''; display: inline-block; width: 7px; height: 7px; margin-right: 5px; border-radius: 50%; background: currentColor; vertical-align: 1px; animation: vista-pulsa 1.6s ease-in-out infinite; }
@keyframes vista-pulsa { 50% { opacity: .25; } }
@media (prefers-reduced-motion: reduce) { .pillola.inCorso::before { animation: none; } }
.pillola.inCoda { background: var(--codice-sfondo); color: var(--testo); border: 1px dashed var(--grigio); }
.pillola.inAttesa { background: var(--prova-sfondo); color: var(--prova-testo); font-weight: 700; }
.pillola.rosso { background: color-mix(in srgb, var(--rosso) 16%, transparent); color: var(--rosso); }
.pillola.verde { background: color-mix(in srgb, var(--verde) 18%, transparent); color: var(--verde); }
.pillola.ambra { background: color-mix(in srgb, var(--ambra) 20%, transparent); color: var(--ambra); }
tr.in-attesa td { background: color-mix(in srgb, var(--prova-sfondo) 55%, transparent); }
.agente { display: inline-block; padding: 1px 9px; border-radius: 10px; border: 1px solid var(--bordo); font-size: 12px; font-weight: 600; white-space: nowrap; color: var(--attenuato); }
.agente.cloud { color: var(--accento); border-color: var(--accento); background: var(--accento-sfondo); }
.agente.interno { color: var(--rilascia-testo); border-color: var(--rilascia-testo); background: var(--rilascia-sfondo); }
.agente.misto { color: var(--rispondi-testo); border-color: var(--rispondi-testo); background: var(--rispondi-sfondo); }
.agente.stimato { border-style: dashed; opacity: .8; }
.tipo { display: inline-block; padding: 0 8px; border-radius: 8px; font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; white-space: nowrap; background: var(--codice-sfondo); color: var(--attenuato); }
.tipo.rilascio { background: var(--accento-sfondo); color: var(--accento); }
.tipo.pr { background: var(--rispondi-sfondo); color: var(--rispondi-testo); }
.tipo.ci { background: var(--rilascia-sfondo); color: var(--rilascia-testo); }
table.build-tab td.numero { font: 12px ui-monospace, "Cascadia Mono", Consolas, monospace; color: var(--attenuato); white-space: nowrap; }
table.build-tab td.numero .build-id { display: block; font-size: 13px; color: var(--testo); }
table.build-tab td.numero .versione { display: block; font-size: 11px; }
.comp { display: inline-block; margin: 0 4px 3px 0; padding: 1px 8px; border-radius: 10px; background: var(--codice-sfondo); color: var(--testo); font-size: 12px; }
.agenti-pool { margin: 0 0 16px; }
.agenti-pool h3 { margin: 0 0 8px; }
.pool-lista { display: flex; flex-wrap: wrap; gap: 10px; }
.pool { min-width: 260px; padding: 8px 12px; border: 1px solid var(--bordo); border-radius: 10px; background: var(--superficie); }
.pool h4 { margin: 0 0 8px; padding-bottom: 6px; border-bottom: 1px solid var(--bordo); font-size: 14px; }
.pool ul { padding-left: 4px !important; }
.etichetta-tipo { display: inline-block; min-width: 46px; padding: 0 6px; border-radius: 6px; font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: .05em; text-align: center; vertical-align: 1px; }
.etichetta-tipo.pool { background: var(--testo); color: var(--superficie); }
.etichetta-tipo.agente { background: var(--codice-sfondo); color: var(--attenuato); border: 1px solid var(--bordo); }
.pool ul { list-style: none; margin: 0; padding: 0; font-size: 13px; }
.pool li { margin: 4px 0; }
.pool li a { color: var(--accento); }
.filtri { display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 16px; }
.filtri button { padding: 4px 12px; border-radius: 16px; border: 1px solid var(--bordo); background: var(--superficie); color: var(--testo); font: inherit; font-size: 13px; cursor: pointer; }
.filtri button[aria-pressed="true"] { border-color: var(--accento); background: var(--accento-sfondo); color: var(--accento); font-weight: 600; }
.filtri .conta { display: inline-block; min-width: 18px; margin-left: 6px; padding: 0 5px; border-radius: 9px; background: var(--bordo); color: var(--testo); font-size: 11px; text-align: center; }
.da-approvare { margin: 0 0 18px; padding: 10px 12px 12px; border: 1px solid var(--prova-testo); border-left-width: 5px; border-radius: 10px; background: var(--prova-sfondo); }
.da-approvare h3 { margin: 0 0 8px; color: var(--prova-testo); }
.da-approvare .tabella { background: var(--superficie); }
.da-approvare td.azione a { color: var(--prova-testo); }
details.gruppo > summary { list-style: none; cursor: pointer; }
details.gruppo > summary::-webkit-details-marker { display: none; }
details.gruppo > summary h3::before { content: '\25BE'; display: inline-block; width: 14px; }
details.gruppo:not([open]) > summary h3::before { content: '\25B8'; }
details.progetto { margin: 0 0 18px; }
details.progetto > summary { list-style: none; cursor: pointer; }
details.progetto > summary::-webkit-details-marker { display: none; }
details.progetto > summary h3::before { content: '\25BE'; display: inline-block; width: 14px; color: var(--attenuato); }
details.progetto:not([open]) > summary h3::before { content: '\25B8'; }
details.progetto h3 { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 8px; margin: 20px 0 8px; font-size: 15px; text-transform: none; letter-spacing: 0; color: var(--testo); }
details.progetto details.falliti { margin-top: 8px; }
details.progetto details.falliti .tabella { margin-top: 6px; }
.tag-rilascio { display: inline-block; margin-left: 4px; padding: 0 7px; border-radius: 8px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .04em; background: var(--accento-sfondo); color: var(--accento); }
.fase-run { white-space: nowrap; }
@media (max-width: 480px) { main { padding: 14px 10px 32px; } h1 { font-size: 24px; } }
'@

# I due pulsanti, solo con il server. "Avvia smistatore": POST /giro col codice di sessione (attributo data-token) nell'header
# X-Vista-Token. "Aggiorna agenti e card": POST /aggiorna, poi aspetta che il server ridisegni la pagina (cambia data-generata
# di <main>) e la ricarica; nel frattempo il contatore non ricarica. Le risposte si scrivono con textContent, mai come HTML.
# Il messaggio si ricorda in sessionStorage per sopravvivere al ricaricamento (ogni accesso in try/catch: senza storage funziona
# uguale, il messaggio dura fino al ricaricamento).
$script:ScriptGiro = @'
<script>
(function () {
  // tre pulsanti: "Avvia smistatore" (POST /giro), "Aggiorna agenti e card" (POST /aggiorna) e "Aggiorna pipeline" (POST /aggiorna-pipeline).
  // L'esito di ognuno si scrive (con textContent) nello span .esito-ado accanto al pulsante e si ritrova dopo il ricaricamento.
  var esito = function (p) { return p.parentNode.querySelector('.esito-ado'); };
  var dire = function (p, t, ricorda) {
    var e = esito(p); if (e) { e.textContent = t; }
    if (ricorda) { try { sessionStorage.setItem('esito:' + p.id, t); } catch (x) {} }
  };
  ['giro', 'aggiorna', 'aggiorna-pipeline', 'quota-applica', 'quota-applica-5', 'quota-ignora', 'quota-ripristina', 'suite-aggiorna', 'suite-automatico', 'funzionalita-esito', 'pausa-sistema'].forEach(function (id) {
    var p = document.getElementById(id); if (!p) return;
    try { var m = sessionStorage.getItem('esito:' + id); if (m) { dire(p, m); sessionStorage.removeItem('esito:' + id); } } catch (x) {}
  });
  var b = document.getElementById('giro');
  if (b) b.addEventListener('click', function () {
    var intestazioni = {};
    intestazioni['X-Vista-Token'] = b.dataset.token;
    b.disabled = true; dire(b, 'avvio in corso...');
    fetch('/giro', { method: 'POST', headers: intestazioni })
      .then(function (r) { return r.json(); })
      .then(function (j) { dire(b, j.messaggio, true); })
      .catch(function (x) { dire(b, 'errore: ' + x, true); })
      .then(function () { b.disabled = false; });
  });
  // una rilettura chiesta: POST, poi si aspetta che il server ridisegni la pagina (cambia data-generata di <main>) e si ricarica;
  // nel frattempo il contatore non ricarica
  var rileggi = function (p, indirizzo, fatto, inCorso, alErrore) {
    var intestazioni = {};
    intestazioni['X-Vista-Token'] = p.dataset.token;
    var prima = document.querySelector('main').getAttribute('data-generata');
    var finito = function () { p.disabled = false; window.vistaAttesaAggiorna = false; };
    var fallito = function () { finito(); if (alErrore) alErrore(); };
    p.disabled = true; window.vistaAttesaAggiorna = true; dire(p, inCorso || 'rilettura in corso...');
    // D60: la vista serve le richieste fra un disegno e l'altro; mentre rilegge Azure DevOps una richiesta puo cadere per strada
    // (Failed to fetch). Allora si riprova, fino a 5 volte a 10 secondi: i comandi sono idempotenti, rifarli non cambia l'esito.
    var invia = function (tentativo) {
      return fetch(indirizzo, { method: 'POST', headers: intestazioni }).catch(function (x) {
        if (tentativo >= 5) throw x;
        dire(p, 'la vista e occupata a rileggere, riprovo...');
        return new Promise(function (ok) { setTimeout(ok, 10000); }).then(function () { return invia(tentativo + 1); });
      });
    };
    invia(1)
      .then(function (r) { return r.json(); })
      .then(function (j) {
        dire(p, j.messaggio);
        if (j.esito !== 'accodato') { fallito(); return; }
        var tentativi = 0;
        var guarda = function () {
          fetch('/vista.html', { cache: 'no-store' })
            .then(function (r) { return r.text(); })
            .then(function (t) {
              var g = /data-generata="([^"]*)"/.exec(t);
              if ((g && g[1] !== prima) || ++tentativi > 120) { dire(p, fatto, true); location.reload(); }
              else { setTimeout(guarda, 1000); }
            })
            .catch(function () { setTimeout(guarda, 1000); });
        };
        setTimeout(guarda, 1000);
      })
      .catch(function (x) { dire(p, 'errore: ' + x, true); fallito(); });
  };
  var a = document.getElementById('aggiorna'), ap = document.getElementById('aggiorna-pipeline');
  if (a) a.addEventListener('click', function () { rileggi(a, '/aggiorna', 'agenti e card riletti'); });
  if (ap) ap.addEventListener('click', function () { rileggi(ap, '/aggiorna-pipeline', 'pipeline rilette'); });
  // la quota (D51): POST /soglia, che scrive l'override e fa ridisegnare la pagina come /aggiorna. La soglia va in frazione (max 0.95).
  var qa = document.getElementById('quota-applica'), qi = document.getElementById('quota-ignora'), qr = document.getElementById('quota-ripristina');
  if (qa) qa.addEventListener('click', function () {
    var campo = document.getElementById('quota-soglia'), min = parseFloat(campo.min), max = parseFloat(campo.max);
    var v = parseFloat(String(campo.value).replace(',', '.'));
    if (!(v >= min && v <= max)) { dire(qa, 'la soglia deve stare fra ' + min + ' e ' + max); return; }
    rileggi(qa, '/soglia?soglia=' + encodeURIComponent((v / 100).toFixed(4)), 'soglia aggiornata');
  });
  // D60: la soglia delle 5 ore, come la settimanale ma fino al reset della finestra
  var q5 = document.getElementById('quota-applica-5');
  if (q5) q5.addEventListener('click', function () {
    var campo = document.getElementById('quota-soglia-5'), min = parseFloat(campo.min), max = parseFloat(campo.max);
    var v = parseFloat(String(campo.value).replace(',', '.'));
    if (!(v >= min && v <= max)) { dire(q5, 'la soglia deve stare fra ' + min + ' e ' + max); return; }
    rileggi(q5, '/soglia?soglia5Ore=' + encodeURIComponent((v / 100).toFixed(4)), 'soglia delle 5 ore aggiornata');
  });
  // D60: le funzionalita in ordine di priorita. Si trascina una scheda (POST /ordine?id=&dopo=, dopo = la Feature sopra, 0 = in cima) e il
  // pulsante della scheda mette o toglie la pausa (POST /pausa?id=&attiva=). Mentre una richiesta e in corso non se ne parte un'altra; se
  // fallisce la pagina si ricarica, cosi non resta un ordine che non e stato salvato.
  var lista = document.querySelector('.funzionalita-lista'), pe = document.getElementById('funzionalita-esito');
  if (lista && pe) {
    var trascinata = null, occupata = false;
    var ricarica = function () { location.reload(); };
    var chiedi = function (indirizzo, fatto, inCorso) {
      if (occupata) return;
      occupata = true;
      Array.prototype.forEach.call(lista.querySelectorAll('button.pausa'), function (b) { b.disabled = true; });
      rileggi(pe, indirizzo, fatto, inCorso, ricarica);
    };
    Array.prototype.forEach.call(lista.querySelectorAll('.funzionalita-voce[draggable=true]'), function (v) {
      v.addEventListener('dragstart', function (e) { if (occupata) { e.preventDefault(); return; } trascinata = v; v.classList.add('trascinata'); try { e.dataTransfer.setData('text/plain', v.dataset.feature); } catch (x) {} });
      v.addEventListener('dragend', function () { v.classList.remove('trascinata'); Array.prototype.forEach.call(lista.children, function (x) { x.classList.remove('sopra'); }); });
      v.addEventListener('dragover', function (e) { if (!trascinata || trascinata === v) return; e.preventDefault(); v.classList.add('sopra'); });
      v.addEventListener('dragleave', function () { v.classList.remove('sopra'); });
      v.addEventListener('drop', function (e) {
        e.preventDefault(); v.classList.remove('sopra');
        if (!trascinata || trascinata === v) return;
        var schede = Array.prototype.slice.call(lista.children);
        var sotto = schede.indexOf(trascinata) < schede.indexOf(v);
        lista.insertBefore(trascinata, sotto ? v.nextSibling : v);
        var prima = trascinata.previousElementSibling;
        chiedi('/ordine?id=' + encodeURIComponent(trascinata.dataset.feature) + '&dopo=' + (prima ? encodeURIComponent(prima.dataset.feature) : '0'), 'priorita salvata', 'salvo la priorita...');
      });
    });
    Array.prototype.forEach.call(lista.querySelectorAll('button.pausa'), function (bt) {
      bt.addEventListener('click', function (e) {
        e.stopPropagation();
        var attiva = bt.dataset.pausa === '1' ? '0' : '1';
        chiedi('/pausa?id=' + encodeURIComponent(bt.dataset.id) + '&attiva=' + attiva, attiva === '1' ? 'Feature ' + bt.dataset.id + ' in pausa' : 'Feature ' + bt.dataset.id + ' ripartita', 'scrivo su Azure DevOps...');
      });
    });
  }
  // D60: la pausa di tutto il sistema (POST /pausa-sistema?attivo=0|1)
  var ps = document.getElementById('pausa-sistema');
  if (ps) ps.addEventListener('click', function () {
    var attivo = ps.dataset.pausa === '1' ? '0' : '1';
    rileggi(ps, '/pausa-sistema?attivo=' + attivo, attivo === '1' ? 'sistema in pausa' : 'sistema ripartito');
  });
  if (qi) qi.addEventListener('change', function () { rileggi(qi, '/soglia?ignoraRiserva=' + (qi.checked ? '1' : '0'), qi.checked ? 'riserva ignorata fino al reset' : 'riserva di nuovo attiva', null, function () { qi.checked = !qi.checked; }); });
  if (qr) qr.addEventListener('click', function () { rileggi(qr, '/soglia?ripristina=1', 'soglia ripristinata'); });
  // la suite (D53): "Aggiorna adesso" scrive la richiesta e avvia il supervisore (POST /aggiorna-suite; l'esito arriva col suo giro, la pagina non
  // aspetta); "Aggiornamento automatico" scrive l'impostazione (POST /automatico?attivo=0|1) e ridisegna come /aggiorna
  var sa = document.getElementById('suite-aggiorna'), sx = document.getElementById('suite-automatico');
  if (sa) sa.addEventListener('click', function () {
    var intestazioni = {};
    intestazioni['X-Vista-Token'] = sa.dataset.token;
    sa.disabled = true; dire(sa, 'richiesta in corso...');
    fetch('/aggiorna-suite', { method: 'POST', headers: intestazioni })
      .then(function (r) { return r.json(); })
      .then(function (j) { dire(sa, j.messaggio, true); })
      .catch(function (x) { dire(sa, 'errore: ' + x, true); })
      .then(function () { sa.disabled = false; });
  });
  if (sx) sx.addEventListener('change', function () { rileggi(sx, '/automatico?attivo=' + (sx.checked ? '1' : '0'), sx.checked ? 'aggiornamento automatico acceso' : 'aggiornamento automatico spento', null, function () { sx.checked = !sx.checked; }); });
  // "Togli on-hold" (D37) sulle card in on-hold: conferma, POST /togli-attesa?id=<card>, poi la stessa rilettura di "Aggiorna agenti e card".
  // Dopo il ricaricamento la card non e piu in on-hold e il suo pulsante non c'e piu: l'esito si ritrova accanto a "Avvia smistatore".
  var gi = document.getElementById('giro');
  try {
    for (var i = 0; i < sessionStorage.length; i++) {
      var k = sessionStorage.key(i);
      if (k && k.indexOf('esito:togli-attesa-') === 0 && gi) { dire(gi, sessionStorage.getItem(k)); sessionStorage.removeItem(k); break; }
    }
  } catch (x) {}
  Array.prototype.forEach.call(document.querySelectorAll('.togli-attesa'), function (t) {
    t.addEventListener('click', function () {
      var n = t.dataset.id;
      if (!window.confirm('Togliere il tag on-hold dalla card ' + n + '? Il seguito lo decide lo smistatore al prossimo giro.')) return;
      rileggi(t, '/togli-attesa?id=' + encodeURIComponent(t.dataset.id), 'card ' + n + ': on-hold tolto', 'tolgo il tag on-hold...');
    });
  });
})();
</script>
'@

# Le schede: un clic mostra un pannello e nasconde l'altro; la scelta resta in sessionStorage (la pagina si ricarica da sola).
# La disposizione (schede, affiancate, in colonna) resta in localStorage: e una preferenza, vale anche alla prossima apertura.
$script:ScriptSchede = @'
<script>
(function () {
  var bottoni = document.querySelectorAll('.schede [data-scheda]');
  var pannelli = document.querySelector('.pannelli');
  var disposizione = 'schede';
  // Con le schede ne vale una alla volta. Affiancate o in colonna le schede sono interruttori: aria-selected dice quale pannello si vede,
  // un clic lo nasconde o lo fa tornare (i nascosti restano in localStorage, come la disposizione).
  var nascosti = [];
  try { nascosti = JSON.parse(localStorage.getItem('nascosti') || '[]'); } catch (e) {}
  if (!Array.isArray(nascosti)) { nascosti = []; }
  // un pannello agganciato fuori dalle schede (l'Ufficio sopra o sotto: data-fuori) non e una scheda: niente colonna, niente pulsante
  var fuori = function (n) { var p = document.querySelector('[data-pannello="' + n + '"]'); return !!(p && p.hasAttribute('data-fuori')); };
  var nomi = function () { var l = []; bottoni.forEach(function (b) { if (!fuori(b.dataset.scheda)) { l.push(b.dataset.scheda); } }); return l; };
  var divAgenti = document.querySelector('.divisore[data-divisore="agenti"]'), divPipeline = document.querySelector('.divisore[data-divisore="pipeline"]');
  var divUfficio = document.querySelector('.divisore[data-divisore="ufficio"]');
  // le colonne della griglia seguono i pannelli visibili. Il primo divisore sta fra Agenti e il pannello che segue (c'e se Agenti e almeno
  // un altro sono visibili); il secondo fra Pipeline e Apprendimento (c'e se sono visibili tutti e due). La larghezza di Agenti e quella di
  // Pipeline (quando Apprendimento le sta accanto) sono le misure dei divisori; il resto e di Apprendimento.
  var colonne = function () {
    if (!pannelli) return;
    var vis = nomi().filter(function (n) { return nascosti.indexOf(n) < 0; });
    var d1 = vis[0] === 'agenti' && vis.length > 1;
    var d2 = vis.indexOf('pipeline') >= 0 && vis.indexOf('apprendimento') >= 0;
    // il terzo, fra l'Ufficio e il pannello visibile prima di lui, se quello non e Agenti (fra Agenti e il seguente c'e gia il primo)
    var iu = vis.indexOf('ufficio'), d3 = iu > 0 && vis[iu - 1] !== 'agenti';
    var t = [];
    vis.forEach(function (n) {
      if (n === 'agenti') { t.push(d1 ? 'minmax(0, var(--quota, 50%))' : 'minmax(0, 1fr)'); if (d1) { t.push('16px'); } }
      else if (n === 'pipeline') { t.push(d2 ? 'minmax(0, var(--quota-pipeline, 1fr))' : 'minmax(0, 1fr)'); if (d2) { t.push('16px'); } }
      else if (n === 'ufficio' && d3) { t.push('16px'); t.push('minmax(0, var(--quota-ufficio, 1fr))'); }
      else { t.push('minmax(0, 1fr)'); }
    });
    pannelli.style.gridTemplateColumns = disposizione === 'affiancate' ? t.join(' ') : '';
    if (divAgenti) { divAgenti.style.display = d1 || disposizione === 'schede' ? '' : 'none'; }
    if (divPipeline) { divPipeline.style.display = d2 || disposizione === 'schede' ? '' : 'none'; }
    if (divUfficio) { divUfficio.style.display = d3 || disposizione === 'schede' ? '' : 'none'; }
  };
  var mostra = function (nome) {
    var insieme = disposizione !== 'schede';
    bottoni.forEach(function (b) { if (fuori(b.dataset.scheda)) { return; } b.setAttribute('aria-selected', (insieme ? nascosti.indexOf(b.dataset.scheda) < 0 : b.dataset.scheda === nome) ? 'true' : 'false'); });
    document.querySelectorAll('[data-pannello]').forEach(function (p) { if (p.hasAttribute('data-fuori')) { return; } p.hidden = insieme ? nascosti.indexOf(p.dataset.pannello) >= 0 : p.dataset.pannello !== nome; });
    colonne();
  };
  var scelta = 'agenti';
  try { scelta = sessionStorage.getItem('scheda') || 'agenti'; } catch (e) {}
  if (location.hash === '#pipeline' || location.hash === '#agenti' || location.hash === '#apprendimento' || location.hash === '#ufficio') { scelta = location.hash.substring(1); }
  // un valore ricordato che non e una scheda (vecchio o sbagliato) ricade su agenti
  if (nomi().indexOf(scelta) < 0) { scelta = 'agenti'; }
  // la disposizione: schede (una alla volta), affiancate o in colonna (tutte e due); resta in localStorage
  var scelte = document.querySelectorAll('.disposizione [data-disposizione]');
  var disponi = function (d) {
    disposizione = d; if (pannelli) { pannelli.dataset.disposizione = d; }
    scelte.forEach(function (b) { b.setAttribute('aria-pressed', b.dataset.disposizione === d ? 'true' : 'false'); });
    mostra(scelta);
  };
  try { var dd = localStorage.getItem('disposizione'); if (dd === 'affiancate' || dd === 'colonna') { disposizione = dd; } } catch (e) {}
  scelte.forEach(function (b) { b.addEventListener('click', function () { disponi(b.dataset.disposizione); try { localStorage.setItem('disposizione', b.dataset.disposizione); } catch (e) {} }); });
  disponi(disposizione);
  // chi aggancia o sgancia l'Ufficio (VistaUfficioPannello) chiede di ridisporre: una scheda uscita dalle schede non puo restare la scelta
  window.vistaRidisponi = function () { if (nomi().indexOf(scelta) < 0) { scelta = 'agenti'; } mostra(scelta); };
  // il divisore fra i due pannelli: trascinato allarga o stringe (affiancate: la quota a sinistra; in colonna: l'altezza degli
  // Agenti), con le frecce va a scatti, doppio clic torna com'era. Le misure restano in localStorage, una per disposizione.
  var leggiMisura = function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } };
  var salvaMisura = function (k, v) { try { if (v === null) { localStorage.removeItem(k); } else { localStorage.setItem(k, v); } } catch (e) {} };
  var applicaMisure = function () {
    var q = parseFloat(leggiMisura('quota-affiancate')); pannelli.style.setProperty('--quota', (q >= 15 && q <= 85 ? q : 50) + '%');
    var q2 = parseFloat(leggiMisura('quota-pipeline')); if (q2 >= 10 && q2 <= 60) { pannelli.style.setProperty('--quota-pipeline', q2 + '%'); } else { pannelli.style.removeProperty('--quota-pipeline'); }
    var q3 = parseFloat(leggiMisura('quota-ufficio')); if (q3 >= 15 && q3 <= 70) { pannelli.style.setProperty('--quota-ufficio', q3 + '%'); } else { pannelli.style.removeProperty('--quota-ufficio'); }
    var a = parseInt(leggiMisura('alto-colonna'), 10); if (a >= 120) { pannelli.style.setProperty('--alto', a + 'px'); } else { pannelli.style.removeProperty('--alto'); }
  };
  var misura = function (x, y, quale) {
    if (quale === 'ufficio') {
      // la larghezza dell'Ufficio, in % della griglia: dalla posizione del divisore al bordo destro
      var ru = pannelli.getBoundingClientRect();
      salvaMisura('quota-ufficio', Math.min(70, Math.max(15, (ru.right - x) / ru.width * 100)).toFixed(1));
    } else if (quale === 'pipeline') {
      // la larghezza di Pipeline, in % della griglia: dal suo bordo sinistro alla posizione del divisore
      var rp = pannelli.getBoundingClientRect(), sx = pannelli.querySelector('[data-pannello="pipeline"]').getBoundingClientRect().left;
      salvaMisura('quota-pipeline', Math.min(60, Math.max(10, (x - sx) / rp.width * 100)).toFixed(1));
    } else if (disposizione === 'affiancate') {
      var r = pannelli.getBoundingClientRect();
      salvaMisura('quota-affiancate', Math.min(85, Math.max(15, (x - r.left) / r.width * 100)).toFixed(1));
    } else if (disposizione === 'colonna') {
      var su = pannelli.querySelector('[data-pannello="agenti"]').getBoundingClientRect().top;
      salvaMisura('alto-colonna', String(Math.round(Math.max(120, y - su))));
    }
    applicaMisure();
  };
  var collega = function (divisore) {
    var quale = divisore.dataset.divisore;
    var chiave = function () { return quale === 'ufficio' ? 'quota-ufficio' : (quale === 'pipeline' ? 'quota-pipeline' : (disposizione === 'affiancate' ? 'quota-affiancate' : 'alto-colonna')); };
    divisore.addEventListener('pointerdown', function (ev) {
      ev.preventDefault(); divisore.setPointerCapture(ev.pointerId); document.body.classList.add('trascina');
      var muovi = function (e) { misura(e.clientX, e.clientY, quale); };
      var fine = function () {
        document.body.classList.remove('trascina');
        divisore.removeEventListener('pointermove', muovi); divisore.removeEventListener('pointerup', fine); divisore.removeEventListener('pointercancel', fine);
      };
      divisore.addEventListener('pointermove', muovi); divisore.addEventListener('pointerup', fine); divisore.addEventListener('pointercancel', fine);
    });
    divisore.addEventListener('dblclick', function () { salvaMisura(chiave(), null); applicaMisure(); });
    divisore.addEventListener('keydown', function (ev) {
      var passo = { ArrowLeft: -1, ArrowUp: -1, ArrowRight: 1, ArrowDown: 1 }[ev.key]; if (!passo) return;
      ev.preventDefault();
      var r = divisore.getBoundingClientRect();
      if (disposizione === 'affiancate') { misura(r.left + r.width / 2 + passo * pannelli.clientWidth * 0.05, 0, quale); }
      else { misura(0, r.top - 14 + passo * 60, quale); }
    });
  };
  if (pannelli) {
    applicaMisure();
    document.querySelectorAll('.divisore').forEach(collega);
  }
  // un clic su una riga di run (non sul suo link) apre il run in una scheda nuova, come il link
  document.addEventListener('click', function (ev) {
    var tr = ev.target.closest('tr[data-url]');
    if (!tr || ev.target.closest('a')) return;
    var w = window.open(tr.dataset.url, '_blank', 'noopener');
    if (w) { w.opener = null; }
  });
  // i filtri per stato, a scelta multipla: ogni pulsante si accende e si spegne, "Tutti" li azzera. Si vedono le righe degli
  // stati scelti, e i blocchi e le tabelle che ne hanno almeno una. La scelta resta in sessionStorage (stati separati da virgola).
  var filtri = document.querySelectorAll('.filtri [data-filtro]');
  var scelti = [];
  var applica = function () {
    var tutti = scelti.length === 0;
    var vede = function (st) { return tutti || scelti.indexOf(st) >= 0; };
    filtri.forEach(function (x) { var f = x.dataset.filtro; x.setAttribute('aria-pressed', (f === 'tutti' ? tutti : scelti.indexOf(f) >= 0) ? 'true' : 'false'); });
    document.querySelectorAll('tr[data-stato]').forEach(function (tr) { tr.hidden = !vede(tr.dataset.stato); });
    document.querySelectorAll('.tabella, details.falliti, details.progetto, .da-approvare').forEach(function (b) {
      b.hidden = !tutti && !Array.prototype.some.call(b.querySelectorAll('tr[data-stato]'), function (tr) { return vede(tr.dataset.stato); });
    });
    if (scelti.indexOf('fallito') >= 0) { document.querySelectorAll('details.falliti').forEach(function (d) { d.open = true; }); }
    try { sessionStorage.setItem('filtro-pipeline', scelti.join(',')); } catch (e) {}
  };
  try { var m = sessionStorage.getItem('filtro-pipeline'); if (m && m !== 'tutti') { scelti = m.split(',').filter(function (x) { return x; }); } } catch (e) {}
  if (filtri.length) { applica(); }
  filtri.forEach(function (x) { x.addEventListener('click', function () {
    var f = x.dataset.filtro;
    if (f === 'tutti') { scelti = []; } else { var i = scelti.indexOf(f); if (i >= 0) { scelti.splice(i, 1); } else { scelti.push(f); } }
    applica();
  }); });
  // i progetti chiusi restano chiusi dopo il ricaricamento
  document.querySelectorAll('details.progetto').forEach(function (d) {
    var k = 'progetto-chiuso:' + d.dataset.progetto;
    try { if (sessionStorage.getItem(k) === '1') { d.open = false; } } catch (e) {}
    d.addEventListener('toggle', function () { try { sessionStorage.setItem(k, d.open ? '0' : '1'); } catch (e) {} });
  });
  // le lezioni aperte restano aperte dopo il ricaricamento (e le sezioni delle stabili, aperte o chiuse, come le ha lasciate chi legge)
  document.querySelectorAll('details[data-ricorda]').forEach(function (d) {
    var k = 'aperto:' + d.dataset.ricorda;
    try { var v = sessionStorage.getItem(k); if (v === '1') { d.open = true; } else if (v === '0') { d.open = false; } } catch (e) {}
    d.addEventListener('toggle', function () { try { sessionStorage.setItem(k, d.open ? '1' : '0'); } catch (e) {} });
  });
  bottoni.forEach(function (b) { b.addEventListener('click', function () {
    if (fuori(b.dataset.scheda)) { return; }   // l'Ufficio agganciato lo mostra o nasconde il suo script
    if (disposizione !== 'schede') {
      var i = nascosti.indexOf(b.dataset.scheda);
      if (i >= 0) { nascosti.splice(i, 1); } else { nascosti.push(b.dataset.scheda); }
      try { localStorage.setItem('nascosti', JSON.stringify(nascosti)); } catch (e) {}
      mostra(scelta); return;
    }
    scelta = b.dataset.scheda; mostra(scelta); try { sessionStorage.setItem('scheda', b.dataset.scheda); } catch (e) {}
  }); });
})();
</script>
'@

# I due contatori, sempre: fra quanti secondi si ricarica la pagina e fra quanto parte lo smistatore (data-quando, con il fuso;
# vuoto se l'attivita pianificata non si legge). Con il server (data-ricarica="script" su <main>) ricarica lo script, salvo
# durante una rilettura chiesta; senza server ricarica il meta refresh e lo script conta soltanto.
$script:ScriptContatori = @'
<script>
(function () {
  var p = document.getElementById('conta-pagina'), s = document.getElementById('conta-smistatore');
  var main = document.querySelector('main');
  var resto = p ? parseInt(p.getAttribute('data-secondi'), 10) : 0, ricarica = false;
  var quando = s && s.getAttribute('data-quando') ? Date.parse(s.getAttribute('data-quando')) : NaN;
  var durata = function (sec) { var m = Math.floor(sec / 60), r = sec % 60; return (m > 0 ? m + ' min ' : '') + r + ' s'; };
  var passo = function () {
    if (p) { p.textContent = resto > 0 ? resto + ' s' : 'adesso'; }
    if (s) {
      if (isNaN(quando)) { s.textContent = 'non si sa'; }
      else { var d = Math.round((quando - Date.now()) / 1000); s.textContent = d > 0 ? durata(d) : 'adesso'; }
    }
    // una volta sola: con il server occupato a rileggere ADO, un reload al secondo annulla ogni volta la richiesta di prima
    if (resto <= 0 && !ricarica && main && main.getAttribute('data-ricarica') === 'script' && !window.vistaAttesaAggiorna && !(document.hasFocus() && document.activeElement && document.activeElement.id === 'quota-soglia' && resto > -60)) { ricarica = true; location.reload(); }
    resto--;
  };
  passo(); setInterval(passo, 1000);
})();
</script>
'@

function Format-BarraTask($Avanzamento) {
    if ($null -eq $Avanzamento -or $Avanzamento.Totali -le 0) { return '' }
    $perc = [int][math]::Floor(100 * $Avanzamento.Chiusi / $Avanzamento.Totali)
    "<div class=`"barra`" role=`"img`" aria-label=`"$($Avanzamento.Chiusi) task chiusi su $($Avanzamento.Totali)`"><span style=`"width:$perc%`"></span></div><div class=`"etichetta-barra`">$($Avanzamento.Chiusi)/$($Avanzamento.Totali) task</div>"
}

# Il numero di una card: un link alla card su Azure DevOps (il modello lo dice in .UrlCard) che si apre in una scheda nuova;
# senza un indirizzo http(s) resta testo. Non compone mai l'indirizzo: lo calcola il modello.
# Numero e titolo di una card in un link solo alla card (scheda nuova): si clicca dove si legge. Senza un link http
# restano testo; senza titolo il link ha solo il numero.
# La riga "Stato:" sotto il titolo di una card, con l'etichetta colorata per fase (Format-StatoBoard). Vuota senza stato.
function Format-RigaStato([string]$Stato, [string]$Chiave) {
    if (-not $Stato) { return '' }
    "<div class=`"riga-stato`"><span class=`"campo`">Stato:</span> $(Format-StatoBoard ([pscustomobject]@{ Stato = $Stato; Chiave = $Chiave }))</div>"
}

# La chiave di stato di una voce (Get-ChiaveStato, la mette Vista.ps1), vuota se manca.
function Get-ChiaveVoce($V) { if ($V.PSObject.Properties['Chiave']) { [string]$V.Chiave } else { '' } }

function Format-CardLink($Voce) {
    $url = if ($Voce.PSObject.Properties['UrlCard']) { "$($Voce.UrlCard)" } else { '' }
    $t = if ($Voce.PSObject.Properties['Titolo'] -and $Voce.Titolo) { ' ' + (E $Voce.Titolo) } else { '' }
    $dentro = "<span class=`"num`">#$($Voce.Id)</span>$t"
    if ($url -match '^https?://') { "<a class=`"card`" href=`"$(E $url)`" target=`"_blank`" rel=`"noopener`">$dentro</a>" } else { $dentro }
}

function Format-NumeroCard($Voce, [string]$Classe = 'num') {
    $url = if ($Voce.PSObject.Properties['UrlCard']) { "$($Voce.UrlCard)" } else { '' }
    if ($url -match '^https?://') { "<a class=`"num`" href=`"$(E $url)`" target=`"_blank`" rel=`"noopener`">#$($Voce.Id)</a>" }
    else { "<span class=`"$Classe`">#$($Voce.Id)</span>" }
}

# La riga della PR su una scheda (il modello la dice in .Pr: numero, validazione, link alla PR e al log della build). Senza PR,
# o in un modello che il campo non ce l'ha, non c'e riga. Il link al log si da solo dove la build e rossa o ancora in corso.
function Format-RigaPr($Voce) {
    if (-not $Voce.PSObject.Properties['Pr'] -or $null -eq $Voce.Pr) { return '' }
    $pr = $Voce.Pr
    $etichette = @{ verde = 'verde'; rossa = 'rossa'; inCorso = 'in corso'; scaduta = 'scaduta (si rilancia al merge)'; conflitti = 'in conflitto'; assente = 'assente' }
    $v = [string]$pr.Validazione
    $chiave = if ($etichette.ContainsKey($v)) { $v } else { 'assente' }
    $link = { param($Url, $Testo) if ("$Url" -match '^https?://') { "<a href=`"$(E $Url)`" target=`"_blank`" rel=`"noopener`">$(E $Testo)</a>" } else { E $Testo } }
    $riga = "<div class=`"pr pr-$chiave`">$(& $link $pr.Url "PR #$($pr.Id)") <span class=`"pr-stato`">$($etichette[$chiave])</span>"
    if ($chiave -in 'rossa', 'inCorso' -and "$($pr.UrlLog)" -match '^https?://') { $riga += " &middot; $(& $link $pr.UrlLog 'log')" }
    $riga + '</div>'
}

function Format-SchedaSessione($S) {
    $t = [System.Text.StringBuilder]::new()
    [void]$t.Append('<article class="' + $(if ($S.Viva) { 'scheda' } else { 'scheda pausa' }) + '" data-id="' + $S.Id + '">')
    # Il link porta alla pagina dello stream (la scrive Vista.ps1, accanto a vista.html). L'id e un nome di file: se non lo e, niente link.
    $segui = if ($S.PSObject.Properties['SessioneId'] -and "$($S.SessioneId)" -match '^[\w.-]+$') { " <a class=`"segui`" href=`"sessione-$(E $S.SessioneId).html`" target=`"_blank`" rel=`"noopener`">segui</a>" } else { '' }
    [void]$t.Append("<h3>$(Format-CardLink $S)$segui</h3>")
    if ($S.PSObject.Properties['StatoAdo'] -and $S.StatoAdo) { [void]$t.Append((Format-RigaStato ([string]$S.StatoAdo) (Get-ChiaveVoce $S))) }
    $chip = @()
    if ($S.Repo) { $chip += "<span class=`"chip`">$(E $S.Repo)</span>" }
    if ($S.Ruolo) { $chip += "<span class=`"chip`">$(E $S.Ruolo)</span>" }
    if ($chip) { [void]$t.Append('<div>' + ($chip -join '') + '</div>') }
    if ($S.Task) {
        $tt = if ($S.TitoloTask) { " $(E $S.TitoloTask)" } else { '' }
        [void]$t.Append("<div class=`"meta`">task <b>$(E $S.Task)</b>$tt</div>")
    }
    $viva = if ($S.Viva) { '<span class="pallino viva"></span>processo vivo' } else { '<span class="pallino"></span>processo non attivo' }
    $parti = @($viva)
    if ($null -ne $S.Minuti) { $parti += "$($S.Minuti) min" }
    if ($S.TokenTesto) { $parti += (E $S.TokenTesto) }
    [void]$t.Append('<div class="meta">' + ($parti -join ' &middot; ') + '</div>')
    [void]$t.Append((Format-RigaPr $S))
    [void]$t.Append((Format-BarraTask $S.Avanzamento))
    if (@($S.Azioni).Count -gt 0) {
        [void]$t.Append('<pre class="azioni">' + ((@($S.Azioni) | ForEach-Object { '- ' + (E $_) }) -join "`n") + '</pre>')
    }
    [void]$t.Append('</article>')
    $t.ToString()
}

# Una voce della coda di un ruolo: il motivo dell'attesa, o che parte al prossimo giro (lo dice il modello).
# Le predecessore che tengono ferma una card (Get-AttesePredecessori), in un riquadro ben visibile al posto del motivo:
# numero (link), stato e, se tocca a una persona, cosa fare. Vuoto se la voce non aspetta nessuno.
function Format-Aspetta($V) {
    $a = @(if ($V.PSObject.Properties['Aspetta']) { @($V.Aspetta) | Where-Object { $null -ne $_ } })
    if ($a.Count -eq 0) { return '' }
    $righe = @(foreach ($p in $a) {
        $gesto = if ($p.Gesto) { "<span class=`"gesto`">$(E $p.Gesto)</span>" } else { '' }
        # tre righe: chi aspetta, il suo stato (con un'etichetta sua) e, se serve una persona, cosa fare
        "<li$(if ($p.Gesto) { ' class="persona"' })><span class=`"aspetta-testo`">Aspetta la card $(Format-NumeroCard $p)</span>" +
            "<span class=`"aspetta-stato`"><span class=`"campo`">Stato:</span>$(Format-StatoBoard $p)</span>$gesto</li>"
    })
    $persona = @($a | Where-Object { $_.Gesto }).Count -gt 0
    "<div class=`"aspetta$(if ($persona) { ' persona' })`"><ul>$($righe -join '')</ul></div>"
}

# Lo stato di una card sulla board come etichetta colorata per fase: analisi (grigio), sviluppo (blu), verifica (ambra),
# verso develop (verde), rimossa (rosso). La chiave viene da Get-ChiaveStato; senza chiave l'etichetta resta neutra.
function Format-StatoBoard($P) {
    $k = if ($P.PSObject.Properties['Chiave']) { [string]$P.Chiave } else { '' }
    $tono = switch ($k) {
        { $_ -in 'bozza', 'nuova', 'daChiarire' } { 'analisi'; break }
        { $_ -in 'pronto', 'inSviluppo' } { 'sviluppo'; break }
        { $_ -in 'inRevisione', 'inDeployTest', 'inCollaudo', 'inProvaUmana' } { 'verifica'; break }
        { $_ -in 'daUnire', 'inFeature', 'daRilasciare', 'inRilascio', 'chiusa' } { 'unione'; break }
        'rimossa' { 'rimossa'; break }
        default { 'altro' }
    }
    "<span class=`"stato-board $tono`">$(E $P.Stato)</span>"
}

# Il motivo di una voce, o al suo posto il riquadro delle predecessore che la tengono ferma.
# $Grezzo e lo stesso testo prima dell'escape o della formattazione: serve a dire se e lungo (piu righe o piu di 90 caratteri). Un motivo
# lungo sta in un dettaglio chiuso, con la prima riga come anteprima, cosi le voci hanno tutte la stessa altezza; lo ricorda lo script
# delle schede (data-ricorda), perche la pagina si ricarica da sola. Uno breve resta una riga sola.
function Format-MotivoVoce($V, [string]$Testo, [string]$Grezzo = '') {
    $asp = Format-Aspetta $V
    if ($asp) { return $asp }
    if (-not $Testo) { return '' }
    $corpo = "<span class=`"motivo`">$Testo</span>"
    $righe = @($Grezzo -split "`n")
    if ($Grezzo -and ($righe.Count -gt 1 -or $Grezzo.Length -gt 90)) {
        return "<details class=`"dettagli`" data-ricorda=`"voce-$($V.Id)`"><summary><span class=`"anteprima`">$(E $righe[0].Trim())</span></summary>$corpo</details>"
    }
    $corpo
}

function Format-VoceCoda($C) {
    $stato = if ($C.PSObject.Properties['Stato']) { Format-RigaStato ([string]$C.Stato) (Get-ChiaveVoce $C) } else { '' }
    "<div class=`"voce`" data-id=`"$($C.Id)`">$(Format-CardLink $C)$stato$(Format-MotivoVoce $C (E $C.Testo) ([string]$C.Testo))$(Format-RigaPr $C)$(Format-BarraTask $C.Avanzamento)</div>"
}

# Il testo di una voce Rispondi (Format-DomandaOperatore): il titolo di ogni domanda D1, D2... in grassetto e l'etichetta
# "proposta:" a parte, cosi le domande si distinguono a colpo d'occhio. Gli a capo restano (motivo e pre-line).
function Format-TestoRispondi([string]$Testo) {
    @($Testo -split "`n" | ForEach-Object {
        if ($_ -cmatch '^\W*D\d+\b') { "<b>$(E $_)</b>" }
        elseif ($_ -match '^proposta:\s*(.*)$') { "<span class=`"proposta`">proposta:</span> $(E $Matches[1])" }
        else { E $_ }
    }) -join "`n"
}

# Con il server (token) la pagina ha i pulsanti dei comandi; New-PaginaVista lo scrive qui per le voci che li portano.
$script:PaginaConServer = $false; $script:TokenPagina = ''

# Una voce della colonna dell'operatore: etichetta col verbo (il colore viene dalla classe att-<attivita>), fase e testo.
function Format-VoceOperatore($V) {
    $fase = if ($V.Fase) { " <span class=`"fase`">$(E $V.Fase)</span>" } else { '' }
    $testo = if ($V.Attivita -eq 'rispondi') { Format-TestoRispondi $V.Testo } else { E $V.Testo }
    # D52: un gesto che non viene da una predecessora (la chiusura in Draft, da spostare in New) sta sotto il motivo, come nel riquadro Aspetta
    $gesto = if ($V.PSObject.Properties['Gesto'] -and $V.Gesto) { "<div class=`"aspetta persona`"><span class=`"gesto`">$(E $V.Gesto)</span></div>" } else { '' }
    # D37: una card col tag on-hold porta il segno data-on-hold e, con il server, il pulsante "Togli on-hold" (il motivo resta visibile sopra)
    $inAttesa = $V.PSObject.Properties['InAttesa'] -and [bool]$V.InAttesa
    $segno = if ($inAttesa) { ' data-on-hold="1"' } else { '' }
    # D57: la sezione "Cosa fare" dell'on-hold (Get-RigheCosaFare), sopra il pulsante
    $cf = @(if ($V.PSObject.Properties['CosaFare']) { @($V.CosaFare) | Where-Object { $_ } })
    if ($cf.Count -gt 0) { $gesto += "<div class=`"aspetta persona cosa-fare`"><b>Cosa fare</b>$(($cf | ForEach-Object { "<div>$(E $_)</div>" }) -join '')</div>" }
    $togli = if ($inAttesa -and $script:PaginaConServer) { "<span class=`"azione`"><button type=`"button`" class=`"togli-attesa`" id=`"togli-attesa-$($V.Id)`" data-id=`"$($V.Id)`" data-token=`"$(E $script:TokenPagina)`">Togli on-hold</button><span class=`"esito-ado`" role=`"status`"></span></span>" } else { '' }
    "<div class=`"voce att-$(E $V.Attivita)`" data-attivita=`"$(E $V.Attivita)`" data-id=`"$($V.Id)`"$segno><span class=`"etichetta att-$(E $V.Attivita)`">$(E $V.Verbo)</span>$fase<br>$(Format-CardLink $V)$(if ($V.PSObject.Properties['Stato']) { Format-RigaStato ([string]$V.Stato) (Get-ChiaveVoce $V) })$(Format-MotivoVoce $V $testo ([string]$V.Testo))$gesto$(Format-RigaPr $V)$togli</div>"
}

function Format-ColonnaAgente($A) {
    $t = [System.Text.StringBuilder]::new()
    $nome = if ($script:TitoliRuoli.ContainsKey($A.Ruolo)) { $script:TitoliRuoli[$A.Ruolo] } else { $A.Ruolo }
    $brief = if ($A.PSObject.Properties['Brief'] -and "$($A.Brief)" -match '^[\w.-]+\.html$') { " <a class=`"brief`" href=`"$(E $A.Brief)`" target=`"_blank`" rel=`"noopener`">brief</a>" } else { '' }
    [void]$t.AppendLine("<section class=`"colonna`" data-colonna=`"$(E $A.Ruolo)`"><h2>$(E $nome)<span class=`"conta`">$(@($A.Sessioni).Count)</span>$brief</h2>")
    if (@($A.Sessioni).Count -eq 0) { [void]$t.AppendLine('<p class="libero">libero</p>') }
    foreach ($s in @($A.Sessioni)) { [void]$t.AppendLine((Format-SchedaSessione $s)) }
    if (@($A.Coda).Count -gt 0) {
        # chiusa di partenza: chi legge la apre, e la pagina ricorda la scelta (data-ricorda)
        [void]$t.AppendLine("<details class=`"gruppo`" data-ricorda=`"coda-$(E $A.Ruolo)`"><summary><h3>In coda<span class=`"conta`">$(@($A.Coda).Count)</span></h3></summary>")
        foreach ($c in @($A.Coda)) { [void]$t.AppendLine((Format-VoceCoda $c)) }
        [void]$t.AppendLine('</details>')
    }
    [void]$t.AppendLine('</section>')
    $t.ToString()
}

# La colonna del supervisore, dopo quelle dei ruoli: ultimo e prossimo giro, i problemi aperti (gli urgenti evidenziati) e le diagnosi
# in corso. Il modello la porta in Supervisore; se il file non si legge lo dice e la pagina si disegna lo stesso.
function Format-ColonnaSupervisore($S) {
    $t = [System.Text.StringBuilder]::new()
    $brief = if ($S.PSObject.Properties['Brief'] -and "$($S.Brief)" -match '^[\w.-]+\.html$') { " <a class=`"brief`" href=`"$(E $S.Brief)`" target=`"_blank`" rel=`"noopener`">brief</a>" } else { '' }
    $conta = if ($S.Letto) { @($S.Problemi).Count } else { '?' }
    [void]$t.AppendLine("<section class=`"colonna supervisore`" data-colonna=`"supervisore`"><h2>Supervisore<span class=`"conta`">$conta</span>$brief</h2>")
    if (-not $S.Letto) { [void]$t.AppendLine('<p class="libero">stato non leggibile</p>') }
    $ultimo = if ($S.Letto) { "ultimo giro $(E $S.Ultimo) &middot; " } else { '' }
    [void]$t.AppendLine("<p class=`"giro-supervisore`">$ultimo`prossimo $(E $S.Prossimo)</p>")
    if ($S.Letto) {
        if (@($S.Problemi).Count -eq 0) { [void]$t.AppendLine('<p class="libero">nessun problema</p>') }
        foreach ($p in @($S.Problemi)) {
            $classe = if ($p.Urgente) { 'voce problema urgente' } else { 'voce problema' }
            $etichetta = if ($p.Urgente) { '<span class="etichetta urgente">urgente</span> ' } else { '' }
            [void]$t.AppendLine("<div class=`"$classe`" data-problema=`"$(E $p.Chiave)`">$etichetta$(E $p.Testo)</div>")
        }
        if (@($S.Diagnosi).Count -gt 0) {
            [void]$t.AppendLine("<h3>Diagnosi in corso<span class=`"conta`">$(@($S.Diagnosi).Count)</span></h3>")
            foreach ($d in @($S.Diagnosi)) { [void]$t.AppendLine("<div class=`"voce diagnosi`">$(E $d.Testo)</div>") }
        }
    }
    [void]$t.AppendLine('</section>')
    $t.ToString()
}

function Format-ColonnaOperatore($Operatore) {
    $t = [System.Text.StringBuilder]::new()
    $tot = @($Operatore.Fermano).Count + @($Operatore.NonFermano).Count
    [void]$t.AppendLine("<section class=`"colonna operatore`" data-colonna=`"operatore`"><h2>Operatore (tu)<span class=`"conta`">$tot</span></h2>")
    if ($tot -eq 0) { [void]$t.AppendLine('<p class="libero">niente da fare</p>') }
    # i due gruppi si chiudono con un clic e la pagina ricorda la scelta (data-ricorda); di partenza solo "Fermano il flusso" e aperto
    foreach ($g in @(@{ Titolo = 'Fermano il flusso'; Voci = $Operatore.Fermano; Chiave = 'fermano'; Aperto = ' open' }, @{ Titolo = 'Non fermano nessuno'; Voci = $Operatore.NonFermano; Chiave = 'non-fermano'; Aperto = '' })) {
        if (@($g.Voci).Count -eq 0) { continue }
        [void]$t.AppendLine("<details class=`"gruppo`" data-ricorda=`"operatore-$($g.Chiave)`"$($g.Aperto)><summary><h3>$(E $g.Titolo)<span class=`"conta`">$(@($g.Voci).Count)</span></h3></summary>")
        foreach ($v in @($g.Voci)) { [void]$t.AppendLine((Format-VoceOperatore $v)) }
        [void]$t.AppendLine('</details>')
    }
    [void]$t.AppendLine('<ul class="legenda">' +
        '<li><span class="campione att-sblocca"></span><span><b>Sblocca</b>: on-hold, un limite o un problema da sbloccare</span></li>' +
        '<li><span class="campione att-rispondi"></span><span><b>Rispondi</b>: responsabile ha fatto una domanda</span></li>' +
        '<li><span class="campione att-prova"></span><span><b>Prova in Test</b>: la prova tocca a una persona</span></li>' +
        '<li><span class="campione att-rilascia"></span><span><b>Rilascia</b>: pronta per la produzione</span></li></ul>')
    [void]$t.AppendLine('</section>')
    $t.ToString()
}

function Format-ColonnaPipeline($Pipeline) {
    $t = [System.Text.StringBuilder]::new()
    [void]$t.AppendLine("<section class=`"colonna pipeline`" data-colonna=`"pipeline`"><h2>Pipeline<span class=`"conta`">$(@($Pipeline).Count)</span></h2>")
    if (@($Pipeline).Count -eq 0) { [void]$t.AppendLine('<p class="libero">nessuna</p>') }
    foreach ($c in @($Pipeline)) {
        # lo stato sulla board come etichetta colorata, su una riga sua sotto il titolo (le parole vanno a capo intere)
        $stato = Format-RigaStato ([string]$c.Stato) (Get-ChiaveVoce $c)
        $nota = Format-MotivoVoce $c $(if ($c.Testo) { E $c.Testo } else { '' })
        [void]$t.AppendLine("<div class=`"voce`" data-id=`"$($c.Id)`"><span class=`"titolo`">$(Format-CardLink $c)</span>$stato$nota$(Format-RigaPr $c)</div>")
    }
    [void]$t.AppendLine('</section>')
    $t.ToString()
}

# Dove gira il run: un'icona compatta, cloud (pool Microsoft-hosted) o interno (self-hosted); il nome del pool sta nel tooltip.
function Format-AgenteBuild($B) {
    $a = if ($B.PSObject.Properties['Agente']) { [string]$B.Agente } else { '' }
    if ($a -notin 'cloud', 'interno', 'misto') { return '' }
    $stima = $B.PSObject.Properties['AgenteStimato'] -and $B.AgenteStimato
    $pool = if ($B.PSObject.Properties['Pool'] -and $B.Pool) { [string]$B.Pool } else { '' }
    $icona = switch ($a) { 'cloud' { '&#9729;' } 'interno' { '&#8962;' } default { '&#9680;' } }
    $nota = if ($stima) { ' (stimato: l''ultimo run concluso della pipeline)' } else { '' }
    "<span class=`"agente $a$(if ($stima) { ' stimato' })`" title=`"agente $a$(if ($pool) { ': ' + (E $pool) })$nota`">$icona $a</span>"
}

# Il nome di chi ha lanciato il run, senza la ragione sociale ("Rossi Mario - Acme S.p.A." -> "Rossi Mario").
function Format-NomeBreve([string]$Nome) { ($Nome -replace '\s+-\s+[^-]*$', '').Trim() }

# Da quanto dura un run, a parole brevi (i minuti, o le ore e i minuti).
function Format-DurataBuild($Da, $A) {
    if ($null -eq $Da -or $null -eq $A) { return '' }
    $m = [int][math]::Max(0, [math]::Floor(([datetime]$A - [datetime]$Da).TotalMinutes))
    if ($m -ge 60) { "$([math]::Floor($m / 60)) h $($m % 60) min" } else { "$m min" }
}

# L'attributo che rende cliccabile tutta la riga (lo script delle schede apre il run in una scheda nuova); vuoto senza un link http.
function Format-UrlRiga($B) { if ("$($B.Url)" -match '^https?://') { " data-url=`"$(E $B.Url)`"" } else { '' } }

function Format-LinkRun($B, [string]$Testo = 'apri il run') {
    if ("$($B.Url)" -match '^https?://') { "<a href=`"$(E $B.Url)`" target=`"_blank`" rel=`"noopener`">$Testo</a>" } else { '' }
}

# Una cella; $Classe e opzionale. Il contenuto e gia html.
function Format-Cella([string]$Html, [string]$Classe = '') {
    if ($Classe) { "<td class=`"$Classe`">$Html</td>" } else { "<td>$Html</td>" }
}

function Format-Tabella([string[]]$Colonne, [string[]]$Righe) {
    '<div class="tabella"><table class="build-tab"><thead><tr>' + (($Colonne | ForEach-Object { "<th>$_</th>" }) -join '') + '</tr></thead><tbody>' + ($Righe -join "`n") + '</tbody></table></div>'
}

# Un run in coda, con la posizione nel pool quando ADO la da (richieste dei pool di agenti).
function Format-PillolaCoda($B) {
    if ($B.PSObject.Properties['PosizioneCoda'] -and $B.PosizioneCoda) {
        $pool = if ($B.PSObject.Properties['PoolCoda'] -and $B.PoolCoda) { " del pool $(E $B.PoolCoda)" } else { '' }
        return "<span class=`"pillola inCoda`" title=`"posizione nella coda$pool (da Azure DevOps)`">in coda &middot; $([int]$B.PosizioneCoda)&deg;</span>"
    }
    '<span class="pillola inCoda">in coda</span>'
}

# Lo stato di un run per i filtri della scheda: quello del run se e attivo, per un run concluso riuscito o fallito.
function Get-StatoFiltro($B) {
    if ($B.Stato -ne 'concluso') { return [string]$B.Stato }
    if ("$($B.Esito)" -eq 'succeeded') { 'riuscito' } else { 'fallito' }
}

# Il riquadro degli agenti dei pool interni: per ogni pool quanti run ci aspettano e ogni agente con lo stato (online,
# offline, disabilitato) e cosa sta facendo, con il link al run. $Run sono i run attivi: da loro si contano le attese.
function Format-AgentiPool([object[]]$Pool, [object[]]$Run) {
    if ($Pool.Count -eq 0) { return '' }
    $schede = foreach ($p in $Pool) {
        $attesa = @($Run | Where-Object { $_.Stato -eq 'inCoda' -and $_.PSObject.Properties['PoolCoda'] -and $_.PoolCoda -eq $p.Pool }).Count
        $righe = foreach ($a in @($p.Agenti)) {
            $stato = if (-not $a.Abilitato) { '<span class="pillola">disabilitato</span>' } elseif ($a.Online) { '<span class="pillola verde">online</span>' } else { '<span class="pillola rosso">offline</span>' }
            $lavoro = if ($a.Lavoro) {
                $testo = "build $([int]$a.Lavoro.BuildId) &middot; $(E $a.Lavoro.Pipeline)"
                $txt = if ("$($a.Lavoro.Url)" -match '^https?://') { "<a href=`"$(E $a.Lavoro.Url)`" target=`"_blank`" rel=`"noopener`">$testo</a>" } else { $testo }
                "<span class=`"pillola inCorso`">al lavoro</span> $txt"
            } elseif ($a.Online -and $a.Abilitato) { '<span class="dove">libero</span>' } else { '' }
            "<li><span class=`"etichetta-tipo agente`">agente</span> <b>$(E $a.Nome)</b> $stato $lavoro</li>"
        }
        $coda = if ($attesa -gt 0) { " <span class=`"pillola inCoda`">$attesa in coda</span>" } else { '' }
        $n = @($p.Agenti).Count
        $quanti = " <span class=`"dove`">$n $(if ($n -eq 1) { 'agente' } else { 'agenti' })</span>"
        "<div class=`"pool`" data-pool=`"$(E $p.Pool)`"><h4><span class=`"etichetta-tipo pool`">pool</span> $(E $p.Pool)$quanti$coda</h4><ul>$($righe -join '')</ul></div>"
    }
    '<div class="agenti-pool" data-blocco="agenti"><h3>Agenti dei pool interni</h3><div class="pool-lista">' + ($schede -join '') + '</div></div>'
}

# I filtri per stato, con quanti run ha ciascuno; li fa funzionare lo script delle schede (scelta ricordata in sessionStorage).
function Format-FiltriBuild([object[]]$Run) {
    $voci = @(@('tutti', 'Tutti'), @('inCorso', 'In corso'), @('inCoda', 'In coda'), @('inAttesa', 'Da approvare'), @('fallito', 'Falliti o annullati'), @('riuscito', 'Riusciti'))
    $pulsanti = foreach ($v in $voci) {
        $n = if ($v[0] -eq 'tutti') { $Run.Count } else { @($Run | Where-Object { (Get-StatoFiltro $_) -eq $v[0] }).Count }
        "<button type=`"button`" data-filtro=`"$($v[0])`" aria-pressed=`"$(if ($v[0] -eq 'tutti') { 'true' } else { 'false' })`">$($v[1])<span class=`"conta`">$n</span></button>"
    }
    '<div class="filtri" role="group" aria-label="Filtra per stato (scelta multipla)" title="un clic aggiunge o toglie uno stato; Tutti li azzera">' + ($pulsanti -join '') + '</div>'
}

# Lo stato di un run come pillola: per un run concluso l'esito, per gli altri a che punto e.
function Format-PillolaRun($B) {
    if ($B.Stato -eq 'concluso') {
        switch ("$($B.Esito)") {
            'succeeded' { return '<span class="pillola verde">riuscito</span>' } 'partiallySucceeded' { return '<span class="pillola ambra">riuscito in parte</span>' }
            'failed' { return '<span class="pillola rosso">fallito</span>' } 'canceled' { return '<span class="pillola ambra">annullato</span>' }
            default { return "<span class=`"pillola`">$(E $B.Esito)</span>" }
        }
    }
    switch ($B.Stato) { 'inAttesa' { '<span class="pillola inAttesa">attende approvazione</span>' } 'inCoda' { Format-PillolaCoda $B } default { '<span class="pillola inCorso">in corso</span>' } }
}

# Una riga di run nel blocco di un progetto: stato, pipeline (un rilascio ha l'etichetta), ramo, cosa sta facendo, chi, agente, quando, link.
# Il dettaglio dice i componenti di un rilascio e la fase o l'approvazione su cui un run attivo e fermo.
function Format-RigaRun($B, $Adesso, [bool]$Rilascio) {
    $nome = E $B.Pipeline
    $tipo = if ($Rilascio) { 'rilascio' } elseif ($B.PSObject.Properties['Tipo'] -and $B.Tipo) { [string]$B.Tipo } else { '' }
    $cellaTipo = if ($tipo) { "<span class=`"tipo $(E $tipo)`">$(E $tipo)</span>" } else { '' }
    $numero = "<b class=`"build-id`" title=`"build id`">$([int]$B.Id)</b>" + $(if ($B.PSObject.Properties['Numero'] -and $B.Numero) { "<span class=`"versione`" title=`"versione del run (buildNumber)`">$(E $B.Numero)</span>" } else { '' })
    $det = [System.Collections.Generic.List[string]]::new()
    if ($Rilascio) {
        $comp = (@(foreach ($c in @($B.Componenti)) { "<span class=`"comp`">$(E $c)</span>" }) -join '')
        $det.Add($(if ($comp) { $comp } else { '<span class="dove">nessun componente</span>' }))
    }
    if ($B.Fase -and $B.Stato -ne 'concluso') {
        $attende = if ($B.PSObject.Properties['Attende']) { [string]$B.Attende } else { '' }
        $etichetta = switch ($B.Stato) { 'inAttesa' { 'approvazione per' } 'inCoda' { if ($attende -eq 'controllo') { 'aspetta un controllo:' } else { 'aspetta un agente:' } } default { 'fase' } }
        $det.Add("<span class=`"fase-run`">$etichetta <b>$(E $B.Fase)</b></span>")
    }
    $quando = switch ($B.Stato) {
        'concluso' { if ($B.Fine) { "finito $(E ([datetime]$B.Fine).ToLocalTime().ToString('dd/MM HH:mm'))" } else { '' } }
        'inCoda' { if ($B.Inizio) { "in coda da $(Format-DurataBuild $B.Inizio $Adesso.ToUniversalTime())" } else { '' } }
        default { if ($B.Inizio) { "gira da $(Format-DurataBuild $B.Inizio $Adesso.ToUniversalTime())" } else { '' } }
    }
    $classe = if ($B.Stato -eq 'inAttesa') { ' class="in-attesa"' } else { '' }
    $filtro = Get-StatoFiltro $B
    "<tr$classe data-stato=`"$filtro`" data-build=`"$([int]$B.Id)`"$(Format-UrlRiga $B)>" + (Format-Cella (Format-PillolaRun $B)) + (Format-Cella $cellaTipo) + (Format-Cella $nome 'nome') + (Format-Cella $numero 'numero') + (Format-Cella (E $B.Ramo) 'ramo') +
        (Format-Cella ($det -join ' ')) + (Format-Cella (E (Format-NomeBreve $B.Autore)) 'chi') + (Format-Cella (Format-AgenteBuild $B)) +
        (Format-Cella $quando 'dove') + (Format-Cella (Format-LinkRun $B) 'azione') + '</tr>'
}

$script:ColonneRun = @('Stato', 'Tipo', 'Pipeline', 'Run', 'Ramo', 'Dettaglio', 'Chi', 'Agente', 'Quando', '')

# Il riquadro in cima: solo i run fermi su un'approvazione, l'unica cosa che chiede a una persona di fare qualcosa.
function Format-DaApprovare([object[]]$Run, $Adesso) {
    if ($Run.Count -eq 0) { return '' }
    $righe = foreach ($b in $Run) {
        $da = if ($b.Inizio) { "da $(Format-DurataBuild $b.Inizio $Adesso.ToUniversalTime())" } else { '' }
        "<tr data-stato=`"inAttesa`" data-build=`"$([int]$b.Id)`"$(Format-UrlRiga $b)>" + (Format-Cella (E $b.Progetto) 'nome') + (Format-Cella (E $b.Pipeline)) + (Format-Cella (E $b.Ramo) 'ramo') +
            (Format-Cella $(if ($b.Fase) { "<b>$(E $b.Fase)</b>" } else { '' })) + (Format-Cella $da 'dove') + (Format-Cella (Format-LinkRun $b 'apri e approva') 'azione') + '</tr>'
    }
    "<div class=`"da-approvare`" data-blocco=`"approvazioni`"><h3>Da approvare<span class=`"conta`">$($Run.Count)</span></h3>" +
        (Format-Tabella @('Progetto', 'Pipeline', 'Ramo', 'Approvazione per', 'In attesa', '') @($righe)) + '</div>'
}

# Il blocco di un progetto: i rilasci (orchestrator) e i run attivi in una tabella, i falliti/annullati delle ultime ore in un riquadro chiuso.
function Format-BloccoProgetto([string]$Nome, [object[]]$Rilasci, [object[]]$Attivi, [object[]]$Falliti, [int]$Ore, $Adesso) {
    $t = [System.Text.StringBuilder]::new()
    $chip = [System.Collections.Generic.List[string]]::new()
    $att = @(@($Attivi) + @($Rilasci | Where-Object Stato -ne 'concluso'))
    $nAttesa = @($att | Where-Object Stato -eq 'inAttesa').Count
    $nCorso = @($att | Where-Object Stato -eq 'inCorso').Count; $nCoda = @($att | Where-Object Stato -eq 'inCoda').Count
    if ($nAttesa -gt 0) { $chip.Add("<span class=`"pillola inAttesa`">$nAttesa da approvare</span>") }
    if ($nCorso -gt 0) { $chip.Add("<span class=`"pillola inCorso`">$nCorso in corso</span>") }
    if ($nCoda -gt 0) { $chip.Add("<span class=`"pillola inCoda`">$nCoda in coda</span>") }
    if ($Falliti.Count -gt 0) { $chip.Add("<span class=`"pillola rosso`">$($Falliti.Count) falliti/annullati</span>") }
    # comprimibile: aperto di default, chi lo chiude lo ritrova chiuso dopo il ricaricamento (lo ricorda lo script delle schede)
    [void]$t.AppendLine("<details class=`"progetto`" data-progetto=`"$(E $Nome)`" open><summary><h3>$(E $Nome) $($chip -join ' ')</h3></summary>")
    $righe = @(@($Rilasci | ForEach-Object { Format-RigaRun $_ $Adesso $true }) + @($Attivi | ForEach-Object { Format-RigaRun $_ $Adesso $false }))
    if ($righe.Count -gt 0) { [void]$t.AppendLine((Format-Tabella $script:ColonneRun $righe)) }
    if ($Falliti.Count -gt 0) {
        [void]$t.AppendLine("<details class=`"falliti`"><summary>Falliti o annullati nelle ultime $Ore ore<span class=`"conta`">$($Falliti.Count)</span></summary>")
        [void]$t.AppendLine((Format-Tabella $script:ColonneRun @($Falliti | ForEach-Object { Format-RigaRun $_ $Adesso $false })))
        [void]$t.AppendLine('</details>')
    }
    [void]$t.AppendLine('</details>')
    $t.ToString()
}

# La sezione delle pipeline di tutti i progetti: in cima il titolo con il pulsante delle PR e il riepilogo, poi le approvazioni
# che aspettano, poi un blocco per progetto (prima quelli con attese, poi con run attivi, poi con falliti).
# $Build e il risultato di Get-AdoBuildPipeline, o $null se non si e ancora letto; $Errore il motivo di una lettura fallita.
# $Lettura e l'ora dell'ultima lettura riuscita, $Ogni ogni quanti secondi si rilegge; con $Token (vista servita) c'e il pulsante
# "Aggiorna pipeline", che fa la stessa rilettura di "Aggiorna agenti e card" (POST /aggiorna): agenti e pipeline si leggono insieme.
function Format-SezioneBuild($Build, [string]$Errore, $Adesso, [string]$UrlPr, [string]$Lettura = '', [int]$Ogni = 0, [string]$Token = '') {
    $t = [System.Text.StringBuilder]::new()
    $pr = if ("$UrlPr" -match '^https?://') { "<a class=`"build-pr`" href=`"$(E $UrlPr)`" target=`"_blank`" rel=`"noopener`">Pull request di tutti i progetti &#8599;</a>" } else { '' }
    [void]$t.AppendLine("<section class=`"build`" data-sezione=`"build`"><div class=`"build-testa`"><h1>Pipeline</h1>$pr</div>")
    $sotto = @('Run di build di tutti i progetti dell''organizzazione')
    if ($Lettura) { $sotto += "letti alle $(E $Lettura)" }
    if ($Ogni -gt 0) { $sotto += "si rileggono ogni $Ogni s" }
    [void]$t.AppendLine("<p class=`"sotto`">$($sotto -join ' &middot; ')</p>")
    if ($Token) { [void]$t.AppendLine("<p class=`"giro`"><button type=`"button`" id=`"aggiorna-pipeline`" data-token=`"$(E $Token)`">Aggiorna pipeline</button><span class=`"esito-ado`" role=`"status`"></span></p>") }
    if ($Errore) { [void]$t.AppendLine("<div class=`"avviso`">Non riesco a leggere le pipeline di Azure DevOps ($(E $Errore)).</div>") }
    elseif ($null -ne $Build) {
        [void]$t.AppendLine('<div class="build-riepilogo">' +
            "<div class=`"dato`"><b>$($Build.InCorso)</b>in corso</div><div class=`"dato`"><b>$($Build.InCoda)</b>in coda</div>" +
            "<div class=`"dato attesa`"><b>$($Build.InAttesa)</b>in attesa di approvazione</div>" +
            "<div class=`"dato fallito`"><b>$($Build.NumFalliti)</b>falliti nelle ultime $($Build.Ore) ore</div></div>")
        foreach ($e in @($Build.Errori)) { [void]$t.AppendLine("<p class=`"meta`">Progetto non letto: $(E $e)</p>") }
        $orc = @(if ($Build.PSObject.Properties['Orchestratori']) { $Build.Orchestratori })
        $attivi = @($Build.Attivi); $falliti = @($Build.Falliti)
        $pool = @(if ($Build.PSObject.Properties['AgentiPool']) { $Build.AgentiPool })
        [void]$t.AppendLine((Format-AgentiPool $pool @(@($orc) + $attivi)))
        [void]$t.AppendLine((Format-FiltriBuild @(@($orc) + $attivi + $falliti)))
        [void]$t.AppendLine((Format-DaApprovare @(@($orc) + $attivi | Where-Object Stato -eq 'inAttesa' | Sort-Object Inizio) $Adesso))
        $progetti = @(@($orc) + $attivi + $falliti | ForEach-Object { [string]$_.Progetto } | Sort-Object -Unique)
        if ($progetti.Count -eq 0) { [void]$t.AppendLine('<p class="libero">nessun run in corso, in coda o fallito</p>') }
        $ordine = foreach ($p in $progetti) {
            $vivi = @(@($orc) + $attivi | Where-Object { $_.Progetto -eq $p -and $_.Stato -ne 'concluso' })
            [pscustomobject]@{ Nome = $p; Attese = @($vivi | Where-Object Stato -eq 'inAttesa').Count; Vivi = $vivi.Count
                Falliti = @($falliti | Where-Object Progetto -eq $p).Count }
        }
        foreach ($p in @($ordine | Sort-Object @{ e = 'Attese'; Descending = $true }, @{ e = 'Vivi'; Descending = $true }, @{ e = 'Falliti'; Descending = $true }, Nome)) {
            [void]$t.Append((Format-BloccoProgetto $p.Nome @($orc | Where-Object Progetto -eq $p.Nome) @($attivi | Where-Object Progetto -eq $p.Nome) @($falliti | Where-Object Progetto -eq $p.Nome) $Build.Ore $Adesso))
        }
    }
    else { [void]$t.AppendLine('<p class="libero">lettura in corso...</p>') }
    [void]$t.AppendLine('</section>')
    $t.ToString()
}

# Ogni nodo e una schedina: id e titolo, stato sulla board, e dove sta adesso la card (lo dice il modello, dalla kanban).
function Format-Catena($Catena) {
    $nodi = foreach ($n in @($Catena.Nodi)) {
        $stato = if ($n.StatoBoard) { "<span class=`"stato`">$(E $n.StatoBoard)</span>" } else { '' }
        $dove = if ($n.Dove) { "<span class=`"dove`">$(E $n.Dove)</span>" } else { '' }
        $numero = Format-CardLink $n
        $spunta = if ($n.Stato -eq 'unita') { '<span class="spunta" role="img" aria-label="unita">&#10003;</span> ' } else { '' }
        "<div data-id=`"$($n.Id)`" class=`"nodo stato-$($n.Stato)`"><b>$spunta$numero</b>$stato$dove</div>"
    }
    '<div class="catena">' + ($nodi -join '<span class="freccia">&rarr;</span>') + '</div>'
}

# D52: una funzionalita come una scheda: la Feature con il suo stato, la card di chiusura con il suo stato e dove sta, poi le altre card,
# ognuna con il suo stato sulla board e dove sta nella kanban (lo dice il modello, come per le catene).
# D60: la scheda ha la sua posizione nella priorita e dice se e in pausa; con il server (Token) si trascina e ha il pulsante pausa/riprendi.
# Una Feature senza card di chiusura (raggruppa soltanto) mostra solo le sue card.
function Format-Funzionalita($F, [string]$Token = '', [int]$Posizione = 0) {
    $dove = { param($V) if ($V.Dove) { "<span class=`"dove`">$(E $V.Dove)</span>" } else { '' } }
    $chiusura = $F.Chiusura
    $righe = foreach ($c in @($F.Card | Where-Object { -not $_.EChiusura })) {
        "<li data-id=`"$($c.Id)`">$(Format-CardLink $c) $(Format-StatoBoard $c)$(& $dove $c)</li>"
    }
    $pausa = [bool]$(if ($F.PSObject.Properties['Pausa']) { $F.Pausa } else { $false })
    $classe = if ($pausa) { 'funzionalita-voce in-pausa' } else { 'funzionalita-voce' }
    $trascina = if ($Token) { ' draggable="true"' } else { '' }
    $numero = if ($Posizione -gt 0) { "<span class=`"posizione`">$Posizione</span>" } else { '' }
    $segno = if ($pausa) { '<span class="pausa-segno">in pausa</span>' } else { '' }
    $pulsante = if ($Token) {
        $titolo = if ($pausa) { 'Riprendi: le card della Feature ripartono' } else { 'Metti in pausa: nessuna card della Feature avanza, le sessioni in corso finiscono' }
        "<button type=`"button`" class=`"pausa`" data-id=`"$($F.Feature)`" data-pausa=`"$(if ($pausa) { '1' } else { '0' })`" title=`"$titolo`" aria-label=`"$titolo`">$(if ($pausa) { '&#9654;' } else { '&#10074;&#10074;' })</button>"
    } else { '' }
    $feature = [pscustomobject]@{ Id = $F.Feature; UrlCard = $F.UrlCard; Titolo = $F.Titolo }
    $testaChiusura = if ($chiusura) { "<div class=`"chiusura`" data-id=`"$($chiusura.Id)`"><span class=`"campo`">Card di chiusura:</span> $(Format-CardLink $chiusura) $(Format-StatoBoard $chiusura)$(& $dove $chiusura)</div>" } else { '' }
    $elenco = if (@($righe).Count -gt 0) { "<ul>$(@($righe) -join '')</ul>" } else { '<span class="vuota">nessuna card aperta</span>' }
    "<div class=`"$classe`" data-feature=`"$($F.Feature)`"$trascina><h3>$numero<span>Feature $(Format-CardLink $feature) <span class=`"stato`">$(E $F.StatoFeature)</span></span>$segno$pulsante</h3>" +
        $testaChiusura + $elenco + '</div>'
}

# Oltre questo numero di lezioni stabili le sezioni per ruolo partono chiuse: sono lunghe e si aprono quando servono.
$script:SogliaStabiliAperte = 8

# Una lezione che si apre con un clic: la situazione e il titolo, il testo intero (e testo dell'agente: sempre E) sotto, con gli a capo.
# data-ricorda: lo script delle schede ricorda se e aperta, perche la pagina si ricarica da sola.
function Format-LezioneApribile($L, [string]$Tipo) {
    $testo = if ($L.PSObject.Properties['Testo']) { [string]$L.Testo } else { '' }
    '<details class="lezione" data-ricorda="' + $Tipo + '-' + (E $L.Id) + '"><summary>' + (E $L.Situazione) + '</summary><pre class="testo-lezione">' + (E $testo.TrimEnd()) + '</pre></details>'
}

# La sezione Apprendimento (D46): i blocchi, gli on-hold, le correzioni e le lezioni applicate per ruolo e per settimana, e le
# lezioni in prova che aspettano la conferma (la fusione della PR della memoria). $A e Apprendimento del modello: il riassunto
# (Righe, gia calcolato da Get-RiassuntoApprendimento) e le due letture con il loro esito. Il registro e le lezioni si leggono
# separate e una puo mancare senza l'altra: ognuna dice il suo errore. Lezioni $null = ancora non lette.
function Format-SezioneApprendimento($A) {
    $t = [System.Text.StringBuilder]::new()
    $righe = @($A.Righe)
    $sotto = @("Per ruolo e per settimana ISO (da lunedi), $(E $A.Finestra)")
    if ($A.PSObject.Properties['LetturaLezioni'] -and $A.LetturaLezioni) { $sotto += "lezioni in prova lette alle $(E (([datetime]$A.LetturaLezioni).ToString('HH:mm:ss')))" }
    [void]$t.AppendLine('<section class="apprendimento" data-sezione="apprendimento"><h2>Apprendimento</h2>')
    [void]$t.AppendLine("<p class=`"sotto`">$($sotto -join ' &middot; ')</p>")
    if ($A.ErroreRegistro) { [void]$t.AppendLine("<div class=`"avviso`">Non riesco a leggere il registro dell'apprendimento ($(E $A.ErroreRegistro)).</div>") }
    elseif ($righe.Count -eq 0) { [void]$t.AppendLine("<p class=`"libero`">nessun blocco, on-hold o correzione registrato nelle $(E $A.Finestra)</p>") }
    else {
        $corpo = foreach ($r in $righe) {
            '<tr data-ruolo="' + (E $r.Ruolo) + '" data-settimana="' + (E $r.Settimana) + '">' +
            (Format-Cella ((E $r.Settimana) + ' <span class="dove">dal ' + (E $r.Lunedi) + '</span>')) + (Format-Cella (E $r.Ruolo)) +
            (Format-Cella ([string][int]$r.Blocchi) 'num') + (Format-Cella ([string][int]$r.OnHold) 'num') +
            (Format-Cella ([string][int]$r.Correzioni) 'num') + (Format-Cella ([string][int]$r.LezioniApplicate) 'num') + '</tr>'
        }
        [void]$t.AppendLine((Format-Tabella @('Settimana', 'Ruolo', 'Blocchi', 'On-hold', 'Correzioni', 'Lezioni applicate') @($corpo)))
    }
    # Le lezioni che hanno evitato un blocco (la regola e in Get-RiassuntoApprendimento): "finora" perche una card ancora aperta puo cambiare il conto.
    $evitati = @($A.Evitati)
    if ($evitati.Count -gt 0) {
        $corpo = foreach ($e in $evitati) {
            '<tr data-evitata="' + (E $e.Lezione) + '">' + (Format-Cella ('<b>' + (E $e.Lezione) + '</b>')) + (Format-Cella (E $e.Ruolo)) +
            (Format-Cella ('card ' + ((@($e.Card) | ForEach-Object { [string][int]$_ }) -join ', '))) + '</tr>'
        }
        [void]$t.AppendLine("<h3>Lezioni che hanno evitato un blocco finora<span class=`"conta`">$($evitati.Count)</span></h3>")
        [void]$t.AppendLine((Format-Tabella @('Lezione', 'Ruolo', 'Applicata su') @($corpo)))
    }
    $lezioni = $A.Lezioni
    $conta = if ($null -ne $lezioni) { "<span class=`"conta`">$(@($lezioni).Count)</span>" } else { '' }
    [void]$t.AppendLine("<h3>Lezioni in prova in attesa di conferma$conta</h3>")
    if ($A.ErroreLezioni) { [void]$t.AppendLine("<div class=`"avviso`">Lezioni in prova non lette del tutto ($(E $A.ErroreLezioni)).</div>") }
    if ($null -eq $lezioni) { if (-not $A.ErroreLezioni) { [void]$t.AppendLine('<p class="libero">lettura in corso...</p>') } }
    elseif (@($lezioni).Count -eq 0) { [void]$t.AppendLine('<p class="libero">nessuna lezione in prova</p>') }
    else {
        $corpo = foreach ($l in @($lezioni)) {
            '<tr data-lezione="' + (E $l.Id) + '">' + (Format-Cella ('<b>' + (E $l.Id) + '</b>')) + (Format-Cella (E $l.Ruolo)) +
            (Format-Cella (E $l.Repo)) + (Format-Cella (Format-LezioneApribile $l 'lezione')) + '</tr>'
        }
        [void]$t.AppendLine((Format-Tabella @('Id', 'Ruolo', 'Repo', 'Situazione (clic per leggerla)') @($corpo)))
    }
    # Le lezioni stabili (gia confermate), una sezione per ruolo: aperta se in tutto sono poche, chiusa se tante (SogliaStabiliAperte).
    $stabili = $null; if ($A.PSObject.Properties['Stabili']) { $stabili = $A.Stabili }   # un if come espressione scarta l'array vuoto
    if ($null -ne $stabili) {
        $stabili = @($stabili)
        [void]$t.AppendLine("<h3>Lezioni stabili<span class=`"conta`">$($stabili.Count)</span></h3>")
        if ($stabili.Count -eq 0) { [void]$t.AppendLine('<p class="libero">nessuna lezione stabile</p>') }
        else {
            $aperte = if ($stabili.Count -le $script:SogliaStabiliAperte) { ' open' } else { '' }
            foreach ($g in @($stabili | Group-Object Ruolo | Sort-Object Name)) {
                $corpo = foreach ($l in $g.Group) {
                    '<tr data-stabile="' + (E $l.Id) + '">' + (Format-Cella ('<b>' + (E $l.Id) + '</b>')) + (Format-Cella (E $l.Repo)) +
                    (Format-Cella (Format-LezioneApribile $l 'stabile')) + '</tr>'
                }
                [void]$t.AppendLine('<details class="stabili" data-ruolo-stabili="' + (E $g.Name) + '" data-ricorda="stabili-' + (E $g.Name) + '"' + $aperte + '><summary><b>' + (E $g.Name) + '</b><span class="conta">' + $g.Count + '</span></summary>')
                [void]$t.AppendLine((Format-Tabella @('Id', 'Repo', 'Situazione (clic per leggerla)') @($corpo)))
                [void]$t.AppendLine('</details>')
            }
        }
    }
    [void]$t.AppendLine('</section>')
    $t.ToString()
}

# ---- la quota (D51) ---------------------------------------------------------------------------------------------
# Il modello ha Quota (Get-RiepilogoQuota in Decisioni.psm1, come oggetto) o niente: senza, la pagina non dice niente sulla quota.

function Get-DatiQuota($Modello) {
    if ($Modello.PSObject.Properties['Quota'] -and $null -ne $Modello.Quota) { $Modello.Quota } else { $null }
}
function Format-PercentoQuota($Frazione) { if ($null -eq $Frazione) { '?' } else { "$([math]::Round([double]$Frazione * 100))%" } }
function Format-QuandoQuota($Iso) {
    $d = ConvertTo-DataUtc $Iso
    if ($null -eq $d) { 'data non nota' } else { $d.ToLocalTime().ToString('dd/MM HH:mm') }
}

# La riga di testata, sempre: uso settimanale, soglia (e se e alzata, fino a quando), reset e bypass.
function Format-RigaQuota($Q) {
    $soglia = "soglia $(Format-PercentoQuota $Q.Soglia)"
    if ($Q.DaOverride) { $soglia += " (alzata fino al $(Format-QuandoQuota $Q.Reset))" }
    $ignora = if ($Q.IgnoraRiserva) { "riserva ignorata fino al $(Format-QuandoQuota $Q.Reset)" } else { 'riserva non ignorata' }
    $reset = if ($Q.Reset) { "reset $(Format-QuandoQuota $Q.Reset)" } else { 'reset non noto' }
    # un override che c'e ma non vale (scaduto, illeggibile, fuori range) non deve restare invisibile: la soglia e quella di limiti.json
    $ignorato = if ($Q.Override -in 'scaduto', 'illeggibile', 'fuoriRange') { " &middot; override ignorato: $(E $Q.Override)" } else { '' }
    $riga5 = ''
    # D60: la finestra di 5 ore, con la sua soglia (alzata o no) e il suo reset; un modello senza il campo non la ha
    if ($Q.PSObject.Properties['Soglia5Ore']) {
        $soglia5 = "soglia $(Format-PercentoQuota $Q.Soglia5Ore)"
        if ($Q.DaOverride5Ore) { $soglia5 += " (alzata fino alle $(Format-QuandoQuota $Q.Reset5Ore))" }
        $reset5 = if ($Q.Reset5Ore) { "reset $(Format-QuandoQuota $Q.Reset5Ore)" } else { 'reset non noto' }
        $riga5 = "<p class=`"quota-riga`">Quota 5 ore: <b>$(E (Format-PercentoQuota $Q.Uso5Ore))</b> usata &middot; $(E $soglia5) &middot; $(E $reset5)</p>"
    }
    "<p class=`"quota-riga`">Quota settimanale: <b>$(E (Format-PercentoQuota $Q.Uso))</b> usata &middot; $(E $soglia) &middot; $(E $reset) &middot; $(E $ignora)$ignorato</p>$riga5"
}

# I comandi, solo con il server (Token): alzare la soglia (in %, max 95), ignorare la riserva, ripristinare. Parlano con POST /soglia.
function Format-ComandiQuota($Q, [string]$Token) {
    $t = E $Token
    $valore = [math]::Round([double]$Q.Soglia * 100)
    $minimo = [math]::Round([double]$Q.SogliaMin * 100); $massimo = [math]::Round([double]$Q.SogliaMax * 100)
    $spunta = if ($Q.IgnoraRiserva) { ' checked' } else { '' }
    "<span class=`"quota-comandi`"><label for=`"quota-soglia`">Soglia %</label><input type=`"number`" id=`"quota-soglia`" min=`"$minimo`" max=`"$massimo`" step=`"1`" value=`"$valore`">" +
        "<button type=`"button`" id=`"quota-applica`" data-token=`"$t`">Applica</button>" +
        "<input type=`"checkbox`" id=`"quota-ignora`" data-token=`"$t`"$spunta><label for=`"quota-ignora`">Ignora la riserva fino al reset</label>" +
        "<button type=`"button`" id=`"quota-ripristina`" data-token=`"$t`">Ripristina</button>" + (Format-ComandiQuota5Ore $Q $t) + "<span class=`"esito-ado`" role=`"status`"></span></span>"
}

# D60: il campo e il pulsante della soglia delle 5 ore, solo con un reset della finestra noto e futuro. $T e il token gia escapato.
function Format-ComandiQuota5Ore($Q, [string]$T) {
    if (-not $Q.PSObject.Properties['PuoImpostare5Ore'] -or -not $Q.PuoImpostare5Ore) { return '' }
    $valore = [math]::Round([double]$Q.Soglia5Ore * 100)
    $minimo = [math]::Round([double]$Q.SogliaMin * 100); $massimo = [math]::Round([double]$Q.SogliaMax * 100)
    "<label for=`"quota-soglia-5`">Soglia 5 ore %</label><input type=`"number`" id=`"quota-soglia-5`" min=`"$minimo`" max=`"$massimo`" step=`"1`" value=`"$valore`">" +
        "<button type=`"button`" id=`"quota-applica-5`" data-token=`"$T`">Applica</button>"
}

# Il banner a tutta larghezza in cima, solo quando gli agenti sono fermi per la quota (Blocco), col colore suo e i comandi accanto.
function Format-BannerQuota($Q, [string]$Token) {
    $b = $Q.Blocco
    $fino = Format-QuandoQuota $b.Fino
    $causa = if ($b.Causa -eq 'limite') { "Gli agenti sono fermi: limite di token raggiunto, riprendono il $fino." }
             elseif ($b.Causa -eq 'cinqueOre') { "Gli agenti sono fermi: soglia delle 5 ore. L'uso e al $(Format-PercentoQuota $b.Uso), la soglia e $(Format-PercentoQuota $b.Soglia): ripartono al reset della finestra, il $fino." }
             else { "Gli agenti sono fermi: riserva settimanale. L'uso e al $(Format-PercentoQuota $b.Uso), la soglia e $(Format-PercentoQuota $b.Soglia): ripartono al reset, il $fino." }
    $dettaglio = if ($b.Causa -eq 'limite') { "Uso settimanale $(Format-PercentoQuota $Q.Uso), soglia $(Format-PercentoQuota $Q.Soglia). La pausa dopo il limite di token non si salta: le sessioni fallirebbero." } else { '' }
    $comandi = if ($Token -and $Q.PuoImpostare) { Format-ComandiQuota $Q $Token } else { '' }
    "<div class=`"banner-quota`" role=`"alert`" data-causa=`"$(E $b.Causa)`"><div class=`"banner-testo`"><b>$(E $causa)</b>$(if ($dettaglio) { ' ' + (E $dettaglio) })</div>$comandi</div>"
}

# ---- la suite (D53) ----------------------------------------------------------------------------------------------
# Il modello ha Suite (ConvertTo-ModelloSuite in VistaSuite.psm1) o niente: senza, la pagina non dice niente della suite. Lo stato lo scrive il
# supervisore; qui solo il disegno. I comandi (Aggiorna adesso, interruttore) ci sono solo con il server (Token).

# La Suite compatta, per la testata: chiusa dice versione installata e stato (in rosso se chiede qualcosa a una persona) e, se c'e,
# la versione nuova; aperta mostra il riquadro intero, comandi compresi. Ricorda se e aperta (details[data-ricorda], come gli altri).
function Format-SuiteCompatta($S, [string]$Token) {
    $installata = if ($S.Installata) { E $S.Installata } else { 'non letta' }
    $classe = if ($S.Allarme) { 'suite-pillola allarme' } else { 'suite-pillola' }
    $nuova = if ($S.Disponibile) { " &middot; nuova: <b>$(E $S.Disponibile)</b>" } else { '' }
    "<details class=`"suite-compatta`" data-ricorda=`"suite`"><summary><span class=`"suite-nome`">Suite</span> <b>$installata</b> &middot; <span class=`"$classe`">$(E $S.Stato)</span>$nuova</summary>`n" +
        (Format-SezioneSuite $S $Token) + '</details>'
}

function Format-SezioneSuite($S, [string]$Token) {
    $t = [System.Text.StringBuilder]::new()
    [void]$t.AppendLine('<section class="suite" data-sezione="suite"><h2>Suite</h2>')
    $disp = if ($S.Disponibile) { E $S.Disponibile } else { 'nessuna: sei all&#39;ultima versione' }
    [void]$t.AppendLine("<p>Installata: <b>$(E $S.Installata)</b> &middot; Disponibile: <b>$disp</b> &middot; Ultimo controllo: <b>$(E $S.UltimoControllo)</b></p>")
    $classe = if ($S.Allarme) { 'suite-stato allarme' } else { 'suite-stato' }
    [void]$t.AppendLine("<p class=`"$classe`">Stato: $(E $S.Stato)</p>")
    if ($S.ErroreControllo) { [void]$t.AppendLine("<p class=`"suite-stato allarme`">Il controllo di origin non e riuscito: $(E $S.ErroreControllo)</p>") }
    if (@($S.Pr).Count -gt 0) {
        [void]$t.AppendLine("<p>PR in arrivo ($(@($S.Pr).Count)):</p><ul class=`"suite-pr`">")
        foreach ($p in @($S.Pr)) {
            $voce = "PR $([int]$p.Numero)"
            $link = if ("$($p.Url)" -match '^https?://') { "<a href=`"$(E $p.Url)`" target=`"_blank`" rel=`"noopener`">$voce</a>" } else { $voce }
            [void]$t.AppendLine("<li>${link}: $(E $p.Titolo)</li>")
        }
        [void]$t.AppendLine('</ul>')
    }
    if ($Token) {
        $k = E $Token
        $spunta = if ($S.Automatico) { ' checked' } else { '' }
        [void]$t.AppendLine("<p class=`"giro`"><button type=`"button`" id=`"suite-aggiorna`" data-token=`"$k`">Aggiorna adesso</button>" +
            "<input type=`"checkbox`" id=`"suite-automatico`" data-token=`"$k`"$spunta><label for=`"suite-automatico`">Aggiornamento automatico</label><span class=`"esito-ado`" role=`"status`"></span></p>")
    }
    else { [void]$t.AppendLine("<p>Aggiornamento automatico: <b>$(if ($S.Automatico) { 'acceso' } else { 'spento' })</b></p>") }
    [void]$t.AppendLine('</section>')
    $t.ToString()
}

# Il modello e quello di Get-ModelloVista; $Secondi e l'intervallo di ricaricamento. Con $Token (la vista servita da
# VistaServer.psm1) la testata ha i pulsanti "Avvia smistatore" e "Aggiorna agenti e card", che fanno POST con il token in un
# header, e la pagina la ricarica lo script (il meta refresh resta in <noscript>); senza, niente pulsanti e ricarica il meta
# refresh. I due contatori ci sono sempre.
function New-PaginaVista($Modello, [int]$Secondi = 10, [string]$Token = '') {
    $script:PaginaConServer = [bool]$Token; $script:TokenPagina = $Token
    $h = [System.Text.StringBuilder]::new()
    [void]$h.AppendLine('<!DOCTYPE html>')
    [void]$h.AppendLine('<html lang="it">')
    [void]$h.AppendLine('<head>')
    [void]$h.AppendLine('<meta charset="utf-8">')
    [void]$h.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    $meta = "<meta http-equiv=`"refresh`" content=`"$Secondi`">"
    [void]$h.AppendLine($(if ($Token) { "<noscript>$meta</noscript>" } else { $meta }))
    [void]$h.AppendLine('<title>Agenti</title>')
    [void]$h.AppendLine('<style>' + $script:Css + '</style>')
    [void]$h.AppendLine('</head>')
    [void]$h.AppendLine('<body>')
    $ricarica = if ($Token) { ' data-ricarica="script"' } else { '' }
    # La testata, prima di <main> e visibile da ogni scheda: in alto a destra la Suite (D53), compatta. Senza schede (pipeline non ancora
    # lette) anche il link per aprire l'ufficio, che con le schede sta nella sua scheda.
    $conSuite = $Modello.PSObject.Properties['Suite'] -and $null -ne $Modello.Suite
    $conSchedeTestata = ($Modello.PSObject.Properties['BuildAdo'] -and $null -ne $Modello.BuildAdo) -or ($Modello.PSObject.Properties['ErroreBuild'] -and [string]$Modello.ErroreBuild)
    if ($conSuite -or -not $conSchedeTestata) {
        [void]$h.AppendLine('<div class="testata">')
        if ($conSuite) { [void]$h.AppendLine((Format-SuiteCompatta $Modello.Suite $Token)) }
        if (-not $conSchedeTestata) { [void]$h.AppendLine('<a href="ufficio.html" target="_blank" rel="noopener" title="Apre l&#39;ufficio degli agenti in una scheda a parte">Apri l&#39;ufficio</a>') }
        [void]$h.AppendLine('</div>')
    }
    [void]$h.AppendLine("<main data-generata=`"$(E $Modello.Generata.ToString('o'))`"$ricarica>")
    $quota = Get-DatiQuota $Modello
    if ($quota -and $quota.Blocco) { [void]$h.AppendLine((Format-BannerQuota $quota $Token)) }
    # D60: il sistema in pausa si vede subito, sopra tutto
    if ($Modello.PSObject.Properties['SistemaInPausa'] -and $Modello.SistemaInPausa) { [void]$h.AppendLine('<div class="banner-pausa" role="status">Sistema in pausa: lo smistatore chiude le sessioni che finiscono, ma non lancia niente e non sposta card.</div>') }
    # Due schede: Agenti (kanban e catene) e Pipeline (i run di tutti i progetti). Senza lettura delle pipeline niente schede.
    # Senza JavaScript i due pannelli si vedono uno sotto l'altro; con lo script se ne vede uno, ricordato in sessionStorage.
    $build = if ($Modello.PSObject.Properties['BuildAdo']) { $Modello.BuildAdo } else { $null }
    $erroreBuild = if ($Modello.PSObject.Properties['ErroreBuild']) { [string]$Modello.ErroreBuild } else { '' }
    $urlPr = if ($Modello.PSObject.Properties['UrlPullRequest']) { [string]$Modello.UrlPullRequest } else { '' }
    $conSchede = $null -ne $build -or $erroreBuild
    if ($conSchede) {
        $contaP = ''
        if ($erroreBuild) { $contaP = '<span class="conta allarme" title="lettura fallita">!</span>' }
        elseif ($build.InAttesa -gt 0) { $contaP = "<span class=`"conta attenzione`" title=`"in attesa di approvazione`">$($build.InAttesa)</span>" }
        # Il contatore dell'Apprendimento: le lezioni in prova che aspettano la conferma (nessuna, o non ancora lette: niente contatore).
        $contaA = ''
        $appr = if ($Modello.PSObject.Properties['Apprendimento']) { $Modello.Apprendimento } else { $null }
        if ($null -ne $appr -and $null -ne $appr.Lezioni -and @($appr.Lezioni).Count -gt 0) { $contaA = "<span class=`"conta attenzione`" title=`"lezioni in prova in attesa di conferma`">$(@($appr.Lezioni).Count)</span>" }
        [void]$h.AppendLine('<div class="schede" role="tablist"><button type="button" role="tab" data-scheda="agenti" aria-selected="true">Agenti</button>' +
            "<button type=`"button`" role=`"tab`" data-scheda=`"pipeline`" aria-selected=`"false`">Pipeline$contaP</button>" +
            "<button type=`"button`" role=`"tab`" data-scheda=`"apprendimento`" aria-selected=`"false`">Apprendimento$contaA</button>" +
            '<button type="button" role="tab" data-scheda="ufficio" aria-selected="false">Ufficio</button>' +
            '<span class="disposizione" role="group" aria-label="Disposizione"><button type="button" data-disposizione="schede" aria-pressed="true" title="una scheda alla volta">Schede</button>' +
            '<button type="button" data-disposizione="affiancate" aria-pressed="false" title="Agenti e Pipeline uno accanto all&#39;altro (l&#39;Apprendimento sotto)">Affiancate</button>' +
            '<button type="button" data-disposizione="colonna" aria-pressed="false" title="Agenti sopra, Pipeline sotto (e l&#39;Apprendimento)">In colonna</button></span></div>')
        [void]$h.AppendLine('<div class="pannelli" data-disposizione="schede">')
    }
    [void]$h.AppendLine('<div data-pannello="agenti" role="tabpanel">')
    [void]$h.AppendLine('<h1>Agenti</h1>')
    $sotto = "Generata alle $(E $Modello.Generata.ToString('yyyy-MM-dd HH:mm:ss')) &middot; Ultimo giro dello smistatore $(E $Modello.UltimoGiro) &middot; prossimo $(E $Modello.ProssimoGiro)"
    [void]$h.AppendLine("<p class=`"sotto`">$sotto</p>")
    $iso = if ($Modello.PSObject.Properties['ProssimoGiroIso']) { [string]$Modello.ProssimoGiroIso } else { '' }
    [void]$h.AppendLine("<p class=`"contatori`">Pagina: si ricarica fra <b id=`"conta-pagina`" data-secondi=`"$Secondi`">$Secondi s</b> &middot; Smistatore: parte fra <b id=`"conta-smistatore`" data-quando=`"$(E $iso)`">&hellip;</b></p>")
    if ($quota) {
        [void]$h.AppendLine((Format-RigaQuota $quota))
        if ($Token -and $quota.PuoImpostare -and -not $quota.Blocco) { [void]$h.AppendLine("<p class=`"giro`">$(Format-ComandiQuota $quota $Token)</p>") }
    }
    if ($Token) {
        $t = E $Token
        $inPausa = $Modello.PSObject.Properties['SistemaInPausa'] -and $Modello.SistemaInPausa
        $tastoPausa = "<button type=`"button`" id=`"pausa-sistema`" data-token=`"$t`" data-pausa=`"$(if ($inPausa) { '1' } else { '0' })`">$(if ($inPausa) { '&#9654; Riprendi il sistema' } else { '&#10074;&#10074; Metti in pausa il sistema' })</button>"
        [void]$h.AppendLine("<p class=`"giro`">$tastoPausa<button type=`"button`" id=`"giro`" data-token=`"$t`">Avvia smistatore</button><button type=`"button`" id=`"aggiorna`" data-token=`"$t`">Aggiorna agenti e card</button><span id=`"giro-esito`" class=`"esito-ado`" role=`"status`"></span></p>")
    }

    # D53: il riquadro Suite sta nella testata (Format-SuiteCompatta), visibile da ogni scheda

    if ($Modello.ErroreAdo) {
        [void]$h.AppendLine("<div class=`"avviso`">Azure DevOps non risponde ($(E $Modello.ErroreAdo)): le card in coda e da fare non si vedono, resta la parte locale.</div>")
    }

    if (-not $Modello.ErroreAdo -and @($Modello.Catene).Count -gt 0) {
        # in cima, sopra la kanban, chiuso di default: se l'utente lo apre lo ricorda sessionStorage (ogni accesso e protetto)
        [void]$h.AppendLine("<details class=`"catene`"><summary>Catene delle card<span class=`"pillola`">$(@($Modello.Catene).Count)</span><span class=`"nota`">le card che aspettano altre card: clic per aprire</span></summary><div class=`"catene-lista`">")
        foreach ($c in @($Modello.Catene)) { [void]$h.AppendLine((Format-Catena $c)) }
        [void]$h.AppendLine('</div><ul class="legenda"><li><span class="campione stato-unita"></span><span>unita: il suo lavoro e in develop</span></li><li><span class="campione stato-lavorazione"></span><span>in lavorazione: ha un ramo che avanza o una sessione</span></li><li><span class="campione stato-coda"></span><span>in coda: non e ancora partita</span></li></ul></details>')
        [void]$h.AppendLine('<script>')
        [void]$h.AppendLine("(function () { var d = document.querySelector('details.catene'); if (!d) return;")
        [void]$h.AppendLine("  try { if (sessionStorage.getItem('catene-aperte') === '1') d.open = true; } catch (e) {}")
        [void]$h.AppendLine("  d.addEventListener('toggle', function () { try { sessionStorage.setItem('catene-aperte', d.open ? '1' : '0'); } catch (e) {} });")
        [void]$h.AppendLine('})();')
        [void]$h.AppendLine('</script>')
    }
    # D52: le funzionalita, aperte di default (poche) ma comprimibili con un clic, e fuori dai details delle catene; lo script delle schede ricorda se sono aperte. Un modello senza il campo non le ha.
    if (-not $Modello.ErroreAdo -and $Modello.PSObject.Properties['Funzionalita'] -and @($Modello.Funzionalita).Count -gt 0) {
        $nota = if ($Token) { 'in ordine di priorita: trascina una scheda per spostarla, il pulsante la mette in pausa' } else { 'in ordine di priorita (l ordine del backlog in Azure DevOps)' }
        [void]$h.AppendLine("<details class=`"funzionalita`" data-ricorda=`"funzionalita`" open><summary><h2>Funzionalita<span class=`"pillola`">$(@($Modello.Funzionalita).Count)</span><span class=`"nota`">$nota</span></h2></summary><span id=`"funzionalita-esito`" class=`"esito-ado`" role=`"status`" data-token=`"$(E $Token)`"></span><div class=`"funzionalita-lista`">")
        $posizione = 0
        foreach ($f in @($Modello.Funzionalita)) { $posizione++; [void]$h.AppendLine((Format-Funzionalita $f $Token $posizione)) }
        [void]$h.AppendLine('</div></details>')
    }
    # La pagina disegna solo le colonne che ha: senza Azure DevOps restano gli agenti (e la pipeline se ha qualcosa).
    $conOperatore = -not $Modello.ErroreAdo
    $conPipeline = (-not $Modello.ErroreAdo) -or @($Modello.Pipeline).Count -gt 0
    $conSupervisore = $Modello.PSObject.Properties['Supervisore'] -and $null -ne $Modello.Supervisore
    $tracce = @('minmax(150px,1fr)') * (@($Modello.Agenti).Count + [int]$conSupervisore)
    if ($conOperatore) { $tracce += 'minmax(190px,1.2fr)' }
    if ($conPipeline) { $tracce += 'minmax(170px,0.8fr)' }
    [void]$h.AppendLine("<div class=`"kanban`" style=`"grid-template-columns:$($tracce -join ' ')`">")
    foreach ($a in @($Modello.Agenti)) { [void]$h.Append((Format-ColonnaAgente $a)) }
    if ($conSupervisore) { [void]$h.Append((Format-ColonnaSupervisore $Modello.Supervisore)) }
    if ($conOperatore) { [void]$h.Append((Format-ColonnaOperatore $Modello.Operatore)) }
    if ($conPipeline) { [void]$h.Append((Format-ColonnaPipeline $Modello.Pipeline)) }
    [void]$h.AppendLine('</div>')

    # Con le schede l'Apprendimento ha la sua (piu sotto). Senza schede (niente lettura delle pipeline) non ha un posto suo e resta
    # in fondo al pannello degli agenti, sotto la kanban. Un modello senza Apprendimento (o con $null) non ha la sezione.
    if (-not $conSchede -and $Modello.PSObject.Properties['Apprendimento'] -and $null -ne $Modello.Apprendimento) { [void]$h.Append((Format-SezioneApprendimento $Modello.Apprendimento)) }
    [void]$h.AppendLine('</div>')
    if ($conSchede) {
        [void]$h.AppendLine('<div class="divisore" role="separator" tabindex="0" data-divisore="agenti" aria-label="Allarga o stringi i pannelli" title="Trascina per allargare o stringere; doppio clic per tornare com&#39;era"></div>')
        [void]$h.AppendLine('<div data-pannello="pipeline" role="tabpanel">')
        $lettura = if ($Modello.PSObject.Properties['LetturaBuild'] -and $Modello.LetturaBuild) { ([datetime]$Modello.LetturaBuild).ToString('HH:mm:ss') } else { '' }
        $ogni = if ($Modello.PSObject.Properties['SecondiAdo']) { [int]$Modello.SecondiAdo } else { 0 }
        [void]$h.Append((Format-SezioneBuild $build $erroreBuild $Modello.Generata $urlPr $lettura $ogni $Token))
        [void]$h.AppendLine('</div>')
        # Il secondo divisore, fra Pipeline e Apprendimento: serve solo affiancate (in colonna i pannelli sono impilati e il CSS lo nasconde).
        [void]$h.AppendLine('<div class="divisore secondo" role="separator" tabindex="0" data-divisore="pipeline" aria-label="Allarga o stringi Pipeline e Apprendimento" title="Trascina per allargare o stringere; doppio clic per tornare com&#39;era"></div>')
        # La terza scheda e un pannello come gli altri, dentro .pannelli: affiancate sta nella terza colonna, in colonna sotto la Pipeline.
        # Senza dati (modello senza Apprendimento, lettura non ancora fatta) il posto c'e lo stesso e lo dice.
        [void]$h.AppendLine('<div data-pannello="apprendimento" role="tabpanel">')
        if ($null -ne $appr) { [void]$h.Append((Format-SezioneApprendimento $appr)) }
        else { [void]$h.AppendLine('<h2>Apprendimento</h2><p class="libero" data-sezione="apprendimento-vuota">nessun dato: la lettura dell''apprendimento non e ancora stata fatta</p>') }
        [void]$h.AppendLine('</div>')
        # La scheda Ufficio (VistaUfficioPannello.psm1): un pannello come gli altri, che solo lei puo agganciare sopra o sotto le altre schede.
        # Il terzo divisore, fra il pannello che precede e l'Ufficio: affiancate lo allarga o lo stringe come gli altri (in colonna non serve).
        [void]$h.AppendLine('<div class="divisore terzo" role="separator" tabindex="0" data-divisore="ufficio" aria-label="Allarga o stringi l&#39;Ufficio" title="Trascina per allargare o stringere; doppio clic per tornare com&#39;era"></div>')
        [void]$h.AppendLine((Get-SchedaUfficio))
        [void]$h.AppendLine('</div>')
        [void]$h.AppendLine($script:ScriptSchede)
        [void]$h.AppendLine((Get-ScriptUfficio))
    }
    [void]$h.AppendLine($script:ScriptContatori)
    if ($Token) { [void]$h.AppendLine($script:ScriptGiro) }
    [void]$h.AppendLine('</main>')
    [void]$h.AppendLine('</body>')
    [void]$h.AppendLine('</html>')
    $h.ToString()
}

# ---- la pagina di una sessione -----------------------------------------------------------------------------------

$script:CssSessione = @'
.ev { background: var(--superficie); border: 1px solid var(--bordo); border-left: 4px solid var(--grigio); border-radius: 8px; padding: 7px 10px; margin: 6px 0; overflow-wrap: anywhere; }
.ev pre { margin: 4px 0 0; white-space: pre-wrap; overflow-wrap: anywhere; font: 13px/1.5 ui-monospace, "Cascadia Mono", Consolas, monospace; }
.ev.testo { border-left-color: var(--accento); }
.ev.testo pre { font: inherit; }
.ev.strumento { border-left-color: var(--ambra); }
.ev.risultato { border-left-color: var(--grigio); background: var(--codice-sfondo); color: var(--attenuato); }
.ev.esito { border-left-color: var(--verde); }
.ev.errore { border-left-color: var(--rosso); }
.ev .taglio { display: block; margin-top: 4px; font-size: 12px; font-style: italic; color: var(--attenuato); }
.ev .tipo { font-size: 12px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--attenuato); }
.ripresa { margin: 14px 0 6px; padding-top: 6px; border-top: 2px dashed var(--bordo); font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--attenuato); }
'@

function Format-EventoSessione($Ev) {
    if ($Ev.Tipo -eq 'ripresa') { return "<div class=`"ripresa`">$(E $Ev.Testo)</div>" }
    $errore = if ($Ev.Errore) { ' errore' } else { '' }
    $taglio = if ($Ev.Tagliato) { "<span class=`"taglio`">$(if ($Ev.Tipo -eq 'strumento') { 'parametri tagliati' } else { 'risultato tagliato' }): il resto non si vede qui</span>" } else { '' }
    switch ($Ev.Tipo) {
        'strumento' { return "<div class=`"ev strumento$errore`"><span class=`"tipo`">strumento</span> <b>$(E $Ev.Nome)</b><pre>$(E $Ev.Testo)</pre>$taglio</div>" }
        'risultato' { return "<div class=`"ev risultato$errore`"><span class=`"tipo`">risultato</span><pre>$(E $Ev.Testo)</pre>$taglio</div>" }
        'esito' { return "<div class=`"ev esito$errore`"><span class=`"tipo`">esito</span><pre>$(E $Ev.Testo)</pre></div>" }
        default { return "<div class=`"ev testo`"><pre>$(E $Ev.Testo)</pre></div>" }
    }
}

# La pagina dello stream di una sessione: in cima i dati della scheda (dal modello), poi gli eventi dal piu vecchio al piu
# recente (Get-EventiSessione). Si apre scorsa in fondo, dove arrivano i nuovi; se chi legge e risalito, la ricarica lo lascia
# dov'e (sessionStorage, ogni accesso in try/catch: senza storage la pagina funziona uguale, scorsa in fondo).
function New-PaginaSessione($Sessione, $Eventi, [int]$Saltati = 0, [bool]$Finita = $false, [int]$Secondi = 10) {
    $S = $Sessione
    $h = [System.Text.StringBuilder]::new()
    [void]$h.AppendLine('<!DOCTYPE html>')
    [void]$h.AppendLine('<html lang="it">')
    [void]$h.AppendLine('<head>')
    [void]$h.AppendLine('<meta charset="utf-8">')
    [void]$h.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$h.AppendLine("<meta http-equiv=`"refresh`" content=`"$Secondi`">")
    [void]$h.AppendLine("<title>Sessione #$($S.Id)</title>")
    [void]$h.AppendLine('<style>' + $script:Css + $script:CssSessione + '</style>')
    [void]$h.AppendLine('</head>')
    [void]$h.AppendLine('<body>')
    [void]$h.AppendLine('<main>')
    [void]$h.AppendLine("<h1>$(Format-CardLink $S)</h1>")
    if ($Finita) { [void]$h.AppendLine('<div class="avviso">sessione finita</div>') }
    $chip = @()
    if ($S.Repo) { $chip += "<span class=`"chip`">$(E $S.Repo)</span>" }
    if ($S.Ruolo) { $chip += "<span class=`"chip`">$(E $S.Ruolo)</span>" }
    if ($chip) { [void]$h.AppendLine('<div>' + ($chip -join '') + '</div>') }
    if ($S.Task) {
        $tt = if ($S.TitoloTask) { " $(E $S.TitoloTask)" } else { '' }
        [void]$h.AppendLine("<div class=`"meta`">task <b>$(E $S.Task)</b>$tt</div>")
    }
    $parti = @()
    if ($null -ne $S.Minuti) { $parti += "$($S.Minuti) min" }
    if ($S.TokenTesto) { $parti += (E $S.TokenTesto) }
    if ($parti) { [void]$h.AppendLine('<div class="meta">' + ($parti -join ' &middot; ') + '</div>') }
    [void]$h.AppendLine('<h2>Stream</h2>')
    if ($Saltati -gt 0) { [void]$h.AppendLine("<p class=`"sotto`">$Saltati eventi precedenti non mostrati</p>") }
    if (@($Eventi).Count -eq 0) { [void]$h.AppendLine('<p class="vuoto">nessun evento ancora</p>') }
    foreach ($ev in @($Eventi)) { [void]$h.AppendLine((Format-EventoSessione $ev)) }
    [void]$h.AppendLine('</main>')
    [void]$h.AppendLine('<script>')
    [void]$h.AppendLine("(function () { var k = 'scorri:' + location.pathname, v = null;")
    [void]$h.AppendLine("  try { history.scrollRestoration = 'manual'; v = sessionStorage.getItem(k); } catch (e) {}")
    [void]$h.AppendLine("  var fondo = function () { return window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 40; };")
    [void]$h.AppendLine("  window.scrollTo(0, (v === null || v === 'fondo') ? document.documentElement.scrollHeight : (parseInt(v, 10) || 0));")
    [void]$h.AppendLine("  window.addEventListener('scroll', function () { try { sessionStorage.setItem(k, fondo() ? 'fondo' : String(window.scrollY)); } catch (e) {} });")
    [void]$h.AppendLine('})();')
    [void]$h.AppendLine('</script>')
    [void]$h.AppendLine('</body>')
    [void]$h.AppendLine('</html>')
    $h.ToString()
}


# ---- la pagina del brief di un ruolo -----------------------------------------------------------------------------

$script:CssBrief = @'
main.brief { max-width: 760px; }
main.brief .testo { font-size: 15px; line-height: 1.65; overflow-wrap: anywhere; }
main.brief .testo h1, main.brief .testo h2, main.brief .testo h3 { text-transform: none; letter-spacing: 0; color: var(--testo); }
main.brief .testo h1 { font-size: 24px; }
main.brief .testo h2 { font-size: 19px; margin-top: 28px; }
main.brief .testo h3 { font-size: 16px; }
main.brief .testo pre { padding: 10px 12px; border-radius: 8px; background: var(--codice-sfondo); overflow-x: auto; }
main.brief .testo code { font: 13px ui-monospace, "Cascadia Mono", Consolas, monospace; background: var(--codice-sfondo); padding: 1px 4px; border-radius: 4px; }
main.brief .testo pre code { padding: 0; background: none; }
main.brief .testo table { border-collapse: collapse; }
main.brief .testo th, main.brief .testo td { border: 1px solid var(--bordo); padding: 4px 8px; }
main.brief .testo a { color: var(--accento); }
'@

# Il titolo da mostrare di un ruolo.
function Get-TitoloRuolo([string]$Ruolo) { if ($script:TitoliRuoli.ContainsKey($Ruolo)) { $script:TitoliRuoli[$Ruolo] } else { $Ruolo } }

# Il brief di un ruolo, da leggere. Titolo e percorso passano da E; $HtmlMarkdown e l'HTML gia convertito (ConvertFrom-Markdown)
# da un file del repo: non si mescola con dati di Azure DevOps. Niente ricaricamento: e un testo, non uno stato.
function New-PaginaBrief([string]$Titolo, [string]$Percorso, [string]$HtmlMarkdown) {
    $h = [System.Text.StringBuilder]::new()
    [void]$h.AppendLine('<!DOCTYPE html>')
    [void]$h.AppendLine('<html lang="it">')
    [void]$h.AppendLine('<head>')
    [void]$h.AppendLine('<meta charset="utf-8">')
    [void]$h.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$h.AppendLine("<title>Brief: $(E $Titolo)</title>")
    [void]$h.AppendLine('<style>' + $script:Css + $script:CssBrief + '</style>')
    [void]$h.AppendLine('</head>')
    [void]$h.AppendLine('<body>')
    [void]$h.AppendLine('<main class="brief">')
    [void]$h.AppendLine("<p class=`"sotto`"><b>$(E $Titolo)</b> &middot; <code>$(E $Percorso)</code></p>")
    [void]$h.AppendLine('<div class="testo">')
    [void]$h.AppendLine($HtmlMarkdown)
    [void]$h.AppendLine('</div>')
    [void]$h.AppendLine('</main>')
    [void]$h.AppendLine('</body>')
    [void]$h.AppendLine('</html>')
    $h.ToString()
}

Export-ModuleMember -Function New-PaginaVista, New-PaginaSessione, New-PaginaBrief, Get-TitoloRuolo
