BeforeAll {
    # D53: Get-Config e Get-ConfigSupervisore leggono impostazioni.json dalla cartella dati: i test non devono vedere quella vera di chi li lancia.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    # I moduli si caricano prima, nello stesso modo dello script, cosi i Mock trovano i comandi da sostituire.
    foreach ($m in 'Comune', 'Config', 'Ado', 'Stato', 'Decisioni', 'Sessioni', 'Telegram', 'Worktree', 'Supervisione', 'Impostazioni', 'Aggiornamento') {
        Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Global
    }
    $script:Script = Join-Path $PSScriptRoot '../src/Supervisore.ps1'
    . (Join-Path $PSScriptRoot 'finti/Radice.ps1')

    # Un giro del supervisore sulla cartella dati di prova, con tutto l'I/O sostituito (vedi il BeforeEach). Restituisce l'uscita.
    function Invoke-Sup { param([hashtable]$Parametri = @{}) & $script:Script -CartellaDati $script:Dati -Radice $script:Rad -ClaudeDir $script:Claude -PercorsoPatInfo (Join-Path $script:Claude 'nessun-pat-info.json') @Parametri *>&1 | Out-String }
    function Get-Sup { Get-StatoSupervisore -Percorso (Join-Path $script:Dati 'supervisore.json') }
    function New-Run($Id, $Ramo = 'develop') {
        [pscustomobject]@{ Id = $Id; Progetto = 'Acme.AI'; Pipeline = 'build-ci'; Ramo = $Ramo; Stato = 'concluso'; Fase = $null; Esito = 'failed'; Tipo = 'ci'
            DefinizioneId = 20; Inizio = $null; Fine = [datetime]::UtcNow.AddHours(-1); Url = "https://ado/run/$Id"; SourceVersion = 'abc123'; ParametriTemplate = $null }
    }
    function Add-RigheLogCard([int]$Card, [int]$Volte) {
        $d = Join-Path $script:Dati 'log'; New-Item -ItemType Directory $d -Force | Out-Null
        $righe = 1..$Volte | ForEach-Object { '{0} ERRORE {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (Format-RigaLog 'LetturaNonRiuscita' @($Card, "The property 'result' cannot be found")) }
        [IO.File]::AppendAllText((Get-FileLog $script:Dati (Get-Date)), (($righe -join "`n") + "`n"))
    }
}

Describe 'Supervisore.ps1: il giro, con tutto l I/O finto' {
    BeforeEach {
        $script:Dati = Join-Path $TestDrive ('dati-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:Dati | Out-Null
        $script:Claude = Join-Path $TestDrive ('claude-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:Claude | Out-Null
        Set-Content (Join-Path $script:Claude 'pat-smistatore.txt') 'finto'   # solo l esistenza conta: le chiamate ad ADO sono finte
        # una radice di prova con la pipeline di build-ci fra quelle rilanciabili (di default l elenco e vuoto)
        $script:Rad = New-RadiceDiProva -Cartella $TestDrive
        $c = Get-Content (Join-Path $script:Rad 'config/supervisore.json') -Raw | ConvertFrom-Json
        $c.pipelineRilanciabili = @([pscustomobject]@{ progetto = 'Acme.AI'; definizioneId = 20 })
        $c | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:Rad 'config/supervisore.json')
        $global:Mondo = @{ Falliti = @(); Smistatore = 'Ready'; Vista = 'Ready'; VistaRisponde = $true; Sessione = $null; Card = @(); Orchestratori = @() }
        Mock Get-ScheduledTask { [pscustomobject]@{ State = $(if ($TaskName -eq 'Smistatore') { $global:Mondo.Smistatore } else { $global:Mondo.Vista }) } }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = (Get-Date).AddMinutes(-1); LastTaskResult = 0 } }
        Mock Start-ScheduledTask { }
        Mock Stop-ScheduledTask { }
        Mock Get-ProcessiVistaRadice { @([pscustomobject]@{ ProcessId = 111; ParentProcessId = 1; CommandLine = 'x' }, [pscustomobject]@{ ProcessId = 222; ParentProcessId = 111; CommandLine = 'x' }) }
        Mock Stop-Process { }
        Mock Get-CimInstance { [pscustomobject]@{ LastBootUpTime = (Get-Date).AddHours(-6) } }
        Mock Invoke-WebRequest { if (-not $global:Mondo.VistaRisponde) { throw 'timeout' }; [pscustomobject]@{ StatusCode = 200 } }
        Mock Get-AdoUtenteCorrente { [pscustomobject]@{ Id = 'u-ric'; Nome = 'Titolare' } }
        Mock Get-AdoCardAttive { @($global:Mondo.Card) }; Mock Get-AdoFeatureAperte { @() }
        Mock Get-AdoBuildPipeline {
            [pscustomobject]@{ Attivi = @(); Orchestratori = @($global:Mondo.Orchestratori); AgentiPool = @(); AgentiLetti = $true; ErroriAgenti = @(); Falliti = @($global:Mondo.Falliti); Errori = @() } }
        Mock Get-AdoMotivoFallimento { 'The agent lost communication with the server' }
        Mock Get-AdoUltimoRun { param($Progetto, $DefinizioneId, $Ramo) [pscustomobject]@{ Id = $global:Mondo.Falliti[0].Id; Stato = 'completed'; Esito = 'failed' } }
        Mock Start-AdoRilancioRun { 777 }
        Mock Read-FilePat { 'mai letto' }
        Mock Test-TelegramConfigurato { $true }
        Mock Send-TelegramMessaggio { $true }
        Mock Start-SessioneRuolo { [pscustomobject]@{ Id = 'sid-diag'; Pid = 5151; Avvio = '2026-11-23T09:00:00.0000000Z'; Ripresa = $false } }
        Mock Get-EsitoSessione { [pscustomobject]@{ Finita = $false; Errore = $false; Esito = $null; Testo = $null; UltimoEvento = [datetime]::UtcNow; Quota = $null; Limite = $null } }
        Mock Test-SessioneViva { $true }
        Mock Stop-Sessione { }
        Mock Get-ImprontaWorktree { @{ ramo = 'develop'; testa = 'h1'; stato = ''; diff = '' } }
    }

    It '-WhatIf non scrive niente: ne la cartella dati, ne Telegram, ne le attivita, ne ADO, ne le sessioni' {
        $global:Mondo.Falliti = @(New-Run 501)
        $global:Mondo.Smistatore = 'Disabled'
        $global:Mondo.VistaRisponde = $false
        Set-Content (Join-Path $script:Claude 'pat-info.json') '{}'
        Add-RigheLogCard 9 5
        $prima = @(Get-ChildItem $script:Dati -Recurse -File | ForEach-Object { $_.Name })
        $out = Invoke-Sup @{ WhatIf = $true }
        # lo stesso scenario fuori da -WhatIf agirebbe: lo si vede dall'uscita
        $out | Should -Match '\[WhatIf\] problema'
        $out | Should -Match '\[WhatIf\] gesto: rilancio il run 501'
        $out | Should -Match '\[WhatIf\] diagnosi: lancerei'
        @(Get-ChildItem $script:Dati -Recurse -File | ForEach-Object { $_.Name }) | Should -Be $prima
        Test-Path (Join-Path $script:Dati 'supervisore.json') | Should -BeFalse
        Should -Invoke Start-AdoRilancioRun -Times 0 -Exactly
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        Should -Invoke Start-ScheduledTask -Times 0 -Exactly
        Should -Invoke Send-TelegramMessaggio -Times 0 -Exactly
    }

    It 'fuori da -WhatIf lo stesso scenario agisce, e lo ricorda in supervisore.json' {
        $global:Mondo.Falliti = @(New-Run 501)
        $out = Invoke-Sup
        $out | Should -Not -Match 'interrotto'
        Should -Invoke Start-AdoRilancioRun -Times 1 -Exactly -ParameterFilter { $DefinizioneId -eq 20 -and $Ramo -eq 'develop' -and $SourceVersion -eq 'abc123' }
        (Get-Sup).gesti.rilanciati['501'].nuovo | Should -Be 777
        (Get-Sup).esecuzioni.Count | Should -Be 1
    }

    It 'un rilancio si registra una volta sola: se il giro dopo va in errore il run non si rilancia di nuovo' {
        $global:Mondo.Falliti = @(New-Run 501)
        Mock Test-TelegramConfigurato { throw 'guasto dopo il gesto' }
        (Invoke-Sup) | Should -Match 'interrotto'
        Should -Invoke Start-AdoRilancioRun -Times 1 -Exactly
        (Get-Sup).gesti.rilanciati['501'].nuovo | Should -Be 777
        # il giro dopo: lo stesso run risulta ancora fallito, ma non si rilancia
        Mock Test-TelegramConfigurato { $true }
        Invoke-Sup | Out-Null
        Should -Invoke Start-AdoRilancioRun -Times 1 -Exactly
    }

    It 'se supervisore.json non si salva il giro si ferma prima del rilancio: nessun gesto non ricordato' {
        $global:Mondo.Falliti = @(New-Run 501)
        Mock Save-StatoSupervisore { throw 'disco pieno' }
        (Invoke-Sup) | Should -Match 'supervisore.json non si salva'
        Should -Invoke Start-AdoRilancioRun -Times 0 -Exactly
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
    }

    It 'se il rilancio fallisce si ricorda lo stesso (una volta per run) e diventa una voce rilancio-fallito' {
        $global:Mondo.Falliti = @(New-Run 501)
        Mock Start-AdoRilancioRun { throw 'HTTP 500' }
        Invoke-Sup | Out-Null
        Invoke-Sup | Out-Null
        Should -Invoke Start-AdoRilancioRun -Times 1 -Exactly
        $s = Get-Sup
        $s.gesti.rilanciati['501'].nuovo | Should -BeNullOrEmpty
        $s.problemi.Keys | Should -Contain 'rilancio-fallito-501'
    }

    It 'una diagnosi lanciata conta nel tetto del giorno anche se il giro poi va in errore, e una per volta' {
        Add-RigheLogCard 9 5
        Mock Test-TelegramConfigurato { throw 'guasto dopo la diagnosi' }
        (Invoke-Sup) | Should -Match 'interrotto'
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'supervisore' -and $Card -eq 0 -and $Cartella -like '*diagnosi*' }
        $s = Get-Sup
        $s.diagnosiGiorno.n | Should -Be 1
        @($s.sessioniDiagnosi).Count | Should -Be 1
        $s.sessioniDiagnosi[0].chiave | Should -Be 'errore-card-9'
        # il giro dopo: la sessione e ancora in corso, nessun altro lancio
        Mock Test-TelegramConfigurato { $true }
        Invoke-Sup | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly
        (Get-Sup).diagnosiGiorno.n | Should -Be 1
    }

    It 'la diagnosi finita con ESITO=diagnosi va nel problema e la sessione esce dall elenco; la quota la scrive la stessa funzione dello smistatore' {
        Add-RigheLogCard 9 5
        Invoke-Sup | Out-Null
        Mock Get-EsitoSessione {
            [pscustomobject]@{ Finita = $true; Errore = $false; Esito = 'diagnosi'; Testo = "Causa: la proprieta result manca.`nESITO=diagnosi"; UltimoEvento = [datetime]::UtcNow
                Quota = @{ five_hour = @{ Utilization = 0.4; ResetsAt = [datetime]::UtcNow.AddHours(2) } }; Limite = $null; Turni = 3; TokenIn = 1; TokenOut = 2; CacheLetti = 3; CacheScritti = 4 } }
        Mock Test-SessioneViva { $false }
        Invoke-Sup | Out-Null
        $s = Get-Sup
        @($s.sessioniDiagnosi).Count | Should -Be 0
        $s.problemi['errore-card-9'].diagnosi | Should -Match 'proprieta result manca'
        $s.problemi['errore-card-9'].diagnosi | Should -Not -Match 'ESITO'
        (Get-Quota -Percorso (Join-Path $script:Dati 'quota.json')).fiveHour.utilization | Should -Be 0.4
        # registrata come le altre sessioni: card 0, ruolo supervisore
        $r = Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl') | ConvertFrom-Json
        $r.card | Should -Be 0; $r.ruolo | Should -Be 'supervisore'; $r.esito | Should -Be 'diagnosi'
    }

    It 'una diagnosi che finisce sul limite di token scrive la pausa in quota.json' {
        Add-RigheLogCard 9 5
        Invoke-Sup | Out-Null
        $reset = [datetime]::UtcNow.AddHours(3)
        Mock Get-EsitoSessione {
            [pscustomobject]@{ Finita = $true; Errore = $true; Esito = $null; Testo = "You've hit your limit"; UltimoEvento = [datetime]::UtcNow
                Quota = @{ five_hour = @{ Utilization = 1.0; ResetsAt = $reset } }; Limite = @{ Finestra = 'five_hour'; Reset = $reset }; Turni = 1; TokenIn = 0; TokenOut = 0; CacheLetti = 0; CacheScritti = 0 } }
        Mock Test-SessioneViva { $false }
        Invoke-Sup | Out-Null
        (Get-Sup).problemi['errore-card-9'].diagnosi | Should -Be 'diagnosi non riuscita'
        (ConvertTo-DataUtc (Get-Quota -Percorso (Join-Path $script:Dati 'quota.json')).pausaFino) | Should -BeGreaterThan ([datetime]::UtcNow.AddHours(2))
    }

    It 'la riserva ferma la diagnosi; con il bypass della vista (soglia-quota.json) la diagnosi parte, perche il cancello e lo stesso dello smistatore' {
        Add-RigheLogCard 9 5
        $reset = [datetime]::UtcNow.AddDays(2).ToString('o')
        Save-Quota -Quota @{ sevenDay = @{ utilization = 0.95; resetsAt = $reset } } -Percorso (Join-Path $script:Dati 'quota.json')
        Invoke-Sup | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        Save-SogliaQuota -Override @{ soglia = $null; ignoraRiserva = $true; fino = $reset; impostata = [datetime]::UtcNow.ToString('o') } -Percorso (Join-Path $script:Dati 'soglia-quota.json')
        Invoke-Sup | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'supervisore' }
    }
    It 'una diagnosi che ha scritto qualcosa (la copia principale e cambiata) e scartata e diventa un urgente' {
        Add-RigheLogCard 9 5
        Invoke-Sup | Out-Null
        Mock Get-ImprontaWorktree { @{ ramo = 'develop'; testa = 'h2'; stato = ' M src/Smistatore.ps1'; diff = '' } }
        Mock Get-EsitoSessione { [pscustomobject]@{ Finita = $true; Errore = $false; Esito = 'diagnosi'; Testo = "Causa x.`nESITO=diagnosi"; UltimoEvento = [datetime]::UtcNow; Quota = $null; Limite = $null; Turni = 1; TokenIn = 0; TokenOut = 0; CacheLetti = 0; CacheScritti = 0 } }
        Mock Test-SessioneViva { $false }
        Invoke-Sup | Out-Null
        $s = Get-Sup
        $s.problemi['errore-card-9'].diagnosi | Should -Be 'diagnosi scartata'
        @($s.problemi.Keys | Where-Object { $_ -like 'diagnosi-ha-scritto-*' }).Count | Should -Be 1
        Should -Invoke Send-TelegramMessaggio -ParameterFilter { $Topic -eq 'urgenti' -and $Testo -match 'La diagnosi ha scritto: .*copia principale' }
    }

    It 'senza pat-smistatore.txt (anche con un pat.txt) nessuna chiamata ad ADO: un urgente con il comando -Pat, e pat.txt non si legge' {
        Remove-Item (Join-Path $script:Claude 'pat-smistatore.txt')
        Set-Content (Join-Path $script:Claude 'pat.txt') 'di una persona'
        Invoke-Sup | Out-Null
        foreach ($f in 'Get-AdoUtenteCorrente', 'Get-AdoCardAttive', 'Get-AdoBuildPipeline', 'Get-AdoMotivoFallimento', 'Get-AdoUltimoRun', 'Start-AdoRilancioRun', 'Read-FilePat') {
            Should -Invoke $f -Times 0 -Exactly
        }
        Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'urgenti' -and $Testo -match 'PAT' -and $Testo -match 'Install-Attrezzi\.ps1 -Pat' }
        (Get-Sup).problemi.Keys | Should -Contain 'pat-mancante'
    }

    It 'uno smistatore fermo e un urgente solo se il supervisore girava: una volta sola, anche se i giri dopo lo ritrovano' {
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = (Get-Date).AddHours(-3); LastTaskResult = 0 } }
        # il PC si e appena risvegliato: il supervisore non girava da ore, non e un problema
        $s = Get-StatoSupervisore -Percorso (Join-Path $script:Dati 'supervisore.json')
        $s.esecuzioni = @([datetime]::UtcNow.AddHours(-3).ToString('o')); $s.ultimaEsecuzione = [datetime]::UtcNow.AddHours(-3).ToString('o')
        Save-StatoSupervisore -Stato $s -Percorso (Join-Path $script:Dati 'supervisore.json')
        Invoke-Sup | Out-Null
        Should -Invoke Send-TelegramMessaggio -Times 0 -Exactly -ParameterFilter { $Topic -eq 'urgenti' -and $Testo -match 'non gira' }
        # il supervisore ha girato ai due giri prima di questo: adesso si
        $s = Get-Sup
        $s.esecuzioni = @([datetime]::UtcNow.AddMinutes(-7).ToString('o'), [datetime]::UtcNow.AddMinutes(-2).ToString('o')); $s.ultimaEsecuzione = $s.esecuzioni[-1]
        Save-StatoSupervisore -Stato $s -Percorso (Join-Path $script:Dati 'supervisore.json')
        Invoke-Sup | Out-Null
        Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'urgenti' -and $Testo -match 'non gira' }
        Invoke-Sup | Out-Null
        Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'urgenti' -and $Testo -match 'non gira' }
    }

    It 'il giro del supervisore che muore manda un urgente una volta sola finche non torna a funzionare' {
        Mock Save-StatoSupervisore { throw 'disco pieno' }
        Invoke-Sup | Out-Null
        Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'urgenti' -and $Testo -match 'si è fermato' }
        Test-Path (Join-Path $script:Dati 'supervisore-morto') | Should -BeTrue
        Invoke-Sup | Out-Null
        Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'urgenti' -and $Testo -match 'si è fermato' }
        # torna a funzionare: il segno sparisce, e un nuovo guasto si dice di nuovo
        Mock Save-StatoSupervisore { Save-Stato -Stato $Stato -Percorso $Percorso }
        Invoke-Sup | Out-Null
        Test-Path (Join-Path $script:Dati 'supervisore-morto') | Should -BeFalse
    }

    It 'se anche Telegram fallisce il guasto resta nel log e il segno non si scrive (si riprova al giro dopo)' {
        Mock Save-StatoSupervisore { throw 'disco pieno' }
        Mock Send-TelegramMessaggio { throw 'Invio a Telegram fallito' }
        (Invoke-Sup) | Should -Match 'interrotto'
        Test-Path (Join-Path $script:Dati 'supervisore-morto') | Should -BeFalse
    }

    It 'la vista: una mancata risposta non basta; alla seconda si riavvia l attivita, ricordato in supervisore.json' {
        $global:Mondo.VistaRisponde = $false
        Invoke-Sup | Out-Null
        Should -Invoke Start-ScheduledTask -Times 0 -Exactly
        (Get-Sup).vistaMancate | Should -Be 1
        Invoke-Sup | Out-Null
        Should -Invoke Start-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Vista' }
        Invoke-Sup | Out-Null   # entro l ora: niente altro riavvio
        Should -Invoke Start-ScheduledTask -Times 1 -Exactly
        $global:Mondo.VistaRisponde = $true
        Invoke-Sup | Out-Null
        (Get-Sup).vistaMancate | Should -Be 0
    }

    It 'la vista in esecuzione ma che non risponde: si ferma e si riavvia; disabilitata: non si tocca' {
        $global:Mondo.VistaRisponde = $false; $global:Mondo.Vista = 'Running'
        Invoke-Sup | Out-Null; Invoke-Sup | Out-Null
        Should -Invoke Stop-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Vista' }
        Should -Invoke Start-ScheduledTask -Times 1 -Exactly
        $global:Mondo.Vista = 'Disabled'
        Remove-Item (Join-Path $script:Dati 'supervisore.json')
        Invoke-Sup | Out-Null; Invoke-Sup | Out-Null
        Should -Invoke Start-ScheduledTask -Times 1 -Exactly
    }

    It 'riavviare la vista chiude prima le pwsh della vista vecchia, poi avvia l attivita; con -WhatIf non chiude niente' {
        $global:Ordine = [System.Collections.Generic.List[string]]::new()
        Mock Stop-Process { $global:Ordine.Add("stop-$Id") }
        Mock Start-ScheduledTask { $global:Ordine.Add('start') }
        $global:Mondo.VistaRisponde = $false; $global:Mondo.Vista = 'Running'
        Invoke-Sup | Out-Null; Invoke-Sup | Out-Null
        ($global:Ordine -join ',') | Should -Be 'stop-111,stop-222,start'
        Remove-Item (Join-Path $script:Dati 'supervisore.json')
        Invoke-Sup @{ WhatIf = [switch]$true } | Out-Null; Invoke-Sup @{ WhatIf = [switch]$true } | Out-Null
        Should -Invoke Stop-Process -Times 2 -Exactly
    }

    It 'il timeout con cui il supervisore interroga la vista e 60 secondi (la vista non risponde mentre ridisegna)' {
        (Get-ConfigSupervisore).timeoutVistaSecondi | Should -Be 60
    }

    It 'un on-hold nato da un bloccato del responsabile: dalla card letta al riepilogo, con il suo resoconto e non "togli il tag"' {
        $global:Mondo.Card = @([pscustomobject]@{ Id = 56; Tipo = 'User Story'; Titolo = 'Titolo della card 56'; Stato = 'Automated test'; Tag = @('agents', 'on-hold')
                Area = 'DevOps.Agents\AI\Stime'; AssegnataA = [pscustomobject]@{ Id = 'u-ric' } })
        Mock Get-AdoCommenti { @() }
        Mock Get-AdoStoriaStato { @() }
        $adesso = [datetime]::UtcNow
        $stato = @{ '56' = @{ inAttesaPer = 'sessione'; ultimoRuolo = 'collaudatore'; cartella = $null; ultimaSessione = @{
                    collaudatore = @{ ruolo = 'collaudatore'; inizio = $adesso.AddHours(-2).ToString('o'); fine = $adesso.AddHours(-2).AddMinutes(5).ToString('o'); esito = 'bloccato'; errore = $false; testo = 'non trovo la versione' }
                    responsabile = @{ ruolo = 'responsabile'; motivo = 'attesa'; inizio = $adesso.AddHours(-1).ToString('o'); fine = $adesso.AddHours(-1).AddMinutes(2).ToString('o'); esito = 'bloccato'; errore = $false
                        testo = "In Test c'e ancora la build della card 55.`n1. Accodare ``release-orchestrator`` con forceRedeploy.`n2. Togliere l'on-hold solo dopo.`nESITO=bloccato" } } } }
        Save-Stato -Stato $stato -Percorso (Join-Path $script:Dati 'stato.json')
        Invoke-Sup | Out-Null
        $voce = (Get-Sup).problemi['card-56-bloccato']
        $voce | Should -Not -BeNullOrEmpty
        (Get-Sup).problemi.ContainsKey('card-56-sblocca') | Should -BeFalse
        Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter {
            $Topic -eq 'riepilogo' -and $Testo -match 'responsabile ha chiuso bloccato' -and $Testo -match 'Accodare release-orchestrator con forceRedeploy' -and $Testo -match 'solo dopo' -and $Testo -notmatch 'ESITO' }
    }

    # ---- i topic (D51): a ogni tipo di avviso il suo ----
    Context 'instradamento nei topic' {
        BeforeEach {
            $global:Mondo.Card = @(
                [pscustomobject]@{ Id = 6; Tipo = 'User Story'; Titolo = 'Titolo della card 6 <script>x</script> & Co'; Stato = 'Ready to release'; Tag = @('agents'); Area = 'DevOps.Agents\AI\Stime'; AssegnataA = [pscustomobject]@{ Id = 'u-ric' } }
                [pscustomobject]@{ Id = 9; Tipo = 'User Story'; Titolo = 'Titolo della card 9'; Stato = 'Ready to release'; Tag = @('agents'); Area = 'DevOps.Agents\AI\Stime'; AssegnataA = [pscustomobject]@{ Id = 'u-ric' } })
            $global:Mondo.Orchestratori = @([pscustomobject]@{ Progetto = 'Acme.AI'; Pipeline = 'release-orchestrator'; DefinizioneId = 33; Tipo = 'rilascio'; Stato = 'concluso'; Esito = 'succeeded'; Fase = $null; Inizio = $null; Fine = [datetime]::UtcNow.AddHours(-30); Ramo = 'main'; Url = 'https://ado/run/1' })
            # le card pronte da rilasciare: la card 6 da 6 giorni (la storia lo dice), la 9 da 2
            Mock Get-AdoCommenti { @() }
            Mock Get-AdoStoriaStato { @([pscustomobject]@{ Rev = 1; Da = 'In review'; A = 'Ready to release'; Chi = 'u'; ChiNome = 'u'; Quando = [datetime]::UtcNow.AddDays().ToString('o') }) }
            # le card pronte da rilasciare: la 6 da 6 giorni (lo dice la storia), la 9 da 2
            Mock Get-AdoCommenti { @() }
            Mock Get-AdoStoriaStato { @([pscustomobject]@{ Rev = 1; Da = 'In review'; A = 'Ready to release'; Chi = 'u'; ChiNome = 'u'; Quando = [datetime]::UtcNow.AddDays($(if ($Id -eq 6) { -6 } else { -2 })).ToString('o') }) }
            $stato = @{ '6' = @{ prId = 61; cartella = $null }; '9' = @{ prId = 91; cartella = $null } }
            Save-Stato -Stato $stato -Percorso (Join-Path $script:Dati 'stato.json')
        }
        It 'urgenti negli Urgenti, riepilogo nel Riepilogo, rilasci in un messaggio a parte nel topic Rilasci, diagnosi nel topic Diagnosi' {
            # un giro dello smistatore finito con errore: un urgente
            Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = (Get-Date).AddMinutes(-1); LastTaskResult = 1 } }
            Add-RigheLogCard 9 5
            Invoke-Sup | Out-Null
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'urgenti' -and $Testo -match '^Supervisore · ' -and $Testo -match '🔴' }
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'riepilogo' -and $Testo -match '<b>\d+ cos[ae] per te</b>' -and $Testo -notmatch 'Rilasci in attesa|Da rilasciare' }
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'rilasci' -and $Testo -match 'Da rilasciare in produzione: 2 card' -and $Testo -match 'AI · Stime' -and $Testo -match 'Acme\.AI/_build\?definitionId=33' -and $Testo -notmatch '<script' -and $Testo -match 'Co\b' }
            # la diagnosi parte appena e pronta: un messaggio nel topic Diagnosi, e il riepilogo la rimanda li
            Mock Get-EsitoSessione {
                [pscustomobject]@{ Finita = $true; Errore = $false; Esito = 'diagnosi'; Testo = "Causa: la proprieta result manca.`nESITO=diagnosi"; UltimoEvento = [datetime]::UtcNow
                    Quota = $null; Limite = $null; Turni = 3; TokenIn = 1; TokenOut = 2; CacheLetti = 3; CacheScritti = 4 } }
            Mock Test-SessioneViva { $false }
            Invoke-Sup | Out-Null
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'diagnosi' -and $Testo -match '🔎' -and $Testo -match 'proprieta result manca' -and $Testo -notmatch 'ESITO' }
        }
        It 'i rilasci seguono il ritmo di prima: una volta, poi non ricompaiono nello stesso giorno senza una card nuova' {
            Invoke-Sup | Out-Null
            Invoke-Sup | Out-Null
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'rilasci' }
            Should -Invoke Send-TelegramMessaggio -Times 0 -Exactly -ParameterFilter { $Topic -eq 'riepilogo' }
            (Get-Sup).problemi['rilasci'].avvisati | Should -Contain '6'
        }
        It 'senza pipeline orchestrator nel progetto la riga lo dice' {
            $global:Mondo.Orchestratori = @()
            Invoke-Sup | Out-Null
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'rilasci' -and $Testo -match 'rilascio: nessuna pipeline orchestrator nel progetto Acme\.AI' }
        }
        It 'D52: le card di una funzionalita sono una voce nei rilasci, con il link alla Feature (UrlFeature della riga) e le card vere nel totale' {
            $global:Mondo.Card = @($global:Mondo.Card | ForEach-Object { $_ | Add-Member PadreId 7 -PassThru -Force })
            $global:Mondo.F7 = [pscustomobject]@{ Id = 7; Tipo = 'Feature'; Titolo = 'Esportare in PDF'; Stato = 'Active'; Tag = @(); Area = 'DevOps.Agents\AI\Stime'; FigliIds = @(6, 9, 10) }
            $global:Mondo.F7Figli = @(
                [pscustomobject]@{ Id = 6; Stato = 'Ready to release'; Tag = @('agents'); Tipo = 'User Story'; Titolo = 'Titolo della card 6' }
                [pscustomobject]@{ Id = 9; Stato = 'Ready to release'; Tag = @('agents'); Tipo = 'User Story'; Titolo = 'Titolo della card 9' }
                [pscustomobject]@{ Id = 10; Stato = 'Ready to release'; Tag = @('collaudo-funzionalita', 'agents'); Tipo = 'User Story'; Titolo = 'Collaudo' })
            Mock Get-AdoFeature { $global:Mondo.F7 }
            Mock Get-AdoFigliFeature { @($global:Mondo.F7Figli) }
            Mock Get-AdoRamoCard { 'feature/f7-esportare-in-pdf' }
            Invoke-Sup | Out-Null
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'rilasci' -and $Testo -match 'Da rilasciare in produzione: 2 card' -and $Testo -match 'edit/7"' -and $Testo -match 'Esportare in PDF \(2 card\)' -and $Testo -notmatch 'edit/6"' }
        }
        It '-WhatIf stampa i messaggi con il topic di destinazione e non manda niente' {
            $out = Invoke-Sup @{ WhatIf = $true }
            $out | Should -Match '\[WhatIf\] Telegram \[topic rilasci\]'
            $out | Should -Match 'Da rilasciare in produzione: 2 card'
            Should -Invoke Send-TelegramMessaggio -Times 0 -Exactly
        }
        It 'se i topic non si creano una voce nel riepilogo dice di dare il permesso al bot, una volta sola' {
            Set-Content (Join-Path $script:Dati 'telegram-topic.json') ('{"topic":{},"fallita":{"quando":"' + [datetime]::UtcNow.ToString('o') + '","errore":"Bad Request: not enough rights"},"permessoAvvisato":false}')
            Invoke-Sup | Out-Null
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'riepilogo' -and $Testo -match 'Gestisci topic' }
            (Get-TelegramProblemaTopic -CartellaDati $script:Dati).Avvisato | Should -BeTrue
            Invoke-Sup | Out-Null
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Testo -match 'Gestisci topic' }
        }
    }

    Context 'l aggiornamento della suite (D53, punto 4)' {
        BeforeEach { New-Item -ItemType Directory (Join-Path $script:Rad '.git') -Force | Out-Null }
        It 'a ogni giro chiama l aggiornamento con la radice, la cartella dati e la config del supervisore, senza -WhatIf' {
            Mock Invoke-AggiornamentoSuite { }
            Invoke-Sup | Out-Null
            Should -Invoke Invoke-AggiornamentoSuite -Times 1 -Exactly -ParameterFilter { $Radice -eq $script:Rad -and $CartellaDati -eq $script:Dati -and $ConfigSupervisore.minutiControlloAggiornamenti -eq 30 -and $ConfigSupervisore.oreAttesaAggiornamento -eq 6 -and -not $WhatIf }
        }
        It 'con -WhatIf lo chiama con -WhatIf: e il modulo a non scrivere' {
            Mock Invoke-AggiornamentoSuite { }
            Invoke-Sup @{ WhatIf = $true } | Out-Null
            Should -Invoke Invoke-AggiornamentoSuite -Times 1 -Exactly -ParameterFilter { $WhatIf }
        }
        It 'una copia senza git non si aggiorna: non lo chiama' {
            Remove-Item (Join-Path $script:Rad '.git') -Recurse -Force
            Mock Invoke-AggiornamentoSuite { }
            Invoke-Sup | Out-Null
            Should -Invoke Invoke-AggiornamentoSuite -Times 0 -Exactly
        }
        It 'viene dopo i controlli del giro: l ultima esecuzione e gia salvata quando parte' {
            $global:EsecuzioniAllaPartenza = -1
            Mock Invoke-AggiornamentoSuite { $global:EsecuzioniAllaPartenza = @((Get-StatoSupervisore -Percorso (Join-Path $global:DatiProva 'supervisore.json')).esecuzioni).Count }
            $global:DatiProva = $script:Dati
            Invoke-Sup | Out-Null
            $global:EsecuzioniAllaPartenza | Should -Be 1
        }
        It 'un errore dell aggiornamento non ferma il giro: va nel log e il supervisore non risulta fermo' {
            Mock Invoke-AggiornamentoSuite { throw 'git rotto' }
            $out = Invoke-Sup
            $out | Should -Match 'aggiornamento della suite non riuscito: git rotto'
            $out | Should -Not -Match 'giro del supervisore interrotto'
            Test-Path (Join-Path $script:Dati 'supervisore-morto') | Should -BeFalse
            (Get-Sup).esecuzioni.Count | Should -Be 1
        }
        It 'con la funzione vera su una cartella .git che non e un repo: l errore e nel log, il giro finisce' {
            $out = Invoke-Sup
            $out | Should -Match 'aggiornamento della suite non riuscito'
            $out | Should -Not -Match 'giro del supervisore interrotto'
        }
        It 'i tre messaggi (aggiornato, fallito, attesa) vanno nel topic aggiornamenti, con le PR e i link' {
            Mock Invoke-AggiornamentoSuite {
                & $Invia 'aggiornato' @{ Da = 'main aaa1111 (20/11/2026)'; A = 'main bbb2222 (25/11/2026)'; Pr = @([pscustomobject]@{ Numero = 1202; Titolo = 'Una PR'; Url = 'https://ado/pullrequest/1202' }) }
                & $Invia 'fallito' @{ A = 'bbb2222'; Errore = 'esce con codice 1' }
                & $Invia 'attesa' @{ A = 'main bbb2222 (25/11/2026)'; Ore = 6 }
            }
            Invoke-Sup | Out-Null
            Should -Invoke Send-TelegramMessaggio -Times 3 -Exactly -ParameterFilter { $Topic -eq 'aggiornamenti' }
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'aggiornamenti' -and $Testo -match 'Suite aggiornata' -and $Testo -match 'href="https://ado/pullrequest/1202">PR 1202' }
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'aggiornamenti' -and $Testo -match 'tornato alla versione di prima' -and $Testo -match 'codice 1' }
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'aggiornamenti' -and $Testo -match 'da oltre 6 ore' }
        }
        It 'C5: la copia lasciata a meta e urgente: va nel topic urgenti, non in Aggiornamenti' {
            Mock Invoke-AggiornamentoSuite { & $Invia 'copiaRotta' @{ Hash = 'abc1234'; Prima = 'def5678'; Errore = 'git ha detto di no' } }
            Invoke-Sup | Out-Null
            Should -Invoke Send-TelegramMessaggio -Times 1 -Exactly -ParameterFilter { $Topic -eq 'urgenti' -and $Testo -match 'la copia e rimasta a meta' -and $Testo -match 'abc1234' }
            Should -Invoke Send-TelegramMessaggio -Times 0 -Exactly -ParameterFilter { $Topic -eq 'aggiornamenti' }
        }
        It 'un invio che non riesce lo sa il modulo (che non da per detto l avviso): l eccezione risale a lui, non al giro' {
            Mock Send-TelegramMessaggio { throw 'telegram giu' }
            $global:ErroreInvio = $null
            Mock Invoke-AggiornamentoSuite { try { & $Invia 'fallito' @{ A = 'x'; Errore = 'e' } } catch { $global:ErroreInvio = $_.Exception.Message } }
            $out = Invoke-Sup
            $global:ErroreInvio | Should -Match 'invio su Telegram non riuscito'
            $out | Should -Not -Match 'giro del supervisore interrotto'
        }
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }
