// Le entita sulla scena: i personaggi, lo smistatore, il gatto e Titolare, ordinati per profondita', con le loro etichette e i fumetti;
// poi gli avvisi a tutta scena (la pausa dello smistatore, i dati fermi). Disegna e basta: le decisioni stanno nel cervello.
(function (U) {
  'use strict';
  var M = U.M;
  function R(c, x, y, w, h, col) { c.fillStyle = col; c.fillRect(Math.round(x), Math.round(y), w, h); }
  function chiaro(hex) { var r = parseInt(hex.substr(1, 2), 16), g = parseInt(hex.substr(3, 2), 16), b = parseInt(hex.substr(5, 2), 16); return (r * 299 + g * 587 + b * 114) / 1000 > 170; }
  function sfondoEtichetta(s) { return /^#/.test(s.top) && chiaro(s.top) ? s.dettaglio : s.top; }

  function agente(c, G, a) {
    var o = { x: a.x, y: a.y, dir: a.dir, passo: a.passo, cammina: a.cammina, posa: a.posa, t: a.t, stile: a.stile, seduto: a.seduto, blink: a.occhi > 0 };
    if (a.portando) o.cartella = { verso: a.portando.verso };
    U.persona(c, o);
  }
  function sopra(c, G, a) {
    var x = Math.round(a.x), y = Math.round(a.y), top = a.seduto ? y - 18 : (a.posa === 'divano' || a.posa === 'dorme' ? y - 20 : y - 22);
    var fondo = sfondoEtichetta(a.stile);
    U.etichetta(c, a.stile.sigla, x, top, '#ffffff', fondo);
    var alto = top - 2;
    if (a.portando) {
      var verso = a.portando.verso, col = verso === 'indietro' ? '#d1495b' : (verso === 'avanti' ? '#2a9d4e' : '#2a6fb0');
      var nome = verso === 'indietro' ? 'INDIETRO' : (verso === 'avanti' ? 'AVANTI' : 'LATER');
      U.etichetta(c, nome, x, alto - 7, '#ffffff', col);
      U.etichetta(c, '#' + a.portando.id, x, alto - 15, '#ffffff', col);
      alto -= 17;
    }
    if (a.modo === 'fila' && G.modello && G.modello.fila && G.modello.fila[a.slot]) {
      U.etichetta(c, '#' + G.modello.fila[a.slot].id, x, alto - 7, '#ffffff', '#8a6a46');
      alto -= 9;
    }
    var ic = a.bolla ? a.bolla.icona : null, colIc = a.bolla ? a.bolla.colore : '#1d1b2b';
    if (!ic && a.modo === 'fila') { ic = (Math.floor(G.t * 1.1) % 3 === 0) ? 'esclama' : 'puntini'; colIc = '#8a6a46'; }
    if (ic) U.fumetto(c, ic, x, alto, colIc);
    if (a.posa === 'dorme') {
      for (var k = 0; k < 3; k++) {
        var f = ((G.t * 0.7 + k / 3) % 1);
        U.testo(c, 'Z', x + 6 + k * 2, y - 24 - Math.round(f * 12), 'rgba(255,255,255,' + (1 - f).toFixed(2) + ')', k === 2 ? 2 : 1);
      }
    }
  }

  function robot(c, G, r) {
    U.robot(c, { x: r.x, y: r.y, stato: r.stato, cammina: r.cammina, t: r.t });
    var x = Math.round(r.x), y = Math.round(r.y);
    if (r.piano.length && r.piano[0].k === 'fai' && r.piano[0].posa === 'scan') {
      for (var k = 0; k < 6; k++) R(c, x, y - 28 - k * 5 + (Math.floor(G.t * 8) % 2) * 2, 1, 3, '#7fe3ff');
    }
    if (r.stato === 'dorme') {
      for (var z = 0; z < 3; z++) {
        var f = ((G.t * 0.6 + z / 3) % 1);
        U.testo(c, 'Z', x + 6 + z * 3, y - 28 - Math.round(f * 16), 'rgba(255,255,255,' + (1 - f).toFixed(2) + ')', 2);
      }
    }
  }

  function titolare(c, G) {
    var t = G.t, st = U.stile('titolare');
    var pos = Math.floor(t / 7) % 3 === 2 ? 'stira' : 'scrivania';
    U.persona(c, { x: 288, y: 102, dir: 'u', passo: 0, cammina: false, posa: pos, t: t, stile: st, seduto: true });
  }

  U.disegnaEntita = function (c, G) {
    var lista = [];
    G.agenti.forEach(function (a) { lista.push({ y: a.y, f: function () { agente(c, G, a); } }); });
    (G.colleghi || []).forEach(function (k) { if (!k.nascosto) lista.push({ y: k.y, f: function () { agente(c, G, k); } }); });
    lista.push({ y: G.robot.y, f: function () { robot(c, G, G.robot); } });
    lista.push({ y: G.gatto.y, f: function () { U.gatto(c, { x: G.gatto.x, y: G.gatto.y, stato: G.gatto.stato, dir: G.gatto.dir, t: G.gatto.t }); } });
    lista.push({ y: 102, f: function () { titolare(c, G); } });
    lista.sort(function (a, b) { return a.y - b.y; });
    lista.forEach(function (e) { e.f(); });
    G.agenti.forEach(function (a) { sopra(c, G, a); });
    // i colleghi: la sigla del ruolo e l'id della card della loro sessione (dato vero)
    (G.colleghi || []).forEach(function (k) {
      if (k.nascosto) return;
      var x = Math.round(k.x), testo = k.stile.sigla + ' #' + k.sessione.id;
      // al tavolo le persone sono una sopra l'altra: l'etichetta sta a destra, accanto alla testa, non sopra
      if (k.seduto) U.etichetta(c, testo, x + 8 + Math.ceil((U.larghezzaTesto(testo) + 3) / 2), Math.round(k.y) - 13, '#ffffff', sfondoEtichetta(k.stile));
      else U.etichetta(c, testo, x, Math.round(k.y) - 22, '#ffffff', sfondoEtichetta(k.stile));
      if (k.bolla) U.fumetto(c, k.bolla.icona, x, Math.round(k.y) - (k.seduto ? 18 : 24), k.bolla.colore);
    });
    // la porta dell'open space dice quanti ci lavorano (sessioni senza posto al tavolo)
    var n = (G.openSpace || []).length;
    if (n > 0) U.etichetta(c, 'OPEN SPACE +' + n, 40, M.portaOpenSpace.y + 7, '#ffffff', '#6b4b2b');
    U.etichetta(c, 'RIC', 288, 83, '#ffffff', '#3a6ea5');
    if (G.robot.stato === 'dorme') U.etichetta(c, 'PAUSA', Math.round(G.robot.x), Math.round(G.robot.y) - 33, '#ffffff', '#b3282d');
    else if (G.robot.stato === 'giro') U.etichetta(c, 'SMIST', Math.round(G.robot.x), Math.round(G.robot.y) - 29, '#ffffff', '#4a4f63');
  };

  // Cosa si puo cliccare, dal piu in alto al piu in basso. rif: l'oggetto di cui aprire la scheda.
  U.bersagli = function (G) {
    var b = [];
    b.push({ tipo: 'robot', x: G.robot.x - 8, y: G.robot.y - 26, w: 16, h: 28 });
    G.agenti.forEach(function (a) { b.push({ tipo: 'persona', rif: a.ruolo, x: a.x - 8, y: a.y - 22, w: 16, h: 24 }); });
    (G.colleghi || []).forEach(function (k) { if (!k.nascosto) b.push({ tipo: 'collega', rif: k.chiave, ruolo: k.ruolo, x: k.x - 8, y: k.y - 22, w: 16, h: 24 }); });
    b.push({ tipo: 'openspace', x: 0, y: M.portaOpenSpace.y - 4, w: 22, h: M.portaOpenSpace.h + 8 });
    if (G.modello) {
      G.modello.personaggi.slice(0, M.MAX_SCRIVANIE).forEach(function (p, i) {
        var d = M.scrivania(i);
        if (p.codaTotale > 0) b.push({ tipo: 'coda', rif: p.ruolo, x: d.pila.x - 3, y: d.pila.y - 20, w: 12, h: 24 });
        b.push({ tipo: 'persona', rif: p.ruolo, x: d.monitor.x, y: d.monitor.y, w: d.monitor.w, h: d.monitor.h });
      });
    }
    b.push({ tipo: 'porta', x: M.stanza.x - 8, y: 0, w: M.stanza.w + 8, h: 128 });
    b.push({ tipo: 'bacheca', x: M.bacheca.x, y: M.bacheca.y, w: M.bacheca.w, h: M.bacheca.h });
    return b;
  };
  U.trova = function (G, x, y) {
    var l = U.bersagli(G);
    for (var i = 0; i < l.length; i++) { var r = l[i]; if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) return r; }
    return null;
  };

  // ---- gli avvisi a tutta scena ------------------------------------------------------------------------------------------------------
  function pannello(c, x, y, w, h) { R(c, x - 2, y - 2, w + 4, h + 4, '#1d1b2b'); R(c, x, y, w, h, 'rgba(22,20,40,0.86)'); }
  function centro(c, s, y, col, scala) { U.testo(c, s, Math.round(M.W / 2 - U.larghezzaTesto(s, scala) / 2), y, col, scala); }

  // Lo smistatore e in pausa (riserva settimanale oltre soglia, o limite di token): lo dice tutta la scena, non un'etichetta.
  U.disegnaPausa = function (c, G) {
    var q = G.modello && G.modello.quota;
    if (!q || (q.stato !== 'riserva' && q.stato !== 'limite')) return;
    c.fillStyle = 'rgba(14,20,58,0.42)'; c.fillRect(0, 0, M.W, M.H);
    var p = (Math.sin(G.t * 3) + 1) / 2, col = 'rgba(255,' + Math.round(120 + 80 * p) + ',60,1)';
    for (var i = 0; i < 3; i++) { c.strokeStyle = i === 0 ? col : 'rgba(255,170,60,0.35)'; c.strokeRect(1 + i, 1 + i, M.W - 2 - i * 2, M.H - 2 - i * 2); }
    // La pausa per il limite NON e la riserva settimanale: e il limite di una finestra (5 ore o settimana) arrivato al 100%. Si dice
    // quale, quanto e usata e quando riparte; la soglia settimanale qui non c'entra e non si disegna.
    if (q.stato === 'limite') {
      var y1 = 84, conUso = q.usoFinestra !== null && q.usoFinestra !== undefined;
      pannello(c, 56, y1, 208, conUso ? 74 : 56);
      centro(c, 'PAUSA', y1 + 5, '#ffb347', 4);
      centro(c, q.finestra === 'cinqueOre' ? 'LIMITE DELLE 5 ORE' : (q.finestra === 'settimana' ? 'LIMITE SETTIMANALE' : 'LIMITE DI TOKEN'), y1 + 29, '#ffffff', 2);
      var ry = y1 + 44;
      if (conUso) {
        var bx1 = 76, bw1 = 168, u1 = Math.max(0, Math.min(1, q.usoFinestra));
        R(c, bx1 - 1, ry - 1, bw1 + 2, 10, '#ffffff'); R(c, bx1, ry, bw1, 8, '#3a3f55'); R(c, bx1, ry, Math.round(bw1 * u1), 8, u1 >= 1 ? '#ff5c5c' : '#ffb347');
        centro(c, 'USATO ' + Math.round(q.usoFinestra * 100) + '%', ry + 12, '#ffffff', 1);
        ry += 20;
      }
      var fino = new Date(q.fino);
      if (!isNaN(fino)) {
        var oggi = new Date(), dueCifre = function (n) { return (n < 10 ? '0' : '') + n; };
        var giorno = fino.toDateString() === oggi.toDateString() ? '' : dueCifre(fino.getDate()) + '/' + dueCifre(fino.getMonth() + 1) + ' ';
        centro(c, 'RIPARTE ' + giorno + 'ALLE ' + dueCifre(fino.getHours()) + ':' + dueCifre(fino.getMinutes()), ry, '#ffd166', 1);
      }
      return;
    }
    var haBarra = q.uso !== null && q.uso !== undefined;
    var h = haBarra ? 62 : 44, y0 = 84;
    pannello(c, 56, y0, 208, h);
    centro(c, 'PAUSA', y0 + 5, '#ffb347', 4);
    centro(c, 'RISERVA SETTIMANALE', y0 + 29, '#ffffff', 2);
    if (haBarra) {
      var bx = 76, bw = 168, by = y0 + 44, uso = Math.max(0, Math.min(1, q.uso));
      R(c, bx - 1, by - 1, bw + 2, 10, '#ffffff'); R(c, bx, by, bw, 8, '#3a3f55');
      R(c, bx, by, Math.round(bw * uso), 8, uso >= (q.soglia || 2) ? '#ff5c5c' : '#4cc38a');
      if (q.soglia) { R(c, bx + Math.round(bw * Math.min(1, q.soglia)), by - 3, 2, 14, '#ffd166'); }
      var tt = Math.round(q.uso * 100) + '%' + (q.soglia ? ' / SOGLIA ' + Math.round(q.soglia * 100) + '%' : '');
      centro(c, tt, by + 12, '#ffffff', 1);
    }
  };

  // I dati sono fermi: l'ufficio non finge. Si grida a tutta scena, con l'ora dell'ultimo dato buono.
  U.disegnaFermo = function (c, ultimo) {
    c.fillStyle = 'rgba(20,20,26,0.45)'; c.fillRect(0, 0, M.W, M.H);
    pannello(c, 40, 88, 240, 46);
    centro(c, 'DATI FERMI', 93, '#ff9aa8', 3);
    centro(c, 'ULTIMO DATO ' + ultimo, 117, '#ffffff', 1);
  };
})(U);
