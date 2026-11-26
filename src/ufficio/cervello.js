// Il cervello del gioco: cosa fa ogni personaggio, un passo alla volta. Niente DOM, niente disegno.
//
// Due strati, tenuti separati di proposito:
//  - il dato vero (G.modello, dalla vista) decide SOLO: chi siede alla scrivania, chi fa la fila alla porta, chi fa una consegna e di che
//    verso, quanti fogli ci sono. Da li' vengono tutti gli id di card che la pagina mostra;
//  - la vita (la pausa, le chiacchiere, il gatto, il meteo) e' movimento di contorno: non porta id di card e non finge lavoro.
// Un personaggio non cambia mai posto di colpo: ha un piano (andare, fare, fare) e cammina lungo un percorso che evita mobili e muri.
(function (U) {
  'use strict';
  var M = U.M;
  var VEL = 34;                    // pixel al secondo
  var PESI = { caffe: 3, gioco: 2, finestra: 2, divano: 2.5, chiacchiere: 2, vaga: 1.5 };
  var ICONE_CHIACCHIERE = ['cuore', 'nota', 'domanda', 'esclama', 'stella', 'sorriso', 'puntini'];

  function Gioco(opz) {
    opz = opz || {};
    this.rnd = opz.rnd || Math.random;
    this.t = 0; this.ridotto = !!opz.ridotto; this.modello = null;
    this.salvato = null;
    this.colleghi = []; this.openSpace = [];
    this.agenti = []; this.inAttesa = []; this.drops = []; this.fatte = opz.fatte || {}; this.occ = {}; this.chat = [];
    this.usoCaffe = false; this.usoGioco = false;
    this.robot = nuovoRobot(this); this.gatto = nuovoGatto(this);
  }
  U.Gioco = Gioco;

  // ---- movimento ------------------------------------------------------------------------------------------------------------------
  function muovi(e, dt, vel) {
    var tgt = e.percorso.length ? e.percorso[0] : (e.slide || null);
    if (!tgt) { e.cammina = false; return true; }
    var dx = tgt.x - e.x, dy = tgt.y - e.y, d = Math.sqrt(dx * dx + dy * dy), passo = (vel || VEL) * dt;
    if (d <= passo) {
      e.x = tgt.x; e.y = tgt.y;
      if (e.percorso.length) e.percorso.shift(); else e.slide = null;
    } else { e.x += dx / d * passo; e.y += dy / d * passo; }
    if (d > 0.01) e.dir = Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? 'r' : 'l') : (dy > 0 ? 'd' : 'u');
    e.cammina = true; e.tPasso += dt; e.passo = Math.floor(e.tPasso * 7) % 4;
    return !e.percorso.length && !e.slide;
  }
  function avvia(e, spot) {
    var p = M.percorso(e.x, e.y, spot.ax, spot.ay) || [];
    p.push({ x: spot.ax, y: spot.ay });   // l'ultimo tratto va al punto esatto, non al centro della cella
    e.percorso = p;
    e.slide = (spot.x !== spot.ax || spot.y !== spot.ay) ? { x: spot.x, y: spot.y } : null;
  }

  // ---- il piano di un personaggio ---------------------------------------------------------------------------------------------
  // Passi: { k:'vai', spot }, { k:'fai', posa, dir, dur | fino(a), inizio(a), fine(a), tick(a,dt) }, { k:'fn', f }
  function esegui(G, e, dt, quandoVuoto) {
    var s = e.piano[0];
    if (!s) { quandoVuoto(e); return; }
    if (s.k === 'vai') {
      if (!s.avviato) { s.avviato = true; e.seduto = false; e.posa = 'in piedi'; avvia(e, s.spot); }
      if (muovi(e, dt)) { e.dir = s.spot.dir || e.dir; e.piano.shift(); }
    } else if (s.k === 'fai') {
      e.cammina = false;
      if (!s.t0 && s.t0 !== 0) { s.t0 = 0; e.posa = s.posa || 'in piedi'; if (s.dir) e.dir = s.dir; if (s.inizio) s.inizio(e); }
      s.t0 += dt;
      if (s.tick) s.tick(e, dt, s.t0);
      if (s.fino ? s.fino(e) : s.t0 >= s.dur) { if (s.fine) s.fine(e); e.posa = 'in piedi'; e.piano.shift(); }
    } else { s.f(e); e.piano.shift(); }
  }
  function libera(G, e) { (e.prenota || []).forEach(function (k) { if (G.occ[k] === e) delete G.occ[k]; }); e.prenota = []; }
  function prendi(G, e, k) { G.occ[k] = e; e.prenota.push(k); }
  function interrompi(G, e) {
    libera(G, e);
    if (e.chat) { e.chat.fatta = true; e.chat = null; }
    e.piano = []; e.percorso = []; e.slide = null; e.cammina = false; e.seduto = false; e.posa = 'in piedi'; e.bolla = null; e.portando = null; e.consegnaCorrente = null;
  }
  function durata(G, e, lo, hi) { return (lo + G.rnd() * (hi - lo)) * e.car.tempo; }
  function fumetto(G, e, icona, colore, secondi) { e.bolla = { icona: icona, colore: colore || '#1d1b2b', fino: G.t + secondi }; }

  // ---- gli agenti -----------------------------------------------------------------------------------------------------------------
  function nuovoAgente(G, ruolo, indice) {
    var pesi = {}; Object.keys(PESI).forEach(function (k) { pesi[k] = 0.35 + G.rnd() * 1.7; });
    return {
      ruolo: ruolo, indice: indice, stile: U.stile(ruolo), x: 0, y: 0, dir: 'd', passo: 0, tPasso: 0, cammina: false, posa: 'in piedi', seduto: false, t: G.rnd() * 10,
      modo: 'pausa', piano: [], percorso: [], slide: null, vuole: { lavora: false, fila: -1 }, slot: -1, portando: null, bolla: null, prenota: [], chat: null,
      ultima: '', attivita: '', car: { pesi: pesi, tempo: 0.8 + G.rnd() * 0.6 }, micro: null, microT: 4 + G.rnd() * 8, occhi: 0
    };
  }
  function spotScrivania(a) { var d = M.scrivania(a.indice); return { ax: d.seduto.x, ay: d.seduto.y, x: d.seduto.x, y: d.seduto.y, dir: 'u' }; }
  function spotVisita(i) { var d = M.scrivania(i); return { ax: d.visita.x, ay: d.visita.y, x: d.visita.x, y: d.visita.y, dir: 'u' }; }

  // Seduti al lavoro, alla scrivania o al tavolo dei portatili: si digita, ogni tanto ci si stiracchia o si beve, ma non si lascia il posto
  function faiSeduto(G, dir, fino) {
    return {
      k: 'fai', posa: 'scrivania', dir: dir, fino: fino,
      inizio: function (e) { e.seduto = true; e.microT = 5 + G.rnd() * 8; },
      tick: function (e, dt) {
        if (e.micro) { e.micro.t += dt; if (e.micro.t >= e.micro.dur) { e.micro = null; e.posa = 'scrivania'; e.microT = 6 + G.rnd() * 12; } return; }
        e.microT -= dt;
        if (e.microT <= 0) {
          e.micro = G.rnd() < 0.5 ? { posa: 'stira', dur: 1.3, t: 0 } : { posa: 'bevi', dur: 2.2, t: 0 };
          e.posa = e.micro.posa;
        }
      },
      fine: function (e) { e.seduto = false; e.micro = null; }
    };
  }
  function pianoLavoro(G, a) {
    a.modo = 'lavoro'; a.attivita = 'lavora';
    a.piano = [
      { k: 'vai', spot: spotScrivania(a) },
      faiSeduto(G, 'u', function (e) { return !e.vuole.lavora; })
    ];
  }
  function pianoFila(G, a, slot) {
    a.modo = 'fila'; a.slot = slot; a.attivita = 'in fila';
    var s = M.codaPorta(slot);
    a.piano = [{ k: 'vai', spot: { ax: s.x, ay: s.y, x: s.x, y: s.y, dir: 'r' } },
      { k: 'fai', posa: 'in piedi', dir: 'r', fino: function (e) { return e.vuole.fila !== slot; } }];
  }

  // La pausa: sceglie da solo cosa fare, con pesi e durate diversi per ognuno, cosi due fermi non fanno la stessa cosa insieme.
  function liberoQualsiasi(G, base, n) {
    var l = [];
    for (var i = 0; i < n; i++) if (!G.occ[base + i]) l.push(i);
    return l.length ? l[Math.floor(G.rnd() * l.length)] : -1;
  }
  function coppiaLibera(G) {
    var l = [];
    for (var i = 0; i < M.posti.chiacchiere.length; i++) if (!G.occ['chat' + i]) l.push(i);
    return l.length ? l[Math.floor(G.rnd() * l.length)] : -1;
  }
  function partnerPossibile(G, a) {
    var l = G.agenti.filter(function (b) { return b !== a && b.modo === 'pausa' && !b.chat && b.attivita !== 'consegna'; });
    return l.length ? l[Math.floor(G.rnd() * l.length)] : null;
  }
  function scegliPausa(G, a) {
    var o = [];
    function agg(nome, ok) { if (!ok) return; var p = PESI[nome] * a.car.pesi[nome]; if (nome === a.ultima) p *= 0.12;
      // se altri stanno gia facendo la stessa cosa si preferisce altro: due fermi non fanno la stessa cosa insieme
      G.agenti.forEach(function (b) { if (b !== a && b.modo === 'pausa' && b.attivita === nome) p *= 0.4; });
      o.push([nome, p]);
    }
    agg('caffe', !G.occ.caffe0); agg('gioco', !G.occ.gioco0); agg('finestra', liberoQualsiasi(G, 'finestra', 3) >= 0);
    agg('divano', liberoQualsiasi(G, 'divano', 2) >= 0); agg('chiacchiere', coppiaLibera(G) >= 0 && partnerPossibile(G, a) !== null); agg('vaga', true);
    var tot = 0; o.forEach(function (x) { tot += x[1]; });
    var r = G.rnd() * tot;
    for (var i = 0; i < o.length; i++) { r -= o[i][1]; if (r <= 0) return o[i][0]; }
    return 'vaga';
  }
  function pianoPausa(G, a) {
    a.modo = 'pausa';
    var nome = scegliPausa(G, a); a.ultima = nome; a.attivita = nome; a.prenota = [];
    function fineAtt(e) { libera(G, e); }
    if (nome === 'caffe') {
      prendi(G, a, 'caffe0'); var sp = M.posti.caffe[0];
      a.piano = [{ k: 'vai', spot: sp }, { k: 'fai', posa: 'bevi', dir: 'u', dur: durata(G, a, 4, 9), fine: fineAtt },
        { k: 'fn', f: function (e) { fumetto(G, e, G.rnd() < 0.5 ? 'sorriso' : 'tazza', '#6b4226', 2.5); } }, { k: 'fai', posa: 'in piedi', dir: 'd', dur: durata(G, a, 0.8, 2) }];
    } else if (nome === 'gioco') {
      prendi(G, a, 'gioco0'); var sg = M.posti.gioco[0];
      a.piano = [{ k: 'vai', spot: sg }, { k: 'fai', posa: 'gioca', dir: 'u', dur: durata(G, a, 8, 18), fine: fineAtt },
        { k: 'fn', f: function (e) { fumetto(G, e, G.rnd() < 0.5 ? 'stella' : 'esclama', '#e0a800', 2.2); } }, { k: 'fai', posa: 'in piedi', dir: 'd', dur: 1 }];
    } else if (nome === 'finestra') {
      var i = liberoQualsiasi(G, 'finestra', 3); prendi(G, a, 'finestra' + i);
      a.piano = [{ k: 'vai', spot: M.posti.finestra[i] }, {
        k: 'fai', posa: 'in piedi', dir: 'u', dur: durata(G, a, 6, 15), fine: fineAtt,
        inizio: function (e) { e.microT = 2 + G.rnd() * 4; },
        tick: function (e, dt) { e.microT -= dt; if (e.microT <= 0) { fumetto(G, e, G.rnd() < 0.5 ? 'nota' : 'puntini', '#4a5a8a', 2); e.microT = 4 + G.rnd() * 6; } }
      }];
    } else if (nome === 'divano') {
      var j = liberoQualsiasi(G, 'divano', 2); prendi(G, a, 'divano' + j);
      var dorme = G.rnd() < 0.3;
      a.piano = [{ k: 'vai', spot: M.posti.divano[j] }, { k: 'fai', posa: dorme ? 'dorme' : 'divano', dir: 'd', dur: durata(G, a, 10, 26), fine: fineAtt }];
    } else if (nome === 'chiacchiere') {
      var k = coppiaLibera(G), b = partnerPossibile(G, a);
      if (k < 0 || !b) { a.ultima = ''; return pianoPausa(G, a); }
      interrompi(G, b); b.modo = 'pausa'; b.attivita = 'chiacchiere'; b.ultima = 'chiacchiere';
      var ch = { fatta: false, pronti: 0, t: 0, dur: durata(G, a, 9, 20), parla: 0, cambio: 0, a: a, b: b };
      a.chat = ch; b.chat = ch; G.chat.push(ch);
      G.occ['chat' + k] = a; a.prenota = ['chat' + k];
      var coppia = M.posti.chiacchiere[k];
      var pronto = function () { ch.pronti++; };
      a.piano = [{ k: 'vai', spot: coppia[0] }, { k: 'fn', f: pronto }, { k: 'fai', posa: 'parla', dir: coppia[0].dir, fino: function () { return ch.fatta; }, fine: function (e) { e.chat = null; libera(G, e); } }];
      b.piano = [{ k: 'vai', spot: coppia[1] }, { k: 'fn', f: pronto }, { k: 'fai', posa: 'parla', dir: coppia[1].dir, fino: function () { return ch.fatta; }, fine: function (e) { e.chat = null; } }];
    } else {
      var n = 1 + Math.floor(G.rnd() * 3), p = [];
      for (var q = 0; q < n; q++) {
        var c = M.cellaLibera(G.rnd);
        p.push({ k: 'vai', spot: { ax: c.x, ay: c.y, x: c.x, y: c.y, dir: ['d', 'l', 'r', 'u'][Math.floor(G.rnd() * 4)] } });
        p.push({ k: 'fai', posa: 'in piedi', dur: durata(G, a, 1.2, 4.5) });
      }
      a.piano = p;
    }
  }

  // Cosa fare quando il piano e finito: dipende da cosa dice il dato.
  function quandoVuoto(G, a) {
    if (a.modo === 'consegna') a.modo = 'pausa';
    rivaluta(G, a, true);
  }
  function rivaluta(G, a, finito) {
    if (a.modo === 'consegna') return;
    if (a.vuole.lavora) { if (a.modo !== 'lavoro') { interrompi(G, a); pianoLavoro(G, a); } else if (finito) pianoLavoro(G, a); return; }
    if (a.vuole.fila >= 0) { if (a.modo !== 'fila' || a.slot !== a.vuole.fila) { interrompi(G, a); pianoFila(G, a, a.vuole.fila); } else if (finito) pianoFila(G, a, a.vuole.fila); return; }
    if (a.modo === 'lavoro' || a.modo === 'fila') { interrompi(G, a); a.modo = 'pausa'; pianoPausa(G, a); return; }
    if (finito || !a.piano.length) pianoPausa(G, a);
  }

  // ---- le consegne ----------------------------------------------------------------------------------------------------------------
  // Chi consegna si alza, prende la cartellina col suo id, attraversa l'ufficio, la posa sulla scrivania dell'altro e torna al suo posto.
  function avviaConsegna(G, a, dest, c) {
    var eraSeduto = a.seduto;
    interrompi(G, a); a.modo = 'consegna'; a.attivita = 'consegna'; a.consegnaCorrente = c;
    var portare = { id: c.id, verso: c.verso, da: c.da, a: c.a };
    a.piano = [];
    if (eraSeduto) a.piano.push({ k: 'fai', posa: 'in piedi', dir: 'u', dur: 0.6 });   // prima si alza dalla sedia
    a.piano.push({ k: 'vai', spot: spotVisita(a.indice) });
    a.piano.push({ k: 'fai', posa: 'in piedi', dir: 'u', dur: 0.7, inizio: function (e) { e.portando = portare; fumetto(G, e, c.verso === 'indietro' ? 'esclama' : 'freccia', c.verso === 'indietro' ? '#d1495b' : '#2a9d4e', 2.5); } });
    a.piano.push({ k: 'vai', spot: spotVisita(dest.indice) });
    a.piano.push({
      k: 'fai', posa: 'in piedi', dir: 'u', dur: 1.3,
      fine: function (e) {
        e.portando = null;
        G.drops = G.drops.filter(function (d) { return d.scrivania !== dest.indice; });
        G.drops.push({ scrivania: dest.indice, id: c.id, verso: c.verso, fino: G.t + 25 });
        fumetto(G, dest, c.verso === 'indietro' ? 'domanda' : 'sorriso', '#1d1b2b', 3);
      }
    });
    a.piano.push({ k: 'vai', spot: spotScrivania(a) });
    a.piano.push({ k: 'fai', posa: 'in piedi', dir: 'u', dur: 1.5, fine: function (e) { e.consegnaCorrente = null; } });
  }

  // Una consegna alla volta: due cartelline che si incrociano nello stesso corridoio si coprirebbero le etichette.
  function prossimaConsegna(G) {
    if (G.agenti.some(function (a) { return a.modo === 'consegna'; })) return;
    while (G.inAttesa.length) {
      var x = G.inAttesa.shift();
      var da = G.agenti.filter(function (a) { return a.ruolo === x.da; })[0], a = G.agenti.filter(function (b) { return b.ruolo === x.a; })[0];
      if (da && a) { avviaConsegna(G, da, a, x.c); return; }
    }
  }

  // ---- il dato nuovo ---------------------------------------------------------------------------------------------------------------
  Gioco.prototype.applica = function (modello) {
    var G = this;
    G.modello = modello;
    if (G.salvato && !G.agenti.length) ripristinaGenerale(G);
    var ruoli = modello.personaggi.slice(0, M.MAX_SCRIVANIE).map(function (p) { return p.ruolo; });
    // personaggi nuovi: compaiono dove stanno gia (un ruolo con una sessione e gia seduto), senza camminare da fuori
    ruoli.forEach(function (r, i) {
      var a = G.agenti.filter(function (x) { return x.ruolo === r; })[0];
      if (!a) { a = nuovoAgente(G, r, i); G.agenti.push(a); a.nuovo = true; }
      a.indice = i;
    });
    G.agenti = G.agenti.filter(function (a) { return ruoli.indexOf(a.ruolo) >= 0; });
    G.agenti.forEach(function (a) {
      var p = modello.personaggi.filter(function (x) { return x.ruolo === a.ruolo; })[0];
      var fila = (modello.fila || []).map(function (f) { return f.ruolo; }).indexOf(a.ruolo);
      a.vuole = { lavora: !!(p && p.sessione), fila: fila };
      a.sessione = p ? p.sessione : null;
      if (a.nuovo) { a.nuovo = false; piazza(G, a); }
    });
    // le consegne nuove: si recitano una volta sola (e non quando si riduce il movimento)
    (modello.consegne || []).forEach(function (c) {
      var chiave = c.id + '|' + c.da + '|' + c.a;
      if (G.fatte[chiave]) return;
      G.fatte[chiave] = true;
      var da = G.agenti.filter(function (x) { return x.ruolo === c.da; })[0], a = G.agenti.filter(function (x) { return x.ruolo === c.a; })[0];
      if (G.ridotto || !da || !a) return;
      G.inAttesa.push({ da: c.da, a: c.a, c: c });
    });
    prossimaConsegna(G);
    G.agenti.forEach(function (a) { if (a.piano.length === 0 || a.modo !== 'consegna') rivaluta(G, a, false); });
    aggiornaColleghi(G, modello);
    if (G.ridotto) G.metti();
    G.salvato = null;
  };

  // ---- i colleghi al tavolo dei portatili -----------------------------------------------------------------------------------------
  // Una persona per ogni sessione oltre la prima di un ruolo (modello.altreSessioni). Entra dalla porta dell'open space, siede a un posto
  // libero del tavolo e lavora finche la sessione e aperta; poi si alza ed esce dalla stessa porta. Senza posto resta nell'open space
  // (non si vede: la porta dice quanti sono). Al primo dato (o dopo un ricarico) chi lavora e gia seduto: non entra da fuori.
  function chiaveSessione(s) { return s.ruolo + '#' + s.id; }
  function aggiornaColleghi(G, modello) {
    var voluti = modello.altreSessioni || [], perChiave = {};
    voluti.forEach(function (s) { perChiave[chiaveSessione(s)] = s; });
    var primo = !G.colleghiVisti; G.colleghiVisti = true;
    G.colleghi.forEach(function (k) {
      var s = perChiave[k.chiave];
      if (s) { k.sessione = s; return; }
      if (k.modo === 'esce') return;
      // sessione finita: si alza ed esce dall'open space
      interrompi(G, k); k.modo = 'esce'; k.posto = -1;
      k.piano = [{ k: 'vai', spot: M.ingressoOpenSpace }, { k: 'fn', f: function (e) { e.via = true; } }];
    });
    var occupati = {};
    G.colleghi.forEach(function (k) { if (k.posto >= 0) occupati[k.posto] = true; });
    var presenti = {};
    G.colleghi.forEach(function (k) { if (k.modo !== 'esce') presenti[k.chiave] = true; });
    G.openSpace = [];
    var entrano = 0;   // chi entra insieme entra uno alla volta, non tutti sulla soglia
    voluti.forEach(function (s) {
      var chiave = chiaveSessione(s);
      if (presenti[chiave]) return;
      // dopo un ricarico ognuno torna al suo posto (non a uno qualsiasi: sarebbe un salto)
      var sv0 = salvatoCollega(G, chiave), posto = -1;
      if (sv0 && sv0.posto >= 0 && !occupati[sv0.posto]) posto = sv0.posto;
      for (var i = 0; posto < 0 && i < M.POSTI_TAVOLO; i++) if (!occupati[i]) posto = i;
      if (posto < 0) { G.openSpace.push(s); return; }
      occupati[posto] = true;
      var k = nuovoAgente(G, s.ruolo, -1);
      k.chiave = chiave; k.sessione = s; k.posto = posto; k.modo = 'lavoro'; k.attivita = 'lavora';
      var spot = M.postoTavolo(posto), sv = salvatoCollega(G, chiave);
      var siediSubito = G.ridotto || primo || (sv && sv.seduto);
      if (sv && !sv.seduto) { k.x = sv.x; k.y = sv.y; k.dir = sv.dir || 'r'; }
      else if (siediSubito) { k.x = spot.x; k.y = spot.y; k.dir = 'l'; }
      else { k.x = M.ingressoOpenSpace.x; k.y = M.ingressoOpenSpace.y; k.dir = 'r'; }
      var resta = function (e) { return e.modo === 'esce'; };
      if (siediSubito && !(sv && !sv.seduto)) { var f = faiSeduto(G, 'l', resta); k.piano = [f]; k.seduto = true; k.posa = 'scrivania'; f.t0 = 0; f.inizio(k); }
      // chi entra dall'open space aspetta un attimo sulla porta: il posto si libera da chi esce
      else {
        var attesa = 1.5 + 2 * entrano; entrano++;
        k.piano = [{ k: 'fai', posa: 'in piedi', dir: 'r', dur: 0.1 }, { k: 'fai', posa: 'in piedi', dir: 'r', dur: attesa, inizio: function (e) { e.nascosto = true; }, fine: function (e) { e.nascosto = false; } },
          { k: 'vai', spot: spot }, faiSeduto(G, 'l', resta)];
      }
      G.colleghi.push(k);
    });
    // chi non trova posto al tavolo lavora nell'open space, la stanza oltre la porta (openspace.js)
    if (U.OS) U.OS.aggiorna(G, G.openSpace, primo);
  }
  function salvatoCollega(G, chiave) {
    var l = G.salvato && G.salvato.colleghi ? G.salvato.colleghi.filter(function (x) { return x.chiave === chiave; }) : [];
    return l.length ? l[0] : null;
  }

  // Lo stato che sopravvive a un ricarico della pagina: dove stanno tutti, le cartelline posate da poco, il tempo del gioco.
  // Si salva a intervalli e quando la pagina si nasconde o si chiude (sessionStorage, nel gioco che lo chiama).
  Gioco.prototype.salva = function () {
    var G = this;
    return {
      quando: Date.now(), t: G.t,
      agenti: G.agenti.map(function (a) { return { ruolo: a.ruolo, x: a.x, y: a.y, dir: a.dir, modo: a.modo, slot: a.slot, seduto: !!a.seduto, consegna: a.consegnaCorrente || null }; }),
      colleghi: G.colleghi.filter(function (k) { return k.modo !== 'esce'; }).map(function (k) { return { chiave: k.chiave, posto: k.posto, x: k.x, y: k.y, dir: k.dir, seduto: !!k.seduto }; }),
      osPersone: U.OS ? U.OS.salva(G) : [],
      robot: { x: G.robot.x, y: G.robot.y }, gatto: { x: G.gatto.x, y: G.gatto.y, stato: G.gatto.stato, dir: G.gatto.dir },
      drops: G.drops.map(function (d) { return { scrivania: d.scrivania, id: d.id, verso: d.verso, resto: d.fino - G.t }; })
    };
  };
  function ripristinaGenerale(G) {
    var s = G.salvato;
    G.t = s.t + Math.max(0, (Date.now() - s.quando) / 1000);
    G.robot.x = s.robot.x; G.robot.y = s.robot.y;
    G.gatto.x = s.gatto.x; G.gatto.y = s.gatto.y; G.gatto.dir = s.gatto.dir || 'l'; G.gatto.stato = s.gatto.stato === 'cammina' ? 'siede' : s.gatto.stato;
    G.drops = s.drops.filter(function (d) { return d.resto > 0; }).map(function (d) { return { scrivania: d.scrivania, id: d.id, verso: d.verso, fino: G.t + d.resto }; });
  }
  function salvatoDi(G, ruolo) {
    var l = G.salvato ? G.salvato.agenti.filter(function (x) { return x.ruolo === ruolo; }) : [];
    return l.length ? l[0] : null;
  }
  function siediSubito(G, a) { pianoLavoro(G, a); a.piano.shift(); a.seduto = true; a.posa = 'scrivania'; a.piano[0].t0 = 0; if (a.piano[0].inizio) a.piano[0].inizio(a); }
  function piazza(G, a) {
    var sv = G.ridotto ? null : salvatoDi(G, a.ruolo);
    if (sv) {
      // la pagina si e ricaricata (la vista lo fa da sola): si riparte da dove stava, senza salti
      a.x = sv.x; a.y = sv.y; a.dir = sv.dir || 'd';
      if (a.vuole.lavora) { if (sv.seduto) siediSubito(G, a); else pianoLavoro(G, a); }
      else if (a.vuole.fila >= 0) { if (sv.modo === 'fila' && sv.slot === a.vuole.fila) { pianoFila(G, a, a.vuole.fila); a.piano.shift(); } else pianoFila(G, a, a.vuole.fila); }
      else { a.modo = 'pausa'; a.piano = [{ k: 'fai', posa: 'in piedi', dur: G.rnd() * 3 }]; }
      // una consegna interrotta dal ricarico riparte: chi la portava ricomincia da dov'e
      if (sv.consegna && a.modo !== 'consegna') G.inAttesa.unshift({ da: sv.consegna.da, a: sv.consegna.a, c: sv.consegna });
      return;
    }
    if (a.vuole.lavora) { var s = M.scrivania(a.indice); a.x = s.seduto.x; a.y = s.seduto.y; a.dir = 'u'; pianoLavoro(G, a); a.piano.shift(); a.seduto = true; a.posa = 'scrivania'; a.piano[0].t0 = 0; a.piano[0].inizio && a.piano[0].inizio(a); }
    else if (a.vuole.fila >= 0) { var q = M.codaPorta(a.vuole.fila); a.x = q.x; a.y = q.y; a.dir = 'r'; pianoFila(G, a, a.vuole.fila); a.piano.shift(); }
    else if (G.ridotto) { a.x = 96 + a.indice * 26; a.y = 126; a.dir = 'd'; a.piano = [{ k: 'fai', posa: 'in piedi', dur: 1e9 }]; a.modo = 'pausa'; }
    else { var c = M.cellaLibera(G.rnd); a.x = c.x; a.y = c.y; a.dir = 'd'; a.modo = 'pausa'; a.piano = [{ k: 'fai', posa: 'in piedi', dur: G.rnd() * 5 }]; }
  }
  // Con il movimento ridotto i personaggi stanno al loro posto: si riposizionano direttamente, senza camminare.
  Gioco.prototype.metti = function () {
    var G = this;
    G.agenti.forEach(function (a) {
      interrompi(G, a); a.cammina = false;
      if (a.vuole.lavora) { var s = M.scrivania(a.indice); a.x = s.seduto.x; a.y = s.seduto.y; a.dir = 'u'; a.modo = 'lavoro'; a.seduto = true; a.posa = 'scrivania'; a.piano = [{ k: 'fai', posa: 'scrivania', dur: 1e9 }]; }
      else if (a.vuole.fila >= 0) { var q = M.codaPorta(a.vuole.fila); a.x = q.x; a.y = q.y; a.dir = 'r'; a.modo = 'fila'; a.piano = [{ k: 'fai', posa: 'in piedi', dur: 1e9 }]; }
      else { a.x = 96 + a.indice * 26; a.y = 126; a.dir = 'd'; a.modo = 'pausa'; a.piano = [{ k: 'fai', posa: 'in piedi', dur: 1e9 }]; }
    });
  };

  // ---- lo smistatore --------------------------------------------------------------------------------------------------------------
  function nuovoRobot(G) {
    return { x: M.stazione.x, y: M.stazione.y, dir: 'd', stato: 'riposo', cammina: false, tPasso: 0, passo: 0, percorso: [], slide: null, piano: [], t: 0, ronda: false, attesa: 0 };
  }
  function pianoGiro(G, r) {
    var p = [];
    for (var i = 0; i < Math.min(M.MAX_SCRIVANIE, G.agenti.length); i++) {
      var d = M.scrivania(i);
      p.push({ k: 'vai', spot: { ax: d.x + 8, ay: 104, x: d.x + 8, y: 104, dir: 'u' } });
      p.push({ k: 'fai', posa: 'scan', dir: 'u', dur: 1.1 });
    }
    p.push({ k: 'vai', spot: M.stazione });
    p.push({ k: 'fai', posa: 'riposo', dir: 'd', dur: 1.2 });
    r.piano = p; r.ronda = true;
  }
  function passoRobot(G, r, dt) {
    var m = G.modello, inGiro = !!(m && m.smistatore && m.smistatore.inGiro === true);
    var pausa = !!(m && m.quota && (m.quota.stato === 'riserva' || m.quota.stato === 'limite'));
    r.t += dt;
    if (r.piano.length) {
      esegui(G, r, dt, function () { });
      if (!r.piano.length) { r.ronda = false; r.attesa = 2; }
      return;
    }
    r.cammina = false;
    if (inGiro) {
      r.stato = 'giro'; r.attesa -= dt;
      if (r.attesa <= 0) pianoGiro(G, r);
    } else {
      r.stato = pausa ? 'dorme' : 'riposo';
      // un giro interrotto lo lascia fuori posto: torna alla stazione
      if (Math.abs(r.x - M.stazione.x) > 1 || Math.abs(r.y - M.stazione.y) > 1) r.piano = [{ k: 'vai', spot: M.stazione }];
    }
  }

  // ---- il gatto -------------------------------------------------------------------------------------------------------------------
  function nuovoGatto(G) { return { x: M.gatto.x, y: M.gatto.y, dir: 'l', stato: 'siede', cammina: false, tPasso: 0, passo: 0, percorso: [], slide: null, t: 0, timer: 2 + G.rnd() * 4 }; }
  function passoGatto(G, g, dt) {
    g.t += dt;
    if (g.stato === 'cammina') {
      if (muovi(g, dt, 20)) { g.stato = 'siede'; g.timer = 3 + G.rnd() * 9; }
      if (g.percorso.length === 0 && !g.slide) g.cammina = false;
      g.dir = (g.dir === 'r' || g.dir === 'l') ? g.dir : 'l';
      return;
    }
    g.cammina = false; g.timer -= dt;
    if (g.timer <= 0) {
      var r = G.rnd();
      if (r < 0.55) {
        var c = M.cellaLibera(G.rnd, 100), p = M.percorso(g.x, g.y, c.x, c.y);
        if (p) { g.percorso = p; g.slide = null; g.stato = 'cammina'; }
        else g.timer = 2;
      } else if (r < 0.8) { g.stato = 'dorme'; g.timer = 10 + G.rnd() * 20; }
      else { g.stato = 'siede'; g.timer = 3 + G.rnd() * 6; }
    }
  }

  // ---- un passo di gioco -----------------------------------------------------------------------------------------------------------
  Gioco.prototype.passo = function (dt) {
    var G = this;
    G.t += dt;
    if (G.ridotto) return;
    G.drops = G.drops.filter(function (d) { return d.fino > G.t; });
    G.chat = G.chat.filter(function (c) { return !c.fatta || c.a.chat === c || c.b.chat === c; });
    G.chat.forEach(function (c) {
      if (c.a.modo !== 'pausa' || c.b.modo !== 'pausa') { c.fatta = true; return; }
      if (c.pronti >= 2 && !c.fatta) {
        c.t += dt; c.cambio -= dt;
        if (c.cambio <= 0) {
          c.parla = 1 - c.parla; c.cambio = 1.4 + G.rnd() * 1.4;
          var chi = c.parla ? c.a : c.b;
          fumetto(G, chi, ICONE_CHIACCHIERE[Math.floor(G.rnd() * ICONE_CHIACCHIERE.length)], ['#d1495b', '#2a7de1', '#2a9d4e', '#c97a00'][Math.floor(G.rnd() * 4)], c.cambio - 0.1);
        }
        if (c.t >= c.dur) c.fatta = true;
      }
    });
    G.agenti.forEach(function (a) {
      a.t += dt;
      if (a.bolla && a.bolla.fino <= G.t) a.bolla = null;
      a.occhi -= dt; if (a.occhi < -3.2 - (a.indice % 3)) a.occhi = 0.14;
      esegui(G, a, dt, function (e) { quandoVuoto(G, e); });
    });
    G.usoCaffe = G.agenti.some(function (a) { return a.posa === 'bevi' && a.modo === 'pausa'; });
    G.usoGioco = G.agenti.some(function (a) { return a.posa === 'gioca'; });
    prossimaConsegna(G);
    G.colleghi.forEach(function (k) {
      k.t += dt;
      if (k.bolla && k.bolla.fino <= G.t) k.bolla = null;
      esegui(G, k, dt, function () { });
    });
    G.colleghi = G.colleghi.filter(function (k) { return !k.via; });
    if (U.OS) U.OS.passo(G, dt);
    passoRobot(G, G.robot, dt);
    passoGatto(G, G.gatto, dt);
  };

  // Chi aveva chiesto meno movimento sceglie di vederlo: i personaggi ripartono da dove stanno.
  Gioco.prototype.sciogli = function () {
    var G = this; G.ridotto = false;
    G.agenti.forEach(function (a) { interrompi(G, a); a.modo = 'pausa'; rivaluta(G, a, true); });
  };

  // Per i test e per guardare: cosa fa ognuno adesso.
  Gioco.prototype.diag = function () {
    return this.agenti.map(function (a) { return { ruolo: a.ruolo, modo: a.modo, attivita: a.attivita, posa: a.posa, x: Math.round(a.x), y: Math.round(a.y), cammina: a.cammina }; });
  };
})(U);
