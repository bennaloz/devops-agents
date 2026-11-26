// I personaggi: un disegno per ruolo (colori e dettagli diversi, riconoscibili a colpo d'occhio), il robot dello smistatore e il gatto.
// Tutto con rettangoli: nessuna immagine. Le posizioni sono i piedi al centro (x, y).
(function (U) {
  'use strict';
  function R(c, x, y, w, h, col) { c.fillStyle = col; c.fillRect(Math.round(x), Math.round(y), w, h); }

  var BASE = { pelle: '#f2c6a0', capelli: '#3b2a1a', top: '#777777', dettaglio: '#bbbbbb', pantaloni: '#33384a', scarpe: '#1d1b2b', acc: '' };
  U.stili = {
    responsabile: { pelle: '#f2c6a0', capelli: '#4a2f1b', top: '#7a4fd1', dettaglio: '#c9b6f7', acc: 'cravatta', sigla: 'RESP' },
    dev: { pelle: '#e0a97f', capelli: '#1d1d1d', top: '#2a9d8f', dettaglio: '#8fe0d4', acc: 'cuffie', sigla: 'DEV' },
    reviewer: { pelle: '#f6d3b3', capelli: '#e9c46a', top: '#e76f51', dettaglio: '#ffd0c2', acc: 'occhiali', sigla: 'REV' },
    collaudatore: { pelle: '#c68642', capelli: '#2b2b2b', top: '#f4f1ea', dettaglio: '#2a9d4e', acc: 'camice', sigla: 'COLL' },
    mentore: { pelle: '#f0c9a6', capelli: '#c9ccd1', top: '#8a5a2b', dettaglio: '#d9b27c', acc: 'barba', sigla: 'MENT' },
    titolare: { pelle: '#f0c9a6', capelli: '#5a3a22', top: '#3a6ea5', dettaglio: '#a9c8e8', acc: '', sigla: 'RIC' }
  };
  U.stile = function (ruolo) {
    var s = U.stili[ruolo];
    if (s) return Object.assign({}, BASE, s);
    // un ruolo nuovo, senza disegno suo: colore dal nome, sigla dalle prime lettere
    var h = 0; for (var i = 0; i < ruolo.length; i++) h = (h * 31 + ruolo.charCodeAt(i)) % 360;
    return Object.assign({}, BASE, { top: 'hsl(' + h + ',55%,50%)', dettaglio: 'hsl(' + h + ',55%,75%)', capelli: '#2b2b2b', sigla: ruolo.slice(0, 4).toUpperCase() });
  };

  // o: { x, y, dir ('d','u','l','r'), passo (0-3), cammina, posa, t (secondi), stile }
  // pose: 'in piedi', 'scrivania' (digita; con seduto: true sta seduto di schiena), 'stira', 'bevi', 'gioca', 'divano', 'dorme', 'parla'
  U.persona = function (c, o) {
    var s = o.stile, x = Math.round(o.x), y = Math.round(o.y), dir = o.dir, posa = o.posa || 'in piedi';
    var cam = !!o.cammina, passo = o.passo | 0;
    var seduto = !!o.seduto, divano = posa === 'divano' || posa === 'dorme';
    R(c, x - 5, y - 1, 10, 2, 'rgba(0,0,0,0.22)');
    var su = cam && (passo % 2 === 1) ? 1 : 0;      // il corpo sale un pixel a ogni mezzo passo
    var by = y - su;
    var dy = seduto ? 3 : (divano ? 2 : 0);          // da seduti si sta piu in basso
    // gambe
    if (!seduto) {
      var lungaS = 3, lungaD = 3;
      if (cam) { if (passo === 0) lungaD = 2; else if (passo === 2) lungaS = 2; }
      if (divano) { R(c, x - 3, y - 3, 3, 2, s.pantaloni); R(c, x + 1, y - 3, 3, 2, s.pantaloni); R(c, x - 3, y - 1, 3, 1, s.scarpe); R(c, x + 1, y - 1, 3, 1, s.scarpe); }
      else {
        R(c, x - 3, y - lungaS, 3, lungaS, s.pantaloni); R(c, x + 1, y - lungaD, 3, lungaD, s.pantaloni);
        R(c, x - 3, y - 1, 3, 1, s.scarpe); R(c, x + 1, y - 1, 3, 1, s.scarpe);
      }
    }
    // busto e braccia
    var ty = by - 9 + dy;
    R(c, x - 4, ty, 8, 6, s.top);
    if (s.acc === 'camice') { R(c, x - 4, ty, 8, 1, s.dettaglio); if (dir === 'd') R(c, x + 1, ty + 2, 2, 2, s.dettaglio); }
    if (s.acc === 'cravatta' && dir === 'd') { R(c, x - 1, ty, 2, 4, '#d1495b'); R(c, x - 4, ty, 3, 1, s.dettaglio); R(c, x + 1, ty, 3, 1, s.dettaglio); }
    if (s.acc === 'cuffie' && dir === 'd') R(c, x - 4, ty + 5, 8, 1, s.dettaglio);
    var bS = 0, bD = 0, t = o.t || 0;
    if (cam) { bS = passo === 0 ? 1 : (passo === 2 ? -1 : 0); bD = -bS; }
    var braccioSu = false, tazza = false;
    if (posa === 'stira') braccioSu = true;
    if (posa === 'bevi') tazza = true;
    if (posa === 'parla') { bD = (Math.floor(t * 3) % 2) ? -3 : 0; }
    if (posa === 'scrivania') { bS = (Math.floor(t * 9) % 2); bD = 1 - bS; }
    if (posa === 'gioca') { bS = (Math.floor(t * 8) % 2) * -1; bD = (Math.floor(t * 6) % 2) * -1; }
    if (braccioSu) {
      R(c, x - 6, ty - 8, 2, 9, s.top); R(c, x + 4, ty - 8, 2, 9, s.top); R(c, x - 6, ty - 10, 2, 2, s.pelle); R(c, x + 4, ty - 10, 2, 2, s.pelle);
    } else if (tazza) {
      R(c, x - 6, ty + 1, 2, 5, s.top); R(c, x + 4, ty - 3, 2, 6, s.top);
      R(c, x + 3, ty - 6, 4, 4, '#f5f5f5'); R(c, x + 4, ty - 5, 2, 2, '#6b4226');
    } else {
      R(c, x - 6, ty + 1 + bS, 2, 5, s.top); R(c, x + 4, ty + 1 + bD, 2, 5, s.top);
      R(c, x - 6, ty + 5 + bS, 2, 1, s.pelle); R(c, x + 4, ty + 5 + bD, 2, 1, s.pelle);
    }
    // testa
    var hy = by - 16 + dy + (o.posa === 'dorme' ? 1 : 0);
    R(c, x - 4, hy, 8, 7, s.pelle);
    if (dir === 'u') {
      R(c, x - 4, hy, 8, 7, s.capelli);
      if (s.acc === 'camice') R(c, x - 4, hy, 8, 3, s.dettaglio);
    } else {
      R(c, x - 4, hy, 8, 3, s.capelli);
      if (dir === 'd') { R(c, x - 4, hy + 3, 1, 2, s.capelli); R(c, x + 3, hy + 3, 1, 2, s.capelli); }
      if (dir === 'l') R(c, x + 1, hy + 3, 3, 3, s.capelli);
      if (dir === 'r') R(c, x - 4, hy + 3, 3, 3, s.capelli);
      if (s.acc === 'camice') { R(c, x - 4, hy, 8, 3, s.dettaglio); R(c, x - 4, hy + 3, 8, 1, '#f2d34f'); }
      // occhi
      var chiusi = o.posa === 'dorme' || (o.blink);
      if (dir === 'd') {
        if (chiusi) { R(c, x - 3, hy + 4, 2, 1, '#1d1b2b'); R(c, x + 1, hy + 4, 2, 1, '#1d1b2b'); }
        else { R(c, x - 2, hy + 3, 1, 2, '#1d1b2b'); R(c, x + 1, hy + 3, 1, 2, '#1d1b2b'); }
      } else {
        var ex = dir === 'l' ? x - 3 : x + 2;
        if (chiusi) R(c, ex - (dir === 'l' ? 0 : 1), hy + 4, 2, 1, '#1d1b2b'); else R(c, ex, hy + 3, 1, 2, '#1d1b2b');
      }
      if (s.acc === 'occhiali') {
        if (dir === 'd') { R(c, x - 3, hy + 2, 3, 1, '#b3282d'); R(c, x + 1, hy + 2, 3, 1, '#b3282d'); R(c, x - 3, hy + 5, 3, 1, '#b3282d'); R(c, x + 1, hy + 5, 3, 1, '#b3282d'); }
        else R(c, dir === 'l' ? x - 4 : x + 1, hy + 2, 3, 1, '#b3282d');
      }
      if (s.acc === 'barba') {
        if (dir === 'd') { R(c, x - 3, hy + 5, 6, 2, '#e3e5e8'); }
        else R(c, dir === 'l' ? x - 4 : x + 1, hy + 5, 3, 2, '#e3e5e8');
      }
    }
    if (s.acc === 'cuffie') {
      R(c, x - 4, hy - 1, 8, 1, '#555a66');
      if (dir === 'd' || dir === 'u') { R(c, x - 5, hy + 2, 1, 4, '#555a66'); R(c, x + 4, hy + 2, 1, 4, '#555a66'); }
      else R(c, x - 1, hy + 2, 2, 4, '#555a66');
    }
    if (s.acc === 'barba' && dir === 'u') R(c, x - 4, hy + 3, 8, 3, s.capelli);
    if (o.cartella) U.cartella(c, x, by - 6 + dy, o.cartella.verso);
  };

  // La cartellina che si porta in mano: verde se si va avanti nel flusso, rossa con un segno se e un rimando indietro, azzurra
  // se il passaggio non e ne l'uno ne l'altro (il mentore). L'id lo scrive l'etichetta sopra la testa.
  U.cartella = function (c, x, y, verso) {
    var col = verso === 'indietro' ? '#d1495b' : (verso === 'avanti' ? '#3fae5a' : '#4a90d9');
    R(c, x - 5, y, 10, 7, '#1d1b2b'); R(c, x - 4, y + 1, 8, 5, col); R(c, x - 4, y - 1, 4, 2, col);
    R(c, x - 3, y + 2, 6, 1, 'rgba(255,255,255,0.7)');
    if (verso === 'indietro') R(c, x - 1, y + 3, 2, 2, '#ffffff');
  };

  // Lo smistatore: un robot a ruote. stato: 'riposo' (occhio blu), 'giro' (occhio verde, vassoio), 'dorme' (occhio spento).
  U.robot = function (c, o) {
    var x = Math.round(o.x), y = Math.round(o.y), t = o.t || 0;
    R(c, x - 6, y - 1, 12, 2, 'rgba(0,0,0,0.22)');
    var su = o.cammina && (Math.floor(t * 8) % 2) ? 1 : 0;
    R(c, x - 6, y - 3, 4, 3, '#2b2d3a'); R(c, x + 2, y - 3, 4, 3, '#2b2d3a');
    R(c, x - 5, y - 11 - su, 10, 8, '#aab4c4'); R(c, x - 5, y - 4 - su, 10, 1, '#7d8799');
    R(c, x - 4, y - 17 - su, 8, 6, '#c7cfdc'); R(c, x - 4, y - 12 - su, 8, 1, '#7d8799');
    var occhio = o.stato === 'giro' ? '#5fe08a' : (o.stato === 'dorme' ? '#3a3f55' : '#57a8ff');
    R(c, x - 3, y - 15 - su, 6, 2, '#1d1b2b'); R(c, x - 2, y - 15 - su, 4, 2, occhio);
    R(c, x, y - 21 - su, 1, 4, '#7d8799');
    var led = o.stato === 'dorme' ? '#5b2a2a' : (Math.floor(t * 2) % 2 ? '#ff6b6b' : '#8a2f2f');
    R(c, x - 1, y - 23 - su, 3, 2, led);
    if (o.stato === 'giro') { R(c, x - 6, y - 8 - su, 3, 4, '#f4f1ea'); R(c, x - 6, y - 9 - su, 3, 1, '#d9d4c7'); }
    R(c, x + 5, y - 8 - su, 2, 2, '#aab4c4');
  };

  // Il gatto di casa. stato: 'cammina', 'siede', 'dorme'. dir: 'l' o 'r'.
  U.gatto = function (c, o) {
    var x = Math.round(o.x), y = Math.round(o.y), t = o.t || 0, f = o.dir === 'l' ? -1 : 1, col = '#d98a3d';
    R(c, x - 4, y - 1, 9, 2, 'rgba(0,0,0,0.2)');
    if (o.stato === 'dorme') {
      R(c, x - 4, y - 4, 9, 4, col); R(c, x - 5, y - 4, 2, 3, col); R(c, x - 4, y - 5, 1, 1, '#a8651f'); R(c, x - 2, y - 5, 1, 1, '#a8651f');
      R(c, x + 2, y - 3, 3, 1, '#a8651f');
      if (Math.floor(t * 1.2) % 2) R(c, x + 5, y - 7, 1, 1, '#ffffff');
      return;
    }
    var sw = Math.floor(t * 3) % 2;
    var passo = o.stato === 'cammina' ? Math.floor(t * 8) % 2 : 0;
    R(c, x - 3 * f - (f > 0 ? 0 : 3), y - 5, 6, 3, col);
    R(c, x + 2 * f - (f > 0 ? 0 : 2), y - 7, 3, 3, col);
    R(c, x + 2 * f - (f > 0 ? 0 : 2), y - 8, 1, 1, '#a8651f'); R(c, x + 4 * f - (f > 0 ? 0 : 1), y - 8, 1, 1, '#a8651f');
    R(c, x - 3 * f - (f > 0 ? 0 : 3), y - 3, 1, 3 - passo, col); R(c, x + 1 * f - (f > 0 ? 0 : 1), y - 3, 1, 2 + passo, col);
    R(c, x - 4 * f - (f > 0 ? 0 : 1), y - 7 + sw, 1, 4, col);
  };
})(U);
