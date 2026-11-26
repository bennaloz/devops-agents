# La scheda Ufficio della vista: una scheda come Agenti, Pipeline e Apprendimento (affiancata come le altre), con dentro il comando per
# aprire l'ufficio a parte. Solo lei si puo agganciare sopra o sotto le altre schede, per guardare l'ufficio mentre si lavora altrove.
# Si prova cio che deve restare vero: a scheda non visibile il gioco non e caricato (quindi il ciclo non gira), l'aggancio si ricorda, le
# scelte del vecchio pannello non lasciano la pagina rotta, il messaggio dal gioco non diventa selettore ne markup, nessuna risorsa esterna.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VistaUfficioPannello.psm1') -Force
    $script:Html = Get-SchedaUfficio
    $script:Js = ([regex]::Match((Get-ScriptUfficio), '(?s)<script>(.*?)</script>')).Groups[1].Value
}

Describe 'Get-SchedaUfficio: il markup' {
    It 'e un pannello di scheda come gli altri (data-pannello="ufficio", role tabpanel)' {
        $script:Html | Should -Match '<div data-pannello="ufficio" role="tabpanel"'
    }

    It 'dentro la scheda c e il comando per aprire l ufficio a parte, a grandezza piena' {
        $script:Html | Should -Match '<a[^>]*href="ufficio\.html"[^>]*target="_blank"[^>]*rel="noopener"[^>]*>Apri a parte</a>'
    }

    It 'il gioco non e caricato finche la scheda non si vede: l iframe non ha src, solo data-src' {
        $iframe = [regex]::Match($script:Html, '<iframe[^>]*>').Value
        $iframe | Should -Not -Match '\ssrc='
        $iframe | Should -Match 'data-src="ufficio\.html\?compatto=1"'
        $iframe | Should -Match 'title="'
    }

    It 'ha le tre scelte di aggancio: nella scheda, sopra, sotto (a lato non c e: affiancata e come le altre schede)' {
        foreach ($a in 'no', 'sopra', 'sotto') { $script:Html | Should -Match "data-aggancio-scelta=`"$a`"" }
        $script:Html | Should -Not -Match 'data-aggancio-scelta="lato"'
    }

    It 'ha la maniglia per ingrandire o rimpicciolire l ufficio agganciato, usabile da tastiera' {
        $script:Html | Should -Match 'class="maniglia"[^>]*role="separator"'
        $script:Html | Should -Match 'class="maniglia"[^>]*tabindex="0"'
    }

    It 'non porta nessuna risorsa esterna e nessun dato: e sempre uguale' {
        $script:Html | Should -Not -Match '(?i)https?://'
        (Get-SchedaUfficio) | Should -Be (Get-SchedaUfficio)
    }
}

Describe 'Get-ScriptUfficio' {
    It 'l aggancio e la sua apertura si ricordano fra un apertura e l altra' {
        $script:Js | Should -Match "leggi\('ufficio-aggancio'\)"
        $script:Js | Should -Match "scrivi\('ufficio-aggancio'"
        $script:Js | Should -Match "scrivi\('ufficio-aperto'"
        $script:Js | Should -Match 'localStorage\.getItem\(k\)'
    }

    It 'le scelte del vecchio pannello (chiuso, in basso, a lato) diventano quelle nuove e si tolgono, senza lasciare la pagina rotta' {
        $script:Js | Should -Match "leggi\('ufficio-pannello'\)"
        $script:Js | Should -Match "vecchio === 'basso'"
        $script:Js | Should -Match "togli\('ufficio-pannello'\)"
        $script:Js | Should -Match "togli\('ufficio-pannello-ultima'\)"
        $script:Js | Should -Match "togli\('ufficio-pannello-larghezza'\)"
    }

    It 'un valore ricordato che non e un aggancio ricade su nella scheda' {
        $script:Js | Should -Match "\['sopra', 'sotto'\]\.indexOf\(aggancio\) < 0"
    }

    It 'il gioco si carica solo quando la scheda si vede e si scarica quando non si vede (il ciclo non gira)' {
        $script:Js | Should -Match 'about:blank'
        $script:Js | Should -Match 'dataset\.src'
        $script:Js | Should -Match 'MutationObserver'
        $script:Js | Should -Match 'getClientRects'
    }

    It 'agganciata, la scheda esce dalle schede (data-fuori) e la vista ridispone le altre' {
        $script:Js | Should -Match "setAttribute\('data-fuori'"
        $script:Js | Should -Match 'vistaRidisponi'
    }

    It 'la maniglia si trascina con il puntatore e la misura si ricorda; il gioco non si prende i movimenti mentre si trascina' {
        $script:Js | Should -Match 'setPointerCapture'
        $script:Js | Should -Match "'ufficio-pannello-altezza'"
        $script:Html | Should -Match 'trascina iframe \{ pointer-events: none'
    }

    It 'il messaggio dal gioco e accettato solo dal proprio iframe e dalla stessa origine, e il ruolo non diventa mai un selettore' {
        $script:Js | Should -Match 'e\.source !== '
        $script:Js | Should -Match 'e\.origin'
        $script:Js | Should -Match "'ufficio-persona'"
        $script:Js | Should -Match 'dataset\.colonna === '
        $script:Js | Should -Not -Match 'querySelector(All)?\([^)]*d\.ruolo'
        $script:Js | Should -Match 'scrollIntoView'
    }

    It 'non scrive HTML da stringhe' {
        foreach ($vietato in 'innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function') {
            $script:Js | Should -Not -Match ([regex]::Escape($vietato))
        }
    }
}
