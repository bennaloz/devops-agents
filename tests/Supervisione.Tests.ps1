BeforeAll {
    # D53: Get-Config e Get-ConfigSupervisore leggono impostazioni.json dalla cartella dati: i test non devono vedere quella vera di chi li lancia.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    Import-Module (Join-Path $PSScriptRoot '../src/Supervisione.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot '../src/Telegram.psm1') -Global
    Import-Module (Join-Path $PSScriptRoot '../src/Sessioni.psm1') -Global
    $script:Cfg = Get-ConfigSupervisore
    $script:LimitiVeri = Get-Content (Join-Path $PSScriptRoot '../config/limiti.json') -Raw | ConvertFrom-Json

    # Un'ora locale (i riepiloghi hanno orari locali) come istante UTC. Il 23/11/2026 e un lunedi, il 28 un sabato.
    function New-Ora([int]$Giorno, [int]$Ore, [int]$Minuti = 0) {
        [datetime]::new(2026, 11, $Giorno, $Ore, $Minuti, 0, [DateTimeKind]::Local).ToUniversalTime()
    }
    $script:Adesso = New-Ora 23 10 0

    # Un'osservazione in cui va tutto bene: ogni test cambia solo la sezione che prova.
    function New-Oss {
        $adesso = $script:Adesso
        @{
            Adesso = $adesso; AvvioPc = $adesso.AddHours(-5); UrlBaseCard = 'https://ado/board/_workitems/edit/'; UrlOrganizzazione = 'https://ado'
            UrlVista = 'http://localhost:18799/vista.html'; TagAttesa = 'on-hold'; Limiti = $script:LimitiVeri
            ProgettiMappa = @('Acme.AI'); DefinizioniDeploy = @(115); SenzaPat = $false; VistaMancate = 0
            EsecuzioniPrecedenti = @($adesso.AddMinutes(-7), $adesso.AddMinutes(-2))
            Smistatore = @{ Letto = $true; Errore = $null; Abilitata = $true; Stato = 'Ready'; UltimoGiro = $adesso.AddMinutes(-2); Esito = 0 }
            VistaAttivita = @{ Letto = $true; Errore = $null; Abilitata = $true; Stato = 'Running'; UltimoGiro = $adesso.AddHours(-3); Esito = 267009 }
            VistaRisponde = $true; VistaErrore = $null
            Log = @{ Letto = $true; Errore = $null; Righe = @() }
            Quota = @{ Letto = $true; Errore = $null; Dati = @{} }
            Pat = @{ Letto = $true; Errore = $null; Scadenza = $adesso.AddDays(60) }
            Card = @{ Letto = $true; Errore = $null; Righe = @(); FermaDaOre = @{} }
            Pipeline = @{ Letto = $true; Errore = $null; Attivi = @(); Orchestratori = @(); AgentiPool = @(); AgentiLetti = $true; ErroriAgenti = @(); Falliti = @(); Errori = @(); Motivi = @{}; Ultimi = @{} }
        }
    }
    # una riga di log di N minuti fa, come la scrive lo smistatore (data locale), con il testo di un modello di Comune.psm1
    function New-RigaRecente([double]$MinutiFa, [string]$Livello, [string]$Testo) {
        '{0} {1} {2}' -f $script:Adesso.AddMinutes(-$MinutiFa).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'), $Livello, $Testo
    }
    function New-Sup { Get-StatoSupervisore -Percorso (Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')) }
    function Get-Riga([string]$Ora, [string]$Livello, [string]$Testo) { "2026-11-23 $Ora $Livello $Testo" }
    function New-RigaCard($Id, $Attivita = $null, $Motivo = $null, $Azioni = 0, $Gesto = $null, $Errore = $null, $Stato = 'In review') {
        [pscustomobject]@{ Id = $Id; Titolo = "Titolo $Id"; Stato = $Stato; Azioni = $Azioni; Ruolo = $null; Motivo = $Motivo; Gesto = $Gesto; Attivita = $Attivita
            Domanda = $null; Errore = $Errore; Pr = $null; Url = "https://ado/board/_workitems/edit/$Id"; Firma = 'f' }
    }
    function New-Run($Id, $Tipo = 'ci', $Ramo = 'develop', $Pipeline = 'build-ci', $Progetto = 'Acme.AI', $Def = 20, $Esito = 'failed', $Stato = 'concluso', $Inizio = $null) {
        [pscustomobject]@{ SourceVersion = 'abc123'; ParametriTemplate = $null; Id = $Id; Progetto = $Progetto; Pipeline = $Pipeline; Ramo = $Ramo; Stato = $Stato; Fase = $null; Esito = $Esito; Tipo = $Tipo
            DefinizioneId = $Def; Inizio = $Inizio; Fine = $script:Adesso.AddHours(-1); Url = "https://ado/run/$Id" }
    }
    function Get-PianoNormale($Adesso, $Avvio) {
        $script:S.ultimaEsecuzione = $Adesso.AddMinutes(-5).ToString('o')
        Get-PianoAvvisi -Supervisore $script:S -Adesso $Adesso -Config $script:Cfg -AvvioPc $Avvio
    }
    function Get-Chiavi($Problemi) { @($Problemi | ForEach-Object { $_.Chiave }) }
}

Describe 'Get-ConfigSupervisore' {
    It 'legge config/supervisore.json del repo' {
        $c = Get-ConfigSupervisore
        $c.minutiSenzaGiro | Should -BeGreaterThan 0
        @($c.orariRiepilogo).Count | Should -BeGreaterThan 0
    }
    It 'pipelineRilanciabili: vuoto di default, e una voce senza progetto o definizioneId e un errore' {
        @(Get-Campo $script:Cfg 'pipelineRilanciabili').Count | Should -Be 0
        $r = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory "$r/config" | Out-Null
        $c = Get-Content (Join-Path $PSScriptRoot '../config/supervisore.json') -Raw | ConvertFrom-Json
        $c.pipelineRilanciabili = @([pscustomobject]@{ progetto = 'P' })
        $c | ConvertTo-Json -Depth 5 | Set-Content "$r/config/supervisore.json"
        { Get-ConfigSupervisore -Radice $r } | Should -Throw '*definizioneId*'
        $c.pipelineRilanciabili = @([pscustomobject]@{ progetto = 'P'; definizioneId = 7 })
        $c | ConvertTo-Json -Depth 5 | Set-Content "$r/config/supervisore.json"
        @((Get-ConfigSupervisore -Radice $r).pipelineRilanciabili).Count | Should -Be 1
    }
    It 'rifiuta un valore mancante, un orario sbagliato, un testo che non e un espressione' {
        $r = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory "$r/config" | Out-Null
        $base = Get-Content (Join-Path $PSScriptRoot '../config/supervisore.json') -Raw | ConvertFrom-Json
        $scrivi = { param($o) $o | ConvertTo-Json -Depth 5 | Set-Content "$r/config/supervisore.json" }
        $c = $base | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $c.PSObject.Properties.Remove('minutiSenzaGiro'); & $scrivi $c
        { Get-ConfigSupervisore -Radice $r } | Should -Throw "*'minutiSenzaGiro'*"
        $c = $base | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $c.orariRiepilogo = @('8:30'); & $scrivi $c
        { Get-ConfigSupervisore -Radice $r } | Should -Throw '*HH:mm*'
        $c = $base | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $c.testiInfrastruttura = @('(non chiusa'); & $scrivi $c
        { Get-ConfigSupervisore -Radice $r } | Should -Throw '*espressione*'
        { Get-ConfigSupervisore -Radice (Join-Path $TestDrive 'non-c-e') } | Should -Throw '*mancante*'
    }
}

Describe 'Controllo 1: lo smistatore' {
    It 'tutto bene: nessun problema' {
        @(Get-ProblemiSmistatore (New-Oss) $script:Cfg).Count | Should -Be 0
    }
    It 'fermo da piu di minutiSenzaGiro con il PC acceso da piu di cosi: urgente' {
        $o = New-Oss; $o.Smistatore.UltimoGiro = $script:Adesso.AddMinutes(-($script:Cfg.minutiSenzaGiro + 1))
        $p = @(Get-ProblemiSmistatore $o $script:Cfg)
        $p.Count | Should -Be 1
        $p[0].Chiave | Should -Be 'smistatore-fermo'; $p[0].Urgente | Should -BeTrue; $p[0].DaDiagnosi | Should -BeFalse
        $p[0].Azione | Should -Match 'Utilita di pianificazione'
    }
    It 'il supervisore non girava (PC sospeso o spento): lo smistatore al risveglio non e fermo, nemmeno con il PC acceso da ore' {
        $o = New-Oss; $o.Smistatore.UltimoGiro = $script:Adesso.AddHours(-3)
        $o.EsecuzioniPrecedenti = @($script:Adesso.AddHours(-3))
        @(Get-ProblemiSmistatore $o $script:Cfg).Count | Should -Be 0
        $o.EsecuzioniPrecedenti = @()
        @(Get-ProblemiSmistatore $o $script:Cfg).Count | Should -Be 0
    }
    It 'il supervisore girava ma con un buco piu grande di due intervalli: non e uno smistatore fermo' {
        $piccolo = [pscustomobject]@{ minutiSenzaGiro = 10; intervalloMinuti = 2 }
        $o = New-Oss; $o.Smistatore.UltimoGiro = $script:Adesso.AddHours(-3)
        $o.EsecuzioniPrecedenti = @($script:Adesso.AddMinutes(-9))
        @(Get-ProblemiSmistatore $o $piccolo).Count | Should -Be 0
        $o.EsecuzioniPrecedenti = @($script:Adesso.AddMinutes(-9), $script:Adesso.AddMinutes(-6), $script:Adesso.AddMinutes(-3))
        (Get-Chiavi (Get-ProblemiSmistatore $o $piccolo)) | Should -Contain 'smistatore-fermo'
    }
    It 'Test-SupervisoreContinuo: serve un esecuzione nella finestra e nessun buco oltre due intervalli, l attuale compresa' {
        $a = $script:Adesso
        Test-SupervisoreContinuo @($a.AddMinutes(-7), $a.AddMinutes(-2)) $a $script:Cfg | Should -BeTrue
        Test-SupervisoreContinuo @($a.AddMinutes(-2)) $a $script:Cfg | Should -BeTrue
        Test-SupervisoreContinuo @($a.AddMinutes(-9)) $a $script:Cfg | Should -BeTrue
        Test-SupervisoreContinuo @() $a $script:Cfg | Should -BeFalse
        Test-SupervisoreContinuo $null $a $script:Cfg | Should -BeFalse
        Test-SupervisoreContinuo @($a.AddMinutes(-30)) $a $script:Cfg | Should -BeFalse
        $piccolo = [pscustomobject]@{ minutiSenzaGiro = 10; intervalloMinuti = 2 }
        Test-SupervisoreContinuo @($a.AddMinutes(-9)) $a $piccolo | Should -BeFalse
    }
    It 'appena sotto la soglia: niente' {
        $o = New-Oss; $o.Smistatore.UltimoGiro = $script:Adesso.AddMinutes(-($script:Cfg.minutiSenzaGiro - 1))
        @(Get-ProblemiSmistatore $o $script:Cfg).Count | Should -Be 0
    }
    It 'PC acceso da poco: uno smistatore che non ha girato a PC spento non e un problema' {
        $o = New-Oss; $o.Smistatore.UltimoGiro = $script:Adesso.AddHours(-20); $o.AvvioPc = $script:Adesso.AddMinutes(-3)
        @(Get-ProblemiSmistatore $o $script:Cfg).Count | Should -Be 0
    }
    It 'mai girato e PC acceso da tempo: urgente' {
        $o = New-Oss; $o.Smistatore.UltimoGiro = $null
        (Get-Chiavi (Get-ProblemiSmistatore $o $script:Cfg)) | Should -Contain 'smistatore-fermo'
    }
    It 'disabilitato: una voce del riepilogo, non urgente, e nessun controllo di giro fermo' {
        $o = New-Oss; $o.Smistatore.Abilitata = $false; $o.Smistatore.UltimoGiro = $script:Adesso.AddDays(-2)
        $p = @(Get-ProblemiSmistatore $o $script:Cfg)
        $p.Count | Should -Be 1
        $p[0].Chiave | Should -Be 'smistatore-disabilitato'; $p[0].Urgente | Should -BeFalse
        $p[0].Azione | Should -Match 'riabilitalo da Utilita di pianificazione'
    }
    It 'giro interrotto a ogni giro (righe vere dello smistatore, con codice 0): urgente e da diagnosi' {
        $o = New-Oss
        $o.Log.Righe = @((New-RigaRecente 6 'ERRORE' (Format-RigaLog 'GiroInterrotto' @('rete assente'))), (New-RigaRecente 4 'ERRORE' (Format-RigaLog 'GiroInterrotto' @('rete assente'))), (New-RigaRecente 2 'ERRORE' (Format-RigaLog 'GiroInterrotto' @('rete assente'))))
        $p = @(Get-ProblemiSmistatore $o $script:Cfg)
        $p.Count | Should -Be 1
        $p[0].Chiave | Should -Be 'smistatore-giro-interrotto'; $p[0].Urgente | Should -BeTrue; $p[0].DaDiagnosi | Should -BeTrue
        $p[0].Testo | Should -Match 'rete assente'
    }
    It 'una riga sola, o righe vecchie, o il giro fermato per il PAT (ha il suo problema): niente' {
        $o = New-Oss
        $o.Log.Righe = @((New-RigaRecente 2 'ERRORE' (Format-RigaLog 'GiroInterrotto' @('rete assente'))))
        @(Get-ProblemiSmistatore $o $script:Cfg).Count | Should -Be 0
        $o.Log.Righe = @((New-RigaRecente 40 'ERRORE' (Format-RigaLog 'GiroInterrotto' @('x'))), (New-RigaRecente 30 'ERRORE' (Format-RigaLog 'GiroInterrotto' @('x'))), (New-RigaRecente 20 'ERRORE' (Format-RigaLog 'GiroInterrotto' @('x'))))
        @(Get-ProblemiSmistatore $o $script:Cfg).Count | Should -Be 0
        $o.Log.Righe = @((New-RigaRecente 4 'ERRORE' (Format-RigaLog 'GiroFermato' @((Get-TestoPatScaduto)))), (New-RigaRecente 2 'ERRORE' (Format-RigaLog 'GiroFermato' @((Get-TestoPatScaduto)))))
        @(Get-ProblemiSmistatore $o $script:Cfg).Count | Should -Be 0
    }
    It 'un giro in corso non e un giro fermo, a meno che non duri da piu di silenzioMinuti' {
        $o = New-Oss; $o.Smistatore.Stato = 'Running'
        $o.Smistatore.UltimoGiro = $script:Adesso.AddMinutes(-($script:Cfg.minutiSenzaGiro + 5))
        @(Get-ProblemiSmistatore $o $script:Cfg).Count | Should -Be 0
        $o.Smistatore.UltimoGiro = $script:Adesso.AddMinutes(-($script:LimitiVeri.silenzioMinuti + 5))
        (Get-Chiavi (Get-ProblemiSmistatore $o $script:Cfg)) | Should -Contain 'smistatore-fermo'
    }
    It 'esito diverso da zero: urgente, con le ultime righe ERRORE del log' {
        $o = New-Oss; $o.Smistatore.Esito = 1
        $o.Log.Righe = @((Get-Riga '09:50:00' 'ERRORE' 'giro interrotto: rete assente'), (Get-Riga '09:51:00' 'INFO' 'altro'))
        $p = @(Get-ProblemiSmistatore $o $script:Cfg)
        $p[0].Chiave | Should -Be 'smistatore-errore'; $p[0].Urgente | Should -BeTrue
        $p[0].Testo | Should -Match 'giro interrotto: rete assente'
    }
    It 'in esecuzione (267009) o mai partita (267011) non sono errori' {
        foreach ($codice in 267009, 267011) {
            $o = New-Oss; $o.Smistatore.Esito = $codice
            @(Get-ProblemiSmistatore $o $script:Cfg).Count | Should -Be 0
        }
    }
    It 'attivita che non si legge: un problema che lo dice, non urgente' {
        $o = New-Oss; $o.Smistatore = @{ Letto = $false; Errore = 'non trovata' }
        $p = @(Get-ProblemiSmistatore $o $script:Cfg)
        $p[0].Chiave | Should -Be 'lettura-smistatore'; $p[0].Urgente | Should -BeFalse; $p[0].Testo | Should -Match 'non trovata'
    }
}

Describe 'Controllo 2: errore ripetuto su una card' {
    It 'la stessa card saltata erroriDiFilaPerCard volte di fila: voce da diagnosi (il caso della card 9)' {
        $o = New-Oss
        $o.Log.Righe = @(1..$script:Cfg.erroriDiFilaPerCard | ForEach-Object { Get-Riga "09:0$_`:00" 'ERRORE' "card 9: lettura non riuscita, la salto in questo giro: The property 'result' cannot be found" })
        $p = @(Get-ProblemiErroriCard $o $script:Cfg)
        $p.Count | Should -Be 1
        $p[0].Chiave | Should -Be 'errore-card-9'; $p[0].DaDiagnosi | Should -BeTrue; $p[0].Urgente | Should -BeFalse
        $p[0].Testo | Should -Match "'result' cannot be found"
        $p[0].Link | Should -Be 'https://ado/board/_workitems/edit/9'
    }
    It 'una volta in meno: niente' {
        $o = New-Oss
        $o.Log.Righe = @(1..($script:Cfg.erroriDiFilaPerCard - 1) | ForEach-Object { Get-Riga "09:0$_`:00" 'ERRORE' 'card 9: lettura non riuscita, la salto in questo giro: x' })
        @(Get-ProblemiErroriCard $o $script:Cfg).Count | Should -Be 0
    }
    It 'un altra riga della stessa card in mezzo spezza la serie; le righe di altre card e dell on-hold no' {
        $o = New-Oss
        $r = @(); $n = $script:Cfg.erroriDiFilaPerCard
        foreach ($i in 1..$n) {
            $r += Get-Riga "09:0$i`:00" 'ERRORE' "card 9: l'azione CreaWorktree e fallita: x"
            $r += Get-Riga "09:0$i`:10" 'INFO' 'card 12: lanciata la sessione s'
            $r += Get-Riga "09:0$i`:20" 'INFO' 'card 9: on-hold: L''azione CreaWorktree e fallita (per x)'
        }
        $o.Log.Righe = $r
        (Get-Chiavi (Get-ProblemiErroriCard $o $script:Cfg)) | Should -Contain 'errore-card-9'
        $o.Log.Righe = @($r[0..($r.Count - 4)]) + @(Get-Riga '09:30:00' 'INFO' 'card 9: lanciata la sessione s') + @(Get-Riga '09:31:00' 'ERRORE' 'card 9: lettura non riuscita: x')
        @(Get-ProblemiErroriCard $o $script:Cfg).Count | Should -Be 0
    }
    It 'due card diverse non si sommano' {
        $o = New-Oss
        $o.Log.Righe = @(1..$script:Cfg.erroriDiFilaPerCard | ForEach-Object { Get-Riga "09:0$_`:00" 'ERRORE' "card $(7 + ($_ % 2)): lettura non riuscita: x" })
        @(Get-ProblemiErroriCard $o $script:Cfg).Count | Should -Be 0
    }
    It 'il log che non si legge e un problema, non un errore del controllo' {
        $o = New-Oss; $o.Log = @{ Letto = $false; Errore = 'bloccato'; Righe = @() }
        (Get-ProblemiErroriCard $o $script:Cfg)[0].Chiave | Should -Be 'lettura-log'
    }
}

Describe 'Le righe di log: chi scrive e chi legge usano gli stessi modelli' {
    It 'ogni modello, riempito con dei valori, e riconosciuto dalla sua espressione regolare (e dai valori si risale)' -ForEach @(
        @{ Nome = 'OnHold'; Valori = @('5', 'motivo', 'limite') }, @{ Nome = 'OnHoldFallito'; Valori = @('5', 'boom') },
        @{ Nome = 'LetturaNonRiuscita'; Valori = @('9', "The property 'result' cannot be found") }, @{ Nome = 'AzioneFallita'; Valori = @('5', 'CreaWorktree', 'git rifiutato') },
        @{ Nome = 'GiroInterrotto'; Valori = @('rete assente') }, @{ Nome = 'GiroFermato'; Valori = @('PAT scaduto') }, @{ Nome = 'PatInScadenza'; Valori = @('20/12/2026') }) {
        $testo = Format-RigaLog $Nome $Valori
        $m = [regex]::Match($testo, (Get-RegexRigaLog $Nome))
        $m.Success | Should -BeTrue
        for ($i = 0; $i -lt $Valori.Count; $i++) { $m.Groups[$i + 1].Value | Should -Be $Valori[$i] }
    }
    It 'sono tutti i modelli che esistono: un modello nuovo va provato qui' {
        @(Get-NomiModelliRigaLog | Sort-Object) | Should -Be @('AzioneFallita', 'GiroFermato', 'GiroInterrotto', 'LetturaNonRiuscita', 'OnHold', 'OnHoldFallito', 'PatInScadenza')
    }
    It 'il messaggio del 401 che scrive Ado.psm1 e riconosciuto come PAT rifiutato' {
        (Get-TestoPatScaduto) | Should -Match (Get-RegexPatRifiutato)
        'Response status code does not indicate success: 401 (Unauthorized).' | Should -Match (Get-RegexPatRifiutato)
    }
    It 'un nome di modello che non c e e un errore' {
        { Format-RigaLog 'Inesistente' @('x') } | Should -Throw '*sconosciuto*'
    }
}

Describe 'Controllo 3: la vista' {
    It 'risponde, o ha mancato una volta sola: niente' {
        @(Get-ProblemiVista (New-Oss) (New-Sup) $script:Cfg).Count | Should -Be 0
        $o = New-Oss; $o.VistaRisponde = $false; $o.VistaMancate = 1; $o.VistaErrore = 'timeout'
        @(Get-ProblemiVista $o (New-Sup) $script:Cfg).Count | Should -Be 0
    }
    It 'giu dopo due mancate risposte di fila: una voce del riepilogo, la stessa a ogni riavvio (non si chiude e riapre)' {
        $o = New-Oss; $o.VistaRisponde = $false; $o.VistaMancate = 2; $o.VistaErrore = 'timeout'
        $p = @(Get-ProblemiVista $o (New-Sup) $script:Cfg)
        $p[0].Chiave | Should -Be 'vista-giu'; $p[0].Urgente | Should -BeFalse
        $o.VistaMancate = 7
        (Get-ProblemiVista $o (New-Sup) $script:Cfg)[0].Chiave | Should -Be 'vista-giu'
    }
    It 'con l attivita disabilitata lo dice' {
        $o = New-Oss; $o.VistaRisponde = $false; $o.VistaMancate = 3; $o.VistaAttivita.Abilitata = $false
        (Get-ProblemiVista $o (New-Sup) $script:Cfg)[0].Testo | Should -Match 'disabilitata'
    }
}

Describe 'I gesti' {
    It 'la vista non risponde da due controlli: avvia l attivita (non una volta sola)' {
        $o = New-Oss; $o.VistaRisponde = $false; $o.VistaMancate = 1; $o.VistaAttivita.Stato = 'Ready'
        @(Get-GestiSupervisore $o (New-Sup) $script:Cfg).Count | Should -Be 0
        $o.VistaMancate = 2
        $g = @(Get-GestiSupervisore $o (New-Sup) $script:Cfg)
        $g.Count | Should -Be 1; $g[0].Tipo | Should -Be 'RiavviaVista'; $g[0].Ferma | Should -BeFalse
    }
    It 'se l attivita risulta in esecuzione ma non risponde: la ferma e la riavvia' {
        $o = New-Oss; $o.VistaRisponde = $false; $o.VistaMancate = 2; $o.VistaAttivita.Stato = 'Running'
        (Get-GestiSupervisore $o (New-Sup) $script:Cfg)[0].Ferma | Should -BeTrue
    }
    It 'se l attivita e disabilitata non si tocca' {
        $o = New-Oss; $o.VistaRisponde = $false; $o.VistaMancate = 5; $o.VistaAttivita.Abilitata = $false
        @(Get-GestiSupervisore $o (New-Sup) $script:Cfg).Count | Should -Be 0
    }
    It 'al piu una volta ogni minutiFraRiavviiVista' {
        $o = New-Oss; $o.VistaRisponde = $false; $o.VistaMancate = 4
        $s = New-Sup; $s.gesti.riavviiVista = @($script:Adesso.AddMinutes(-($script:Cfg.minutiFraRiavviiVista - 1)).ToString('o'))
        @(Get-GestiSupervisore $o $s $script:Cfg).Count | Should -Be 0
        $s.gesti.riavviiVista = @($script:Adesso.AddMinutes(-($script:Cfg.minutiFraRiavviiVista + 1)).ToString('o'))
        @((Get-GestiSupervisore $o $s $script:Cfg) | ForEach-Object Tipo) | Should -Be @('RiavviaVista')
    }
    It 'la vista risponde: nessun gesto' {
        @(Get-GestiSupervisore (New-Oss) (New-Sup) $script:Cfg).Count | Should -Be 0
    }
    Context 'il rilancio dei run' {
        BeforeEach {
            $script:CfgRil = [pscustomobject]@{ minutiInCoda = 60; testiInfrastruttura = $script:Cfg.testiInfrastruttura
                pipelineRilanciabili = @([pscustomobject]@{ progetto = 'Acme.AI'; definizioneId = 20 }) }
            $script:O = New-Oss
            $script:O.Pipeline.Falliti = @(New-Run 501)
            $script:O.Pipeline.Motivi = @{ '501' = 'The agent lost communication with the server' }
            $script:O.Pipeline.Ultimi = @{ 'Acme.AI|20|develop' = @{ Id = 501; Stato = 'completed'; Esito = 'failed' } }
        }
        It 'con l elenco vuoto (il default) non rilancia mai: una voce "si potrebbe rilanciare", senza diagnosi' {
            @(Get-GestiSupervisore $script:O (New-Sup) $script:Cfg).Count | Should -Be 0
            $p = @(Get-ProblemiPipeline $script:O (New-Sup) $script:Cfg)
            $p[0].Chiave | Should -Be 'run-fallito-501'; $p[0].DaDiagnosi | Should -BeFalse
            $p[0].Azione | Should -Match 'pipelineRilanciabili'; $p[0].Azione | Should -Match 'si potrebbe rilanciare'
        }
        It 'definizione in elenco, develop, ultimo run, fallito per infrastruttura: rilancia, con sorgente e parametri del run' {
            $g = @(Get-GestiSupervisore $script:O (New-Sup) $script:CfgRil)
            $g.Count | Should -Be 1; $g[0].Tipo | Should -Be 'RilanciaRun'; $g[0].Run.Id | Should -Be 501; $g[0].Run.SourceVersion | Should -Be 'abc123'
            @(Get-ProblemiPipeline $script:O (New-Sup) $script:CfgRil).Count | Should -Be 0
        }
        It 'mai main, nemmeno se la definizione e in elenco' {
            $script:O.Pipeline.Falliti = @(New-Run 501 -Ramo 'main')
            $script:O.Pipeline.Ultimi = @{ 'Acme.AI|20|main' = @{ Id = 501; Stato = 'completed'; Esito = 'failed' } }
            @(Get-GestiSupervisore $script:O (New-Sup) $script:CfgRil).Count | Should -Be 0
            (Get-ProblemiPipeline $script:O (New-Sup) $script:CfgRil)[0].Azione | Should -Match 'a mano'
        }
        It 'una definizione che non e in elenco non si rilancia' {
            $c = [pscustomobject]@{ minutiInCoda = 60; testiInfrastruttura = $script:Cfg.testiInfrastruttura; pipelineRilanciabili = @([pscustomobject]@{ progetto = 'Acme.AI'; definizioneId = 99 }) }
            @(Get-GestiSupervisore $script:O (New-Sup) $c).Count | Should -Be 0
        }
        It 'se non e l ultimo run di quella definizione e ramo non si rilancia; se uno piu recente e riuscito la voce si chiude' {
            $script:O.Pipeline.Ultimi = @{ 'Acme.AI|20|develop' = @{ Id = 505; Stato = 'inProgress'; Esito = '' } }
            @(Get-GestiSupervisore $script:O (New-Sup) $script:CfgRil).Count | Should -Be 0
            $script:O.Pipeline.Ultimi = @{ 'Acme.AI|20|develop' = @{ Id = 505; Stato = 'completed'; Esito = 'succeeded' } }
            @(Get-GestiSupervisore $script:O (New-Sup) $script:CfgRil).Count | Should -Be 0
            @(Get-ProblemiPipeline $script:O (New-Sup) $script:CfgRil).Count | Should -Be 0
            # vale anche per un run fallito per un errore del codice
            $script:O.Pipeline.Motivi = @{ '501' = 'Assert.True() Failure' }
            @(Get-ProblemiPipeline $script:O (New-Sup) $script:CfgRil).Count | Should -Be 0
        }
        It 'senza sapere qual e l ultimo run (lettura fallita) non rilancia' {
            $script:O.Pipeline.Ultimi = @{}
            @(Get-GestiSupervisore $script:O (New-Sup) $script:CfgRil).Count | Should -Be 0
        }
        It 'una volta per run: gia rilanciato, niente gesto e niente voce' {
            $s = New-Sup; $s.gesti.rilanciati['501'] = @{ quando = $script:Adesso.ToString('o'); nuovo = 600 }
            @(Get-GestiSupervisore $script:O $s $script:CfgRil).Count | Should -Be 0
            @(Get-ProblemiPipeline $script:O $s $script:CfgRil).Count | Should -Be 0
        }
        It 'un run che e gia un nostro rilancio e fallisce di nuovo non si rilancia all infinito: diventa una voce' {
            $script:O.Pipeline.Falliti = @(New-Run 600)
            $script:O.Pipeline.Motivi = @{ '600' = 'Timeout expired' }
            $script:O.Pipeline.Ultimi = @{ 'Acme.AI|20|develop' = @{ Id = 600; Stato = 'completed'; Esito = 'failed' } }
            $s = New-Sup; $s.gesti.rilanciati['501'] = @{ quando = $script:Adesso.ToString('o'); nuovo = 600 }
            @(Get-GestiSupervisore $script:O $s $script:CfgRil).Count | Should -Be 0
            $p = @(Get-ProblemiPipeline $script:O $s $script:CfgRil)
            $p[0].Chiave | Should -Be 'run-fallito-600'; $p[0].DaDiagnosi | Should -BeFalse
        }
        It 'un rilancio non riuscito (nuovo nullo) e una voce per run, per un giorno' {
            $s = New-Sup; $s.gesti.rilanciati['501'] = @{ quando = $script:Adesso.AddHours(-1).ToString('o'); nuovo = $null }
            $s.gesti.rilanciati['502'] = @{ quando = $script:Adesso.AddHours(-30).ToString('o'); nuovo = $null }
            $s.gesti.rilanciati['503'] = @{ quando = $script:Adesso.ToString('o'); nuovo = 700 }
            $o = New-Oss
            (Get-Chiavi (Get-ProblemiPipeline $o $s $script:Cfg)) | Should -Be @('rilancio-fallito-501')
        }
        It 'Remove-RilanciatiVecchi toglie i rilanci di piu di tre giorni' {
            $s = New-Sup; $s.gesti.rilanciati['1'] = @{ quando = $script:Adesso.AddDays(-4).ToString('o'); nuovo = 5 }; $s.gesti.rilanciati['2'] = @{ quando = $script:Adesso.AddDays(-1).ToString('o'); nuovo = 6 }
            Remove-RilanciatiVecchi -Supervisore $s -Adesso $script:Adesso
            @($s.gesti.rilanciati.Keys) | Should -Be @('2')
        }
    }
    It 'mai su un deploy, un orchestrator, una validazione di PR o un ramo di una card, nemmeno con la pipeline in elenco' {
        $c = [pscustomobject]@{ minutiInCoda = 60; testiInfrastruttura = $script:Cfg.testiInfrastruttura
            pipelineRilanciabili = @([pscustomobject]@{ progetto = 'Acme.AI'; definizioneId = 20 }, [pscustomobject]@{ progetto = 'Acme.AI'; definizioneId = 115 }) }
        $o = New-Oss
        $o.Pipeline.Falliti = @(
            (New-Run 1 -Tipo 'rilascio' -Pipeline 'deploy-test'), (New-Run 2 -Pipeline 'release-orchestrator'), (New-Run 3 -Def 115),
            (New-Run 4 -Tipo 'pr' -Ramo 'PR #12' -Pipeline 'pr-validation'), (New-Run 5 -Ramo 'feature/9-x'), (New-Run 6 -Ramo 'fix/9-y'),
            (New-Run 7 -Progetto 'Altro.Progetto'), (New-Run 8 -Esito 'canceled'))
        $o.Pipeline.Motivi = @{ '1' = 'LocalDB'; '2' = 'LocalDB'; '3' = 'LocalDB'; '4' = 'LocalDB'; '5' = 'LocalDB'; '6' = 'LocalDB'; '7' = 'LocalDB'; '8' = 'LocalDB' }
        @(Get-GestiSupervisore $o (New-Sup) $c).Count | Should -Be 0
        @(Get-ProblemiPipeline $o (New-Sup) $c).Count | Should -Be 0
    }
    It 'un fallimento che non e infrastruttura non si rilancia: voce da diagnosi' {
        $o = New-Oss; $o.Pipeline.Falliti = @(New-Run 502)
        $o.Pipeline.Motivi = @{ '502' = 'Failed A.Test_due [39 s] Assert.True() Failure' }
        @(Get-GestiSupervisore $o (New-Sup) $script:Cfg).Count | Should -Be 0
        $p = @(Get-ProblemiPipeline $o (New-Sup) $script:Cfg)
        $p[0].Chiave | Should -Be 'run-fallito-502'; $p[0].DaDiagnosi | Should -BeTrue; $p[0].Link | Should -Be 'https://ado/run/502'
    }
    It 'tutti i testi di testiInfrastruttura riconoscono un guasto, anche in maiuscole diverse' {
        Test-FallimentoInfrastruttura 'LOST COMMUNICATION with the server' $script:Cfg | Should -BeTrue
        Test-FallimentoInfrastruttura 'cannot open LocalDB instance' $script:Cfg | Should -BeTrue
        Test-FallimentoInfrastruttura 'Timeout expired. The timeout period elapsed' $script:Cfg | Should -BeTrue
        Test-FallimentoInfrastruttura 'The agent SRV-BUILD-3 was not found' $script:Cfg | Should -BeTrue
        Test-FallimentoInfrastruttura 'Assert.Equal() Failure' $script:Cfg | Should -BeFalse
        Test-FallimentoInfrastruttura '' $script:Cfg | Should -BeFalse
    }
}

Describe 'Controllo 4: le card' {
    It 'una card che aspetta Titolare e una voce del riepilogo con testo, azione e link della card' {
        $o = New-Oss
        $o.Card.Righe = @(
            (New-RigaCard 11 @{ Attivita = 'sblocca'; Ferma = $true; Testo = 'in on-hold, togliendo il tag si rilancia il deploy in Test' }),
            (New-RigaCard 12 @{ Attivita = 'prova'; Ferma = $true; Testo = 'La card aspetta la tua verifica.' }),
            (New-RigaCard 13 @{ Attivita = 'rispondi'; Ferma = $true; Testo = 'responsabile aspetta una tua risposta sulla card' }),
            (New-RigaCard 14 @{ Attivita = 'rilascia'; Ferma = $false; Testo = 'unita in develop: aspetta il rilascio in produzione' }))
        $p = @(Get-ProblemiCard $o $script:Cfg)
        (Get-Chiavi $p) | Should -Be @('card-11-sblocca', 'card-12-prova', 'card-13-rispondi', 'rilasci')
        $p | ForEach-Object { $_.Urgente | Should -BeFalse; $_.DaDiagnosi | Should -BeFalse }
        $p[0].Testo | Should -Match 'Card #11'; $p[0].Testo | Should -Match 'deploy in Test'
        $p[0].Azione | Should -Match 'togli il tag on-hold'
        $p[0].Link | Should -Be 'https://ado/board/_workitems/edit/11'
    }
    It 'un on-hold che lo smistatore sta per togliere da solo non e una voce' {
        $o = New-Oss
        $r = New-RigaCard 15 @{ Attivita = 'sblocca'; Ferma = $true; Testo = 'in on-hold' }; $r | Add-Member TogliAttesa $true
        $o.Card.Righe = @($r, (New-RigaCard 16 @{ Attivita = 'sblocca'; Ferma = $true; Testo = 'in on-hold' }))
        (Get-Chiavi (Get-ProblemiCard $o $script:Cfg)) | Should -Be @('card-16-sblocca')
    }
    It 'D57: on-hold con Cosa fare: il gesto e l azione, le righe il resto, con le card che la aspettano' {
        $o = New-Oss
        $r = New-RigaCard 86 @{ Attivita = 'sblocca'; Ferma = $true; Testo = 'in on-hold' }
        $r | Add-Member Indicazioni @{ Gesto = 'rilancia la validazione del gateway sulla PR 1146'; Fonte = 'agente' }
        $r | Add-Member CosaFare @('1. rilancia la validazione del gateway sulla PR 1146', "2. Togli l'on-hold: x.", 'Perche: y', 'Non riportarla in Draft o in New: z')
        $r | Add-Member Bloccato @{ Ruolo = 'responsabile'; Righe = @('diagnosi lunga') }
        $d = New-RigaCard 74 $null; $d | Add-Member Motivo @{ Tipo = 'predecessori'; Predecessori = @(@{ Id = 86; Stato = 'In development' }) } -Force
        $o.Card.Righe = @($r, $d)
        $p = @(Get-ProblemiCard $o $script:Cfg | Where-Object { $_.Chiave -like 'card-86-*' })
        (Get-Chiavi $p) | Should -Be @('card-86-sblocca')
        $p[0].Testo | Should -Match 'Card #86 .*: in on-hold$'
        $p[0].Azione | Should -Be 'rilancia la validazione del gateway sulla PR 1146'
        $p[0].Righe | Should -Be @("2. Togli l'on-hold: x.", 'Perche: y', 'Non riportarla in Draft o in New: z', 'Tiene ferme anche: #74')
    }
    It 'D57: un bloccato con resoconto e solo il Cosa fare predefinito resta al resoconto' {
        $o = New-Oss
        $r = New-RigaCard 56 @{ Attivita = 'sblocca'; Ferma = $true; Testo = 'in on-hold' }
        $r | Add-Member Indicazioni @{ Gesto = 'generico'; Fonte = 'predefinita' }
        $r | Add-Member CosaFare @('1. generico', '2. x')
        $r | Add-Member Bloccato @{ Ruolo = 'responsabile'; Righe = @('passo 1') }
        $o.Card.Righe = @($r)
        (Get-Chiavi (Get-ProblemiCard $o $script:Cfg)) | Should -Be @('card-56-bloccato')
    }
    It 'on-hold nato da un bloccato con resoconto: voce sua con le righe del resoconto, niente diagnosi, il tag solo dopo' {
        $o = New-Oss
        $r = New-RigaCard 56 @{ Attivita = 'sblocca'; Ferma = $true; Testo = 'in on-hold, togliendo il tag si riprende la sessione' }
        $r | Add-Member Bloccato @{ Ruolo = 'responsabile'; Righe = @('In Test non c e il codice della card.', '1. Accodare release-orchestrator') }
        $o.Card.Righe = @($r)
        $p = @(Get-ProblemiCard $o $script:Cfg)
        (Get-Chiavi $p) | Should -Be @('card-56-bloccato')
        $p[0].DaDiagnosi | Should -BeFalse; $p[0].Urgente | Should -BeFalse
        $p[0].Testo | Should -Match 'Card #56'; $p[0].Testo | Should -Match 'responsabile ha chiuso bloccato'
        $p[0].Testo | Should -Not -Match 'si riprende la sessione'
        $p[0].Azione | Should -Match 'passi del responsabile'; $p[0].Azione | Should -Match 'togli il tag on-hold solo dopo'
        $p[0].Righe | Should -Be @('In Test non c e il codice della card.', '1. Accodare release-orchestrator')
        $p[0].Link | Should -Be 'https://ado/board/_workitems/edit/56'
    }
    It 'on-hold nato da un bloccato senza resoconto: va alla diagnosi del modello' {
        $o = New-Oss
        $r = New-RigaCard 57 @{ Attivita = 'sblocca'; Ferma = $true; Testo = 'in on-hold' }
        $r | Add-Member Bloccato @{ Ruolo = 'collaudatore'; Righe = @() }
        $o.Card.Righe = @($r)
        $p = @(Get-ProblemiCard $o $script:Cfg)
        (Get-Chiavi $p) | Should -Be @('card-57-bloccato-senza-resoconto')
        $p[0].DaDiagnosi | Should -BeTrue; $p[0].Testo | Should -Match 'collaudatore ha chiuso bloccato senza resoconto'
        @($p[0].Righe).Count | Should -Be 0
    }
    It 'un on-hold nato da un bloccato che lo smistatore sta per togliere non e una voce' {
        $o = New-Oss
        $r = New-RigaCard 58 @{ Attivita = 'sblocca'; Ferma = $true; Testo = 'in on-hold' }
        $r | Add-Member Bloccato @{ Ruolo = 'responsabile'; Righe = @('x') }; $r | Add-Member TogliAttesa $true
        $o.Card.Righe = @($r)
        @(Get-ProblemiCard $o $script:Cfg).Count | Should -Be 0
    }
    Context 'Get-ResocontoBloccato' {
        BeforeAll {
            function New-Sessione($Ruolo, $Fine, $Esito, $Testo = 'resoconto') { @{ ruolo = $Ruolo; fine = $Fine; esito = $Esito; testo = $Testo; motivo = 'attesa' } }
        }
        It 'la sessione finita per ultima e del responsabile con esito bloccato: il suo resoconto, ripulito, in righe' {
            $testo = "La card 56 resta **bloccata**.`n`n- **Cosa c'e in Test:** la build della 55.`n1. Accodare ``release-orchestrator`` con ``forceRedeploy`` a ``true``.`n`nESITO=bloccato"
            $sc = @{ ultimoRuolo = 'collaudatore'; ultimaSessione = @{
                    collaudatore = (New-Sessione 'collaudatore' '2026-11-24T16:20:00Z' 'bloccato' 'il collaudatore')
                    responsabile = (New-Sessione 'responsabile' '2026-11-24T16:33:09Z' 'bloccato' $testo)
                    dev = (New-Sessione 'dev' '2026-11-24T13:57:11Z' 'fatto') } }
            $b = Get-ResocontoBloccato $sc
            $b.Ruolo | Should -Be 'responsabile'
            $b.Righe | Should -Be @('La card 56 resta bloccata.', "Cosa c'e in Test: la build della 55.", '1. Accodare release-orchestrator con forceRedeploy a true.')
        }
        It 'vale anche per il collaudatore, e per lo stato letto da JSON' {
            $sc = '{"ultimaSessione":{"collaudatore":{"fine":"2026-11-24T16:40:00Z","esito":"bloccato","testo":"manca urlTest\nESITO=bloccato"},"dev":{"fine":"2026-11-24T10:00:00Z","esito":"fatto","testo":"x"}}}' | ConvertFrom-Json
            $b = Get-ResocontoBloccato $sc
            $b.Ruolo | Should -Be 'collaudatore'; $b.Righe | Should -Be @('manca urlTest')
        }
        It 'al piu Max righe; un resoconto vuoto da righe vuote' {
            $sc = @{ ultimaSessione = @{ responsabile = (New-Sessione 'responsabile' '2026-11-24T16:00:00Z' 'bloccato' "a`nb`nc`nd") } }
            (Get-ResocontoBloccato $sc -Max 2).Righe | Should -Be @('a', 'b')
            $sc.ultimaSessione.responsabile.testo = "`nESITO=bloccato`n"
            $b = Get-ResocontoBloccato $sc
            $b.Ruolo | Should -Be 'responsabile'; @($b.Righe).Count | Should -Be 0
        }
        It 'null se l ultima sessione non e un bloccato del collaudatore o del responsabile' {
            $sc = @{ ultimaSessione = @{
                    responsabile = (New-Sessione 'responsabile' '2026-11-24T10:00:00Z' 'bloccato')
                    dev = (New-Sessione 'dev' '2026-11-24T12:00:00Z' 'bloccato') } }
            Get-ResocontoBloccato $sc | Should -BeNullOrEmpty
            $sc = @{ ultimaSessione = @{ collaudatore = (New-Sessione 'collaudatore' '2026-11-24T12:00:00Z' 'respinto') } }
            Get-ResocontoBloccato $sc | Should -BeNullOrEmpty
            Get-ResocontoBloccato @{ ultimaSessione = $null } | Should -BeNullOrEmpty
            Get-ResocontoBloccato $null | Should -BeNullOrEmpty
        }
        It 'un on-hold messo da Close-Sessione (causaAttesa) non e nato dal bloccato, anche con ESITO=bloccato' {
            $sc = @{ causaAttesa = 'scritture'; ultimaSessione = @{ collaudatore = (New-Sessione 'collaudatore' '2026-11-24T12:00:00Z' 'bloccato') } }
            Get-ResocontoBloccato $sc | Should -BeNullOrEmpty
        }
        It 'una sessione senza fine conta dal suo inizio: un silenzio dopo il bloccato non ripropone il resoconto vecchio' {
            $sc = @{ ultimaSessione = @{
                    responsabile = (New-Sessione 'responsabile' '2026-11-24T10:00:00Z' 'bloccato')
                    collaudatore = @{ ruolo = 'collaudatore'; inizio = '2026-11-24T11:00:00Z'; fine = $null; esito = $null; testo = $null } } }
            Get-ResocontoBloccato $sc | Should -BeNullOrEmpty
        }
        It 'i blocchi recintati spariscono, il markdown di riga e il grassetto pure, il codice in linea resta intero con i suoi asterischi' {
            $testo = "## Causa`n> citata`n+ voce`n``````text`nstack riga 1`nstack riga 2`n```````nFiltro ``**/*.csproj`` e [la build](https://ado/b/1).`nESITO=bloccato"
            $sc = @{ ultimaSessione = @{ responsabile = (New-Sessione 'responsabile' '2026-11-24T16:00:00Z' 'bloccato' $testo) } }
            (Get-ResocontoBloccato $sc).Righe | Should -Be @('Causa', 'citata', 'voce', 'Filtro **/*.csproj e la build (https://ado/b/1).')
        }
        It 'un ultimaSessione vuota letta da JSON non e un errore' {
            Get-ResocontoBloccato ('{"ultimaSessione":{}}' | ConvertFrom-Json) | Should -BeNullOrEmpty
        }
    }
    It 'validazione della PR in corso da piu di validazioneMinuti dalla fine di dev: una voce del riepilogo con il link al log' {
        $o = New-Oss
        $r = New-RigaCard 17; $r.Pr = [pscustomobject]@{ Id = 4; Validazione = 'inCorso'; UrlLog = 'https://log/4' }
        $r | Add-Member ValidazioneFine $script:Adesso.AddMinutes(-($script:LimitiVeri.validazioneMinuti + 5))
        $o.Card.Righe = @($r)
        $p = @(Get-ProblemiCard $o $script:Cfg)
        $p[0].Chiave | Should -Be 'validazione-lunga-17'; $p[0].Urgente | Should -BeFalse; $p[0].Link | Should -Be 'https://log/4'
        $r.ValidazioneFine = $script:Adesso.AddMinutes(-($script:LimitiVeri.validazioneMinuti - 5))
        @(Get-ProblemiCard $o $script:Cfg).Count | Should -Be 0
        $r.ValidazioneFine = $script:Adesso.AddHours(-5); $r.Pr.Validazione = 'verde'
        @(Get-ProblemiCard $o $script:Cfg).Count | Should -Be 0
    }
    It 'senza il PAT dello smistatore non si leggono card ne pipeline: il problema e il PAT, non loro' {
        $o = New-Oss; $o.SenzaPat = $true
        $o.Card = @{ Letto = $false; Errore = 'manca'; Righe = @(); FermaDaOre = @{} }
        @(Get-ProblemiCard $o $script:Cfg).Count | Should -Be 0
        $o.Pipeline.Letto = $false
        @(Get-ProblemiPipeline $o (New-Sup) $script:Cfg).Count | Should -Be 0
        $p = @(Get-ProblemiPat $o $script:Cfg)
        $p[0].Chiave | Should -Be 'pat-mancante'; $p[0].Urgente | Should -BeTrue; $p[0].Azione | Should -Match 'Install-Attrezzi.ps1 -Pat'
    }
    It 'ferma da oreSenzaMovimento senza on-hold, sessione, azioni ne motivo: voce da diagnosi' {
        $o = New-Oss; $o.Card.Righe = @(New-RigaCard 20)
        $o.Card.FermaDaOre = @{ '20' = $script:Cfg.oreSenzaMovimento + 0.5 }
        $p = @(Get-ProblemiCard $o $script:Cfg)
        $p.Count | Should -Be 1
        $p[0].Chiave | Should -Be 'ferma-20'; $p[0].DaDiagnosi | Should -BeTrue
    }
    It 'ferma da meno della soglia: niente' {
        $o = New-Oss; $o.Card.Righe = @(New-RigaCard 20)
        $o.Card.FermaDaOre = @{ '20' = $script:Cfg.oreSenzaMovimento - 0.5 }
        @(Get-ProblemiCard $o $script:Cfg).Count | Should -Be 0
    }
    It 'le card ferme per un motivo noto non sono problemi, nemmeno da molto' -ForEach @(
        @{ Tipo = 'predecessori' }, @{ Tipo = 'limiteRepo' }, @{ Tipo = 'limiteTest' }, @{ Tipo = 'limiteSessioni' }, @{ Tipo = 'quota' }) {
        $o = New-Oss; $o.Card.Righe = @(New-RigaCard 21 -Motivo @{ Tipo = $Tipo })
        $o.Card.FermaDaOre = @{ '21' = 500 }
        @(Get-ProblemiCard $o $script:Cfg).Count | Should -Be 0
    }
    It 'D52: una card In feature branch (AspettaFunzionalita) non e "ferma senza on-hold", nemmeno da molto' {
        $o = New-Oss
        $inFeature = New-RigaCard 25 -Stato 'In feature branch'; $inFeature | Add-Member AspettaFunzionalita $true
        $o.Card.Righe = @($inFeature)
        $o.Card.FermaDaOre = @{ '25' = 500 }
        @(Get-ProblemiCard $o $script:Cfg).Count | Should -Be 0
        # la stessa riga senza il segno e ferma come sempre: la regola non e allentata per le altre
        $isolata = New-RigaCard 27 -Stato 'In feature branch'
        $o.Card.Righe = @($isolata); $o.Card.FermaDaOre = @{ '27' = 500 }
        (Get-Chiavi (Get-ProblemiCard $o $script:Cfg)) | Should -Be @('ferma-27')
    }
    It 'D52: la card di chiusura in Draft e una voce di una persona, una sola anche se la dicono due sorelle, con il gesto e il link della chiusura' {
        $o = New-Oss
        $m = @{ Tipo = 'chiusuraInBozza'; Ruolo = $null; Chiusura = 32; Gesto = 'sposta la card #32 in New' }
        $o.Card.Righe = @((New-RigaCard 30 -Motivo $m -Stato 'In feature branch'), (New-RigaCard 31 -Motivo $m -Stato 'In feature branch'))
        $o.Card.FermaDaOre = @{ '30' = 500; '31' = 500 }
        $p = @(Get-ProblemiCard $o $script:Cfg)
        $p.Count | Should -Be 1
        $p[0].Chiave | Should -Be 'chiusura-32-bozza'
        $p[0].Urgente | Should -BeFalse; $p[0].DaDiagnosi | Should -BeFalse
        $p[0].Testo | Should -Match '#32'
        $p[0].Azione | Should -Be 'sposta la card #32 in New'
        $p[0].Link | Should -Be 'https://ado/board/_workitems/edit/32'
    }
    It 'una card con azioni pronte, un gesto atteso o un errore di lettura non e "ferma senza motivo"' {
        $o = New-Oss
        $o.Card.Righe = @((New-RigaCard 22 -Azioni 1), (New-RigaCard 23 -Gesto @{ Tipo = 'x' }), (New-RigaCard 24 -Errore 'boom'))
        $o.Card.FermaDaOre = @{ '22' = 500; '23' = 500; '24' = 500 }
        @(Get-ProblemiCard $o $script:Cfg).Count | Should -Be 0
    }
    It 'le card che non si leggono sono un problema, non un errore' {
        $o = New-Oss; $o.Card = @{ Letto = $false; Errore = 'rete'; Righe = @(); FermaDaOre = @{} }
        (Get-ProblemiCard $o $script:Cfg)[0].Chiave | Should -Be 'lettura-card'
    }
    It 'Update-FirmeCard: la stessa firma conserva il "dal", una firma cambiata riparte, una card sparita esce' {
        $t0 = $script:Adesso.AddHours(-8)
        $r = [pscustomobject]@{ Id = 30; Firma = 'a' }
        $f1 = Update-FirmeCard $null @($r) $t0
        $f1.FermaDaOre['30'] | Should -Be 0
        $f2 = Update-FirmeCard $f1.Firme @($r) $script:Adesso
        [math]::Round($f2.FermaDaOre['30']) | Should -Be 8
        $f3 = Update-FirmeCard $f2.Firme @([pscustomobject]@{ Id = 30; Firma = 'b' }) $script:Adesso
        $f3.FermaDaOre['30'] | Should -Be 0
        (Update-FirmeCard $f2.Firme @() $script:Adesso).Firme.Count | Should -Be 0
    }
    It 'Get-FirmaCard cambia con stato, ultima sessione, motivo dell attesa e PR' {
        $r = [pscustomobject]@{ Stato = 'In review'; Pr = $null }
        $base = Get-FirmaCard $r @{ ultimaSessione = @{}; inAttesaPer = $null }
        (Get-FirmaCard $r @{ ultimaSessione = @{}; inAttesaPer = $null }) | Should -Be $base
        (Get-FirmaCard ([pscustomobject]@{ Stato = 'Ready'; Pr = $null }) @{ ultimaSessione = @{}; inAttesaPer = $null }) | Should -Not -Be $base
        (Get-FirmaCard $r @{ ultimaSessione = @{ dev = @{ id = 's1' } }; inAttesaPer = $null }) | Should -Not -Be $base
        (Get-FirmaCard $r @{ ultimaSessione = @{}; inAttesaPer = 'limite' }) | Should -Not -Be $base
        (Get-FirmaCard ([pscustomobject]@{ Stato = 'In review'; Pr = [pscustomobject]@{ Id = 4; Validazione = 'rossa' } }) @{ ultimaSessione = @{}; inAttesaPer = $null }) | Should -Not -Be $base
    }
}

Describe 'Controllo 5: le pipeline' {
    It 'gli agenti che non si leggono sono un problema a parte, non un elenco vuoto' {
        $o = New-Oss; $o.Pipeline.AgentiLetti = $false; $o.Pipeline.ErroriAgenti = @('pool degli agenti: 401')
        (Get-ProblemiPipeline $o (New-Sup) $script:Cfg)[0].Chiave | Should -Be 'lettura-agenti'
    }
    It 'un run in attesa di approvazione e urgente, con il link al run' {
        $o = New-Oss
        $o.Pipeline.Attivi = @([pscustomobject]@{ Id = 900; Pipeline = 'deploy'; Ramo = 'develop'; Stato = 'inAttesa'; Fase = 'Test'; Inizio = $script:Adesso.AddMinutes(-5); Url = 'https://ado/run/900' })
        $p = @(Get-ProblemiPipeline $o (New-Sup) $script:Cfg)
        $p[0].Chiave | Should -Be 'approvazione-900'; $p[0].Urgente | Should -BeTrue; $p[0].Link | Should -Be 'https://ado/run/900'
    }
    It 'anche un orchestrator in attesa' {
        $o = New-Oss
        $o.Pipeline.Orchestratori = @([pscustomobject]@{ Id = 901; Pipeline = 'release-orchestrator'; Ramo = 'main'; Stato = 'inAttesa'; Fase = $null; Inizio = $script:Adesso; Url = 'https://ado/run/901' })
        (Get-Chiavi (Get-ProblemiPipeline $o (New-Sup) $script:Cfg)) | Should -Be @('approvazione-901')
    }
    It 'un agente abilitato e offline e urgente; uno disabilitato o online no' {
        $o = New-Oss
        $o.Pipeline.AgentiPool = @([pscustomobject]@{ Pool = 'Interno'; Agenti = @(
            [pscustomobject]@{ Nome = 'a1'; Online = $false; Abilitato = $true; Lavoro = $null },
            [pscustomobject]@{ Nome = 'a2'; Online = $false; Abilitato = $false; Lavoro = $null },
            [pscustomobject]@{ Nome = 'a3'; Online = $true; Abilitato = $true; Lavoro = $null }) })
        $p = @(Get-ProblemiPipeline $o (New-Sup) $script:Cfg)
        $p.Count | Should -Be 1
        $p[0].Chiave | Should -Be 'agente-offline-Interno-a1'; $p[0].Urgente | Should -BeTrue
    }
    It 'un run in coda da piu di minutiInCoda e una voce del riepilogo; sotto soglia no' {
        $o = New-Oss
        $o.Pipeline.Attivi = @(
            [pscustomobject]@{ Id = 910; Pipeline = 'build-ci'; Ramo = 'develop'; Stato = 'inCoda'; Fase = $null; Inizio = $script:Adesso.AddMinutes(-($script:Cfg.minutiInCoda + 5)); Url = 'https://ado/run/910' },
            [pscustomobject]@{ Id = 911; Pipeline = 'build-ci'; Ramo = 'develop'; Stato = 'inCoda'; Fase = $null; Inizio = $script:Adesso.AddMinutes(-($script:Cfg.minutiInCoda - 5)); Url = 'https://ado/run/911' })
        $p = @(Get-ProblemiPipeline $o (New-Sup) $script:Cfg)
        (Get-Chiavi $p) | Should -Be @('coda-910')
        $p[0].Urgente | Should -BeFalse
    }
    It 'la lettura che fallisce e un problema; un progetto che non risponde e un altro' {
        $o = New-Oss; $o.Pipeline = @{ Letto = $false; Errore = 'rete'; Attivi = @(); Orchestratori = @(); AgentiPool = @(); Falliti = @(); Errori = @(); Motivi = @{} }
        (Get-ProblemiPipeline $o (New-Sup) $script:Cfg)[0].Chiave | Should -Be 'lettura-pipeline'
        $o = New-Oss; $o.Pipeline.Errori = @('Acme.AI: 500')
        (Get-ProblemiPipeline $o (New-Sup) $script:Cfg)[0].Chiave | Should -Be 'lettura-pipeline-progetti'
    }
    It 'Select-FallitiDaEsaminare tiene solo i falliti dei progetti della mappa, fuori da PR, rilasci e rami delle card' {
        $f = @((New-Run 1), (New-Run 2 -Tipo 'pr'), (New-Run 3 -Ramo 'feature/x'), (New-Run 4 -Progetto 'Altro'), (New-Run 5 -Def 115), (New-Run 6 -Esito 'canceled'), (New-Run 7 -Ramo 'main'))
        @(Select-FallitiDaEsaminare $f @('Acme.AI') @(115) | ForEach-Object Id) | Should -Be @(1, 7)
    }
}

Describe 'Controllo 6: la quota' {
    It 'nessuna pausa e riserva non raggiunta: niente' {
        $o = New-Oss
        $o.Quota.Dati = @{ sevenDay = @{ utilization = 0.1; resetsAt = $script:Adesso.AddDays(3).ToString('o') } }
        @(Get-ProblemiQuota $o $script:Cfg).Count | Should -Be 0
    }
    It 'pausa in corso: una voce del riepilogo con l ora della ripresa' {
        $o = New-Oss; $o.Quota.Dati = @{ pausaFino = $script:Adesso.AddHours(2).ToString('o') }
        $p = @(Get-ProblemiQuota $o $script:Cfg)
        $p[0].Chiave | Should -Be 'quota-pausa'; $p[0].Urgente | Should -BeFalse; $p[0].Testo | Should -Match 'fermi per il limite di token fino al'
    }
    It 'pausa gia finita: niente' {
        $o = New-Oss; $o.Quota.Dati = @{ pausaFino = $script:Adesso.AddMinutes(-1).ToString('o') }
        @(Get-ProblemiQuota $o $script:Cfg).Count | Should -Be 0
    }
    It 'una pausa lunga (giorni) non e mai urgente: D51 non mette la quota fra gli urgenti' {
        $o = New-Oss; $o.Quota.Dati = @{ pausaFino = $script:Adesso.AddDays(3).ToString('o') }
        (Get-ProblemiQuota $o $script:Cfg)[0].Urgente | Should -BeFalse
    }
    It 'riserva settimanale raggiunta: una voce del riepilogo' {
        $o = New-Oss
        $o.Quota.Dati = @{ sevenDay = @{ utilization = ($script:LimitiVeri.sogliaQuotaSettimanale + 0.05); resetsAt = $script:Adesso.AddDays(2).ToString('o') } }
        $p = @(Get-ProblemiQuota $o $script:Cfg)
        $p[0].Chiave | Should -Be 'quota-riserva'; $p[0].Urgente | Should -BeFalse; $p[0].Testo | Should -Match 'Riserva settimanale raggiunta'
    }
    It 'quota.json che non si legge e un problema' {
        $o = New-Oss; $o.Quota = @{ Letto = $false; Errore = 'bloccato'; Dati = @{} }
        (Get-ProblemiQuota $o $script:Cfg)[0].Chiave | Should -Be 'lettura-quota'
    }
}

Describe 'Controllo 7: il PAT' {
    It 'scadenza lontana, log pulito: niente' {
        @(Get-ProblemiPat (New-Oss) $script:Cfg).Count | Should -Be 0
    }
    It 'scade entro giorniPreavvisoPat: voce con il comando per rinnovarlo' {
        $o = New-Oss; $o.Pat.Scadenza = $script:Adesso.AddDays($script:Cfg.giorniPreavvisoPat - 1)
        $p = @(Get-ProblemiPat $o $script:Cfg)
        $p[0].Chiave | Should -Be 'pat-scadenza'; $p[0].Urgente | Should -BeFalse
        $p[0].Azione | Should -Be 'pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Pat'
        $p[0].Testo | Should -Match 'scade il'
    }
    It 'appena oltre il preavviso: niente; gia scaduto: lo dice' {
        $o = New-Oss; $o.Pat.Scadenza = $script:Adesso.AddDays($script:Cfg.giorniPreavvisoPat + 1)
        @(Get-ProblemiPat $o $script:Cfg).Count | Should -Be 0
        $o.Pat.Scadenza = $script:Adesso.AddDays(-1)
        (Get-ProblemiPat $o $script:Cfg)[0].Testo | Should -Match 'e scaduto il'
    }
    It 'il log recente dice PAT scaduto o revocato: urgente con lo stesso comando' {
        $o = New-Oss
        $o.Log.Righe = @((Get-Riga ($script:Adesso.AddMinutes(-2).ToLocalTime().ToString('HH:mm:ss')) 'ERRORE' 'giro fermato: Chiamata fallita: PAT scaduto o revocato: rilancia setup/Install-Attrezzi.ps1 -Pat'))
        $p = @(Get-ProblemiPat $o $script:Cfg)
        $p[0].Chiave | Should -Be 'pat-rifiutato'; $p[0].Urgente | Should -BeTrue
        $p[0].Azione | Should -Be 'pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Pat'
    }
    It 'un 401 nel log recente conta; la stessa riga di ore fa (PAT gia rinnovato) no' {
        $o = New-Oss
        $o.Log.Righe = @((Get-Riga ($script:Adesso.AddMinutes(-1).ToLocalTime().ToString('HH:mm:ss')) 'ERRORE' 'card 5: lettura non riuscita: Response status code does not indicate success: 401 (Unauthorized).'))
        (Get-Chiavi (Get-ProblemiPat $o $script:Cfg)) | Should -Contain 'pat-rifiutato'
        $o.Log.Righe = @((Get-Riga ($script:Adesso.AddHours(-3).ToLocalTime().ToString('HH:mm:ss')) 'ERRORE' 'giro fermato: PAT scaduto o revocato'))
        @(Get-ProblemiPat $o $script:Cfg).Count | Should -Be 0
    }
    It 'anche una nostra lettura rifiutata (card o pipeline) e un PAT rifiutato' {
        $o = New-Oss; $o.Pipeline.Errore = 'boh'; $o.Card = @{ Letto = $false; Errore = 'x - PAT scaduto o revocato: rilancia'; Righe = @(); FermaDaOre = @{} }
        (Get-Chiavi (Get-ProblemiPat $o $script:Cfg)) | Should -Contain 'pat-rifiutato'
    }
    It 'pat-info.json che non si legge e un problema' {
        $o = New-Oss; $o.Pat = @{ Letto = $false; Errore = 'json rotto'; Scadenza = $null }
        (Get-Chiavi (Get-ProblemiPat $o $script:Cfg)) | Should -Contain 'lettura-pat'
    }
}

Describe 'Get-ProblemiSupervisore' {
    It 'osservazione in ordine: nessun problema' {
        @(Get-ProblemiSupervisore (New-Oss) (New-Sup) $script:Cfg).Count | Should -Be 0
    }
    It 'un controllo che lancia non ferma gli altri: diventa un problema' {
        $o = New-Oss; $o.Quota = $null; $o.Smistatore.Abilitata = $false
        $k = Get-Chiavi (Get-ProblemiSupervisore $o (New-Sup) $script:Cfg)
        $k | Should -Contain 'controllo-quota'
        $k | Should -Contain 'smistatore-disabilitato'
    }
    It 'mette insieme i problemi di tutti i controlli' {
        $o = New-Oss
        $o.Smistatore.UltimoGiro = $script:Adesso.AddHours(-1); $o.Pat.Scadenza = $script:Adesso.AddDays(2); $o.Quota.Dati = @{ pausaFino = $script:Adesso.AddHours(1).ToString('o') }
        (Get-Chiavi (Get-ProblemiSupervisore $o (New-Sup) $script:Cfg)) | Should -Be @('smistatore-fermo', 'quota-pausa', 'pat-scadenza')
    }
}

Describe 'Problemi aperti: apertura, aggiornamento, chiusura' {
    It 'un problema nuovo comincia adesso, senza ultimo avviso' {
        $p = New-Problema 'k' 'testo' 'azione' 'https://l'
        $a = Update-ProblemiAperti @{} @($p) $script:Adesso
        $a['k'].primoVisto | Should -Be $script:Adesso.ToString('o')
        $a['k'].ultimoAvviso | Should -BeNullOrEmpty
        $a['k'].testo | Should -Be 'testo'; $a['k'].urgente | Should -BeFalse
    }
    It 'uno gia aperto conserva primo visto, ultimo avviso e diagnosi, e aggiorna il resto' {
        $prima = @{ k = @{ primoVisto = $script:Adesso.AddHours(-9).ToString('o'); ultimoAvviso = $script:Adesso.AddHours(-2).ToString('o'); diagnosi = 'causa x'; testo = 'vecchio' } }
        $a = Update-ProblemiAperti $prima @(New-Problema 'k' 'nuovo' 'a') $script:Adesso
        (ConvertTo-DataUtc $a['k'].primoVisto) | Should -Be $script:Adesso.AddHours(-9)
        (ConvertTo-DataUtc $a['k'].ultimoAvviso) | Should -Be $script:Adesso.AddHours(-2)
        $a['k'].diagnosi | Should -Be 'causa x'; $a['k'].testo | Should -Be 'nuovo'
    }
    It 'un problema che non si vede si chiude solo dopo due assenze di fila; tornato, l assenza si azzera' {
        $a = Update-ProblemiAperti @{} @(New-Problema 'k' 't' 'a') $script:Adesso
        $a = Update-ProblemiAperti $a @() $script:Adesso.AddMinutes(5)
        $a.ContainsKey('k') | Should -BeTrue; $a['k'].assenze | Should -Be 1
        $a = Update-ProblemiAperti $a @(New-Problema 'k' 't' 'a') $script:Adesso.AddMinutes(10)
        $a['k'].assenze | Should -Be 0
        $a = Update-ProblemiAperti $a @() $script:Adesso.AddMinutes(15)
        $a = Update-ProblemiAperti $a @() $script:Adesso.AddMinutes(20)
        $a.ContainsKey('k') | Should -BeFalse
    }
    It 'un problema in assenza non si dice: ne urgenti ne riepilogo' {
        $s = New-Sup; $s.ultimaEsecuzione = $script:Adesso.AddMinutes(-5).ToString('o')
        $a = Update-ProblemiAperti @{} @(New-Problema 'u' 't' 'a' -Urgente $true) $script:Adesso.AddHours(-1)
        $s.problemi = Update-ProblemiAperti $a @() $script:Adesso
        @((Get-PianoAvvisi -Supervisore $s -Adesso $script:Adesso -Config $script:Cfg).Urgenti).Count | Should -Be 0
    }
    It 'una sezione che non si e letta non chiude i suoi problemi e non li aggiorna' {
        $a = Update-ProblemiAperti @{} @((New-Problema 'approvazione-9' 't' 'a' -Urgente $true), (New-Problema 'agente-offline-P-a1' 't' 'a'), (New-Problema 'pat-scadenza' 't' 'a')) $script:Adesso
        foreach ($i in 1..4) { $a = Update-ProblemiAperti $a @() $script:Adesso.AddMinutes(5 * $i) -SezioniNonLette @('pipeline', 'agenti') }
        $a.ContainsKey('approvazione-9') | Should -BeTrue; $a['approvazione-9'].assenze | Should -Be 0
        $a.ContainsKey('agente-offline-P-a1') | Should -BeTrue
        $a.ContainsKey('pat-scadenza') | Should -BeFalse
    }
    It 'Get-SezioniNonLette: card, pipeline (anche con un progetto che non risponde) e agenti' {
        $o = New-Oss
        @(Get-SezioniNonLette $o).Count | Should -Be 0
        $o.Card.Letto = $false; (Get-SezioniNonLette $o) | Should -Contain 'card'
        $o = New-Oss; $o.Pipeline.Errori = @('P: 500'); (Get-SezioniNonLette $o) | Should -Contain 'pipeline'
        $o = New-Oss; $o.Pipeline.AgentiLetti = $false; $s = @(Get-SezioniNonLette $o); $s | Should -Contain 'agenti'; $s | Should -Not -Contain 'pipeline'
    }
    It 'Get-SezioneDelProblema assegna le chiavi alla sezione che le genera' {
        Get-SezioneDelProblema 'card-9-sblocca' | Should -Be 'card'
        Get-SezioneDelProblema 'run-fallito-3' | Should -Be 'pipeline'
        Get-SezioneDelProblema 'agente-offline-P-a' | Should -Be 'agenti'
        Get-SezioneDelProblema 'vista-giu' | Should -BeNullOrEmpty
    }
    It 'un problema sparito per due giri si chiude, senza messaggi (sparisce e basta)' {
        $prima = @{ k = @{ primoVisto = $script:Adesso.ToString('o'); ultimoAvviso = $null; testo = 't' }; h = @{ primoVisto = $script:Adesso.ToString('o'); ultimoAvviso = $null; testo = 't' } }
        $a = Update-ProblemiAperti $prima @(New-Problema 'h' 't' 'a') $script:Adesso
        $a.ContainsKey('k') | Should -BeTrue
        $a = Update-ProblemiAperti $a @(New-Problema 'h' 't' 'a') $script:Adesso
        @($a.Keys) | Should -Be @('h')
        $s = New-Sup; $s.problemi = $a
        (Get-PianoAvvisi -Supervisore $s -Adesso $script:Adesso -Config $script:Cfg).Urgenti.Count | Should -Be 0
    }
}

Describe 'Avvisi urgenti: subito, poi ogni oreRicordoUrgente' {
    BeforeEach {
        $script:S = New-Sup
        $script:S.ultimaEsecuzione = $script:Adesso.AddMinutes(-5).ToString('o')
        $script:S.problemi = Update-ProblemiAperti @{} @(New-Problema 'u1' 'Smistatore fermo' 'riavvialo' 'https://l' -Urgente $true) $script:Adesso.AddHours(-10)
    }
    It 'appena compare: un messaggio; una volta mandato non si ripete al giro dopo' {
        $p = Get-PianoAvvisi -Supervisore $script:S -Adesso $script:Adesso -Config $script:Cfg
        @($p.Urgenti).Count | Should -Be 1
        $p.Urgenti[0].Ricordo | Should -BeFalse
        Register-AvvisiMandati -Supervisore $script:S -Chiavi @('u1') -Adesso $script:Adesso
        $script:S.problemi = Update-ProblemiAperti $script:S.problemi @(New-Problema 'u1' 'Smistatore fermo' 'riavvialo' 'https://l' -Urgente $true) $script:Adesso.AddMinutes(5)
        @((Get-PianoAvvisi -Supervisore $script:S -Adesso $script:Adesso.AddMinutes(5) -Config $script:Cfg).Urgenti).Count | Should -Be 0
    }
    It 'ancora aperto dopo oreRicordoUrgente: si ricorda, dicendo da quanto' {
        Register-AvvisiMandati -Supervisore $script:S -Chiavi @('u1') -Adesso $script:Adesso
        $dopo = $script:Adesso.AddHours($script:Cfg.oreRicordoUrgente - 0.1)
        @((Get-PianoAvvisi -Supervisore $script:S -Adesso $dopo -Config $script:Cfg).Urgenti).Count | Should -Be 0
        $dopo = $script:Adesso.AddHours($script:Cfg.oreRicordoUrgente + 0.1)
        $u = @((Get-PianoAvvisi -Supervisore $script:S -Adesso $dopo -Config $script:Cfg).Urgenti)
        $u.Count | Should -Be 1
        $u[0].Ricordo | Should -BeTrue
        $u[0].Attesa | Should -Match '^da \d+ ore$'
    }
    It 'gli urgenti non finiscono nel riepilogo' {
        $p = Get-PianoAvvisi -Supervisore $script:S -Adesso (New-Ora 23 9 0) -Config $script:Cfg
        @($p.Riepilogo).Count | Should -Be 0
    }
}

Describe 'Il riepilogo: orari, feriali, voci nuove e ricordi' {
    BeforeEach {
        $script:S = New-Sup
        $script:S.ultimaEsecuzione = (New-Ora 23 7 0).ToString('o')   # ultima esecuzione dopo l'avvio del PC
        $script:Avvio = (New-Ora 23 6 0)
        $script:Voce = New-Problema 'r1' 'Card #1 ferma' 'guardala' 'https://l/1'
    }
    It 'prima dell orario: niente' {
        $script:S.problemi = Update-ProblemiAperti @{} @($script:Voce) (New-Ora 23 8 0)
        $p = Get-PianoNormale (New-Ora 23 8 29) $script:Avvio
        $p.MandaRiepilogo | Should -BeFalse
        $p.InSospeso | Should -Be 1
    }
    It 'alla prima esecuzione dopo le 8:30 di un feriale: parte, una volta sola per quella fascia' {
        $script:S.problemi = Update-ProblemiAperti @{} @($script:Voce) (New-Ora 23 8 0)
        $adesso = New-Ora 23 8 35
        $p = Get-PianoNormale $adesso $script:Avvio
        $p.MandaRiepilogo | Should -BeTrue
        @($p.Riepilogo).Count | Should -Be 1
        $p.Fasce | Should -Be @('2026-11-23 08:30')
        Register-AvvisiMandati -Supervisore $script:S -Chiavi @('r1') -Fasce $p.Fasce -Adesso $adesso
        $p2 = Get-PianoNormale (New-Ora 23 9 0) $script:Avvio
        $p2.MandaRiepilogo | Should -BeFalse
        # alle 14:00 un altra fascia, ma la voce e gia stata detta oggi: non c'e niente da ricordare
        $p3 = Get-PianoNormale (New-Ora 23 14 5) $script:Avvio
        $p3.Fasce | Should -Be @('2026-11-23 14:00')
        $p3.MandaRiepilogo | Should -BeFalse
    }
    It 'una voce gia segnalata ieri si ricorda una volta al giorno, con da quanto tempo aspetta' {
        $script:S.problemi = Update-ProblemiAperti @{} @($script:Voce) (New-Ora 20 8 0)
        Register-AvvisiMandati -Supervisore $script:S -Chiavi @('r1') -Adesso (New-Ora 20 9 0)
        $script:S.problemi = Update-ProblemiAperti $script:S.problemi @($script:Voce) (New-Ora 23 8 0)
        $p = Get-PianoNormale (New-Ora 23 8 35) $script:Avvio
        $p.MandaRiepilogo | Should -BeTrue
        $p.Riepilogo[0].Ricordo | Should -BeTrue
        $p.Riepilogo[0].Attesa | Should -Be 'da 3 giorni'
    }
    It 'riepilogo vuoto: non parte, ma la fascia si consuma (una voce che arriva alle 9 aspetta le 14)' {
        $adesso = New-Ora 23 8 35
        $p = Get-PianoNormale $adesso $script:Avvio
        $p.MandaRiepilogo | Should -BeFalse
        $p.Fasce | Should -Be @('2026-11-23 08:30')
        Register-AvvisiMandati -Supervisore $script:S -Chiavi @() -Fasce $p.Fasce -Adesso $adesso
        $script:S.problemi = Update-ProblemiAperti @{} @($script:Voce) (New-Ora 23 9 0)
        (Get-PianoNormale (New-Ora 23 9 5) $script:Avvio).MandaRiepilogo | Should -BeFalse
        (Get-PianoNormale (New-Ora 23 14 5) $script:Avvio).MandaRiepilogo | Should -BeTrue
    }
    It 'dopo le 14:00 con tutte e due le fasce arretrate: un messaggio solo, e le fasce si consumano tutte e due' {
        $script:S.problemi = Update-ProblemiAperti @{} @($script:Voce) (New-Ora 23 8 0)
        $p = Get-PianoNormale (New-Ora 23 15 0) $script:Avvio
        $p.MandaRiepilogo | Should -BeTrue
        @($p.Riepilogo).Count | Should -Be 1
        $p.Fasce | Should -Be @('2026-11-23 08:30', '2026-11-23 14:00')
    }
    It 'sabato e domenica: nessuna fascia, nessun riepilogo' {
        foreach ($g in 28, 29) {
            $script:S.problemi = Update-ProblemiAperti @{} @($script:Voce) (New-Ora $g 7 0)
            $p = Get-PianoNormale (New-Ora $g 15 0) (New-Ora $g 6 0)
            $p.MandaRiepilogo | Should -BeFalse
            @($p.Fasce).Count | Should -Be 0
        }
    }
    It 'PC appena acceso (ultima esecuzione prima dell avvio): il riepilogo parte subito, anche fuori orario e nel weekend' {
        $script:S.problemi = Update-ProblemiAperti @{} @($script:Voce) (New-Ora 28 7 0)
        $script:S.ultimaEsecuzione = (New-Ora 27 17 0).ToString('o')
        $p = Get-PianoAvvisi -Supervisore $script:S -Adesso (New-Ora 28 7 30) -Config $script:Cfg -AvvioPc (New-Ora 28 7 25)
        $p.PcAppenaAcceso | Should -BeTrue
        $p.MandaRiepilogo | Should -BeTrue
        @($p.Fasce).Count | Should -Be 0
    }
    It 'PC appena acceso: solo le voci non ancora avvisate oggi (nuove o da ricordare), non quelle gia dette oggi' {
        $script:S.problemi = Update-ProblemiAperti @{} @($script:Voce) (New-Ora 23 8 0)
        Register-AvvisiMandati -Supervisore $script:S -Chiavi @('r1') -Adesso (New-Ora 23 8 30)
        $script:S.ultimaEsecuzione = (New-Ora 22 18 0).ToString('o')
        $p = Get-PianoAvvisi -Supervisore $script:S -Adesso (New-Ora 23 9 0) -Config $script:Cfg -AvvioPc (New-Ora 23 8 55)
        @($p.Riepilogo).Count | Should -Be 0
        $p.MandaRiepilogo | Should -BeFalse
    }
    It 'PC appena acceso con niente in sospeso: nessun messaggio' {
        $script:S.ultimaEsecuzione = (New-Ora 22 18 0).ToString('o')
        (Get-PianoAvvisi -Supervisore $script:S -Adesso (New-Ora 28 9 0) -Config $script:Cfg -AvvioPc (New-Ora 28 8 55)).MandaRiepilogo | Should -BeFalse
    }
    It 'PC acceso da prima dell ultima esecuzione: non e appena acceso' {
        $script:S.ultimaEsecuzione = (New-Ora 28 8 55).ToString('o')
        $p = Get-PianoAvvisi -Supervisore $script:S -Adesso (New-Ora 28 9 0) -Config $script:Cfg -AvvioPc (New-Ora 28 3 0)
        $p.PcAppenaAcceso | Should -BeFalse
    }
    It 'prima esecuzione in assoluto (nessuna ultima esecuzione) dopo un avvio noto: conta come appena acceso' {
        $script:S.ultimaEsecuzione = $null
        (Get-PianoAvvisi -Supervisore $script:S -Adesso (New-Ora 23 7 0) -Config $script:Cfg -AvvioPc (New-Ora 23 6 0)).PcAppenaAcceso | Should -BeTrue
    }
    It 'Register-AvvisiMandati segna le voci e tiene solo le ultime fasce' {
        $script:S.problemi = Update-ProblemiAperti @{} @($script:Voce) (New-Ora 23 8 0)
        Register-AvvisiMandati -Supervisore $script:S -Chiavi @('r1') -Fasce @(1..30 | ForEach-Object { "f$_" }) -Adesso (New-Ora 23 9 0)
        (ConvertTo-DataUtc $script:S.problemi['r1'].ultimoAvviso) | Should -Be (New-Ora 23 9 0)
        @($script:S.riepiloghi).Count | Should -Be 20
        $script:S.riepiloghi[-1] | Should -Be 'f30'
    }
}

Describe 'supervisore.json' {
    It 'un file che manca e uno stato vuoto con i campi attesi' {
        $s = Get-StatoSupervisore -Percorso (Join-Path $TestDrive 'non-c-e.json')
        $s.problemi.Count | Should -Be 0
        @($s.gesti.riavviiVista).Count | Should -Be 0
        $s.gesti.rilanciati.Count | Should -Be 0
        $s.ultimaEsecuzione | Should -BeNullOrEmpty
    }
    It 'si salva e si rilegge uguale, con le date che restano date' {
        $f = Join-Path $TestDrive 'sup.json'
        $s = Get-StatoSupervisore -Percorso $f
        $s.problemi = Update-ProblemiAperti @{} @(New-Problema 'k' 'testo' 'azione' 'https://l' -Urgente $true -DaDiagnosi $true) $script:Adesso
        $s.gesti.riavviiVista = @($script:Adesso.ToString('o'))
        $s.gesti.rilanciati['501'] = @{ quando = $script:Adesso.ToString('o'); nuovo = 600 }
        $s.ultimaEsecuzione = $script:Adesso.ToString('o')
        Save-StatoSupervisore -Stato $s -Percorso $f
        $r = Get-StatoSupervisore -Percorso $f
        $r.problemi['k'].urgente | Should -BeTrue
        $r.problemi['k'].daDiagnosi | Should -BeTrue
        $r.problemi['k'].diagnosi | Should -Be ''
        (ConvertTo-DataUtc $r.problemi['k'].primoVisto) | Should -Be $script:Adesso
        $r.gesti.rilanciati['501'].nuovo | Should -Be 600
        (ConvertTo-DataUtc $r.ultimaEsecuzione) | Should -Be $script:Adesso
    }
    It 'un file vecchio senza alcuni campi si completa' {
        $f = Join-Path $TestDrive 'vecchio.json'
        '{ "problemi": {} }' | Set-Content $f
        $s = Get-StatoSupervisore -Percorso $f
        $s.Contains('firme') | Should -BeTrue
        $s.Contains('riepiloghi') | Should -BeTrue
        $s.gesti.Contains('rilanciati') | Should -BeTrue
    }
}

Describe 'src/Supervisore.ps1' {
    It 'si legge senza errori di sintassi' {
        $errori = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../src/Supervisore.ps1'), [ref]$null, [ref]$errori)
        @($errori).Count | Should -Be 0
    }
}

Describe 'PC appena acceso dopo una sospensione' {
    BeforeEach {
        $script:S = New-Sup
        $script:S.problemi = Update-ProblemiAperti @{} @(New-Problema 'r1' 'Card #1 ferma' 'guardala' 'https://l/1') (New-Ora 23 8 0)
    }
    It 'l ultima esecuzione piu vecchia di tre intervalli: il riepilogo parte, anche se l avvio del PC e di giorni fa' {
        $adesso = New-Ora 28 12 0
        $script:S.ultimaEsecuzione = $adesso.AddMinutes(-(3 * $script:Cfg.intervalloMinuti + 1)).ToString('o')
        $p = Get-PianoAvvisi -Supervisore $script:S -Adesso $adesso -Config $script:Cfg -AvvioPc (New-Ora 25 8 0)
        $p.PcAppenaAcceso | Should -BeTrue
        $p.MandaRiepilogo | Should -BeTrue
    }
    It 'fino a tre intervalli e un giro normale: niente' {
        $adesso = New-Ora 28 12 0
        $script:S.ultimaEsecuzione = $adesso.AddMinutes(-(3 * $script:Cfg.intervalloMinuti - 1)).ToString('o')
        (Get-PianoAvvisi -Supervisore $script:S -Adesso $adesso -Config $script:Cfg -AvvioPc (New-Ora 25 8 0)).PcAppenaAcceso | Should -BeFalse
    }
}

Describe 'La diagnosi con il modello: quando si lancia' {
    BeforeEach {
        $script:S = New-Sup
        $script:S.problemi = Update-ProblemiAperti @{} @(
            (New-Problema 'errore-card-9' 'Card 9 saltata' 'guarda' 'https://l/9' -DaDiagnosi $true),
            (New-Problema 'ferma-20' 'Card 20 ferma' 'guarda' 'https://l/20' -DaDiagnosi $true),
            (New-Problema 'card-1-sblocca' 'Card 1 on-hold' 'sblocca' 'https://l/1')) $script:Adesso
    }
    It 'sceglie un problema da diagnosi senza diagnosi, uno solo, nell ordine delle chiavi' {
        Get-DiagnosiDaLanciare -Supervisore $script:S -Adesso $script:Adesso -Config $script:Cfg | Should -Be 'errore-card-9'
    }
    It 'mai per un problema che non e da diagnosi' {
        $s = New-Sup; $s.problemi = Update-ProblemiAperti @{} @(New-Problema 'k' 't' 'a') $script:Adesso
        Get-DiagnosiDaLanciare -Supervisore $s -Adesso $script:Adesso -Config $script:Cfg | Should -BeNullOrEmpty
    }
    It 'una volta sola per problema: con la diagnosi gia scritta (anche non riuscita) passa al successivo' {
        $script:S.problemi['errore-card-9']['diagnosi'] = 'diagnosi non riuscita'
        Get-DiagnosiDaLanciare -Supervisore $script:S -Adesso $script:Adesso -Config $script:Cfg | Should -Be 'ferma-20'
        $script:S.problemi['ferma-20']['diagnosi'] = 'causa x'
        Get-DiagnosiDaLanciare -Supervisore $script:S -Adesso $script:Adesso -Config $script:Cfg | Should -BeNullOrEmpty
    }
    It 'al piu una sessione di diagnosi in corso per volta' {
        Register-DiagnosiLanciata -Supervisore $script:S -Chiave 'errore-card-9' -Sessione ([pscustomobject]@{ Id = 's1'; Pid = 1; Avvio = 'x'; Cartella = 'c' }) -Adesso $script:Adesso
        Get-DiagnosiDaLanciare -Supervisore $script:S -Adesso $script:Adesso -Config $script:Cfg | Should -BeNullOrEmpty
        $script:S.sessioniDiagnosi.Count | Should -Be 1
        $script:S.sessioniDiagnosi[0].chiave | Should -Be 'errore-card-9'
    }
    It 'mai con le sessioni dello smistatore gia al limite' {
        Get-DiagnosiDaLanciare -Supervisore $script:S -Adesso $script:Adesso -Config $script:Cfg -SessioniAttive 3 -LimiteSessioni 3 | Should -BeNullOrEmpty
        Get-DiagnosiDaLanciare -Supervisore $script:S -Adesso $script:Adesso -Config $script:Cfg -SessioniAttive 2 -LimiteSessioni 3 | Should -Be 'errore-card-9'
    }
    It 'mai con la quota che blocca' {
        Get-DiagnosiDaLanciare -Supervisore $script:S -Adesso $script:Adesso -Config $script:Cfg -QuotaBloccata $true | Should -BeNullOrEmpty
    }
    It 'al piu diagnosiAlGiorno al giorno, il contatore riparte il giorno dopo' {
        $cfg = [pscustomobject]@{ diagnosiAlGiorno = 2 }
        foreach ($i in 1, 2) {
            Get-DiagnosiDaLanciare -Supervisore $script:S -Adesso $script:Adesso -Config $cfg | Should -Not -BeNullOrEmpty
            Register-DiagnosiLanciata -Supervisore $script:S -Chiave "k$i" -Sessione ([pscustomobject]@{ Id = "s$i"; Pid = 1; Avvio = 'x'; Cartella = 'c' }) -Adesso $script:Adesso
            $script:S.sessioniDiagnosi = @()
        }
        $script:S.diagnosiGiorno.n | Should -Be 2
        Get-DiagnosiDaLanciare -Supervisore $script:S -Adesso $script:Adesso.AddHours(1) -Config $cfg | Should -BeNullOrEmpty
        Get-DiagnosiDaLanciare -Supervisore $script:S -Adesso $script:Adesso.AddDays(1) -Config $cfg | Should -Not -BeNullOrEmpty
        Register-DiagnosiLanciata -Supervisore $script:S -Chiave 'k3' -Sessione ([pscustomobject]@{ Id = 's3'; Pid = 1; Avvio = 'x'; Cartella = 'c' }) -Adesso $script:Adesso.AddDays(1)
        $script:S.diagnosiGiorno.n | Should -Be 1
    }
    It 'il tetto del giorno sta in supervisore.json: si salva e si rilegge' {
        $f = Join-Path $TestDrive 'diag.json'
        Register-DiagnosiLanciata -Supervisore $script:S -Chiave 'errore-card-9' -Sessione ([pscustomobject]@{ Id = 's1'; Pid = 7; Avvio = '2026-11-23T09:00:00Z'; Cartella = 'c' }) -Adesso $script:Adesso
        Save-StatoSupervisore -Stato $script:S -Percorso $f
        $r = Get-StatoSupervisore -Percorso $f
        $r.diagnosiGiorno.n | Should -Be 1
        $r.sessioniDiagnosi[0].id | Should -Be 's1'
        $r.sessioniDiagnosi[0].pid | Should -Be 7
    }
}

Describe 'La diagnosi con il modello: l esito' {
    BeforeAll {
        function New-EsitoDiag($Finita = $true, $Esito = 'diagnosi', $Testo = 'Causa: x. Prova: f riga 1. Azione: y.', $Errore = $false, $Ultimo = $null) {
            [pscustomobject]@{ Finita = $Finita; Errore = $Errore; Esito = $Esito; Testo = $Testo; UltimoEvento = $Ultimo }
        }
        # la fase come la calcola lo smistatore (Get-FaseSessione), con il processo vivo o no
        function Get-FaseDiag($Esito, [bool]$Viva) {
            $cfg = [pscustomobject]@{ Limiti = [pscustomobject]@{ silenzioMinuti = 45 } }
            $sess = @{ pid = 1; avvio = 'x'; inizio = $script:Adesso.AddMinutes(-10).ToString('o') }
            Get-FaseSessione $cfg $sess $Esito ({ param($p, $a) $Viva }.GetNewClosure()) $script:Adesso
        }
        function Get-Esito($Esito, [bool]$Viva = $false) { ConvertTo-EsitoDiagnosi -Fase (Get-FaseDiag $Esito $Viva) -Esito $Esito }
    }
    It 'finita con ESITO=diagnosi: il testo senza la riga ESITO' {
        $r = Get-Esito (New-EsitoDiag -Testo "Causa: la proprieta result manca.`nAzione: correggi Smistatore.ps1.`nESITO=diagnosi")
        $r.Stato | Should -Be 'finita'
        $r.Testo | Should -Match 'proprieta result manca'
        $r.Testo | Should -Not -Match 'ESITO'
    }
    It 'il testo passa dalle regole di Telegram: niente codice recintato ne tag, tagliato' {
        $r = Get-Esito (New-EsitoDiag -Testo ("Causa <b>x</b>:`n" + '```' + "`nSecret-Code`n" + '```' + "`n" + ('y' * 2000) + "`nESITO=diagnosi"))
        $r.Testo | Should -Not -Match 'Secret-Code'
        $r.Testo | Should -Not -Match '<b>'
        $r.Testo.Length | Should -BeLessOrEqual 600
    }
    It 'finita senza ESITO=diagnosi, con un altro esito o con errore: diagnosi non riuscita' {
        foreach ($e in (New-EsitoDiag -Esito $null), (New-EsitoDiag -Esito 'altro'), (New-EsitoDiag -Errore $true)) {
            $r = Get-Esito $e
            $r.Stato | Should -Be 'fallita'; $r.Testo | Should -Be 'diagnosi non riuscita'
        }
    }
    It 'esito con ESITO=diagnosi ma testo vuoto: non riuscita' {
        (Get-Esito (New-EsitoDiag -Testo 'ESITO=diagnosi')).Stato | Should -Be 'fallita'
    }
    It 'processo sparito senza risultato: non riuscita' {
        (Get-Esito (New-EsitoDiag -Finita $false)).Stato | Should -Be 'fallita'
        (Get-Esito $null).Stato | Should -Be 'fallita'
    }
    It 'viva e con eventi recenti: si aspetta' {
        (Get-Esito (New-EsitoDiag -Finita $false -Esito $null -Testo $null -Ultimo $script:Adesso.AddMinutes(-3)) $true).Stato | Should -Be 'inCorso'
        (Get-Esito $null $true).Stato | Should -Be 'inCorso'
    }
    It 'viva ma in silenzio oltre silenzioMinuti: non riuscita, e la fase dice che e viva (va fermata)' {
        $e = New-EsitoDiag -Finita $false -Esito $null -Testo $null -Ultimo $script:Adesso.AddMinutes(-46)
        $f = Get-FaseDiag $e $true
        $f.Fase | Should -Be 'senzaRisultato'; $f.Causa | Should -Be 'silenzio'; $f.Viva | Should -BeTrue
        (ConvertTo-EsitoDiagnosi -Fase $f -Esito $e).Testo | Should -Be 'diagnosi non riuscita'
    }
    It 'un result senza riga ESITO con il processo ancora vivo e una pausa, non la fine' {
        (Get-Esito (New-EsitoDiag -Esito $null -Ultimo $script:Adesso.AddMinutes(-1)) $true).Stato | Should -Be 'inCorso'
    }
}

Describe 'La diagnosi con il modello: nel problema e nel riepilogo' {
    BeforeEach {
        $script:S = New-Sup
        $script:S.ultimaEsecuzione = (New-Ora 23 8 30).ToString('o')
        $script:S.problemi = Update-ProblemiAperti @{} @(New-Problema 'errore-card-9' 'Card 9 saltata' 'guarda' 'https://l/9' -DaDiagnosi $true) (New-Ora 23 8 0)
        Register-DiagnosiLanciata -Supervisore $script:S -Chiave 'errore-card-9' -Sessione ([pscustomobject]@{ Id = 's1'; Pid = 1; Avvio = 'x'; Cartella = 'c' }) -Adesso (New-Ora 23 8 10)
        $script:Sess = $script:S.sessioniDiagnosi[0]
    }
    It 'la diagnosi va nel problema, la sessione esce dall elenco' {
        Complete-Diagnosi -Supervisore $script:S -Sessione $script:Sess -Testo 'Causa: x' | Should -BeTrue
        $script:S.problemi['errore-card-9'].diagnosi | Should -Be 'Causa: x'
        @($script:S.sessioniDiagnosi).Count | Should -Be 0
    }
    It 'il problema chiuso prima della fine: il risultato si scarta, la sessione esce dall elenco' {
        $script:S.problemi = Update-ProblemiAperti $script:S.problemi @() (New-Ora 23 8 20)
        $script:S.problemi = Update-ProblemiAperti $script:S.problemi @() (New-Ora 23 8 25)
        Complete-Diagnosi -Supervisore $script:S -Sessione $script:Sess -Testo 'Causa: x' | Should -BeFalse
        $script:S.problemi.Count | Should -Be 0
        @($script:S.sessioniDiagnosi).Count | Should -Be 0
        # e se lo stesso problema si riapre e un altro, senza la diagnosi vecchia
        $script:S.problemi = Update-ProblemiAperti $script:S.problemi @(New-Problema 'errore-card-9' 't' 'a' -DaDiagnosi $true) (New-Ora 23 9 0)
        $script:S.problemi['errore-card-9'].diagnosi | Should -Be ''
    }
    It 'un problema che resta aperto conserva la diagnosi quando si aggiorna' {
        [void](Complete-Diagnosi -Supervisore $script:S -Sessione $script:Sess -Testo 'Causa: x')
        $script:S.problemi = Update-ProblemiAperti $script:S.problemi @(New-Problema 'errore-card-9' 'Card 9 saltata di nuovo' 'guarda' 'https://l/9' -DaDiagnosi $true) (New-Ora 23 8 40)
        $script:S.problemi['errore-card-9'].diagnosi | Should -Be 'Causa: x'
    }
    It 'la diagnosi sta sotto la voce del riepilogo, e arriva alla prossima fascia anche se la voce era gia stata detta' {
        Register-AvvisiMandati -Supervisore $script:S -Chiavi @('errore-card-9') -Adesso (New-Ora 23 8 35)
        [void](Complete-Diagnosi -Supervisore $script:S -Sessione $script:Sess -Testo 'Causa: x. Azione: y.')
        $p = Get-PianoNormale (New-Ora 23 14 5) (New-Ora 23 6 0)
        $p.MandaRiepilogo | Should -BeTrue
        $p.Riepilogo[0].Diagnosi | Should -Be 'Causa: x. Azione: y.'
        $t = Format-RiepilogoTelegram -Voci $p.Riepilogo -Adesso (New-Ora 23 14 5)
        # il testo della diagnosi ha il suo messaggio nel topic Diagnosi: qui solo il rimando
        $t | Should -Match "(?m)^1\. Card 9 saltata.*\n→ .*\ndiagnosi nel topic Diagnosi$"
        $t | Should -Not -Match 'Causa: x'
    }
    It 'la diagnosi si ricorda una volta al giorno come le altre voci' {
        [void](Complete-Diagnosi -Supervisore $script:S -Sessione $script:Sess -Testo 'Causa: x')
        Register-AvvisiMandati -Supervisore $script:S -Chiavi @('errore-card-9') -Adesso (New-Ora 23 8 35)
        (Get-PianoNormale (New-Ora 23 14 5) (New-Ora 23 6 0)).MandaRiepilogo | Should -BeFalse
        (Get-PianoNormale (New-Ora 24 8 35) (New-Ora 24 6 0)).Riepilogo[0].Diagnosi | Should -Be 'Causa: x'
    }
}

Describe 'Esecuzioni del supervisore e quota delle sessioni' {
    It 'Add-EsecuzioneSupervisore tiene solo l ultima ora' {
        $s = New-Sup
        foreach ($m in 90, 70, 30, 10) { $s.esecuzioni = @($s.esecuzioni) + $script:Adesso.AddMinutes(-$m).ToString('o') }
        Add-EsecuzioneSupervisore -Supervisore $s -Adesso $script:Adesso
        @($s.esecuzioni).Count | Should -Be 3
        (ConvertTo-DataUtc $s.esecuzioni[-1]) | Should -Be $script:Adesso
    }
    It 'Update-QuotaDaEsito: una sessione finita sul limite scrive la pausa nella quota (la quota e una sola)' {
        $f = Join-Path $TestDrive 'quota.json'
        $reset = $script:Adesso.AddHours(3)
        $esito = [pscustomobject]@{ Quota = @{ five_hour = @{ Utilization = 1.0; ResetsAt = $reset } }; Limite = @{ Finestra = 'five_hour'; Reset = $reset } }
        Update-QuotaDaEsito -Esito $esito -Adesso $script:Adesso -Limite $esito.Limite -Margine 5 -Percorso $f
        $q = Get-Quota -Percorso $f
        (ConvertTo-DataUtc $q.pausaFino) | Should -Be $reset.AddMinutes(5)
        $q.finestraPausa | Should -Be 'five_hour'
        # e il cancello dello smistatore la vede
        $o = New-Oss; $o.Quota.Dati = $q
        (Get-ProblemiQuota $o $script:Cfg)[0].Chiave | Should -Be 'quota-pausa'
    }
}

Describe 'La diagnosi con il modello: sola lettura, conservazione, eventi' {
    It 'Compare-ImprontaDiagnosi: git sempre; stato.json e quota.json solo se nessun giro dello smistatore e passato in mezzo' {
        $p = @{ stato = 'a'; quota = 'b'; testa = 'h1'; gitStato = '' }
        @(Compare-ImprontaDiagnosi $p $p $false).Count | Should -Be 0
        (Compare-ImprontaDiagnosi $p @{ stato = 'x'; quota = 'b'; testa = 'h1'; gitStato = '' } $false) | Should -Be @('stato.json')
        (Compare-ImprontaDiagnosi $p @{ stato = 'a'; quota = 'y'; testa = 'h1'; gitStato = '' } $false) | Should -Be @('quota.json')
        @(Compare-ImprontaDiagnosi $p @{ stato = 'x'; quota = 'y'; testa = 'h1'; gitStato = '' } $true).Count | Should -Be 0
        @(Compare-ImprontaDiagnosi $p @{ stato = 'a'; quota = 'b'; testa = 'h2'; gitStato = '' } $true).Count | Should -Be 1
        @(Compare-ImprontaDiagnosi $p @{ stato = 'a'; quota = 'b'; testa = 'h1'; gitStato = ' M src/x.ps1' } $true).Count | Should -Be 1
        @(Compare-ImprontaDiagnosi $null $p $false).Count | Should -Be 0
    }
    It 'una diagnosi si conserva 24 ore dopo la chiusura del problema: se riappare non se ne lancia un altra' {
        $s = New-Sup
        $s.problemi = Update-ProblemiAperti @{} @(New-Problema 'errore-card-9' 't' 'a' -DaDiagnosi $true) $script:Adesso.AddHours(-3)
        $s.problemi['errore-card-9']['diagnosi'] = 'Causa: x'
        $prima = $s.problemi
        $s.problemi = @{}
        Sync-DiagnosiConservate -Supervisore $s -Prima $prima -Adesso $script:Adesso
        $s.diagnosiConservate.ContainsKey('errore-card-9') | Should -BeTrue
        # il giorno dopo (meno di 24 ore): riappare e riprende la diagnosi
        $s.problemi = Update-ProblemiAperti @{} @(New-Problema 'errore-card-9' 't' 'a' -DaDiagnosi $true) $script:Adesso.AddHours(10)
        Sync-DiagnosiConservate -Supervisore $s -Prima @{} -Adesso $script:Adesso.AddHours(10)
        $s.problemi['errore-card-9'].diagnosi | Should -Be 'Causa: x'
        Get-DiagnosiDaLanciare -Supervisore $s -Adesso $script:Adesso.AddHours(10) -Config $script:Cfg | Should -BeNullOrEmpty
        # dopo 24 ore si butta
        $s.problemi = @{}
        Sync-DiagnosiConservate -Supervisore $s -Prima @{} -Adesso $script:Adesso.AddHours(30)
        $s.diagnosiConservate.Count | Should -Be 0
    }
    It 'un evento entra subito fra i problemi aperti e resta fra quelli di ogni giro per 24 ore' {
        $s = New-Sup
        Add-EventoSupervisore -Supervisore $s -Problema (New-Problema 'diagnosi-ha-scritto-s1' 'La diagnosi ha scritto: stato.json.' 'guarda' '' -Urgente $true) -Adesso $script:Adesso
        $s.problemi['diagnosi-ha-scritto-s1'].urgente | Should -BeTrue
        (Get-Chiavi (Get-ProblemiEventi -Supervisore $s -Adesso $script:Adesso.AddHours(5))) | Should -Be @('diagnosi-ha-scritto-s1')
        @(Get-ProblemiEventi -Supervisore $s -Adesso $script:Adesso.AddHours(25)).Count | Should -Be 0
        @($s.eventi).Count | Should -Be 0
    }
}

Describe 'I rilasci in attesa: una voce sola per area (D51)' {
    BeforeAll {
        function New-RigaRilascio($Id, [string]$Area, $GiorniFa = 1) {
            $r = New-RigaCard $Id @{ Attivita = 'rilascia'; Ferma = $false; Testo = 'unita in develop' }
            $r | Add-Member Area $Area
            $r | Add-Member InStatoDa $(if ($null -ne $GiorniFa) { $script:Adesso.AddDays(-$GiorniFa) } else { $null }) -Force
            $r
        }
        $script:AreaA = 'DevOps.Agents\AI\Stime'; $script:AreaB = 'DevOps.Agents\Workflow\Forms'
        function Get-Rilasci($Righe, $Config = $script:Cfg) { $o = New-Oss; $o.Card.Righe = @($Righe); @(Get-ProblemiCard $o $Config) }
    }
    It 'le card da rilasciare non sono una voce ciascuna: una voce rilasci, non urgente, con una riga per area' {
        $p = @(Get-Rilasci @((New-RigaRilascio 1 $script:AreaA 2), (New-RigaRilascio 2 $script:AreaA 3), (New-RigaRilascio 3 $script:AreaB 1)))
        $p.Count | Should -Be 1
        $p[0].Chiave | Should -Be 'rilasci'; $p[0].Urgente | Should -BeFalse; $p[0].DaDiagnosi | Should -BeFalse
        $p[0].Testo | Should -Match 'Rilasci in attesa: 3 card in 2 aree'
        @($p[0].Righe).Count | Should -Be 2
        ($p[0].Righe -join "`n") | Should -Match 'Stime: 2 card \(#1, #2\), la piu vecchia aspetta da 3 giorni'
        ($p[0].Righe -join "`n") | Should -Match 'Forms: 1 card \(#3\), la piu vecchia aspetta da 1 giorno'
        @($p[0].Elementi | Sort-Object) | Should -Be @('1', '2', '3')
    }
    It 'D52: una funzionalita e una voce sola, con il numero delle sue card, accanto alle card isolate della stessa area' {
        $righe = @(1..4 | ForEach-Object { New-RigaRilascio (20 + $_) $script:AreaA 2 }) + @(New-RigaRilascio 5 $script:AreaA 1)
        foreach ($r in $righe[0..3]) { $r | Add-Member Funzionalita ([pscustomobject]@{ Feature = 7; Titolo = 'Esportare in PDF' }); $r | Add-Member UrlFeature 'https://ado/board/_workitems/edit/7' }
        $p = @(Get-Rilasci $righe)
        $p.Count | Should -Be 1
        # il testo conta le card vere (4 + 1) e dice le voci
        $p[0].Testo | Should -Match 'Rilasci in attesa: 5 card in 1 area \(2 voci\)'
        $p[0].Righe[0] | Should -Match 'Stime: 2 card \(#5, funzionalita #7 \(4 card\)\), la piu vecchia aspetta da 2 giorni'
        @($p[0].Elementi | Sort-Object) | Should -Be @('5', 'f7')
        $g = @($p[0].Gruppi)[0]
        @($g.Card).Count | Should -Be 2
        ($g.Card | Where-Object Id -eq 7).Titolo | Should -Match 'Esportare in PDF \(4 card\)'
        # il link di una funzionalita e quello della Feature, non quello di una sua card
        ($g.Card | Where-Object Id -eq 7).Url | Should -Be 'https://ado/board/_workitems/edit/7'
        ($g.Card | Where-Object Id -eq 5).Url | Should -Be 'https://ado/board/_workitems/edit/5'
    }
    It 'D52: senza il link della Feature la voce di una funzionalita non ripiega sul link di una card' {
        $righe = @(1..2 | ForEach-Object { New-RigaRilascio $_ $script:AreaA 1 })
        foreach ($r in $righe) { $r | Add-Member Funzionalita ([pscustomobject]@{ Feature = 7; Titolo = 'F' }) }
        $g = @((@(Get-Rilasci $righe))[0].Gruppi)[0]
        ($g.Card | Where-Object Id -eq 7).Url | Should -BeNullOrEmpty
    }
    It 'D52: le card di una funzionalita contano una volta sola per la soglia di area' {
        $righe = @(1..5 | ForEach-Object { New-RigaRilascio $_ $script:AreaA 1 })
        foreach ($r in $righe) { $r | Add-Member Funzionalita ([pscustomobject]@{ Feature = 7; Titolo = 'Esportare in PDF' }) }
        $p = @(Get-Rilasci $righe)
        $p[0].Righe[0] | Should -Not -Match 'OLTRE SOGLIA'
        $p[0].Testo | Should -Match 'Rilasci in attesa: 5 card in 1 area \(1 voce\)'
        $p[0].Righe[0] | Should -Match 'Stime: 1 card \(funzionalita #7 \(5 card\)\)'
        $p[0].Ricorda | Should -BeFalse
    }
    It 'altre attivita restano voci a se' {
        $o = New-Oss; $o.Card.Righe = @((New-RigaCard 11 @{ Attivita = 'sblocca'; Ferma = $true; Testo = 'in on-hold' }))
        (Get-Chiavi (Get-ProblemiCard $o $script:Cfg)) | Should -Be @('card-11-sblocca')
    }
    It 'soglia predefinita: troppe card oppure troppo vecchia, con il motivo; sotto soglia nessun segno' {
        $poche = @(Get-Rilasci @((New-RigaRilascio 1 $script:AreaA 1), (New-RigaRilascio 2 $script:AreaA 2)))
        $poche[0].Righe[0] | Should -Not -Match 'OLTRE SOGLIA'
        $tante = @(Get-Rilasci @(1..5 | ForEach-Object { New-RigaRilascio $_ $script:AreaA 1 }))
        $tante[0].Righe[0] | Should -Match '^OLTRE SOGLIA - .*5 card \(soglia 5\)$'
        $vecchia = @(Get-Rilasci @((New-RigaRilascio 1 $script:AreaA 7)))
        $vecchia[0].Righe[0] | Should -Match 'OLTRE SOGLIA .* 7 giorni \(soglia 7\)'
        $vecchia[0].Urgente | Should -BeFalse
        $vecchia[0].Testo | Should -Match '1 oltre soglia'
        $vecchia[0].Ricorda | Should -BeTrue
        $poche[0].Ricorda | Should -BeFalse
    }
    It 'soglia per area: rende oltre soglia un area sola, le altre restano sulla predefinita' {
        $cfg = [pscustomobject]@{ minutiInCoda = 60; oreSenzaMovimento = 6
            rilasci = [pscustomobject]@{ predefinito = [pscustomobject]@{ card = 5; giorni = 7 }
                perArea = [pscustomobject]@{ $script:AreaB = [pscustomobject]@{ card = 1; giorni = 2 } } } }
        $p = @(Get-Rilasci @((New-RigaRilascio 1 $script:AreaA 1), (New-RigaRilascio 2 $script:AreaB 1)) $cfg)
        $p[0].Righe[0] | Should -Match 'OLTRE SOGLIA - .*Forms: 1 card'
        $p[0].Righe[0] | Should -Match 'soglia 1'
        $p[0].Righe[1] | Should -Not -Match 'OLTRE SOGLIA'
    }
    It 'le aree oltre soglia vanno in cima, poi per numero di card' {
        $p = @(Get-Rilasci @((New-RigaRilascio 1 $script:AreaA 1), (New-RigaRilascio 2 $script:AreaA 1), (New-RigaRilascio 3 $script:AreaA 1), (New-RigaRilascio 4 $script:AreaB 9), (New-RigaRilascio 5 'Zeta' 1)))
        $p[0].Righe[0] | Should -Match 'OLTRE SOGLIA - .*Forms'
        $p[0].Righe[1] | Should -Match 'Stime: 3 card'
        $p[0].Righe[2] | Should -Match '^Zeta: 1 card'
    }
    It 'Set-RilasciDa: senza l ingresso nella storia vale il primo visto del supervisore, che si ricorda' {
        $s = New-Sup
        $r = New-RigaRilascio 1 $script:AreaA $null
        Set-RilasciDa -Supervisore $s -Righe @($r) -Adesso $script:Adesso.AddDays(-4)
        $r.InStatoDa | Should -Be $script:Adesso.AddDays(-4)
        $r2 = New-RigaRilascio 1 $script:AreaA $null
        Set-RilasciDa -Supervisore $s -Righe @($r2) -Adesso $script:Adesso
        [math]::Round(($script:Adesso - $r2.InStatoDa).TotalDays) | Should -Be 4
        # una card che non e piu in attesa esce dai visti
        Set-RilasciDa -Supervisore $s -Righe @() -Adesso $script:Adesso
        $s.rilasciVisti.Count | Should -Be 0
        # con l ingresso dalla storia non lo si cambia
        $r3 = New-RigaRilascio 2 $script:AreaA 10
        Set-RilasciDa -Supervisore $s -Righe @($r3) -Adesso $script:Adesso
        [math]::Round(($script:Adesso - $r3.InStatoDa).TotalDays) | Should -Be 10
    }
    Context 'quando la voce compare nel riepilogo' {
        BeforeAll {
            function Set-VoceRilasci($Sup, [string[]]$Card, [bool]$Oltre, [datetime]$Quando) {
                $p = New-Problema 'rilasci' 'Rilasci in attesa' 'rilascia' '' -Righe @('riga') -Elementi $Card -Ricorda $Oltre
                $Sup.problemi = Update-ProblemiAperti $Sup.problemi @($p) $Quando
            }
        }
        BeforeEach {
            $script:S = New-Sup
            $script:Ora = New-Ora 23 8 35
            $script:Avvio = New-Ora 23 6 0
        }
        It 'la prima volta compare, con le righe' {
            Set-VoceRilasci $script:S @('1', '2') $false (New-Ora 23 8 0)
            $p = Get-PianoNormale $script:Ora $script:Avvio
            $p.MandaRiepilogo | Should -BeTrue
            @($p.Riepilogo[0].Righe).Count | Should -Be 1
            (Format-RiepilogoTelegram -Voci $p.Riepilogo -Adesso (New-Ora 23 8 35)) | Should -Match '(?m)^   - riga$'
        }
        It 'senza aree oltre soglia non si ricorda ogni giorno' {
            Set-VoceRilasci $script:S @('1', '2') $false (New-Ora 20 8 0)
            Register-AvvisiMandati -Supervisore $script:S -Chiavi @('rilasci') -Adesso (New-Ora 20 9 0)
            Set-VoceRilasci $script:S @('1', '2') $false (New-Ora 23 8 0)
            (Get-PianoNormale $script:Ora $script:Avvio).MandaRiepilogo | Should -BeFalse
        }
        It 'con un area oltre soglia si ricorda una volta al giorno' {
            Set-VoceRilasci $script:S @('1', '2') $true (New-Ora 20 8 0)
            Register-AvvisiMandati -Supervisore $script:S -Chiavi @('rilasci') -Adesso (New-Ora 20 9 0)
            Set-VoceRilasci $script:S @('1', '2') $true (New-Ora 23 8 0)
            $p = Get-PianoNormale $script:Ora $script:Avvio
            $p.MandaRiepilogo | Should -BeTrue
            $p.Riepilogo[0].Ricordo | Should -BeTrue
            # lo stesso giorno non torna
            Register-AvvisiMandati -Supervisore $script:S -Chiavi @('rilasci') -Adesso $script:Ora
            (Get-PianoNormale (New-Ora 23 14 5) $script:Avvio).MandaRiepilogo | Should -BeFalse
        }
        It 'una card nuova in rilascio fa ricomparire la voce, anche senza soglia e anche lo stesso giorno' {
            Set-VoceRilasci $script:S @('1', '2') $false (New-Ora 23 8 0)
            Register-AvvisiMandati -Supervisore $script:S -Chiavi @('rilasci') -Adesso $script:Ora
            (Get-PianoNormale (New-Ora 23 9 0) $script:Avvio).MandaRiepilogo | Should -BeFalse
            Set-VoceRilasci $script:S @('1', '2', '3') $false (New-Ora 23 9 30)
            $p = Get-PianoNormale (New-Ora 23 14 5) $script:Avvio
            $p.MandaRiepilogo | Should -BeTrue
            $p.Riepilogo[0].Ricordo | Should -BeFalse
            # dopo l avviso la card 3 non e piu nuova
            Register-AvvisiMandati -Supervisore $script:S -Chiavi @('rilasci') -Adesso (New-Ora 23 14 5)
            Set-VoceRilasci $script:S @('1', '2', '3') $false (New-Ora 23 15 0)
            @((Get-PianoNormale (New-Ora 23 16 0) $script:Avvio).Riepilogo).Count | Should -Be 0
            # una card che esce non e una novita
            Set-VoceRilasci $script:S @('1', '3') $false (New-Ora 23 16 30)
            @((Get-PianoNormale (New-Ora 23 17 0) $script:Avvio).Riepilogo).Count | Should -Be 0
        }
    }
    It 'rilasci.predefinito e perArea si validano' {
        $r = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory "$r/config" | Out-Null
        $c = Get-Content (Join-Path $PSScriptRoot '../config/supervisore.json') -Raw | ConvertFrom-Json
        $script:Cfg.rilasci.predefinito.card | Should -Be 5; $script:Cfg.rilasci.predefinito.giorni | Should -Be 7
        @($script:Cfg.rilasci.perArea.PSObject.Properties).Count | Should -Be 0
        $c.rilasci.perArea = [pscustomobject]@{ 'X\Y' = [pscustomobject]@{ card = 0; giorni = 3 } }
        $c | ConvertTo-Json -Depth 6 | Set-Content "$r/config/supervisore.json"
        { Get-ConfigSupervisore -Radice $r } | Should -Throw "*'card'*"
        $c.rilasci.perArea = [pscustomobject]@{ 'X\Y' = [pscustomobject]@{ card = 2; giorni = 3 } }
        $c | ConvertTo-Json -Depth 6 | Set-Content "$r/config/supervisore.json"
        (Get-ConfigSupervisore -Radice $r).rilasci.perArea.'X\Y'.card | Should -Be 2
    }
}

Describe 'Controllo 6: la quota con l override della vista (D51, 2026-11-24)' {
    BeforeAll {
        function script:New-OssRiserva($Override) {
            $o = New-Oss
            $o.Quota.Dati = @{ sevenDay = @{ utilization = ($script:LimitiVeri.sogliaQuotaSettimanale + 0.05); resetsAt = $script:Adesso.AddDays(2).ToString('o') } }
            $o.Quota.Override = $Override
            $o
        }
    }
    It 'senza override il problema quota-riserva suggerisce di alzare la soglia o ignorare la riserva dalla vista' {
        $p = @(Get-ProblemiQuota (script:New-OssRiserva $null) $script:Cfg)
        $p[0].Chiave | Should -Be 'quota-riserva'
        $p[0].Azione | Should -Be 'alza la soglia o ignora la riserva dalla vista'
        $p[0].Azione | Should -Not -Match 'limiti.json'
    }
    It 'con il bypass attivo il problema non si apre' {
        $ov = @{ soglia = $null; ignoraRiserva = $true; fino = $script:Adesso.AddDays(2).ToString('o') }
        @(Get-ProblemiQuota (script:New-OssRiserva $ov) $script:Cfg).Count | Should -Be 0
    }
    It 'con la soglia alzata sopra l uso il problema non si apre' {
        $ov = @{ soglia = 0.95; ignoraRiserva = $false; fino = $script:Adesso.AddDays(2).ToString('o') }
        @(Get-ProblemiQuota (script:New-OssRiserva $ov) $script:Cfg).Count | Should -Be 0
    }
    It 'un bypass scaduto o illeggibile non conta: il problema si apre' {
        $scaduto = @{ soglia = $null; ignoraRiserva = $true; fino = $script:Adesso.AddMinutes(-1).ToString('o') }
        @(Get-ProblemiQuota (script:New-OssRiserva $scaduto) $script:Cfg)[0].Chiave | Should -Be 'quota-riserva'
        @(Get-ProblemiQuota (script:New-OssRiserva @{ errore = 'json rotto' }) $script:Cfg)[0].Chiave | Should -Be 'quota-riserva'
    }
    It 'con il bypass la pausa dopo il limite resta un problema' {
        $o = New-Oss
        $o.Quota.Dati = @{ pausaFino = $script:Adesso.AddHours(2).ToString('o') }
        $o.Quota.Override = @{ soglia = $null; ignoraRiserva = $true; fino = $script:Adesso.AddDays(2).ToString('o') }
        @(Get-ProblemiQuota $o $script:Cfg)[0].Chiave | Should -Be 'quota-pausa'
    }
}

Describe 'Get-ConfigSupervisore con le chiavi dell aggiornamento e gli override (D53)' {
    BeforeEach {
        $script:Rad = Join-Path $TestDrive ('rs-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory "$script:Rad/config" | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '../config/supervisore.json') "$script:Rad/config/supervisore.json"
        $script:Dati = Join-Path $TestDrive ('ds-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:Dati | Out-Null
    }
    It 'il file del repo ha minutiControlloAggiornamenti (30) e oreAttesaAggiornamento (6)' {
        $c = Get-ConfigSupervisore -Radice $script:Rad -CartellaDati $script:Dati
        $c.minutiControlloAggiornamenti | Should -Be 30
        $c.oreAttesaAggiornamento | Should -Be 6
    }
    It 'le due chiavi nuove sono obbligatorie e maggiori di zero' {
        foreach ($n in 'minutiControlloAggiornamenti', 'oreAttesaAggiornamento') {
            $c = Get-Content "$script:Rad/config/supervisore.json" -Raw | ConvertFrom-Json
            $c.PSObject.Properties.Remove($n); $c | ConvertTo-Json -Depth 5 | Set-Content "$script:Rad/config/supervisore.json"
            { Get-ConfigSupervisore -Radice $script:Rad -CartellaDati $script:Dati } | Should -Throw "*'$n'*"
            Copy-Item (Join-Path $PSScriptRoot '../config/supervisore.json') "$script:Rad/config/supervisore.json" -Force
        }
    }
    It 'un override di impostazioni.json vale sopra il file' {
        Set-Content (Join-Path $script:Dati 'impostazioni.json') '{ "supervisore": { "minutiControlloAggiornamenti": 5 } }'
        (Get-ConfigSupervisore -Radice $script:Rad -CartellaDati $script:Dati).minutiControlloAggiornamenti | Should -Be 5
    }
    It 'un override invalido e un errore che dice da dove viene' {
        Set-Content (Join-Path $script:Dati 'impostazioni.json') '{ "supervisore": { "oreAttesaAggiornamento": 0 } }'
        { Get-ConfigSupervisore -Radice $script:Rad -CartellaDati $script:Dati } | Should -Throw "*'oreAttesaAggiornamento'*impostazioni.json*"
        Set-Content (Join-Path $script:Dati 'impostazioni.json') '{ "supervisore": { "nonEsiste": 1 } }'
        { Get-ConfigSupervisore -Radice $script:Rad -CartellaDati $script:Dati } | Should -Throw "*'supervisore.nonEsiste' non esiste*"
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }
