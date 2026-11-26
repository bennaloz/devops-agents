BeforeAll {
    # D53: Get-Config e Get-ConfigSupervisore leggono impostazioni.json dalla cartella dati: i test non devono vedere quella vera di chi li lancia.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    # I moduli si caricano prima, nello stesso modo dello script, cosi i Mock trovano i comandi da sostituire.
    foreach ($m in 'Config', 'Ado', 'Stato', 'Decisioni', 'Sessioni', 'Memoria', 'MemoriaRepo') {
        Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Global
    }
    $script:Script = Join-Path $PSScriptRoot '../src/Vista.ps1'
    . (Join-Path $PSScriptRoot 'finti/Radice.ps1')
    $script:Cfg = Get-Config
    $script:Area = 'DevOps.Agents\AI\Stime'   # l'area che sta in config/mappa.json

    function St([string]$Chiave) { $script:Cfg.Stati.$Chiave }

    function New-FintaCard($Id, [string]$Chiave, $Tag = $null, $Assegnata = 'u-ric') {
        if ($null -eq $Tag) { $Tag = @($script:Cfg.Stati.tagAgenti) }
        [pscustomobject]@{
            Id = [int]$Id; Rev = 10; Tipo = 'User Story'; Titolo = "Titolo della card $Id"; Descrizione = 'd'; Criteri = 'c'
            Stato = (St $Chiave); Tag = @($Tag); Area = $script:Area; CreataDa = [pscustomobject]@{ Id = 'u-rich'; Nome = 'Richiedente' }
            AssegnataA = $(if ($Assegnata) { [pscustomobject]@{ Id = $Assegnata; Nome = "Nome di $Assegnata" } } else { $null })
            ConsumoTotale = [int64]0; MinutiAgente = [int64]0
        }
    }
    function New-FintaStoria([string]$Chiave) {
        @(
            [pscustomobject]@{ Rev = 1; Da = $null; A = (St 'bozza'); Chi = 'u-ric'; ChiNome = 'x'; Quando = '2026-11-01T08:00:00Z' }
            [pscustomobject]@{ Rev = 20; Da = (St 'bozza'); A = (St $Chiave); Chi = 'u-ric'; ChiNome = 'x'; Quando = '2026-11-01T09:00:00Z' }
        )
    }
    function Set-StatoDiPartenza($Dati, $Voci) {
        $st = @{}
        foreach ($k in $Voci.Keys) {
            $v = Get-StatoCard -Stato $st -Id ([int]$k)
            foreach ($c in $Voci[$k].Keys) { $v[$c] = $Voci[$k][$c] }
        }
        [IO.File]::WriteAllText((Join-Path $Dati 'stato.json'), ($st | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))   # non Save-Stato: nei test e' un Mock
    }
    function New-SessioneInCorso([string]$Ruolo = 'dev', [string]$Id = 'sid-1', $Task = $null, [int]$Minuti = 12) {
        @{ id = $Id; pid = 4242; avvio = '2026-11-16T08:00:00.0000000Z'; ruolo = $Ruolo; inizio = (Get-Date).ToUniversalTime().AddMinutes(-$Minuti).ToString('o')
           ripresa = $false; cartella = 'C:/x'; modello = 'opus'; sforzo = 'high'; task = $Task }
    }
    function New-Riga($Id, $Contenuto, $Usage = $null) {
        $m = [ordered]@{ id = $Id; role = 'assistant'; content = @($Contenuto) }
        if ($Usage) { $m.usage = $Usage }
        ([ordered]@{ type = 'assistant'; message = $m } | ConvertTo-Json -Depth 10 -Compress)
    }
    function New-Uso([string]$Nome, $Parametri) { [ordered]@{ type = 'tool_use'; id = "t-$Nome"; name = $Nome; input = $Parametri } }
    function Set-Uscita($Dati, [string]$Id, [string[]]$Righe) {
        $d = Join-Path $Dati 'sessioni'
        if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null }
        [IO.File]::WriteAllText((Join-Path $d "$Id.jsonl"), (($Righe -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    }
    function Set-LogDiOggi($Dati, [string[]]$Righe) {
        $d = Join-Path $Dati 'log'
        New-Item -ItemType Directory $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d ('smistatore-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))), (($Righe -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    }
    # L'html di una colonna della kanban (agente, operatore, pipeline): le colonne non annidano altre section.
    function Get-Colonna([string]$Html, [string]$Nome) {
        $m = [regex]::Match($Html, "(?s)<section class=""colonna[^""]*"" data-colonna=""$Nome"">.*?</section>")
        if (-not $m.Success) { throw "colonna $Nome non trovata" }
        $m.Value
    }
    # La sezione Apprendimento della pagina (non annida altri details).
    function Get-SezioneApprendimento([string]$Html) {
        $m = [regex]::Match($Html, '(?s)<section class="apprendimento"[^>]*>.*?</section>')
        if (-not $m.Success) { throw 'sezione Apprendimento non trovata' }
        $m.Value
    }
    function Invoke-Vista { param($Dati, [hashtable]$Parametri = @{}) & $script:Script -CartellaDati $Dati @Parametri *>&1 | Out-String }
    # supervisore.json come lo scrive il supervisore (Save-Stato e un Mock nei test: si scrive il file a mano).
    function Set-SupervisoreDiPartenza($Dati, [hashtable]$Contenuto) {
        [IO.File]::WriteAllText((Join-Path $Dati 'supervisore.json'), ($Contenuto | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    }
    # Il contenuto di tutti i file della cartella dati, per vedere che la vista non ne cambia nemmeno uno.
    function Get-Impronta($Dati) {
        @(Get-ChildItem $Dati -Recurse -File | Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$((Get-FileHash $_.FullName).Hash)" })
    }
}

Describe 'Vista: cosa fanno gli agenti' {
    BeforeEach {
        $script:Dati = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:Dati | Out-Null
        $global:Mondo = @{ Cards = @(); Commenti = @{}; Storia = @{}; Pr = @{}; Task = @{}; Predecessori = @{} }
        Mock Get-AdoUtenteCorrente { [pscustomobject]@{ Id = 'u-ric'; Nome = 'Titolare' } }
        # come la query vera (Get-AdoCardAttive): le card in Draft non ci sono
        Mock Get-AdoCardAttive { @($global:Mondo.Cards | Where-Object { $_.Stato -ne 'Draft' }) }
        Mock Get-AdoCard { param($Id) $global:Mondo.Cards | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
        Mock Get-AdoCommenti { param($Id, $DopoId = 0) @() }
        Mock Get-AdoStoriaStato { param($Id) @($global:Mondo.Storia["$Id"]) }
        Mock Get-AdoTaskFigli { param($CardId) @($global:Mondo.Task["$CardId"] | Where-Object { $null -ne $_ }) }
        Mock Get-AdoCardPredecessori { param($CardId) @($global:Mondo.Predecessori["$CardId"] | Where-Object { $null -ne $_ }) }
        Mock Get-AdoPr { param($Progetto, $Repo, $Ramo, [switch]$AncheCompletate) $global:Mondo.Pr[$Ramo] }
        Mock Get-AdoRun { $null }
        Mock Get-AdoBuildPipeline { if ($global:Mondo.ContainsKey('BuildErrore')) { throw $global:Mondo.BuildErrore }; $global:Mondo.Build }
        Mock Test-SessioneViva { $true }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ NextRunTime = [datetime]'2026-11-18T10:04:00' } }
        # Tutto cio che scriverebbe da qualche parte: la vista non deve mai chiamarlo.
        Mock Set-AdoCard { 55 }
        Mock Add-AdoCommento { 900 }
        Mock New-AdoPr { 77 }
        Mock Set-AdoTaskStato { 1 }
        Mock Start-SessioneRuolo { [pscustomobject]@{ Id = 'x'; Pid = 1; Avvio = 'x'; Ripresa = $false } }
        Mock Stop-Sessione { }
        Mock Save-Stato { }
        Mock Write-RegistroSessione { }
        Mock Add-RevNostra { }
        # La memoria dei ruoli e git piu Azure DevOps e il registro un file: di default niente, cosi nessun test li tocca davvero.
        Mock Get-MemoriaDelRuolo { [pscustomobject]@{ Ruolo = $Ruolo; Repo = $Repo; Disponibile = $true; InProvaUsato = $false; Motivi = @(); File = @() } }
        Mock Get-RigheApprendimento { }
    }

    Context 'In corso' {
        BeforeEach {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            $global:Mondo.Task['5'] = @([pscustomobject]@{ Id = 55; Titolo = 'Scrivere il parser'; Stato = 'Active'; Tipo = 'Task' })
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1' 55); ultimoRuolo = 'dev'; ramo = 'feature/5-x'; cartella = 'C:/x' } }
        }

        It 'mostra card, titolo, repo, ruolo, task, minuti, processo vivo e token' {
            $u = @{ input_tokens = 100; output_tokens = 200; cache_read_input_tokens = 3000; cache_creation_input_tokens = 0 }
            Set-Uscita $script:Dati 'sid-1' @((New-Riga 'm1' (New-Uso 'Read' @{ file_path = 'C:/repo/a.ps1' }) $u))
            $out = Invoke-Vista $script:Dati
            $out | Should -Match 'In corso'
            $out | Should -Match '#5 Titolo della card 5'
            $out | Should -Match 'Acme\.AI'
            $out | Should -Match 'dev'
            $out | Should -Match 'task 55 .Scrivere il parser.'
            $out | Should -Match '12 min'
            $out | Should -Match 'processo vivo'
            $out | Should -Match '3[.,]3k token'
        }

        It 'riassume le ultime 5 azioni: strumento con descrizione, file_path, prima riga del comando' {
            $righe = @(
                (New-Riga 'm0' (New-Uso 'Read' @{ file_path = 'C:/vecchia.txt' }))
                (New-Riga 'm1' (New-Uso 'Bash' @{ command = 'npm test'; description = 'Lancia i test' }))
                (New-Riga 'm2' (New-Uso 'Read' @{ file_path = 'C:/repo/src/a.ps1' }))
                (New-Riga 'm3' (New-Uso 'Bash' @{ command = "git status`ngit diff --stat" }))
                (New-Riga 'm4' (New-Uso 'Edit' @{ file_path = 'C:/repo/src/b.ps1' }))
                (New-Riga 'm5' (New-Uso 'Grep' @{ pattern = 'x' })))
            Set-Uscita $script:Dati 'sid-1' $righe
            $out = Invoke-Vista $script:Dati
            $out | Should -Match 'Bash: Lancia i test'
            $out | Should -Match 'Read: C:/repo/src/a\.ps1'
            $out | Should -Match 'Bash: git status'
            $out | Should -Not -Match 'git diff'
            $out | Should -Match 'Edit: C:/repo/src/b\.ps1'
            $out | Should -Match '(?m)^\s+- Grep\s*$'
            $out | Should -Not -Match 'vecchia\.txt'
        }

        It 'con il processo morto lo dice' {
            Mock Test-SessioneViva { $false }
            $out = Invoke-Vista $script:Dati
            $out | Should -Match 'processo non attivo'
            $out | Should -Not -Match 'processo vivo'
        }

        It 'senza uscita leggibile la card si vede lo stesso, senza azioni ne token' {
            $out = Invoke-Vista $script:Dati
            $out | Should -Match '#5 Titolo della card 5'
            $out | Should -Not -Match 'token'
        }

        It 'la card in corso non compare fra quelle in coda' {
            $out = Invoke-Vista $script:Dati
            ($out -split "`n" | Where-Object { $_ -match '#5 ' }).Count | Should -Be 1
        }
    }

    Context 'In coda / ferme: il motivo e quello che decide lo smistatore' {
        It 'on-hold, e compare anche in Da fare tu' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagAttesa))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'sessione'; ultimoRuolo = 'dev' } }
            $out = Invoke-Vista $script:Dati
            $coda = ($out -split '(?m)^== ')[2]
            $fare = ($out -split '(?m)^== ')[3]
            $coda | Should -Match '#5 .*in on-hold, togliendo il tag si riprende la sessione'
            $fare | Should -Match '#5 .*in on-hold'
        }

        It 'in attesa di card precedenti: dice quali' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inRevisione'), (New-FintaCard 6 'pronto'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'; $global:Mondo.Storia['6'] = New-FintaStoria 'pronto'
            $global:Mondo.Predecessori['6'] = @([pscustomobject]@{ Id = 5; Stato = (St 'inRevisione') })
            $out = Invoke-Vista $script:Dati
            $out | Should -Match '#6 .*aspetta le card precedenti non ancora unite: #5 \(In review\)'
        }

        It 'posto occupato dal limite di sessioni: dice da quale card' {
            $global:Mondo.Cards = @((New-FintaCard 9 'inSviluppo'), (New-FintaCard 6 'nuova'))
            $global:Mondo.Storia['9'] = New-FintaStoria 'inSviluppo'; $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            Set-StatoDiPartenza $script:Dati @{ '9' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-9'); ultimoRuolo = 'dev' } }
            $out = Invoke-Vista $script:Dati @{ Radice = (New-RadiceDiProva -Cartella $TestDrive -Limiti @{ sessioniAttive = 1 }) }
            $out | Should -Match '#6 .*in coda, posto occupato \(sessioni attive 1/1: card 9\)'
        }

        It 'limite per repo: dice quale card e gia in sviluppo' {
            $global:Mondo.Cards = @((New-FintaCard 8 'inSviluppo'), (New-FintaCard 6 'pronto'))
            $global:Mondo.Storia['8'] = New-FintaStoria 'inSviluppo'; $global:Mondo.Storia['6'] = New-FintaStoria 'pronto'
            $out = Invoke-Vista $script:Dati
            $out | Should -Match '#6 .*in coda, un altra card e in sviluppo su Acme\.AI \(1/1: card 8\)'
        }

        It 'una card che puo partire e pronta al prossimo giro' {
            $global:Mondo.Cards = @(New-FintaCard 6 'nuova')
            $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            Invoke-Vista $script:Dati | Should -Match '#6 .*pronta al prossimo giro'
        }

        It 'la quota si legge dalla cartella dati della vista, non da quella predefinita' {
            # una quota oltre la riserva nella cartella predefinita (ATTREZZI_DATI) non deve contare: la vista ha la sua cartella
            $predefinita = Join-Path $TestDrive 'dati-predefiniti'
            New-Item -ItemType Directory -Force $predefinita | Out-Null
            $oltre = @{ sevenDay = @{ utilization = 0.95; resetsAt = '2099-01-01T00:00:00Z' } } | ConvertTo-Json
            Set-Content (Join-Path $predefinita 'quota.json') $oltre
            $prima = $env:ATTREZZI_DATI
            try {
                $env:ATTREZZI_DATI = $predefinita
                $global:Mondo.Cards = @(New-FintaCard 6 'nuova')
                $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
                Invoke-Vista $script:Dati | Should -Match '#6 .*pronta al prossimo giro'
                # la stessa quota nella cartella della vista invece ferma la card
                Set-Content (Join-Path $script:Dati 'quota.json') $oltre
                Invoke-Vista $script:Dati | Should -Match '#6 .*riserva settimanale raggiunta'
            }
            finally { $env:ATTREZZI_DATI = $prima; Remove-Item (Join-Path $script:Dati 'quota.json') -ErrorAction SilentlyContinue }
        }

        It 'il mentore non muove la card: con solo un LanciaMentore la riga non e pronta al prossimo giro' {
            # In Deploying to test con il deploy in corso la card non ha azioni; il commento di una persona fa solo partire il mentore.
            $global:Mondo.Cards = @(New-FintaCard 6 'inDeployTest')
            $global:Mondo.Storia['6'] = New-FintaStoria 'inDeployTest'
            # la revisione e superata (senza, la card tornerebbe indietro): il deploy in corso e l'unica cosa che aspetta
            Set-StatoDiPartenza $script:Dati @{ '6' = @{ runId = 9; runDopoRev = 20; ramo = 'feature/6-x'; cartella = 'C:/x'; ultimoRuolo = 'reviewer'
                ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-02T10:00:00Z' }; reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-03T10:00:00Z' } } } }
            Mock Get-AdoRun { [pscustomobject]@{ Stato = 'inProgress'; Esito = $null } }
            Mock Get-AdoCommenti { param($Id, $DopoId = 0) @([pscustomobject]@{ Id = 51; Autore = 'Anna'; Testo = 'Cosi non va'; Quando = '2026-11-02T10:00:00Z' }) }
            $out = Invoke-Vista $script:Dati
            $out | Should -Match '#6 '
            $out | Should -Not -Match '#6 .*pronta al prossimo giro'
        }

        It 'la riga della coda dice a quale ruolo andra la card' {
            $global:Mondo.Cards = @((New-FintaCard 8 'inSviluppo'), (New-FintaCard 6 'pronto'), (New-FintaCard 7 'nuova'))
            $global:Mondo.Storia['8'] = New-FintaStoria 'inSviluppo'; $global:Mondo.Storia['6'] = New-FintaStoria 'pronto'; $global:Mondo.Storia['7'] = New-FintaStoria 'nuova'
            $out = Invoke-Vista $script:Dati
            $out | Should -Match '#6 .*\(Ready to develop\) \S+ dev: in coda, un altra card'
            $out | Should -Match '#7 .*\(New\) \S+ responsabile: pronta al prossimo giro'
        }

        It 'una card che aspetta un evento non ha azioni previste' {
            # in Releasing: le card in Draft non le legge nessuno (Get-AdoCardAttive le scarta)
            $global:Mondo.Cards = @(New-FintaCard 6 'inRilascio')
            $global:Mondo.Storia['6'] = New-FintaStoria 'inRilascio'
            Invoke-Vista $script:Dati | Should -Match '#6 .*nessuna azione prevista'
        }

        It 'le card di un altro assegnatario non compaiono' {
            $global:Mondo.Cards = @(New-FintaCard 6 'nuova' -Assegnata 'u-collega')
            $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            Invoke-Vista $script:Dati | Should -Not -Match '#6 '
        }
    }

    Context 'Da fare tu' {

        It 'revisione superata: passa da sola In Deploying to test, quindi non e piu un gesto da fare e non compare in Da fare tu' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ avvisi = @('revisioneSuperata@20'); ultimoRuolo = 'reviewer' } }
            $fare = ((Invoke-Vista $script:Dati) -split '(?m)^== ')[3]
            $fare | Should -Not -Match '#5 '
            $fare | Should -Not -Match 'via al deploy in Test'
        }

        It 'In review con la revisione superata e il posto in Test occupato: in coda con il motivo, non fra le cose da fare' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inRevisione'), (New-FintaCard 8 'inCollaudo'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'; $global:Mondo.Storia['8'] = New-FintaStoria 'inCollaudo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } } }
            $out = Invoke-Vista $script:Dati
            $out | Should -Match '#5 .*in coda, un altra card dello stesso componente e in Test \(stime, 1/1: card 8\)'
            (($out) -split '(?m)^== ')[3] | Should -Not -Match '#5 '
        }

        It 'Da fare tu nel terminale ha il verbo di ogni attivita, anche Rilascia e Rispondi' {
            $global:Mondo.Cards = @((New-FintaCard 5 'daChiarire'), (New-FintaCard 7 'daRilasciare'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'daChiarire'; $global:Mondo.Storia['7'] = New-FintaStoria 'daRilasciare'
            Set-StatoDiPartenza $script:Dati @{ '7' = @{ prId = 77 } }
            $fare = ((Invoke-Vista $script:Dati) -split '(?m)^== ')[3]
            $fare | Should -Match '#5 .*: Rispondi - '
            $fare | Should -Match '#7 .*: Rilascia - '
        }

        It 'verifica in Test riuscita: aspetta la tua verifica' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inProvaUmana')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inProvaUmana'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ avvisi = @('testPronto@20'); ultimoRuolo = 'reviewer' } }
            $fare = ((Invoke-Vista $script:Dati) -split '(?m)^== ')[3]
            $fare | Should -Match '#5 .*la card aspetta la tua verifica'
        }

        It 'un avviso di un ingresso precedente non conta' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inProvaUmana')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inProvaUmana'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ avvisi = @('testPronto@3'); ultimoRuolo = 'reviewer' } }
            $fare = ((Invoke-Vista $script:Dati) -split '(?m)^== ')[3]
            $fare | Should -Not -Match '#5 '
        }

        It 'card in Test con il deploy riuscito e l avviso dato: in coda dice che aspetta la prova del richiedente' {
            Mock Get-AdoRun { [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded' } }
            $global:Mondo.Cards = @(New-FintaCard 5 'inProvaUmana' -Tag @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagProvaUmana))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inProvaUmana'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; runId = 300; runDopoRev = 20; avvisi = @('testPronto@20'); ultimoRuolo = 'reviewer'
                ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } } }
            $out = Invoke-Vista $script:Dati
            $out | Should -Match '#5 .*\(Human test\): aspetta la prova in Test del richiedente'
            $out | Should -Not -Match 'aspetta un tuo gesto'
        }
    }

    Context 'Ultima riga e Azure DevOps che non risponde' {
        It 'mostra l ora dell ultimo giro dal log di oggi e il prossimo della pianificazione' {
            Set-LogDiOggi $script:Dati @('2026-11-18 10:00:01 INFO card 4: qualcosa', '2026-11-18 10:02:03 INFO card 5: lanciata la sessione x')
            $out = Invoke-Vista $script:Dati
            $out | Should -Match 'Ultimo giro dello smistatore: 2026-11-18 10:02:03 \| prossimo giro: 2026-11-18 10:04'
        }

        It 'senza log e senza pianificazione lo dice senza fallire' {
            Mock Get-ScheduledTaskInfo { throw 'non c e' }
            $out = Invoke-Vista $script:Dati
            $out | Should -Match 'Ultimo giro dello smistatore: nessun log di oggi \| prossimo giro: non leggibile'
        }

        It 'se Azure DevOps non risponde mostra la parte locale con un avviso' {
            Mock Get-AdoCardAttive { throw 'Chiamata ad Azure DevOps fallita' }
            Mock Get-AdoUtenteCorrente { throw 'Chiamata ad Azure DevOps fallita' }
            $global:Mondo.Cards = @()
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev' } }
            Set-Uscita $script:Dati 'sid-1' @((New-Riga 'm1' (New-Uso 'Read' @{ file_path = 'C:/a' })))
            $out = Invoke-Vista $script:Dati
            $out | Should -Match 'Azure DevOps non risponde'
            $out | Should -Match '#5'
            $out | Should -Match 'Read: C:/a'
            $out | Should -Match 'processo vivo'
        }
    }

    Context 'Pagina HTML' {
        BeforeEach { $script:Pagina = Join-Path $script:Dati 'vista.html' }

        It 'scrive vista.html con le colonne, i titoli delle card e il meta refresh' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inSviluppo'), (New-FintaCard 6 'nuova'), (New-FintaCard 7 'inProvaUmana'))
            foreach ($i in 5, 6, 7) { $global:Mondo.Storia["$i"] = New-FintaStoria @{ 5 = 'inSviluppo'; 6 = 'nuova'; 7 = 'inProvaUmana' }[$i] }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev' }; '7' = @{ avvisi = @('testPronto@20'); ultimoRuolo = 'reviewer' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            Test-Path $script:Pagina | Should -BeTrue
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match 'Titolo della card 5'
            $h | Should -Match 'Titolo della card 6'
            $h | Should -Match 'Titolo della card 7'
            $h | Should -Match '<meta http-equiv="refresh" content="10">'
            $h | Should -Match 'Acme\.AI'
            $h | Should -Match 'processo vivo'
        }

        It 'la riga quota e il banner nascono dal quota.json della cartella dati (e dal bypass di soglia-quota.json)' {
            $q = @{ sevenDay = @{ utilization = 0.90; resetsAt = [datetime]::UtcNow.AddDays(2).ToString('o') } }
            # Save-Stato e un Mock in questa suite: i file si scrivono a mano
            [IO.File]::WriteAllText((Join-Path $script:Dati 'quota.json'), ($q | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match 'Quota settimanale: <b>90%</b> usata'
            $h | Should -Match 'riserva non ignorata'
            $h | Should -Match '<div class="banner-quota" role="alert" data-causa="riserva">'
            $o = @{ soglia = $null; ignoraRiserva = $true; fino = $q.sevenDay.resetsAt; impostata = [datetime]::UtcNow.ToString('o') }
            [IO.File]::WriteAllText((Join-Path $script:Dati 'soglia-quota.json'), ($o | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match 'riserva ignorata fino al'
            $h | Should -Not -Match '<div class="banner-quota"'
        }

        It 'l ufficio usa la stessa quota della vista: con la soglia alzata (soglia-quota.json) sopra la soglia di config non e in pausa' {
            $q = @{ sevenDay = @{ utilization = 0.90; resetsAt = [datetime]::UtcNow.AddDays(2).ToString('o') } }
            [IO.File]::WriteAllText((Join-Path $script:Dati 'quota.json'), ($q | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $m = Get-Content (Join-Path $script:Dati 'ufficio.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $m.quota.stato | Should -Be 'riserva'
            $o = @{ soglia = 0.95; ignoraRiserva = $false; fino = $q.sevenDay.resetsAt; impostata = [datetime]::UtcNow.ToString('o') }
            [IO.File]::WriteAllText((Join-Path $script:Dati 'soglia-quota.json'), ($o | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $m = Get-Content (Join-Path $script:Dati 'ufficio.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $m.quota.stato | Should -Be 'libera'
            $m.quota.soglia | Should -Be 0.95
            $m.quota.alzata | Should -BeTrue
        }

        It 'l ufficio dice di quale finestra e la pausa per il limite: con il limite delle 5 ore non mostra la soglia settimanale' {
            $q = @{ sevenDay = @{ utilization = 0.27; resetsAt = [datetime]::UtcNow.AddDays(3).ToString('o') }; fiveHour = @{ utilization = 1.0; resetsAt = [datetime]::UtcNow.AddHours(2).ToString('o') }
                    pausaFino = [datetime]::UtcNow.AddHours(3).ToString('o'); finestraPausa = 'five_hour' }
            [IO.File]::WriteAllText((Join-Path $script:Dati 'quota.json'), ($q | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $m = Get-Content (Join-Path $script:Dati 'ufficio.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $m.quota.stato | Should -Be 'limite'
            $m.quota.finestra | Should -Be 'cinqueOre'
            $m.quota.usoFinestra | Should -Be 1.0
        }

        It 'e una pagina autonoma: niente JavaScript, niente risorse esterne, colori su :root e tema scuro' {
            $global:Mondo.Cards = @(New-FintaCard 6 'nuova'); $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Not -Match '<script[^>]*\ssrc'
            # le risorse (src, link, stylesheet) non escono; i link <a> alle card su Azure DevOps si
            $h | Should -Not -Match '<(?!a[\s>])[^>]*(src|href)\s*=\s*"https?:'
            $h | Should -Not -Match '@import|url\('
            $h | Should -Match ':root\s*\{'
            $h | Should -Match 'prefers-color-scheme:\s*dark'
            $h | Should -Match 'name="viewport"'
        }

        It 'il testo che viene da ADO e dalle sessioni e escapato' {
            $c = New-FintaCard 5 'inSviluppo'; $c.Titolo = 'Fix <script>alert(1)</script> & co'
            $global:Mondo.Cards = @($c, (New-FintaCard 6 'nuova'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'; $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev' } }
            Set-Uscita $script:Dati 'sid-1' @((New-Riga 'm1' (New-Uso 'Bash' @{ command = 'echo "<img src=x onerror=1>" && ls' })))
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Not -Match '<script>alert'
            $h | Should -Not -Match '<img'
            $h | Should -Match 'Fix &lt;script&gt;alert\(1\)&lt;/script&gt; &amp; co'
            $h | Should -Match '&lt;img src=x onerror=1&gt;'
        }

        It 'ogni scheda di sessione ha il link segui alla sua pagina, in una nuova scheda' {
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev' } }
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo'); $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '<a class="segui" href="sessione-sid-1\.html" target="_blank" rel="noopener">segui</a>'
        }

        Context 'Il brief di ogni ruolo' {
            BeforeEach {
                $script:Rad = New-RadiceDiProva -Cartella $TestDrive
                $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo'); $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            }

            It 'scrive una pagina brief-<ruolo>.html per ogni ruolo di ruoli.json' {
                Invoke-Vista $script:Dati @{ Html = $true; Radice = $script:Rad } | Out-Null
                foreach ($r in 'responsabile', 'dev', 'reviewer', 'collaudatore') { Test-Path (Join-Path $script:Dati "brief-$r.html") | Should -BeTrue -Because $r }
            }

            It 'converte il Markdown in HTML e mostra nome del ruolo e percorso, con lo stile della vista e senza ricaricamento' {
                Set-Content (Join-Path $script:Rad 'ruoli/dev.md') "# Titolo del brief`n`nUn testo con <b>tag</b>." -Encoding UTF8
                Invoke-Vista $script:Dati @{ Html = $true; Radice = $script:Rad } | Out-Null
                $h = Get-Content (Join-Path $script:Dati 'brief-dev.html') -Raw -Encoding UTF8
                $h | Should -Match '<h1'
                $h | Should -Match 'Titolo del brief'
                $h | Should -Match 'ruoli/dev\.md'
                $h | Should -Match '--sfondo'
                $h | Should -Match 'prefers-color-scheme: dark'
                $h | Should -Not -Match 'http-equiv="refresh"'
            }

            It 'mette il link brief nell''intestazione di ogni colonna di agente' {
                Invoke-Vista $script:Dati @{ Html = $true; Radice = $script:Rad } | Out-Null
                $h = Get-Content $script:Pagina -Raw -Encoding UTF8
                foreach ($r in 'responsabile', 'dev', 'reviewer', 'collaudatore') {
                    (Get-Colonna $h $r) | Should -Match "(?s)<h2>.*?<a class=`"brief`" href=`"brief-$r\.html`" target=`"_blank`" rel=`"noopener`">brief</a>" -Because $r
                }
            }

            It 'senza un brief leggibile non c''e il link per quel ruolo, la pagina non si scrive e la vista non si ferma' {
                $f = Join-Path $script:Rad 'config/ruoli.json'
                (Get-Content $f -Raw).Replace('"ruoli/dev.md"', '"ruoli"') | Set-Content $f   # una cartella: esiste per Get-Config ma non si converte
                { Invoke-Vista $script:Dati @{ Html = $true; Radice = $script:Rad } } | Should -Not -Throw
                $h = Get-Content $script:Pagina -Raw -Encoding UTF8
                (Get-Colonna $h 'dev') | Should -Not -Match 'brief-dev'
                (Get-Colonna $h 'reviewer') | Should -Match 'brief-reviewer\.html'
                Test-Path (Join-Path $script:Dati 'brief-dev.html') | Should -BeFalse
            }

            It 'non riscrive la pagina piu recente del file e la riscrive se il file cambia' {
                Invoke-Vista $script:Dati @{ Html = $true; Radice = $script:Rad } | Out-Null
                $p = Join-Path $script:Dati 'brief-dev.html'
                Set-Content $p 'SENTINELLA'
                (Get-Item $p).LastWriteTime = (Get-Date).AddMinutes(5)
                Invoke-Vista $script:Dati @{ Html = $true; Radice = $script:Rad } | Out-Null
                (Get-Content $p -Raw) | Should -Match 'SENTINELLA'
                (Get-Item (Join-Path $script:Rad 'ruoli/dev.md')).LastWriteTime = (Get-Date).AddMinutes(10)
                Invoke-Vista $script:Dati @{ Html = $true; Radice = $script:Rad } | Out-Null
                (Get-Content $p -Raw) | Should -Not -Match 'SENTINELLA'
            }
        }

        It 'scrive una pagina sessione-<id>.html per ogni sessione in corso, con lo stream codificato e il ricaricamento' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inSviluppo'), (New-FintaCard 8 'inRevisione'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'; $global:Mondo.Storia['8'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{
                '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1' 55); ultimoRuolo = 'dev' }
                '8' = @{ sessione = (New-SessioneInCorso 'reviewer' 'sid-8'); ultimoRuolo = 'reviewer' } }
            $u = @{ input_tokens = 100; output_tokens = 200; cache_read_input_tokens = 3000; cache_creation_input_tokens = 0 }
            Set-Uscita $script:Dati 'sid-1' @(
                (New-Riga 'm1' @{ type = 'text'; text = 'Penso a <script>alert(1)</script>' } $u)
                (New-Riga 'm2' (New-Uso 'Bash' @{ command = 'echo "<img src=x onerror=1>"' }))
                ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = 't'; content = '<b>uscita</b>' }) } } | ConvertTo-Json -Depth 10 -Compress)
                '{"type":"result","subtype":"success","is_error":false,"result":"Finito <i>bene</i>"}')
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            Test-Path (Join-Path $script:Dati 'sessione-sid-1.html') | Should -BeTrue
            Test-Path (Join-Path $script:Dati 'sessione-sid-8.html') | Should -BeTrue
            $h = Get-Content (Join-Path $script:Dati 'sessione-sid-1.html') -Raw -Encoding UTF8
            $h | Should -Match '<meta http-equiv="refresh" content="10">'
            $h | Should -Match 'Titolo della card 5'
            $h | Should -Match 'task <b>55</b>'
            $h | Should -Match '3[.,]3k token'
            $h | Should -Match 'Penso a &lt;script&gt;alert\(1\)&lt;/script&gt;'
            $h | Should -Match '&lt;img src=x onerror=1&gt;'
            $h | Should -Match '&lt;b&gt;uscita&lt;/b&gt;'
            $h | Should -Match 'Finito &lt;i&gt;bene&lt;/i&gt;'
            $h | Should -Not -Match '<script>alert'
            $h | Should -Not -Match '<img'
            # l'unico script e quello dello scorrimento
            @([regex]::Matches($h, '<script>')).Count | Should -Be 1
            Get-ChildItem $script:Dati -Recurse -Filter '*.tmp' | Should -BeNullOrEmpty
        }

        It 'cancella le pagine sessione-*.html piu vecchie di 7 giorni e solo quelle' {
            Set-StatoDiPartenza $script:Dati @{ '6' = @{ ultimoRuolo = 'dev' } }
            $global:Mondo.Cards = @(New-FintaCard 6 'nuova'); $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            $vecchia = Join-Path $script:Dati 'sessione-vecchia.html'; $recente = Join-Path $script:Dati 'sessione-recente.html'
            $altro = Join-Path $script:Dati 'altro-vecchio.html'
            foreach ($f in $vecchia, $recente, $altro) { Set-Content $f 'x' }
            (Get-Item $vecchia).LastWriteTime = (Get-Date).AddDays(-8)
            (Get-Item $altro).LastWriteTime = (Get-Date).AddDays(-30)
            (Get-Item $recente).LastWriteTime = (Get-Date).AddDays(-6)
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            Test-Path $vecchia | Should -BeFalse
            Test-Path $recente | Should -BeTrue
            Test-Path $altro | Should -BeTrue
        }

        It 'senza -Html non scrive nessuna pagina sessione' {
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev' } }
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo'); $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Invoke-Vista $script:Dati | Out-Null
            Get-ChildItem $script:Dati -Filter 'sessione-*.html' | Should -BeNullOrEmpty
        }

        It 'scrive solo vista.html e le pagine dei brief: il file temporaneo dell atomica non resta' {
            $global:Mondo.Cards = @(New-FintaCard 6 'nuova'); $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            Set-StatoDiPartenza $script:Dati @{ '6' = @{ ultimoRuolo = 'dev' } }
            $prima = Get-Impronta $script:Dati
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $dopo = Get-Impronta $script:Dati
            @($dopo | Where-Object { $_ -notin $prima }).Count | Should -Be 9   # vista.html, ufficio.html, ufficio.json e i sei brief (uno per ruolo di ruoli.json, mentore e supervisore compresi)
            @($dopo | Where-Object { $_ -notin $prima } | Where-Object { $_ -notmatch 'brief-[a-z]+\.html\|' }).Count | Should -Be 3
            @($dopo | Where-Object { $_ -notin $prima } | Where-Object { $_ -notmatch 'brief-[a-z]+\.html\|' }) | Should -Match '(vista|ufficio)\.(html|json)\|'
            @($prima | Where-Object { $_ -notin $dopo }).Count | Should -Be 0
            Get-ChildItem $script:Dati -Recurse -Filter '*.tmp' | Should -BeNullOrEmpty
            Should -Invoke Save-Stato -Times 0 -Exactly
            Should -Invoke Set-AdoCard -Times 0 -Exactly
        }

        It 'senza -Html non crea nessuna pagina' {
            $global:Mondo.Cards = @(New-FintaCard 6 'nuova'); $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            Invoke-Vista $script:Dati | Out-Null
            Test-Path $script:Pagina | Should -BeFalse
        }

        It '-PercorsoHtml cambia dove scrive, e -Secondi il refresh' {
            $altro = Join-Path $TestDrive 'altrove/pagina.html'
            Invoke-Vista $script:Dati @{ Html = $true; PercorsoHtml = $altro; Secondi = 30 } | Out-Null
            Test-Path $altro | Should -BeTrue
            Test-Path $script:Pagina | Should -BeFalse
            (Get-Content $altro -Raw -Encoding UTF8) | Should -Match 'content="30"'
        }

        It '-Apri apre la pagina nel browser una volta sola; senza -Apri non la apre' {
            Mock Start-Process { }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            Should -Invoke Start-Process -Times 0 -Exactly
            Invoke-Vista $script:Dati @{ Html = $true; Apri = $true } | Out-Null
            Should -Invoke Start-Process -Times 1 -Exactly
        }

        It 'le colonne seguono l ordine del flusso: responsabile, dev, reviewer, collaudatore, supervisore, operatore, pipeline' {
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $nomi = @([regex]::Matches($h, 'data-colonna="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
            $nomi | Should -Be @('responsabile', 'dev', 'reviewer', 'collaudatore', 'supervisore', 'operatore', 'pipeline')
            $h | Should -Not -Match 'Da fare tu'
            $h | Should -Not -Match 'In prova in Test|Pronte per la produzione'
        }

        It 'le sessioni stanno in cima alla colonna del loro ruolo; le colonne senza sessione dicono libero' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inSviluppo'), (New-FintaCard 8 'inRevisione'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'; $global:Mondo.Storia['8'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev' }; '8' = @{ sessione = (New-SessioneInCorso 'reviewer' 'sid-8'); ultimoRuolo = 'reviewer' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            (Get-Colonna $h 'dev') | Should -Match 'data-id="5"'
            (Get-Colonna $h 'dev') | Should -Not -Match 'data-id="8"'
            (Get-Colonna $h 'reviewer') | Should -Match 'data-id="8"'
            foreach ($r in 'responsabile', 'collaudatore') { (Get-Colonna $h $r) | Should -Match 'libero' }
            (Get-Colonna $h 'dev') | Should -Not -Match 'libero'
        }

        It 'il responsabile puo avere piu sessioni in cima alla sua colonna' {
            $global:Mondo.Cards = @((New-FintaCard 5 'nuova'), (New-FintaCard 6 'nuova'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'; $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'responsabile' 'sid-5'); ultimoRuolo = 'responsabile' }; '6' = @{ sessione = (New-SessioneInCorso 'responsabile' 'sid-6'); ultimoRuolo = 'responsabile' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $col = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'responsabile'
            @([regex]::Matches($col, 'class="scheda[ "]')).Count | Should -Be 2
        }

        It 'il bordo della sessione e verde se il processo e vivo, giallo se non lo e' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo'); $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            (Get-Content $script:Pagina -Raw -Encoding UTF8) | Should -Match 'class="scheda" data-id="5"'
            Mock Test-SessioneViva { $false }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            (Get-Content $script:Pagina -Raw -Encoding UTF8) | Should -Match 'class="scheda pausa" data-id="5"'
        }

        It 'la coda di ogni colonna e il ruolo che dice Decisioni, con il motivo o parte al prossimo giro' {
            # 8 occupa il repo: 6 (pronto) e ferma per dev; 7 (nuova) parte al prossimo giro con il responsabile
            $global:Mondo.Cards = @((New-FintaCard 8 'inSviluppo'), (New-FintaCard 6 'pronto'), (New-FintaCard 7 'nuova'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            (Get-Colonna $h 'dev') | Should -Match 'data-id="6".*in coda, un altra card e in sviluppo su Acme\.AI'
            (Get-Colonna $h 'responsabile') | Should -Match 'data-id="7".*parte al prossimo giro'
            (Get-Colonna $h 'responsabile') | Should -Not -Match 'data-id="6"'
        }

        It 'una card ferma dai predecessori in New e in coda dal responsabile, in Ready to develop da dev' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inRevisione'), (New-FintaCard 6 'nuova'), (New-FintaCard 7 'pronto'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            $global:Mondo.Predecessori['6'] = @([pscustomobject]@{ Id = 5; Stato = (St 'inRevisione') })
            $global:Mondo.Predecessori['7'] = @([pscustomobject]@{ Id = 5; Stato = (St 'inRevisione') })
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            (Get-Colonna $h 'responsabile') | Should -Match '(?s)data-id="6".*<div class="aspetta"><ul><li><span class="aspetta-testo">Aspetta la card <[^>]*>#5</[^>]*></span><span class="aspetta-stato"><span class="campo">Stato:</span><span class="stato-board verifica">In review</span></span></li>'
            (Get-Colonna $h 'dev') | Should -Match 'data-id="7".*class="aspetta"'
            (Get-Colonna $h 'operatore') | Should -Not -Match 'data-id="[67]"'
        }

        It 'una predecessora ferma su una persona porta la card dall operatore, con il gesto: Draft, New senza tag, rimossa' {
            $global:Mondo.Cards = @((New-FintaCard 40 'pronto'), (New-FintaCard 41 'pronto'), (New-FintaCard 42 'pronto'), (New-FintaCard 43 'pronto'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria 'pronto' }
            $global:Mondo.Predecessori['40'] = @([pscustomobject]@{ Id = 46; Stato = (St 'bozza'); Tag = @('agents') })
            $global:Mondo.Predecessori['41'] = @([pscustomobject]@{ Id = 47; Stato = (St 'nuova'); Tag = @() })
            $global:Mondo.Predecessori['42'] = @([pscustomobject]@{ Id = 48; Stato = (St 'rimossa'); Tag = @('agents') })
            # in New con il tag agenti la predecessora la prende il responsabile: un attesa normale, resta da dev
            $global:Mondo.Predecessori['43'] = @([pscustomobject]@{ Id = 49; Stato = (St 'nuova'); Tag = @('agents', 'human-test') })
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $op = Get-Colonna $h 'operatore'
            $op | Should -Match '(?s)data-attivita="sblocca" data-id="40".*<div class="aspetta persona">.*<li class="persona"><span class="aspetta-testo">Aspetta la card <[^>]*>#46</[^>]*></span><span class="aspetta-stato"><span class="campo">Stato:</span><span class="stato-board analisi">Draft</span></span><span class="gesto">spostala in New</span></li>'
            $op | Should -Match '(?s)data-id="41".*#47</[^>]*></span>.*<span class="stato-board analisi">New</span></span><span class="gesto">dalle il tag agents</span>'
            $op | Should -Match '(?s)data-id="42".*<span class="stato-board rimossa">Removed</span></span><span class="gesto">togli il link Predecessor dalla #42</span>'
            $op | Should -Not -Match 'data-id="43"'
            (Get-Colonna $h 'dev') | Should -Match '(?s)data-id="43".*<div class="aspetta">.*#49'
            (Get-Colonna $h 'dev') | Should -Not -Match 'data-id="4[012]"'
        }

        It 'il limite di sessioni porta la card nella colonna del ruolo che sarebbe partito' {
            $global:Mondo.Cards = @((New-FintaCard 9 'inSviluppo'), (New-FintaCard 6 'nuova'))
            $global:Mondo.Storia['9'] = New-FintaStoria 'inSviluppo'; $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            Set-StatoDiPartenza $script:Dati @{ '9' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-9'); ultimoRuolo = 'dev' } }
            Invoke-Vista $script:Dati @{ Html = $true; Radice = (New-RadiceDiProva -Cartella $TestDrive -Limiti @{ sessioniAttive = 1 }) } | Out-Null
            (Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'responsabile') | Should -Match 'data-id="6".*posto occupato'
        }

        It 'In review con il posto in Test occupato: in coda dal collaudatore' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inRevisione'), (New-FintaCard 8 'inCollaudo'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'; $global:Mondo.Storia['8'] = New-FintaStoria 'inCollaudo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $col = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'collaudatore'
            $col | Should -Match 'data-id="5".*e in Test'
            # la coda si apre con un clic: chiusa di partenza, la pagina ricorda la scelta
            $col | Should -Match '<details class="gruppo" data-ricorda="coda-collaudatore"><summary><h3>In coda'
        }

        It 'due card ferme dallo stesso limite per repo: tutte e due nella coda di dev, con il motivo' {
            $global:Mondo.Cards = @((New-FintaCard 8 'inSviluppo'), (New-FintaCard 6 'pronto'), (New-FintaCard 9 'pronto'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $dev = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'dev'
            $dev | Should -Match 'data-id="6".*in sviluppo su Acme\.AI'
            $dev | Should -Match 'data-id="9".*in sviluppo su Acme\.AI'
        }

        It 'una card In Deploying to test con il deploy ancora in corso non aspetta nessuno: sta in Pipeline' {
            Mock Get-AdoRun { [pscustomobject]@{ Stato = 'inProgress'; Esito = $null } }
            $global:Mondo.Cards = @(New-FintaCard 5 'inDeployTest' -Tag @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagProvaUmana))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inDeployTest'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; runId = 300; runDopoRev = 20; ultimoRuolo = 'reviewer'
                ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            (Get-Colonna $h 'pipeline') | Should -Match 'data-id="5"'
            (Get-Colonna $h 'operatore') | Should -Not -Match 'data-id="5"'
        }

        It 'In review con human-test e il posto in Test occupato: nessun agente la prende, sta in Pipeline con il motivo' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inRevisione' -Tag @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagProvaUmana)), (New-FintaCard 8 'inCollaudo'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'; $global:Mondo.Storia['8'] = New-FintaStoria 'inCollaudo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            (Get-Colonna $h 'pipeline') | Should -Match 'data-id="5".*e in Test'
            (Get-Colonna $h 'collaudatore') | Should -Not -Match 'data-id="5"'
        }

        It 'una sessione con un ruolo fuori dalle colonne non sparisce: sta in Pipeline, col ruolo scritto' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo'); $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'smistatore' 'sid-1'); ultimoRuolo = 'dev' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            (Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'pipeline') | Should -Match 'data-id="5".*sessione di smistatore'
        }

        It 'con Azure DevOps che non risponde la griglia ha solo le quattro colonne degli agenti' {
            Mock Get-AdoCardAttive { throw 'Chiamata ad Azure DevOps fallita' }
            Mock Get-AdoUtenteCorrente { throw 'Chiamata ad Azure DevOps fallita' }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            @([regex]::Matches($h, 'data-colonna="')).Count | Should -Be 5
            $h | Should -Match 'class="kanban" style="grid-template-columns:(minmax\([^)]*\) ){4}minmax\([^)]*\)"'
        }

        It 'operatore, Sblocca: la card on-hold, anche in Test, con il testo di Format-MotivoCoda' {
            $c = New-FintaCard 5 'inCollaudo'; $c.Tag = @($c.Tag) + 'on-hold'
            $global:Mondo.Cards = @($c); $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'limite' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            (Get-Colonna $h 'operatore') | Should -Match 'data-attivita="sblocca"[^>]*data-id="5".*Sblocca.*i contatori ripartono da zero'
            (Get-Colonna $h 'pipeline') | Should -Not -Match 'data-id="5"'
        }

        It 'operatore, Sblocca: solo la card col tag on-hold porta il segno data-on-hold; un altro Sblocca o un Rispondi no (D37)' {
            $c5 = New-FintaCard 5 'inSviluppo' @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagAttesa)
            $global:Mondo.Cards = @($c5, (New-FintaCard 6 'daChiarire'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'; $global:Mondo.Storia['6'] = New-FintaStoria 'daChiarire'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'limite' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $col = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'operatore'
            $col | Should -Match 'data-attivita="sblocca"[^>]*data-id="5"[^>]*data-on-hold="1"'
            $col | Should -Not -Match 'data-id="6"[^>]*data-on-hold'
        }

        It 'operatore, Rispondi: la card da chiarire, con la domanda del responsabile se e fra i dati letti, altrimenti un testo fisso' {
            $global:Mondo.Cards = @((New-FintaCard 5 'daChiarire'), (New-FintaCard 6 'daChiarire'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'daChiarire'; $global:Mondo.Storia['6'] = New-FintaStoria 'daChiarire'
            Mock Get-AdoCommenti { param($Id, $DopoId = 0)
                if ($Id -eq 5) { @([pscustomobject]@{ Id = 1; Autore = 'a'; Testo = '<div>[responsabile] Quale formato di export?</div>'; Quando = '2026-11-01T09:00:00Z' }) } else { @() } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $col = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'operatore'
            $col | Should -Match 'data-attivita="rispondi"[^>]*data-id="5".*Rispondi.*Quale formato di export\?'
            $col | Should -Match 'data-attivita="rispondi"[^>]*data-id="6".*responsabile aspetta una tua risposta sulla card'
            $col | Should -Match 'analisi'
        }

        It 'Rispondi mostra la domanda anche se ultimoCommento e gia oltre il commento del responsabile' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daChiarire'); $global:Mondo.Storia['5'] = New-FintaStoria 'daChiarire'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ultimoCommento = 10 } }
            Mock Get-AdoCommenti { param($Id, $DopoId = 0)
                @([pscustomobject]@{ Id = 1; Autore = 'a'; Testo = '[responsabile] Serve anche il formato CSV?'; Quando = '2026-11-01T09:00:00Z' }) | Where-Object { $_.Id -gt $DopoId } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            (Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'operatore') | Should -Match 'data-attivita="rispondi"[^>]*data-id="5".*Serve anche il formato CSV\?'
        }

        It 'una card da chiarire con un commento di persona non aspetta te: il responsabile parte al prossimo giro' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daChiarire'); $global:Mondo.Storia['5'] = New-FintaStoria 'daChiarire'
            Mock Get-AdoCommenti { param($Id, $DopoId = 0) @([pscustomobject]@{ Id = 1; Autore = 'a'; Testo = 'ecco la risposta'; Quando = '2026-11-01T09:00:00Z' }) }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            (Get-Colonna $h 'operatore') | Should -Not -Match 'data-id="5"'
            (Get-Colonna $h 'responsabile') | Should -Match 'data-id="5".*parte al prossimo giro'
        }

        It 'operatore, Prova in Test ferma il flusso e Rilascia no: i due gruppi sono separati, con la legenda' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inProvaUmana'), (New-FintaCard 7 'daRilasciare'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inProvaUmana'; $global:Mondo.Storia['7'] = New-FintaStoria 'daRilasciare'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ avvisi = @('testPronto@20'); ultimoRuolo = 'reviewer' }; '7' = @{ prId = 77 } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $col = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'operatore'
            $col | Should -Match '(?s)Fermano il flusso.*data-attivita="prova"[^>]*data-id="5".*Prova in Test.*la card aspetta la tua verifica.*Non fermano nessuno.*data-attivita="rilascia"[^>]*data-id="7".*Rilascia'
            $col | Should -Match 'class="legenda"'
            # i due gruppi si chiudono con un clic: di partenza Fermano il flusso e aperto, Non fermano nessuno chiuso
            $col | Should -Match '<details class="gruppo" data-ricorda="operatore-fermano" open><summary><h3>Fermano il flusso'
            $col | Should -Match '<details class="gruppo" data-ricorda="operatore-non-fermano"><summary><h3>Non fermano nessuno'
        }

        It 'pipeline: le card senza sessione, azioni, motivo e attivita dell operatore, con id, titolo e stato sulla board' {
            $global:Mondo.Cards = @((New-FintaCard 6 'inRilascio'), (New-FintaCard 7 'nuova'), (New-FintaCard 8 'daRilasciare'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $pipe = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'pipeline'
            $pipe | Should -Match 'data-id="6".*Titolo della card 6.*Releasing'
            $pipe | Should -Not -Match 'data-id="7"'
            $pipe | Should -Not -Match 'data-id="8"'
        }

        It 'le catene stanno in un details chiuso sopra la kanban, che sessionStorage ricorda se aperto (in try/catch)' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inRevisione'), (New-FintaCard 6 'pronto'))
            foreach ($i in 5, 6) { $global:Mondo.Storia["$i"] = New-FintaStoria 'pronto' }
            $global:Mondo.Predecessori['6'] = @([pscustomobject]@{ Id = 5; Stato = (St 'inRevisione') })
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '<details class="catene"><summary>Catene delle card<span class="pillola">1</span><span class="nota">'
            $h | Should -Match '(?s)<details class="catene">.*class="catena".*class="kanban".*data-colonna="pipeline"'
            $h | Should -Match "sessionStorage.getItem\('catene-aperte'\) === '1'"
            $script = [regex]::Match($h, '(?s)<script>(.*?)</script>').Groups[1].Value
            $script | Should -Match 'sessionStorage\.getItem'
            $script | Should -Match 'sessionStorage\.setItem'
            @([regex]::Matches($script, 'try \{')).Count | Should -Be 2
        }

        It 'ogni nodo della catena e una schedina con titolo, stato sulla board e dove sta la card; le frecce stanno fra una e l altra' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inSviluppo'), (New-FintaCard 6 'pronto'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            $global:Mondo.Predecessori['6'] = @([pscustomobject]@{ Id = 5; Stato = (St 'inSviluppo') }, [pscustomobject]@{ Id = 3; Stato = (St 'chiusa') })
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $cat = [regex]::Match($h, '(?s)<div class="catena">.*?</div></div>|<div class="catena">.*').Value
            $cat | Should -Match '(?s)data-id="3"[^>]*stato-unita.*unita'
            $cat | Should -Match '(?s)data-id="5"[^>]*stato-lavorazione.*Titolo della card 5.*In development.*dev al lavoro'
            $cat | Should -Match '(?s)data-id="6"[^>]*stato-coda.*Titolo della card 6.*Ready to develop.*in coda per dev'
            @([regex]::Matches($cat, '&rarr;')).Count | Should -Be 2
        }

        It 'disegna la catena dei predecessori con un pallino per card, colorato per stato' {
            # 3 e chiusa e non e sulla board: la conosce solo il link di 6. 5 e in revisione, 6 e 7 non sono partite.
            $global:Mondo.Cards = @((New-FintaCard 5 'inRevisione'), (New-FintaCard 6 'pronto'), (New-FintaCard 7 'nuova'))
            foreach ($i in 5, 6, 7) { $global:Mondo.Storia["$i"] = New-FintaStoria 'pronto' }
            $global:Mondo.Predecessori['6'] = @([pscustomobject]@{ Id = 5; Stato = (St 'inRevisione') }, [pscustomobject]@{ Id = 3; Stato = (St 'chiusa') })
            $global:Mondo.Predecessori['7'] = @([pscustomobject]@{ Id = 6; Stato = (St 'pronto') })
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '(?s)class="catena".*?data-id="3"[^>]*stato-unita.*?data-id="5"[^>]*stato-lavorazione.*?data-id="6"[^>]*stato-coda.*?data-id="7"[^>]*stato-coda'
        }

        It 'una card unita resta in testa alla catena anche se la card che la segue e gia oltre Ready to develop, con la spunta verde' {
            # 11 e in sviluppo (l'istantanea non ne legge piu i predecessori), 12 la aspetta; 10, unita, deve restare in testa
            $global:Mondo.Cards = @((New-FintaCard 11 'inSviluppo'), (New-FintaCard 12 'nuova'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            $global:Mondo.Predecessori['11'] = @([pscustomobject]@{ Id = 10; Stato = (St 'chiusa') })
            $global:Mondo.Predecessori['12'] = @([pscustomobject]@{ Id = 11; Stato = (St 'inSviluppo') })
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '(?s)class="catena".*?data-id="10"[^>]*stato-unita.*?data-id="11"[^>]*stato-lavorazione.*?data-id="12"[^>]*stato-coda'
            $cat = [regex]::Match($h, '(?s)<div class="catena">.*').Value
            $cat | Should -Match '(?s)data-id="10"[^>]*stato-unita[^>]*><b><span class="spunta"[^>]*>&#10003;</span>'
            @([regex]::Matches($cat, 'class="spunta"')).Count | Should -Be 1
        }

        It 'una card unita resta nella catena anche se quella che la segue ha una sessione' {
            $global:Mondo.Cards = @((New-FintaCard 11 'inSviluppo'), (New-FintaCard 12 'nuova'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            $global:Mondo.Predecessori['11'] = @([pscustomobject]@{ Id = 10; Stato = (St 'chiusa') })
            $global:Mondo.Predecessori['12'] = @([pscustomobject]@{ Id = 11; Stato = (St 'inSviluppo') })
            Set-StatoDiPartenza $script:Dati @{ '11' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '(?s)class="catena".*?data-id="10"[^>]*stato-unita.*?data-id="11"[^>]*stato-lavorazione.*?dev al lavoro.*?data-id="12"'
        }

        It 'una catena con tutte le card unite sparisce: resta finche ha card ancora aperte' {
            $global:Mondo.Cards = @(New-FintaCard 11 'inRilascio')
            $global:Mondo.Storia['11'] = New-FintaStoria 'inRilascio'
            $global:Mondo.Predecessori['11'] = @([pscustomobject]@{ Id = 10; Stato = (St 'chiusa') })
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Not -Match 'class="catena"'
            $h | Should -Not -Match '<details class="catene"'
        }

        It 'la spunta c e solo sui nodi unita' {
            $m = [pscustomobject]@{
                Generata = [datetime]'2026-11-18T10:00:00'; ErroreAdo = $null; InCorso = @(); Coda = @(); UltimoGiro = 'x'; ProssimoGiro = 'y'
                Catene = @([pscustomobject]@{ Nodi = @(
                    [pscustomobject]@{ Id = 10; UrlCard = $null; Stato = 'unita'; Titolo = 'a'; StatoBoard = 'Closed'; Dove = 'unita' }
                    [pscustomobject]@{ Id = 11; UrlCard = $null; Stato = 'lavorazione'; Titolo = 'b'; StatoBoard = 'x'; Dove = $null }) })
                Agenti = @([pscustomobject]@{ Ruolo = 'dev'; Sessioni = @(); Coda = @(); Brief = $null })
                Operatore = [pscustomobject]@{ Fermano = @(); NonFermano = @() }; Pipeline = @()
            }
            $h = New-PaginaVista $m 10
            @([regex]::Matches($h, 'class="spunta"')).Count | Should -Be 1
            $h | Should -Match '(?s)data-id="10".*?class="spunta".*?data-id="11"'
            $h | Should -Match 'aria-label="unita"'
        }

        It 'una card unita in Ready to release e unita nella catena, qualunque sia l ordine degli Id' {
            # X (chiusa) -> A (Ready to release, PR completata, worktree tolto) -> B (In development): unita / unita / lavorazione
            foreach ($ids in @(@(10, 11, 12), @(10, 12, 11), @(12, 11, 10))) {
                $x = $ids[0]; $a = $ids[1]; $b = $ids[2]
                $global:Mondo.Cards = @((New-FintaCard $a 'daRilasciare'), (New-FintaCard $b 'inSviluppo')); if ($b -lt $a) { [array]::Reverse($global:Mondo.Cards) }   # anche l'ordine delle righe cambia
                $global:Mondo.Storia = @{}
                foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
                $global:Mondo.Predecessori = @{}
                $global:Mondo.Predecessori["$a"] = @([pscustomobject]@{ Id = $x; Stato = (St 'chiusa') })
                $global:Mondo.Predecessori["$b"] = @([pscustomobject]@{ Id = $a; Stato = (St 'daRilasciare') })
                Set-StatoDiPartenza $script:Dati @{ "$a" = @{ prId = 77; cartella = '' } }
                Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
                $h = Get-Content $script:Pagina -Raw -Encoding UTF8
                $h | Should -Match "(?s)class=""catena"".*?data-id=""$x""[^>]*stato-unita.*?data-id=""$a""[^>]*stato-unita.*?data-id=""$b""[^>]*stato-lavorazione" -Because "ordine $($ids -join ',')"
            }
        }

        It 'una catena fatta solo di card unite (X chiusa -> A in Ready to release unita) sparisce' {
            $global:Mondo.Cards = @(New-FintaCard 11 'daRilasciare'); $global:Mondo.Storia['11'] = New-FintaStoria 'daRilasciare'
            $global:Mondo.Predecessori['11'] = @([pscustomobject]@{ Id = 10; Stato = (St 'chiusa') })
            Set-StatoDiPartenza $script:Dati @{ '11' = @{ prId = 77; cartella = '' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            Get-Content $script:Pagina -Raw -Encoding UTF8 | Should -Not -Match 'class="catena"'
        }

        It 'se la lettura dei predecessori fallisce la card resta nella sua colonna, con la PR' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione'); $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x' } }
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 105; Stato = 'active'; Validazione = 'verde'; BuildId = 9; UrlLog = 'https://log/9' }
            Mock Get-AdoCardPredecessori { throw 'ADO non risponde sui link' }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Not -Match 'non letta'
            (Get-Colonna $h 'reviewer') | Should -Match 'data-id="5".*PR #105'
        }

        It 'Rispondi mostra solo le domande del commento, con gli a capo, e rimanda alla card se lungo' {
            $global:Mondo.Cards = @(New-FintaCard 11 'daChiarire'); $global:Mondo.Storia['11'] = New-FintaStoria 'daChiarire'
            $righe = @('[responsabile] Mi servono quattro risposte.', 'DOMANDE', 'D1. Quale formato di export?', 'a) CSV', 'b) PDF', 'D2. Quale lingua?', 'a) it', 'b) en',
                'D3. Serve il filtro?', 'a) si', 'b) no', 'D4. Quale ordine?', 'a) data', 'b) nome', 'D5. Altro?', 'a) si', 'b) no', 'REGISTRO DELLE DECISIONI') + @(1..30 | ForEach-Object { "Decisione ${_}: scelto lo standard <x>" })
            $global:Mondo.Commenti['11'] = '<div>' + (($righe | ForEach-Object { [System.Net.WebUtility]::HtmlEncode($_) }) -join '</div><div>') + '</div>'
            Mock Get-AdoCommenti { param($Id, $DopoId = 0) @([pscustomobject]@{ Id = 1; Autore = 'a'; Testo = $global:Mondo.Commenti["$Id"]; Quando = '2026-11-01T09:00:00Z' }) }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $col = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'operatore'
            $col | Should -Match 'data-attivita="rispondi"'
            $col | Should -Match '<b>D1\. Quale formato di export\?</b>\na\) CSV\nb\) PDF\n<b>D2\. Quale lingua\?</b>'
            $col | Should -Not -Match 'Decisione 1|REGISTRO|Mi servono quattro'
            $col | Should -Match ([regex]::Escape([string][char]0x2026 + ' continua sulla card'))
        }

        It 'il disegno rispetta gli a capo del testo della voce e lo codifica' {
            $voce = [pscustomobject]@{ Id = 11; UrlCard = $null; Titolo = 't'; Attivita = 'rispondi'; Verbo = 'Rispondi'; Fase = $null; Testo = "D1. a <b>?`nD2. c?"; Pr = $null }
            $m = [pscustomobject]@{
                Generata = [datetime]'2026-11-18T10:00:00'; ErroreAdo = $null; InCorso = @(); Coda = @(); Catene = @(); UltimoGiro = 'x'; ProssimoGiro = 'y'
                Agenti = @([pscustomobject]@{ Ruolo = 'dev'; Sessioni = @(); Coda = @(); Brief = $null })
                Operatore = [pscustomobject]@{ Fermano = @($voce); NonFermano = @() }; Pipeline = @()
            }
            $h = New-PaginaVista $m 10
            $h | Should -Match '<b>D1\. a &lt;b&gt;\?</b>\n<b>D2\. c\?</b>'
            $h | Should -Match '\.voce \.motivo \{[^}]*white-space: pre-line'
        }

        It 'un motivo lungo o su piu righe sta in un dettaglio chiuso, con la prima riga come anteprima; uno breve resta com e' {
            $lungo = [pscustomobject]@{ Id = 11; UrlCard = $null; Titolo = 't'; Attivita = 'rispondi'; Verbo = 'Rispondi'; Fase = $null; Testo = "D1. Quale <formato>?`nA) CSV`nB) PDF"; Pr = $null }
            $breve = [pscustomobject]@{ Id = 12; UrlCard = $null; Titolo = 't'; Attivita = 'sblocca'; Verbo = 'Sblocca'; Fase = $null; Testo = 'in on-hold per limite'; Pr = $null }
            $m = [pscustomobject]@{
                Generata = [datetime]'2026-11-18T10:00:00'; ErroreAdo = $null; InCorso = @(); Coda = @(); Catene = @(); UltimoGiro = 'x'; ProssimoGiro = 'y'
                Agenti = @([pscustomobject]@{ Ruolo = 'dev'; Sessioni = @(); Coda = @(); Brief = $null })
                Operatore = [pscustomobject]@{ Fermano = @($lungo, $breve); NonFermano = @() }; Pipeline = @()
            }
            $h = New-PaginaVista $m 10
            $h | Should -Match '<details class="dettagli" data-ricorda="voce-11"><summary><span class="anteprima">D1\. Quale &lt;formato&gt;\?</span></summary><span class="motivo">'
            $h | Should -Not -Match 'data-ricorda="voce-11" open'
            $h | Should -Match '(?s)data-ricorda="voce-11".*A\) CSV\r?\nB\) PDF</span></details>'
            $h | Should -Not -Match 'data-ricorda="voce-12"'
            $h | Should -Match '<span class="motivo">in on-hold per limite</span>'
        }

        It 'Rispondi: il titolo della domanda in grassetto e l etichetta della proposta a parte; le altre voci no' {
            $voce = [pscustomobject]@{ Id = 11; UrlCard = $null; Titolo = 't'; Attivita = 'rispondi'; Verbo = 'Rispondi'; Fase = $null; Testo = "D1. Quale rete?`nproposta: a) <solo> online"; Pr = $null }
            $sblocca = [pscustomobject]@{ Id = 12; UrlCard = $null; Titolo = 't'; Attivita = 'sblocca'; Verbo = 'Sblocca'; Fase = $null; Testo = 'D1. non e una domanda'; Pr = $null }
            $m = [pscustomobject]@{
                Generata = [datetime]'2026-11-18T10:00:00'; ErroreAdo = $null; InCorso = @(); Coda = @(); Catene = @(); UltimoGiro = 'x'; ProssimoGiro = 'y'
                Agenti = @([pscustomobject]@{ Ruolo = 'dev'; Sessioni = @(); Coda = @(); Brief = $null })
                Operatore = [pscustomobject]@{ Fermano = @($voce, $sblocca); NonFermano = @() }; Pipeline = @()
            }
            $h = New-PaginaVista $m 10
            $h | Should -Match '<b>D1\. Quale rete\?</b>\n<span class="proposta">proposta:</span> a\) &lt;solo&gt; online'
            $h | Should -Match '<span class="motivo">D1\. non e una domanda</span>'
            $h | Should -Match '\.proposta \{'
        }

        It 'una sessione con task mostra la barra dei task chiusi su totali' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo'); $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            $global:Mondo.Task['5'] = @(
                [pscustomobject]@{ Id = 55; Titolo = 'Scrivere il parser'; Stato = 'Active'; Tipo = 'Task' }
                [pscustomobject]@{ Id = 56; Titolo = 'Documentare'; Stato = (St 'taskChiuso'); Tipo = 'Task' }
                [pscustomobject]@{ Id = 57; Titolo = 'Tolto'; Stato = (St 'taskRimosso'); Tipo = 'Task' })
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1' 55); ultimoRuolo = 'dev' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '1/2 task'
            $h | Should -Match 'width:50%'
        }

        It 'una card in coda con i task noti ha la barra; senza task noti niente barra' {
            $global:Mondo.Cards = @((New-FintaCard 6 'pronto'), (New-FintaCard 7 'nuova'))
            $global:Mondo.Storia['6'] = New-FintaStoria 'pronto'; $global:Mondo.Storia['7'] = New-FintaStoria 'nuova'
            $global:Mondo.Task['6'] = @([pscustomobject]@{ Id = 61; Titolo = 'a'; Stato = (St 'taskChiuso'); Tipo = 'Task' }, [pscustomobject]@{ Id = 62; Titolo = 'b'; Stato = 'Active'; Tipo = 'Task' })
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            @([regex]::Matches($h, 'class="barra"')).Count | Should -Be 1
            $h | Should -Match '1/2 task'
        }

        It 'se Azure DevOps non risponde mostra una fascia di avviso e la parte locale' {
            Mock Get-AdoCardAttive { throw 'Chiamata ad Azure DevOps fallita' }
            Mock Get-AdoUtenteCorrente { throw 'Chiamata ad Azure DevOps fallita' }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match 'class="avviso"'
            $h | Should -Match 'Azure DevOps non risponde'
            $h | Should -Match 'data-id="5"'
        }

        # ufficio.json e ufficio.html: la stessa lettura della vista. Scenario: dev con una sessione su una card e una card in revisione
        # che il collaudatore ha appena lasciato (un rimando indietro: dopo il collaudo si torna alla revisione).
        It 'con -Html scrive ufficio.json e ufficio.html con il dato vero: sessione, consegna, bacheca' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inSviluppo'), (New-FintaCard 12 'inRevisione'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'; $global:Mondo.Storia['12'] = New-FintaStoria 'inRevisione'
            $ora = (Get-Date).ToUniversalTime()
            Set-StatoDiPartenza $script:Dati @{
                '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1' $null 3); ultimoRuolo = 'dev' }
                '12' = @{ ultimoRuolo = 'collaudatore'; ultimaSessione = @{ collaudatore = @{ id = 'sid-c'; fine = $ora.AddMinutes(-5).ToString('o') } } } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $j = Join-Path $script:Dati 'ufficio.json'
            Test-Path $j | Should -BeTrue
            $m = Get-Content $j -Raw -Encoding UTF8 | ConvertFrom-Json
            ($m.personaggi | Where-Object ruolo -eq 'dev').sessione.id | Should -Be 5
            ($m.personaggi | Where-Object ruolo -eq 'dev').sessione.titolo | Should -Be 'Titolo della card 5'
            @($m.consegne).Count | Should -Be 1
            $m.consegne[0].id | Should -Be 12
            $m.consegne[0].da | Should -Be 'collaudatore'
            $m.consegne[0].a | Should -Be 'responsabile'   # la decisione dello smistatore per quella card nel mondo finto
            $m.consegne[0].verso | Should -Be 'indietro'
            ($m.board | Where-Object chiave -eq 'inRevisione').conteggio | Should -Be 1
            ($m.board | Where-Object chiave -eq 'inSviluppo').conteggio | Should -Be 1
            $m.quota.stato | Should -BeIn 'libera', 'sconosciuta'
            $u = Join-Path $script:Dati 'ufficio.html'
            Test-Path $u | Should -BeTrue
            $h = Get-Content $u -Raw -Encoding UTF8
            $h | Should -Match 'id="dati"'
            $h | Should -Match '"id":12'
            if ($env:UFFICIO_ESEMPIO) { Copy-Item $u $env:UFFICIO_ESEMPIO -Force }
        }

        It 'mostra ultimo e prossimo giro nel sottotitolo' {
            Set-LogDiOggi $script:Dati @('2026-11-18 10:02:03 INFO x')
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '<h1>Agenti</h1>'
            $h | Should -Match 'Ultimo giro dello smistatore 2026-11-18 10:02:03 &middot; prossimo 2026-11-18 10:04</p>'
        }

        It 'con -Html il terminale non e ridisegnato con i blocchi di testo' {
            $global:Mondo.Cards = @(New-FintaCard 6 'nuova'); $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            Invoke-Vista $script:Dati @{ Html = $true } | Should -Not -Match '== In corso'
        }

        # Con dati ricchi la pagina ha tutti i pezzi. Se $env:VISTA_ESEMPIO e impostata la pagina e scritta anche li: e cosi che
        # si rigenera docs/vista-esempio.html (VISTA_ESEMPIO=<percorso> e si lancia questo test).
        It 'con dati ricchi la pagina ha sessioni, catena, gruppi e barre (e rigenera l esempio se richiesto)' {
            $global:Mondo.Cards = @(
                (New-FintaCard 5 'inSviluppo'), (New-FintaCard 8 'inRevisione'), (New-FintaCard 11 'inProvaUmana'), (New-FintaCard 23 'inCollaudo'),
                (New-FintaCard 12 'daUnire'), (New-FintaCard 13 'pronto'), (New-FintaCard 17 'nuova'), (New-FintaCard 18 'nuova'),
                (New-FintaCard 14 'daChiarire'), (New-FintaCard 15 'daRilasciare'), (New-FintaCard 19 'inRilascio'), (New-FintaCard 21 'inSviluppo' @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagAttesa)))
            # D52: una funzionalita (Feature 70) con due card unite nel ramo e la card di chiusura in Draft, da spostare in New
            foreach ($i in 60, 61) { $c = New-FintaCard $i 'inFeature'; $c | Add-Member PadreId 70; $global:Mondo.Cards += $c }
            $c = New-FintaCard 62 'bozza'; $c | Add-Member PadreId 70; $c.Titolo = 'Collaudo funzionalita: Esportare le stime in PDF'; $global:Mondo.Cards += $c
            $tagC = @($script:Cfg.Stati.tagChiusura, $script:Cfg.Stati.tagAgenti)
            $global:Mondo.Figli = @([pscustomobject]@{ Id = 60; Stato = (St 'inFeature'); Tag = @('agents'); Tipo = 'User Story'; Titolo = 'Titolo della card 60' },
                [pscustomobject]@{ Id = 61; Stato = (St 'inFeature'); Tag = @('agents'); Tipo = 'Bug'; Titolo = 'Titolo della card 61' },
                [pscustomobject]@{ Id = 62; Stato = (St 'bozza'); Tag = $tagC; Tipo = 'User Story'; Titolo = 'Collaudo funzionalita: Esportare le stime in PDF' })
            $global:Mondo.Feature = [pscustomobject]@{ Id = 70; Tipo = 'Feature'; Titolo = 'Esportare le stime in PDF'; Stato = 'Active'; Tag = @(); Area = $script:Area; FigliIds = @(60, 61, 62) }
            Mock Get-AdoFeature { $global:Mondo.Feature }
            Mock Get-AdoFigliFeature { @($global:Mondo.Figli) }
            Mock Get-AdoRamoCard { 'feature/f70-esportare-le-stime-in-pdf' }
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            ($global:Mondo.Cards | Where-Object Id -eq 5).Titolo = 'Importare le stime dal foglio Excel'
            ($global:Mondo.Cards | Where-Object Id -eq 8).Titolo = 'Esportare il riepilogo in PDF'
            ($global:Mondo.Cards | Where-Object Id -eq 17).Titolo = 'Rapporto finale delle stime'
            $global:Mondo.Task['5'] = @(
                [pscustomobject]@{ Id = 55; Titolo = 'Scrivere il parser'; Stato = 'Active'; Tipo = 'Task' }
                [pscustomobject]@{ Id = 56; Titolo = 'Test del parser'; Stato = (St 'taskChiuso'); Tipo = 'Task' }
                [pscustomobject]@{ Id = 57; Titolo = 'Documentare'; Stato = (St 'taskChiuso'); Tipo = 'Task' })
            $global:Mondo.Task['13'] = @([pscustomobject]@{ Id = 131; Titolo = 'a'; Stato = 'Active'; Tipo = 'Task' })
            # la catena 10 -> 12 -> 13 -> 17 -> 18: 10 e unita (chiusa, fuori board), 12 e in lavorazione, il resto in coda
            $global:Mondo.Predecessori['13'] = @([pscustomobject]@{ Id = 12; Stato = (St 'daUnire') }, [pscustomobject]@{ Id = 10; Stato = (St 'chiusa') })
            $global:Mondo.Predecessori['17'] = @([pscustomobject]@{ Id = 13; Stato = (St 'pronto') })
            $global:Mondo.Predecessori['18'] = @([pscustomobject]@{ Id = 17; Stato = (St 'nuova'); Tag = @('agents') })
            Mock Get-AdoCommenti { param($Id, $DopoId = 0)
                if ($Id -eq 14) { @([pscustomobject]@{ Id = 1; Autore = 'a'; Testo = '<div>[responsabile] Restano due scelte di prodotto.</div><div>DOMANDE</div><div>D1. L export deve includere anche le stime scartate? Oggi non sono salvate.</div><div>a) Si, in un foglio a parte. &lt;- la mia scelta: non cambia il riepilogo.</div><div>b) No.</div><div>D2. Quale formato?</div><div>a) CSV</div><div>b) PDF</div>'; Quando = '2026-11-01T09:00:00Z' }) } else { @() } }
            Mock Get-AdoRun { [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded' } }
            Set-StatoDiPartenza $script:Dati @{
                '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1' 55 34); ultimoRuolo = 'dev'; ramo = 'feature/5-x'; cartella = 'C:/x' }
                '8' = @{ sessione = (New-SessioneInCorso 'reviewer' 'sid-8' $null 6); ultimoRuolo = 'reviewer' }
                '11' = @{ ramo = 'feature/11-x'; runId = 300; runDopoRev = 20; avvisi = @('testPronto@20'); ultimoRuolo = 'reviewer'
                    ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } }
                '23' = @{ ramo = 'feature/23-x'; ultimoRuolo = 'reviewer'
                    ultimaSessione = @{ reviewer = @{ id = 'r3'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } }
                '21' = @{ inAttesaPer = 'sessione'; ultimoRuolo = 'dev' }; '60' = @{ prId = 960; destinazione = 'feature/f70-esportare-le-stime-in-pdf' }; '61' = @{ prId = 961; destinazione = 'feature/f70-esportare-le-stime-in-pdf' } }
            # il limite per componente e uno: le card nei tre stati di Test stanno in componenti diversi (la 23 in Forms)
            ($global:Mondo.Cards | Where-Object Id -eq 23).Area = 'DevOps.Agents\Workflow\Forms'
            $u = @{ input_tokens = 900; output_tokens = 4100; cache_read_input_tokens = 11800; cache_creation_input_tokens = 2000 }
            Set-Uscita $script:Dati 'sid-1' @(
                (New-Riga 'm0' @{ type = 'text'; text = 'Parto dal parser: leggo il file e poi lancio i test.' })
                (New-Riga 'm1' (New-Uso 'Read' @{ file_path = 'C:/repo/src/Importa.ps1' }))
                ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = 't'; content = "function Import-Stime {`n    param(`$Percorso)`n}" }) } } | ConvertTo-Json -Depth 10 -Compress)
                (New-Riga 'm2' (New-Uso 'Bash' @{ command = 'npm test'; description = 'Lancia i test' }))
                (New-Riga 'm3' (New-Uso 'Edit' @{ file_path = 'C:/repo/src/Importa.ps1' }) $u))
            Set-Uscita $script:Dati 'sid-8' @((New-Riga 'm1' (New-Uso 'Grep' @{ pattern = 'TODO' })))
            # la PR sta sulla scheda della sessione (5), nella colonna dell'operatore (11) e in quella del collaudatore (23)
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 105; Stato = 'active'; Validazione = 'rossa'; BuildId = 9; UrlLog = 'https://log/9' }
            $global:Mondo.Pr['feature/11-x'] = [pscustomobject]@{ Id = 111; Stato = 'active'; Validazione = 'verde'; BuildId = 8; UrlLog = 'https://log/8' }
            $global:Mondo.Pr['feature/23-x'] = [pscustomobject]@{ Id = 123; Stato = 'active'; Validazione = 'inCorso'; BuildId = 7; UrlLog = 'https://log/7' }
            $ora = (Get-Date).ToUniversalTime()
            $mk = { param($id, $prog, $pip, $ramo, $chi, $stato, $minuti, $fase, $esito = '')
                [pscustomobject]@{ Id = $id; Progetto = $prog; Pipeline = $pip; Ramo = $ramo; Autore = $chi; Stato = $stato; Fase = $fase
                    Inizio = $ora.AddMinutes(-$minuti); Fine = $(if ($esito) { $ora.AddMinutes(-$minuti + 9) } else { $null }); Esito = $esito
                    Url = "https://acme.visualstudio.com/$prog/_build/results?buildId=$id" } }
            $global:Mondo.Build = [pscustomobject]@{ Ore = 24; InCorso = 2; InCoda = 1; InAttesa = 1; NumFalliti = 2; Errori = @()
                Attivi = @(
                    (& $mk 4101 'Acme.Monitor' 'build-ci' 'feature/5-importa-stime' 'Paolo Rossi' 'inCorso' 7 'Test' | Add-Member Agente 'interno' -PassThru | Add-Member Pool 'Self-Hosted' -PassThru)
                    (& $mk 4102 'Acme.Agenda' 'deploy-test' 'develop' 'Mario Rossi' 'inAttesa' 42 'DeployTest' | Add-Member Agente 'cloud' -PassThru | Add-Member Pool 'Azure Pipelines' -PassThru)
                    (& $mk 4103 'Acme.Warehouse' 'build-ci' 'develop' 'Anna Verdi' 'inCorso' 95 'Build')
                    (& $mk 4104 'Acme.Portale' 'pr-validation' 'feature/8-pdf' 'Paolo Rossi' 'inCoda' 3 $null))
                Orchestratori = @(
                    (& $mk 4201 'Acme.AI' 'release-orchestrator' 'release/1.2' 'Mario Rossi' 'inAttesa' 12 'Prod' | Add-Member Componenti @('deployApi', 'deployWeb') -PassThru)
                    (& $mk 4200 'Acme.AI' 'release-orchestrator' 'release/1.1' 'Mario Rossi' 'concluso' 300 $null 'succeeded' | Add-Member Componenti @('deployWeb') -PassThru))
                Falliti = @(
                    (& $mk 4090 'Acme.Monitor' 'build-ci' 'feature/11-x' 'Paolo Rossi' 'concluso' 130 $null 'failed')
                    (& $mk 4080 'Acme.Warehouse' 'pr-validation' 'fix/9-y' 'Anna Verdi' 'concluso' 400 $null 'failed')
                    (& $mk 4070 'Acme.Portale' 'build-ci' 'develop' 'Mario Rossi' 'concluso' 700 $null 'canceled')) }
            Set-LogDiOggi $script:Dati @("$(Get-Date -Format 'yyyy-MM-dd') 10:02:03 INFO card 5: lanciata la sessione x")
            Set-SupervisoreDiPartenza $script:Dati @{ ultimaEsecuzione = (Get-Date).ToUniversalTime().AddMinutes(-2).ToString('o')
                problemi = @{ 'pat' = @{ testo = 'Il PAT di Azure DevOps scade fra 3 giorni'; urgente = $true; primoVisto = '2026-11-18T08:00:00Z' }
                    'quota' = @{ testo = 'La quota settimanale e al 80%'; urgente = $false; primoVisto = '2026-11-18T09:00:00Z' } }
                sessioniDiagnosi = @(@{ id = 'd-1'; pid = 1; avvio = 'x'; chiave = 'quota'; inizio = '2026-11-18T09:30:00Z' }) }
            # la sezione Apprendimento: qualche riga del registro nelle ultime settimane e due lezioni in prova
            $registro = @(
                @(0, 1, 1, 2, 9) | ForEach-Object -Begin { $n = 40 } -Process { $n++; [pscustomobject]@{ data = (Get-Date).ToUniversalTime().AddDays(-$_).ToString('o'); card = $n; repo = 'Acme.AI'; tipo = 'blocco'; ruolo = 'dev'; motivo = 'm'; lezione = $null } }
                [pscustomobject]@{ data = (Get-Date).ToUniversalTime().AddDays(-1).ToString('o'); card = 8; repo = 'Acme.AI'; tipo = 'onHold'; ruolo = 'reviewer'; motivo = 'm'; lezione = $null }
                [pscustomobject]@{ data = (Get-Date).ToUniversalTime().AddDays(-2).ToString('o'); card = 5; repo = 'Acme.AI'; tipo = 'correzione'; ruolo = 'dev'; motivo = 'm'; lezione = $null }
                [pscustomobject]@{ data = (Get-Date).ToUniversalTime().AddDays(-2).ToString('o'); card = 7; repo = 'Acme.AI'; tipo = 'lezioneApplicata'; ruolo = 'dev'; motivo = $null; lezione = 'dev-001'; esito = 'finito' })
            Mock Get-RigheApprendimento { $registro }
            Mock Get-MemoriaDelRuolo {
                if ($Ruolo -ne 'dev') { return [pscustomobject]@{ Ruolo = $Ruolo; Repo = $Repo; Disponibile = $true; InProvaUsato = $false; Motivi = @(); File = @() } }
                $l1 = ConvertTo-TestoLezione -Id 'dev-001' -Situazione 'Il test di integrazione non parte' -CosaFare 'Avvia prima il database di prova con docker compose up -d e aspetta che risponda sulla porta 5432, poi lancia i test.' -Perche 'Senza database la suite fallisce con un timeout che sembra un errore di rete.' -Card '5'
                $l2 = ConvertTo-TestoLezione -Id 'dev-002' -Situazione 'Il restore dei pacchetti fallisce dietro il proxy' -CosaFare 'Imposta HTTPS_PROXY prima di dotnet restore e ripeti il comando una sola volta.' -Perche 'Il feed interno risponde solo dalla rete aziendale.' -Card '9'
                $l3 = ConvertTo-TestoLezione -Id 'dev-003' -Situazione 'La pipeline di build non trova la versione' -CosaFare 'Lancia scripts/Calculate-Version.ps1 con il nome del ramo, non con il commit.' -Perche 'Lo script ricava la fascia (alpha, beta, rc) dal nome del ramo.' -Card '12'
                $l4 = ConvertTo-TestoLezione -Id 'dev-004' -Situazione 'Il commit viene rifiutato dall hook' -CosaFare 'Leggi il messaggio dell hook: chiede un prefisso Conventional Commits, correggi il titolo e ripeti.' -Perche 'L hook controlla il titolo prima di accettare il commit.' -Card '14'
                # dev-003 e dev-004 sono gia su develop (stabili), dev-001 e dev-002 sono solo sul ramo della memoria (in prova)
                [pscustomobject]@{ Ruolo = $Ruolo; Repo = $Repo; Disponibile = $true; InProvaUsato = $true; Motivi = @(); File = @([pscustomobject]@{ Nome = 'comune'; Develop = ($l3 + "`n`n" + $l4); InProva = ($l1 + "`n`n" + $l2 + "`n`n" + $l3 + "`n`n" + $l4) }) }
            }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            Get-SezioneApprendimento $h | Should -Match '(?s)<td[^>]*>dev</td><td[^>]*>.*data-lezione="dev-001".*data-lezione="dev-002"'
            @([regex]::Matches($h, 'class="scheda[ "]')).Count | Should -Be 2
            # la sezione delle pipeline: riepilogo, una riga per run attivo col link, i falliti in un riquadro chiuso, il link alle PR
            $sez = [regex]::Match($h, '(?s)<section class="build" data-sezione="build">.*</section>').Value   # avida: i progetti sono section annidate
            $sez | Should -Match '<b>2</b>in corso'
            $sez | Should -Match '<b>1</b>in attesa di approvazione'
            $sez | Should -Match '<b>2</b>falliti nelle ultime 24 ore'
            # in cima il pulsante delle PR (scheda nuova), poi i run in corso o in coda, poi l'orchestratore con componenti, stage, approvazione ed esito
            $sez | Should -Match '(?s)^<section[^>]*><div class="build-testa"><h1>Pipeline</h1><a class="build-pr" href="https://acme\.visualstudio\.com/_pulls" target="_blank"'
            # in cima le approvazioni che aspettano (il run normale 4102 e il rilascio 4201), con il link per aprire il run e approvare
            $app = [regex]::Match($sez, '(?s)<div class="da-approvare".*?</table>').Value
            $app | Should -Match '<span class="conta">2</span>'
            $app | Should -Match '(?s)data-build="4102".*<b>DeployTest</b>.*buildId=4102" target="_blank" rel="noopener">apri e approva'
            $app | Should -Match 'data-build="4201"'
            $app | Should -Not -Match 'data-build="4101"'
            # poi un blocco per progetto: prima quelli con attese (AI e Acme.Agenda), poi con run attivi, poi con soli falliti
            $ordine = @([regex]::Matches($sez, 'data-progetto="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
            $ordine | Should -Be @('Acme.Agenda', 'Acme.AI', 'Acme.Monitor', 'Acme.Portale', 'Acme.Warehouse')
            $ai = [regex]::Match($sez, '(?s)<details class="progetto" data-progetto="Acme\.AI" open>.*?</details>').Value
            $ai | Should -Match '(?s)data-build="4201".*rilascio</span>.*deployApi.*deployWeb.*approvazione per <b>Prod</b>.*data-build="4200".*riuscito'
            $sup = [regex]::Match($sez, '(?s)<details class="progetto" data-progetto="Acme\.Monitor" open>.*?</details>').Value
            $sup | Should -Match '(?s)data-build="4101".*fase <b>Test</b>.*agente interno: Self-Hosted.*gira da 7 min'
            $sup | Should -Match '(?s)<details class="falliti">.*data-build="4090".*fallito'
            $sez | Should -Match 'data-build="4102".*title="agente cloud: Azure Pipelines"'
            $sez | Should -Match 'data-build="4103".*gira da 1 h 35 min'
            $sez | Should -Match 'data-build="4104".*in coda da 3 min'
            # badge del progetto separati: in corso e in coda
            $sez | Should -Match 'data-progetto="Acme.Portale" open><summary><h3>Acme.Portale <span class="pillola inCoda">1 in coda</span>'
            $sez | Should -Match '<details class="falliti">(?!.* open)'
            $sez | Should -Match 'data-build="4070".*annullato'
            $sez | Should -Match 'href="https://acme\.visualstudio\.com/_pulls"'
            @([regex]::Matches($h, 'class="nodo ')).Count | Should -Be 5
            (Get-Colonna $h 'operatore') | Should -Match 'data-attivita="sblocca"'
            (Get-Colonna $h 'operatore') | Should -Match 'data-attivita="prova"'
            (Get-Colonna $h 'responsabile') | Should -Match 'data-id="18".*class="aspetta">.*#17'
            (Get-Colonna $h 'pipeline') | Should -Match 'data-id="19"><span class="titolo">.*</span><div class="riga-stato"><span class="campo">Stato:</span> <span class="stato-board [a-z]+">'
            (Get-Colonna $h 'collaudatore') | Should -Match 'data-id="23"'
            (Get-Colonna $h 'operatore') | Should -Match 'data-attivita="rispondi"[^>]*data-id="14".*stime scartate'
            (Get-Colonna $h 'operatore') | Should -Match 'data-attivita="rilascia"[^>]*data-id="15"'
            $h | Should -Match '2/3 task'
            (Get-Colonna $h 'dev') | Should -Match 'pr-rossa.*PR #105.*href="https://log/9"'
            (Get-Colonna $h 'operatore') | Should -Match 'data-id="11".*pr-verde.*PR #111'
            (Get-Colonna $h 'collaudatore') | Should -Match 'data-id="23".*pr-inCorso.*PR #123.*href="https://log/7"'
            # il numero di ogni card e un link alla card (stesso indirizzo di Get-AdoUrlCard), in una scheda nuova
            $lk = { param($i) '<a class="card" href="' + [System.Net.WebUtility]::HtmlEncode((Get-AdoUrlCard -Id $i)) + '" target="_blank" rel="noopener"><span class="num">#' + $i + '</span>' }
            (Get-Colonna $h 'dev') | Should -Match ([regex]::Escape((& $lk 5)))
            (Get-Colonna $h 'reviewer') | Should -Match ([regex]::Escape((& $lk 8)))
            (Get-Colonna $h 'responsabile') | Should -Match ([regex]::Escape((& $lk 18)))
            # anche il titolo e un link alla stessa card, accanto al numero
            (Get-Colonna $h 'responsabile') | Should -Match ([regex]::Escape((& $lk 18)) + ' Titolo della card 18</a><div class="riga-stato"><span class="campo">Stato:</span> <span class="stato-board analisi">New</span></div>')
            (Get-Colonna $h 'operatore') | Should -Match ([regex]::Escape((& $lk 14)))
            # la funzionalita: sotto la sua Feature, e la chiusura in Draft aspetta il gesto dall operatore
            # la sezione si comprime con un clic (aperta di default) e ricorda come l'ha lasciata chi legge
            $h | Should -Match '<details class="funzionalita" data-ricorda="funzionalita" open><summary><h2>Funzionalita<span class="pillola">1</span>'
            $h | Should -Match '(?s)<div class="funzionalita-lista">.*</div></details>'
            $h | Should -Match '(?s)<div class="funzionalita-voce" data-feature="70">.*Esportare le stime in PDF.*<div class="chiusura" data-id="62">.*<li data-id="60">.*<li data-id="61">'
            (Get-Colonna $h 'operatore') | Should -Match '(?s)data-id="62".*<span class="gesto">sposta la card #62 in New</span>'
            (Get-Colonna $h 'pipeline') | Should -Match ([regex]::Escape((& $lk 19)))
            $h | Should -Match ('<b>' + [regex]::Escape((& $lk 13)))
            $h | Should -Match ('<b><span class="spunta"[^>]*>&#10003;</span> ' + [regex]::Escape((& $lk 10)))   # 10 e unita: la spunta prima del numero
            (Get-Content (Join-Path $script:Dati 'sessione-sid-1.html') -Raw -Encoding UTF8) | Should -Match ('<h1>' + [regex]::Escape((& $lk 5)))
            # ogni card sta in un posto solo della kanban (le catene, sopra, le nominano di nuovo: si prende solo la kanban)
            $da = $h.IndexOf('class="kanban"'); $fino = $h.IndexOf('<div data-pannello="pipeline"')
            $kanban = $h.Substring($da, $fino - $da)
            foreach ($c in $global:Mondo.Cards) {
                @([regex]::Matches($kanban, ('data-id="' + $c.Id + '"'))).Count | Should -Be 1 -Because "la card $($c.Id) deve comparire una volta sola"
            }
            if ($env:VISTA_ESEMPIO) { Copy-Item $script:Pagina $env:VISTA_ESEMPIO -Force }
            # la pagina di una sessione: docs/sessione-esempio.html (SESSIONE_ESEMPIO=<percorso>)
            Test-Path (Join-Path $script:Dati 'sessione-sid-1.html') | Should -BeTrue
            $h | Should -Match 'href="sessione-sid-1\.html"'
            if ($env:SESSIONE_ESEMPIO) { Copy-Item (Join-Path $script:Dati 'sessione-sid-1.html') $env:SESSIONE_ESEMPIO -Force }
        }
    }

    Context 'Apprendimento (D46)' {
        BeforeEach {
            $script:Pagina = Join-Path $script:Dati 'vista.html'
            $global:Mondo.Cards = @(New-FintaCard 6 'nuova'); $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
        }

        It 'ha la tabella per ruolo e settimana dal registro e le lezioni in prova, ognuna una volta anche con piu repo' {
            $adesso = (Get-Date).ToUniversalTime().ToString('o')
            Mock Get-RigheApprendimento {
                @([pscustomobject]@{ data = $adesso; card = 5; repo = 'r'; tipo = 'blocco'; ruolo = 'dev'; motivo = 'm'; lezione = $null }
                  [pscustomobject]@{ data = $adesso; card = 5; repo = 'r'; tipo = 'correzione'; ruolo = 'dev'; motivo = 'm'; lezione = $null }
                  [pscustomobject]@{ data = $adesso; card = 8; repo = 'r'; tipo = 'onHold'; ruolo = 'reviewer'; motivo = 'm'; lezione = $null })
            }
            Mock Get-MemoriaDelRuolo {
                $t = ConvertTo-TestoLezione -Id "$Ruolo-001" -Situazione "Situazione di $Ruolo" -CosaFare 'c' -Perche 'p' -Card '5'
                [pscustomobject]@{ Ruolo = $Ruolo; Repo = $Repo; Disponibile = $true; InProvaUsato = $true; Motivi = @()
                    File = @([pscustomobject]@{ Nome = 'comune'; Develop = $null; InProva = $t }, [pscustomobject]@{ Nome = $Repo; Develop = $null; InProva = $null }) }
            }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $sez = Get-SezioneApprendimento (Get-Content $script:Pagina -Raw -Encoding UTF8)
            $sez | Should -Match '(?s)<td[^>]*>dev</td><td[^>]*>1</td><td[^>]*>0</td><td[^>]*>1</td><td[^>]*>0</td>'
            $sez | Should -Match '(?s)<td[^>]*>reviewer</td><td[^>]*>0</td><td[^>]*>1</td>'
            $sez | Should -Match 'Lezioni in prova'
            @([regex]::Matches($sez, 'data-lezione="dev-001"')).Count | Should -Be 1
            $sez | Should -Match 'Situazione di dev'
        }

        It 'se le lezioni non si leggono la sezione lo dice e il resto della pagina si disegna' {
            Mock Get-MemoriaDelRuolo { throw 'git non risponde <x>' }
            Mock Get-RigheApprendimento { @([pscustomobject]@{ data = (Get-Date).ToUniversalTime().ToString('o'); card = 5; repo = 'r'; tipo = 'blocco'; ruolo = 'dev'; motivo = 'm'; lezione = $null }) }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $sez = Get-SezioneApprendimento $h
            $sez | Should -Match 'git non risponde &lt;x&gt;'
            $sez | Should -Match '<td[^>]*>dev</td><td[^>]*>1</td>'
            $h | Should -Match 'data-id="6"'
            (Get-Colonna $h 'responsabile') | Should -Match 'data-id="6"'
        }

        It 'se il registro non si legge la sezione lo dice, restano le lezioni e la pagina si disegna' {
            Mock Get-RigheApprendimento { throw 'registro bloccato' }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            Get-SezioneApprendimento $h | Should -Match 'registro bloccato'
            $h | Should -Match 'data-id="6"'
        }

        It 'un avviso della lettura (git che ripiega) si mostra senza perdere le lezioni lette' {
            Mock Get-MemoriaDelRuolo {
                $t = ConvertTo-TestoLezione -Id "$Ruolo-001" -Situazione 'ok' -CosaFare 'c' -Perche 'p' -Card '5'
                [pscustomobject]@{ Ruolo = $Ruolo; Repo = $Repo; Disponibile = $true; InProvaUsato = $true; Motivi = @('fetch fallito'); File = @([pscustomobject]@{ Nome = 'comune'; Develop = $null; InProva = $t }) }
            }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $sez = Get-SezioneApprendimento (Get-Content $script:Pagina -Raw -Encoding UTF8)
            $sez | Should -Match 'fetch fallito'
            $sez | Should -Match 'data-lezione="dev-001"'
        }

        It 'senza registro ne lezioni la sezione c e e lo dice, senza numeri finti' {
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $sez = Get-SezioneApprendimento (Get-Content $script:Pagina -Raw -Encoding UTF8)
            $sez | Should -Match 'class="libero"'
            $sez | Should -Not -Match '<table'
        }

        It 'le lezioni si leggono solo per la pagina HTML: il testo nel terminale non tocca git' {
            Invoke-Vista $script:Dati | Out-Null
            Should -Invoke Get-MemoriaDelRuolo -Times 0 -Exactly
        }

        It 'gli avvisi uguali di piu ruoli si mostrano una volta' {
            Mock Get-MemoriaDelRuolo { [pscustomobject]@{ Ruolo = $Ruolo; Repo = $Repo; Disponibile = $true; InProvaUsato = $false; Motivi = @('fetch fallito: rete giu'); File = @() } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $sez = Get-SezioneApprendimento (Get-Content $script:Pagina -Raw -Encoding UTF8)
            @([regex]::Matches($sez, 'fetch fallito: rete giu')).Count | Should -Be 1
        }

        It 'la sezione dice la finestra (4 settimane intere piu quella in corso) e mostra le lezioni che hanno evitato un blocco, finora' {
            $adesso = (Get-Date).ToUniversalTime().ToString('o')
            Mock Get-RigheApprendimento {
                @([pscustomobject]@{ data = $adesso; card = 8; repo = 'r'; tipo = 'lezioneApplicata'; ruolo = 'dev'; motivo = ''; lezione = 'dev-001'; esito = 'finito' }
                  [pscustomobject]@{ data = $adesso; card = 5; repo = 'r'; tipo = 'lezioneApplicata'; ruolo = 'dev'; motivo = ''; lezione = 'dev-001'; esito = 'finito' })
            }
            # dev-001 e stabile (nasce dalla card 5): sulla 5 il blocco e stato visto, sulla 8 la lezione l'ha anticipato
            Mock Get-MemoriaDelRuolo {
                $t = ConvertTo-TestoLezione -Id "$Ruolo-001" -Situazione 's' -CosaFare 'c' -Perche 'p' -Card '5'
                [pscustomobject]@{ Ruolo = $Ruolo; Repo = $Repo; Disponibile = $true; InProvaUsato = $false; Motivi = @(); File = @([pscustomobject]@{ Nome = 'comune'; Develop = $t; InProva = $null }) }
            }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $sez = Get-SezioneApprendimento (Get-Content $script:Pagina -Raw -Encoding UTF8)
            $sez | Should -Match 'ultime 4 settimane intere piu quella in corso'
            $sez | Should -Match '(?s)evitato un blocco.*finora.*data-evitata="dev-001".*card 8'
            $sez | Should -Not -Match 'card 5'
        }
        It 'le lezioni in prova e le stabili arrivano alla pagina con il testo intero, lette una volta sola per file' {
            Mock Get-MemoriaDelRuolo {
                $a = ConvertTo-TestoLezione -Id 'dev-001' -Situazione 'Lezione gia confermata' -CosaFare 'fai A' -Perche 'perche A' -Card '5'
                $b = ConvertTo-TestoLezione -Id 'dev-002' -Situazione 'Lezione ancora in prova' -CosaFare 'fai B' -Perche 'perche B' -Card '9'
                [pscustomobject]@{ Ruolo = $Ruolo; Repo = $Repo; Disponibile = $true; InProvaUsato = $true; Motivi = @()
                    File = @([pscustomobject]@{ Nome = 'comune'; Develop = $a; InProva = ($a + "`n`n" + $b) }) }
            }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $sez = Get-SezioneApprendimento (Get-Content $script:Pagina -Raw -Encoding UTF8)
            $sez | Should -Match '(?s)data-lezione="dev-002".*fai B'
            $sez | Should -Not -Match 'data-lezione="dev-001"'
            $sez | Should -Match '(?s)data-stabile="dev-001".*fai A.*perche A'
            $sez | Should -Not -Match 'data-stabile="dev-002"'
        }
        It 'una lettura per ruolo e per repo della mappa' {
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $ruoli = @($script:Cfg.Ruoli.PSObject.Properties.Name).Count
            $repo = @($script:Cfg.Mappa.aree | ForEach-Object { [string]$_.repo } | Select-Object -Unique).Count
            Should -Invoke Get-MemoriaDelRuolo -Times ($ruoli * $repo) -Exactly
        }
    }

    Context 'Una funzionalita (D52): le card sotto la Feature, la chiusura in Draft, i motivi di Decisioni' {
        BeforeAll {
            # una card figlia della Feature 7; senza tag agenti non partirebbe (New-FintaCard ne mette uno)
            function New-CardFunz($Id, [string]$Chiave, $Tag = $null) {
                $c = New-FintaCard $Id $Chiave $Tag
                $c | Add-Member PadreId 7
                $c
            }
            function New-Figlia($Id, [string]$Chiave, $Tag = $null) {
                if ($null -eq $Tag) { $Tag = @($script:Cfg.Stati.tagAgenti) }
                [pscustomobject]@{ Id = [int]$Id; Stato = (St $Chiave); Tag = @($Tag); Tipo = 'User Story'; Titolo = "Titolo della card $Id" }
            }
        }
        BeforeEach {
            $script:Pagina = Join-Path $script:Dati 'vista.html'
            $global:Mondo.Feature = [pscustomobject]@{ Id = 7; Tipo = 'Feature'; Titolo = 'Esportare il riepilogo in PDF'; Stato = 'Active'; Tag = @(); Area = $script:Area; FigliIds = @(30, 31, 32) }
            $global:Mondo.Figli = @()
            Mock Get-AdoFeature { $global:Mondo.Feature }
            Mock Get-AdoFigliFeature { @($global:Mondo.Figli) }
            Mock Get-AdoRamoCard { 'feature/f7-esportare-il-riepilogo' }
        }

        It 'la card di chiusura in Draft (che Get-AdoCardAttive non da) va dall operatore, una volta sola, con il gesto che dice Decisioni' {
            $global:Mondo.Cards = @((New-CardFunz 30 'inFeature'), (New-CardFunz 31 'inFeature'), (New-CardFunz 32 'bozza'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            $global:Mondo.Figli = @((New-Figlia 30 'inFeature'), (New-Figlia 31 'inFeature'), (New-Figlia 32 'bozza' @($script:Cfg.Stati.tagChiusura, $script:Cfg.Stati.tagAgenti)))
            Set-StatoDiPartenza $script:Dati @{ '30' = @{ prId = 90; destinazione = 'feature/f7-esportare-il-riepilogo' }; '31' = @{ prId = 91; destinazione = 'feature/f7-esportare-il-riepilogo' } }
            @(Get-AdoCardAttive | Where-Object Id -eq 32).Count | Should -Be 0 -Because 'il finto scarta le Draft come la query vera'
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $op = Get-Colonna $h 'operatore'
            $op | Should -Match '(?s)data-attivita="sblocca" data-id="32".*<span class="gesto">sposta la card #32 in New</span>'
            @([regex]::Matches($op, 'data-id="32"')).Count | Should -Be 1
            $op | Should -Not -Match 'data-id="3[01]"'
            # le due sorelle restano nella kanban, una volta sola ciascuna, con il motivo
            (Get-Colonna $h 'pipeline') | Should -Match '(?s)data-id="30".*la card di chiusura della funzionalita \(#32\) e in Draft'
            (Get-Colonna $h 'pipeline') | Should -Match 'data-id="31"'
        }

        It 'la card di chiusura in Draft con una sorella non ancora unita non e una cosa da fare per l operatore' {
            $global:Mondo.Cards = @((New-CardFunz 30 'inFeature'), (New-CardFunz 31 'inSviluppo'), (New-CardFunz 32 'bozza'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            $global:Mondo.Figli = @((New-Figlia 30 'inFeature'), (New-Figlia 31 'inSviluppo'), (New-Figlia 32 'bozza' @($script:Cfg.Stati.tagChiusura, $script:Cfg.Stati.tagAgenti)))
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            (Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'operatore') | Should -Not -Match 'data-id="32"'
        }

        It 'le card della funzionalita stanno sotto la Feature, con lo stato della card di chiusura e dove sta ognuna' {
            $global:Mondo.Cards = @((New-CardFunz 30 'inFeature'), (New-CardFunz 31 'inFeature'), (New-CardFunz 32 'bozza'), (New-FintaCard 40 'nuova'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            $global:Mondo.Figli = @((New-Figlia 30 'inFeature'), (New-Figlia 31 'inFeature'), (New-Figlia 32 'bozza' @($script:Cfg.Stati.tagChiusura, $script:Cfg.Stati.tagAgenti)))
            Set-StatoDiPartenza $script:Dati @{ '30' = @{ prId = 90; destinazione = 'feature/f7-esportare-il-riepilogo' }; '31' = @{ prId = 91; destinazione = 'feature/f7-esportare-il-riepilogo' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '(?s)<div class="funzionalita-voce" data-feature="7">.*Esportare il riepilogo in PDF'
            $h | Should -Match '(?s)<div class="chiusura" data-id="32">.*?<span class="stato-board analisi">Draft</span>'
            $h | Should -Match '<li data-id="30">'
            $h | Should -Match '<li data-id="31">'
            $h | Should -Match '(?s)<li data-id="30">.*?<span class="stato-board unione">In feature branch</span>'
            $h | Should -Match '(?s)<div class="chiusura" data-id="32">.*?tocca a te: Sblocca'
            # la card isolata non e sotto nessuna Feature
            $h | Should -Not -Match '<li data-id="40">'
        }

        It 'una card In feature branch in on-hold, dall operatore, ha la fase feature branch' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inFeature' @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagAttesa))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inFeature'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'sessione'; ultimoRuolo = 'dev' } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            (Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'operatore') | Should -Match '(?s)data-id="5".*'
            (Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'operatore') | Should -Match '<span class="fase">feature branch</span>'
        }

        It 'una predecessora In feature branch e unita solo per le card della sua Feature: se ha anche una dipendente isolata resta in lavorazione' {
            $global:Mondo.Cards = @((New-CardFunz 30 'inFeature'), (New-CardFunz 33 'nuova'), (New-FintaCard 42 'nuova'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            $global:Mondo.Figli = @((New-Figlia 30 'inFeature'), (New-Figlia 33 'nuova'), (New-Figlia 34 'bozza' @($script:Cfg.Stati.tagChiusura, $script:Cfg.Stati.tagAgenti)))
            $global:Mondo.Predecessori['33'] = @([pscustomobject]@{ Id = 30; Stato = (St 'inFeature'); Tag = @('agents'); PadreId = 7 })
            $global:Mondo.Predecessori['42'] = @([pscustomobject]@{ Id = 30; Stato = (St 'inFeature'); Tag = @('agents'); PadreId = 7 })
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '<div data-id="30" class="nodo stato-lavorazione">'
            $h | Should -Not -Match '<div data-id="30" class="nodo stato-unita">'
        }

        It 'senza card di una funzionalita la pagina non ha la sezione' {
            $global:Mondo.Cards = @(New-FintaCard 40 'nuova'); $global:Mondo.Storia['40'] = New-FintaStoria 'nuova'
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            (Get-Content $script:Pagina -Raw -Encoding UTF8) | Should -Not -Match 'class="funzionalita-voce"'
        }

        It 'una predecessora In feature branch della stessa Feature e unita nella catena, una di un altra Feature no' {
            $global:Mondo.Cards = @((New-CardFunz 30 'inFeature'), (New-CardFunz 33 'nuova'), (New-FintaCard 41 'inFeature'), (New-FintaCard 42 'nuova'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            $global:Mondo.Figli = @((New-Figlia 30 'inFeature'), (New-Figlia 33 'nuova'), (New-Figlia 34 'bozza' @($script:Cfg.Stati.tagChiusura, $script:Cfg.Stati.tagAgenti)))
            $global:Mondo.Predecessori['33'] = @([pscustomobject]@{ Id = 30; Stato = (St 'inFeature'); Tag = @('agents'); PadreId = 7 })
            $global:Mondo.Predecessori['42'] = @([pscustomobject]@{ Id = 41; Stato = (St 'inFeature'); Tag = @('agents'); PadreId = 9 })
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '<div data-id="30" class="nodo stato-unita">'
            $h | Should -Match '<div data-id="41" class="nodo stato-lavorazione">'
        }

        It 'la chiusura che aspetta le sorelle: il riquadro Aspetta con i numeri, letto dal motivo di Decisioni' {
            $global:Mondo.Cards = @((New-CardFunz 30 'inFeature'), (New-CardFunz 31 'inSviluppo'), (New-CardFunz 32 'nuova'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            $global:Mondo.Figli = @((New-Figlia 30 'inFeature'), (New-Figlia 31 'inSviluppo'), (New-Figlia 32 'nuova' @($script:Cfg.Stati.tagChiusura, $script:Cfg.Stati.tagAgenti)))
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $resp = Get-Colonna $h 'responsabile'
            $resp | Should -Match '(?s)data-id="32".*<div class="aspetta"><ul><li><span class="aspetta-testo">Aspetta la card <[^>]*>#31</[^>]*>'
            $resp | Should -Not -Match 'aspetta-testo">Aspetta la card <[^>]*>#30'
        }

        It 'la sorella in Ready to merge mentre la chiusura prova la funzionalita: il motivo e quello di Decisioni' {
            $global:Mondo.Cards = @((New-CardFunz 31 'daUnire'), (New-CardFunz 32 'inCollaudo'), (New-CardFunz 30 'inFeature'))
            foreach ($c in $global:Mondo.Cards) { $global:Mondo.Storia["$($c.Id)"] = New-FintaStoria (Get-ChiaveStato $script:Cfg.Stati $c.Stato) }
            $global:Mondo.Figli = @((New-Figlia 30 'inFeature'), (New-Figlia 31 'daUnire'), (New-Figlia 32 'inCollaudo' @($script:Cfg.Stati.tagChiusura, $script:Cfg.Stati.tagAgenti)))
            Set-StatoDiPartenza $script:Dati @{ '31' = @{ ramo = 'feature/31-x'; destinazione = 'feature/f7-esportare-il-riepilogo'; cartella = 'C:/x'; prId = 70 } }
            Mock Get-AdoPr { [pscustomobject]@{ Id = 70; Stato = 'active'; Validazione = 'verde'; UrlLog = $null; BuildId = 5 } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '(?s)data-id="31".*aspetta il collaudo della funzionalita: la card di chiusura #32 e in Automated test'
        }
    }

    Context 'stato.json bloccato' {
        It 'se stato.json resta bloccato la vista non si ferma: disegna lo stesso e lo dice' {
            $global:Mondo.Cards = @(New-FintaCard 6 'nuova'); $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
            Set-StatoDiPartenza $script:Dati @{ '6' = @{ ultimoRuolo = 'dev' } }
            $blocco = [IO.File]::Open((Join-Path $script:Dati 'stato.json'), 'Open', 'Read', 'None')
            try { $out = Invoke-Vista $script:Dati }
            finally { $blocco.Dispose() }
            $out | Should -Match 'stato.json non si legge'
            $out | Should -Match '== In corso'
        }
    }

    Context 'Il supervisore' {
        BeforeEach {
            $script:Pagina = Join-Path $script:Dati 'vista.html'
            # lo smistatore e il supervisore hanno prossimi giri diversi: la vista deve chiedere la pianificazione giusta a ciascuno
            Mock Get-ScheduledTaskInfo { [pscustomobject]@{ NextRunTime = [datetime]'2026-11-18T10:05:00' } } -ParameterFilter { $TaskName -eq 'Supervisore' }
            $script:Ultima = (Get-Date).ToUniversalTime().AddMinutes(-3).ToString('o')
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo'); $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        }

        It 'la colonna sta subito dopo il collaudatore, prima dell operatore, col link al brief' {
            Set-SupervisoreDiPartenza $script:Dati @{ ultimaEsecuzione = $script:Ultima; problemi = @{} }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            @([regex]::Matches($h, 'data-colonna="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) | Should -Be @('responsabile', 'dev', 'reviewer', 'collaudatore', 'supervisore', 'operatore', 'pipeline')
            (Get-Colonna $h 'supervisore') | Should -Match '(?s)<h2>Supervisore<span class="conta">0</span> <a class="brief" href="brief-supervisore\.html" target="_blank" rel="noopener">brief</a>'
            Test-Path (Join-Path $script:Dati 'brief-supervisore.html') | Should -BeTrue
        }

        It 'con problemi mostra il conteggio nel badge, i testi e gli urgenti evidenziati, piu ultimo e prossimo giro' {
            Set-SupervisoreDiPartenza $script:Dati @{ ultimaEsecuzione = $script:Ultima; problemi = @{
                'quota' = @{ testo = 'La quota sta finendo'; urgente = $false; primoVisto = '2026-11-18T08:00:00Z' }
                'vista' = @{ testo = 'La vista non risponde'; urgente = $true; primoVisto = '2026-11-18T09:00:00Z' } } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $c = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'supervisore'
            $c | Should -Match '<h2>Supervisore<span class="conta">2</span>'
            $c | Should -Match '(?s)class="voce problema urgente"[^>]*>.*urgente</span> La vista non risponde</div>'
            $c | Should -Match 'class="voce problema" data-problema="quota">La quota sta finendo</div>'
            # l urgente viene prima
            $c.IndexOf('La vista non risponde') | Should -BeLessThan $c.IndexOf('La quota sta finendo')
            $c | Should -Match 'ultimo giro \d{4}-\d\d-\d\d \d\d:\d\d:\d\d'
            $c | Should -Match 'prossimo 2026-11-18 10:05'
            $c | Should -Not -Match 'nessun problema'
        }

        It 'senza problemi dice nessun problema' {
            Set-SupervisoreDiPartenza $script:Dati @{ ultimaEsecuzione = $script:Ultima; problemi = @{} }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $c = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'supervisore'
            $c | Should -Match '<p class="libero">nessun problema</p>'
            $c | Should -Not -Match 'problema urgente'
        }

        It 'con diagnosi in corso le mostra col testo del problema' {
            Set-SupervisoreDiPartenza $script:Dati @{ ultimaEsecuzione = $script:Ultima
                problemi = @{ 'vista' = @{ testo = 'La vista non risponde'; urgente = $true; primoVisto = '2026-11-18T09:00:00Z' } }
                sessioniDiagnosi = @(@{ id = 'd-1'; pid = 1; avvio = 'x'; chiave = 'vista'; inizio = '2026-11-18T09:01:00Z' }) }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $c = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'supervisore'
            $c | Should -Match '(?s)Diagnosi in corso<span class="conta">1</span></h3>\s*<div class="voce diagnosi">La vista non risponde</div>'
        }

        It 'senza supervisore.json la colonna dice stato non leggibile e la pagina si disegna lo stesso' {
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $c = Get-Colonna $h 'supervisore'
            $c | Should -Match '<p class="libero">stato non leggibile</p>'
            $c | Should -Not -Match 'nessun problema'
            $c | Should -Match 'prossimo 2026-11-18 10:05'
            (Get-Colonna $h 'dev') | Should -Match 'libero'
        }

        It 'con supervisore.json illeggibile (JSON a meta o bloccato) la colonna dice stato non leggibile e la vista non si ferma' {
            Set-Content (Join-Path $script:Dati 'supervisore.json') '{ "problemi": { "a": ' -Encoding UTF8
            { Invoke-Vista $script:Dati @{ Html = $true } } | Should -Not -Throw
            (Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'supervisore') | Should -Match 'stato non leggibile'
            Set-SupervisoreDiPartenza $script:Dati @{ problemi = @{} }
            $blocco = [IO.File]::Open((Join-Path $script:Dati 'supervisore.json'), 'Open', 'Read', 'None')
            try { Invoke-Vista $script:Dati @{ Html = $true } | Out-Null }
            finally { $blocco.Dispose() }
            (Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'supervisore') | Should -Match 'stato non leggibile'
        }

        It 'nell uscita testo c e la riga del supervisore, e non scrive supervisore.json' {
            Set-SupervisoreDiPartenza $script:Dati @{ ultimaEsecuzione = $script:Ultima; problemi = @{
                'quota' = @{ testo = 'q'; urgente = $false; primoVisto = '2026-11-18T08:00:00Z' }
                'vista' = @{ testo = 'v'; urgente = $true; primoVisto = '2026-11-18T09:00:00Z' } }
                sessioniDiagnosi = @(@{ id = 'd-1'; chiave = 'vista'; inizio = '2026-11-18T09:01:00Z' }) }
            $prima = Get-Impronta $script:Dati
            $out = Invoke-Vista $script:Dati
            $out | Should -Match 'Ultimo giro del supervisore: \d{4}-\d\d-\d\d \d\d:\d\d:\d\d \| prossimo giro: 2026-11-18 10:05 \| problemi aperti: 2 \(1 urgenti\) \| diagnosi in corso: 1'
            Get-Impronta $script:Dati | Should -Be $prima
        }

        It 'smistatore e supervisore hanno ciascuno il proprio prossimo giro, nel testo e nella pagina' {
            Mock Get-ScheduledTaskInfo { [pscustomobject]@{ NextRunTime = [datetime]'2026-11-18T10:04:00' } } -ParameterFilter { $TaskName -eq 'Smistatore' }
            Set-SupervisoreDiPartenza $script:Dati @{ ultimaEsecuzione = $script:Ultima; problemi = @{} }
            $out = Invoke-Vista $script:Dati
            $out | Should -Match 'Ultimo giro dello smistatore: [^|]*\| prossimo giro: 2026-11-18 10:04\r?\n'
            $out | Should -Match 'Ultimo giro del supervisore: [^|]*\| prossimo giro: 2026-11-18 10:05 \|'
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match 'Ultimo giro dello smistatore [^&]*&middot; prossimo 2026-11-18 10:04</p>'
            (Get-Colonna $h 'supervisore') | Should -Match 'prossimo 2026-11-18 10:05</p>'
        }

        It 'i problemi si ordinano per data di primo avvistamento anche a cavallo d anno, gli urgenti per primi' {
            Set-SupervisoreDiPartenza $script:Dati @{ ultimaEsecuzione = $script:Ultima; problemi = @{
                'nuovo' = @{ testo = 'Visto a gennaio'; urgente = $false; primoVisto = '2026-01-02T08:00:00Z' }
                'vecchio' = @{ testo = 'Visto a dicembre'; urgente = $false; primoVisto = '2025-12-30T08:00:00Z' } } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $c = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'supervisore'
            $c.IndexOf('Visto a dicembre') | Should -BeLessThan $c.IndexOf('Visto a gennaio')
        }

        It 'l ultimo giro e l ora UTC di ultimaEsecuzione convertita nel fuso locale' {
            Set-SupervisoreDiPartenza $script:Dati @{ ultimaEsecuzione = '2026-11-18T09:58:07Z'; problemi = @{} }
            $atteso = ([datetime]'2026-11-18T09:58:07Z').ToUniversalTime().ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            Invoke-Vista $script:Dati | Should -Match "Ultimo giro del supervisore: $atteso \|"
        }

        It 'il testo di un problema e la sua chiave escono codificati nella pagina' {
            Set-SupervisoreDiPartenza $script:Dati @{ ultimaEsecuzione = $script:Ultima; problemi = @{
                'a"b' = @{ testo = '<script>alert(1)</script>'; urgente = $true; primoVisto = '2026-11-18T08:00:00Z' } } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $c = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'supervisore'
            $c | Should -Not -Match '<script>'
            $c | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
            $c | Should -Match 'data-problema="a&quot;b"'
        }

        It 'un supervisore.json vuoto non e "nessun problema": e stato non leggibile' {
            [IO.File]::WriteAllText((Join-Path $script:Dati 'supervisore.json'), '', [Text.UTF8Encoding]::new($false))
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $c = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'supervisore'
            $c | Should -Match 'stato non leggibile'
            $c | Should -Not -Match 'nessun problema'
        }

        It 'un problema aperto ma da non dire (assenze > 0) non si conta e non si mostra' {
            Set-SupervisoreDiPartenza $script:Dati @{ ultimaEsecuzione = $script:Ultima; problemi = @{
                'visto' = @{ testo = 'Ancora qui'; urgente = $false; primoVisto = '2026-11-18T08:00:00Z'; assenze = 0 }
                'sparito' = @{ testo = 'Non si vede piu'; urgente = $true; primoVisto = '2026-11-18T08:00:00Z'; assenze = 1 } } }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $c = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'supervisore'
            $c | Should -Match '<span class="conta">1</span>'
            $c | Should -Match 'Ancora qui'
            $c | Should -Not -Match 'Non si vede piu'
            Invoke-Vista $script:Dati | Should -Match 'problemi aperti: 1 \(0 urgenti\)'
        }

        It 'nell uscita testo, senza supervisore.json, la riga dice stato non leggibile' {
            Invoke-Vista $script:Dati | Should -Match 'Ultimo giro del supervisore: stato non leggibile \| prossimo giro: 2026-11-18 10:05'
        }
    }

    Context 'La suite (D53, punto 8)' {
        BeforeEach {
            $script:Pagina = Join-Path $script:Dati 'vista.html'
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo'); $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            $script:StatoSuite = [ordered]@{
                canale = 'main'; automatico = $true
                installata = [ordered]@{ canale = 'main'; hash = 'abc1234'; data = '2026-11-20T09:30:00Z' }
                disponibile = [ordered]@{ canale = 'main'; hash = 'def5678'; data = '2026-11-25T09:30:00Z' }
                ultimoControllo = '2026-11-25T10:00:00Z'; erroreControllo = $null
                ultimoEsito = [ordered]@{ esito = 'inAttesaSessioni'; quando = '2026-11-25T10:00:00Z'; da = '2026-11-25T09:00:00Z'; oltreSoglia = $false }
                scartato = $null; attesaSegnalata = $false
                prInArrivo = @([ordered]@{ numero = 1202; titolo = 'Una PR'; url = 'https://acme.visualstudio.com/P/_git/R/pullrequest/1202' }, [ordered]@{ numero = 1201; titolo = 'Senza link'; url = $null })
            }
        }
        It 'senza aggiornamento.json il riquadro c e e dice che non c e stato nessun controllo' {
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $h | Should -Match '(?s)<section class="suite" data-sezione="suite"><h2>Suite</h2>.*nessun controllo ancora fatto'
        }
        It 'con lo stato: versione installata e disponibile, ultimo controllo, stato e le PR in arrivo col link come gli altri link ADO' {
            [IO.File]::WriteAllText((Join-Path $script:Dati 'aggiornamento.json'), ($script:StatoSuite | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            $h = Get-Content $script:Pagina -Raw -Encoding UTF8
            $suite = [regex]::Match($h, '(?s)<section class="suite".*?</section>').Value
            $suite | Should -Match 'Installata: <b>main abc1234 \(20/11/2026\)</b>'
            $suite | Should -Match 'Disponibile: <b>main def5678 \(25/11/2026\)</b>'
            $suite | Should -Match 'Ultimo controllo: <b>\d\d/\d\d \d\d:\d\d</b>'
            $suite | Should -Match 'Stato: in attesa che finiscano le sessioni degli agenti'
            $suite | Should -Match '<a href="https://acme.visualstudio.com/P/_git/R/pullrequest/1202" target="_blank" rel="noopener">PR 1202</a>: Una PR'
            $suite | Should -Match '<li>PR 1201: Senza link</li>'
            # senza server niente comandi, ma l interruttore si legge
            $suite | Should -Not -Match '<button'
            $suite | Should -Match 'Aggiornamento automatico: <b>acceso</b>'
        }
        It 'l interruttore e quello di impostazioni.json, non quello che il supervisore ha scritto l ultima volta' {
            [IO.File]::WriteAllText((Join-Path $script:Dati 'aggiornamento.json'), ($script:StatoSuite | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $script:Dati 'impostazioni.json'), '{ "aggiornamentoAutomatico": false }', [Text.UTF8Encoding]::new($false))
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            (Get-Content $script:Pagina -Raw -Encoding UTF8) | Should -Match 'Aggiornamento automatico: <b>spento</b>'
        }
        It 'nel terminale una riga Suite con versioni, controllo, automatico e stato' {
            [IO.File]::WriteAllText((Join-Path $script:Dati 'aggiornamento.json'), ($script:StatoSuite | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
            $out = Invoke-Vista $script:Dati
            $out | Should -Match 'Suite: installata main abc1234 \(20/11/2026\) \| disponibile main def5678 \(25/11/2026\) \| ultimo controllo \d\d/\d\d \d\d:\d\d \| automatico acceso \| in attesa'
        }
        It 'legge soltanto: aggiornamento.json e impostazioni.json restano com erano, e nessuna richiesta di aggiornamento nasce' {
            [IO.File]::WriteAllText((Join-Path $script:Dati 'aggiornamento.json'), ($script:StatoSuite | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $script:Dati 'impostazioni.json'), '{ "canale": "develop" }', [Text.UTF8Encoding]::new($false))
            $prima = @('aggiornamento.json', 'impostazioni.json') | ForEach-Object { (Get-FileHash (Join-Path $script:Dati $_)).Hash }
            Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
            @('aggiornamento.json', 'impostazioni.json') | ForEach-Object { (Get-FileHash (Join-Path $script:Dati $_)).Hash } | Should -Be $prima
            Test-Path (Join-Path $script:Dati 'aggiorna-suite.richiesta') | Should -BeFalse
        }
    }

    Context 'Sola lettura' {
        It 'non scrive niente: ne file nella cartella dati, ne Azure DevOps, ne sessioni' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inSviluppo'), (New-FintaCard 6 'nuova'), (New-FintaCard 7 'inRevisione'))
            foreach ($i in 5, 6, 7) { $global:Mondo.Storia["$i"] = New-FintaStoria @{ 5 = 'inSviluppo'; 6 = 'nuova'; 7 = 'inRevisione' }[$i] }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev' }; '7' = @{ avvisi = @('testPronto@20') } }
            Set-Uscita $script:Dati 'sid-1' @((New-Riga 'm1' (New-Uso 'Read' @{ file_path = 'C:/a' })))
            Set-LogDiOggi $script:Dati @('2026-11-18 10:02:03 INFO x')
            $prima = Get-Impronta $script:Dati
            Invoke-Vista $script:Dati | Out-Null
            Get-Impronta $script:Dati | Should -Be $prima
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            Should -Invoke Add-AdoCommento -Times 0 -Exactly
            Should -Invoke New-AdoPr -Times 0 -Exactly
            Should -Invoke Set-AdoTaskStato -Times 0 -Exactly
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
            Should -Invoke Stop-Sessione -Times 0 -Exactly
            Should -Invoke Save-Stato -Times 0 -Exactly
            Should -Invoke Write-RegistroSessione -Times 0 -Exactly
            Should -Invoke Add-RevNostra -Times 0 -Exactly
        }

        It 'senza una cartella dati non la crea' {
            $assente = Join-Path $TestDrive 'non-esiste'
            Invoke-Vista $assente | Out-Null
            Test-Path $assente | Should -BeFalse
        }
    }
}


Describe 'New-PaginaSessione: la pagina dello stream di una sessione' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/VistaHtml.psm1') -Force
        $script:Sess = [pscustomobject]@{ Id = 5; SessioneId = 'sid-1'; Titolo = 'Titolo <x>'; Repo = 'R'; Ruolo = 'dev'; Task = 55; TitoloTask = 'T'; Minuti = 12; TokenTesto = '3.3k token'; Viva = $true }
        function Ev($Tipo, $Testo, $Nome = $null, $Tagliato = $false) { [pscustomobject]@{ Tipo = $Tipo; Testo = $Testo; Nome = $Nome; Tagliato = $Tagliato; Errore = $false } }
    }
    It 'in cima ha card, titolo, ruolo, task, minuti e token; gli eventi seguono nell ordine' {
        $h = New-PaginaSessione $script:Sess @((Ev 'testo' 'primo'), (Ev 'strumento' 'command: ls' 'Bash'), (Ev 'risultato' 'out'), (Ev 'esito' 'ESITO=ok')) 0 $false 10
        $h | Should -Match '#5'
        $h | Should -Match 'Titolo &lt;x&gt;'
        $h | Should -Match '12 min'
        $h | Should -Match '3\.3k token'
        $h | Should -Match '(?s)primo.*Bash.*command: ls.*out.*ESITO=ok'
        $h | Should -Not -Match 'sessione finita'
    }
    It 'dice che un risultato e tagliato, quanti eventi ha saltato e separa le riprese' {
        $h = New-PaginaSessione $script:Sess @((Ev 'risultato' 'abc' $null $true), (Ev 'ripresa' 'ripresa 2')) 42 $false 10
        $h | Should -Match 'tagliato'
        $h | Should -Match '42 eventi'
        $h | Should -Match 'ripresa 2'
    }
    It 'una sessione finita lo dice in cima' {
        $h = New-PaginaSessione $script:Sess @() 0 $true 10
        $h | Should -Match '(?s)<h1>.*sessione finita'
    }
    It 'codifica ogni testo dello stream' {
        $h = New-PaginaSessione $script:Sess @((Ev 'testo' '<script>alert(1)</script>'), (Ev 'strumento' '<img src=x>' '<b>')) 0 $false 10
        $h | Should -Not -Match '<script>alert'
        $h | Should -Not -Match '<img'
        $h | Should -Match '&lt;b&gt;'
        $h | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
    }
    It 'lo scorrimento ricorda in sessionStorage se l utente e risalito, con ogni accesso in try/catch' {
        $h = New-PaginaSessione $script:Sess @((Ev 'testo' 'a')) 0 $false 10
        $js = [regex]::Match($h, '(?s)<script>(.*?)</script>').Groups[1].Value
        $js | Should -Match 'sessionStorage\.getItem'
        $js | Should -Match 'sessionStorage\.setItem'
        $js | Should -Match 'scrollTo'
        @([regex]::Matches($js, 'try \{')).Count | Should -Be 2
    }
}


Describe 'La riga della PR su ogni scheda' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/VistaHtml.psm1') -Force
        function New-PrModello([string]$Validazione, $UrlLog = $null) {
            [pscustomobject]@{ Id = 33; Validazione = $Validazione; Url = 'https://ado/pr/33'; UrlLog = $UrlLog }
        }
        # Un modello minimo con la stessa PR in ognuna delle quattro posizioni della kanban.
        function New-ModelloConPr($Pr) {
            $sess = [pscustomobject]@{ Id = 1; SessioneId = 's1'; Titolo = 'a'; Repo = 'r'; Ruolo = 'dev'; StatoAdo = $null; Task = $null; TitoloTask = $null; Minuti = 1; Viva = $true; TokenTesto = $null; Azioni = @(); Avanzamento = $null; Pr = $Pr }
            $coda = [pscustomobject]@{ Id = 2; Titolo = 'b'; Stato = 's'; Ruolo = 'dev'; Testo = 't'; Avanzamento = $null; Pr = $Pr }
            $op = [pscustomobject]@{ Id = 3; Titolo = 'c'; Attivita = 'prova'; Verbo = 'Prova in Test'; Fase = $null; Testo = 't'; Pr = $Pr }
            $pip = [pscustomobject]@{ Id = 4; Titolo = 'd'; Stato = 's'; Testo = 't'; Pr = $Pr }
            [pscustomobject]@{
                Generata = Get-Date; ErroreAdo = $null; InCorso = @($sess); Coda = @(); Catene = @(); UltimoGiro = 'x'; ProssimoGiro = 'y'
                Agenti = @([pscustomobject]@{ Ruolo = 'dev'; Sessioni = @($sess); Coda = @($coda); Brief = $null })
                Operatore = [pscustomobject]@{ Fermano = @(); NonFermano = @($op) }; Pipeline = @($pip)
            }
        }
    }
    It 'in ogni posizione la riga ha il numero con il link e lo stato' {
        $h = New-PaginaVista (New-ModelloConPr (New-PrModello 'verde'))
        @([regex]::Matches($h, 'class="pr pr-verde"')).Count | Should -Be 4
        @([regex]::Matches($h, '<a href="https://ado/pr/33"[^>]*>PR #33</a>')).Count | Should -Be 4
        (Get-Colonna $h 'operatore') | Should -Match 'pr-verde'
        (Get-Colonna $h 'pipeline') | Should -Match 'pr-verde'
        (Get-Colonna $h 'dev') | Should -Match '(?s)pr-verde.*pr-verde'
    }
    It 'mostra lo stato giusto per ognuno dei cinque casi' {
        $attesi = @{ verde = 'verde'; rossa = 'rossa'; inCorso = 'in corso'; conflitti = 'in conflitto'; assente = 'assente' }
        foreach ($k in $attesi.Keys) {
            $h = New-PaginaVista (New-ModelloConPr (New-PrModello $k))
            $h | Should -Match "class=""pr pr-$k"""
            $h | Should -Match "(?s)pr-$k"".*?$($attesi[$k])"
        }
    }
    It 'il link al log c e solo se la validazione e rossa o in corso' {
        foreach ($k in 'rossa', 'inCorso') {
            $h = New-PaginaVista (New-ModelloConPr (New-PrModello $k 'https://ado/log/7'))
            @([regex]::Matches($h, '<a href="https://ado/log/7"[^>]*>log</a>')).Count | Should -Be 4
        }
        foreach ($k in 'verde', 'conflitti', 'assente') {
            New-PaginaVista (New-ModelloConPr (New-PrModello $k 'https://ado/log/7')) | Should -Not -Match 'ado/log/7'
        }
        # rossa senza URL (build non nota): niente link rotto
        New-PaginaVista (New-ModelloConPr (New-PrModello 'rossa')) | Should -Not -Match '>log</a>'
    }
    It 'senza PR non c e la riga' {
        New-PaginaVista (New-ModelloConPr $null) | Should -Not -Match 'class="pr '
    }
    It 'codifica numero e link' {
        $pr = [pscustomobject]@{ Id = 33; Validazione = 'rossa'; Url = 'https://ado/"><script>x</script>'; UrlLog = 'https://ado/"onclick="y' }
        $h = New-PaginaVista (New-ModelloConPr $pr)
        $h | Should -Not -Match '<script>x'
        $h | Should -Not -Match 'href="https://ado/"onclick'
    }
    It 'un modello senza il campo Pr (come i vecchi) si disegna senza riga' {
        $m = New-ModelloConPr $null
        $m.Pipeline[0].PSObject.Properties.Remove('Pr')
        { New-PaginaVista $m } | Should -Not -Throw
    }
}

Describe 'Vista: la PR letta dai dati' {
    BeforeEach {
        $script:Dati = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:Dati | Out-Null
        $global:Mondo = @{ Cards = @(); Commenti = @{}; Storia = @{}; Pr = @{}; Task = @{}; Predecessori = @{} }
        Mock Get-AdoUtenteCorrente { [pscustomobject]@{ Id = 'u-ric'; Nome = 'Titolare' } }
        # come la query vera (Get-AdoCardAttive): le card in Draft non ci sono
        Mock Get-AdoCardAttive { @($global:Mondo.Cards | Where-Object { $_.Stato -ne 'Draft' }) }
        Mock Get-AdoCard { param($Id) $global:Mondo.Cards | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
        Mock Get-AdoCommenti { param($Id, $DopoId = 0) @() }
        Mock Get-AdoStoriaStato { param($Id) @($global:Mondo.Storia["$Id"]) }
        Mock Get-AdoTaskFigli { param($CardId) @() }
        Mock Get-AdoCardPredecessori { param($CardId) @() }
        Mock Get-AdoPr { param($Progetto, $Repo, $Ramo, [switch]$AncheCompletate) $global:Mondo.Pr[$Ramo] }
        Mock Get-AdoRun { $null }
        Mock Test-SessioneViva { $true }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ NextRunTime = [datetime]'2026-11-18T10:04:00' } }
        Mock Save-Stato { }
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-1'); ultimoRuolo = 'dev'; ramo = 'feature/5-x'; cartella = 'C:/x' } }
        $script:Pagina = Join-Path $script:Dati 'vista.html'
    }
    It 'una card con la sessione aperta mostra la PR letta sul suo ramo, con il link costruito da Ado' {
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 33; Stato = 'active'; Validazione = 'rossa'; BuildId = 7; UrlLog = 'https://log/7' }
        Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
        $col = Get-Colonna (Get-Content $script:Pagina -Raw -Encoding UTF8) 'dev'
        $col | Should -Match 'pr-rossa'
        $col | Should -Match 'Acme\.AI/_git/Acme\.AI/pullrequest/33'
        $col | Should -Match 'href="https://log/7"'
        Should -Invoke Get-AdoPr -ParameterFilter { $Ramo -eq 'feature/5-x' -and $Repo -eq 'Acme.AI' }
    }
    It 'senza PR sul ramo la scheda non ha la riga' {
        Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
        Get-Content $script:Pagina -Raw -Encoding UTF8 | Should -Not -Match 'class="pr '
    }
    It 'se la PR non si legge la vista va avanti senza la riga' {
        Mock Get-AdoPr { throw 'boom' }
        Invoke-Vista $script:Dati @{ Html = $true } | Out-Null
        $h = Get-Content $script:Pagina -Raw -Encoding UTF8
        $h | Should -Match 'data-id="5"'
        $h | Should -Not -Match 'class="pr '
        $h | Should -Not -Match 'Azure DevOps non risponde'
    }
}

Describe 'VistaCodice: il riavvio quando cambia il codice' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/VistaCodice.psm1') -Force
        $script:T0 = [datetime]'2026-11-18T10:00:00Z'
    }
    It 'Get-DateCodice legge src/*.ps1, src/*.psm1 e config/*.json e nient altro' {
        $r = Join-Path $TestDrive 'radice'
        foreach ($d in 'src', 'config', 'docs') { New-Item -ItemType Directory (Join-Path $r $d) -Force | Out-Null }
        foreach ($f in 'src/a.ps1', 'src/b.psm1', 'src/c.txt', 'config/d.json', 'config/e.md', 'docs/f.json') { Set-Content (Join-Path $r $f) 'x' }
        $d = Get-DateCodice $r
        @($d.Keys | Sort-Object) | Should -Be @('config/d.json', 'src/a.ps1', 'src/b.psm1')
    }
    It 'nessun cambio se le date sono uguali' {
        Get-CambioCodice @{ 'src/a.ps1' = $script:T0 } @{ 'src/a.ps1' = $script:T0 } | Should -BeNullOrEmpty
    }
    It 'riconosce un file modificato, uno aggiunto e uno tolto' {
        $base = @{ 'src/a.ps1' = $script:T0; 'src/b.ps1' = $script:T0 }
        Get-CambioCodice $base @{ 'src/a.ps1' = $script:T0.AddMinutes(1); 'src/b.ps1' = $script:T0 } | Should -Not -BeNullOrEmpty
        Get-CambioCodice $base @{ 'src/a.ps1' = $script:T0; 'src/b.ps1' = $script:T0; 'src/c.ps1' = $script:T0 } | Should -Not -BeNullOrEmpty
        Get-CambioCodice $base @{ 'src/a.ps1' = $script:T0 } | Should -Not -BeNullOrEmpty
    }
    It 'non riavvia al primo cambio visto, riavvia al secondo uguale' {
        $base = @{ 'src/a.ps1' = $script:T0 }
        $ora = @{ 'src/a.ps1' = $script:T0.AddMinutes(1) }
        $e1 = Get-EsitoRiavvio $base $ora $null
        $e1.Riavvia | Should -BeFalse
        $e1.Cambio | Should -Not -BeNullOrEmpty
        (Get-EsitoRiavvio $base $ora $e1.Cambio).Riavvia | Should -BeTrue
    }
    It 'se il cambiamento e ancora in corso (diverso dal giro prima) aspetta ancora' {
        $base = @{ 'src/a.ps1' = $script:T0 }
        $e1 = Get-EsitoRiavvio $base @{ 'src/a.ps1' = $script:T0.AddMinutes(1) } $null
        (Get-EsitoRiavvio $base @{ 'src/a.ps1' = $script:T0.AddMinutes(2) } $e1.Cambio).Riavvia | Should -BeFalse
    }
    It 'senza cambiamenti azzera l attesa e non riavvia' {
        $base = @{ 'src/a.ps1' = $script:T0 }
        $e = Get-EsitoRiavvio $base $base 'qualcosa'
        $e.Riavvia | Should -BeFalse
        $e.Cambio | Should -BeNullOrEmpty
    }
}

Describe 'VistaCodice: il supervisore a profondita fissa' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot '../src/VistaCodice.psm1') -Force }
    It 'il codice riservato al riavvio e 75' {
        Get-CodiceRiavvio | Should -Be 75
    }
    It 'gli argomenti del figlio: switch senza valore, gli altri con il valore, -Apri solo al primo' {
        $p = @{ Segui = [switch]$true; Html = [switch]$true; Apri = [switch]$true; Secondi = 5; CartellaDati = 'C:\a b' }
        $primo = @(Get-ArgomentiFiglio $p $true)
        $primo | Should -Contain '-Apri'
        $primo | Should -Contain '-Segui'
        $primo[$primo.IndexOf('-Secondi') + 1] | Should -Be '5'
        $primo[$primo.IndexOf('-CartellaDati') + 1] | Should -Be 'C:\a b'
        @(Get-ArgomentiFiglio $p $false) | Should -Not -Contain '-Apri'
        @(Get-ArgomentiFiglio $p $false) | Should -Contain '-Html'
    }
    It 'un switch spento non si passa' {
        @(Get-ArgomentiFiglio @{ Segui = [switch]$true; Apri = [switch]$false } $true) | Should -Not -Contain '-Apri'
    }
    It 'rilancia il figlio finche esce con 75, poi termina con il codice dell ultimo' {
        $script:chiamate = [System.Collections.Generic.List[bool]]::new()
        $codici = [System.Collections.Generic.Queue[int]]::new([int[]](75, 75, 75, 0))
        $r = Invoke-SupervisoreVista { param($primo) $script:chiamate.Add($primo); $codici.Dequeue() }
        $r | Should -Be 0
        @($script:chiamate).Count | Should -Be 4
        # -Apri vale solo per il primo figlio
        @($script:chiamate) | Should -Be @($true, $false, $false, $false)
    }
    It 'con un altro codice termina subito con quello stesso codice' {
        $script:n = 0
        $r = Invoke-SupervisoreVista { param($primo) $script:n++; 3 }
        $r | Should -Be 3
        $script:n | Should -Be 1
    }
}

Describe 'Il numero della card e un link alla card su Azure DevOps' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/VistaHtml.psm1') -Force
        $script:Url = { param($Id) "https://ado.test/Proj/_workitems/edit/$Id" }
        $script:Link = { param($Id) "<a class=`"card`" href=`"https://ado.test/Proj/_workitems/edit/$Id`" target=`"_blank`" rel=`"noopener`"><span class=`"num`">#$Id</span>" }
        function New-ModelloConLink([bool]$ConUrl = $true) {
            $u = { param($Id) if ($ConUrl) { "https://ado.test/Proj/_workitems/edit/$Id" } else { $null } }
            $sess = [pscustomobject]@{ Id = 5; UrlCard = (& $u 5); SessioneId = 'sid-1'; Titolo = 'T5'; Repo = 'R'; StatoAdo = 'x'; Ruolo = 'dev'; Task = $null; TitoloTask = $null; Minuti = 3; TokenTesto = $null; Viva = $true; Avanzamento = $null; Azioni = @(); Pr = $null }
            $coda = [pscustomobject]@{ Id = 6; UrlCard = (& $u 6); Titolo = 'T6'; Stato = 'x'; Ruolo = 'dev'; Testo = 'parte'; Avanzamento = $null; Pr = $null }
            $voce = [pscustomobject]@{ Id = 7; UrlCard = (& $u 7); Titolo = 'T7'; Attivita = 'prova'; Verbo = 'prova'; Fase = $null; Testo = 't'; Pr = $null }
            $pipe = [pscustomobject]@{ Id = 8; UrlCard = (& $u 8); Titolo = 'T8'; Stato = 's'; Testo = 'aspetta'; Pr = $null }
            $nodo = [pscustomobject]@{ Id = 9; UrlCard = (& $u 9); Stato = 'coda'; Titolo = 'T9'; StatoBoard = 'b'; Dove = $null }
            [pscustomobject]@{
                Generata = [datetime]'2026-11-18T10:00:00'; ErroreAdo = $null; InCorso = @($sess); Coda = @(); Catene = @([pscustomobject]@{ Nodi = @($nodo) })
                Agenti = @([pscustomobject]@{ Ruolo = 'dev'; Sessioni = @($sess); Coda = @($coda); Brief = $null })
                Operatore = [pscustomobject]@{ Fermano = @($voce); NonFermano = @() }; Pipeline = @($pipe); UltimoGiro = 'x'; ProssimoGiro = 'y'
            }
        }
    }
    It 'e un link in scheda, coda, operatore, pipeline e catena' {
        $h = New-PaginaVista (New-ModelloConLink) 10
        foreach ($i in 5, 6, 7, 8, 9) { $h | Should -Match ([regex]::Escape((& $script:Link $i))) }
    }
    It 'senza URL il numero resta testo semplice' {
        $h = New-PaginaVista (New-ModelloConLink $false) 10
        $h | Should -Not -Match '_workitems'
        foreach ($i in 5, 6, 7, 8, 9) { $h | Should -Match "<span class=`"num`">#$i</span>|<b>#$i " }
    }
    It 'la testata della pagina di una sessione ha il link, e senza URL niente' {
        $s = [pscustomobject]@{ Id = 5; UrlCard = 'https://ado.test/Proj/_workitems/edit/5?a=1&b=2'; SessioneId = 'sid-1'; Titolo = 'T'; Repo = 'R'; Ruolo = 'dev'; Task = $null; TitoloTask = $null; Minuti = 1; TokenTesto = $null; Viva = $true }
        New-PaginaSessione $s @() 0 $false 10 | Should -Match '<h1><a class="card" href="https://ado\.test/Proj/_workitems/edit/5\?a=1&amp;b=2" target="_blank" rel="noopener"><span class="num">#5</span>'
        $s.UrlCard = $null
        $h = New-PaginaSessione $s @() 0 $false 10
        $h | Should -Not -Match '_workitems'
        $h | Should -Match '<h1><span class="num">#5</span>'
    }
    It 'un URL che non e http(s) non diventa link' {
        $m = New-ModelloConLink; $m.Pipeline[0].UrlCard = 'javascript:alert(1)'
        (New-PaginaVista $m 10) | Should -Not -Match 'javascript:'
    }
}

Describe 'Vista: il modello porta UrlCard' {
    BeforeAll { foreach ($m in 'Config', 'Ado', 'Stato', 'Decisioni', 'Sessioni') { Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Global } }
    It 'Get-AdoUrlCard da l indirizzo che la vista deve usare' {
        Get-AdoUrlCard -Id 23 | Should -Match '/_workitems/edit/23$'
    }
}

Describe 'I pulsanti "Avvia smistatore" e "Aggiorna agenti e card", i contatori e il token nella pagina' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/VistaHtml.psm1') -Force
        function New-ModelloVuoto {
            [pscustomobject]@{
                Generata = [datetime]'2026-11-18T10:00:00'; ErroreAdo = $null; InCorso = @(); Coda = @(); Catene = @()
                Agenti = @([pscustomobject]@{ Ruolo = 'dev'; Sessioni = @(); Coda = @(); Brief = $null })
                Operatore = [pscustomobject]@{ Fermano = @(); NonFermano = @() }; Pipeline = @(); UltimoGiro = 'x'; ProssimoGiro = 'y'
                ProssimoGiroIso = '2026-11-18T10:05:00.0000000+01:00'
            }
        }
    }
    It 'con il token la pagina ha il pulsante in testa, prima della kanban, e il token in un attributo' {
        $t = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        $h = New-PaginaVista (New-ModelloVuoto) 10 $t
        $h | Should -Match '(?s)<h1>Agenti</h1>.*<button[^>]*id="giro"[^>]*>Avvia smistatore</button>.*class="kanban"'
        $h | Should -Match '(?s)<h1>Agenti</h1>.*<button[^>]*id="aggiorna"[^>]*>Aggiorna agenti e card</button>.*class="kanban"'
        $h | Should -Match ('id="giro" data-token="' + $t + '"')
        $h | Should -Match ('id="aggiorna" data-token="' + $t + '"')
        $h | Should -Match 'id="giro-esito"'
    }
    Context 'Togli on-hold (D37)' {
        BeforeAll {
            function New-ModelloConVoce([bool]$InAttesa) {
                $m = New-ModelloVuoto
                $voce = [pscustomobject]@{ Id = 5; UrlCard = $null; Titolo = 't'; Attivita = 'sblocca'; Verbo = 'Sblocca'; Fase = $null; Testo = 'limite <x>'; Pr = $null; InAttesa = $InAttesa }
                $m.Operatore = [pscustomobject]@{ Fermano = @($voce); NonFermano = @() }
                $m
            }
        }
        It 'una card in on-hold ha il pulsante, col motivo dell attesa ancora visibile' {
            $h = New-PaginaVista (New-ModelloConVoce $true) 10 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
            $h | Should -Match '<button type="button" class="togli-attesa" id="togli-attesa-5" data-id="5" data-token="a1b2c3d4e5f60718293a4b5c6d7e8f90">Togli on-hold</button>'
            $h | Should -Match '(?s)data-id="5"[^>]*data-on-hold="1".*<span class="motivo">limite &lt;x&gt;</span>.*class="togli-attesa"'
        }
        It 'senza on-hold o senza server non c e pulsante' {
            (New-PaginaVista (New-ModelloConVoce $false) 10 'a1b2c3d4e5f60718293a4b5c6d7e8f90') | Should -Not -Match 'togli-attesa"'
            (New-PaginaVista (New-ModelloConVoce $true) 10) | Should -Not -Match 'togli-attesa"'
        }
        It 'il clic chiede conferma, fa POST /togli-attesa?id= col token, mostra caricamento ed esito e non scrive HTML' {
            $h = New-PaginaVista (New-ModelloConVoce $true) 10 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
            $s = [regex]::Match($h, "(?s)<script>(?:(?!</script>).)*togli-attesa.*?</script>").Value
            $s | Should -Not -BeNullOrEmpty
            $s | Should -Match 'confirm\('
            $s | Should -Match "'/togli-attesa\?id=' \+ encodeURIComponent\(t\.dataset\.id\)"
            $s | Should -Match "method: 'POST'"
            $s | Should -Match 'X-Vista-Token'
            $s | Should -Match 'tolgo il tag on-hold'
            $s | Should -Not -Match 'innerHTML'
        }
    }
    It 'Aggiorna fa POST /aggiorna con il token e ricarica la pagina quando il server l ha ridisegnata' {
        $h = New-PaginaVista (New-ModelloVuoto) 10 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        $s = [regex]::Match($h, "(?s)<script>(?:(?!</script>).)*rileggi\(a, '/aggiorna'.*?</script>").Value
        $s | Should -Not -BeNullOrEmpty
        $s | Should -Match "method: 'POST'"
        $s | Should -Match 'X-Vista-Token'
        # la pagina nuova si riconosce dall ora di generazione, scritta in un attributo
        $s | Should -Match 'data-generata'
        $h | Should -Match 'data-generata="2026-11-18T10:00:00'
        $s | Should -Match "fetch\(indirizzo, \{ method: 'POST'"
        # il pulsante delle pipeline rilegge solo le pipeline, con il suo indirizzo
        $s | Should -Match "rileggi\(ap, '/aggiorna-pipeline'"
        $s | Should -Not -Match 'innerHTML'
    }
    It 'due contatori: il ricaricamento della pagina e il prossimo avvio dello smistatore' {
        $h = New-PaginaVista (New-ModelloVuoto) 10 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        $h | Should -Match 'id="conta-pagina" data-secondi="10"'
        $h | Should -Match 'id="conta-smistatore" data-quando="2026-11-18T10:05:00.0000000\+01:00"'
        # servita dal server la pagina si ricarica dallo script, che aspetta una rilettura chiesta; il meta refresh resta per chi non ha script
        $h | Should -Match '<noscript><meta http-equiv="refresh" content="10"></noscript>'
    }
    It 'i contatori ci sono anche senza server; senza prossimo avvio leggibile lo smistatore dice che non si sa' {
        $m = New-ModelloVuoto; $m.ProssimoGiroIso = $null
        $h = New-PaginaVista $m 10
        $h | Should -Match 'id="conta-pagina" data-secondi="10"'
        $h | Should -Match 'id="conta-smistatore" data-quando=""'
    }
    It 'lo script fa POST /giro con il token in un header e scrive la risposta con textContent' {
        $h = New-PaginaVista (New-ModelloVuoto) 10 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        $s = [regex]::Match($h, '(?s)<script>(?:(?!</script>).)*fetch\(.*?</script>').Value
        $s | Should -Match "fetch\('/giro'"
        $s | Should -Match "method: 'POST'"
        $s | Should -Match 'X-Vista-Token'
        $s | Should -Match 'textContent'
        $s | Should -Not -Match 'innerHTML'
    }
    It 'il token e codificato: un valore con virgolette non esce dall attributo' {
        $h = New-PaginaVista (New-ModelloVuoto) 10 'x"><script>y</script>'
        $h | Should -Not -Match 'x"><script>y'
    }
    It 'senza token (pagina da file, senza server) non c e pulsante ne token' {
        $h = New-PaginaVista (New-ModelloVuoto) 10
        $h | Should -Not -Match 'Avvia smistatore|Aggiorna agenti'
        $h | Should -Not -Match 'data-token'
        $h | Should -Not -Match "fetch\("
    }
    It 'la pagina di una sessione e quella del brief non hanno il pulsante' {
        $s = [pscustomobject]@{ Id = 5; UrlCard = $null; SessioneId = 'sid-1'; Titolo = 'T'; Repo = 'R'; Ruolo = 'dev'; Task = $null; TitoloTask = $null; Minuti = 1; TokenTesto = $null; Viva = $true }
        (New-PaginaSessione $s @() 0 $false 10) | Should -Not -Match 'Avvia smistatore'
        (New-PaginaBrief 'Dev' 'ruoli/dev.md' '<p>x</p>') | Should -Not -Match 'Avvia smistatore'
    }
}

Describe 'La sezione Pipeline di build nella pagina' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/VistaHtml.psm1') -Force
        function New-ModelloBuild($Build, [string]$Errore = '') {
            [pscustomobject]@{
                Generata = Get-Date; ErroreAdo = $null; InCorso = @(); Coda = @(); Catene = @(); UltimoGiro = 'x'; ProssimoGiro = 'y'
                Agenti = @(); Operatore = [pscustomobject]@{ Fermano = @(); NonFermano = @() }; Pipeline = @()
                BuildAdo = $Build; ErroreBuild = $Errore; UrlPullRequest = 'https://acme.visualstudio.com/_pulls'
            }
        }
        function New-RunFinto([string]$Stato, [string]$Pipeline = 'build-ci') {
            [pscustomobject]@{ Id = 7; Progetto = 'P'; Pipeline = $Pipeline; Ramo = 'develop'; Autore = 'X'; Stato = $Stato; Fase = $null
                Inizio = (Get-Date).ToUniversalTime().AddMinutes(-5); Fine = $null; Esito = ''; Url = 'https://acme.visualstudio.com/P/_build/results?buildId=7' }
        }
    }
    It 'senza lettura ne errore la sezione non c e (i modelli vecchi funzionano)' {
        $m = New-ModelloBuild $null; $m.PSObject.Properties.Remove('BuildAdo')
        New-PaginaVista $m | Should -Not -Match 'data-sezione="build"'
    }
    It 'con zero run mostra il riepilogo a zero, il riquadro vuoto e il link alle PR' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @(); Falliti = @() }
        $h = New-PaginaVista (New-ModelloBuild $b)
        $h | Should -Match 'nessun run in corso, in coda o fallito'
        $h | Should -Not -Match 'class="da-approvare"'
        $h | Should -Match 'class="build-pr"'
    }
    It 'con le pipeline la pagina ha due schede, Agenti e Pipeline, e la kanban sta nella prima' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 2; NumFalliti = 1; Errori = @(); Attivi = @(); Falliti = @() }
        $h = New-PaginaVista (New-ModelloBuild $b)
        $h | Should -Match 'role="tablist"'
        $h | Should -Match 'data-scheda="pipeline"[^>]*>Pipeline<span class="conta attenzione"[^>]*>2</span>'
        $h | Should -Match '(?s)<main[^>]*>\s*<div class="schede".*data-pannello="agenti"[^>]*>\s*<h1>Agenti</h1>.*class="kanban".*data-pannello="pipeline".*data-sezione="build"'
    }
    It 'con le schede l Ufficio e una scheda come le altre: il suo pulsante dopo Apprendimento, il suo pannello in .pannelli, una volta sola' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @(); Falliti = @() }
        $h = New-PaginaVista (New-ModelloBuild $b) 10 'tok'
        $h | Should -Match '(?s)data-scheda="apprendimento".*<button type="button" role="tab" data-scheda="ufficio" aria-selected="false">Ufficio</button>'
        ([regex]::Matches($h, '<div data-pannello="ufficio"')).Count | Should -Be 1
        $h | Should -Match '(?s)<div class="pannelli".*<div data-pannello="apprendimento".*<div data-pannello="ufficio"'
        ([regex]::Match($h, '<iframe[^>]*>').Value) | Should -Not -Match '\ssrc='
        $h | Should -Not -Match 'id="pannello-ufficio"|id="apri-ufficio"'   # il vecchio pannello non c e piu
        # lo script delle schede conosce l Ufficio e lascia fuori un pannello agganciato
        $h | Should -Match "'#ufficio'"
        $h | Should -Match 'data-fuori'
        $h | Should -Match 'window\.vistaRidisponi'
    }
    It 'il riquadro degli agenti: per pool, quanti run aspettano, ogni agente con stato e lavoro' {
        $q = New-RunFinto 'inCoda'; $q | Add-Member PoolCoda 'acme-internal'
        $pool = [pscustomobject]@{ Pool = 'acme-internal'; Agenti = @(
            [pscustomobject]@{ Nome = 'sh-1'; Online = $true; Abilitato = $true; Lavoro = [pscustomobject]@{ BuildId = 99; Pipeline = 'api <x>'; Url = 'https://acme.visualstudio.com/P/_build/results?buildId=99' } }
            [pscustomobject]@{ Nome = 'sh-2'; Online = $false; Abilitato = $true; Lavoro = $null }) }
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 1; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @($q); Falliti = @(); AgentiPool = @($pool) }
        $h = New-PaginaVista (New-ModelloBuild $b)
        $h | Should -Match '<div class="pool" data-pool="acme-internal"><h4><span class="etichetta-tipo pool">pool</span> acme-internal <span class="dove">2 agenti</span> <span class="pillola inCoda">1 in coda</span></h4>'
        $h | Should -Match '<span class="etichetta-tipo agente">agente</span> <b>sh-1</b> <span class="pillola verde">online</span> <span class="pillola inCorso">al lavoro</span> <a href="https://acme\.visualstudio\.com/P/_build/results\?buildId=99" target="_blank" rel="noopener">build 99 &middot; api &lt;x&gt;</a>'
        $h | Should -Match '<span class="etichetta-tipo agente">agente</span> <b>sh-2</b> <span class="pillola rosso">offline</span>'
    }
    It 'la scheda Pipeline non ha il bollino dei falliti: solo quello delle approvazioni' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 5; Errori = @(); Attivi = @(); Falliti = @() }
        $h = New-PaginaVista (New-ModelloBuild $b)
        $h | Should -Match 'data-scheda="pipeline" aria-selected="false">Pipeline</button>'
    }
    It 'le schede si possono affiancare o mettere in colonna: la scelta e nella barra e i pannelli stanno in .pannelli' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @(); Falliti = @() }
        $h = New-PaginaVista (New-ModelloBuild $b)
        $h | Should -Match '<span class="disposizione" role="group" aria-label="Disposizione"><button type="button" data-disposizione="schede" aria-pressed="true"'
        $h | Should -Match 'data-disposizione="affiancate"'
        $h | Should -Match 'data-disposizione="colonna"'
        $h | Should -Match '(?s)<div class="pannelli" data-disposizione="schede">\s*<div data-pannello="agenti".*<div data-pannello="pipeline"'
        $h | Should -Match "localStorage.getItem\('disposizione'\)"
        # fra i due pannelli il divisore che si trascina, con le misure in localStorage
        $h | Should -Match '(?s)<div data-pannello="agenti".*<div class="divisore" role="separator" tabindex="0"[^>]*></div>\s*<div data-pannello="pipeline"'
        $h | Should -Match "leggiMisura\('quota-affiancate'\)"
        $h | Should -Match "leggiMisura\('alto-colonna'\)"
    }
    It 'senza pipeline niente schede' {
        $m = New-ModelloBuild $null; $m.PSObject.Properties.Remove('BuildAdo')
        New-PaginaVista $m | Should -Not -Match 'role="tablist"'
    }
    It 'i run stanno in una tabella con le intestazioni' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 1; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @((New-RunFinto 'inCorso')); Falliti = @() }
        $h = New-PaginaVista (New-ModelloBuild $b)
        $h | Should -Match '<details class="progetto" data-progetto="P" open><summary><h3>P <span class="pillola inCorso">1 in corso</span></h3></summary>'
        $h | Should -Match '<table class="build-tab"><thead><tr><th>Stato</th><th>Tipo</th><th>Pipeline</th><th>Run</th><th>Ramo</th><th>Dettaglio</th><th>Chi</th><th>Agente</th><th>Quando</th>'
        # tutta la riga apre il run (data-url, aperto dallo script in una scheda nuova), oltre al link con target _blank
        # la colonna Run: il build id in evidenza
        $h | Should -Match '<td class="numero"><b class="build-id" title="build id">7</b></td>'
        # i filtri per stato e lo stato di ogni riga
        $h | Should -Match '<div class="filtri"[^>]*><button type="button" data-filtro="tutti" aria-pressed="true">Tutti<span class="conta">1</span></button><button type="button" data-filtro="inCorso" aria-pressed="false">In corso<span class="conta">1</span>'
        $h | Should -Match "sessionStorage.getItem\('filtro-pipeline'\)"
        # a scelta multipla: un clic aggiunge o toglie lo stato, Tutti azzera
        $h | Should -Match "scelti\.splice\(i, 1\)"
        $h | Should -Match "scelti\.join\(','\)"
        $h | Should -Match '<tr data-stato="inCorso" data-build="7" data-url="https://acme\.visualstudio\.com/P/_build/results\?buildId=7">'
        $h | Should -Match 'buildId=7" target="_blank" rel="noopener">apri il run'
        $h | Should -Match "window\.open\(tr\.dataset\.url, '_blank'"
    }
    It 'una lettura fallita lo dice, senza nascondere il resto, e non mostra numeri finti' {
        $h = New-PaginaVista (New-ModelloBuild $null 'HTTP 401 <x>')
        $h | Should -Match 'Non riesco a leggere le pipeline.*HTTP 401 &lt;x&gt;'
        $h | Should -Not -Match 'class="build-riepilogo"'
    }
    It 'ogni testo che viene da Azure DevOps passa da escape e solo i link http si accettano' {
        $r = New-RunFinto 'inCorso' '<script>alert(1)</script>'; $r.Url = 'javascript:alert(1)'
        $b = [pscustomobject]@{ Ore = 24; InCorso = 1; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @('A: <b>'); Attivi = @($r); Falliti = @() }
        $h = New-PaginaVista (New-ModelloBuild $b)
        $h | Should -Not -Match '<script>alert'
        $h | Should -Match '&lt;script&gt;alert\(1\)'
        $h | Should -Not -Match 'javascript:'
        $h | Should -Match 'Progetto non letto: A: &lt;b&gt;'
    }
}

Describe 'La sezione Apprendimento nella pagina (solo HTML)' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/VistaHtml.psm1') -Force
        function New-ModelloApprendimento($Apprendimento, [bool]$Senza = $false) {
            $m = [pscustomobject]@{
                Generata = Get-Date; ErroreAdo = $null; InCorso = @(); Coda = @(); Catene = @(); UltimoGiro = 'x'; ProssimoGiro = 'y'
                Agenti = @(); Operatore = [pscustomobject]@{ Fermano = @(); NonFermano = @() }; Pipeline = @()
                BuildAdo = $null; ErroreBuild = ''; UrlPullRequest = 'https://acme.visualstudio.com/_pulls'
            }
            if (-not $Senza) { $m | Add-Member Apprendimento $Apprendimento }
            $m
        }
        function New-Appr($Righe = @(), $Lezioni = @(), [string]$ErroreRegistro = '', [string]$ErroreLezioni = '', $Stabili = @()) {
            [pscustomobject]@{ Settimane = 4; Finestra = 'ultime 4 settimane intere piu quella in corso'; Righe = @($Righe); Evitati = @(); ErroreRegistro = $ErroreRegistro; Lezioni = $Lezioni; ErroreLezioni = $ErroreLezioni; Stabili = $Stabili }
        }
        function New-LezioneVista([string]$Id, [string]$Ruolo = 'dev', [string]$Testo = '', [string]$Situazione = 's') {
            [pscustomobject]@{ Id = $Id; Ruolo = $Ruolo; Repo = 'comune'; Situazione = $Situazione; Testo = $(if ($Testo) { $Testo } else { "### $Id`nSituazione: $Situazione`nCosa fare: c" }) }
        }
    }
    It 'un modello senza Apprendimento (o con $null) ha comunque la scheda, con il messaggio nessun dato e senza la sezione' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @(); Falliti = @() }
        foreach ($m in @((New-ModelloApprendimento $null $true), (New-ModelloApprendimento $null))) {
            $m.BuildAdo = $b
            $h = New-PaginaVista $m
            $h | Should -Match '<button type="button" role="tab" data-scheda="apprendimento" aria-selected="false">Apprendimento</button>'
            $h | Should -Match '(?s)<div data-pannello="apprendimento" role="tabpanel">.*nessun dato'
            $h | Should -Not -Match 'class="apprendimento"'
        }
    }
    It 'la scheda Apprendimento e la terza, con il contatore delle lezioni in prova in attesa' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @(); Falliti = @() }
        $l = @(1, 2 | ForEach-Object { [pscustomobject]@{ Id = "dev-00$_"; Ruolo = 'dev'; Repo = 'comune'; Situazione = 's' } })
        $m = New-ModelloApprendimento (New-Appr @() $l); $m.BuildAdo = $b
        $h = New-PaginaVista $m
        $h | Should -Match '(?s)data-scheda="agenti".*data-scheda="pipeline".*data-scheda="apprendimento" aria-selected="false">Apprendimento<span class="conta attenzione" title="lezioni in prova in attesa di conferma">2</span></button>'
        $m2 = New-ModelloApprendimento (New-Appr); $m2.BuildAdo = $b
        New-PaginaVista $m2 | Should -Not -Match 'data-scheda="apprendimento"[^>]*>Apprendimento<span'
    }
    It 'la sezione sta nel suo pannello, dopo i pannelli di Agenti e Pipeline, e non e un details che la nasconde' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @(); Falliti = @() }
        $m = New-ModelloApprendimento (New-Appr); $m.BuildAdo = $b
        $h = New-PaginaVista $m
        $h | Should -Match '(?s)data-pannello="agenti".*class="kanban".*data-pannello="pipeline".*data-pannello="apprendimento" role="tabpanel">\s*<section class="apprendimento" data-sezione="apprendimento">'
        $h | Should -Not -Match '<details class="apprendimento"'
        # il pannello dei soli agenti non contiene piu la sezione
        $agenti = [regex]::Match($h, '(?s)<div data-pannello="agenti".*?<div class="divisore"').Value
        $agenti | Should -Not -Match 'apprendimento'
    }
    It 'affiancate e in colonna: l Apprendimento e un pannello come gli altri, dentro .pannelli, e le schede restano come interruttori' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @(); Falliti = @() }
        $m = New-ModelloApprendimento (New-Appr); $m.BuildAdo = $b
        $h = New-PaginaVista $m
        # il pannello sta dentro .pannelli, dopo la Pipeline; dopo di lui viene solo la scheda Ufficio, poi si chiude .pannelli e viene lo script
        $h | Should -Match '(?s)<div class="pannelli".*data-pannello="pipeline".*data-pannello="apprendimento".*</section>\s*</div>\s*<div data-pannello="ufficio".*</style>\s*</div>\s*<script>'
        # le schede non spariscono nelle altre disposizioni: l elenco dei pannelli nascosti e una preferenza in localStorage
        $h | Should -Not -Match 'b\.hidden = disposizione'
        $h | Should -Match "localStorage\.getItem\('nascosti'\)"
        $h | Should -Match "localStorage\.setItem\('nascosti'"
        # le colonne della griglia seguono i pannelli visibili
        $h | Should -Match 'gridTemplateColumns'
    }
    It 'un secondo divisore, fra Pipeline e Apprendimento, con la sua misura in localStorage e il suo doppio clic' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @(); Falliti = @() }
        $m = New-ModelloApprendimento (New-Appr); $m.BuildAdo = $b
        $h = New-PaginaVista $m
        $h | Should -Match '(?s)<div class="divisore" role="separator" tabindex="0" data-divisore="agenti"[^>]*></div>\s*<div data-pannello="pipeline".*</div>\s*<div class="divisore secondo" role="separator" tabindex="0" data-divisore="pipeline"[^>]*></div>\s*<div data-pannello="apprendimento"'
        $h | Should -Match "leggiMisura\('quota-pipeline'\)"
        $h | Should -Match "salvaMisura\('quota-pipeline'"
        $h | Should -Match '--quota-pipeline'
        # in colonna il secondo divisore non serve: i pannelli sono impilati
        $h | Should -Match '\[data-disposizione="colonna"\] > \.divisore\.secondo \{ display: none; \}'
    }
    It 'lo script conosce la terza scheda: il valore ricordato sconosciuto ricade su agenti, e #apprendimento la apre' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @(); Falliti = @() }
        $m = New-ModelloApprendimento (New-Appr); $m.BuildAdo = $b
        $h = New-PaginaVista $m
        # le schede valide sono quelle con un pulsante (fuori chi e agganciato): un valore che non e fra loro ricade su agenti
        $h | Should -Match "if \(nomi\(\)\.indexOf\(scelta\) < 0\) \{ scelta = 'agenti'; \}"
        $h | Should -Match 'data-scheda="apprendimento"'
        $h | Should -Match "location\.hash === '#apprendimento'"
    }
    It 'la tabella ha una riga per settimana e ruolo, con la settimana ISO e il lunedi' {
        $r = [pscustomobject]@{ Lunedi = '2026-11-16'; Settimana = '2026-W47'; Ruolo = 'dev'; Blocchi = 3; OnHold = 1; Correzioni = 2; LezioniApplicate = 4 }
        $h = New-PaginaVista (New-ModelloApprendimento (New-Appr @($r)))
        $h | Should -Match '<th>Settimana</th><th>Ruolo</th><th>Blocchi</th><th>On-hold</th><th>Correzioni</th><th>Lezioni applicate</th>'
        $h | Should -Match '2026-W47'
        $h | Should -Match '<td[^>]*>dev</td><td[^>]*>3</td><td[^>]*>1</td><td[^>]*>2</td><td[^>]*>4</td>'
    }
    It 'il testo che viene dalle lezioni e dagli errori passa da escape' {
        $l = [pscustomobject]@{ Id = 'dev-001'; Ruolo = 'dev'; Repo = 'comune'; Situazione = '<script>alert(1)</script>' }
        $h = New-PaginaVista (New-ModelloApprendimento (New-Appr @() @($l) '<b>reg</b>' '<i>git</i>'))
        $h | Should -Not -Match '<script>alert'
        $h | Should -Match '&lt;script&gt;alert\(1\)'
        $h | Should -Match '&lt;b&gt;reg&lt;/b&gt;'
        $h | Should -Match '&lt;i&gt;git&lt;/i&gt;'
    }
    It 'una lezione in prova si apre con un clic e mostra il testo intero, con gli a capo, dentro un pre' {
        $l = New-LezioneVista 'dev-001' 'dev' "### dev-001`nSituazione: il restore fallisce`nCosa fare: usa il proxy`nPerche: la rete"
        $h = New-PaginaVista (New-ModelloApprendimento (New-Appr @() @($l)))
        # gli a capo dell'atteso si scrivono con `n: una stringa su piu righe nel file prenderebbe il CRLF del checkout (core.autocrlf)
        $h | Should -Match ('(?s)<tr data-lezione="dev-001">.*<details class="lezione" data-ricorda="lezione-dev-001"><summary>s</summary><pre class="testo-lezione">' + "### dev-001`nSituazione: il restore fallisce`nCosa fare: usa il proxy`nPerche: la rete" + '</pre></details>')
    }
    It 'il testo intero delle lezioni (in prova e stabili) passa da escape: un script non esce come tag' {
        $c = "### dev-001`n<script>alert(1)</script> & <b>x</b>"
        $h = New-PaginaVista (New-ModelloApprendimento (New-Appr @() @((New-LezioneVista 'dev-001' 'dev' $c)) '' '' @((New-LezioneVista 'dev-002' 'dev' $c.Replace('001', '002')))))
        $h | Should -Not -Match '<script>alert'
        $h | Should -Not -Match '<b>x</b>'
        @([regex]::Matches($h, '&lt;script&gt;alert\(1\)&lt;/script&gt; &amp; &lt;b&gt;x&lt;/b&gt;')).Count | Should -Be 2
    }
    It 'le lezioni stabili hanno la loro tabella per ruolo, ognuna apribile con il testo intero' {
        $s = @((New-LezioneVista 'dev-001' 'dev' "### dev-001`nCosa fare: a"), (New-LezioneVista 'dev-002' 'dev'), (New-LezioneVista 'reviewer-001' 'reviewer'))
        $h = New-PaginaVista (New-ModelloApprendimento (New-Appr @() @() '' '' $s))
        $h | Should -Match '<h3>Lezioni stabili<span class="conta">3</span></h3>'
        $h | Should -Match ('(?s)data-ruolo-stabili="dev".*data-stabile="dev-001".*<pre class="testo-lezione">' + "### dev-001`nCosa fare: a" + '</pre>.*data-stabile="dev-002".*data-ruolo-stabili="reviewer".*data-stabile="reviewer-001"')
        @([regex]::Matches($h, 'data-ruolo-stabili="dev"')).Count | Should -Be 1
    }
    It 'le stabili sono aperte se poche e chiuse se tante (oltre la soglia del modulo)' {
        $poche = @(1..3 | ForEach-Object { New-LezioneVista "dev-00$_" })
        $tante = @(1..20 | ForEach-Object { New-LezioneVista ('dev-{0:000}' -f $_) })
        New-PaginaVista (New-ModelloApprendimento (New-Appr @() @() '' '' $poche)) | Should -Match '<details class="stabili" data-ruolo-stabili="dev" data-ricorda="stabili-dev" open>'
        New-PaginaVista (New-ModelloApprendimento (New-Appr @() @() '' '' $tante)) | Should -Match '<details class="stabili" data-ruolo-stabili="dev" data-ricorda="stabili-dev">'
    }
    It 'senza lezioni stabili la sezione lo dice; stabili non lette (null o proprieta assente) non rompono e non cambiano il contatore' {
        New-PaginaVista (New-ModelloApprendimento (New-Appr)) | Should -Match 'nessuna lezione stabile'
        $a = New-Appr; $a.PSObject.Properties.Remove('Stabili')
        { New-PaginaVista (New-ModelloApprendimento $a) } | Should -Not -Throw
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @(); Falliti = @() }
        $m = New-ModelloApprendimento (New-Appr @() @((New-LezioneVista 'dev-001')) '' '' @(1..5 | ForEach-Object { New-LezioneVista "dev-10$_" })); $m.BuildAdo = $b
        New-PaginaVista $m | Should -Match 'data-scheda="apprendimento" aria-selected="false">Apprendimento<span class="conta attenzione" title="lezioni in prova in attesa di conferma">1</span></button>'
    }
    It 'lo script ricorda le lezioni aperte fra un ricaricamento e l altro' {
        $b = [pscustomobject]@{ Ore = 24; InCorso = 0; InCoda = 0; InAttesa = 0; NumFalliti = 0; Errori = @(); Attivi = @(); Falliti = @() }
        $m = New-ModelloApprendimento (New-Appr); $m.BuildAdo = $b
        New-PaginaVista $m | Should -Match "querySelectorAll\('details\[data-ricorda\]'\)"
    }
    It 'le lezioni che hanno evitato un blocco hanno il loro elenco, col titolo che dice finora; senza, niente elenco' {
        $a = New-Appr; $a.Evitati = @([pscustomobject]@{ Ruolo = 'dev'; Lezione = 'dev-001'; Card = @(8, 9) })
        $h = New-PaginaVista (New-ModelloApprendimento $a)
        $h | Should -Match '(?s)<h3>Lezioni che hanno evitato un blocco finora.*data-evitata="dev-001".*card 8, 9'
        New-PaginaVista (New-ModelloApprendimento (New-Appr)) | Should -Not -Match 'evitato un blocco'
    }
    It 'il sottotitolo dice la finestra con le parole della costante del modulo' {
        New-PaginaVista (New-ModelloApprendimento (New-Appr)) | Should -Match 'ultime 4 settimane intere piu quella in corso'
    }
    It 'le lezioni non ancora lette (null) dicono che la lettura e in corso, senza errore' {
        $a = New-Appr; $a.Lezioni = $null
        New-PaginaVista (New-ModelloApprendimento $a) | Should -Match 'lettura in corso'
    }
}

Describe 'VistaRitmo: quando leggere le lezioni in prova' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot '../src/VistaRitmo.psm1') -Force }
    It 'senza -Html mai' {
        Test-LeggiLezioniOra -Html $false -Segui $true -PrimoDisegno $false -Trascorsi $null -Secondi 300 | Should -BeFalse
    }
    It 'una volta sola (senza -Segui) si legge subito: la pagina e una e deve averle' {
        Test-LeggiLezioniOra -Html $true -Segui $false -PrimoDisegno $true -Trascorsi $null -Secondi 300 | Should -BeTrue
    }
    It 'con -Segui il primo disegno non le aspetta; dopo, la prima volta si leggono' {
        Test-LeggiLezioniOra -Html $true -Segui $true -PrimoDisegno $true -Trascorsi $null -Secondi 300 | Should -BeFalse
        Test-LeggiLezioniOra -Html $true -Segui $true -PrimoDisegno $false -Trascorsi $null -Secondi 300 | Should -BeTrue
    }
    It 'poi ogni -SecondiMemoria' {
        Test-LeggiLezioniOra -Html $true -Segui $true -PrimoDisegno $false -Trascorsi 299 -Secondi 300 | Should -BeFalse
        Test-LeggiLezioniOra -Html $true -Segui $true -PrimoDisegno $false -Trascorsi 300 -Secondi 300 | Should -BeTrue
    }
}
Describe 'La quota nella pagina (D51, 2026-11-24): riga, banner e comandi' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/Comune.psm1') -Force -Global
        Import-Module (Join-Path $PSScriptRoot '../src/VistaHtml.psm1') -Force
        $script:Reset = '2026-11-27T10:00:00.0000000Z'
        function New-ModelloQuota($Quota) {
            $m = [pscustomobject]@{
                Generata = [datetime]'2026-11-24T10:00:00'; ErroreAdo = $null; InCorso = @(); Coda = @(); Catene = @()
                Agenti = @([pscustomobject]@{ Ruolo = 'dev'; Sessioni = @(); Coda = @(); Brief = $null })
                Operatore = [pscustomobject]@{ Fermano = @(); NonFermano = @() }; Pipeline = @(); UltimoGiro = 'x'; ProssimoGiro = 'y'
            }
            if ($null -ne $Quota) { $m | Add-Member Quota ([pscustomobject]$Quota) }
            $m
        }
        function New-Quota($Blocco = $null, [bool]$Alzata = $false, [bool]$Ignora = $false, $Soglia = 0.70) {
            @{ Uso = 0.64; Soglia = $Soglia; DaOverride = $Alzata; IgnoraRiserva = $Ignora; Override = 'nessuno'; Reset = $script:Reset; PuoImpostare = $true; Blocco = $Blocco; SogliaMin = 0.05; SogliaMax = 0.95 }
        }
        $script:BloccoRiserva = @{ Tipo = 'quota'; Causa = 'riserva'; Fino = $script:Reset; Uso = 0.72; Soglia = 0.70 }
        $script:BloccoLimite = @{ Tipo = 'quota'; Causa = 'limite'; Fino = '2026-11-24T14:05:00.0000000Z'; Uso = 0.40 }
    }
    It 'senza Quota nel modello la pagina non dice niente sulla quota' {
        $h = New-PaginaVista (New-ModelloQuota $null) 10 'tok'
        $h | Should -Not -Match '<p class="quota-riga"'
        $h | Should -Not -Match '<div class="banner-quota"'
    }
    It 'la riga quota c e sempre: uso, soglia, reset e bypass no' {
        $h = New-PaginaVista (New-ModelloQuota (New-Quota)) 10
        $h | Should -Match '<p class="quota-riga">Quota settimanale: <b>64%</b> usata'
        $h | Should -Match 'soglia 70%'
        $h | Should -Match 'reset \d\d/\d\d \d\d:\d\d'
        $h | Should -Match 'riserva non ignorata'
        $h | Should -Not -Match 'alzata fino al'
    }
    It 'con la soglia alzata la riga dice fino a quando; con il bypass lo dice' {
        $h = New-PaginaVista (New-ModelloQuota (New-Quota -Alzata $true -Ignora $true -Soglia 0.85)) 10
        $h | Should -Match 'soglia 85% \(alzata fino al \d\d/\d\d \d\d:\d\d\)'
        $h | Should -Match 'riserva ignorata fino al \d\d/\d\d'
    }
    It 'il banner c e solo quando il blocco c e' {
        New-PaginaVista (New-ModelloQuota (New-Quota)) 10 'tok' | Should -Not -Match 'banner-quota" role'
        $h = New-PaginaVista (New-ModelloQuota (New-Quota $script:BloccoRiserva)) 10 'tok'
        $h | Should -Match '<div class="banner-quota" role="alert" data-causa="riserva">'
        $h | Should -Match 'riserva settimanale\. L&#39;uso e al 72%, la soglia e 70%'
        $h | Should -Match '(?s)<main[^>]*>\s*<div class="banner-quota"'
    }
    It 'per la pausa dopo il limite il banner dice la causa e che non si salta' {
        $h = New-PaginaVista (New-ModelloQuota (New-Quota $script:BloccoLimite)) 10 'tok'
        $h | Should -Match 'data-causa="limite"'
        $h | Should -Match 'limite di token raggiunto, riprendono il'
        $h | Should -Match 'non si salta'
    }
    It 'il colore del banner e suo: non quello degli avvisi' {
        $h = New-PaginaVista (New-ModelloQuota (New-Quota $script:BloccoRiserva)) 10
        $h | Should -Match '\.banner-quota \{[^}]*--rispondi-testo'
        $h | Should -Not -Match '\.banner-quota \{[^}]*--ambra'
    }
    It 'con il server (token) i comandi ci sono, col valore in percento, e nel banner quando bloccata' {
        $h = New-PaginaVista (New-ModelloQuota (New-Quota -Soglia 0.85)) 10 'tok'
        $h | Should -Match 'id="quota-soglia" min="5" max="95" step="1" value="85"'
        $h | Should -Match 'id="quota-applica" data-token="tok">Applica<'
        $h | Should -Match 'id="quota-ripristina" data-token="tok">Ripristina<'
        $h | Should -Match 'Ignora la riserva fino al reset'
        $h = New-PaginaVista (New-ModelloQuota (New-Quota $script:BloccoRiserva)) 10 'tok'
        $h | Should -Match '(?s)<div class="banner-quota".*id="quota-applica".*</div>\s*<div data-pannello="agenti"'
        ([regex]::Matches($h, 'id="quota-applica"')).Count | Should -Be 1
    }
    It 'la casella del bypass e spuntata solo se il bypass e attivo' {
        New-PaginaVista (New-ModelloQuota (New-Quota -Ignora $true)) 10 'tok' | Should -Match 'id="quota-ignora" data-token="tok" checked>'
        New-PaginaVista (New-ModelloQuota (New-Quota)) 10 'tok' | Should -Not -Match 'id="quota-ignora"[^>]*checked'
    }
    It 'senza server (pagina da file) niente comandi ne script, ma riga e banner si' {
        $h = New-PaginaVista (New-ModelloQuota (New-Quota $script:BloccoRiserva)) 10
        $h | Should -Match 'banner-quota" role="alert"'
        $h | Should -Match 'quota-riga'
        $h | Should -Not -Match 'id="quota-(soglia|applica|ignora|ripristina)"'
        $h | Should -Not -Match '/soglia\?'
    }
    It 'lo script parla con POST /soglia e tiene la soglia entro il tetto' {
        $h = New-PaginaVista (New-ModelloQuota (New-Quota)) 10 'tok'
        $h | Should -Match "'/soglia\?soglia='"
        $h | Should -Match "'/soglia\?ignoraRiserva='"
        $h | Should -Match "'/soglia\?ripristina=1'"
        # il range non e scritto nello script: lo legge dai min/max del campo, che arrivano dal modello
        $h | Should -Not -Match 'v >= 5'
        $h | Should -Match 'campo\.min'
    }
    It 'il range del campo viene dal modello, non e scritto nella pagina' {
        $q = New-Quota; $q.SogliaMin = 0.10; $q.SogliaMax = 0.90
        New-PaginaVista (New-ModelloQuota $q) 10 'tok' | Should -Match 'id="quota-soglia" min="10" max="90"'
    }
    It 'senza un reset noto i comandi non si mostrano, ne nel banner ne in testata' {
        $q = New-Quota $script:BloccoRiserva; $q.PuoImpostare = $false
        New-PaginaVista (New-ModelloQuota $q) 10 'tok' | Should -Not -Match 'id="quota-applica"'
        $q = New-Quota; $q.PuoImpostare = $false
        New-PaginaVista (New-ModelloQuota $q) 10 'tok' | Should -Not -Match 'id="quota-applica"'
    }
    It 'un override ignorato (scaduto, illeggibile, fuori range) si vede nella riga; uno valido o assente no' {
        foreach ($o in 'scaduto', 'illeggibile', 'fuoriRange') {
            $q = New-Quota; $q.Override = $o
            New-PaginaVista (New-ModelloQuota $q) 10 | Should -Match "override ignorato: $o"
        }
        foreach ($o in 'nessuno', 'valido') {
            $q = New-Quota; $q.Override = $o
            New-PaginaVista (New-ModelloQuota $q) 10 | Should -Not -Match 'override ignorato'
        }
    }
    It 'la casella del bypass torna com era se POST /soglia risponde con un errore' {
        $h = New-PaginaVista (New-ModelloQuota (New-Quota)) 10 'tok'
        $h | Should -Match 'function \(\) \{ qi\.checked = !qi\.checked; \}'
        $h | Should -Match 'var fallito = function \(\) \{ finito\(\); if \(alErrore\) alErrore\(\); \};'
    }
    It 'il ricaricamento sospeso dal campo soglia ha un limite e vale solo con la finestra in primo piano' {
        $h = New-PaginaVista (New-ModelloQuota (New-Quota)) 10 'tok'
        $h | Should -Match 'document\.hasFocus\(\) && document\.activeElement && document\.activeElement\.id === ''quota-soglia'' && resto > -60'
    }}

Describe 'New-ContestoGiro porta l override della soglia (D51, 2026-11-24)' {
    BeforeAll {
        foreach ($m in 'Comune', 'Config', 'Stato', 'Decisioni') { Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Global }
        . (Join-Path $PSScriptRoot '../src/Istantanea.ps1')
    }
    It 'legge quota.json e soglia-quota.json dai percorsi dati, e Get-BloccoQuota ne tiene conto' {
        $q = Join-Path $TestDrive 'ctx-quota.json'; $s = Join-Path $TestDrive 'ctx-soglia.json'
        $fino = [datetime]::UtcNow.AddDays(2).ToString('o')
        Save-Quota -Quota @{ sevenDay = @{ utilization = 0.80; resetsAt = $fino } } -Percorso $q
        $cfg = @{ Stati = @{}; Limiti = @{ sogliaQuotaSettimanale = 0.70 }; Mappa = @() }
        $ctx = New-ContestoGiro $cfg @() 'u-ric' $q $s
        (Get-BloccoQuota $ctx).Causa | Should -Be 'riserva'
        Save-SogliaQuota -Override @{ soglia = $null; ignoraRiserva = $true; fino = $fino; impostata = [datetime]::UtcNow.ToString('o') } -Percorso $s
        $ctx = New-ContestoGiro $cfg @() 'u-ric' $q $s
        Get-BloccoQuota $ctx | Should -BeNullOrEmpty
    }
}
Describe 'Vista.ps1 -Segui: una sola vista per radice' {
    It 'se un altra vista -Segui della stessa radice e viva, scrive un messaggio ed esce con 0 senza lanciare figli' {
        $rad = Join-Path ([IO.Path]::GetTempPath()) ('radice-finta-' + [guid]::NewGuid().ToString('N'))
        $pwsh = (Get-Process -Id $PID).Path
        $dorme = Join-Path $TestDrive 'dorme.ps1'; Set-Content $dorme 'Start-Sleep 60'
        # un processo che porta nella riga di comando il percorso della vista di quella radice
        $altra = Start-Process $pwsh -ArgumentList '-NoProfile', '-File', $dorme, ($rad.Replace([string][char]92, '/') + '/src/Vista.ps1'), '-Segui' -PassThru -WindowStyle Hidden
        try {
            Import-Module (Join-Path $PSScriptRoot '../src/Comune.psm1') -Force
            $t = 0; while (@(Get-ProcessiVistaRadice $rad).Count -eq 0 -and $t++ -lt 100) { Start-Sleep -Milliseconds 100 }
            $env:VISTA_FIGLIO = $null
            $uscita = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot '../src/Vista.ps1') -Segui -Radice $rad 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $uscita
            $uscita | Should -Match "gia in esecuzione \(pid $($altra.Id)\)"
        }
        finally { Stop-Process -Id $altra.Id -Force -ErrorAction SilentlyContinue }
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }

Describe 'Il riquadro Suite nella pagina, con i comandi (D53, punto 8)' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/Comune.psm1') -Force -Global
        Import-Module (Join-Path $PSScriptRoot '../src/VistaHtml.psm1') -Force
        function New-ModelloSuite($Suite) {
            $m = [pscustomobject]@{
                Generata = [datetime]'2026-11-25T10:00:00'; ErroreAdo = $null; InCorso = @(); Coda = @(); Catene = @()
                Agenti = @([pscustomobject]@{ Ruolo = 'dev'; Sessioni = @(); Coda = @(); Brief = $null })
                Operatore = [pscustomobject]@{ Fermano = @(); NonFermano = @() }; Pipeline = @(); UltimoGiro = 'x'; ProssimoGiro = 'y'
            }
            if ($null -ne $Suite) { $m | Add-Member Suite ([pscustomobject]$Suite) }
            $m
        }
        function New-DatiSuite([bool]$Automatico = $true, [bool]$Allarme = $false) {
            @{ Letto = $true; Canale = 'main'; Automatico = $Automatico; Installata = 'main abc1234 (20/11/2026)'; Disponibile = 'main def5678 (25/11/2026)'; UltimoControllo = '25/11 10:00'
               ErroreControllo = $null; Esito = 'daAggiornare'; Stato = 'c e una versione nuova'; Allarme = $Allarme; Pr = @([pscustomobject]@{ Numero = 1202; Titolo = 'Una <b>PR</b>'; Url = 'https://x/pullrequest/1202' }) }
        }
    }
    It 'senza le schede (pipeline non ancora lette) l Ufficio non e una scheda: in testata c e il link per aprirlo a parte' {
        $h = New-PaginaVista (New-ModelloSuite $null) 10 'tok'
        $h | Should -Not -Match '<div data-pannello="ufficio"'
        $h | Should -Match '(?s)<body>\s*<div class="testata">.*href="ufficio\.html".*</div>\s*<main'
    }
    It 'senza Suite nel modello la pagina non ha il riquadro' {
        (New-PaginaVista (New-ModelloSuite $null) 10 'tok') | Should -Not -Match 'data-sezione="suite"'
    }
    It 'col token ci sono il pulsante Aggiorna adesso e l interruttore, col token in un attributo, dentro il riquadro' {
        $t = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        $h = New-PaginaVista (New-ModelloSuite (New-DatiSuite)) 10 $t
        $suite = [regex]::Match($h, '(?s)<section class="suite".*?</section>').Value
        $suite | Should -Match ('<button type="button" id="suite-aggiorna" data-token="' + $t + '">Aggiorna adesso</button>')
        $suite | Should -Match ('<input type="checkbox" id="suite-automatico" data-token="' + $t + '" checked><label for="suite-automatico">Aggiornamento automatico</label>')
        # il riquadro sta in alto a destra, in testata (prima di main): si vede da ogni scheda
        $h | Should -Match '(?s)<body>\s*<div class="testata">\s*<details class="suite-compatta".*data-sezione="suite".*</details>.*<main'
        $h | Should -Not -Match '(?s)<h1>Agenti</h1>.*data-sezione="suite"'
    }
    It 'la Suite in testata si legge a colpo d occhio, chiusa: versione installata e stato nel sommario, allarme compreso' {
        $h = New-PaginaVista (New-ModelloSuite (New-DatiSuite $true $true)) 10 'tok'
        $sommario = [regex]::Match($h, '(?s)<details class="suite-compatta"[^>]*>\s*<summary>(.*?)</summary>').Groups[1].Value
        $sommario | Should -Match 'main abc1234'
        $sommario | Should -Match 'c e una versione nuova'
        $sommario | Should -Match 'allarme'
    }
    It 'l interruttore e spuntato solo se l automatico e acceso' {
        (New-PaginaVista (New-ModelloSuite (New-DatiSuite $false)) 10 'tok') | Should -Not -Match 'id="suite-automatico"[^>]* checked'
        (New-PaginaVista (New-ModelloSuite (New-DatiSuite $true)) 10 'tok') | Should -Match 'id="suite-automatico"[^>]* checked'
    }
    It 'lo script collega i due comandi agli indirizzi giusti' {
        $h = New-PaginaVista (New-ModelloSuite (New-DatiSuite)) 10 'tok'
        $h | Should -Match "fetch\('/aggiorna-suite', \{ method: 'POST'"
        $h | Should -Match "'/automatico\?attivo=' \+ \(sx\.checked \? '1' : '0'\)"
    }
    It 'senza token niente pulsanti e niente script dei comandi' {
        $h = New-PaginaVista (New-ModelloSuite (New-DatiSuite)) 10
        ([regex]::Match($h, '(?s)<section class="suite".*?</section>').Value) | Should -Not -Match '<button|<input'
        $h | Should -Not -Match '/aggiorna-suite'
    }
    It 'il testo che viene da fuori (titolo di una PR, stato, errore) si escapa; un link non http non diventa un link' {
        $s = New-DatiSuite; $s.Stato = '<script>x()</script>'; $s.ErroreControllo = '<img src=x>'
        $s.Pr = @([pscustomobject]@{ Numero = 7; Titolo = '<b>x</b>'; Url = 'javascript:alert(1)' })
        $h = New-PaginaVista (New-ModelloSuite $s) 10 'tok'
        $suite = [regex]::Match($h, '(?s)<section class="suite".*?</section>').Value
        $suite | Should -Not -Match '<script|<img|<b>x'
        $suite | Should -Match '&lt;script&gt;'
        $suite | Should -Not -Match 'href="javascript'
    }
    It 'uno stato che chiede qualcosa a una persona ha la classe allarme' {
        (New-PaginaVista (New-ModelloSuite (New-DatiSuite $true $true)) 10 'tok') | Should -Match 'class="suite-stato allarme"'
        (New-PaginaVista (New-ModelloSuite (New-DatiSuite $true $false)) 10 'tok') | Should -Not -Match 'class="suite-stato allarme"'
    }
    It 'senza versione disponibile dice che si e all ultima' {
        $s = New-DatiSuite; $s.Disponibile = $null
        (New-PaginaVista (New-ModelloSuite $s) 10 'tok') | Should -Match 'Disponibile: <b>nessuna: sei all&#39;ultima versione</b>'
    }
}
