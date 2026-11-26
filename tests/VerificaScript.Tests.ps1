# D53: la verifica di una versione appena aggiornata lancia lo smistatore e il supervisore con -WhatIf e guarda il codice di uscita. Un giro che si
# interrompe deve quindi uscire con un codice diverso da 0, altrimenti la verifica non verifica niente. Qui gli script veri (copiati) con un modulo
# che va in errore durante l'esecuzione, non uno stub che fa exit 2.
BeforeAll {
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:IdentitaPrima = @{}
    foreach ($n in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL') { $script:IdentitaPrima[$n] = [Environment]::GetEnvironmentVariable($n) }
    $env:GIT_AUTHOR_NAME = 'prova'; $env:GIT_AUTHOR_EMAIL = 'prova@example.com'; $env:GIT_COMMITTER_NAME = 'prova'; $env:GIT_COMMITTER_EMAIL = 'prova@example.com'

    # Una copia degli script veri; con -Rompi Get-Config lancia (un guasto durante il giro, non all'avvio dello script).
    function New-Albero([switch]$Rompi) {
        $r = Join-Path $TestDrive ('albero-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $r | Out-Null
        foreach ($d in 'src', 'config', 'ruoli', 'setup', 'hooks') { Copy-Item (Join-Path $script:Repo $d) (Join-Path $r $d) -Recurse }
        if ($Rompi) {
            $f = Join-Path $r 'src/Config.psm1'
            $t = [IO.File]::ReadAllText($f)
            $voglio = '$imp = Get-Impostazioni $CartellaDati'
            if (-not $t.Contains($voglio)) { throw 'Config.psm1 non ha piu la riga attesa: aggiorna il test' }
            [IO.File]::WriteAllText($f, $t.Replace($voglio, "throw 'guasto di prova'"))
        }
        $r
    }
    function New-Cartella([string]$Nome) { $d = Join-Path $TestDrive ($Nome + '-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null; $d }
    function Invoke-Script($Albero, [string]$Nome, [string[]]$Argomenti, [string]$Dati, [string]$Claude) {
        $extra = if ($Nome -eq 'Supervisore.ps1') { @('-ClaudeDir', $Claude, '-PercorsoPatInfo', (Join-Path $Claude 'nessun-pat-info.json')) } else { @() }
        $out = & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path $Albero "src/$Nome") -CartellaDati $Dati @extra @Argomenti 2>&1 | Out-String
        [pscustomobject]@{ Codice = $LASTEXITCODE; Uscita = $out }
    }
}

AfterAll {
    $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento
    foreach ($n in $script:IdentitaPrima.Keys) { [Environment]::SetEnvironmentVariable($n, $script:IdentitaPrima[$n]) }
}

Describe 'Smistatore.ps1 -WhatIf: un giro che si interrompe esce con un codice diverso da 0 (D53)' {
    It 'con un errore durante il giro esce con un codice diverso da 0 e lo scrive' {
        $r = Invoke-Script (New-Albero -Rompi) 'Smistatore.ps1' @('-WhatIf') (New-Cartella 'dati')
        $r.Codice | Should -Not -Be 0
        $r.Uscita | Should -Match 'guasto di prova'
    }
    It 'fuori da -WhatIf il codice resta 0 (l attivita pianificata non segna in errore un giro che ha scritto il suo log) e l errore e nel log' {
        $dati = New-Cartella 'dati'
        $r = Invoke-Script (New-Albero -Rompi) 'Smistatore.ps1' @() $dati
        $r.Codice | Should -Be 0
        (Get-Content (Get-ChildItem (Join-Path $dati 'log') -Filter '*.log').FullName -Raw) | Should -Match 'guasto di prova'
    }
}

Describe 'Supervisore.ps1 -WhatIf: un giro che si interrompe esce con un codice diverso da 0 (D53)' {
    It 'con un errore durante il giro esce con un codice diverso da 0 e lo scrive' {
        $r = Invoke-Script (New-Albero -Rompi) 'Supervisore.ps1' @('-WhatIf') (New-Cartella 'dati') (New-Cartella 'claude')
        $r.Codice | Should -Not -Be 0
        $r.Uscita | Should -Match 'guasto di prova'
    }
    It 'fuori da -WhatIf il codice resta 0' {
        $r = Invoke-Script (New-Albero -Rompi) 'Supervisore.ps1' @() (New-Cartella 'dati') (New-Cartella 'claude')
        $r.Codice | Should -Be 0
    }
}

Describe 'Supervisore.ps1 -WhatIf della copia nuova non aggiorna e non scrive (D53)' {
    It 'con una versione nuova su origine esce con 0, dice cosa farebbe e lascia copia, refs e cartella dati com erano' {
        $base = New-Cartella 'repo'
        $lavoro = Join-Path $base 'lavoro'; $bare = Join-Path $base 'origin.git'; $copia = Join-Path $base 'copia'
        New-Item -ItemType Directory $lavoro | Out-Null
        foreach ($d in 'src', 'config', 'ruoli', 'setup', 'hooks') { Copy-Item (Join-Path $script:Repo $d) (Join-Path $lavoro $d) -Recurse }
        & git -C $lavoro init -q -b main; & git -C $lavoro config core.autocrlf false; & git -C $lavoro add -A; & git -C $lavoro commit -q -m 'Merged PR 1: base'
        & git -C $base clone -q --bare $lavoro $bare; & git -C $lavoro remote add origin $bare
        & git -C $base clone -q -c core.autocrlf=false $bare $copia
        Set-Content (Join-Path $lavoro 'nuovo.txt') 'x'; & git -C $lavoro add -A; & git -C $lavoro commit -q -m 'Merged PR 2: nuova'; & git -C $lavoro push -q origin main
        & git -C $copia fetch -q origin
        $testa = (& git -C $copia rev-parse HEAD)
        $refs = (& git -C $copia for-each-ref) -join "`n"
        $dati = New-Cartella 'dati'
        $r = Invoke-Script $copia 'Supervisore.ps1' @('-WhatIf') $dati (New-Cartella 'claude')
        $r.Codice | Should -Be 0 -Because $r.Uscita
        $r.Uscita | Should -Match '\[WhatIf\] aggiornamento:'
        (& git -C $copia rev-parse HEAD) | Should -Be $testa
        ((& git -C $copia for-each-ref) -join "`n") | Should -Be $refs
        @(Get-ChildItem $dati -Recurse -File).Count | Should -Be 0
    }
}
