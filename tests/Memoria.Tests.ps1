BeforeAll {
    # D53: i moduli che chiamano Get-Config (Card, MemoriaRepo, Sessioni) leggono impostazioni.json dalla cartella dati: non quella vera di chi lancia i test.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    Import-Module (Join-Path $PSScriptRoot '../src/Memoria.psm1') -Force
    $script:Repo = Split-Path -Parent $PSScriptRoot
    # il massimo utile per il testo della descrizione lo dice Ado.psm1 (Get-AdoLimiteTestoPr): qui un numero qualsiasi
    $script:Lim = 4000

    function Lezione($Ruolo, $N, $Situazione = 's', $CosaFare = 'c', $Perche = 'p', $Card = '12') {
        ConvertTo-TestoLezione -Id ('{0}-{1:000}' -f $Ruolo, $N) -Situazione $Situazione -CosaFare $CosaFare -Perche $Perche -Card $Card
    }
}

Describe 'Config' {
    It 'il tetto della memoria sta in limiti.json, 25 lezioni per file' {
        $limiti = Get-Content (Join-Path $script:Repo 'config/limiti.json') -Raw | ConvertFrom-Json
        $limiti.tettoMemoria | Should -Be 25
    }
}

Describe 'Formato della lezione' {
    It 'il blocco e un titolo con l id e quattro righe: Situazione, Cosa fare, Perche, Card' {
        $t = ConvertTo-TestoLezione -Id 'dev-003' -Situazione 'Il test non parte' -CosaFare 'Lancia prima il restore' -Perche 'Senza pacchetti fallisce' -Card '57'
        $t | Should -Be "### dev-003`n- Situazione: Il test non parte`n- Cosa fare: Lancia prima il restore`n- Perché: Senza pacchetti fallisce`n- Card: 57"
    }

    It 'un file si legge in lezioni con id, ruolo, numero, campi e testo del blocco' {
        $file = (Lezione dev 1 'prima') + "`n`n" + (Lezione dev 2 'seconda') + "`n"
        $l = @(Read-Lezioni $file)
        $l.Count | Should -Be 2
        $l[1].Id | Should -Be 'dev-002'
        $l[1].Ruolo | Should -Be 'dev'
        $l[1].Numero | Should -Be 2
        $l[1].Situazione | Should -Be 'seconda'
        $l[1].CosaFare | Should -Be 'c'
        $l[1].Perche | Should -Be 'p'
        $l[1].Card | Should -Be '12'
        $l[1].Testo | Should -Be (Lezione dev 2 'seconda')
    }

    It 'un testo vuoto o nullo non ha lezioni' {
        @(Read-Lezioni $null).Count | Should -Be 0
        @(Read-Lezioni "`n`n").Count | Should -Be 0
    }
}

Describe 'Validazione dei campi' {
    It 'una lezione completa non ha errori' {
        @(Test-CampiLezione @{ situazione = 'a'; cosaFare = 'b'; perche = 'c'; card = '9' }).Count | Should -Be 0
    }

    It 'un campo mancante o vuoto e un errore che lo nomina' {
        $e = @(Test-CampiLezione ([pscustomobject]@{ situazione = 'a'; cosaFare = '   '; card = '9' }))
        $e.Count | Should -Be 2
        ($e -join ' ') | Should -BeLike '*cosaFare*'
        ($e -join ' ') | Should -BeLike '*perche*'
    }

    It 'un campo su piu righe e rifiutato: il formato ha una riga per campo' {
        $e = @(Test-CampiLezione @{ situazione = "a`nb"; cosaFare = 'b'; perche = 'c'; card = '9' })
        $e.Count | Should -Be 1
        $e[0] | Should -BeLike '*situazione*'
    }
}

Describe 'Id progressivo' {
    It 'senza lezioni parte da 001' {
        Get-ProssimoIdLezione -Ruolo 'dev' -Testi @() | Should -Be 'dev-001'
    }

    It 'e il massimo di tutti i file del ruolo piu uno, anche con buchi' {
        $a = (Lezione dev 1) + "`n`n" + (Lezione dev 7)
        $b = Lezione dev 3
        Get-ProssimoIdLezione -Ruolo 'dev' -Testi @($a, $b) | Should -Be 'dev-008'
    }

    It 'non conta le lezioni degli altri ruoli' {
        Get-ProssimoIdLezione -Ruolo 'reviewer' -Testi @((Lezione dev 9), (Lezione reviewer 2)) | Should -Be 'reviewer-003'
    }

    It 'un testo nullo (file assente) non conta' {
        Get-ProssimoIdLezione -Ruolo 'dev' -Testi @($null, (Lezione dev 1)) | Should -Be 'dev-002'
    }
}

Describe 'Tetto' {
    It 'con 24 lezioni ce n e posto per un altra, con 25 no' {
        $n = { param($k) (@(1..$k | ForEach-Object { Lezione dev $_ }) -join "`n`n") }
        Test-MemoriaPiena -Testo (& $n 24) -Tetto 25 | Should -BeFalse
        Test-MemoriaPiena -Testo (& $n 25) -Tetto 25 | Should -BeTrue
        Test-MemoriaPiena -Testo $null -Tetto 25 | Should -BeFalse
    }
}

Describe 'Modifica del testo di un file' {
    BeforeEach {
        $script:File = (Lezione dev 1 'uno') + "`n`n" + (Lezione dev 2 'due') + "`n"
    }

    It 'aggiunge in fondo, con una riga vuota fra i blocchi e a capo finale' {
        $nuovo = Add-LezioneAlTesto -Testo $script:File -Lezione (Lezione dev 3 'tre')
        $nuovo | Should -Be ((Lezione dev 1 'uno') + "`n`n" + (Lezione dev 2 'due') + "`n`n" + (Lezione dev 3 'tre') + "`n")
    }

    It 'aggiunge a un file vuoto o assente' {
        Add-LezioneAlTesto -Testo $null -Lezione (Lezione dev 1) | Should -Be ((Lezione dev 1) + "`n")
    }

    It 'sostituisce il blocco con quell id e lascia gli altri' {
        $nuovo = Set-LezioneNelTesto -Testo $script:File -Id 'dev-002' -Lezione (Lezione dev 2 'DUE CORRETTA')
        $l = @(Read-Lezioni $nuovo)
        $l.Count | Should -Be 2
        $l[0].Situazione | Should -Be 'uno'
        $l[1].Situazione | Should -Be 'DUE CORRETTA'
    }

    It 'toglie il blocco con quell id' {
        $nuovo = Remove-LezioneDalTesto -Testo $script:File -Id 'dev-001'
        $l = @(Read-Lezioni $nuovo)
        $l.Count | Should -Be 1
        $l[0].Id | Should -Be 'dev-002'
    }

    It 'un id che nel testo non c e restituisce null: chi chiama decide l errore' {
        Set-LezioneNelTesto -Testo $script:File -Id 'dev-009' -Lezione (Lezione dev 9) | Should -BeNullOrEmpty
        Remove-LezioneDalTesto -Testo $script:File -Id 'dev-009' | Should -BeNullOrEmpty
    }

    It 'togliere l ultima lezione lascia un testo vuoto' {
        $solo = (Lezione dev 1) + "`n"
        Remove-LezioneDalTesto -Testo $solo -Id 'dev-001' | Should -Be ''
    }
}

Describe 'In prova o stabile' {
    It 'una lezione identica su develop e stabile, una nuova o cambiata e in prova' {
        $develop = (Lezione dev 1 'uguale') + "`n`n" + (Lezione dev 2 'vecchia') + "`n"
        $inProva = (Lezione dev 1 'uguale') + "`n`n" + (Lezione dev 2 'cambiata') + "`n`n" + (Lezione dev 3 'nuova') + "`n"
        $l = @(Get-LezioniConEtichetta -Develop $develop -InProva $inProva)
        $l.Count | Should -Be 3
        $l[0].InProva | Should -BeFalse
        $l[1].InProva | Should -BeTrue
        $l[1].Situazione | Should -Be 'cambiata'
        $l[2].InProva | Should -BeTrue
    }

    It 'se il ramo in prova non c e (null) si usa develop e niente e in prova' {
        $l = @(Get-LezioniConEtichetta -Develop (Lezione dev 1) -InProva $null)
        $l.Count | Should -Be 1
        $l[0].InProva | Should -BeFalse
    }

    It 'una lezione tolta sul ramo in prova non si mostra piu' {
        $develop = (Lezione dev 1) + "`n`n" + (Lezione dev 2)
        $inProva = Lezione dev 2
        $l = @(Get-LezioniConEtichetta -Develop $develop -InProva $inProva)
        $l.Count | Should -Be 1
        $l[0].Id | Should -Be 'dev-002'
    }

    It 'un file che esiste solo sul ramo in prova ha tutte le lezioni in prova' {
        $l = @(Get-LezioniConEtichetta -Develop $null -InProva (Lezione dev 1))
        $l[0].InProva | Should -BeTrue
    }

    It 'il confronto con develop distingue le maiuscole: una lezione che cambia solo di maiuscole e in prova' {
        $l = @(Get-LezioniConEtichetta -Develop (Lezione dev 1 'Uguale') -InProva (Lezione dev 1 'uguale'))
        $l[0].InProva | Should -BeTrue
    }

    It 'il testo per la lettura marca il titolo con (in prova) e non le stabili' {
        $l = @(Get-LezioniConEtichetta -Develop (Lezione dev 1) -InProva ((Lezione dev 1) + "`n`n" + (Lezione dev 2)))
        $t = ConvertTo-TestoLezioni $l
        $t | Should -BeLike "*### dev-001`n*"
        $t | Should -BeLike "*### dev-002 (in prova)`n*"
    }
}

Describe 'Il brief con la memoria (D46)' {
    BeforeAll {
        function File($Nome, $Develop = $null, $InProva = $null) { [pscustomobject]@{ Nome = $Nome; Develop = $Develop; InProva = $InProva } }
    }

    It 'senza lezioni il brief resta identico: nessuna sezione Memoria' {
        New-BriefConMemoria -Brief "# Dev`ncorpo`n" -File @() | Should -BeExactly "# Dev`ncorpo`n"
        New-BriefConMemoria -Brief "# Dev`ncorpo`n" -File @((File 'comune'), (File 'Acme.AI' '' $null)) | Should -BeExactly "# Dev`ncorpo`n"
    }

    It 'dopo il brief vengono le lezioni di comune, poi quelle del repo, ognuna con il suo titolo' {
        $t = New-BriefConMemoria -Brief '# Dev' -File @((File 'Acme.AI' (Lezione dev 2 'del repo')), (File 'comune' (Lezione dev 1 'di tutti')))
        $iBrief = $t.IndexOf('# Dev'); $iMem = $t.IndexOf('# Memoria'); $iComune = $t.IndexOf('di tutti'); $iRepo = $t.IndexOf('del repo')
        $iBrief | Should -Be 0
        $iMem | Should -BeGreaterThan $iBrief
        $iComune | Should -BeGreaterThan $iMem
        $iRepo | Should -BeGreaterThan $iComune
        $t | Should -BeLike '*## Lezioni comuni*'
        $t | Should -BeLike '*## Lezioni del repo Acme.AI*'
    }

    It 'una lezione in prova ha l etichetta nel titolo, una stabile no' {
        $t = New-BriefConMemoria -Brief '# Dev' -File @((File 'comune' (Lezione dev 1) ((Lezione dev 1) + "`n`n" + (Lezione dev 2))))
        $t | Should -BeLike "*### dev-001`n*"
        $t | Should -BeLike "*### dev-002 (in prova)`n*"
    }

    It 'un file senza lezioni non lascia il suo titolo; l altro resta' {
        $t = New-BriefConMemoria -Brief '# Dev' -File @((File 'comune' $null), (File 'Acme.AI' (Lezione dev 1)))
        $t | Should -Not -BeLike '*## Lezioni comuni*'
        $t | Should -BeLike '*## Lezioni del repo Acme.AI*'
    }

    It 'se il ramo in prova ha tolto una lezione di develop non si mostra' {
        $t = New-BriefConMemoria -Brief '# Dev' -File @((File 'comune' ((Lezione dev 1 'tolta') + "`n`n" + (Lezione dev 2 'resta')) (Lezione dev 2 'resta')))
        $t | Should -Not -BeLike '*tolta*'
        $t | Should -BeLike '*resta*'
    }
}

Describe 'Descrizione della PR della memoria' {
    It 'oltre il limite di Azure DevOps tronca le lezioni in prova, prima le piu vecchie, e lo dice' {
        $lunga = 'x' * 150
        $l = @(1..60 | ForEach-Object { Read-Lezioni (Lezione dev $_ $lunga) })
        $d = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva $l
        $d.Length | Should -BeLessOrEqual 4000
        $d | Should -BeLike '*dev-060*'
        $d | Should -Not -BeLike '*dev-001:*'
        $d | Should -BeLike '*non elencate*'
    }

    It 'il limite e quello ricevuto: con 600 caratteri la descrizione sta in 600 e dice quante lezioni ha omesso' {
        $l = @(1..20 | ForEach-Object { Read-Lezioni (Lezione dev $_ ('x' * 100)) })
        $d = New-DescrizionePrMemoria -Limite 600 -LezioniInProva $l
        $d.Length | Should -BeLessOrEqual 600
        $d | Should -BeLike '*non elencate*600 caratteri*'
        $d | Should -BeLike '*dev-020*'
    }

    It 'sotto il limite non tronca e non dice niente' {
        $d = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @(Read-Lezioni (Lezione dev 1 'breve'))
        $d | Should -Not -BeLike '*non elencate*'
    }

    It 'troncando tiene sempre le note di conflitto' {
        $l = @(1..60 | ForEach-Object { Read-Lezioni (Lezione dev $_ ('y' * 150)) })
        $d = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva $l -Conflitti @('Card 5: contraddice D40', 'Card 8: contraddice il brief')
        $d.Length | Should -BeLessOrEqual 4000
        @(Get-NoteConflitto $d).Count | Should -Be 2
    }

    It 'le note di conflitto identiche non si ripetono' {
        $d = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @() -Conflitti @('Card 5: stessa', 'Card 5: stessa', 'Card 6: altra')
        @(Get-NoteConflitto $d).Count | Should -Be 2
    }

    It 'elenca le lezioni in prova con id e situazione' {
        $l = @(Get-LezioniConEtichetta -Develop $null -InProva (Lezione dev 1 'Il test non parte'))
        $d = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva $l
        $d | Should -BeLike '*dev-001*Il test non parte*'
    }

    It 'senza lezioni dice che non ce ne sono' {
        New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @() | Should -BeLike '*nessuna*'
    }

    It 'le note di conflitto ci sono e si rileggono dalla descrizione, una per riga' {
        $d = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @() -Conflitti @('Card 5: la correzione contraddice D40', 'Card 8: contraddice il brief')
        $d | Should -BeLike '*Card 5: la correzione contraddice D40*'
        $note = @(Get-NoteConflitto $d)
        $note.Count | Should -Be 2
        $note[1] | Should -Be 'Card 8: contraddice il brief'
    }

    It 'senza note di conflitto la descrizione non ha la sezione e non si rilegge niente' {
        $d = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @()
        $d | Should -Not -BeLike '*onflitt*'
        @(Get-NoteConflitto $d).Count | Should -Be 0
        @(Get-NoteConflitto $null).Count | Should -Be 0
    }

    It 'una nota su piu righe diventa una riga sola' {
        $d = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @() -Conflitti @("una`ndue")
        @(Get-NoteConflitto $d)[0] | Should -Be 'una due'
    }
}

Describe 'Riassunto del registro dell apprendimento' {
    BeforeAll {
        # una riga come la leggerebbe Get-RigheApprendimento (data come stringa ISO o come datetime, ConvertFrom-Json fa il secondo)
        function Riga($Data, $Card, [string]$Tipo, [string]$Ruolo, [string]$Lezione = $null, [string]$Esito = $null) {
            [pscustomobject]@{ data = $Data; card = $Card; repo = 'Acme.AI'; tipo = $Tipo; ruolo = $Ruolo; motivo = 'm'; lezione = $Lezione; esito = $Esito }
        }
        function Utc([string]$T) { [datetime]::Parse($T, [cultureinfo]::InvariantCulture, 'AdjustToUniversal') }
        $script:Adesso = Utc '2026-11-20T12:00:00Z'
    }

    It 'conta per ruolo e per settimana blocchi, on-hold, correzioni e lezioni applicate' {
        $righe = @(
            (Riga '2026-11-17T08:00:00Z' 5 'blocco' 'dev'), (Riga '2026-11-18T08:00:00Z' 5 'blocco' 'dev')
            (Riga '2026-11-18T09:00:00Z' 6 'onHold' 'dev'), (Riga '2026-11-19T09:00:00Z' 6 'correzione' 'dev')
            (Riga '2026-11-19T10:00:00Z' 7 'lezioneApplicata' 'dev' 'dev-001'), (Riga '2026-11-19T11:00:00Z' 8 'blocco' 'reviewer'))
        $r = Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso
        $dev = @($r.Righe | Where-Object Ruolo -eq 'dev')
        $dev.Count | Should -Be 1
        $dev[0].Blocchi | Should -Be 2
        $dev[0].OnHold | Should -Be 1
        $dev[0].Correzioni | Should -Be 1
        $dev[0].LezioniApplicate | Should -Be 1
        $rev = @($r.Righe | Where-Object Ruolo -eq 'reviewer')
        $rev[0].Blocchi | Should -Be 1
        $rev[0].OnHold | Should -Be 0
    }

    It 'la settimana e ISO e comincia il lunedi: la domenica sta con la settimana prima, il lunedi con la nuova' {
        $righe = @((Riga '2026-11-22T23:59:00Z' 1 'blocco' 'dev'), (Riga '2026-11-23T00:01:00Z' 2 'blocco' 'dev'))
        $r = Get-RiassuntoApprendimento -Righe $righe -Adesso (Utc '2026-11-25T12:00:00Z')
        @($r.Righe).Count | Should -Be 2
        $r.Righe[0].Lunedi | Should -Be '2026-11-23'
        $r.Righe[0].Settimana | Should -Be '2026-W48'
        $r.Righe[1].Lunedi | Should -Be '2026-11-16'
        $r.Righe[1].Settimana | Should -Be '2026-W47'
    }

    It 'a cavallo d anno la settimana ISO e quella del lunedi (3 gennaio 2027 e la W53 del 2026)' {
        $r = Get-RiassuntoApprendimento -Righe @(Riga '2027-01-03T10:00:00Z' 1 'blocco' 'dev') -Adesso (Utc '2027-01-05T00:00:00Z')
        $r.Righe[0].Lunedi | Should -Be '2026-12-28'
        $r.Righe[0].Settimana | Should -Be '2026-W53'
    }

    It 'la data puo essere un datetime, come la restituisce ConvertFrom-Json' {
        $r = Get-RiassuntoApprendimento -Righe @(Riga (Utc '2026-11-18T08:00:00Z') 1 'blocco' 'dev') -Adesso $script:Adesso
        $r.Righe[0].Blocchi | Should -Be 1
    }

    It 'le righe di tipo sconosciuto, senza ruolo o con la data illeggibile si ignorano' {
        $righe = @((Riga '2026-11-18T08:00:00Z' 1 'altro' 'dev'), (Riga '2026-11-18T08:00:00Z' 2 'blocco' ''), (Riga 'ieri' 3 'blocco' 'dev'), (Riga $null 4 'blocco' 'dev')
            (Riga '2026-11-18T08:00:00Z' 5 'blocco' 'dev'))
        $r = Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso
        @($r.Righe).Count | Should -Be 1
        $r.Righe[0].Blocchi | Should -Be 1
    }

    It 'tiene le N settimane intere prima di quella in corso e quella in corso (la finestra e N+1 settimane ISO)' {
        # lunedi della settimana in corso: 2026-11-16
        $righe = @((Riga '2026-11-18T08:00:00Z' 1 'blocco' 'dev'), (Riga '2026-11-04T08:00:00Z' 2 'blocco' 'dev'), (Riga '2026-10-20T08:00:00Z' 3 'blocco' 'dev'), (Riga '2026-10-14T08:00:00Z' 4 'blocco' 'dev'), (Riga '2026-09-01T08:00:00Z' 5 'blocco' 'dev'))
        @((Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso -Settimane 4).Righe).Count | Should -Be 3
        @((Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso -Settimane 8).Righe).Count | Should -Be 4
        @((Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso -Settimane 2).Righe).Count | Should -Be 2
    }

    It 'senza -Settimane la finestra e la costante del modulo (4), la stessa per vista e PR' {
        $r = Get-RiassuntoApprendimento -Righe @() -Adesso $script:Adesso
        $r.Settimane | Should -Be 4
        $r.Finestra | Should -Be 'ultime 4 settimane intere piu quella in corso'
    }

    It 'una riga con la card non numerica o vuota si salta come una riga non JSON: le altre si contano' {
        $righe = @((Riga '2026-11-18T08:00:00Z' 'abc' 'blocco' 'dev'), (Riga '2026-11-18T08:00:00Z' '' 'blocco' 'dev'), (Riga '2026-11-18T08:00:00Z' $null 'onHold' 'dev')
            (Riga '2026-11-18T08:00:00Z' 'x' 'lezioneApplicata' 'dev' 'dev-001'), (Riga '2026-11-18T08:00:00Z' 5 'blocco' 'dev'), (Riga '2026-11-18T08:00:00Z' '6' 'blocco' 'dev'))
        $r = Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso -LezioniConosciute @{ 'dev-001' = 3 }
        @($r.Righe).Count | Should -Be 1
        $r.Righe[0].Blocchi | Should -Be 2
        $r.Righe[0].OnHold | Should -Be 0
        @($r.Evitati).Count | Should -Be 0
    }

    It 'senza righe il riassunto e vuoto e non lancia' {
        $r = Get-RiassuntoApprendimento -Righe @() -Adesso $script:Adesso
        @($r.Righe).Count | Should -Be 0
        @($r.Evitati).Count | Should -Be 0
        @((Get-RiassuntoApprendimento -Righe $null -Adesso $script:Adesso).Righe).Count | Should -Be 0
    }

    It 'una lezione ha evitato un blocco se applicata su un altra card di quella d origine, in una sessione non bloccata e senza uno stop dopo' {
        $conosciute = @{ 'dev-001' = 3; 'dev-002' = 3; 'dev-003' = 3; 'dev-004' = 3; 'dev-005' = 3; 'dev-006' = 3; 'dev-007' = 3; 'dev-008' = 3; 'dev-009' = 3 }
        $righe = @(
            (Riga '2026-11-18T08:00:00Z' 5 'lezioneApplicata' 'dev' 'dev-001' 'finito')
            (Riga '2026-11-18T08:00:00Z' 3 'lezioneApplicata' 'dev' 'dev-002' 'finito')
            (Riga '2026-11-18T08:00:00Z' 9 'lezioneApplicata' 'dev' 'dev-003' 'bloccato')
            (Riga '2026-11-18T08:00:00Z' 10 'lezioneApplicata' 'dev' 'dev-004' 'bivio')
            (Riga '2026-11-18T08:00:00Z' 11 'lezioneApplicata' 'dev' 'dev-005' 'finito'), (Riga '2026-11-18T10:00:00Z' 11 'onHold' 'dev')
            (Riga '2026-11-18T08:00:00Z' 12 'lezioneApplicata' 'dev' 'dev-006' 'finito'), (Riga '2026-11-18T10:00:00Z' 12 'blocco' 'reviewer')
            (Riga '2026-11-18T08:00:00Z' 13 'lezioneApplicata' 'dev' 'dev-007'), (Riga '2026-11-18T07:00:00Z' 13 'blocco' 'dev')
            (Riga '2026-11-18T08:00:00Z' 14 'lezioneApplicata' 'dev' 'dev-008' 'finito'), (Riga '2026-11-18T10:00:00Z' 14 'correzione' 'dev')
            (Riga '2026-11-18T08:00:00Z' 15 'lezioneApplicata' 'dev' 'dev-009' 'finito'), (Riga '2026-11-18T10:00:00Z' 15 'blocco' 'dev'))
        $e = @((Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso -LezioniConosciute $conosciute).Evitati)
        # 001: tutto in regola; 002: e la card d'origine; 003 e 004: la sessione e finita bloccata o in bivio; 005: onHold dopo;
        # 006: il blocco dopo e di un altro ruolo; 007: il blocco e prima e senza esito la sessione non risulta bloccata;
        # 008: la correzione dopo e il fallimento che la lezione doveva evitare; 009: blocco dopo
        @($e | ForEach-Object { $_.Lezione } | Sort-Object) | Should -Be @('dev-001', 'dev-006', 'dev-007')
    }

    It 'una lezione di cui non si conosce l origine, o senza lezioni conosciute, non conta come evitata' {
        $righe = @(Riga '2026-11-18T08:00:00Z' 5 'lezioneApplicata' 'dev' 'dev-001' 'finito')
        @((Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso).Evitati).Count | Should -Be 0
        @((Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso -LezioniConosciute @{ 'dev-002' = 3 }).Evitati).Count | Should -Be 0
        @((Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso -LezioniConosciute @{ 'dev-001' = 5 }).Evitati).Count | Should -Be 0
    }

    It 'lo stop e dello stesso ruolo e della stessa card: un blocco dopo su un altra card o di un altro ruolo non conta' {
        $righe = @((Riga '2026-11-18T08:00:00Z' 5 'lezioneApplicata' 'dev' 'dev-001' 'finito'), (Riga '2026-11-18T10:00:00Z' 6 'blocco' 'dev'), (Riga '2026-11-18T10:00:00Z' 5 'correzione' 'reviewer'))
        @((Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso -LezioniConosciute @{ 'dev-001' = 3 }).Evitati).Count | Should -Be 1
    }

    It 'con un registro grande il calcolo e lineare: migliaia di righe in pochi secondi' {
        $righe = @(foreach ($n in 1..2500) {
                Riga '2026-11-18T08:00:00Z' $n 'lezioneApplicata' 'dev' ('dev-{0:000}' -f ($n % 50 + 1)) 'finito'
                Riga '2026-11-18T09:00:00Z' $n 'blocco' 'reviewer'
                Riga '2026-11-18T09:00:00Z' ($n + 5000) 'onHold' 'dev' })
        $conosciute = @{}; foreach ($k in 1..50) { $conosciute[('dev-{0:000}' -f $k)] = 9999 }
        $tempo = Measure-Command { $script:Grande = Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso -LezioniConosciute $conosciute }
        $tempo.TotalSeconds | Should -BeLessThan 5
        @($script:Grande.Evitati).Count | Should -Be 50
    }

    It 'la stessa lezione su piu card si raggruppa e le card si elencano una volta' {
        $righe = @((Riga '2026-11-18T08:00:00Z' 5 'lezioneApplicata' 'dev' 'dev-001'), (Riga '2026-11-18T09:00:00Z' 5 'lezioneApplicata' 'dev' 'dev-001')
            (Riga '2026-11-19T08:00:00Z' 8 'lezioneApplicata' 'dev' 'dev-001'))
        $e = @((Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso -LezioniConosciute @{ 'dev-001' = 3 }).Evitati)
        $e.Count | Should -Be 1
        $e[0].Ruolo | Should -Be 'dev'
        @($e[0].Card) | Should -Be @(5, 8)
    }

    It 'una lezione applicata senza id non entra fra quelle che hanno evitato un blocco' {
        $e = @((Get-RiassuntoApprendimento -Righe @(Riga '2026-11-18T08:00:00Z' 5 'lezioneApplicata' 'dev' '') -Adesso $script:Adesso).Evitati)
        $e.Count | Should -Be 0
    }
}

Describe 'Le lezioni conosciute e la cache del riassunto' {
    It 'le lezioni conosciute sono id -> card d origine, per tutte le lezioni, stabili o in prova; l origine illeggibile non entra' {
        $l = @(Read-Lezioni ((Lezione dev 1 's' 'c' 'p' '5') + "`n`n" + (Lezione dev 2 's' 'c' 'p' 'boh') + "`n`n" + (Lezione reviewer 1 's' 'c' 'p' ' 7 ')))
        $c = ConvertTo-LezioniConosciute $l
        $c['dev-001'] | Should -Be 5
        $c['reviewer-001'] | Should -Be 7
        $c.ContainsKey('dev-002') | Should -BeFalse
        (ConvertTo-LezioniConosciute $null).Count | Should -Be 0
    }

    It 'il riassunto si ricalcola solo se la chiave cambia' {
        $script:Calcoli = 0; $cache = @{}
        $calcola = { param($x) $script:Calcoli++; "$x$script:Calcoli" }
        Get-RiassuntoDallaCache $cache 'a' $calcola @('v') | Should -Be 'v1'
        Get-RiassuntoDallaCache $cache 'a' $calcola @('v') | Should -Be 'v1'
        Get-RiassuntoDallaCache $cache 'b' $calcola @('v') | Should -Be 'v2'
        Get-RiassuntoDallaCache @{} 'b' $calcola @('v') | Should -Be 'v3'
        $script:Calcoli | Should -Be 3
    }
}
Describe 'Il riassunto nella descrizione della PR della memoria' {
    BeforeAll {
        function Riga($Data, $Card, [string]$Tipo, [string]$Ruolo, [string]$Lezione = $null, [string]$Esito = $null) {
            [pscustomobject]@{ data = $Data; card = $Card; repo = 'r'; tipo = $Tipo; ruolo = $Ruolo; motivo = 'm'; lezione = $Lezione; esito = $Esito }
        }
        $script:Adesso = [datetime]::Parse('2026-11-20T12:00:00Z', [cultureinfo]::InvariantCulture, 'AdjustToUniversal')
        $script:Riass = Get-RiassuntoApprendimento -Settimane 4 -Adesso $script:Adesso -LezioniConosciute @{ 'dev-003' = 1 } -Righe @(
            (Riga '2026-11-18T08:00:00Z' 5 'blocco' 'dev'), (Riga '2026-11-11T08:00:00Z' 6 'blocco' 'dev'), (Riga '2026-11-18T09:00:00Z' 6 'correzione' 'reviewer')
            (Riga '2026-11-18T10:00:00Z' 7 'lezioneApplicata' 'dev' 'dev-003'))
    }

    It 'ha i totali per ruolo delle settimane e le lezioni che hanno evitato un blocco' {
        $d = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @() -Riassunto $script:Riass
        $d | Should -BeLike '*## Apprendimento (ultime 4 settimane intere piu quella in corso)*'
        $d | Should -BeLike '*dev: 2 blocchi, 0 on-hold, 0 correzioni, 1 lezioni applicate*'
        $d | Should -BeLike '*reviewer: 0 blocchi, 0 on-hold, 1 correzioni, 0 lezioni applicate*'
        $d | Should -BeLike '*dev-003*card 7*'
    }

    It 'senza riassunto o con un riassunto vuoto la descrizione e quella di prima' {
        $senza = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @()
        New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @() -Riassunto $null | Should -Be $senza
        New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @() -Riassunto (Get-RiassuntoApprendimento -Righe @() -Adesso $script:Adesso) | Should -Be $senza
        $senza | Should -Not -BeLike '*Apprendimento*'
    }

    It 'sta nel limite: prima le note di conflitto, poi le lezioni in prova, il riassunto solo con lo spazio che resta' {
        $l = @(1..60 | ForEach-Object { Read-Lezioni (Lezione dev $_ ('y' * 150)) })
        $d = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva $l -Conflitti @('Card 5: contraddice D40', 'Card 8: contraddice il brief') -Riassunto $script:Riass
        $d.Length | Should -BeLessOrEqual 4000
        @(Get-NoteConflitto $d).Count | Should -Be 2
        $d | Should -BeLike '*dev-060*'
    }

    It 'un riassunto enorme non fa sforare il limite ne perdere le note di conflitto' {
        $righe = @(1..300 | ForEach-Object { Riga '2026-11-18T08:00:00Z' $_ 'lezioneApplicata' 'dev' ('dev-{0:000}' -f $_) })
        $conosciute = @{}; foreach ($n in 1..300) { $conosciute[('dev-{0:000}' -f $n)] = 9999 }
        $grande = Get-RiassuntoApprendimento -Righe $righe -Adesso $script:Adesso -Settimane 4 -LezioniConosciute $conosciute
        $d = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @(Read-Lezioni (Lezione dev 1 'breve')) -Conflitti @('Card 5: contraddice D40') -Riassunto $grande
        $d.Length | Should -BeLessOrEqual 4000
        @(Get-NoteConflitto $d).Count | Should -Be 1
        $d | Should -BeLike '*dev-001: breve*'
    }
}

# ---- il comando memoria.ps1: git vero su repo finti in TestDrive, Azure DevOps solo Mock ---------------------------

Describe 'memoria.ps1' {
    BeforeAll {
        foreach ($m in 'Comune', 'Config', 'Ado', 'Card', 'Worktree', 'MemoriaRepo', 'Stato') { Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Global }
        $script:MemoriaPs1 = Join-Path $script:Repo 'src/memoria.ps1'
        # Le funzioni del comando: lo script non esegue niente se lo si carica con il punto.
        . $script:MemoriaPs1

        # Il registro dell'apprendimento si legge dalla cartella dati: mai quella vera dell'utente.
        $script:DatiPrima = $env:ATTREZZI_DATI
        $env:GIT_AUTHOR_NAME = 'Test'; $env:GIT_AUTHOR_EMAIL = 'test@example.invalid'
        $env:GIT_COMMITTER_NAME = 'Test'; $env:GIT_COMMITTER_EMAIL = 'test@example.invalid'
        function g([string]$Cartella, [string[]]$Argomenti) {
            $out = & git -C $Cartella @Argomenti 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($Argomenti -join ' ') fallito: $out" }
            $out
        }
        # Un file su un ramo di origin, passando da un altro clone: la copia sorgente resta indietro come nella realta.
        function Add-SuRamo([string]$Ramo, [string]$Percorso, [string]$Testo) {
            $altra = Join-Path $script:Base ('altra-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            & git clone $script:Origin $altra 2>&1 | Out-Null
            g $altra 'checkout', $Ramo | Out-Null
            $p = Join-Path $altra $Percorso
            New-Item -ItemType Directory -Force (Split-Path -Parent $p) | Out-Null
            [IO.File]::WriteAllText($p, $Testo)
            g $altra 'add', '-A' | Out-Null
            g $altra 'commit', '-m', "aggiunge $Percorso" | Out-Null
            g $altra 'push', 'origin', $Ramo | Out-Null
        }
        function Add-SuDevelop([string]$Percorso, [string]$Testo) { Add-SuRamo 'develop' $Percorso $Testo }
        function Get-DaOrigin([string]$Ref, [string]$Percorso) {
            # git scrive UTF-8: con la tabella della console le lettere accentate si leggerebbero storte
            $prima = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
            try { $r = & git -C $script:Origin show "${Ref}:$Percorso" 2>&1 } finally { [Console]::OutputEncoding = $prima }
            if ($LASTEXITCODE -ne 0) { return $null }
            (@($r) -join "`n")
        }
        function Test-RamoSuOrigin { (& git -C $script:Origin branch --list 'memoria/in-prova' 2>&1 | Out-String).Trim() -ne '' }
        function Get-CampiProva($S = 'Il test non parte', $C = 'Lancia prima il restore', $P = 'Senza pacchetti fallisce', $Card = '57') {
            [pscustomobject]@{ situazione = $S; cosaFare = $C; perche = $P; card = $Card }
        }
        # Le PR della memoria come le restituisce Get-AdoPrDelRamo: la attiva, o una chiusa su un commit.
        function Set-PrAttiva { $global:PrFinte = @([pscustomobject]@{ Id = 7; Stato = 'active'; CommitSorgente = $null }) }
        function Set-PrChiusaSulla([string]$Stato = 'abandoned') {
            $global:PrFinte = @([pscustomobject]@{ Id = 7; Stato = $Stato; CommitSorgente = (g $script:Origin 'rev-parse', 'memoria/in-prova') })
        }
        # Il progetto e il repo di Azure DevOps sono quelli del repo della memoria: un Mock che non li controlla lascerebbe
        # passare una chiamata verso il repo sbagliato.
        $script:FiltroAdo = { $Progetto -eq 'DevOps.Agents' -and $Repo -eq 'DevOps.Agents' }
        $script:RepoA = 'Acme.AI'
        $script:RepoB = 'Acme.Workflow'
    }

    BeforeEach {
        $script:Base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Origin = Join-Path $script:Base 'origin.git'
        $script:Sorgente = Join-Path $script:Base 'sorgente'
        New-Item -ItemType Directory $script:Base | Out-Null
        & git init --bare -b develop $script:Origin 2>&1 | Out-Null
        & git clone $script:Origin $script:Sorgente 2>&1 | Out-Null
        g $script:Sorgente 'checkout', '-b', 'develop' | Out-Null
        Set-Content (Join-Path $script:Sorgente 'LEGGIMI.md') 'prova'
        g $script:Sorgente 'add', '-A' | Out-Null
        g $script:Sorgente 'commit', '-m', 'iniziale' | Out-Null
        g $script:Sorgente 'push', '-u', 'origin', 'develop' | Out-Null

        $script:Wt = Join-Path $script:Base 'wt/memoria'
        $script:Ctx = New-ContestoMemoria -Worktree $script:Wt -Sorgente $script:Sorgente
        $script:Ctx.AttesaMutexSecondi = 5

        $script:Dati = Join-Path $script:Base 'dati'
        $env:ATTREZZI_DATI = $script:Dati
        $global:PrFinte = @()
        $global:DescrizioneFinta = ''
        # Senza il filtro giusto ogni chiamata fallisce.
        Mock Get-AdoPrDelRamo -ModuleName MemoriaRepo { throw "Get-AdoPrDelRamo chiamata con parametri inattesi: $Progetto / $Repo / $Ramo" }
        Mock Get-AdoPrDelRamo -ModuleName MemoriaRepo { $global:PrFinte } -ParameterFilter { $Progetto -eq 'DevOps.Agents' -and $Repo -eq 'DevOps.Agents' -and $Ramo -eq 'memoria/in-prova' }
        Mock New-AdoPr { throw 'New-AdoPr chiamata con parametri inattesi' }
        Mock New-AdoPr { 7 } -ParameterFilter { $Progetto -eq 'DevOps.Agents' -and $Repo -eq 'DevOps.Agents' -and $Ramo -eq 'memoria/in-prova' }
        Mock Get-AdoDescrizionePr { throw 'Get-AdoDescrizionePr chiamata con parametri inattesi' }
        Mock Get-AdoDescrizionePr { $global:DescrizioneFinta } -ParameterFilter $script:FiltroAdo
        Mock Set-AdoDescrizionePr { throw 'Set-AdoDescrizionePr chiamata con parametri inattesi' }
        Mock Set-AdoDescrizionePr { } -ParameterFilter $script:FiltroAdo
        Mock Add-CardCommento { 99 }
    }
    AfterAll {
        Remove-Variable PrFinte, DescrizioneFinta -Scope Global -ErrorAction SilentlyContinue
        $env:ATTREZZI_DATI = $script:DatiPrima
    }

    Context 'il riassunto dell apprendimento nella descrizione della PR' {
        It 'legge il registro dalla cartella dati e mette in descrizione i totali per ruolo' {
            Add-RigaApprendimento -CartellaDati $script:Dati -Card 5 -Tipo 'blocco' -Ruolo 'dev' -Motivo 'm'
            Add-RigaApprendimento -CartellaDati $script:Dati -Card 6 -Tipo 'lezioneApplicata' -Ruolo 'dev' -Lezione 'dev-001'
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva))
            Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Descrizione -like '*## Apprendimento (ultime 4 settimane intere piu quella in corso)*dev: 1 blocchi, 0 on-hold, 0 correzioni, 1 lezioni applicate*dev-001 (dev): card 6*' }
        }

        It 'una lezione applicata sulla card da cui nasce non e fra quelle che hanno evitato un blocco (la card d origine di dev-001 e la 57)' {
            Add-RigaApprendimento -CartellaDati $script:Dati -Card 57 -Tipo 'lezioneApplicata' -Ruolo 'dev' -Lezione 'dev-001'
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva))
            Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Descrizione -like '*## Apprendimento*dev: 0 blocchi, 0 on-hold, 0 correzioni, 1 lezioni applicate*' -and $Descrizione -notlike '*hanno evitato*' }
        }

        It 'la descrizione che arriva a New-AdoPr sta nel massimo che Ado.psm1 dice, anche con una lezione che da sola lo supera' {
            $enorme = Get-CampiProva ('x' * 4500)
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' $enorme)
            Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Descrizione.Length -le (Get-AdoLimiteTestoPr) -and $Descrizione -like '*non elencate*' }
        }

        It 'senza registro la descrizione esce senza riassunto' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva))
            Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Descrizione -like '*dev-001*' -and $Descrizione -notlike '*Apprendimento*' }
        }

        It 'con un registro che non si legge la lezione si scrive lo stesso e la descrizione esce senza riassunto' {
            # una cartella al posto del file: aprirlo come file fallisce
            New-Item -ItemType Directory -Path (Join-Path $script:Dati 'registro-apprendimento.jsonl') -Force | Out-Null
            $r = Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva)
            $r.Id | Should -Be 'dev-001'
            $r.PrErrore | Should -BeNullOrEmpty
            Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Descrizione -like '*dev-001*' -and $Descrizione -notlike '*Apprendimento*' }
        }
    }

    Context 'scrivi' {
        It 'assegna l id, committa e pusha su memoria/in-prova, crea la PR e il worktree' {
            $r = Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva)
            $r.Id | Should -Be 'dev-001'
            $r.PrErrore | Should -BeNullOrEmpty
            Test-Path (Join-Path $script:Wt '.git') | Should -BeTrue
            (g $script:Wt 'branch', '--show-current') | Should -Be 'memoria/in-prova'
            $f = Get-DaOrigin 'memoria/in-prova' 'memoria/dev/comune.md'
            $f | Should -BeLike '*### dev-001*'
            $f | Should -BeLike '*- Situazione: Il test non parte*'
            $f | Should -BeLike '*- Perché: Senza pacchetti fallisce*'
            Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'memoria/in-prova' -and $Descrizione -like '*dev-001*Il test non parte*' }
            Should -Invoke Set-AdoDescrizionePr -Times 0 -Exactly
        }

        It 'con la PR gia attiva riparte dal ramo remoto, non crea una PR nuova e ne aggiorna la descrizione' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'prima'))
            Set-PrAttiva
            (Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'seconda')).Id | Should -Be 'dev-002'
            $f = Get-DaOrigin 'memoria/in-prova' 'memoria/dev/comune.md'
            $f | Should -BeLike '*- Situazione: prima*'
            $f | Should -BeLike '*- Situazione: seconda*'
            Should -Invoke New-AdoPr -Times 1 -Exactly
            Should -Invoke Set-AdoDescrizionePr -Times 1 -Exactly -ParameterFilter { $Id -eq 7 -and $Descrizione -like '*dev-001*prima*dev-002*seconda*' }
            (g $script:Origin 'rev-list', '--count', 'develop..memoria/in-prova') | Should -Be '2'
        }

        # Cambiato: prima la PR abbandonata faceva ripartire da develop e riusava dev-001. Ora l id non si riusa mai
        # (punto 6) e la PR chiusa si riconosce dal commit su cui e stata chiusa (punto 3).
        It 'con la PR abbandonata riparte da develop e forza il push, ma l id della lezione bocciata non si riusa' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'abbandonata'))
            Set-PrChiusaSulla 'abandoned'
            (Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'nuova')).Id | Should -Be 'dev-002'
            $f = Get-DaOrigin 'memoria/in-prova' 'memoria/dev/comune.md'
            $f | Should -Not -BeLike '*abbandonata*'
            $f | Should -BeLike '*- Situazione: nuova*'
            (g $script:Origin 'rev-list', '--count', 'develop..memoria/in-prova') | Should -Be '1'
            Should -Invoke New-AdoPr -Times 2 -Exactly
        }

        It 'con la PR completata (anche a squash: la testa non e in develop) riparte da develop e forza il push' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'unita-con-squash'))
            Set-PrChiusaSulla 'completed'
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'dopo'))
            $f = Get-DaOrigin 'memoria/in-prova' 'memoria/dev/comune.md'
            $f | Should -Not -BeLike '*unita-con-squash*'
            (g $script:Origin 'rev-list', '--count', 'develop..memoria/in-prova') | Should -Be '1'
        }

        It 'a PR unita (le lezioni sono su develop) riparte da develop e prosegue la numerazione' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'unita'))
            g $script:Origin 'update-ref', 'refs/heads/develop', 'memoria/in-prova' | Out-Null
            (Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'dopo')).Id | Should -Be 'dev-002'
            $f = Get-DaOrigin 'memoria/in-prova' 'memoria/dev/comune.md'
            $f | Should -BeLike '*- Situazione: unita*'
            $f | Should -BeLike '*- Situazione: dopo*'
        }

        It 'a PR unita con il ramo cancellato riparte da develop e prosegue la numerazione' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'unita'))
            g $script:Origin 'update-ref', 'refs/heads/develop', 'memoria/in-prova' | Out-Null
            g $script:Origin 'branch', '-D', 'memoria/in-prova' | Out-Null
            (Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'dopo')).Id | Should -Be 'dev-002'
        }

        It 'se la PR non e mai nata (il push era riuscito) riparte dal ramo e la scrittura crea la PR: le lezioni non si buttano' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'prima'))
            $global:PrFinte = @()   # nessuna PR, attiva o chiusa
            (Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'seconda')).Id | Should -Be 'dev-002'
            $f = Get-DaOrigin 'memoria/in-prova' 'memoria/dev/comune.md'
            $f | Should -BeLike '*- Situazione: prima*'
            $f | Should -BeLike '*- Situazione: seconda*'
            (g $script:Origin 'rev-list', '--count', 'develop..memoria/in-prova') | Should -Be '2'
            Should -Invoke New-AdoPr -Times 2 -Exactly
            Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Descrizione -like '*dev-001*prima*dev-002*seconda*' }
        }

        It 'una PR chiusa su un commit vecchio non copre le lezioni scritte dopo: si riparte dal ramo' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'prima'))
            Set-PrAttiva
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'seconda'))
            $global:PrFinte = @([pscustomobject]@{ Id = 7; Stato = 'abandoned'; CommitSorgente = (g $script:Origin 'rev-parse', 'memoria/in-prova~1') })
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'terza'))
            $f = Get-DaOrigin 'memoria/in-prova' 'memoria/dev/comune.md'
            $f | Should -BeLike '*- Situazione: prima*'
            $f | Should -BeLike '*- Situazione: seconda*'
            $f | Should -BeLike '*- Situazione: terza*'
        }

        It 'un errore nel leggere le PR ferma la scrittura: niente push, niente forza, niente PR' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'prima'))
            $testa = g $script:Origin 'rev-parse', 'memoria/in-prova'
            Mock Get-AdoPrDelRamo -ModuleName MemoriaRepo { throw 'rete giu' } -ParameterFilter { $Ramo -eq 'memoria/in-prova' }
            { Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'seconda') } | Should -Throw '*rete giu*'
            (g $script:Origin 'rev-parse', 'memoria/in-prova') | Should -Be $testa
            Should -Invoke New-AdoPr -Times 1 -Exactly
            Should -Invoke Set-AdoDescrizionePr -Times 0 -Exactly
        }

        It 'il push con --force-with-lease e respinto se nel frattempo un altro clone ha pushato sul ramo' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'prima'))
            Set-PrChiusaSulla 'abandoned'   # si riparte da develop e si forza
            $altroClone = {
                param($c)
                Add-SuRamo 'memoria/in-prova' 'memoria/dev/altro.md' ((Lezione dev 9 'di un altro clone') + "`n")
                Write-FileMemoria (Join-Path $c.Worktree 'memoria/dev/comune.md') ((Lezione dev 2 'mia') + "`n")
            }
            { Save-ModificaMemoria $script:Ctx $altroClone 'chore(memoria): prova' $null } | Should -Throw '*push*'
            (Get-DaOrigin 'memoria/in-prova' 'memoria/dev/altro.md') | Should -BeLike '*di un altro clone*'
            Should -Invoke New-AdoPr -Times 1 -Exactly
        }

        It 'l id continua oltre le lezioni dello stesso ruolo negli altri file, anche su develop' {
            Add-SuDevelop "memoria/dev/$script:RepoA.md" (Lezione dev 4)
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva))
            Set-PrAttiva
            (Invoke-MemoriaScrivi $script:Ctx 'dev' $script:RepoB (Get-CampiProva)).Id | Should -Be 'dev-006'
        }

        It 'l id non ripete quello di una lezione tolta da develop in un commit precedente' {
            Add-SuDevelop 'memoria/dev/comune.md' ((Lezione dev 7) + "`n")
            Add-SuDevelop 'memoria/dev/comune.md' ''
            (Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva)).Id | Should -Be 'dev-008'
        }

        It 'l id non ripete quello di una lezione tolta sul ramo in prova' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'una'))
            Set-PrAttiva
            [void](Invoke-MemoriaTogli $script:Ctx 'dev-001')
            (Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'due')).Id | Should -Be 'dev-002'
        }

        It 'rifiuta un campo mancante o vuoto e non scrive niente' {
            { Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' ([pscustomobject]@{ situazione = 'a'; cosaFare = ''; card = '1' }) } |
                Should -Throw '*cosaFare*'
            Test-RamoSuOrigin | Should -BeFalse
            Should -Invoke Get-AdoPrDelRamo -ModuleName MemoriaRepo -Times 0 -Exactly
            Should -Invoke New-AdoPr -Times 0 -Exactly
        }

        It 'rifiuta un ruolo che non e in ruoli.json' {
            { Invoke-MemoriaScrivi $script:Ctx 'cuoco' 'comune' (Get-CampiProva) } | Should -Throw "*cuoco*"
            Test-RamoSuOrigin | Should -BeFalse
        }

        It 'rifiuta un repo che non e comune ne un repo di mappa.json, anche per le maiuscole o un percorso' {
            foreach ($dove in 'Repo.Inventato', 'acme.ai', '..\..\LEGGIMI') {
                { Invoke-MemoriaScrivi $script:Ctx 'dev' $dove (Get-CampiProva) } | Should -Throw '*sconosciuto*'
            }
            Test-RamoSuOrigin | Should -BeFalse
        }

        It 'accetta un repo di mappa.json col nome esatto' {
            (Invoke-MemoriaScrivi $script:Ctx 'dev' $script:RepoA (Get-CampiProva)).Id | Should -Be 'dev-001'
        }

        It 'oltre il tetto rifiuta e chiede il consolidamento' {
            $script:Ctx.Tetto = 3
            Add-SuDevelop 'memoria/dev/comune.md' (((1..3 | ForEach-Object { Lezione dev $_ }) -join "`n`n") + "`n")
            { Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva) } | Should -Throw '*consolid*'
            Test-RamoSuOrigin | Should -BeFalse
            Should -Invoke New-AdoPr -Times 0 -Exactly
        }
    }

    Context 'dopo il push, la PR che non si aggiorna' {
        It 'scrivi: se la creazione della PR fallisce la lezione e pubblicata e l errore e nel risultato, non un throw' {
            Mock New-AdoPr { throw 'ADO non risponde' } -ParameterFilter { $Ramo -eq 'memoria/in-prova' }
            $r = Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva)
            $r.Id | Should -Be 'dev-001'
            $r.PrErrore | Should -BeLike '*ADO non risponde*'
            (Get-DaOrigin 'memoria/in-prova' 'memoria/dev/comune.md') | Should -BeLike '*### dev-001*'
            Get-MessaggioEsito $r 'scritta' | Should -Be 'lezione dev-001 scritta; PR non aggiornata: ADO non risponde'
        }

        It 'scrivi: se l aggiornamento della descrizione fallisce la lezione e pubblicata e l errore e nel risultato' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'prima'))
            Set-PrAttiva
            Mock Set-AdoDescrizionePr { throw 'ADO non risponde' } -ParameterFilter $script:FiltroAdo
            $r = Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'seconda')
            $r.PrErrore | Should -BeLike '*ADO non risponde*'
            (Get-DaOrigin 'memoria/in-prova' 'memoria/dev/comune.md') | Should -BeLike '*seconda*'
        }

        It 'la PR si sistema alla scrittura dopo: il ramo con commit non coperti riparte da li e la PR nasce' {
            Mock New-AdoPr { throw 'ADO non risponde' } -ParameterFilter { $Ramo -eq 'memoria/in-prova' }
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'prima'))
            Mock New-AdoPr { 8 } -ParameterFilter { $Ramo -eq 'memoria/in-prova' }
            $r = Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'seconda')
            $r.PrErrore | Should -BeNullOrEmpty
            Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Descrizione -like '*dev-001*prima*dev-002*seconda*' }
        }

        It 'rivedi e togli: stesso comportamento, lezione scritta e PR non aggiornata nel risultato' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'una'))
            Set-PrAttiva
            Mock Set-AdoDescrizionePr { throw 'ADO non risponde' } -ParameterFilter $script:FiltroAdo
            $r = Invoke-MemoriaRivedi $script:Ctx 'dev-001' (Get-CampiProva 'rivista')
            $r.PrErrore | Should -BeLike '*ADO non risponde*'
            $r.Id | Should -Be 'dev-001'
            $t = Invoke-MemoriaTogli $script:Ctx 'dev-001'
            $t.PrErrore | Should -BeLike '*ADO non risponde*'
        }

        It 'senza errore il messaggio e quello normale' {
            Get-MessaggioEsito ([pscustomobject]@{ Id = 'dev-003'; PrErrore = $null }) 'rivista' | Should -Be 'Lezione dev-003 rivista.'
        }

        It 'conflitto: se la PR non si aggiorna fallisce e non commenta la card, cosi il tentativo dopo non fa doppioni' {
            Mock New-AdoPr { throw 'ADO non risponde' } -ParameterFilter { $Ramo -eq 'memoria/in-prova' }
            { Invoke-MemoriaConflitto $script:Ctx 55 'contraddice D40' } | Should -Throw '*ADO non risponde*'
            Should -Invoke Add-CardCommento -Times 0 -Exactly
        }
    }

    Context 'il worktree fisso' {
        It 'una cartella che esiste ma non e un worktree registrato del repo si rifiuta' {
            New-Item -ItemType Directory -Force $script:Wt | Out-Null
            Set-Content (Join-Path $script:Wt 'estraneo.txt') 'non mio'
            { Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva) } | Should -Throw '*registrato*'
            Test-RamoSuOrigin | Should -BeFalse
            Test-Path (Join-Path $script:Wt 'estraneo.txt') | Should -BeTrue
        }

        It 'se la cartella e sparita ma il worktree e ancora registrato, lo ripulisce e lo ricrea' {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'prima'))
            Remove-Item -Recurse -Force $script:Wt
            Set-PrAttiva
            (Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'seconda')).Id | Should -Be 'dev-002'
            Test-Path (Join-Path $script:Wt '.git') | Should -BeTrue
        }
    }

    Context 'rivedi e togli' {
        BeforeEach {
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'uno'))
            Set-PrAttiva
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'due'))
        }

        It 'rivedi sostituisce la lezione con quell id, che resta lo stesso' {
            [void](Invoke-MemoriaRivedi $script:Ctx 'dev-001' (Get-CampiProva 'uno corretta' 'fai X' 'perche Y' '60'))
            $l = @(Read-Lezioni (Get-DaOrigin 'memoria/in-prova' 'memoria/dev/comune.md'))
            $l.Count | Should -Be 2
            $l[0].Id | Should -Be 'dev-001'
            $l[0].Situazione | Should -Be 'uno corretta'
            $l[0].Card | Should -Be '60'
            $l[1].Situazione | Should -Be 'due'
        }

        It 'rivedi vuole i quattro campi' {
            { Invoke-MemoriaRivedi $script:Ctx 'dev-001' ([pscustomobject]@{ situazione = 'x' }) } | Should -Throw '*cosaFare*'
        }

        It 'togli toglie la lezione' {
            [void](Invoke-MemoriaTogli $script:Ctx 'dev-001')
            $l = @(Read-Lezioni (Get-DaOrigin 'memoria/in-prova' 'memoria/dev/comune.md'))
            $l.Count | Should -Be 1
            $l[0].Id | Should -Be 'dev-002'
        }

        It 'con un id che non esiste e un errore e non pubblica niente di nuovo' {
            $prima = g $script:Origin 'rev-parse', 'memoria/in-prova'
            { Invoke-MemoriaRivedi $script:Ctx 'dev-009' (Get-CampiProva) } | Should -Throw '*dev-009*'
            { Invoke-MemoriaTogli $script:Ctx 'dev-009' } | Should -Throw '*dev-009*'
            { Invoke-MemoriaTogli $script:Ctx 'storto' } | Should -Throw '*storto*'
            (g $script:Origin 'rev-parse', 'memoria/in-prova') | Should -Be $prima
        }

        It 'si puo rivedere una lezione stabile (su develop): diventa in prova con lo stesso id' {
            Set-PrChiusaSulla 'abandoned'   # chiusa la PR si riparte da develop, che ora ha il file
            Add-SuDevelop 'memoria/reviewer/comune.md' ((Lezione reviewer 1 'stabile') + "`n")
            [void](Invoke-MemoriaRivedi $script:Ctx 'reviewer-001' (Get-CampiProva 'rivista'))
            $l = @(Read-Lezioni (Get-DaOrigin 'memoria/in-prova' 'memoria/reviewer/comune.md'))
            $l[0].Situazione | Should -Be 'rivista'
        }
    }

    Context 'conflitto' {
        It 'commenta la card come mentore e mette la nota nella PR, creandola con un commit vuoto' {
            $r = Invoke-MemoriaConflitto $script:Ctx 55 'La correzione contraddice D40'
            Should -Invoke Add-CardCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 55 -and $Ruolo -eq 'mentore' -and $Testo -like '*contraddice D40*' }
            Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Descrizione -like '*Card 55: La correzione contraddice D40*' }
            (g $script:Origin 'rev-list', '--count', 'develop..memoria/in-prova') | Should -Be '1'
            $r | Should -BeLike '*55*'
        }

        It 'con la PR gia attiva tiene le note vecchie e aggiunge la nuova' {
            Set-PrAttiva
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva))
            $global:DescrizioneFinta = New-DescrizionePrMemoria -Limite $script:Lim -LezioniInProva @() -Conflitti @('Card 5: nota vecchia')
            [void](Invoke-MemoriaConflitto $script:Ctx 8 'nota nuova')
            Should -Invoke Set-AdoDescrizionePr -Times 1 -Exactly -ParameterFilter {
                $Descrizione -like '*dev-001*' -and $Descrizione -like '*Card 5: nota vecchia*' -and $Descrizione -like '*Card 8: nota nuova*' }
        }

        It 'senza testo e un errore' {
            { Invoke-MemoriaConflitto $script:Ctx 55 '  ' } | Should -Throw '*testo*'
            Should -Invoke Add-CardCommento -Times 0 -Exactly
        }
    }

    Context 'leggi' {
        It 'con una PR attiva mostra le lezioni stabili senza etichetta e quelle in prova con (in prova)' {
            Add-SuDevelop 'memoria/dev/comune.md' ((Lezione dev 1 'stabile') + "`n")
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'in prova'))
            Set-PrAttiva
            $t = Invoke-MemoriaLeggi $script:Ctx 'dev' $script:RepoA
            $t | Should -BeLike "*### dev-001`n*Situazione: stabile*"
            $t | Should -BeLike "*### dev-002 (in prova)`n*Situazione: in prova*"
            $t | Should -BeLike '*- Perché: Senza pacchetti fallisce*'
        }

        It 'senza una PR attiva le lezioni in prova non si servono, nemmeno se il ramo c e' {
            Add-SuDevelop 'memoria/dev/comune.md' ((Lezione dev 1 'stabile') + "`n")
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'bocciata'))
            Set-PrChiusaSulla 'abandoned'
            $t = Invoke-MemoriaLeggi $script:Ctx 'dev' $script:RepoA
            $t | Should -BeLike '*Situazione: stabile*'
            $t | Should -Not -BeLike '*bocciata*'
        }

        It 'se le PR non si leggono serve solo develop e lo dice' {
            Add-SuDevelop 'memoria/dev/comune.md' ((Lezione dev 1 'stabile') + "`n")
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'non confermata'))
            Mock Get-AdoPrDelRamo -ModuleName MemoriaRepo { throw 'rete giu' } -ParameterFilter { $Ramo -eq 'memoria/in-prova' }
            $t = Invoke-MemoriaLeggi $script:Ctx 'dev' $script:RepoA
            $t | Should -BeLike '*Situazione: stabile*'
            $t | Should -Not -BeLike '*non confermata*'
            $t | Should -BeLike '*rete giu*'
        }

        It 'senza il ramo in prova legge develop e niente e in prova' {
            Add-SuDevelop "memoria/dev/$script:RepoA.md" ((Lezione dev 1 'di repo') + "`n")
            $t = Invoke-MemoriaLeggi $script:Ctx 'dev' $script:RepoA
            $t | Should -BeLike '*Situazione: di repo*'
            $t | Should -Not -BeLike '*in prova)*'
        }

        It 'senza lezioni lo dice' {
            Invoke-MemoriaLeggi $script:Ctx 'dev' $script:RepoA | Should -BeLike '*nessuna lezione*'
        }

        It 'una lezione tolta sul ramo in prova non si legge piu' {
            Add-SuDevelop 'memoria/dev/comune.md' ((Lezione dev 1 'tolta') + "`n")
            Set-PrAttiva
            [void](Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva 'altra'))
            [void](Invoke-MemoriaTogli $script:Ctx 'dev-001')
            Invoke-MemoriaLeggi $script:Ctx 'dev' $script:RepoA | Should -Not -BeLike '*tolta*'
        }

        It 'rifiuta un repo che non e di mappa.json' {
            { Invoke-MemoriaLeggi $script:Ctx 'dev' 'Repo.Inventato' } | Should -Throw '*sconosciuto*'
        }
    }

    Context 'due scritture insieme' {
        It 'una scrittura aspetta il mutex e, se non lo ottiene, rinuncia senza toccare niente' {
            $script:Ctx.AttesaMutexSecondi = 1
            $nome = Get-NomeMutexMemoria $script:Ctx
            $job = Start-ThreadJob -ArgumentList $nome {
                param($n)
                $m = [System.Threading.Mutex]::new($false, $n)
                [void]$m.WaitOne()
                Start-Sleep -Seconds 5
                $m.ReleaseMutex()
            }
            try {
                Start-Sleep -Milliseconds 1500
                { Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva) } | Should -Throw '*in corso*'
                Test-RamoSuOrigin | Should -BeFalse
            }
            finally { Wait-Job $job | Remove-Job }
            # rilasciato il mutex, la scrittura riesce
            $script:Ctx.AttesaMutexSecondi = 5
            (Invoke-MemoriaScrivi $script:Ctx 'dev' 'comune' (Get-CampiProva)).Id | Should -Be 'dev-001'
        }
    }

    Context 'la riga di comando' {
        BeforeAll {
            # Il comando gira in un processo suo, dove i Mock non arrivano: con i valori predefiniti leggerebbe il PAT vero
            # dello smistatore dalla cartella utente e userebbe come sorgente questo repo, con l'origin vero. E successo il
            # 23/11/2026: un test rosso ha pushato memoria/in-prova, aperto la PR 1080 e commentato la card 6 veri. Qui il
            # processo ha una cartella utente vuota (nessun PAT: Azure DevOps rifiuta prima di partire), una sorgente git
            # senza remoto e un worktree in TestDrive, salvo che il test li dia lui.
            function Invoke-Cli([string]$Stdin, [string[]]$Argomenti) {
                $casa = Join-Path $TestDrive 'casa-finta'
                New-Item -ItemType Directory -Path $casa -Force | Out-Null
                $sorgente = Join-Path $TestDrive 'sorgente-finta'
                if (-not (Test-Path -LiteralPath $sorgente)) { git init -q $sorgente 2>&1 | Out-Null }
                $argomenti = @($Argomenti)
                if ($argomenti -notcontains '-Sorgente') { $argomenti += @('-Sorgente', $sorgente) }
                if ($argomenti -notcontains '-Worktree') { $argomenti += @('-Worktree', (Join-Path $TestDrive 'worktree-finto')) }
                $vecchie = @{ USERPROFILE = $env:USERPROFILE; HOME = $env:HOME }
                try {
                    $env:USERPROFILE = $casa; $env:HOME = $casa
                    $out = if ($null -ne $Stdin) { $Stdin | & pwsh -NoProfile -File $script:MemoriaPs1 @argomenti 2>&1 } else { & pwsh -NoProfile -File $script:MemoriaPs1 @argomenti 2>&1 }
                    $codice = $LASTEXITCODE
                }
                finally { foreach ($k in $vecchie.Keys) { Set-Item "Env:$k" $vecchie[$k] } }
                [pscustomobject]@{ Codice = $codice; Testo = ($out | Out-String) }
            }
        }

        It 'il processo del comando non raggiunge il mondo vero: un conflitto valido fallisce senza PAT e senza remoto' {
            $prima = $env:ATTREZZI_CARD
            try {
                Remove-Item Env:ATTREZZI_CARD -ErrorAction SilentlyContinue
                $r = Invoke-Cli 'La correzione contraddice una regola scritta' @('conflitto', '6')
                $r.Codice | Should -Be 1 -Because $r.Testo
                $r.Testo | Should -Not -BeLike '*PR 1*'
            }
            finally { if ($null -ne $prima) { $env:ATTREZZI_CARD = $prima } }
        }

        It 'un comando sconosciuto esce con 1 e un messaggio' {
            $r = Invoke-Cli $null @('boh')
            $r.Codice | Should -Be 1
            $r.Testo | Should -BeLike '*memoria:*comando sconosciuto*'
        }

        It 'conflitto in una sessione di agente (ATTREZZI_CARD impostata) accetta solo la card della sessione, e non tocca git' {
            $prima = $env:ATTREZZI_CARD
            try {
                $env:ATTREZZI_CARD = '5'
                $r = Invoke-Cli '  ' @('conflitto', '6', '-Worktree', (Join-Path $TestDrive 'mai'))
                $r.Codice | Should -Be 1
                $r.Testo | Should -BeLike '*ATTREZZI_CARD*'
                Test-Path (Join-Path $TestDrive 'mai') | Should -BeFalse
                # stdin vuoto in entrambi i casi: se il controllo mancasse, il comando si fermerebbe lo stesso prima di git e di Azure DevOps
                # la card giusta passa il controllo: l'errore e un altro (qui il testo vuoto)
                $ok = Invoke-Cli '  ' @('conflitto', '5', '-Worktree', (Join-Path $TestDrive 'mai'))
                $ok.Codice | Should -Be 1
                $ok.Testo | Should -Not -BeLike '*ATTREZZI_CARD*'
                $ok.Testo | Should -BeLike '*testo*'
            }
            finally { $env:ATTREZZI_CARD = $prima }
        }

        It 'scrivi con un campo vuoto esce con 1 e dice quale, prima di toccare git o Azure DevOps' {
            $r = Invoke-Cli '{"situazione":"a","cosaFare":"","perche":"c","card":"1"}' @('scrivi', 'dev', 'comune', '-Worktree', (Join-Path $TestDrive 'mai'))
            $r.Codice | Should -Be 1
            $r.Testo | Should -BeLike '*cosaFare*'
            Test-Path (Join-Path $TestDrive 'mai') | Should -BeFalse
        }

        It 'scrivi con uno stdin che non e JSON esce con 1' {
            $r = Invoke-Cli 'non json' @('scrivi', 'dev', 'comune', '-Worktree', (Join-Path $TestDrive 'mai'))
            $r.Codice | Should -Be 1
            $r.Testo | Should -BeLike '*JSON*'
        }

        It 'scrivi con un ruolo sconosciuto esce con 1' {
            $r = Invoke-Cli '{}' @('scrivi', 'cuoco', 'comune', '-Worktree', (Join-Path $TestDrive 'mai'))
            $r.Codice | Should -Be 1
            $r.Testo | Should -BeLike '*cuoco*'
        }

        It 'scrivi con un repo sconosciuto esce con 1 prima di toccare git' {
            $r = Invoke-Cli '{}' @('scrivi', 'dev', 'Repo.Inventato', '-Worktree', (Join-Path $TestDrive 'mai'))
            $r.Codice | Should -Be 1
            $r.Testo | Should -BeLike '*sconosciuto*'
            Test-Path (Join-Path $TestDrive 'mai') | Should -BeFalse
        }
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }
