// L'open space: la seconda stanza, oltre la porta in basso a sinistra dell'ufficio. Ci lavorano le sessioni che non trovano posto al
// tavolo dei portatili (G.openSpace, deciso dal cervello sul dato vero): una persona per sessione, al suo banco, con l'id della card.
// Chi arriva entra dalla porta e cammina fino al banco; a sessione finita (o se si libera un posto al tavolo dell'ufficio) si alza ed
// esce. I percorsi sono a tratti dritti lungo i corridoi, che passano sempre fuori dai banchi.
(function (U) {
  'use strict';
  var M = U.M;
  function R(c, x, y, w, h, col) { c.fillStyle = col; c.fillRect(Math.round(x), Math.round(y), w, h); }
  var VEL = 30;
  var OS = {};

  // tre file di banchi; si siede sul lato sotto il banco, guardando il banco (di schiena). Sotto ogni fila corre il suo corridoio, e a
  // sinistra un corridoio verticale li unisce tutti alla porta.
  var FILE = [{ y: 58 }, { y: 104 }, { y: 150 }];
  var PER_FILA = 11, X0 = 44, PASSO = 24, ALTO_BANCO = 9;
  OS.POSTI = FILE.length * PER_FILA;
  OS.porta = { x: 0, y: 128, w: 8, h: 18 };
  OS.ingresso = { x: 14, y: 137 };
  OS.posto = function (i) {
    var f = Math.floor(i / PER_FILA), k = i % PER_FILA, b = FILE[f];
    return { x: X0 + k * PASSO, y: b.y + ALTO_BANCO + 17, corridoio: b.y + ALTO_BANCO + 27, fila: f };
  };
  function percorso(da, a) {
    // dalla porta: su per il corridoio di sinistra fino al corridoio della fila, lungo il corridoio, poi su al banco
    var p = OS.posto(a);
    return [{ x: OS.ingresso.x, y: p.corridoio }, { x: p.x, y: p.corridoio }, { x: p.x, y: p.y }];
  }
  function percorsoUscita(e) {
    var p = OS.posto(e.posto);
    return [{ x: p.x, y: p.corridoio }, { x: OS.ingresso.x, y: p.corridoio }, { x: OS.ingresso.x, y: OS.ingresso.y }];
  }

  // ---- il dato: chi lavora nell'open space ------------------------------------------------------------------------------------------
  OS.aggiorna = function (G, sessioni, primo) {
    G.osPersone = G.osPersone || [];
    var voluti = {}; (sessioni || []).forEach(function (s) { voluti[s.ruolo + '#' + s.id] = s; });
    G.osPersone.forEach(function (e) {
      if (voluti[e.chiave]) { e.sessione = voluti[e.chiave]; return; }
      if (e.stato === 'esce') return;
      e.stato = 'esce'; e.seduto = false; e.attesa = 0; e.cammino = percorsoUscita(e);
    });
    var occupati = {}, presenti = {};
    G.osPersone.forEach(function (e) { if (e.stato !== 'esce') { occupati[e.posto] = true; presenti[e.chiave] = true; } });
    var entrano = 0;
    (sessioni || []).forEach(function (s) {
      var chiave = s.ruolo + '#' + s.id;
      if (presenti[chiave]) return;
      var sv = G.salvato && G.salvato.osPersone ? G.salvato.osPersone.filter(function (x) { return x.chiave === chiave; })[0] : null;
      var posto = sv && !occupati[sv.posto] ? sv.posto : -1;
      for (var i = 0; posto < 0 && i < OS.POSTI; i++) if (!occupati[i]) posto = i;
      if (posto < 0) return;   // oltre i posti dell'open space: si contano, non si disegnano
      occupati[posto] = true;
      var p = OS.posto(posto), subito = G.ridotto || primo || !!sv;
      var e = { chiave: chiave, ruolo: s.ruolo, sessione: s, stile: U.stile(s.ruolo), posto: posto, t: G.rnd() * 10, tPasso: 0, passo: 0, dir: 'u' };
      if (subito) { e.x = p.x; e.y = p.y; e.stato = 'siede'; e.seduto = true; e.cammino = []; e.attesa = 0; }
      else { e.x = OS.ingresso.x; e.y = OS.ingresso.y; e.stato = 'entra'; e.seduto = false; e.cammino = percorso(null, posto); e.attesa = 1.2 + 1.8 * entrano++; }
      G.osPersone.push(e);
    });
    G.osOltre = Math.max(0, (sessioni || []).length - G.osPersone.filter(function (e) { return e.stato !== 'esce'; }).length);
  };

  OS.passo = function (G, dt) {
    (G.osPersone || []).forEach(function (e) {
      e.t += dt;
      if (e.attesa > 0) { e.attesa -= dt; return; }
      var tgt = e.cammino[0];
      if (!tgt) {
        e.cammina = false;
        if (e.stato === 'entra') { e.stato = 'siede'; e.seduto = true; e.dir = 'u'; }
        else if (e.stato === 'esce') e.via = true;
        return;
      }
      var dx = tgt.x - e.x, dy = tgt.y - e.y, d = Math.sqrt(dx * dx + dy * dy), s = VEL * dt;
      if (d <= s) { e.x = tgt.x; e.y = tgt.y; e.cammino.shift(); } else { e.x += dx / d * s; e.y += dy / d * s; }
      if (d > 0.01) e.dir = Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? 'r' : 'l') : (dy > 0 ? 'd' : 'u');
      e.cammina = true; e.tPasso += dt; e.passo = Math.floor(e.tPasso * 7) % 4;
    });
    if (G.osPersone) G.osPersone = G.osPersone.filter(function (e) { return !e.via; });
  };

  OS.salva = function (G) {
    return (G.osPersone || []).filter(function (e) { return e.stato !== 'esce'; }).map(function (e) { return { chiave: e.chiave, posto: e.posto }; });
  };

  // ---- il disegno ---------------------------------------------------------------------------------------------------------------------
  var FINESTRE = [{ x: 40, y: 8, w: 56, h: 30 }, { x: 132, y: 8, w: 56, h: 30 }, { x: 224, y: 8, w: 56, h: 30 }];
  var sfondo = null;
  function creaSfondo() {
    var cv = document.createElement('canvas'); cv.width = M.W; cv.height = M.H;
    var c = cv.getContext('2d');
    // moquette a quadrotte
    for (var y = 48; y < M.H; y += 16) for (var x = 0; x < M.W; x += 16) R(c, x, y, 16, 16, ((x + y) / 16) % 2 ? '#7c8aa0' : '#76849a');
    for (var y2 = 48; y2 < M.H; y2 += 16) R(c, 0, y2, M.W, 1, '#6c7a90');
    // muro in alto con le finestre, a sinistra, in basso
    R(c, 0, 0, M.W, 46, '#e4e8ee'); R(c, 0, 46, M.W, 4, '#9aa6b8'); R(c, 0, 50, M.W, 1, '#7a869a');
    FINESTRE.forEach(function (f) {
      R(c, f.x - 2, f.y - 2, f.w + 4, f.h + 4, '#5a6478'); c.clearRect(f.x, f.y, f.w, f.h);
      R(c, f.x + f.w / 2 - 1, f.y, 2, f.h, '#5a6478'); R(c, f.x, f.y + 13, f.w, 2, '#5a6478'); R(c, f.x - 3, f.y + f.h + 2, f.w + 6, 2, '#9aa6b8');
    });
    R(c, 0, 48, 8, M.H - 48, '#cfd5de'); R(c, 7, 48, 1, M.H - 48, '#9aa6b8');
    R(c, 0, 208, M.W, 16, '#e4e8ee'); R(c, 0, 208, M.W, 3, '#9aa6b8');
    // la porta verso l'ufficio, con lo zerbino
    var P = OS.porta;
    R(c, P.x, P.y - 2, P.w, P.h + 4, '#6b4b2b'); R(c, P.x + 1, P.y, P.w - 2, P.h, '#3a2a1a'); R(c, P.x + 2, P.y + 1, 3, P.h - 2, '#8a6a46'); R(c, P.x + 4, P.y + 9, 1, 1, '#f2d34f');
    R(c, P.x + 8, P.y + 3, 9, 12, '#5a5048');
    // i banchi bianchi lunghi, con le sedie
    FILE.forEach(function (b) {
      var x0 = X0 - 14, w = PER_FILA * PASSO + 4;
      R(c, x0, b.y, w, ALTO_BANCO, '#f1f2f4'); R(c, x0, b.y, w, 1, '#ffffff'); R(c, x0, b.y + ALTO_BANCO, w, 3, '#b8bfca');
      R(c, x0 + 2, b.y + ALTO_BANCO + 3, 2, 3, '#8a93a3'); R(c, x0 + w - 4, b.y + ALTO_BANCO + 3, 2, 3, '#8a93a3');
      for (var k = 0; k < PER_FILA; k++) { var sx = X0 + k * PASSO; R(c, sx - 5, b.y + ALTO_BANCO + 10, 10, 5, '#3f4a63'); R(c, sx - 5, b.y + ALTO_BANCO + 15, 10, 4, '#4c5877'); }
    });
    return cv;
  }
  function pianta(c, x, y, t) {
    R(c, x, y + 8, 10, 8, '#a8651f'); R(c, x - 1, y + 8, 12, 2, '#c47a2c');
    var s = Math.round(Math.sin(t * 1.3 + x));
    R(c, x + 1 + s, y + 1, 3, 8, '#2d9a5a'); R(c, x + 6 - s, y, 3, 9, '#3dba70'); R(c, x + 3, y - 3 + s, 3, 9, '#2d9a5a');
  }

  OS.disegna = function (c, G) {
    var data = G.ora, ora = data.getHours() + data.getMinutes() / 60, t = G.t;
    if (!sfondo) sfondo = creaSfondo();
    c.clearRect(0, 0, M.W, M.H);
    FINESTRE.forEach(function (f) { U.cielo(c, ora, t + f.x, f); });
    c.drawImage(sfondo, 0, 0);
    U.testo(c, 'OPEN SPACE', 160 - Math.round(U.larghezzaTesto('OPEN SPACE') / 2), 41, '#5a6478');
    pianta(c, 296, 182, t); pianta(c, 296, 56, t); pianta(c, 14, 182, t);
    // i portatili sui banchi: accesi dove qualcuno siede
    var seduti = {};
    (G.osPersone || []).forEach(function (e) { if (e.seduto) seduti[e.posto] = true; });
    for (var i = 0; i < OS.POSTI; i++) {
      var p = OS.posto(i), by = FILE[p.fila].y;
      R(c, p.x - 5, by + 2, 10, 2, '#9aa0ab'); R(c, p.x - 4, by - 4, 8, 6, '#2f3140');
      R(c, p.x - 3, by - 3, 6, 4, seduti[i] ? (Math.floor(t * 3 + i) % 4 ? '#4df0a0' : '#35c98a') : '#10131f');
    }
    // le persone, per profondita
    var l = (G.osPersone || []).filter(function (e) { return !(e.stato === 'entra' && e.attesa > 0); }).slice().sort(function (a, b) { return a.y - b.y; });
    l.forEach(function (e) {
      U.persona(c, { x: e.x, y: e.y, dir: e.dir, passo: e.passo, cammina: e.cammina, posa: e.seduto ? 'scrivania' : 'in piedi', t: e.t, stile: e.stile, seduto: !!e.seduto });
    });
    l.forEach(function (e) {
      var fondo = /^#/.test(e.stile.top) && parseInt(e.stile.top.substr(1, 2), 16) * 0.3 + parseInt(e.stile.top.substr(3, 2), 16) * 0.59 + parseInt(e.stile.top.substr(5, 2), 16) * 0.11 > 170 ? e.stile.dettaglio : e.stile.top;
      U.etichetta(c, '#' + e.sessione.id, Math.round(e.x), Math.round(e.y) - (e.seduto ? 18 : 22), '#ffffff', fondo);
    });
    U.etichetta(c, 'UFFICIO', 30, OS.porta.y - 9, '#ffffff', '#6b4b2b');
    if (G.osOltre > 0) U.etichetta(c, 'E ALTRI ' + G.osOltre, 160, 200, '#ffffff', '#6b4b2b');
  };

  OS.trova = function (G, x, y) {
    var l = (G.osPersone || []).filter(function (e) { return !(e.stato === 'entra' && e.attesa > 0); });
    for (var i = 0; i < l.length; i++) {
      var e = l[i];
      if (x >= e.x - 8 && x < e.x + 8 && y >= e.y - 22 && y < e.y + 2) return { tipo: 'collega', rif: e.chiave, ruolo: e.ruolo };
    }
    if (x < 24 && y >= OS.porta.y - 14 && y < OS.porta.y + OS.porta.h + 4) return { tipo: 'ufficio' };
    return null;
  };

  U.OS = OS;
})(U);
