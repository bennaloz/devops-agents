// Il mondo: le misure dell'ufficio, la griglia dei posti dove si cammina e il percorso che evita mobili e muri.
// Niente DOM e niente disegno: ci si ragiona anche fuori dal browser.
(function (U) {
  'use strict';
  var W = 320, H = 224, T = 8, GW = W / T, GH = H / T;
  var M = { W: W, H: H, T: T, GW: GW, GH: GH };

  // Le scrivanie sono in fila contro il muro in alto, una per ruolo, nell'ordine in cui arrivano i personaggi.
  M.MAX_SCRIVANIE = 5;
  var DESK_X0 = 84, DESK_STEP = 34, DESK_W = 28;
  M.scrivania = function (i) {
    var x = DESK_X0 + i * DESK_STEP;
    return {
      x: x, y: 56, w: DESK_W, h: 12,
      monitor: { x: x + 3, y: 42, w: 22, h: 13 },
      seduto: { x: x + 14, y: 84 },
      visita: { x: x + 22, y: 92 },        // dove sta in piedi chi viene a portare qualcosa
      pila: { x: x + 22, y: 66 },
      appoggio: { x: x + 2, y: 58 }        // dove si posa la cartellina consegnata
    };
  };

  // La stanza di Titolare, a destra: ci si entra solo con gli occhi, si fa la fila davanti alla porta.
  M.stanza = { x: 252, y: 0, w: 68, h: 128 };
  M.porta = { x: 248, y: 96, w: 8, h: 24 };
  M.codaPorta = function (i) { return { x: 242 - i * 14, y: 116 }; };
  M.scrivaniaTitolare = { x: 270, y: 74, w: 36, h: 12 };
  M.pilaTitolare = { x: 274, y: 84 };
  M.bacheca = { x: 98, y: 2, w: 136, h: 40 };

  // Dove si fa cosa quando si e in pausa. Ogni posto ha un punto di arrivo (ax, ay: sempre in una cella libera) e, se serve, un punto
  // finale (x, y) in cui ci si infila (il divano). dir e dove si guarda.
  M.posti = {
    caffe: [{ ax: 302, ay: 182, x: 302, y: 182, dir: 'u' }],
    gioco: [{ ax: 272, ay: 182, x: 272, y: 182, dir: 'u' }],
    finestra: [{ ax: 24, ay: 62, x: 24, y: 62, dir: 'u' }, { ax: 42, ay: 62, x: 42, y: 62, dir: 'u' }, { ax: 60, ay: 62, x: 60, y: 62, dir: 'u' }],
    divano: [{ ax: 28, ay: 206, x: 28, y: 193, dir: 'd' }, { ax: 48, ay: 206, x: 48, y: 193, dir: 'd' }],
    chiacchiere: [
      [{ ax: 112, ay: 134, x: 112, y: 134, dir: 'r' }, { ax: 130, ay: 134, x: 130, y: 134, dir: 'l' }],
      [{ ax: 190, ay: 166, x: 190, y: 166, dir: 'r' }, { ax: 208, ay: 166, x: 208, y: 166, dir: 'l' }]
    ]
  };
  // Il tavolo dei portatili, contro il muro a sinistra: una persona per ogni sessione oltre la prima di un ruolo (la prima siede alla
  // scrivania del ruolo). Chi non trova posto e nell'open space, oltre la porta in basso a sinistra: da li si entra e si esce.
  M.POSTI_TAVOLO = 4;
  M.tavolo = { x: 8, y: 68, w: 15, h: 57 };
  M.postoTavolo = function (i) { var y = 80 + i * 14; return { ax: 28, ay: y, x: 28, y: y, dir: 'l' }; };
  M.portaOpenSpace = { x: 0, y: 158, w: 8, h: 16 };
  M.ingressoOpenSpace = { ax: 14, ay: 167, x: 14, y: 167, dir: 'r' };
  M.stazione = { ax: 18, ay: 151, x: 18, y: 151, dir: 'd' };   // dove riposa lo smistatore
  M.gatto = { x: 170, y: 190 };

  // La griglia: true dove non si passa.
  var blocco = new Array(GW * GH);
  function cella(x, y) { return { cx: Math.max(0, Math.min(GW - 1, Math.floor(x / T))), cy: Math.max(0, Math.min(GH - 1, Math.floor(y / T))) }; }
  M.cella = cella;
  function bloccaRett(x, y, w, h) {
    var a = cella(x, y), b = cella(x + w - 1, y + h - 1);
    for (var cy = a.cy; cy <= b.cy; cy++) for (var cx = a.cx; cx <= b.cx; cx++) blocco[cy * GW + cx] = true;
  }
  for (var i = 0; i < blocco.length; i++) blocco[i] = false;
  bloccaRett(0, 0, W, 56);                       // il muro in alto, con i monitor e la bacheca
  bloccaRett(0, 0, T, H);                        // il muro a sinistra
  bloccaRett(0, 208, W, 16);                     // il muro in basso
  bloccaRett(W - T, 0, T, H);                    // il muro a destra
  bloccaRett(M.stanza.x - 4, 0, M.stanza.w + 4, M.porta.y);   // la stanza di Titolare, sopra la porta
  bloccaRett(M.stanza.x - 4, M.porta.y + M.porta.h, M.stanza.w + 4, 128 - M.porta.y - M.porta.h);   // e sotto
  bloccaRett(M.stanza.x + 4, M.porta.y, M.stanza.w, M.porta.h);   // dentro la stanza non si entra
  for (var s = 0; s < M.MAX_SCRIVANIE; s++) { var d = M.scrivania(s); bloccaRett(d.x, d.y, d.w, d.h + 3); }
  bloccaRett(14, 176, 48, 23);                   // il divano
  bloccaRett(289, 134, 24, 42);                  // l'angolo del caffe: bancone, macchina da espresso e insegna
  bloccaRett(262, 148, 20, 28);                  // la macchina da gioco
  bloccaRett(96, 188, 36, 20);                   // l'acquario
  bloccaRett(146, 130, 12, 22);                  // il refrigeratore
  bloccaRett(66, 48, 10, 18);                    // il cactus davanti alla finestra
  bloccaRett(M.tavolo.x, M.tavolo.y, M.tavolo.w, M.tavolo.h);   // il tavolo dei portatili
  bloccaRett(232, 194, 12, 14);                  // la pianta in basso
  bloccaRett(8, 130, 20, 8);                     // la stazione di ricarica dello smistatore (il retro)
  M.bloccata = function (cx, cy) { return cx < 0 || cy < 0 || cx >= GW || cy >= GH || blocco[cy * GW + cx]; };

  // Il percorso piu breve fra due punti, in celle, con le diagonali solo se non tagliano un angolo. Restituisce i punti da toccare
  // (centri delle celle, senza quella di partenza) oppure null se non si arriva.
  var DIR = [[1, 0, 1], [-1, 0, 1], [0, 1, 1], [0, -1, 1], [1, 1, 1.41], [1, -1, 1.41], [-1, 1, 1.41], [-1, -1, 1.41]];
  M.percorso = function (x0, y0, x1, y1) {
    var a = cella(x0, y0), b = cella(x1, y1);
    var da = a.cy * GW + a.cx, fine = b.cy * GW + b.cx;
    if (da === fine) return [];
    var costo = new Array(GW * GH), prec = new Array(GW * GH), chiuso = new Array(GW * GH);
    for (var i = 0; i < costo.length; i++) { costo[i] = Infinity; prec[i] = -1; chiuso[i] = false; }
    costo[da] = 0;
    for (;;) {
      var cur = -1, mn = Infinity;
      for (var k = 0; k < costo.length; k++) if (!chiuso[k] && costo[k] < mn) { mn = costo[k]; cur = k; }
      if (cur < 0) return null;
      if (cur === fine) break;
      chiuso[cur] = true;
      var cx = cur % GW, cy = Math.floor(cur / GW);
      for (var j = 0; j < DIR.length; j++) {
        var nx = cx + DIR[j][0], ny = cy + DIR[j][1];
        if (M.bloccata(nx, ny)) continue;
        if (DIR[j][2] > 1 && (M.bloccata(cx + DIR[j][0], cy) || M.bloccata(cx, cy + DIR[j][1]))) continue;
        var n = ny * GW + nx, c = costo[cur] + DIR[j][2];
        if (c < costo[n]) { costo[n] = c; prec[n] = cur; }
      }
    }
    var celle = [];
    for (var p = fine; p !== da; p = prec[p]) celle.push(p);
    celle.reverse();
    // si tengono solo i punti dove la direzione cambia: in linea retta si va dritti
    var punti = [], ultimaDir = null;
    for (var q = 0; q < celle.length; q++) {
      var prima = q === 0 ? da : celle[q - 1];
      var dd = (celle[q] % GW - prima % GW) + ',' + (Math.floor(celle[q] / GW) - Math.floor(prima / GW));
      if (q > 0 && dd === ultimaDir) punti[punti.length - 1] = puntoCella(celle[q]);
      else punti.push(puntoCella(celle[q]));
      ultimaDir = dd;
    }
    return punti;
  };
  function puntoCella(n) { return { x: (n % GW) * T + T / 2, y: Math.floor(n / GW) * T + T - 1 }; }

  // Una cella libera a caso nel corridoio (per chi passeggia e per il gatto). rnd: numero casuale in [0,1).
  M.cellaLibera = function (rnd, minY) {
    for (var t = 0; t < 200; t++) {
      var cx = 2 + Math.floor(rnd() * (GW - 12)), cy = Math.floor((minY || 88) / T) + Math.floor(rnd() * 14);
      if (!M.bloccata(cx, cy) && cy < GH - 3) return puntoCella(cy * GW + cx);
    }
    return { x: 160, y: 140 };
  };

  U.M = M;
})(U);
