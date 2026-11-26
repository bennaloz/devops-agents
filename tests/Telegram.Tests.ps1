BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Telegram.psm1') -Force
    # Valore inventato a ogni esecuzione: nei test non c'e nessun valore fisso che somigli a un token vero, e i file veri
    # non si toccano.
    $script:ValoreFinto = '1234:FINTO-' + [guid]::NewGuid().ToString('N')

    function New-Dati([string]$Valore = $script:ValoreFinto, [string]$Chat = '-100123456') {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $d | Out-Null
        $f = Join-Path $d 'file-del-bot.txt'
        if ($null -ne $Valore) { Set-Content -LiteralPath $f -Value $Valore -NoNewline }
        if ($null -ne $Chat) { Set-Content -LiteralPath (Join-Path $d 'telegram-chat.txt') -Value $Chat -NoNewline }
        [pscustomobject]@{ Dati = $d; FileBot = $f }
    }
}

Describe 'Test-TelegramConfigurato' {
    It 'vero se i due file esistono e non sono vuoti' {
        $x = New-Dati
        Test-TelegramConfigurato -CartellaDati $x.Dati -PercorsoToken $x.FileBot | Should -BeTrue
    }
    It 'falso senza il file del bot' {
        $x = New-Dati -Valore $null
        Test-TelegramConfigurato -CartellaDati $x.Dati -PercorsoToken $x.FileBot | Should -BeFalse
    }
    It 'falso senza il file della chat' {
        $x = New-Dati -Chat $null
        Test-TelegramConfigurato -CartellaDati $x.Dati -PercorsoToken $x.FileBot | Should -BeFalse
    }
    It 'falso se un file e vuoto o fatto di soli spazi' {
        $x = New-Dati -Valore "  `r`n"
        Test-TelegramConfigurato -CartellaDati $x.Dati -PercorsoToken $x.FileBot | Should -BeFalse
        $y = New-Dati -Chat ''
        Test-TelegramConfigurato -CartellaDati $y.Dati -PercorsoToken $y.FileBot | Should -BeFalse
    }
    It 'il file del bot sta per predefinito nel profilo utente, non in un percorso scritto fisso' {
        Get-TelegramPercorsoTokenPredefinito | Should -Be (Join-Path $HOME '.claude/telegram-token.txt')
    }
}

Describe 'ConvertTo-AnteprimaTelegram' {
    It 'lascia intatto un testo breve e semplice' {
        ConvertTo-AnteprimaTelegram -Testo 'Quale formato per la data?' | Should -Be 'Quale formato per la data?'
    }
    It 'toglie i blocchi di codice recintati' {
        $t = "Prima`n``````powershell`nGet-Secret -Cliente Rossi`n```````nDopo"
        $r = ConvertTo-AnteprimaTelegram -Testo $t
        $r | Should -Not -Match 'Get-Secret|Rossi|```'
        $r | Should -Match 'Prima'
        $r | Should -Match 'Dopo'
    }
    It 'toglie un blocco recintato mai chiuso fino alla fine' {
        $r = ConvertTo-AnteprimaTelegram -Testo "Domanda`n``````sql`nSELECT * FROM clienti"
        $r | Should -Be 'Domanda'
    }
    It 'toglie il codice in linea con il suo contenuto' {
        $r = ConvertTo-AnteprimaTelegram -Testo 'Usare `Invoke-Cliente -Id 5` oppure no?'
        $r | Should -Not -Match 'Invoke-Cliente|`'
        $r | Should -Match 'Usare'
        $r | Should -Match 'oppure no\?'
    }
    It 'toglie i tag HTML dei commenti di Azure DevOps e decodifica le entita' {
        $r = ConvertTo-AnteprimaTelegram -Testo '<p>Serve <b>davvero</b> il campo &quot;Note&quot; &amp; il resto?<br>Link: <a href="https://x.it/a">qui</a></p>'
        $r | Should -Be 'Serve davvero il campo "Note" & il resto? Link: qui'
    }
    It 'toglie i blocchi pre/code dell HTML con il contenuto' {
        $r = ConvertTo-AnteprimaTelegram -Testo '<div>Vedi:</div><pre><code>SELECT cf FROM clienti</code></pre><p>Fine</p>'
        $r | Should -Not -Match 'SELECT|clienti'
        $r | Should -Match 'Vedi'
        $r | Should -Match 'Fine'
    }
    It 'prima di decodificare toglie i tag, cosi un testo scritto come entita non viene tolto' {
        $r = ConvertTo-AnteprimaTelegram -Testo 'a &lt;b&gt; c <i>d</i>'
        $r | Should -Be 'a <b> c d'
    }
    It 'taglia a 300 caratteri al massimo' {
        $r = ConvertTo-AnteprimaTelegram -Testo ('parola ' * 200)
        $r.Length | Should -BeLessOrEqual 300
        $r.Length | Should -BeGreaterThan 250
    }
    It 'comprime gli a capo e gli spazi' {
        ConvertTo-AnteprimaTelegram -Testo "uno`n`n   due`t tre" | Should -Be 'uno due tre'
    }
    It 'un testo vuoto o nullo da una stringa vuota' {
        ConvertTo-AnteprimaTelegram -Testo $null | Should -Be ''
        ConvertTo-AnteprimaTelegram -Testo '   ' | Should -Be ''
    }
}

Describe 'Format-MessaggioTelegram' {
    It 'ha titolo, anteprima e link, in testo semplice' {
        $m = Format-MessaggioTelegram -Titolo 'Card 5: Preventivo' -Testo '<p>Serve la <b>firma</b>?</p>' -Url 'https://acme.visualstudio.com/P/_workitems/edit/5'
        $m | Should -Match 'Card 5: Preventivo'
        $m | Should -Match 'Serve la firma\?'
        $m | Should -Match 'https://acme\.visualstudio\.com/P/_workitems/edit/5'
        $m | Should -Not -Match '<'
    }
}

Describe 'Send-TelegramAvviso' {
    It 'non configurato: non chiama niente e non e un errore' {
        $x = New-Dati -Valore $null
        Mock Invoke-TelegramApi -ModuleName Telegram { }
        $r = Send-TelegramAvviso -Titolo 'T' -Testo 'x' -Url 'https://u' -CartellaDati $x.Dati -PercorsoToken $x.FileBot
        $r | Should -BeFalse
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 0 -Exactly
    }

    It 'configurato: una chiamata a sendMessage con chat e testo, senza parse_mode' {
        $x = New-Dati
        Mock Invoke-TelegramApi -ModuleName Telegram { }
        $r = Send-TelegramAvviso -Titolo 'Card 5' -Testo '<p>Domanda `x`?</p>' -Url 'https://u/5' -CartellaDati $x.Dati -PercorsoToken $x.FileBot
        $r | Should -BeTrue
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter {
            $Metodo -eq 'sendMessage' -and $Token -eq $script:ValoreFinto -and
            "$($Corpo.chat_id)" -eq '-100123456' -and $Corpo.text -match 'Card 5' -and $Corpo.text -match 'https://u/5' -and
            $Corpo.text -notmatch 'Domanda `x`' -and -not $Corpo.ContainsKey('parse_mode')
        }
    }

    It 'il valore si legge dal file nel momento della chiamata, senza lo spazio finale' {
        $x = New-Dati -Valore "$script:ValoreFinto`r`n"
        Mock Invoke-TelegramApi -ModuleName Telegram { }
        [void](Send-TelegramAvviso -Titolo 'T' -Testo 'x' -Url 'https://u' -CartellaDati $x.Dati -PercorsoToken $x.FileBot)
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Token -eq $script:ValoreFinto }
    }

    It 'non scrive il valore in nessun flusso di uscita' {
        $x = New-Dati
        Mock Invoke-TelegramApi -ModuleName Telegram { }
        $out = Send-TelegramAvviso -Titolo 'T' -Testo 'x' -Url 'https://u' -CartellaDati $x.Dati -PercorsoToken $x.FileBot *>&1 | Out-String
        $out | Should -Not -Match ([regex]::Escape($script:ValoreFinto))
    }
}

Describe 'Invoke-TelegramApi: il valore segreto non esce negli errori' {
    It 'un errore di Invoke-RestMethod che nomina l indirizzo viene riscritto senza il valore' {
        Mock Invoke-RestMethod -ModuleName Telegram {
            throw [System.Net.Http.HttpRequestException]::new("Response status code does not indicate success: 401 (Unauthorized). Uri: https://api.telegram.org/bot$($script:ValoreFinto)/sendMessage")
        }
        $msg = $null; $rec = $null
        try { Invoke-TelegramApi -Token $script:ValoreFinto -Metodo 'sendMessage' -Corpo @{ chat_id = '1'; text = 'x' } }
        catch { $msg = $_.Exception.Message; $rec = $_ }
        $msg | Should -Not -BeNullOrEmpty
        $msg | Should -Not -Match ([regex]::Escape($script:ValoreFinto))
        $msg | Should -Not -Match 'FINTO-'
        $msg | Should -Match '\*\*\*'
        # nemmeno nel resto del record dell'errore
        ($rec | Out-String) | Should -Not -Match ([regex]::Escape($script:ValoreFinto))
        "$($rec.ScriptStackTrace)$($rec.InvocationInfo.Line)" | Should -Not -Match ([regex]::Escape($script:ValoreFinto))
    }

    It 'anche se l indirizzo e codificato e se il corpo dell errore lo ripete' {
        Mock Invoke-RestMethod -ModuleName Telegram {
            $e = [System.Management.Automation.ErrorRecord]::new(
                [Exception]::new("Not Found: bot$([uri]::EscapeDataString($script:ValoreFinto))/sendMessage"),
                'x', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
            $e.ErrorDetails = [System.Management.Automation.ErrorDetails]::new("{""description"":""bot$($script:ValoreFinto)/sendMessage""}")
            $PSCmdlet.ThrowTerminatingError($e)
        }
        $msg = $null
        try { Invoke-TelegramApi -Token $script:ValoreFinto -Metodo 'sendMessage' -Corpo @{ chat_id = '1'; text = 'x' } } catch { $msg = $_.Exception.Message }
        $msg | Should -Not -BeNullOrEmpty
        $msg | Should -Not -Match 'FINTO-'
        $msg | Should -Not -Match ([regex]::Escape([uri]::EscapeDataString($script:ValoreFinto)))
    }

    It 'l errore arriva fino a Send-TelegramAvviso senza il valore' {
        $x = New-Dati
        Mock Invoke-RestMethod -ModuleName Telegram { throw "boom https://api.telegram.org/bot$($script:ValoreFinto)/sendMessage" }
        $msg = $null
        try { Send-TelegramAvviso -Titolo 'T' -Testo 'x' -Url 'https://u' -CartellaDati $x.Dati -PercorsoToken $x.FileBot } catch { $msg = $_.Exception.Message }
        $msg | Should -Not -BeNullOrEmpty
        $msg | Should -Not -Match 'FINTO-'
    }

    It 'chiama l indirizzo di sendMessage con il corpo in JSON e un timeout' {
        Mock Invoke-RestMethod -ModuleName Telegram { [pscustomobject]@{ ok = $true } }
        Invoke-TelegramApi -Token $script:ValoreFinto -Metodo 'sendMessage' -Corpo @{ chat_id = '9'; text = 'ciao' }
        Should -Invoke Invoke-RestMethod -ModuleName Telegram -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://api.telegram.org/bot$($script:ValoreFinto)/sendMessage" -and $Method -eq 'Post' -and
            $ContentType -match 'json' -and $TimeoutSec -gt 0 -and ([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json).text -eq 'ciao'
        }
    }
}

Describe 'Invoke-TelegramApi: il valore segreto non esce sui flussi verbose e debug' {
    BeforeAll {
        # Un indirizzo locale che rifiuta la connessione: la chiamata e vera, la rete no.
        InModuleScope Telegram { $script:ApiBaseVera = $script:ApiBase; $script:ApiBase = 'http://127.0.0.1:1' }
    }
    AfterAll { InModuleScope Telegram { $script:ApiBase = $script:ApiBaseVera } }

    It 'con VerbosePreference Continue nessun flusso porta il valore' {
        $vecchio = $global:VerbosePreference
        try {
            $global:VerbosePreference = 'Continue'
            $out = & { try { Invoke-TelegramApi -Token $script:ValoreFinto -Metodo 'sendMessage' -Corpo @{ chat_id = '1'; text = 'x' } } catch { "ECCEZIONE: $($_.Exception.Message)" } } *>&1 | Out-String
        }
        finally { $global:VerbosePreference = $vecchio }
        $out | Should -Match 'ECCEZIONE'
        $out | Should -Not -Match 'FINTO-'
        $out | Should -Not -Match ([regex]::Escape($script:ValoreFinto))
    }

    It 'con DebugPreference Continue nessun flusso porta il valore' {
        $vecchio = $global:DebugPreference
        try {
            $global:DebugPreference = 'Continue'
            $out = & { try { Invoke-TelegramApi -Token $script:ValoreFinto -Metodo 'sendMessage' -Corpo @{ chat_id = '1'; text = 'x' } } catch { "ECCEZIONE: $($_.Exception.Message)" } } *>&1 | Out-String
        }
        finally { $global:DebugPreference = $vecchio }
        $out | Should -Match 'ECCEZIONE'
        $out | Should -Not -Match 'FINTO-'
    }

    It 'Send-TelegramAvviso con -Verbose non stampa il valore e l eccezione nemmeno' {
        $x = New-Dati
        $out = & { try { Send-TelegramAvviso -Titolo 'T' -Testo 'x' -Url 'https://u' -CartellaDati $x.Dati -PercorsoToken $x.FileBot -Verbose } catch { "ECCEZIONE: $($_.Exception.Message)" } } *>&1 | Out-String
        $out | Should -Match 'ECCEZIONE'
        $out | Should -Not -Match 'FINTO-'
    }
}

Describe 'Telegram: la cartella dati e quella comune' {
    It 'senza -CartellaDati il file della chat si cerca dove dice ATTREZZI_DATI' {
        $x = New-Dati
        $vecchia = $env:ATTREZZI_DATI
        try {
            $env:ATTREZZI_DATI = $x.Dati
            Test-TelegramConfigurato -PercorsoToken $x.FileBot | Should -BeTrue
            $env:ATTREZZI_DATI = Join-Path $TestDrive 'vuota'
            Test-TelegramConfigurato -PercorsoToken $x.FileBot | Should -BeFalse
        }
        finally { $env:ATTREZZI_DATI = $vecchia }
    }
}


Describe 'Telegram: i testi in HTML' {
    BeforeAll {
        $script:Ora = [datetime]::new(2026, 11, 23, 14, 0, 0, [DateTimeKind]::Local)
        function New-Voce([int]$N, [string]$Testo = "Cosa $N", [string]$Azione = "azione $N") {
            [pscustomobject]@{ Testo = $Testo; Azione = $Azione; Link = "https://u/$N"; Attesa = '' }
        }
        # i soli tag ammessi nel messaggio sono quelli scritti dal supervisore
        function Get-TagUsati([string]$T) { @([regex]::Matches($T, '</?([a-zA-Z]\w*)') | ForEach-Object { $_.Groups[1].Value.ToLower() } | Select-Object -Unique) }
    }

    It 'intestazione: giorno e ora locali, poi una riga vuota' {
        Format-IntestazioneTelegram $script:Ora | Should -Be 'Supervisore · lun 23/11 14:00'
        $t = Format-RiepilogoTelegram -Voci @((New-Voce 1)) -Adesso $script:Ora
        ($t -split "`n")[0..1] | Should -Be @('Supervisore · lun 23/11 14:00', '')
    }

    Context 'riepilogo' {
        It 'titolo in grassetto con il numero, poi una voce per punto: la cosa e a capo la freccia con l azione linkata' {
            $t = Format-RiepilogoTelegram -Voci @((New-Voce 1), (New-Voce 2)) -Adesso $script:Ora
            $r = $t -split "`n"
            $r[2] | Should -Be '<b>2 cose per te</b>'
            $r[4] | Should -Be '1. Cosa 1'
            $r[5] | Should -Be '→ <a href="https://u/1">azione 1</a>'
            $r[7] | Should -Be '2. Cosa 2'
            $t | Should -Not -Match 'Fai:'
            $t | Should -Not -Match '(?m)^[^<]*https://'
        }
        It 'una cosa sola: al singolare' {
            (Format-RiepilogoTelegram -Voci @((New-Voce 1)) -Adesso $script:Ora) | Should -Match '<b>1 cosa per te</b>'
        }
        It 'senza link l azione e testo semplice' {
            $v = New-Voce 1; $v.Link = ''
            (Format-RiepilogoTelegram -Voci @($v) -Adesso $script:Ora) | Should -Match '(?m)^→ azione 1$'
        }
        It 'una voce ricordata dice da quanto aspetta' {
            $v = New-Voce 1; $v.Attesa = 'da 3 giorni'
            (Format-RiepilogoTelegram -Voci @($v) -Adesso $script:Ora) | Should -Match '(?m)^1\. Cosa 1 \(da 3 giorni\)$'
        }
        It 'la voce con una diagnosi rimanda al topic Diagnosi, senza il testo' {
            $v = New-Voce 1; $v | Add-Member Diagnosi 'Causa: il file x manca'
            $t = Format-RiepilogoTelegram -Voci @($v) -Adesso $script:Ora
            $t | Should -Match '(?m)^diagnosi nel topic Diagnosi$'
            $t | Should -Not -Match 'file x manca'
        }
        It 'escape HTML: un titolo con <script> e & non porta tag e il & e scritto come entita' {
            $t = Format-RiepilogoTelegram -Voci @((New-Voce 1 'Card <script>alert(1)</script> Rossi & Bianchi' 'apri <b>la</b> card & guarda')) -Adesso $script:Ora
            $t | Should -Not -Match '<script'
            $t | Should -Match 'Rossi &amp; Bianchi'
            $t | Should -Match 'card &amp; guarda'
            Get-TagUsati $t | Should -Be @('b', 'a')
        }
        It 'un testo scritto come entita non diventa un tag' {
            $t = Format-RiepilogoTelegram -Voci @((New-Voce 1 'a &lt;script&gt; b')) -Adesso $script:Ora
            $t | Should -Not -Match '<script'
            $t | Should -Match '&lt;script&gt;'
        }
        It 'niente codice nel testo' {
            $t = Format-RiepilogoTelegram -Voci @((New-Voce 1 'Errore in `Select-Object x`' 'apri la card')) -Adesso $script:Ora
            $t | Should -Not -Match 'Select-Object'
        }
        It 'sotto il limite di Telegram contato con i tag: tronca e dice quante voci mancano' {
            $voci = @(1..60 | ForEach-Object { New-Voce $_ ('x' * 250) ('y' * 200) })
            $t = Format-RiepilogoTelegram -Voci $voci -Adesso $script:Ora
            $t.Length | Should -BeLessOrEqual 4096
            $t | Should -Match '\.\.\. e altre (\d+) voci'
            $n = [int]([regex]::Match($t, 'e altre (\d+) voci').Groups[1].Value)
            $incluse = ([regex]::Matches($t, '(?m)^\d+\. ')).Count
            ($incluse + $n) | Should -Be 60
        }
        It 'entra tutto: nessuna riga di troncamento' {
            (Format-RiepilogoTelegram -Voci @((New-Voce 1)) -Adesso $script:Ora) | Should -Not -Match 'altre'
        }
    }

    Context 'urgente' {
        It '🔴 con la cosa in grassetto, poi a capo l azione con il link' {
            $v = [pscustomobject]@{ Testo = 'Lo smistatore non gira.'; Azione = 'riavvialo'; Link = 'https://u/x'; Ricordo = $false; Attesa = '' }
            $r = (Format-UrgenteTelegram -Voce $v -Adesso $script:Ora) -split "`n"
            $r[2] | Should -Be '🔴 <b>Lo smistatore non gira</b>'
            $r[3] | Should -Be '<a href="https://u/x">riavvialo</a>'
        }
        It 'senza link usa quello predefinito; ricordata dice che e ancora aperta' {
            $v = [pscustomobject]@{ Testo = 'Cosa'; Azione = 'fai'; Link = ''; Ricordo = $true; Attesa = 'da 4 ore' }
            $t = Format-UrgenteTelegram -Voce $v -Adesso $script:Ora -LinkPredefinito 'https://org'
            $t | Should -Match '🔴 <b>Cosa</b> \(ancora aperto, da 4 ore\)'
            $t | Should -Match '<a href="https://org">fai</a>'
        }
        It 'escape HTML anche qui' {
            $v = [pscustomobject]@{ Testo = 'Run <script>x</script> & co'; Azione = 'fai'; Link = 'https://u/?a=1&b=2'; Ricordo = $false; Attesa = '' }
            $t = Format-UrgenteTelegram -Voce $v -Adesso $script:Ora
            $t | Should -Not -Match '<script'
            $t | Should -Match '&amp; co'
            $t | Should -Match 'href="https://u/\?a=1&amp;b=2"'
        }
    }

    Context 'diagnosi' {
        It '🔎 con il problema in grassetto, poi il testo della diagnosi, tutto escapato' {
            $t = Format-DiagnosiTelegram -Problema 'Card 9 saltata' -Diagnosi 'Causa: <script>x</script> manca il campo & basta' -Adesso $script:Ora
            $r = $t -split "`n"
            $r[2] | Should -Be '🔎 <b>Card 9 saltata</b>'
            $r[3] | Should -Match '^Causa: x manca il campo &amp; basta$'
            $t | Should -Not -Match '<script'
        }
    }

    Context 'aggiornamenti della suite (D53)' {
        It 'aggiornato: da quale a quale versione e le PR entrate, ognuna col suo link, tutto escapato' {
            $pr = @([pscustomobject]@{ Numero = 1202; Titolo = 'Una <b>PR</b> & basta'; Url = 'https://ado/pullrequest/1202' }, [pscustomobject]@{ Numero = 1201; Titolo = 'Altra'; Url = $null })
            $t = Format-AggiornamentoTelegram -Tipo aggiornato -Adesso $script:Ora -Da 'main aaa1111 (20/11/2026)' -A 'main bbb2222 (25/11/2026)' -Pr $pr
            $r = $t -split "`n"
            $r[2] | Should -Match '^🔄 <b>Suite aggiornata</b>: main aaa1111 \(20/11/2026\) → main bbb2222 \(25/11/2026\)$'
            $r[3] | Should -Be '<a href="https://ado/pullrequest/1202">PR 1202</a>: Una PR &amp; basta'
            $r[4] | Should -Be 'PR 1201: Altra'
            $t | Should -Not -Match '<b>PR</b>'
        }
        It 'aggiornato senza PR: solo la riga delle versioni' {
            ((Format-AggiornamentoTelegram -Tipo aggiornato -Adesso $script:Ora -Da 'a' -A 'b') -split "`n").Count | Should -Be 3
        }
        It 'fallito: il commit scartato e l errore, e dice che e tornato indietro' {
            $t = Format-AggiornamentoTelegram -Tipo fallito -Adesso $script:Ora -A 'abc1234' -Errore 'Install-Attrezzi.ps1 e uscito con codice 1: a & b'
            $t | Should -Match 'tornato alla versione di prima'
            $t | Should -Match 'commit scartato: abc1234'
            $t | Should -Match 'codice 1: a &amp; b'
        }
        It 'copiaRotta: dice dove e rimasta la copia e che va sistemata a mano' {
            $t = Format-AggiornamentoTelegram -Tipo copiaRotta -Adesso $script:Ora -A 'abc1234' -Errore 'git ha detto di no & basta'
            $t | Should -Match 'la copia e rimasta a meta'
            $t | Should -Match 'lasciata a abc1234'
            $t | Should -Match 'a mano'
            $t | Should -Match 'di no &amp; basta'
        }
        It 'attesa: dice da quante ore le sessioni tengono ferma la copia' {
            $t = Format-AggiornamentoTelegram -Tipo attesa -Adesso $script:Ora -A 'main bbb2222 (25/11/2026)' -Ore 6
            $t | Should -Match 'da oltre 6 ore'
            $t | Should -Match 'non forzo'
        }
    }

    Context 'rilasci' {
        BeforeAll {
            function New-CardR([int]$Id, [string]$Titolo = "Titolo della card $Id") { [pscustomobject]@{ Id = $Id; Titolo = $Titolo; Url = "https://ado/edit/$Id" } }
            function New-Gruppo([string]$Area, $Card, [int]$Giorni, [bool]$OltreCard = $false, [bool]$OltreGiorni = $false, [string]$Link = 'https://acme.visualstudio.com/P/_build?definitionId=7') {
                [pscustomobject]@{ Area = $Area; Card = @($Card); Giorni = $Giorni; MaxCard = 5; MaxGiorni = 7; OltreCard = $OltreCard; OltreGiorni = $OltreGiorni; Progetto = 'P'; LinkRilascio = $Link }
            }
        }
        It 'il formato di un area oltre soglia: segno, area corta, soglia, card linkate e link al rilascio' {
            $g = New-Gruppo 'DevOps.Agents\AI\Stime' @(6, 9 | ForEach-Object { New-CardR $_ }) 6 $true
            $r = (Format-RilasciTelegram -Gruppi @($g) -Adesso $script:Ora) -split "`n"
            $r[2] | Should -Be '<b>Da rilasciare in produzione: 2 card</b>'
            $r[3] | Should -Be ''
            $r[4] | Should -Be '⚠️ <b>AI · Stime</b>: 2 card, la più vecchia aspetta da 6 giorni (soglia: 5 card)'
            $r[5] | Should -Be '   <a href="https://ado/edit/6">#6</a> Titolo della card 6'
            $r[6] | Should -Be '   <a href="https://ado/edit/9">#9</a> Titolo della card 9'
            $r[7] | Should -Be '   → <a href="https://acme.visualstudio.com/P/_build?definitionId=7">lancia il rilascio</a>'
        }
        It 'la soglia dice card, giorni o tutte e due; un area sotto soglia non ha segno ne soglia' {
            $t = Format-RilasciTelegram -Adesso $script:Ora -Gruppi @(
                (New-Gruppo 'A\B\C' @(New-CardR 1) 8 $false $true), (New-Gruppo 'A\B\D' @(New-CardR 2) 8 $true $true), (New-Gruppo 'A\B\E' @(New-CardR 3) 1))
            $t | Should -Match '<b>B · C</b>: 1 card, la più vecchia aspetta da 8 giorni \(soglia: 7 giorni\)'
            $t | Should -Match '<b>B · D</b>: 1 card, la più vecchia aspetta da 8 giorni \(soglia: 5 card e 7 giorni\)'
            $t | Should -Match '(?m)^<b>B · E</b>: 1 card, la più vecchia aspetta da 1 giorno$'
        }
        It 'l ordine e quello dei gruppi: le aree oltre soglia in cima' {
            $t = Format-RilasciTelegram -Adesso $script:Ora -Gruppi @((New-Gruppo 'A\X\Sopra' @(New-CardR 1) 9 $false $true), (New-Gruppo 'A\X\Sotto' @(New-CardR 2) 0))
            $t.IndexOf('Sopra') | Should -BeLessThan $t.IndexOf('Sotto')
            $t | Should -Match 'aspetta da meno di un giorno'
        }
        It 'un area con un solo pezzo nel percorso si legge com e' {
            (Format-RilasciTelegram -Adesso $script:Ora -Gruppi @((New-Gruppo 'Sola' @(New-CardR 1) 0))) | Should -Match '<b>Sola</b>'
        }
        It 'un titolo lungo si tronca a 60 caratteri con i puntini' {
            $t = Format-RilasciTelegram -Adesso $script:Ora -Gruppi @((New-Gruppo 'A\B' @(New-CardR 1 ('x' * 100)) 0))
            $riga = (($t -split "`n") | Where-Object { $_ -match '#1</a>' })
            $titolo = $riga -replace '^.*</a> ', ''
            $titolo.Length | Should -Be 60
            $titolo | Should -Be (('x' * 59) + '…')
        }
        It 'senza la pipeline orchestrator la riga dice che manca, con il progetto' {
            $t = Format-RilasciTelegram -Adesso $script:Ora -Gruppi @((New-Gruppo 'A\B' @(New-CardR 1) 0 $false $false ''))
            $t | Should -Match '(?m)^   rilascio: nessuna pipeline orchestrator nel progetto P$'
            $t | Should -Not -Match 'lancia il rilascio'
        }
        It 'escape HTML: un titolo con <script> e & non porta tag' {
            $t = Format-RilasciTelegram -Adesso $script:Ora -Gruppi @((New-Gruppo 'A\B' @(New-CardR 1 'Fix <script>alert(1)</script> Rossi & Figli') 0))
            $t | Should -Not -Match '<script'
            $t | Should -Match 'Rossi &amp; Figli'
            Get-TagUsati $t | Should -Be @('b', 'a')
        }
        It 'sotto il limite di Telegram: le aree che non entrano non si mandano e l ultima riga dice quante mancano' {
            $gruppi = @(1..40 | ForEach-Object { New-Gruppo "A\B\Area$_" @(1..8 | ForEach-Object { New-CardR ($_ * 100) ('t' * 60) }) 0 })
            $t = Format-RilasciTelegram -Gruppi $gruppi -Adesso $script:Ora
            $t.Length | Should -BeLessOrEqual 4096
            $n = [int]([regex]::Match($t, 'e altre (\d+) aree').Groups[1].Value)
            $n | Should -BeGreaterThan 0
            ([regex]::Matches($t, '(?m)^<b>B · Area')).Count + $n | Should -Be 40
        }
    }
}

Describe 'Telegram: i topic' {
    BeforeEach {
        $global:TgMondo = @{ Crea = $true; Id = 77; Mancanti = @() }
        Mock Invoke-TelegramApi -ModuleName Telegram {
            if ($Metodo -eq 'createForumTopic') {
                if (-not $global:TgMondo.Crea) { throw 'Invio a Telegram fallito (metodo createForumTopic): Bad Request: not enough rights to create a topic' }
                return [pscustomobject]@{ ok = $true; result = [pscustomobject]@{ message_thread_id = $global:TgMondo.Id; name = $Corpo.name } }
            }
            if ($Corpo.ContainsKey('message_thread_id') -and $Corpo.message_thread_id -in $global:TgMondo.Mancanti) { throw 'Invio a Telegram fallito (metodo sendMessage): Bad Request: message thread not found' }
            [pscustomobject]@{ ok = $true }
        }
        $script:Adesso = [datetime]::new(2026, 11, 23, 12, 0, 0, [DateTimeKind]::Utc)
    }
    BeforeAll {
        function Get-FileTopic($X) { Get-Content -LiteralPath (Join-Path $X.Dati 'telegram-topic.json') -Raw | ConvertFrom-Json }
        function Send-Prova($X, [string]$Topic, [datetime]$Quando = $script:Adesso, [scriptblock]$Log) {
            Send-TelegramMessaggio -Testo '<b>x</b>' -Topic $Topic -CartellaDati $X.Dati -PercorsoToken $X.FileBot -Adesso $Quando -Log $Log
        }
    }

    It 'la prima volta crea il topic con il nome visibile e salva l id; poi riusa quello salvato' {
        $x = New-Dati
        $r = [System.Collections.Generic.List[string]]::new(); $log = { param($m) $r.Add($m) }.GetNewClosure()
        (Send-Prova $x 'rilasci' -Log $log) | Should -BeTrue
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'createForumTopic' -and $Corpo.name -eq 'Rilasci' -and "$($Corpo.chat_id)" -eq '-100123456' -and $Token -eq $script:ValoreFinto }
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'sendMessage' -and $Corpo.message_thread_id -eq 77 -and $Corpo.parse_mode -eq 'HTML' -and $Corpo.link_preview_options.is_disabled -eq $true -and $Corpo.text -eq '<b>x</b>' }
        (Get-FileTopic $x).topic.rilasci | Should -Be 77
        [void](Send-Prova $x 'rilasci' -Log $log)
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'createForumTopic' }
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 2 -Exactly -ParameterFilter { $Metodo -eq 'sendMessage' -and $Corpo.message_thread_id -eq 77 }
    }

    It 'i quattro nomi logici hanno i nomi visibili Urgenti, Riepilogo, Rilasci, Diagnosi' {
        $x = New-Dati
        foreach ($n in 'urgenti', 'riepilogo', 'rilasci', 'diagnosi') { [void](Get-TelegramTopicId -Nome $n -CartellaDati $x.Dati -PercorsoToken $x.FileBot -Adesso $script:Adesso) }
        foreach ($v in 'Urgenti', 'Riepilogo', 'Rilasci', 'Diagnosi') {
            Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'createForumTopic' -and $Corpo.name -eq $v }
        }
    }

    It 'il topic aggiornamenti (D53) si crea da solo con il nome Aggiornamenti e il messaggio parte li' {
        $x = New-Dati
        (Send-Prova $x 'aggiornamenti') | Should -BeTrue
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'createForumTopic' -and $Corpo.name -eq 'Aggiornamenti' }
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'sendMessage' -and $Corpo.message_thread_id -eq 77 }
        (Get-FileTopic $x).topic.aggiornamenti | Should -Be 77
    }

    It 'senza topic il messaggio va nel generale: niente createForumTopic, niente message_thread_id' {
        $x = New-Dati
        [void](Send-TelegramMessaggio -Testo 'x' -CartellaDati $x.Dati -PercorsoToken $x.FileBot)
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 0 -Exactly -ParameterFilter { $Metodo -eq 'createForumTopic' }
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'sendMessage' -and -not $Corpo.ContainsKey('message_thread_id') -and $Corpo.parse_mode -eq 'HTML' }
    }

    It 'non configurato: non chiama niente' {
        $x = New-Dati -Valore $null
        (Send-Prova $x 'urgenti') | Should -BeFalse
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 0 -Exactly
    }

    It 'creazione fallita: il messaggio parte lo stesso nel generale, una riga nel log, la voce del permesso, nuovo tentativo solo dopo un ora' {
        $global:TgMondo.Crea = $false
        $x = New-Dati
        $r = [System.Collections.Generic.List[string]]::new(); $log = { param($m) $r.Add($m) }.GetNewClosure()
        (Send-Prova $x 'urgenti' -Log $log) | Should -BeTrue
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'sendMessage' -and -not $Corpo.ContainsKey('message_thread_id') }
        $r.Count | Should -Be 1
        $r[0] | Should -Match 'Urgenti'
        $r[0] | Should -Not -Match 'FINTO-'
        $p = Get-TelegramProblemaTopic -CartellaDati $x.Dati
        $p.Errore | Should -Match 'not enough rights'
        $p.Avvisato | Should -BeFalse
        # entro l ora: nessuna nuova chiamata a createForumTopic, e nessun altra riga di log
        (Send-Prova $x 'riepilogo' $script:Adesso.AddMinutes(59) -Log $log) | Should -BeTrue
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'createForumTopic' }
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 2 -Exactly -ParameterFilter { $Metodo -eq 'sendMessage' -and -not $Corpo.ContainsKey('message_thread_id') }
        $r.Count | Should -Be 1
        # dopo un ora si riprova (e fallisce di nuovo: l ora riparte da qui)
        [void](Send-Prova $x 'urgenti' $script:Adesso.AddMinutes(61) -Log $log)
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 2 -Exactly -ParameterFilter { $Metodo -eq 'createForumTopic' }
        [void](Send-Prova $x 'urgenti' $script:Adesso.AddMinutes(100) -Log $log)
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 2 -Exactly -ParameterFilter { $Metodo -eq 'createForumTopic' }
        # la creazione riesce: il problema sparisce e il topic si usa
        $global:TgMondo.Crea = $true
        [void](Send-Prova $x 'urgenti' $script:Adesso.AddMinutes(130) -Log $log)
        Get-TelegramProblemaTopic -CartellaDati $x.Dati | Should -BeNullOrEmpty
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'sendMessage' -and $Corpo.message_thread_id -eq 77 }
    }

    It 'la voce del permesso si dice una volta sola finche la creazione non riesce' {
        $global:TgMondo.Crea = $false
        $x = New-Dati
        [void](Send-Prova $x 'urgenti')
        Set-TelegramPermessoAvvisato -CartellaDati $x.Dati
        [void](Send-Prova $x 'urgenti' $script:Adesso.AddHours(2))
        (Get-TelegramProblemaTopic -CartellaDati $x.Dati).Avvisato | Should -BeTrue
    }

    It 'topic cancellato a mano: l id si dimentica, si ricrea una volta e il messaggio parte nel nuovo' {
        $x = New-Dati
        Set-Content -LiteralPath (Join-Path $x.Dati 'telegram-topic.json') -Value '{"topic":{"diagnosi":5},"fallita":null,"permessoAvvisato":false}'
        $global:TgMondo.Mancanti = @(5); $global:TgMondo.Id = 88
        $r = [System.Collections.Generic.List[string]]::new(); $log = { param($m) $r.Add($m) }.GetNewClosure()
        (Send-Prova $x 'diagnosi' -Log $log) | Should -BeTrue
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'createForumTopic' -and $Corpo.name -eq 'Diagnosi' }
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'sendMessage' -and $Corpo.message_thread_id -eq 5 }
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'sendMessage' -and $Corpo.message_thread_id -eq 88 }
        (Get-FileTopic $x).topic.diagnosi | Should -Be 88
        ($r -join "`n") | Should -Match 'non esiste piu'
    }

    It 'topic cancellato e ricreazione fallita: il messaggio parte nel generale' {
        $x = New-Dati
        Set-Content -LiteralPath (Join-Path $x.Dati 'telegram-topic.json') -Value '{"topic":{"diagnosi":5},"fallita":null,"permessoAvvisato":false}'
        $global:TgMondo.Mancanti = @(5); $global:TgMondo.Crea = $false
        (Send-Prova $x 'diagnosi') | Should -BeTrue
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'sendMessage' -and -not $Corpo.ContainsKey('message_thread_id') }
        (Get-FileTopic $x).topic.PSObject.Properties.Name | Should -Not -Contain 'diagnosi'
    }

    It 'un errore di invio che non riguarda il topic non lo fa ricreare: si lancia, senza il valore del bot' {
        $x = New-Dati
        Set-Content -LiteralPath (Join-Path $x.Dati 'telegram-topic.json') -Value '{"topic":{"urgenti":5},"fallita":null,"permessoAvvisato":false}'
        Mock Invoke-TelegramApi -ModuleName Telegram { throw "Invio a Telegram fallito (metodo sendMessage): HTTP 502 https://api.telegram.org/bot$($Token)/sendMessage" }
        $msg = $null
        try { Send-Prova $x 'urgenti' } catch { $msg = $_.Exception.Message }
        $msg | Should -Match 'HTTP 502'
        Should -Invoke Invoke-TelegramApi -ModuleName Telegram -Times 0 -Exactly -ParameterFilter { $Metodo -eq 'createForumTopic' }
    }
}

Describe 'Telegram: topic, un errore di creazione' {
    It 'non porta il valore del bot ne nel log ne nel file ne nell uscita' {
        $x = New-Dati
        Mock Invoke-RestMethod -ModuleName Telegram { throw "boom https://api.telegram.org/bot$($script:ValoreFinto)/createForumTopic" }
        $r = [System.Collections.Generic.List[string]]::new(); $log = { param($m) $r.Add($m) }.GetNewClosure()
        $out = Get-TelegramTopicId -Nome 'urgenti' -CartellaDati $x.Dati -PercorsoToken $x.FileBot -Adesso ([datetime]::UtcNow) -Log $log *>&1 | Out-String
        $r.Count | Should -Be 1
        ($r -join "`n") + $out + (Get-Content (Join-Path $x.Dati 'telegram-topic.json') -Raw) | Should -Not -Match 'FINTO-'
    }
}