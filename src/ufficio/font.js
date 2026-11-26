// Il font a pixel (3x5) e le icone dei fumetti. Tutto disegnato da codice: nessun font ne immagine scaricati.
// Nel canvas finiscono solo cifre, sigle di ruolo e parole fisse: i titoli delle card non vengono mai disegnati qui.
var U = {};
(function (U) {
  'use strict';
  // ogni glifo: cinque righe da tre colonne, separate da /
  var T = {
    A: '.X./X.X/XXX/X.X/X.X', B: 'XX./X.X/XX./X.X/XX.', C: '.XX/X../X../X../.XX', D: 'XX./X.X/X.X/X.X/XX.', E: 'XXX/X../XX./X../XXX',
    F: 'XXX/X../XX./X../X..', G: '.XX/X../X.X/X.X/.XX', H: 'X.X/X.X/XXX/X.X/X.X', I: 'XXX/.X./.X./.X./XXX', J: '..X/..X/..X/X.X/.X.',
    K: 'X.X/X.X/XX./X.X/X.X', L: 'X../X../X../X../XXX', M: 'X.X/XXX/XXX/X.X/X.X', N: 'XX./X.X/X.X/X.X/X.X', O: '.X./X.X/X.X/X.X/.X.',
    P: 'XX./X.X/XX./X../X..', Q: '.X./X.X/X.X/XX./.XX', R: 'XX./X.X/XX./X.X/X.X', S: '.XX/X../.X./..X/XX.', T: 'XXX/.X./.X./.X./.X.',
    U: 'X.X/X.X/X.X/X.X/XXX', V: 'X.X/X.X/X.X/X.X/.X.', W: 'X.X/X.X/XXX/XXX/X.X', X: 'X.X/X.X/.X./X.X/X.X', Y: 'X.X/X.X/.X./.X./.X.',
    Z: 'XXX/..X/.X./X../XXX',
    0: 'XXX/X.X/X.X/X.X/XXX', 1: '.X./XX./.X./.X./XXX', 2: 'XX./..X/.X./X../XXX', 3: 'XX./..X/.X./..X/XX.', 4: 'X.X/X.X/XXX/..X/..X',
    5: 'XXX/X../XX./..X/XX.', 6: '.XX/X../XXX/X.X/XXX', 7: 'XXX/..X/.X./.X./.X.', 8: 'XXX/X.X/XXX/X.X/XXX', 9: 'XXX/X.X/XXX/..X/XX.',
    '#': 'X.X/XXX/X.X/XXX/X.X', '!': '.X./.X./.X./.../.X.', '?': 'XX./..X/.X./.../.X.', '.': '.../.../.../.../.X.', ':': '.../.X./.../.X./...',
    '-': '.../.../XXX/.../...', '+': '.../.X./XXX/.X./...', '%': 'X.X/..X/.X./X../X.X', '/': '..X/..X/.X./X../X..', x: '.../X.X/.X./X.X/...', ' ': '.../.../.../.../...'
  };
  var G = {};
  Object.keys(T).forEach(function (k) { G[k] = T[k].split('/').join(''); });
  var LARG = 4; // 3 colonne + 1 di spazio

  // Scrive un testo in pixel. 'rect' e il disegno di un rettangolo pieno sul contesto.
  U.testo = function (ctx, s, x, y, colore, scala) {
    scala = scala || 1;
    ctx.fillStyle = colore;
    s = String(s).toUpperCase();
    for (var i = 0; i < s.length; i++) {
      var g = G[s.charAt(i)];
      if (g) {
        for (var k = 0; k < 15; k++) {
          if (g.charAt(k) === 'X') ctx.fillRect(x + (k % 3) * scala, y + Math.floor(k / 3) * scala, scala, scala);
        }
      }
      x += LARG * scala;
    }
  };
  U.larghezzaTesto = function (s, scala) { return String(s).length * LARG * (scala || 1) - (scala || 1); };
  // Testo con un fondo scuro dietro, leggibile su qualunque colore.
  U.etichetta = function (ctx, s, x, y, colore, fondo) {
    var w = U.larghezzaTesto(s) + 3;
    ctx.fillStyle = fondo || '#1d1b2b';
    ctx.fillRect(x - Math.floor(w / 2), y - 1, w, 7);
    U.testo(ctx, s, x - Math.floor(w / 2) + 2, y, colore || '#ffffff');
  };

  // Le icone dei fumetti, 7x7, un solo colore. Simboli, mai testo di lavoro.
  U.icone = {
    cuore: ['.XX.XX.', 'XXXXXXX', 'XXXXXXX', '.XXXXX.', '..XXX..', '...X...', '.......'],
    nota: ['...XXX.', '...X..X', '...X...', '...X...', '.XXX...', 'XXXX...', '.XX....'],
    domanda: ['.XXXXX.', 'XX...XX', '....XX.', '...XX..', '...X...', '.......', '...X...'],
    esclama: ['..XXX..', '..XXX..', '..XXX..', '..XXX..', '.......', '..XXX..', '..XXX..'],
    stella: ['...X...', '...X...', 'XXXXXXX', '.XXXXX.', '..XXX..', '.XX.XX.', 'XX...XX'],
    sorriso: ['.XXXXX.', 'X.....X', 'X.X.X.X', 'X.....X', 'X.X.X.X', 'X..XXXX', '.XXXXX.'],
    tazza: ['.......', 'XXXXXX.', 'X....XX', 'X....X.', 'X....XX', '.XXXX..', '.......'],
    zeta: ['.XXXXX.', '....XX.', '...XX..', '..XX...', '.XXXXX.', '.......', '.......'],
    puntini: ['.......', '.......', '.......', 'X.X.X..', '.......', '.......', '.......'],
    freccia: ['...X...', '....X..', 'XXXXXX.', '....X..', '...X...', '.......', '.......'],
    indietro: ['...X...', '..X....', '.XXXXXX', '..X....', '...X...', '.......', '.......']
  };
  U.icona = function (ctx, nome, x, y, colore) {
    var b = U.icone[nome];
    if (!b) return;
    ctx.fillStyle = colore;
    for (var r = 0; r < b.length; r++) {
      for (var c = 0; c < b[r].length; c++) if (b[r].charAt(c) === 'X') ctx.fillRect(x + c, y + r, 1, 1);
    }
  };
  // Un fumetto con un'icona (o un testo corto di sole cifre) sopra la testa: cx,y = centro e punta della coda.
  U.fumetto = function (ctx, icona, cx, y, colore, sfondo) {
    var w = 11, h = 11, x = cx - 5, top = y - h - 2;
    ctx.fillStyle = '#1d1b2b';
    ctx.fillRect(x, top + 1, w, h - 2); ctx.fillRect(x + 1, top, w - 2, h);
    ctx.fillStyle = sfondo || '#ffffff';
    ctx.fillRect(x + 1, top + 2, w - 2, h - 4); ctx.fillRect(x + 2, top + 1, w - 4, h - 2);
    ctx.fillStyle = '#1d1b2b';
    ctx.fillRect(cx - 1, top + h, 3, 1); ctx.fillRect(cx, top + h + 1, 1, 1);
    ctx.fillStyle = sfondo || '#ffffff';
    ctx.fillRect(cx, top + h - 1, 1, 1);
    U.icona(ctx, icona, x + 2, top + 2, colore);
  };
})(U);
