BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Impostazioni.psm1') -Force -Global
    function New-Dati { $d = Join-Path $TestDrive ('dati-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null; $d }
    function Set-FileImpostazioni($Dati, [string]$Json) { [IO.File]::WriteAllText((Join-Path $Dati 'impostazioni.json'), $Json, [Text.UTF8Encoding]::new($false)) }
}

Describe 'Get-Impostazioni (D53)' {
    It 'senza il file: canale non impostato, automatico acceso, nessun override' {
        $i = Get-Impostazioni (New-Dati)
        $i.Canale | Should -BeNullOrEmpty
        $i.Automatico | Should -BeTrue
        @($i.Limiti.PSObject.Properties).Count | Should -Be 0
        @($i.Supervisore.PSObject.Properties).Count | Should -Be 0
    }
    It 'legge canale, automatico e gli override delle due sezioni' {
        $d = New-Dati
        Set-FileImpostazioni $d '{ "canale": "develop", "aggiornamentoAutomatico": false, "limiti": { "sogliaQuotaSettimanale": 0.85 }, "supervisore": { "diagnosiAlGiorno": 1 } }'
        $i = Get-Impostazioni $d
        $i.Canale | Should -Be 'develop'
        $i.Automatico | Should -BeFalse
        $i.Limiti.sogliaQuotaSettimanale | Should -Be 0.85
        $i.Supervisore.diagnosiAlGiorno | Should -Be 1
    }
    It 'rispetta ATTREZZI_DATI quando la cartella non e indicata' {
        $d = New-Dati; Set-FileImpostazioni $d '{ "canale": "develop" }'
        $prima = $env:ATTREZZI_DATI
        try { $env:ATTREZZI_DATI = $d; (Get-Impostazioni).Canale | Should -Be 'develop' }
        finally { $env:ATTREZZI_DATI = $prima }
    }
    It 'un canale che non e main o develop e un errore chiaro' {
        $d = New-Dati; Set-FileImpostazioni $d '{ "canale": "release" }'
        { Get-Impostazioni $d } | Should -Throw "*'canale' deve essere main o develop*"
    }
    It 'aggiornamentoAutomatico non booleano e un errore chiaro' {
        $d = New-Dati; Set-FileImpostazioni $d '{ "aggiornamentoAutomatico": "si" }'
        { Get-Impostazioni $d } | Should -Throw "*'aggiornamentoAutomatico' deve essere vero o falso*"
    }
    It 'una sezione che non e un oggetto, o un file che non e JSON, sono errori chiari' {
        $d = New-Dati; Set-FileImpostazioni $d '{ "limiti": 3 }'
        { Get-Impostazioni $d } | Should -Throw "*'limiti' deve essere un oggetto*"
        Set-FileImpostazioni $d '{ non json'
        { Get-Impostazioni $d } | Should -Throw '*non e un JSON valido*'
        Set-FileImpostazioni $d '[1,2]'
        { Get-Impostazioni $d } | Should -Throw '*non e un oggetto JSON*'
    }
}

Describe 'Set-Impostazione e Add-OverrideNuovi (D53)' {
    It 'Set-Impostazione cambia una chiave e lascia il resto' {
        $d = New-Dati; Set-FileImpostazioni $d '{ "canale": "develop", "limiti": { "sogliaQuotaSettimanale": 0.85 } }'
        Set-Impostazione -Nome 'aggiornamentoAutomatico' -Valore $false -CartellaDati $d
        $i = Get-Impostazioni $d
        $i.Automatico | Should -BeFalse
        $i.Canale | Should -Be 'develop'
        $i.Limiti.sogliaQuotaSettimanale | Should -Be 0.85
    }
    It 'Set-Impostazione crea il file se non c e' {
        $d = New-Dati
        Set-Impostazione -Nome 'canale' -Valore 'main' -CartellaDati $d
        (Get-Impostazioni $d).Canale | Should -Be 'main'
    }
    It 'Add-OverrideNuovi aggiunge le chiavi nuove e non sovrascrive un override gia presente' {
        $d = New-Dati; Set-FileImpostazioni $d '{ "limiti": { "sogliaQuotaSettimanale": 0.9 } }'
        $aggiunte = Add-OverrideNuovi -Sezione 'limiti' -Valori @{ sogliaQuotaSettimanale = 0.85; margineQuotaMinuti = 7 } -CartellaDati $d
        @($aggiunte) | Should -Be @('margineQuotaMinuti')
        $i = Get-Impostazioni $d
        $i.Limiti.sogliaQuotaSettimanale | Should -Be 0.9
        $i.Limiti.margineQuotaMinuti | Should -Be 7
    }
    It 'Add-OverrideNuovi crea la sezione se manca' {
        $d = New-Dati
        [void](Add-OverrideNuovi -Sezione 'supervisore' -Valori @{ diagnosiAlGiorno = 2 } -CartellaDati $d)
        (Get-Impostazioni $d).Supervisore.diagnosiAlGiorno | Should -Be 2
    }
}

Describe 'Merge-OverrideConfig, Read-ConfigConOverride e Get-ChiaviDiverse (D53)' {
    It 'le chiavi di primo livello si sostituiscono, anche con un oggetto intero' {
        $base = '{ "a": 1, "b": { "x": 1, "y": 2 } }' | ConvertFrom-Json
        $ov = '{ "b": { "x": 9 } }' | ConvertFrom-Json
        $r = Merge-OverrideConfig $base $ov 'limiti'
        $r.a | Should -Be 1
        $r.b.x | Should -Be 9
        $r.b.PSObject.Properties.Name | Should -Not -Contain 'y'
    }
    It 'una chiave che il file non ha e un errore: un refuso non passa per una chiave valida' {
        $base = '{ "a": 1 }' | ConvertFrom-Json
        { Merge-OverrideConfig $base ('{ "aa": 2 }' | ConvertFrom-Json) 'limiti' } | Should -Throw "*'limiti.aa' non esiste in config/limiti.json*"
    }
    It 'Read-ConfigConOverride legge il file della radice e applica gli override della cartella dati' {
        $radice = Join-Path $TestDrive ('r-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory "$radice/config" | Out-Null
        Set-Content "$radice/config/limiti.json" '{ "intervalloMinuti": 2, "sessioniAttive": 3 }'
        $d = New-Dati; Set-FileImpostazioni $d '{ "limiti": { "intervalloMinuti": 9 } }'
        $c = Read-ConfigConOverride -Radice $radice -Nome 'limiti' -CartellaDati $d
        $c.intervalloMinuti | Should -Be 9
        $c.sessioniAttive | Should -Be 3
        { Read-ConfigConOverride -Radice $radice -Nome 'supervisore' -CartellaDati $d } | Should -Throw '*mancante*'
    }
    It 'Get-ChiaviDiverse da solo le chiavi cambiate rispetto al riferimento, confrontando il JSON e non il testo' {
        $rif = '{ "a": 0.70, "b": 1, "c": { "x": 1 }, "d": true }' | ConvertFrom-Json
        $att = '{ "a": 0.85, "b": 1.0, "c": { "x": 1 }, "d": true, "nuova": 5 }' | ConvertFrom-Json
        $d = Get-ChiaviDiverse -Attuale $att -Riferimento $rif
        @($d.Keys) | Should -Be @('a', 'nuova')
        $d['a'] | Should -Be 0.85
    }
}

Describe 'Impostazioni: lettura, modifica e scrittura sono un passo solo (D53)' {
    It 'due processi che scrivono chiavi diverse insieme non si cancellano a vicenda' {
        $d = New-Dati
        $modulo = Join-Path $PSScriptRoot '../src/Impostazioni.psm1'
        1..2 | ForEach-Object -Parallel {
            Import-Module $using:modulo -Force
            foreach ($i in 1..15) { Set-Impostazione -Nome "chiave$($_)_$i" -Valore $i -CartellaDati $using:d }
        } -ThrottleLimit 2
        $o = Read-ImpostazioniGrezze $d
        @($o.PSObject.Properties).Count | Should -Be 30
    }
    It 'un override aggiunto mentre un altro processo scrive una chiave non si perde' {
        $d = New-Dati
        $modulo = Join-Path $PSScriptRoot '../src/Impostazioni.psm1'
        1..2 | ForEach-Object -Parallel {
            Import-Module $using:modulo -Force
            foreach ($i in 1..10) {
                if ($_ -eq 1) { Set-Impostazione -Nome "a$i" -Valore $i -CartellaDati $using:d }
                else { [void](Add-OverrideNuovi -Sezione 'limiti' -Valori @{ "k$i" = $i } -CartellaDati $using:d) }
            }
        } -ThrottleLimit 2
        $o = Read-ImpostazioniGrezze $d
        @($o.PSObject.Properties | Where-Object { $_.Name -like 'a*' }).Count | Should -Be 10
        @($o.limiti.PSObject.Properties).Count | Should -Be 10
    }
}
