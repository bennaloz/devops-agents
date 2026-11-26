# Get-ModelloUfficio: tutto cio che la pagina dell'ufficio mostra come vero (id di card, code, conteggi, stati). E l'unica parte che
# puo mentire a chi guarda, quindi e quella provata; il movimento di contorno (la pausa, le chiacchiere) non porta dati e non si prova qui.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VistaUfficio.psm1') -Force
    $script:Ruoli = 'responsabile', 'dev', 'collaudatore', 'reviewer', 'mentore'
    $script:Flusso = 'responsabile', 'dev', 'reviewer', 'collaudatore'
    $script:Adesso = [datetime]::Parse('2026-11-24T10:00:00Z', $null, [Globalization.DateTimeStyles]::AdjustToUniversal)
    $script:Dieci = $script:Adesso.AddMinutes(-10).ToString('o')

    function Storia([string]$Ultimo, [string]$Fine = $null) {
        $s = @{ ultimoRuolo = $Ultimo; ultimaSessione = @{} }
        if ($Fine) { $s.ultimaSessione[$Ultimo] = @{ id = 'sid'; fine = $Fine } }
        $s
    }
    # una riga della coda (card che aspetta un ruolo) e una sessione in corso, come le dà Get-ModelloVista
    function Riga([int]$Id, $Ruolo, [string]$Chiave = 'inSviluppo') {
        [pscustomobject]@{ Id = $Id; Ruolo = $Ruolo; Titolo = "Card $Id"; Chiave = $Chiave; UrlCard = "https://ado/$Id" }
    }
    function Viva([int]$Id, [string]$Ruolo, [string]$Chiave = 'inSviluppo') {
        [pscustomobject]@{ Id = $Id; Ruolo = $Ruolo; Titolo = "Card $Id"; Task = 7; TitoloTask = 'Il task'; Minuti = 12; Token = 34500; TokenTesto = '34.5k token'; UrlCard = "https://ado/$Id"; Chiave = $Chiave }
    }
    function Voce([int]$Id, [string]$Verbo = 'Sblocca') {
        [pscustomobject]@{ Id = $Id; Titolo = "Card $Id"; UrlCard = "https://ado/$Id"; Verbo = $Verbo; Testo = 'serve una risposta' }
    }
    function Modello {
        param([object[]]$InCorso = @(), [object[]]$Coda = @(), [object[]]$Agenti = @(), $Operatore = $null, $Stato = @{}, $Quota = $null, $Smistatore = $null, [string]$ErroreAdo = '')
        if ($null -eq $Operatore) { $Operatore = [pscustomobject]@{ Fermano = @(); NonFermano = @() } }
        if ($null -eq $Quota) { $Quota = @{ Blocco = $null; Uso = $null; Soglia = $null } }
        if ($null -eq $Smistatore) { $Smistatore = @{ InGiro = $false; Ultimo = '2026-11-24 10:00:00'; Prossimo = 'tra 3 minuti' } }
        Get-ModelloUfficio -Ruoli $script:Ruoli -Flusso $script:Flusso -InCorso $InCorso -Coda $Coda -Agenti $Agenti -Operatore $Operatore `
            -Stato $Stato -Adesso $script:Adesso -Quota $Quota -Smistatore $Smistatore -ErroreAdo $ErroreAdo -Secondi 5
    }
    function Pers($M, [string]$Ruolo) { @($M.personaggi | Where-Object ruolo -eq $Ruolo)[0] }
}

Describe 'Get-RuoliFlusso' {
    It 'e l ordine del flusso: chi prende la card per primo e chi per ultimo, senza mentore e supervisore' {
        (Get-RuoliFlusso) -join ',' | Should -Be 'responsabile,dev,reviewer,collaudatore'
    }
}

Describe 'Get-ModelloUfficio' {
    It 'e serializzabile in JSON e porta l ora del dato in UTC' {
        $m = Modello
        $m.generata | Should -Be '2026-11-24T10:00:00.0000000Z'
        { $m | ConvertTo-Json -Depth 8 -Compress } | Should -Not -Throw
    }

    It 'un personaggio per ruolo, nell ordine del flusso e poi gli altri ruoli' {
        (Modello).personaggi.ruolo -join ',' | Should -Be 'responsabile,dev,reviewer,collaudatore,mentore'
    }

    It 'chi ha una sessione ha la sessione con id, task, durata, token e link; gli altri hanno sessione nulla' {
        $m = Modello -InCorso @(Viva 5 'dev')
        $s = (Pers $m 'dev').sessione
        $s.id | Should -Be 5
        $s.task | Should -Be 7
        $s.titoloTask | Should -Be 'Il task'
        $s.minuti | Should -Be 12
        $s.tokenUsati | Should -Be 34500
        $s.urlCard | Should -Be 'https://ado/5'
        $s.altre | Should -Be 0
        (Pers $m 'reviewer').sessione | Should -BeNullOrEmpty
    }

    It 'con due sessioni dello stesso ruolo siede sulla card piu piccola e conta le altre' {
        $s = (Pers (Modello -InCorso @((Viva 9 'dev'), (Viva 5 'dev'))) 'dev').sessione
        $s.id | Should -Be 5
        $s.altre | Should -Be 1
    }

    It 'le sessioni oltre la prima di un ruolo sono in altreSessioni, con ruolo, id, titolo, link, task, minuti e token: una persona per sessione' {
        $m = Modello -InCorso @((Viva 9 'dev'), (Viva 5 'dev'), (Viva 12 'dev'), (Viva 7 'collaudatore' 'inCollaudo'), (Viva 3 'collaudatore' 'inCollaudo'))
        (Pers $m 'dev').sessione.id | Should -Be 5
        @($m.altreSessioni).Count | Should -Be 3
        ($m.altreSessioni | ForEach-Object { "$($_.ruolo):$($_.id)" }) -join ',' | Should -Be 'dev:9,dev:12,collaudatore:7'
        $s = $m.altreSessioni[0]
        $s.titolo | Should -Be 'Card 9'
        $s.urlCard | Should -Be 'https://ado/9'
        $s.task | Should -Be 7
        $s.minuti | Should -Be 12
        $s.tokenUsati | Should -Be 34500
    }

    It 'senza sessioni in piu altreSessioni e vuoto' {
        @((Modello -InCorso @(Viva 5 'dev')).altreSessioni).Count | Should -Be 0
    }

    It 'la pila sulla scrivania e la coda vera del ruolo: tante card quante ne ha Agenti, con id e titolo' {
        $agenti = @([pscustomobject]@{ Ruolo = 'reviewer'; Coda = @((Riga 11 'reviewer' 'inRevisione'), (Riga 12 'reviewer' 'inRevisione'), (Riga 13 'reviewer' 'inRevisione')) })
        $m = Modello -Agenti $agenti
        $r = Pers $m 'reviewer'
        $r.codaTotale | Should -Be 3
        @($r.coda).Count | Should -Be 3
        $r.coda[0].id | Should -Be 11
        $r.coda[0].titolo | Should -Be 'Card 11'
        (Pers $m 'dev').codaTotale | Should -Be 0
    }

    It 'una consegna in avanti nel flusso (dev -> reviewer) ha verso avanti' {
        $m = Modello -Coda @(Riga 20 'reviewer' 'inRevisione') -Stato @{ '20' = (Storia 'dev' $script:Dieci) }
        @($m.consegne).Count | Should -Be 1
        $m.consegne[0].id | Should -Be 20
        $m.consegne[0].da | Should -Be 'dev'
        $m.consegne[0].a | Should -Be 'reviewer'
        $m.consegne[0].verso | Should -Be 'avanti'
        $m.consegne[0].urlCard | Should -Be 'https://ado/20'
    }

    It 'un rimando indietro (reviewer -> dev) ha verso indietro' {
        $m = Modello -Coda @(Riga 21 'dev') -Stato @{ '21' = (Storia 'reviewer' $script:Dieci) }
        $m.consegne[0].verso | Should -Be 'indietro'
    }

    It 'un passaggio con un ruolo fuori dal flusso (il mentore) ha verso laterale: la direzione non si inventa' {
        $m = Modello -Coda @(Riga 22 'mentore') -Stato @{ '22' = (Storia 'dev' $script:Dieci) }
        $m.consegne[0].verso | Should -Be 'laterale'
    }

    It 'senza passaggi la lista delle consegne e vuota' {
        @((Modello).consegne).Count | Should -Be 0
    }

    It 'la voce di Da fare tu porta id, titolo, verbo, testo e link; il conteggio e quello vero' {
        $op = [pscustomobject]@{ Fermano = @(Voce 30); NonFermano = @((Voce 31 'Prova in Test'), (Voce 32 'Rilascia')) }
        $m = Modello -Operatore $op
        @($m.daFareTu).Count | Should -Be 3
        $m.daFareTu[0].id | Should -Be 30
        $m.daFareTu[0].verbo | Should -Be 'Sblocca'
        $m.daFareTu[0].ferma | Should -BeTrue
        $m.daFareTu[1].ferma | Should -BeFalse
        $m.daFareTu[0].urlCard | Should -Be 'https://ado/30'
    }

    It 'fa la fila alla porta chi ha lavorato per ultimo una card che aspetta Titolare e non ha una sessione' {
        $op = [pscustomobject]@{ Fermano = @(Voce 30); NonFermano = @() }
        $m = Modello -Operatore $op -Stato @{ '30' = (Storia 'dev') }
        @($m.fila).Count | Should -Be 1
        $m.fila[0].ruolo | Should -Be 'dev'
        $m.fila[0].id | Should -Be 30
    }

    It 'non fa la fila chi ha una sessione in corso, un ruolo fuori elenco o una card senza storia' {
        $op = [pscustomobject]@{ Fermano = @((Voce 30), (Voce 31), (Voce 32)); NonFermano = @() }
        $stato = @{ '30' = (Storia 'dev'); '31' = (Storia 'supervisore') }
        $m = Modello -Operatore $op -Stato $stato -InCorso @(Viva 99 'dev')
        @($m.fila).Count | Should -Be 0
    }

    It 'non fa la fila chi ha lavorato per ultimo una card che aspetta Titolare senza essere ferma (rilascio, prova in Test): non e in attesa' {
        $op = [pscustomobject]@{ Fermano = @(); NonFermano = @((Voce 50 'Rilascia'), (Voce 51 'Prova in Test')) }
        $m = Modello -Operatore $op -Stato @{ '50' = (Storia 'reviewer'); '51' = (Storia 'collaudatore') }
        @($m.fila).Count | Should -Be 0
        @($m.daFareTu).Count | Should -Be 2   # le voci per Titolare restano tutte
    }

    It 'ogni ruolo fa la fila una volta sola, sulla card piu piccola' {
        $op = [pscustomobject]@{ Fermano = @((Voce 41), (Voce 40)); NonFermano = @() }
        $m = Modello -Operatore $op -Stato @{ '40' = (Storia 'dev'); '41' = (Storia 'dev') }
        @($m.fila).Count | Should -Be 1
        $m.fila[0].id | Should -Be 40
    }

    It 'la bacheca conta le card per colonna: sessioni e coda, ognuna una volta' {
        $m = Modello -InCorso @(Viva 1 'dev' 'inSviluppo') -Coda @((Riga 2 'dev' 'inSviluppo'), (Riga 3 'reviewer' 'inRevisione'), (Riga 4 $null 'daRilasciare'))
        ($m.board | Where-Object chiave -eq 'inSviluppo').conteggio | Should -Be 2
        ($m.board | Where-Object chiave -eq 'inRevisione').conteggio | Should -Be 1
        ($m.board | Where-Object chiave -eq 'daRilasciare').conteggio | Should -Be 1
        ($m.board | Where-Object chiave -eq 'pronto').conteggio | Should -Be 0
    }

    It 'ogni colonna della bacheca ha chiave, titolo e una sigla corta' {
        foreach ($c in (Modello).board) {
            $c.chiave | Should -Not -BeNullOrEmpty
            $c.titolo | Should -Not -BeNullOrEmpty
            $c.sigla.Length | Should -BeLessOrEqual 5
        }
    }

    It 'se Azure DevOps non risponde la bacheca non ha numeri (un conteggio parziale sarebbe falso) e l errore e scritto' {
        $m = Modello -InCorso @(Viva 1 'dev') -ErroreAdo 'timeout'
        $m.board | Should -BeNullOrEmpty
        $m.erroreAdo | Should -Be 'timeout'
        @($m.daFareTu).Count | Should -Be 0
    }

    It 'la quota oltre la riserva e riserva, con uso, soglia e fino a quando' {
        $b = @{ Tipo = 'quota'; Causa = 'riserva'; Fino = '2026-11-27T08:00:00.0000000Z'; Uso = 0.91; Soglia = 0.9 }
        $q = (Modello -Quota @{ Blocco = $b; Uso = 0.91; Soglia = 0.9 }).quota
        $q.stato | Should -Be 'riserva'
        $q.uso | Should -Be 0.91
        $q.soglia | Should -Be 0.9
        $q.fino | Should -Be '2026-11-27T08:00:00.0000000Z'
    }

    It 'la pausa per il limite dice di quale finestra (5 ore o settimana) e quanto e usata, dal quota.json letto' {
        $b = @{ Tipo = 'quota'; Causa = 'limite'; Fino = '2026-11-26T02:05:00.0000000Z'; Uso = 0.27 }
        $letta = @{ finestraPausa = 'five_hour'; fiveHour = @{ utilization = 1.0 }; sevenDay = @{ utilization = 0.27 } }
        $q = (Modello -Quota @{ Blocco = $b; Uso = 0.27; Soglia = 0.85; Letta = $letta }).quota
        $q.stato | Should -Be 'limite'
        $q.finestra | Should -Be 'cinqueOre'
        $q.usoFinestra | Should -Be 1.0
        $letta.finestraPausa = 'seven_day'
        $q2 = (Modello -Quota @{ Blocco = $b; Uso = 0.27; Soglia = 0.85; Letta = $letta }).quota
        $q2.finestra | Should -Be 'settimana'
        $q2.usoFinestra | Should -Be 0.27
    }

    It 'la pausa per il limite senza finestra nota non ne inventa una' {
        $b = @{ Tipo = 'quota'; Causa = 'limite'; Fino = '2026-11-26T02:05:00.0000000Z'; Uso = 0.27 }
        $q = (Modello -Quota @{ Blocco = $b; Uso = 0.27; Soglia = 0.85 }).quota
        $q.finestra | Should -BeNullOrEmpty
        $q.usoFinestra | Should -BeNullOrEmpty
    }

    It 'la pausa per il limite di token e limite' {
        $b = @{ Tipo = 'quota'; Causa = 'limite'; Fino = '2026-11-24T12:00:00.0000000Z'; Uso = 0.4 }
        (Modello -Quota @{ Blocco = $b; Uso = 0.4; Soglia = 0.9 }).quota.stato | Should -Be 'limite'
    }

    It 'senza blocco la quota e libera se l uso si conosce, sconosciuta se no' {
        (Modello -Quota @{ Blocco = $null; Uso = 0.3; Soglia = 0.9 }).quota.stato | Should -Be 'libera'
        (Modello -Quota @{ Blocco = $null; Uso = $null; Soglia = 0.9 }).quota.stato | Should -Be 'sconosciuta'
    }

    It 'con la soglia alzata dalla vista la quota e libera anche sopra la soglia di config: si legge la soglia effettiva, non quella del file' {
        $q = (Modello -Quota @{ Blocco = $null; Uso = 0.78; Soglia = 0.95; DaOverride = $true; IgnoraRiserva = $false }).quota
        $q.stato | Should -Be 'libera'
        $q.soglia | Should -Be 0.95
        $q.alzata | Should -BeTrue
        $q.ignorata | Should -BeFalse
    }

    It 'con la riserva ignorata fino al reset lo dice' {
        $q = (Modello -Quota @{ Blocco = $null; Uso = 0.99; Soglia = 0.9; DaOverride = $false; IgnoraRiserva = $true }).quota
        $q.stato | Should -Be 'libera'
        $q.ignorata | Should -BeTrue
    }

    It 'senza override ne ignora la quota non e alzata ne ignorata' {
        $q = (Modello -Quota @{ Blocco = $null; Uso = 0.3; Soglia = 0.9 }).quota
        $q.alzata | Should -BeFalse
        $q.ignorata | Should -BeFalse
    }

    It 'lo smistatore porta se gira, l ultimo e il prossimo giro; se non si sa se gira resta nullo' {
        $m = Modello -Smistatore @{ InGiro = $true; Ultimo = 'adesso'; Prossimo = 'ora' }
        $m.smistatore.inGiro | Should -BeTrue
        $m.smistatore.ultimoGiro | Should -Be 'adesso'
        (Modello -Smistatore @{ InGiro = $null; Ultimo = 'x'; Prossimo = 'y' }).smistatore.inGiro | Should -BeNullOrEmpty
    }
}
