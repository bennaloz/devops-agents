BeforeAll {
    # D53: Get-Config e Get-ConfigSupervisore leggono impostazioni.json dalla cartella dati: i test non devono vedere quella vera di chi li lancia.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    Import-Module (Join-Path $PSScriptRoot '../src/Config.psm1') -Force
    $script:Repo = Split-Path -Parent $PSScriptRoot

    # Copia dei file di config in una radice temporanea, con brief fittizi.
    function New-RadiceProva {
        $r = Join-Path ([IO.Path]::GetTempPath()) ("cfg-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path "$r/config", "$r/ruoli" | Out-Null
        Copy-Item "$script:Repo/config/*.json" "$r/config"
        foreach ($n in 'responsabile', 'dev', 'reviewer', 'collaudatore', 'mentore', 'supervisore') { Set-Content "$r/ruoli/$n.md" 'brief di prova' }
        $r
    }
}

Describe 'Get-Config' {
    BeforeEach { $script:R = New-RadiceProva }
    AfterEach { Remove-Item $script:R -Recurse -Force -ErrorAction SilentlyContinue }

    It 'carica i quattro file' {
        $c = Get-Config -Radice $script:R
        $c.Stati.inDeployTest | Should -Be 'Deploying to test'
        $c.Stati.inCollaudo | Should -Be 'Automated test'
        $c.Stati.inProvaUmana | Should -Be 'Human test'
        $c.Stati.PSObject.Properties.Name | Should -Not -Contain 'inTest'
        $c.Ruoli.dev.modello | Should -Be 'opus'
        $c.Ruoli.dev.sforzo | Should -Be 'medium'
        $c.Limiti.giriRevisione | Should -Be 2
        $c.Mappa.aree.Count | Should -BeGreaterThan 0
        $c.Mappa.progettoBoard | Should -Be 'DevOps.Agents'
    }

    It 'la shell dei ruoli e PowerShell, non Bash' {
        $c = Get-Config -Radice $script:R
        foreach ($r in $c.Ruoli.PSObject.Properties) {
            $r.Value.strumenti | Should -Contain 'PowerShell'
            $r.Value.strumenti | Should -Not -Contain 'Bash'
        }
    }

    It 'ogni ruolo ha lo strumento Skill: senza, --tools gli toglie la skill regole-sviluppo' {
        $c = Get-Config -Radice $script:R
        # il supervisore e di sola lettura e non carica le regole di sviluppo: non ha Skill (D51)
        foreach ($r in $c.Ruoli.PSObject.Properties | Where-Object Name -ne 'supervisore') {
            $r.Value.strumenti | Should -Contain 'Skill' -Because "il ruolo $($r.Name) deve poter caricare regole-sviluppo"
        }
    }

    It 'il ruolo supervisore (D51): sonnet, medium, sola lettura, nessuna transizione, senza Skill ne scrittura' {
        $r = (Get-Config -Radice $script:R).Ruoli.supervisore
        $r.modello | Should -Be 'sonnet'
        $r.sforzo | Should -Be 'medium'
        $r.brief | Should -Be 'ruoli/supervisore.md'
        @($r.strumenti) | Should -Be @('Read', 'Grep', 'Glob', 'PowerShell')
        @($r.transizioni).Count | Should -Be 0
        Test-RuoloSolaLettura $r | Should -BeTrue
    }

    It 'errore se una transizione usa una chiave assente da stati.json' {
        $p = "$script:R/config/ruoli.json"
        (Get-Content $p -Raw).Replace('"daUnire"', '"inventata"') | Set-Content $p
        { Get-Config -Radice $script:R } | Should -Throw '*inventata*'
    }

    It 'errore se manca progettoBoard in mappa.json' {
        $p = "$script:R/config/mappa.json"
        (Get-Content $p -Raw) -replace '"progettoBoard":\s*"[^"]*",?', '' | Set-Content $p
        { Get-Config -Radice $script:R } | Should -Throw '*progettoBoard*'
    }

    It 'la sorgente del codice (github) vuole repoGithub nella forma owner/repo; ado o assente va bene' {
        $p = "$script:R/config/mappa.json"
        $m = Get-Content $p -Raw | ConvertFrom-Json
        $m.aree[0] | Add-Member sorgente 'github' -Force
        $m | ConvertTo-Json -Depth 10 | Set-Content $p
        { Get-Config -Radice $script:R } | Should -Throw "*repoGithub*"
        $m.aree[0] | Add-Member repoGithub 'acme/web' -Force
        $m | ConvertTo-Json -Depth 10 | Set-Content $p
        (Get-Config -Radice $script:R).Mappa.aree[0].repoGithub | Should -Be 'acme/web'
        $m.aree[0].sorgente = 'gitlab'
        $m | ConvertTo-Json -Depth 10 | Set-Content $p
        { Get-Config -Radice $script:R } | Should -Throw "*ado o github*"
    }

    It 'i limiti della quota (D51) si leggono' {
        $c = Get-Config -Radice $script:R
        $c.Limiti.sogliaQuotaSettimanale | Should -Be 0.70
        $c.Limiti.margineQuotaMinuti | Should -Be 5
    }

    It 'errore se manca sogliaQuotaSettimanale o e fuori da 0..1' {
        $p = "$script:R/config/limiti.json"
        $orig = Get-Content $p -Raw
        $orig -replace '"sogliaQuotaSettimanale":\s*[0-9.]+,?', '' | Set-Content $p
        { Get-Config -Radice $script:R } | Should -Throw '*sogliaQuotaSettimanale*'
        $orig -replace '"sogliaQuotaSettimanale":\s*[0-9.]+', '"sogliaQuotaSettimanale": 1.5' | Set-Content $p
        { Get-Config -Radice $script:R } | Should -Throw '*sogliaQuotaSettimanale*'
    }

    It 'errore se margineQuotaMinuti e negativo' {
        $p = "$script:R/config/limiti.json"
        (Get-Content $p -Raw) -replace '"margineQuotaMinuti":\s*[0-9]+', '"margineQuotaMinuti": -1' | Set-Content $p
        { Get-Config -Radice $script:R } | Should -Throw '*margineQuotaMinuti*'
    }

    It 'D52: funzionalitaAttive e accesa nel file che si spedisce (gruppo 5)' {
        $v = (Get-Config -Radice $script:R).Limiti.funzionalitaAttive
        $v | Should -BeOfType [bool]
        $v | Should -BeTrue
    }

    It 'D52: errore se funzionalitaAttive manca o non e vero/falso' {
        $p = "$script:R/config/limiti.json"
        $orig = Get-Content $p -Raw
        $orig -replace '"funzionalitaAttive":\s*(true|false),?', '' | Set-Content $p
        { Get-Config -Radice $script:R } | Should -Throw '*funzionalitaAttive*'
        $orig -replace '"funzionalitaAttive":\s*(true|false)', '"funzionalitaAttive": "no"' | Set-Content $p
        { Get-Config -Radice $script:R } | Should -Throw '*funzionalitaAttive*'
    }

    It 'D52: gli stati della Feature sono in stati.json' {
        $c = Get-Config -Radice $script:R
        $c.Stati.featureNuova | Should -Be 'New'
        $c.Stati.featureAttiva | Should -Be 'Active'
        $c.Stati.featureRisolta | Should -Be 'Resolved'
        $c.Stati.featureChiusa | Should -Be 'Closed'
        $c.Stati.featureRimossa | Should -Be 'Removed'
    }

    It 'D52: errore se manca uno stato della Feature' -ForEach 'featureNuova', 'featureAttiva', 'featureRisolta', 'featureChiusa', 'featureRimossa' {
        $p = "$script:R/config/stati.json"
        (Get-Content $p -Raw) -replace "`"$_`":\s*`"[^`"]*`",?", '' | Set-Content $p
        { Get-Config -Radice $script:R } | Should -Throw "*$_*"
    }

    It 'errore se un brief non esiste' {
        Remove-Item "$script:R/ruoli/dev.md"
        { Get-Config -Radice $script:R } | Should -Throw '*dev*brief*'
    }
}

Describe 'Get-VoceMappa' {
    It 'restituisce la riga giusta' {
        $v = Get-VoceMappa -Area 'DevOps.Agents\AI\Stime'
        $v.repo | Should -Be 'Acme.AI'
        $v.pipelineDeploy | Should -Be 115
    }

    It 'errore con area sconosciuta' {
        { Get-VoceMappa -Area 'Non\Esiste' } | Should -Throw '*sconosciuta*'
    }
}

Describe 'Find-VoceMappa' {
    It 'cerca nella mappa gia letta e restituisce null se l area non c e' {
        $mappa = Get-Content (Join-Path $script:Repo 'config/mappa.json') -Raw | ConvertFrom-Json
        (Find-VoceMappa -Mappa $mappa -Area 'DevOps.Agents\AI\Stime').repo | Should -Be 'Acme.AI'
        Find-VoceMappa -Mappa $mappa -Area 'Non\Esiste' | Should -BeNullOrEmpty
    }
    It 'Get-VoceMappa con la mappa gia letta non rilegge il file' {
        $mappa = [pscustomobject]@{ aree = @([pscustomobject]@{ area = 'A\B'; repo = 'R' }) }
        (Get-VoceMappa -Area 'A\B' -Mappa $mappa).repo | Should -Be 'R'
        { Get-VoceMappa -Area 'X' -Mappa $mappa } | Should -Throw '*sconosciuta*'
    }
}

Describe 'Il ruolo collaudatore' {
    It 'esiste, con Opus medio, il suo brief, senza strumenti di scrittura e senza transizioni' {
        $r = (Get-Content (Join-Path $PSScriptRoot '../config/ruoli.json') -Raw | ConvertFrom-Json).collaudatore
        $r | Should -Not -BeNullOrEmpty
        $r.modello | Should -Be 'opus'
        $r.sforzo | Should -Be 'medium'
        $r.brief | Should -Be 'ruoli/collaudatore.md'
        Test-Path (Join-Path $PSScriptRoot "../$($r.brief)") | Should -BeTrue
        @($r.strumenti) | Should -Not -Contain 'Write'
        @($r.strumenti) | Should -Not -Contain 'Edit'
        @($r.transizioni).Count | Should -Be 0
    }
}

Describe 'Il ruolo mentore (D46)' {
    It 'e valido: Opus a sforzo alto, il suo brief, solo lettura e shell, nessuna transizione' {
        $c = Get-Config -Radice $script:Repo
        $r = $c.Ruoli.mentore
        $r | Should -Not -BeNullOrEmpty
        $r.modello | Should -Be 'opus'
        $r.sforzo | Should -Be 'high'
        $r.brief | Should -Be 'ruoli/mentore.md'
        Test-Path (Join-Path $script:Repo $r.brief) | Should -BeTrue
        (@($r.strumenti) -join ',') | Should -Be 'Read,Grep,Glob,PowerShell,Skill'
        @($r.transizioni).Count | Should -Be 0
        Test-RuoloSolaLettura -RuoloConfig $r | Should -BeTrue
    }
}

Describe 'Test-RuoloSolaLettura' {
    BeforeAll { $script:Ruoli = Get-Content (Join-Path $PSScriptRoot '../config/ruoli.json') -Raw | ConvertFrom-Json }

    It 'dev scrive i file: non e in sola lettura' {
        Test-RuoloSolaLettura -RuoloConfig $script:Ruoli.dev | Should -BeFalse
    }

    It '<_> non ha strumenti che scrivono file: e in sola lettura' -ForEach 'responsabile', 'reviewer', 'collaudatore' {
        Test-RuoloSolaLettura -RuoloConfig $script:Ruoli.$_ | Should -BeTrue
    }

    It 'basta uno strumento che scrive perche il ruolo non sia in sola lettura' {
        Test-RuoloSolaLettura -RuoloConfig ([pscustomobject]@{ strumenti = @('Read', 'Edit') }) | Should -BeFalse
    }
}

Describe 'Get-Config con gli override di impostazioni.json (D53)' {
    BeforeEach {
        $script:R = New-RadiceProva
        $script:Dati = Join-Path ([IO.Path]::GetTempPath()) ("dati-" + [guid]::NewGuid())
        New-Item -ItemType Directory $script:Dati | Out-Null
    }
    AfterEach { Remove-Item $script:R, $script:Dati -Recurse -Force -ErrorAction SilentlyContinue }

    It 'senza impostazioni.json vale il file del repo' {
        (Get-Config -Radice $script:R -CartellaDati $script:Dati).Limiti.sogliaQuotaSettimanale | Should -Be 0.70
    }
    It 'un override sostituisce la chiave del file e lascia le altre' {
        Set-Content (Join-Path $script:Dati 'impostazioni.json') '{ "limiti": { "sogliaQuotaSettimanale": 0.85 } }'
        $l = (Get-Config -Radice $script:R -CartellaDati $script:Dati).Limiti
        $l.sogliaQuotaSettimanale | Should -Be 0.85
        $l.sessioniAttive | Should -Be 3
    }
    It 'senza -CartellaDati legge quella di ATTREZZI_DATI' {
        Set-Content (Join-Path $script:Dati 'impostazioni.json') '{ "limiti": { "sogliaQuotaSettimanale": 0.55 } }'
        $prima = $env:ATTREZZI_DATI
        try { $env:ATTREZZI_DATI = $script:Dati; (Get-Config -Radice $script:R).Limiti.sogliaQuotaSettimanale | Should -Be 0.55 }
        finally { $env:ATTREZZI_DATI = $prima }
    }
    It 'un override invalido e un errore chiaro che dice da dove viene (come per il file)' {
        Set-Content (Join-Path $script:Dati 'impostazioni.json') '{ "limiti": { "sogliaQuotaSettimanale": 1.5 } }'
        { Get-Config -Radice $script:R -CartellaDati $script:Dati } | Should -Throw "*'sogliaQuotaSettimanale' deve essere fra 0 (escluso) e 1*impostazioni.json*sogliaQuotaSettimanale*"
        Set-Content (Join-Path $script:Dati 'impostazioni.json') '{ "limiti": { "funzionalitaAttive": "no" } }'
        { Get-Config -Radice $script:R -CartellaDati $script:Dati } | Should -Throw "*funzionalitaAttive*vero/falso*impostazioni.json*"
    }
    It 'un override con una chiave che limiti.json non ha e un errore' {
        Set-Content (Join-Path $script:Dati 'impostazioni.json') '{ "limiti": { "sogliaQuotaSetimanale": 0.8 } }'
        { Get-Config -Radice $script:R -CartellaDati $script:Dati } | Should -Throw "*'limiti.sogliaQuotaSetimanale' non esiste*"
    }
    It 'un file di config del repo invalido resta un errore senza il suffisso degli override' {
        $f = Join-Path $script:R 'config/limiti.json'
        $l = Get-Content $f -Raw | ConvertFrom-Json; $l.sogliaQuotaSettimanale = 2; $l | ConvertTo-Json | Set-Content $f
        try { Get-Config -Radice $script:R -CartellaDati $script:Dati; throw 'doveva fallire' } catch { $_.Exception.Message | Should -Not -Match 'impostazioni.json' }
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }
