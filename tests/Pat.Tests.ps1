BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Pat.psm1') -Force
    $script:Config = Join-Path $PSScriptRoot '../config/pat.json'
    $script:Install = Join-Path $PSScriptRoot '../setup/Install-Attrezzi.ps1'
}

Describe 'Install-Pat' {
    BeforeEach {
        $script:Claude = Join-Path $TestDrive ('claude-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Claude | Out-Null
        $global:PatCreati = 0
        $global:PatFallisceAl = 0       # numero della creazione che deve fallire (0 = nessuna)
        $global:LoginAttivo = $true
        $global:ClaudeT = $script:Claude
        Mock Test-AzPresente -ModuleName Pat { $true }
        # az finto: account show dipende da LoginAttivo; login lo attiva; il resto va a buon fine
        Mock Invoke-Az -ModuleName Pat {
            switch ($Argomenti[0]) {
                'account' {
                    if ($Argomenti[1] -eq 'show') { return [pscustomobject]@{ Codice = $(if ($global:LoginAttivo) { 0 } else { 1 }); Uscita = '' } }
                    return [pscustomobject]@{ Codice = 0; Uscita = 'VALORE-ENTRA-FINTO' }
                }
                'login' { $global:LoginAttivo = $true; return [pscustomobject]@{ Codice = 0; Uscita = '' } }
                default { return [pscustomobject]@{ Codice = 0; Uscita = '' } }
            }
        }
        Mock Invoke-ApiPat -ModuleName Pat {
            if ($Metodo -eq 'POST') {
                $global:PatCreati++
                if ($global:PatFallisceAl -eq $global:PatCreati) { throw 'Chiamata all''API dei PAT fallita (POST x): 403' }
                $finto = "VALORE-PAT-FINTO-$($global:PatCreati)"
                $dati = [pscustomobject]@{ authorizationId = "id-$($global:PatCreati)"; validTo = [datetime]::new(2027, 2, 17, 10, 0, 0, [DateTimeKind]::Utc); token = $finto }
                return [pscustomobject]@{ patToken = $dati }
            }
            $null
        }
    }
    AfterAll { Remove-Variable PatCreati, PatFallisceAl, LoginAttivo, ClaudeT -Scope Global -ErrorAction SilentlyContinue }

    It 'con il login gia attivo crea i due PAT con scope, nome e durata della config, e non fa ne login ne logout' {
        Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null
        $cfg = Get-Content $script:Config -Raw | ConvertFrom-Json
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 2 -Exactly -ParameterFilter {
            $Metodo -eq 'POST' -and $Url -eq 'https://vssps.dev.azure.com/acme/_apis/tokens/pats?api-version=7.1-preview.1' -and
            $Token -eq 'VALORE-ENTRA-FINTO' -and $Corpo.allOrgs -eq $false
        }
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 1 -Exactly -ParameterFilter {
            $Corpo.displayName -eq $cfg.smistatore.nome -and $Corpo.scope -eq ($cfg.smistatore.scope -join ' ')
        }
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 1 -Exactly -ParameterFilter {
            $Corpo.displayName -eq $cfg.solaLettura.nome -and $Corpo.scope -eq ($cfg.solaLettura.scope -join ' ')
        }
        Should -Invoke Invoke-Az -ModuleName Pat -Times 0 -Exactly -ParameterFilter { $Argomenti[0] -in 'login', 'logout' }
        # la scadenza e quella chiesta: oggi + durataGiorni
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 2 -Exactly -ParameterFilter {
            $v = ([datetime]$Corpo.validTo).ToUniversalTime()
            $v -gt [datetime]::UtcNow.AddDays($cfg.durataGiorni - 1) -and $v -lt [datetime]::UtcNow.AddDays($cfg.durataGiorni + 1)
        }
    }

    It 'scrive i due file cifrati con DPAPI (leggibili da Read-FilePat, non in chiaro) e pat-info.json senza segreti' {
        Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null
        (Get-Content (Join-Path $script:Claude 'pat-smistatore.txt') -Raw) | Should -Not -Match 'VALORE-PAT-FINTO'
        Read-FilePat (Join-Path $script:Claude 'pat-smistatore.txt') | Should -Be 'VALORE-PAT-FINTO-1'
        Read-FilePat (Join-Path $script:Claude 'pat-smistatore-lettura.txt') | Should -Be 'VALORE-PAT-FINTO-2'
        $raw = Get-Content (Join-Path $script:Claude 'pat-info.json') -Raw
        $raw | Should -Not -Match 'FINTO'
        $info = $raw | ConvertFrom-Json
        $info.smistatore.authorizationId | Should -Be 'id-1'
        # ConvertFrom-Json riconosce le date e le riformatta: la stringa vera e quella nel testo
        ([regex]::Matches($raw, '"validTo":\s*"2027-02-17T10:00:00\.0000000Z"')).Count | Should -Be 2
        $info.solaLettura.authorizationId | Should -Be 'id-2'
    }

    It 'senza login: lo fa e alla fine fa il logout' {
        $global:LoginAttivo = $false
        Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null
        Should -Invoke Invoke-Az -ModuleName Pat -Times 1 -Exactly -ParameterFilter { $Argomenti[0] -eq 'login' -and '--allow-no-subscriptions' -in $Argomenti }
        Should -Invoke Invoke-Az -ModuleName Pat -Times 1 -Exactly -ParameterFilter { $Argomenti[0] -eq 'logout' }
    }

    It 'il logout si fa anche se la creazione del secondo PAT fallisce: nessun file scritto, il primo PAT revocato' {
        $global:LoginAttivo = $false
        $global:PatFallisceAl = 2
        { Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null } | Should -Throw
        Should -Invoke Invoke-Az -ModuleName Pat -Times 1 -Exactly -ParameterFilter { $Argomenti[0] -eq 'logout' }
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'DELETE' -and $Url -match 'authorizationId=id-1' }
        @(Get-ChildItem $script:Claude).Count | Should -Be 0
    }

    It 'se az login non riesce: errore, nessun PAT, e il logout comunque' {
        Mock Invoke-Az -ModuleName Pat {
            if ($Argomenti[0] -eq 'account') { return [pscustomobject]@{ Codice = 1; Uscita = '' } }
            [pscustomobject]@{ Codice = $(if ($Argomenti[0] -eq 'login') { 1 } else { 0 }); Uscita = '' }
        }
        { Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null } | Should -Throw '*az login non riuscito*'
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 0 -Exactly
        Should -Invoke Invoke-Az -ModuleName Pat -Times 1 -Exactly -ParameterFilter { $Argomenti[0] -eq 'logout' }
    }

    It 'az assente: messaggio chiaro e stop, niente chiamate' {
        Mock Test-AzPresente -ModuleName Pat { $false }
        { Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config } | Should -Throw '*Azure CLI*-Pat*'
        Should -Invoke Invoke-Az -ModuleName Pat -Times 0 -Exactly
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 0 -Exactly
    }

    It 'senza il token di az: errore e nessun PAT' {
        Mock Invoke-Az -ModuleName Pat {
            if ($Argomenti[1] -eq 'get-access-token') { return [pscustomobject]@{ Codice = 1; Uscita = '' } }
            [pscustomobject]@{ Codice = 0; Uscita = '' }
        }
        { Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null } | Should -Throw '*nessun PAT creato*'
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 0 -Exactly
    }

    It 'al giro dopo revoca i PAT vecchi di pat-info.json, dopo aver scritto i nuovi' {
        @{ smistatore = @{ authorizationId = 'vecchio-1'; validTo = '2026-12-01T00:00:00Z' }; solaLettura = @{ authorizationId = 'vecchio-2'; validTo = '2026-12-01T00:00:00Z' } } |
            ConvertTo-Json | Set-Content (Join-Path $script:Claude 'pat-info.json')
        $global:NuovoEsisteAllaRevoca = @()
        Mock Invoke-ApiPat -ModuleName Pat {
            if ($Metodo -eq 'DELETE') {
                $global:NuovoEsisteAllaRevoca += [bool]((Test-Path (Join-Path $global:ClaudeT 'pat-smistatore.txt')) -and (Test-Path (Join-Path $global:ClaudeT 'pat-smistatore-lettura.txt')) -and
                    ((Get-Content (Join-Path $global:ClaudeT 'pat-info.json') -Raw | ConvertFrom-Json).smistatore.authorizationId -eq 'id-1'))
                return $null
            }
            $global:PatCreati++
            [pscustomobject]@{ patToken = [pscustomobject]@{ authorizationId = "id-$($global:PatCreati)"; validTo = '2027-02-17T10:00:00Z'; token = "VALORE-PAT-FINTO-$($global:PatCreati)" } }
        }
        Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null
        $global:NuovoEsisteAllaRevoca.Count | Should -Be 2
        $global:NuovoEsisteAllaRevoca | Should -Not -Contain $false
        Remove-Variable NuovoEsisteAllaRevoca -Scope Global
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'DELETE' -and $Url -match 'authorizationId=vecchio-1' -and $Url -match 'vssps\.dev\.azure\.com/acme/_apis/tokens/pats' }
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'DELETE' -and $Url -match 'authorizationId=vecchio-2' }
        (Get-Content (Join-Path $script:Claude 'pat-info.json') -Raw | ConvertFrom-Json).smistatore.authorizationId | Should -Be 'id-1'
    }

    It 'se la revoca dei vecchi fallisce: avviso, ma i nuovi restano e l installazione non fallisce' {
        @{ smistatore = @{ authorizationId = 'vecchio-1'; validTo = '2026-12-01T00:00:00Z' } } | ConvertTo-Json | Set-Content (Join-Path $script:Claude 'pat-info.json')
        Mock Invoke-ApiPat -ModuleName Pat {
            if ($Metodo -eq 'DELETE') { throw 'Chiamata all''API dei PAT fallita (DELETE x): 404' }
            $finto = 'VALORE-PAT-FINTO-N'
            $dati = [pscustomobject]@{ authorizationId = 'nuovo'; validTo = '2027-02-17T10:00:00Z'; token = $finto }
            [pscustomobject]@{ patToken = $dati }
        }
        { Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config -WarningAction SilentlyContinue *>&1 | Out-Null } | Should -Not -Throw
        (Get-Content (Join-Path $script:Claude 'pat-info.json') -Raw | ConvertFrom-Json).smistatore.authorizationId | Should -Be 'nuovo'
    }

    It 'non tocca mai pat.txt ne pat-read-only.txt, nemmeno se ci sono' {
        Set-Content (Join-Path $script:Claude 'pat.txt') 'PAT-IN-CHIARO-DELL-UTENTE' -NoNewline
        Set-Content (Join-Path $script:Claude 'pat-read-only.txt') 'LETTURA-DELL-UTENTE' -NoNewline
        Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null
        Get-Content (Join-Path $script:Claude 'pat.txt') -Raw | Should -Be 'PAT-IN-CHIARO-DELL-UTENTE'
        Get-Content (Join-Path $script:Claude 'pat-read-only.txt') -Raw | Should -Be 'LETTURA-DELL-UTENTE'
        Test-Path (Join-Path $script:Claude 'pat-smistatore.txt') | Should -BeTrue
        Test-Path (Join-Path $script:Claude 'pat-smistatore-lettura.txt') | Should -BeTrue
    }

    It 'la scadenza e in ISO UTC anche quando l API da una data con fuso locale' {
        Mock Invoke-ApiPat -ModuleName Pat {
            $global:PatCreati++
            $locale = [datetime]::new(2027, 2, 17, 12, 0, 0, [DateTimeKind]::Local)
            [pscustomobject]@{ patToken = [pscustomobject]@{ authorizationId = "id-$($global:PatCreati)"; validTo = $locale; token = "VALORE-PAT-FINTO-$($global:PatCreati)" } }
        }
        $out = Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-String
        $atteso = [datetime]::new(2027, 2, 17, 12, 0, 0, [DateTimeKind]::Local).ToUniversalTime().ToString('o')
        (Get-Content (Join-Path $script:Claude 'pat-info.json') -Raw) | Should -Match ([regex]::Escape($atteso))
        $out | Should -Match ([regex]::Escape($atteso))
    }

    It 'se la scrittura del secondo file fallisce: i PAT nuovi si revocano e i file di prima restano com erano' {
        Set-Content (Join-Path $script:Claude 'pat-smistatore.txt') 'ORIGINALE' -NoNewline
        $global:ScrittiFiniti = 0
        Mock Write-FilePat -ModuleName Pat { $global:ScrittiFiniti++; if ($global:ScrittiFiniti -eq 2) { throw 'disco pieno' } }
        { Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null } | Should -Throw '*scrittura dei file fallita*'
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'DELETE' -and $Url -match 'authorizationId=id-1' }
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'DELETE' -and $Url -match 'authorizationId=id-2' }
        Get-Content (Join-Path $script:Claude 'pat-smistatore.txt') -Raw | Should -Be 'ORIGINALE'
        @(Get-ChildItem $script:Claude).Name | Should -Be @('pat-smistatore.txt')
        Remove-Variable ScrittiFiniti -Scope Global
    }

    It 'se la scrittura di pat-info.json fallisce: PAT nuovi revocati, file di prima intatti, nessun .nuovo' {
        Set-Content (Join-Path $script:Claude 'pat-smistatore.txt') 'ORIGINALE' -NoNewline
        Set-Content (Join-Path $script:Claude 'pat-info.json') '{"smistatore":{"authorizationId":"vecchio-1"}}' -NoNewline
        Mock Write-InfoPat -ModuleName Pat { throw 'accesso negato' }
        { Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null } | Should -Throw '*scrittura dei file fallita*'
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 2 -Exactly -ParameterFilter { $Metodo -eq 'DELETE' -and $Url -match 'authorizationId=id-[12]' }
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 0 -Exactly -ParameterFilter { $Metodo -eq 'DELETE' -and $Url -match 'vecchio-1' }
        Get-Content (Join-Path $script:Claude 'pat-smistatore.txt') -Raw | Should -Be 'ORIGINALE'
        Get-Content (Join-Path $script:Claude 'pat-info.json') -Raw | Should -Match 'vecchio-1'
        @(Get-ChildItem $script:Claude).Name | Sort-Object | Should -Be @('pat-info.json', 'pat-smistatore.txt')
    }

    It 'un PAT vecchio gia sparito (404) conta come revocato e non resta in daRevocare' {
        @{ smistatore = @{ authorizationId = 'vecchio-1'; validTo = '2026-12-01T00:00:00Z' }; solaLettura = @{ authorizationId = 'vecchio-2'; validTo = '2026-12-01T00:00:00Z' } } |
            ConvertTo-Json | Set-Content (Join-Path $script:Claude 'pat-info.json')
        Mock Invoke-ApiPat -ModuleName Pat {
            if ($Metodo -eq 'DELETE') {
                if ($Url -match 'vecchio-2') { $e = [Exception]::new('Chiamata all''API dei PAT fallita (DELETE x): 404'); $e.Data['Stato'] = 404; throw $e }
                return $null
            }
            $global:PatCreati++
            [pscustomobject]@{ patToken = [pscustomobject]@{ authorizationId = "id-$($global:PatCreati)"; validTo = '2027-02-17T10:00:00Z'; token = "VALORE-PAT-FINTO-$($global:PatCreati)" } }
        }
        Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null
        $info = Get-Content (Join-Path $script:Claude 'pat-info.json') -Raw | ConvertFrom-Json
        $info.PSObject.Properties['daRevocare'] | Should -BeNullOrEmpty
    }

    It 'revoca fallita: l id resta in pat-info.json in daRevocare e il -Pat dopo lo riprova' {
        @{ smistatore = @{ authorizationId = 'vecchio-1'; validTo = '2026-12-01T00:00:00Z' }; solaLettura = @{ authorizationId = 'vecchio-2'; validTo = '2026-12-01T00:00:00Z' } } |
            ConvertTo-Json | Set-Content (Join-Path $script:Claude 'pat-info.json')
        Mock Invoke-ApiPat -ModuleName Pat {
            if ($Metodo -eq 'DELETE') { if ($Url -match 'vecchio-2') { throw 'Chiamata all''API dei PAT fallita (DELETE x): 500' }; return $null }
            $global:PatCreati++
            [pscustomobject]@{ patToken = [pscustomobject]@{ authorizationId = "id-$($global:PatCreati)"; validTo = '2027-02-17T10:00:00Z'; token = "VALORE-PAT-FINTO-$($global:PatCreati)" } }
        }
        Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config -WarningAction SilentlyContinue *>&1 | Out-Null
        $info = Get-Content (Join-Path $script:Claude 'pat-info.json') -Raw | ConvertFrom-Json
        @($info.daRevocare) | Should -Be @('vecchio-2')
        $info.smistatore.authorizationId | Should -Be 'id-1'

        # il giro dopo: riprova vecchio-2 (e revoca i due di id-1/id-2), e la lista si svuota
        Mock Invoke-ApiPat -ModuleName Pat {
            if ($Metodo -eq 'DELETE') { return $null }
            $global:PatCreati++
            [pscustomobject]@{ patToken = [pscustomobject]@{ authorizationId = "id-$($global:PatCreati)"; validTo = '2027-02-17T10:00:00Z'; token = "VALORE-PAT-FINTO-$($global:PatCreati)" } }
        }
        Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-Null
        # i conteggi sono di tutto il test: vecchio-2 due volte (fallita, poi riprovata), gli altri una
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 2 -Exactly -ParameterFilter { $Metodo -eq 'DELETE' -and $Url -match 'authorizationId=vecchio-2' }
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 1 -Exactly -ParameterFilter { $Metodo -eq 'DELETE' -and $Url -match 'authorizationId=vecchio-1' }
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 2 -Exactly -ParameterFilter { $Metodo -eq 'DELETE' -and $Url -match 'authorizationId=id-[12]&' }
        $info2 = Get-Content (Join-Path $script:Claude 'pat-info.json') -Raw | ConvertFrom-Json
        $info2.PSObject.Properties['daRevocare'] | Should -BeNullOrEmpty
        $info2.smistatore.authorizationId | Should -Be 'id-3'
    }

    It 'config invalida: errore chiaro e nessun login, nessuna chiamata' {
        foreach ($guasto in @(
                @{ durataGiorni = 0 },
                @{ senzaDurata = $true },
                @{ nome = 'smistatore' },
                @{ scope = 'solaLettura' })) {
            $cfg = Get-Content $script:Config -Raw | ConvertFrom-Json
            if ($guasto.ContainsKey('durataGiorni')) { $cfg.durataGiorni = 0 }
            elseif ($guasto.ContainsKey('senzaDurata')) { $cfg.PSObject.Properties.Remove('durataGiorni') }
            elseif ($guasto.ContainsKey('nome')) { $cfg.smistatore.nome = '' }
            else { $cfg.solaLettura.scope = @() }
            $p = Join-Path $TestDrive ('pat-guasto-' + [guid]::NewGuid().ToString('N') + '.json')
            $cfg | ConvertTo-Json -Depth 5 | Set-Content $p
            $global:LoginAttivo = $false
            { Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $p *>&1 | Out-Null } | Should -Throw '*Nessun login fatto*'
        }
        Should -Invoke Invoke-Az -ModuleName Pat -Times 0 -Exactly
        Should -Invoke Invoke-ApiPat -ModuleName Pat -Times 0 -Exactly
        { Install-Pat -ClaudeDir $script:Claude -PercorsoConfig (Join-Path $TestDrive 'non-c-e.json') } | Should -Throw '*illeggibile*'
        Should -Invoke Invoke-Az -ModuleName Pat -Times 0 -Exactly
    }

    It 'se az logout non riesce: avviso che il login e ancora attivo, non "login tolto"' {
        $global:LoginAttivo = $false
        Mock Invoke-Az -ModuleName Pat {
            switch ($Argomenti[0]) {
                'account' {
                    if ($Argomenti[1] -eq 'show') { return [pscustomobject]@{ Codice = 1; Uscita = '' } }
                    return [pscustomobject]@{ Codice = 0; Uscita = 'VALORE-ENTRA-FINTO' }
                }
                'logout' { return [pscustomobject]@{ Codice = 1; Uscita = '' } }
                default { return [pscustomobject]@{ Codice = 0; Uscita = '' } }
            }
        }
        $out = Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-String
        $out | Should -Match 'ancora attivo'
        $out | Should -Match 'az logout a mano'
        $out | Should -Not -Match 'login az tolto'
    }

    It 'ne il token di az ne i PAT compaiono nell output, negli avvisi o negli errori' {
        $out = Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-String
        $out | Should -Not -Match 'VALORE-ENTRA-FINTO|VALORE-PAT-FINTO'
        $global:PatFallisceAl = 4   # il secondo giro (creazioni 3 e 4) fallisce alla seconda
        $err = try { Install-Pat -ClaudeDir $script:Claude -PercorsoConfig $script:Config *>&1 | Out-String; '' } catch { $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -Not -Match 'VALORE-ENTRA-FINTO|VALORE-PAT-FINTO'
    }
}

Describe 'Invoke-ApiPat' {
    It 'l errore non contiene il token' {
        Mock Invoke-RestMethod -ModuleName Pat { throw 'Unauthorized: Bearer VALORE-ENTRA-FINTO' }
        $msg = try { Invoke-ApiPat 'POST' 'https://vssps.dev.azure.com/o/_apis/tokens/pats' 'VALORE-ENTRA-FINTO' @{ a = 1 }; '' } catch { $_.Exception.Message }
        $msg | Should -Not -BeNullOrEmpty
        $msg | Should -Not -Match 'VALORE-ENTRA-FINTO'
    }
}

Describe 'Get-NomeOrganizzazione' {
    It 'ricava il nome dall URL dell organizzazione che Ado.psm1 conosce' {
        Get-NomeOrganizzazione | Should -Be 'acme'
    }
}

Describe 'Install-Attrezzi -Pat' {
    It 'lo script ha l opzione -Pat e non ha piu -Az' {
        (Get-Command $script:Install).Parameters.ContainsKey('Pat') | Should -BeTrue
        (Get-Command $script:Install).Parameters.ContainsKey('Az') | Should -BeFalse
    }

    It 'la config dei PAT e leggibile e ha scope, durata e nomi per entrambi' {
        $cfg = Get-Content $script:Config -Raw | ConvertFrom-Json
        $cfg.durataGiorni | Should -BeGreaterThan 0
        foreach ($k in 'smistatore', 'solaLettura') { $cfg.$k.nome | Should -Not -BeNullOrEmpty; @($cfg.$k.scope).Count | Should -BeGreaterThan 0 }
    }
}

Describe 'Install-Attrezzi: -Pat gira per ultimo' {
    It 'il blocco -Pat sta dopo -Regole, -Hook, -Pianificazione e -RimuoviPianificazione' {
        $testo = Get-Content $script:Install -Raw
        $pat = $testo.IndexOf('if ($Pat) {')
        $pat | Should -BeGreaterThan 0
        foreach ($altro in 'if ($Regole) {', 'if ($Hook) {', 'if ($Pianificazione) {', 'if ($RimuoviPianificazione) {') {
            $testo.IndexOf($altro) | Should -BeGreaterThan 0
            $testo.IndexOf($altro) | Should -BeLessThan $pat
        }
    }
}
