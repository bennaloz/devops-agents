BeforeAll {
    # D53: Get-Config e Get-ConfigSupervisore leggono impostazioni.json dalla cartella dati: i test non devono vedere quella vera di chi li lancia.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    # I moduli si caricano prima, nello stesso modo dello script, cosi i Mock trovano i comandi da sostituire.
    foreach ($m in 'Config', 'Ado', 'Stato', 'Decisioni', 'Sessioni', 'Memoria', 'MemoriaRepo') {
        Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Global
    }
    . (Join-Path $PSScriptRoot '../src/Istantanea.ps1')
    $script:Cfg = Get-Config
    $script:Stati = $script:Cfg.Stati
    # l'interruttore di D52 e spento in config/limiti.json fino al gruppo 4: i test della funzionalita lo accendono
    $script:Cfg.Limiti.funzionalitaAttive = $true

    # il log dello script che carica Istantanea.ps1: qui raccoglie le righe
    function Write-Log([string]$Livello, [string]$Messaggio) { $global:FxLog += "$Livello $Messaggio" }

    function script:Nuova-Card([int]$Id, [string]$Chiave = 'inRevisione', $PadreId = $null) {
        [pscustomobject]@{ Id = $Id; Rev = 3; Tipo = 'User Story'; Titolo = "Card $Id"; Stato = $script:Stati.$Chiave; Tag = @($script:Stati.tagAgenti); Area = 'DevOps.Agents\AI\Stime'; PadreId = $PadreId }
    }
    function script:Nuova-Figlia([int]$Id, [string]$Chiave = 'inSviluppo', [string[]]$Tag = @()) {
        [pscustomobject]@{ Id = $Id; Stato = $script:Stati.$Chiave; Tag = @($Tag); Tipo = 'User Story' }
    }
    function script:Nuovo-Padre([int]$Id = 7, [string]$Tipo = 'Feature') {
        [pscustomobject]@{ Id = $Id; Tipo = $Tipo; Titolo = 'Una funzionalita'; Stato = 'New'; Tag = @(); Area = 'DevOps.Agents\AI\Stime'; FigliIds = @(20, 21, 22) }
    }
    # Il mondo finto: i padri (id -> padre) e le figlie di ogni padre (id -> figlie). Le chiamate si contano sui mock.
    function script:Imposta-Mondo($Padri, $Figlie) {
        # le figlie che il padre elenca sono quelle che il mondo finto ha (un padre che ne elenca di piu e un caso a parte)
        foreach ($k in @($Padri.Keys)) { if ($Figlie.ContainsKey($k)) { $Padri[$k].FigliIds = @($Figlie[$k] | ForEach-Object { $_.Id }) } }
        $global:FxPadri = $Padri
        $global:FxFiglie = $Figlie
        $global:FxLog = @()
        Mock Get-AdoFeature { $global:FxPadri[[int]$Id] }
        Mock Get-AdoFigliFeature { @($global:FxFiglie[7]) }
    }
    function script:Nuovo-Contesto { New-ContestoGiro $script:Cfg @() 'u-ric' (Join-Path $TestDrive 'quota-inesistente.json') }
    $script:ConChiusura = {
        @{ 7 = @((script:Nuova-Figlia 20), (script:Nuova-Figlia 21 'inFeature'), (script:Nuova-Figlia 22 'bozza' @($script:Stati.tagChiusura, $script:Stati.tagAgenti))) }
    }
}

Describe 'Get-FunzionalitaCard' {
    It 'una card senza padre e isolata: null e nessuna chiamata in piu' {
        script:Imposta-Mondo @{} @{}
        Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20) (script:Nuovo-Contesto) | Should -BeNullOrEmpty
        Should -Invoke Get-AdoFeature -Times 0 -Exactly
        Should -Invoke Get-AdoFigliFeature -Times 0 -Exactly
    }

    It 'una Feature senza card di chiusura non e una funzionalita D52: la card e isolata' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } @{ 7 = @((script:Nuova-Figlia 20), (script:Nuova-Figlia 21)) }
        Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto) | Should -BeNullOrEmpty
    }

    It 'una card della funzionalita: Feature, chiusura, sorelle senza la chiusura, Ramo nullo, non e la chiusura' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        $f = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto)
        $f.Feature.Id | Should -Be 7
        $f.Chiusura | Should -Be 22
        @($f.Sorelle | ForEach-Object Id) | Should -Be @(20, 21)
        $f.Ramo | Should -BeNullOrEmpty
        $f.EChiusura | Should -BeFalse
    }

    It 'la card di chiusura sa di esserlo' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        $f = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 22 'bozza' 7) (script:Nuovo-Contesto)
        $f.EChiusura | Should -BeTrue
        $f.Chiusura | Should -Be 22
        @($f.Sorelle | ForEach-Object Id) | Should -Be @(20, 21)
    }

    It 'una sorella Removed non e fra le sorelle' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } @{ 7 = @(
            (script:Nuova-Figlia 20), (script:Nuova-Figlia 21 'rimossa'), (script:Nuova-Figlia 22 'bozza' @($script:Stati.tagChiusura))) }
        $f = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto)
        @($f.Sorelle | ForEach-Object Id) | Should -Be @(20)
    }

    It 'due card della stessa Feature nello stesso giro: due chiamate in totale (il padre e le figlie), nessuna per card' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        $ctx = script:Nuovo-Contesto
        $a = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) $ctx
        $b = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 21 'inRevisione' 7) $ctx
        Should -Invoke Get-AdoFeature -Times 1 -Exactly
        Should -Invoke Get-AdoFigliFeature -Times 1 -Exactly
        $a.Chiusura | Should -Be 22
        $b.Chiusura | Should -Be 22
    }

    It 'un padre che non e una Feature: la card e isolata, il padre si legge una volta sola, le figlie mai' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre 7 'Epic') } @{}
        $ctx = script:Nuovo-Contesto
        Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) $ctx | Should -BeNullOrEmpty
        Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 21 'inRevisione' 7) $ctx | Should -BeNullOrEmpty
        Should -Invoke Get-AdoFeature -Times 1 -Exactly
        Should -Invoke Get-AdoFigliFeature -Times 0 -Exactly
    }

    It 'un giro nuovo (contesto nuovo) rilegge il padre e le figlie' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        $null = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto)
        $null = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto)
        Should -Invoke Get-AdoFeature -Times 2 -Exactly
        Should -Invoke Get-AdoFigliFeature -Times 2 -Exactly
    }

    It 'la lettura del padre che fallisce da Errore (non null), un WARN nel log, una lettura sola per il giro' {
        script:Imposta-Mondo @{} @{}
        Mock Get-AdoFeature { throw 'ADO non risponde' }
        $ctx = script:Nuovo-Contesto
        $a = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) $ctx
        $b = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 21 'inRevisione' 7) $ctx
        $a | Should -Not -BeNullOrEmpty
        $a.Errore | Should -BeLike '*ADO non risponde*'
        $b.Errore | Should -BeLike '*ADO non risponde*'
        Should -Invoke Get-AdoFeature -Times 1 -Exactly
        $global:FxLog.Count | Should -Be 1
        $global:FxLog[0] | Should -BeLike 'WARN*7*ADO non risponde*'
    }

    It 'la lettura delle figlie che fallisce da Errore, non una card isolata' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } @{}
        Mock Get-AdoFigliFeature { throw 'figlie illeggibili' }
        $f = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto)
        $f.Errore | Should -BeLike '*figlie illeggibili*'
        $global:FxLog.Count | Should -Be 1
    }
}

Describe 'Get-FunzionalitaCard: il ramo della funzionalita' {
    BeforeEach {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        $global:FxRamo = 'feature/f7-una-funzionalita'
        Mock Get-AdoRamoCard { $global:FxRamo }
        $script:VoceRepo = [pscustomobject]@{ repo = 'Repo.Prova'; cartella = 'C:\principale'; progettoAdo = 'P' }
    }

    It 'riempie Ramo con il ramo trovato su origin per id della Feature, via REST nel progetto e nel repo della Voce' {
        $f = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto) $script:VoceRepo
        $f.Ramo | Should -Be 'feature/f7-una-funzionalita'
        Should -Invoke Get-AdoRamoCard -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'P' -and $Repo -eq 'Repo.Prova' -and $FeatureId -eq 7 }
    }

    It 'un ramo non ancora pubblicato e Ramo nullo, non un errore' {
        $global:FxRamo = $null
        $f = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto) $script:VoceRepo
        $f.Errore | Should -BeNullOrEmpty
        $f.Ramo | Should -BeNullOrEmpty
        $f.Chiusura | Should -Be 22
    }

    It 'una ricerca sola per Feature in un giro con due card (e con la chiusura), nella stessa cache' {
        $ctx = script:Nuovo-Contesto
        $a = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) $ctx $script:VoceRepo
        $b = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 21 'inRevisione' 7) $ctx $script:VoceRepo
        $c = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 22 'bozza' 7) $ctx $script:VoceRepo
        Should -Invoke Get-AdoRamoCard -Times 1 -Exactly
        $a.Ramo | Should -Be $b.Ramo
        $c.Ramo | Should -Be 'feature/f7-una-funzionalita'
    }

    It 'un ramo nullo resta in cache per il giro: una sola ricerca anche se non c e' {
        $global:FxRamo = $null
        $ctx = script:Nuovo-Contesto
        $null = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) $ctx $script:VoceRepo
        $null = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 21 'inRevisione' 7) $ctx $script:VoceRepo
        Should -Invoke Get-AdoRamoCard -Times 1 -Exactly
    }

    It 'un giro nuovo cerca di nuovo il ramo' {
        $null = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto) $script:VoceRepo
        $null = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto) $script:VoceRepo
        Should -Invoke Get-AdoRamoCard -Times 2 -Exactly
    }

    It 'una card isolata non costa nessuna ricerca, ne una Feature senza chiusura, ne un padre che non e una Feature' {
        $ctx = script:Nuovo-Contesto
        Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 30) $ctx $script:VoceRepo | Should -BeNullOrEmpty
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } @{ 7 = @((script:Nuova-Figlia 20)) }
        Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto) $script:VoceRepo | Should -BeNullOrEmpty
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre 7 'Epic') } @{}
        Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto) $script:VoceRepo | Should -BeNullOrEmpty
        Should -Invoke Get-AdoRamoCard -Times 0 -Exactly
    }

    It 'una Feature Removed e come una card isolata: null, e nessuna ricerca' {
        $padre = script:Nuovo-Padre; $padre.Stato = $script:Stati.featureRimossa
        script:Imposta-Mondo @{ 7 = $padre } (& $script:ConChiusura)
        Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto) $script:VoceRepo | Should -BeNullOrEmpty
        Should -Invoke Get-AdoRamoCard -Times 0 -Exactly
    }

    It 'senza Voce non si cerca e Ramo resta nullo' {
        $f = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto)
        $f.Ramo | Should -BeNullOrEmpty
        Should -Invoke Get-AdoRamoCard -Times 0 -Exactly
    }

    It 'se la ricerca fallisce da Errore (mai Ramo nullo: vorrebbe dire da creare), un WARN, una ricerca sola per il giro' {
        Mock Get-AdoRamoCard { throw 'ADO non risponde' }
        $ctx = script:Nuovo-Contesto
        $a = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) $ctx $script:VoceRepo
        $b = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 21 'inRevisione' 7) $ctx $script:VoceRepo
        $a.Errore | Should -BeLike '*ADO non risponde*'
        $b.Errore | Should -BeLike '*ADO non risponde*'
        Should -Invoke Get-AdoRamoCard -Times 1 -Exactly
        $global:FxLog.Count | Should -Be 1
        $global:FxLog[0] | Should -BeLike 'WARN*7*ADO non risponde*'
    }

    It 'Get-IstantaneaCard passa la Voce: Funzionalita.Ramo e quello trovato' {
        Mock Get-AdoCommenti { @() }
        Mock Get-AdoStoriaStato { @() }
        Mock Get-RevNostre { @() }
        $i = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) $script:VoceRepo @{} @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto)
        $i.Funzionalita.Ramo | Should -Be 'feature/f7-una-funzionalita'
    }
}

Describe 'Get-IstantaneaCard: la funzionalita' {
    BeforeEach {
        Mock Get-AdoCommenti { @() }
        Mock Get-AdoStoriaStato { @() }
        Mock Get-RevNostre { @() }
    }

    It 'mette Funzionalita nell istantanea: la funzionalita per una card della Feature, null per una isolata' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        $ctx = script:Nuovo-Contesto
        $i = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) $null @{} @{} (Join-Path $TestDrive 'stato.json') $ctx
        $i.Funzionalita.Chiusura | Should -Be 22
        $j = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 30) $null @{} @{} (Join-Path $TestDrive 'stato.json') $ctx
        $j.ContainsKey('Funzionalita') | Should -BeTrue
        $j.Funzionalita | Should -BeNullOrEmpty
    }

    It 'il contesto del giro e la cache: due card della stessa Feature attraverso Get-IstantaneaCard, due chiamate in totale' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        $ctx = script:Nuovo-Contesto
        $null = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) $null @{} @{} (Join-Path $TestDrive 'stato.json') $ctx
        $null = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 21 'inRevisione' 7) $null @{} @{} (Join-Path $TestDrive 'stato.json') $ctx
        Should -Invoke Get-AdoFeature -Times 1 -Exactly
        Should -Invoke Get-AdoFigliFeature -Times 1 -Exactly
    }

    It 'una lettura che fallisce non fa cadere l istantanea: Funzionalita porta l errore' {
        script:Imposta-Mondo @{} @{}
        Mock Get-AdoFeature { throw 'rete giu' }
        $i = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) $null @{} @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto)
        $i.Funzionalita.Errore | Should -BeLike '*rete giu*'
        $i.Card.Id | Should -Be 20
    }

    It 'Get-RigaCoda passa a Get-IstantaneaCard il contesto del giro' {
        $global:FxCtx = script:Nuovo-Contesto
        Mock Get-IstantaneaCard { $null }
        $null = Get-RigaCoda $script:Cfg (script:Nuova-Card 20) $null @{} @{} (Join-Path $TestDrive 'stato.json') $global:FxCtx
        Should -Invoke Get-IstantaneaCard -Times 1 -Exactly -ParameterFilter { [object]::ReferenceEquals($Ctx, $global:FxCtx) }
    }
}

Describe 'Get-PredecessoriCard: il padre del predecessore' {
    It 'porta PadreId del predecessore (nullo senza padre) e i tag come elenco' {
        Mock Get-AdoCardPredecessori { @(
            [pscustomobject]@{ Id = 30; Stato = 'In review'; Tag = @('agents'); PadreId = 7 }
            [pscustomobject]@{ Id = 31; Stato = 'Closed'; Tag = @(); PadreId = $null }) }
        $p = @(Get-PredecessoriCard ([pscustomobject]@{ Id = 42 }) @{})
        $p[0].PadreId | Should -Be 7
        $p[1].PadreId | Should -BeNullOrEmpty
        @($p[0].Tag) | Should -Be @('agents')
        @($p[1].Tag).Count | Should -Be 0
    }
}

Describe 'Get-FunzionalitaCard: lo stato della card di chiusura (D52, gruppo 3)' {
    It 'porta StatoChiusura, il nome ADO dello stato della chiusura, senza chiamate in piu' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        $f = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto)
        $f.StatoChiusura | Should -Be $script:Stati.bozza
        Should -Invoke Get-AdoFeature -Times 1 -Exactly
        Should -Invoke Get-AdoFigliFeature -Times 1 -Exactly
    }
}

Describe 'Get-IstantaneaCard: la PR verso la destinazione e In feature branch (D52, gruppo 3)' {
    BeforeEach {
        Mock Get-AdoCommenti { @() }
        Mock Get-AdoStoriaStato { @() }
        Mock Get-RevNostre { @() }
        Mock Get-AdoTaskFigli { @() }
        Mock Get-AdoPr { $null }
        script:Imposta-Mondo @{} @{}
        $script:VoceRepo = [pscustomobject]@{ repo = 'Repo.Prova'; cartella = 'C:\principale'; progettoAdo = 'P' }
    }

    It 'legge la PR con la destinazione salvata nello stato della card' {
        $sc = @{ ramo = 'feature/20-x'; destinazione = 'feature/f7-la-funzione' }
        $null = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 20 'inRevisione') $script:VoceRepo $sc @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto)
        Should -Invoke Get-AdoPr -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/20-x' -and $Destinazione -eq 'feature/f7-la-funzione' }
    }

    It 'senza destinazione salvata (card isolata, stato di prima) la PR si cerca verso develop' {
        $sc = @{ ramo = 'feature/20-x' }
        $null = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 20 'inRevisione') $script:VoceRepo $sc @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto)
        Should -Invoke Get-AdoPr -Times 1 -Exactly -ParameterFilter { $Destinazione -eq 'develop' }
    }

    It 'In feature branch la PR si cerca anche fra le completate (e quella che ha portato la card li)' {
        $sc = @{ ramo = 'feature/20-x'; destinazione = 'feature/f7-la-funzione' }
        $null = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 20 'inFeature') $script:VoceRepo $sc @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto)
        Should -Invoke Get-AdoPr -Times 1 -Exactly -ParameterFilter { $AncheCompletate -and $Destinazione -eq 'feature/f7-la-funzione' }
    }

    It 'In review la PR si cerca solo fra le attive' {
        $sc = @{ ramo = 'feature/20-x' }
        $null = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 20 'inRevisione') $script:VoceRepo $sc @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto)
        Should -Invoke Get-AdoPr -Times 1 -Exactly -ParameterFilter { -not $AncheCompletate }
    }

    It 'In feature branch i task si leggono solo finche c e il worktree, come negli altri stati' {
        $sc = @{ ramo = 'feature/20-x'; cartella = 'C:/wt/card-20'; prId = 9 }
        $null = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 20 'inFeature') $script:VoceRepo $sc @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto)
        Should -Invoke Get-AdoTaskFigli -Times 1 -Exactly
    }

    It 'In feature branch senza il worktree i task non si leggono' {
        $sc = @{ ramo = $null; cartella = $null; prId = 9 }
        $null = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 20 'inFeature') $script:VoceRepo $sc @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto)
        Should -Invoke Get-AdoTaskFigli -Times 0 -Exactly
    }

    It 'In Ready to release senza worktree i task non si leggono, come prima' {
        $sc = @{ ramo = $null; cartella = $null; prId = 9 }
        $null = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 20 'daRilasciare') $script:VoceRepo $sc @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto)
        Should -Invoke Get-AdoTaskFigli -Times 0 -Exactly
    }
}

Describe 'Get-FunzionalitaCard: l interruttore funzionalitaAttive (D52)' {
    It 'con l interruttore spento da null e non legge niente: una chiusura taggata a mano in ADO non accende niente' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        $script:Cfg.Limiti.funzionalitaAttive = $false
        try {
            Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto) | Should -BeNullOrEmpty
            Should -Invoke Get-AdoFeature -Times 0 -Exactly
            Should -Invoke Get-AdoFigliFeature -Times 0 -Exactly
        }
        finally { $script:Cfg.Limiti.funzionalitaAttive = $true }
    }
}

Describe 'Get-IstantaneaCard: la card di chiusura (D52, gruppo 4)' {
    BeforeEach {
        Mock Get-AdoCommenti { @() }
        Mock Get-AdoStoriaStato { @() }
        Mock Get-RevNostre { @() }
        Mock Get-AdoTaskFigli { @() }
        Mock Get-AdoPr { $null }
        Mock Get-AdoRamoCard { 'feature/f7-una-funzionalita' }
        Mock Get-AdoErroriBuild { "Passo 'Run tests' fallito.`nFailed A.Test_due" }
        Mock Get-AdoRun { [pscustomobject]@{ Stato = 'completed'; Esito = 'failed'; Url = 'https://ado/9'; SourceVersion = 'c1' } }
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        $script:VoceRepo = [pscustomobject]@{ repo = 'Repo.Prova'; cartella = 'C:\principale'; progettoAdo = 'P' }
        $script:ScChiusura = { @{ ramo = 'feature/f7-una-funzionalita'; destinazione = 'develop'; cartella = $null } }
        $script:Snap = { param($Id, $Chiave, $Sc) Get-IstantaneaCard $script:Cfg (script:Nuova-Card $Id $Chiave 7) $script:VoceRepo $Sc @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto) }
    }

    It 'in Ready to develop con il ramo salvato legge la PR verso develop: la chiusura la apre da li, e ci segue la validazione' {
        $null = & $script:Snap 22 'pronto' (& $script:ScChiusura)
        Should -Invoke Get-AdoPr -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/f7-una-funzionalita' -and $Destinazione -eq 'develop' }
    }

    It 'una card della funzionalita (non la chiusura) in Ready to develop non legge nessuna PR, come prima' {
        $null = & $script:Snap 20 'pronto' @{ ramo = 'feature/20-x'; destinazione = 'feature/f7-una-funzionalita' }
        Should -Invoke Get-AdoPr -Times 0 -Exactly
    }

    It 'PR rossa: ErroriBuild sono gli errori della build della PR' {
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 58; UrlLog = 'u'; UltimoCommit = 'c1' } }
        $i = & $script:Snap 22 'pronto' (& $script:ScChiusura)
        Should -Invoke Get-AdoErroriBuild -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'P' -and $BuildId -eq 58 }
        $i.ErroriBuild | Should -BeLike '*Failed A.Test_due*'
    }

    It 'PR rossa: gli errori si chiedono con -SoloCodice (test falliti e compilazione, non l infrastruttura)' {
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 58; UrlLog = 'u'; UltimoCommit = 'c1' } }
        $null = & $script:Snap 22 'pronto' (& $script:ScChiusura)
        Should -Invoke Get-AdoErroriBuild -Times 1 -Exactly -ParameterFilter { $SoloCodice }
    }

    It 'PR rossa e log che non si legge: nel dubbio e infrastruttura, ErroriBuild nullo' {
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 58; UrlLog = 'u'; UltimoCommit = 'c1' } }
        Mock Get-AdoErroriBuild { throw 'timeline non disponibile' }
        (& $script:Snap 22 'pronto' (& $script:ScChiusura)).ErroriBuild | Should -BeNullOrEmpty
    }

    It 'D52, gruppo 5: Ready to merge con la PR rossa (dopo un rilancio di scadute): gli errori della build della PR, come in Ready to develop' {
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 58; UrlLog = 'u'; UltimoCommit = 'c1' } }
        $i = & $script:Snap 22 'daUnire' (& $script:ScChiusura)
        Should -Invoke Get-AdoErroriBuild -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'P' -and $BuildId -eq 58 -and $SoloCodice }
        $i.ErroriBuild | Should -BeLike '*Failed A.Test_due*'
    }

    It 'D52, gruppo 5: Ready to merge con la PR verde o in conflitto: nessuna lettura degli errori' {
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = 'u'; UltimoCommit = 'c1' } }
        $null = & $script:Snap 22 'daUnire' (& $script:ScChiusura)
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'conflitti'; BuildId = 58; UrlLog = 'u'; UltimoCommit = 'c1' } }
        $null = & $script:Snap 22 'daUnire' (& $script:ScChiusura)
        Should -Invoke Get-AdoErroriBuild -Times 0 -Exactly
    }

    It 'gli errori si leggono una volta per build: dal giro dopo vengono dallo stato della card, con la stessa build' {
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 58; UrlLog = 'u'; UltimoCommit = 'c1' } }
        $sc = & $script:ScChiusura
        $a = & $script:Snap 22 'pronto' $sc
        $b = & $script:Snap 22 'pronto' $sc
        $c = & $script:Snap 22 'pronto' $sc
        Should -Invoke Get-AdoErroriBuild -Times 1 -Exactly
        $b.ErroriBuild | Should -Be $a.ErroriBuild
        $c.ErroriBuild | Should -BeLike '*Failed A.Test_due*'
    }

    It 'anche l assenza di errori di codice si ricorda: nessuna rilettura per una build che e solo infrastruttura' {
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 58; UrlLog = 'u'; UltimoCommit = 'c1' } }
        Mock Get-AdoErroriBuild { $null }
        $sc = & $script:ScChiusura
        $null = & $script:Snap 22 'pronto' $sc
        $null = & $script:Snap 22 'pronto' $sc
        Should -Invoke Get-AdoErroriBuild -Times 1 -Exactly
    }

    It 'una build nuova (altro BuildId) si rilegge' {
        $sc = & $script:ScChiusura
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 58; UrlLog = 'u'; UltimoCommit = 'c1' } }
        $null = & $script:Snap 22 'pronto' $sc
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 59; UrlLog = 'u'; UltimoCommit = 'c2' } }
        $null = & $script:Snap 22 'pronto' $sc
        Should -Invoke Get-AdoErroriBuild -Times 2 -Exactly
    }

    It 'una lettura fallita non si ricorda: si riprova al giro dopo' {
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 58; UrlLog = 'u'; UltimoCommit = 'c1' } }
        Mock Get-AdoErroriBuild { throw 'rete giu' }
        $sc = & $script:ScChiusura
        $null = & $script:Snap 22 'pronto' $sc
        $null = & $script:Snap 22 'pronto' $sc
        Should -Invoke Get-AdoErroriBuild -Times 2 -Exactly
    }

    It 'PR verde o in corso: nessuna lettura degli errori' {
        Mock Get-AdoPr { [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = 'u'; UltimoCommit = 'c1' } }
        $i = & $script:Snap 22 'pronto' (& $script:ScChiusura)
        Should -Invoke Get-AdoErroriBuild -Times 0 -Exactly
        $i.ErroriBuild | Should -BeNullOrEmpty
    }

    It 'run del deploy fallito in Deploying to test: gli errori del run, letti con -SoloCodice' {
        $sc = & $script:ScChiusura; $sc.runId = 9
        $i = & $script:Snap 22 'inDeployTest' $sc
        Should -Invoke Get-AdoErroriBuild -Times 1 -Exactly -ParameterFilter { $BuildId -eq 9 -and $SoloCodice }
        $i.ErroriBuild | Should -BeLike '*Run tests*'
    }

    It 'run fallito senza passi falliti: ErroriBuild nullo, e il deploy fallito di sempre' {
        Mock Get-AdoErroriBuild { $null }
        $sc = & $script:ScChiusura; $sc.runId = 9
        (& $script:Snap 22 'inDeployTest' $sc).ErroriBuild | Should -BeNullOrEmpty
    }

    It 'run riuscito o in corso: nessuna lettura' {
        Mock Get-AdoRun { [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded'; Url = 'u'; SourceVersion = 'c1' } }
        $sc = & $script:ScChiusura; $sc.runId = 9
        $null = & $script:Snap 22 'inDeployTest' $sc
        Mock Get-AdoRun { [pscustomobject]@{ Stato = 'inProgress'; Esito = $null; Url = 'u'; SourceVersion = 'c1' } }
        $null = & $script:Snap 22 'inDeployTest' $sc
        Should -Invoke Get-AdoErroriBuild -Times 0 -Exactly
    }

    It 'una card isolata con un run fallito non costa nessuna lettura degli errori' {
        $sc = @{ ramo = 'feature/30-x'; runId = 9 }
        $null = Get-IstantaneaCard $script:Cfg (script:Nuova-Card 30 'inDeployTest') $script:VoceRepo $sc @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto)
        Should -Invoke Get-AdoErroriBuild -Times 0 -Exactly
    }
}

Describe 'Get-FunzionalitaCard: le figlie lette e i tipi (D52, correzioni)' {
    It 'se le figlie lette sono meno di quelle che la Feature elenca: Errore, non una funzionalita senza quella figlia' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        $global:FxPadri[7].FigliIds = @(20, 21, 22, 23)
        $f = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto)
        $f.Errore | Should -BeLike '*figlie*'
        $f.ContainsKey('Chiusura') | Should -BeFalse
    }

    It 'con tutte le figlie lette la funzionalita c e' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } (& $script:ConChiusura)
        (Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto)).Chiusura | Should -Be 22
    }

    It 'le sorelle sono solo User Story e Bug: una figlia di un altro tipo non e una sorella' {
        script:Imposta-Mondo @{ 7 = (script:Nuovo-Padre) } @{ 7 = @(
            (script:Nuova-Figlia 20), (script:Nuova-Figlia 21), [pscustomobject]@{ Id = 23; Stato = 'Active'; Tag = @(); Tipo = 'Task' },
            (script:Nuova-Figlia 22 'bozza' @($script:Stati.tagChiusura, $script:Stati.tagAgenti))) }
        $f = Get-FunzionalitaCard $script:Cfg (script:Nuova-Card 20 'inRevisione' 7) (script:Nuovo-Contesto)
        @($f.Sorelle | ForEach-Object Id) | Should -Be @(20, 21)
    }
}

Describe 'Get-RigaCoda: AspettaFunzionalita (D52, correzioni)' {
    BeforeAll {
        function script:Riga-Con([string]$Chiave, $Funz) {
            $global:FxFunz = $Funz
            Get-RigaCoda $script:Cfg (script:Nuova-Card 20 $Chiave 7) $null @{} @{} (Join-Path $TestDrive 'stato.json') (script:Nuovo-Contesto)
        }
        function script:Funz-Finta([bool]$EChiusura) {
            @{ Feature = [pscustomobject]@{ Id = 7; Titolo = 'F'; Stato = 'Active' }; Chiusura = 22; EChiusura = $EChiusura; StatoChiusura = 'Draft'; Sorelle = @() }
        }
    }
    BeforeEach {
        Mock Get-Decisione { @{ Azioni = @(); Motivo = $null } }
        Mock Get-GestoAtteso { $null }
        Mock Get-AttivitaOperatore { $null }
        Mock Get-IstantaneaCard {
            @{ Task = @(); Pr = $null; Storia = @(); Predecessori = @(); Funzionalita = $global:FxFunz }
        }
    }
    It 'una card della funzionalita In feature branch aspetta la funzionalita' {
        (script:Riga-Con 'inFeature' (script:Funz-Finta $false)).AspettaFunzionalita | Should -BeTrue
    }
    It 'la card di chiusura in <K> no: senza un motivo deve restare segnalabile come ferma' -ForEach @(
        @{ K = 'bozza' }, @{ K = 'nuova' }, @{ K = 'pronto' }
    ) {
        (script:Riga-Con $K (script:Funz-Finta $true)).AspettaFunzionalita | Should -BeFalse
    }
    It 'una card della funzionalita fuori da In feature branch no' {
        (script:Riga-Con 'inRevisione' (script:Funz-Finta $false)).AspettaFunzionalita | Should -BeFalse
    }
    It 'una card isolata In feature branch no (non e della funzionalita)' {
        (script:Riga-Con 'inFeature' $null).AspettaFunzionalita | Should -BeFalse
    }
    It 'la riga porta la funzionalita per la vista e il supervisore' {
        $r = script:Riga-Con 'inFeature' (script:Funz-Finta $false)
        $r.Funzionalita.Feature | Should -Be 7
        $r.Funzionalita.Chiusura | Should -Be 22
    }
}

Describe 'D59: l ambiente di collaudo nel contesto e nell istantanea' {
    BeforeAll {
        $script:VoceColl = [pscustomobject]@{ area = 'DevOps.Agents\AI\Stime'; repo = 'Repo.Prova'; cartella = 'C:\principale'; progettoAdo = 'P'; componente = 'stime'
            collaudo = [pscustomobject]@{ compose = 'c.yaml'; porte = @('WEB'); url = [pscustomobject]@{ Web = 'WEB' } } }
        $script:VoceSenza = [pscustomobject]@{ area = 'DevOps.Agents\AI\Ordini'; repo = 'Repo.Prova'; cartella = 'C:\principale'; progettoAdo = 'P'; componente = 'dico'; pipelineDeploy = 5 }
        $script:CfgColl = @{ Stati = $script:Cfg.Stati; Limiti = $script:Cfg.Limiti; Ruoli = $script:Cfg.Ruoli; Mappa = [pscustomobject]@{ aree = @($script:VoceColl, $script:VoceSenza) } }
        function script:Card-In([int]$Id, [string]$Chiave, [string]$Area) {
            $c = script:Nuova-Card $Id $Chiave; $c.Area = $Area; $c
        }
    }

    It 'AmbientiCollaudo conta le card in uno stato di Test il cui componente ha la voce collaudo, di qualunque componente' {
        $attive = @((script:Card-In 1 'inDeployTest' $script:VoceColl.area), (script:Card-In 2 'inCollaudo' $script:VoceColl.area), (script:Card-In 3 'inProvaUmana' $script:VoceColl.area),
            (script:Card-In 4 'inRevisione' $script:VoceColl.area), (script:Card-In 5 'inCollaudo' $script:VoceSenza.area))
        $ctx = New-ContestoGiro $script:CfgColl $attive 'u-ric' (Join-Path $TestDrive 'quota-inesistente.json')
        @($ctx.AmbientiCollaudo | Sort-Object) | Should -Be @(1, 2, 3)
        @($ctx.InTestPerComponente['dico']) | Should -Be @(5)
    }
    It 'Add-CardAlContestoTest e il punto che usano anche il giro e lo smistatore: aggiunge una volta sola' {
        $ctx = New-ContestoGiro $script:CfgColl @() 'u-ric' (Join-Path $TestDrive 'quota-inesistente.json')
        Add-CardAlContestoTest $ctx $script:VoceColl 9
        Add-CardAlContestoTest $ctx $script:VoceColl 9
        Add-CardAlContestoTest $ctx $script:VoceSenza 10
        @($ctx.AmbientiCollaudo) | Should -Be @(9)
        @($ctx.InTestPerComponente['stime']) | Should -Be @(9)
        @($ctx.InTestPerComponente['dico']) | Should -Be @(10)
    }
    Context 'Get-IstantaneaCard' {
        BeforeEach {
            Mock Get-AdoCommenti { @() }; Mock Get-AdoStoriaStato { @() }; Mock Get-RevNostre { @() }; Mock Get-AdoTaskFigli { @() }
            Mock Get-AdoPr { $null }; Mock Get-AdoRun { throw 'non deve leggere un run' }
            Mock Get-EsitoAmbienteCollaudo { [pscustomobject]@{ Stato = 'completed'; Esito = 'failed'; Log = 'C:\x.log'; Url = $null } }
            Mock Get-AdoParametriDeploy { throw 'non deve leggere lo YAML' }
            $script:Sn = { param($Sc) Get-IstantaneaCard $script:CfgColl (script:Card-In 7 'inDeployTest' $script:VoceColl.area) $script:VoceColl $Sc @{} (Join-Path $TestDrive 'stato.json') (New-ContestoGiro $script:CfgColl @() 'u-ric' (Join-Path $TestDrive 'q.json')) }
        }
        It 'con un ambiente salvato il Run e l esito dell ambiente (stessa forma del run), letto con pid e avvio dello stato, senza run di Azure DevOps' {
            $i = & $script:Sn @{ collaudoProgetto = 'card-7'; collaudoSlot = 1; collaudoPid = 321; collaudoAvvio = '2026-11-26T10:00:00Z'; runDopoRev = 3 }
            $i.Run.Stato | Should -Be 'completed'; $i.Run.Esito | Should -Be 'failed'; $i.Run.Log | Should -Be 'C:\x.log'
            Should -Invoke Get-EsitoAmbienteCollaudo -Times 1 -Exactly -ParameterFilter { $Card -eq 7 -and $ProcessoId -eq 321 -and $Avvio -eq '2026-11-26T10:00:00Z' }
            Should -Invoke Get-AdoRun -Times 0 -Exactly
        }
        It 'senza ambiente salvato non c e nessun run' {
            (& $script:Sn @{}).Run | Should -BeNullOrEmpty
            Should -Invoke Get-EsitoAmbienteCollaudo -Times 0 -Exactly
        }
        It 'per la voce collaudo non si leggono la scelta del deploy ne lo YAML' {
            (& $script:Sn @{}).Deploy | Should -BeNullOrEmpty
            Should -Invoke Get-AdoParametriDeploy -Times 0 -Exactly
        }
    }
    It 'Get-RigaCoda non conta la ButtaAmbienteCollaudo fra i lavori pronti (come il mentore: non muove la card)' {
        Mock Get-IstantaneaCard { @{ Card = $null } }
        Mock Get-Decisione { @{ Azioni = @([ordered]@{ Tipo = 'ButtaAmbienteCollaudo' }); Motivo = $null } }
        Mock Get-GestoAtteso { $null }; Mock Get-AttivitaOperatore { $null }
        $r = Get-RigaCoda $script:CfgColl (script:Card-In 7 'inRevisione' $script:VoceColl.area) $script:VoceColl @{} @{} (Join-Path $TestDrive 's.json') @{}
        $r.Azioni | Should -Be 0
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }
