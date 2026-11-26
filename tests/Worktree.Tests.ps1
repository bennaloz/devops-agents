BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Worktree.psm1') -Force

    # git nei test: identita fissa, nessuna configurazione dell'utente, errore se il comando fallisce.
    $env:GIT_AUTHOR_NAME = 'Test'; $env:GIT_AUTHOR_EMAIL = 'test@example.invalid'
    $env:GIT_COMMITTER_NAME = 'Test'; $env:GIT_COMMITTER_EMAIL = 'test@example.invalid'
    function g([string]$Cartella, [string[]]$Argomenti) {
        $out = & git -C $Cartella @Argomenti 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($Argomenti -join ' ') fallito: $out" }
        $out
    }
    function Add-Commit([string]$Cartella, [string]$File, [string]$Testo) {
        Set-Content -LiteralPath (Join-Path $Cartella $File) -Value $Testo
        g $Cartella 'add', '-A' | Out-Null
        g $Cartella 'commit', '-m', "aggiunge $File" | Out-Null
        (g $Cartella 'rev-parse', 'HEAD' | Select-Object -First 1).Trim()
    }
    function Remove-Wt($Voce = $script:Voce, $Id = 42, $Ramo = $script:Wt.Ramo, $Cartella = $script:Wt.Cartella) {
        Remove-WorktreeCard -Voce $Voce -Id $Id -Ramo $Ramo -Cartella $Cartella -RadiceWorktree $script:Radice
    }
    function New-Card($Id, $Titolo, $Tipo = 'User Story') { [pscustomobject]@{ Id = $Id; Titolo = $Titolo; Tipo = $Tipo } }
}

Describe 'Worktree della card' {
    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Origin = Join-Path $base 'origin.git'
        $script:Principale = Join-Path $base 'principale'
        $script:Radice = Join-Path $base '_wt'
        New-Item -ItemType Directory $base, $script:Radice | Out-Null
        & git init --bare -b develop $script:Origin 2>&1 | Out-Null
        & git clone $script:Origin $script:Principale 2>&1 | Out-Null
        g $script:Principale 'checkout', '-b', 'develop' | Out-Null
        $script:Iniziale = Add-Commit $script:Principale 'a.txt' 'uno'
        g $script:Principale 'push', '-u', 'origin', 'develop' | Out-Null
        $script:Voce = [pscustomobject]@{ repo = 'Repo.Prova'; cartella = $script:Principale }
    }

    It 'crea cartella e ramo da origin/develop, non dal develop locale vecchio' {
        # origin va avanti, il develop locale della copia principale resta indietro
        $altra = Join-Path (Split-Path -Parent $script:Principale) 'altra'
        & git clone $script:Origin $altra 2>&1 | Out-Null
        g $altra 'checkout', 'develop' | Out-Null
        $nuovo = Add-Commit $altra 'b.txt' 'due'
        g $altra 'push', 'origin', 'develop' | Out-Null

        $r = New-WorktreeCard -Voce $script:Voce -Card (New-Card 42 'Aggiungi il filtro') -RadiceWorktree $script:Radice

        $r.Cartella | Should -Be (Join-Path $script:Radice 'Repo.Prova\card-42')
        $r.Ramo | Should -Be 'feature/42-aggiungi-il-filtro'
        Test-Path (Join-Path $r.Cartella 'b.txt') | Should -BeTrue
        (g $r.Cartella 'rev-parse', 'HEAD' | Select-Object -First 1).Trim() | Should -Be $nuovo
        (g $r.Cartella 'branch', '--show-current' | Select-Object -First 1).Trim() | Should -Be $r.Ramo
        # la copia principale non si e mossa
        (g $script:Principale 'branch', '--show-current' | Select-Object -First 1).Trim() | Should -Be 'develop'
        (g $script:Principale 'rev-parse', 'develop' | Select-Object -First 1).Trim() | Should -Be $script:Iniziale
    }

    It 'chiamato due volte non fallisce e non crea un secondo ramo' {
        $card = New-Card 42 'Aggiungi il filtro'
        $primo = New-WorktreeCard -Voce $script:Voce -Card $card -RadiceWorktree $script:Radice
        $secondo = New-WorktreeCard -Voce $script:Voce -Card $card -RadiceWorktree $script:Radice
        $secondo.Cartella | Should -Be $primo.Cartella
        $secondo.Ramo | Should -Be $primo.Ramo
        @(g $script:Principale 'branch', '--list', 'feature/*').Count | Should -Be 1
    }

    Context 'card presa in carico da un altro (ramo gia su origin)' {
        BeforeEach {
            # un collega ha lavorato sulla card da un altro PC e ha pubblicato il ramo
            $script:Altra = Join-Path (Split-Path -Parent $script:Principale) 'collega'
            & git clone $script:Origin $script:Altra 2>&1 | Out-Null
            g $script:Altra 'checkout', 'develop' | Out-Null
            function script:Publish-Ramo([string]$Ramo, [string]$File = 'lavoro.txt') {
                g $script:Altra 'checkout', '-B', $Ramo, 'origin/develop' | Out-Null
                $c = Add-Commit $script:Altra $File 'fatto dal collega'
                g $script:Altra 'push', '-f', 'origin', $Ramo | Out-Null
                $c
            }
        }

        It 'ricrea il worktree dal ramo remoto della card, trovato per id anche se il titolo e cambiato' {
            $commit = Publish-Ramo 'feature/42-titolo-di-prima'
            $r = New-WorktreeDaRemoto -Voce $script:Voce -Card (New-Card 42 'Titolo cambiato dopo') -RadiceWorktree $script:Radice
            $r.Cartella | Should -Be (Join-Path $script:Radice 'Repo.Prova\card-42')
            $r.Ramo | Should -Be 'feature/42-titolo-di-prima'
            (g $r.Cartella 'rev-parse', 'HEAD' | Select-Object -First 1).Trim() | Should -Be $commit
            (g $r.Cartella 'branch', '--show-current' | Select-Object -First 1).Trim() | Should -Be 'feature/42-titolo-di-prima'
        }

        It 'non confonde la card 4 con la 42' {
            Publish-Ramo 'feature/42-un-altra' | Out-Null
            $commit = Publish-Ramo 'feature/4-questa' 'q.txt'
            $r = New-WorktreeDaRemoto -Voce $script:Voce -Card (New-Card 4 'Questa') -RadiceWorktree $script:Radice
            $r.Ramo | Should -Be 'feature/4-questa'
            (g $r.Cartella 'rev-parse', 'HEAD' | Select-Object -First 1).Trim() | Should -Be $commit
        }

        It 'una cartella card-42 gia presente ma su un ramo che non e della card 42: si ferma' {
            Publish-Ramo 'feature/42-x' | Out-Null
            g $script:Principale 'fetch', 'origin' | Out-Null
            g $script:Principale 'worktree', 'add', '-b', 'feature/7-altra', (Join-Path $script:Radice 'Repo.Prova\card-42'), 'origin/develop' | Out-Null
            { New-WorktreeDaRemoto -Voce $script:Voce -Card (New-Card 42 'X') -RadiceWorktree $script:Radice } | Should -Throw '*non e della card 42*'
        }

        It 'senza un ramo della card su origin restituisce niente e non crea niente: decide chi chiama' {
            New-WorktreeDaRemoto -Voce $script:Voce -Card (New-Card 42 'X') -RadiceWorktree $script:Radice | Should -BeNullOrEmpty
            Test-Path (Join-Path $script:Radice 'Repo.Prova\card-42') | Should -BeFalse
        }

        It 'con due rami della stessa card su origin si ferma: non sceglie lui' {
            Publish-Ramo 'feature/42-uno' | Out-Null
            Publish-Ramo 'fix/42-due' 'd.txt' | Out-Null
            { New-WorktreeDaRemoto -Voce $script:Voce -Card (New-Card 42 'X') -RadiceWorktree $script:Radice } | Should -Throw '*piu di un ramo*'
        }

        It 'un ramo locale rimasto indietro viene portato al remoto' {
            Publish-Ramo 'feature/42-x' | Out-Null
            g $script:Principale 'fetch', 'origin' | Out-Null
            g $script:Principale 'branch', 'feature/42-x', 'origin/feature/42-x' | Out-Null
            g $script:Altra 'checkout', 'feature/42-x' | Out-Null
            $nuovo = Add-Commit $script:Altra 'altro.txt' 'ancora'
            g $script:Altra 'push', 'origin', 'feature/42-x' | Out-Null
            $r = New-WorktreeDaRemoto -Voce $script:Voce -Card (New-Card 42 'X') -RadiceWorktree $script:Radice
            (g $r.Cartella 'rev-parse', 'HEAD' | Select-Object -First 1).Trim() | Should -Be $nuovo
        }

        It 'un ramo locale con commit non pubblicati non si sovrascrive: si ferma' {
            Publish-Ramo 'feature/42-x' | Out-Null
            g $script:Principale 'fetch', 'origin' | Out-Null
            $wt = Join-Path $TestDrive ('tmp-' + [guid]::NewGuid().ToString('N'))
            g $script:Principale 'worktree', 'add', '-b', 'feature/42-x', $wt, 'origin/feature/42-x' | Out-Null
            Add-Commit $wt 'mio.txt' 'non pubblicato' | Out-Null
            g $script:Principale 'worktree', 'remove', $wt | Out-Null
            { New-WorktreeDaRemoto -Voce $script:Voce -Card (New-Card 42 'X') -RadiceWorktree $script:Radice } | Should -Throw '*non pubblicati*'
            Test-Path (Join-Path $script:Radice 'Repo.Prova\card-42') | Should -BeFalse
        }
    }

    It 'riusa il ramo se esiste gia ma il worktree no' {
        $card = New-Card 42 'Aggiungi il filtro'
        $primo = New-WorktreeCard -Voce $script:Voce -Card $card -RadiceWorktree $script:Radice
        g $script:Principale 'worktree', 'remove', $primo.Cartella | Out-Null
        $di_nuovo = New-WorktreeCard -Voce $script:Voce -Card $card -RadiceWorktree $script:Radice
        $di_nuovo.Ramo | Should -Be $primo.Ramo
        Test-Path $di_nuovo.Cartella | Should -BeTrue
    }

    It 'lo slug di "Aggiungi l''età minima al preventivo" e aggiungi-l-eta-minima-al' {
        $r = New-WorktreeCard -Voce $script:Voce -Card (New-Card 7 "Aggiungi l'età minima al preventivo") -RadiceWorktree $script:Radice
        $r.Ramo | Should -Be 'feature/7-aggiungi-l-eta-minima-al'
    }

    It 'un Bug da il prefisso fix/' {
        $r = New-WorktreeCard -Voce $script:Voce -Card (New-Card 8 'Il totale e sbagliato' 'Bug') -RadiceWorktree $script:Radice
        $r.Ramo | Should -Be 'fix/8-il-totale-e-sbagliato'
    }

    It 'un titolo senza parole usa solo l id' {
        $r = New-WorktreeCard -Voce $script:Voce -Card (New-Card 9 '???') -RadiceWorktree $script:Radice
        $r.Ramo | Should -Be 'feature/9'
    }

    Context 'Remove-WorktreeCard' {
        BeforeEach {
            $script:Wt = New-WorktreeCard -Voce $script:Voce -Card (New-Card 42 'Aggiungi il filtro') -RadiceWorktree $script:Radice
        }

        It 'si rifiuta con un file non tracciato e non tocca niente' {
            Set-Content (Join-Path $script:Wt.Cartella 'nuovo.txt') 'lavoro mio'
            { Remove-Wt } | Should -Throw '*non salvato*'
            Test-Path (Join-Path $script:Wt.Cartella 'nuovo.txt') | Should -BeTrue
            @(g $script:Principale 'branch', '--list', $script:Wt.Ramo).Count | Should -Be 1
        }

        It 'si rifiuta con una modifica non committata' {
            Set-Content (Join-Path $script:Wt.Cartella 'a.txt') 'cambiato'
            { Remove-Wt } | Should -Throw '*non salvato*'
        }

        It 'con il worktree pulito rimuove cartella e ramo locale gia assorbito' {
            $r = Remove-Wt
            Test-Path $script:Wt.Cartella | Should -BeFalse
            @(g $script:Principale 'branch', '--list', $script:Wt.Ramo).Count | Should -Be 0
            $r.RamoCancellato | Should -BeTrue
        }

        It 'toglie la cartella anche se restano file ignorati (node_modules)' {
            Set-Content (Join-Path $script:Wt.Cartella '.gitignore') 'node_modules/'
            g $script:Wt.Cartella 'add', '.gitignore' | Out-Null
            g $script:Wt.Cartella 'commit', '-m', 'ignora' | Out-Null
            g $script:Wt.Cartella 'push', 'origin', "$($script:Wt.Ramo):develop" | Out-Null   # il ramo e assorbito
            New-Item -ItemType Directory (Join-Path $script:Wt.Cartella 'node_modules/x') -Force | Out-Null
            Set-Content (Join-Path $script:Wt.Cartella 'node_modules/x/y.js') 'x'
            Remove-Wt | Out-Null
            Test-Path $script:Wt.Cartella | Should -BeFalse
            (g $script:Principale 'worktree', 'list' | Out-String) | Should -Not -Match 'card-42'
        }

        It 'si rifiuta se il ramo ha commit non pubblicati: non toglie ne cartella ne ramo' {
            Add-Commit $script:Wt.Cartella 'c.txt' 'lavoro committato' | Out-Null
            { Remove-Wt } | Should -Throw '*non pubblicati*'
            Test-Path (Join-Path $script:Wt.Cartella 'c.txt') | Should -BeTrue
            @(g $script:Principale 'branch', '--list', $script:Wt.Ramo).Count | Should -Be 1
        }

        It 'con i commit pubblicati sul ramo remoto ma non in develop toglie la cartella e tiene il ramo locale' {
            Add-Commit $script:Wt.Cartella 'c.txt' 'lavoro' | Out-Null
            g $script:Wt.Cartella 'push', 'origin', $script:Wt.Ramo | Out-Null
            $r = Remove-Wt
            Test-Path $script:Wt.Cartella | Should -BeFalse
            @(g $script:Principale 'branch', '--list', $script:Wt.Ramo).Count | Should -Be 1
            $r.RamoCancellato | Should -BeFalse
        }

        It 'con -CancellaRamoPubblicato toglie anche il ramo locale che un ramo remoto contiene (card ceduta a un collega)' {
            Add-Commit $script:Wt.Cartella 'c.txt' 'lavoro' | Out-Null
            g $script:Wt.Cartella 'push', 'origin', $script:Wt.Ramo | Out-Null
            $r = Remove-WorktreeCard -Voce $script:Voce -Id 42 -Ramo $script:Wt.Ramo -Cartella $script:Wt.Cartella -RadiceWorktree $script:Radice -CancellaRamoPubblicato
            @(g $script:Principale 'branch', '--list', $script:Wt.Ramo).Count | Should -Be 0
            $r.RamoCancellato | Should -BeTrue
        }

        It 'riconosce il ramo assorbito guardando origin/develop, non il develop locale' {
            Add-Commit $script:Wt.Cartella 'c.txt' 'lavoro' | Out-Null
            g $script:Wt.Cartella 'push', 'origin', "$($script:Wt.Ramo):develop" | Out-Null   # origin/develop lo contiene, il develop locale no
            $r = Remove-Wt
            $r.RamoCancellato | Should -BeTrue
            @(g $script:Principale 'branch', '--list', $script:Wt.Ramo).Count | Should -Be 0
        }

        It 'rifiuta una cartella fuori dalla radice dei worktree' {
            { Remove-Wt -Cartella $script:Principale } | Should -Throw '*non e il worktree*'
            Test-Path $script:Principale | Should -BeTrue
        }

        It 'rifiuta un clone completo sotto la radice, anche pulito e con il suo .git' {
            $clone = Join-Path $script:Radice 'Repo.Prova\card-77'
            & git clone $script:Origin $clone 2>&1 | Out-Null
            g $clone 'checkout', '-b', 'feature/77-x' | Out-Null
            Add-Commit $clone 'mio.txt' 'commit mai pubblicato' | Out-Null
            { Remove-Wt -Id 77 -Ramo 'feature/77-x' -Cartella $clone } | Should -Throw '*non e un worktree*'
            Test-Path (Join-Path $clone '.git') | Should -BeTrue
            Test-Path (Join-Path $clone 'mio.txt') | Should -BeTrue
        }

        It 'rifiuta un clone completo al posto atteso della card che git non ha registrato come worktree' {
            $ramo = $script:Wt.Ramo
            Remove-Wt | Out-Null
            $clone = Join-Path $script:Radice 'Repo.Prova\card-42'
            & git clone $script:Origin $clone 2>&1 | Out-Null
            g $clone 'checkout', '-b', $ramo | Out-Null
            { Remove-Wt -Ramo $ramo } | Should -Throw '*non e un worktree*'
            Test-Path (Join-Path $clone '.git') | Should -BeTrue
        }

        It 'rifiuta il worktree di un altra card' {
            $altra = New-WorktreeCard -Voce $script:Voce -Card (New-Card 43 'Altra cosa') -RadiceWorktree $script:Radice
            { Remove-Wt -Ramo $altra.Ramo -Cartella $altra.Cartella } | Should -Throw '*non e il worktree*'
            Test-Path $altra.Cartella | Should -BeTrue
            @(g $script:Principale 'branch', '--list', $altra.Ramo).Count | Should -Be 1
        }

        It 'rifiuta un worktree di Titolare accanto a quelli delle card' {
            $suo = Join-Path $script:Radice 'Repo.Prova\mio-lavoro'
            g $script:Principale 'worktree', 'add', '-b', 'feature/mio', $suo, 'origin/develop' | Out-Null
            { Remove-Wt -Ramo 'feature/mio' -Cartella $suo } | Should -Throw '*non e il worktree*'
            Test-Path $suo | Should -BeTrue
        }

        It 'rifiuta se la voce e di un altro repo: il percorso atteso cambia' {
            $altraVoce = [pscustomobject]@{ repo = 'Altro.Repo'; cartella = $script:Principale }
            { Remove-Wt -Voce $altraVoce } | Should -Throw '*non e il worktree*'
            Test-Path $script:Wt.Cartella | Should -BeTrue
        }

        It 'rifiuta se la copia principale della voce e un altro repo che non conosce quella cartella' {
            $altro = Join-Path (Split-Path -Parent $script:Principale) 'altro-repo'
            & git clone $script:Origin $altro 2>&1 | Out-Null
            $voceAltro = [pscustomobject]@{ repo = 'Repo.Prova'; cartella = $altro }
            { Remove-Wt -Voce $voceAltro } | Should -Throw '*non e un worktree*'
            Test-Path (Join-Path $script:Wt.Cartella '.git') | Should -BeTrue
        }

        It 'rifiuta se il worktree ha un ramo diverso da quello della card' {
            g $script:Wt.Cartella 'checkout', '-b', 'feature/altro' | Out-Null
            { Remove-Wt } | Should -Throw '*ramo*'
            Test-Path $script:Wt.Cartella | Should -BeTrue
        }

        It 'se git non riesce a togliere un worktree ancora registrato lancia un errore e non cancella la cartella' {
            g $script:Principale 'worktree', 'lock', $script:Wt.Cartella | Out-Null   # git rifiuta di toglierlo e resta registrato
            { Remove-Wt } | Should -Throw '*ancora registrato*'
            Test-Path (Join-Path $script:Wt.Cartella '.git') | Should -BeTrue
        }

        It 'il worktree nuovo non traccia origin/develop: un push non puo finire su develop' {
            (& git -C $script:Principale config --get-all "branch.$($script:Wt.Ramo).merge") | Should -BeNullOrEmpty
        }

        It 'toglie dalla copia principale i riferimenti ai rami che Azure DevOps ha cancellato' {
            g $script:Wt.Cartella 'push', 'origin', "$($script:Wt.Ramo):develop", $script:Wt.Ramo | Out-Null
            g $script:Origin 'branch', '-D', $script:Wt.Ramo | Out-Null   # come fa Azure DevOps al completamento
            Remove-Wt | Out-Null
            (& git -C $script:Principale rev-parse --verify --quiet "refs/remotes/origin/$($script:Wt.Ramo)") | Should -BeNullOrEmpty
        }
    }

    Context 'D52: il ramo della funzionalita' {
        BeforeEach {
            # un collega (o un altro smistatore) che pubblica rami su origin
            $script:Altra = Join-Path (Split-Path -Parent $script:Principale) 'collega'
            & git clone $script:Origin $script:Altra 2>&1 | Out-Null
            g $script:Altra 'checkout', 'develop' | Out-Null
            function script:Publish-Altro([string]$Ramo) {
                g $script:Altra 'push', 'origin', "origin/develop:refs/heads/$Ramo" | Out-Null
            }
            function script:New-Feature($Id = 7, $Titolo = 'Il filtro degli ordini', $Tag = @()) { [pscustomobject]@{ Id = $Id; Titolo = $Titolo; Tag = @($Tag) } }
            function script:Ref-Origin([string]$Ramo) { (& git -C $script:Origin rev-parse --verify --quiet "refs/heads/$Ramo" 2>$null) }
        }

        Context 'Get-NomeRamoFunzionalita' {
            It 'feature/f7-slug per una funzionalita, bugfix/f7-slug con il tag bug' {
                Get-NomeRamoFunzionalita (script:New-Feature 7 'Il filtro degli ordini') -TagBug 'bug' | Should -Be 'feature/f7-il-filtro-degli-ordini'
                Get-NomeRamoFunzionalita (script:New-Feature 7 'Il filtro' @('altro', 'bug')) -TagBug 'bug' | Should -Be 'bugfix/f7-il-filtro'
            }
            It 'un titolo senza parole usa solo l id' {
                Get-NomeRamoFunzionalita (script:New-Feature 7 '???') -TagBug 'bug' | Should -Be 'feature/f7'
            }
        }

        Context 'Find-RamoFunzionalita' {
            It 'senza un ramo della funzionalita su origin da null' {
                Find-RamoFunzionalita -Principale $script:Principale -IdFeature 7 | Should -BeNullOrEmpty
            }
            It 'lo trova per id anche se il prefisso e il titolo sono cambiati dopo la creazione' {
                script:Publish-Altro 'bugfix/f7-un-altro-titolo-del-tutto'
                Find-RamoFunzionalita -Principale $script:Principale -IdFeature 7 | Should -Be 'bugfix/f7-un-altro-titolo-del-tutto'
            }
            It 'non confonde la Feature 7 con la 70, ne con la card 7' {
                script:Publish-Altro 'feature/f70-altra'
                script:Publish-Altro 'feature/7-card-sette'
                script:Publish-Altro 'fix/7-card-sette-bug'
                Find-RamoFunzionalita -Principale $script:Principale -IdFeature 7 | Should -BeNullOrEmpty
            }
            It 'con due rami della stessa funzionalita si ferma: non sceglie lui' {
                script:Publish-Altro 'feature/f7-a'
                script:Publish-Altro 'bugfix/f7-b'
                { Find-RamoFunzionalita -Principale $script:Principale -IdFeature 7 } | Should -Throw '*bugfix/f7-b*feature/f7-a*'
            }
        }

        Context 'Publish-RamoFunzionalita' {
            It 'crea il ramo da origin/develop (non dal develop locale vecchio) e lo pubblica, senza toccare la copia principale' {
                $nuovo = Add-Commit $script:Altra 'b.txt' 'due'
                g $script:Altra 'push', 'origin', 'develop' | Out-Null
                $r = Publish-RamoFunzionalita -Principale $script:Principale -Feature (script:New-Feature) -TagBug 'bug'
                $r | Should -Be 'feature/f7-il-filtro-degli-ordini'
                (script:Ref-Origin $r).Trim() | Should -Be $nuovo
                (g $script:Principale 'branch', '--show-current' | Select-Object -First 1).Trim() | Should -Be 'develop'
                @(g $script:Principale 'branch', '--list', $r).Count | Should -Be 0
            }
            It 'una Feature con il tag bug da un ramo bugfix/' {
                Publish-RamoFunzionalita -Principale $script:Principale -Feature (script:New-Feature 8 'Errore nel conteggio' @('bug')) -TagBug 'bug' |
                    Should -Be 'bugfix/f8-errore-nel-conteggio'
                script:Ref-Origin 'bugfix/f8-errore-nel-conteggio' | Should -Not -BeNullOrEmpty
            }
            It 'se il ramo c e gia (anche con un altro titolo) lo usa e non ne crea un secondo' {
                script:Publish-Altro 'feature/f7-titolo-vecchio'
                Publish-RamoFunzionalita -Principale $script:Principale -Feature (script:New-Feature) -TagBug 'bug' | Should -Be 'feature/f7-titolo-vecchio'
                script:Ref-Origin 'feature/f7-il-filtro-degli-ordini' | Should -BeNullOrEmpty
            }
            It 'chiamato due volte non fallisce e da lo stesso ramo' {
                $a = Publish-RamoFunzionalita -Principale $script:Principale -Feature (script:New-Feature) -TagBug 'bug'
                Publish-RamoFunzionalita -Principale $script:Principale -Feature (script:New-Feature) -TagBug 'bug' | Should -Be $a
            }
            It 'un push rifiutato perche un altro smistatore ha creato il ramo nel frattempo non e un errore: usa quello' {
                # l'hook di origin crea il ramo (con un altro titolo) e rifiuta il push, come una corsa fra due smistatori
                $hook = Join-Path $script:Origin 'hooks/pre-receive'
                Set-Content -LiteralPath $hook -Value "#!/bin/sh`nunset GIT_QUARANTINE_PATH`ngit update-ref refs/heads/feature/f7-creato-da-altri refs/heads/develop`nexit 1`n" -NoNewline
                $r = Publish-RamoFunzionalita -Principale $script:Principale -Feature (script:New-Feature) -TagBug 'bug'
                $r | Should -Be 'feature/f7-creato-da-altri'
            }
            It 'un push rifiutato per un altro motivo e un errore' {
                Set-Content -LiteralPath (Join-Path $script:Origin 'hooks/pre-receive') -Value "#!/bin/sh`nexit 1`n" -NoNewline
                { Publish-RamoFunzionalita -Principale $script:Principale -Feature (script:New-Feature) -TagBug 'bug' } | Should -Throw '*push*'
            }
        }

        Context 'New-WorktreeCard -Base' {
            It 'il ramo della card nasce dalla base su origin, non da develop' {
                script:Publish-Altro 'feature/f7-il-filtro'
                g $script:Altra 'checkout', '-B', 'feature/f7-il-filtro', 'origin/feature/f7-il-filtro' | Out-Null
                $sul_ramo = Add-Commit $script:Altra 'base.txt' 'sul ramo della funzionalita'
                g $script:Altra 'push', 'origin', 'feature/f7-il-filtro' | Out-Null
                $r = New-WorktreeCard -Voce $script:Voce -Card (New-Card 42 'Aggiungi il filtro') -RadiceWorktree $script:Radice -Base 'feature/f7-il-filtro'
                $r.Ramo | Should -Be 'feature/42-aggiungi-il-filtro'
                (g $r.Cartella 'rev-parse', 'HEAD' | Select-Object -First 1).Trim() | Should -Be $sul_ramo
                Test-Path (Join-Path $r.Cartella 'base.txt') | Should -BeTrue
                # non traccia la base: un push non puo finire sul ramo della funzionalita
                (& git -C $r.Cartella config --get "branch.$($r.Ramo).merge") | Should -BeNullOrEmpty
            }
            It 'un ramo locale vecchio, gia contenuto in un ref remoto, si riporta alla base' {
                script:Publish-Altro 'feature/f7-il-filtro'
                g $script:Altra 'checkout', '-B', 'feature/f7-il-filtro', 'origin/feature/f7-il-filtro' | Out-Null
                $nuovo = Add-Commit $script:Altra 'base.txt' 'nuovo'
                g $script:Altra 'push', 'origin', 'feature/f7-il-filtro' | Out-Null
                # un ramo locale della card, rimasto indietro, da un tentativo di prima: il suo commit sta in origin/develop
                g $script:Principale 'branch', 'feature/42-aggiungi-il-filtro', $script:Iniziale | Out-Null
                $r = New-WorktreeCard -Voce $script:Voce -Card (New-Card 42 'Aggiungi il filtro') -RadiceWorktree $script:Radice -Base 'feature/f7-il-filtro'
                (g $r.Cartella 'rev-parse', 'HEAD' | Select-Object -First 1).Trim() | Should -Be $nuovo
            }
            It 'un ramo locale con commit non pubblicati non si tocca: errore chiaro, il commit resta, nessun worktree' {
                script:Publish-Altro 'feature/f7-il-filtro'
                g $script:Principale 'branch', 'feature/42-aggiungi-il-filtro', $script:Iniziale | Out-Null
                $tmp = Join-Path (Split-Path -Parent $script:Principale) 'tmp-lavoro'
                g $script:Principale 'worktree', 'add', $tmp, 'feature/42-aggiungi-il-filtro' | Out-Null
                $perso = Add-Commit $tmp 'mio.txt' 'lavoro non pubblicato'
                g $script:Principale 'worktree', 'remove', '--force', $tmp | Out-Null
                { New-WorktreeCard -Voce $script:Voce -Card (New-Card 42 'Aggiungi il filtro') -RadiceWorktree $script:Radice -Base 'feature/f7-il-filtro' } |
                    Should -Throw '*non pubblicati*'
                (g $script:Principale 'rev-parse', 'feature/42-aggiungi-il-filtro' | Select-Object -First 1).Trim() | Should -Be $perso
                Test-Path (Join-Path $script:Radice 'Repo.Prova\card-42') | Should -BeFalse
            }
            It 'se il ramo della card e gia su origin si riparte da quello, non dalla base' {
                script:Publish-Altro 'feature/f7-il-filtro'
                g $script:Altra 'checkout', '-B', 'feature/42-aggiungi-il-filtro', 'origin/feature/f7-il-filtro' | Out-Null
                $lavoro = Add-Commit $script:Altra 'card.txt' 'lavoro della card gia pubblicato'
                g $script:Altra 'push', 'origin', 'feature/42-aggiungi-il-filtro' | Out-Null
                $r = New-WorktreeCard -Voce $script:Voce -Card (New-Card 42 'Aggiungi il filtro') -RadiceWorktree $script:Radice -Base 'feature/f7-il-filtro'
                (g $r.Cartella 'rev-parse', 'HEAD' | Select-Object -First 1).Trim() | Should -Be $lavoro
                Test-Path (Join-Path $r.Cartella 'card.txt') | Should -BeTrue
            }
            It 'il fetch pota i ref remoti spariti: un ramo della card cancellato su origin non e piu una partenza' {
                script:Publish-Altro 'feature/f7-il-filtro'
                $base = (g $script:Altra 'rev-parse', 'origin/feature/f7-il-filtro' | Select-Object -First 1).Trim()
                g $script:Altra 'checkout', '-B', 'feature/42-aggiungi-il-filtro', 'origin/feature/f7-il-filtro' | Out-Null
                Add-Commit $script:Altra 'card.txt' 'lavoro gia unito' | Out-Null
                g $script:Altra 'push', 'origin', 'feature/42-aggiungi-il-filtro' | Out-Null
                # la copia principale lo vede, poi origin lo cancella (e il completamento della PR a farlo)
                g $script:Principale 'fetch', 'origin' | Out-Null
                g $script:Altra 'push', 'origin', '--delete', 'feature/42-aggiungi-il-filtro' | Out-Null
                $r = New-WorktreeCard -Voce $script:Voce -Card (New-Card 42 'Aggiungi il filtro') -RadiceWorktree $script:Radice -Base 'feature/f7-il-filtro'
                (g $r.Cartella 'rev-parse', 'HEAD' | Select-Object -First 1).Trim() | Should -Be $base
                Test-Path (Join-Path $r.Cartella 'card.txt') | Should -BeFalse
            }
            It 'una base che non e su origin e un errore, e non crea niente' {
                { New-WorktreeCard -Voce $script:Voce -Card (New-Card 42 'Aggiungi il filtro') -RadiceWorktree $script:Radice -Base 'feature/f7-non-c-e' } | Should -Throw
                Test-Path (Join-Path $script:Radice 'Repo.Prova\card-42') | Should -BeFalse
            }
        }

        Context 'Remove-WorktreeCard -Destinazione' {
            BeforeEach {
                script:Publish-Altro 'feature/f7-il-filtro'
                $script:Wt = New-WorktreeCard -Voce $script:Voce -Card (New-Card 42 'Aggiungi il filtro') -RadiceWorktree $script:Radice -Base 'feature/f7-il-filtro'
                Add-Commit $script:Wt.Cartella 'c.txt' 'lavoro' | Out-Null
                # la PR verso il ramo della funzionalita e completata: il ramo della funzionalita contiene il lavoro, develop no
                g $script:Wt.Cartella 'push', 'origin', "$($script:Wt.Ramo):feature/f7-il-filtro" | Out-Null
            }
            It 'cancella il ramo locale se la destinazione su origin lo contiene' {
                $r = Remove-WorktreeCard -Voce $script:Voce -Id 42 -Ramo $script:Wt.Ramo -Cartella $script:Wt.Cartella -RadiceWorktree $script:Radice -Destinazione 'feature/f7-il-filtro'
                $r.RamoCancellato | Should -BeTrue
                @(g $script:Principale 'branch', '--list', $script:Wt.Ramo).Count | Should -Be 0
            }
            It 'senza destinazione guarda origin/develop, che non lo contiene: il ramo locale resta' {
                $r = Remove-WorktreeCard -Voce $script:Voce -Id 42 -Ramo $script:Wt.Ramo -Cartella $script:Wt.Cartella -RadiceWorktree $script:Radice
                $r.RamoCancellato | Should -BeFalse
                @(g $script:Principale 'branch', '--list', $script:Wt.Ramo).Count | Should -Be 1
            }
        }

        # D52, gruppo 4: la card di chiusura ha un worktree vero ma in sola lettura: detached su origin/<ramo della funzionalita>, nella
        # cartella standard delle card. Nessun ramo suo, quindi niente commit che si possano pubblicare per sbaglio.
        Context 'Update-WorktreeChiusura' {
            BeforeEach {
                script:Publish-Altro 'feature/f7-il-filtro'
                $script:CardChiusura = New-Card 22 'Collaudo funzionalita: il filtro'
                function script:Ramo-Nuovo-Commit([string]$File = 'sorella.txt') {
                    g $script:Altra 'checkout', '-B', 'feature/f7-il-filtro', 'origin/feature/f7-il-filtro' | Out-Null
                    $c = Add-Commit $script:Altra $File 'una sorella e entrata nel ramo'
                    g $script:Altra 'push', 'origin', 'feature/f7-il-filtro' | Out-Null
                    $c
                }
            }

            It 'primo lancio: crea il worktree nella cartella standard, detached su origin/<ramo>, senza ramo locale' {
                $c1 = Ramo-Nuovo-Commit
                $r = Update-WorktreeChiusura -Voce $script:Voce -Card $script:CardChiusura -Ramo 'feature/f7-il-filtro' -RadiceWorktree $script:Radice
                $r.Cartella | Should -Be (Join-Path $script:Radice 'Repo.Prova\card-22')
                (g $r.Cartella 'rev-parse', 'HEAD' | Select-Object -First 1).Trim() | Should -Be $c1
                Test-Path (Join-Path $r.Cartella 'sorella.txt') | Should -BeTrue
                # detached: nessun ramo, quindi nessun commit che qualcuno possa pubblicare per sbaglio con un push del ramo
                (g $r.Cartella 'branch', '--show-current' | Out-String).Trim() | Should -BeNullOrEmpty
                & git -C $r.Cartella symbolic-ref -q HEAD 2>$null; $LASTEXITCODE | Should -Not -Be 0
                @(g $script:Principale 'branch', '--list', 'feature/f7-*').Count | Should -Be 0
                # la copia principale non si e mossa
                (g $script:Principale 'branch', '--show-current' | Select-Object -First 1).Trim() | Should -Be 'develop'
            }

            It 'a ogni lancio il worktree e riportato a origin/<ramo> aggiornato: una sorella entrata nel ramo si vede' {
                Ramo-Nuovo-Commit | Out-Null
                $primo = Update-WorktreeChiusura -Voce $script:Voce -Card $script:CardChiusura -Ramo 'feature/f7-il-filtro' -RadiceWorktree $script:Radice
                $c2 = Ramo-Nuovo-Commit 'altra-sorella.txt'
                $secondo = Update-WorktreeChiusura -Voce $script:Voce -Card $script:CardChiusura -Ramo 'feature/f7-il-filtro' -RadiceWorktree $script:Radice
                $secondo.Cartella | Should -Be $primo.Cartella
                (g $secondo.Cartella 'rev-parse', 'HEAD' | Select-Object -First 1).Trim() | Should -Be $c2
                Test-Path (Join-Path $secondo.Cartella 'altra-sorella.txt') | Should -BeTrue
                (g $secondo.Cartella 'branch', '--show-current' | Out-String).Trim() | Should -BeNullOrEmpty
            }

            It 'cio che un ruolo ha lasciato nei file tracciati non resta: il worktree torna com e il ramo' {
                Ramo-Nuovo-Commit | Out-Null
                $r = Update-WorktreeChiusura -Voce $script:Voce -Card $script:CardChiusura -Ramo 'feature/f7-il-filtro' -RadiceWorktree $script:Radice
                Set-Content (Join-Path $r.Cartella 'sorella.txt') 'modificato'
                Update-WorktreeChiusura -Voce $script:Voce -Card $script:CardChiusura -Ramo 'feature/f7-il-filtro' -RadiceWorktree $script:Radice | Out-Null
                (Get-Content (Join-Path $r.Cartella 'sorella.txt') -Raw).Trim() | Should -Be 'una sorella e entrata nel ramo'
            }

            It 'senza il ramo su origin da un errore che lo dice, e non crea la cartella' {
                { Update-WorktreeChiusura -Voce $script:Voce -Card $script:CardChiusura -Ramo 'feature/f9-non-c-e' -RadiceWorktree $script:Radice } | Should -Throw '*feature/f9-non-c-e*'
                Test-Path (Join-Path $script:Radice 'Repo.Prova\card-22') | Should -BeFalse
            }

            It 'una cartella che e sul ramo di una card (non detached) non si usa' {
                $wt = New-WorktreeCard -Voce $script:Voce -Card $script:CardChiusura -RadiceWorktree $script:Radice
                { Update-WorktreeChiusura -Voce $script:Voce -Card $script:CardChiusura -Ramo 'feature/f7-il-filtro' -RadiceWorktree $script:Radice } | Should -Throw '*non e detached*'
                (g $wt.Cartella 'branch', '--show-current' | Select-Object -First 1).Trim() | Should -Be $wt.Ramo
            }

            It 'Remove-WorktreeCard toglie un worktree detached (anche sporco) senza toccare nessun ramo locale con lo stesso nome' {
                Ramo-Nuovo-Commit | Out-Null
                g $script:Principale 'branch', 'feature/f7-il-filtro', 'origin/develop' | Out-Null
                $r = Update-WorktreeChiusura -Voce $script:Voce -Card $script:CardChiusura -Ramo 'feature/f7-il-filtro' -RadiceWorktree $script:Radice
                Set-Content (Join-Path $r.Cartella 'sporco.txt') 'avanzo di una prova'
                $out = Remove-WorktreeCard -Voce $script:Voce -Id 22 -Ramo 'feature/f7-il-filtro' -Cartella $r.Cartella -RadiceWorktree $script:Radice
                Test-Path $r.Cartella | Should -BeFalse
                $out.RamoCancellato | Should -BeFalse
                @(g $script:Principale 'branch', '--list', 'feature/f7-il-filtro').Count | Should -Be 1
                Get-WorktreeRegistrato $script:Principale $r.Cartella | Should -BeNullOrEmpty
            }

            It 'Remove-WorktreeCard rifiuta ancora una cartella che non e un worktree registrato' {
                $finta = Join-Path $script:Radice 'Repo.Prova\card-22'
                New-Item -ItemType Directory $finta | Out-Null
                { Remove-WorktreeCard -Voce $script:Voce -Id 22 -Ramo 'feature/f7-il-filtro' -Cartella $finta -RadiceWorktree $script:Radice } | Should -Throw '*non e un worktree*'
            }
        }
    }

    It 'git non apre prompt di credenziali: un fetch che le chiede fallisce invece di restare appeso' {
        # l'ambiente di chi lancia puo gia averle impostate: si tolgono prima, e si rimettono dopo
        $prima = @{ GIT_TERMINAL_PROMPT = $env:GIT_TERMINAL_PROMPT; GCM_INTERACTIVE = $env:GCM_INTERACTIVE }
        Remove-Item Env:GIT_TERMINAL_PROMPT, Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue
        try {
            InModuleScope Worktree -Parameters @{ P = $script:Principale } {
                param($P)
                (Invoke-Git $P @('-c', 'alias.vedi=!echo "$GIT_TERMINAL_PROMPT/$GCM_INTERACTIVE"', 'vedi')) | Should -Be '0/never'
            }
            # e dopo la chiamata l'ambiente di chi lancia e com'era
            $env:GIT_TERMINAL_PROMPT | Should -BeNullOrEmpty
        }
        finally { foreach ($k in $prima.Keys) { Set-Item "Env:$k" $prima[$k] -ErrorAction SilentlyContinue } }
    }
}

Describe 'Impronta del worktree' {
    BeforeEach {
        $script:Wt = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:Wt | Out-Null
        & git init -b feature/7-prova $script:Wt 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Wt '.gitignore') -Value 'bin/'
        Add-Commit $script:Wt 'a.txt' 'uno' | Out-Null
        $script:Prima = Get-ImprontaWorktree -Cartella $script:Wt
    }

    It 'un worktree che nessuno ha toccato non ha differenze' {
        @(Compare-ImprontaWorktree -Prima $script:Prima -Dopo (Get-ImprontaWorktree -Cartella $script:Wt)).Count | Should -Be 0
    }

    It 'l impronta salvata nello stato (JSON) e riletta si confronta come quella appena presa' {
        $riletta = $script:Prima | ConvertTo-Json | ConvertFrom-Json -AsHashtable
        @(Compare-ImprontaWorktree -Prima $riletta -Dopo (Get-ImprontaWorktree -Cartella $script:Wt)).Count | Should -Be 0
    }

    It 'un file nuovo e una differenza, con il suo nome' {
        Set-Content -LiteralPath (Join-Path $script:Wt 'nuovo.txt') -Value 'x'
        $d = @(Compare-ImprontaWorktree -Prima $script:Prima -Dopo (Get-ImprontaWorktree -Cartella $script:Wt))
        $d.Count | Should -Be 1
        $d[0] | Should -Match 'nuovo\.txt'
    }

    It 'un file che git ignora (il prodotto di una build) non e una differenza' {
        New-Item -ItemType Directory (Join-Path $script:Wt 'bin') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Wt 'bin/x.dll') -Value 'x'
        @(Compare-ImprontaWorktree -Prima $script:Prima -Dopo (Get-ImprontaWorktree -Cartella $script:Wt)).Count | Should -Be 0
    }

    It 'un file tracciato modificato e una differenza, con il suo nome' {
        Set-Content -LiteralPath (Join-Path $script:Wt 'a.txt') -Value 'due'
        $d = @(Compare-ImprontaWorktree -Prima $script:Prima -Dopo (Get-ImprontaWorktree -Cartella $script:Wt))
        $d.Count | Should -Be 1
        $d[0] | Should -Match 'a\.txt'
    }

    It 'un commit e una differenza, con il commit di prima e quello di dopo' {
        $nuovo = Add-Commit $script:Wt 'b.txt' 'due'
        $d = @(Compare-ImprontaWorktree -Prima $script:Prima -Dopo (Get-ImprontaWorktree -Cartella $script:Wt))
        ($d -join ' ') | Should -Match $script:Prima['testa'].Substring(0, 7)
        ($d -join ' ') | Should -Match $nuovo.Substring(0, 7)
    }

    It 'un altro ramo sullo stesso commit e una differenza' {
        g $script:Wt 'checkout', '-b', 'altro' | Out-Null
        $d = @(Compare-ImprontaWorktree -Prima $script:Prima -Dopo (Get-ImprontaWorktree -Cartella $script:Wt))
        ($d -join ' ') | Should -Match 'altro'
    }

    It 'un file gia modificato che cambia ancora e una differenza, anche se git status e uguale' {
        Set-Content -LiteralPath (Join-Path $script:Wt 'a.txt') -Value 'due'
        $sporco = Get-ImprontaWorktree -Cartella $script:Wt
        Set-Content -LiteralPath (Join-Path $script:Wt 'a.txt') -Value 'tre'
        $dopo = Get-ImprontaWorktree -Cartella $script:Wt
        $dopo['stato'] | Should -Be $sporco['stato']
        @(Compare-ImprontaWorktree -Prima $sporco -Dopo $dopo).Count | Should -Be 1
    }

    It 'piu file cambiati di quanti se ne elencano: dice quanti restano fuori' {
        1..4 | ForEach-Object { Set-Content -LiteralPath (Join-Path $script:Wt "n$_.txt") -Value 'x' }
        $d = @(Compare-ImprontaWorktree -Prima $script:Prima -Dopo (Get-ImprontaWorktree -Cartella $script:Wt) -MassimoFile 3)
        $d[0] | Should -Match 'altri 1'
    }
}
