# La pagina dell'ufficio: il HTML che si compone dai file del gioco. Si prova cio che deve restare vero a qualunque disegno: nessuna
# risorsa esterna, nessun markup dai dati, il dato incorporato e quello giusto, le promesse del gioco (ciclo vero, pausa quando la scheda
# non si vede, movimento ridotto). Il disegno in se si guarda nel browser.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VistaUfficio.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../src/VistaUfficioPagina.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../src/VistaUfficioEsempio.psm1') -Force
    $script:Cartella = Get-CartellaGioco
    $script:Js = (Get-ChildItem $script:Cartella -Filter '*.js' | ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    $script:Cattivo = '</script><img src=x onerror=alert(1)> @@SCRIPT@@ "&'
    function Modello-Cattivo {
        $m = Get-ModelloUfficio -Ruoli 'dev' -Flusso 'dev' -Adesso ([datetime]'2026-11-24T10:00:00Z') -Quota @{ Blocco = $null; Uso = 0.2; Soglia = 0.9 } `
            -Smistatore @{ InGiro = $false; Ultimo = ''; Prossimo = '' } -Secondi 5 `
            -InCorso @([pscustomobject]@{ Id = 5; Ruolo = 'dev'; Titolo = $script:Cattivo; Task = $null; TitoloTask = $null; Minuti = 1; Token = 0; TokenTesto = $null; UrlCard = 'https://ado/5'; Chiave = 'inSviluppo' })
        $m
    }
    function Dato-Incorporato([string]$Html) {
        $m = [regex]::Match($Html, '(?s)<script type="application/json" id="dati">(.*?)</script>')
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | ConvertFrom-Json
    }
}

Describe 'New-PaginaUfficio: il testo dei dati non diventa mai markup' {
    It 'un titolo con tag e con il segnaposto resta dato: non chiude il blocco, non finisce nel codice' {
        $h = New-PaginaUfficio (Modello-Cattivo)
        $h | Should -Not -Match '</script><img'
        $d = Dato-Incorporato $h
        $d.personaggi[0].sessione.titolo | Should -Be $script:Cattivo
        # il segnaposto dello script e stato sostituito una volta sola, anche con un titolo che lo contiene
        ([regex]::Matches($h, [regex]::Escape('@@SCRIPT@@'))).Count | Should -Be 1   # solo quello del titolo, dentro il dato
    }

    It 'ConvertTo-JsonUfficio non scrive mai un segno di minore' {
        (ConvertTo-JsonUfficio @{ titolo = '<b>x</b>' }) | Should -Not -Match '<'
        ((ConvertTo-JsonUfficio @{ titolo = '<b>x</b>' }) | ConvertFrom-Json).titolo | Should -Be '<b>x</b>'
    }

    It 'il codice del gioco non scrive HTML da stringhe: niente innerHTML, outerHTML, insertAdjacentHTML, document.write, eval, new Function' {
        foreach ($vietato in 'innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function', 'setTimeout("', "setInterval('") {
            $script:Js | Should -Not -Match ([regex]::Escape($vietato)) -Because "'$vietato' lascerebbe entrare markup dai dati"
        }
    }

    It 'un collegamento dai dati e ammesso solo se http o https' {
        $script:Js | Should -Match 'https\?:'
    }

    It 'nessun file del gioco contiene una chiusura di script che romperebbe la pagina' {
        $script:Js | Should -Not -Match '(?i)</script'
    }
}

Describe 'New-PaginaUfficio: nessuna risorsa esterna, nessuna uscita' {
    BeforeAll { $script:Pagina = New-PaginaUfficio (Get-EsempioUfficio) }

    It 'porta una Content-Security-Policy che ammette solo il proprio server' {
        $script:Pagina | Should -Match 'http-equiv="Content-Security-Policy"'
        $script:Pagina | Should -Match "default-src 'none'"
        $script:Pagina | Should -Match "connect-src 'self'"
    }

    It 'non scarica nulla: nessun src, nessun link a stylesheet, nessun import, nessuna richiesta a un altro indirizzo' {
        $script:Pagina | Should -Not -Match '(?i)<(script|img|iframe|link|source|video|audio)\b[^>]*\b(src|href)\s*='
        $script:Pagina | Should -Not -Match '(?i)@import|url\(|importScripts|XMLHttpRequest|WebSocket|EventSource|sendBeacon'
        # le uniche richieste di rete del codice sono la rilettura del dato dal proprio server
        ([regex]::Matches($script:Js, 'fetch\(')).Count | Should -Be 1
        $script:Js | Should -Match "fetch\('ufficio\.json"
    }

    It 'non carica immagini ne font: tutto e disegnato da codice' {
        $script:Js | Should -Not -Match '(?i)new Image\(|\.png|\.jpg|\.gif|@font-face|FontFace'
    }
}

Describe 'New-PaginaUfficio: le promesse del gioco' {
    BeforeAll { $script:Pagina = New-PaginaUfficio (Get-EsempioUfficio) }

    It 'ha un ciclo di gioco vero a passo fisso, con requestAnimationFrame' {
        $script:Js | Should -Match 'requestAnimationFrame'
        $script:Js | Should -Match 'STEP = 1 / 30'
        $script:Js | Should -Match 'acc >= STEP'
    }

    It 'disegna a risoluzione bassa scalata a multipli interi, senza sfumature' {
        $script:Pagina | Should -Match 'width="320" height="224"'
        $script:Pagina | Should -Match 'image-rendering: pixelated'
        $script:Js | Should -Match 'Math\.floor\(Math\.min\('
    }

    It 'il ciclo si ferma quando la scheda non si vede' {
        $script:Js | Should -Match 'visibilitychange'
        $script:Js | Should -Match 'cancelAnimationFrame'
        $script:Js | Should -Match 'document\.hidden'
    }

    It 'il movimento parte da solo: lo ferma solo una scelta salvata, non la preferenza di sistema' {
        # su certi PC la preferenza di sistema e sempre attiva (animazioni di Windows spente): se decidesse lei, il gioco sarebbe fermo
        $script:Js | Should -Match 'var ridotto = movimentoFermato\(\);'
        $script:Js | Should -Not -Match 'ridotto\s*=\s*[^;]*mq\.matches'
        $script:Js | Should -Match 'prefers-reduced-motion: reduce'   # la preferenza si legge, ma per mostrare una nota
        $script:Js | Should -Match "!ridotto && mq\.matches"
    }

    It 'chi vuole fermare il movimento ha un comando visibile e la scelta si ricorda fra un apertura e l altra' {
        $script:Pagina | Should -Match 'id="tasto-movimento"'
        $script:Js | Should -Match "localStorage\.setItem\('ufficio-movimento', 'fermo'\)"
        $script:Js | Should -Match "localStorage\.getItem\('ufficio-movimento'\)"
        $script:Js | Should -Not -Match "sessionStorage\.(get|set)Item\('ufficio-movimento'"
    }

    It 'a movimento fermo i personaggi non camminano' {
        $script:Js | Should -Match 'if \(G\.ridotto\) return;'
    }

    It 'se i dati sono fermi o il server non risponde lo scrive in chiaro con l ora dell ultimo dato buono' {
        $script:Js | Should -Match 'I dati sono fermi dalle'
        $script:Js | Should -Match 'erroriRete'
        $script:Js | Should -Match 'DATI FERMI'
    }

    It 'e in sola lettura: nessuna richiesta che scrive' {
        $script:Js | Should -Not -Match "(?i)method:\s*'(POST|PUT|PATCH|DELETE)'"
        $script:Js | Should -Not -Match '(?i)<form\b'
        $script:Pagina | Should -Not -Match '(?i)<form\b'
    }
}

Describe 'Get-EsempioUfficio: la pagina d esempio mostra tutti i comportamenti' {
    BeforeAll { $script:E = Get-EsempioUfficio }

    It 'ha le scene per consegna e rimando, giornata di lavoro, pausa della quota, Azure DevOps giu e dati fermi' {
        @($script:E.scenari).Count | Should -Be 6
        $script:E.esempio | Should -BeTrue
    }

    It 'una scena senza sessioni ha una consegna in avanti, un rimando indietro e un agente in fila alla porta' {
        $m = $script:E.scenari[0].modello
        @($m.personaggi | Where-Object { $null -ne $_.sessione }).Count | Should -Be 0
        @($m.consegne | Where-Object verso -eq 'avanti').Count | Should -BeGreaterOrEqual 1
        @($m.consegne | Where-Object verso -eq 'indietro').Count | Should -BeGreaterOrEqual 1
        @($m.fila).Count | Should -BeGreaterOrEqual 1
        @($m.daFareTu).Count | Should -BeGreaterThan 1
    }

    It 'una scena ha le sessioni al lavoro e lo smistatore in giro, una la quota oltre la soglia, una Azure DevOps che non risponde' {
        @($script:E.scenari[1].modello.personaggi | Where-Object { $null -ne $_.sessione }).Count | Should -BeGreaterOrEqual 2
        $script:E.scenari[1].modello.smistatore.inGiro | Should -BeTrue
        $script:E.scenari[3].modello.quota.stato | Should -Be 'riserva'
        $script:E.scenari[4].modello.erroreAdo | Should -Not -BeNullOrEmpty
        $script:E.scenari[4].modello.board | Should -BeNullOrEmpty
        $script:E.scenari[5].fermoDaMinuti | Should -BeGreaterThan 0
    }

    It 'una scena ha piu sessioni dello stesso ruolo (tavolo dei portatili) e una ne ha piu dei posti (open space)' {
        @($script:E.scenari[1].modello.altreSessioni).Count | Should -BeGreaterOrEqual 2
        @($script:E.scenari[2].modello.altreSessioni).Count | Should -BeGreaterThan 4   # i posti al tavolo (M.POSTI_TAVOLO)
        # al tavolo e nell'open space ci sono ruoli diversi, non solo dev
        @($script:E.scenari[2].modello.altreSessioni | ForEach-Object ruolo | Sort-Object -Unique).Count | Should -BeGreaterOrEqual 3
    }
}

Describe 'L ufficio: una persona per sessione' {
    It 'il tavolo dei portatili, la porta dell open space e la scheda della persona in piu ci sono' {
        $script:Js | Should -Match 'POSTI_TAVOLO'
        $script:Js | Should -Match 'portaOpenSpace'
        $script:Js | Should -Match "hit\.tipo === 'collega'"
        $script:Js | Should -Match 'altreSessioni'
    }

    It 'l open space e una stanza disegnata: la porta ci porta dentro, la sua porta riporta all ufficio, e la stanza si ricorda' {
        $script:Js | Should -Match 'U\.OS = OS'
        $script:Js | Should -Match "h\.tipo === 'openspace'\) \{ vaiStanza\('openspace'\)"
        $script:Js | Should -Match "h\.tipo === 'ufficio'\) \{ vaiStanza\('ufficio'\)"
        $script:Js | Should -Match "sessionStorage\.setItem\('ufficio-stanza'"
        $script:Pagina | Should -Match 'id="cambia-stanza"'
    }

    It 'nell open space si entra e si esce camminando lungo i corridoi, e dopo un ricarico ognuno torna al suo banco' {
        $script:Js | Should -Match 'percorsoUscita'
        $script:Js | Should -Match 'osPersone: U\.OS \? U\.OS\.salva\(G\)'
    }

    It 'chi entra o esce passa dalla porta dell open space, camminando' {
        $script:Js | Should -Match 'ingressoOpenSpace'
        $script:Js | Should -Match "e\.modo === 'esce'"
    }

    It 'la pagina committata in docs/ e quella che lo script scrive adesso (i dati portano l ora: si confronta tutto il resto)' {
        $tmp = Join-Path $TestDrive 'esempio.html'
        & (Join-Path $PSScriptRoot '../src/UfficioEsempio.ps1') -Percorso $tmp | Out-Null
        $nuova = Get-Content $tmp -Raw -Encoding UTF8
        $vecchia = Get-Content (Join-Path $PSScriptRoot '../docs/ufficio-esempio.html') -Raw -Encoding UTF8
        # senza i dati e con gli a capo uniformi: Git sul PC di chi clona puo scrivere i file con CRLF
        $senzaDati = { param($t) [regex]::Replace($t, '(?s)<script type="application/json" id="dati">.*?</script>', '').Replace("`r`n", "`n") }
        (& $senzaDati $nuova) | Should -Be (& $senzaDati $vecchia) -Because 'docs/ufficio-esempio.html va rigenerata con src/UfficioEsempio.ps1 quando cambia il gioco'
    }
}

Describe 'La pagina dell ufficio dentro il pannello della vista (versione compatta)' {
    BeforeAll { $script:Pagina = New-PaginaUfficio (Get-EsempioUfficio) }

    It 'ha una versione compatta, scelta da ?compatto=1, senza un secondo gioco: e la stessa pagina' {
        $script:Js | Should -Match 'compatto=1'
        $script:Pagina | Should -Match 'body\.compatto'
    }

    It 'un clic su un personaggio avvisa la vista che lo ospita, che scorre alla colonna; se la vista non la ha, si apre la scheda' {
        $script:Js | Should -Match "postMessage\(\{ tipo: 'ufficio-persona'"
        $script:Js | Should -Match "'ufficio-risposta'"
        $script:Js | Should -Match 'e\.source !== window\.parent'
    }

    It 'lo stato del gioco sopravvive al ricarico della vista (che si ricarica da sola): si salva e si ripristina, senza salti' {
        $script:Js | Should -Match "sessionStorage\.setItem\('ufficio-stato'"
        $script:Js | Should -Match "sessionStorage\.getItem\('ufficio-stato'\)"
        $script:Js | Should -Match "'pagehide'"
        $script:Js | Should -Match 'quando'
    }
}

Describe 'La pagina dell ufficio dice chi e chi e perche' {
    BeforeAll { $script:Pagina = New-PaginaUfficio (Get-EsempioUfficio) }

    It 'chi fa la fila alla porta mostra l id della card sopra la testa e, nella scheda e nell elenco, la card con il link e cosa serve' {
        $script:Js | Should -Match "G\.modello\.fila\[a\.slot\]"
        $script:Js | Should -Match 'Cosa serve'
        $script:Js | Should -Match 'rigaPersonaggio'
        $script:Js | Should -Match 'aspetta Titolare sulla card '
    }

    It 'ogni ruolo ha una riga che dice chi e, il mentore compreso' {
        $script:Js | Should -Match 'mentore: '
        $script:Js | Should -Match 'descrizioneRuolo'
    }

    It 'la pagina d esempio lo dice a chiare lettere: i dati sono inventati' {
        $script:Js | Should -Match "PAGINA D.{1,2}ESEMPIO"
    }
}

Describe 'L ufficio: zoom e trascinamento' {
    BeforeAll { $script:Pagina = New-PaginaUfficio (Get-EsempioUfficio) }

    It 'ha i tasti per ingrandire, rimpicciolire e tornare alla misura che sta nello spazio' {
        foreach ($id in 'zoom-piu', 'zoom-meno', 'zoom-adatta', 'zoom-livello') { $script:Pagina | Should -Match "id=`"$id`"" }
    }

    It 'lo zoom e a multipli interi (pixel nitidi), ha un massimo, e si ricorda' {
        $script:Js | Should -Match 'ZOOM_MAX'
        $script:Js | Should -Match "localStorage\.setItem\('ufficio-zoom'"
        $script:Js | Should -Match "localStorage\.getItem\('ufficio-zoom'\)"
        $script:Js | Should -Not -Match 'scale\('
    }

    It 'si sposta la vista dentro l ufficio trascinando; un trascinamento non e un clic' {
        $script:Js | Should -Match "addEventListener\('pointerdown'"
        $script:Js | Should -Match "addEventListener\('pointermove'"
        $script:Js | Should -Match 'setPointerCapture'
        $script:Js | Should -Match 'scrollLeft'
        $script:Js | Should -Match 'ignoraClic'
    }

    It 'la posizione dentro l ufficio sopravvive al ricarico della vista' {
        $script:Js | Should -Match "sessionStorage\.setItem\('ufficio-vista'"
        $script:Js | Should -Match "sessionStorage\.getItem\('ufficio-vista'\)"
    }

    It 'a quota libera con la soglia alzata lo dice, e con la riserva ignorata pure' {
        $script:Js | Should -Match 'alzata'
        $script:Js | Should -Match 'ignorata'
    }
}

Describe 'L ufficio: la pausa per il limite non e la riserva' {
    It 'con il limite dice quale finestra (5 ore o settimana), quanto e usata e quando riparte; la soglia settimanale non si disegna' {
        $script:Js | Should -Match "q\.stato === 'limite'"
        $script:Js | Should -Match 'LIMITE DELLE 5 ORE'
        $script:Js | Should -Match 'RIPARTE '
        $script:Js | Should -Match 'Non e la riserva settimanale'
    }
}
