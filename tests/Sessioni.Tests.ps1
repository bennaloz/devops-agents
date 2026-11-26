BeforeAll {
    # D53: i moduli che chiamano Get-Config (Card, MemoriaRepo, Sessioni) leggono impostazioni.json dalla cartella dati: non quella vera di chi lancia i test.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    Import-Module (Join-Path $PSScriptRoot '../src/Sessioni.psm1') -Force
    $script:Finto = Join-Path $PSScriptRoot 'finti/claude-finto.ps1'
    $script:Pwsh = (Get-Process -Id $PID).Path
    Set-SessioniEseguibile -Percorso $script:Pwsh -ArgomentiIniziali @('-NoProfile', '-File', $script:Finto)

    # Avvia una sessione con il finto e aspetta che il processo finisca. Restituisce l'esito di Start-SessioneRuolo
    # e gli argomenti che il finto ha visto.
    function Invoke-Lancio {
        param($Ruolo = 'dev', $Riprendi = $null, $Messaggio = 'Card 7 nel repo X.', $Dati, $Eventi = $null, $Attesa = $null, $Allegato = $null, $Task = $null,
            $PatLettura = (Join-Path $Dati 'nessun-pat-lettura.txt'), $FileCollaudo = $null, $Repo = $null, $Base = $null)
        $argv = Join-Path $Dati ("argv-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $env:CLAUDE_FINTO_ARGV = $argv
        if ($Eventi) { $env:CLAUDE_FINTO_EVENTI = $Eventi } else { Remove-Item Env:CLAUDE_FINTO_EVENTI -ErrorAction SilentlyContinue }
        if ($Attesa) { $env:CLAUDE_FINTO_ATTESA = "$Attesa" } else { Remove-Item Env:CLAUDE_FINTO_ATTESA -ErrorAction SilentlyContinue }
        try {
            $p = @{ Card = 7; Ruolo = $Ruolo; Messaggio = $Messaggio; Cartella = $Dati; CartellaDati = $Dati; PercorsoPatLettura = $PatLettura }
            if ($Riprendi) { $p.Riprendi = $Riprendi }
            if ($Allegato) { $p.Allegato = $Allegato }
            if ($Task) { $p.Task = $Task }
            if ($FileCollaudo) { $p.FileCollaudo = $FileCollaudo }
            if ($Repo) { $p.Repo = $Repo }
            if ($Base) { $p.Base = $Base }
            $r = Start-SessioneRuolo @p
        }
        finally {
            Remove-Item Env:CLAUDE_FINTO_ARGV, Env:CLAUDE_FINTO_EVENTI, Env:CLAUDE_FINTO_ATTESA -ErrorAction SilentlyContinue
        }
        if (-not $Attesa) {
            $proc = Get-Process -Id $r.Pid -ErrorAction SilentlyContinue
            if ($proc) { $proc | Wait-Process -Timeout 60 -ErrorAction SilentlyContinue }
        }
        $t = 0; while (-not (Test-Path $argv) -and $t -lt 100) { Start-Sleep -Milliseconds 100; $t++ }
        [pscustomobject]@{ Sessione = $r; Vista = (Get-Content -LiteralPath $argv -Raw | ConvertFrom-Json) }
    }

    function Scrivi-Eventi($Percorso, [string[]]$Righe) { Set-Content -LiteralPath $Percorso -Value $Righe -Encoding utf8 }

    $script:EvInit = '{"type":"system","subtype":"init","session_id":"s1"}'
    $script:EvTool = '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"PowerShell"}]}}'
    function New-Risultato([string]$Testo, [bool]$IsError = $false, $Denials = @(), [string]$Subtype = 'success') {
        @{
            type = 'result'; subtype = $Subtype; is_error = $IsError; result = $Testo; session_id = 's1'
            num_turns = 4; duration_ms = 125000; permission_denials = @($Denials)
            usage = @{ input_tokens = 10; output_tokens = 200; cache_read_input_tokens = 3000; cache_creation_input_tokens = 400 }
        } | ConvertTo-Json -Compress -Depth 6
    }
    $script:EvDopo = '{"type":"system","subtype":"task_summary"}'
}

Describe 'Start-SessioneRuolo: riga di comando' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:D | Out-Null }

    It 'contiene modello, sforzo e brief del ruolo' {
        $x = Invoke-Lancio -Ruolo 'responsabile' -Dati $script:D
        $a = @($x.Vista.args)
        $a[0] | Should -Be '-p'
        $a[1] | Should -Be 'Card 7 nel repo X.'
        $a[$a.IndexOf('--model') + 1] | Should -Be 'opus'
        $a[$a.IndexOf('--effort') + 1] | Should -Be 'high'
        $a[$a.IndexOf('--append-system-prompt-file') + 1] | Should -Match 'ruoli[\\/]responsabile\.md$'
    }

    It '--effort e assente quando lo sforzo e null' {
        # nessun ruolo della configurazione ha oggi lo sforzo null: si prova sul costruttore degli argomenti
        $rc = [pscustomobject]@{ modello = 'sonnet'; sforzo = $null; strumenti = @('Read') }
        $a = @(& (Get-Module Sessioni) { param($r) Get-ArgomentiClaude -Messaggio 'm' -RuoloConfig $r -Brief 'b.md' -SessioneId 's' } $rc | ForEach-Object { $_ })
        $a | Should -Not -Contain '--effort'
        $a[$a.IndexOf('--model') + 1] | Should -Be 'sonnet'
    }

    It 'D55: responsabile e dev partono con Fable come advisor' {
        foreach ($ruolo in 'responsabile', 'dev') {
            $x = Invoke-Lancio -Ruolo $ruolo -Dati $script:D
            $a = @($x.Vista.args)
            $a[$a.IndexOf('--advisor') + 1] | Should -Be 'fable'
        }
    }

    It '--advisor e assente quando il ruolo non ha advisor' {
        $rc = [pscustomobject]@{ modello = 'sonnet'; sforzo = 'medium'; strumenti = @('Read') }
        $a = @(& (Get-Module Sessioni) { param($r) Get-ArgomentiClaude -Messaggio 'm' -RuoloConfig $r -Brief 'b.md' -SessioneId 's' } $rc | ForEach-Object { $_ })
        $a | Should -Not -Contain '--advisor'
    }

    It 'dev parte con Opus a sforzo medio' {
        $x = Invoke-Lancio -Ruolo 'dev' -Dati $script:D
        $a = @($x.Vista.args)
        $a[$a.IndexOf('--model') + 1] | Should -Be 'opus'
        $a[$a.IndexOf('--effort') + 1] | Should -Be 'medium'
    }

    It 'primo lancio: --session-id con un uuid nuovo e niente --resume' {
        $x = Invoke-Lancio -Dati $script:D
        $a = @($x.Vista.args)
        $a | Should -Not -Contain '--resume'
        $a[$a.IndexOf('--session-id') + 1] | Should -Be $x.Sessione.Id
        $x.Sessione.Id | Should -Match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
        $x.Sessione.Ripresa | Should -BeFalse
    }

    It 'con -Riprendi c e --resume e non --session-id' {
        $id = 'aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb'
        $x = Invoke-Lancio -Dati $script:D -Riprendi $id
        $a = @($x.Vista.args)
        $a | Should -Not -Contain '--session-id'
        $a[$a.IndexOf('--resume') + 1] | Should -Be $id
        $x.Sessione.Id | Should -Be $id
        $x.Sessione.Ripresa | Should -BeTrue
    }

    It 'primo lancio e ripresa: stessa riga di comando, cambia solo --session-id in --resume' {
        $id = 'aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb'
        $primo = Invoke-Lancio -Dati $script:D
        $ripresa = Invoke-Lancio -Dati $script:D -Riprendi $id
        $a = @($primo.Vista.args); $b = @($ripresa.Vista.args)
        $a.Count | Should -Be $b.Count
        $ia = $a.IndexOf('--session-id'); $ib = $b.IndexOf('--resume')
        $ia | Should -Be $ib
        $a[$ia + 1] = '<ID>'; $b[$ib + 1] = '<ID>'
        $a[$ia] = '<APRI>'; $b[$ib] = '<APRI>'
        ($a -join "`n") | Should -Be ($b -join "`n")
        # stesso modo di lancio: stessa cartella, stesse variabili d'ambiente
        $ripresa.Vista.cwd | Should -Be $primo.Vista.cwd
        $ripresa.Vista.card | Should -Be $primo.Vista.card
    }

    It '--mcp-config arriva a claude come JSON intatto, e il messaggio multiriga con virgolette e barre pure' {
        $msg = "Card 7 nel repo `"X`".`nMotivo: C:\dir\ e `"citazione\`" fine.`n- trattino"
        $x = Invoke-Lancio -Dati $script:D -Messaggio $msg
        $a = @($x.Vista.args)
        $a[$a.IndexOf('--mcp-config') + 1] | Should -Be '{"mcpServers":{}}'
        $a | Should -Contain '--strict-mcp-config'
        $a[1] | Should -Be $msg
    }

    It 'permessi: strumenti del ruolo senza jolly, acceptEdits, niente skip dei permessi' {
        $x = Invoke-Lancio -Dati $script:D
        $a = @($x.Vista.args)
        $i = $a.IndexOf('--allowedTools')
        $i | Should -BeGreaterThan 0
        $strumenti = @()
        for ($k = $i + 1; $k -lt $a.Count -and -not $a[$k].StartsWith('--'); $k++) { $strumenti += $a[$k] }
        $strumenti | Should -Contain 'PowerShell'
        $strumenti | Should -Contain 'Write'
        ($strumenti -join ' ') | Should -Not -Match '[*(]'
        $a[$a.IndexOf('--permission-mode') + 1] | Should -Be 'acceptEdits'
        $a | Should -Not -Contain '--dangerously-skip-permissions'
        $a | Should -Contain 'stream-json'
        $a | Should -Contain '--verbose'
    }

    It 'ATTREZZI_CARD e ATTREZZI_RUOLO stanno nell ambiente del processo lanciato, non in quello di chi lancia' {
        $x = Invoke-Lancio -Ruolo 'reviewer' -Dati $script:D
        $x.Vista.card | Should -Be '7'
        $x.Vista.ruolo | Should -Be 'reviewer'
        $env:ATTREZZI_CARD | Should -BeNullOrEmpty
        $env:ATTREZZI_RUOLO | Should -BeNullOrEmpty
    }

    It 'ATTREZZI_TASK arriva al processo di una sessione di task, e non resta nell ambiente di chi lancia' {
        $x = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Task 62
        $x.Vista.task | Should -Be '62'
        $x.Vista.card | Should -Be '7'
        $env:ATTREZZI_TASK | Should -BeNullOrEmpty
    }

    It 'ATTREZZI_BASE e develop se la card non dice altro (card isolata): dev e reviewer lo usano per il diff e il merge' {
        $x = Invoke-Lancio -Ruolo 'dev' -Dati $script:D
        $x.Vista.base | Should -Be 'develop'
        $env:ATTREZZI_BASE | Should -BeNullOrEmpty
    }

    It 'ATTREZZI_BASE e il ramo di base della card (D52: il ramo della funzionalita) e non resta nell ambiente di chi lancia, che resta com era' {
        $env:ATTREZZI_BASE = 'quella-di-chi-lancia'
        try {
            $x = Invoke-Lancio -Ruolo 'reviewer' -Dati $script:D -Base 'feature/f7-la-funzione'
            $x.Vista.base | Should -Be 'feature/f7-la-funzione'
            $env:ATTREZZI_BASE | Should -Be 'quella-di-chi-lancia'
        }
        finally { Remove-Item Env:ATTREZZI_BASE -ErrorAction SilentlyContinue }
    }

    It 'i brief di dev e reviewer leggono la base da ATTREZZI_BASE, non da un origin/develop scritto a mano' {
        $radice = Join-Path $PSScriptRoot '..'
        foreach ($b in 'dev', 'reviewer') {
            $testo = Get-Content -LiteralPath (Join-Path $radice "ruoli/$b.md") -Raw
            $testo | Should -Match 'origin/\$env:ATTREZZI_BASE' -Because "il brief $b"
            $testo | Should -Not -Match 'origin/develop' -Because "il brief $b"
        }
        (Get-Content -LiteralPath (Join-Path $radice 'ruoli/reviewer.md') -Raw) | Should -Match 'allinea-develop[\s\S]*remerge-diff'
    }

    It 'D52, gruppo 5: il brief di dev dice cosa fare con il tag allinea-develop (unire develop nel ramo della card), e con il motivo conflitti su quella card' {
        $testo = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../ruoli/dev.md') -Raw
        $testo | Should -Match 'tag `allinea-develop`'
        $testo | Should -Match 'allinea-develop[\s\S]*unisci nel tuo ramo il ramo `develop` di origin'
        $testo | Should -Match 'allinea-develop[\s\S]*motivo\s+`conflitti` su questa card'
    }

    It 'una sessione senza task non eredita ATTREZZI_TASK dall ambiente di chi lancia, che resta com era' {
        $env:ATTREZZI_TASK = '999'
        try {
            $x = Invoke-Lancio -Ruolo 'reviewer' -Dati $script:D
            $x.Vista.task | Should -BeNullOrEmpty
            $env:ATTREZZI_TASK | Should -Be '999'
        }
        finally { Remove-Item Env:ATTREZZI_TASK -ErrorAction SilentlyContinue }
    }

    It 'parte dalla cartella data e scrive l uscita su sessioni\<id>.jsonl' {
        $ev = Join-Path $script:D 'ev.jsonl'
        Scrivi-Eventi $ev @($script:EvInit)
        $x = Invoke-Lancio -Dati $script:D -Eventi $ev
        (Resolve-Path $x.Vista.cwd).Path | Should -Be (Resolve-Path $script:D).Path
        $f = Join-Path $script:D "sessioni/$($x.Sessione.Id).jsonl"
        Test-Path $f | Should -BeTrue
        (Get-Content $f -Raw) | Should -Match '"subtype":"init"'
    }

    It 'un ruolo sconosciuto e un errore' {
        { Start-SessioneRuolo -Card 7 -Ruolo 'scout' -Messaggio 'x' -Cartella $script:D -CartellaDati $script:D } | Should -Throw '*scout*'
    }
}

Describe 'Get-EsitoSessione' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $script:D 'sessioni') | Out-Null }
    BeforeAll {
        function Nuova-Sessione($Righe, [string]$Id = 'sess-1') {
            Scrivi-Eventi (Join-Path $script:D "sessioni/$Id.jsonl") $Righe
            $Id
        }
    }

    It 'su una sessione in corso: Finita falso e UltimoEvento valorizzato' {
        $id = Nuova-Sessione @($script:EvInit, $script:EvTool)
        $e = Get-EsitoSessione -Id $id -CartellaDati $script:D
        $e.Finita | Should -BeFalse
        $e.UltimoEvento | Should -Not -BeNullOrEmpty
        $e.UltimoEvento | Should -BeOfType [datetime]
        $e.Esito | Should -BeNullOrEmpty
    }

    It 'su una finita: esito, turni, durata e i quattro numeri di token (il result non e l ultima riga)' {
        $id = Nuova-Sessione @($script:EvInit, $script:EvTool, (New-Risultato "Fatto.`nESITO=fatto"), $script:EvDopo)
        $e = Get-EsitoSessione -Id $id -CartellaDati $script:D
        $e.Finita | Should -BeTrue
        $e.Errore | Should -BeFalse
        $e.Esito | Should -Be 'fatto'
        $e.Testo | Should -Match 'Fatto'
        $e.Turni | Should -Be 4
        $e.DurataMs | Should -Be 125000
        $e.TokenIn | Should -Be 10
        $e.TokenOut | Should -Be 200
        $e.CacheLetti | Should -Be 3000
        $e.CacheScritti | Should -Be 400
    }

    It 'senza riga ESITO= l esito e nullo' {
        $id = Nuova-Sessione @((New-Risultato 'Ho finito senza dire come.'))
        (Get-EsitoSessione -Id $id -CartellaDati $script:D).Esito | Should -BeNullOrEmpty
    }

    It 'con piu righe ESITO= vale l ultima' {
        $id = Nuova-Sessione @((New-Risultato "ESITO=bivio`nripensandoci`nESITO=fatto"))
        (Get-EsitoSessione -Id $id -CartellaDati $script:D).Esito | Should -Be 'fatto'
    }

    It 'un evento finale con is_error vero da Errore vero' {
        $id = Nuova-Sessione @((New-Risultato 'boom' $true))
        $e = Get-EsitoSessione -Id $id -CartellaDati $script:D
        $e.Finita | Should -BeTrue
        $e.Errore | Should -BeTrue
    }

    It 'comandi negati con un esito valido: la sessione non e fallita, i negati si contano per strumento' {
        # card 10: il reviewer si e visto negare una controverifica e ha concluso lo stesso con un esito valido
        $den = @(@{ tool_name = 'PowerShell'; tool_use_id = 't1'; tool_input = @{ command = 'git push' } }, @{ tool_name = 'Bash'; tool_use_id = 't2'; tool_input = @{ command = 'x' } })
        $id = Nuova-Sessione @((New-Risultato "ESITO=fatto" $false $den))
        $e = Get-EsitoSessione -Id $id -CartellaDati $script:D
        $e.Errore | Should -BeFalse
        $e.Esito | Should -Be 'fatto'
        @($e.Negati) | Should -Be @('PowerShell', 'Bash')
    }

    It 'comandi negati senza un esito: la sessione e fallita' {
        $den = @(@{ tool_name = 'PowerShell'; tool_use_id = 't1'; tool_input = @{ command = 'git push' } })
        $id = Nuova-Sessione @((New-Risultato "non riesco" $false $den))
        $e = Get-EsitoSessione -Id $id -CartellaDati $script:D
        $e.Errore | Should -BeTrue
    }

    It 'un sottotipo diverso da success e un errore' {
        $id = Nuova-Sessione @((New-Risultato 'x' $false @() 'error_max_turns'))
        (Get-EsitoSessione -Id $id -CartellaDati $script:D).Errore | Should -BeTrue
    }

    It 'ignora le righe che non sono JSON' {
        $id = Nuova-Sessione @('rumore', $script:EvInit, (New-Risultato 'ESITO=fatto'))
        (Get-EsitoSessione -Id $id -CartellaDati $script:D).Esito | Should -Be 'fatto'
    }

    It 'dopo una ripresa vale l uscita piu recente della stessa sessione' {
        $id = Nuova-Sessione @((New-Risultato 'ESITO=bivio')) 'sess-r'
        Start-Sleep -Milliseconds 50
        Scrivi-Eventi (Join-Path $script:D 'sessioni/sess-r.r1.jsonl') @((New-Risultato 'ESITO=fatto'))
        (Get-EsitoSessione -Id $id -CartellaDati $script:D).Esito | Should -Be 'fatto'
    }

    It 'una sessione di cui non c e il file: Finita falso, nessun errore' {
        $e = Get-EsitoSessione -Id 'non-esiste' -CartellaDati $script:D
        $e.Finita | Should -BeFalse
        $e.UltimoEvento | Should -BeNullOrEmpty
    }
}

Describe 'Start-SessioneRuolo: ripresa nello stesso file di uscita' {
    It 'la ripresa non cancella l uscita del primo lancio' {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null
        $ev1 = Join-Path $d 'ev1.jsonl'; Scrivi-Eventi $ev1 @((New-Risultato 'ESITO=bivio'))
        $ev2 = Join-Path $d 'ev2.jsonl'; Scrivi-Eventi $ev2 @((New-Risultato 'ESITO=fatto'))
        $x = Invoke-Lancio -Dati $d -Eventi $ev1
        $y = Invoke-Lancio -Dati $d -Eventi $ev2 -Riprendi $x.Sessione.Id
        $y.Sessione.Id | Should -Be $x.Sessione.Id
        @(Get-ChildItem (Join-Path $d 'sessioni') -Filter "$($x.Sessione.Id)*.jsonl").Count | Should -Be 2
        (Get-EsitoSessione -Id $x.Sessione.Id -CartellaDati $d).Esito | Should -Be 'fatto'
    }
}

Describe 'Start-SessioneRuolo: cartella dati, strumenti, allegato' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:D | Out-Null }

    It 'la cartella dati va al processo lanciato come ATTREZZI_DATI, e non resta nell ambiente di chi lancia' {
        $vecchia = $env:ATTREZZI_DATI
        try {
            $env:ATTREZZI_DATI = $null
            $x = Invoke-Lancio -Dati $script:D
            $x.Vista.dati | Should -Be $script:D
            $env:ATTREZZI_DATI | Should -BeNullOrEmpty
        }
        finally { $env:ATTREZZI_DATI = $vecchia }
    }

    It 'la sessione parte con AZURE_CONFIG_DIR su una cartella sua con il solo config dell organizzazione, e il valore di chi lancia torna' {
        $vecchia = $env:AZURE_CONFIG_DIR
        try {
            $env:AZURE_CONFIG_DIR = 'C:/login-di-chi-lancia'
            $x = Invoke-Lancio -Dati $script:D
            $x.Vista.configAz | Should -BeLike (Join-Path (Join-Path $script:D 'az') '*')
            $x.Vista.configAz | Should -Be (Join-Path (Join-Path $script:D 'az') $x.Sessione.Id)
            $x.Vista.configAzElenco | Should -Be @('config')
            $x.Vista.configAzFile | Should -Match '(?m)^\[defaults\]\r?\n^organization = https://\S+'
            $x.Vista.configAzFile | Should -Be ("[defaults]`norganization = $(Get-AdoUrlOrganizzazione)`n")
            $env:AZURE_CONFIG_DIR | Should -Be 'C:/login-di-chi-lancia'
        }
        finally { if ($null -eq $vecchia) { Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue } else { $env:AZURE_CONFIG_DIR = $vecchia } }
    }

    It 'una ripresa riparte da una cartella di configurazione vuota: un az login rimasto dentro non resta' {
        $x = Invoke-Lancio -Dati $script:D
        Set-Content (Join-Path $x.Vista.configAz 'msal_token_cache.json') 'login-lasciato'
        $y = Invoke-Lancio -Dati $script:D -Riprendi $x.Sessione.Id
        $y.Vista.configAz | Should -Be $x.Vista.configAz
        $y.Vista.configAzElenco | Should -Be @('config')
    }

    It 'AZURE_EXTENSION_DIR punta alle estensioni di az dell utente se ci sono, e il valore di chi lancia torna' {
        $estensioni = Join-Path $HOME '.azure/cliextensions'
        $vecchia = $env:AZURE_EXTENSION_DIR
        try {
            $env:AZURE_EXTENSION_DIR = 'C:/estensioni-di-chi-lancia'
            $x = Invoke-Lancio -Dati $script:D
            if (Test-Path -LiteralPath $estensioni -PathType Container) { $x.Vista.estensioniAz | Should -Be $estensioni }
            else { $x.Vista.estensioniAz | Should -BeNullOrEmpty }
            $env:AZURE_EXTENSION_DIR | Should -Be 'C:/estensioni-di-chi-lancia'
        }
        finally { if ($null -eq $vecchia) { Remove-Item Env:AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue } else { $env:AZURE_EXTENSION_DIR = $vecchia } }
    }
    It 'il PAT in sola lettura cifrato con DPAPI va al processo lanciato in chiaro' {
        $vecchia = $env:AZURE_DEVOPS_EXT_PAT
        try {
            $f = Join-Path $script:D 'pat-read-only.txt'
            Write-FilePat $f 'solo-lettura-cifrato'
            $x = Invoke-Lancio -Dati $script:D -PatLettura $f
            $x.Vista.adoLettura | Should -Be 'solo-lettura-cifrato'
        }
        finally { $env:AZURE_DEVOPS_EXT_PAT = $vecchia }
    }

    It 'il PAT in sola lettura va al processo lanciato come AZURE_DEVOPS_EXT_PAT, e non resta nell ambiente di chi lancia' {
        $vecchia = $env:AZURE_DEVOPS_EXT_PAT
        try {
            $env:AZURE_DEVOPS_EXT_PAT = 'pieno-di-chi-lancia'
            $f = Join-Path $script:D 'pat-read-only.txt'
            Set-Content -LiteralPath $f -Value "  solo-lettura  `n" -NoNewline
            $x = Invoke-Lancio -Dati $script:D -PatLettura $f
            $x.Vista.adoLettura | Should -Be 'solo-lettura'
            $env:AZURE_DEVOPS_EXT_PAT | Should -Be 'pieno-di-chi-lancia'
        }
        finally { $env:AZURE_DEVOPS_EXT_PAT = $vecchia }
    }

    It 'le credenziali di collaudo vanno al collaudatore come COLLAUDO_CHIAVE, e non restano nell ambiente di chi lancia' {
        $f = Join-Path $script:D 'collaudo-repo.json'
        Set-Content -LiteralPath $f -Value '{ "utente": "prova", "password": "segreta", "tokenUrl": "https://kc.example.invalid/token" }'
        $env:COLLAUDO_RESIDUO = 'di chi lancia'
        try {
            $x = Invoke-Lancio -Dati $script:D -Ruolo 'collaudatore' -FileCollaudo $f
            @($x.Vista.collaudo) | Should -Be @('COLLAUDO_PASSWORD=segreta', 'COLLAUDO_TOKENURL=https://kc.example.invalid/token', 'COLLAUDO_UTENTE=prova')
            $env:COLLAUDO_UTENTE | Should -BeNullOrEmpty
            $env:COLLAUDO_RESIDUO | Should -Be 'di chi lancia'
        }
        finally { Remove-Item Env:COLLAUDO_RESIDUO -ErrorAction SilentlyContinue }
    }

    It 'il messaggio al collaudatore elenca i nomi delle variabili di collaudo, senza i valori' {
        $f = Join-Path $script:D 'collaudo-nomi.json'
        Set-Content -LiteralPath $f -Value '{ "utente": "tester-x9", "password": "changeme-x", "urlLogin": "https://kc.example.invalid/login" }'
        $x = Invoke-Lancio -Dati $script:D -Ruolo 'collaudatore' -FileCollaudo $f
        $testo = @($x.Vista.args) -join ' '
        $testo | Should -Match 'COLLAUDO_PASSWORD, COLLAUDO_URLLOGIN, COLLAUDO_UTENTE'
        $testo | Should -Not -Match 'changeme|kc\.example|tester-x9'
    }

    It 'senza file delle credenziali il messaggio al collaudatore lo dice' {
        $x = Invoke-Lancio -Dati $script:D -Ruolo 'collaudatore' -FileCollaudo (Join-Path $script:D 'non-esiste.json')
        (@($x.Vista.args) -join ' ') | Should -Match 'nessuna credenziale di prova'
    }

    It 'un file delle credenziali malformato fa fallire il lancio senza riportarne il contenuto' {
        $f = Join-Path $script:D 'collaudo-rotto.json'
        Set-Content -LiteralPath $f -Value '{ "password": "segreta", '
        { Invoke-Lancio -Dati $script:D -Ruolo 'collaudatore' -FileCollaudo $f } | Should -Throw -ExpectedMessage '*credenziali di collaudo*'
        try { Invoke-Lancio -Dati $script:D -Ruolo 'collaudatore' -FileCollaudo $f } catch { $_.Exception.Message | Should -Not -Match 'segreta|password' }
    }

    It 'un valore non semplice nel file delle credenziali non diventa una variabile' {
        $f = Join-Path $script:D 'collaudo-annidato.json'
        Set-Content -LiteralPath $f -Value '{ "utente": "prova", "extra": { "a": 1 } }'
        $x = Invoke-Lancio -Dati $script:D -Ruolo 'collaudatore' -FileCollaudo $f
        @($x.Vista.collaudo) | Should -Be @('COLLAUDO_UTENTE=prova')
    }

    It 'un ruolo che non e il collaudatore non riceve credenziali di collaudo, nemmeno quelle di chi lancia' {
        $f = Join-Path $script:D 'collaudo-repo.json'
        Set-Content -LiteralPath $f -Value '{ "utente": "prova" }'
        $env:COLLAUDO_RESIDUO = 'di chi lancia'
        try {
            $x = Invoke-Lancio -Dati $script:D -Ruolo 'dev' -FileCollaudo $f
            @($x.Vista.collaudo).Count | Should -Be 0
        }
        finally { Remove-Item Env:COLLAUDO_RESIDUO -ErrorAction SilentlyContinue }
    }

    It 'senza il file del PAT in lettura il processo lanciato non eredita il PAT di chi lancia' {
        $vecchia = $env:AZURE_DEVOPS_EXT_PAT
        try {
            $env:AZURE_DEVOPS_EXT_PAT = 'pieno-di-chi-lancia'
            $x = Invoke-Lancio -Dati $script:D -PatLettura (Join-Path $script:D 'manca.txt')
            $x.Vista.adoLettura | Should -BeNullOrEmpty
            $env:AZURE_DEVOPS_EXT_PAT | Should -Be 'pieno-di-chi-lancia'
        }
        finally { $env:AZURE_DEVOPS_EXT_PAT = $vecchia }
    }

    It '--tools limita gli strumenti disponibili a quelli del ruolo, come --allowedTools' {
        foreach ($ruolo in 'responsabile', 'dev', 'reviewer') {
            $x = Invoke-Lancio -Ruolo $ruolo -Dati $script:D
            $a = @($x.Vista.args)
            $i = $a.IndexOf('--tools')
            $i | Should -BeGreaterThan 0 -Because $ruolo
            $tools = @(); for ($k = $i + 1; $k -lt $a.Count -and -not $a[$k].StartsWith('--'); $k++) { $tools += $a[$k] }
            $ia = $a.IndexOf('--allowedTools')
            $consentiti = @(); for ($k = $ia + 1; $k -lt $a.Count -and -not $a[$k].StartsWith('--'); $k++) { $consentiti += $a[$k] }
            ($tools -join ',') | Should -Be ($consentiti -join ',')
        }
        $r = Invoke-Lancio -Ruolo 'responsabile' -Dati $script:D
        @($r.Vista.args) | Should -Not -Contain 'Write'
        @($r.Vista.args) | Should -Not -Contain 'Edit'
    }

    It 'con un allegato il messaggio resta di tre righe e la terza e il file con il testo intero' {
        $lungo = ('riga di rilievo ' * 4000)   # ben oltre i 32.767 caratteri di una riga di comando
        $d = $script:D
        $x = Invoke-Lancio -Dati $d -Messaggio "Card 7 nel repo X.`nMotivo: rilievi." -Allegato $lungo
        $msg = [string]$x.Vista.args[1]
        $righe = @($msg -split "`n")
        $righe.Count | Should -Be 3
        $righe[0] | Should -Be 'Card 7 nel repo X.'
        $righe[1] | Should -Be 'Motivo: rilievi.'
        Test-Path -LiteralPath $righe[2] | Should -BeTrue
        (Get-Content -LiteralPath $righe[2] -Raw -Encoding UTF8).TrimEnd() | Should -Be $lungo.TrimEnd()
        ([string]$righe[2]) | Should -BeLike (Join-Path $d 'sessioni*')
        $msg.Length | Should -BeLessThan 1000
    }

    It 'senza allegato il messaggio e quello dato, due righe' {
        $x = Invoke-Lancio -Dati $script:D -Messaggio "Card 7 nel repo X.`nMotivo: nuova."
        @([string]$x.Vista.args[1] -split "`n").Count | Should -Be 2
    }

    It 'il risultato porta l orario di avvio del processo, in UTC' {
        $x = Invoke-Lancio -Dati $script:D
        $x.Sessione.Avvio | Should -Not -BeNullOrEmpty
        ([datetime]::Parse($x.Sessione.Avvio).ToUniversalTime()) | Should -BeLessThan ((Get-Date).ToUniversalTime().AddSeconds(5))
    }
}

Describe 'Test-SessioneViva e Stop-Sessione: solo il processo che abbiamo lanciato' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:D | Out-Null }

    It 'viva: stesso PID, stesso orario di avvio, stesso eseguibile' {
        $x = Invoke-Lancio -Dati $script:D -Attesa 60000
        try { Test-SessioneViva -ProcessoId $x.Sessione.Pid -Avvio $x.Sessione.Avvio | Should -BeTrue }
        finally { Stop-Sessione -ProcessoId $x.Sessione.Pid -Avvio $x.Sessione.Avvio }
    }

    It 'non viva: processo finito, PID inesistente, orario diverso (PID riusato), senza orario' {
        $x = Invoke-Lancio -Dati $script:D
        Test-SessioneViva -ProcessoId $x.Sessione.Pid -Avvio $x.Sessione.Avvio | Should -BeFalse
        Test-SessioneViva -ProcessoId 999999 -Avvio $x.Sessione.Avvio | Should -BeFalse
        $y = Invoke-Lancio -Dati $script:D -Attesa 60000
        try {
            Test-SessioneViva -ProcessoId $y.Sessione.Pid -Avvio ([datetime]::UtcNow.AddHours(-5).ToString('o')) | Should -BeFalse
            Test-SessioneViva -ProcessoId $y.Sessione.Pid -Avvio '' | Should -BeFalse
        }
        finally { Stop-Sessione -ProcessoId $y.Sessione.Pid -Avvio $y.Sessione.Avvio }
    }

    It 'non e viva se l eseguibile non e claude (un processo estraneo con lo stesso PID)' {
        $y = Invoke-Lancio -Dati $script:D -Attesa 60000
        try {
            Set-SessioniEseguibile -Percorso 'C:\altro\claude.exe'
            Test-SessioneViva -ProcessoId $y.Sessione.Pid -Avvio $y.Sessione.Avvio | Should -BeFalse
        }
        finally {
            Set-SessioniEseguibile -Percorso $script:Pwsh -ArgomentiIniziali @('-NoProfile', '-File', $script:Finto)
            Stop-Sessione -ProcessoId $y.Sessione.Pid -Avvio $y.Sessione.Avvio
        }
    }

    It 'Stop-Sessione non uccide un processo il cui orario di avvio non coincide' {
        $y = Invoke-Lancio -Dati $script:D -Attesa 60000
        try {
            Stop-Sessione -ProcessoId $y.Sessione.Pid -Avvio ([datetime]::UtcNow.AddHours(-5).ToString('o'))
            Stop-Sessione -ProcessoId $y.Sessione.Pid
            Get-Process -Id $y.Sessione.Pid -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        finally { Stop-Sessione -ProcessoId $y.Sessione.Pid -Avvio $y.Sessione.Avvio }
    }
}

Describe 'Get-EsitoSessione: righe ESITO scritte con la formattazione' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $script:D 'sessioni') | Out-Null }

    It 'la riga ESITO tra backtick o in grassetto vale come quella nuda' {
        $i = 0
        foreach ($riga in '`ESITO=fatto`', '**ESITO=fatto**', '**`ESITO=fatto`**', '  `ESITO=fatto`  ') {
            $id = "fmt-$i"; $i++
            Scrivi-Eventi (Join-Path $script:D "sessioni/$id.jsonl") @((New-Risultato "Finito.`n$riga"))
            (Get-EsitoSessione -Id $id -CartellaDati $script:D).Esito | Should -Be 'fatto' -Because $riga
        }
    }

    It 'una riga che cita ESITO=valore dentro una frase non vale' {
        Scrivi-Eventi (Join-Path $script:D 'sessioni/frase.jsonl') @((New-Risultato 'Scrivero ESITO=fatto quando avro finito, per ora no.'))
        (Get-EsitoSessione -Id 'frase' -CartellaDati $script:D).Esito | Should -BeNullOrEmpty
    }

    It 'Eventi conta le righe JSON valide dell uscita' {
        Scrivi-Eventi (Join-Path $script:D 'sessioni/ev.jsonl') @('rumore', $script:EvInit, $script:EvTool)
        (Get-EsitoSessione -Id 'ev' -CartellaDati $script:D).Eventi | Should -Be 2
        Scrivi-Eventi (Join-Path $script:D 'sessioni/vuoto.jsonl') @()
        (Get-EsitoSessione -Id 'vuoto' -CartellaDati $script:D).Eventi | Should -Be 0
    }
}

Describe 'Get-EsitoSessione: le righe LEZIONE (D46)' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $script:D 'sessioni') | Out-Null }

    It 'raccoglie una riga LEZIONE con l id per ogni lezione seguita, anche con la formattazione e una volta sola' {
        $testo = "Fatto.`nLEZIONE: dev-003`n`n- non e una riga`n``LEZIONE: dev-004```n**LEZIONE: dev-003**`nESITO=fatto"
        Scrivi-Eventi (Join-Path $script:D 'sessioni/lez.jsonl') @((New-Risultato $testo))
        $e = Get-EsitoSessione -Id 'lez' -CartellaDati $script:D
        @($e.Lezioni) | Should -Be @('dev-003', 'dev-004')
        $e.Esito | Should -Be 'fatto'
    }

    It 'accetta l id seguito da (in prova), il titolo che il ruolo vede: conta l id, il resto si ignora' {
        $testo = "Fatto.`nLEZIONE: dev-003 (in prova)`n**LEZIONE: dev-004 (in prova)**`nLEZIONE: dev-003`nESITO=fatto"
        Scrivi-Eventi (Join-Path $script:D 'sessioni/prova.jsonl') @((New-Risultato $testo))
        @((Get-EsitoSessione -Id 'prova' -CartellaDati $script:D).Lezioni) | Should -Be @('dev-003', 'dev-004')
    }

    It 'l etichetta in prova e quella di Memoria.psm1: la riga LEZIONE col titolo come lo compone New-BriefConMemoria e riconosciuta' {
        $titolo = (New-BriefConMemoria -Brief '# B' -File @([pscustomobject]@{ Nome = 'comune'; Develop = $null; InProva = "### dev-005`n- Situazione: s`n- Cosa fare: c`n- Perché: p`n- Card: 5" })) -split "`n" | Where-Object { $_ -like '### dev-005*' }
        $etichetta = $titolo -replace '^### dev-005\s*', ''
        $etichetta | Should -Be (Get-EtichettaInProva)
        Scrivi-Eventi (Join-Path $script:D 'sessioni/etich.jsonl') @((New-Risultato "Fatto.`nLEZIONE: dev-005 $etichetta`nESITO=fatto"))
        @((Get-EsitoSessione -Id 'etich' -CartellaDati $script:D).Lezioni) | Should -Be @('dev-005')
    }

    It 'una frase che cita LEZIONE con l id non vale, e senza righe l elenco e vuoto' {
        Scrivi-Eventi (Join-Path $script:D 'sessioni/frase.jsonl') @((New-Risultato 'Ho seguito LEZIONE: dev-003 come previsto.'))
        @((Get-EsitoSessione -Id 'frase' -CartellaDati $script:D).Lezioni).Count | Should -Be 0
        @((Get-EsitoSessione -Id 'inesistente' -CartellaDati $script:D).Lezioni).Count | Should -Be 0
    }
}

Describe 'Start-SessioneRuolo: la memoria nel brief (D46)' {
    BeforeAll {
        # la lettura di git e di Azure DevOps si sostituisce: nessun git vero qui
        $global:LezMem = { param($N, $T) "### dev-$N`n- Situazione: $T`n- Cosa fare: c`n- Perché: p`n- Card: 5" }
        function Get-FileBrief($Esito) {
            $a = @($Esito.Vista.args)
            $a[$a.IndexOf('--append-system-prompt-file') + 1]
        }
    }
    BeforeEach {
        $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:D | Out-Null
        $global:ChiamateMem = [System.Collections.Generic.List[object]]::new()
        Mock Get-MemoriaDelRuolo -ModuleName Sessioni {
            param($Radice, $Ruolo, $Repo)
            $global:ChiamateMem.Add(@{ Radice = $Radice; Ruolo = $Ruolo; Repo = $Repo })
            [pscustomobject]@{ Ruolo = $Ruolo; Repo = $Repo; Disponibile = $true; InProvaUsato = $true; Motivi = @(); File = @(
                    [pscustomobject]@{ Nome = 'comune'; Develop = (& $global:LezMem 1 'testo-comune-zz'); InProva = (& $global:LezMem 1 'testo-comune-zz') }
                    [pscustomobject]@{ Nome = $Repo; Develop = $null; InProva = (& $global:LezMem 2 'testo-repo-zz') }) }
        }
    }

    It 'il file passato a claude e quello composto: brief, poi comune, poi il repo, la lezione in prova marcata' {
        $x = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Repo 'Acme.AI'
        $f = Get-FileBrief $x
        $f | Should -Not -Match 'ruoli[\\/]dev\.md$'
        $f | Should -BeLike (Join-Path $script:D 'sessioni/*')
        $t = Get-Content -LiteralPath $f -Raw -Encoding UTF8
        $brief = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'ruoli/dev.md') -Raw -Encoding UTF8
        $t.StartsWith($brief.TrimEnd()) | Should -BeTrue
        $t.IndexOf('testo-comune-zz') | Should -BeGreaterThan ($brief.Length - 2)
        $t.IndexOf('testo-repo-zz') | Should -BeGreaterThan $t.IndexOf('testo-comune-zz')
        $t | Should -BeLike "*### dev-1`n*"
        $t | Should -BeLike "*### dev-2 (in prova)`n*"
    }

    It 'legge la memoria del ruolo e del repo dalla radice degli attrezzi' {
        [void](Invoke-Lancio -Ruolo 'reviewer' -Dati $script:D -Repo 'Acme.AI')
        $global:ChiamateMem.Count | Should -Be 1
        $global:ChiamateMem[0].Ruolo | Should -Be 'reviewer'
        $global:ChiamateMem[0].Repo | Should -Be 'Acme.AI'
        $global:ChiamateMem[0].Radice | Should -Be (Split-Path -Parent $PSScriptRoot)
    }

    It 'senza il repo non legge niente e passa il brief del ruolo, come prima' {
        $x = Invoke-Lancio -Ruolo 'dev' -Dati $script:D
        $global:ChiamateMem.Count | Should -Be 0
        Get-FileBrief $x | Should -Match 'ruoli[\\/]dev\.md$'
    }

    It 'memoria senza lezioni: il file del primo lancio e comunque quello composto (brief.md della sessione), con il testo del brief del ruolo e basta' {
        Mock Get-MemoriaDelRuolo -ModuleName Sessioni {
            [pscustomobject]@{ Disponibile = $true; InProvaUsato = $false; Motivi = @(); File = @([pscustomobject]@{ Nome = 'comune'; Develop = $null; InProva = $null }, [pscustomobject]@{ Nome = 'Acme.AI'; Develop = $null; InProva = $null }) }
        }
        $x = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Repo 'Acme.AI'
        Get-FileBrief $x | Should -BeLike (Join-Path $script:D "sessioni/$($x.Sessione.Id).brief.md")
        $brief = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'ruoli/dev.md') -Raw -Encoding UTF8
        (Get-Content -LiteralPath (Get-FileBrief $x) -Raw -Encoding UTF8) | Should -Be $brief
        @($x.Sessione.AvvisiMemoria).Count | Should -Be 0
    }

    It 'la ripresa di un lancio senza lezioni riusa il brief del primo lancio anche se nel frattempo e nata una lezione' {
        Mock Get-MemoriaDelRuolo -ModuleName Sessioni {
            [pscustomobject]@{ Disponibile = $true; InProvaUsato = $false; Motivi = @(); File = @([pscustomobject]@{ Nome = 'comune'; Develop = $null; InProva = $null }) }
        }
        $primo = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Repo 'Acme.AI'
        $testoPrima = Get-Content -LiteralPath (Get-FileBrief $primo) -Raw -Encoding UTF8
        Mock Get-MemoriaDelRuolo -ModuleName Sessioni {
            [pscustomobject]@{ Disponibile = $true; InProvaUsato = $true; Motivi = @(); File = @([pscustomobject]@{ Nome = 'comune'; Develop = $null; InProva = (& $global:LezMem 1 'nata-dopo-zz') }) }
        }
        $r = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Repo 'Acme.AI' -Riprendi $primo.Sessione.Id
        (Get-FileBrief $r) | Should -Be (Get-FileBrief $primo)
        (Get-Content -LiteralPath (Get-FileBrief $r) -Raw -Encoding UTF8) | Should -Be $testoPrima
        $testoPrima | Should -Not -BeLike '*nata-dopo-zz*'
    }

    It 'memoria non disponibile: il brief da solo, e i motivi vengono riportati nel risultato senza fermare il lancio' {
        Mock Get-MemoriaDelRuolo -ModuleName Sessioni {
            [pscustomobject]@{ Disponibile = $false; InProvaUsato = $false; Motivi = @('origin/develop non si legge: niente memoria'); File = @() }
        }
        $x = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Repo 'Acme.AI'
        Get-FileBrief $x | Should -BeLike '*.brief.md'
        (Get-Content -LiteralPath (Get-FileBrief $x) -Raw -Encoding UTF8) | Should -Be (Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'ruoli/dev.md') -Raw -Encoding UTF8)
        @($x.Sessione.AvvisiMemoria) | Should -Be @('origin/develop non si legge: niente memoria')
        $x.Sessione.Pid | Should -BeGreaterThan 0
    }

    It 'le lezioni lette con un ripiego (fetch fallito) si usano e il motivo viene riportato' {
        Mock Get-MemoriaDelRuolo -ModuleName Sessioni {
            [pscustomobject]@{ Disponibile = $true; InProvaUsato = $false; Motivi = @('fetch fallito'); File = @([pscustomobject]@{ Nome = 'comune'; Develop = "### dev-001`n- Situazione: testo-comune-zz`n- Cosa fare: c`n- Perché: p`n- Card: 5"; InProva = $null }) }
        }
        $x = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Repo 'Acme.AI'
        (Get-Content -LiteralPath (Get-FileBrief $x) -Raw -Encoding UTF8) | Should -BeLike '*testo-comune-zz*'
        @($x.Sessione.AvvisiMemoria) | Should -Be @('fetch fallito')
    }

    It 'se la lettura lancia comunque, il lancio parte con il brief da solo e dice perche' {
        Mock Get-MemoriaDelRuolo -ModuleName Sessioni { throw 'git esploso' }
        $x = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Repo 'Acme.AI'
        Get-FileBrief $x | Should -BeLike '*.brief.md'
        (Get-Content -LiteralPath (Get-FileBrief $x) -Raw -Encoding UTF8) | Should -Be (Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'ruoli/dev.md') -Raw -Encoding UTF8)
        @($x.Sessione.AvvisiMemoria)[0] | Should -BeLike '*git esploso*'
    }

    It 'la ripresa riusa il brief composto al primo lancio: stesso file, senza rileggere la memoria (la cache del prompt vale solo con opzioni identiche)' {
        $primo = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Repo 'Acme.AI'
        $global:ChiamateMem.Clear()
        $testoPrima = Get-Content -LiteralPath (Get-FileBrief $primo) -Raw -Encoding UTF8
        $r = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Repo 'Acme.AI' -Riprendi $primo.Sessione.Id
        (Get-FileBrief $r) | Should -Be (Get-FileBrief $primo)
        $global:ChiamateMem.Count | Should -Be 0
        (Get-Content -LiteralPath (Get-FileBrief $r) -Raw -Encoding UTF8) | Should -Be $testoPrima
        @($r.Sessione.AvvisiMemoria).Count | Should -Be 0
    }

    It 'la ripresa senza il file composto (sessione di prima della memoria, o file tolto) lo compone adesso' {
        $primo = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Repo 'Acme.AI'
        Remove-Item -LiteralPath (Get-FileBrief $primo)
        $global:ChiamateMem.Clear()
        $r = Invoke-Lancio -Ruolo 'dev' -Dati $script:D -Repo 'Acme.AI' -Riprendi $primo.Sessione.Id
        $global:ChiamateMem.Count | Should -Be 1
        Test-Path (Get-FileBrief $r) | Should -BeTrue
        (Get-Content -LiteralPath (Get-FileBrief $r) -Raw -Encoding UTF8) | Should -BeLike '*testo-repo-zz*'
    }
}

Describe 'Get-ErroriSessione' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $script:D 'sessioni') | Out-Null }

    It 'restituisce le ultime righe del file degli errori della sessione' {
        Set-Content (Join-Path $script:D 'sessioni/e1.jsonl') ''
        Set-Content (Join-Path $script:D 'sessioni/e1.err') (1..20 | ForEach-Object { "errore $_" })
        $t = Get-ErroriSessione -Id 'e1' -CartellaDati $script:D -Righe 3
        @($t -split "`n").Count | Should -Be 3
        $t | Should -Match 'errore 20'
        $t | Should -Not -Match 'errore 17'
    }

    It 'senza file degli errori o vuoto: stringa vuota' {
        Get-ErroriSessione -Id 'non-c-e' -CartellaDati $script:D | Should -Be ''
        Set-Content (Join-Path $script:D 'sessioni/e2.jsonl') ''
        Set-Content (Join-Path $script:D 'sessioni/e2.err') ''
        Get-ErroriSessione -Id 'e2' -CartellaDati $script:D | Should -Be ''
    }
}

Describe 'Get-EseguibileClaude' {
    BeforeAll {
        $script:Radice = Join-Path $TestDrive 'npm'
        New-Item -ItemType Directory (Join-Path $script:Radice 'node_modules/@anthropic-ai/claude-code/bin') -Force | Out-Null
        $script:ExeNpm = Join-Path $script:Radice 'node_modules/@anthropic-ai/claude-code/bin/claude.exe'
        Set-Content $script:ExeNpm 'x'
        Set-Content (Join-Path $script:Radice 'claude.cmd') 'x'
    }
    BeforeEach { Set-SessioniEseguibile -Percorso $null }
    AfterEach { Set-SessioniEseguibile -Percorso $script:Pwsh -ArgomentiIniziali @('-NoProfile', '-File', $script:Finto) }

    It 'se il comando e uno shim di npm, usa il claude.exe accanto allo shim' {
        Mock Get-Command -ModuleName Sessioni { [pscustomobject]@{ Source = (Join-Path $script:Radice 'claude.cmd') } }
        Get-EseguibileClaude | Should -Be $script:ExeNpm
    }
    It 'se il comando e gia un exe, usa quello' {
        Mock Get-Command -ModuleName Sessioni { [pscustomobject]@{ Source = 'C:\x\claude.exe' } }
        Get-EseguibileClaude | Should -Be 'C:\x\claude.exe'
    }
    It 'senza claude da nessuna parte e un errore chiaro' {
        Mock Get-Command -ModuleName Sessioni { }
        { Get-EseguibileClaude } | Should -Throw '*claude.exe non trovato*'
    }
}

Describe 'Stop-Sessione' {
    It 'chiude il processo' {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null
        $x = Invoke-Lancio -Dati $d -Attesa 60000
        Get-Process -Id $x.Sessione.Pid -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Stop-Sessione -Pid $x.Sessione.Pid -Avvio $x.Sessione.Avvio
        Start-Sleep -Milliseconds 500
        Get-Process -Id $x.Sessione.Pid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'un processo che non esiste piu non e un errore' {
        { Stop-Sessione -Pid 999999 } | Should -Not -Throw
    }
}

Describe 'Write-RegistroSessione' {
    It 'aggiunge una riga JSON valida senza riscrivere le precedenti' {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Write-RegistroSessione -CartellaDati $d -Riga @{ card = 7; repo = 'R'; ruolo = 'dev'; esito = 'fatto'; tokenIn = 1 }
        $f = Join-Path $d 'registro-sessioni.jsonl'
        $prima = Get-Content $f -Raw
        Write-RegistroSessione -CartellaDati $d -Riga @{ card = 8; repo = 'R'; ruolo = 'reviewer'; esito = 'superata'; tokenIn = 2 }
        $righe = @(Get-Content $f)
        $righe.Count | Should -Be 2
        ($righe[0] + "`n") -replace "`r", '' | Should -Be ($prima -replace "`r", '')
        ($righe[1] | ConvertFrom-Json).card | Should -Be 8
        ($righe[0] | ConvertFrom-Json).ruolo | Should -Be 'dev'
    }
}

Describe 'Test-Riprendibile' {
    BeforeAll {
        $script:Ora = (Get-Date).ToUniversalTime()
    }
    It 'e falso con soglia 0, anche se la sessione e finita adesso' {
        Test-Riprendibile -UltimaSessione @{ id = 'x'; fine = $script:Ora.ToString('o') } -Limiti @{ sogliaResumeMinuti = 0 } | Should -BeFalse
    }
    It 'e vero se la fine e entro la soglia' {
        Test-Riprendibile -UltimaSessione @{ id = 'x'; fine = $script:Ora.AddMinutes(-3).ToString('o') } -Limiti ([pscustomobject]@{ sogliaResumeMinuti = 10 }) | Should -BeTrue
    }
    It 'e falso se la fine e oltre la soglia' {
        Test-Riprendibile -UltimaSessione @{ id = 'x'; fine = $script:Ora.AddMinutes(-30).ToString('o') } -Limiti @{ sogliaResumeMinuti = 10 } | Should -BeFalse
    }
    It 'e falso senza sessione, senza id o senza fine' {
        Test-Riprendibile -UltimaSessione $null -Limiti @{ sogliaResumeMinuti = 10 } | Should -BeFalse
        Test-Riprendibile -UltimaSessione @{ fine = $script:Ora.ToString('o') } -Limiti @{ sogliaResumeMinuti = 10 } | Should -BeFalse
        Test-Riprendibile -UltimaSessione @{ id = 'x'; fine = $null } -Limiti @{ sogliaResumeMinuti = 10 } | Should -BeFalse
    }
}


Describe 'Get-ProgressoSessione: cosa sta facendo la sessione, dall uscita a eventi' {
    BeforeAll {
        function Nuovo-Assistente([string]$MsgId, $Contenuto, $Usage = $null) {
            $m = [ordered]@{ id = $MsgId; role = 'assistant'; content = @($Contenuto) }
            if ($Usage) { $m.usage = $Usage }
            ([ordered]@{ type = 'assistant'; message = $m } | ConvertTo-Json -Depth 10 -Compress)
        }
        function Nuovo-Tool([string]$Nome, $Parametri) { [ordered]@{ type = 'tool_use'; id = "t-$Nome"; name = $Nome; input = $Parametri } }
        function Scrivi-Uscita([string]$Id, [string[]]$Righe) {
            [IO.File]::WriteAllText((Join-Path $script:D "sessioni/$Id.jsonl"), (($Righe -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        }
    }
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $script:D 'sessioni') | Out-Null }

    It 'riassume ogni strumento: descrizione, altrimenti file_path, altrimenti la prima riga del comando' {
        Scrivi-Uscita 's1' @(
            '{"type":"system","subtype":"init"}'
            (Nuovo-Assistente 'm1' (Nuovo-Tool 'Bash' @{ command = 'npm test'; description = 'Lancia i test' }))
            (Nuovo-Assistente 'm2' (Nuovo-Tool 'Read' @{ file_path = 'C:/repo/src/a.ps1' }))
            (Nuovo-Assistente 'm3' (Nuovo-Tool 'Bash' @{ command = "git status`ngit diff`ngit log" }))
        )
        $p = Get-ProgressoSessione -Id 's1' -CartellaDati $script:D
        @($p.Azioni) | Should -Be @('Bash: Lancia i test', 'Read: C:/repo/src/a.ps1', 'Bash: git status')
    }

    It 'un comando lungo si tronca a circa 100 caratteri' {
        Scrivi-Uscita 's1' @((Nuovo-Assistente 'm1' (Nuovo-Tool 'Bash' @{ command = ('x' * 300) })))
        $a = @((Get-ProgressoSessione -Id 's1' -CartellaDati $script:D).Azioni)[0]
        $a.Length | Should -BeLessOrEqual 110
        $a | Should -Match '^Bash: x+\.\.\.$'
    }

    It 'tiene solo le ultime N, la piu vecchia per prima; il testo libero dell assistente non conta' {
        $righe = 1..8 | ForEach-Object { Nuovo-Assistente "m$_" @((Nuovo-Tool 'Read' @{ file_path = "f$_" }), @{ type = 'text'; text = 'penso' }) }
        Scrivi-Uscita 's1' $righe
        @((Get-ProgressoSessione -Id 's1' -CartellaDati $script:D -Ultime 5).Azioni) | Should -Be @('Read: f4', 'Read: f5', 'Read: f6', 'Read: f7', 'Read: f8')
    }

    It 'uno strumento senza niente da dire resta il solo nome' {
        Scrivi-Uscita 's1' @((Nuovo-Assistente 'm1' (Nuovo-Tool 'TodoWrite' @{})))
        @((Get-ProgressoSessione -Id 's1' -CartellaDati $script:D).Azioni) | Should -Be @('TodoWrite')
    }

    It 'i token si sommano per messaggio una volta sola, anche se lo stesso messaggio compare su piu righe' {
        $u1 = @{ input_tokens = 10; output_tokens = 5; cache_read_input_tokens = 100; cache_creation_input_tokens = 20 }
        $u2 = @{ input_tokens = 1; output_tokens = 7; cache_read_input_tokens = 200; cache_creation_input_tokens = 0 }
        Scrivi-Uscita 's1' @(
            (Nuovo-Assistente 'm1' @{ type = 'text'; text = 'a' } $u1)
            (Nuovo-Assistente 'm1' (Nuovo-Tool 'Read' @{ file_path = 'f' }) $u1)
            (Nuovo-Assistente 'm2' (Nuovo-Tool 'Read' @{ file_path = 'g' }) $u2)
        )
        $p = Get-ProgressoSessione -Id 's1' -CartellaDati $script:D
        $p.Token | Should -Be (10 + 5 + 100 + 20 + 1 + 7 + 200)
    }

    It 'senza file o con righe illeggibili non fallisce: nessuna azione, token zero' {
        $p = Get-ProgressoSessione -Id 'non-c-e' -CartellaDati $script:D
        @($p.Azioni).Count | Should -Be 0
        $p.Token | Should -Be 0
        Scrivi-Uscita 's2' @('non json', '{"type":"assistant"}')
        @((Get-ProgressoSessione -Id 's2' -CartellaDati $script:D).Azioni).Count | Should -Be 0
    }

    It 'non scrive niente nella cartella dati' {
        Scrivi-Uscita 's1' @((Nuovo-Assistente 'm1' (Nuovo-Tool 'Read' @{ file_path = 'f' })))
        $prima = @(Get-ChildItem $script:D -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
        $null = Get-ProgressoSessione -Id 's1' -CartellaDati $script:D
        @(Get-ChildItem $script:D -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) | Should -Be $prima
    }
}

Describe 'Get-EventiSessione: lo stream della sessione, evento per evento' {
    BeforeAll {
        function Riga-Assistente($Contenuto) { ([ordered]@{ type = 'assistant'; message = [ordered]@{ id = 'm'; role = 'assistant'; content = @($Contenuto) } } | ConvertTo-Json -Depth 10 -Compress) }
        function Riga-Risultato($Contenuto, [bool]$Errore = $false) {
            ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = 't1'; content = $Contenuto; is_error = $Errore }) } } | ConvertTo-Json -Depth 10 -Compress)
        }
        function Scrivi-File([string]$Nome, [string[]]$Righe) {
            [IO.File]::WriteAllText((Join-Path $script:D "sessioni/$Nome"), (($Righe -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        }
    }
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $script:D 'sessioni') | Out-Null }

    It 'legge testo, strumento con parametri, risultato ed esito, nell ordine del file' {
        Scrivi-File 's1.jsonl' @(
            '{"type":"system","subtype":"init"}'
            (Riga-Assistente @{ type = 'text'; text = 'Guardo il file' })
            (Riga-Assistente @{ type = 'tool_use'; id = 't1'; name = 'Bash'; input = @{ command = 'git status'; description = 'Stato' } })
            (Riga-Risultato 'On branch x')
            '{"type":"result","subtype":"success","is_error":false,"result":"Fatto\nESITO=ok"}'
        )
        $r = Get-EventiSessione -Id 's1' -CartellaDati $script:D
        $e = @($r.Eventi)
        @($e.Tipo) | Should -Be @('testo', 'strumento', 'risultato', 'esito')
        $e[0].Testo | Should -Be 'Guardo il file'
        $e[1].Nome | Should -Be 'Bash'
        $e[1].Testo | Should -Match 'command: git status'
        $e[1].Testo | Should -Match 'description: Stato'
        $e[2].Testo | Should -Be 'On branch x'
        $e[2].Tagliato | Should -BeFalse
        $e[3].Testo | Should -Match 'ESITO=ok'
        $r.Saltati | Should -Be 0
    }

    It 'il risultato puo essere un elenco di blocchi di testo' {
        Scrivi-File 's1.jsonl' @((Riga-Risultato @(@{ type = 'text'; text = 'uno' }, @{ type = 'text'; text = 'due' })))
        @((Get-EventiSessione -Id 's1' -CartellaDati $script:D).Eventi)[0].Testo | Should -Be "uno`ndue"
    }

    It 'un risultato lungo si taglia a circa 1500 caratteri e lo dice' {
        Scrivi-File 's1.jsonl' @((Riga-Risultato ('x' * 5000)))
        $e = @((Get-EventiSessione -Id 's1' -CartellaDati $script:D).Eventi)[0]
        $e.Tagliato | Should -BeTrue
        $e.Testo.Length | Should -BeLessOrEqual 1500
    }

    It 'i parametri lunghi di uno strumento (un Write di un file intero) si tagliano e lo dice' {
        $uso = [ordered]@{ type = 'tool_use'; id = 't1'; name = 'Write'; input = [ordered]@{ file_path = 'a.ps1'; content = ((1..200 | ForEach-Object { "riga $_" }) -join "`n") } }
        Scrivi-File 's1.jsonl' @((Riga-Assistente $uso))
        $e = @((Get-EventiSessione -Id 's1' -CartellaDati $script:D).Eventi)[0]
        $e.Tagliato | Should -BeTrue
        $e.Testo | Should -Match 'file_path: a.ps1'
        @($e.Testo -split "`n").Count | Should -BeLessOrEqual 40
    }

    It 'un risultato con troppe righe si taglia a poche righe e lo dice' {
        Scrivi-File 's1.jsonl' @((Riga-Risultato ((1..100 | ForEach-Object { "riga $_" }) -join "`n")))
        $e = @((Get-EventiSessione -Id 's1' -CartellaDati $script:D).Eventi)[0]
        $e.Tagliato | Should -BeTrue
        @($e.Testo -split "`n").Count | Should -BeLessOrEqual 20
        $e.Testo | Should -Match 'riga 1'
        $e.Testo | Should -Not -Match 'riga 100'
    }

    It 'tiene gli ultimi N eventi e dice quanti ne ha saltati' {
        Scrivi-File 's1.jsonl' @(1..10 | ForEach-Object { Riga-Assistente @{ type = 'text'; text = "t$_" } })
        $r = Get-EventiSessione -Id 's1' -CartellaDati $script:D -Ultimi 4
        @($r.Eventi.Testo) | Should -Be @('t7', 't8', 't9', 't10')
        $r.Saltati | Should -Be 6
    }

    It 'le riprese si leggono in ordine, ognuna dopo una riga ripresa N' {
        Scrivi-File 's1.jsonl' @((Riga-Assistente @{ type = 'text'; text = 'primo' }))
        Scrivi-File 's1.r2.jsonl' @((Riga-Assistente @{ type = 'text'; text = 'terzo' }))
        Scrivi-File 's1.r1.jsonl' @((Riga-Assistente @{ type = 'text'; text = 'secondo' }))
        Scrivi-File 's10.jsonl' @((Riga-Assistente @{ type = 'text'; text = 'altra sessione' }))
        $e = @((Get-EventiSessione -Id 's1' -CartellaDati $script:D).Eventi)
        @($e.Tipo) | Should -Be @('testo', 'ripresa', 'testo', 'ripresa', 'testo')
        @($e.Testo) | Should -Be @('primo', 'ripresa 1', 'secondo', 'ripresa 2', 'terzo')
    }

    It 'senza file o con righe illeggibili non fallisce' {
        $r = Get-EventiSessione -Id 'non-c-e' -CartellaDati $script:D
        @($r.Eventi).Count | Should -Be 0
        $r.Saltati | Should -Be 0
        Scrivi-File 's2.jsonl' @('non json', '{"type":"assistant"}')
        @((Get-EventiSessione -Id 's2' -CartellaDati $script:D).Eventi).Count | Should -Be 0
    }
}

Describe 'Get-TotaleToken' {
    It 'somma i quattro numeri dell esito' {
        Get-TotaleToken ([pscustomobject]@{ TokenIn = 10; TokenOut = 200; CacheLetti = 3000; CacheScritti = 400 }) | Should -Be 3610
    }
}

# D51: la quota e il limite di token si leggono dai rate_limit_event del jsonl (forma presa da sessioni vere) e dal testo del result.
Describe 'Get-EsitoSessione: quota e limite di token (D51)' {
    BeforeEach { $script:D = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $script:D 'sessioni') | Out-Null }
    BeforeAll {
        function Nuova-SessioneQ($Righe, [string]$Id = 'sess-q') {
            Scrivi-Eventi (Join-Path $script:D "sessioni/$Id.jsonl") $Righe
            $Id
        }
        function New-EventoQuota([string]$Status, [string]$Tipo, [double]$Cinque, [double]$Sette, [long]$ResetCinque = 1795186800, [long]$ResetSette = 1795658400) {
            @{ type = 'rate_limit_event'; rate_limit_info = @{
                status = $Status; resetsAt = $ResetCinque; rateLimitType = $Tipo; overageStatus = 'rejected'
                unifiedWindows = @{
                    five_hour = @{ utilization = $Cinque; resetsAt = $ResetCinque; status = $Status }
                    seven_day = @{ utilization = $Sette; resetsAt = $ResetSette; status = 'allowed' }
                } } } | ConvertTo-Json -Compress -Depth 6
        }
        function New-RisultatoLimite([string]$Testo) {
            @{ type = 'result'; subtype = 'success'; is_error = $true; api_error_status = 429; result = $Testo; num_turns = 1; duration_ms = 592
                permission_denials = @(); usage = @{ input_tokens = 0; output_tokens = 0; cache_read_input_tokens = 0; cache_creation_input_tokens = 0 } } | ConvertTo-Json -Compress -Depth 6
        }
    }

    It 'un rate_limit_event allowed: Quota con le due finestre (l ultimo evento vale) e Limite nullo' {
        $id = Nuova-SessioneQ @($script:EvInit, (New-EventoQuota 'allowed' 'five_hour' 0.20 0.10), (New-EventoQuota 'allowed' 'five_hour' 0.38 0.26), (New-Risultato "Fatto.`nESITO=fatto"))
        $e = Get-EsitoSessione -Id $id -CartellaDati $script:D
        $e.Limite | Should -BeNullOrEmpty
        $e.Quota.five_hour.Utilization | Should -Be 0.38
        $e.Quota.seven_day.Utilization | Should -Be 0.26
        $e.Quota.five_hour.ResetsAt | Should -BeOfType [datetime]
        $e.Quota.five_hour.ResetsAt.Kind | Should -Be 'Utc'
        $e.Quota.five_hour.ResetsAt | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds(1795186800).UtcDateTime)
        $e.Quota.seven_day.ResetsAt | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds(1795658400).UtcDateTime)
    }

    It 'senza rate_limit_event la Quota e nulla' {
        $id = Nuova-SessioneQ @($script:EvInit, (New-Risultato "Fatto.`nESITO=fatto"))
        (Get-EsitoSessione -Id $id -CartellaDati $script:D).Quota | Should -BeNullOrEmpty
    }

    It 'un evento rejected: Limite con la finestra e il reset dell evento' {
        $id = Nuova-SessioneQ @($script:EvInit, (New-EventoQuota 'rejected' 'five_hour' 1 0.37 1795204800), (New-RisultatoLimite "You've hit your 5-hour limit · resets 9pm (Europe/Rome)"))
        $e = Get-EsitoSessione -Id $id -CartellaDati $script:D
        $e.Finita | Should -BeTrue
        $e.Limite.Finestra | Should -Be 'five_hour'
        $e.Limite.Reset | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds(1795204800).UtcDateTime)
        $e.Limite.Reset.Kind | Should -Be 'Utc'
        $e.Quota.five_hour.Utilization | Should -Be 1
    }

    It 'solo il testo "hit your ... limit": Limite dalla finestra con utilization piena' {
        $id = Nuova-SessioneQ @($script:EvInit, (New-EventoQuota 'allowed_warning' 'seven_day' 1 0.5 1795094400), (New-RisultatoLimite "You've hit your 5-hour limit · resets 2:20pm (Europe/Rome)"))
        $e = Get-EsitoSessione -Id $id -CartellaDati $script:D
        $e.Limite.Finestra | Should -Be 'five_hour'
        $e.Limite.Reset | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds(1795094400).UtcDateTime)
    }

    It 'il testo del limite senza nessuna finestra piena: Limite nullo, resta un errore normale' {
        $id = Nuova-SessioneQ @($script:EvInit, (New-EventoQuota 'allowed' 'five_hour' 0.4 0.2), (New-RisultatoLimite "You've hit your 5-hour limit · resets 9pm (Europe/Rome)"))
        $e = Get-EsitoSessione -Id $id -CartellaDati $script:D
        $e.Limite | Should -BeNullOrEmpty
        $e.Errore | Should -BeTrue
    }

    It 'il testo del limite senza rate_limit_event: Limite nullo' {
        $id = Nuova-SessioneQ @($script:EvInit, (New-RisultatoLimite "You've hit your 5-hour limit · resets 9pm (Europe/Rome)"))
        (Get-EsitoSessione -Id $id -CartellaDati $script:D).Limite | Should -BeNullOrEmpty
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }
