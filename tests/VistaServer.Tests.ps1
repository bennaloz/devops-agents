BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VistaServer.psm1') -Force
    $script:Cartella = Join-Path $TestDrive 'dati'
    New-Item -ItemType Directory $script:Cartella | Out-Null
    foreach ($n in 'vista.html', 'sessione-sid-1.html', 'brief-dev.html') {
        [IO.File]::WriteAllText((Join-Path $script:Cartella $n), "<p>$n</p>", [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $script:Cartella 'ufficio.json'), '{"generata":"x"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $script:Cartella 'stato.json'), '{"riservato":1}', [Text.UTF8Encoding]::new($false))
    $script:Atteso = New-TokenVista
    $script:Porta = 8787
    function Get-Corpo($R) { [Text.Encoding]::UTF8.GetString($R.Corpo) }
    $script:Aggiorna = { $script:Aggiornamenti++ }
    function Invoke-Rete([string]$Metodo, [string]$Percorso, $Ricevuto = $null, [scriptblock]$AvviaGiro = { [pscustomobject]@{ Esito = 'avviato'; Messaggio = 'giro avviato' } }, $HostHeader = 'localhost:8787', [bool]$Locale = $true) {
        Get-RispostaVista -Metodo $Metodo -Percorso $Percorso -TokenRicevuto $Ricevuto -Token $script:Atteso -Cartella $script:Cartella `
            -AvviaGiro $AvviaGiro -Aggiorna $script:Aggiorna -HostHeader $HostHeader -Porta $script:Porta -Locale $Locale
    }
}

Describe 'New-TokenVista' {
    It 'e casuale e abbastanza lungo' {
        $a = New-TokenVista; $b = New-TokenVista
        $a | Should -Match '^[0-9a-f]{32,}$'
        $a | Should -Not -Be $b
    }
}

Describe 'Test-TokenVista' {
    It 'accetta solo il token uguale' {
        Test-TokenVista 'abc' 'abc' | Should -BeTrue
        Test-TokenVista 'abc' 'abd' | Should -BeFalse
        Test-TokenVista 'abc' 'abcd' | Should -BeFalse
        Test-TokenVista 'abc' '' | Should -BeFalse
        Test-TokenVista 'abc' $null | Should -BeFalse
        Test-TokenVista '' '' | Should -BeFalse
    }
}

Describe 'Resolve-FileVista' {
    It 'ammette solo vista.html, ufficio.html, sessione-<id>.html e brief-<ruolo>.html' {
        Resolve-FileVista '/vista.html' | Should -Be 'vista.html'
        Resolve-FileVista '/sessione-sid-1.html' | Should -Be 'sessione-sid-1.html'
        Resolve-FileVista '/brief-dev.html' | Should -Be 'brief-dev.html'
        Resolve-FileVista '/ufficio.html' | Should -Be 'ufficio.html'
        Resolve-FileVista '/ufficio.json' | Should -Be 'ufficio.json'
    }
    It 'rifiuta percorsi non ammessi' {
        foreach ($p in '/', '', '/stato.json', '/../stato.json', '/sessione-../x.html', '/sessione-..html', '/brief-a/b.html', '/brief-a\b.html',
                       '/%2e%2e/stato.json', '/vista.html/x', '/sessione-.html', '/log/smistatore.log', '/Vista.ps1', '//vista.html', '/vista.html%00') {
            Resolve-FileVista $p | Should -BeNullOrEmpty -Because "il percorso '$p' non e ammesso"
        }
        Resolve-FileVista $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-RispostaVista: GET' {
    It 'serve ufficio.json come JSON, non come HTML: la pagina dell ufficio lo rilegge da sola' {
        $r = Invoke-Rete 'GET' '/ufficio.json?t=123'
        $r.Codice | Should -Be 200
        $r.Tipo | Should -Match '^application/json'
        Get-Corpo $r | Should -Be '{"generata":"x"}'
    }

    It 'serve un file noto come HTML' {
        $r = Invoke-Rete 'GET' '/vista.html'
        $r.Codice | Should -Be 200
        $r.Tipo | Should -Match '^text/html'
        Get-Corpo $r | Should -Be '<p>vista.html</p>'
        (Get-Corpo (Invoke-Rete 'GET' '/sessione-sid-1.html')) | Should -Be '<p>sessione-sid-1.html</p>'
        (Get-Corpo (Invoke-Rete 'GET' '/brief-dev.html')) | Should -Be '<p>brief-dev.html</p>'
    }
    It 'non serve ne file fuori elenco ne percorsi con ..' {
        foreach ($p in '/stato.json', '/../stato.json', '/sessione-../x.html', '/%2e%2e/stato.json', '/') {
            (Invoke-Rete 'GET' $p).Codice | Should -Be 404 -Because $p
        }
    }
    It 'un file noto che non c e e 404' {
        (Invoke-Rete 'GET' '/brief-reviewer.html').Codice | Should -Be 404
    }
    It 'la query string non cambia il file servito' {
        (Invoke-Rete 'GET' '/vista.html?x=1').Codice | Should -Be 200
        (Invoke-Rete 'GET' '/stato.json?x=/vista.html').Codice | Should -Be 404
    }
}

Describe 'Get-RispostaVista: POST /giro' {
    BeforeEach { $script:Chiamate = 0 }
    It '403 senza token e non avvia niente' {
        $r = Invoke-Rete 'POST' '/giro' $null { $script:Chiamate++; [pscustomobject]@{ Esito = 'avviato'; Messaggio = 'x' } }
        $r.Codice | Should -Be 403
        $script:Chiamate | Should -Be 0
    }
    It '403 con un token sbagliato' {
        $r = Invoke-Rete 'POST' '/giro' (New-TokenVista) { $script:Chiamate++; [pscustomobject]@{ Esito = 'avviato'; Messaggio = 'x' } }
        $r.Codice | Should -Be 403
        $script:Chiamate | Should -Be 0
    }
    It '200 col token giusto e avvia il giro una volta' {
        $r = Invoke-Rete 'POST' '/giro' $script:Atteso { $script:Chiamate++; [pscustomobject]@{ Esito = 'avviato'; Messaggio = 'giro avviato' } }
        $r.Codice | Should -Be 200
        $script:Chiamate | Should -Be 1
        $j = Get-Corpo $r | ConvertFrom-Json
        $j.esito | Should -Be 'avviato'
        $j.messaggio | Should -Be 'giro avviato'
        $r.Tipo | Should -Match 'json'
    }
    It 'se il giro e gia in esecuzione lo dice (409)' {
        $r = Invoke-Rete 'POST' '/giro' $script:Atteso { [pscustomobject]@{ Esito = 'inEsecuzione'; Messaggio = 'il giro e gia in esecuzione' } }
        $r.Codice | Should -Be 409
        (Get-Corpo $r | ConvertFrom-Json).messaggio | Should -Match 'gia in esecuzione'
    }
    It 'se l avvio fallisce riporta l errore (500), anche se lancia' {
        $r = Invoke-Rete 'POST' '/giro' $script:Atteso { [pscustomobject]@{ Esito = 'errore'; Messaggio = 'attivita non trovata' } }
        $r.Codice | Should -Be 500
        (Get-Corpo $r | ConvertFrom-Json).messaggio | Should -Match 'non trovata'
        $r = Invoke-Rete 'POST' '/giro' $script:Atteso { throw 'boom' }
        $r.Codice | Should -Be 500
        (Get-Corpo $r | ConvertFrom-Json).esito | Should -Be 'errore'
    }
    It 'il corpo della richiesta non entra nella funzione: niente dati dell utente arriva all avvio' {
        (Get-Command Get-RispostaVista).Parameters.Keys | Should -Not -Contain 'Corpo'
    }
}

Describe 'Get-RispostaVista: POST /aggiorna-pipeline' {
    BeforeEach { $script:Pipe = 0; $script:Aggiornamenti = 0 }
    It 'col token chiede la rilettura delle sole pipeline; senza token 403; solo POST' {
        $ap = { $script:Pipe++ }
        $chiama = { param($m, $t) Get-RispostaVista -Metodo $m -Percorso '/aggiorna-pipeline' -TokenRicevuto $t -Token $script:Atteso -Cartella $script:Cartella `
            -AvviaGiro { } -Aggiorna $script:Aggiorna -AggiornaPipeline $ap -HostHeader 'localhost:8787' -Porta $script:Porta -Locale $true }
        (& $chiama 'POST' (New-TokenVista)).Codice | Should -Be 403
        (& $chiama 'GET' $script:Atteso).Codice | Should -Be 405
        $script:Pipe | Should -Be 0
        $r = & $chiama 'POST' $script:Atteso
        $r.Codice | Should -Be 202
        ([Text.Encoding]::UTF8.GetString($r.Corpo) | ConvertFrom-Json).messaggio | Should -BeLike '*pipeline*'
        $script:Pipe | Should -Be 1
        $script:Aggiornamenti | Should -Be 0   # agenti e card non si rileggono
    }
}

Describe 'Get-RispostaVista: POST /aggiorna' {
    BeforeEach { $script:Aggiornamenti = 0 }
    It 'senza token o con un token sbagliato: 403 e non chiede niente' {
        (Invoke-Rete 'POST' '/aggiorna' $null).Codice | Should -Be 403
        (Invoke-Rete 'POST' '/aggiorna' (New-TokenVista)).Codice | Should -Be 403
        $script:Aggiornamenti | Should -Be 0
    }
    It 'col token: 202, chiede la rilettura una volta e lo dice' {
        $r = Invoke-Rete 'POST' '/aggiorna' $script:Atteso
        $r.Codice | Should -Be 202
        (Get-Corpo $r | ConvertFrom-Json).esito | Should -Be 'accodato'
        $script:Aggiornamenti | Should -Be 1
    }
    It 'solo POST' {
        (Invoke-Rete 'GET' '/aggiorna' $script:Atteso).Codice | Should -Be 405
        $script:Aggiornamenti | Should -Be 0
    }
    It 'una richiesta non locale e rifiutata' {
        (Invoke-Rete 'POST' '/aggiorna' $script:Atteso $null 'localhost:8787' $false).Codice | Should -Be 403
        $script:Aggiornamenti | Should -Be 0
    }
}

Describe 'Get-RispostaVista: POST /togli-attesa (D37)' {
    BeforeEach { $script:Aggiornamenti = 0; $script:Tolte = [System.Collections.Generic.List[object]]::new() }
    BeforeAll {
        $script:Togli = { param($Id) $script:Tolte.Add($Id) }
        function Invoke-Togli([string]$Metodo, [string]$Percorso, $Ricevuto, [int[]]$InAttesa = @(41, 42), [scriptblock]$Azione = $script:Togli, [string]$HostHeader = 'localhost:8787', [bool]$Locale = $true) {
            Get-RispostaVista -Metodo $Metodo -Percorso $Percorso -TokenRicevuto $Ricevuto -Token $script:Atteso -Cartella $script:Cartella `
                -AvviaGiro { } -Aggiorna $script:Aggiorna -TogliAttesa $Azione -InAttesa $InAttesa -HostHeader $HostHeader -Porta $script:Porta -Locale $Locale
        }
    }
    It 'una card in on-hold: toglie l attesa, chiede la rilettura e risponde 202' {
        $r = Invoke-Togli 'POST' '/togli-attesa?id=42' $script:Atteso
        $r.Codice | Should -Be 202
        (Get-Corpo $r | ConvertFrom-Json).esito | Should -Be 'accodato'
        @($script:Tolte) | Should -Be @(42)
        $script:Aggiornamenti | Should -Be 1
    }
    It 'senza token, con un token sbagliato, da un host non ammesso o non locale: 403 e niente chiamate' {
        (Invoke-Togli 'POST' '/togli-attesa?id=42' $null).Codice | Should -Be 403
        (Invoke-Togli 'POST' '/togli-attesa?id=42' (New-TokenVista)).Codice | Should -Be 403
        (Invoke-Togli 'POST' '/togli-attesa?id=42' $script:Atteso -HostHeader 'evil.example:8787').Codice | Should -Be 403
        (Invoke-Togli 'POST' '/togli-attesa?id=42' $script:Atteso -Locale $false).Codice | Should -Be 403
        $script:Tolte.Count | Should -Be 0
        $script:Aggiornamenti | Should -Be 0
    }
    It 'solo POST' {
        (Invoke-Togli 'GET' '/togli-attesa?id=42' $script:Atteso).Codice | Should -Be 405
        $script:Tolte.Count | Should -Be 0
    }
    It 'un id che non e un intero: 400 e niente chiamate' {
        foreach ($q in '', '?', '?id=', '?id=abc', '?id=4x', '?id=-5', '?id=4.2', '?id=42&id=41', '?id=42&x=1', '?x=42', '?id=0x2A', '?id=99999999999999999999', '?id=%34%32', '?id=42%20', '?id=;rm') {
            (Invoke-Togli 'POST' "/togli-attesa$q" $script:Atteso).Codice | Should -Be 400 -Because "la richiesta '$q' non porta un solo id intero"
        }
        $script:Tolte.Count | Should -Be 0
        $script:Aggiornamenti | Should -Be 0
    }
    It 'un id che la vista non mostra in on-hold: 403 e niente chiamate' {
        (Invoke-Togli 'POST' '/togli-attesa?id=7' $script:Atteso).Codice | Should -Be 403
        (Invoke-Togli 'POST' '/togli-attesa?id=42' $script:Atteso -InAttesa @()).Codice | Should -Be 403
        (Invoke-Togli 'POST' '/togli-attesa?id=42' $script:Atteso -InAttesa $null).Codice | Should -Be 403
        $script:Tolte.Count | Should -Be 0
        $script:Aggiornamenti | Should -Be 0
    }
    It 'se ADO rifiuta: 500 con l errore e nessuna rilettura' {
        $r = Invoke-Togli 'POST' '/togli-attesa?id=42' $script:Atteso -Azione { param($Id) throw 'ADO ha detto no' }
        $r.Codice | Should -Be 500
        (Get-Corpo $r | ConvertFrom-Json).messaggio | Should -BeLike '*ADO ha detto no*'
        $script:Aggiornamenti | Should -Be 0
    }
    It 'senza l azione registrata il percorso non esiste' {
        (Get-RispostaVista -Metodo 'POST' -Percorso '/togli-attesa?id=42' -TokenRicevuto $script:Atteso -Token $script:Atteso -Cartella $script:Cartella `
            -AvviaGiro { } -Aggiorna $script:Aggiorna -InAttesa @(42) -HostHeader 'localhost:8787' -Porta $script:Porta -Locale $true).Codice | Should -Be 404
    }
}

Describe 'Get-RispostaVista: tutto il resto e rifiutato' {
    It 'solo GET dei file noti e POST /giro' {
        (Invoke-Rete 'POST' '/vista.html' $script:Atteso).Codice | Should -Be 405
        (Invoke-Rete 'GET' '/giro').Codice | Should -Be 405
        (Invoke-Rete 'POST' '/altro' $script:Atteso).Codice | Should -Be 404
        foreach ($m in 'PUT', 'DELETE', 'OPTIONS', 'HEAD', 'PATCH') {
            (Invoke-Rete $m '/vista.html' $script:Atteso).Codice | Should -Be 405 -Because $m
            (Invoke-Rete $m '/giro' $script:Atteso).Codice | Should -Be 405 -Because $m
        }
    }
    It 'rifiuta un Host che non e localhost sulla porta del server (DNS rebinding)' {
        foreach ($h in 'evil.example:8787', 'localhost:9999', 'localhost', $null, '', '192.168.1.5:8787') {
            (Invoke-Rete 'GET' '/vista.html' $null $null $h).Codice | Should -Be 403 -Because "Host '$h'"
        }
        # con il prefisso localhost http.sys rifiuta gia 127.0.0.1 e [::1]: l'unico Host ammesso e localhost
        (Invoke-Rete 'GET' '/vista.html' $null $null 'localhost:8787').Codice | Should -Be 200
        foreach ($h in '127.0.0.1:8787', '[::1]:8787') {
            (Invoke-Rete 'GET' '/vista.html' $null $null $h).Codice | Should -Be 403 -Because "Host '$h'"
        }
    }
}

Describe 'Get-RispostaVista: solo richieste locali' {
    It 'una richiesta non locale e rifiutata (403) anche con Host localhost e token giusto' {
        (Invoke-Rete 'GET' '/vista.html' $null $null 'localhost:8787' $false).Codice | Should -Be 403
        $r = Invoke-Rete 'POST' '/giro' $script:Atteso { throw 'non deve partire' } 'localhost:8787' $false
        $r.Codice | Should -Be 403
    }
    It 'senza dire se e locale il server rifiuta (default sicuro)' {
        (Get-RispostaVista -Metodo 'GET' -Percorso '/vista.html' -Token $script:Atteso -Cartella $script:Cartella -HostHeader 'localhost:8787' -Porta 8787).Codice | Should -Be 403
    }
}

Describe 'Invoke-GestioneRichiesta: il cablaggio fra HttpListener e le funzioni pure' {
    BeforeAll {
        function New-CtxFinto([string]$Metodo, [string]$Url, [bool]$Locale = $true, [hashtable]$Header = @{ Host = 'localhost:8787' }) {
            $h = [System.Collections.Specialized.NameValueCollection]::new()
            foreach ($k in $Header.Keys) { $h[$k] = $Header[$k] }
            $resp = [pscustomobject]@{ StatusCode = 0; ContentType = $null; Headers = [System.Collections.Specialized.NameValueCollection]::new(); ContentLength64 = 0L; OutputStream = [IO.MemoryStream]::new(); Chiusa = $false }
            $resp | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Chiusa = $true }
            [pscustomobject]@{ Request = [pscustomobject]@{ HttpMethod = $Metodo; RawUrl = $Url; Headers = $h; IsLocal = $Locale }; Response = $resp }
        }
        function Get-TestoCtx($Ctx) { [Text.Encoding]::UTF8.GetString($Ctx.Response.OutputStream.ToArray()) }
        $script:Chiamate = 0
        $script:Avvia = { $script:Chiamate++; [pscustomobject]@{ Esito = 'avviato'; Messaggio = 'giro avviato' } }
        function Invoke-Gestione($Ctx) { Invoke-GestioneRichiesta $Ctx $script:Atteso $script:Cartella $script:Avvia 8787 }
    }
    BeforeEach { $script:Chiamate = 0 }
    It 'GET di un file noto: 200, tipo, header di sicurezza e corpo' {
        $c = New-CtxFinto 'GET' '/vista.html'
        Invoke-Gestione $c
        $c.Response.StatusCode | Should -Be 200
        $c.Response.ContentType | Should -Match '^text/html'
        $c.Response.Headers['Cache-Control'] | Should -Be 'no-store'
        $c.Response.Headers['X-Content-Type-Options'] | Should -Be 'nosniff'
        Get-TestoCtx $c | Should -Be '<p>vista.html</p>'
        $c.Response.ContentLength64 | Should -Be ([Text.Encoding]::UTF8.GetByteCount('<p>vista.html</p>'))
        $c.Response.Chiusa | Should -BeTrue
    }
    It 'un client che chiude prima della risposta non finisce in console; un altro errore di scrittura si' {
        Mock Write-Host -ModuleName VistaServer { }
        $c = New-CtxFinto 'GET' '/vista.html'
        $c.Response.OutputStream = [pscustomobject]@{} | Add-Member -PassThru ScriptMethod Write { throw [System.Net.HttpListenerException]::new(64) }
        Invoke-Gestione $c
        Should -Invoke Write-Host -ModuleName VistaServer -Times 0 -Exactly
        $c.Response.OutputStream = [pscustomobject]@{} | Add-Member -PassThru ScriptMethod Write { throw [IO.IOException]::new('disco pieno') }
        Invoke-Gestione $c
        Should -Invoke Write-Host -ModuleName VistaServer -Times 1 -Exactly -ParameterFilter { "$Object" -match 'risposta non scritta.*disco pieno' }
    }
    It 'POST /giro senza token: 403 e non avvia niente' {
        $c = New-CtxFinto 'POST' '/giro'
        Invoke-Gestione $c
        $c.Response.StatusCode | Should -Be 403
        $script:Chiamate | Should -Be 0
    }
    It 'POST /giro col token: 200 e avvia il giro una volta' {
        $c = New-CtxFinto 'POST' '/giro' $true @{ Host = 'localhost:8787'; 'X-Vista-Token' = $script:Atteso }
        Invoke-Gestione $c
        $c.Response.StatusCode | Should -Be 200
        (Get-TestoCtx $c | ConvertFrom-Json).esito | Should -Be 'avviato'
        $script:Chiamate | Should -Be 1
    }
    It 'POST /togli-attesa: la lista bianca si legge da Segnali a ogni richiesta, non una volta sola' {
        $segnali = [pscustomobject]@{ Aggiorna = $false; AggiornaPipeline = $false; InAttesa = @(42) }
        $script:Tolte2 = @()
        $togli = { param($Id) $script:Tolte2 += $Id }
        $agg = { $segnali.Aggiorna = $true }.GetNewClosure()
        $h = @{ Host = 'localhost:8787'; 'X-Vista-Token' = $script:Atteso }
        $c = New-CtxFinto 'POST' '/togli-attesa?id=42' $true $h
        Invoke-GestioneRichiesta $c $script:Atteso $script:Cartella $script:Avvia 8787 $agg $null $togli $segnali
        $c.Response.StatusCode | Should -Be 202
        $segnali.Aggiorna | Should -BeTrue
        $segnali.InAttesa = @()   # la vista ha riletto: la card non e piu in on-hold
        $c2 = New-CtxFinto 'POST' '/togli-attesa?id=42' $true $h
        Invoke-GestioneRichiesta $c2 $script:Atteso $script:Cartella $script:Avvia 8787 $agg $null $togli $segnali
        $c2.Response.StatusCode | Should -Be 403
        $script:Tolte2 | Should -Be @(42)
    }
    It 'una richiesta non locale e rifiutata (403) senza servire ne avviare niente' {
        $c = New-CtxFinto 'POST' '/giro' $false @{ Host = 'localhost:8787'; 'X-Vista-Token' = $script:Atteso }
        Invoke-Gestione $c
        $c.Response.StatusCode | Should -Be 403
        $script:Chiamate | Should -Be 0
        $c2 = New-CtxFinto 'GET' '/vista.html' $false
        Invoke-Gestione $c2
        $c2.Response.StatusCode | Should -Be 403
        Get-TestoCtx $c2 | Should -Not -Match 'vista.html</p>'
    }
    It 'se la gestione fallisce scrive l errore in console e risponde 500 con un testo' {
        Mock Write-Host { } -ModuleName VistaServer
        Mock Get-RispostaVista { throw 'guasto interno' } -ModuleName VistaServer
        $c = New-CtxFinto 'GET' '/vista.html'
        Invoke-Gestione $c
        $c.Response.StatusCode | Should -Be 500
        Get-TestoCtx $c | Should -Not -BeNullOrEmpty
        Should -Invoke Write-Host -ModuleName VistaServer -ParameterFilter { "$Object" -match 'guasto interno' }
        $c.Response.Chiusa | Should -BeTrue
    }
}

Describe 'Start-GiroPianificato' {
    It 'avvia l attivita dello smistatore' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } } -ModuleName VistaServer
        Mock Start-ScheduledTask { } -ModuleName VistaServer
        $r = Start-GiroPianificato
        $r.Esito | Should -Be 'avviato'
        $r.Messaggio | Should -Be 'smistatore avviato'
        Should -Invoke Start-ScheduledTask -ModuleName VistaServer -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Smistatore' -and $TaskPath -eq '\DevOps.Agents\' }
    }
    It 'se e gia in esecuzione non ne avvia un altra' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Running' } } -ModuleName VistaServer
        Mock Start-ScheduledTask { } -ModuleName VistaServer
        $r = Start-GiroPianificato
        $r.Esito | Should -Be 'inEsecuzione'
        Should -Invoke Start-ScheduledTask -ModuleName VistaServer -Times 0 -Exactly
    }
    It 'se l attivita non c e o l avvio fallisce riporta l errore' {
        Mock Get-ScheduledTask { throw 'non trovata' } -ModuleName VistaServer
        Mock Start-ScheduledTask { } -ModuleName VistaServer
        $r = Start-GiroPianificato
        $r.Esito | Should -Be 'errore'
        $r.Messaggio | Should -Match 'non trovata'
        Should -Invoke Start-ScheduledTask -ModuleName VistaServer -Times 0 -Exactly
    }
}

Describe 'Il server e il ciclo' {
    It 'Invoke-RichiesteVista serve la richiesta in attesa e ritorna allo scadere dei secondi, senza porta vera' {
        $ctx = [pscustomobject]@{ Fatto = $false }; $stato = @{ Prima = $true }
        $server = [pscustomobject]@{
            Attesa = $null
            # la prima richiesta e gia arrivata, le altre non arrivano mai
            Prendi = { if ($stato.Prima) { $stato.Prima = $false; [System.Threading.Tasks.Task]::FromResult($ctx) } else { [System.Threading.Tasks.TaskCompletionSource[object]]::new().Task } }.GetNewClosure()
            Gestisci = { param($c) $c.Fatto = $true }
        }
        $t = Get-Date
        Invoke-RichiesteVista $server 1
        $ctx.Fatto | Should -BeTrue
        ((Get-Date) - $t).TotalSeconds | Should -BeGreaterOrEqual 0.9
        ((Get-Date) - $t).TotalSeconds | Should -BeLessThan 3
    }

    It 'Invoke-RichiesteVista ritorna subito dopo una richiesta che chiede la rilettura, senza aspettare i secondi' {
        $ctx = [pscustomobject]@{ Fatto = $false }; $stato = @{ Prima = $true }
        $segnali = [pscustomobject]@{ Aggiorna = $false }
        $server = [pscustomobject]@{
            Attesa = $null; Segnali = $segnali
            Prendi = { if ($stato.Prima) { $stato.Prima = $false; [System.Threading.Tasks.Task]::FromResult($ctx) } else { [System.Threading.Tasks.TaskCompletionSource[object]]::new().Task } }.GetNewClosure()
            Gestisci = { param($c) $c.Fatto = $true; $segnali.Aggiorna = $true }.GetNewClosure()
        }
        $t = Get-Date
        Invoke-RichiesteVista $server 10
        $ctx.Fatto | Should -BeTrue
        ((Get-Date) - $t).TotalSeconds | Should -BeLessThan 2
    }
}

Describe 'Get-RispostaVista: POST /soglia (D51, 2026-11-24)' {
    BeforeAll {
        function Invoke-Soglia([string]$Metodo, [string]$Percorso, $Ricevuto, [scriptblock]$Imposta, [bool]$ConAggiorna = $true) {
            $args2 = @{ Metodo = $Metodo; Percorso = $Percorso; TokenRicevuto = $Ricevuto; Token = $script:Atteso; Cartella = $script:Cartella
                        AvviaGiro = { }; HostHeader = 'localhost:8787'; Porta = $script:Porta; Locale = $true; ImpostaSoglia = $Imposta }
            if ($ConAggiorna) { $args2.Aggiorna = { $script:Aggiornamenti++ } }
            Get-RispostaVista @args2
        }
        $script:Ok = { param($q) $script:Ricevuti += , $q; @{ Esito = 'ok'; Messaggio = 'soglia aggiornata' } }
    }
    BeforeEach { $script:Aggiornamenti = 0; $script:Ricevuti = @() }
    It 'senza token o con un token sbagliato: 403 e non scrive niente' {
        (Invoke-Soglia 'POST' '/soglia?soglia=0.8' $null $script:Ok).Codice | Should -Be 403
        (Invoke-Soglia 'POST' '/soglia?soglia=0.8' (New-TokenVista) $script:Ok).Codice | Should -Be 403
        $script:Ricevuti.Count | Should -Be 0
        $script:Aggiornamenti | Should -Be 0
    }
    It 'solo POST' {
        (Invoke-Soglia 'GET' '/soglia?soglia=0.8' $script:Atteso $script:Ok).Codice | Should -Be 405
        $script:Ricevuti.Count | Should -Be 0
    }
    It 'col token: passa solo i parametri noti, risponde 202 e fa ridisegnare la pagina' {
        $r = Invoke-Soglia 'POST' '/soglia?soglia=0.8500&ignoraRiserva=1&altro=x&ripristina=0' $script:Atteso $script:Ok
        $r.Codice | Should -Be 202
        (Get-Corpo $r | ConvertFrom-Json).esito | Should -Be 'accodato'
        $script:Ricevuti.Count | Should -Be 1
        $q = $script:Ricevuti[0]
        $q['soglia'] | Should -Be '0.8500'; $q['ignoraRiserva'] | Should -Be '1'; $q['ripristina'] | Should -Be '0'
        $q.ContainsKey('altro') | Should -BeFalse
        $script:Aggiornamenti | Should -Be 1
    }
    It 'senza query passa una tabella vuota; i valori codificati si decodificano' {
        Invoke-Soglia 'POST' '/soglia' $script:Atteso $script:Ok | Out-Null
        $script:Ricevuti[0].Count | Should -Be 0
        Invoke-Soglia 'POST' '/soglia?soglia=0%2E8' $script:Atteso $script:Ok | Out-Null
        $script:Ricevuti[1]['soglia'] | Should -Be '0.8'
    }
    It 'un rifiuto della validazione e 400 col messaggio, e non ridisegna' {
        $r = Invoke-Soglia 'POST' '/soglia?soglia=2' $script:Atteso { param($q) @{ Esito = 'errore'; Messaggio = 'la soglia deve stare fra 5% e 95%' } }
        $r.Codice | Should -Be 400
        $j = Get-Corpo $r | ConvertFrom-Json
        $j.esito | Should -Be 'errore'; $j.messaggio | Should -Match 'fra 5% e 95%'
        $script:Aggiornamenti | Should -Be 0
    }
    It 'se la scrittura lancia: 400 con l errore, mai un 500 nudo' {
        $r = Invoke-Soglia 'POST' '/soglia?soglia=0.8' $script:Atteso { throw 'disco pieno' }
        $r.Codice | Should -Be 400
        (Get-Corpo $r | ConvertFrom-Json).messaggio | Should -Match 'disco pieno'
    }
    It 'senza il comando collegato (pagina da file) la rotta non esiste' {
        (Invoke-Soglia 'POST' '/soglia?soglia=0.8' $script:Atteso $null).Codice | Should -Be 404
    }
    It 'una richiesta non locale o con host sbagliato e rifiutata' {
        (Get-RispostaVista -Metodo 'POST' -Percorso '/soglia' -TokenRicevuto $script:Atteso -Token $script:Atteso -Cartella $script:Cartella -HostHeader 'localhost:8787' -Porta 8787 -Locale $false -ImpostaSoglia $script:Ok).Codice | Should -Be 403
        (Get-RispostaVista -Metodo 'POST' -Percorso '/soglia' -TokenRicevuto $script:Atteso -Token $script:Atteso -Cartella $script:Cartella -HostHeader 'evil.example:8787' -Porta 8787 -Locale $true -ImpostaSoglia $script:Ok).Codice | Should -Be 403
        $script:Ricevuti.Count | Should -Be 0
    }
    It 'il cablaggio: Invoke-GestioneRichiesta passa il comando al server' {
        $h = [System.Collections.Specialized.NameValueCollection]::new(); $h['Host'] = 'localhost:8787'; $h['X-Vista-Token'] = $script:Atteso
        $resp = [pscustomobject]@{ StatusCode = 0; ContentType = $null; Headers = [System.Collections.Specialized.NameValueCollection]::new(); ContentLength64 = 0L; OutputStream = [IO.MemoryStream]::new() }
        $resp | Add-Member -MemberType ScriptMethod -Name Close -Value { }
        $ctx = [pscustomobject]@{ Request = [pscustomobject]@{ HttpMethod = 'POST'; RawUrl = '/soglia?ripristina=1'; Headers = $h; IsLocal = $true }; Response = $resp }
        Invoke-GestioneRichiesta $ctx $script:Atteso $script:Cartella { } 8787 -ImpostaSoglia $script:Ok
        $resp.StatusCode | Should -Be 202
        $script:Ricevuti[0]['ripristina'] | Should -Be '1'
    }
}

Describe 'Start-ServerVista: il comando della soglia arriva fino alla richiesta (D51, 2026-11-24)' {
    It 'una richiesta passata da .Gestisci raggiunge il comando collegato, col token del server, e accoda la rilettura' {
        $porta = 18933
        $script:Parametri = $null
        $comando = { param($q) $script:Parametri = $q; @{ Esito = 'ok'; Messaggio = 'soglia aggiornata' } }
        $server = Start-ServerVista $porta $script:Cartella $script:Atteso { } -ImpostaSoglia $comando
        try {
            $h = [System.Collections.Specialized.NameValueCollection]::new(); $h['Host'] = "localhost:$porta"; $h['X-Vista-Token'] = $script:Atteso
            $resp = [pscustomobject]@{ StatusCode = 0; ContentType = $null; Headers = [System.Collections.Specialized.NameValueCollection]::new(); ContentLength64 = 0L; OutputStream = [IO.MemoryStream]::new() }
            $resp | Add-Member -MemberType ScriptMethod -Name Close -Value { }
            $ctx = [pscustomobject]@{ Request = [pscustomobject]@{ HttpMethod = 'POST'; RawUrl = '/soglia?soglia=0.8000&ignoraRiserva=1'; Headers = $h; IsLocal = $true }; Response = $resp }
            & $server.Gestisci $ctx
            $resp.StatusCode | Should -Be 202
            $script:Parametri['soglia'] | Should -Be '0.8000'; $script:Parametri['ignoraRiserva'] | Should -Be '1'
            $server.Segnali.Aggiorna | Should -BeTrue
            # col token sbagliato il comando non parte
            $script:Parametri = $null; $h['X-Vista-Token'] = 'sbagliato'
            $resp.OutputStream = [IO.MemoryStream]::new()
            & $server.Gestisci $ctx
            $resp.StatusCode | Should -Be 403
            $script:Parametri | Should -BeNullOrEmpty
        }
        finally { Stop-ServerVista $server }
    }
}

Describe 'Get-RispostaVista: POST /aggiorna-suite (D53)' {
    BeforeAll {
        function Invoke-Suite([string]$Metodo, $Ricevuto, [scriptblock]$Comando, [bool]$Locale = $true, [string]$HostHeader = 'localhost:8787') {
            Get-RispostaVista -Metodo $Metodo -Percorso '/aggiorna-suite' -TokenRicevuto $Ricevuto -Token $script:Atteso -Cartella $script:Cartella -AvviaGiro { } `
                -HostHeader $HostHeader -Porta $script:Porta -Locale $Locale -AggiornaSuite $Comando -Aggiorna { $script:Aggiornamenti++ }
        }
        $script:Ok = { $script:Chiamate++; @{ Esito = 'ok'; Messaggio = 'richiesta inviata: il supervisore parte adesso' } }
    }
    BeforeEach { $script:Chiamate = 0; $script:Aggiornamenti = 0 }
    It 'senza token o con un token sbagliato: 403 e non scrive niente' {
        (Invoke-Suite 'POST' $null $script:Ok).Codice | Should -Be 403
        (Invoke-Suite 'POST' (New-TokenVista) $script:Ok).Codice | Should -Be 403
        $script:Chiamate | Should -Be 0
    }
    It 'solo POST' {
        (Invoke-Suite 'GET' $script:Atteso $script:Ok).Codice | Should -Be 405
        $script:Chiamate | Should -Be 0
    }
    It 'col token: chiama il comando una volta e risponde 202 col messaggio' {
        $r = Invoke-Suite 'POST' $script:Atteso $script:Ok
        $r.Codice | Should -Be 202
        $j = Get-Corpo $r | ConvertFrom-Json
        $j.esito | Should -Be 'accodato'; $j.messaggio | Should -Match 'supervisore parte adesso'
        $script:Chiamate | Should -Be 1
    }
    It 'un comando che fallisce o lancia e un 500 con l errore' {
        (Invoke-Suite 'POST' $script:Atteso { @{ Esito = 'errore'; Messaggio = 'il supervisore non parte' } }).Codice | Should -Be 500
        $r = Invoke-Suite 'POST' $script:Atteso { throw 'disco pieno' }
        $r.Codice | Should -Be 500
        (Get-Corpo $r | ConvertFrom-Json).messaggio | Should -Match 'disco pieno'
    }
    It 'senza il comando collegato la rotta non esiste; non locale o host sbagliato: 403' {
        (Invoke-Suite 'POST' $script:Atteso $null).Codice | Should -Be 404
        (Invoke-Suite 'POST' $script:Atteso $script:Ok $false).Codice | Should -Be 403
        (Invoke-Suite 'POST' $script:Atteso $script:Ok $true 'evil.example:8787').Codice | Should -Be 403
        $script:Chiamate | Should -Be 0
    }
    It 'il cablaggio: Invoke-GestioneRichiesta passa il comando al server' {
        $h = [System.Collections.Specialized.NameValueCollection]::new(); $h['Host'] = 'localhost:8787'; $h['X-Vista-Token'] = $script:Atteso
        $resp = [pscustomobject]@{ StatusCode = 0; ContentType = $null; Headers = [System.Collections.Specialized.NameValueCollection]::new(); ContentLength64 = 0L; OutputStream = [IO.MemoryStream]::new() }
        $resp | Add-Member -MemberType ScriptMethod -Name Close -Value { }
        $ctx = [pscustomobject]@{ Request = [pscustomobject]@{ HttpMethod = 'POST'; RawUrl = '/aggiorna-suite'; Headers = $h; IsLocal = $true }; Response = $resp }
        Invoke-GestioneRichiesta $ctx $script:Atteso $script:Cartella { } 8787 -AggiornaSuite $script:Ok
        $resp.StatusCode | Should -Be 202
        $script:Chiamate | Should -Be 1
    }
}

Describe 'Get-RispostaVista: POST /automatico?attivo=0|1 (D53)' {
    BeforeAll {
        function Invoke-Auto([string]$Metodo, [string]$Percorso, $Ricevuto, [scriptblock]$Comando, [bool]$Locale = $true) {
            Get-RispostaVista -Metodo $Metodo -Percorso $Percorso -TokenRicevuto $Ricevuto -Token $script:Atteso -Cartella $script:Cartella -AvviaGiro { } `
                -HostHeader 'localhost:8787' -Porta $script:Porta -Locale $Locale -ImpostaAutomatico $Comando -Aggiorna { $script:Aggiornamenti++ }
        }
        $script:Ok = { param($Attivo) $script:Ricevuti += , $Attivo; @{ Esito = 'ok'; Messaggio = 'impostato' } }
    }
    BeforeEach { $script:Ricevuti = @(); $script:Aggiornamenti = 0 }
    It 'senza token o con un token sbagliato: 403 e non scrive niente' {
        (Invoke-Auto 'POST' '/automatico?attivo=1' $null $script:Ok).Codice | Should -Be 403
        (Invoke-Auto 'POST' '/automatico?attivo=1' (New-TokenVista) $script:Ok).Codice | Should -Be 403
        $script:Ricevuti.Count | Should -Be 0
    }
    It 'solo POST' {
        (Invoke-Auto 'GET' '/automatico?attivo=1' $script:Atteso $script:Ok).Codice | Should -Be 405
        $script:Ricevuti.Count | Should -Be 0
    }
    It 'attivo=1 e attivo=0 arrivano al comando come vero e falso, e la pagina si ridisegna' {
        (Invoke-Auto 'POST' '/automatico?attivo=1' $script:Atteso $script:Ok).Codice | Should -Be 202
        (Invoke-Auto 'POST' '/automatico?attivo=0' $script:Atteso $script:Ok).Codice | Should -Be 202
        $script:Ricevuti | Should -Be @($true, $false)
        $script:Ricevuti[0] | Should -BeOfType [bool]
        $script:Aggiornamenti | Should -Be 2
    }
    It 'la query ha solo i parametri noti con valori noti: tutto il resto e 400 e non scrive' {
        foreach ($q in '', '?', '?attivo=', '?attivo=2', '?attivo=true', '?attivo=1&altro=x', '?altro=1', '?attivo=1&attivo=0', '?attivo=10', '?attivo=1%0A', '?ATTIVO=1x') {
            (Invoke-Auto 'POST' "/automatico$q" $script:Atteso $script:Ok).Codice | Should -Be 400 -Because "la query '$q' non e ammessa"
        }
        $script:Ricevuti.Count | Should -Be 0
    }
    It 'un comando che fallisce o lancia e un 400 con l errore e non ridisegna' {
        (Invoke-Auto 'POST' '/automatico?attivo=1' $script:Atteso { @{ Esito = 'errore'; Messaggio = 'no' } }).Codice | Should -Be 400
        $r = Invoke-Auto 'POST' '/automatico?attivo=1' $script:Atteso { throw 'disco pieno' }
        $r.Codice | Should -Be 400
        (Get-Corpo $r | ConvertFrom-Json).messaggio | Should -Match 'disco pieno'
        $script:Aggiornamenti | Should -Be 0
    }
    It 'senza il comando collegato la rotta non esiste; non locale: 403' {
        (Invoke-Auto 'POST' '/automatico?attivo=1' $script:Atteso $null).Codice | Should -Be 404
        (Invoke-Auto 'POST' '/automatico?attivo=1' $script:Atteso $script:Ok $false).Codice | Should -Be 403
    }
    It 'il cablaggio: Start-ServerVista porta il comando fino alla richiesta e accoda la rilettura' {
        $porta = 18934
        $script:Ricevuti = @()
        $server = Start-ServerVista $porta $script:Cartella $script:Atteso { } -ImpostaAutomatico $script:Ok
        try {
            $h = [System.Collections.Specialized.NameValueCollection]::new(); $h['Host'] = "localhost:$porta"; $h['X-Vista-Token'] = $script:Atteso
            $resp = [pscustomobject]@{ StatusCode = 0; ContentType = $null; Headers = [System.Collections.Specialized.NameValueCollection]::new(); ContentLength64 = 0L; OutputStream = [IO.MemoryStream]::new() }
            $resp | Add-Member -MemberType ScriptMethod -Name Close -Value { }
            $ctx = [pscustomobject]@{ Request = [pscustomobject]@{ HttpMethod = 'POST'; RawUrl = '/automatico?attivo=0'; Headers = $h; IsLocal = $true }; Response = $resp }
            & $server.Gestisci $ctx
            $resp.StatusCode | Should -Be 202
            $script:Ricevuti | Should -Be @($false)
            $server.Segnali.Aggiorna | Should -BeTrue
        }
        finally { Stop-ServerVista $server }
    }
}

Describe 'Start-SupervisorePianificato (D53): la vista avvia il supervisore, che e chi aggiorna' {
    It 'avvia l attivita del supervisore e non quella dello smistatore' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } } -ModuleName VistaServer
        Mock Start-ScheduledTask { } -ModuleName VistaServer
        $r = Start-SupervisorePianificato
        $r.Esito | Should -Be 'avviato'
        Should -Invoke Start-ScheduledTask -ModuleName VistaServer -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Supervisore' -and $TaskPath -eq '\DevOps.Agents\' }
    }
    It 'se gira gia non ne avvia un altro' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Running' } } -ModuleName VistaServer
        Mock Start-ScheduledTask { } -ModuleName VistaServer
        (Start-SupervisorePianificato).Esito | Should -Be 'inEsecuzione'
        Should -Invoke Start-ScheduledTask -ModuleName VistaServer -Times 0 -Exactly
    }
}

Describe 'Get-RispostaVista: POST /ordine e /pausa (D60)' {
    BeforeEach { $script:Aggiornamenti = 0; $script:Chiamate = [System.Collections.Generic.List[object]]::new() }
    BeforeAll {
        $script:Ordina = { param($Id, $Dopo) $script:Chiamate.Add("ordine $Id $Dopo"); @{ Esito = 'ok'; Messaggio = 'fatto' } }
        $script:Pausa = { param($Id, $Attiva) $script:Chiamate.Add("pausa $Id $Attiva"); @{ Esito = 'ok'; Messaggio = 'fatto' } }
        function Invoke-Priorita([string]$Percorso, $Ricevuto = $script:Atteso, [string]$Metodo = 'POST') {
            Get-RispostaVista -Metodo $Metodo -Percorso $Percorso -TokenRicevuto $Ricevuto -Token $script:Atteso -Cartella $script:Cartella `
                -AvviaGiro { } -Aggiorna $script:Aggiorna -ImpostaOrdine $script:Ordina -ImpostaPausa $script:Pausa -Feature @(10, 20) -HostHeader 'localhost:8787' -Porta $script:Porta -Locale $true
        }
    }
    It 'sposta una Feature dopo un altra o in cima, e chiede la rilettura' {
        (Invoke-Priorita '/ordine?id=20&dopo=0').Codice | Should -Be 202
        (Invoke-Priorita '/ordine?id=10&dopo=20').Codice | Should -Be 202
        @($script:Chiamate) | Should -Be @('ordine 20 0', 'ordine 10 20')
        $script:Aggiornamenti | Should -Be 2
    }
    It 'mette e toglie la pausa' {
        (Invoke-Priorita '/pausa?id=10&attiva=1').Codice | Should -Be 202
        (Invoke-Priorita '/pausa?id=10&attiva=0').Codice | Should -Be 202
        @($script:Chiamate) | Should -Be @('pausa 10 True', 'pausa 10 False')
    }
    It 'rifiuta senza token, con id fuori dalla lista bianca o parametri sbagliati, e non chiama niente' {
        (Invoke-Priorita '/ordine?id=10&dopo=0' $null).Codice | Should -Be 403
        (Invoke-Priorita '/ordine?id=99&dopo=0').Codice | Should -Be 400
        (Invoke-Priorita '/ordine?id=10&dopo=99').Codice | Should -Be 400
        (Invoke-Priorita '/pausa?id=10&attiva=2').Codice | Should -Be 400
        (Invoke-Priorita '/pausa?id=abc&attiva=1').Codice | Should -Be 400
        (Invoke-Priorita '/pausa?id=10&attiva=1' $script:Atteso 'GET').Codice | Should -Be 405
        $script:Chiamate.Count | Should -Be 0
    }
}

Describe 'Get-RispostaVista: POST /soglia con soglia5Ore e POST /pausa-sistema (D60)' {
    It 'soglia5Ore arriva al comando della soglia' {
        $script:Ricevuti = $null
        $imposta = { param($P) $script:Ricevuti = $P; @{ Esito = 'ok'; Messaggio = 'fatto' } }
        $r = Get-RispostaVista -Metodo 'POST' -Percorso '/soglia?soglia5Ore=0.8000' -TokenRicevuto $script:Atteso -Token $script:Atteso -Cartella $script:Cartella `
            -AvviaGiro { } -Aggiorna { } -ImpostaSoglia $imposta -HostHeader 'localhost:8787' -Porta $script:Porta -Locale $true
        $r.Codice | Should -Be 202
        $script:Ricevuti['soglia5Ore'] | Should -Be '0.8000'
    }
    It 'pausa-sistema passa vero o falso, rifiuta il resto e senza token' {
        $script:Chiesti = [System.Collections.Generic.List[object]]::new()
        $pausa = { param($A) $script:Chiesti.Add($A); @{ Esito = 'ok'; Messaggio = 'fatto' } }
        $chiedi = { param($Percorso, $Ricevuto) Get-RispostaVista -Metodo 'POST' -Percorso $Percorso -TokenRicevuto $Ricevuto -Token $script:Atteso -Cartella $script:Cartella `
            -AvviaGiro { } -Aggiorna { } -ImpostaPausaSistema $pausa -HostHeader 'localhost:8787' -Porta $script:Porta -Locale $true }
        (& $chiedi '/pausa-sistema?attivo=1' $script:Atteso).Codice | Should -Be 202
        (& $chiedi '/pausa-sistema?attivo=0' $script:Atteso).Codice | Should -Be 202
        (& $chiedi '/pausa-sistema?attivo=2' $script:Atteso).Codice | Should -Be 400
        (& $chiedi '/pausa-sistema?attivo=1' $null).Codice | Should -Be 403
        @($script:Chiesti) | Should -Be @($true, $false)
    }
}
