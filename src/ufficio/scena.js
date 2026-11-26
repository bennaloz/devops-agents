// La scena: lo sfondo fisso (pre-disegnato una volta), il cielo che segue l'ora vera, la bacheca, le scrivanie e l'ambiente che si muove sempre.
// Qui si disegna soltanto: nessuna decisione. Gli id di card che compaiono (schermi, pile, cartelline) arrivano dal modello dei dati.
(function (U) {
  'use strict';
  var M = U.M;
  function R(c, x, y, w, h, col) { c.fillStyle = col; c.fillRect(Math.round(x), Math.round(y), w, h); }
  function lerp(a, b, k) { return a + (b - a) * k; }
  function hex(h) { return [parseInt(h.substr(1, 2), 16), parseInt(h.substr(3, 2), 16), parseInt(h.substr(5, 2), 16)]; }
  function mix(a, b, k) { var x = hex(a), y = hex(b); return 'rgb(' + Math.round(lerp(x[0], y[0], k)) + ',' + Math.round(lerp(x[1], y[1], k)) + ',' + Math.round(lerp(x[2], y[2], k)) + ')'; }
  // un generatore deterministico per le cose che devono restare uguali a ogni disegno (le assi del pavimento, le stelle)
  function seme(n) { var s = n; return function () { s = (s * 1664525 + 1013904223) % 4294967296; return s / 4294967296; }; }

  // ---- il cielo dalla finestra, secondo l'ora vera del giorno ---------------------------------------------------------------
  var CIELO = [[0, '#0a1030', '#18204a'], [5, '#141c46', '#3a3f7a'], [6.5, '#f08a5d', '#f9c784'], [8, '#6cb4ee', '#bfe4f7'], [12, '#4aa3e8', '#a9dcf5'],
    [17, '#5aa8e6', '#f7d9a0'], [19, '#e76f51', '#f4a261'], [20.5, '#2a2a5e', '#50407a'], [22, '#0a1030', '#18204a'], [24, '#0a1030', '#18204a']];
  function coloriCielo(ora) {
    for (var i = 1; i < CIELO.length; i++) {
      if (ora <= CIELO[i][0]) {
        var a = CIELO[i - 1], b = CIELO[i], k = (ora - a[0]) / (b[0] - a[0]);
        return [mix(a[1], b[1], k), mix(a[2], b[2], k)];
      }
    }
    return [CIELO[0][1], CIELO[0][2]];
  }
  var FIN = { x: 10, y: 8, w: 64, h: 34 };
  var NUVOLE = [{ x: 0, y: 12, v: 2.2, s: 1 }, { x: 30, y: 22, v: 1.3, s: 1.3 }, { x: 52, y: 6, v: 3.1, s: 0.8 }];
  var rs = seme(7), STELLE = [];
  for (var si = 0; si < 14; si++) STELLE.push({ x: 2 + Math.floor(rs() * (FIN.w - 4)), y: 2 + Math.floor(rs() * (FIN.h - 12)), f: rs() * 6 });

  // F: il rettangolo della finestra (quella dell'ufficio se manca)
  function cielo(c, ora, t, F) {
    F = F || FIN;
    var col = coloriCielo(ora);
    var fascia = F.h / 6;
    for (var i = 0; i < 6; i++) R(c, F.x, F.y + i * fascia, F.w, Math.ceil(fascia), mixRgb(col[0], col[1], i / 5));
    var giorno = ora >= 6.5 && ora <= 19.5, notte = ora < 5.5 || ora > 20.5;
    if (notte) STELLE.forEach(function (s) { if (Math.floor(t * 1.5 + s.f) % 3) R(c, F.x + s.x, F.y + s.y, 1, 1, '#ffffff'); });
    var arco = function (da, a) { var k = ((ora - da + 24) % 24) / a; return { x: F.x + 6 + k * (F.w - 12), y: F.y + F.h - 6 - Math.sin(k * Math.PI) * (F.h - 14) }; };
    if (giorno) { var p = arco(6.5, 13); R(c, p.x - 3, p.y - 3, 7, 7, '#ffe27a'); R(c, p.x - 4, p.y - 1, 9, 3, '#ffe27a'); R(c, p.x - 1, p.y - 4, 3, 9, '#ffe27a'); }
    else if (ora > 19.5 || ora < 6.5) { var q = arco(19.5, 11); R(c, q.x - 3, q.y - 3, 6, 6, '#f1f1e6'); R(c, q.x - 1, q.y - 3, 4, 6, mixRgb(col[0], col[1], 0.3)); }
    var chiara = giorno ? '#ffffff' : '#7d86b8';
    NUVOLE.forEach(function (n) {
      var x = ((n.x + t * n.v) % (F.w + 24)) - 12;
      R(c, F.x + x, F.y + n.y + 2, Math.round(14 * n.s), 3, chiara); R(c, F.x + x + 3, F.y + n.y, Math.round(8 * n.s), 3, chiara);
    });
  }
  function mixRgb(a, b, k) {
    var pa = a.match(/\d+/g).map(Number), pb = b.match(/\d+/g).map(Number);
    return 'rgb(' + Math.round(lerp(pa[0], pb[0], k)) + ',' + Math.round(lerp(pa[1], pb[1], k)) + ',' + Math.round(lerp(pa[2], pb[2], k)) + ')';
  }
  // quanto buio e dentro: 0 di giorno, fino a 0.34 di notte
  function bui(ora) {
    if (ora >= 8 && ora <= 17.5) return 0;
    if (ora > 17.5 && ora < 20.5) return (ora - 17.5) / 3 * 0.34;
    if (ora >= 20.5 || ora <= 5) return 0.34;
    if (ora > 5 && ora < 8) return (8 - ora) / 3 * 0.34;
    return 0;
  }

  // ---- lo sfondo fisso ---------------------------------------------------------------------------------------------------
  U.creaSfondo = function () {
    var cv = document.createElement('canvas'); cv.width = M.W; cv.height = M.H;
    var c = cv.getContext('2d');
    // pavimento a doghe
    var r = seme(3);
    for (var y = 56; y < M.H; y += 8) {
      var off = (Math.floor(y / 8) % 2) * 16;
      for (var x = 0; x < M.W; x += 32) R(c, x, y, 32, 8, ((x + y) / 8) % 2 ? '#c99d63' : '#c19659');
      for (var s = -off; s < M.W; s += 32) R(c, s, y, 1, 8, '#a97e48');
      R(c, 0, y + 7, M.W, 1, '#b48850');
      if (r() > 0.7) R(c, Math.floor(r() * M.W), y + 2, 2, 1, '#b08350');
    }
    // il muro in alto, a sinistra e in basso
    R(c, 0, 0, M.W, 50, '#e9dfc9'); R(c, 0, 50, M.W, 6, '#a07a4f'); R(c, 0, 50, M.W, 1, '#c29c6b'); R(c, 0, 55, M.W, 1, '#7b5b37');
    for (var wx = 0; wx < M.W; wx += 16) R(c, wx, 0, 1, 50, '#e1d6bd');
    R(c, 0, 56, 8, M.H - 56, '#d6c8a8'); R(c, 7, 56, 1, M.H - 56, '#a07a4f');
    R(c, 0, 208, M.W, 16, '#e9dfc9'); R(c, 0, 208, M.W, 3, '#a07a4f'); R(c, 0, 211, M.W, 1, '#7b5b37');
    for (var bx = 0; bx < M.W; bx += 16) R(c, bx, 212, 1, 12, '#e1d6bd');
    // la finestra: il buco da cui si vede il cielo, il telaio, le tende
    R(c, FIN.x - 2, FIN.y - 2, FIN.w + 4, FIN.h + 4, '#8a6a46');
    c.clearRect(FIN.x, FIN.y, FIN.w, FIN.h);
    R(c, FIN.x + FIN.w / 2 - 1, FIN.y, 2, FIN.h, '#8a6a46'); R(c, FIN.x, FIN.y + 16, FIN.w, 2, '#8a6a46');
    R(c, FIN.x - 4, FIN.y + FIN.h + 1, FIN.w + 8, 3, '#b08457');
    R(c, FIN.x, FIN.y, 7, FIN.h, '#c0576a'); R(c, FIN.x + FIN.w - 7, FIN.y, 7, FIN.h, '#c0576a');
    for (var tk = 0; tk < FIN.h; tk += 4) { R(c, FIN.x + 2, FIN.y + tk, 1, 3, '#a8445a'); R(c, FIN.x + FIN.w - 5, FIN.y + tk, 1, 3, '#a8445a'); }
    // l'orologio a muro
    R(c, 81, 8, 14, 14, '#6b4b2b'); R(c, 82, 7, 12, 16, '#6b4b2b'); R(c, 82, 9, 12, 12, '#f6f1e4'); R(c, 83, 8, 10, 14, '#f6f1e4');
    // la bacheca
    var B = M.bacheca;
    R(c, B.x - 2, B.y - 2, B.w + 4, B.h + 4, '#6b4b2b'); R(c, B.x, B.y, B.w, B.h, '#c79a5d');
    for (var gx = 0; gx < 5; gx++) for (var gy = 0; gy < 2; gy++) { var cx = cellaBacheca(gx, gy); R(c, cx.x - 1, cx.y - 1, cx.w + 1, cx.h + 1, '#b08648'); R(c, cx.x, cx.y, cx.w, cx.h, '#d2a868'); }
    // la stanza di Titolare (vista in sezione): muro con la porta, pavimento, scaffale, tappeto
    var S = M.stanza;
    R(c, S.x + 4, 0, S.w - 4, 52, '#d3dcea'); R(c, S.x + 4, 52, S.w - 4, 4, '#7b8aa6');
    R(c, S.x + 4, 56, S.w - 4, 72, '#a9b7cf');
    for (var ry = 56; ry < 128; ry += 8) R(c, S.x + 4, ry, S.w - 4, 1, '#98a8c2');
    R(c, S.x - 4, 0, 8, M.porta.y, '#a07a4f'); R(c, S.x - 4, M.porta.y + M.porta.h, 8, 128 - M.porta.y - M.porta.h, '#a07a4f');
    R(c, S.x + 4, 0, 2, 128, '#8a6a46'); R(c, S.x - 4, 126, S.w + 4, 2, '#7b5b37');
    R(c, S.x - 4, M.porta.y - 3, 8, 3, '#6b4b2b'); R(c, S.x - 4, M.porta.y + M.porta.h, 8, 2, '#6b4b2b');
    R(c, S.x + 8, 94, 56, 30, '#5b7aa8'); R(c, S.x + 9, 95, 54, 28, '#6a8bbd');
    R(c, S.x + 8, 8, 24, 38, '#7a5530');
    for (var sh = 0; sh < 4; sh++) {
      R(c, S.x + 9, 10 + sh * 9, 22, 1, '#a07a4f');
      var rb = seme(40 + sh), bk = ['#c0392b', '#2e86c1', '#27ae60', '#f1c40f', '#8e44ad', '#e67e22'];
      for (var b = 0; b < 7; b++) R(c, S.x + 9 + b * 3, 3 + sh * 9 + 4 - Math.floor(rb() * 3), 2, 5 + Math.floor(rb() * 3), bk[Math.floor(rb() * bk.length)]);
    }
    // le scrivanie e le sedie
    for (var i = 0; i < M.MAX_SCRIVANIE; i++) {
      var d = M.scrivania(i);
      R(c, d.seduto.x - 6, d.seduto.y - 11, 12, 6, '#454a60'); R(c, d.seduto.x - 6, d.seduto.y - 6, 12, 7, '#555b75'); R(c, d.seduto.x - 5, d.seduto.y + 1, 10, 1, '#2b2e3c');
      R(c, d.x, d.y, d.w, d.h, '#b78552'); R(c, d.x, d.y, d.w, 1, '#d09b66'); R(c, d.x, d.y + d.h, d.w, 3, '#8c6540');
      R(c, d.x + 2, d.y + d.h + 3, 2, 3, '#6b4b2b'); R(c, d.x + d.w - 4, d.y + d.h + 3, 2, 3, '#6b4b2b');
      R(c, d.x + 7, d.y + 6, 14, 4, '#2f3140'); R(c, d.x + 8, d.y + 7, 12, 1, '#454a60');
    }
    R(c, 270, 74, 36, 12, '#a87848'); R(c, 270, 74, 36, 1, '#c79a5d'); R(c, 270, 86, 36, 3, '#7b5b37');
    R(c, 285, 98, 12, 6, '#3a4660'); R(c, 285, 104, 12, 7, '#46557a');
    // il divano e il tappeto
    R(c, 8, 168, 64, 40, '#8aa88a'); R(c, 8, 168, 64, 1, '#759475'); R(c, 8, 207, 64, 1, '#759475');
    R(c, 14, 174, 48, 10, '#7a4f6d'); R(c, 14, 184, 48, 14, '#9a6a8a'); R(c, 14, 184, 48, 1, '#7a4f6d');
    R(c, 14, 176, 5, 22, '#6a4160'); R(c, 57, 176, 5, 22, '#6a4160'); R(c, 38, 185, 1, 12, '#7a4f6d');
    // l'angolo del caffe: un bancone di legno con sopra una macchina da espresso (corpo cromato, frontale rosso, manometro, braccio
    // del filtro, tazzina sotto l'erogatore, tazzine che scaldano sul tetto) e un'insegna CAFFE, cosi si riconosce a colpo d'occhio
    R(c, 290, 134, 24, 9, '#3b2a1a'); R(c, 291, 135, 22, 7, '#f6f1e4'); U.testo(c, 'CAFFE', 293, 136, '#8a4b1f');
    R(c, 301, 143, 2, 3, '#3b2a1a');
    R(c, 289, 161, 24, 15, '#7b5232'); R(c, 289, 160, 24, 2, '#b07a4a'); R(c, 289, 175, 24, 1, '#4e321d');
    R(c, 291, 164, 9, 9, '#6b4529'); R(c, 302, 164, 9, 9, '#6b4529'); R(c, 297, 168, 2, 1, '#c9a26b'); R(c, 303, 168, 2, 1, '#c9a26b');
    R(c, 292, 147, 18, 13, '#8c929c'); R(c, 293, 147, 16, 12, '#d6dbe2'); R(c, 293, 147, 16, 1, '#f4f6f9');
    R(c, 294, 150, 14, 4, '#c0392b'); R(c, 294, 150, 14, 1, '#e05a4b');
    R(c, 295, 151, 3, 2, '#f4f6f9'); R(c, 296, 151, 1, 1, '#1d1b2b'); R(c, 305, 151, 2, 2, '#5fe08a');
    R(c, 299, 154, 4, 2, '#4a4f63'); R(c, 302, 155, 6, 1, '#2b2d3a'); R(c, 307, 154, 2, 2, '#2b2d3a');
    R(c, 298, 157, 6, 3, '#4a4f63'); R(c, 299, 156, 4, 1, '#f4f6f9');
    R(c, 299, 158, 4, 2, '#ffffff'); R(c, 303, 158, 1, 1, '#ffffff');
    R(c, 294, 145, 3, 2, '#ffffff'); R(c, 298, 145, 3, 2, '#ffffff'); R(c, 302, 145, 3, 2, '#ffffff'); R(c, 292, 146, 18, 1, '#8c929c');
    R(c, 310, 157, 3, 3, '#ffffff'); R(c, 310, 158, 1, 1, '#6b4226');
    // la macchina da gioco
    R(c, 262, 148, 20, 28, '#3a4aa8'); R(c, 262, 148, 20, 6, '#e63946'); R(c, 265, 156, 14, 11, '#0f1428'); R(c, 264, 168, 16, 7, '#2c3a8a');
    R(c, 267, 170, 2, 2, '#ffd166'); R(c, 272, 170, 2, 2, '#ef476f'); R(c, 276, 170, 2, 2, '#06d6a0');
    // l'acquario
    R(c, 96, 188, 36, 14, '#bfe4f7'); R(c, 97, 189, 34, 12, '#5fb7d9'); R(c, 97, 198, 34, 3, '#e8d8a0'); R(c, 96, 202, 36, 6, '#6b4b2b'); R(c, 98, 208, 3, 0, '#6b4b2b');
    R(c, 100, 193, 2, 5, '#2d9a5a'); R(c, 118, 191, 2, 7, '#2d9a5a'); R(c, 122, 194, 2, 4, '#3dba70');
    // il refrigeratore dell'acqua
    R(c, 146, 130, 12, 22, '#dfe6ee'); R(c, 148, 124, 8, 8, '#8fd0f0'); R(c, 148, 124, 8, 1, '#bfe4f7'); R(c, 148, 142, 3, 2, '#d1495b'); R(c, 153, 142, 3, 2, '#4a90d9');
    // il tavolo dei portatili contro il muro a sinistra, con gli sgabelli
    var T = M.tavolo;
    R(c, T.x, T.y, T.w, T.h, '#a87848'); R(c, T.x, T.y, T.w, 1, '#c79a5d'); R(c, T.x + T.w - 1, T.y, 1, T.h, '#8c6540'); R(c, T.x, T.y + T.h, T.w, 3, '#7b5b37');
    R(c, T.x + 2, T.y + T.h + 3, 2, 2, '#6b4b2b'); R(c, T.x + T.w - 4, T.y + T.h + 3, 2, 2, '#6b4b2b');
    for (var ps = 0; ps < M.POSTI_TAVOLO; ps++) { var pt = M.postoTavolo(ps); R(c, pt.x - 3, pt.y - 5, 7, 4, '#555b75'); R(c, pt.x - 2, pt.y - 1, 1, 2, '#2b2e3c'); R(c, pt.x + 2, pt.y - 1, 1, 2, '#2b2e3c'); }
    // la porta verso l'open space, nel muro a sinistra, con lo zerbino
    var PO = M.portaOpenSpace;
    R(c, PO.x, PO.y - 2, PO.w, PO.h + 4, '#6b4b2b'); R(c, PO.x + 1, PO.y, PO.w - 2, PO.h, '#3a2a1a'); R(c, PO.x + 2, PO.y + 1, 3, PO.h - 2, '#8a6a46');
    R(c, PO.x + 4, PO.y + 8, 1, 1, '#f2d34f'); R(c, PO.x + 8, PO.y + 3, 9, 10, '#7a6a5a'); R(c, PO.x + 9, PO.y + 4, 7, 8, '#8f7f6f');
    // la stazione di ricarica dello smistatore
    R(c, 8, 134, 20, 20, '#8a8fa3'); R(c, 10, 136, 16, 16, '#6c7186'); R(c, 12, 140, 12, 8, '#4a4f63'); R(c, 8, 154, 20, 1, '#555a6e');
    return cv;
  };

  function cellaBacheca(gx, gy) {
    var B = M.bacheca, w = 26, h = 18;
    return { x: B.x + 2 + gx * (w + 1), y: B.y + 2 + gy * (h + 2), w: w, h: h };
  }

  // ---- le parti che cambiano ---------------------------------------------------------------------------------------------------
  var COLORI_FOGLIETTI = ['#fff176', '#ff8fab', '#80deea', '#a5d6a7', '#ffcc80'];
  function bacheca(c, board) {
    var B = M.bacheca;
    for (var k = 0; k < 10; k++) {
      var cel = cellaBacheca(k % 5, Math.floor(k / 5));
      var col = board ? board[k] : null;
      if (!col) { if (board) continue; U.testo(c, '?', cel.x + 1, cel.y + 1, '#6b4b2b'); continue; }
      U.testo(c, col.sigla, cel.x + 1, cel.y + 1, '#3b2a1a');
      var n = String(col.conteggio);
      U.testo(c, n, cel.x + cel.w - U.larghezzaTesto(n) - 1, cel.y + 1, col.conteggio > 0 ? '#b3282d' : '#8a6a46');
      var visibili = Math.min(col.conteggio, 18);
      for (var f = 0; f < visibili; f++) {
        var fx = cel.x + 1 + (f % 6) * 4, fy = cel.y + 8 + Math.floor(f / 6) * 3;
        R(c, fx, fy, 3, 2, COLORI_FOGLIETTI[(k + f) % COLORI_FOGLIETTI.length]);
      }
    }
  }

  function orologio(c, data) {
    var h = data.getHours() % 12 + data.getMinutes() / 60, m = data.getMinutes() + data.getSeconds() / 60, s = data.getSeconds();
    var cx = 88, cy = 15;
    R(c, cx, cy - 5, 1, 1, '#6b4b2b'); R(c, cx, cy + 5, 1, 1, '#6b4b2b'); R(c, cx - 5, cy, 1, 1, '#6b4b2b'); R(c, cx + 5, cy, 1, 1, '#6b4b2b');
    function lancetta(ang, len, col) { for (var i = 0; i <= len; i++) R(c, cx + Math.round(Math.sin(ang) * i), cy - Math.round(Math.cos(ang) * i), 1, 1, col); }
    lancetta(h / 12 * Math.PI * 2, 3, '#1d1b2b'); lancetta(m / 60 * Math.PI * 2, 4, '#1d1b2b'); lancetta(s / 60 * Math.PI * 2, 5, '#d1495b');
  }

  function acquario(c, t) {
    for (var i = 0; i < 3; i++) {
      var v = 6 + i * 3, dir = i % 2 ? -1 : 1, per = 30, x = ((t * v * dir) % per + per) % per;
      var fx = 98 + x, fy = 192 + i * 2 + Math.round(Math.sin(t * 1.5 + i) * 1);
      R(c, fx, fy, 3, 2, ['#ff8a5c', '#ffd166', '#ef476f'][i]); R(c, fx - dir, fy, 1, 2, ['#ff8a5c', '#ffd166', '#ef476f'][i]);
    }
    if (Math.floor(t * 2) % 3 === 0) R(c, 126, 195 - Math.floor((t * 6) % 6), 1, 1, '#ffffff');
  }

  // il vapore sale sempre dalla tazzina sotto l'erogatore; quando qualcuno prende il caffe scende il filo di caffe e la spia lampeggia
  function vaporeCaffe(c, t, attiva) {
    for (var i = 0; i < 3; i++) {
      var k = (t * 0.8 + i / 3) % 1;
      R(c, 300 + i + Math.round(Math.sin(t * 3 + i) * 1), 156 - Math.round(k * 10), 1, 2, 'rgba(255,255,255,' + (0.7 * (1 - k)).toFixed(2) + ')');
    }
    if (attiva) {
      if (Math.floor(t * 6) % 2) R(c, 301, 157, 1, 1, '#6b4226');
      R(c, 300, 158, 2, 1, '#6b4226');
      R(c, 305, 151, 2, 2, Math.floor(t * 3) % 2 ? '#ffd166' : '#5fe08a');
    }
  }

  function macchinaGioco(c, t, attiva) {
    var col = attiva ? ['#ffd166', '#06d6a0', '#ef476f', '#4cc9f0'][Math.floor(t * 6) % 4] : '#1f3a6a';
    R(c, 267, 158 + Math.floor(t * 3) % 6, 3, 2, col); R(c, 272 + Math.floor(t * 4) % 5, 160, 3, 3, attiva ? '#ffffff' : '#35507a');
    if (!attiva && Math.floor(t * 1.5) % 2) U.testo(c, 'PLAY', 266, 162, '#3d5f9a');
  }

  function piante(c, t) {
    function pianta(x, y) {
      R(c, x, y + 8, 10, 8, '#a8651f'); R(c, x - 1, y + 8, 12, 2, '#c47a2c');
      var s = Math.round(Math.sin(t * 1.4 + x));
      R(c, x + 1 + s, y + 1, 3, 8, '#2d9a5a'); R(c, x + 6 - s, y, 3, 9, '#3dba70'); R(c, x + 3, y - 3 + s, 3, 9, '#2d9a5a'); R(c, x - 1, y + 3, 3, 5, '#3dba70'); R(c, x + 8, y + 3, 3, 5, '#2d9a5a');
    }
    pianta(66, 50); pianta(232, 194);
    R(c, 306, 54, 10, 8, '#a8651f'); R(c, 307 + Math.round(Math.sin(t * 1.2)), 46, 3, 9, '#3dba70'); R(c, 311, 44, 3, 11, '#2d9a5a');
  }

  function schermo(c, i, p, t) {
    var d = M.scrivania(i), m = d.monitor;
    R(c, m.x, m.y, m.w, m.h, '#2f3140'); R(c, m.x + 9, m.y + m.h, 4, 2, '#2f3140'); R(c, m.x + 6, m.y + m.h + 1, 10, 1, '#454a60');
    var sx = m.x + 1, sy = m.y + 1, sw = m.w - 2, sh = m.h - 2;
    if (p && p.sessione) {
      R(c, sx, sy, sw, sh, '#0c2a22');
      var id = '#' + p.sessione.id;
      U.testo(c, id, sx + 1, sy + 1, '#eafff6');
      var r = Math.floor(t * 2.5);
      for (var l = 0; l < 2; l++) {
        var len = 5 + ((r + l * 7 + i * 3) * 7) % 12;
        R(c, sx + 1, sy + 8 + l * 2, len, 1, l ? '#35c98a' : '#4df0a0');
      }
      if (Math.floor(t * 2) % 2) R(c, sx + 1 + ((r * 7) % 12) + 6, sy + 8, 1, 1, '#ffffff');
      // la tastiera lampeggia
      R(c, d.x + 7 + ((r * 5) % 12), d.y + 6, 2, 1, '#7ee8b0');
    } else {
      R(c, sx, sy, sw, sh, '#10131f');
      // salvaschermo: un quadratino che rimbalza piano
      var px = Math.abs(((t * 4 + i * 5) % (2 * (sw - 3))) - (sw - 3)), py = Math.abs(((t * 2.5 + i * 3) % (2 * (sh - 3))) - (sh - 3));
      R(c, sx + px, sy + py, 3, 3, ['#4a90d9', '#7a4fd1', '#2a9d8f', '#e76f51', '#e9c46a'][i % 5]);
    }
  }

  function pila(c, x, y, n, colore) {
    var vis = Math.min(n, 10);
    for (var k = 0; k < vis; k++) R(c, x + (k % 2), y - k, 6, 1, k % 2 ? '#e4dcc4' : '#fffdf5');
    if (vis > 0) R(c, x + 4, y - vis + 1, 2, 1, colore || '#d1495b');
    if (n > 0) {
      var s = String(n);
      U.etichetta(c, s, x + 3, y - vis - 7, n > 10 ? '#ffd166' : '#ffffff');
    }
  }

  U.pile = { pila: pila };

  // I portatili sul tavolo: acceso con l'id della sessione sullo schermo (in piccolo, una riga) se qualcuno ci lavora, spento se no.
  function portatili(c, G, t) {
    var occupati = {};
    (G.colleghi || []).forEach(function (k) { if (k.posto >= 0 && k.seduto) occupati[k.posto] = k; });
    for (var i = 0; i < M.POSTI_TAVOLO; i++) {
      var p = M.postoTavolo(i), x = M.tavolo.x + 3, y = p.y - 13;
      var k = occupati[i];
      R(c, x, y + 6, 9, 3, '#9aa0ab'); R(c, x + 1, y + 7, 7, 1, '#6c7280');
      R(c, x, y, 2, 8, '#2f3140');
      R(c, x + 1, y + 1, 1, 6, k ? (Math.floor(t * 3 + i) % 4 ? '#4df0a0' : '#35c98a') : '#10131f');
      if (k) R(c, x + 3 + Math.floor(t * 7 + i) % 5, y + 7, 1, 1, '#7ee8b0');
    }
  }
  U.portatili = portatili;

  // Tutto cio che sta sotto i personaggi. G: modello, t (secondi di gioco), ora (Date), drops (cartelline appena posate).
  U.disegnaFondo = function (c, sfondo, G) {
    var data = G.ora, ora = data.getHours() + data.getMinutes() / 60, t = G.t;
    c.clearRect(0, 0, M.W, M.H);
    cielo(c, ora, t);
    c.drawImage(sfondo, 0, 0);
    bacheca(c, G.modello ? G.modello.board : null);
    orologio(c, data);
    acquario(c, t);
    piante(c, t);
    vaporeCaffe(c, t, G.usoCaffe);
    macchinaGioco(c, t, G.usoGioco);
    // il refrigeratore: ogni tanto una bolla
    if (Math.floor(t * 1.1) % 4 === 0) R(c, 151, 128 + Math.floor((t * 5) % 5), 1, 1, '#ffffff');
    var P = G.modello ? G.modello.personaggi : [];
    for (var i = 0; i < M.MAX_SCRIVANIE; i++) {
      var p = P[i];
      schermo(c, i, p, t);
      var d = M.scrivania(i);
      if (p && p.codaTotale > 0) pila(c, d.pila.x, d.pila.y, p.codaTotale, null);
    }
    portatili(c, G, t);
    // le cartelline posate da poco sulle scrivanie
    (G.drops || []).forEach(function (dr) {
      var d = M.scrivania(dr.scrivania);
      U.cartella(c, d.appoggio.x + 5, d.appoggio.y - 1, dr.verso);
      if (Math.floor(G.t * 2) % 2 || dr.verso !== 'indietro') U.etichetta(c, '#' + dr.id, d.x + 14, d.y - 22, dr.verso === 'indietro' ? '#ff9aa8' : '#9affc0');
    });
    // la stazione dello smistatore
    U.etichetta(c, 'SMIST', 18, 157, '#ffffff');
    // la stanza di Titolare: le voci "da fare tu" sono fogli sulla sua scrivania, tanti quanti sono
    var n = G.modello ? G.modello.daFareTu.length : 0, S = M.stanza;
    var vis = Math.min(n, 16);
    for (var k = 0; k < vis; k++) R(c, M.pilaTitolare.x - 10 + (k % 2), M.pilaTitolare.y - 4 - k, 12, 1, k % 2 ? '#e4dcc4' : '#fffdf5');
    if (vis > 0) R(c, M.pilaTitolare.x - 1, M.pilaTitolare.y - 3 - vis, 3, 1, '#d1495b');
    R(c, S.x + 8, 56, 34, 14, '#2f3140'); R(c, S.x + 9, 57, 32, 12, '#10131f');
    if (G.modello && G.modello.erroreAdo) U.testo(c, 'ADO?', S.x + 11, 60, '#ff9aa8');
    else U.testo(c, 'LEGGE ' + (Math.floor(t) % 2 ? '.' : ' '), S.x + 11, 60, '#9ad1ff');
    // la targa sopra: DA FARE TU e il numero grande
    R(c, S.x + 36, 6, 28, 22, '#3a3f55'); R(c, S.x + 37, 7, 26, 20, '#f6f1e4');
    U.testo(c, 'DA FARE', S.x + 39, 9, '#1d1b2b'); U.testo(c, 'TU', S.x + 39, 16, '#1d1b2b');
    var ns = String(n);
    U.testo(c, ns, S.x + 62 - U.larghezzaTesto(ns, 2) - 1, 14, n > 0 ? '#d1495b' : '#2a9d4e', 2);
  };

  // Sopra tutto: il buio della sera, che segue l'ora vera.
  U.disegnaVelo = function (c, G) {
    var data = G.ora, ora = data.getHours() + data.getMinutes() / 60, b = bui(ora);
    if (b > 0) { c.fillStyle = 'rgba(16,24,70,' + b.toFixed(3) + ')'; c.fillRect(0, 0, M.W, M.H); }
  };

  U.coloriCielo = coloriCielo;
  U.cielo = cielo;
  U.bui = bui;
  U.cellaBacheca = cellaBacheca;
})(U);
