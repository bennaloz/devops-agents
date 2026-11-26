BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Comune.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot '../src/Aggiornamento.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot '../src/VistaSuite.psm1') -Force -Global
}

Describe 'Format-RequisitoMancante: la frase (D53, punto 5)' {
    It 'dice cosa serve e cosa c e' {
        Format-RequisitoMancante @{ Nome = 'claude'; Richiesta = '2.1'; Trovata = '2.0.9' } | Should -Match "claude.*serve la versione 2.1.*c'e la 2.0.9"
    }
    It 'un programma che non c e: non e installato; legge anche la forma salvata in aggiornamento.json' {
        Format-RequisitoMancante @{ Nome = 'claude'; Richiesta = '2.1'; Trovata = $null } | Should -Match 'non e installato'
        Format-RequisitoMancante @{ nome = 'powershell'; richiesta = '7.4'; trovata = '5.1.1' } | Should -Match "powershell.*7.4.*c'e la 5.1.1"
    }
}

Describe 'ConvertTo-ModelloSuite: cosa vede la vista (D53, punto 8)' {
    It 'senza stato: non letto, con una frase che lo dice' {
        $m = ConvertTo-ModelloSuite @{} $true
        $m.Letto | Should -BeFalse; $m.Automatico | Should -BeTrue; $m.Stato | Should -Match 'nessun controllo'
    }
    It 'aggiornata: versioni, ultimo controllo, nessun allarme' {
        $s = @{ canale = 'main'; installata = @{ canale = 'main'; hash = 'abc1234'; data = '2026-11-25T09:30:00Z' }; disponibile = $null; ultimoControllo = '2026-11-25T10:00:00Z'
            ultimoEsito = @{ esito = 'aggiornato'; quando = '2026-11-25T10:00:00Z' }; prInArrivo = @() }
        $m = ConvertTo-ModelloSuite $s $false
        $m.Letto | Should -BeTrue; $m.Installata | Should -Match 'main abc1234'; $m.Disponibile | Should -BeNullOrEmpty
        $m.Stato | Should -Match 'aggiornata'; $m.Allarme | Should -BeFalse; $m.Automatico | Should -BeFalse
        $m.UltimoControllo | Should -Match '^\d\d/\d\d \d\d:\d\d$'
    }
    It 'le PR in arrivo portano numero, titolo e link' {
        $s = @{ canale = 'main'; installata = @{ hash = 'a' }; disponibile = @{ canale = 'main'; hash = 'b'; data = '2026-11-25T09:30:00Z' }
            ultimoEsito = @{ esito = 'daAggiornare' }; prInArrivo = @(@{ numero = 1201; titolo = 'Una PR'; url = 'https://x/pullrequest/1201' }) }
        $m = ConvertTo-ModelloSuite $s $false
        $m.Pr[0].Numero | Should -Be 1201; $m.Pr[0].Titolo | Should -Be 'Una PR'; $m.Pr[0].Url | Should -Be 'https://x/pullrequest/1201'
        $m.Stato | Should -Match 'automatico e spento'
    }
    It 'ogni esito che chiede qualcosa a una persona e un allarme, con la sua frase' {
        $casi = @{
            requisitiMancanti = @{ esito = 'requisitiMancanti'; elenco = @(@{ nome = 'claude'; richiesta = '9.0'; trovata = '2.1.3' }) }
            modificheLocali = @{ esito = 'modificheLocali'; file = @('src/x.ps1') }
            copiaAvanti = @{ esito = 'copiaAvanti' }; divergente = @{ esito = 'divergente' }; ramoCanaleDivergente = @{ esito = 'ramoCanaleDivergente' }
            fallitoTornatoIndietro = @{ esito = 'fallitoTornatoIndietro'; errore = 'rotto'; commitScartato = 'abcdef0123456789' }
            errore = @{ esito = 'errore'; errore = 'git non risponde' }
        }
        foreach ($k in $casi.Keys) {
            $m = ConvertTo-ModelloSuite @{ canale = 'main'; installata = @{ hash = 'a' }; ultimoEsito = $casi[$k]; prInArrivo = @() } $true
            $m.Allarme | Should -BeTrue -Because $k
            $m.Esito | Should -Be $k
        }
        (ConvertTo-ModelloSuite @{ canale = 'main'; ultimoEsito = $casi.requisitiMancanti } $true).Stato | Should -Match 'claude.*9.0.*2.1.3'
        (ConvertTo-ModelloSuite @{ canale = 'main'; ultimoEsito = $casi.modificheLocali } $true).Stato | Should -Match 'src/x.ps1'
        (ConvertTo-ModelloSuite @{ canale = 'main'; ultimoEsito = $casi.fallitoTornatoIndietro } $true).Stato | Should -Match 'abcdef0.*rotto'
    }
    It 'l attesa delle sessioni e un allarme solo se dura da oltre la soglia' {
        $e = { param($oltre) @{ canale = 'main'; ultimoEsito = @{ esito = 'inAttesaSessioni'; da = '2026-11-25T08:00:00Z'; oltreSoglia = $oltre } } }
        (ConvertTo-ModelloSuite (& $e $false) $true).Allarme | Should -BeFalse
        (ConvertTo-ModelloSuite (& $e $false) $true).Stato | Should -Match 'in attesa che finiscano le sessioni'
        (ConvertTo-ModelloSuite (& $e $true) $true).Allarme | Should -BeTrue
    }
    It 'un errore nel controllo di origin e un allarme anche se l esito e aggiornato' {
        $m = ConvertTo-ModelloSuite @{ canale = 'main'; erroreControllo = 'git fetch origin e fallito: rete'; ultimoEsito = @{ esito = 'aggiornato' } } $true
        $m.Allarme | Should -BeTrue; $m.ErroreControllo | Should -Match 'rete'
    }
}


Describe 'VistaSuite: gli esiti nuovi della revisione' {
    It 'il ramo del canale divergente: dice che il ramo locale ha commit che origine non ha' {
        $m = ConvertTo-ModelloSuite @{ canale = 'main'; installata = @{ hash = 'a' }; ultimoEsito = @{ esito = 'ramoCanaleDivergente' }; prInArrivo = @() } $true
        $m.Stato | Should -Match 'ramo locale main ha commit che origin/main non ha'
        $m.Allarme | Should -BeTrue
    }
    It 'un errore con la copia lasciata a meta e un allarme che porta il messaggio' {
        $m = ConvertTo-ModelloSuite @{ canale = 'main'; ultimoEsito = @{ esito = 'errore'; errore = 'copia lasciata a abc1234' } } $true
        $m.Allarme | Should -BeTrue; $m.Stato | Should -Match 'copia lasciata a abc1234'
    }
}
