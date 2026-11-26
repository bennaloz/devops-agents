BeforeAll {
    # D53: i moduli che chiamano Get-Config (Card, MemoriaRepo, Sessioni) leggono impostazioni.json dalla cartella dati: non quella vera di chi lancia i test.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    Import-Module (Join-Path $PSScriptRoot '../src/Card.psm1') -Force
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:CardPs1 = Join-Path $script:Repo 'src/card.ps1'

    $global:FxConfig = [pscustomobject]@{
        Stati = Get-Content (Join-Path $script:Repo 'config/stati.json') -Raw | ConvertFrom-Json
        Ruoli = Get-Content (Join-Path $script:Repo 'config/ruoli.json') -Raw | ConvertFrom-Json
        Mappa = Get-Content (Join-Path $script:Repo 'config/mappa.json') -Raw | ConvertFrom-Json
    }
}

AfterAll { Remove-Variable FxConfig, FxCard, FxTask -Scope Global -ErrorAction SilentlyContinue }

Describe 'Card: task figli' {
    BeforeEach {
        Mock Get-Config -ModuleName Card { $global:FxConfig }
        Mock Get-AdoCard -ModuleName Card { $global:FxCard }
        Mock Get-AdoCommenti -ModuleName Card { @() }
        Mock Get-AdoTaskFigli -ModuleName Card { @($global:FxTask) }
        $script:Seq = 100
        Mock New-AdoTask -ModuleName Card {
            $script:Seq++
            [pscustomobject]@{ Id = $script:Seq; Titolo = $Titolo; Descrizione = $Descrizione; Stato = 'New'; Tipo = 'Task' }
        }
        Mock Set-AdoTaskStato -ModuleName Card { 9 }
        $global:FxCard = [pscustomobject]@{ Id = 5; Rev = 20; Tipo = 'User Story'; Titolo = 'Titolo di prova'
            Descrizione = 'Descrizione di prova'; Criteri = 'Criteri di prova'; Stato = $global:FxConfig.Stati.pronto; Tag = @()
            Area = 'DevOps.Agents\AI\Stime'; CreataDa = $null }
        $global:FxTask = @(
            [pscustomobject]@{ Id = 61; Titolo = 'Primo task'; Descrizione = 'Fare A; fatto se B'; Stato = $global:FxConfig.Stati.taskChiuso; Tipo = 'Task' }
            [pscustomobject]@{ Id = 62; Titolo = 'Secondo task'; Descrizione = 'Fare C; fatto se D'; Stato = 'New'; Tipo = 'Task' }
        )
        $script:Due = "=== Primo`nTesto del primo con `$x e ``backtick```nSeconda riga.`n=== Secondo`nTesto del secondo.`n"
    }

    Context 'Read-Card mostra i task' {
        It 'elenca i task con id, stato, titolo e testo, nell ordine di esecuzione' {
            $t = Read-Card -Id 5
            $t | Should -BeLike '*TASK*'
            $t | Should -BeLike "*#61*$($global:FxConfig.Stati.taskChiuso)*Primo task*"
            $t | Should -BeLike '*#62*New*Secondo task*'
            $t | Should -BeLike '*Fare C; fatto se D*'
            $t.IndexOf('#61') | Should -BeLessThan $t.IndexOf('#62')
        }
        It 'con -TaskSessione segna il task della sessione' {
            $t = Read-Card -Id 5 -TaskSessione 62
            ($t -split "`n" | Where-Object { $_ -like '#62*' }) | Should -BeLike '*il tuo task*'
            ($t -split "`n" | Where-Object { $_ -like '#61*' }) | Should -Not -BeLike '*il tuo task*'
        }
        It 'una card senza task non ha la sezione' {
            $global:FxTask = @()
            Read-Card -Id 5 | Should -Not -BeLike '*TASK*'
        }
    }

    Context 'New-CardTask' {
        It 'crea i task nell ordine in cui sono scritti, con l area della card' {
            $r = @(New-CardTask -Id 5 -Ruolo 'responsabile' -Testo $script:Due)
            $r.Count | Should -Be 2
            Should -Invoke New-AdoTask -ModuleName Card -Times 2 -Exactly
            Should -Invoke New-AdoTask -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $CardId -eq 5 -and $Titolo -eq 'Primo' -and $Area -eq $global:FxCard.Area -and
                $Descrizione -eq "Testo del primo con `$x e ``backtick```nSeconda riga." }
            Should -Invoke New-AdoTask -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Titolo -eq 'Secondo' -and $Descrizione -eq 'Testo del secondo.' }
            $r[0].Id | Should -BeLessThan $r[1].Id
        }
        It 'e permesso solo a responsabile' {
            foreach ($ruolo in 'dev', 'reviewer') {
                { New-CardTask -Id 5 -Ruolo $ruolo -Testo $script:Due } | Should -Throw '*responsabile*'
            }
            Should -Invoke New-AdoTask -ModuleName Card -Times 0 -Exactly
        }
        It 'un testo malformato non crea niente: testo prima del primo titolo' {
            { New-CardTask -Id 5 -Ruolo 'responsabile' -Testo "premessa`n=== Uno`ntesto" } | Should -Throw '*===*'
            Should -Invoke New-AdoTask -ModuleName Card -Times 0 -Exactly
        }
        It 'un testo malformato non crea niente: un task senza testo, nominandolo' {
            { New-CardTask -Id 5 -Ruolo 'responsabile' -Testo "=== Uno`ntesto`n=== Due`n   `n" } | Should -Throw '*2*Due*'
            Should -Invoke New-AdoTask -ModuleName Card -Times 0 -Exactly
        }
        It 'senza nessun task e un errore' {
            { New-CardTask -Id 5 -Ruolo 'responsabile' -Testo 'solo testo' } | Should -Throw
            Should -Invoke New-AdoTask -ModuleName Card -Times 0 -Exactly
        }
        It 'aggiungere task a una card che ne ha gia e permesso' {
            $r = @(New-CardTask -Id 5 -Ruolo 'responsabile' -Testo "=== Terzo task`nFare E; fatto se F")
            $r.Count | Should -Be 1
        }
        It 'un titolo uguale a un task gia presente (anche chiuso) non crea niente e lo nomina' {
            $msg = try { New-CardTask -Id 5 -Ruolo 'responsabile' -Testo "=== Nuovo`ntesto`n===  primo TASK `naltro"; '' } catch { $_.Exception.Message }
            $msg | Should -BeLike '*#61*'
            Should -Invoke New-AdoTask -ModuleName Card -Times 0 -Exactly
        }
        It 'un task rimosso non conta come doppione' {
            $global:FxTask = @([pscustomobject]@{ Id = 70; Titolo = 'Primo'; Descrizione = 'x'; Stato = $global:FxConfig.Stati.taskRimosso; Tipo = 'Task' })
            @(New-CardTask -Id 5 -Ruolo 'responsabile' -Testo $script:Due).Count | Should -Be 2
        }
        It 'due titoli uguali nello stesso testo non creano niente' {
            { New-CardTask -Id 5 -Ruolo 'responsabile' -Testo "=== Uno`na`n=== uno`nb" } | Should -Throw '*Uno*'
            Should -Invoke New-AdoTask -ModuleName Card -Times 0 -Exactly
        }
        It 'se la creazione fallisce a meta dice quali task sono gia stati creati' {
            Mock New-AdoTask -ModuleName Card {
                if ($Titolo -eq 'Secondo') { throw 'ADO ko' }
                [pscustomobject]@{ Id = 101; Titolo = $Titolo; Descrizione = $Descrizione; Stato = 'New'; Tipo = 'Task' }
            }
            $msg = try { New-CardTask -Id 5 -Ruolo 'responsabile' -Testo $script:Due; '' } catch { $_.Exception.Message }
            $msg | Should -BeLike '*101*'
            $msg | Should -BeLike '*Secondo*'
            $msg | Should -BeLike '*ADO ko*'
        }
    }

    Context 'Close-CardTask' {
        It 'dev chiude il task della sessione' {
            Close-CardTask -Id 5 -Ruolo 'dev' -TaskSessione '62' | Out-Null
            Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Id -eq 62 -and $Stato -eq $global:FxConfig.Stati.taskChiuso }
        }
        It 'con l id del task della sessione passato come argomento va lo stesso' {
            Close-CardTask -Id 5 -Ruolo 'dev' -TaskSessione '62' -TaskRichiesto '62' | Out-Null
            Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Id -eq 62 }
        }
        It 'rifiuta qualunque task diverso da quello della sessione' {
            { Close-CardTask -Id 5 -Ruolo 'dev' -TaskSessione '62' -TaskRichiesto '61' } | Should -Throw '*sessione*'
            { Close-CardTask -Id 5 -Ruolo 'dev' -TaskSessione '62' -TaskRichiesto '999' } | Should -Throw '*sessione*'
            Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 0 -Exactly
        }
        It 'e permesso solo a dev' {
            foreach ($ruolo in 'responsabile', 'reviewer') {
                { Close-CardTask -Id 5 -Ruolo $ruolo -TaskSessione '62' } | Should -Throw '*dev*'
            }
            Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 0 -Exactly
        }
        It 'una sessione senza task non ha niente da chiudere' {
            { Close-CardTask -Id 5 -Ruolo 'dev' -TaskSessione '' } | Should -Throw '*task*'
            { Close-CardTask -Id 5 -Ruolo 'dev' -TaskSessione 'abc' } | Should -Throw '*task*'
            Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 0 -Exactly
        }
        It 'un task che non e figlio della card non si chiude' {
            { Close-CardTask -Id 5 -Ruolo 'dev' -TaskSessione '777' } | Should -Throw '*figlio*'
            Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 0 -Exactly
        }
        It 'un task gia chiuso non si riscrive e non e un errore' {
            Close-CardTask -Id 5 -Ruolo 'dev' -TaskSessione '61' | Should -BeLike '*gia*'
            Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 0 -Exactly
        }
        It 'un task rimosso non si chiude' {
            $global:FxTask[1].Stato = $global:FxConfig.Stati.taskRimosso
            { Close-CardTask -Id 5 -Ruolo 'dev' -TaskSessione '62' } | Should -Throw '*rimosso*'
            Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 0 -Exactly
        }
    }
}

Describe 'card.ps1: task' {
    BeforeAll {
        function Invoke-CardTask($Ruolo, $Task, $Comando, $Stdin, $Argomento) {
            $vecchi = @($env:ATTREZZI_CARD, $env:ATTREZZI_RUOLO, $env:ATTREZZI_TASK, [Console]::In)
            $env:ATTREZZI_CARD = '5'; $env:ATTREZZI_RUOLO = $Ruolo
            if ($Task) { $env:ATTREZZI_TASK = $Task } else { Remove-Item Env:ATTREZZI_TASK -ErrorAction SilentlyContinue }
            [Console]::SetIn([IO.StringReader]::new([string]$Stdin))
            try {
                $global:LASTEXITCODE = 0
                if ($Argomento) { $null = & $script:CardPs1 $Comando $Argomento 2>&1 } else { $null = & $script:CardPs1 $Comando 2>&1 }
                $global:LASTEXITCODE
            }
            finally {
                $env:ATTREZZI_CARD = $vecchi[0]; $env:ATTREZZI_RUOLO = $vecchi[1]
                if ($null -eq $vecchi[2]) { Remove-Item Env:ATTREZZI_TASK -ErrorAction SilentlyContinue } else { $env:ATTREZZI_TASK = $vecchi[2] }
                [Console]::SetIn($vecchi[3])
            }
        }
    }
    BeforeEach {
        Mock Get-Config -ModuleName Card { $global:FxConfig }
        Mock Get-AdoCard -ModuleName Card { $global:FxCard }
        Mock Get-AdoTaskFigli -ModuleName Card { @($global:FxTask) }
        Mock New-AdoTask -ModuleName Card { [pscustomobject]@{ Id = 101; Titolo = $Titolo; Descrizione = $Descrizione; Stato = 'New'; Tipo = 'Task' } }
        Mock Set-AdoTaskStato -ModuleName Card { 9 }
        $global:FxCard = [pscustomobject]@{ Id = 5; Rev = 20; Tipo = 'User Story'; Titolo = 'T'; Descrizione = 'D'; Criteri = 'C'
            Stato = $global:FxConfig.Stati.pronto; Tag = @(); Area = 'DevOps.Agents\AI\Stime'; CreataDa = $null }
        $global:FxTask = @([pscustomobject]@{ Id = 62; Titolo = 'Task gia presente'; Descrizione = 'd'; Stato = 'New'; Tipo = 'Task' })
    }

    It 'crea-task legge i task da stdin, intatti: dollaro, backtick e trattino iniziale' {
        $testo = "=== Primo`n-Area non valida: `$null e ``y```nseconda riga`n=== Secondo`nTesto`r`n"
        Invoke-CardTask 'responsabile' $null 'crea-task' $testo | Should -Be 0
        Should -Invoke New-AdoTask -ModuleName Card -Times 2 -Exactly
        Should -Invoke New-AdoTask -ModuleName Card -Times 1 -Exactly -ParameterFilter {
            $Titolo -eq 'Primo' -and $Descrizione -eq "-Area non valida: `$null e ``y```nseconda riga" }
    }
    It 'crea-task da dev e rifiutato' {
        Invoke-CardTask 'dev' $null 'crea-task' "=== A`nb" | Should -Be 1
        Should -Invoke New-AdoTask -ModuleName Card -Times 0 -Exactly
    }
    It 'crea-task con il testo come argomento da errore e indica stdin' {
        Invoke-CardTask 'responsabile' $null 'crea-task' '' 'ciao' | Should -Be 1
        Should -Invoke New-AdoTask -ModuleName Card -Times 0 -Exactly
    }
    It 'crea-task con stdin vuoto da errore' {
        Invoke-CardTask 'responsabile' $null 'crea-task' '' | Should -Be 1
        Should -Invoke New-AdoTask -ModuleName Card -Times 0 -Exactly
    }
    It 'chiudi-task chiude il task di ATTREZZI_TASK' {
        Invoke-CardTask 'dev' '62' 'chiudi-task' '' | Should -Be 0
        Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Id -eq 62 }
    }
    It 'chiudi-task rifiuta un task diverso da ATTREZZI_TASK' {
        Invoke-CardTask 'dev' '62' 'chiudi-task' '' '63' | Should -Be 1
        Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 0 -Exactly
    }
    It 'chiudi-task senza ATTREZZI_TASK da errore' {
        Invoke-CardTask 'dev' $null 'chiudi-task' '' | Should -Be 1
        Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 0 -Exactly
    }
    It 'chiudi-task da responsabile e rifiutato' {
        Invoke-CardTask 'responsabile' '62' 'chiudi-task' '' | Should -Be 1
        Should -Invoke Set-AdoTaskStato -ModuleName Card -Times 0 -Exactly
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }
