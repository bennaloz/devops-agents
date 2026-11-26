BeforeAll {
    # D53: i moduli che chiamano Get-Config (Card, MemoriaRepo, Sessioni) leggono impostazioni.json dalla cartella dati: non quella vera di chi lancia i test.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    Import-Module (Join-Path $PSScriptRoot '../src/Card.psm1') -Force
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:CardPs1 = Join-Path $script:Repo 'src/card.ps1'

    # La configurazione vera, senza il controllo dei brief (arrivano col task 8).
    $global:FxConfig = [pscustomobject]@{
        Stati = Get-Content (Join-Path $script:Repo 'config/stati.json') -Raw | ConvertFrom-Json
        Ruoli = Get-Content (Join-Path $script:Repo 'config/ruoli.json') -Raw | ConvertFrom-Json
        Mappa = Get-Content (Join-Path $script:Repo 'config/mappa.json') -Raw | ConvertFrom-Json
        Limiti = Get-Content (Join-Path $script:Repo 'config/limiti.json') -Raw | ConvertFrom-Json
    }
}

AfterAll { Remove-Variable FxConfig, FxCard, FxCommenti -Scope Global -ErrorAction SilentlyContinue }

Describe 'Card' {
    BeforeEach {
        Mock Get-Config -ModuleName Card { $global:FxConfig }
        Mock Get-AdoCard -ModuleName Card { $global:FxCard }
        Mock Get-AdoCommenti -ModuleName Card { $global:FxCommenti }
        Mock Get-AdoTaskFigli -ModuleName Card { @() }
        Mock Add-AdoCommento -ModuleName Card { 99 }
        Mock Set-AdoCard -ModuleName Card { 21 }
        Mock Add-RevNostra -ModuleName Card { }
        $global:FxCard = [pscustomobject]@{ Id = 5; Rev = 20; Tipo = 'User Story'; Titolo = 'Titolo di prova'
            Descrizione = 'Descrizione di prova'; Criteri = 'Criteri di prova'; Stato = $global:FxConfig.Stati.nuova; Tag = @($global:FxConfig.Stati.tagAgenti)
            Area = 'DevOps.Agents\AI\Stime'; CreataDa = $null }
        $global:FxCommenti = @()
    }

    Context 'Read-Card' {
        It 'mostra titolo, descrizione e criteri' {
            $t = Read-Card -Id 5
            $t | Should -BeLike '*Titolo di prova*'
            $t | Should -BeLike '*Descrizione di prova*'
            $t | Should -BeLike '*Criteri di prova*'
        }

        It 'non supera i 10 commenti e li mette dal più vecchio al più nuovo' {
            $global:FxCommenti = 1..15 | ForEach-Object {
                [pscustomobject]@{ Id = $_; Autore = 'X'; Testo = "testo-$_"; Quando = '2026-11-16' } }
            $t = Read-Card -Id 5
            ([regex]::Matches($t, 'testo-\d+')).Count | Should -Be 10
            $t | Should -Not -BeLike '*testo-5*' -Because 'sono tenuti gli ultimi 10: dal 6 al 15'
            $t | Should -BeLike '*testo-6*'
            $t.IndexOf('testo-6') | Should -BeLessThan $t.IndexOf('testo-15')
            $t.IndexOf('testo-14') | Should -BeLessThan $t.IndexOf('testo-15')
        }
    }

    Context 'Read-Card: tag e funzionalita (D52, gruppo 4)' {
        BeforeEach {
            Mock Get-AdoFeature -ModuleName Card { [pscustomobject]@{ Id = 7; Tipo = 'Feature'; Titolo = 'La funzione'; Stato = 'Active'; Tag = @(); Area = 'x'; FigliIds = @(5, 6, 22) } }
            Mock Get-AdoFigliFeature -ModuleName Card { @(
                    [pscustomobject]@{ Id = 5; Stato = 'In feature branch'; Tag = @('agents'); Tipo = 'User Story'; Titolo = 'Prima sorella' }
                    [pscustomobject]@{ Id = 6; Stato = 'In development'; Tag = @('agents', 'no-test-deploy'); Tipo = 'Bug'; Titolo = 'Seconda sorella' }
                    [pscustomobject]@{ Id = 22; Stato = 'New'; Tag = @('agents', 'collaudo-funzionalita'); Tipo = 'User Story'; Titolo = 'Collaudo funzionalita: La funzione' }) }
        }

        It 'mostra i tag della card' {
            $global:FxCard.Tag = @('agents', 'human-test')
            Read-Card -Id 5 | Should -Match "TAG\r?\nagents, human-test"
        }

        It 'una card senza padre non legge la Feature e non ha la sezione della funzionalita' {
            $t = Read-Card -Id 5
            $t | Should -Not -BeLike '*FUNZIONALITA*'
            Should -Invoke Get-AdoFeature -ModuleName Card -Times 0 -Exactly
        }

        It 'una card di una funzionalita mostra la Feature (id, titolo, stato) e le sorelle (id, titolo, stato, tag) senza la chiusura' {
            $global:FxCard | Add-Member PadreId 7 -Force
            $t = Read-Card -Id 5
            $t | Should -BeLike '*FUNZIONALITA*'
            $t | Should -Match ([regex]::Escape('Feature 7 [Active] La funzione'))
            $t | Should -Match ([regex]::Escape('#6 [In development] Seconda sorella (agents, no-test-deploy)'))
            $t | Should -BeLike '*card di chiusura: #22*'
            $t | Should -BeLike '*questa card e una sorella*'
            $t | Should -Not -Match ([regex]::Escape('#22 [New]'))
        }

        It 'sulla card di chiusura lo dice, e le sorelle sono le altre figlie' {
            $global:FxCard.Id = 22
            $global:FxCard | Add-Member PadreId 7 -Force
            $t = Read-Card -Id 22
            $t | Should -BeLike '*questa card e la card di chiusura*'
            $t | Should -Match ([regex]::Escape('#5 [In feature branch] Prima sorella'))
        }

        It 'un padre che non e una Feature, o una Feature senza card di chiusura, non e una funzionalita' {
            $global:FxCard | Add-Member PadreId 7 -Force
            Mock Get-AdoFeature -ModuleName Card { [pscustomobject]@{ Id = 7; Tipo = 'Epic'; Titolo = 'x'; Stato = 'New'; Tag = @(); Area = 'x'; FigliIds = @(5) } }
            Read-Card -Id 5 | Should -Not -BeLike '*FUNZIONALITA*'
            Mock Get-AdoFeature -ModuleName Card { [pscustomobject]@{ Id = 7; Tipo = 'Feature'; Titolo = 'x'; Stato = 'New'; Tag = @(); Area = 'x'; FigliIds = @(5) } }
            Mock Get-AdoFigliFeature -ModuleName Card { @([pscustomobject]@{ Id = 5; Stato = 'New'; Tag = @(); Tipo = 'User Story'; Titolo = 'a' }) }
            Read-Card -Id 5 | Should -Not -BeLike '*FUNZIONALITA*'
        }

        It 'se la Feature non si legge la lettura della card non salta: lo dice' {
            $global:FxCard | Add-Member PadreId 7 -Force
            Mock Get-AdoFeature -ModuleName Card { throw 'ADO non risponde' }
            $t = Read-Card -Id 5
            $t | Should -BeLike '*FUNZIONALITA*non si legge*ADO non risponde*'
            $t | Should -BeLike '*Titolo di prova*'
        }
    }

    Context 'Set-CardProvaUmana' {
        It 'rifiuta un ruolo che non e responsabile' {
            { Set-CardProvaUmana -Id 5 -Ruolo 'dev' -Motivo 'x' } | Should -Throw '*solo responsabile*'
            Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly
        }
        It 'senza motivo non fa niente' {
            { Set-CardProvaUmana -Id 5 -Ruolo 'responsabile' -Motivo ' ' } | Should -Throw '*motivo*'
            Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly
        }
        It 'per responsabile aggiunge il tag human-test e scrive il motivo sulla card' {
            Set-CardProvaUmana -Id 5 -Ruolo 'responsabile' -Motivo 'Il criterio sul layout lo giudica una persona.'
            Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains $global:FxConfig.Stati.tagProvaUmana }
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Id -eq 5 -and $Testo -match '^\[responsabile\]' -and $Testo -match 'human-test' -and $Testo -match 'layout' }
        }
    }

    Context 'Read-Card: il deploy in Test scelto' {
        It 'mostra i parametri dell ultimo commento di deploy, anche se e fuori dagli ultimi 10' {
            $deploy = [pscustomobject]@{ Id = 1; Autore = 'X'; Quando = 'd'; Testo = "[responsabile] Parametri del deploy in Test: deployDatabases, deployStime`n`nPerche: x" }
            $global:FxCommenti = @($deploy) + @(2..15 | ForEach-Object { [pscustomobject]@{ Id = $_; Autore = 'X'; Testo = "testo-$_"; Quando = 'd' } })
            $t = Read-Card -Id 5
            $t | Should -Match "DEPLOY IN TEST\r?\ndeployDatabases, deployStime"
        }

        It 'D59: con la voce collaudo dice che si prova nell.ambiente Docker della card, non che manca la scelta' {
            $global:FxConfig.Mappa.aree[0] | Add-Member -NotePropertyName collaudo -NotePropertyValue ([pscustomobject]@{ compose = 'c.yaml'; porte = @('WEB') }) -Force
            try {
                $t = Read-Card -Id 5
                $t | Should -Match "DEPLOY IN TEST\r?\nsi prova nell.ambiente Docker della card \(D59\)"
                $t | Should -Not -Match 'nessuna scelta'
            }
            finally { $global:FxConfig.Mappa.aree[0].PSObject.Properties.Remove('collaudo') }
        }

        It 'senza scelta lo dice' {
            $t = Read-Card -Id 5
            $t | Should -Match "DEPLOY IN TEST\r?\nnessuna scelta"
        }
    }

    Context 'Add-CardCommento' {
        It 'aggiunge prefisso e riga di attribuzione' {
            Add-CardCommento -Id 5 -Ruolo 'dev' -Testo 'fatto' | Should -Be 99
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Id -eq 5 -and $Testo.StartsWith('[dev] fatto') -and $Testo.EndsWith('— scritto da Claude (dev)') }
        }

        It 'non raddoppia prefisso e firma se il ruolo li ha gia scritti (visto nel pilota sulla card 6)' {
            $testo = "[reviewer] Revisione superata`n`n— scritto da Claude (reviewer)"
            Add-CardCommento -Id 5 -Ruolo 'reviewer' -Testo $testo | Out-Null
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Testo -eq "[reviewer] Revisione superata`n`n— scritto da Claude (reviewer)" }
        }
    }

    Context 'Move-Card' {
        It 'accetta nuova -> pronto per responsabile e registra la revisione scritta' {
            Move-Card -Id 5 -Ruolo 'responsabile' -Stato 'pronto' | Should -Be 21
            Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq $global:FxConfig.Stati.pronto }
            Should -Invoke Add-RevNostra -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Rev -eq 21 }
        }

        It 'per ogni coppia (da, a) il responsabile passa solo se la coppia e nella sua lista' {
            $config = $global:FxConfig
            $chiavi = @($config.Stati.PSObject.Properties.Name | Where-Object { $_ -notlike 'tag*' -and $_ -notlike 'feature*' })
            $ammesse = @($config.Ruoli.responsabile.transizioni | ForEach-Object { "$($_[0])>$($_[1])" })
            $ammesse.Count | Should -BeGreaterThan 0
            foreach ($da in $chiavi) {
                foreach ($a in $chiavi) {
                    $global:FxCard.Stato = $config.Stati.$da
                    $esito = try { Move-Card -Id 5 -Ruolo 'responsabile' -Stato $a | Out-Null; 'passa' } catch { 'rifiutata' }
                    $atteso = if ("$da>$a" -in $ammesse) { 'passa' } else { 'rifiutata' }
                    $esito | Should -Be $atteso -Because "$da -> $a"
                }
            }
        }

        It 'rifiuta inRevisione -> pronto per responsabile (destinazione valida, origine sbagliata)' {
            $global:FxCard.Stato = $global:FxConfig.Stati.inRevisione
            { Move-Card -Id 5 -Ruolo 'responsabile' -Stato 'pronto' } | Should -Throw
            Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly
        }

        It 'rifiuta qualunque transizione per dev' {
            $config = $global:FxConfig
            $chiavi = @($config.Stati.PSObject.Properties.Name | Where-Object { $_ -notlike 'tag*' -and $_ -notlike 'feature*' })
            foreach ($da in $chiavi) {
                $global:FxCard.Stato = $config.Stati.$da
                foreach ($a in $chiavi) {
                    { Move-Card -Id 5 -Ruolo 'dev' -Stato $a } | Should -Throw
                }
            }
            Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly
        }

        It 'rifiuta una chiave di stato sconosciuta' {
            { Move-Card -Id 5 -Ruolo 'responsabile' -Stato 'inventato' } | Should -Throw '*sconosciuto*'
        }
    }

    Context 'Set-CardCriteri' {
        It 'rifiuta dev' {
            { Set-CardCriteri -Id 5 -Ruolo 'dev' -Testo 'x' } | Should -Throw
            Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly
        }

        It 'scrive i criteri per responsabile' {
            Set-CardCriteri -Id 5 -Ruolo 'responsabile' -Testo 'nuovi criteri'
            Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Id -eq 5 -and $Criteri -eq 'nuovi criteri' }
        }
    }

    Context 'Set-CardSenzaTest' {
        # niente prova in Test: lo decide responsabile quando nessun criterio si verifica nell'ambiente di Test, e lo motiva
        It 'rifiuta un ruolo che non e responsabile' {
            { Set-CardSenzaTest -Id 5 -Ruolo 'dev' -Motivo 'x' } | Should -Throw '*solo responsabile*'
            Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly
        }

        It 'senza motivo non fa niente' {
            { Set-CardSenzaTest -Id 5 -Ruolo 'responsabile' -Motivo '  ' } | Should -Throw '*motivo*'
            Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly
        }

        It 'per responsabile aggiunge il tag e scrive il motivo sulla card' {
            Set-CardSenzaTest -Id 5 -Ruolo 'responsabile' -Motivo 'I criteri misurano la durata della pr-validation: si vedono in CI, non in Test.'
            Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains $global:FxConfig.Stati.tagSenzaTest }
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Id -eq 5 -and $Testo -match '^\[responsabile\]' -and $Testo -match 'Test' -and $Testo -match 'pr-validation' }
        }
    }

    # D43: i parametri del deploy in Test li sceglie il responsabile, fra i booleani deploy* dello YAML della pipeline
    Context 'Set-CardDeploy' {
        BeforeEach {
            # la card 5 e nell'area di Stime: pipeline 115 nella mappa
            Mock Get-AdoRamoCard -ModuleName Card { 'feature/5-x' }
            Mock Get-AdoParametriDeploy -ModuleName Card { @('deployStime', 'deployDatabases') }
        }

        It 'D59: su un componente con la voce collaudo non c e niente da scegliere: risponde senza errore e non scrive il commento' {
            $global:FxConfig.Mappa.aree[0] | Add-Member -NotePropertyName collaudo -NotePropertyValue ([pscustomobject]@{ compose = 'c.yaml'; porte = @('WEB') }) -Force
            try {
                $r = Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployStime`nperche"
                $r | Should -Match 'nell.ambiente Docker della card \(D59\)'
                $r | Should -Match 'non e un motivo per senza-test'
                Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
                Should -Invoke Get-AdoParametriDeploy -ModuleName Card -Times 0 -Exactly
            }
            finally { $global:FxConfig.Mappa.aree[0].PSObject.Properties.Remove('collaudo') }
        }

        It 'rifiuta un ruolo che non e responsabile' {
            { Set-CardDeploy -Id 5 -Ruolo 'dev' -Testo "deployStime`nperche" } | Should -Throw '*solo responsabile*'
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
        }

        It 'scrive il commento di deploy con i parametri e il perche, che lo smistatore rilegge' {
            $r = Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployDatabases, deployStime`nLa card cambia lo schema`ne il componente"
            $r | Should -Match 'deployDatabases, deployStime'
            $r | Should -Match 'feature/5-x'
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Id -eq 5 -and $Testo -match "^\[responsabile\] Parametri del deploy in Test: deployDatabases, deployStime`n" -and
                $Testo -match "Perche: La card cambia lo schema`ne il componente" }
            $global:FxScritto = $null
            Mock Add-AdoCommento -ModuleName Card { $global:FxScritto = $Testo; 99 }
            Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployDatabases deployStime`nperche" | Out-Null
            @(Get-SceltaDeploy @([pscustomobject]@{ Id = 1; Testo = $global:FxScritto })) | Should -Be @('deployDatabases', 'deployStime')
        }

        It 'legge l elenco sul ramo della card e, senza ramo, su develop' {
            Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployStime`nperche" | Out-Null
            Should -Invoke Get-AdoRamoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'Acme.AI' -and $Repo -eq 'Acme.AI' -and $CardId -eq 5 }
            Should -Invoke Get-AdoParametriDeploy -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'Acme.AI' -and $PipelineId -eq 115 -and $Ramo -eq 'feature/5-x' }
            Mock Get-AdoRamoCard -ModuleName Card { $null }
            Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployStime`nperche" | Out-Null
            Should -Invoke Get-AdoParametriDeploy -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'develop' }
        }

        It 'rifiuta un nome che non e fra i booleani deploy* dello YAML, e dice quali ci sono' {
            { Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployStime, allowDatabaseDataLoss`nperche" } |
                Should -Throw '*parametro di deploy sconosciuto: allowDatabaseDataLoss*deployStime, deployDatabases*'
            { Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "DeployStime`nperche" } | Should -Throw '*sconosciuto: DeployStime*'
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
        }

        It 'senza nomi o senza perche non scrive niente' -ForEach @(
            @{ Testo = ''; Atteso = '*parametri*' }
            @{ Testo = "`n`nsolo il perche"; Atteso = '*parametri*' }
            @{ Testo = 'deployStime'; Atteso = '*perche*' }
            @{ Testo = "deployStime`n   "; Atteso = '*perche*' }
        ) {
            { Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo $Testo } | Should -Throw $Atteso
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
        }

        It 'un nome ripetuto si scrive una volta' {
            Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployStime, deployStime`nperche" | Out-Null
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Testo -match 'Parametri del deploy in Test: deployStime\r?\n' }
        }

        It 'un componente senza deploy in Test nella mappa: errore che rimanda a senza-test' {
            $global:FxCard.Area = 'DevOps.Agents\Workflow\Forms'
            $mappa = $global:FxConfig.Mappa | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            foreach ($v in $mappa.aree) { $v.PSObject.Properties.Remove('pipelineDeploy') }
            $global:FxMappaSenza = [pscustomobject]@{ Stati = $global:FxConfig.Stati; Ruoli = $global:FxConfig.Ruoli; Mappa = $mappa }
            Mock Get-Config -ModuleName Card { $global:FxMappaSenza }
            { Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployForms`nperche" } | Should -Throw '*senza-test*'
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
        }

        Context 'la card di chiusura di una funzionalita (D52)' {
            BeforeEach {
                $global:FxCard | Add-Member PadreId 50
                Mock Get-AdoFeature -ModuleName Card { [pscustomobject]@{ Id = 50; Tipo = 'Feature'; Titolo = 'F'; Stato = 'Active'; Tag = @(); Area = 'x'; FigliIds = @(4, 5, 6) } }
                Mock Get-AdoFigliFeature -ModuleName Card {
                    @([pscustomobject]@{ Id = 4; Stato = 'Active'; Tag = @(); Tipo = 'User Story' },
                      [pscustomobject]@{ Id = 5; Stato = 'Draft'; Tag = @('collaudo-funzionalita', 'agents'); Tipo = 'User Story' },
                      [pscustomobject]@{ Id = 6; Stato = 'Active'; Tag = @(); Tipo = 'Bug' }) }
                Mock Get-AdoRamoCard -ModuleName Card { 'feature/f50-funzionalita' }
            }

            It 'la card di chiusura legge i parametri sul ramo della funzionalita, cercato per id della Feature' {
                $r = Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployStime`nperche"
                Should -Invoke Get-AdoRamoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $FeatureId -eq 50 -and $Repo -eq 'Acme.AI' }
                Should -Invoke Get-AdoParametriDeploy -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/f50-funzionalita' }
                $r | Should -Match 'feature/f50-funzionalita'
            }

            It 'la chiusura con il ramo della funzionalita non ancora pubblicato ripiega su develop, come una card isolata' {
                Mock Get-AdoRamoCard -ModuleName Card { $null }
                $r = Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployStime`nperche"
                Should -Invoke Get-AdoRamoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $FeatureId -eq 50 }
                Should -Invoke Get-AdoParametriDeploy -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'develop' }
                $r | Should -Match 'ramo develop'
            }

            It 'una sorella della funzionalita (non la chiusura) legge sul suo ramo, come una card isolata' {
                Mock Get-AdoFigliFeature -ModuleName Card {
                    @([pscustomobject]@{ Id = 5; Stato = 'Active'; Tag = @(); Tipo = 'User Story' },
                      [pscustomobject]@{ Id = 6; Stato = 'Draft'; Tag = @('collaudo-funzionalita'); Tipo = 'User Story' }) }
                Mock Get-AdoRamoCard -ModuleName Card { 'feature/5-x' }
                Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployStime`nperche" | Out-Null
                Should -Invoke Get-AdoRamoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $CardId -eq 5 }
                Should -Invoke Get-AdoParametriDeploy -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/5-x' }
            }

            It 'una card isolata non legge la Feature: nessuna chiamata in piu' {
                $global:FxCard.PadreId = $null
                Set-CardDeploy -Id 5 -Ruolo 'responsabile' -Testo "deployStime`nperche" | Out-Null
                Should -Invoke Get-AdoFeature -ModuleName Card -Times 0 -Exactly
                Should -Invoke Get-AdoFigliFeature -ModuleName Card -Times 0 -Exactly
            }
        }
    }

    Context 'Set-CardDescrizionePr' {
        BeforeEach {
            $script:file = Join-Path $TestDrive 'descrizione.md'
            [System.IO.File]::WriteAllText($script:file, "## Misure`nTempo: 12 minuti, perché più veloce`n", [System.Text.UTF8Encoding]::new($false))
            Mock Get-AdoPrCollegata -ModuleName Card { [pscustomobject]@{ Id = 1019; Stato = 'active'; Titolo = 'Base'; Progetto = 'P'; Repo = 'R'; Ramo = 'feature/5-x' } }
            Mock Get-AdoDescrizionePr -ModuleName Card { "[Card 5](http://x/5): Titolo`n`n🤖 Generated with [Claude Code](https://claude.com/claude-code)" }
            Mock Set-AdoDescrizionePr -ModuleName Card { }
        }

        It 'scrive il file dopo il link alla card, con gli accenti' {
            $r = Set-CardDescrizionePr -Id 5 -Ruolo 'dev' -File $script:file
            Should -Invoke Set-AdoDescrizionePr -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Id -eq 1019 -and $Progetto -eq 'P' -and $Repo -eq 'R' -and $Descrizione -eq "[Card 5](http://x/5): Titolo`n`n## Misure`nTempo: 12 minuti, perché più veloce" }
            $r | Should -Match '1019'
        }

        It 'con una descrizione senza il link lo rifà dalla card' {
            Mock Get-AdoDescrizionePr -ModuleName Card { 'testo scritto a mano' }
            Mock Get-AdoUrlCard -ModuleName Card { "http://x/$Id" }
            Set-CardDescrizionePr -Id 5 -Ruolo 'responsabile' -File $script:file | Out-Null
            Should -Invoke Set-AdoDescrizionePr -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Descrizione.StartsWith("[Card 5](http://x/5)`n`n## Misure") }
        }

        It 'rifiuta un testo oltre il tetto e non scrive' {
            [System.IO.File]::WriteAllText($script:file, ('a' * 4000), [System.Text.UTF8Encoding]::new($false))
            { Set-CardDescrizionePr -Id 5 -Ruolo 'dev' -File $script:file } | Should -Throw '*al massimo*'
            Should -Invoke Set-AdoDescrizionePr -ModuleName Card -Times 0 -Exactly
        }

        It 'il reviewer non puo' {
            { Set-CardDescrizionePr -Id 5 -Ruolo 'reviewer' -File $script:file } | Should -Throw '*solo dev e responsabile*'
            Should -Invoke Set-AdoDescrizionePr -ModuleName Card -Times 0 -Exactly
        }

        It 'file mancante o vuoto non scrive' {
            { Set-CardDescrizionePr -Id 5 -Ruolo 'dev' -File (Join-Path $TestDrive 'no.md') } | Should -Throw '*non trovato*'
            Set-Content -LiteralPath $script:file -Value '  '
            { Set-CardDescrizionePr -Id 5 -Ruolo 'dev' -File $script:file } | Should -Throw '*vuoto*'
            Should -Invoke Set-AdoDescrizionePr -ModuleName Card -Times 0 -Exactly
        }

        Context 'senza una PR attiva' {
            BeforeEach {
                Mock Get-AdoPrCollegata -ModuleName Card { $null }
                Mock Get-AdoUrlCard -ModuleName Card { "http://x/$Id" }
                Mock Add-CardCommento -ModuleName Card { 1 }
            }

            It 'salva il testo in un commento marcato e non tocca la PR' {
                $r = Set-CardDescrizionePr -Id 5 -Ruolo 'dev' -File $script:file
                Should -Invoke Add-CardCommento -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                    $Id -eq 5 -and $Ruolo -eq 'dev' -and $Testo -eq "Descrizione della PR:`n`n## Misure`nTempo: 12 minuti, perché più veloce" }
                Should -Invoke Set-AdoDescrizionePr -ModuleName Card -Times 0 -Exactly
                $r | Should -Match 'non ha ancora una PR'
            }

            It 'una PR gia completata vale come nessuna PR' {
                Mock Get-AdoPrCollegata -ModuleName Card { [pscustomobject]@{ Id = 9; Stato = 'completed'; Progetto = 'P'; Repo = 'R'; Ramo = 'x' } }
                Set-CardDescrizionePr -Id 5 -Ruolo 'dev' -File $script:file | Out-Null
                Should -Invoke Add-CardCommento -ModuleName Card -Times 1 -Exactly
                Should -Invoke Set-AdoDescrizionePr -ModuleName Card -Times 0 -Exactly
            }

            It 'rifiuta un testo che nella PR non starebbe' {
                [System.IO.File]::WriteAllText($script:file, ('a' * 4000), [System.Text.UTF8Encoding]::new($false))
                { Set-CardDescrizionePr -Id 5 -Ruolo 'dev' -File $script:file } | Should -Throw '*al massimo*'
                Should -Invoke Add-CardCommento -ModuleName Card -Times 0 -Exactly
            }
        }
    }

    Context 'Set-CardTitoloPr' {
        BeforeEach {
            Mock Get-AdoPrCollegata -ModuleName Card { [pscustomobject]@{ Id = 1019; Stato = 'active'; Titolo = 'Base'; Progetto = 'P'; Repo = 'R'; Ramo = 'feature/5-x' } }
            Mock Set-AdoTitoloPr -ModuleName Card { }
            Mock Start-AdoRivalutazione -ModuleName Card { 2 }
        }

        It 'rinomina la PR della card e rilancia la validazione' {
            $r = Set-CardTitoloPr -Id 5 -Ruolo 'dev' -Titolo '  feat: Base  '
            Should -Invoke Get-AdoPrCollegata -ModuleName Card -Times 1 -Exactly -ParameterFilter { $CardId -eq 5 }
            Should -Invoke Set-AdoTitoloPr -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'P' -and $Repo -eq 'R' -and $Id -eq 1019 -and $Titolo -eq 'feat: Base' }
            Should -Invoke Start-AdoRivalutazione -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/5-x' }
            $r | Should -Match '1019'
        }

        It 'il collaudatore e il reviewer non possono' {
            { Set-CardTitoloPr -Id 5 -Ruolo 'reviewer' -Titolo 'feat: x' } | Should -Throw '*solo dev e responsabile*'
            Should -Invoke Set-AdoTitoloPr -ModuleName Card -Times 0 -Exactly
        }

        It 'senza una PR attiva non tocca niente' {
            Mock Get-AdoPrCollegata -ModuleName Card { [pscustomobject]@{ Id = 1019; Stato = 'completed'; Progetto = 'P'; Repo = 'R'; Ramo = 'feature/5-x' } }
            { Set-CardTitoloPr -Id 5 -Ruolo 'responsabile' -Titolo 'feat: x' } | Should -Throw '*PR attiva*'
            Should -Invoke Set-AdoTitoloPr -ModuleName Card -Times 0 -Exactly
        }

        It 'senza titolo non fa niente' {
            { Set-CardTitoloPr -Id 5 -Ruolo 'dev' -Titolo '   ' } | Should -Throw '*titolo*'
            Should -Invoke Get-AdoPrCollegata -ModuleName Card -Times 0 -Exactly
        }
    }

    Context 'New-Card' {
        BeforeAll {
            $script:AreaOk = 'DevOps.Agents\AI\Stime'
            $script:Completo = "## Descrizione`nFare la cosa.`n`n## Criteri di accettazione`n- funziona`n`n## Recinto`nsolo src/`n`n## Riferimenti`nspec 3`n"
            function Nuovo-FileCard($Testo) {
                $f = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.md')
                Set-Content -LiteralPath $f -Value $Testo -Encoding UTF8
                $f
            }
        }
        BeforeEach {
            $script:RuoloVecchio = $env:ATTREZZI_RUOLO
            $env:ATTREZZI_RUOLO = $null
            Mock New-AdoCard -ModuleName Card {
                [pscustomobject]@{ Id = 77; Stato = $global:FxConfig.Stati.bozza; Tipo = $Tipo; Titolo = $Titolo; Area = $Area; Tag = @() } }
            Mock Get-AdoUtenteCorrente -ModuleName Card { [pscustomobject]@{ Id = 'u-9'; Nome = 'Titolare'; Email = 'titolare@example.invalid' } }
            # D60: ogni card sta in una Feature; questa raggruppa soltanto (nessuna card di chiusura), come la maggior parte
            Mock Get-AdoFeature -ModuleName Card { [pscustomobject]@{ Id = 50; Tipo = 'Feature'; Titolo = 'F'; Stato = 'Active'; Tag = @(); Area = 'altra'; FigliIds = @() } }
            Mock Get-AdoFigliFeature -ModuleName Card { @() }
        }
        AfterEach { $env:ATTREZZI_RUOLO = $script:RuoloVecchio }

        It 'D52, gruppo 5: New-Card non fa mai nascere in New: nessuna chiamata a Set-AdoCard con uno stato, per nessun tipo ne opzione' {
            foreach ($tipo in 'User Story', 'Bug') {
                New-Card -Tipo $tipo -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 -SenzaTest -ProvaUmana | Out-Null
            }
            Should -Invoke Set-AdoCard -ModuleName Card -Times 2 -Exactly -ParameterFilter { $AggiungiTag }
            Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly -ParameterFilter { $PSBoundParameters.ContainsKey('Stato') }
            # e card.ps1 non ha un parametro per chiederlo
            (Get-Command New-Card).Parameters.Keys | Should -Not -Contain 'InNew'
            (Get-Command New-Card).Parameters.Keys | Should -Not -Contain 'Stato'
        }

        It 'crea la card, poi le da il tag agenti, criteri e descrizione composta' {
            $r = New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50
            $r.Id | Should -Be 77
            Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Id -eq 77 -and $AggiungiTag -contains $global:FxConfig.Stati.tagAgenti }
            Should -Invoke New-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Tipo -eq 'User Story' -and $Titolo -eq 'T' -and $Area -eq 'DevOps.Agents\AI\Stime' -and
                -not $Tag -and $Criteri -like '*funziona*' -and
                $Descrizione -like '*Fare la cosa*' -and $Descrizione -like '*solo src/*' -and $Descrizione -like '*spec 3*' -and
                $Descrizione -notlike '*funziona*' }
        }

        It 'senza l indirizzo dell utente non crea la card: nascerebbe senza padrone e nessuno smistatore la prenderebbe' {
            Mock Get-AdoUtenteCorrente -ModuleName Card { [pscustomobject]@{ Id = 'u-9'; Nome = 'Titolare'; Email = $null } }
            { New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 } | Should -Throw '*indirizzo*'
            Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
        }

        It 'con -SenzaTest la card nasce con il tag no-test-deploy accanto ad agents' {
            New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 -SenzaTest | Out-Null
            Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $AggiungiTag -contains $global:FxConfig.Stati.tagAgenti -and $AggiungiTag -contains $global:FxConfig.Stati.tagSenzaTest }
        }

        It 'con -ProvaUmana la card nasce con il tag human-test: in Test la prova una persona' {
            New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 -ProvaUmana | Out-Null
            Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $AggiungiTag -contains $global:FxConfig.Stati.tagProvaUmana }
        }

        It 'assegna la card a chi la crea: il suo smistatore la fara avanzare' {
            New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 | Out-Null
            Should -Invoke New-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $AssegnataA -eq 'titolare@example.invalid' }
        }

        It 'con -Dopo passa le card precedenti a New-AdoCard' {
            New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 -Dopo 11, 12 | Out-Null
            Should -Invoke New-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { @($Dopo).Count -eq 2 -and $Dopo[0] -eq 11 -and $Dopo[1] -eq 12 }
        }

        It 'senza -Dopo non passa predecessori' {
            New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 | Out-Null
            Should -Invoke New-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { -not $Dopo }
        }

        It 'rifiuta una sezione mancante dicendo quale' {
            $t = $script:Completo -replace '(?s)## Recinto.*?(?=## Riferimenti)', ''
            { New-Card -Tipo 'Bug' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $t) -Feature 50 } | Should -Throw '*Recinto*'
            Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
        }

        It 'rifiuta una sezione vuota dicendo quale' {
            $t = $script:Completo -replace '(?s)## Riferimenti.*', "## Riferimenti`n   `n"
            { New-Card -Tipo 'Bug' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $t) -Feature 50 } | Should -Throw '*Riferimenti*'
            Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
        }

        It 'rifiuta un file che non esiste' {
            { New-Card -Tipo 'Bug' -Titolo 'T' -Area $script:AreaOk -File (Join-Path $TestDrive 'non-c-e.md') } | Should -Throw
        }

        It 'rifiuta un tipo diverso da User Story e Bug' {
            { New-Card -Tipo 'Task' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) } | Should -Throw
        }

        It 'rifiuta un area assente da mappa.json' {
            { New-Card -Tipo 'Bug' -Titolo 'T' -Area 'Altro\Area' -File (Nuovo-FileCard $script:Completo) -Feature 50 } | Should -Throw '*Altro*'
            Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
        }

        It 'e vietato dentro una sessione di ruolo' {
            $env:ATTREZZI_RUOLO = 'dev'
            { New-Card -Tipo 'Bug' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 } | Should -Throw '*ruolo*'
            $msg = try { New-Card -Tipo 'Bug' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50; '' } catch { $_.Exception.Message }
            $msg | Should -Not -BeLike '*ATTREZZI*'
            Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
        }

        It 'da errore se la card non nasce in bozza, senza spostarla' {
            Mock New-AdoCard -ModuleName Card { [pscustomobject]@{ Id = 78; Stato = $global:FxConfig.Stati.nuova; Tag = @() } }
            { New-Card -Tipo 'Bug' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 } | Should -Throw "*$($global:FxConfig.Stati.bozza)*"
            # nessuna chiamata che dia il tag agenti alla card nata nello stato sbagliato
            Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly
            Should -Invoke New-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { -not $Tag }
        }

        Context 'D52: Feature e card della funzionalita' {
            BeforeEach {
                $global:FxConfig.Limiti.funzionalitaAttive = $true
                $global:FxCreate = [System.Collections.Generic.List[object]]::new()
                Mock New-AdoCard -ModuleName Card {
                    $id = 100 + $global:FxCreate.Count
                    $global:FxCreate.Add([pscustomobject]@{ Id = $id; Tipo = $Tipo; Titolo = $Titolo; Tag = $Tag; Padre = $Padre; Criteri = $Criteri; Area = $Area })
                    [pscustomobject]@{ Id = $id; Stato = $global:FxConfig.Stati.bozza; Tipo = $Tipo; Titolo = $Titolo; Area = $Area; Tag = @() } }
                Mock Get-AdoFeature -ModuleName Card {
                    [pscustomobject]@{ Id = $Id; Tipo = $global:FxFeatureTipo; Titolo = 'F'; Stato = $global:FxFeatureStato; Tag = @(); Area = $global:FxFeatureArea; FigliIds = @(4, 5) } }
                Mock Get-AdoFigliFeature -ModuleName Card { @($global:FxFigli) }
                $global:FxFeatureTipo = 'Feature'; $global:FxFeatureStato = 'Active'; $global:FxFeatureArea = $script:AreaOk
                $global:FxFigli = @([pscustomobject]@{ Id = 4; Stato = 'Active'; Tag = @(); Tipo = 'User Story' },
                                    [pscustomobject]@{ Id = 5; Stato = 'Draft'; Tag = @('collaudo-funzionalita', 'agents'); Tipo = 'User Story' })
            }
            AfterEach { $global:FxConfig.Limiti.funzionalitaAttive = $false }
            AfterAll { Remove-Variable FxCreate, FxFeatureTipo, FxFeatureStato, FxFeatureArea, FxFigli -Scope Global -ErrorAction SilentlyContinue }

            It 'con l interruttore spento -Tipo Feature si rifiuta e non crea niente' {
                $global:FxConfig.Limiti.funzionalitaAttive = $false
                { New-Card -Tipo 'Feature' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) } | Should -Throw '*D52 non è ancora attiva*'
                Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
            }

            It 'con l interruttore spento -Feature si rifiuta e non legge nemmeno la Feature' {
                $global:FxConfig.Limiti.funzionalitaAttive = $false
                { New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 } | Should -Throw '*D52 non è ancora attiva*'
                Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
                Should -Invoke Get-AdoFeature -ModuleName Card -Times 0 -Exactly
            }

            It '-Tipo Feature crea la Feature e la sua card di chiusura figlia, con tag e titolo' {
                $r = New-Card -Tipo 'Feature' -Titolo 'Il filtro' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo)
                $global:FxCreate.Count | Should -Be 2
                $f, $c = $global:FxCreate
                $f.Tipo | Should -Be 'Feature'
                $f.Titolo | Should -Be 'Il filtro'
                @($f.Tag) | Should -BeNullOrEmpty
                $f.Padre | Should -BeNullOrEmpty
                $c.Tipo | Should -Be 'User Story'
                $c.Titolo | Should -Be 'Collaudo funzionalità: Il filtro'
                $c.Padre | Should -Be $f.Id
                $c.Area | Should -Be $script:AreaOk
                $c.Criteri | Should -BeLike '*funziona*'
                $f.Criteri | Should -BeNullOrEmpty -Because 'il tipo Feature non ha il campo dei criteri'
                Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                    $Id -eq $c.Id -and $AggiungiTag -contains 'agents' -and $AggiungiTag -contains 'collaudo-funzionalita' }
                $r.Id | Should -Be $f.Id
                $r.Chiusura.Id | Should -Be $c.Id
            }

            It '-Tipo Feature -Bug da alla Feature il tag bug, alla chiusura no' {
                New-Card -Tipo 'Feature' -Bug -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) | Out-Null
                @($global:FxCreate[0].Tag) | Should -Be @('bug')
                @($global:FxCreate[1].Tag) | Should -BeNullOrEmpty
            }

            It '-Bug senza -Tipo Feature si rifiuta' {
                { New-Card -Tipo 'Bug' -Bug -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) } | Should -Throw '*-Bug*Feature*'
                Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
            }

            It '-Tipo Feature con -Feature si rifiuta, e con -Dopo, -SenzaTest o -ProvaUmana (la Feature non li usa)' {
                { New-Card -Tipo 'Feature' -Feature 50 -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) } | Should -Throw '*Feature*'
                { New-Card -Tipo 'Feature' -Dopo 3 -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) } | Should -Throw '*-Dopo*'
                { New-Card -Tipo 'Feature' -SenzaTest -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) } | Should -Throw '*-SenzaTest*'
                { New-Card -Tipo 'Feature' -ProvaUmana -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) } | Should -Throw '*-ProvaUmana*'
                Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
            }

            It 'se la chiusura non si crea l errore dice quale Feature e rimasta, e la chiusura non prende tag' {
                Mock New-AdoCard -ModuleName Card {
                    if ($Tipo -eq 'Feature') { [pscustomobject]@{ Id = 100; Stato = $global:FxConfig.Stati.bozza; Tag = @() } } else { throw 'ADO non risponde' } }
                $msg = try { New-Card -Tipo 'Feature' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo); '' } catch { $_.Exception.Message }
                $msg | Should -BeLike '*Feature 100*'
                $msg | Should -BeLike '*ADO non risponde*'
                Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly
            }

            It 'se la chiusura nasce ma la marcatura fallisce l errore riporta l id della chiusura e quello della Feature' {
                Mock Set-AdoCard -ModuleName Card { throw 'tag rifiutati' }
                $msg = try { New-Card -Tipo 'Feature' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo); '' } catch { $_.Exception.Message }
                $msg | Should -BeLike '*Feature 100*'
                $msg | Should -BeLike '*card di chiusura 101*'
                $msg | Should -BeLike '*tag rifiutati*'
            }

            It 'se la chiusura non nasce l errore non inventa un id di chiusura' {
                Mock New-AdoCard -ModuleName Card {
                    if ($Tipo -eq 'Feature') { [pscustomobject]@{ Id = 100; Stato = $global:FxConfig.Stati.bozza; Tag = @() } } else { throw 'ADO non risponde' } }
                $msg = try { New-Card -Tipo 'Feature' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo); '' } catch { $_.Exception.Message }
                $msg | Should -Not -BeLike '*card di chiusura 1*'
            }

            It 'la chiusura che non nasce in bozza non prende i tag' {
                Mock New-AdoCard -ModuleName Card { [pscustomobject]@{ Id = 100 + $Titolo.Length; Stato = $(if ($Tipo -eq 'Feature') { $global:FxConfig.Stati.bozza } else { $global:FxConfig.Stati.nuova }); Tag = @() } }
                { New-Card -Tipo 'Feature' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) } | Should -Throw "*$($global:FxConfig.Stati.bozza)*"
                Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly
            }

            It '-Feature crea una card figlia della Feature, con il tag agenti' {
                $r = New-Card -Tipo 'User Story' -Titolo 'Pezzo' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50
                $global:FxCreate.Count | Should -Be 1
                $global:FxCreate[0].Padre | Should -Be 50
                $global:FxCreate[0].Tipo | Should -Be 'User Story'
                Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                    $Id -eq 100 -and $AggiungiTag -contains 'agents' -and $AggiungiTag -notcontains 'collaudo-funzionalita' }
                Should -Invoke Get-AdoFigliFeature -ModuleName Card -Times 1 -Exactly -ParameterFilter { @($FigliIds) -contains 5 }
                $r.Id | Should -Be 100
            }

            It '-Feature accetta anche un Bug, e -Dopo' {
                New-Card -Tipo 'Bug' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 -Dopo 4 | Out-Null
                Should -Invoke New-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Tipo -eq 'Bug' -and $Padre -eq 50 -and $Dopo -contains 4 }
            }

            It '-Feature rifiuta un area diversa da quella della Feature' {
                $global:FxFeatureArea = 'DevOps.Agents\AI\Altro'
                { New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 } | Should -Throw '*area*'
                Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
            }

            It '-Feature rifiuta una Feature <Stato>' -ForEach @(@{ Stato = 'Resolved' }, @{ Stato = 'Closed' }, @{ Stato = 'Removed' }) {
                $global:FxFeatureStato = $Stato
                { New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 } | Should -Throw "*$Stato*"
                Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
            }

            It '-Feature rifiuta un work item che non e una Feature' {
                $global:FxFeatureTipo = 'Epic'
                { New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 } | Should -Throw '*non e una Feature*'
                Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
            }

            It 'D60: -Feature accetta una Feature senza card di chiusura (raggruppa soltanto), anche in un area diversa' {
                $global:FxFigli = @([pscustomobject]@{ Id = 4; Stato = 'Active'; Tag = @(); Tipo = 'User Story' })
                New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 | Out-Null
                Should -Invoke New-AdoCard -ModuleName Card -Times 1 -Exactly
            }

            It 'D60: con la sola chiusura Removed la Feature raggruppa soltanto, e la card nasce' {
                $global:FxFigli = @([pscustomobject]@{ Id = 5; Stato = 'Removed'; Tag = @('collaudo-funzionalita'); Tipo = 'User Story' })
                New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) -Feature 50 | Out-Null
                Should -Invoke New-AdoCard -ModuleName Card -Times 1 -Exactly
            }

            It 'D60: una card senza -Feature si rifiuta, senza leggere Feature e senza creare niente' {
                { New-Card -Tipo 'User Story' -Titolo 'T' -Area $script:AreaOk -File (Nuovo-FileCard $script:Completo) } | Should -Throw '*-Feature*'
                Should -Invoke Get-AdoFeature -ModuleName Card -Times 0 -Exactly
                Should -Invoke New-AdoCard -ModuleName Card -Times 0 -Exactly
            }
        }
    }

    # D52, gruppo 5: la correzione che il responsabile della card di chiusura scrive, e le Bug che lo smistatore crea.
    Context 'Add-CardCorrezione (D52, gruppo 5)' {
        BeforeEach {
            Mock Get-Config -ModuleName Card { $global:FxConfig }
            # la card 5 e la card di chiusura della Feature 7; la 6 e una sorella
            Mock Get-AdoFeature -ModuleName Card { [pscustomobject]@{ Id = 7; Tipo = 'Feature'; Titolo = 'F'; Stato = 'Active'; Tag = @(); Area = 'x'; FigliIds = @(5, 6) } }
            Mock Get-AdoFigliFeature -ModuleName Card { @(
                    [pscustomobject]@{ Id = 5; Stato = 'Automated test'; Tag = @('agents', 'collaudo-funzionalita'); Tipo = 'User Story'; Titolo = 'Collaudo' }
                    [pscustomobject]@{ Id = 6; Stato = 'In feature branch'; Tag = @('agents'); Tipo = 'User Story'; Titolo = 'Pezzo' }) }
            $global:FxCard | Add-Member -NotePropertyName PadreId -NotePropertyValue 7 -Force
            $global:FxScritto = $null
            Mock Add-AdoCommento -ModuleName Card { $global:FxScritto = $Testo; 99 }
            $script:Testo = "tecnico`n=== Il totale non somma`nIl totale ignora le righe scontate.`nAtteso: le somma."
        }
        AfterAll { Remove-Variable FxScritto -Scope Global -ErrorAction SilentlyContinue }

        It 'solo il responsabile: dev non scrive correzioni' {
            { Add-CardCorrezione -Id 5 -Ruolo 'dev' -Testo $script:Testo } | Should -Throw '*solo responsabile*'
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
        }

        It 'solo sulla card di chiusura: una card isolata si rifiuta, senza leggere la Feature' {
            $global:FxCard.PadreId = $null
            { Add-CardCorrezione -Id 5 -Ruolo 'responsabile' -Testo $script:Testo } | Should -Throw '*card di chiusura*'
            Should -Invoke Get-AdoFeature -ModuleName Card -Times 0 -Exactly
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
        }

        It 'solo sulla card di chiusura: una sorella della stessa Feature si rifiuta' {
            $global:FxCard.Id = 6
            { Add-CardCorrezione -Id 6 -Ruolo 'responsabile' -Testo $script:Testo } | Should -Throw '*card di chiusura*'
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
        }

        It 'la prima riga deve essere tecnico o prodotto' {
            { Add-CardCorrezione -Id 5 -Ruolo 'responsabile' -Testo "urgente`n=== T`nD" } | Should -Throw '*tecnico*prodotto*'
            { Add-CardCorrezione -Id 5 -Ruolo 'responsabile' -Testo "=== T`nD" } | Should -Throw '*tecnico*prodotto*'
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
        }

        It 'serve un titolo e una descrizione: senza uno dei due si rifiuta' {
            { Add-CardCorrezione -Id 5 -Ruolo 'responsabile' -Testo "tecnico`nsolo testo senza titolo" } | Should -Throw '*===*'
            { Add-CardCorrezione -Id 5 -Ruolo 'responsabile' -Testo "tecnico`n=== Solo il titolo" } | Should -Throw '*testo*'
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
        }

        It 'una correzione per comando: due titoli si rifiutano' {
            { Add-CardCorrezione -Id 5 -Ruolo 'responsabile' -Testo "tecnico`n=== Uno`nA`n=== Due`nB" } | Should -Throw '*una sola correzione*'
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
        }

        It 'scrive un solo commento firmato [responsabile] con la marca, che lo smistatore rilegge cosi come e' {
            Add-CardCorrezione -Id 5 -Ruolo 'responsabile' -Testo $script:Testo | Out-Null
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Id -eq 5 }
            $global:FxScritto | Should -BeLike '[[]responsabile] Correzione: tecnico*'
            $c = @(Get-CorrezioniScritte @([pscustomobject]@{ Id = 9; Testo = $global:FxScritto }))
            $c.Count | Should -Be 1
            $c[0].Tipo | Should -Be 'tecnico'
            $c[0].Titolo | Should -Be 'Il totale non somma'
            $c[0].Descrizione | Should -Be "Il totale ignora le righe scontate.`nAtteso: le somma."
        }

        It 'il tipo prodotto passa' {
            Add-CardCorrezione -Id 5 -Ruolo 'responsabile' -Testo "prodotto`n=== Quale arrotondamento`nDue strade, serve una scelta." | Out-Null
            $global:FxScritto | Should -BeLike '[[]responsabile] Correzione: prodotto*'
        }
    }

    Context 'le Bug che lo smistatore crea (D52, gruppo 5)' {
        BeforeEach {
            $global:FxCreate = [System.Collections.Generic.List[object]]::new()
            Mock New-AdoCard -ModuleName Card {
                $global:FxCreate.Add([pscustomobject]@{ Tipo = $Tipo; Titolo = $Titolo; Area = $Area; Descrizione = $Descrizione; Criteri = $Criteri; Padre = $Padre; AssegnataA = $AssegnataA; Tag = $Tag })
                [pscustomobject]@{ Id = 300; Stato = $global:FxConfig.Stati.bozza; Tipo = $Tipo; Titolo = $Titolo; Area = $Area; Tag = @() } }
            $script:Feat = [pscustomobject]@{ Id = 7; Titolo = 'La funzione'; Area = 'DevOps.Agents\AI\Stime'; Stato = 'Active'; Tag = @() }
        }
        AfterAll { Remove-Variable FxCreate, FxOrdine -Scope Global -ErrorAction SilentlyContinue }

        It 'correzione tecnica: una Bug figlia della Feature, nell area della Feature, con il tag agenti, in New' {
            $corr = [pscustomobject]@{ Id = 41; Tipo = 'tecnico'; Titolo = 'Il totale non somma'; Descrizione = 'Il totale ignora le righe scontate.' }
            $b = New-CardCorrezioneFunzionalita -Config $global:FxConfig -Feature $script:Feat -Chiusura 22 -Correzione $corr -AssegnataA 'titolare@example.invalid'
            $b.Id | Should -Be 300
            $global:FxCreate.Count | Should -Be 1
            $global:FxCreate[0].Tipo | Should -Be 'Bug'
            $global:FxCreate[0].Titolo | Should -Be 'Il totale non somma'
            $global:FxCreate[0].Padre | Should -Be 7
            $global:FxCreate[0].Area | Should -Be 'DevOps.Agents\AI\Stime'
            $global:FxCreate[0].AssegnataA | Should -Be 'titolare@example.invalid'
            $global:FxCreate[0].Descrizione | Should -BeLike '*Il totale ignora le righe scontate.*'
            $global:FxCreate[0].Descrizione | Should -BeLike '*#22*'
            Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Id -eq 300 -and $AggiungiTag -contains 'agents' -and $Stato -eq 'New' }
        }

        It 'la configurazione la da lo smistatore: i creatori non la rileggono' {
            Mock Get-Config -ModuleName Card { throw 'non si rilegge' }
            $corr = [pscustomobject]@{ Id = 41; Tipo = 'tecnico'; Titolo = 'T'; Descrizione = 'D' }
            { New-CardCorrezioneFunzionalita -Config $global:FxConfig -Feature $script:Feat -Chiusura 22 -Correzione $corr -AssegnataA 'a@b.c' } | Should -Not -Throw
            { New-CardAllineaDevelop -Config $global:FxConfig -Feature $script:Feat -Ramo 'feature/f7-x' -AssegnataA 'a@b.c' } | Should -Not -Throw
        }

        It 'correzione di prodotto: resta in Draft con il tag agenti, e il via a New lo da una persona' {
            $corr = [pscustomobject]@{ Id = 42; Tipo = 'prodotto'; Titolo = 'Quale arrotondamento'; Descrizione = 'Serve una scelta.' }
            New-CardCorrezioneFunzionalita -Config $global:FxConfig -Feature $script:Feat -Chiusura 22 -Correzione $corr -AssegnataA 'titolare@example.invalid' | Out-Null
            Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Id -eq 300 -and $AggiungiTag -contains 'agents' }
            Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly -ParameterFilter { $Stato }
        }

        It 'la Bug che non nasce in Draft non prende ne tag ne stato' {
            Mock New-AdoCard -ModuleName Card { [pscustomobject]@{ Id = 301; Stato = $global:FxConfig.Stati.nuova; Tag = @() } }
            $corr = [pscustomobject]@{ Id = 41; Tipo = 'tecnico'; Titolo = 'T'; Descrizione = 'D' }
            { New-CardCorrezioneFunzionalita -Config $global:FxConfig -Feature $script:Feat -Chiusura 22 -Correzione $corr -AssegnataA 'a@b.c' } | Should -Throw "*$($global:FxConfig.Stati.bozza)*"
            Should -Invoke Set-AdoCard -ModuleName Card -Times 0 -Exactly
        }

        It 'allinea-develop: titolo, criteri, tag agents e allinea-develop, direttamente in Ready to develop (dev parte senza il responsabile), figlia della Feature' {
            $b = New-CardAllineaDevelop -Config $global:FxConfig -Feature $script:Feat -Ramo 'feature/f7-la-funzione' -AssegnataA 'titolare@example.invalid'
            $b.Id | Should -Be 300
            $global:FxCreate[0].Tipo | Should -Be 'Bug'
            $global:FxCreate[0].Titolo | Should -Be 'Allinea feature/f7-la-funzione a develop'
            $global:FxCreate[0].Criteri | Should -Be 'la PR feature/f7-la-funzione → develop non ha conflitti'
            $global:FxCreate[0].Padre | Should -Be 7
            $global:FxCreate[0].Area | Should -Be 'DevOps.Agents\AI\Stime'
            $global:FxCreate[0].Descrizione | Should -BeLike '*origin/develop*'
            Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Id -eq 300 -and $AggiungiTag -contains 'agents' -and $AggiungiTag -contains 'allinea-develop' -and $Stato -eq 'Ready to develop' }
        }

        It 'DopoNascita gira appena la Bug esiste, prima di tag e stato' {
            $global:FxOrdine = [System.Collections.Generic.List[string]]::new()
            Mock Set-AdoCard -ModuleName Card { $global:FxOrdine.Add('tag'); 21 }
            $corr = [pscustomobject]@{ Id = 41; Tipo = 'tecnico'; Titolo = 'T'; Descrizione = 'D' }
            New-CardCorrezioneFunzionalita -Config $global:FxConfig -Feature $script:Feat -Chiusura 22 -Correzione $corr -AssegnataA 'a@b.c' -DopoNascita { param($b) $global:FxOrdine.Add("nata $($b.Id)") } | Out-Null
            @($global:FxOrdine) | Should -Be @('nata 300', 'tag')
        }

        It 'se tag o stato falliscono dopo la nascita l errore dice quale Bug e nata e cosa completare a mano; DopoNascita e gia girata' {
            Mock Set-AdoCard -ModuleName Card { throw 'tag rifiutati' }
            $global:FxOrdine = [System.Collections.Generic.List[string]]::new()
            $corr = [pscustomobject]@{ Id = 41; Tipo = 'tecnico'; Titolo = 'T'; Descrizione = 'D' }
            $msg = try { New-CardCorrezioneFunzionalita -Config $global:FxConfig -Feature $script:Feat -Chiusura 22 -Correzione $corr -AssegnataA 'a@b.c' -DopoNascita { param($b) $global:FxOrdine.Add('marca') }; '' } catch { $_.Exception.Message }
            $msg | Should -BeLike '*Bug 300*'
            $msg | Should -BeLike '*a mano*'
            $msg | Should -BeLike '*agents*'
            $msg | Should -BeLike '*New*'
            $msg | Should -BeLike '*tag rifiutati*'
            @($global:FxOrdine) | Should -Be @('marca')
            $msg2 = try { New-CardAllineaDevelop -Config $global:FxConfig -Feature $script:Feat -Ramo 'feature/f7-x' -AssegnataA 'a@b.c'; '' } catch { $_.Exception.Message }
            $msg2 | Should -BeLike '*Bug 300*'
            $msg2 | Should -BeLike '*allinea-develop*'
            $msg2 | Should -BeLike '*Ready to develop*'
        }
    }
}

Describe 'card.ps1' {
    BeforeAll {
        # card.ps1 di una radice di prova (src, config e ruoli copiati) con funzionalitaAttive spento: il test dichiara il valore,
        # non dipende da config/limiti.json, che e acceso. Ritorna il percorso del card.ps1 della radice.
        function New-CardPs1ConFunzionalitaSpente {
            . (Join-Path $PSScriptRoot 'finti/Radice.ps1')
            $radice = New-RadiceDiProva -Cartella $TestDrive -Limiti @{ funzionalitaAttive = $false }
            Copy-Item (Join-Path $script:Repo 'src') (Join-Path $radice 'src') -Recurse
            Join-Path $radice 'src/card.ps1'
        }
        # -Script: un altro card.ps1 (per esempio quello di una radice di prova con i limiti scelti dal test)
        function Invoke-CardPs1($Id, $Ruolo, [string[]]$Argomenti, [string]$Script = $script:CardPs1) {
            $vecchi = @($env:ATTREZZI_CARD, $env:ATTREZZI_RUOLO)
            $env:ATTREZZI_CARD = $Id; $env:ATTREZZI_RUOLO = $Ruolo
            try {
                $out = & pwsh -NoProfile -File $Script @Argomenti 2>&1
                [pscustomobject]@{ Codice = $LASTEXITCODE; Testo = ($out | Out-String) }
            }
            finally { $env:ATTREZZI_CARD = $vecchi[0]; $env:ATTREZZI_RUOLO = $vecchi[1] }
        }
    }

    It 'esce con codice 1 e un messaggio se manca ATTREZZI_CARD' {
        $r = Invoke-CardPs1 $null 'dev' @('leggi')
        $r.Codice | Should -Be 1
        $r.Testo | Should -BeLike '*ATTREZZI_CARD*'
    }

    It 'esce con codice 1 e un messaggio se manca ATTREZZI_RUOLO' {
        $r = Invoke-CardPs1 '5' $null @('leggi')
        $r.Codice | Should -Be 1
        $r.Testo | Should -BeLike '*ATTREZZI_RUOLO*'
    }

    It 'esce con codice 1 su un comando sconosciuto, senza chiamare Azure DevOps' {
        $r = Invoke-CardPs1 '5' 'dev' @('boh')
        $r.Codice | Should -Be 1
        $r.Testo | Should -BeLike '*sconosciuto*'
    }

    It 'crea esce con codice 1 dentro una sessione di ruolo' {
        $r = Invoke-CardPs1 '5' 'dev' @('crea', '-Tipo', 'Bug', '-Titolo', 'T', '-Area', 'x', '-File', 'y.md')
        $r.Codice | Should -Be 1
        $r.Testo | Should -BeLike '*ruolo*'
        $r.Testo | Should -Not -BeLike '*ATTREZZI*'
    }

    It 'crea non richiede ATTREZZI_CARD e ATTREZZI_RUOLO: l errore viene dal file, non dalle variabili' {
        $r = Invoke-CardPs1 $null $null @('crea', '-Tipo', 'Bug', '-Titolo', 'T', '-Area', 'x', '-File', 'non-esiste.md')
        $r.Codice | Should -Be 1
        $r.Testo | Should -Not -BeLike '*ATTREZZI_*'
        $r.Testo | Should -BeLike '*non-esiste*'
    }

    It 'crea accetta -Dopo con una lista "11,12" (arriva come stringa sola): l errore successivo viene dal file' {
        $r = Invoke-CardPs1 $null $null @('crea', '-Tipo', 'Bug', '-Titolo', 'T', '-Area', 'x', '-File', 'non-esiste.md', '-Dopo', '11,12')
        $r.Codice | Should -Be 1
        $r.Testo | Should -BeLike '*non-esiste*'
    }

    It 'D52: crea -Tipo Feature con la funzionalita spenta esce con 1 e lo dice, prima di guardare il file' {
        $r = Invoke-CardPs1 $null $null @('crea', '-Tipo', 'Feature', '-Bug', '-Titolo', 'T', '-Area', 'x', '-File', 'non-esiste.md') -Script (New-CardPs1ConFunzionalitaSpente)
        $r.Codice | Should -Be 1
        $r.Testo | Should -BeLike '*D52 non è ancora attiva*'
        $r.Testo | Should -Not -BeLike '*non-esiste*'
    }

    It 'D52: crea -Feature con la funzionalita spenta esce con 1 e lo dice' {
        $r = Invoke-CardPs1 $null $null @('crea', '-Tipo', 'User Story', '-Feature', '50', '-Titolo', 'T', '-Area', 'x', '-File', 'non-esiste.md') -Script (New-CardPs1ConFunzionalitaSpente)
        $r.Codice | Should -Be 1
        $r.Testo | Should -BeLike '*D52 non è ancora attiva*'
    }

    It 'crea rifiuta un -Dopo che non e fatto di numeri' {
        $r = Invoke-CardPs1 $null $null @('crea', '-Tipo', 'Bug', '-Titolo', 'T', '-Area', 'x', '-File', 'non-esiste.md', '-Dopo', 'abc')
        $r.Codice | Should -Be 1
        $r.Testo | Should -Not -BeLike '*non-esiste*'
    }

    Context 'testo da stdin' {
        BeforeAll {
            function Invoke-CardInProcess($Ruolo, $Comando, $Stdin, $Argomento) {
                $vecchi = @($env:ATTREZZI_CARD, $env:ATTREZZI_RUOLO, [Console]::In)
                $env:ATTREZZI_CARD = '5'; $env:ATTREZZI_RUOLO = $Ruolo
                [Console]::SetIn([IO.StringReader]::new([string]$Stdin))
                try {
                    $global:LASTEXITCODE = 0
                    if ($Argomento) { $null = & $script:CardPs1 $Comando $Argomento 2>&1 } else { $null = & $script:CardPs1 $Comando 2>&1 }
                    $global:LASTEXITCODE
                }
                finally { $env:ATTREZZI_CARD = $vecchi[0]; $env:ATTREZZI_RUOLO = $vecchi[1]; [Console]::SetIn($vecchi[2]) }
            }
        }
        BeforeEach {
            Mock Get-Config -ModuleName Card { $global:FxConfig }
            Mock Add-AdoCommento -ModuleName Card { 99 }
            Mock Set-AdoCard -ModuleName Card { 21 }
        }

        It 'commenta arriva intatto da stdin: dollaro, backtick e trattino iniziale' {
            $global:FxTesto = '-Area non valida: $null e $x, vedi `src/Ado.psm1:224` e `regole`' + "`nseconda riga"
            Invoke-CardInProcess 'reviewer' 'commenta' ($global:FxTesto + "`r`n") | Should -Be 0
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 1 -Exactly -ParameterFilter {
                $Testo -eq ("[reviewer] " + $global:FxTesto + "`n`n— scritto da Claude (reviewer)") }
        }

        It 'criteri arriva intatto da stdin' {
            $global:FxTesto = 'dato $x il risultato e `y`'
            Invoke-CardInProcess 'responsabile' 'criteri' $global:FxTesto | Should -Be 0
            Should -Invoke Set-AdoCard -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Criteri -eq $global:FxTesto }
        }

        It 'un testo passato come argomento da errore e indica stdin, senza scrivere niente' {
            Invoke-CardInProcess 'dev' 'commenta' '' 'ciao' | Should -Be 1
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
            $r = Invoke-CardPs1 '5' 'dev' @('commenta', 'ciao')
            $r.Codice | Should -Be 1
            $r.Testo | Should -BeLike '*stdin*'
        }

        It 'deploy prende parametri e perche da stdin e scrive il commento' {
            Mock Get-AdoCard -ModuleName Card { [pscustomobject]@{ Id = 5; Area = 'DevOps.Agents\AI\Stime'; Stato = 'New'; Tag = @() } }
            Mock Get-AdoRamoCard -ModuleName Card { $null }
            Mock Get-AdoParametriDeploy -ModuleName Card { @('deployStime') }
            Invoke-CardInProcess 'responsabile' 'deploy' "deployStime`r`nil `$perche`r`n" | Should -Be 0
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Testo -match 'Parametri del deploy in Test: deployStime' -and $Testo -match 'Perche: il \$perche' }
            Invoke-CardInProcess 'responsabile' 'deploy' '' 'deployStime' | Should -Be 1
        }

        It 'D52: correzione prende tipo, titolo e descrizione da stdin (dollaro e backtick compresi) e scrive il commento' {
            Mock Get-AdoCard -ModuleName Card { [pscustomobject]@{ Id = 5; Area = 'x'; Stato = 'Automated test'; Tag = @(); PadreId = 7 } }
            Mock Get-AdoFeature -ModuleName Card { [pscustomobject]@{ Id = 7; Tipo = 'Feature'; Titolo = 'F'; Stato = 'Active'; Tag = @(); Area = 'x'; FigliIds = @(5) } }
            Mock Get-AdoFigliFeature -ModuleName Card { @([pscustomobject]@{ Id = 5; Stato = 'Automated test'; Tag = @('collaudo-funzionalita'); Tipo = 'User Story'; Titolo = 'C' }) }
            $entrata = "tecnico`r`n=== Il `$totale`r`n" + 'Atteso: la `somma' + "`r`n"
            Invoke-CardInProcess 'responsabile' 'correzione' $entrata | Should -Be 0
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 1 -Exactly -ParameterFilter { $Testo -match 'Correzione: tecnico' -and $Testo -match 'Titolo: Il \$totale' -and $Testo -match 'la `somma' }
            Invoke-CardInProcess 'responsabile' 'correzione' '' 'tecnico' | Should -Be 1
            Invoke-CardInProcess 'dev' 'correzione' "tecnico`n=== T`nD" | Should -Be 1
        }

        It 'uno stdin vuoto da errore' {
            Invoke-CardInProcess 'dev' 'commenta' '' | Should -Be 1
            Should -Invoke Add-AdoCommento -ModuleName Card -Times 0 -Exactly
        }
    }

    It 'i moduli si caricano in qualunque ordine lasciando al chiamante le funzioni di entrambi' {
        $src = Join-Path $script:Repo 'src'
        $ordini = @(
            @('Ado', 'Card'), @('Card', 'Ado'), @('Card'), @('Stato', 'Card', 'Ado', 'Config'), @('Ado', 'Card', 'Stato')
        )
        foreach ($o in $ordini) {
            $imports = ($o | ForEach-Object { "Import-Module '$src/$_.psm1' -Force" }) -join '; '
            $cmd = "$imports; foreach (`$f in 'Read-Card','Move-Card','Get-AdoCard','Set-AdoCard','Add-RevNostra','Get-Config') { if (-not (Get-Command `$f -ErrorAction SilentlyContinue)) { Write-Output ('MANCA ' + `$f) } }; 'FINE'"
            $out = (& pwsh -NoProfile -Command $cmd 2>&1 | Out-String).Trim()
            $out | Should -Be 'FINE' -Because ($o -join ' > ')
        }
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }
