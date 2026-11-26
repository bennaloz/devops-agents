BeforeAll {
    # D53: i test non devono vedere impostazioni.json ne aggiornamento.json veri di chi li lancia: ogni prova ha la sua cartella dati.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    foreach ($m in 'Comune', 'Stato', 'Worktree', 'Impostazioni', 'Config', 'Aggiornamento') { Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Force -Global }
    $script:Repo = Split-Path -Parent $PSScriptRoot
    # git ha bisogno di un'identita per i commit dei repo di prova
    $script:IdentitaPrima = @{}
    foreach ($n in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL') { $script:IdentitaPrima[$n] = [Environment]::GetEnvironmentVariable($n) }
    $env:GIT_AUTHOR_NAME = 'prova'; $env:GIT_AUTHOR_EMAIL = 'prova@example.com'; $env:GIT_COMMITTER_NAME = 'prova'; $env:GIT_COMMITTER_EMAIL = 'prova@example.com'

    function Invoke-G($Cartella, [string[]]$Argomenti) {
        $out = & git -C $Cartella @Argomenti 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($Argomenti -join ' ') in $Cartella fallito: $out" }
        (@($out) -join "`n").Trim()
    }
    function Set-File([string]$Cartella, [string]$Percorso, [string]$Testo) {
        $p = Join-Path $Cartella $Percorso
        $d = Split-Path -Parent $p
        if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
        [IO.File]::WriteAllText($p, $Testo, [Text.UTF8Encoding]::new($false))
    }
    # Un commit sul ramo di lavoro (main) e il push verso l'origine di prova. Ritorna l'hash.
    function Add-CommitOrigine($S, [string]$Messaggio, [hashtable]$File = @{}) {
        if ($File.Count -eq 0) { $File = @{ "note/$([guid]::NewGuid().ToString('N')).txt" = 'x' } }
        foreach ($k in $File.Keys) { Set-File $S.Lavoro $k $File[$k] }
        Invoke-G $S.Lavoro 'add', '-A' | Out-Null
        Invoke-G $S.Lavoro 'commit', '-m', $Messaggio | Out-Null
        Invoke-G $S.Lavoro 'push', 'origin', 'main' | Out-Null
        Invoke-G $S.Lavoro 'rev-parse', 'HEAD'
    }
    # Una suite di prova: un'origine, il repo di chi ci scrive (lavoro) e la copia che si aggiorna, con config e ruoli veri del repo e due
    # script finti (installazione e giro di prova) che registrano il loro lancio e finiscono con codice 0.
    function New-Suite {
        $base = Join-Path $TestDrive ('s-' + [guid]::NewGuid().ToString('N'))
        $S = @{ Base = $base; Lavoro = "$base/lavoro"; Bare = "$base/origin.git"; Copia = "$base/copia"; Dati = "$base/dati" }
        New-Item -ItemType Directory $S.Lavoro, $S.Dati | Out-Null
        Invoke-G $S.Lavoro 'init', '-q', '-b', 'main' | Out-Null
        Invoke-G $S.Lavoro 'config', 'core.autocrlf', 'false' | Out-Null
        Copy-Item (Join-Path $script:Repo 'config') (Join-Path $S.Lavoro 'config') -Recurse
        Copy-Item (Join-Path $script:Repo 'ruoli') (Join-Path $S.Lavoro 'ruoli') -Recurse
        $log = "$($S.Dati)/lanci.log".Replace('\', '/')
        $S.StubInstalla = "param([switch]`$Regole, [switch]`$Hook, [switch]`$Pianificazione, [string]`$RadicePrincipale)`nAdd-Content '$log' `"install `$PSScriptRoot Regole=`$Regole Hook=`$Hook Pianificazione=`$Pianificazione Radice=`$RadicePrincipale`"`nexit 0`n"
        $S.StubGiro = "param([switch]`$WhatIf)`nAdd-Content '$log' `"giro `$PSScriptRoot WhatIf=`$WhatIf`"`nexit 0`n"
        Set-File $S.Lavoro 'setup/Install-Attrezzi.ps1' $S.StubInstalla
        Set-File $S.Lavoro 'src/Smistatore.ps1' $S.StubGiro
        $S.StubSup = "param([switch]`$WhatIf)`nAdd-Content '$log' `"sup `$PSScriptRoot WhatIf=`$WhatIf`"`nexit 0`n"
        Set-File $S.Lavoro 'src/Supervisore.ps1' $S.StubSup
        Invoke-G $S.Lavoro 'add', '-A' | Out-Null
        Invoke-G $S.Lavoro 'commit', '-q', '-m', 'Merged PR 1000: base' | Out-Null
        Invoke-G $S.Base 'clone', '-q', '--bare', $S.Lavoro, $S.Bare | Out-Null
        Invoke-G $S.Lavoro 'remote', 'add', 'origin', $S.Bare | Out-Null
        # autocrlf spento fin dal checkout: con quello globale acceso git riscriverebbe i file di prova e la copia risulterebbe modificata
        Invoke-G $S.Base 'clone', '-q', '-c', 'core.autocrlf=false', $S.Bare, $S.Copia | Out-Null
        $S.Base0 = Invoke-G $S.Lavoro 'rev-parse', 'HEAD'
        $S
    }
    function Get-Lanci($S) { $f = "$($S.Dati)/lanci.log"; if (Test-Path $f) { @(Get-Content $f) } else { @() } }
    function Get-StatoAgg($S) { Get-Content "$($S.Dati)/aggiornamento.json" -Raw | ConvertFrom-Json }

    $script:CfgSup = [pscustomobject]@{ minutiControlloAggiornamenti = 30; oreAttesaAggiornamento = 6 }
    $script:Ora = [datetime]::new(2026, 11, 25, 10, 0, 0, [DateTimeKind]::Utc)
    # Un giro con i tre canali di uscita raccolti in variabili.
    function Invoke-Giro($S, [datetime]$Adesso = $script:Ora, [switch]$WhatIf) {
        Invoke-AggiornamentoSuite -Radice $S.Copia -CartellaDati $S.Dati -ConfigSupervisore $script:CfgSup -Adesso $Adesso -WhatIf:$WhatIf `
            -Log { param($Livello, $Messaggio) $script:Registro += "$Livello $Messaggio" } -Prova { param($Messaggio) $script:Provato += $Messaggio } `
            -Invia { param($Tipo, $Dati) $script:Inviati += , @($Tipo, $Dati) }
    }
}

AfterAll {
    $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento
    foreach ($n in $script:IdentitaPrima.Keys) { [Environment]::SetEnvironmentVariable($n, $script:IdentitaPrima[$n]) }
}

Describe 'Get-CanaleAggiornamento (D53, punto 1)' {
    It 'il canale delle impostazioni vince su tutto' {
        Get-CanaleAggiornamento 'develop' 'main' | Should -Be 'develop'
        Get-CanaleAggiornamento 'main' 'feature/x' | Should -Be 'main'
    }
    It 'senza impostazione vale il ramo estratto se e main o develop' {
        Get-CanaleAggiornamento $null 'develop' | Should -Be 'develop'
        Get-CanaleAggiornamento '' 'main' | Should -Be 'main'
    }
    It 'altrimenti main: un ramo di lavoro o un commit staccato non sono un canale' {
        Get-CanaleAggiornamento $null 'feature/x' | Should -Be 'main'
        Get-CanaleAggiornamento $null 'HEAD' | Should -Be 'main'
        Get-CanaleAggiornamento $null '' | Should -Be 'main'
    }
}

Describe 'Il confronto delle versioni e i requisiti (D53, punto 5)' {
    It 'legge la prima versione dal testo dei programmi veri' {
        (ConvertTo-VersioneConfrontabile '2.1.328 (Claude Code)') | Should -Be ([version]'2.1.328')
        (ConvertTo-VersioneConfrontabile 'PowerShell 7.7.0') | Should -Be ([version]'7.7.0')
        (ConvertTo-VersioneConfrontabile 'azure-cli                         2.87.0 *') | Should -Be ([version]'2.87.0')
        ConvertTo-VersioneConfrontabile 'nessuna versione' | Should -BeNullOrEmpty
        ConvertTo-VersioneConfrontabile $null | Should -BeNullOrEmpty
    }
    It 'una versione uguale o piu nuova della minima soddisfa il requisito, anche con meno cifre' {
        $req = '{ "claude": "2.1", "powershell": "7.7", "az": "2.87" }' | ConvertFrom-Json
        @(Get-RequisitiMancanti $req @{ claude = '2.1.328 (Claude Code)'; powershell = '7.7.0'; az = 'azure-cli 2.87.0' }).Count | Should -Be 0
        @(Get-RequisitiMancanti $req @{ claude = '2.1'; powershell = '8.0.1'; az = '3.0' }).Count | Should -Be 0
    }
    It 'una versione piu vecchia e un requisito mancante, con quello che serve e quello che c e' {
        $req = '{ "claude": "2.1", "powershell": "7.7" }' | ConvertFrom-Json
        $m = @(Get-RequisitiMancanti $req @{ claude = '2.0.9 (Claude Code)'; powershell = '7.7.0' })
        $m.Count | Should -Be 1
        $m[0].Nome | Should -Be 'claude'; $m[0].Richiesta | Should -Be '2.1'; $m[0].Trovata | Should -Be '2.0.9'
    }
    It 'un programma che non c e (o non risponde) e un requisito mancante' {
        $req = '{ "az": "2.87" }' | ConvertFrom-Json
        $m = @(Get-RequisitiMancanti $req @{ az = $null })
        $m.Count | Should -Be 1
        $m[0].Trovata | Should -BeNullOrEmpty
    }
    It 'un requisito che questa versione non sa misurare non blocca niente; senza file nessun requisito' {
        $req = '{ "claude": "2.1", "git": "9.9" }' | ConvertFrom-Json
        @(Get-RequisitiMancanti $req @{ claude = '2.1.1' }).Count | Should -Be 0
        @(Get-RequisitiMancanti $null @{ claude = '1.0' }).Count | Should -Be 0
    }
    It 'config/requisiti.json del repo chiede Claude Code e PowerShell 7.4, senza az (serve solo all installazione)' {
        $r = Get-Content (Join-Path $script:Repo 'config/requisiti.json') -Raw | ConvertFrom-Json
        @($r.PSObject.Properties.Name | Sort-Object) | Should -Be @('claude', 'powershell')
        $r.powershell | Should -Be '7.4'
        foreach ($n in 'claude', 'powershell') { ConvertTo-VersioneConfrontabile ([string]$r.$n) | Should -Not -BeNullOrEmpty -Because "il requisito '$n' deve avere una versione" }
    }
}

Describe 'Le PR in arrivo, dai messaggi dei commit (D53, punto 7)' {
    It 'riconosce Merged PR n: titolo e Merge pull request n from ramo' {
        $r = @(ConvertFrom-RigheLogPr @('Merged PR 1201: Aggiunge la vista della suite', 'Merge pull request 1137 from memoria/in-prova into develop'))
        $r.Count | Should -Be 2
        $r[0].Numero | Should -Be 1201; $r[0].Titolo | Should -Be 'Aggiunge la vista della suite'
        $r[1].Numero | Should -Be 1137; $r[1].Titolo | Should -Be 'memoria/in-prova'
    }
    It 'un commit che non e una PR non e una voce, e righe vuote o nulle non fanno danni' {
        @(ConvertFrom-RigheLogPr @('fix: un commit diretto', '', 'Merge branch main into develop')).Count | Should -Be 0
        @(ConvertFrom-RigheLogPr @()).Count | Should -Be 0
        @(ConvertFrom-RigheLogPr $null).Count | Should -Be 0
    }
}

Describe 'Get-RelazioneCopia (D53, punto 2)' {
    It 'uguale, indietro (fast-forward), avanti, divergente, senza origine' {
        Get-RelazioneCopia 'a' 'a' $true $true | Should -Be 'uguale'
        Get-RelazioneCopia 'a' 'b' $true $false | Should -Be 'indietro'
        Get-RelazioneCopia 'a' 'b' $false $true | Should -Be 'avanti'
        Get-RelazioneCopia 'a' 'b' $false $false | Should -Be 'divergente'
        Get-RelazioneCopia 'a' $null $false $false | Should -Be 'senzaOrigine'
    }
}

Describe 'Get-FileModificati: i percorsi di git status porcelain' {
    It 'modificati, non tracciati, rinominati e nomi fra virgolette' {
        $f = @(Get-FileModificati " M config/limiti.json`n?? nuovo.txt`nR  vecchio.ps1 -> src/nuovo.ps1`n M `"con spazi.txt`"`n")
        $f | Should -Be @('config/limiti.json', 'nuovo.txt', 'vecchio.ps1', 'src/nuovo.ps1', 'con spazi.txt')
    }
    It 'niente da riportare se la copia e pulita' {
        @(Get-FileModificati '').Count | Should -Be 0
        @(Get-FileModificati $null).Count | Should -Be 0
    }
}

Describe 'Get-PassoAggiornamento: il passo da fare (D53, punti 2, 4, 5)' {
    BeforeAll {
        function New-Oss([hashtable]$Cambia = @{}) {
            $o = @{ Testa = 'aaa'; Punta = 'bbb'; Scartato = $null; Automatico = $true; Richiesta = $false; Relazione = 'indietro'; Modifiche = @()
                Requisiti = { @() }; Occupazione = { [pscustomobject]@{ Sessioni = 0; Processi = 0 } } }
            foreach ($k in $Cambia.Keys) { $o[$k] = $Cambia[$k] }
            $o
        }
    }
    It 'tutto libero e una versione nuova: avanza' {
        $p = Get-PassoAggiornamento (New-Oss)
        $p.Azione | Should -Be 'avanza'; $p.Esito | Should -Be 'aggiornato'; $p.Migra | Should -BeFalse
    }
    It 'la copia e gia all ultima versione: niente, aggiornato' {
        $p = Get-PassoAggiornamento (New-Oss @{ Relazione = 'uguale' })
        $p.Azione | Should -Be 'niente'; $p.Esito | Should -Be 'aggiornato'
    }
    It 'senza il ramo del canale su origin non fa niente e lascia l esito di prima' {
        $p = Get-PassoAggiornamento (New-Oss @{ Relazione = 'senzaOrigine'; Punta = $null })
        $p.Azione | Should -Be 'niente'; $p.Esito | Should -Be 'invariato'
    }
    It 'con l automatico spento e senza richiesta non aggiorna: daAggiornare; con la richiesta aggiorna' {
        (Get-PassoAggiornamento (New-Oss @{ Automatico = $false })).Esito | Should -Be 'daAggiornare'
        (Get-PassoAggiornamento (New-Oss @{ Automatico = $false })).Azione | Should -Be 'niente'
        (Get-PassoAggiornamento (New-Oss @{ Automatico = $false; Richiesta = $true })).Azione | Should -Be 'avanza'
    }
    It 'un commit gia scartato non si riprova finche origine non va oltre' {
        $p = Get-PassoAggiornamento (New-Oss @{ Scartato = 'bbb' })
        $p.Azione | Should -Be 'niente'; $p.Esito | Should -Be 'invariato'
        (Get-PassoAggiornamento (New-Oss @{ Scartato = 'vecchio' })).Azione | Should -Be 'avanza'
    }
    It 'copia avanti o divergente: non fa niente e lo dice, anche con una richiesta' {
        (Get-PassoAggiornamento (New-Oss @{ Relazione = 'avanti' })).Esito | Should -Be 'copiaAvanti'
        (Get-PassoAggiornamento (New-Oss @{ Relazione = 'divergente'; Richiesta = $true })).Esito | Should -Be 'divergente'
        (Get-PassoAggiornamento (New-Oss @{ Relazione = 'avanti'; Richiesta = $true })).Azione | Should -Be 'niente'
        # con l automatico spento una copia avanti non e "una versione nuova disponibile"
        (Get-PassoAggiornamento (New-Oss @{ Relazione = 'avanti'; Automatico = $false })).Esito | Should -Be 'copiaAvanti'
        (Get-PassoAggiornamento (New-Oss @{ Relazione = 'divergente'; Automatico = $false })).Esito | Should -Be 'divergente'
    }
    It 'modifiche locali che non sono solo le due config: non aggiorna e riporta i file' {
        $p = Get-PassoAggiornamento (New-Oss @{ Modifiche = @('src/Supervisore.ps1') })
        $p.Azione | Should -Be 'niente'; $p.Esito | Should -Be 'modificheLocali'; $p.File | Should -Be @('src/Supervisore.ps1')
        $p = Get-PassoAggiornamento (New-Oss @{ Modifiche = @('config/limiti.json', 'README.md') })
        $p.Esito | Should -Be 'modificheLocali'; $p.File.Count | Should -Be 2
    }
    It 'solo limiti.json e supervisore.json modificati: avanza migrando' {
        $p = Get-PassoAggiornamento (New-Oss @{ Modifiche = @('config/limiti.json', 'config/supervisore.json') })
        $p.Azione | Should -Be 'avanza'; $p.Migra | Should -BeTrue; $p.File.Count | Should -Be 2
    }
    It 'requisiti mancanti: non aggiorna e dice cosa manca' {
        $m = @{ Nome = 'claude'; Richiesta = '9.0'; Trovata = '2.1.328' }
        $req = { @($m) }.GetNewClosure()
        $p = Get-PassoAggiornamento (New-Oss @{ Requisiti = $req })
        $p.Azione | Should -Be 'niente'; $p.Esito | Should -Be 'requisitiMancanti'; $p.Requisiti[0].Nome | Should -Be 'claude'
    }
    It 'sessioni in corso o un giro dello smistatore: aspetta' {
        $p = Get-PassoAggiornamento (New-Oss @{ Occupazione = { [pscustomobject]@{ Sessioni = 2; Processi = 0 } } })
        $p.Azione | Should -Be 'niente'; $p.Esito | Should -Be 'inAttesaSessioni'; $p.Occupazione.Sessioni | Should -Be 2
        (Get-PassoAggiornamento (New-Oss @{ Occupazione = { [pscustomobject]@{ Sessioni = 0; Processi = 1 } } })).Esito | Should -Be 'inAttesaSessioni'
    }
    It 'l ordine dei casi: le modifiche locali vengono prima dei requisiti, i requisiti prima delle sessioni' {
        $r = { @(@{ Nome = 'az'; Richiesta = '9'; Trovata = $null }) }
        $o = { [pscustomobject]@{ Sessioni = 1; Processi = 0 } }
        (Get-PassoAggiornamento (New-Oss @{ Modifiche = @('x.txt'); Requisiti = $r; Occupazione = $o })).Esito | Should -Be 'modificheLocali'
        (Get-PassoAggiornamento (New-Oss @{ Requisiti = $r; Occupazione = $o })).Esito | Should -Be 'requisitiMancanti'
    }
    It 'requisiti e sessioni costano (processi, disco): non si chiamano se un caso prima ha gia deciso' {
        $script:Chiamate = 0
        $costoso = { $script:Chiamate++; @() }
        Get-PassoAggiornamento (New-Oss @{ Relazione = 'uguale'; Requisiti = $costoso; Occupazione = { $script:Chiamate++; [pscustomobject]@{ Sessioni = 0; Processi = 0 } } }) | Out-Null
        Get-PassoAggiornamento (New-Oss @{ Automatico = $false; Requisiti = $costoso }) | Out-Null
        Get-PassoAggiornamento (New-Oss @{ Relazione = 'divergente'; Requisiti = $costoso }) | Out-Null
        Get-PassoAggiornamento (New-Oss @{ Modifiche = @('x'); Requisiti = $costoso }) | Out-Null
        $script:Chiamate | Should -Be 0
    }
}

Describe 'Le regole piccole dell aggiornamento' {
    It 'Test-ControlloDovuto: subito se non c e un controllo o se c e una richiesta, altrimenti dopo i minuti' {
        $ora = [datetime]::new(2026, 11, 25, 10, 0, 0, [DateTimeKind]::Utc)
        Test-ControlloDovuto $null 30 $ora $false | Should -BeTrue
        Test-ControlloDovuto $ora.AddMinutes(-10).ToString('o') 30 $ora $false | Should -BeFalse
        Test-ControlloDovuto $ora.AddMinutes(-30).ToString('o') 30 $ora $false | Should -BeTrue
        Test-ControlloDovuto $ora.AddMinutes(-1).ToString('o') 30 $ora $true | Should -BeTrue
        Test-ControlloDovuto 'non una data' 30 $ora $false | Should -BeTrue
    }
    It 'Test-AttesaOltre: l attesa dura da troppo dopo le ore indicate' {
        $ora = [datetime]::new(2026, 11, 25, 16, 0, 0, [DateTimeKind]::Utc)
        Test-AttesaOltre $ora.AddHours(-5).ToString('o') $ora 6 | Should -BeFalse
        Test-AttesaOltre $ora.AddHours(-6).ToString('o') $ora 6 | Should -BeTrue
        Test-AttesaOltre $null $ora 6 | Should -BeFalse
    }
    It 'Format-VersioneSuite: canale, hash corto e data' {
        Format-VersioneSuite @{ canale = 'main'; hash = '4f3a2b1'; data = '2026-11-25T09:30:00+01:00' } | Should -Match '^main 4f3a2b1 \(25/11/2026\)$'
        Format-VersioneSuite $null | Should -Be 'non nota'
    }
    It 'ConvertTo-UrlRepoAdo: l indirizzo base del repo, senza utente; altro e null' {
        ConvertTo-UrlRepoAdo 'https://acme.visualstudio.com/DevOps.Agents/_git/DevOps.Agents' | Should -Be 'https://acme.visualstudio.com/DevOps.Agents/_git/DevOps.Agents'
        ConvertTo-UrlRepoAdo 'https://utente@dev.azure.com/acme/Progetto/_git/Repo/' | Should -Be 'https://dev.azure.com/acme/Progetto/_git/Repo'
        ConvertTo-UrlRepoAdo 'C:/da/qualche/parte/origin.git' | Should -BeNullOrEmpty
        ConvertTo-UrlRepoAdo '' | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-ProcessoFiglio: un processo con un tempo massimo (D53, punto 6)' {
    It 'riporta il codice di uscita e l uscita del processo' {
        $f = Join-Path $TestDrive 'esce3.ps1'
        Set-Content $f "param([string]`$Nome)`nWrite-Output `"ciao `$Nome`"`n[Console]::Error.WriteLine('un errore')`nexit 3"
        $r = Invoke-ProcessoFiglio -Script $f -Argomenti @('-Nome', 'mondo') -TimeoutSecondi 60
        $r.Codice | Should -Be 3; $r.Timeout | Should -BeFalse
        $r.Uscita | Should -Match 'ciao mondo'; $r.Uscita | Should -Match 'un errore'
    }
    It 'un processo che non finisce entro il tempo si chiude e conta come timeout' {
        $f = Join-Path $TestDrive 'dorme.ps1'
        Set-Content $f 'Start-Sleep -Seconds 120'
        $inizio = Get-Date
        $r = Invoke-ProcessoFiglio -Script $f -TimeoutSecondi 2
        $r.Timeout | Should -BeTrue; $r.Codice | Should -Not -Be 0
        ((Get-Date) - $inizio).TotalSeconds | Should -BeLessThan 30
    }
}

Describe 'Le attivita pianificate dello smistatore: si riabilita solo cio che si e disabilitato (D53, punto 4)' {
    It 'abilitata: la disabilita e lo dice' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } } -ModuleName Aggiornamento
        Mock Disable-ScheduledTask { } -ModuleName Aggiornamento
        Disable-AttivitaSmistatore | Should -BeTrue
        Should -Invoke Disable-ScheduledTask -ModuleName Aggiornamento -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Smistatore' -and $TaskPath -eq '\DevOps.Agents\' }
    }
    It 'gia disabilitata da una persona: non la tocca e dice di no, cosi non la riabilita' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Disabled' } } -ModuleName Aggiornamento
        Mock Disable-ScheduledTask { } -ModuleName Aggiornamento
        Disable-AttivitaSmistatore | Should -BeFalse
        Should -Invoke Disable-ScheduledTask -ModuleName Aggiornamento -Times 0 -Exactly
    }
    It 'senza l attivita (nessuna pianificazione) non fa niente' {
        Mock Get-ScheduledTask { $null } -ModuleName Aggiornamento
        Mock Disable-ScheduledTask { } -ModuleName Aggiornamento
        Disable-AttivitaSmistatore | Should -BeFalse
        Should -Invoke Disable-ScheduledTask -ModuleName Aggiornamento -Times 0 -Exactly
    }
    It 'Enable-AttivitaSmistatore riabilita l attivita dello smistatore' {
        Mock Enable-ScheduledTask { } -ModuleName Aggiornamento
        Enable-AttivitaSmistatore
        Should -Invoke Enable-ScheduledTask -ModuleName Aggiornamento -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Smistatore' }
    }
}

Describe 'Get-OccupazioneSuite: le sessioni sono quelle che la vista conta come in corso (D53, punto 4)' {
    BeforeEach { Mock Get-ProcessiSmistatoreRadice { @() } -ModuleName Aggiornamento }
    It 'conta le card con una sessione in stato.json e i giri dello smistatore della radice' {
        $d = Join-Path $TestDrive ('occ-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null
        Set-Content "$d/stato.json" '{ "101": { "sessione": { "id": "s1" } }, "102": { "sessione": null }, "103": { "prId": 5 } }'
        (Get-OccupazioneSuite 'C:/x' $d).Sessioni | Should -Be 1
        (Get-OccupazioneSuite 'C:/x' $d).Processi | Should -Be 0
        Mock Get-ProcessiSmistatoreRadice { @([pscustomobject]@{ ProcessId = 9 }) } -ModuleName Aggiornamento
        (Get-OccupazioneSuite 'C:/x' $d).Processi | Should -Be 1
    }
    It 'senza stato.json non ci sono sessioni' {
        $d = Join-Path $TestDrive ('occ-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null
        (Get-OccupazioneSuite 'C:/x' $d).Sessioni | Should -Be 0
    }
}

Describe 'Get-PassoAggiornamento: le correzioni della revisione (D53)' {
    BeforeAll {
        function New-Oss2([hashtable]$Cambia = @{}) {
            $o = @{ Testa = 'aaa'; Punta = 'bbb'; Scartato = $null; Automatico = $true; Richiesta = $false; Relazione = 'indietro'; Modifiche = @(); RamoCanaleLocaleDivergente = $false
                Requisiti = { @() }; Occupazione = { [pscustomobject]@{ Sessioni = 0; Processi = 0 } } }
            foreach ($k in $Cambia.Keys) { $o[$k] = $Cambia[$k] }
            $o
        }
    }
    It 'C3: una richiesta esplicita Aggiorna adesso riprova il commit scartato; il giro automatico no' {
        (Get-PassoAggiornamento (New-Oss2 @{ Scartato = 'bbb' })).Azione | Should -Be 'niente'
        (Get-PassoAggiornamento (New-Oss2 @{ Scartato = 'bbb'; Richiesta = $true })).Azione | Should -Be 'avanza'
        (Get-PassoAggiornamento (New-Oss2 @{ Scartato = 'bbb'; Richiesta = $true; Automatico = $false })).Azione | Should -Be 'avanza'
    }
    It 'C4: un ramo locale del canale che origine non contiene: niente aggiornamento, con il suo esito' {
        $p = Get-PassoAggiornamento (New-Oss2 @{ RamoCanaleLocaleDivergente = $true })
        $p.Azione | Should -Be 'niente'; $p.Esito | Should -Be 'ramoCanaleDivergente'
        (Get-PassoAggiornamento (New-Oss2 @{ RamoCanaleLocaleDivergente = $true; Richiesta = $true })).Esito | Should -Be 'ramoCanaleDivergente'
    }
}

Describe 'Get-OccupazioneSuite: anche i mentori e le diagnosi (D53, C2)' {
    BeforeEach {
        Mock Get-ProcessiSmistatoreRadice { @() } -ModuleName Aggiornamento
        $script:D = Join-Path $TestDrive ('occ-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:D | Out-Null
    }
    It 'un mentore vivo in stato.json tiene ferma la copia' {
        Set-Content "$script:D/stato.json" '{ "101": { "sessione": null, "mentori": [ { "id": "m1", "ruolo": "mentore" } ] } }'
        (Get-OccupazioneSuite 'C:/x' $script:D).Sessioni | Should -Be 1
    }
    It 'una diagnosi in corso del supervisore (supervisore.json) tiene ferma la copia' {
        Set-Content "$script:D/supervisore.json" '{ "sessioniDiagnosi": [ { "id": "d1", "chiave": "k" } ], "problemi": {} }'
        (Get-OccupazioneSuite 'C:/x' $script:D).Sessioni | Should -Be 1
    }
    It 'sessioni di card, mentori e diagnosi si sommano; liste vuote o con null non contano' {
        Set-Content "$script:D/stato.json" '{ "1": { "sessione": { "id": "s" }, "mentori": [ { "id": "m" }, null ] }, "2": { "mentori": [] } }'
        Set-Content "$script:D/supervisore.json" '{ "sessioniDiagnosi": [ { "id": "d" }, null ] }'
        (Get-OccupazioneSuite 'C:/x' $script:D).Sessioni | Should -Be 3
    }
}

Describe 'Get-VersioniInstallate: claude si trova come lo trovano le sessioni (D53, C7)' {
    It 'usa Get-EseguibileClaude e non cerca da se; non c e az' {
        Mock Get-EseguibileClaude { (Get-Process -Id $PID).Path } -ModuleName Aggiornamento
        $v = Get-VersioniInstallate
        Should -Invoke Get-EseguibileClaude -ModuleName Aggiornamento -Times 1 -Exactly
        $v.claude | Should -Match 'PowerShell'
        $v.powershell | Should -Be $PSVersionTable.PSVersion.ToString()
        $v.ContainsKey('az') | Should -BeFalse
    }
    It 'se claude non si trova la versione e nulla (requisito mancante)' {
        Mock Get-EseguibileClaude { throw 'claude.exe non trovato' } -ModuleName Aggiornamento
        (Get-VersioniInstallate).claude | Should -BeNullOrEmpty
    }
}

Describe 'Restore-CopiaPrecedente rimette il ramo del canale dov era (D53, C4)' {
    BeforeEach { $script:S = New-Suite }
    It 'dopo un checkout -B del canale, il ritorno rimette main al commit di prima' {
        Invoke-G $script:S.Lavoro 'branch', 'develop' | Out-Null; Invoke-G $script:S.Lavoro 'push', '-q', 'origin', 'develop' | Out-Null
        Invoke-G $script:S.Copia 'fetch', '-q', 'origin' | Out-Null
        Invoke-G $script:S.Copia 'checkout', '-q', '-b', 'develop', 'origin/develop' | Out-Null
        Add-CommitOrigine $script:S 'Merged PR 1: nuova' | Out-Null
        Invoke-G $script:S.Copia 'fetch', '-q', 'origin' | Out-Null
        Invoke-G $script:S.Copia 'checkout', '-q', '-B', 'main', 'origin/main' | Out-Null
        Restore-CopiaPrecedente $script:S.Copia $script:S.Base0 'develop' 'main' $script:S.Base0
        Invoke-G $script:S.Copia 'branch', '--show-current' | Should -Be 'develop'
        Invoke-G $script:S.Copia 'rev-parse', 'main' | Should -Be $script:S.Base0
    }
    It 'se il ramo del canale non esisteva prima, il ritorno lo toglie' {
        Invoke-G $script:S.Lavoro 'branch', 'develop' | Out-Null; Invoke-G $script:S.Lavoro 'push', '-q', 'origin', 'develop' | Out-Null
        Invoke-G $script:S.Copia 'fetch', '-q', 'origin' | Out-Null
        Invoke-G $script:S.Copia 'checkout', '-q', '-b', 'develop', 'origin/develop' | Out-Null
        Invoke-G $script:S.Copia 'branch', '-D', 'main' | Out-Null
        Invoke-G $script:S.Copia 'checkout', '-q', '-B', 'main', 'origin/main' | Out-Null
        Restore-CopiaPrecedente $script:S.Copia $script:S.Base0 'develop' 'main' ''
        Invoke-G $script:S.Copia 'branch', '--list', 'main' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-RadiceInstallazione (D53, C1)' {
    It 'porta la radice con le barre in avanti' {
        ConvertTo-RadiceInstallazione 'C:\develop\GIT\DevOps.Agents' | Should -Be 'C:/develop/GIT/DevOps.Agents'
        ConvertTo-RadiceInstallazione 'C:/x/y' | Should -Be 'C:/x/y'
    }
}

Describe 'Invoke-AggiornamentoSuite su repo git temporanei (D53)' {
    BeforeEach {
        $script:Registro = @(); $script:Provato = @(); $script:Inviati = @()
        $global:ContaDisabilita = 0; $global:ContaAbilita = 0; $global:DisabilitaRisponde = $true
        Mock Disable-AttivitaSmistatore { $global:ContaDisabilita++; $global:DisabilitaRisponde } -ModuleName Aggiornamento
        Mock Enable-AttivitaSmistatore { $global:ContaAbilita++ } -ModuleName Aggiornamento
        Mock Get-ProcessiSmistatoreRadice { @() } -ModuleName Aggiornamento
        Mock Get-VersioniInstallate { @{ claude = '2.1.328 (Claude Code)'; powershell = '7.7.0'; az = 'azure-cli 2.87.0' } } -ModuleName Aggiornamento
        $script:S = New-Suite
    }
    AfterEach { InModuleScope Aggiornamento { $script:TimeoutInstallazioneSecondi = 300; $script:TimeoutGiroProvaSecondi = 300 } }

    Context 'l avanzamento in fast-forward' {
        It 'porta la copia all ultimo commit di origin/main, lancia installazione e giro di prova dalla copia aggiornata e scrive lo stato' {
            Invoke-G $script:S.Copia 'config', 'remote.origin.url', 'https://acme.visualstudio.com/DevOps.Agents/_git/DevOps.Agents' | Out-Null
            Invoke-G $script:S.Copia 'config', "url.$($script:S.Bare.Replace('\', '/')).insteadOf", 'https://acme.visualstudio.com/DevOps.Agents/_git/DevOps.Agents' | Out-Null
            $h1 = Add-CommitOrigine $script:S 'Merged PR 1201: Primo cambio'
            $h2 = Add-CommitOrigine $script:S 'Merge pull request 1202 from feat/secondo into main'
            $r = Invoke-Giro $script:S
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $h2
            Invoke-G $script:S.Copia 'status', '--porcelain' | Should -BeNullOrEmpty
            $r.ultimoEsito.esito | Should -Be 'aggiornato'
            $s = Get-StatoAgg $script:S
            $s.installata.hash | Should -Be $h2.Substring(0, 7); $s.installata.canale | Should -Be 'main'
            $s.disponibile | Should -BeNullOrEmpty
            $s.ultimoEsito.da | Should -Be $script:S.Base0.Substring(0, 7); $s.ultimoEsito.a | Should -Be $h2.Substring(0, 7)
            $lanci = Get-Lanci $script:S
            $lanci.Count | Should -Be 3
            $lanci[0] | Should -Match 'install .*copia.setup Regole=True Hook=True Pianificazione=True Radice=.*copia$'
            $lanci[0] | Should -Not -Match 'Pat'
            $lanci[1] | Should -Match 'giro .*copia.src WhatIf=True'
            # anche il supervisore della copia nuova, a vuoto: la verifica non e solo lo smistatore
            $lanci[2] | Should -Match 'sup .*copia.src WhatIf=True'
            # la radice all installazione ha le barre in avanti, come negli hook di settings.json
            $lanci[0] | Should -Match 'Radice=[A-Za-z]:/'
            $lanci[0] | Should -Not -Match 'Radice=.*[\\]'
            # la disabilitazione dell'attivita e solo per il tempo dell'aggiornamento
            $global:ContaDisabilita | Should -Be 1; $global:ContaAbilita | Should -Be 1
            # un messaggio, con da quale a quale versione e le PR entrate con i loro link (dal piu nuovo)
            $script:Inviati.Count | Should -Be 1
            $script:Inviati[0][0] | Should -Be 'aggiornato'
            $d = $script:Inviati[0][1]
            $d.Da | Should -Match '^main '; $d.A | Should -Match $h2.Substring(0, 7)
            @($d.Pr).Count | Should -Be 2
            $d.Pr[0].Numero | Should -Be 1202; $d.Pr[0].Titolo | Should -Be 'feat/secondo'
            $d.Pr[0].Url | Should -Be 'https://acme.visualstudio.com/DevOps.Agents/_git/DevOps.Agents/pullrequest/1202'
            $d.Pr[1].Numero | Should -Be 1201; $d.Pr[1].Titolo | Should -Be 'Primo cambio'
        }
        It 'le PR in arrivo restano nello stato finche la copia non avanza (automatico spento)' {
            Add-CommitOrigine $script:S 'Merged PR 1301: Una PR' | Out-Null
            Set-Impostazione -Nome 'aggiornamentoAutomatico' -Valore $false -CartellaDati $script:S.Dati
            Invoke-Giro $script:S | Out-Null
            $s = Get-StatoAgg $script:S
            $s.ultimoEsito.esito | Should -Be 'daAggiornare'
            @($s.prInArrivo).Count | Should -Be 1; $s.prInArrivo[0].numero | Should -Be 1301
            $s.disponibile.hash | Should -Not -BeNullOrEmpty
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            $global:ContaDisabilita | Should -Be 0
        }
        It 'senza versioni nuove non cambia niente e dice aggiornato' {
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'aggiornato'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            (Get-Lanci $script:S).Count | Should -Be 0
            $script:Inviati.Count | Should -Be 0
            $global:ContaDisabilita | Should -Be 0
        }
        It 'un attivita gia disabilitata da una persona non si riabilita a fine aggiornamento' {
            $global:DisabilitaRisponde = $false
            Add-CommitOrigine $script:S 'Merged PR 1302: Altro' | Out-Null
            Invoke-Giro $script:S | Out-Null
            $global:ContaDisabilita | Should -Be 1
            $global:ContaAbilita | Should -Be 0
        }
        It 'un avviso Telegram che fallisce non annulla l aggiornamento' {
            $h = Add-CommitOrigine $script:S 'Merged PR 1303: Altro'
            $r = Invoke-AggiornamentoSuite -Radice $script:S.Copia -CartellaDati $script:S.Dati -ConfigSupervisore $script:CfgSup -Adesso $script:Ora -Invia { throw 'telegram giu' } -Log { param($l, $m) $script:Registro += "$l $m" }
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $h
            $r.ultimoEsito.esito | Should -Be 'aggiornato'
            ($script:Registro -join "`n") | Should -Match 'telegram giu'
        }
    }

    Context 'il controllo con fetch ogni tanto' {
        It 'fra un controllo e l altro non guarda origine: un commit arrivato dopo si vede solo al controllo dovuto' {
            Invoke-Giro $script:S | Out-Null
            $h = Add-CommitOrigine $script:S 'Merged PR 1401: Dopo'
            Invoke-Giro $script:S $script:Ora.AddMinutes(10) | Out-Null
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            Invoke-Giro $script:S $script:Ora.AddMinutes(31) | Out-Null
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $h
        }
        It 'un fetch che non riesce non ferma il giro: lo stato dice l errore' {
            Invoke-G $script:S.Copia 'remote', 'set-url', 'origin', (Join-Path $TestDrive 'non-esiste.git') | Out-Null
            $r = Invoke-Giro $script:S
            $r.erroreControllo | Should -Match 'git fetch origin e fallito'
            (Get-StatoAgg $script:S).erroreControllo | Should -Match 'fallito'
            ($script:Registro -join "`n") | Should -Match 'AVVISO'
            # il giro dopo, a origine tornata, cancella l errore
            Invoke-G $script:S.Copia 'remote', 'set-url', 'origin', $script:S.Bare | Out-Null
            $r = Invoke-Giro $script:S $script:Ora.AddMinutes(31)
            $r.erroreControllo | Should -BeNullOrEmpty
        }
    }

    Context 'la copia non si tocca a mano' {
        It 'con una modifica locale a un file qualunque non aggiorna e riporta i file (anche un file non tracciato)' {
            Add-CommitOrigine $script:S 'Merged PR 1501: Nuova' | Out-Null
            Add-Content (Join-Path $script:S.Copia 'src/Smistatore.ps1') '# modifica a mano'
            Set-File $script:S.Copia 'appunti.txt' 'miei'
            $r = Invoke-Giro $script:S
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            $r.ultimoEsito.esito | Should -Be 'modificheLocali'
            @($r.ultimoEsito.file) | Should -Contain 'src/Smistatore.ps1'
            @($r.ultimoEsito.file) | Should -Contain 'appunti.txt'
            (Get-Content (Join-Path $script:S.Copia 'src/Smistatore.ps1') -Raw) | Should -Match 'modifica a mano'
            $global:ContaDisabilita | Should -Be 0
        }
        It 'la migrazione non parte se accanto a limiti.json c e un altro file modificato: limiti.json resta com e' {
            Add-CommitOrigine $script:S 'Merged PR 1502: Nuova' | Out-Null
            $f = Join-Path $script:S.Copia 'config/limiti.json'
            Set-Content $f ((Get-Content $f -Raw) -replace '0\.70', '0.85')
            Set-File $script:S.Copia 'README.md' 'mio'
            Invoke-Giro $script:S | Out-Null
            (Get-Content $f -Raw) | Should -Match '0\.85'
            Test-Path (Join-Path $script:S.Dati 'impostazioni.json') | Should -BeFalse
        }
        It 'una copia con un commit locale e origine che ne ha uno nuovo e divergente: non si tocca' {
            Set-File $script:S.Copia 'mio.txt' 'm'
            Invoke-G $script:S.Copia 'add', '-A' | Out-Null; Invoke-G $script:S.Copia 'commit', '-q', '-m', 'commit locale' | Out-Null
            $locale = Invoke-G $script:S.Copia 'rev-parse', 'HEAD'
            Add-CommitOrigine $script:S 'Merged PR 1503: Nuova' | Out-Null
            Invoke-G $script:S.Copia 'fetch', 'origin', '-q' | Out-Null
            # origine e copia hanno ciascuna un commit che l altra non ha: divergente
            (Invoke-Giro $script:S).ultimoEsito.esito | Should -Be 'divergente'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $locale
        }
        It 'una copia avanti (un commit in piu di origine, nessuno di meno) non si tocca: copiaAvanti' {
            Set-File $script:S.Copia 'mio.txt' 'm'
            Invoke-G $script:S.Copia 'add', '-A' | Out-Null; Invoke-G $script:S.Copia 'commit', '-q', '-m', 'commit locale' | Out-Null
            $locale = Invoke-G $script:S.Copia 'rev-parse', 'HEAD'
            (Invoke-Giro $script:S).ultimoEsito.esito | Should -Be 'copiaAvanti'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $locale
            $global:ContaDisabilita | Should -Be 0
        }
    }

    Context 'la migrazione delle modifiche locali di config (D53, punto 3)' {
        It 'sogliaQuotaSettimanale 0.85 a mano in limiti.json: dopo l aggiornamento vale ancora 0.85 e il file e pulito' {
            $f = Join-Path $script:S.Copia 'config/limiti.json'
            ((Get-Content $f -Raw) -match '"sogliaQuotaSettimanale": 0\.70') | Should -BeTrue
            Set-Content $f ((Get-Content $f -Raw) -replace '"sogliaQuotaSettimanale": 0\.70', '"sogliaQuotaSettimanale": 0.85')
            $h = Add-CommitOrigine $script:S 'Merged PR 1601: Nuova'
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'aggiornato'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $h
            Invoke-G $script:S.Copia 'status', '--porcelain' | Should -BeNullOrEmpty
            (Invoke-G $script:S.Copia 'show', 'HEAD:config/limiti.json') | Should -Match '0\.70'
            $i = Get-Impostazioni $script:S.Dati
            $i.Limiti.sogliaQuotaSettimanale | Should -Be 0.85
            @($i.Limiti.PSObject.Properties).Count | Should -Be 1
            (Get-Config -Radice $script:S.Copia -CartellaDati $script:S.Dati).Limiti.sogliaQuotaSettimanale | Should -Be 0.85
        }
        It 'migra anche supervisore.json, e un override gia presente non si sovrascrive' {
            $limiti = Join-Path $script:S.Copia 'config/limiti.json'
            Set-Content $limiti ((Get-Content $limiti -Raw) -replace '"sogliaQuotaSettimanale": 0\.70', '"sogliaQuotaSettimanale": 0.85')
            $sup = Join-Path $script:S.Copia 'config/supervisore.json'
            Set-Content $sup ((Get-Content $sup -Raw) -replace '"diagnosiAlGiorno": 3', '"diagnosiAlGiorno": 1')
            Set-File $script:S.Dati 'impostazioni.json' '{ "limiti": { "sogliaQuotaSettimanale": 0.9 } }'
            Add-CommitOrigine $script:S 'Merged PR 1602: Nuova' | Out-Null
            Invoke-Giro $script:S | Out-Null
            Invoke-G $script:S.Copia 'status', '--porcelain' | Should -BeNullOrEmpty
            $i = Get-Impostazioni $script:S.Dati
            $i.Limiti.sogliaQuotaSettimanale | Should -Be 0.9
            $i.Supervisore.diagnosiAlGiorno | Should -Be 1
        }
        It 'la migrazione e definitiva: se l aggiornamento fallisce il file resta ripristinato (la versione di prima ha gia D53) e l override resta' {
            $f = Join-Path $script:S.Copia 'config/limiti.json'
            Set-Content $f ((Get-Content $f -Raw) -replace '"sogliaQuotaSettimanale": 0\.70', '"sogliaQuotaSettimanale": 0.85')
            Add-CommitOrigine $script:S 'Merged PR 1603: Rotta' @{ 'setup/Install-Attrezzi.ps1' = "exit 1`n" } | Out-Null
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'fallitoTornatoIndietro'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            Invoke-G $script:S.Copia 'status', '--porcelain' | Should -BeNullOrEmpty
            (Get-Content $f -Raw) | Should -Match '0\.70'
            (Get-Impostazioni $script:S.Dati).Limiti.sogliaQuotaSettimanale | Should -Be 0.85
        }
        It 'un limiti.json modificato con un JSON rotto non si migra: modificheLocali e niente di perso' {
            $f = Join-Path $script:S.Copia 'config/limiti.json'
            Set-Content $f '{ rotto'
            Add-CommitOrigine $script:S 'Merged PR 1604: Nuova' | Out-Null
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'modificheLocali'
            $r.ultimoEsito.errore | Should -Match 'non sono un JSON valido'
            (Get-Content $f -Raw) | Should -Match 'rotto'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            $global:ContaAbilita | Should -Be $global:ContaDisabilita
        }
    }

    Context 'i requisiti della versione nuova (D53, punto 5)' {
        It 'una versione nuova che chiede piu di quanto c e non si installa, e lo stato dice cosa serve' {
            Add-CommitOrigine $script:S 'Merged PR 1701: Chiede di piu' @{ 'config/requisiti.json' = '{ "claude": "9.0", "powershell": "7.7", "az": "2.87" }' } | Out-Null
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'requisitiMancanti'
            @($r.ultimoEsito.elenco).Count | Should -Be 1
            $r.ultimoEsito.elenco[0].nome | Should -Be 'claude'; $r.ultimoEsito.elenco[0].richiesta | Should -Be '9.0'; $r.ultimoEsito.elenco[0].trovata | Should -Be '2.1.328'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            $global:ContaDisabilita | Should -Be 0
        }
        It 'si legge il file della versione nuova, non quello della copia: il requisito che c era e stato tolto non pesa piu' {
            Add-CommitOrigine $script:S 'Merged PR 1702: Altro' @{ 'note/x.txt' = 'x' } | Out-Null
            Invoke-G $script:S.Lavoro 'rm', '-q', 'config/requisiti.json' | Out-Null
            Invoke-G $script:S.Lavoro 'commit', '-q', '-m', 'Merged PR 1703: senza requisiti' | Out-Null; Invoke-G $script:S.Lavoro 'push', 'origin', 'main' | Out-Null
            $h2 = Invoke-G $script:S.Lavoro 'rev-parse', 'HEAD'
            Mock Get-VersioniInstallate { @{ claude = $null; powershell = '5.1'; az = $null } } -ModuleName Aggiornamento
            Invoke-Giro $script:S | Out-Null
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $h2
        }
        It 'un programma che non risponde e un requisito mancante, con "non e installato"' {
            Mock Get-VersioniInstallate { @{ claude = $null; powershell = '7.7.0'; az = '2.87.0' } } -ModuleName Aggiornamento
            Add-CommitOrigine $script:S 'Merged PR 1704: Nuova' | Out-Null
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'requisitiMancanti'
            $r.ultimoEsito.elenco[0].nome | Should -Be 'claude'
        }
        It 'un requisiti.json illegibile della versione nuova e un errore, non un via libera' {
            Add-CommitOrigine $script:S 'Merged PR 1705: Rotto' @{ 'config/requisiti.json' = '{ non json' } | Out-Null
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'errore'
            $r.ultimoEsito.errore | Should -Match 'requisiti.json'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
        }
    }

    Context 'le sessioni degli agenti (D53, punto 4)' {
        BeforeEach {
            $script:H = Add-CommitOrigine $script:S 'Merged PR 1801: Nuova'
            Set-File $script:S.Dati 'stato.json' '{ "321": { "sessione": { "id": "s1", "ruolo": "dev" } } }'
        }
        It 'con una sessione in corso aspetta, e lo scrive con da quando' {
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'inAttesaSessioni'
            $r.ultimoEsito.sessioni | Should -Be 1
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            $global:ContaDisabilita | Should -Be 0
            (ConvertTo-DataUtc $r.ultimoEsito.da) | Should -Be $script:Ora
        }
        It 'l attesa conta dal primo giro, non da ogni giro; passate le ore lo dice nello stato e su Telegram una volta sola' {
            Invoke-Giro $script:S | Out-Null
            $r = Invoke-Giro $script:S $script:Ora.AddHours(2)
            (ConvertTo-DataUtc $r.ultimoEsito.da) | Should -Be $script:Ora
            $r.ultimoEsito.oltreSoglia | Should -BeFalse
            $script:Inviati.Count | Should -Be 0
            $r = Invoke-Giro $script:S $script:Ora.AddHours(7)
            $r.ultimoEsito.oltreSoglia | Should -BeTrue
            $script:Inviati.Count | Should -Be 1
            $script:Inviati[0][0] | Should -Be 'attesa'; $script:Inviati[0][1].Ore | Should -Be 6
            Invoke-Giro $script:S $script:Ora.AddHours(8) | Out-Null
            $script:Inviati.Count | Should -Be 1
            (Get-StatoAgg $script:S).attesaSegnalata | Should -BeTrue
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
        }
        It 'finite le sessioni aggiorna al giro dopo, senza aspettare il prossimo controllo con fetch' {
            Invoke-Giro $script:S | Out-Null
            Remove-Item (Join-Path $script:S.Dati 'stato.json')
            Invoke-Giro $script:S $script:Ora.AddMinutes(5) | Out-Null
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:H
            (Get-StatoAgg $script:S).attesaSegnalata | Should -BeFalse
        }
        It 'un giro dello smistatore in corso (anche senza sessioni nello stato) tiene ferma la copia' {
            Remove-Item (Join-Path $script:S.Dati 'stato.json')
            Mock Get-ProcessiSmistatoreRadice { @([pscustomobject]@{ ProcessId = 7 }) } -ModuleName Aggiornamento
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'inAttesaSessioni'
            $r.ultimoEsito.processi | Should -Be 1
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
        }
        It 'una sessione che parte fra la decisione e la disabilitazione dell attivita: ricontrolla, riabilita e aspetta' {
            Remove-Item (Join-Path $script:S.Dati 'stato.json')
            $global:Chiamate = 0
            Mock Get-OccupazioneSuite { $global:Chiamate++; [pscustomobject]@{ Sessioni = $(if ($global:Chiamate -ge 2) { 1 } else { 0 }); Processi = 0 } } -ModuleName Aggiornamento
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'inAttesaSessioni'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            $global:ContaDisabilita | Should -Be 1; $global:ContaAbilita | Should -Be 1
            (Get-Lanci $script:S).Count | Should -Be 0
        }
    }

    Context 'l aggiornamento automatico spento e la richiesta dalla vista (D53, punti 4 e 8)' {
        BeforeEach { Set-Impostazione -Nome 'aggiornamentoAutomatico' -Valore $false -CartellaDati $script:S.Dati }
        It 'senza richiesta non aggiorna; con la richiesta aggiorna e la richiesta si chiude' {
            $h = Add-CommitOrigine $script:S 'Merged PR 1901: Nuova'
            Invoke-Giro $script:S | Out-Null
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            Write-RichiestaAggiornamento -CartellaDati $script:S.Dati
            Test-Path (Get-PercorsoRichiestaAggiornamento $script:S.Dati) | Should -BeTrue
            Invoke-Giro $script:S $script:Ora.AddMinutes(5) | Out-Null
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $h
            Test-Path (Get-PercorsoRichiestaAggiornamento $script:S.Dati) | Should -BeFalse
        }
        It 'la richiesta forza il controllo con fetch anche prima dei minuti' {
            Invoke-Giro $script:S | Out-Null
            $h = Add-CommitOrigine $script:S 'Merged PR 1902: Nuova'
            Write-RichiestaAggiornamento -CartellaDati $script:S.Dati
            Invoke-Giro $script:S $script:Ora.AddMinutes(2) | Out-Null
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $h
        }
        It 'se aspetta le sessioni la richiesta resta, e al giro dopo che le sessioni sono finite aggiorna' {
            $h = Add-CommitOrigine $script:S 'Merged PR 1903: Nuova'
            Set-File $script:S.Dati 'stato.json' '{ "1": { "sessione": { "id": "s" } } }'
            Write-RichiestaAggiornamento -CartellaDati $script:S.Dati
            Invoke-Giro $script:S | Out-Null
            Test-Path (Get-PercorsoRichiestaAggiornamento $script:S.Dati) | Should -BeTrue
            Remove-Item (Join-Path $script:S.Dati 'stato.json')
            Invoke-Giro $script:S $script:Ora.AddMinutes(5) | Out-Null
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $h
            Test-Path (Get-PercorsoRichiestaAggiornamento $script:S.Dati) | Should -BeFalse
        }
        It 'una richiesta senza niente di nuovo si chiude lo stesso' {
            Write-RichiestaAggiornamento -CartellaDati $script:S.Dati
            Invoke-Giro $script:S | Out-Null
            Test-Path (Get-PercorsoRichiestaAggiornamento $script:S.Dati) | Should -BeFalse
        }
        It 'una richiesta che trova modifiche locali si chiude con quell esito: va ripetuta dopo aver sistemato' {
            Add-CommitOrigine $script:S 'Merged PR 1904: Nuova' | Out-Null
            Set-File $script:S.Copia 'appunti.txt' 'miei'
            Write-RichiestaAggiornamento -CartellaDati $script:S.Dati
            (Invoke-Giro $script:S).ultimoEsito.esito | Should -Be 'modificheLocali'
            Test-Path (Get-PercorsoRichiestaAggiornamento $script:S.Dati) | Should -BeFalse
        }
    }

    Context 'il canale (D53, punto 1)' {
        BeforeEach {
            Invoke-G $script:S.Lavoro 'branch', 'develop' | Out-Null
            Invoke-G $script:S.Lavoro 'push', '-q', 'origin', 'develop' | Out-Null
            Invoke-G $script:S.Copia 'fetch', '-q', 'origin' | Out-Null
        }
        It 'senza impostazione segue il ramo gia estratto se e develop' {
            Invoke-G $script:S.Copia 'checkout', '-q', '-b', 'develop', 'origin/develop' | Out-Null
            Invoke-G $script:S.Lavoro 'checkout', '-q', 'develop' | Out-Null
            Set-File $script:S.Lavoro 'solo-develop.txt' 'd'; Invoke-G $script:S.Lavoro 'add', '-A' | Out-Null
            Invoke-G $script:S.Lavoro 'commit', '-q', '-m', 'Merged PR 2001: su develop' | Out-Null; Invoke-G $script:S.Lavoro 'push', '-q', 'origin', 'develop' | Out-Null
            $hd = Invoke-G $script:S.Lavoro 'rev-parse', 'HEAD'
            Invoke-G $script:S.Lavoro 'checkout', '-q', 'main' | Out-Null
            $r = Invoke-Giro $script:S
            $r.canale | Should -Be 'develop'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $hd
            Invoke-G $script:S.Copia 'branch', '--show-current' | Should -Be 'develop'
        }
        It 'con un ramo di lavoro estratto il canale e main: se e un fast-forward passa a main' {
            Invoke-G $script:S.Copia 'checkout', '-q', '-b', 'feature/mio', 'origin/main' | Out-Null
            $h = Add-CommitOrigine $script:S 'Merged PR 2002: su main'
            $r = Invoke-Giro $script:S
            $r.canale | Should -Be 'main'
            Invoke-G $script:S.Copia 'branch', '--show-current' | Should -Be 'main'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $h
        }
        It 'il canale delle impostazioni vince sul ramo estratto' {
            Invoke-G $script:S.Copia 'checkout', '-q', '-b', 'develop', 'origin/develop' | Out-Null
            Set-Impostazione -Nome 'canale' -Valore 'main' -CartellaDati $script:S.Dati
            $h = Add-CommitOrigine $script:S 'Merged PR 2003: su main'
            $r = Invoke-Giro $script:S
            $r.canale | Should -Be 'main'
            Invoke-G $script:S.Copia 'branch', '--show-current' | Should -Be 'main'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $h
            $r.installata.canale | Should -Be 'main'
        }
        It 'se non e un fast-forward dal ramo estratto al canale non cambia ramo' {
            Invoke-G $script:S.Copia 'checkout', '-q', '-b', 'feature/mio', 'origin/main' | Out-Null
            Set-File $script:S.Copia 'mio.txt' 'm'; Invoke-G $script:S.Copia 'add', '-A' | Out-Null; Invoke-G $script:S.Copia 'commit', '-q', '-m', 'locale' | Out-Null
            Add-CommitOrigine $script:S 'Merged PR 2004: su main' | Out-Null
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'divergente'
            Invoke-G $script:S.Copia 'branch', '--show-current' | Should -Be 'feature/mio'
        }
        It 'un aggiornamento fallito dopo il cambio di ramo torna al ramo e al commit di prima' {
            Invoke-G $script:S.Copia 'checkout', '-q', '-b', 'develop', 'origin/develop' | Out-Null
            Set-Impostazione -Nome 'canale' -Valore 'main' -CartellaDati $script:S.Dati
            Add-CommitOrigine $script:S 'Merged PR 2005: rotta' @{ 'setup/Install-Attrezzi.ps1' = "exit 1`n" } | Out-Null
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'fallitoTornatoIndietro'
            Invoke-G $script:S.Copia 'branch', '--show-current' | Should -Be 'develop'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            Invoke-G $script:S.Copia 'status', '--porcelain' | Should -BeNullOrEmpty
        }
    }

    Context 'se la verifica fallisce torna indietro (D53, punto 6)' {
        It 'installazione che esce con errore: la copia torna al commit di prima, si reinstalla la versione di prima, il commit e scartato e Telegram lo dice' {
            $rotto = Add-CommitOrigine $script:S 'Merged PR 2101: Rotta' @{ 'setup/Install-Attrezzi.ps1' = "Add-Content '$($script:S.Dati.Replace('\', '/'))/lanci.log' 'install-rotta'`nexit 1`n" }
            $r = Invoke-Giro $script:S
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            Invoke-G $script:S.Copia 'status', '--porcelain' | Should -BeNullOrEmpty
            $r.ultimoEsito.esito | Should -Be 'fallitoTornatoIndietro'
            $r.ultimoEsito.commitScartato | Should -Be $rotto
            $r.ultimoEsito.errore | Should -Match 'codice 1'
            $r.scartato | Should -Be $rotto
            $lanci = Get-Lanci $script:S
            $lanci | Should -Contain 'install-rotta'
            # l'ultimo lancio e la reinstallazione della versione di prima, fatta dalla copia gia tornata indietro
            $lanci[-1] | Should -Match '^install .*copia.setup Regole=True Hook=True Pianificazione=True'
            @($lanci | Where-Object { $_ -like 'giro*' }).Count | Should -Be 0
            $global:ContaAbilita | Should -Be 1
            $script:Inviati.Count | Should -Be 1
            $script:Inviati[0][0] | Should -Be 'fallito'
            $script:Inviati[0][1].A | Should -Be $rotto.Substring(0, 7)
            $script:Inviati[0][1].Errore | Should -Match 'codice 1'
        }
        It 'giro di prova dello smistatore che esce con errore: stesso ritorno indietro' {
            $rotto = Add-CommitOrigine $script:S 'Merged PR 2102: Giro rotto' @{ 'src/Smistatore.ps1' = "exit 2`n" }
            $r = Invoke-Giro $script:S
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            $r.ultimoEsito.esito | Should -Be 'fallitoTornatoIndietro'
            $r.ultimoEsito.errore | Should -Match 'giro di prova.*codice 2'
            $r.scartato | Should -Be $rotto
        }
        It 'un processo che non finisce entro il tempo conta come un fallimento' {
            InModuleScope Aggiornamento { $script:TimeoutInstallazioneSecondi = 3 }
            Add-CommitOrigine $script:S 'Merged PR 2103: Lenta' @{ 'setup/Install-Attrezzi.ps1' = "Start-Sleep -Seconds 60`n" } | Out-Null
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'fallitoTornatoIndietro'
            $r.ultimoEsito.errore | Should -Match 'non e finito entro 3 secondi'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
        }
        It 'il commit scartato non si riprova ai giri dopo; quando origine va oltre si riprova' {
            $rotto = Add-CommitOrigine $script:S 'Merged PR 2104: Rotta' @{ 'setup/Install-Attrezzi.ps1' = "exit 1`n" }
            Invoke-Giro $script:S | Out-Null
            $lanciPrima = (Get-Lanci $script:S).Count
            $r = Invoke-Giro $script:S $script:Ora.AddMinutes(40)
            (Get-Lanci $script:S).Count | Should -Be $lanciPrima
            $r.ultimoEsito.esito | Should -Be 'fallitoTornatoIndietro'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            $script:Inviati.Count | Should -Be 1
            # il commit che sistema: origine e andata oltre
            $buono = Add-CommitOrigine $script:S 'Merged PR 2105: Sistemata' @{ 'setup/Install-Attrezzi.ps1' = $script:S.StubInstalla }
            $r = Invoke-Giro $script:S $script:Ora.AddMinutes(80)
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $buono
            $r.ultimoEsito.esito | Should -Be 'aggiornato'
        }
        It 'se la reinstallazione della versione di prima fallisce a sua volta lo dice nell errore, e la copia e comunque tornata' {
            $dati = $script:S.Dati.Replace('\', '/')
            # il commit di prima esce con 1 solo se il file "rompi" c'e: cosi la reinstallazione fallisce dopo il rollback
            Set-File $script:S.Lavoro 'setup/Install-Attrezzi.ps1' "if (Test-Path '$dati/rompi') { exit 1 }`n"
            Invoke-G $script:S.Lavoro 'add', '-A' | Out-Null; Invoke-G $script:S.Lavoro 'commit', '-q', '-m', 'Merged PR 2106: base che si puo rompere' | Out-Null
            Invoke-G $script:S.Lavoro 'push', '-q', 'origin', 'main' | Out-Null
            Invoke-G $script:S.Copia 'pull', '-q', '--ff-only' | Out-Null
            $base = Invoke-G $script:S.Copia 'rev-parse', 'HEAD'
            Add-CommitOrigine $script:S 'Merged PR 2107: nuova' | Out-Null
            Set-Content "$dati/rompi" 'x'
            $r = Invoke-Giro $script:S
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $base
            $r.ultimoEsito.errore | Should -Match 'reinstallazione della versione di prima non e riuscita'
        }
    }

    Context 'le correzioni della revisione (D53)' {
        It 'C3: dopo un fallimento il giro automatico non riprova, ma Aggiorna adesso si' {
            $rotto = Add-CommitOrigine $script:S 'Merged PR 3001: Rotta' @{ 'setup/Install-Attrezzi.ps1' = "exit 1`n" }
            (Invoke-Giro $script:S).ultimoEsito.esito | Should -Be 'fallitoTornatoIndietro'
            $n = (Get-Lanci $script:S).Count
            Invoke-Giro $script:S $script:Ora.AddMinutes(40) | Out-Null
            (Get-Lanci $script:S).Count | Should -Be $n
            Write-RichiestaAggiornamento -CartellaDati $script:S.Dati
            $r = Invoke-Giro $script:S $script:Ora.AddMinutes(50)
            (Get-Lanci $script:S).Count | Should -BeGreaterThan $n
            $r.ultimoEsito.esito | Should -Be 'fallitoTornatoIndietro'
            $r.scartato | Should -Be $rotto
            Test-Path (Get-PercorsoRichiestaAggiornamento $script:S.Dati) | Should -BeFalse
        }
        It 'C4: con un ramo main locale che origine non contiene non passa al canale e lo dice, senza toccare niente' {
            Set-File $script:S.Copia 'mio.txt' 'm'; Invoke-G $script:S.Copia 'add', '-A' | Out-Null; Invoke-G $script:S.Copia 'commit', '-q', '-m', 'mio su main' | Out-Null
            $mioMain = Invoke-G $script:S.Copia 'rev-parse', 'HEAD'
            Invoke-G $script:S.Copia 'checkout', '-q', '-b', 'feature/x', $script:S.Base0 | Out-Null
            Add-CommitOrigine $script:S 'Merged PR 3002: Nuova' | Out-Null
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'ramoCanaleDivergente'
            Invoke-G $script:S.Copia 'branch', '--show-current' | Should -Be 'feature/x'
            Invoke-G $script:S.Copia 'rev-parse', 'main' | Should -Be $mioMain
            $global:ContaDisabilita | Should -Be 0
        }
        It 'C4: un main locale antenato di origin/main non e un ostacolo, e dopo un fallimento torna dov era' {
            Invoke-G $script:S.Copia 'checkout', '-q', '-b', 'feature/x' | Out-Null
            Add-CommitOrigine $script:S 'Merged PR 3003: Rotta' @{ 'setup/Install-Attrezzi.ps1' = "exit 1`n" } | Out-Null
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'fallitoTornatoIndietro'
            Invoke-G $script:S.Copia 'branch', '--show-current' | Should -Be 'feature/x'
            Invoke-G $script:S.Copia 'rev-parse', 'main' | Should -Be $script:S.Base0
        }
        It 'C5: se il ritorno indietro non riesce l esito e errore con dove e rimasta la copia, mai aggiornato, e parte un avviso urgente' {
            Mock Restore-CopiaPrecedente { throw 'git ha detto di no' } -ModuleName Aggiornamento
            $rotto = Add-CommitOrigine $script:S 'Merged PR 3004: Rotta' @{ 'setup/Install-Attrezzi.ps1' = "exit 1`n" }
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'errore'
            $r.ultimoEsito.copiaLasciataA | Should -Be $rotto
            $r.ultimoEsito.errore | Should -Match "copia lasciata a $rotto"
            $r.ultimoEsito.errore | Should -Match 'git ha detto di no'
            (Get-StatoAgg $script:S).ultimoEsito.esito | Should -Be 'errore'
            @($script:Inviati | Where-Object { $_[0] -eq 'copiaRotta' }).Count | Should -Be 1
            @($script:Inviati | Where-Object { $_[0] -eq 'aggiornato' }).Count | Should -Be 0
            $r.scartato | Should -Be $rotto
            $global:ContaAbilita | Should -Be 1
        }
        It 'C2: un mentore vivo o una diagnosi in corso aspettano come una sessione' {
            Add-CommitOrigine $script:S 'Merged PR 3005: Nuova' | Out-Null
            Set-File $script:S.Dati 'stato.json' '{ "7": { "mentori": [ { "id": "m" } ] } }'
            (Invoke-Giro $script:S).ultimoEsito.esito | Should -Be 'inAttesaSessioni'
            Remove-Item (Join-Path $script:S.Dati 'stato.json')
            Set-File $script:S.Dati 'supervisore.json' '{ "sessioniDiagnosi": [ { "id": "d" } ] }'
            (Invoke-Giro $script:S $script:Ora.AddMinutes(5)).ultimoEsito.esito | Should -Be 'inAttesaSessioni'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
        }
        It 'B2: un supervisore della copia nuova che esce con errore e un fallimento della verifica' {
            Add-CommitOrigine $script:S 'Merged PR 3006: Supervisore rotto' @{ 'src/Supervisore.ps1' = "exit 4`n" } | Out-Null
            $r = Invoke-Giro $script:S
            $r.ultimoEsito.esito | Should -Be 'fallitoTornatoIndietro'
            $r.ultimoEsito.errore | Should -Match 'supervisore e uscito con codice 4'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
        }
    }

    Context '-WhatIf non scrive niente (D53, punto 4 e il modello del supervisore)' {
        It 'dice cosa farebbe e lascia stato, copia, refs di git, attivita e richiesta come erano' {
            Invoke-Giro $script:S | Out-Null
            Add-CommitOrigine $script:S 'Merged PR 2201: Nuova' | Out-Null
            Invoke-G $script:S.Copia 'fetch', '-q', 'origin' | Out-Null
            Write-RichiestaAggiornamento -CartellaDati $script:S.Dati
            $hashStato = (Get-FileHash "$($script:S.Dati)/aggiornamento.json").Hash
            $refs = Invoke-G $script:S.Copia 'for-each-ref'
            $script:Provato = @()
            $r = Invoke-Giro $script:S $script:Ora.AddMinutes(1) -WhatIf
            ($script:Provato -join "`n") | Should -Match 'avanzerei main da'
            Invoke-G $script:S.Copia 'rev-parse', 'HEAD' | Should -Be $script:S.Base0
            (Get-FileHash "$($script:S.Dati)/aggiornamento.json").Hash | Should -Be $hashStato
            Invoke-G $script:S.Copia 'for-each-ref' | Should -Be $refs
            Test-Path (Get-PercorsoRichiestaAggiornamento $script:S.Dati) | Should -BeTrue
            $global:ContaDisabilita | Should -Be 0
            @(Get-Lanci $script:S).Count | Should -Be 0
            $script:Inviati.Count | Should -Be 0
        }
        It 'il controllo con fetch dovuto si dice e non si fa: i refs di origine non cambiano' {
            Add-CommitOrigine $script:S 'Merged PR 2202: Nuova' | Out-Null
            $refs = Invoke-G $script:S.Copia 'for-each-ref'
            Invoke-Giro $script:S -WhatIf | Out-Null
            ($script:Provato -join "`n") | Should -Match 'git fetch origin'
            Invoke-G $script:S.Copia 'for-each-ref' | Should -Be $refs
            Test-Path "$($script:S.Dati)/aggiornamento.json" | Should -BeFalse
        }
    }
}
