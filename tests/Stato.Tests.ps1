BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Stato.psm1') -Force
}

Describe 'Stato' {
    BeforeEach {
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ("stato-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        $script:File = Join-Path $script:Dir 'stato.json'
    }
    AfterEach { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'file assente dà tabella vuota' {
        $s = Get-Stato -Percorso $script:File
        $s.Count | Should -Be 0
    }

    It 'salva e rilegge senza perdite' {
        $s = Get-Stato -Percorso $script:File
        $c = Get-StatoCard -Stato $s -Id 42
        $c.ultimoCommento = 17
        $c.ramo = 'feature/x'
        $c.ultimaSessione = @{ dev = @{ id = 's1'; esito = 'ok' } }
        Save-Stato -Stato $s -Percorso $script:File

        $r = Get-Stato -Percorso $script:File
        $r['42'].ultimoCommento | Should -Be 17
        $r['42'].ramo | Should -Be 'feature/x'
        $r['42'].ultimaSessione.dev.esito | Should -Be 'ok'
    }

    It 'Get-StatoCard crea la voce con i valori predefiniti' {
        $s = @{}
        $c = Get-StatoCard -Stato $s -Id 7
        $s.Contains('7') | Should -BeTrue
        $c.ultimoCommento | Should -Be 0
        $c.giriRevisione | Should -Be 0
        $c.rosseDiFila | Should -Be 0
        $c.rossaGestita | Should -BeNullOrEmpty
        $c.inAttesaPer | Should -BeNullOrEmpty
        @($c.avvisi).Count | Should -Be 0
        $c.sessione | Should -BeNullOrEmpty
        $c.ultimaSessione.Count | Should -Be 0
        $c.rilanci | Should -Be 0
        $c.rilancioDi | Should -BeNullOrEmpty
        ($c.Keys | Sort-Object) | Should -Be (@('ultimoCommento', 'giriRevisione', 'rosseDiFila', 'rossaGestita', 'rilanci', 'rilancioDi', 'completaPr',
                'inAttesaPer', 'attesaInEsame', 'passateFatte', 'avvisi', 'ramo', 'cartella', 'prId', 'runId', 'runDopoRev', 'sessione', 'ultimoRuolo',
                'ultimaSessione', 'mentoriFatti', 'mentori') | Sort-Object)
        @($c.mentoriFatti).Count | Should -Be 0
        @($c.mentori).Count | Should -Be 0
    }

    It 'Get-StatoCard aggiunge mentori (le sessioni dei mentori in corso) a una voce vecchia che non lo ha' {
        $c = Get-StatoCard -Stato @{ '7' = [ordered]@{ ultimoCommento = 4 } } -Id 7
        $c.Contains('mentori') | Should -BeTrue
        @($c.mentori).Count | Should -Be 0
    }

    It 'Get-StatoCard aggiunge mentoriFatti a una voce vecchia che non lo ha' {
        $s = @{ '7' = [ordered]@{ ultimoCommento = 4; giriRevisione = 0 } }
        $c = Get-StatoCard -Stato $s -Id 7
        $c.ultimoCommento | Should -Be 4
        $c.Contains('mentoriFatti') | Should -BeTrue
        @($c.mentoriFatti).Count | Should -Be 0
    }

    It 'Add-RevNostra scrive una riga nel file della card e Get-RevNostre le restituisce' {
        Get-RevNostre -Id 42 -Percorso $script:File | Should -BeNullOrEmpty
        Add-RevNostra -Id 42 -Rev 5 -Percorso $script:File
        Add-RevNostra -Id 42 -Rev 5 -Percorso $script:File
        Add-RevNostra -Id 42 -Rev 6 -Percorso $script:File
        Add-RevNostra -Id 43 -Rev 9 -Percorso $script:File
        $f = Join-Path $script:Dir 'rev-nostre/42.txt'
        Test-Path $f | Should -BeTrue
        @(Get-Content $f).Count | Should -Be 3
        @(Get-RevNostre -Id 42 -Percorso $script:File) | Should -Be @(5, 6)
        @(Get-RevNostre -Id 43 -Percorso $script:File) | Should -Be @(9)
    }

    It 'Add-RevNostra non legge ne riscrive stato.json' {
        $s = Get-Stato -Percorso $script:File
        (Get-StatoCard -Stato $s -Id 42).ultimoCommento = 3
        Save-Stato -Stato $s -Percorso $script:File
        $prima = [IO.File]::ReadAllBytes($script:File)
        $t0 = (Get-Item $script:File).LastWriteTimeUtc
        # file tenuto aperto in esclusiva: se Add-RevNostra lo toccasse, fallirebbe
        $blocco = [IO.File]::Open($script:File, 'Open', 'Read', 'None')
        try { Add-RevNostra -Id 42 -Rev 7 -Percorso $script:File } finally { $blocco.Dispose() }
        [IO.File]::ReadAllBytes($script:File) | Should -Be $prima
        (Get-Item $script:File).LastWriteTimeUtc | Should -Be $t0
        @(Get-RevNostre -Id 42 -Percorso $script:File) | Should -Be @(7)
    }

    It 'un Save-Stato dello smistatore con copia vecchia non cancella le revisioni nostre' {
        $copiaVecchia = Get-Stato -Percorso $script:File
        Add-RevNostra -Id 42 -Rev 21 -Percorso $script:File
        (Get-StatoCard -Stato $copiaVecchia -Id 42).ultimoCommento = 4
        Save-Stato -Stato $copiaVecchia -Percorso $script:File
        @(Get-RevNostre -Id 42 -Percorso $script:File) | Should -Be @(21)
    }

    It 'un file bloccato per un istante (Save-Stato che lo sostituisce) si legge al tentativo dopo' {
        $s = @{}; (Get-StatoCard -Stato $s -Id 7).ultimoCommento = 5
        Save-Stato -Stato $s -Percorso $script:File
        # un altro thread tiene il file in esclusiva per 300 ms, come fa File.Replace di Save-Stato
        $pronto = Join-Path $script:Dir 'pronto'
        $j = Start-ThreadJob -ArgumentList $script:File, $pronto { param($f, $p) $b = [IO.File]::Open($f, 'Open', 'Read', 'None'); New-Item $p | Out-Null; Start-Sleep -Milliseconds 300; $b.Dispose() }
        while (-not (Test-Path $pronto)) { Start-Sleep -Milliseconds 10 }
        try { (Get-Stato -Percorso $script:File)['7'].ultimoCommento | Should -Be 5 }
        finally { $j | Wait-Job | Remove-Job }
    }

    It 'un file che resta bloccato fa lanciare, non restituisce uno stato vuoto' {
        Save-Stato -Stato @{ '1' = @{ ultimoCommento = 1 } } -Percorso $script:File
        $blocco = [IO.File]::Open($script:File, 'Open', 'Read', 'None')
        try { { Get-Stato -Percorso $script:File -Tentativi 3 -AttesaMs 10 } | Should -Throw '*non si legge dopo 3 tentativi*' }
        finally { $blocco.Dispose() }
    }

    It 'un salvataggio interrotto non lascia un file a metà' {
        $s = Get-Stato -Percorso $script:File
        (Get-StatoCard -Stato $s -Id 1).ultimoCommento = 1
        Save-Stato -Stato $s -Percorso $script:File
        $prima = Get-Content $script:File -Raw

        (Get-StatoCard -Stato $s -Id 1).ultimoCommento = 99
        # Il file di destinazione e' tenuto aperto: la sostituzione fallisce.
        $blocco = [IO.File]::Open($script:File, 'Open', 'Read', 'None')
        try { { Save-Stato -Stato $s -Percorso $script:File } | Should -Throw }
        finally { $blocco.Dispose() }

        (Get-Content $script:File -Raw) | Should -Be $prima
        @(Get-ChildItem $script:Dir -Filter '*.tmp').Count | Should -Be 0
    }
}

Describe 'Giro' {
    BeforeEach { $script:Nome = "Acme.Test.Giro.$([guid]::NewGuid().ToString('N'))" }
    AfterEach { Exit-Giro -Nome $script:Nome }

    It 'Get-NomeGiro da un nome per cartella dati: uguale per la stessa cartella, diverso per un altra' {
        $a = Get-NomeGiro -CartellaDati 'C:\Dati\Uno'
        $a | Should -BeLike 'Global\DevOps.Agents.Smistatore-*'
        Get-NomeGiro -CartellaDati 'c:/dati/uno/' | Should -Be $a
        Get-NomeGiro -CartellaDati 'C:\Dati\Due' | Should -Not -Be $a
    }

    It 'Enter-Giro chiamato due volte restituisce false la seconda' {
        Enter-Giro -Nome $script:Nome | Should -BeTrue
        Enter-Giro -Nome $script:Nome | Should -BeFalse
    }

    It 'dopo Exit-Giro si puo rientrare' {
        Enter-Giro -Nome $script:Nome | Should -BeTrue
        Exit-Giro -Nome $script:Nome
        Enter-Giro -Nome $script:Nome | Should -BeTrue
    }

    It 'Exit-Giro senza Enter-Giro non fallisce' {
        { Exit-Giro -Nome $script:Nome } | Should -Not -Throw
    }

    It 'un altro processo non entra mentre il giro e preso, entra dopo Exit-Giro' {
        $modulo = Join-Path $PSScriptRoot '../src/Stato.psm1'
        $prova = "Import-Module '$modulo'; if (Enter-Giro -Nome '$($script:Nome)') { 'preso' } else { 'occupato' }"
        Enter-Giro -Nome $script:Nome | Should -BeTrue
        (pwsh -NoProfile -Command $prova) | Should -Be 'occupato'
        Exit-Giro -Nome $script:Nome
        (pwsh -NoProfile -Command $prova) | Should -Be 'preso'
    }
}

Describe 'Stato: cartella dati e mutex globale' {
    BeforeEach { $script:Vecchia = $env:ATTREZZI_DATI }
    AfterEach { $env:ATTREZZI_DATI = $script:Vecchia }

    It 'le revisioni nostre di card.ps1 vanno nella cartella dati della variabile ATTREZZI_DATI' {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:ATTREZZI_DATI = $d
        Add-RevNostra -Id 42 -Rev 9
        @(Get-RevNostre -Id 42) | Should -Contain 9
        Test-Path (Join-Path $d 'rev-nostre/42.txt') | Should -BeTrue
    }

    It 'stato.json e nella stessa cartella dati' {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:ATTREZZI_DATI = $d
        Save-Stato -Stato @{ '1' = @{ a = 1 } }
        Test-Path (Join-Path $d 'stato.json') | Should -BeTrue
    }

    It 'il giro predefinito prende un mutex Global\, visibile anche senza utente connesso' {
        try {
            Enter-Giro | Should -BeTrue
            $m = $null
            [System.Threading.Mutex]::TryOpenExisting('Global\DevOps.Agents.Smistatore', [ref]$m) | Should -BeTrue
            if ($m) { $m.Dispose() }
        }
        finally { Exit-Giro }
    }
}

Describe 'Registro dell apprendimento (D46)' {
    BeforeEach {
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ("appr-" + [guid]::NewGuid())
        $script:Reg = Join-Path $script:Dir 'registro-apprendimento.jsonl'
    }
    AfterEach { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'Add-RigaApprendimento crea la cartella e il file e scrive una riga JSON con i campi del registro' {
        Add-RigaApprendimento -CartellaDati $script:Dir -Card 42 -Repo 'Acme.AI' -Tipo 'onHold' -Ruolo 'dev' -Motivo 'serve una scelta'
        Test-Path $script:Reg | Should -BeTrue
        $r = @(Get-Content $script:Reg)
        $r.Count | Should -Be 1
        $o = $r[0] | ConvertFrom-Json
        $o.card | Should -Be 42
        $o.repo | Should -Be 'Acme.AI'
        $o.tipo | Should -Be 'onHold'
        $o.ruolo | Should -Be 'dev'
        $o.motivo | Should -Be 'serve una scelta'
        $o.PSObject.Properties.Name | Should -Contain 'lezione'
        [datetime]$o.data | Should -BeOfType [datetime]
    }

    It 'la riga porta l esito della sessione (vuoto se non c e) per chi deve sapere se la sessione e finita bloccata' {
        Add-RigaApprendimento -CartellaDati $script:Dir -Card 1 -Tipo 'lezioneApplicata' -Ruolo 'dev' -Lezione 'dev-001' -Esito 'bloccato'
        Add-RigaApprendimento -CartellaDati $script:Dir -Card 2 -Tipo 'blocco' -Ruolo 'dev'
        $r = @(Get-Content $script:Reg | ForEach-Object { $_ | ConvertFrom-Json })
        $r[0].esito | Should -Be 'bloccato'
        $r[1].esito | Should -Be ''
    }

    It 'l impronta del registro cambia quando il file cresce e non c e senza file' {
        Get-ImprontaRegistroApprendimento -CartellaDati $script:Dir | Should -Be ''
        Add-RigaApprendimento -CartellaDati $script:Dir -Card 1 -Tipo 'blocco' -Ruolo 'dev'
        $a = Get-ImprontaRegistroApprendimento -CartellaDati $script:Dir
        $a | Should -Not -BeNullOrEmpty
        Get-ImprontaRegistroApprendimento -CartellaDati $script:Dir | Should -Be $a
        Add-RigaApprendimento -CartellaDati $script:Dir -Card 2 -Tipo 'blocco' -Ruolo 'dev'
        Get-ImprontaRegistroApprendimento -CartellaDati $script:Dir | Should -Not -Be $a
    }
    It 'solo aggiunta: le righe gia scritte restano com erano' {
        Add-RigaApprendimento -CartellaDati $script:Dir -Card 1 -Repo 'r' -Tipo 'blocco' -Ruolo 'dev' -Motivo 'a'
        $prima = Get-Content $script:Reg -Raw
        Add-RigaApprendimento -CartellaDati $script:Dir -Card 2 -Repo 'r' -Tipo 'onHold' -Ruolo 'reviewer' -Motivo 'b'
        (Get-Content $script:Reg -Raw).StartsWith($prima) | Should -BeTrue
        @(Get-Content $script:Reg).Count | Should -Be 2
    }

    It 'un tipo che non e del registro viene rifiutato' {
        { Add-RigaApprendimento -CartellaDati $script:Dir -Card 1 -Repo 'r' -Tipo 'boh' -Ruolo 'dev' } | Should -Throw
    }

    It 'Get-RigheApprendimento restituisce le righe nell ordine e salta quelle illeggibili' {
        Add-RigaApprendimento -CartellaDati $script:Dir -Card 1 -Repo 'r' -Tipo 'blocco' -Ruolo 'dev' -Motivo 'a'
        [IO.File]::AppendAllText($script:Reg, "questa non e json`n{rotta`n")
        Add-RigaApprendimento -CartellaDati $script:Dir -Card 2 -Repo 'r' -Tipo 'onHold' -Ruolo 'reviewer' -Motivo 'b'
        $r = @(Get-RigheApprendimento -CartellaDati $script:Dir)
        $r.Count | Should -Be 2
        $r[0].card | Should -Be 1
        $r[1].card | Should -Be 2
    }

    It 'Get-RigheApprendimento legge anche mentre un altro processo tiene il file aperto in scrittura (la vista legge, lo smistatore aggiunge)' {
        Add-RigaApprendimento -CartellaDati $script:Dir -Card 1 -Repo 'r' -Tipo 'blocco' -Ruolo 'dev' -Motivo 'a'
        $scrittore = [IO.FileStream]::new($script:Reg, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            @(Get-RigheApprendimento -CartellaDati $script:Dir).Count | Should -Be 1
        }
        finally { $scrittore.Dispose() }
    }

    It 'Get-RigheApprendimento senza file non restituisce niente' {
        @(Get-RigheApprendimento -CartellaDati $script:Dir).Count | Should -Be 0
    }
}

Describe 'Giro: il processo precedente e morto senza rilasciare' {
    It 'un mutex abbandonato non blocca il giro: Enter-Giro lo prende' {
        $nome = "Acme.Test.Abbandonato.$([guid]::NewGuid().ToString('N'))"
        try {
            # il processo prende il mutex ed esce senza rilasciarlo: per Windows e abbandonato
            pwsh -NoProfile -Command "`$m = [System.Threading.Mutex]::new(`$true, '$nome'); exit 0"
            Enter-Giro -Nome $nome | Should -BeTrue
            Enter-Giro -Nome $nome | Should -BeFalse
        }
        finally { Exit-Giro -Nome $nome }
    }
}

Describe 'Quota (D51): quota.json' {
    BeforeEach {
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ("quota-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        $script:File = Join-Path $script:Dir 'quota.json'
    }
    AfterEach { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'file assente da una quota vuota' {
        (Get-Quota -Percorso $script:File).Count | Should -Be 0
    }

    It 'salva e rilegge senza perdite, anche su un file che esiste gia' {
        Save-Quota -Quota @{ letta = '2026-11-23T10:00:00.0000000Z'; fiveHour = @{ utilization = 0.38; resetsAt = '2026-11-23T12:00:00.0000000Z' }; pausaFino = $null; finestraPausa = $null } -Percorso $script:File
        Save-Quota -Quota @{ letta = '2026-11-23T11:00:00.0000000Z'; sevenDay = @{ utilization = 0.26; resetsAt = '2026-11-27T10:00:00.0000000Z' }; pausaFino = '2026-11-23T12:05:00.0000000Z'; finestraPausa = 'five_hour' } -Percorso $script:File
        $q = Get-Quota -Percorso $script:File
        $q['sevenDay']['utilization'] | Should -Be 0.26
        $q['finestraPausa'] | Should -Be 'five_hour'
        $q.ContainsKey('fiveHour') | Should -BeFalse
        Get-ChildItem $script:Dir -Filter '*.tmp' | Should -BeNullOrEmpty
    }

    It 'un file bloccato oltre i tentativi lancia, non da una quota vuota' {
        Save-Quota -Quota @{ letta = 'x' } -Percorso $script:File
        $fs = [IO.File]::Open($script:File, 'Open', 'Read', 'None')
        try { { Get-Quota -Percorso $script:File -Tentativi 2 -AttesaMs 10 } | Should -Throw '*quota.json*' }
        finally { $fs.Dispose() }
    }
}

# Integrazione di D51 (2026-11-24): soglia-quota.json, l'override della soglia dalla vista. Qui solo i file: la regola e in Decisioni. Tutto in $TestDrive.
Describe 'Soglia della quota: soglia-quota.json (solo lettura e scrittura)' {
    BeforeEach { $script:S = Join-Path $TestDrive "soglia-$([guid]::NewGuid().ToString('N')).json" }

    It 'il nome del file sta in un posto solo: la cartella dati passata, o quella predefinita' {
        Get-PercorsoSogliaQuotaPredefinito 'C:\dati' | Should -Be (Join-Path 'C:\dati' 'soglia-quota.json')
        Get-PercorsoSogliaQuotaPredefinito | Should -Be (Join-Path (Get-CartellaDati) 'soglia-quota.json')
    }
    It 'il file che manca e un override vuoto; quello rotto da un errore, senza lanciare' {
        (Get-SogliaQuota -Percorso $script:S).Count | Should -Be 0
        [IO.File]::WriteAllText($script:S, '{ non json', [Text.UTF8Encoding]::new($false))
        (Get-SogliaQuota -Percorso $script:S).errore | Should -Match 'JSON'
        [IO.File]::WriteAllText($script:S, '[1,2]', [Text.UTF8Encoding]::new($false))
        (Get-SogliaQuota -Percorso $script:S).errore | Should -Not -BeNullOrEmpty
    }
    It 'un file bloccato oltre i tentativi non lancia: da un errore' {
        Save-SogliaQuota -Override @{ soglia = 0.8 } -Percorso $script:S
        $fs = [IO.File]::Open($script:S, 'Open', 'Read', 'None')
        try { (Get-SogliaQuota -Percorso $script:S -Tentativi 2 -AttesaMs 10).errore | Should -Match 'soglia-quota.json' }
        finally { $fs.Dispose() }
    }
    It 'salva e rilegge senza perdite, senza file temporanei; Remove-SogliaQuota lo cancella e non si lamenta se manca' {
        Save-SogliaQuota -Override @{ soglia = 0.85; ignoraRiserva = $true; fino = '2026-11-27T10:00:00Z'; impostata = '2026-11-24T10:00:00Z' } -Percorso $script:S
        Save-SogliaQuota -Override @{ soglia = $null; ignoraRiserva = $true; fino = '2026-11-27T10:00:00Z'; impostata = '2026-11-24T11:00:00Z' } -Percorso $script:S
        $o = Get-SogliaQuota -Percorso $script:S
        $o.soglia | Should -BeNullOrEmpty; $o.ignoraRiserva | Should -BeTrue
        Get-ChildItem $TestDrive -Filter '*.tmp' | Should -BeNullOrEmpty
        Remove-SogliaQuota -Percorso $script:S
        Test-Path $script:S | Should -BeFalse
        { Remove-SogliaQuota -Percorso $script:S } | Should -Not -Throw
    }
}

Describe 'Get-IdCardConSessione (D53): la definizione di sessione in corso' {
    It 'le card con il campo sessione valorizzato, in ordine numerico' {
        $stato = @{ '300' = @{ sessione = @{ id = 'a' } }; '20' = @{ sessione = $null }; '100' = @{ sessione = @{ id = 'b' } }; '5' = @{ prId = 7 }; '7' = $null }
        @(Get-IdCardConSessione $stato) | Should -Be @(100, 300)
    }
    It 'uno stato vuoto non ha sessioni' {
        @(Get-IdCardConSessione @{}).Count | Should -Be 0
    }
}
