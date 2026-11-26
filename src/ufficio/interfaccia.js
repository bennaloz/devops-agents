// L'interfaccia a fianco del canvas: la scheda che si apre cliccando, gli avvisi, l'elenco in testo e la lista delle consegne.
// Ogni testo che arriva dai dati (titoli, nomi) entra nella pagina SOLO come testo (textContent): mai come markup.
(function (U) {
  'use strict';
  var TITOLI = { responsabile: 'Responsabile', dev: 'Dev', reviewer: 'Reviewer', collaudatore: 'Collaudatore', mentore: 'Mentore', supervisore: 'Supervisore' };
  // Chi e' ciascun ruolo, in una riga (dai brief dei ruoli): serve a chi guarda e non sa chi sia, per esempio il mentore.
  var DESCRIZIONI = {
    responsabile: 'Prende la richiesta, decide quello che il repo sa decidere e la segue fino alla PR e al deploy in Test.',
    dev: 'Implementa la card in un worktree, con i test.',
    reviewer: 'Rivede le modifiche prima della PR: correttezza e regole di sviluppo.',
    collaudatore: 'Prova la card nell\'ambiente di Test.',
    mentore: 'Parte quando un superiore corregge un ruolo: ricava la lezione e la scrive nella memoria di quel ruolo. Non tocca il codice delle card.'
  };
  U.descrizioneRuolo = function (r) { return DESCRIZIONI[r] || ''; };
  U.titoloRuolo = function (r) { return TITOLI[r] || (String(r).charAt(0).toUpperCase() + String(r).slice(1)); };

  function el(tag, testo, classe) {
    var e = document.createElement(tag);
    if (testo !== undefined && testo !== null) e.textContent = String(testo);
    if (classe) e.className = classe;
    return e;
  }
  // Un collegamento solo se l'indirizzo e' http o https: un indirizzo dei dati non puo' essere uno script.
  function collegamento(testo, url) {
    if (typeof url === 'string' && /^https?:\/\//i.test(url)) {
      var a = el('a', testo); a.href = url; a.target = '_blank'; a.rel = 'noopener noreferrer'; return a;
    }
    return el('span', testo);
  }
  function titolo(t) { return t ? String(t) : '(senza titolo)'; }
  function riga(lista, etichetta, valore) {
    var li = el('li'); li.appendChild(el('strong', etichetta + ': ')); li.appendChild(typeof valore === 'object' && valore ? valore : document.createTextNode(String(valore))); lista.appendChild(li);
  }
  function cardLink(c) { return collegamento('#' + c.id + ' ' + titolo(c.titolo), c.urlCard); }
  function ora(s) { var d = new Date(s); return isNaN(d) ? '?' : d.toLocaleString('it-IT'); }
  function percento(v) { return (v === null || v === undefined) ? '?' : Math.round(v * 100) + '%'; }

  // La voce di "Da fare tu" per una card: dice perche' Titolare e' aspettato (verbo e testo vengono dal dato).
  function voceDi(m, id) { return (m.daFareTu || []).filter(function (v) { return v.id === id; })[0] || null; }
  function cosaServe(v) { return v ? (v.verbo || '') + (v.testo ? ': ' + v.testo : '') : ''; }

  U.testoQuota = function (q) {
    if (!q) return '';
    if (q.stato === 'riserva') return 'Riserva settimanale raggiunta: uso ' + percento(q.uso) + ', soglia ' + percento(q.soglia) + '. Lo smistatore e\' in pausa e non lancia sessioni nuove fino al ' + ora(q.fino) + '.';
    if (q.stato === 'limite') {
      var quale = q.finestra === 'cinqueOre' ? 'delle 5 ore' : (q.finestra === 'settimana' ? 'settimanale' : 'di token');
      var usato = (q.usoFinestra !== null && q.usoFinestra !== undefined) ? ' (usato ' + percento(q.usoFinestra) + ')' : '';
      return 'Pausa per il limite ' + quale + usato + ': lo smistatore non lancia sessioni nuove fino al ' + ora(q.fino) + '. Non e la riserva settimanale.';
    }
    // la soglia che conta e quella effettiva della vista: alzata a mano fino al reset, o la riserva ignorata
    if (q.stato === 'libera') return 'Quota: uso ' + percento(q.uso) + ', soglia ' + percento(q.soglia) + (q.alzata ? ' (alzata dalla vista fino al reset)' : '') + (q.ignorata ? '; riserva ignorata fino al reset' : '') + '.';
    return 'Quota: non si sa (nessuna lettura).';
  };

  // La frase vera su un personaggio: la stessa informazione del disegno, in testo. Nessun movimento di scena.
  U.frasePersonaggio = function (p, fila, m) {
    var parti = [];
    if (p.sessione) parti.push('al lavoro sulla card #' + p.sessione.id + ' ' + titolo(p.sessione.titolo));
    else parti.push('nessuna sessione in corso');
    if (fila) { var v = m ? voceDi(m, fila.id) : null; parti.push('aspetta Titolare sulla card #' + fila.id + (v ? ' ' + titolo(v.titolo) + ' (' + cosaServe(v) + ')' : '')); }
    parti.push(p.codaTotale + ' card in coda');
    return parti.join(' \u00b7 ');
  };
  // la riga dell'elenco con i collegamenti alle card (sessione e card che aspetta Titolare)
  U.rigaPersonaggio = function (p, fila, m) {
    var f = document.createDocumentFragment();
    function sep() { f.appendChild(document.createTextNode(' \u00b7 ')); }
    if (p.sessione) { f.appendChild(document.createTextNode('al lavoro sulla card ')); f.appendChild(cardLink(p.sessione)); }
    else f.appendChild(document.createTextNode('nessuna sessione in corso'));
    if (fila) {
      var v = voceDi(m, fila.id); sep();
      f.appendChild(document.createTextNode('aspetta Titolare sulla card '));
      f.appendChild(cardLink(v || { id: fila.id, titolo: null, urlCard: null }));
      if (v) f.appendChild(document.createTextNode(' \u2014 ' + cosaServe(v)));
    }
    var altre = m ? (m.altreSessioni || []).filter(function (x) { return x.ruolo === p.ruolo; }) : [];
    if (altre.length) {
      sep(); f.appendChild(document.createTextNode((altre.length === 1 ? 'un\'altra sessione su ' : altre.length + ' altre sessioni su ')));
      altre.forEach(function (x, i) { if (i) f.appendChild(document.createTextNode(', ')); f.appendChild(cardLink(x)); });
    }
    sep(); f.appendChild(document.createTextNode(p.codaTotale + ' card in coda'));
    return f;
  };

  U.scheda = function (G, hit) {
    var m = G.modello, f = document.createDocumentFragment();
    if (!m) return f;
    if (hit.tipo === 'persona') {
      var p = m.personaggi.filter(function (x) { return x.ruolo === hit.rif; })[0];
      if (!p) return f;
      var fila = (m.fila || []).filter(function (x) { return x.ruolo === p.ruolo; })[0];
      f.appendChild(el('h2', U.titoloRuolo(p.ruolo)));
      if (U.descrizioneRuolo(p.ruolo)) f.appendChild(el('p', U.descrizioneRuolo(p.ruolo), 'nota'));
      var ul = el('ul');
      if (p.sessione) {
        var s = p.sessione;
        riga(ul, 'Sta lavorando su', cardLink(s));
        if (s.task) riga(ul, 'Task', 'n. ' + s.task + (s.titoloTask ? ': ' + s.titoloTask : ''));
        if (s.minuti !== null && s.minuti !== undefined) riga(ul, 'Sessione aperta da', s.minuti + ' minuti');
        riga(ul, 'Token usati', s.tokenTesto ? s.tokenTesto : 'non ancora letti');
        var altre = (m.altreSessioni || []).filter(function (x) { return x.ruolo === p.ruolo; });
        if (altre.length) {
          var la = el('span');
          altre.forEach(function (x, i) { if (i) la.appendChild(document.createTextNode(', ')); la.appendChild(cardLink(x)); });
          riga(ul, 'Altre sessioni dello stesso ruolo (al tavolo dei portatili)', la);
        }
      } else {
        riga(ul, 'Sessione', 'nessuna in corso');
      }
      if (fila) {
        var vf = voceDi(m, fila.id);
        riga(ul, 'Aspetta Titolare sulla card', vf ? cardLink(vf) : '#' + fila.id);
        if (vf) riga(ul, 'Cosa serve', cosaServe(vf));
      }
      riga(ul, 'Card in coda per questo ruolo', p.codaTotale);
      f.appendChild(ul);
      f.appendChild(el('p', 'La scheda dice cosa fa davvero lo smistatore. Quando non ha una sessione, quello che fa nell\'ufficio e\' solo scena.', 'nota'));
    } else if (hit.tipo === 'collega') {
      var k = (m.altreSessioni || []).filter(function (x) { return x.ruolo + '#' + x.id === hit.rif; })[0];
      if (!k) return f;
      f.appendChild(el('h2', U.titoloRuolo(k.ruolo) + ' \u2014 un\'altra sessione'));
      f.appendChild(el('p', 'Una persona per sessione: questa e una sessione in piu dello stesso ruolo. Lavora al tavolo dei portatili o, se il tavolo e pieno, nell\'open space.', 'nota'));
      var ulk = el('ul');
      riga(ulk, 'Sta lavorando su', cardLink(k));
      if (k.task) riga(ulk, 'Task', 'n. ' + k.task + (k.titoloTask ? ': ' + k.titoloTask : ''));
      if (k.minuti !== null && k.minuti !== undefined) riga(ulk, 'Sessione aperta da', k.minuti + ' minuti');
      riga(ulk, 'Token usati', k.tokenTesto ? k.tokenTesto : 'non ancora letti');
      f.appendChild(ulk);
    } else if (hit.tipo === 'coda') {
      var q = m.personaggi.filter(function (x) { return x.ruolo === hit.rif; })[0];
      if (!q) return f;
      f.appendChild(el('h2', 'Coda del ' + U.titoloRuolo(q.ruolo).toLowerCase() + ': ' + q.codaTotale));
      var ul2 = el('ul');
      q.coda.forEach(function (c) { var li = el('li'); li.appendChild(cardLink(c)); ul2.appendChild(li); });
      if (!q.coda.length) ul2.appendChild(el('li', 'Nessuna card in coda.'));
      f.appendChild(ul2);
    } else if (hit.tipo === 'porta') {
      f.appendChild(el('h2', 'Da fare tu: ' + m.daFareTu.length));
      if (m.erroreAdo) f.appendChild(el('p', 'Azure DevOps non risponde: le voci non si conoscono.', 'nota'));
      var ul3 = el('ul');
      m.daFareTu.forEach(function (v) {
        var li = el('li'); li.appendChild(cardLink(v));
        li.appendChild(document.createTextNode(' — ' + (v.verbo || '') + (v.testo ? ': ' + v.testo : '') + (v.ferma ? ' (tiene ferma la card)' : '')));
        ul3.appendChild(li);
      });
      if (!m.daFareTu.length && !m.erroreAdo) ul3.appendChild(el('li', 'Niente da fare per te.'));
      f.appendChild(ul3);
    } else if (hit.tipo === 'robot') {
      f.appendChild(el('h2', 'Smistatore'));
      var ul4 = el('ul'), g = m.smistatore;
      riga(ul4, 'Adesso', g.inGiro === true ? 'sta facendo il giro' : (g.inGiro === false ? 'non sta girando' : 'non si sa se sta girando'));
      if (g.ultimoGiro) riga(ul4, 'Ultimo giro', g.ultimoGiro);
      if (g.prossimoGiro) riga(ul4, 'Prossimo giro', g.prossimoGiro);
      riga(ul4, 'Quota', U.testoQuota(m.quota));
      f.appendChild(ul4);
    } else if (hit.tipo === 'bacheca') {
      f.appendChild(el('h2', 'La board'));
      if (!m.board) f.appendChild(el('p', 'Azure DevOps non risponde: i numeri non si conoscono.', 'nota'));
      else {
        var ul5 = el('ul');
        m.board.forEach(function (c) { riga(ul5, c.titolo, c.conteggio); });
        f.appendChild(ul5);
        f.appendChild(el('p', 'Le card che lo smistatore vede, per fase.', 'nota'));
      }
    }
    return f;
  };

  // I testi sempre visibili sotto la scena: chi fa cosa (vero) e le consegne in corso.
  U.riempiElenco = function (ul, G, apri) {
    while (ul.firstChild) ul.removeChild(ul.firstChild);
    var m = G.modello; if (!m) return;
    m.personaggi.forEach(function (p) {
      var li = el('li'), b = el('button', U.titoloRuolo(p.ruolo)); b.type = 'button'; b.className = 'tasto';
      b.addEventListener('click', function () { apri({ tipo: 'persona', rif: p.ruolo }); });
      li.appendChild(b);
      li.appendChild(document.createTextNode(' ')); li.appendChild(U.rigaPersonaggio(p, (m.fila || []).filter(function (x) { return x.ruolo === p.ruolo; })[0], m));
      ul.appendChild(li);
    });
    function voce(testo, hit, frase) {
      var li = el('li'), b = el('button', testo); b.type = 'button'; b.className = 'tasto';
      b.addEventListener('click', function () { apri(hit); }); li.appendChild(b); li.appendChild(document.createTextNode(' ' + frase)); ul.appendChild(li);
    }
    voce('Da fare tu', { tipo: 'porta' }, m.erroreAdo ? 'non si sa (Azure DevOps non risponde)' : m.daFareTu.length + (m.daFareTu.length === 1 ? ' voce' : ' voci'));
    var g = m.smistatore;
    voce('Smistatore', { tipo: 'robot' }, g.inGiro === true ? 'sta facendo il giro' : (g.inGiro === false ? 'non sta girando' : 'non si sa se sta girando'));
    voce('Board', { tipo: 'bacheca' }, m.board ? m.board.reduce(function (n, c) { return n + c.conteggio; }, 0) + ' card' : 'non si sa');
  };
  U.riempiConsegne = function (ul, G) {
    while (ul.firstChild) ul.removeChild(ul.firstChild);
    var m = G.modello; if (!m) return;
    m.consegne.forEach(function (c) {
      var verso = c.verso === 'indietro' ? 'RIMANDO INDIETRO' : (c.verso === 'avanti' ? 'Consegna' : 'Passaggio');
      var li = el('li', verso + ': ', c.verso === 'indietro' ? 'indietro' : 'avanti'); li.appendChild(cardLink(c));
      li.appendChild(document.createTextNode(' — ' + U.titoloRuolo(c.da) + ' → ' + U.titoloRuolo(c.a)));
      ul.appendChild(li);
    });
    if (!m.consegne.length) ul.appendChild(el('li', 'Nessuna consegna recente.'));
  };

  // Gli avvisi in testo sopra la scena. tipo: 'allarme' (rosso), 'pausa' (arancio), 'nota'.
  U.riempiAvvisi = function (box, voci) {
    while (box.firstChild) box.removeChild(box.firstChild);
    voci.forEach(function (v) {
      var p = el('p', v.testo + (v.azione ? ' ' : ''), 'avviso ' + v.tipo);
      if (v.azione) { var b = el('button', v.azione.testo); b.type = 'button'; b.addEventListener('click', v.azione.f); p.appendChild(b); }
      box.appendChild(p);
    });
  };
  U.el = el;
})(U);
