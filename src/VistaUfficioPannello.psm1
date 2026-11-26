#requires -Version 7
# La scheda Ufficio della vista: una scheda come Agenti, Pipeline e Apprendimento (con "Affiancate" e "In colonna" sta con le altre), che
# incorpora la pagina dell'ufficio che c'e gia (ufficio.html?compatto=1, stessi dati, stesso codice del gioco) e porta dentro il comando
# per aprirla a parte, a grandezza piena. Solo lei si puo agganciare sopra o sotto le altre schede: cosi si guarda l'ufficio mentre si
# lavora in un'altra scheda. Agganciata esce dalle schede (data-fuori) e lo script delle schede (VistaHtml) la lascia stare; il suo
# pulsante allora la mostra o la nasconde. Aggancio, apertura e altezza si ricordano (localStorage).
#
# Il gioco si carica solo quando la scheda si vede (l'iframe non ha src finche non serve) e si scarica quando non si vede: niente ciclo
# di gioco nascosto. La vista si ricarica da sola ogni pochi secondi: il gioco riprende da dove stava (lo stato lo salva lui).
# Il markup e sempre lo stesso, senza dati: il dato lo legge il gioco da ufficio.json.
Set-StrictMode -Version Latest

$script:StileUfficio = @'
<style>
[data-pannello="ufficio"] { position: relative; display: flex; flex-direction: column; height: calc(100vh - 150px); min-height: 320px; border: 1px solid var(--bordo, #c8ccd4); border-radius: 8px; overflow: hidden; background: #1b1a26; }
[data-pannello="ufficio"][hidden] { display: none; }
.pannelli[data-disposizione="colonna"] > [data-pannello="ufficio"] { height: 70vh; margin-top: 28px; }
[data-pannello="ufficio"] .testa { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; padding: 5px 10px; background: var(--superficie, #fff); color: var(--testo, #1d2430); border-bottom: 1px solid var(--bordo, #c8ccd4); }
[data-pannello="ufficio"] .aggancio { display: flex; gap: 4px; align-items: center; margin-right: auto; font-size: 13px; color: var(--attenuato, #667085); }
[data-pannello="ufficio"] .testa button, [data-pannello="ufficio"] .testa a { padding: 3px 10px; border: 1px solid var(--bordo, #c8ccd4); border-radius: 8px; background: var(--superficie, #fff); color: var(--testo, #1d2430); font: inherit; font-size: 13px; font-weight: 600; text-decoration: none; cursor: pointer; }
[data-pannello="ufficio"] .testa button[aria-pressed="true"] { background: var(--accento, #2a7de1); border-color: var(--accento, #2a7de1); color: var(--superficie, #fff); }
[data-pannello="ufficio"] .nascondi { display: none; }
[data-pannello="ufficio"][data-aggancio] .nascondi { display: inline-block; }
[data-pannello="ufficio"] iframe { flex: 1 1 auto; min-height: 0; width: 100%; border: 0; background: #1b1a26; }
[data-pannello="ufficio"][data-aggancio] { position: fixed; left: 0; right: 0; z-index: 50; height: var(--ufficio-h, min(62vh, 520px)); margin: 0; border-radius: 0; border-width: 0; box-shadow: 0 0 18px rgba(0, 0, 0, 0.4); }
[data-pannello="ufficio"][data-aggancio="sotto"] { bottom: 0; border-top-width: 2px; }
[data-pannello="ufficio"][data-aggancio="sopra"] { top: 0; border-bottom-width: 2px; flex-direction: column-reverse; }
[data-pannello="ufficio"].trascina iframe { pointer-events: none; }
[data-pannello="ufficio"] .maniglia { display: none; position: absolute; left: 0; right: 0; height: 12px; z-index: 3; cursor: ns-resize; }
[data-pannello="ufficio"][data-aggancio] .maniglia { display: block; }
[data-pannello="ufficio"][data-aggancio="sotto"] .maniglia { top: -6px; }
[data-pannello="ufficio"][data-aggancio="sopra"] .maniglia { bottom: -6px; }
[data-pannello="ufficio"] .maniglia:hover, [data-pannello="ufficio"] .maniglia:focus-visible, [data-pannello="ufficio"].trascina .maniglia { background: var(--accento, #2a7de1); opacity: 0.55; outline: none; }
body.ufficio-trascina { user-select: none; }
body[data-ufficio="sotto"] main { padding-bottom: calc(var(--ufficio-h, min(62vh, 520px)) + 16px); }
body[data-ufficio="sopra"] { padding-top: var(--ufficio-h, min(62vh, 520px)); }
.colonna.evidenziata { outline: 3px solid var(--accento, #2a7de1); outline-offset: 3px; border-radius: 6px; }
</style>
'@

$script:ScriptUfficio = @'
<script>
(function () {
  var pan = document.querySelector('[data-pannello="ufficio"]');
  if (!pan) { return; }
  var tab = document.querySelector('.schede [data-scheda="ufficio"]');
  var fr = pan.querySelector('iframe'), maniglia = pan.querySelector('.maniglia');
  var leggi = function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } };
  var scrivi = function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} };
  var togli = function (k) { try { localStorage.removeItem(k); } catch (e) {} };

  // le scelte del vecchio pannello: "in basso" diventa agganciato sotto e aperto; "a lato" e "chiuso" diventano la scheda normale
  // (a lato ora si sta con "Affiancate", come le altre schede). Poi le chiavi vecchie si tolgono.
  var vecchio = leggi('ufficio-pannello');
  if (vecchio !== null) {
    if (vecchio === 'basso') { scrivi('ufficio-aggancio', 'sotto'); scrivi('ufficio-aperto', '1'); }
    togli('ufficio-pannello'); togli('ufficio-pannello-ultima'); togli('ufficio-pannello-larghezza');
  }
  var aggancio = leggi('ufficio-aggancio');
  if (['sopra', 'sotto'].indexOf(aggancio) < 0) { aggancio = 'no'; }
  var aperto = leggi('ufficio-aperto') !== '0';

  // il gioco si carica solo se la scheda si vede, e si scarica se non si vede: niente ciclo nascosto
  var carica = function () {
    var src = fr.getAttribute('src'), vede = !pan.hidden && pan.getClientRects().length > 0;
    if (vede) { if (!src || src === 'about:blank') { fr.setAttribute('src', fr.dataset.src); } }
    else if (src && src !== 'about:blank') { fr.setAttribute('src', 'about:blank'); }
  };
  new MutationObserver(carica).observe(pan, { attributes: true, attributeFilter: ['hidden'] });

  var applica = function () {
    if (aggancio === 'no') {
      pan.removeAttribute('data-fuori'); pan.removeAttribute('data-aggancio'); document.body.removeAttribute('data-ufficio');
    } else {
      // agganciata esce dalle schede: la mostra o la nasconde il suo pulsante
      pan.setAttribute('data-fuori', ''); pan.setAttribute('data-aggancio', aggancio);
      pan.hidden = !aperto;
      if (tab) { tab.setAttribute('aria-selected', aperto ? 'true' : 'false'); }
      document.body.setAttribute('data-ufficio', aperto ? aggancio : 'no');
    }
    pan.querySelectorAll('[data-aggancio-scelta]').forEach(function (b) { b.setAttribute('aria-pressed', b.dataset.aggancioScelta === aggancio ? 'true' : 'false'); });
    if (window.vistaRidisponi) { window.vistaRidisponi(); }
    carica();
  };
  pan.querySelectorAll('[data-aggancio-scelta]').forEach(function (b) {
    b.addEventListener('click', function () {
      aggancio = b.dataset.aggancioScelta; scrivi('ufficio-aggancio', aggancio);
      if (aggancio !== 'no') { aperto = true; scrivi('ufficio-aperto', '1'); }
      applica();
    });
  });
  var nascondi = pan.querySelector('.nascondi');
  if (nascondi) { nascondi.addEventListener('click', function () { aperto = false; scrivi('ufficio-aperto', '0'); applica(); }); }
  if (tab) {
    // agganciata, il pulsante della scheda la mostra o la nasconde (lo script delle schede ignora un pannello fuori)
    tab.addEventListener('click', function () { if (aggancio === 'no') { return; } aperto = !aperto; scrivi('ufficio-aperto', aperto ? '1' : '0'); applica(); });
  }

  // l'altezza dell'ufficio agganciato: trascinando la maniglia, con le frecce, doppio clic per tornare come era; si ricorda
  var CHIAVE = 'ufficio-pannello-altezza';
  var dentro = function (v) { return Math.max(160, Math.min(Math.floor(window.innerHeight * 0.85), v)); };
  var metti = function (v, salva) { v = dentro(v); document.documentElement.style.setProperty('--ufficio-h', v + 'px'); if (salva) { scrivi(CHIAVE, String(Math.round(v))); } };
  var misure = function () { var v = parseInt(leggi(CHIAVE), 10); if (v > 0) { metti(v, false); } else { document.documentElement.style.removeProperty('--ufficio-h'); } };
  if (maniglia) {
    var trascinando = false;
    maniglia.addEventListener('pointerdown', function (e) {
      if (aggancio === 'no') { return; }
      trascinando = true; maniglia.setPointerCapture(e.pointerId); pan.classList.add('trascina'); document.body.classList.add('ufficio-trascina'); e.preventDefault();
    });
    maniglia.addEventListener('pointermove', function (e) { if (trascinando) { metti(aggancio === 'sotto' ? window.innerHeight - e.clientY : e.clientY, false); } });
    var fine = function (e) {
      if (!trascinando) { return; }
      trascinando = false; pan.classList.remove('trascina'); document.body.classList.remove('ufficio-trascina');
      try { maniglia.releasePointerCapture(e.pointerId); } catch (x) {}
      scrivi(CHIAVE, String(Math.round(pan.getBoundingClientRect().height)));
    };
    maniglia.addEventListener('pointerup', fine); maniglia.addEventListener('pointercancel', fine);
    maniglia.addEventListener('keydown', function (e) {
      var passo = e.shiftKey ? 96 : 24, d = 0, cresce = aggancio === 'sotto' ? 'ArrowUp' : 'ArrowDown', cala = aggancio === 'sotto' ? 'ArrowDown' : 'ArrowUp';
      if (e.key === cresce) { d = passo; } else if (e.key === cala) { d = -passo; }
      if (d !== 0) { e.preventDefault(); metti(pan.getBoundingClientRect().height + d, true); }
    });
    maniglia.addEventListener('dblclick', function () { togli(CHIAVE); misure(); });
  }
  window.addEventListener('resize', misure);
  misure();
  applica();

  // un clic su un personaggio nell'ufficio: la vista scorre alla colonna di quell'agente. Il messaggio conta solo se viene dal nostro
  // iframe e dalla stessa origine; il ruolo si confronta con le colonne che ci sono, non diventa mai un selettore ne markup.
  window.addEventListener('message', function (e) {
    if (e.source !== fr.contentWindow || e.origin !== location.origin) { return; }
    var d = e.data;
    if (!d || d.tipo !== 'ufficio-persona' || typeof d.ruolo !== 'string') { return; }
    var col = null, colonne = document.querySelectorAll('[data-colonna]');
    for (var i = 0; i < colonne.length; i++) { if (colonne[i].dataset.colonna === d.ruolo) { col = colonne[i]; } }
    e.source.postMessage({ tipo: 'ufficio-risposta', ruolo: d.ruolo, trovato: col !== null }, e.origin === 'null' ? '*' : e.origin);
    if (!col) { return; }
    var agenti = document.querySelector('.schede [data-scheda="agenti"]');
    var pa = document.querySelector('[data-pannello="agenti"]');
    if (agenti && pa && pa.hidden) { agenti.click(); }
    col.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
    col.classList.add('evidenziata');
    setTimeout(function () { col.classList.remove('evidenziata'); }, 2600);
  });
})();
</script>
'@

# Il pannello della scheda Ufficio, da mettere in .pannelli dopo gli altri: maniglia (solo agganciata), comandi, iframe del gioco.
function Get-SchedaUfficio {
    '<div data-pannello="ufficio" role="tabpanel" aria-label="Ufficio degli agenti">' +
    '<div class="maniglia" role="separator" tabindex="0" aria-orientation="horizontal" aria-label="Ingrandisci o rimpicciolisci l&#39;ufficio agganciato" title="Trascina per ingrandire o rimpicciolire (o usa le frecce); doppio clic per tornare come era"></div>' +
    '<div class="testa"><strong>Ufficio</strong>' +
    '<span class="aggancio" role="group" aria-label="Aggancio dell&#39;ufficio">Aggancio: <button type="button" data-aggancio-scelta="no" aria-pressed="true" title="L&#39;ufficio e una scheda come le altre">Nella scheda</button>' +
    '<button type="button" data-aggancio-scelta="sopra" aria-pressed="false" title="L&#39;ufficio resta in alto, sopra le schede">Sopra</button>' +
    '<button type="button" data-aggancio-scelta="sotto" aria-pressed="false" title="L&#39;ufficio resta in basso, sotto le schede">Sotto</button></span>' +
    '<button type="button" class="nascondi" title="Nasconde l&#39;ufficio agganciato (il pulsante Ufficio lo rimostra)">Nascondi</button>' +
    '<a href="ufficio.html" target="_blank" rel="noopener">Apri a parte</a></div>' +
    '<iframe title="Ufficio degli agenti" data-src="ufficio.html?compatto=1"></iframe></div>' + "`n" + $script:StileUfficio
}

# Lo script della scheda Ufficio, da mettere dopo lo script delle schede (usa window.vistaRidisponi).
function Get-ScriptUfficio { $script:ScriptUfficio }

Export-ModuleMember -Function Get-SchedaUfficio, Get-ScriptUfficio
