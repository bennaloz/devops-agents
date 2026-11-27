BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Comune.psm1') -Force
}

Describe 'Get-CartellaDati' {
    BeforeEach { $script:Vecchia = $env:ATTREZZI_DATI }
    AfterEach { $env:ATTREZZI_DATI = $script:Vecchia }

    It 'usa la variabile ATTREZZI_DATI se c e' {
        $env:ATTREZZI_DATI = 'C:\dati\prova'
        Get-CartellaDati | Should -Be 'C:\dati\prova'
    }
    It 'senza variabile e la cartella di DevOps.Agents sotto LOCALAPPDATA' {
        $env:ATTREZZI_DATI = $null
        Get-CartellaDati | Should -Be (Join-Path $env:LOCALAPPDATA 'DevOps.Agents')
    }
}

Describe 'Get-Campo' {
    It 'legge da un oggetto, da un dizionario e da null' {
        Get-Campo ([pscustomobject]@{ a = 1 }) 'a' | Should -Be 1
        Get-Campo @{ a = 2 } 'a' | Should -Be 2
        Get-Campo ([ordered]@{ a = 3 }) 'a' | Should -Be 3
        Get-Campo $null 'a' | Should -BeNullOrEmpty
    }
    It 'un campo che non c e e null, anche in StrictMode' {
        Set-StrictMode -Version Latest
        Get-Campo ([pscustomobject]@{ a = 1 }) 'b' | Should -BeNullOrEmpty
        Get-Campo @{ a = 1 } 'b' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DataUtc' {
    It 'legge stringhe senza fuso come UTC, DateTime e vuoti' {
        (ConvertTo-DataUtc '2026-11-01T10:00:00Z').Hour | Should -Be 10
        (ConvertTo-DataUtc '2026-11-01T10:00:00').Hour | Should -Be 10
        (ConvertTo-DataUtc ([datetime]::new(2026, 11, 1, 10, 0, 0, [DateTimeKind]::Utc))).Hour | Should -Be 10
        ConvertTo-DataUtc '' | Should -BeNullOrEmpty
        ConvertTo-DataUtc $null | Should -BeNullOrEmpty
        ConvertTo-DataUtc 'non una data' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ChiaveStato' {
    BeforeAll {
        $script:Stati = [pscustomobject]@{ nuova = 'New'; inSviluppo = 'In development'; tagAgenti = 'agenti' }
    }
    It 'dal nome allo stato alla chiave, senza badare alle maiuscole' {
        Get-ChiaveStato $script:Stati 'in DEVELOPMENT' | Should -Be 'inSviluppo'
        Get-ChiaveStato @{ nuova = 'New' } 'new' | Should -Be 'nuova'
    }
    It 'nome sconosciuto o vuoto: null. I tag non sono stati' {
        Get-ChiaveStato $script:Stati 'Boh' | Should -BeNullOrEmpty
        Get-ChiaveStato $script:Stati '' | Should -BeNullOrEmpty
        Get-ChiaveStato $script:Stati 'agenti' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ChiaveStato: i task hanno chiavi proprie' {
    It 'le chiavi task* sono stati di task, non di card: Closed e Removed restano della card anche se un task li condivide' {
        $s = [pscustomobject]@{ taskChiuso = 'Closed'; chiusa = 'Closed'; taskRimosso = 'Removed'; rimossa = 'Removed' }
        Get-ChiaveStato $s 'Closed' | Should -Be 'chiusa'
        Get-ChiaveStato $s 'Removed' | Should -Be 'rimossa'
        Get-ChiaveStato ([pscustomobject]@{ nuova = 'New'; taskChiuso = 'Closed' }) 'Closed' | Should -BeNullOrEmpty
    }
}

Describe 'Get-OperazionePianificata' {
    It 'da il percorso e il nome dell operazione dello smistatore: gli stessi per registrarla, toglierla e leggerne il prossimo giro' {
        $o = Get-OperazionePianificata
        $o.Percorso | Should -Be '\DevOps.Agents\'
        $o.Nome | Should -Be 'Smistatore'
    }
}

Describe 'Get-FileLog' {
    It 'un file per giorno nella cartella log dei dati' {
        Get-FileLog 'C:\dati' ([datetime]'2026-11-18T10:02:03') | Should -Be (Join-Path (Join-Path 'C:\dati' 'log') 'smistatore-2026-11-18.log')
    }
}

Describe 'Read-FilePat e Write-FilePat' {
    BeforeEach { $script:F = Join-Path $TestDrive ('pat-' + [guid]::NewGuid().ToString('N') + '.txt') }

    It 'un file in chiaro (il pat.txt di prima) si legge com e, senza spazi attorno' {
        Set-Content -LiteralPath $script:F -Value "  abc123segreto`r`n" -NoNewline
        Read-FilePat $script:F | Should -Be 'abc123segreto'
    }

    It 'un file scritto da Write-FilePat e cifrato su disco e torna uguale in lettura' {
        Write-FilePat $script:F 'abc123segreto'
        (Get-Content -LiteralPath $script:F -Raw) | Should -Not -Match 'abc123segreto'
        Read-FilePat $script:F | Should -Be 'abc123segreto'
    }

    It 'un file che non c e o e vuoto da una stringa vuota' {
        Read-FilePat (Join-Path $TestDrive 'non-esiste.txt') | Should -Be ''
        Set-Content -LiteralPath $script:F -Value '' -NoNewline
        Read-FilePat $script:F | Should -Be ''
    }

    It 'Write-FilePat crea la cartella che manca' {
        $p = Join-Path $TestDrive 'nuova/sotto/pat.txt'
        Write-FilePat $p 'x1'
        Read-FilePat $p | Should -Be 'x1'
    }
}

Describe 'Read-FilePat con un file cifrato non decifrabile' {
    It 'con l intestazione DPAPI e una decifratura che fallisce da un errore chiaro, senza il valore' {
        $f = Join-Path $TestDrive 'cifrato-altrui.txt'
        $corpo = '01000000d08c9ddf0115d1118c7a00c04fc297eb01000000SEGRETO-DI-ALTRI'
        Set-Content -LiteralPath $f -Value $corpo -NoNewline
        $msg = try { Read-FilePat $f; '' } catch { $_.Exception.Message }
        $msg | Should -Match 'cifrato ma non decifrabile da questo utente Windows'
        $msg | Should -Match 'Install-Attrezzi\.ps1 -Pat'
        $msg | Should -Not -Match 'SEGRETO-DI-ALTRI|01000000d08c9ddf'
    }
}

Describe 'Get-PercorsoFilePat' {
    BeforeEach { $script:C = Join-Path $TestDrive ('c-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $script:C | Out-Null }

    It 'smistatore: pat-smistatore.txt se c e, altrimenti pat.txt' {
        Get-PercorsoFilePat 'smistatore' $script:C | Should -Be (Join-Path $script:C 'pat.txt')
        Set-Content (Join-Path $script:C 'pat-smistatore.txt') 'x'
        Get-PercorsoFilePat 'smistatore' $script:C | Should -Be (Join-Path $script:C 'pat-smistatore.txt')
    }

    It 'lettura: pat-smistatore-lettura.txt se c e, altrimenti pat-read-only.txt' {
        Get-PercorsoFilePat 'lettura' $script:C | Should -Be (Join-Path $script:C 'pat-read-only.txt')
        Set-Content (Join-Path $script:C 'pat-smistatore-lettura.txt') 'x'
        Get-PercorsoFilePat 'lettura' $script:C | Should -Be (Join-Path $script:C 'pat-smistatore-lettura.txt')
    }
}

# D43: il commento con cui il responsabile sceglie i parametri del deploy in Test. Lo scrive card.ps1 deploy, lo legge lo
# smistatore: il formato sta in Comune.psm1, una volta sola.
Describe 'Il commento di deploy del responsabile' {
    BeforeAll {
        function New-Commento($Id, [string]$Testo) { [pscustomobject]@{ Id = $Id; Autore = 'x'; Testo = $Testo; Quando = 'd' } }
        # come lo scrive card.ps1 (prefisso e firma di Add-CardCommento)
        function New-CommentoDeploy($Id, [string[]]$Parametri, [string]$Perche = 'serve') {
            New-Commento $Id ("[responsabile] $(ConvertTo-TestoCommentoDeploy -Parametri $Parametri -Perche $Perche)`n`n— scritto da Claude (responsabile)")
        }
    }

    It 'il testo ha i parametri sulla prima riga e il perche sotto' {
        $t = ConvertTo-TestoCommentoDeploy -Parametri @('deployDatabases', 'deployForms') -Perche "lo schema cambia`ne anche il form"
        ($t -split "`n")[0] | Should -Be 'Parametri del deploy in Test: deployDatabases, deployForms'
        $t | Should -Match "Perche: lo schema cambia`ne anche il form"
    }

    It 'si rilegge cosi come si scrive' {
        $s = Get-SceltaDeploy @(New-CommentoDeploy 3 @('deployDatabases', 'deployForms'))
        @($s) | Should -Be @('deployDatabases', 'deployForms')
    }

    It 'vale l ultimo, nell ordine degli id' {
        $s = Get-SceltaDeploy @((New-CommentoDeploy 9 @('deployForms')), (New-Commento 10 '[responsabile] altro'), (New-CommentoDeploy 4 @('deployDatabases')))
        @($s) | Should -Be @('deployForms')
    }

    It 'nessun commento di deploy: null' {
        Get-SceltaDeploy @((New-Commento 1 '[responsabile] criteri scritti'), (New-Commento 2 'una persona')) | Should -BeNullOrEmpty
        Get-SceltaDeploy @() | Should -BeNullOrEmpty
    }

    It 'vale solo se lo scrive il responsabile: lo smistatore e le persone non scelgono' {
        Get-SceltaDeploy @((New-Commento 1 '[smistatore] Parametri del deploy in Test: deployForms'), (New-Commento 2 'Parametri del deploy in Test: deployForms')) | Should -BeNullOrEmpty
        Get-SceltaDeploy @(New-Commento 1 '[dev] Parametri del deploy in Test: deployForms') | Should -BeNullOrEmpty
    }

    It 'la riga deve aprire il commento: citata in mezzo a un testo non conta' {
        Get-SceltaDeploy @(New-Commento 1 "[responsabile] ho visto che`nParametri del deploy in Test: deployForms") | Should -BeNullOrEmpty
    }

    It 'si legge anche nel testo html che Azure DevOps puo restituire, con backtick e grassetto attorno ai nomi' {
        $html = '<div><p>[responsabile] Parametri del deploy in Test: `deployDatabases`, **deployForms**</p><p>Perche: x &amp; y</p></div>'
        @(Get-SceltaDeploy @(New-Commento 5 $html)) | Should -Be @('deployDatabases', 'deployForms')
    }

    It 'un commento di deploy senza nomi non sceglie niente, e copre quelli di prima' {
        @(Get-SceltaDeploy @((New-CommentoDeploy 4 @('deployForms')), (New-Commento 5 '[responsabile] Parametri del deploy in Test:'))).Count | Should -Be 0
    }
}

Describe 'Get-SceltaDeploy racchiusa in @()' {
    It 'senza commenti di deploy da un elenco vuoto, non un elemento null' {
        @(Get-SceltaDeploy @([pscustomobject]@{ Id = 1; Testo = 'una persona' })).Count | Should -Be 0
    }
}

Describe 'stati.json: le chiavi di D52' {
    It 'ha inFeature e i tag della funzionalita' {
        $st = Get-Content (Join-Path $PSScriptRoot '../config/stati.json') -Raw | ConvertFrom-Json
        $st.inFeature | Should -Be 'In feature branch'
        $st.tagChiusura | Should -Be 'collaudo-funzionalita'
        $st.tagBugFeature | Should -Be 'bug'
        $st.tagAllinea | Should -Be 'allinea-develop'
    }
    It 'inFeature e fra gli stati con ramo, fra daUnire e daRilasciare (D52, gruppo 3)' {
        $s = @(Get-StatiConRamo)
        $s | Should -Contain 'inFeature'
        $s.IndexOf('inFeature') | Should -Be ($s.IndexOf('daUnire') + 1)
        # D61: fra In feature branch e Ready to release c'e Ready to deploy (test)
        $s.IndexOf('daDeployTest') | Should -Be ($s.IndexOf('inFeature') + 1)
        $s.IndexOf('daRilasciare') | Should -Be ($s.IndexOf('daDeployTest') + 1)
    }
}
Describe 'Get-DestinazioneCard' {
    It 'senza destinazione salvata (card isolata, o stato di prima di D52) e develop' {
        Get-DestinazioneCard @{ ramo = 'feature/5-x' } | Should -Be 'develop'
        Get-DestinazioneCard @{ destinazione = $null } | Should -Be 'develop'
        Get-DestinazioneCard $null | Should -Be 'develop'
    }
    It 'con la destinazione salvata e quella, il ramo della funzionalita' {
        Get-DestinazioneCard @{ destinazione = 'feature/f7-la-funzione' } | Should -Be 'feature/f7-la-funzione'
    }
}
Describe 'D52: il nome dei rami della funzionalita' {
    It 'i prefissi e la forma f<id> stanno qui: feature e bugfix, f7' {
        @(Get-PrefissiRamoFunzionalita) | Should -Be @('feature', 'bugfix')
        Get-PrefissoRamoFunzionalita | Should -Be 'feature'
        Get-PrefissoRamoFunzionalita -Correzione | Should -Be 'bugfix'
        Get-SiglaFunzionalita 7 | Should -Be 'f7'
    }
    It 'la regex riconosce il ramo della Feature, con o senza slug, e non quello di un altra Feature ne di una card' {
        $r = Get-RegexRamoFunzionalita 7
        'feature/f7-il-filtro' | Should -Match $r
        'bugfix/f7' | Should -Match $r
        'feature/f70-altra' | Should -Not -Match $r
        'feature/7-card' | Should -Not -Match $r
        'fix/f7-x' | Should -Not -Match $r
        'origin/feature/f7-x' | Should -Not -Match $r
        'origin/feature/f7-x' | Should -Match (Get-RegexRamoFunzionalita 7 -Radice 'origin/')
    }
}

Describe 'Get-ChiaveStato: gli stati della Feature' {
    It 'le chiavi feature* non sono stati delle card: Resolved non si traduce, e New resta la card' {
        $s = [pscustomobject]@{ nuova = 'New'; featureNuova = 'New'; featureRisolta = 'Resolved' }
        Get-ChiaveStato $s 'Resolved' | Should -BeNullOrEmpty
        Get-ChiaveStato $s 'New' | Should -Be 'nuova'
    }
}

# D52, gruppo 5: il commento con cui il responsabile della card di chiusura scrive una correzione. Lo scrive card.ps1 correzione,
# lo legge lo smistatore: il formato sta in Comune.psm1, una volta sola (come il deploy).
Describe 'Il commento di correzione del responsabile' {
    BeforeAll {
        function New-Commento($Id, [string]$Testo) { [pscustomobject]@{ Id = $Id; Autore = 'x'; Testo = $Testo; Quando = 'd' } }
        # come lo scrive card.ps1 (prefisso e firma di Add-CardCommento)
        function New-CommentoCorrezione($Id, [string]$Tipo = 'tecnico', [string]$Titolo = 'Il totale non somma', [string]$Descrizione = "Il totale ignora le righe scontate.`nAtteso: le somma.") {
            New-Commento $Id ("[responsabile] $(ConvertTo-TestoCommentoCorrezione -Tipo $Tipo -Titolo $Titolo -Descrizione $Descrizione)`n`n— scritto da Claude (responsabile)")
        }
    }

    It 'il testo ha la marca e il tipo sulla prima riga, il titolo sulla seconda e la descrizione sotto' {
        $t = ConvertTo-TestoCommentoCorrezione -Tipo 'prodotto' -Titolo 'Quale arrotondamento' -Descrizione "Due strade.`nServe una scelta."
        $righe = $t -split "`n"
        $righe[0] | Should -Be 'Correzione: prodotto'
        $righe[1] | Should -Be 'Titolo: Quale arrotondamento'
        $t | Should -Match "Due strade\.`nServe una scelta\."
    }

    It 'si rilegge cosi come si scrive, con l id del commento, senza la firma' {
        $c = @(Get-CorrezioniScritte @(New-CommentoCorrezione 12))
        $c.Count | Should -Be 1
        $c[0].Id | Should -Be 12
        $c[0].Tipo | Should -Be 'tecnico'
        $c[0].Titolo | Should -Be 'Il totale non somma'
        $c[0].Descrizione | Should -Be "Il totale ignora le righe scontate.`nAtteso: le somma."
    }

    It 'le legge tutte, nell ordine degli id' {
        $c = @(Get-CorrezioniScritte @((New-CommentoCorrezione 20 'prodotto' 'B'), (New-Commento 21 '[responsabile] altro'), (New-CommentoCorrezione 4 'tecnico' 'A')))
        @($c | ForEach-Object { $_.Titolo }) | Should -Be @('A', 'B')
        @($c | ForEach-Object { $_.Tipo }) | Should -Be @('tecnico', 'prodotto')
    }

    It 'nessuna correzione: elenco vuoto' {
        @(Get-CorrezioniScritte @((New-Commento 1 '[responsabile] criteri scritti'), (New-Commento 2 'una persona'))).Count | Should -Be 0
        @(Get-CorrezioniScritte @()).Count | Should -Be 0
    }

    It 'vale solo se la scrive il responsabile: lo smistatore, dev e le persone non correggono' {
        $corpo = ConvertTo-TestoCommentoCorrezione -Tipo 'tecnico' -Titolo 'T' -Descrizione 'D'
        @(Get-CorrezioniScritte @((New-Commento 1 "[smistatore] $corpo"), (New-Commento 2 "[dev] $corpo"), (New-Commento 3 $corpo))).Count | Should -Be 0
    }

    It 'la riga deve aprire il commento: citata in mezzo a un testo non conta' {
        @(Get-CorrezioniScritte @(New-Commento 1 "[responsabile] ho visto che`nCorrezione: tecnico`nTitolo: T`n`nD")).Count | Should -Be 0
    }

    It 'un tipo diverso da tecnico e prodotto, o senza titolo, non e una correzione' {
        @(Get-CorrezioniScritte @(New-Commento 1 "[responsabile] Correzione: urgente`nTitolo: T`n`nD")).Count | Should -Be 0
        @(Get-CorrezioniScritte @(New-Commento 2 "[responsabile] Correzione: tecnico`n`nD")).Count | Should -Be 0
    }

    It 'si legge anche nel testo html che Azure DevOps puo restituire' {
        $html = '<div><p>[responsabile] Correzione: tecnico</p><p>Titolo: Il totale &amp; lo sconto</p><p>Atteso: le somma.</p></div>'
        $c = @(Get-CorrezioniScritte @(New-Commento 5 $html))
        $c.Count | Should -Be 1
        $c[0].Titolo | Should -Be 'Il totale & lo sconto'
        $c[0].Descrizione | Should -Be 'Atteso: le somma.'
    }
}

# D52, gruppo 5: la firma dei commenti di agente e il commento con cui lo smistatore segna sulla card di chiusura che una Bug esiste.
Describe 'La firma dei commenti e la marca della Bug creata' {
    BeforeAll {
        function New-Commento($Id, [string]$Testo) { [pscustomobject]@{ Id = $Id; Autore = 'x'; Testo = $Testo; Quando = 'd' } }
    }

    It 'la firma ha un posto solo: Get-FirmaCommento, e la correzione la toglie dalla descrizione' {
        Get-FirmaCommento 'responsabile' | Should -Be "$([char]0x2014) scritto da Claude (responsabile)"
        $corpo = ConvertTo-TestoCommentoCorrezione -Tipo 'tecnico' -Titolo 'T' -Descrizione 'D'
        $c = @(Get-CorrezioniScritte @(New-Commento 1 "[responsabile] $corpo`n`n$(Get-FirmaCommento 'responsabile')"))
        $c[0].Descrizione | Should -Be 'D'
    }

    It 'il commento della Bug di una correzione si rilegge: la chiave e l id del commento' {
        $t = ConvertTo-TestoCommentoBugCreata -Tipo 'correzione' -Chiave '55' -Bug 300
        $t | Should -Be 'Correzione #55 -> Bug 300'
        @(Get-BugCreate @(New-Commento 9 "[smistatore] $t") 'correzione') | Should -Be @('55')
    }

    It 'la marca di allinea-develop porta il commit di testa' {
        $t = ConvertTo-TestoCommentoBugCreata -Tipo 'allinea' -Chiave 'c-testa' -Bug 400
        @(Get-BugCreate @(New-Commento 9 "[smistatore] $t") 'allinea') | Should -Be @('c-testa')
        @(Get-BugCreate @(New-Commento 9 "[smistatore] $t") 'correzione').Count | Should -Be 0
    }

    It 'vale solo se la scrive lo smistatore e si apre il commento, anche in html' {
        $t = ConvertTo-TestoCommentoBugCreata -Tipo 'correzione' -Chiave '55' -Bug 300
        @(Get-BugCreate @((New-Commento 1 "[responsabile] $t"), (New-Commento 2 $t), (New-Commento 3 "ho visto`n[smistatore] $t")) 'correzione').Count | Should -Be 0
        @(Get-BugCreate @(New-Commento 4 "<div>[smistatore] Correzione #7 -&gt; Bug 9</div>") 'correzione') | Should -Be @('7')
    }
}

Describe 'Get-ProcessiVistaRadice' {
    BeforeAll {
        $script:Pwsh = {
            @(
                [pscustomobject]@{ ProcessId = 10; ParentProcessId = 1; CommandLine = '"C:\Program Files\PowerShell\pwsh.exe" -NoProfile -File C:/develop/GIT/DevOps.Agents/src/Vista.ps1 -Html -Segui -Apri' }
                [pscustomobject]@{ ProcessId = 11; ParentProcessId = 10; CommandLine = 'pwsh.exe -NoProfile -File C:\develop\GIT\DevOps.Agents\src\Vista.ps1 -Segui -Html' }
                [pscustomobject]@{ ProcessId = 20; ParentProcessId = 1; CommandLine = 'pwsh.exe -NoProfile -File C:\develop\GIT\_wt\DevOps.Agentsltro\src\Vista.ps1 -Html -Segui' }
                [pscustomobject]@{ ProcessId = 21; ParentProcessId = 1; CommandLine = 'pwsh.exe -File D:/C:/develop/GIT/DevOps.Agents/src/Vista.ps1 -Segui' }
                [pscustomobject]@{ ProcessId = 30; ParentProcessId = 1; CommandLine = 'pwsh.exe -File C:/develop/GIT/DevOps.Agents/src/Vista.ps1 -Html' }
                [pscustomobject]@{ ProcessId = 40; ParentProcessId = 1; CommandLine = 'pwsh.exe -File C:/develop/GIT/DevOps.Agents/src/Supervisore.ps1' }
            )
        }
    }
    It 'riconosce entrambe le forme di percorso (/ e \) ed esclude altre radici, la vista senza -Segui e gli altri script' {
        Mock Get-ProcessiPwsh $script:Pwsh -ModuleName Comune
        @(Get-ProcessiVistaRadice 'C:\develop\GIT\DevOps.Agents' | ForEach-Object ProcessId) | Should -Be @(10, 11)
        @(Get-ProcessiVistaRadice 'C:/develop/GIT/DevOps.Agents/' | ForEach-Object ProcessId) | Should -Be @(10, 11)
        @(Get-ProcessiVistaRadice 'C:\develop\GIT\_wt\DevOps.Agentsltro' | ForEach-Object ProcessId) | Should -Be @(20)
    }
    It 'con -DiversiDa non conta ne il processo dato ne i suoi figli diretti' {
        Mock Get-ProcessiPwsh $script:Pwsh -ModuleName Comune
        @(Get-ProcessiVistaRadice 'C:\develop\GIT\DevOps.Agents' -DiversiDa 10) | Should -HaveCount 0
        @(Get-ProcessiVistaRadice 'C:\develop\GIT\DevOps.Agents' -DiversiDa 99 | ForEach-Object ProcessId) | Should -Be @(10, 11)
        @(Get-ProcessiVistaRadice 'C:\develop\GIT\DevOps.Agents' -DiversiDa 11 | ForEach-Object ProcessId) | Should -Be @(10)
    }
}

Describe 'Get-ProcessiSmistatoreRadice (D53): un giro dello smistatore di questa radice in corso' {
    BeforeAll {
        $script:Pwsh = {
            @(
                [pscustomobject]@{ ProcessId = 10; ParentProcessId = 1; CommandLine = 'conhost.exe --headless "C:\Program Files\PowerShell\pwsh.exe" -NoProfile -NonInteractive -File "C:/develop/GIT/DevOps.Agents/src/Smistatore.ps1"' }
                [pscustomobject]@{ ProcessId = 11; ParentProcessId = 1; CommandLine = 'pwsh.exe -NoProfile -File C:\develop\GIT\DevOps.Agents\src\Smistatore.ps1 -WhatIf' }
                [pscustomobject]@{ ProcessId = 20; ParentProcessId = 1; CommandLine = 'pwsh.exe -File C:\develop\GIT\_wt\DevOps.Agentsltro\src\Smistatore.ps1' }
                [pscustomobject]@{ ProcessId = 30; ParentProcessId = 1; CommandLine = 'pwsh.exe -File C:/develop/GIT/DevOps.Agents/src/Supervisore.ps1' }
                [pscustomobject]@{ ProcessId = 31; ParentProcessId = 1; CommandLine = 'pwsh.exe -File C:/develop/GIT/DevOps.Agents/src/Vista.ps1 -Segui' }
            )
        }
    }
    It 'riconosce lo smistatore di questa radice (in entrambe le forme di percorso) e non il supervisore, la vista o un altra radice' {
        Mock Get-ProcessiPwsh $script:Pwsh -ModuleName Comune
        @(Get-ProcessiSmistatoreRadice 'C:\develop\GIT\DevOps.Agents' | ForEach-Object ProcessId) | Should -Be @(10, 11)
        @(Get-ProcessiSmistatoreRadice 'C:/develop/GIT/DevOps.Agents/' | ForEach-Object ProcessId) | Should -Be @(10, 11)
        @(Get-ProcessiSmistatoreRadice 'C:\develop\GIT\_wt\DevOps.Agentsltro' | ForEach-Object ProcessId) | Should -Be @(20)
    }
    It 'Get-ProcessiVistaRadice continua a trovare solo la vista con -Segui dopo la generalizzazione' {
        Mock Get-ProcessiPwsh $script:Pwsh -ModuleName Comune
        @(Get-ProcessiVistaRadice 'C:\develop\GIT\DevOps.Agents' | ForEach-Object ProcessId) | Should -Be @(31)
    }
}

Describe 'La descrizione della PR salvata sulla card' {
    BeforeAll {
        function New-CommDescr($Id, [string]$Ruolo, [string]$Testo) {
            [pscustomobject]@{ Id = $Id; Autore = 'x'; Quando = 'd'
                Testo = "[$Ruolo] $(ConvertTo-TestoCommentoDescrizionePr $Testo)`n`n$([char]0x2014) scritto da Claude ($Ruolo)" }
        }
    }

    It 'si rilegge come si scrive, senza marca ne firma' {
        Get-DescrizionePrSalvata @(New-CommDescr 3 'dev' "## Misure`nrighe  e perché") | Should -Be "## Misure`nrighe  e perché"
    }

    It 'vale l ultimo, nell ordine degli id, e solo di dev e responsabile' {
        $c = @((New-CommDescr 9 'dev' 'secondo'), (New-CommDescr 4 'responsabile' 'primo'), (New-CommDescr 12 'reviewer' 'intruso'),
            [pscustomobject]@{ Id = 13; Testo = 'Descrizione della PR: di una persona' })
        Get-DescrizionePrSalvata $c | Should -Be 'secondo'
    }

    It 'senza commenti marcati: niente' {
        Get-DescrizionePrSalvata @([pscustomobject]@{ Id = 1; Testo = '[dev] altro' }) | Should -BeNullOrEmpty
    }
}
