BeforeAll {
    # D53: i moduli che chiamano Get-Config (Card, MemoriaRepo, Sessioni) leggono impostazioni.json dalla cartella dati: non quella vera di chi lancia i test.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    foreach ($m in 'Comune', 'Config', 'Ado', 'Worktree', 'Memoria', 'MemoriaRepo') { Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Global -Force }

    $env:GIT_AUTHOR_NAME = 'Test'; $env:GIT_AUTHOR_EMAIL = 'test@example.invalid'
    $env:GIT_COMMITTER_NAME = 'Test'; $env:GIT_COMMITTER_EMAIL = 'test@example.invalid'

    function g([string]$Cartella, [string[]]$Argomenti) {
        $out = & git -C $Cartella @Argomenti 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($Argomenti -join ' ') fallito: $out" }
        $out
    }
    function Lezione($Ruolo, $N, $Situazione = 's') {
        ConvertTo-TestoLezione -Id ('{0}-{1:000}' -f $Ruolo, $N) -Situazione $Situazione -CosaFare 'c' -Perche 'perché' -Card '12'
    }
    # Un commit su un ramo di origin passando da un altro clone: la copia sorgente resta indietro, come nella realta.
    function Add-SuOrigin([string]$Ramo, [string]$Percorso, [string]$Testo, [switch]$NuovoDaDevelop) {
        $altra = Join-Path $script:Base ('altra-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        & git clone $script:Origin $altra 2>&1 | Out-Null
        if ($NuovoDaDevelop) { g $altra 'checkout', '-b', $Ramo, 'origin/develop' | Out-Null } else { g $altra 'checkout', $Ramo | Out-Null }
        $p = Join-Path $altra $Percorso
        New-Item -ItemType Directory -Force (Split-Path -Parent $p) | Out-Null
        [IO.File]::WriteAllText($p, $Testo, [Text.UTF8Encoding]::new($false))
        g $altra 'add', '-A' | Out-Null
        g $altra 'commit', '-m', "scrive $Percorso" | Out-Null
        g $altra 'push', 'origin', $Ramo | Out-Null
    }
    function Add-SuDevelop([string]$Percorso, [string]$Testo) { Add-SuOrigin 'develop' $Percorso $Testo }
    function Add-InProva([string]$Percorso, [string]$Testo) {
        $esiste = (& git -C $script:Origin branch --list 'memoria/in-prova' 2>&1 | Out-String).Trim() -ne ''
        if ($esiste) { Add-SuOrigin 'memoria/in-prova' $Percorso $Testo } else { Add-SuOrigin 'memoria/in-prova' $Percorso $Testo -NuovoDaDevelop }
    }
    function Get-Testa([string]$Ref) { (g $script:Origin 'rev-parse', $Ref) }
}

Describe 'MemoriaRepo' {
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

        $global:PrFinte = @()
        # Il default fallisce: una chiamata con progetto, repo o ramo sbagliati non passa per caso.
        Mock Get-AdoPrDelRamo -ModuleName MemoriaRepo { throw "Get-AdoPrDelRamo chiamata con parametri inattesi: $Progetto / $Repo / $Ramo" }
        Mock Get-AdoPrDelRamo -ModuleName MemoriaRepo { $global:PrFinte } -ParameterFilter {
            $Progetto -eq 'DevOps.Agents' -and $Repo -eq 'DevOps.Agents' -and $Ramo -eq 'memoria/in-prova' }
    }
    AfterAll { Remove-Variable PrFinte -Scope Global -ErrorAction SilentlyContinue }

    Context 'lo schema dei percorsi' {
        It 'ramo, riferimento e percorso del file hanno un posto solo' {
            Get-RamoMemoria | Should -Be 'memoria/in-prova'
            Get-RifInProva | Should -Be 'origin/memoria/in-prova'
            Get-PercorsoMemoria -Ruolo 'dev' -Nome 'comune' | Should -Be 'memoria/dev/comune.md'
            Get-CartellaMemoria | Should -Be 'memoria'
            Get-CartellaMemoria -Ruolo 'dev' | Should -Be 'memoria/dev'
        }
    }

    Context 'Get-TestoGit' {
        It 'legge in UTF-8: le lettere accentate restano tali' {
            Add-SuDevelop 'memoria/dev/comune.md' ((Lezione dev 1) + "`n")
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            Get-TestoGit $script:Sorgente 'origin/develop' 'memoria/dev/comune.md' | Should -BeLike '*- Perché: perché*'
        }

        It 'un file che non c e e null' {
            Get-TestoGit $script:Sorgente 'origin/develop' 'memoria/dev/non-c-e.md' | Should -BeNullOrEmpty
        }
    }

    Context 'Get-MemoriaDelRuolo' {
        BeforeEach {
            Add-SuDevelop 'memoria/dev/comune.md' ((Lezione dev 1 'stabile comune') + "`n")
            Add-SuDevelop 'memoria/dev/Acme.AI.md' ((Lezione dev 2 'stabile repo') + "`n")
        }

        It 'con una PR attiva e il ramo restituisce i testi develop e in prova di comune e del repo' {
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 1 'stabile comune') + "`n`n" + (Lezione dev 3 'in prova') + "`n")
            $global:PrFinte = @([pscustomobject]@{ Id = 7; Stato = 'active'; CommitSorgente = (Get-Testa 'memoria/in-prova') })
            $r = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI'
            $r.Disponibile | Should -BeTrue
            $r.InProvaUsato | Should -BeTrue
            @($r.Motivi).Count | Should -Be 0
            @($r.File | ForEach-Object Nome) -join ',' | Should -Be 'comune,Acme.AI'
            $comune = $r.File | Where-Object Nome -eq 'comune'
            $comune.Develop | Should -BeLike '*stabile comune*'
            $comune.Develop | Should -Not -BeLike '*in prova*'
            $comune.InProva | Should -BeLike '*dev-003*'
            ($r.File | Where-Object Nome -eq 'Acme.AI').Develop | Should -BeLike '*stabile repo*'
            Should -Invoke Get-AdoPrDelRamo -ModuleName MemoriaRepo -Times 1 -Exactly
        }

        It 'senza una PR attiva il ramo in prova non si legge: una PR abbandonata vuol dire lezioni bocciate' {
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 3 'bocciata') + "`n")
            $global:PrFinte = @([pscustomobject]@{ Id = 7; Stato = 'abandoned'; CommitSorgente = (Get-Testa 'memoria/in-prova') })
            $r = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI'
            $r.Disponibile | Should -BeTrue
            $r.InProvaUsato | Should -BeFalse
            @($r.Motivi).Count | Should -Be 0 -Because 'non e un ripiego: senza PR attiva non ci sono lezioni in prova'
            @($r.File | Where-Object InProva).Count | Should -Be 0
            ($r.File | Where-Object Nome -eq 'comune').Develop | Should -BeLike '*stabile comune*'
        }

        It 'se le PR non si leggono usa solo develop e lo dice, senza lanciare' {
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 3 'non confermata') + "`n")
            Mock Get-AdoPrDelRamo -ModuleName MemoriaRepo { throw 'rete giu' } -ParameterFilter { $Ramo -eq 'memoria/in-prova' }
            $r = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI'
            $r.Disponibile | Should -BeTrue
            $r.InProvaUsato | Should -BeFalse
            ($r.Motivi -join ' ') | Should -BeLike '*rete giu*'
            @($r.File | Where-Object InProva).Count | Should -Be 0
        }

        It 'una PR attiva senza il ramo su origin vale solo develop, e lo dice' {
            $global:PrFinte = @([pscustomobject]@{ Id = 7; Stato = 'active'; CommitSorgente = $null })
            $r = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI'
            $r.InProvaUsato | Should -BeFalse
            ($r.Motivi -join ' ') | Should -BeLike '*memoria/in-prova*'
        }

        It 'se il fetch fallisce legge i riferimenti che ha e lo dice' {
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            g $script:Sorgente 'remote', 'set-url', 'origin', (Join-Path $script:Base 'non-esiste.git') | Out-Null
            $r = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI'
            $r.Disponibile | Should -BeTrue
            ($r.Motivi -join ' ') | Should -BeLike '*fetch*'
            ($r.File | Where-Object Nome -eq 'comune').Develop | Should -BeLike '*stabile comune*'
        }

        It 'se develop non si legge non c e memoria: nessun file, un motivo, nessun errore' {
            $vuota = Join-Path $script:Base 'vuota'
            New-Item -ItemType Directory $vuota | Out-Null
            $r = Get-MemoriaDelRuolo -Radice $vuota -Ruolo 'dev' -Repo 'Acme.AI'
            $r.Disponibile | Should -BeFalse
            $r.InProvaUsato | Should -BeFalse
            @($r.File).Count | Should -Be 0
            @($r.Motivi).Count | Should -BeGreaterThan 0
        }

        It 'una radice che non esiste non lancia' {
            $r = Get-MemoriaDelRuolo -Radice (Join-Path $script:Base 'niente') -Ruolo 'dev' -Repo 'Acme.AI'
            $r.Disponibile | Should -BeFalse
            @($r.Motivi).Count | Should -BeGreaterThan 0
        }

        It 'per comune c e un solo file' {
            $r = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'comune'
            @($r.File).Count | Should -Be 1
            $r.File[0].Nome | Should -Be 'comune'
        }

        # Il fetch e le PR si pagano una volta ogni 4 minuti per radice: uno smistatore lancia fino a una sessione per card,
        # la vista legge ogni ruolo e ogni repo.
        It 'piu letture della stessa radice fanno un fetch e una lettura delle PR sole: ruoli e repo diversi condividono la cache' {
            Mock Get-AdoPrDelRamo -ModuleName MemoriaRepo { $global:PrFinte } -ParameterFilter { $Ramo -eq 'memoria/in-prova' }
            $a = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI'
            $b = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'reviewer' -Repo 'Altro.Repo'
            Should -Invoke Get-AdoPrDelRamo -ModuleName MemoriaRepo -Times 1 -Exactly
            ($a.File | Where-Object Nome -eq 'comune').Develop | Should -BeLike '*stabile comune*'
            $b.Disponibile | Should -BeTrue
        }

        It 'la cache non fa vedere il remoto cambiato prima di 4 minuti, e dopo si rilegge' {
            $global:OraFinta = [datetime]::new(2026, 11, 20, 10, 0, 0, [DateTimeKind]::Utc)
            Mock Get-AdessoMemoria -ModuleName MemoriaRepo { $global:OraFinta }
            [void](Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI')
            Add-SuDevelop 'memoria/dev/comune.md' ((Lezione dev 1 'stabile comune') + "`n`n" + (Lezione dev 9 'arrivata dopo') + "`n")
            $global:OraFinta = $global:OraFinta.AddSeconds(239)
            $r = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI'
            ($r.File | Where-Object Nome -eq 'comune').Develop | Should -Not -BeLike '*arrivata dopo*'
            $global:OraFinta = $global:OraFinta.AddSeconds(2)
            $r = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI'
            ($r.File | Where-Object Nome -eq 'comune').Develop | Should -BeLike '*arrivata dopo*'
        }

        It 'radici diverse hanno cache diverse' {
            $altra = Join-Path $script:Base 'altra-radice'
            & git clone $script:Origin $altra 2>&1 | Out-Null
            [void](Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI')
            [void](Get-MemoriaDelRuolo -Radice $altra -Ruolo 'dev' -Repo 'Acme.AI')
            Should -Invoke Get-AdoPrDelRamo -ModuleName MemoriaRepo -Times 2 -Exactly
        }

        It 'il fallimento del fetch e delle PR resta nei motivi di ogni lettura servita dalla cache' {
            Mock Get-AdoPrDelRamo -ModuleName MemoriaRepo { throw 'rete giu' } -ParameterFilter { $Ramo -eq 'memoria/in-prova' }
            $a = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI'
            $b = Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'reviewer' -Repo 'Acme.AI'
            Should -Invoke Get-AdoPrDelRamo -ModuleName MemoriaRepo -Times 1 -Exactly
            ($a.Motivi -join ' ') | Should -BeLike '*rete giu*'
            ($b.Motivi -join ' ') | Should -BeLike '*rete giu*'
        }

        It 'Get-PrMemoria non usa la cache: chi scrive deve vedere lo stato di adesso' {
            [void](Get-MemoriaDelRuolo -Radice $script:Sorgente -Ruolo 'dev' -Repo 'Acme.AI')
            [void](Get-PrMemoria)
            [void](Get-PrMemoria)
            Should -Invoke Get-AdoPrDelRamo -ModuleName MemoriaRepo -Times 3 -Exactly
        }
    }

    Context 'Get-BaseScrittura' {
        It 'con una PR attiva riparte dal ramo in prova, senza forzare' {
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 1) + "`n")
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            $global:PrFinte = @([pscustomobject]@{ Id = 7; Stato = 'active'; CommitSorgente = (Get-Testa 'memoria/in-prova') })
            $b = Get-BaseScrittura -Cartella $script:Sorgente
            $b.Base | Should -Be 'origin/memoria/in-prova'
            $b.Forza | Should -BeFalse
            $b.Pr.Id | Should -Be 7
        }

        It 'senza il ramo remoto parte da develop, senza forzare' {
            $b = Get-BaseScrittura -Cartella $script:Sorgente
            $b.Base | Should -Be 'origin/develop'
            $b.Forza | Should -BeFalse
            $b.Pr | Should -BeNullOrEmpty
        }

        It 'se la testa del ramo e gia in develop (PR unita) parte da develop e forza' {
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 1) + "`n")
            g $script:Origin 'update-ref', 'refs/heads/develop', 'memoria/in-prova' | Out-Null
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            $b = Get-BaseScrittura -Cartella $script:Sorgente
            $b.Base | Should -Be 'origin/develop'
            $b.Forza | Should -BeTrue
        }

        It 'con una PR completata che ha la testa come ultimo commit sorgente parte da develop e forza' {
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 1) + "`n")
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            $global:PrFinte = @([pscustomobject]@{ Id = 7; Stato = 'completed'; CommitSorgente = (Get-Testa 'memoria/in-prova') })
            $b = Get-BaseScrittura -Cartella $script:Sorgente
            $b.Base | Should -Be 'origin/develop'
            $b.Forza | Should -BeTrue
        }

        It 'con una PR abbandonata che ha la testa come ultimo commit sorgente parte da develop e forza' {
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 1) + "`n")
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            $global:PrFinte = @([pscustomobject]@{ Id = 7; Stato = 'abandoned'; CommitSorgente = (Get-Testa 'memoria/in-prova') })
            $b = Get-BaseScrittura -Cartella $script:Sorgente
            $b.Base | Should -Be 'origin/develop'
            $b.Forza | Should -BeTrue
        }

        It 'con commit non in develop e nessuna PR che li copra riparte dal ramo: nessuna lezione si butta senza che qualcuno la bocci' {
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 1) + "`n")
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            $b = Get-BaseScrittura -Cartella $script:Sorgente
            $b.Base | Should -Be 'origin/memoria/in-prova'
            $b.Forza | Should -BeFalse
            $b.Pr | Should -BeNullOrEmpty -Because 'la scrittura crea la PR'
        }

        It 'una PR chiusa su un commit piu vecchio della testa non copre i commit nuovi' {
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 1) + "`n")
            $vecchia = Get-Testa 'memoria/in-prova'
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 1) + "`n`n" + (Lezione dev 2) + "`n")
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            $global:PrFinte = @([pscustomobject]@{ Id = 7; Stato = 'abandoned'; CommitSorgente = $vecchia })
            $b = Get-BaseScrittura -Cartella $script:Sorgente
            $b.Base | Should -Be 'origin/memoria/in-prova'
            $b.Forza | Should -BeFalse
        }

        It 'un errore nel leggere le PR si propaga: nessuna base, nessuna scrittura' {
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 1) + "`n")
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            Mock Get-AdoPrDelRamo -ModuleName MemoriaRepo { throw 'rete giu' } -ParameterFilter { $Ramo -eq 'memoria/in-prova' }
            { Get-BaseScrittura -Cartella $script:Sorgente } | Should -Throw '*rete giu*'
        }
    }

    Context 'Get-IntestazioniStoricheRuolo' {
        It 'senza storia di memoria e vuoto' {
            @(Read-Lezioni (Get-IntestazioniStoricheRuolo -Cartella $script:Sorgente -Ruolo 'dev')).Count | Should -Be 0
        }

        It 'vede gli id di develop anche se la lezione e stata tolta dopo' {
            Add-SuDevelop 'memoria/dev/comune.md' ((Lezione dev 5) + "`n")
            Add-SuDevelop 'memoria/dev/comune.md' ((Lezione dev 1) + "`n")
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            Get-ProssimoIdLezione -Ruolo 'dev' -Testi @(Get-IntestazioniStoricheRuolo -Cartella $script:Sorgente -Ruolo 'dev') | Should -Be 'dev-006'
        }

        It 'vede gli id del ramo in prova su origin' {
            Add-InProva 'memoria/dev/comune.md' ((Lezione dev 8) + "`n")
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            Get-ProssimoIdLezione -Ruolo 'dev' -Testi @(Get-IntestazioniStoricheRuolo -Cartella $script:Sorgente -Ruolo 'dev') | Should -Be 'dev-009'
        }

        It 'vede gli id che restano solo nel reflog del ramo locale, ripartito da develop dopo un abbandono' {
            g $script:Sorgente 'checkout', '-b', 'memoria/in-prova' | Out-Null
            New-Item -ItemType Directory -Force (Join-Path $script:Sorgente 'memoria/dev') | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:Sorgente 'memoria/dev/comune.md'), (Lezione dev 4) + "`n")
            g $script:Sorgente 'add', '-A' | Out-Null
            g $script:Sorgente 'commit', '-m', 'lezione poi abbandonata' | Out-Null
            g $script:Sorgente 'checkout', 'develop' | Out-Null
            g $script:Sorgente 'branch', '-f', 'memoria/in-prova', 'origin/develop' | Out-Null
            Get-ProssimoIdLezione -Ruolo 'dev' -Testi @(Get-IntestazioniStoricheRuolo -Cartella $script:Sorgente -Ruolo 'dev') | Should -Be 'dev-005'
        }

        It 'non conta gli id degli altri ruoli' {
            Add-SuDevelop 'memoria/reviewer/comune.md' ((Lezione reviewer 9) + "`n")
            g $script:Sorgente 'fetch', 'origin' | Out-Null
            Get-ProssimoIdLezione -Ruolo 'dev' -Testi @(Get-IntestazioniStoricheRuolo -Cartella $script:Sorgente -Ruolo 'dev') | Should -Be 'dev-001'
        }
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }
