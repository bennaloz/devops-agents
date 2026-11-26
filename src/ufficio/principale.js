// Il ciclo di gioco e il collegamento con i dati. Passo fisso, risoluzione interna bassa scalata a multipli interi, si ferma quando la scheda
// non si vede; con prefers-reduced-motion i personaggi stanno al loro posto. I dati: incorporati nella pagina (primo disegno) e riletti da
// ufficio.json; se sono fermi o il server non risponde la pagina lo scrive in chiaro, con l'ora dell'ultimo dato buono, e si ferma.
(function (U) {
  'use strict';
  var M = U.M, STEP = 1 / 30;
  var cv = document.getElementById('schermo'), c = cv.getContext('2d');
  c.imageSmoothingEnabled = false;
  var scena = document.getElementById('scena'), riquadro = document.getElementById('riquadro'), scheda = document.getElementById('scheda'), corpoScheda = document.getElementById('corpo-scheda');
  var elenco = document.getElementById('elenco'), consegne = document.getElementById('consegne'), avvisi = document.getElementById('avvisi'), sotto = document.getElementById('sotto');
  var sfondo = U.creaSfondo();
  var dati = JSON.parse(document.getElementById('dati').textContent);
  var esempio = !!dati.esempio, scenari = dati.scenari || null;
  // la versione compatta sta dentro il pannello della vista (iframe ufficio.html?compatto=1): e la stessa pagina, senza il contorno
  var compatto = /[?&]compatto=1(&|$)/.test(location.search);
  if (compatto) document.body.classList.add('compatto');
  var origineGenitore = function () { return location.origin === 'null' ? '*' : location.origin; };
  var mq = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : { matches: false };
  // chi chiede meno movimento lo ottiene; puo chiedere di vedere comunque l'ufficio muoversi (vale per questa scheda del browser)
  // Il movimento e' attivo sempre: la pagina e' un gioco che si apre per vederlo muovere. La preferenza di sistema (su certi PC e' sempre
  // attiva, per esempio con le animazioni di Windows spente) non decide da sola: fa solo comparire una nota con il comando per fermare.
  // Chi vuole fermarlo lo fa con il tasto in cima, e la scelta si ricorda fra un'apertura e l'altra (localStorage).
  var scelta = null;   // se la memoria del browser non c'e', la scelta vale finche la pagina resta aperta
  function movimentoFermato() {
    try { return localStorage.getItem('ufficio-movimento') === 'fermo'; } catch (e) { return scelta === 'fermo'; }
  }
  function ricordaMovimento(fermo) {
    scelta = fermo ? 'fermo' : 'attivo';
    try { if (fermo) localStorage.setItem('ufficio-movimento', 'fermo'); else localStorage.removeItem('ufficio-movimento'); } catch (e) { /* vale solo per questa apertura */ }
  }
  var ridotto = movimentoFermato();
  var fermo = false, fermoSimulato = 0, ultimoBuono = null, erroriRete = 0, orarioForzato = null, scalaIntera = 1, schedaAperta = null;

  function leggiFatte() { try { return JSON.parse(sessionStorage.getItem('ufficio-consegne') || '{}') || {}; } catch (e) { return {}; } }
  function salvaFatte() { if (esempio) return; try { sessionStorage.setItem('ufficio-consegne', JSON.stringify(G.fatte)); } catch (e) { /* senza memoria di sessione si rivedono le consegne al ricarico */ } }
  var G = new U.Gioco({ ridotto: ridotto, fatte: esempio ? {} : leggiFatte() });
  U.G = G;
  // lo stato del gioco: la vista si ricarica da sola ogni pochi secondi, e il gioco deve riprendere da dove stava
  var ETA_MASSIMA = 120000;
  function salvaStato() { if (esempio || !G.agenti.length) return; try { sessionStorage.setItem('ufficio-stato', JSON.stringify(G.salva())); } catch (e) { /* senza memoria di sessione si riparte da capo */ } }
  function leggiStato() {
    try {
      var s = JSON.parse(sessionStorage.getItem('ufficio-stato') || 'null');
      if (s && typeof s.quando === 'number' && Date.now() - s.quando < ETA_MASSIMA && Array.isArray(s.agenti) && s.robot && s.gatto && Array.isArray(s.drops) && typeof s.t === 'number') return s;
    } catch (e) { /* stato illeggibile: si riparte da capo */ }
    return null;
  }
  if (!esempio) G.salvato = leggiStato();
  window.addEventListener('pagehide', salvaStato);
  document.addEventListener('visibilitychange', function () { if (document.hidden) salvaStato(); });
  setInterval(function () { if (!document.hidden) salvaStato(); }, 2000);

  // ---- i dati ---------------------------------------------------------------------------------------------------------------------
  function valido(m) { return m && typeof m.generata === 'string' && Array.isArray(m.personaggi) && Array.isArray(m.consegne) && m.smistatore && m.quota; }
  function applica(m) {
    if (esempio) m = Object.assign({}, m, { generata: new Date().toISOString(), esempio: true });
    ultimoBuono = new Date(m.generata);
    // nell'esempio una scena puo simulare i dati fermi: l'ora dell'ultimo dato buono e' di qualche minuto fa
    if (esempio) { fermo = fermoSimulato > 0; if (fermo) ultimoBuono = new Date(Date.now() - fermoSimulato * 60000); }
    G.applica(m); salvaFatte();
    aggiornaTesti();
  }
  function attivaMovimento() {
    ricordaMovimento(false);
    ridotto = false; fermaCiclo(); G.sciogli(); G.fatte = {}; G.applica(G.modello); aggiornaTesti(); avviaCiclo();
  }
  function fermaMovimento() {
    ricordaMovimento(true);
    ridotto = true; fermaCiclo(); G.ridotto = true; G.metti(); aggiornaTesti(); avviaCiclo();
  }
  function aggiornaTesti() {
    var m = G.modello; if (!m) return;
    var voci = [];
    if (fermo) voci.push({ tipo: 'allarme', testo: 'I dati sono fermi dalle ' + ultimoBuono.toLocaleTimeString('it-IT') + ': ' + (erroriRete > 0 ? 'il server non risponde' : 'la vista non scrive piu\' nuovi dati') + '. Quello che si vede puo\' non essere vero: l\'ufficio e\' fermo.' });
    if (esempio) voci.push({ tipo: 'pausa', testo: 'PAGINA D\'ESEMPIO: i dati sono inventati e non rispecchiano gli agenti veri. I dati veri stanno nella vista (pulsante Ufficio) o in ufficio.html servita dalla vista.' });
    if (m.erroreAdo) voci.push({ tipo: 'allarme', testo: 'Azure DevOps non risponde (' + m.erroreAdo + '): le card in coda, le voci per Titolare e la board non si conoscono. Si vedono solo le sessioni in corso.' });
    if (m.quota.stato === 'riserva' || m.quota.stato === 'limite') voci.push({ tipo: 'pausa', testo: U.testoQuota(m.quota) });
    if (!ridotto && mq.matches) voci.push({ tipo: 'nota', testo: "Il sistema chiede meno movimento (su Windows: animazioni spente), ma qui l'ufficio si muove perche' e' un gioco.", azione: { testo: 'Ferma il movimento', f: fermaMovimento } });
    var tasto = document.getElementById('tasto-movimento');
    tasto.textContent = ridotto ? "Fai muovere l'ufficio" : 'Ferma il movimento';
    tasto.onclick = ridotto ? attivaMovimento : fermaMovimento;
    U.riempiAvvisi(avvisi, voci);
    U.riempiElenco(elenco, G, apri);
    U.riempiConsegne(consegne, G);
    sotto.textContent = esempio ? 'Pagina d\'esempio: i dati sono inventati, servono a vedere tutti i comportamenti.' :
      'Dati delle ' + ultimoBuono.toLocaleTimeString('it-IT') + ', riletti ogni ' + (m.secondi || 10) + ' secondi.';
    scena.classList.toggle('fermo', fermo);
    if (schedaAperta) apri(schedaAperta, true);
    ridimensiona();   // un avviso in piu o in meno cambia lo spazio per l'ufficio
    aggiornaTastoStanza();
  }
  function controllaFermo() {
    if (esempio || !ultimoBuono) return;
    var m = G.modello, soglia = Math.max(30, 4 * ((m && m.secondi) || 10)) * 1000;
    var f = (Date.now() - ultimoBuono.getTime() > soglia) || erroriRete >= 3;
    if (f !== fermo) { fermo = f; aggiornaTesti(); disegna(); if (!f) avviaCiclo(); }
  }
  function leggi() {
    if (esempio || document.hidden || location.protocol === 'file:') return;
    fetch('ufficio.json?t=' + Date.now(), { cache: 'no-store' }).then(function (r) { if (!r.ok) throw new Error('http ' + r.status); return r.json(); })
      .then(function (m) { if (!valido(m)) throw new Error('forma inattesa'); erroriRete = 0; applica(m); controllaFermo(); })
      .catch(function () { erroriRete++; controllaFermo(); });
  }

  function mostraScheda(si) { scheda.hidden = !si; document.getElementById('layout').classList.toggle('con-scheda', si); ridimensiona(); }
  // ---- le schede ------------------------------------------------------------------------------------------------------------------
  function apri(hit, soloAggiorna) {
    schedaAperta = hit;
    while (corpoScheda.firstChild) corpoScheda.removeChild(corpoScheda.firstChild);
    corpoScheda.appendChild(U.scheda(G, hit));
    mostraScheda(true);
    if (!soloAggiorna) { var x = scheda.querySelector('button'); if (x) x.focus(); }
  }
  document.getElementById('chiudi-scheda').addEventListener('click', function () { schedaAperta = null; mostraScheda(false); });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && schedaAperta) { schedaAperta = null; mostraScheda(false); } });
  function puntoDa(e) {
    var r = cv.getBoundingClientRect();
    return { x: (e.clientX - r.left) / r.width * M.W, y: (e.clientY - r.top) / r.height * M.H };
  }
  cv.addEventListener('click', function (e) {
    if (ignoraClic) { ignoraClic = false; return; }
    var p = puntoDa(e), h = trovaQui(p.x, p.y);
    if (!h) { schedaAperta = null; mostraScheda(false); return; }
    // le porte portano all'altra stanza
    if (h.tipo === 'openspace') { vaiStanza('openspace'); return; }
    if (h.tipo === 'ufficio') { vaiStanza('ufficio'); return; }
    // dentro il pannello della vista un personaggio porta la vista alla sua colonna (se la vista non ce l'ha, risponde e si apre la scheda)
    if (compatto && (h.tipo === 'persona' || h.tipo === 'collega') && window.parent !== window) { window.parent.postMessage({ tipo: 'ufficio-persona', ruolo: h.tipo === 'collega' ? h.ruolo : h.rif }, origineGenitore()); return; }
    apri(h);
  });
  window.addEventListener('message', function (e) {
    if (e.source !== window.parent || e.origin !== location.origin) return;
    var d = e.data;
    if (d && d.tipo === 'ufficio-risposta' && typeof d.ruolo === 'string' && d.trovato === false) apri({ tipo: 'persona', rif: d.ruolo });
  });
  cv.addEventListener('mousemove', function (e) { var p = puntoDa(e); cv.style.cursor = trovaQui(p.x, p.y) ? 'pointer' : (scorrevole() ? 'grab' : 'default'); });

  // ---- il disegno e il ciclo ------------------------------------------------------------------------------------------------------
  // Lo zoom e' a multipli interi (i pixel restano nitidi): 'adatta' sceglie il piu grande che sta nello spazio, i tasti fissano una misura
  // (ricordata). Se l'ufficio e' piu grande dello spazio, si sposta la vista trascinando.
  var ZOOM_MAX = 8, zoom = null;
  (function () { try { var z = localStorage.getItem('ufficio-zoom'); if (z && z !== 'auto' && +z >= 1 && +z <= ZOOM_MAX) zoom = Math.round(+z); } catch (e) { /* senza memoria si parte da adatta */ } })();
  function ricordaZoom() { try { localStorage.setItem('ufficio-zoom', zoom === null ? 'auto' : String(zoom)); } catch (e) { /* vale solo per questa apertura */ } }
  var kAdatta = 1;
  // la stanza che si guarda: l'ufficio o l'open space oltre la porta. Si ricorda fra un ricarico e l'altro della vista.
  var stanza = 'ufficio';
  try { if (sessionStorage.getItem('ufficio-stanza') === 'openspace') stanza = 'openspace'; } catch (e) { /* si parte dall'ufficio */ }
  function vaiStanza(s) {
    stanza = s;
    try { sessionStorage.setItem('ufficio-stanza', s); } catch (e) { /* vale per questa apertura */ }
    schedaAperta = null; mostraScheda(false); aggiornaTastoStanza(); if (!rafId) disegna();
  }
  function aggiornaTastoStanza() {
    var b = document.getElementById('cambia-stanza'); if (!b) return;
    var n = (G.openSpace || []).length;
    b.textContent = stanza === 'ufficio' ? 'Open space' + (n ? ' (' + n + ')' : '') : 'Ufficio';
  }
  function trovaQui(x, y) { return stanza === 'openspace' ? U.OS.trova(G, x, y) : U.trova(G, x, y); }
  function ridimensiona() {
    var disponibileL = riquadro.clientWidth || scena.clientWidth, disponibileA;
    if (compatto) { disponibileA = Math.max(M.H, window.innerHeight - avvisi.offsetHeight); riquadro.style.height = disponibileA + 'px'; }
    else disponibileA = Math.max(1, window.innerHeight - 90);
    kAdatta = Math.max(1, Math.floor(Math.min(disponibileL / M.W, disponibileA / M.H)));
    var k = zoom === null ? kAdatta : zoom;
    scalaIntera = k; cv.style.width = (M.W * k) + 'px'; cv.style.height = (M.H * k) + 'px';
    var l = document.getElementById('zoom-livello'); if (l) l.textContent = '\u00d7' + k + (zoom === null ? ' (adatta)' : '');
  }
  function centroVista() { return { x: (riquadro.scrollLeft + riquadro.clientWidth / 2) / (cv.offsetWidth || 1), y: (riquadro.scrollTop + riquadro.clientHeight / 2) / (cv.offsetHeight || 1) }; }
  function mettiCentro(c) { riquadro.scrollLeft = c.x * cv.offsetWidth - riquadro.clientWidth / 2; riquadro.scrollTop = c.y * cv.offsetHeight - riquadro.clientHeight / 2; }
  // si ingrandisce o rimpicciolisce attorno a quello che si sta guardando, non verso l'angolo
  function cambiaZoom(nuovo) {
    var c = centroVista();
    zoom = nuovo === null ? null : Math.max(1, Math.min(ZOOM_MAX, nuovo));
    ricordaZoom(); ridimensiona(); mettiCentro(c); salvaVista();
  }
  document.getElementById('zoom-piu').addEventListener('click', function () { cambiaZoom((zoom === null ? kAdatta : zoom) + 1); });
  document.getElementById('zoom-meno').addEventListener('click', function () { cambiaZoom((zoom === null ? kAdatta : zoom) - 1); });
  document.getElementById('zoom-adatta').addEventListener('click', function () { cambiaZoom(null); });
  document.getElementById('cambia-stanza').addEventListener('click', function () { vaiStanza(stanza === 'ufficio' ? 'openspace' : 'ufficio'); });

  // dove si sta guardando dentro l'ufficio sopravvive al ricarico della vista (come lo stato del gioco)
  var timerVista = null;
  function salvaVista() { try { sessionStorage.setItem('ufficio-vista', JSON.stringify(centroVista())); } catch (e) { /* si riparte dal centro */ } }
  function ripristinaVista() {
    try { var v = JSON.parse(sessionStorage.getItem('ufficio-vista') || 'null'); if (v && isFinite(v.x) && isFinite(v.y)) mettiCentro(v); } catch (e) { /* dal centro */ }
  }
  riquadro.addEventListener('scroll', function () { if (timerVista === null) timerVista = setTimeout(function () { timerVista = null; salvaVista(); }, 250); });
  window.addEventListener('pagehide', salvaVista);

  // si sposta la vista trascinando; un trascinamento non e' un clic
  var trascinamento = null, ignoraClic = false;
  function scorrevole() { return riquadro.scrollWidth > riquadro.clientWidth + 1 || riquadro.scrollHeight > riquadro.clientHeight + 1; }
  cv.addEventListener('pointerdown', function (e) {
    if ((e.pointerType === 'mouse' && e.button !== 0) || !scorrevole()) return;
    trascinamento = { x: e.clientX, y: e.clientY, sx: riquadro.scrollLeft, sy: riquadro.scrollTop, mosso: false };
    cv.setPointerCapture(e.pointerId);
  });
  cv.addEventListener('pointermove', function (e) {
    if (!trascinamento) return;
    var dx = e.clientX - trascinamento.x, dy = e.clientY - trascinamento.y;
    if (!trascinamento.mosso && Math.sqrt(dx * dx + dy * dy) > 4) { trascinamento.mosso = true; cv.classList.add('trascinato'); }
    if (trascinamento.mosso) { riquadro.scrollLeft = trascinamento.sx - dx; riquadro.scrollTop = trascinamento.sy - dy; }
  });
  function fineTrascinamento(e) {
    if (!trascinamento) return;
    if (trascinamento.mosso) { ignoraClic = true; setTimeout(function () { ignoraClic = false; }, 0); }
    trascinamento = null; cv.classList.remove('trascinato');
    try { cv.releasePointerCapture(e.pointerId); } catch (x) { /* gia rilasciato */ }
  }
  cv.addEventListener('pointerup', fineTrascinamento);
  cv.addEventListener('pointercancel', fineTrascinamento);
  function disegna() {
    var d = new Date();
    if (orarioForzato !== null) d.setHours(Math.floor(orarioForzato), Math.round((orarioForzato % 1) * 60), 0, 0);
    G.ora = d; G.drops = G.drops || [];
    if (stanza === 'openspace') U.OS.disegna(c, G);
    else { U.disegnaFondo(c, sfondo, G); U.disegnaEntita(c, G); }
    U.disegnaVelo(c, G);
    // con i dati fermi parla solo l'avviso dei dati fermi: la pausa dello smistatore potrebbe non essere piu vera
    if (fermo && ultimoBuono) U.disegnaFermo(c, ultimoBuono.toLocaleTimeString('it-IT'));
    else U.disegnaPausa(c, G);
  }
  var rafId = null, tPrec = 0, acc = 0, timerRidotto = null;
  function frame(ts) {
    rafId = requestAnimationFrame(frame);
    var dt = (ts - tPrec) / 1000; tPrec = ts;
    if (dt > 0.25) dt = 0.25;
    if (!fermo) { acc += dt; var n = 0; while (acc >= STEP && n < 6) { G.passo(STEP); acc -= STEP; n++; } if (n === 6) acc = 0; }
    disegna();
  }
  function avviaCiclo() {
    if (document.hidden) return;
    if (ridotto) { if (timerRidotto === null) { timerRidotto = setInterval(function () { if (!fermo) G.passo(1); disegna(); }, 1000); } disegna(); return; }
    if (rafId === null) { tPrec = performance.now(); acc = 0; rafId = requestAnimationFrame(frame); }
  }
  function fermaCiclo() {
    if (rafId !== null) { cancelAnimationFrame(rafId); rafId = null; }
    if (timerRidotto !== null) { clearInterval(timerRidotto); timerRidotto = null; }
  }
  document.addEventListener('visibilitychange', function () { if (document.hidden) fermaCiclo(); else { avviaCiclo(); leggi(); controllaFermo(); } });
  if (mq.addEventListener) mq.addEventListener('change', function () { aggiornaTesti(); });
  window.addEventListener('resize', function () { ridimensiona(); if (!rafId) disegna(); });
  if (window.ResizeObserver) new ResizeObserver(function () { ridimensiona(); }).observe(scena);

  // ---- l'esempio: scene, ora del giorno, consegne da rivedere ---------------------------------------------------------------------
  function preparaEsempio() {
    var box = document.getElementById('comandi-esempio'); box.hidden = false;
    var sel = document.getElementById('scelta-scena');
    scenari.forEach(function (s, i) { var o = document.createElement('option'); o.value = String(i); o.textContent = s.nome; sel.appendChild(o); });
    function mostra() { var sc = scenari[+sel.value]; G.fatte = {}; G.inAttesa = []; G.drops = []; fermoSimulato = sc.fermoDaMinuti || 0; applica(sc.modello); }
    sel.addEventListener('change', mostra);
    var ore = document.getElementById('scelta-ora');
    ore.addEventListener('change', function () { orarioForzato = ore.value === '' ? null : parseFloat(ore.value); if (!rafId) disegna(); });
    document.getElementById('ripeti-consegne').addEventListener('click', mostra);
    setInterval(function () { if (!document.hidden && !ridotto && !fermoSimulato) mostra(); }, 70000);
  }

  // ---- si parte -------------------------------------------------------------------------------------------------------------------
  ridimensiona(); ripristinaVista();
  if (esempio && scenari) { preparaEsempio(); fermoSimulato = scenari[0].fermoDaMinuti || 0; applica(scenari[0].modello); }
  else if (valido(dati)) applica(dati);
  else sotto.textContent = 'Dati non validi.';
  controllaFermo();
  aggiornaTesti();
  avviaCiclo();
  if (!esempio) {
    var passoLettura = ((G.modello && G.modello.secondi) || 10) * 1000;
    setInterval(leggi, passoLettura);
    setInterval(controllaFermo, 1000);
    // aperta da disco (file://) non puo' rileggere ufficio.json: si ricarica, e il dato incorporato e' quello che la vista ha scritto per ultimo
    if (location.protocol === 'file:') setTimeout(function () { location.reload(); }, passoLettura);
  }
})(U);
