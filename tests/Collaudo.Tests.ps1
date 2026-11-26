BeforeAll {
    $script:DatiPrima = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    Import-Module (Join-Path $PSScriptRoot '../src/Collaudo.psm1') -Force
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Segreto = 'valore-segreto-di-prova-7731'

    # La config di config/collaudo.json con un comando docker finto: pwsh che esegue tests/finti/docker-finto.ps1
    function script:New-ConfigCollaudo([string[]]$Comando = $null) {
        if (-not $Comando) { $Comando = @($script:Pwsh, '-NoProfile', '-File', (Join-Path $PSScriptRoot 'finti/docker-finto.ps1')) }
        [pscustomobject]@{ comandoDocker = $Comando; host = 'localhost'; portaBase = 21000; minutiCreazione = 30; minutiComandi = 3 }
    }
    $script:Voce = [pscustomobject]@{
        repo = 'Acme.AI'; componente = 'stime'
        collaudo = [pscustomobject]@{ compose = 'collaudo/stime/compose.yaml'; porte = @('WEB', 'API', 'KEYCLOAK'); url = [pscustomobject]@{ WebApp = 'WEB'; Api = 'API' } }
    }
    function script:New-Richiesta($Dati, [int]$Slot = 2, [string]$FileProva = $null) {
        New-RichiestaCollaudo -Config (script:New-ConfigCollaudo) -Voce $script:Voce -Card 42 -Slot $Slot -Cartella (Join-Path $Dati 'wt') -FileCollaudo $FileProva -CartellaDati $Dati
    }
}
AfterAll { $env:ATTREZZI_DATI = $script:DatiPrima }

Describe 'porte, URL e variabili dello slot' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:D | Out-Null }

    It 'la porta e portaBase + slot*100 + indice del nome in porte' {
        $p = Get-PorteCollaudo (script:New-Richiesta $script:D 2)
        $p['WEB'] | Should -Be 21200
        $p['API'] | Should -Be 21201
        $p['KEYCLOAK'] | Should -Be 21202
        (Get-PorteCollaudo (script:New-Richiesta $script:D 1))['WEB'] | Should -Be 21100
    }
    It 'gli URL sono http://host:porta per i nomi di url' {
        $u = Get-UrlCollaudo (script:New-Richiesta $script:D 3)
        $u['WebApp'] | Should -Be 'http://localhost:21300'
        $u['Api'] | Should -Be 'http://localhost:21301'
        @($u.Keys).Count | Should -Be 2
    }
    It 'le variabili: host, una porta per nome e le chiavi del file credenziali come COLLAUDO_ piu la chiave' {
        $f = Join-Path $script:D 'cred.json'
        Set-Content $f ('{ "utente_prova": "ada", "password-prova": "' + $script:Segreto + '" }')
        $v = Get-VariabiliCollaudo (script:New-Richiesta $script:D 1 $f)
        $v['COLLAUDO_HOST'] | Should -Be 'localhost'
        $v['COLLAUDO_PORTA_API'] | Should -Be '21101'
        $v['COLLAUDO_UTENTE_PROVA'] | Should -Be 'ada'
        $v['COLLAUDO_PASSWORD_PROVA'] | Should -Be $script:Segreto
    }
    It 'senza il file delle credenziali ci sono solo host e porte' {
        $v = Get-VariabiliCollaudo (script:New-Richiesta $script:D 1 (Join-Path $script:D 'manca.json'))
        @($v.Keys | Where-Object { $_ -notlike 'COLLAUDO_PORTA_*' -and $_ -ne 'COLLAUDO_HOST' }).Count | Should -Be 0
    }
    It 'la richiesta salvata per il processo staccato non contiene i valori delle credenziali' {
        $f = Join-Path $script:D 'cred.json'
        Set-Content $f ('{ "password": "' + $script:Segreto + '" }')
        $r = script:New-Richiesta $script:D 1 $f
        ($r | ConvertTo-Json -Depth 6) | Should -Not -Match $script:Segreto
    }
}

Describe 'Get-RigaComandoDocker: il comando e configurabile' {
    It 'con {cartella} la cartella Windows entra nel comando e la cartella di lavoro non conta' {
        $c = script:New-ConfigCollaudo @('wsl', '-d', 'Ubuntu-26.04', '--cd', '{cartella}', '--', 'docker')
        $r = Get-RigaComandoDocker $c 'C:\wt\card 5' @('compose', 'ls')
        $r.File | Should -Be 'wsl'
        $r.Argomenti | Should -Be @('-d', 'Ubuntu-26.04', '--cd', 'C:\wt\card 5', '--', 'docker', 'compose', 'ls')
        $r.CartellaLavoro | Should -BeNullOrEmpty
    }
    It 'senza {cartella} si lavora nella cartella del worktree' {
        $c = script:New-ConfigCollaudo @('docker', '--context', 'server')
        $r = Get-RigaComandoDocker $c 'C:\wt\card 5' @('ps')
        $r.File | Should -Be 'docker'
        $r.Argomenti | Should -Be @('--context', 'server', 'ps')
        $r.CartellaLavoro | Should -Be 'C:\wt\card 5'
    }
}

Describe 'Invoke-Docker: il punto unico che lancia il comando' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:D | Out-Null }

    It 'riporta codice e uscita, e la scrive nel log' {
        $log = Join-Path $script:D 'x.log'
        $r = Invoke-Docker -Config (script:New-ConfigCollaudo) -Cartella $script:D -Argomenti @('compose', 'up') -FileLog $log
        $r.Codice | Should -Be 0
        $r.Uscita | Should -Match 'argomenti: compose up'
        (Get-Content $log -Raw) | Should -Match 'argomenti: compose up'
    }
    It 'un codice di uscita diverso da zero e riportato' {
        (Invoke-Docker -Config (script:New-ConfigCollaudo) -Cartella $script:D -Argomenti @('fallisci')).Codice | Should -Be 3
    }
    It 'le variabili vanno solo al processo figlio, con WSLENV aggiornato (anche se ne esiste gia uno); il log non ha i valori' {
        $log = Join-Path $script:D 'x.log'
        $vecchio = $env:WSLENV; $env:WSLENV = 'ALTRA/u'
        try {
            $r = Invoke-Docker -Config (script:New-ConfigCollaudo) -Cartella $script:D -Argomenti @('stampa-env') -FileLog $log `
                -Variabili ([ordered]@{ COLLAUDO_HOST = 'localhost'; COLLAUDO_PASSWORD = $script:Segreto })
            $r.Uscita | Should -Match 'WSLENV=ALTRA/u:COLLAUDO_HOST/u:COLLAUDO_PASSWORD/u'
            $r.Uscita | Should -Match 'COLLAUDO_HOST=localhost'
            $env:COLLAUDO_HOST | Should -BeNullOrEmpty
            $env:WSLENV | Should -Be 'ALTRA/u'
            (Get-Content $log -Raw) | Should -Not -Match $script:Segreto
        }
        finally { $env:WSLENV = $vecchio }
    }
    It 'oltre il tempo concesso il processo si ferma e Scaduto e vero' {
        $r = Invoke-Docker -Config (script:New-ConfigCollaudo) -Cartella $script:D -Argomenti @('dormi') -TimeoutMinuti 0.02
        $r.Scaduto | Should -BeTrue
    }
}

Describe 'Invoke-CreazioneAmbiente: down, poi up' {
    BeforeEach {
        $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:D | Out-Null
        $script:Chiamate = [System.Collections.Generic.List[object]]::new()
    }
    It 'esegue down -v poi up -d --build --wait con il compose del progetto, e scrive l esito succeeded' {
        Mock Invoke-Docker -ModuleName Collaudo { $global:ChiamateCollaudo.Add(@($Argomenti)); [pscustomobject]@{ Codice = 0; Uscita = 'ok'; Scaduto = $false } }
        $global:ChiamateCollaudo = $script:Chiamate
        $r = script:New-Richiesta $script:D 1
        Invoke-CreazioneAmbiente $r
        $script:Chiamate.Count | Should -Be 2
        ($script:Chiamate[0] -join ' ') | Should -Be 'compose -p card-42 -f collaudo/stime/compose.yaml down -v'
        ($script:Chiamate[1] -join ' ') | Should -Be 'compose -p card-42 -f collaudo/stime/compose.yaml up -d --build --wait'
        (Get-Content $r.Esito -Raw | ConvertFrom-Json).esito | Should -Be 'succeeded'
    }
    It 'se l up fallisce l esito e failed e il log lo dice' {
        Mock Invoke-Docker -ModuleName Collaudo {
            [pscustomobject]@{ Codice = $(if ($Argomenti -contains 'up') { 1 } else { 0 }); Uscita = ''; Scaduto = $false }
        }
        $r = script:New-Richiesta $script:D 1
        Invoke-CreazioneAmbiente $r
        (Get-Content $r.Esito -Raw | ConvertFrom-Json).esito | Should -Be 'failed'
        (Get-Content $r.Log -Raw) | Should -Match 'up.*codice 1'
    }
    It 'tempo scaduto: failed' {
        Mock Invoke-Docker -ModuleName Collaudo { [pscustomobject]@{ Codice = -1; Uscita = ''; Scaduto = $true } }
        $r = script:New-Richiesta $script:D 1
        Invoke-CreazioneAmbiente $r
        (Get-Content $r.Esito -Raw | ConvertFrom-Json).esito | Should -Be 'failed'
        (Get-Content $r.Log -Raw) | Should -Match 'scaduto'
    }
    It 'docker che non risponde (eccezione): failed, senza rilanciare' {
        Mock Invoke-Docker -ModuleName Collaudo { throw 'docker non trovato' }
        $r = script:New-Richiesta $script:D 1
        { Invoke-CreazioneAmbiente $r } | Should -Not -Throw
        (Get-Content $r.Esito -Raw | ConvertFrom-Json).esito | Should -Be 'failed'
        (Get-Content $r.Log -Raw) | Should -Match 'docker non trovato'
    }
}

Describe 'Start-AmbienteCollaudo e Get-EsitoAmbienteCollaudo' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:D | Out-Null }

    It 'avvia un processo staccato, ricorda pid e avvio, toglie l esito vecchio e salva la richiesta' {
        $r = script:New-Richiesta $script:D 1
        New-Item -ItemType Directory (Split-Path $r.Esito) -Force | Out-Null
        Set-Content $r.Esito '{ "esito": "failed" }'
        Mock Start-Process -ModuleName Collaudo { [pscustomobject]@{ Id = 4321; StartTime = [datetime]'2026-11-26T10:00:00Z' } }
        $s = Start-AmbienteCollaudo $r
        $s.Pid | Should -Be 4321
        $s.Avvio | Should -Not -BeNullOrEmpty
        Test-Path $r.Esito | Should -BeFalse
        Test-Path $r.FileRichiesta | Should -BeTrue
        Should -Invoke Start-Process -ModuleName Collaudo -Times 1 -ParameterFilter { "$ArgumentList" -match 'Collaudo-Crea.ps1' -and "$ArgumentList" -match 'card-42' }
    }
    It 'con il file di esito: completed e l esito scritto' {
        $r = script:New-Richiesta $script:D 1
        New-Item -ItemType Directory (Split-Path $r.Esito) -Force | Out-Null
        Set-Content $r.Esito '{ "esito": "succeeded" }'
        $e = Get-EsitoAmbienteCollaudo -Card 42 -CartellaDati $script:D -ProcessoId 1 -Avvio 'x'
        $e.Stato | Should -Be 'completed'; $e.Esito | Should -Be 'succeeded'; $e.Log | Should -Be $r.Log
    }
    It 'senza esito e con il processo vivo: inProgress' {
        $r = script:New-Richiesta $script:D 1
        Mock Test-ProcessoAvviato -ModuleName Collaudo { $true }
        $e = Get-EsitoAmbienteCollaudo -Card 42 -CartellaDati $script:D -ProcessoId 77 -Avvio '2026-11-26T10:00:00Z'
        $e.Stato | Should -Be 'inProgress'; $e.Esito | Should -BeNullOrEmpty
    }
    It 'senza esito e con il processo morto: completed failed' {
        $r = script:New-Richiesta $script:D 1
        Mock Test-ProcessoAvviato -ModuleName Collaudo { $false }
        $e = Get-EsitoAmbienteCollaudo -Card 42 -CartellaDati $script:D -ProcessoId 77 -Avvio '2026-11-26T10:00:00Z'
        $e.Stato | Should -Be 'completed'; $e.Esito | Should -Be 'failed'
    }
}

Describe 'Remove-AmbienteCollaudo e Get-ProgettiCollaudo' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:D | Out-Null }

    It 'butta con compose -p card-N down -v' {
        Mock Invoke-Docker -ModuleName Collaudo { [pscustomobject]@{ Codice = 0; Uscita = ''; Scaduto = $false } }
        Remove-AmbienteCollaudo -Config (script:New-ConfigCollaudo) -Progetto 'card-9' -CartellaDati $script:D | Should -BeTrue
        Should -Invoke Invoke-Docker -ModuleName Collaudo -Times 1 -ParameterFilter { ($Argomenti -join ' ') -eq 'compose -p card-9 down -v' }
    }
    It 'un errore o un docker che non risponde danno falso e vanno nel log, senza eccezioni' {
        Mock Invoke-Docker -ModuleName Collaudo { throw 'nessuna risposta' }
        { Remove-AmbienteCollaudo -Config (script:New-ConfigCollaudo) -Progetto 'card-9' -CartellaDati $script:D } | Should -Not -Throw
        Remove-AmbienteCollaudo -Config (script:New-ConfigCollaudo) -Progetto 'card-9' -CartellaDati $script:D | Should -BeFalse
        (Get-Content (Join-Path $script:D 'collaudo/card-9.log') -Raw) | Should -Match 'nessuna risposta'
    }
    It 'gli orfani: i progetti card-N letti dalle etichette dei contenitori, una volta sola' {
        Mock Invoke-Docker -ModuleName Collaudo {
            [pscustomobject]@{ Codice = 0; Scaduto = $false; Uscita = "acme.collaudo=1,com.docker.compose.project=card-12,altro=x`ncom.docker.compose.project=card-12,acme.collaudo=1`ncom.docker.compose.project=card-7`ncom.docker.compose.project=altro-progetto" }
        }
        @(Get-ProgettiCollaudo -Config (script:New-ConfigCollaudo) -CartellaDati $script:D) | Sort-Object | Should -Be @('card-12', 'card-7')
        Should -Invoke Invoke-Docker -ModuleName Collaudo -ParameterFilter { $Argomenti -contains 'label=acme.collaudo' }
    }
    It 'se docker non risponde Get-ProgettiCollaudo lancia (lo smistatore lo trasforma in un WARN)' {
        Mock Invoke-Docker -ModuleName Collaudo { throw 'nessuna risposta' }
        { Get-ProgettiCollaudo -Config (script:New-ConfigCollaudo) -CartellaDati $script:D } | Should -Throw '*nessuna risposta*'
    }
}

Describe 'D59, correzioni: timeout dei comandi, processo di creazione, volumi, esito della richiesta giusta' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:D | Out-Null; $global:OrdineCollaudo = [System.Collections.Generic.List[string]]::new() }
    AfterAll { Remove-Variable OrdineCollaudo, TimeoutCollaudo -Scope Global -ErrorAction SilentlyContinue }

    It 'il down e il ps usano minutiComandi (3), non minutiCreazione (30); l up usa minutiCreazione' {
        $global:TimeoutCollaudo = [ordered]@{}
        Mock Invoke-Docker -ModuleName Collaudo { $global:TimeoutCollaudo[($Argomenti -join ' ')] = $TimeoutMinuti; [pscustomobject]@{ Codice = 0; Uscita = ''; Scaduto = $false } }
        Remove-AmbienteCollaudo -Config (script:New-ConfigCollaudo) -Progetto 'card-9' -CartellaDati $script:D | Out-Null
        Get-ProgettiCollaudo -Config (script:New-ConfigCollaudo) -CartellaDati $script:D | Out-Null
        Invoke-CreazioneAmbiente (script:New-Richiesta $script:D 1)
        $global:TimeoutCollaudo['compose -p card-9 down -v'] | Should -Be 3
        $global:TimeoutCollaudo['ps -a --filter label=acme.collaudo --format {{.Labels}}'] | Should -Be 3
        $global:TimeoutCollaudo['compose -p card-42 -f collaudo/stime/compose.yaml down -v'] | Should -Be 3
        $global:TimeoutCollaudo['compose -p card-42 -f collaudo/stime/compose.yaml up -d --build --wait'] | Should -Be 30
    }

    It 'dopo il down si tolgono i volumi rimasti con l etichetta del progetto' {
        Mock Invoke-Docker -ModuleName Collaudo {
            $global:OrdineCollaudo.Add($Argomenti -join ' ')
            [pscustomobject]@{ Codice = 0; Scaduto = $false; Uscita = $(if ($Argomenti -contains 'ls') { "vol-a`nvol-b" } else { '' }) }
        }
        Remove-AmbienteCollaudo -Config (script:New-ConfigCollaudo) -Progetto 'card-9' -CartellaDati $script:D | Should -BeTrue
        @($global:OrdineCollaudo) | Should -Be @('compose -p card-9 down -v', 'volume ls -q --filter label=com.docker.compose.project=card-9', 'volume rm vol-a vol-b')
    }
    It 'senza volumi rimasti non si chiama volume rm; se volume rm fallisce il risultato e falso' {
        Mock Invoke-Docker -ModuleName Collaudo { $global:OrdineCollaudo.Add($Argomenti -join ' '); [pscustomobject]@{ Codice = 0; Scaduto = $false; Uscita = '' } }
        Remove-AmbienteCollaudo -Config (script:New-ConfigCollaudo) -Progetto 'card-9' -CartellaDati $script:D | Should -BeTrue
        @($global:OrdineCollaudo | Where-Object { $_ -like 'volume rm*' }).Count | Should -Be 0
        Mock Invoke-Docker -ModuleName Collaudo { [pscustomobject]@{ Codice = $(if ($Argomenti -contains 'rm') { 1 } else { 0 }); Scaduto = $false; Uscita = $(if ($Argomenti -contains 'ls') { 'v' } else { '' }) } }
        Remove-AmbienteCollaudo -Config (script:New-ConfigCollaudo) -Progetto 'card-9' -CartellaDati $script:D | Should -BeFalse
    }
    It 'gli orfani contano anche i volumi con l etichetta del progetto' {
        Mock Invoke-Docker -ModuleName Collaudo {
            [pscustomobject]@{ Codice = 0; Scaduto = $false; Uscita = $(if ($Argomenti -contains 'volume') { "com.docker.compose.project=card-33`ncom.docker.compose.project=altro" } else { 'com.docker.compose.project=card-12' }) }
        }
        @(Get-ProgettiCollaudo -Config (script:New-ConfigCollaudo) -CartellaDati $script:D | Sort-Object) | Should -Be @('card-12', 'card-33')
        Should -Invoke Invoke-Docker -ModuleName Collaudo -ParameterFilter { $Argomenti -contains 'volume' -and $Argomenti -contains 'label=com.docker.compose.project' }
    }

    It 'prima del down ferma il processo di creazione' {
        Mock Stop-ProcessoCollaudo -ModuleName Collaudo { $global:OrdineCollaudo.Add("stop $ProcessoId") }
        Mock Invoke-Docker -ModuleName Collaudo { $global:OrdineCollaudo.Add($Argomenti -join ' '); [pscustomobject]@{ Codice = 0; Scaduto = $false; Uscita = '' } }
        Remove-AmbienteCollaudo -Config (script:New-ConfigCollaudo) -Progetto 'card-9' -CartellaDati $script:D -ProcessoId 321 -Avvio '2026-11-26T10:00:00Z' | Out-Null
        $global:OrdineCollaudo[0] | Should -Be 'stop 321'
        $global:OrdineCollaudo[1] | Should -Be 'compose -p card-9 down -v'
    }
    It 'Stop-ProcessoCollaudo chiude davvero il processo (e solo se pid e avvio coincidono)' {
        $p = Start-Process -FilePath $script:Pwsh -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru
        try {
            $avvio = $p.StartTime.ToUniversalTime().ToString('o')
            Stop-ProcessoCollaudo -ProcessoId $p.Id -Avvio ([datetime]::UtcNow.AddHours(-3).ToString('o'))
            $p.HasExited | Should -BeFalse
            Stop-ProcessoCollaudo -ProcessoId $p.Id -Avvio $avvio
            $p.WaitForExit(5000) | Should -BeTrue
        }
        finally { if (-not $p.HasExited) { $p.Kill($true) } }
    }

    It 'il file di esito porta l avvio del processo che lo scrive, e un esito di un altro avvio si ignora' {
        Mock Invoke-Docker -ModuleName Collaudo { [pscustomobject]@{ Codice = 0; Uscita = ''; Scaduto = $false } }
        $r = script:New-Richiesta $script:D 1
        Invoke-CreazioneAmbiente $r
        $avvio = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
        (Get-EsitoAmbienteCollaudo -Card 42 -CartellaDati $script:D -ProcessoId 1 -Avvio $avvio).Esito | Should -Be 'succeeded'
        # stato di un altro avvio (la card ha ricreato l ambiente): l esito vecchio non vale
        Mock Test-ProcessoAvviato -ModuleName Collaudo { $true }
        $e = Get-EsitoAmbienteCollaudo -Card 42 -CartellaDati $script:D -ProcessoId 77 -Avvio ([datetime]::UtcNow.AddHours(-3).ToString('o'))
        $e.Stato | Should -Be 'inProgress'
    }
    It 'corsa: se il processo muore subito dopo aver scritto l esito, l esito si rilegge prima di dichiarare failed' {
        $r = script:New-Richiesta $script:D 1
        $global:EsitoCorsa = $r.Esito
        Mock Test-ProcessoAvviato -ModuleName Collaudo {
            New-Item -ItemType Directory (Split-Path $global:EsitoCorsa) -Force | Out-Null
            Set-Content $global:EsitoCorsa '{ "esito": "succeeded" }'
            $false
        }
        $e = Get-EsitoAmbienteCollaudo -Card 42 -CartellaDati $script:D -ProcessoId 77 -Avvio '2026-11-26T10:00:00Z'
        $e.Stato | Should -Be 'completed'; $e.Esito | Should -Be 'succeeded'
        Remove-Variable EsitoCorsa -Scope Global
    }
}
