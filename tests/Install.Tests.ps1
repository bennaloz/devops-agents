BeforeAll {
    # D53: Get-Config e Get-ConfigSupervisore leggono impostazioni.json dalla cartella dati: i test non devono vedere quella vera di chi li lancia.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    $script:Install = Join-Path $PSScriptRoot '../setup/Install-Attrezzi.ps1'
    $script:Repo = Split-Path -Parent $PSScriptRoot

    function Get-Voci($Settings) { @($Settings.hooks.PreToolUse) }
    function Get-Comandi($Settings) { @(Get-Voci $Settings | ForEach-Object { $_.hooks } | ForEach-Object { $_.command }) }
}

Describe 'Install-Attrezzi -Hook' {
    BeforeEach {
        # Una cartella finta al posto di ~/.claude: la vera non si tocca mai.
        $script:Claude = Join-Path ([IO.Path]::GetTempPath()) ("claude-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Claude | Out-Null
        $script:Settings = Join-Path $script:Claude 'settings.json'
        @'
{ "hooks": { "Notification": [ { "matcher": "", "hooks": [ { "type": "command", "command": "echo notifica" } ] } ] },
  "model": "opus", "permissions": { "allow": ["Read"] } }
'@ | Set-Content $script:Settings -Encoding utf8
    }
    AfterEach {
        # niente Remove-Item -Recurse sulla giunzione: prima la si stacca
        $g = Join-Path $script:Claude 'skills/regole-sviluppo'
        if (Test-Path $g) { (Get-Item $g).Delete() }
        Remove-Item $script:Claude -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'aggiunge le cinque voci PreToolUse a un file che ha solo Notification' {
        & $script:Install -Hook -ClaudeDir $script:Claude
        $s = Get-Content $script:Settings -Raw | ConvertFrom-Json
        $voci = Get-Voci $s
        $voci.Count | Should -Be 5
        ($voci | Where-Object { $_.hooks.command -like '*deny-commit-outside-worktree.ps1*' }).matcher | Should -Be 'Bash|PowerShell'
        ($voci | Where-Object { $_.hooks.command -like '*deny-secrets-in-repo.ps1*' }).matcher | Should -Be 'Write|Edit'
        ($voci | Where-Object { $_.hooks.command -like '*deny-pat.ps1*' }).matcher | Should -Be 'Bash|PowerShell|Read'
        ($voci | Where-Object { $_.hooks.command -like '*deny-identita.ps1*' }).matcher | Should -Be 'Bash|PowerShell'
        ($voci | Where-Object { $_.hooks.command -like '*deny-host-collaudo.ps1*' }).matcher | Should -Be 'Bash|PowerShell|WebFetch'
        foreach ($c in (Get-Comandi $s)) {
            $c | Should -BeLike 'pwsh -NoProfile -File "C:/develop/GIT/DevOps.Agents/hooks/*.ps1"'
        }
    }

    It 'lanciato due volte non duplica' {
        & $script:Install -Hook -ClaudeDir $script:Claude
        & $script:Install -Hook -ClaudeDir $script:Claude
        $s = Get-Content $script:Settings -Raw | ConvertFrom-Json
        (Get-Voci $s).Count | Should -Be 5
        @(Get-Comandi $s | Select-Object -Unique).Count | Should -Be 5
    }

    It 'conserva le altre chiavi' {
        & $script:Install -Hook -ClaudeDir $script:Claude
        $s = Get-Content $script:Settings -Raw | ConvertFrom-Json
        $s.model | Should -Be 'opus'
        $s.permissions.allow | Should -Be @('Read')
        $s.hooks.Notification[0].hooks[0].command | Should -Be 'echo notifica'
    }

    It 'conserva una voce PreToolUse gia presente e non sua' {
        @'
{ "hooks": { "PreToolUse": [ { "matcher": "Task", "hooks": [ { "type": "command", "command": "echo altro" } ] } ] } }
'@ | Set-Content $script:Settings -Encoding utf8
        & $script:Install -Hook -ClaudeDir $script:Claude
        $s = Get-Content $script:Settings -Raw | ConvertFrom-Json
        (Get-Voci $s).Count | Should -Be 6
        Get-Comandi $s | Should -Contain 'echo altro'
    }

    It 'crea la copia di salvataggio accanto all originale, con il contenuto di prima' {
        $prima = Get-Content $script:Settings -Raw
        & $script:Install -Hook -ClaudeDir $script:Claude
        $copie = @(Get-ChildItem $script:Claude -Filter 'settings.json.*' | Where-Object { $_.Name -ne 'settings.json' })
        $copie.Count | Should -Be 1
        (Get-Content $copie[0].FullName -Raw) | Should -Be $prima
    }

    It 'crea il file se non esiste' {
        Remove-Item $script:Settings
        & $script:Install -Hook -ClaudeDir $script:Claude
        (Get-Voci (Get-Content $script:Settings -Raw | ConvertFrom-Json)).Count | Should -Be 5
    }
}

Describe 'Install-Attrezzi -Pianificazione' {
    BeforeEach {
        # Nessuna operazione vera sulla macchina: i cmdlet di ScheduledTasks che scrivono sono sostituiti.
        Mock Register-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Smistatore' } }
        # Una copia principale finta, con un intervallo diverso da quello del repo che lancia l'installazione.
        $script:Principale = (Join-Path $TestDrive ('principale-' + [guid]::NewGuid().ToString('N'))).Replace('\', '/')
        New-Item -ItemType Directory "$script:Principale/src", "$script:Principale/config" | Out-Null
        Set-Content "$script:Principale/src/Smistatore.ps1" '# finto'
        Set-Content "$script:Principale/src/Vista.ps1" '# finto'
        Set-Content "$script:Principale/src/Supervisore.ps1" '# finto'
        $script:MinutiSupervisore = [int](Get-Content (Join-Path $script:Repo 'config/supervisore.json') -Raw | ConvertFrom-Json).intervalloMinuti + 4
        Set-Content "$script:Principale/config/supervisore.json" ('{ "intervalloMinuti": ' + $script:MinutiSupervisore + ' }')
        $script:MinutiRepo = [int](Get-Content (Join-Path $script:Repo 'config/limiti.json') -Raw | ConvertFrom-Json).intervalloMinuti
        $script:MinutiPrincipale = $script:MinutiRepo + 3
        Set-Content "$script:Principale/config/limiti.json" ('{ "intervalloMinuti": ' + $script:MinutiPrincipale + ' }')
    }

    It 'registra l operazione DevOps.Agents\Smistatore a utente collegato' {
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'Smistatore' -and $TaskPath -eq '\DevOps.Agents\' -and $Principal.LogonType -eq 'Interactive' -and $Principal.RunLevel -eq 'Limited'
        }
    }

    It 'l azione punta a src/Smistatore.ps1 della working copy principale, mai al worktree che lancia l installazione' {
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $a = @($Action)[0]
            $a.Arguments -like "*-File `"$script:Principale/src/Smistatore.ps1`"*" -and
            $a.Arguments -notlike "*$($script:Repo.Replace('\', '/'))*" -and $a.Arguments -notlike "*$($script:Repo)*"
        }
    }

    It 'parte senza finestra: conhost --headless dal suo percorso completo, che lancia pwsh dal suo percorso completo' {
        # pwsh -WindowStyle Hidden apre comunque la console per un istante a ogni giro
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $a = @($Action)[0]
            $pwsh = (Get-Command pwsh).Source
            $TaskName -eq 'Smistatore' -and [IO.Path]::IsPathRooted($a.Execute) -and (Split-Path -Leaf $a.Execute) -ieq 'conhost.exe' -and (Test-Path -LiteralPath $a.Execute) -and
            $a.Arguments -like "--headless `"$pwsh`" -NoProfile -NonInteractive -File *" -and $a.Arguments -notlike '*-WindowStyle*'
        }
    }

    It 'senza -RadicePrincipale usa la working copy principale di DevOps.Agents, non il repo dello script' {
        # i file della copia principale vera non si leggono: il controllo e il limiti.json sono finti
        Mock Test-Path { $true }
        Mock Get-Content { '{ "intervalloMinuti": 5 }' }
        & $script:Install -Pianificazione
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            @($Action)[0].Arguments -like '*"C:/develop/GIT/DevOps.Agents/src/Smistatore.ps1"*'
        }
    }

    It 'l intervallo si legge da config/limiti.json della copia principale, l unica da cui l operazione girera' {
        $script:MinutiPrincipale | Should -Not -Be $script:MinutiRepo
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'Smistatore' -and [System.Xml.XmlConvert]::ToTimeSpan(@($Trigger)[0].Repetition.Interval).TotalMinutes -eq $script:MinutiPrincipale
        }
    }

    It 'se la copia principale non ha src/Smistatore.ps1 (ramo non ancora in develop) non registra niente e lo dice' {
        Remove-Item "$script:Principale/src/Smistatore.ps1"
        { & $script:Install -Pianificazione -RadicePrincipale $script:Principale } | Should -Throw '*Smistatore.ps1*'
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }

    It 'lanciato due volte aggiorna l operazione esistente invece di fallire o duplicarla' {
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Register-ScheduledTask -Times 2 -Exactly -ParameterFilter { $Force -and $TaskName -eq 'Smistatore' -and $TaskPath -eq '\DevOps.Agents\' }
    }

    It '-RimuoviPianificazione toglie l operazione' {
        & $script:Install -RimuoviPianificazione
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'Smistatore' -and $TaskPath -eq '\DevOps.Agents\' -and $Confirm -eq $false
        }
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }

    It 'registra anche la vista: all accesso dell utente, a utente collegato, senza limite di durata, una sola alla volta' {
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'Vista' -and $TaskPath -eq '\DevOps.Agents\' -and $Force -and
            $Principal.LogonType -eq 'Interactive' -and @($Trigger)[0].CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and
            $Settings.ExecutionTimeLimit -eq 'PT0S' -and $Settings.MultipleInstances -eq 'IgnoreNew'
        }
    }

    It 'la vista parte senza finestra dalla copia principale, con la pagina HTML e il server' {
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $a = @($Action)[0]
            $TaskName -eq 'Vista' -and (Split-Path -Leaf $a.Execute) -ieq 'conhost.exe' -and
            $a.Arguments -like "--headless `"*pwsh*`" -NoProfile -NonInteractive -File `"$script:Principale/src/Vista.ps1`" -Html -Segui -Apri"
        }
    }

    It 'se la copia principale non ha src/Vista.ps1 lo dice, senza registrare la vista' {
        Remove-Item "$script:Principale/src/Vista.ps1"
        { & $script:Install -Pianificazione -RadicePrincipale $script:Principale } | Should -Throw '*Vista.ps1*'
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly -ParameterFilter { $TaskName -eq 'Vista' }
    }

    It '-RimuoviPianificazione toglie anche la vista' {
        & $script:Install -RimuoviPianificazione
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'Vista' -and $TaskPath -eq '\DevOps.Agents\' -and $Confirm -eq $false
        }
    }

    It 'registra anche il supervisore: DevOps.Agents\Supervisore a utente collegato, senza finestra, dalla copia principale' {
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $a = @($Action)[0]
            $TaskName -eq 'Supervisore' -and $TaskPath -eq '\DevOps.Agents\' -and $Force -and
            $Principal.LogonType -eq 'Interactive' -and $Principal.RunLevel -eq 'Limited' -and
            (Split-Path -Leaf $a.Execute) -ieq 'conhost.exe' -and $a.Arguments -like "--headless `"*pwsh*`" -NoProfile -NonInteractive -File `"$script:Principale/src/Supervisore.ps1`"" -and
            $a.Arguments -notlike "*$($script:Repo.Replace('\', '/'))*" -and $Settings.MultipleInstances -eq 'IgnoreNew'
        }
    }

    It 'il supervisore gira ogni intervalloMinuti di config/supervisore.json della copia principale, non di limiti.json' {
        $script:MinutiSupervisore | Should -Not -Be $script:MinutiPrincipale
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'Supervisore' -and [System.Xml.XmlConvert]::ToTimeSpan(@($Trigger)[0].Repetition.Interval).TotalMinutes -eq $script:MinutiSupervisore
        }
    }

    It 'se la copia principale non ha src/Supervisore.ps1 lo dice, senza registrare il supervisore' {
        Remove-Item "$script:Principale/src/Supervisore.ps1"
        { & $script:Install -Pianificazione -RadicePrincipale $script:Principale } | Should -Throw '*Supervisore.ps1*'
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly -ParameterFilter { $TaskName -eq 'Supervisore' }
    }

    It '-RimuoviPianificazione toglie anche il supervisore' {
        & $script:Install -RimuoviPianificazione
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'Supervisore' -and $TaskPath -eq '\DevOps.Agents\' -and $Confirm -eq $false
        }
    }

    It '-RimuoviPianificazione senza un operazione registrata non fa niente e non fallisce' {
        Mock Get-ScheduledTask { $null }
        & $script:Install -RimuoviPianificazione
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
    }
}

Describe 'Install-Attrezzi -Regole' {
    BeforeEach {
        $script:Claude = Join-Path ([IO.Path]::GetTempPath()) ("claude-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Claude | Out-Null
    }
    AfterEach {
        foreach ($n in 'regole-sviluppo', 'devops-agents', 'card-agenti') {
            # Get-Item e non Test-Path: una giunzione rimasta senza bersaglio per Test-Path non esiste
            $g = Get-Item -LiteralPath (Join-Path $script:Claude "skills/$n") -Force -ErrorAction SilentlyContinue
            if ($g -and $g.LinkType -eq 'Junction') { $g.Delete() }
        }
        Remove-Item $script:Claude -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'crea la giunzione verso regole/ e si puo rilanciare' {
        & $script:Install -Regole -ClaudeDir $script:Claude
        & $script:Install -Regole -ClaudeDir $script:Claude
        $g = Get-Item (Join-Path $script:Claude 'skills/regole-sviluppo')
        $g.LinkType | Should -Be 'Junction'
        (Resolve-Path $g.Target).Path | Should -Be (Resolve-Path (Join-Path $script:Repo 'regole')).Path
        Test-Path (Join-Path $g.FullName 'SKILL.md') | Should -BeTrue
    }

    It 'crea anche la giunzione della skill devops-agents verso skills/devops-agents' {
        & $script:Install -Regole -ClaudeDir $script:Claude
        & $script:Install -Regole -ClaudeDir $script:Claude
        $g = Get-Item (Join-Path $script:Claude 'skills/devops-agents')
        $g.LinkType | Should -Be 'Junction'
        (Resolve-Path $g.Target).Path | Should -Be (Resolve-Path (Join-Path $script:Repo 'skills/devops-agents')).Path
        Test-Path (Join-Path $g.FullName 'SKILL.md') | Should -BeTrue
    }

    It 'una cartella devops-agents che non e la giunzione attesa non la tocca' {
        New-Item -ItemType Directory -Path (Join-Path $script:Claude 'skills/devops-agents') -Force | Out-Null
        { & $script:Install -Regole -ClaudeDir $script:Claude } | Should -Throw '*devops-agents*non la tocco*'
    }

    It 'toglie la giunzione del nome vecchio card-agenti, che puntava a questo repo' {
        # la skill si chiamava card-agenti: dopo la rinomina la giunzione vecchia punta a una cartella che non c e piu
        $skills = Join-Path $script:Claude 'skills'
        New-Item -ItemType Directory -Path $skills -Force | Out-Null
        $vecchio = Join-Path $script:Repo 'skills/card-agenti'
        New-Item -ItemType Directory -Path $vecchio | Out-Null
        try { New-Item -ItemType Junction -Path (Join-Path $skills 'card-agenti') -Target $vecchio | Out-Null }
        finally { Remove-Item -LiteralPath $vecchio -Force }
        & $script:Install -Regole -ClaudeDir $script:Claude
        Get-Item -LiteralPath (Join-Path $skills 'card-agenti') -Force -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        (Get-Item (Join-Path $skills 'devops-agents')).LinkType | Should -Be 'Junction'
    }

    It 'una cartella card-agenti che non e una giunzione verso questo repo resta dov e' {
        $altra = Join-Path $script:Claude 'skills/card-agenti'
        New-Item -ItemType Directory -Path $altra -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $altra 'SKILL.md') -Value 'una skill di qualcun altro'
        & $script:Install -Regole -ClaudeDir $script:Claude
        Test-Path -LiteralPath (Join-Path $altra 'SKILL.md') | Should -BeTrue
    }
}

Describe 'Install-Attrezzi -Hook: i percorsi si confrontano senza badare a barre e maiuscole (D53)' {
    BeforeEach {
        $script:Claude = Join-Path ([IO.Path]::GetTempPath()) ("claude-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Claude | Out-Null
        $script:Settings = Join-Path $script:Claude 'settings.json'
    }
    AfterEach { Remove-Item $script:Claude -Recurse -Force -ErrorAction SilentlyContinue }

    It 'un settings.json con le voci in forma con barre in avanti, rilanciato con la radice in forma Windows, non duplica' {
        & $script:Install -Hook -ClaudeDir $script:Claude -RadicePrincipale 'C:/develop/GIT/DevOps.Agents'
        $prima = Get-Content $script:Settings -Raw
        & $script:Install -Hook -ClaudeDir $script:Claude -RadicePrincipale 'C:\develop\GIT\DevOps.Agents'
        (Get-Content $script:Settings -Raw) | Should -Be $prima
        @(Get-Voci (Get-Content $script:Settings -Raw | ConvertFrom-Json)).Count | Should -Be 5
    }
    It 'vale anche per le maiuscole e per una voce scritta a mano con le barre rovesciate' {
        & $script:Install -Hook -ClaudeDir $script:Claude
        $s = (Get-Content $script:Settings -Raw).Replace('C:/develop/GIT/DevOps.Agents', 'c:\\DEVELOP\\git\\devops.agents')
        Set-Content $script:Settings $s -Encoding utf8
        & $script:Install -Hook -ClaudeDir $script:Claude -RadicePrincipale 'C:\develop\GIT\DevOps.Agents'
        @(Get-Voci (Get-Content $script:Settings -Raw | ConvertFrom-Json)).Count | Should -Be 5
    }
    It 'una voce davvero diversa (un altra radice) si aggiunge' {
        & $script:Install -Hook -ClaudeDir $script:Claude -RadicePrincipale 'C:/develop/GIT/DevOps.Agents'
        & $script:Install -Hook -ClaudeDir $script:Claude -RadicePrincipale 'D:\altrove'
        @(Get-Voci (Get-Content $script:Settings -Raw | ConvertFrom-Json)).Count | Should -Be 10
    }
}

Describe 'Install-Attrezzi -Pianificazione: un attivita disabilitata resta disabilitata (D53)' {
    BeforeEach {
        $global:StatiAttivita = @{}
        Mock Register-ScheduledTask { }
        Mock Disable-ScheduledTask { }
        Mock Get-ScheduledTask { $n = "$TaskName"; if ($global:StatiAttivita.ContainsKey($n)) { [pscustomobject]@{ TaskName = $n; State = $global:StatiAttivita[$n] } } }
        $script:Principale = (Join-Path $TestDrive ('p-' + [guid]::NewGuid().ToString('N'))).Replace('\', '/')
        New-Item -ItemType Directory "$script:Principale/src", "$script:Principale/config" | Out-Null
        foreach ($f in 'Smistatore', 'Vista', 'Supervisore') { Set-Content "$script:Principale/src/$f.ps1" '# finto' }
        Set-Content "$script:Principale/config/supervisore.json" '{ "intervalloMinuti": 5 }'
        Set-Content "$script:Principale/config/limiti.json" '{ "intervalloMinuti": 2 }'
    }
    It 'lo smistatore disabilitato (da una persona o dall aggiornamento) dopo la registrazione e di nuovo disabilitato; le altre no' {
        $global:StatiAttivita['Smistatore'] = 'Disabled'; $global:StatiAttivita['Vista'] = 'Ready'; $global:StatiAttivita['Supervisore'] = 'Running'
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Register-ScheduledTask -Times 3 -Exactly
        Should -Invoke Disable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Smistatore' }
    }
    It 'lo fa per ognuna delle tre che era disabilitata' {
        foreach ($n in 'Smistatore', 'Vista', 'Supervisore') { $global:StatiAttivita[$n] = 'Disabled' }
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Disable-ScheduledTask -Times 3 -Exactly
    }
    It 'attivita abilitate o mai registrate: niente Disable' {
        $global:StatiAttivita['Smistatore'] = 'Ready'
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
    }
    It 'lo stato si guarda prima di registrare: la disabilitazione viene dopo la registrazione' {
        $global:StatiAttivita['Smistatore'] = 'Disabled'
        $global:Ordine = @()
        Mock Register-ScheduledTask { $global:Ordine += "reg:$TaskName" }
        Mock Disable-ScheduledTask { $global:Ordine += "dis:$TaskName" }
        & $script:Install -Pianificazione -RadicePrincipale $script:Principale
        $global:Ordine.IndexOf('reg:Smistatore') | Should -BeLessThan $global:Ordine.IndexOf('dis:Smistatore')
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }

Describe 'Install-Attrezzi -PatGitHub' {
    BeforeEach {
        $script:Claude = Join-Path ([IO.Path]::GetTempPath()) ("claude-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Claude | Out-Null
        Import-Module (Join-Path $script:Repo 'src/GitHub.psm1') -Force
    }
    AfterEach { Remove-Item $script:Claude -Recurse -Force -ErrorAction SilentlyContinue }

    It 'salva i due token cifrati nei file pat-github, senza il testo in chiaro' {
        $s = ConvertTo-SecureString 'ghp_scrittura' -AsPlainText -Force
        $l = ConvertTo-SecureString 'ghp_lettura' -AsPlainText -Force
        & $script:Install -PatGitHub -TokenGitHub $s -TokenGitHubLettura $l -ClaudeDir $script:Claude 6>$null
        $fs = Join-Path $script:Claude 'pat-github.txt'
        $fl = Join-Path $script:Claude 'pat-github-lettura.txt'
        Read-FilePat $fs | Should -Be 'ghp_scrittura'
        Read-FilePat $fl | Should -Be 'ghp_lettura'
        Get-Content $fs -Raw | Should -Not -Match 'ghp_scrittura'
    }

    It 'un token vuoto non salva niente' {
        $v = ConvertTo-SecureString ' ' -AsPlainText -Force
        { & $script:Install -PatGitHub -TokenGitHub $v -TokenGitHubLettura $v -ClaudeDir $script:Claude 6>$null } | Should -Throw '*vuoto*'
        Test-Path (Join-Path $script:Claude 'pat-github.txt') | Should -BeFalse
    }
}
