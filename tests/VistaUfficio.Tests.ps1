BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VistaUfficio.psm1') -Force
    $script:Ruoli = 'responsabile', 'dev', 'reviewer', 'collaudatore', 'mentore'
    $script:Adesso = [datetime]::Parse('2026-11-24T10:00:00Z', $null, [Globalization.DateTimeStyles]::AdjustToUniversal)
    # una riga di Get-SessioniVista (sessione seduta su una card) e una riga della coda (card che aspetta un ruolo)
    function Sessione([int]$Id, [string]$Ruolo, [string]$Titolo = "Card $Id", $Task = $null) {
        [pscustomobject]@{ Id = $Id; Ruolo = $Ruolo; Titolo = $Titolo; Task = $Task; TitoloTask = $null }
    }
    function Attesa([int]$Id, [string]$Ruolo, [string]$Titolo = "Card $Id") {
        [pscustomobject]@{ Id = $Id; Ruolo = $Ruolo; Titolo = $Titolo }
    }
    # la storia di una card nello stato: chi ha lavorato per ultimo e, se la sua sessione e finita, quando
    function Storia([string]$Ultimo, [string]$Fine = $null) {
        $s = @{ ultimoRuolo = $Ultimo; ultimaSessione = @{} }
        if ($Fine) { $s.ultimaSessione[$Ultimo] = @{ id = 'sid'; fine = $Fine } }
        $s
    }
    function Esito([object[]]$InCorso = @(), [object[]]$Coda = @(), $Stato = @{}, [int]$Finestra = 60) {
        Get-PostazioniUfficio -Ruoli $script:Ruoli -InCorso $InCorso -Coda $Coda -Stato $Stato -Adesso $script:Adesso -FinestraMinuti $Finestra
    }
    function Personaggio($Esito, [string]$Ruolo) { @($Esito.Personaggi | Where-Object Ruolo -eq $Ruolo)[0] }
    $script:Dieci = $script:Adesso.AddMinutes(-10).ToString('o')
}

Describe 'Get-PostazioniUfficio' {
    It 'senza sessioni ne code ogni personaggio sta alla macchinetta del caffe e non ci sono consegne' {
        $e = Esito
        @($e.Personaggi).Count | Should -Be 5
        foreach ($p in $e.Personaggi) { $p.Posto | Should -Be 'caffe' }
        @($e.Passaggi).Count | Should -Be 0
    }

    It 'chi ha una sessione sta al PC, con l id e il titolo della card e il task' {
        $e = Esito -InCorso @(Sessione 5 'dev' 'Importare le stime' 34)
        $d = Personaggio $e 'dev'
        $d.Posto | Should -Be 'pc'
        $d.Id | Should -Be 5
        $d.Titolo | Should -Be 'Importare le stime'
        $d.Task | Should -Be 34
        $d.Altre | Should -Be 0
        (Personaggio $e 'reviewer').Posto | Should -Be 'caffe'
    }

    It 'con due sessioni dello stesso ruolo siede alla card piu piccola e conta le altre' {
        $e = Esito -InCorso @((Sessione 9 'dev'), (Sessione 5 'dev'))
        $d = Personaggio $e 'dev'
        $d.Id | Should -Be 5
        $d.Altre | Should -Be 1
    }

    It 'un ruolo fuori dall elenco (supervisore) non ha un personaggio e non entra nelle consegne' {
        $e = Esito -InCorso @(Sessione 7 'supervisore') -Coda @(Attesa 7 'dev') -Stato @{ '7' = (Storia 'supervisore' $script:Dieci) }
        @($e.Personaggi).Count | Should -Be 5
        @($e.Passaggi).Count | Should -Be 0
    }

    It 'dev consegna a reviewer: i due si avvicinano e parlano della card, e la consegna compare nell elenco' {
        $e = Esito -Coda @(Attesa 12 'reviewer' 'Esportare il PDF') -Stato @{ '12' = (Storia 'dev' $script:Dieci) }
        $d = Personaggio $e 'dev'; $r = Personaggio $e 'reviewer'
        $d.Posto | Should -Be 'parla'; $d.Con | Should -Be 'reviewer'; $d.Id | Should -Be 12
        $r.Posto | Should -Be 'parla'; $r.Con | Should -Be 'dev'; $r.Id | Should -Be 12
        $r.Fumetto | Should -Be '#12 Esportare il PDF'
        $d.Verso | Should -Be 'da'
        $r.Verso | Should -Be 'a'
        @($e.Passaggi).Count | Should -Be 1
        $e.Passaggi[0].Da | Should -Be 'dev'
        $e.Passaggi[0].A | Should -Be 'reviewer'
        $e.Passaggi[0].Id | Should -Be 12
    }

    It 'reviewer rimanda a dev che ha gia la card in sessione: dev resta al PC e reviewer gli va a parlare' {
        $e = Esito -InCorso @(Sessione 12 'dev') -Stato @{ '12' = (Storia 'reviewer' $script:Dieci) }
        $d = Personaggio $e 'dev'; $r = Personaggio $e 'reviewer'
        $d.Posto | Should -Be 'pc'; $d.Id | Should -Be 12; $d.Con | Should -Be 'reviewer'
        $r.Posto | Should -Be 'parla'; $r.Con | Should -Be 'dev'
    }

    It 'una consegna finita prima della finestra non fa parlare nessuno' {
        $vecchia = $script:Adesso.AddMinutes(-90).ToString('o')
        $e = Esito -Coda @(Attesa 12 'reviewer') -Stato @{ '12' = (Storia 'dev' $vecchia) }
        @($e.Passaggi).Count | Should -Be 0
        (Personaggio $e 'dev').Posto | Should -Be 'caffe'
        (Personaggio $e 'reviewer').Posto | Should -Be 'caffe'
    }

    It 'la finestra si puo allargare' {
        $vecchia = $script:Adesso.AddMinutes(-90).ToString('o')
        $e = Esito -Coda @(Attesa 12 'reviewer') -Stato @{ '12' = (Storia 'dev' $vecchia) } -Finestra 120
        @($e.Passaggi).Count | Should -Be 1
    }

    It 'il ricevente occupato su un altra card non viene portato a parlare' {
        $e = Esito -InCorso @(Sessione 30 'reviewer') -Coda @(Attesa 12 'reviewer') -Stato @{ '12' = (Storia 'dev' $script:Dieci) }
        (Personaggio $e 'reviewer').Posto | Should -Be 'pc'
        (Personaggio $e 'reviewer').Id | Should -Be 30
        (Personaggio $e 'dev').Posto | Should -Be 'caffe'
        @($e.Passaggi).Count | Should -Be 0
    }

    It 'il mittente occupato su un altra card non parla' {
        $e = Esito -InCorso @(Sessione 40 'dev') -Coda @(Attesa 12 'reviewer') -Stato @{ '12' = (Storia 'dev' $script:Dieci) }
        (Personaggio $e 'dev').Posto | Should -Be 'pc'
        (Personaggio $e 'dev').Id | Should -Be 40
        (Personaggio $e 'reviewer').Posto | Should -Be 'caffe'
        @($e.Passaggi).Count | Should -Be 0
    }

    It 'una card senza storia, o con lo stesso ruolo che la lavora, non e una consegna' {
        $e = Esito -InCorso @(Sessione 13 'dev') -Coda @(Attesa 12 'reviewer') -Stato @{ '13' = (Storia 'dev' $script:Dieci) }
        @($e.Passaggi).Count | Should -Be 0
        (Personaggio $e 'dev').Posto | Should -Be 'pc'
    }

    It 'una sessione finita senza data di fine non e una consegna' {
        $e = Esito -Coda @(Attesa 12 'reviewer') -Stato @{ '12' = (Storia 'dev') }
        @($e.Passaggi).Count | Should -Be 0
    }

    It 'una card in coda per un ruolo fuori elenco non e una consegna' {
        $e = Esito -Coda @(Attesa 12 'supervisore') -Stato @{ '12' = (Storia 'dev' $script:Dieci) }
        @($e.Passaggi).Count | Should -Be 0
    }

    It 'due consegne su card diverse, con ruoli diversi, parlano entrambe' {
        $e = Esito -Coda @((Attesa 12 'reviewer'), (Attesa 20 'mentore')) -Stato @{
            '12' = (Storia 'dev' $script:Dieci); '20' = (Storia 'collaudatore' $script:Dieci) }
        @($e.Passaggi).Count | Should -Be 2
        (Personaggio $e 'collaudatore').Con | Should -Be 'mentore'
        (Personaggio $e 'mentore').Con | Should -Be 'collaudatore'
    }

    It 'un ruolo gia impegnato in una consegna non ne apre una seconda: la seconda non parla' {
        $e = Esito -Coda @((Attesa 12 'reviewer'), (Attesa 20 'collaudatore')) -Stato @{
            '12' = (Storia 'dev' $script:Dieci); '20' = (Storia 'dev' $script:Dieci) }
        @($e.Passaggi).Count | Should -Be 1
        $e.Passaggi[0].Id | Should -Be 12
        (Personaggio $e 'collaudatore').Posto | Should -Be 'caffe'
    }
}
