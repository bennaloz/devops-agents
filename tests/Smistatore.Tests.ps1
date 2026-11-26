BeforeAll {
    # D53: Get-Config e Get-ConfigSupervisore leggono impostazioni.json dalla cartella dati: i test non devono vedere quella vera di chi li lancia.
    $script:DatiPrimaIsolamento = $env:ATTREZZI_DATI; $env:ATTREZZI_DATI = Join-Path $TestDrive 'dati-isolati'
    # I moduli si caricano prima, nello stesso modo dello script, cosi i Mock trovano i comandi da sostituire.
    foreach ($m in 'Config', 'Ado', 'Stato', 'Decisioni', 'Collaudo', 'Sessioni', 'Telegram', 'Worktree', 'Card') {
        Import-Module (Join-Path $PSScriptRoot "../src/$m.psm1") -Global
    }
    $script:Script = Join-Path $PSScriptRoot '../src/Smistatore.ps1'
    . (Join-Path $PSScriptRoot 'finti/Radice.ps1')
    $script:Cfg = Get-Config
    $script:Area = 'DevOps.Agents\AI\Stime'   # l'area che sta in config/mappa.json
    $script:AreaIgnota = 'DevOps.Agents\Altro\Area'

    function St([string]$Chiave) { $script:Cfg.Stati.$Chiave }

    # Di norma assegnata all'utente dello smistatore (u-ric): solo le sue card avanzano (spec, sezione 19).
    function New-FintaCard($Id, [string]$Chiave, $Tag = $null, $Area = $script:Area, $Tokens = 0, $Minuti = 0, $Assegnata = 'u-ric') {
        if ($null -eq $Tag) { $Tag = @($script:Cfg.Stati.tagAgenti) }
        [pscustomobject]@{
            Id = [int]$Id; Rev = 10; Tipo = 'User Story'; Titolo = "Titolo della card $Id"; Descrizione = 'd'; Criteri = 'c'
            Stato = (St $Chiave); Tag = @($Tag); Area = $Area; CreataDa = [pscustomobject]@{ Id = 'u-rich'; Nome = 'Richiedente' }
            AssegnataA = $(if ($Assegnata) { [pscustomobject]@{ Id = $Assegnata; Nome = "Nome di $Assegnata" } } else { $null })
            ConsumoTotale = [int64]$Tokens; MinutiAgente = [int64]$Minuti
        }
    }
    # Storia con l'ingresso nello stato corrente fatto da Titolare (rev 20) o da altri.
    function New-FintaStoria([string]$Chiave, [string]$Chi = 'u-ric') {
        @(
            [pscustomobject]@{ Rev = 1; Da = $null; A = (St 'bozza'); Chi = $Chi; ChiNome = 'x'; Quando = '2026-11-01T08:00:00Z' }
            [pscustomobject]@{ Rev = 20; Da = (St 'bozza'); A = (St $Chiave); Chi = $Chi; ChiNome = 'x'; Quando = '2026-11-01T09:00:00Z' }
        )
    }
    function New-FintoEsito([bool]$Finita, $Esito = $null, [bool]$Errore = $false, $Ultimo = $null, $Testo = 'testo', $Eventi = 3, $Negati = @(), $Lezioni = @()) {
        [pscustomobject]@{
            Finita = $Finita; Errore = $Errore; Esito = $Esito; Lezioni = @($Lezioni); Testo = $Testo; UltimoEvento = $Ultimo; Eventi = $Eventi; Turni = 4; DurataMs = 125000; Negati = @($Negati)
            TokenIn = 10; TokenOut = 200; CacheLetti = 3000; CacheScritti = 400
        }
    }
    function Set-StatoDiPartenza($Dati, $Voci) {
        $st = @{}
        foreach ($k in $Voci.Keys) {
            $v = Get-StatoCard -Stato $st -Id ([int]$k)
            foreach ($c in $Voci[$k].Keys) { $v[$c] = $Voci[$k][$c] }
        }
        Save-Stato -Stato $st -Percorso (Join-Path $Dati 'stato.json')
    }
    function Get-StatoFinale($Dati) { Get-Stato -Percorso (Join-Path $Dati 'stato.json') }
    function Invoke-Giro { param($Dati, [hashtable]$Parametri = @{}) if (-not $Parametri.ContainsKey('PercorsoPatInfo')) { $Parametri['PercorsoPatInfo'] = Join-Path $Dati 'nessun-pat-info.json' }; & $script:Script -CartellaDati $Dati @Parametri *>&1 | Out-String }
    # Il commento con cui il responsabile sceglie i parametri del deploy in Test (D43), come lo scrive card.ps1 deploy.
    function New-CommentoDeploy($Id, [string[]]$Parametri) {
        [pscustomobject]@{ Id = $Id; Autore = 'Titolare'; Quando = '2026-11-01T08:30:00Z'
            Testo = "[responsabile] $(ConvertTo-TestoCommentoDeploy -Parametri $Parametri -Perche 'il recinto della card')`n`n— scritto da Claude (responsabile)" }
    }
    # Il commento con cui il responsabile della card di chiusura scrive una correzione (D52, gruppo 5), come lo scrive card.ps1 correzione.
    function New-CommentoCorrezione($Id, [string]$Natura = 'tecnico', [string]$Titolo = 'Il totale non somma') {
        $corpo = ConvertTo-TestoCommentoCorrezione -Tipo $Natura -Titolo $Titolo -Descrizione 'Il totale ignora le righe scontate.'
        [pscustomobject]@{ Id = $Id; Autore = 'Titolare'; Quando = '2026-11-02T11:00:00Z'; Testo = "[responsabile] $corpo`n`n— scritto da Claude (responsabile)" }
    }
    function New-SessioneInCorso([string]$Ruolo = 'responsabile', [string]$Id = 'sid-1') {
        @{ id = $Id; pid = 4242; avvio = '2026-11-16T08:00:00.0000000Z'; ruolo = $Ruolo; inizio = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o'); ripresa = $false; cartella = 'C:/x'; modello = 'opus'; sforzo = 'high' }
    }
}

Describe 'Smistatore: un giro' {
    BeforeEach {
        $script:Dati = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:Dati | Out-Null
        $script:CartellaOk = Join-Path $TestDrive 'wt-ok'   # un worktree che esiste, per le card che ne hanno uno
        New-Item -ItemType Directory $script:CartellaOk -Force | Out-Null
        $global:Mondo = @{
            Cards = @(); Commenti = @{}; Storia = @{}; Pr = @{}; Run = @{}; Esiti = @{}; Task = @{}
            ParametriDeploy = @('deployStime', 'deployDatabases')   # i booleani deploy* dello YAML della pipeline sul ramo
        }
        Mock Get-AdoUtenteCorrente { [pscustomobject]@{ Id = 'u-ric'; Nome = 'Titolare' } }
        Mock Get-AdoCardAttive { @($global:Mondo.Cards | ForEach-Object { if (-not $_.PSObject.Properties['PadreId']) { $_ | Add-Member -NotePropertyName PadreId -NotePropertyValue 1 }; $_ }) }; Mock Get-AdoFeatureAperte { @([pscustomobject]@{ Id = 1; Titolo = 'Raggruppa'; Stato = 'Active'; Tag = @(); Area = 'x'; Rank = $null }) }; Mock Get-AdoFeature { [pscustomobject]@{ Id = 1; Tipo = 'Feature'; Titolo = 'Raggruppa'; Stato = 'Active'; Tag = @(); Area = 'x'; FigliIds = @() } } -ParameterFilter { $Id -eq 1 }; Mock Get-AdoFigliFeature { @() } -ParameterFilter { @($FigliIds).Count -eq 0 }
        Mock Get-AdoCard { param($Id) $global:Mondo.Cards | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
        Mock Get-AdoCommenti { param($Id, $DopoId = 0) @($global:Mondo.Commenti["$Id"] | Where-Object { $null -ne $_ -and $_.Id -gt $DopoId }) }
        Mock Get-AdoStoriaStato { param($Id) @($global:Mondo.Storia["$Id"]) }
        Mock Get-AdoTaskFigli { param($CardId) @($global:Mondo.Task["$CardId"] | Where-Object { $null -ne $_ }) }
        Mock Get-AdoCardPredecessori { param($CardId) if ($global:Mondo.ContainsKey('Predecessori')) { @($global:Mondo.Predecessori["$CardId"] | Where-Object { $null -ne $_ }) } else { @() } }
        Mock Get-AdoPr { param($Progetto, $Repo, $Ramo, [switch]$AncheCompletate) $global:Mondo.Pr[$Ramo] }
        Mock Get-AdoRun { param($Progetto, $RunId) $global:Mondo.Run["$RunId"] }
        Mock Set-AdoCard { 55 }
        Mock Add-AdoCommento { 900 }
        Mock New-AdoPr { 77 }
        Mock Start-SessioneRuolo { [pscustomobject]@{ Id = 'sid-nuova'; Pid = 5151; Avvio = '2026-11-16T09:00:00.0000000Z'; Ripresa = [bool]$Riprendi } }
        Mock Get-EsitoSessione { param($Id) $global:Mondo.Esiti[$Id] }
        Mock Stop-Sessione { }
        Mock New-WorktreeCard { [pscustomobject]@{ Cartella = $global:CartellaWt; Ramo = 'feature/5-titolo-della-card' } }
        Mock Remove-WorktreeCard { [pscustomobject]@{ RamoCancellato = $true } }
        Mock Start-AdoDeployTest { 555 }
        Mock Get-AdoParametriDeploy { param($Progetto, $PipelineId, $Ramo) @($global:Mondo.ParametriDeploy) }
        Mock Complete-AdoPr { }
        Mock Test-SessioneViva { $true }
        Mock Send-TelegramAvviso { $true }
        Mock Set-AdoTaskStato { 1 }
        Mock New-WorktreeDaRemoto { [pscustomobject]@{ Cartella = $global:CartellaWt; Ramo = 'feature/5-lavoro-del-collega' } }
        # il worktree come lo trova un ruolo in sola lettura alla partenza; i test sul controllo cambiano quello di dopo
        Mock Get-ImprontaWorktree { @{ ramo = 'feature/5-x'; testa = 'aaa1111aaa'; stato = ''; diff = '' } }
    }

    Context 'un ruolo in sola lettura non cambia il worktree della card' {
        BeforeEach {
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            $script:InCorso = New-SessioneInCorso 'reviewer' 'sid-r'
            $script:InCorso['cartella'] = $script:CartellaOk
            $script:InCorso['impronta'] = @{ ramo = 'feature/5-x'; testa = 'aaa1111aaa'; stato = ''; diff = '' }
            $script:StatoRev = @{ sessione = $script:InCorso; ultimoRuolo = 'reviewer'; ramo = 'feature/5-x'; cartella = $script:CartellaOk }
        }

        It 'reviewer parte con l impronta del worktree salvata nella sessione' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 78; UrlLog = 'https://log/78' }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Get-ImprontaWorktree -Times 1 -Exactly -ParameterFilter { $Cartella -eq $script:CartellaOk }
            (Get-StatoFinale $script:Dati)['5']['sessione']['impronta']['testa'] | Should -Be 'aaa1111aaa'
        }

        It 'dev scrive per mestiere: parte senza impronta' {
            $global:CartellaWt = $script:CartellaOk
            $global:Mondo.Cards = @(New-FintaCard 5 'pronto')
            $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' }
            Should -Invoke Get-ImprontaWorktree -Times 0 -Exactly
        }

        It 'responsabile senza worktree lavora nella copia principale, che non e nostra: parte senza impronta' {
            $global:Mondo.Cards = @(New-FintaCard 5 'nuova')
            $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'responsabile' }
            Should -Invoke Get-ImprontaWorktree -Times 0 -Exactly
        }

        It 'la riserva superata ferma i lanci; con il bypass in soglia-quota.json della cartella dati la sessione parte (e non si legge il file reale)' {
            $global:Mondo.Cards = @(New-FintaCard 5 'nuova')
            $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
            $reset = (Get-Date).ToUniversalTime().AddDays(2).ToString('o')
            Save-Quota -Quota @{ sevenDay = @{ utilization = 0.95; resetsAt = $reset } } -Percorso (Join-Path $script:Dati 'quota.json')
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
            Save-SogliaQuota -Override @{ soglia = $null; ignoraRiserva = $true; fino = $reset; impostata = (Get-Date).ToUniversalTime().ToString('o') } -Percorso (Get-PercorsoSogliaQuotaPredefinito $script:Dati)
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'responsabile' }
        }

        It 'con il bypass la pausa dopo il limite di token ferma lo stesso i lanci' {
            $global:Mondo.Cards = @(New-FintaCard 5 'nuova')
            $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
            $reset = (Get-Date).ToUniversalTime().AddDays(2).ToString('o')
            Save-Quota -Quota @{ sevenDay = @{ utilization = 0.95; resetsAt = $reset }; pausaFino = (Get-Date).ToUniversalTime().AddHours(2).ToString('o') } -Percorso (Join-Path $script:Dati 'quota.json')
            Save-SogliaQuota -Override @{ soglia = $null; ignoraRiserva = $true; fino = $reset; impostata = (Get-Date).ToUniversalTime().ToString('o') } -Percorso (Get-PercorsoSogliaQuotaPredefinito $script:Dati)
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        }
        It 'reviewer che chiude con superata ma ha fatto un commit: card in on-hold con cosa e cambiato, la card non avanza' {
            Mock Get-ImprontaWorktree { @{ ramo = 'feature/5-x'; testa = 'bbb2222bbb'; stato = ''; diff = '' } }
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoRev }
            $global:Mondo.Esiti['sid-r'] = New-FintoEsito $true 'superata'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
            Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter {
                $Id -eq 5 -and $Testo -match '^\[smistatore\]' -and $Testo -match 'sola lettura' -and $Testo -match 'aaa1111' -and $Testo -match 'bbb2222' -and $Menziona -eq 'u-ric'
            }
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['sessione'] | Should -BeNullOrEmpty
            $s['inAttesaPer'] | Should -Be 'sessione'
            # quello che la sessione ha detto resta scritto, e i consumi si registrano lo stesso
            $s['ultimaSessione']['reviewer']['esito'] | Should -Be 'superata'
            @(Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl')).Count | Should -Be 1
            Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato }
            Should -Invoke Start-AdoDeployTest -Times 0 -Exactly
        }

        It 'reviewer che ha fatto un commit e poi trova il limite della quota: on-hold di D39, niente pausa con ripresa (D51)' {
            Mock Get-ImprontaWorktree { @{ ramo = 'feature/5-x'; testa = 'bbb2222bbb'; stato = ''; diff = '' } }
            Mock Test-SessioneViva { $false }
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoRev }
            $reset = (Get-Date).ToUniversalTime().AddHours(2)
            $e = New-FintoEsito $true $null $true
            $e | Add-Member Quota @{ five_hour = @{ Utilization = 1.0; ResetsAt = $reset } }
            $e | Add-Member Limite @{ Finestra = 'five_hour'; Reset = $reset }
            $global:Mondo.Esiti['sid-r'] = $e
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
            Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'sola lettura' }
            (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -Be 'sessione'
        }

        It 'reviewer che lascia il worktree com era prosegue come prima' {
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoRev }
            $global:Mondo.Esiti['sid-r'] = New-FintoEsito $true 'superata'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Add-AdoCommento -Times 0 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'sola lettura' }
            Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'Sessione sid-r finita' }
            (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -Not -Be 'sessione'
        }

        It 'una sessione avviata prima del controllo (senza impronta nello stato) si chiude come prima' {
            $script:InCorso.Remove('impronta')
            Mock Get-ImprontaWorktree { @{ ramo = 'feature/5-x'; testa = 'bbb2222bbb'; stato = ''; diff = '' } }
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoRev }
            $global:Mondo.Esiti['sid-r'] = New-FintoEsito $true 'superata'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Add-AdoCommento -Times 0 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'sola lettura' }
        }

        It 'reviewer morto senza risultato dopo aver cambiato il worktree: il motivo dell on-hold dice anche questo' {
            Mock Test-SessioneViva { $false }
            Mock Get-ImprontaWorktree { @{ ramo = 'feature/5-x'; testa = 'aaa1111aaa'; stato = '?? appunti.txt'; diff = '' } }
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoRev }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter {
                $Id -eq 5 -and $Testo -match 'terminata senza dare un risultato' -and $Testo -match 'sola lettura' -and $Testo -match 'appunti\.txt'
            }
        }

        It 'se il worktree non si riesce a leggere a fine sessione la card va in on-hold: il controllo non salta in silenzio' {
            Mock Get-ImprontaWorktree { throw 'git status e fallito' }
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoRev }
            $global:Mondo.Esiti['sid-r'] = New-FintoEsito $true 'superata'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
            Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'sola lettura' -and $Testo -match 'git status e fallito' }
        }
    }

    Context 'il registro dell apprendimento (D46): blocchi e on-hold' {
        BeforeEach {
            $script:Reg = Join-Path $script:Dati 'registro-apprendimento.jsonl'
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            $sess = New-SessioneInCorso 'dev' 'sid-d'; $sess['cartella'] = $script:CartellaOk
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = $sess; ultimoRuolo = 'dev'; ramo = 'feature/5-x'; cartella = $script:CartellaOk } }
        }

        It 'una sessione di ruolo che chiude con <Esito> lascia una riga blocco, con il suo testo come motivo' -ForEach @(
            @{ Esito = 'bloccato' }
            @{ Esito = 'bivio' }
        ) {
            $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true $Esito $false $null 'Non so quale libreria usare'
            Invoke-Giro $script:Dati | Out-Null
            $r = @(Get-Content $script:Reg | ConvertFrom-Json)
            $r.Count | Should -Be 1
            $r[0].tipo | Should -Be 'blocco'
            $r[0].card | Should -Be 5
            $r[0].repo | Should -Be 'Acme.AI'
            $r[0].ruolo | Should -Be 'dev'
            $r[0].motivo | Should -Match 'Non so quale libreria usare'
        }

        It 'una sessione che chiude con fatto non lascia niente nel registro' {
            $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true 'fatto'
            Invoke-Giro $script:Dati | Out-Null
            Test-Path $script:Reg | Should -BeFalse
        }

        It 'una sessione fallita non e un blocco: il registro non ha righe blocco' {
            $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true 'bloccato' $true
            Invoke-Giro $script:Dati | Out-Null
            @(if (Test-Path $script:Reg) { Get-Content $script:Reg | ConvertFrom-Json | Where-Object { $_.tipo -eq 'blocco' } }).Count | Should -Be 0
        }

        It 'la card messa in on-hold lascia una riga onHold con l ultimo ruolo e il testo del motivo' {
            $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true 'fatto' $true
            Invoke-Giro $script:Dati | Out-Null
            $r = @(Get-Content $script:Reg | ConvertFrom-Json | Where-Object { $_.tipo -eq 'onHold' })
            $r.Count | Should -Be 1
            $r[0].card | Should -Be 5
            $r[0].repo | Should -Be 'Acme.AI'
            $r[0].ruolo | Should -Be 'dev'
            $r[0].motivo | Should -Match 'La sessione di dev e fallita'
        }

        It 'con -WhatIf non si scrive niente nel registro' {
            $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true 'bloccato'
            Invoke-Giro $script:Dati @{ WhatIf = $true } | Out-Null
            Test-Path $script:Reg | Should -BeFalse
        }
    }

    Context 'la memoria dei ruoli nel lancio di una sessione (D46)' {
        It 'passa il repo della card a Start-SessioneRuolo: senza, la sessione parte senza le sue lezioni' {
            $global:CartellaWt = $script:CartellaOk
            $global:Mondo.Cards = @(New-FintaCard 5 'pronto')
            $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Repo -eq 'Acme.AI' }
        }

        It 'gli avvisi della memoria finiscono nel log come WARN, e la sessione parte lo stesso' {
            $global:CartellaWt = $script:CartellaOk
            $global:Mondo.Cards = @(New-FintaCard 5 'pronto')
            $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'
            Mock Start-SessioneRuolo { [pscustomobject]@{ Id = 'sid-nuova'; Pid = 5151; Avvio = '2026-11-16T09:00:00.0000000Z'; Ripresa = $false; AvvisiMemoria = @('fetch fallito, rete giu') } }
            $out = Invoke-Giro $script:Dati
            $out | Should -Match 'WARN card 5: memoria dei ruoli, dev parte senza il suo meglio: fetch fallito, rete giu'
            (Get-StatoFinale $script:Dati)['5']['sessione']['id'] | Should -Be 'sid-nuova'
        }
    }

    Context 'il mentore in -WhatIf (D46)' {
        It 'LanciaMentore si stampa con i suoi campi e non scrive niente' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'responsabile'; ultimaSessione = @{ responsabile = @{ id = 'r1'; esito = 'fatto'; motivo = 'bloccato'; fine = '2026-11-01T10:00:00Z'; testo = 'Usa la libreria X' } } } }
            $out = Invoke-Giro $script:Dati @{ WhatIf = $true }
            $out | Should -Match 'LanciaMentore'
            $out | Should -Match 'Innesco=decisione'
            $out | Should -Match 'Chiave=decisione@r1'
            Test-Path (Join-Path $script:Dati 'registro-apprendimento.jsonl') | Should -BeFalse
        }
    }

    Context 'il mentore (D46): lancio, chiusura, registro dell apprendimento' {
        BeforeEach {
            $script:RegApp = Join-Path $script:Dati 'registro-apprendimento.jsonl'
            $script:RegSes = Join-Path $script:Dati 'registro-sessioni.jsonl'
            # una persona commenta una card In review: parte il solo mentore, nessun ruolo (vedi Decisioni, innesco commento)
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            $global:Mondo.Commenti['5'] = @([pscustomobject]@{ Id = 31; Autore = 'Anna'; Testo = 'Fai cosi'; Quando = '2026-11-02T09:00:00Z' })
            Mock Start-SessioneRuolo { [pscustomobject]@{ Id = "sid-$Ruolo"; Pid = 5151; Avvio = '2026-11-16T09:00:00.0000000Z'; Ripresa = [bool]$Riprendi } }
            $script:Voce = Find-VoceMappa -Mappa $script:Cfg.Mappa -Area $script:Area
        }

        It 'lancia il mentore in una cartella sua sotto la cartella dati, con card, repo, ruoli, correttore, innesco, il percorso di memoria.ps1 e della copia principale; il testo e l allegato' {
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev' } }
            Invoke-Giro $script:Dati | Out-Null
            $dirMentori = Join-Path $script:Dati 'mentori'
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter {
                $Ruolo -eq 'mentore' -and $Card -eq 5 -and $Cartella.StartsWith($dirMentori) -and $Cartella -ne $script:CartellaOk -and $Allegato -eq 'Anna: Fai cosi' -and -not $Repo -and
                $Messaggio -match 'Card 5 nel repo Acme\.AI' -and $Messaggio -match 'responsabile' -and $Messaggio -match 'persona' -and $Messaggio -match 'commento' -and
                $Messaggio -match 'src[\\/]memoria\.ps1' -and $Messaggio.Contains($script:Voce.cartella)
            }
        }

        It 'la cartella del mentore esiste vuota al lancio ed e la stessa con o senza worktree; resta in mentori per toglierla alla chiusura' {
            $global:Lancio = @{}
            Mock Start-SessioneRuolo {
                $global:Lancio.Esiste = Test-Path -LiteralPath $Cartella; $global:Lancio.Cartella = $Cartella
                $global:Lancio.Vuota = @(Get-ChildItem -LiteralPath $Cartella -Force).Count -eq 0
                [pscustomobject]@{ Id = "sid-$Ruolo"; Pid = 5151; Avvio = '2026-11-16T09:00:00.0000000Z'; Ripresa = $false }
            }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ultimoRuolo = 'dev' } }
            Invoke-Giro $script:Dati | Out-Null
            $global:Lancio.Esiste | Should -BeTrue
            $global:Lancio.Vuota | Should -BeTrue
            $global:Lancio.Cartella | Should -BeLike (Join-Path $script:Dati 'mentori/*')
            $global:Lancio.Cartella | Should -Not -Be $script:Voce.cartella
            (Get-StatoFinale $script:Dati)['5']['mentori'][0]['cartella'] | Should -Be $global:Lancio.Cartella
            Remove-Variable Lancio -Scope Global
        }

        It 'non tocca la sessione della card, l ultimo ruolo, l ultima sessione, l attesa; tiene la sua in mentori e la chiave in mentoriFatti' {
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
            Invoke-Giro $script:Dati | Out-Null
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['sessione'] | Should -BeNullOrEmpty
            $s['ultimoRuolo'] | Should -Be 'dev'
            @($s['ultimaSessione'].Keys) | Should -Be @('dev')
            $s['ultimaSessione']['dev']['id'] | Should -Be 'd1'
            $s['inAttesaPer'] | Should -BeNullOrEmpty
            @($s['mentori']).Count | Should -Be 1
            $s['mentori'][0]['id'] | Should -Be 'sid-mentore'
            $s['mentori'][0]['pid'] | Should -Be 5151
            $s['mentori'][0]['ruolo'] | Should -Be 'mentore'
            $s['mentori'][0]['modello'] | Should -Be 'opus'
            $s['mentori'][0]['inizio'] | Should -Not -BeNullOrEmpty
            @($s['mentoriFatti']) | Should -Be @('commento@31')
        }

        It 'una riga correzione nel registro dell apprendimento, per il ruolo istruito, con innesco e correttore' {
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev' } }
            Invoke-Giro $script:Dati | Out-Null
            $r = @(Get-Content $script:RegApp | ConvertFrom-Json | Where-Object { $_.tipo -eq 'correzione' })
            $r.Count | Should -Be 1
            $r[0].card | Should -Be 5
            $r[0].repo | Should -Be 'Acme.AI'
            $r[0].ruolo | Should -Be 'responsabile'
            $r[0].motivo | Should -Match 'commento'
            $r[0].motivo | Should -Match 'persona'
        }

        It 'una correzione per piu ruoli lascia una riga correzione per ciascuno' {
            # Human test -> In development: correggono collaudatore e reviewer; dev riparte sul worktree della card
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = @(
                [pscustomobject]@{ Rev = 1; Da = $null; A = (St 'bozza'); Chi = 'u-ric'; ChiNome = 'x'; Quando = '2026-11-01T08:00:00Z' }
                [pscustomobject]@{ Rev = 15; Da = (St 'inCollaudo'); A = (St 'inProvaUmana'); Chi = 'u-ric'; ChiNome = 'x'; Quando = '2026-11-01T08:30:00Z' }
                [pscustomobject]@{ Rev = 20; Da = (St 'inProvaUmana'); A = (St 'inSviluppo'); Chi = 'u-rich'; ChiNome = 'x'; Quando = '2026-11-01T09:00:00Z' }
            )
            $global:Mondo.Commenti['5'] = @([pscustomobject]@{ Id = 31; Autore = 'Anna'; Testo = 'Il pulsante non fa niente'; Quando = '2026-11-02T09:00:00Z' })
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'responsabile' } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'mentore' -and $Messaggio -match 'collaudatore' -and $Messaggio -match 'reviewer' }
            $r = @(Get-Content $script:RegApp | ConvertFrom-Json | Where-Object { $_.tipo -eq 'correzione' -and $_.motivo -match 'provaUmana' })
            @($r.ruolo | Sort-Object) | Should -Be @('collaudatore', 'reviewer')
        }

        It 'il giro dopo non lo rilancia: la chiave e fra i fatti, anche con il mentore ancora in corso' {
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev' } }
            Invoke-Giro $script:Dati | Out-Null
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'mentore' }
            @((Get-StatoFinale $script:Dati)['5']['mentori']).Count | Should -Be 1
        }


        It 'se il lancio fallisce: la chiave non resta fra i fatti, la card non va in on-hold, nessuna riga correzione; al giro dopo riprova' {
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev' } }
            Mock Start-SessioneRuolo { throw 'claude non parte' }
            $out = Invoke-Giro $script:Dati
            $out | Should -Match 'claude non parte'
            @(Get-ChildItem -LiteralPath (Join-Path $script:Dati 'mentori') -Force -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'la cartella di un lancio fallito non resta'
            Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag -contains 'on-hold' }
            $s = (Get-StatoFinale $script:Dati)['5']
            @($s['mentoriFatti']).Count | Should -Be 0
            @($s['mentori']).Count | Should -Be 0
            $s['inAttesaPer'] | Should -BeNullOrEmpty
            Test-Path $script:RegApp | Should -BeFalse
            Mock Start-SessioneRuolo { [pscustomobject]@{ Id = "sid-$Ruolo"; Pid = 5151; Avvio = '2026-11-16T09:00:00.0000000Z'; Ripresa = $false } }
            Invoke-Giro $script:Dati | Out-Null
            # due chiamate in tutto: quella fallita del primo giro e quella riuscita del secondo
            Should -Invoke Start-SessioneRuolo -Times 2 -Exactly -ParameterFilter { $Ruolo -eq 'mentore' }
            @((Get-StatoFinale $script:Dati)['5']['mentoriFatti']) | Should -Be @('commento@31')
            @((Get-StatoFinale $script:Dati)['5']['mentori']).Count | Should -Be 1
        }

        Context 'a fine sessione' {
            BeforeEach {
                $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione' -Tokens 100 -Minuti 5)
                $global:Mondo.Commenti['5'] = @()
                $m = New-SessioneInCorso 'mentore' 'sid-m'
                $script:StatoMentore = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; mentori = @($m); mentoriFatti = @('commento@31') }
            }

            It 'un mentore finito: riga in registro-sessioni con ruolo mentore, consumi sommati alla card, esce da mentori, la card non cambia' {
                Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoMentore }
                $global:Mondo.Esiti['sid-m'] = New-FintoEsito $true 'fatto'
                Invoke-Giro $script:Dati | Out-Null
                $righe = @(Get-Content $script:RegSes | ConvertFrom-Json)
                $righe.Count | Should -Be 1
                $righe[0].ruolo | Should -Be 'mentore'
                $righe[0].sessione | Should -Be 'sid-m'
                $righe[0].card | Should -Be 5
                $righe[0].tokenOut | Should -Be 200
                $righe[0].esito | Should -Be 'fatto'
                Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Campi['Custom.TotalTokens'] -eq 3710 -and $Campi['Custom.AgentMinutes'] -eq 8 }
                $s = (Get-StatoFinale $script:Dati)['5']
                @($s['mentori']).Count | Should -Be 0
                @($s['mentoriFatti']) | Should -Be @('commento@31')
                $s['ultimoRuolo'] | Should -Be 'dev'
                $s['ultimaSessione'].Count | Should -Be 0
                $s['inAttesaPer'] | Should -BeNullOrEmpty
                Should -Invoke Add-AdoCommento -Times 0 -Exactly -ParameterFilter { $Testo -match 'Sessione sid-m' }
            }

            It 'un mentore ancora in corso resta in mentori e non lascia righe' {
                Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoMentore }
                $global:Mondo.Esiti['sid-m'] = New-FintoEsito $false $null $false (Get-Date).ToUniversalTime()
                Invoke-Giro $script:Dati | Out-Null
                Test-Path $script:RegSes | Should -BeFalse
                @((Get-StatoFinale $script:Dati)['5']['mentori']).Count | Should -Be 1
            }

            It 'un mentore fallito si registra come errore, esce da mentori e la card non va in on-hold' {
                Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoMentore }
                Mock Test-SessioneViva { $false }   # un result senza ESITO con il processo vivo e una pausa, non la fine
                $global:Mondo.Esiti['sid-m'] = New-FintoEsito $true $null $true
                Invoke-Giro $script:Dati | Out-Null
                (Get-Content $script:RegSes | ConvertFrom-Json).esito | Should -Be 'errore'
                @((Get-StatoFinale $script:Dati)['5']['mentori']).Count | Should -Be 0
                Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag -contains 'on-hold' }
                (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -BeNullOrEmpty
            }

            It 'un mentore morto senza risultato si registra come errore e sparisce da mentori, senza on-hold' {
                Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoMentore }
                Mock Test-SessioneViva { $false }
                $global:Mondo.Esiti['sid-m'] = New-FintoEsito $false $null $false $null 'x' 0
                Invoke-Giro $script:Dati | Out-Null
                (Get-Content $script:RegSes | ConvertFrom-Json).esito | Should -Be 'errore'
                @((Get-StatoFinale $script:Dati)['5']['mentori']).Count | Should -Be 0
                Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag -contains 'on-hold' }
            }

            It 'un mentore in silenzio oltre il limite si ferma, si registra come silenzio e sparisce da mentori' {
                Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoMentore }
                $global:Mondo.Esiti['sid-m'] = New-FintoEsito $false $null $false (Get-Date).ToUniversalTime().AddMinutes(-600)
                Invoke-Giro $script:Dati | Out-Null
                Should -Invoke Stop-Sessione -Times 1 -Exactly
                (Get-Content $script:RegSes | ConvertFrom-Json).esito | Should -Be 'silenzio'
                @((Get-StatoFinale $script:Dati)['5']['mentori']).Count | Should -Be 0
                Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag -contains 'on-hold' }
            }

            It 'un mentore finito toglie la sua cartella; una cartella fuori da mentori nella cartella dati non si tocca mai' {
                $mia = Join-Path $script:Dati 'mentori/m1'; New-Item -ItemType Directory $mia -Force | Out-Null
                $m = New-SessioneInCorso 'mentore' 'sid-m'; $m['cartella'] = $mia
                Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; mentori = @($m) } }
                $global:Mondo.Esiti['sid-m'] = New-FintoEsito $true 'fatto'
                Invoke-Giro $script:Dati | Out-Null
                Test-Path $mia | Should -BeFalse

                $altrui = Join-Path $TestDrive 'non-mia'; New-Item -ItemType Directory $altrui -Force | Out-Null
                $m2 = New-SessioneInCorso 'mentore' 'sid-m2'; $m2['cartella'] = $altrui
                Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; mentori = @($m2) } }
                $global:Mondo.Esiti['sid-m2'] = New-FintoEsito $true 'fatto'
                Invoke-Giro $script:Dati | Out-Null
                Test-Path $altrui | Should -BeTrue
            }

            It 'due mentori finiti e il secondo si chiude con un errore: il primo e gia fuori da mentori, il giro dopo non lo registra due volte' {
                $m1 = New-SessioneInCorso 'mentore' 'sid-m1'; $m2 = New-SessioneInCorso 'mentore' 'sid-m2'
                Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; mentori = @($m1, $m2) } }
                $global:Mondo.Esiti['sid-m1'] = New-FintoEsito $true 'fatto'
                $global:Mondo.Esiti['sid-m2'] = New-FintoEsito $true 'fatto'
                Mock Get-EsitoSessione { param($Id) if ($Id -eq 'sid-m2') { throw 'uscita illeggibile' }; $global:Mondo.Esiti[$Id] }
                Invoke-Giro $script:Dati | Out-Null
                @((Get-StatoFinale $script:Dati)['5']['mentori'] | ForEach-Object { $_['id'] }) | Should -Be @('sid-m2')
                Mock Get-EsitoSessione { param($Id) $global:Mondo.Esiti[$Id] }
                Invoke-Giro $script:Dati | Out-Null
                $righe = @(Get-Content $script:RegSes | ConvertFrom-Json)
                @($righe | Where-Object { $_.sessione -eq 'sid-m1' }).Count | Should -Be 1
                @($righe | Where-Object { $_.sessione -eq 'sid-m2' }).Count | Should -Be 1
                @((Get-StatoFinale $script:Dati)['5']['mentori']).Count | Should -Be 0
            }

            It 'la card ceduta con un mentore ancora vivo: la voce di stato si toglie e il log dice che i suoi consumi non arriveranno sulla card' {
                $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione' -Assegnata 'u-collega')
                Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; mentori = @(New-SessioneInCorso 'mentore' 'sid-m') } }
                $global:Mondo.Esiti['sid-m'] = New-FintoEsito $false $null $false (Get-Date).ToUniversalTime()
                $out = Invoke-Giro $script:Dati
                $out | Should -Match 'WARN card 5: .*sid-m.*consumi'
                (Get-StatoFinale $script:Dati).Contains('5') | Should -BeFalse
                Should -Invoke Stop-Sessione -Times 0 -Exactly
            }

            It 'con -WhatIf non chiude niente: il mentore resta, niente righe' {
                Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoMentore }
                $global:Mondo.Esiti['sid-m'] = New-FintoEsito $true 'fatto'
                Invoke-Giro $script:Dati @{ WhatIf = $true } | Out-Null
                Test-Path $script:RegSes | Should -BeFalse
                @((Get-StatoFinale $script:Dati)['5']['mentori']).Count | Should -Be 1
            }
        }
    }

    Context 'lezioneApplicata (D46)' {
        BeforeEach {
            $script:RegApp = Join-Path $script:Dati 'registro-apprendimento.jsonl'
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            $sess = New-SessioneInCorso 'dev' 'sid-d'; $sess['cartella'] = $script:CartellaOk
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = $sess; ultimoRuolo = 'dev'; ramo = 'feature/5-x'; cartella = $script:CartellaOk } }
        }

        It 'ogni riga LEZIONE del testo finale diventa una riga del registro, con ruolo, card, repo e id' {
            $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true 'fatto' $false $null 'Fatto.' 3 @() @('dev-003', 'dev-004')
            Invoke-Giro $script:Dati | Out-Null
            $r = @(Get-Content $script:RegApp | ConvertFrom-Json | Where-Object { $_.tipo -eq 'lezioneApplicata' })
            $r.Count | Should -Be 2
            @($r.lezione) | Should -Be @('dev-003', 'dev-004')
            $r[0].ruolo | Should -Be 'dev'
            $r[0].card | Should -Be 5
            $r[0].repo | Should -Be 'Acme.AI'
        }

        It 'la riga porta l esito della sessione in cui la lezione e stata applicata (finito, bloccato, bivio)' {
            foreach ($e in 'finito', 'bloccato', 'bivio') {
                Remove-Item $script:RegApp -ErrorAction SilentlyContinue
                $sess = New-SessioneInCorso 'dev' 'sid-d'; $sess['cartella'] = $script:CartellaOk
                Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = $sess; ultimoRuolo = 'dev'; ramo = 'feature/5-x'; cartella = $script:CartellaOk } }
                $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true $e $false $null 'Fatto.' 3 @() @('dev-003')
                Invoke-Giro $script:Dati | Out-Null
                $r = @(Get-Content $script:RegApp | ConvertFrom-Json | Where-Object { $_.tipo -eq 'lezioneApplicata' })
                $r.Count | Should -Be 1
                $r[0].esito | Should -Be $e
            }
        }
        It 'senza righe LEZIONE il registro non ha righe lezioneApplicata' {
            $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true 'fatto'
            Invoke-Giro $script:Dati | Out-Null
            Test-Path $script:RegApp | Should -BeFalse
        }
    }

    Context 'piu smistatori: ogni card ha un padrone (spec, sezione 19)' {
        It 'una card assegnata a un altro non si tocca: nessuna sessione, nessuna scrittura' {
            $global:Mondo.Cards = @(New-FintaCard 5 'nuova' -Assegnata 'u-collega')
            $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            Should -Invoke Add-AdoCommento -Times 0 -Exactly
        }

        It 'una card senza assegnatario non la prende nessuno' {
            $global:Mondo.Cards = @(New-FintaCard 5 'nuova' -Assegnata $null)
            $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        }

        It 'i limiti sulle risorse comuni contano anche le card degli altri' {
            # una card del collega e in sviluppo sullo stesso repo: la mia resta in Ready to develop
            $global:Mondo.Cards = @((New-FintaCard 5 'pronto'), (New-FintaCard 6 'inSviluppo' -Assegnata 'u-collega'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'
            $global:Mondo.Storia['6'] = New-FintaStoria 'inSviluppo'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke New-WorktreeCard -Times 0 -Exactly
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        }

        It 'una card mia oltre Ready to develop senza stato locale si prende in carico dal ramo remoto' {
            $global:CartellaWt = Join-Path $TestDrive 'wt-card-5'
            New-Item -ItemType Directory $global:CartellaWt -Force | Out-Null
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke New-WorktreeDaRemoto -Times 1 -Exactly -ParameterFilter { $Card.Id -eq 5 }
            Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'presa in carico' -and $Testo -match 'feature/5-lavoro-del-collega' }
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['ramo'] | Should -Be 'feature/5-lavoro-del-collega'
            $s['cartella'] | Should -Be $global:CartellaWt
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        }

        It 'senza ramo su origin la presa in carico si ferma: on-hold con il motivo' {
            Mock New-WorktreeDaRemoto { throw 'Su origin non ce nessun ramo della card 5' }
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
            Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'nessun ramo' }
        }

        It 'una card mia riassegnata a un altro: tolgo il worktree e lo stato locale, senza scrivere sulla card' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' -Assegnata 'u-collega')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; prId = 9; ultimoRuolo = 'dev' } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Remove-WorktreeCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Ramo -eq 'feature/5-x' -and $Cartella -eq 'C:/wt/card-5' }
            (Get-StatoFinale $script:Dati).Contains('5') | Should -BeFalse
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            Should -Invoke Add-AdoCommento -Times 0 -Exactly
        }

        It 'se il worktree della card riassegnata ha lavoro non pubblicato resta, con lo stato: niente on-hold sulla card altrui' {
            Mock Remove-WorktreeCard { throw 'Il ramo feature/5-x ha commit non pubblicati' }
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' -Assegnata 'u-collega')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; prId = 9 } }
            $log = Invoke-Giro $script:Dati
            (Get-StatoFinale $script:Dati)['5']['cartella'] | Should -Be 'C:/wt/card-5'
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            $log | Should -Match 'non pubblicati'
        }

        It 'al ritorno dell assente, una sessione morta su una card ora del collega si chiude senza scrivere sulla card' {
            Mock Test-SessioneViva { $false }
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' -Assegnata 'u-collega')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; prId = 9 } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            Should -Invoke Add-AdoCommento -Times 0 -Exactly
            Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
        }

        It 'una sessione ancora viva su una card riassegnata si ferma: la card ora la porta avanti il collega' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' -Assegnata 'u-collega')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; prId = 9 } }
            $global:Mondo.Esiti['sid-d'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-2))
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Stop-Sessione -Times 1 -Exactly -ParameterFilter { $ProcessoId -eq 4242 }
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            Should -Invoke Add-AdoCommento -Times 0 -Exactly
        }

        It 'una card senza assegnatario con stato locale non si pulisce: assegnatario nullo vuol dire fermo, non ceduto' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' -Assegnata $null)
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; prId = 9; ultimoRuolo = 'dev' } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Remove-WorktreeCard -Times 0 -Exactly
            (Get-StatoFinale $script:Dati)['5']['ramo'] | Should -Be 'feature/5-x'
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        }

        It 'se la pulizia fallisce la voce resta segnata come ceduta e non si riprova a ogni giro' {
            Mock Remove-WorktreeCard { throw 'Il ramo feature/5-x ha commit non pubblicati' }
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' -Assegnata 'u-collega')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; prId = 9 } }
            Invoke-Giro $script:Dati | Out-Null
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Remove-WorktreeCard -Times 1 -Exactly
            (Get-StatoFinale $script:Dati)['5']['ceduta'] | Should -BeTrue
        }

        It 'una card ceduta che torna mia: si toglie il worktree vecchio e lo stato, poi si riprende dal ramo remoto' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; prId = 9; ultimoRuolo = 'dev'; ceduta = $true } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Remove-WorktreeCard -Times 1 -Exactly -ParameterFilter { $Cartella -eq 'C:/wt/card-5' }
            (Get-StatoFinale $script:Dati).Contains('5') | Should -BeFalse
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        }

        It 'una card ceduta che torna mia con il worktree ancora sporco va in on-hold con il motivo' {
            Mock Remove-WorktreeCard { throw 'Il worktree C:/wt/card-5 ha lavoro non salvato' }
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; prId = 9; ultimoRuolo = 'dev'; ceduta = $true } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
            Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'lavoro non salvato' }
        }

        It 'la PR trovata nell istantanea si salva nello stato, anche se non l ha aperta questo smistatore' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = (Get-Date).ToUniversalTime().ToString('o') } } } }
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 33; Stato = 'active'; Validazione = 'inCorso'; BuildId = 1; UrlLog = 'u' }
            Invoke-Giro $script:Dati | Out-Null
            (Get-StatoFinale $script:Dati)['5']['prId'] | Should -Be 33
        }

        It 'presa in carico In development senza ramo su origin: nessun lavoro pubblicato da perdere, si riparte da develop' {
            Mock New-WorktreeDaRemoto { $null }
            $global:CartellaWt = Join-Path $TestDrive 'wt-card-5'
            New-Item -ItemType Directory $global:CartellaWt -Force | Out-Null
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke New-WorktreeCard -Times 1 -Exactly
            (Get-StatoFinale $script:Dati)['5']['ramo'] | Should -Be 'feature/5-titolo-della-card'
            Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
        }

        It 'presa in carico in Ready to release senza ramo su origin e con la PR collegata gia completata: e rilasciata, niente on-hold' {
            Mock New-WorktreeDaRemoto { $null }
            Mock Get-AdoPrCollegata { [pscustomobject]@{ Id = 951; Stato = 'completed' } }
            $global:Mondo.Cards = @(New-FintaCard 5 'daRilasciare')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daRilasciare'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Get-AdoPrCollegata -Times 1 -Exactly -ParameterFilter { $CardId -eq 5 }
            (Get-StatoFinale $script:Dati)['5']['prId'] | Should -Be 951
            Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke New-WorktreeDaRemoto -Times 1 -Exactly
        }

        It 'se il commento della presa in carico fallisce la card non va in on-hold: il worktree c e' {
            $global:CartellaWt = Join-Path $TestDrive 'wt-card-5'
            New-Item -ItemType Directory $global:CartellaWt -Force | Out-Null
            Mock Add-AdoCommento { throw 'commento rifiutato' }
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
            (Get-StatoFinale $script:Dati)['5']['ramo'] | Should -Be 'feature/5-lavoro-del-collega'
        }

        It 'dopo aver fermato la sessione della card riassegnata, nello stesso giro si toglie anche il worktree' {
            # come nella realta: fermata la sessione, il processo non c'e piu
            $global:Fermata = $false
            Mock Stop-Sessione { $global:Fermata = $true }
            Mock Test-SessioneViva { -not $global:Fermata }
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' -Assegnata 'u-collega')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; ramo = 'feature/5-x'; cartella = 'C:/wt/card-5' } }
            $global:Mondo.Esiti['sid-d'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-2))
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Stop-Sessione -Times 1 -Exactly
            Should -Invoke Remove-WorktreeCard -Times 1 -Exactly
            (Get-StatoFinale $script:Dati).Contains('5') | Should -BeFalse
        }
    }

    It 'il collaudatore parte nel worktree della card, con il file delle credenziali del repo' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inCollaudo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'
        $global:Mondo.Run['300'] = [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded' }
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; prId = 9; runId = 300; runDopoRev = 20; ultimoRuolo = 'reviewer'
            ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter {
            $Ruolo -eq 'collaudatore' -and $Cartella -eq $script:CartellaOk -and $FileCollaudo -like '*collaudo*Acme.AI.json' -and $Messaggio -match 'Motivo: collaudo\.' }
    }

    It 'un collaudo superato porta la card in Ready to merge e azzera il conto dei collaudi respinti' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inCollaudo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'
        $global:Mondo.Run['300'] = [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded' }
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; prId = 9; runId = 300; runDopoRev = 20; ultimoRuolo = 'collaudatore'; giriCollaudo = 1
            ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' }; collaudatore = @{ id = 'c1'; esito = 'superata'; testo = 'ok'; inizio = '2026-11-02T09:00:00Z'; fine = '2026-11-02T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq 'Ready to merge' }
        (Get-StatoFinale $script:Dati)['5']['giriCollaudo'] | Should -Be 0
    }

    It 'un collaudo respinto conta un giro quando parte responsabile' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inCollaudo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'
        $global:Mondo.Run['300'] = [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded' }
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; prId = 9; runId = 300; runDopoRev = 20; ultimoRuolo = 'collaudatore'
            ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' }; collaudatore = @{ id = 'c1'; esito = 'respinta'; testo = 'no'; inizio = '2026-11-02T09:00:00Z'; fine = '2026-11-02T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'responsabile' -and $Messaggio -match 'Motivo: collaudoRespinto\.' }
        (Get-StatoFinale $script:Dati)['5']['giriCollaudo'] | Should -Be 1
    }

    It 'il giro di un altra cartella dati (lo smistatore vero, mentre girano i test) non blocca questo' {
        $global:Mondo.Cards = @(New-FintaCard 5 'nuova')
        $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
        $altro = Get-NomeGiro -CartellaDati (Join-Path $TestDrive 'altra-cartella-dati')
        $preso = Enter-Giro -Nome $altro
        try { Invoke-Giro $script:Dati | Out-Null }
        finally { if ($preso) { Exit-Giro -Nome $altro } }
        $preso | Should -BeTrue
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly
    }

    It 'D52: il contesto del giro e la cache della funzionalita: due card della stessa Feature, una lettura del padre e una delle figlie' {
        $global:Mondo.Cards = @(New-FintaCard 5 'nuova'; New-FintaCard 6 'nuova')
        foreach ($c in $global:Mondo.Cards) { $c | Add-Member -NotePropertyName PadreId -NotePropertyValue 7 }
        $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'; $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
        Mock Get-AdoFeature { [pscustomobject]@{ Id = 7; Tipo = 'Feature'; Titolo = 'F'; Stato = 'New'; Tag = @(); Area = 'area-della-feature'; FigliIds = @(5, 6) } }
        Mock Get-AdoFigliFeature { @([pscustomobject]@{ Id = 5; Stato = 'New'; Tag = @(); Tipo = 'User Story' }, [pscustomobject]@{ Id = 6; Stato = 'New'; Tag = @(); Tipo = 'User Story' }) }
        # l'interruttore funzionalitaAttive e spento nel file reale: qui si accende
        Invoke-Giro $script:Dati @{ Radice = (New-RadiceDiProva -Cartella $TestDrive -Limiti @{ funzionalitaAttive = $true }) } | Out-Null
        Should -Invoke Get-AdoFeature -Times 1 -Exactly
        Should -Invoke Get-AdoFigliFeature -Times 1 -Exactly
    }

    It 'una card in New fa partire responsabile e la sessione finisce nello stato' {
        $global:Mondo.Cards = @(New-FintaCard 5 'nuova')
        $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter {
            $Card -eq 5 -and $Ruolo -eq 'responsabile' -and -not $Riprendi -and
            $Messaggio -match 'Card 5 nel repo Acme\.AI\.' -and $Messaggio -match 'Motivo: nuova\.' -and $Cartella -eq 'C:/develop/GIT/Acme.AI' -and
            $CartellaDati -eq $script:Dati -and -not $Allegato
        }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['sessione']['id'] | Should -Be 'sid-nuova'
        $s['sessione']['ruolo'] | Should -Be 'responsabile'
        $s['sessione']['pid'] | Should -Be 5151
        (ConvertTo-DataUtc $s['sessione']['avvio']) | Should -Be (ConvertTo-DataUtc '2026-11-16T09:00:00.0000000Z')   # lo stato rilegge le date come DateTime
        $s['ultimoRuolo'] | Should -Be 'responsabile'
        $s['ultimaSessione']['responsabile']['id'] | Should -Be 'sid-nuova'
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter {
            $Id -eq 5 -and $Testo -match '^\[smistatore\]' -and $Testo -match 'sid-nuova' -and $Testo -match 'responsabile' -and $Testo -match 'C:/develop/GIT/Acme\.AI'
        }
    }

    It 'il messaggio ha due righe e l allegato va a parte (e il file che lo porta alla sessione)' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'rossa'; BuildId = 77; UrlLog = 'https://log/77' }
        # il log lo scarica lo smistatore: dev non ha il PAT (verificato il 2026-11-17 sulla card 9)
        Mock Get-AdoErroriBuild { "Passo 'Run tests'`n  Failed Prova.Test_che_fallisce [39 s]`n  Error Message:`n   boom" }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Get-AdoErroriBuild -Times 1 -Exactly -ParameterFilter { $BuildId -eq 77 -and $Progetto -eq 'Acme.AI' }
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter {
            $Ruolo -eq 'dev' -and @($Messaggio -split "`n").Count -eq 2 -and $Messaggio -match 'Motivo: rossa\.' -and
            $Allegato -like '*https://log/77*' -and $Allegato -like '*Failed Prova.Test_che_fallisce*' -and $Allegato -like '*boom*'
        }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['rossaGestita'] | Should -Be 77
        $s['rosseDiFila'] | Should -Be 1
    }

    It 'il motivo del lancio resta nella sessione e nell ultima sessione del ruolo, anche dopo la chiusura' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ passateFatte = @('la PR ha ancora conflitti con develop dopo che dev ha provato a risolverli'); ramo = 'feature/5-x'; cartella = $script:CartellaOk; prId = 9; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'conflitti'; BuildId = $null; UrlLog = $null }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Messaggio -match 'Motivo: conflitti\.' }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['sessione']['motivo'] | Should -Be 'conflitti'
        $s['ultimaSessione']['dev']['motivo'] | Should -Be 'conflitti'
        # finita: il motivo resta, e i conflitti ancora li mettono la card in on-hold invece di rilanciare dev
        $global:Mondo.Esiti['sid-nuova'] = New-FintoEsito $true 'fatto'
        Invoke-Giro $script:Dati | Out-Null
        (Get-StatoFinale $script:Dati)['5']['ultimaSessione']['dev']['motivo'] | Should -Be 'conflitti'
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
    }

    It 'dev chiude con rilancia dopo una rossa: la validazione si rilancia una volta, con un commento, poi si segue la PR' {
        Mock Start-AdoRivalutazione { 1 }
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; rossaGestita = 77; rosseDiFila = 1; ultimoRuolo = 'dev'
            ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'rilancia'; fine = '2026-11-01T10:00:00Z'; motivo = 'rossa' } } } }
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'rossa'; BuildId = 77; UrlLog = 'https://log/77' }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-AdoRivalutazione -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'Acme.AI' -and $Repo -eq 'Acme.AI' -and $Ramo -eq 'feature/5-x' }
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match '^\[smistatore\]' -and $Testo -match 'rilanciat' }
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag -contains 'on-hold' }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['rilanci'] | Should -Be 1
        $s['rilancioDi'] | Should -Be 'd1'
        # al giro dopo la validazione e in corso: niente di nuovo, nessun secondo rilancio
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'inCorso'; BuildId = 78; UrlLog = 'https://log/78' }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-AdoRivalutazione -Times 1 -Exactly
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
    }

    It 'validazione scaduta in Ready to merge: lo smistatore rilancia le scadute e non completa la PR (D47)' {
        Mock Start-AdoRivalutazione { 2 }
        Mock Complete-AdoPr { }
        $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
        $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; prId = 9 } }
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'scaduta'; BuildId = 77; UrlLog = $null }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-AdoRivalutazione -Times 1 -Exactly -ParameterFilter { $Scadute -and $Ramo -eq 'feature/5-x' -and $Repo -eq 'Acme.AI' }
        Should -Invoke Complete-AdoPr -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag -contains 'on-hold' }
        [int](Get-StatoFinale $script:Dati)['5']['rilanci'] | Should -Be 0 -Because 'il limite dei rilanci di D38 vale per le rosse, non per le scadute'
    }

    It 'tolto l on-hold per un secondo rilancio chiesto, il conto dei rilanci riparte da zero' {
        Mock Start-AdoRivalutazione { 1 }
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; rossaGestita = 78; rilanci = 1; rilancioDi = 'd1'; inAttesaPer = 'limite'; ultimoRuolo = 'dev'
            ultimaSessione = @{ dev = @{ id = 'd2'; esito = 'rilancia'; fine = '2026-11-01T12:00:00Z'; motivo = 'rossa' } } } }
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'rossa'; BuildId = 78; UrlLog = 'https://log/78' }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-AdoRivalutazione -Times 1 -Exactly
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['rilanci'] | Should -Be 1
        $s['rilancioDi'] | Should -Be 'd2'
    }

    It 'se il log della build rossa non si legge dev parte lo stesso, con il link e il motivo' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'rossa'; BuildId = 77; UrlLog = 'https://log/77' }
        Mock Get-AdoErroriBuild { throw '401 Unauthorized' }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Allegato -like '*https://log/77*' -and $Allegato -like '*non*letto*401*' }
    }

    It 'al giro dopo, a sessione finita: registro, campi della card sommati e stato aggiornato' {
        $global:Mondo.Cards = @(New-FintaCard 5 'daChiarire' -Tokens 100 -Minuti 5)
        $global:Mondo.Storia['5'] = New-FintaStoria 'daChiarire'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso); ultimoRuolo = 'responsabile'; ultimoCommento = 0 } }
        $global:Mondo.Esiti['sid-1'] = New-FintoEsito $true 'domande'
        Invoke-Giro $script:Dati | Out-Null
        $righe = @(Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl'))
        $righe.Count | Should -Be 1
        $r = $righe[0] | ConvertFrom-Json
        $r.card | Should -Be 5
        $r.repo | Should -Be 'Acme.AI'
        $r.ruolo | Should -Be 'responsabile'
        $r.modello | Should -Be 'opus'
        $r.sforzo | Should -Be 'high'
        $r.sessione | Should -Be 'sid-1'
        $r.ripresa | Should -BeFalse
        $r.turni | Should -Be 4
        $r.esito | Should -Be 'domande'
        $r.tokenIn | Should -Be 10
        $r.tokenOut | Should -Be 200
        $r.cacheLetti | Should -Be 3000
        $r.cacheScritti | Should -Be 400
        $r.inizio | Should -Not -BeNullOrEmpty
        $r.fine | Should -Not -BeNullOrEmpty
        # 10 + 200 + 3000 + 400 = 3610 sommati ai 100 che la card aveva; 125000 ms = 2,08 minuti, per eccesso 3, piu i 5 di prima
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter {
            $Id -eq 5 -and $Campi['Custom.TotalTokens'] -eq 3710 -and $Campi['Custom.AgentMinutes'] -eq 8
        }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['sessione'] | Should -BeNullOrEmpty
        $s['ultimoRuolo'] | Should -Be 'responsabile'
        $s['ultimaSessione']['responsabile']['esito'] | Should -Be 'domande'
        $s['ultimaSessione']['responsabile']['fine'] | Should -Not -BeNullOrEmpty
        $s['ultimaSessione']['responsabile']['id'] | Should -Be 'sid-1'
    }

    It 'un reviewer bloccante non fa salire giriRevisione: sale quando dev parte con i rilievi' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'reviewer' 'sid-r'); ultimoRuolo = 'reviewer'; giriRevisione = 0; ramo = 'feature/5-x'; cartella = $script:CartellaOk } }
        $global:Mondo.Esiti['sid-r'] = New-FintoEsito $true 'bloccante'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Messaggio -match 'Motivo: rilievi' -and $Allegato -eq 'testo' }
        (Get-StatoFinale $script:Dati)['5']['giriRevisione'] | Should -Be 1
        # un reviewer che supera la revisione non lo fa salire
        $global:Mondo.Cards = @(New-FintaCard 6 'inRevisione')
        Set-StatoDiPartenza $script:Dati @{ '6' = @{ sessione = (New-SessioneInCorso 'reviewer' 'sid-s'); ultimoRuolo = 'reviewer'; giriRevisione = 0 } }
        $global:Mondo.Esiti['sid-s'] = New-FintoEsito $true 'superata'
        Invoke-Giro $script:Dati | Out-Null
        (Get-StatoFinale $script:Dati)['6']['giriRevisione'] | Should -Be 0
    }

    It 'giriRevisione 2 vuol dire due ritorni a dev: il secondo bloccante torna a dev, il terzo va in on-hold' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        # secondo bloccante: un ritorno e gia stato fatto
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'reviewer' 'sid-r'); ultimoRuolo = 'reviewer'; giriRevisione = 1; ramo = 'feature/5-x'; cartella = $script:CartellaOk } }
        $global:Mondo.Esiti['sid-r'] = New-FintoEsito $true 'bloccante'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Messaggio -match 'Motivo: rilievi' }
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
        (Get-StatoFinale $script:Dati)['5']['giriRevisione'] | Should -Be 2
        # terzo bloccante: i due ritorni sono finiti
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ passateFatte = @('troppi giri di revisione'); sessione = (New-SessioneInCorso 'reviewer' 'sid-r3'); ultimoRuolo = 'reviewer'; giriRevisione = 2; ramo = 'feature/5-x'; cartella = $script:CartellaOk } }
        $global:Mondo.Esiti['sid-r3'] = New-FintoEsito $true 'bloccante'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' }   # nessun dev in piu (il mentore del primo ritorno e un altro lancio)
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -Be 'limite'
    }
    It 'una sessione finita con permission_denials (Errore) mette la card in on-hold con il motivo' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive } }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true 'fatto' $true
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match '^\[smistatore\]' -and $Testo -match 'fallit' -and $Menziona -eq 'u-ric' }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['sessione'] | Should -BeNullOrEmpty
        $s['inAttesaPer'] | Should -Be 'sessione'
        $s['ultimaSessione']['dev']['esito'] | Should -BeNullOrEmpty
        # i consumi si registrano lo stesso
        @(Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl')).Count | Should -Be 1
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
    }

    It 'una sessione con comandi negati ma un esito valido prosegue, e un commento dice quali strumenti sono stati negati' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive } }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true 'fatto' $false -Negati @('PowerShell', 'PowerShell')
        Invoke-Giro $script:Dati | Out-Null
        # nessun on-hold per sessione fallita (il giro puo poi decidere altro sulla card, per altri motivi)
        Should -Invoke Add-AdoCommento -Times 0 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'sessione di dev e fallita' }
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'negat' -and $Testo -match '2 comandi' -and $Testo -match 'PowerShell' -and $Menziona -eq 'u-ric' }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['ultimaSessione']['dev']['esito'] | Should -Be 'fatto'
        $s['ultimaSessione']['dev']['errore'] | Should -BeFalse
    }

    It 'a fine sessione un commento dice ruolo ed esito, perche il commento dell agente non sempre lo scrive' {
        # card 23: il reviewer ha chiuso con superata ma il suo commento non lo diceva in chiaro
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive } }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true 'fatto'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match '^\[smistatore\] Sessione sid-d finita' -and $Testo -match 'dev' -and $Testo -match 'fatto' }
    }

    It 'una sessione silenziosa viene chiusa e, al secondo fermo, la card va in on-hold' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive; ripreseAutomatiche = 1 } }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-60))
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Stop-Sessione -Times 1 -Exactly -ParameterFilter { $ProcessoId -eq 4242 -and (ConvertTo-DataUtc $Avvio) -eq (ConvertTo-DataUtc '2026-11-16T08:00:00.0000000Z') }
        Should -Invoke Set-AdoCard -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'silenzio' }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['sessione'] | Should -BeNullOrEmpty
        $s['inAttesaPer'] | Should -Be 'sessione'
        $s['ultimaSessione']['dev']['id'] | Should -Be 'sid-d'
        $s['ultimaSessione']['dev']['fine'] | Should -BeNullOrEmpty
    }

    It 'il silenzio tollerato basta per un test lungo: 30 minuti senza scrivere non chiudono la sessione' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive } }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-30))
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Stop-Sessione -Times 0 -Exactly
        (Get-StatoFinale $script:Dati)['5']['sessione']['id'] | Should -Be 'sid-d'
    }

    It 'un result senza ESITO con il processo vivo e una pausa (dev aspetta un comando in background): la sessione resta aperta' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive } }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true $null $false ((Get-Date).ToUniversalTime().AddMinutes(-5)) 'Aspetto la fine della misura in background.'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Stop-Sessione -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 0 -Exactly
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        Test-Path (Join-Path $script:Dati 'registro-sessioni.jsonl') | Should -BeFalse
        (Get-StatoFinale $script:Dati)['5']['sessione']['id'] | Should -Be 'sid-d'
    }

    It 'una pausa oltre il silenzio tollerato si chiude per silenzio' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive } }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true $null $false ((Get-Date).ToUniversalTime().AddMinutes(-60)) 'Aspetto.'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Stop-Sessione -Times 1 -Exactly
        Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'silenzio' }
    }

    It 'un result senza ESITO con il processo morto e una sessione finita: si registra e la card va in on-hold come oggi' {
        Mock Test-SessioneViva { $false }
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive } }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true $null $false ((Get-Date).ToUniversalTime().AddMinutes(-5)) 'Fine senza riga.'
        Invoke-Giro $script:Dati | Out-Null
        @(Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl')).Count | Should -Be 1
        # D42: prima dell'on-hold passa il responsabile, con il motivo e l'ultimo testo di dev
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'responsabile' -and $Allegato -match 'senza riga ESITO' }
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag -contains 'on-hold' }
    }

    It 'una sessione che ha scritto da poco non si tocca' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive } }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-2))
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Stop-Sessione -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 0 -Exactly
        (Get-StatoFinale $script:Dati)['5']['sessione']['id'] | Should -Be 'sid-d'
    }

    It '-WhatIf stampa le azioni e non scrive da nessuna parte' {
        $global:Mondo.Cards = @((New-FintaCard 5 'nuova'), (New-FintaCard 6 'daChiarire'))
        $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
        $global:Mondo.Storia['6'] = New-FintaStoria 'daChiarire'
        $global:Mondo.Commenti['6'] = @([pscustomobject]@{ Id = 3; Autore = 'Mario'; Testo = 'una risposta'; Quando = '2026-11-01T10:00:00Z' })
        # una sessione finita da registrare e una silenziosa da chiudere, anch'esse da non toccare
        Set-StatoDiPartenza $script:Dati @{ '7' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive } }
        $global:Mondo.Cards += New-FintaCard 7 'inSviluppo'
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $true 'fatto'
        $statoPrima = Get-Content (Join-Path $script:Dati 'stato.json') -Raw
        $filePrima = @(Get-ChildItem $script:Dati -Recurse | ForEach-Object FullName)
        # tutte le funzioni che scrivono, oltre a quelle gia sostituite nel BeforeEach
        Mock Save-Stato { }; Mock Add-RevNostra { }; Mock Write-RegistroSessione { }; Mock Enter-Giro { $true }; Mock Exit-Giro { }
        # una radice con piu sessioni consentite: la sessione "finita" di card 7 non libera il posto finche non e registrata
        $radice = New-RadiceDiProva -Cartella $TestDrive -Limiti @{ sessioniAttive = 3 }
        $out = Invoke-Giro $script:Dati @{ WhatIf = $true; Radice = $radice }
        $out | Should -Match 'LanciaSessione'
        $out | Should -Match 'responsabile'
        foreach ($f in 'Set-AdoCard', 'Add-AdoCommento', 'New-AdoPr', 'Start-SessioneRuolo', 'Stop-Sessione', 'Send-TelegramAvviso',
            'Save-Stato', 'Add-RevNostra', 'Write-RegistroSessione', 'Enter-Giro', 'Exit-Giro') {
            Should -Invoke $f -Times 0 -Exactly
        }
        @(Get-ChildItem $script:Dati -Recurse | ForEach-Object FullName) | Should -Be $filePrima   # nessun file nuovo: ne log, ne registro
        (Get-Content (Join-Path $script:Dati 'stato.json') -Raw) | Should -Be $statoPrima
    }

    It '-Card tocca solo quella card' {
        $global:Mondo.Cards = @((New-FintaCard 5 'nuova'), (New-FintaCard 6 'nuova'))
        $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'; $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
        Invoke-Giro $script:Dati @{ Card = 6 } | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Card -eq 6 }
        $s = Get-StatoFinale $script:Dati
        $s.ContainsKey('5') | Should -BeFalse
        Should -Invoke Add-AdoCommento -Times 0 -ParameterFilter { $Id -eq 5 }
    }

    It '-Card su una card in Draft (fuori dalle attive) non interrompe il giro' {
        $global:Mondo.Cards = @(New-FintaCard 2 'bozza')
        $global:Mondo.Storia['2'] = New-FintaStoria 'bozza'
        Mock Get-AdoCardAttive { @() }; Mock Get-AdoFeatureAperte { @() }
        $out = Invoke-Giro $script:Dati @{ Card = 2; WhatIf = $true }
        $out | Should -Not -Match 'giro interrotto'
        Should -Invoke Get-AdoCard -ParameterFilter { $Id -eq 2 }
    }

    It 'PAT che scade entro 7 giorni: una riga di log con la data e il comando, una volta sola per quella scadenza, e niente Telegram (lo manda il supervisore)' {
        $info = Join-Path $script:Dati 'pat-info.json'
        $scade = [datetime]::UtcNow.AddDays(3).ToString('o')
        @{ smistatore = @{ authorizationId = 'a1'; validTo = $scade } } | ConvertTo-Json | Set-Content $info
        $out = Invoke-Giro $script:Dati @{ PercorsoPatInfo = $info }
        $out | Should -Match 'AVVISO il PAT scade il \d\d/\d\d/\d{4}.*Install-Attrezzi\.ps1 -Pat'
        $out = Invoke-Giro $script:Dati @{ PercorsoPatInfo = $info }
        $out | Should -Not -Match 'il PAT scade il'
        # dopo il rinnovo la scadenza e un'altra: se anche questa e vicina, la riga riparte
        @{ smistatore = @{ authorizationId = 'a2'; validTo = [datetime]::UtcNow.AddDays(2).ToString('o') } } | ConvertTo-Json | Set-Content $info
        $out = Invoke-Giro $script:Dati @{ PercorsoPatInfo = $info }
        $out | Should -Match 'il PAT scade il'
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
    }

    It 'PAT che scade fra piu di 7 giorni, o senza pat-info.json: nessun avviso' {
        $info = Join-Path $script:Dati 'pat-info.json'
        @{ smistatore = @{ authorizationId = 'a1'; validTo = [datetime]::UtcNow.AddDays(30).ToString('o') } } | ConvertTo-Json | Set-Content $info
        Invoke-Giro $script:Dati @{ PercorsoPatInfo = $info } | Out-Null
        Invoke-Giro $script:Dati @{ PercorsoPatInfo = (Join-Path $script:Dati 'non-c-e.json') } | Out-Null
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
    }

    It 'PAT in scadenza con -WhatIf: niente Telegram e niente file' {
        $info = Join-Path $script:Dati 'pat-info.json'
        @{ smistatore = @{ authorizationId = 'a1'; validTo = [datetime]::UtcNow.AddDays(1).ToString('o') } } | ConvertTo-Json | Set-Content $info
        Invoke-Giro $script:Dati @{ PercorsoPatInfo = $info; WhatIf = $true } | Out-Null
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
        Test-Path (Join-Path $script:Dati 'pat-scadenza-avvisata') | Should -BeFalse
    }

    It 'un pat-info.json illeggibile non ferma il giro' {
        $info = Join-Path $script:Dati 'pat-info.json'
        Set-Content $info '{ non json'
        $out = Invoke-Giro $script:Dati @{ PercorsoPatInfo = $info }
        $out | Should -Match 'controllo della scadenza del PAT'
        Should -Invoke Get-AdoCardAttive -Times 1
    }

    It 'un 401 da ADO ferma il giro con una riga chiara: PAT scaduto o revocato, rilancia -Pat' {
        Mock Get-AdoUtenteCorrente { throw 'Chiamata ad Azure DevOps fallita (GET x): 401 - PAT scaduto o revocato: rilancia setup/Install-Attrezzi.ps1 -Pat' }
        $out = Invoke-Giro $script:Dati
        $out | Should -Match 'giro fermato: .*PAT scaduto o revocato.*-Pat'
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
    }

    It 'un 401 lascia nel log la riga che il supervisore riconosce, senza Telegram e senza segni su disco' {
        Mock Get-AdoUtenteCorrente { throw 'Chiamata ad Azure DevOps fallita (GET x): 401 - PAT scaduto o revocato: rilancia setup/Install-Attrezzi.ps1 -Pat' }
        $out = Invoke-Giro $script:Dati
        $out | Should -Match 'ERRORE giro fermato: .*PAT scaduto o revocato'
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
        Test-Path (Join-Path $script:Dati 'pat-401-avvisato') | Should -BeFalse
    }

    It 'un 401 con -WhatIf non manda Telegram e non scrive il segno' {
        Mock Get-AdoUtenteCorrente { throw 'Chiamata ad Azure DevOps fallita (GET x): 401 - PAT scaduto o revocato: rilancia setup/Install-Attrezzi.ps1 -Pat' }
        Invoke-Giro $script:Dati @{ WhatIf = $true } | Out-Null
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
        Test-Path (Join-Path $script:Dati 'pat-401-avvisato') | Should -BeFalse
    }

    It 'un altro errore del giro e un giro interrotto, senza avvisi Telegram' {
        Mock Get-AdoUtenteCorrente { throw 'rete assente' }
        $out = Invoke-Giro $script:Dati
        $out | Should -Match 'giro interrotto'
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
    }

    It 'un errore in un azione mette quella card in on-hold con il motivo e il giro continua con le altre' {
        # Ready to develop: la prima azione e CreaWorktree, che qui fallisce
        Mock New-WorktreeCard { throw 'git fetch rifiutato' }
        $global:Mondo.Cards = @((New-FintaCard 5 'pronto'), (New-FintaCard 6 'nuova'))
        $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'; $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $Stato }
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'git fetch rifiutato' -and $Testo -match 'CreaWorktree' }
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly -ParameterFilter { $Card -eq 5 }
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Card -eq 6 }
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
        (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'card 5: on-hold: .*git fetch rifiutato'
    }

    It 'due giri sovrapposti sulla stessa cartella dati: il secondo esce subito' {
        $global:Mondo.Cards = @(New-FintaCard 5 'nuova')
        $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
        $nome = Get-NomeGiro -CartellaDati $script:Dati
        $preso = Enter-Giro -Nome $nome
        try {
            $out = Invoke-Giro $script:Dati
        }
        finally { if ($preso) { Exit-Giro -Nome $nome } }
        $preso | Should -BeTrue
        Should -Invoke Get-AdoCardAttive -Times 0 -Exactly
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        $out | Should -Match 'gia in corso|già in corso'
        # e un giro dopo che l'altro ha finito riparte
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly
    }

    It 'una card la cui area non sta nella mappa non si tocca: una riga nel log e nessuna scrittura' {
        $global:Mondo.Cards = @(New-FintaCard 8 'nuova' -Area $script:AreaIgnota)
        $global:Mondo.Storia['8'] = New-FintaStoria 'nuova'
        $out = Invoke-Giro $script:Dati
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 0 -Exactly
        Should -Invoke Add-AdoCommento -Times 0 -Exactly
        $out | Should -Match 'card 8'
        $out | Should -Match 'mappa'
        (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'card 8'
        $s = Get-StatoFinale $script:Dati
        $s.ContainsKey('8') | Should -BeFalse
    }

    It 'il giro esce senza errore anche se Azure DevOps non risponde' {
        Mock Get-AdoCardAttive { throw 'ADO giu' }
        { Invoke-Giro $script:Dati | Out-Null } | Should -Not -Throw
        (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'ADO giu'
    }

    It 'una validazione in corso da troppo dopo la fine di dev da un avviso sulla card, una volta sola, senza Telegram' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        $fine = (Get-Date).ToUniversalTime().AddMinutes(-90).ToString('o')
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = $fine } } } }
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'inCorso'; BuildId = 78; UrlLog = 'https://log/78' }
        Invoke-Giro $script:Dati | Out-Null
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'validazione' -and $Testo -match 'https://log/78' }
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
    }

    It 'SpostaCard scrive la revisione tra quelle nostre e azzera le rosse di fila' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; rosseDiFila = 2; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 78; UrlLog = 'https://log/78' }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq 'In review' }
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'reviewer' }
        @(Get-RevNostre -Id 5 -Percorso (Join-Path $script:Dati 'stato.json')) | Should -Contain 55
        (Get-StatoFinale $script:Dati)['5']['rosseDiFila'] | Should -Be 0
    }

    It 'Ready to develop con task: dev parte sul primo task aperto, con l id nel messaggio e nello stato' {
        $global:CartellaWt = Join-Path $TestDrive 'wt-card-5'
        New-Item -ItemType Directory $global:CartellaWt -Force | Out-Null
        $global:Mondo.Cards = @(New-FintaCard 5 'pronto')
        $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'
        $global:Mondo.Task['5'] = @(
            [pscustomobject]@{ Id = 61; Titolo = 'Primo passo'; Descrizione = 'd'; Stato = 'New' }
            [pscustomobject]@{ Id = 62; Titolo = 'Secondo passo'; Descrizione = 'd'; Stato = 'New' })
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter {
            $Ruolo -eq 'dev' -and $Task -eq 61 -and $Messaggio -match 'Task 61: Primo passo' -and $Messaggio -match 'Motivo: pronto\.' }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['sessione']['task'] | Should -Be 61
        $s['ultimaSessione']['dev']['task'] | Should -Be 61
        # il task su cui parte dev va in Active, gli altri restano come sono
        Should -Invoke Set-AdoTaskStato -Times 1 -Exactly
        Should -Invoke Set-AdoTaskStato -Times 1 -Exactly -ParameterFilter { $Id -eq 61 -and $Stato -eq 'Active' }
    }

    It 'il task e gia in Active (sessione ripresa o rilanciata): non si riscrive' {
        $global:CartellaWt = Join-Path $TestDrive 'wt-card-5'
        New-Item -ItemType Directory $global:CartellaWt -Force | Out-Null
        $global:Mondo.Cards = @(New-FintaCard 5 'pronto')
        $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'
        $global:Mondo.Task['5'] = @([pscustomobject]@{ Id = 61; Titolo = 'Primo passo'; Descrizione = 'd'; Stato = 'Active' })
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Task -eq 61 }
        Should -Invoke Set-AdoTaskStato -Times 0 -Exactly
    }

    It 'se il task non va in Active la sessione resta partita: niente on-hold, solo il log' {
        $global:CartellaWt = Join-Path $TestDrive 'wt-card-5'
        New-Item -ItemType Directory $global:CartellaWt -Force | Out-Null
        $global:Mondo.Cards = @(New-FintaCard 5 'pronto')
        $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'
        $global:Mondo.Task['5'] = @([pscustomobject]@{ Id = 61; Titolo = 'Primo passo'; Descrizione = 'd'; Stato = 'New' })
        Mock Set-AdoTaskStato { throw 'transizione non permessa' }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Task -eq 61 }
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
        (Get-StatoFinale $script:Dati)['5']['sessione']['task'] | Should -Be 61
    }

    It 'una sessione di una card senza task non porta nessun task: ne nel lancio, ne nel messaggio, ne nel registro' {
        $global:Mondo.Cards = @(New-FintaCard 5 'nuova')
        $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { -not $Task -and $Messaggio -notmatch 'Task' }
        Should -Invoke Set-AdoTaskStato -Times 0 -Exactly
        (Get-StatoFinale $script:Dati)['5']['sessione']['task'] | Should -BeNullOrEmpty
        # finita: la riga del registro ha il campo, nullo
        $global:Mondo.Esiti['sid-nuova'] = New-FintoEsito $true 'domande'
        Invoke-Giro $script:Dati | Out-Null
        $r = Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl') | ConvertFrom-Json
        $r.PSObject.Properties.Name | Should -Contain 'task'
        $r.task | Should -BeNullOrEmpty
    }

    It 'dev finisce il task e questo e chiuso: il registro porta il task e nello stesso giro parte dev sul successivo, senza PR' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        $global:Mondo.Task['5'] = @(
            [pscustomobject]@{ Id = 61; Titolo = 'Primo passo'; Descrizione = 'd'; Stato = (St 'taskChiuso') }
            [pscustomobject]@{ Id = 62; Titolo = 'Secondo passo'; Descrizione = 'd'; Stato = 'New' })
        $sess = New-SessioneInCorso 'dev' 'sid-t1'; $sess['task'] = 61
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = $sess; ultimoRuolo = 'dev'; ramo = 'feature/5-x'; cartella = $script:CartellaOk
            ultimaSessione = @{ dev = @{ id = 'sid-t1'; task = 61 } } } }
        $global:Mondo.Esiti['sid-t1'] = New-FintoEsito $true 'fatto'
        Invoke-Giro $script:Dati | Out-Null
        $r = Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl') | ConvertFrom-Json
        $r.task | Should -Be 61
        Should -Invoke New-AdoPr -Times 0 -Exactly
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Task -eq 62 -and $Messaggio -match 'Task 62: Secondo passo' }
        (Get-StatoFinale $script:Dati)['5']['sessione']['task'] | Should -Be 62
    }

    It 'dev finisce con fatto ma il suo task e ancora aperto: on-hold una volta sola, nessuna sessione, nessuna PR, e al giro dopo niente' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        $global:Mondo.Task['5'] = @(
            [pscustomobject]@{ Id = 61; Titolo = 'Primo passo'; Descrizione = 'd'; Stato = 'New' }
            [pscustomobject]@{ Id = 62; Titolo = 'Secondo passo'; Descrizione = 'd'; Stato = 'New' })
        $sess = New-SessioneInCorso 'dev' 'sid-t1'; $sess['task'] = 61
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ passateFatte = @('taskNonChiuso'); sessione = $sess; ultimoRuolo = 'dev'; ramo = 'feature/5-x'; cartella = $script:CartellaOk
            ultimaSessione = @{ dev = @{ id = 'sid-t1'; task = 61 } } } }
        $global:Mondo.Esiti['sid-t1'] = New-FintoEsito $true 'fatto'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        Should -Invoke New-AdoPr -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Testo -match '^\[smistatore\]' -and $Testo -match 'task 61' }
        (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -Be 'sessione'
        # al giro dopo la card ha il tag on-hold: non gira a vuoto
        $global:Mondo.Cards[0].Tag = @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagAttesa)
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Testo -match 'task 61' }
    }

    It 'il dev di un altro task parte con contesto pulito anche se la cache e calda: mai --resume della sessione del task precedente' {
        $radice = New-RadiceDiProva -Cartella $TestDrive -Limiti @{ sogliaResumeMinuti = 60 }
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        $global:Mondo.Task['5'] = @(
            [pscustomobject]@{ Id = 61; Titolo = 'Primo passo'; Descrizione = 'd'; Stato = (St 'taskChiuso') }
            [pscustomobject]@{ Id = 62; Titolo = 'Secondo passo'; Descrizione = 'd'; Stato = 'New' })
        $fine = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; ultimoRuolo = 'dev'; cartella = $script:CartellaOk
            ultimaSessione = @{ dev = @{ id = 'sid-t1'; esito = 'fatto'; fine = $fine; task = 61 } } } }
        Invoke-Giro $script:Dati @{ Radice = $radice } | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Task -eq 62 -and -not $Riprendi }
    }

    It 'un task rimosso non conta come aperto: chiuso l ultimo, parte il percorso di oggi (PR)' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        $global:Mondo.Task['5'] = @(
            [pscustomobject]@{ Id = 61; Titolo = 'Primo passo'; Descrizione = 'd'; Stato = (St 'taskChiuso') }
            [pscustomobject]@{ Id = 62; Titolo = 'Secondo passo'; Descrizione = 'd'; Stato = (St 'taskRimosso') })
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; ultimoRuolo = 'dev'; cartella = $script:CartellaOk
            ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z'; task = 61 } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke New-AdoPr -Times 1 -Exactly
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
    }

    It 'ApriPr apre la PR con il titolo della card e il prefisso del ramo e salva prId' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter {
            $Progetto -eq 'Acme.AI' -and $Repo -eq 'Acme.AI' -and $Ramo -eq 'feature/5-x' -and $Titolo -eq 'feat: Titolo della card 5' -and $CardId -eq 5 -and
            $Descrizione -eq "[Card 5]($(Get-AdoUrlCard -Id 5)): Titolo della card 5"
        }
        (Get-StatoFinale $script:Dati)['5']['prId'] | Should -Be 77
    }

    It 'ApriPr mette sotto il link la descrizione salvata sulla card con descrizione-pr' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        $global:Mondo.Commenti['5'] = @([pscustomobject]@{ Id = 9; Autore = 'x'; Quando = 'd'
            Testo = "[dev] Descrizione della PR:`n`n## Misure`nprima 10 minuti`n`n$([char]0x2014) scritto da Claude (dev)" })
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter {
            $Descrizione -eq "[Card 5]($(Get-AdoUrlCard -Id 5)): Titolo della card 5`n`n## Misure`nprima 10 minuti" }
    }

    It 'ApriPr con una descrizione salvata troppo lunga apre la PR col solo link' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        $global:Mondo.Commenti['5'] = @([pscustomobject]@{ Id = 9; Autore = 'x'; Quando = 'd'; Testo = "[dev] Descrizione della PR:`n`n$('a' * 4000)" })
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Descrizione -eq "[Card 5]($(Get-AdoUrlCard -Id 5)): Titolo della card 5" }
    }

    It 'una card in Ready to develop: crea il worktree, salva ramo e cartella, la sposta e lancia dev nel worktree' {
        $global:CartellaWt = Join-Path $TestDrive 'wt-card-5-task'
        New-Item -ItemType Directory $global:CartellaWt | Out-Null
        $global:Mondo.Cards = @(New-FintaCard 5 'pronto')
        $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke New-WorktreeCard -Times 1 -Exactly -ParameterFilter {
            $Voce.repo -eq 'Acme.AI' -and $Voce.cartella -eq 'C:/develop/GIT/Acme.AI' -and $Card.Id -eq 5 -and $Card.Titolo -eq 'Titolo della card 5'
        }
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq (St 'inSviluppo') }
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Cartella -eq $global:CartellaWt }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['ramo'] | Should -Be 'feature/5-titolo-della-card'
        $s['cartella'] | Should -Be $global:CartellaWt
    }

    It 'dev il cui worktree manca non parte nella copia principale: la card va in on-hold con il motivo' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = (Join-Path $TestDrive 'non-esiste'); ultimoRuolo = 'responsabile'
                ultimaSessione = @{ responsabile = @{ id = 'r1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'worktree' }
    }

    It 'dev senza nessuna cartella salvata (rimossa dopo la PR) non parte nella copia principale' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = $null; cartella = $null; prId = 9; ultimoRuolo = 'responsabile'
                ultimaSessione = @{ responsabile = @{ id = 'r1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
    }

    It 'reviewer rivede il ramo nel worktree della card' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 78; UrlLog = 'https://log/78' }
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'reviewer' -and $Cartella -eq $script:CartellaOk }
    }

    It 'reviewer il cui worktree manca non parte nella copia principale: la card va in on-hold' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 78; UrlLog = 'https://log/78' }
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = (Join-Path $TestDrive 'non-esiste'); ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
    }

    It 'in In development la PR si legge senza le completate (-AncheCompletate solo in Ready to merge e Ready to release)' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Get-AdoPr -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/5-x' -and -not $AncheCompletate }
        Should -Invoke Get-AdoPr -Times 0 -Exactly -ParameterFilter { $AncheCompletate }
    }

    It 'con -WhatIf il worktree non si crea' {
        $global:Mondo.Cards = @(New-FintaCard 5 'pronto')
        $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'
        $out = Invoke-Giro $script:Dati @{ WhatIf = $true }
        $out | Should -Match 'CreaWorktree'
        Should -Invoke New-WorktreeCard -Times 0 -Exactly
    }

    It 'una card in Ready to develop con un predecessore non unito non parte: il log dice quale aspetta' {
        $global:Mondo.Cards = @((New-FintaCard 5 'inRevisione'), (New-FintaCard 6 'pronto'))
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'; $global:Mondo.Storia['6'] = New-FintaStoria 'pronto'
        $global:Mondo.Predecessori = @{ '6' = @([pscustomobject]@{ Id = 5; Stato = (St 'inRevisione') }) }
        $out = Invoke-Giro $script:Dati @{ Card = 6 }
        Should -Invoke New-WorktreeCard -Times 0 -Exactly
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        Should -Invoke Add-AdoCommento -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 0 -Exactly
        $out | Should -Match 'card 6: aspetta le card precedenti non ancora unite: #5 \(In review\)'
    }

    It 'una card con azioni ferma dal limite di sessioni lascia traccia nel log: quale card tiene il posto' {
        Set-StatoDiPartenza $script:Dati @{ '9' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-altra'); ultimoRuolo = 'dev' } }
        $global:Mondo.Cards = @((New-FintaCard 9 'inSviluppo'), (New-FintaCard 5 'nuova'))
        $global:Mondo.Storia['9'] = New-FintaStoria 'inSviluppo'; $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
        $global:Mondo.Esiti['sid-altra'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-1))
        $radice = New-RadiceDiProva -Cartella $TestDrive -Limiti @{ sessioniAttive = 1 }
        $out = Invoke-Giro $script:Dati @{ Radice = $radice }
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        $out | Should -Match 'card 5: in coda, posto occupato \(sessioni attive 1/1: card 9\)'
        (Get-Content (Join-Path $script:Dati 'log/*.log') -Raw) | Should -Match 'card 5: in coda, posto occupato \(sessioni attive 1/1: card 9\)'
    }

    It 'una card senza azioni e senza blocchi non scrive la riga di coda' {
        $global:Mondo.Cards = @(New-FintaCard 5 'bozza')
        $global:Mondo.Storia['5'] = New-FintaStoria 'bozza'
        (Invoke-Giro $script:Dati) | Should -Not -Match 'in coda'
    }

    It 'con -WhatIf la card che aspetta e riconoscibile e non risulta nessuna azione' {
        $global:Mondo.Cards = @(New-FintaCard 6 'nuova')
        $global:Mondo.Storia['6'] = New-FintaStoria 'nuova'
        $global:Mondo.Predecessori = @{ '6' = @([pscustomobject]@{ Id = 4; Stato = (St 'chiusa') }, [pscustomobject]@{ Id = 5; Stato = (St 'rimossa') }) }
        $out = Invoke-Giro $script:Dati @{ WhatIf = $true }
        $out | Should -Match 'card 6: aspetta le card precedenti non ancora unite: #5 \(Removed\)'
        $out | Should -Not -Match '#4'
        $out | Should -Not -Match 'LanciaSessione'
    }

    It 'quando il predecessore e unito la card parte, e lo stato locale dei predecessori non si tocca' {
        $global:Mondo.Cards = @(New-FintaCard 6 'pronto')
        $global:Mondo.Storia['6'] = New-FintaStoria 'pronto'
        # card 5 e in Ready to release con la PR completata e il worktree gia tolto: lo dice lo stato locale
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ prId = 9; cartella = $null } }
        $global:Mondo.Predecessori = @{ '6' = @([pscustomobject]@{ Id = 5; Stato = (St 'daRilasciare') }) }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke New-WorktreeCard -Times 1 -Exactly
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Card -eq 6 -and $Ruolo -eq 'dev' }
    }

    It 'un predecessore Ready to release con il worktree ancora presente blocca, e il giro non crea voci per lui nello stato' {
        $global:Mondo.Cards = @(New-FintaCard 6 'pronto')
        $global:Mondo.Storia['6'] = New-FintaStoria 'pronto'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ prId = 9; cartella = $script:CartellaOk } }
        $global:Mondo.Predecessori = @{ '6' = @([pscustomobject]@{ Id = 5; Stato = (St 'daRilasciare') }, [pscustomobject]@{ Id = 8; Stato = (St 'chiusa') }) }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        (Get-StatoFinale $script:Dati).ContainsKey('8') | Should -BeFalse
    }

    It 'PR completata in Ready to release: rimuove il worktree e azzera ramo e cartella' {
        # il giro deve poter leggere la PR gia completata: Get-AdoPr si chiede anche le completate
        $global:Mondo.Cards = @(New-FintaCard 5 'daRilasciare')
        $global:Mondo.Storia['5'] = New-FintaStoria 'daRilasciare'
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null }
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; prId = 9 } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Get-AdoPr -ParameterFilter { $Ramo -eq 'feature/5-x' -and $AncheCompletate }
        Should -Invoke Remove-WorktreeCard -Times 1 -Exactly -ParameterFilter {
            $Voce.cartella -eq 'C:/develop/GIT/Acme.AI' -and $Ramo -eq 'feature/5-x' -and $Cartella -eq 'C:/wt/card-5'
        }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['cartella'] | Should -BeNullOrEmpty
        $s['ramo'] | Should -BeNullOrEmpty
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
    }

    It 'a worktree gia rimosso la card resta in Ready to release in silenzio: niente on-hold, commenti o avvisi' {
        # e lo stato che lascia RimuoviWorktree: ramo e cartella nulli, prId della PR completata
        $global:Mondo.Cards = @(New-FintaCard 5 'daRilasciare')
        $global:Mondo.Storia['5'] = New-FintaStoria 'daRilasciare'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = $null; cartella = $null; prId = 9; ultimoRuolo = 'reviewer' } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -Times 0 -Exactly
        Should -Invoke Add-AdoCommento -Times 0 -Exactly
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
        (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -BeNullOrEmpty
    }

    It 'In review con la revisione superata e un task aggiunto: il giro legge i task, riporta la card In development e lancia dev sul task' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        $global:Mondo.Task['5'] = @([pscustomobject]@{ Id = 63; Titolo = 'Passo aggiunto'; Descrizione = 'd'; Stato = 'New' })
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null }
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; prId = 9; ultimoRuolo = 'reviewer'
            ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq 'In development' }
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Task -eq 63 -and $Messaggio -match 'Motivo: taskAggiunto' }
    }

    It 'se Remove-WorktreeCard si rifiuta la card va in on-hold e cartella e ramo restano nello stato' {
        Mock Remove-WorktreeCard { throw 'Il worktree ha lavoro non salvato' }
        $global:Mondo.Cards = @(New-FintaCard 5 'daRilasciare')
        $global:Mondo.Storia['5'] = New-FintaStoria 'daRilasciare'
        $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null }
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; prId = 9 } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'lavoro non salvato' }
        (Get-StatoFinale $script:Dati)['5']['cartella'] | Should -Be 'C:/wt/card-5'
    }

    Context 'deploy in Test e merge' {
        BeforeEach {
            # Deploying to test per gesto di Titolare (u-ric, rev 20), revisione superata, nessun run
            $global:Mondo.Cards = @(New-FintaCard 5 'inDeployTest')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inDeployTest'
            $script:StatoInTest = @{ ramo = 'feature/5-x'; ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } }
            # la scelta del deploy del responsabile (D43)
            $global:Mondo.Commenti['5'] = @(New-CommentoDeploy 40 @('deployStime'))
        }

        It 'AccodaDeployTest passa pipeline, ramo e i parametri scelti dal responsabile, e salva runId e runDopoRev' {
            $global:Mondo.Commenti['5'] = @((New-CommentoDeploy 30 @('deployStime')), (New-CommentoDeploy 40 @('deployDatabases', 'deployStime')))
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            Invoke-Giro $script:Dati | Out-Null
            # vale l'ultimo commento di deploy, verificato sui parametri dello YAML del ramo della card
            Should -Invoke Get-AdoParametriDeploy -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'Acme.AI' -and $PipelineId -eq 115 -and $Ramo -eq 'feature/5-x' }
            Should -Invoke Start-AdoDeployTest -Times 1 -Exactly -ParameterFilter {
                $Progetto -eq 'Acme.AI' -and $PipelineId -eq 115 -and (@($Parametri) -join ',') -eq 'deployDatabases,deployStime' -and $Ramo -eq 'feature/5-x'
            }
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['runId'] | Should -Be 555
            $s['runDopoRev'] | Should -Be 20   # la revisione con cui la card e entrata in Deploying to test
            # chi guarda la card trova il run da seguire e con quali parametri e partito
            Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter {
                $Id -eq 5 -and $Testo -match 'Deploy in Test accodato con deployDatabases, deployStime' -and $Testo -match ([regex]::Escape('Acme.AI/_build/results?buildId=555')) }
        }

        It 'i deploy* dello YAML non scelti partono spenti' {
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-AdoDeployTest -Times 1 -Exactly -ParameterFilter { (@($Parametri) -join ',') -eq 'deployStime' -and (@($Spenti) -join ',') -eq 'deployDatabases' }
        }

        It 'con la run in corso i commenti si leggono una volta sola e lo YAML non si legge' {
            $global:Mondo.Run['300'] = [pscustomobject]@{ Stato = 'inProgress'; Esito = $null }
            $st = [hashtable]::new($script:StatoInTest); $st['runId'] = 300; $st['runDopoRev'] = 20
            Set-StatoDiPartenza $script:Dati @{ '5' = $st }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Get-AdoParametriDeploy -Times 0 -Exactly
            Should -Invoke Get-AdoCommenti -Times 1 -Exactly -ParameterFilter { $Id -eq 5 }
            Should -Invoke Start-AdoDeployTest -Times 0 -Exactly
        }

        It 'prima del deploy commenti e YAML si leggono una volta per giro' {
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Get-AdoCommenti -Times 1 -Exactly -ParameterFilter { $Id -eq 5 }
            Should -Invoke Get-AdoParametriDeploy -Times 1 -Exactly
        }

        It 'se lo YAML non si legge la card non salta il giro: niente deploy, passata del responsabile con l errore' {
            Mock Get-AdoParametriDeploy { throw 'pipeline 115 non trovata' }
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            $out = Invoke-Giro $script:Dati
            $out | Should -Not -Match 'lettura non riuscita'
            Should -Invoke Start-AdoDeployTest -Times 0 -Exactly
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'responsabile' }
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['attesaInEsame']['motivo'] | Should -Match '^non riesco a leggere i parametri del deploy in Test: .*pipeline 115 non trovata'
        }

        It 'senza la scelta del deploy del responsabile niente deploy: parte il responsabile per la passata, con il motivo' {
            $global:Mondo.Commenti['5'] = @()
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-AdoDeployTest -Times 0 -Exactly
            Should -Invoke Get-AdoParametriDeploy -Times 0 -Exactly
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'responsabile' }
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['attesaInEsame']['motivo'] | Should -Be 'manca la scelta del deploy in Test del responsabile'
            $s['attesaInEsame']['per'] | Should -Be 'deploy'
        }

        It 'un parametro che lo YAML del ramo non ha: niente deploy, e dopo la passata on-hold con il nome' {
            $global:Mondo.Commenti['5'] = @(New-CommentoDeploy 40 @('deployStime', 'deployVecchio'))
            $st = [hashtable]::new($script:StatoInTest); $st['passateFatte'] = @('parametroDeploySconosciuto')
            Set-StatoDiPartenza $script:Dati @{ '5' = $st }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-AdoDeployTest -Times 0 -Exactly
            Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'parametro di deploy sconosciuto: deployVecchio' }
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
            (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -Be 'deploy'
        }

        It 'tolto l on-hold dopo un deploy fallito, dimentica il run fallito e riaccoda il deploy' {
            $global:Mondo.Run['300'] = [pscustomobject]@{ Stato = 'completed'; Esito = 'failed' }
            $st = [hashtable]::new($script:StatoInTest); $st['runId'] = 300; $st['runDopoRev'] = 20; $st['inAttesaPer'] = 'limite'
            Set-StatoDiPartenza $script:Dati @{ '5' = $st }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-AdoDeployTest -Times 1 -Exactly
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['runId'] | Should -Be 555
            $s['inAttesaPer'] | Should -BeNullOrEmpty
        }

        It 'una voce della mappa senza pipelineDeploy: niente da provare in Test, la card passa in Ready to merge senza deploy' {
            $voce = [pscustomobject]@{ area = $script:Area; repo = 'Acme.AI'; cartella = 'C:/develop/GIT/Acme.AI'; progettoAdo = 'Acme.AI'
                componente = 'stime' }
            $global:VoceSenzaCampo = $voce
            Mock Find-VoceMappa { $global:VoceSenzaCampo }
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-AdoDeployTest -Times 0 -Exactly
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq 'Ready to merge' }
            Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
        }

        It 'AccodaDeployTest senza ramo salvato mette la card in on-hold' {
            $script:StatoInTest['ramo'] = $null; $script:StatoInTest['prId'] = 9
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-AdoDeployTest -Times 0 -Exactly
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        }

        It 'se Azure DevOps rifiuta il deploy la card va in on-hold e il run non si salva' {
            Mock Start-AdoDeployTest { throw 'pipeline non trovata' }
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'AccodaDeployTest' -and $Testo -match 'pipeline non trovata' }
            (Get-StatoFinale $script:Dati)['5']['runId'] | Should -BeNullOrEmpty
        }

        It 'Deploying to test entrata da un altro utente o dallo smistatore: si accoda il deploy, la card non torna In review' {
            $global:Mondo.Storia['5'] = New-FintaStoria 'inDeployTest' 'u-altro'
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-AdoDeployTest -Times 1 -Exactly
            Should -Invoke Set-AdoCard -Times 0 -Exactly
        }

        It 'In review con la revisione superata: la card passa da sola Deploying to test, senza avviso, e il deploy parte al giro dopo' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq 'Deploying to test' }
            Should -Invoke Add-AdoCommento -Times 0 -Exactly
            Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
            Should -Invoke Start-AdoDeployTest -Times 0 -Exactly
        }

        It 'deploy riuscito: la card passa in Automated test' {
            $global:Mondo.Run['300'] = [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded' }
            $st = [hashtable]::new($script:StatoInTest); $st['runId'] = 300; $st['runDopoRev'] = 20
            Set-StatoDiPartenza $script:Dati @{ '5' = $st }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq 'Automated test' }
            Should -Invoke Start-AdoDeployTest -Times 0 -Exactly
        }

        It 'deploy riuscito con il tag human-test: la card passa in Human test, l avviso al richiedente viene al giro dopo' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inDeployTest' -Tag @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagProvaUmana))
            $global:Mondo.Run['300'] = [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded' }
            $st = [hashtable]::new($script:StatoInTest); $st['runId'] = 300; $st['runDopoRev'] = 20
            Set-StatoDiPartenza $script:Dati @{ '5' = $st }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq 'Human test' }
            Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
        }

        It 'In review con la revisione superata e un altra card dello stesso componente in Deploying to test: resta In review' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inRevisione'), (New-FintaCard 6 'inDeployTest'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'; $global:Mondo.Storia['6'] = New-FintaStoria 'inDeployTest'
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            Invoke-Giro $script:Dati @{ Card = 5 } | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -Exactly
        }

        It 'Automated test con un task figlio aperto: il giro legge i task e riporta la card In development' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inCollaudo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'
            $global:Mondo.Task['5'] = @([pscustomobject]@{ Id = 63; Titolo = 'Passo aggiunto'; Descrizione = 'd'; Stato = 'New' })
            $st = [hashtable]::new($script:StatoInTest); $st['cartella'] = $script:CartellaOk; $st['prId'] = 9
            Set-StatoDiPartenza $script:Dati @{ '5' = $st }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq 'In development' }
        }

        It 'Automated test con un commento di persona non letto: parte responsabile, non il collaudatore, e il commento risulta letto' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inCollaudo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'
            $global:Mondo.Commenti['5'] = @([pscustomobject]@{ Id = 31; Autore = 'Anna'; Testo = 'Manca il totale'; Quando = '2026-11-02T09:00:00Z' })
            $st = [hashtable]::new($script:StatoInTest); $st['cartella'] = $script:CartellaOk; $st['prId'] = 9
            Set-StatoDiPartenza $script:Dati @{ '5' = $st }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'responsabile' -and $Messaggio -match 'Motivo: commentoInCollaudo' }
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly -ParameterFilter { $Ruolo -eq 'collaudatore' }
            (Get-StatoFinale $script:Dati)['5']['ultimoCommento'] | Should -Be 31
        }

        It 'In review con la revisione superata e un altra card dello stesso componente gia In Human test: resta In review' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inRevisione'), (New-FintaCard 6 'inProvaUmana'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'; $global:Mondo.Storia['6'] = New-FintaStoria 'inProvaUmana'
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            $out = Invoke-Giro $script:Dati @{ Card = 5 }
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            $out | Should -Match 'card 5: in coda, un altra card dello stesso componente e in Test'
        }

        It 'In review con la revisione superata e un altra card dello stesso componente gia In Automated test: resta In review e il log dice quale' {
            $global:Mondo.Cards = @((New-FintaCard 5 'inRevisione'), (New-FintaCard 6 'inCollaudo'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'; $global:Mondo.Storia['6'] = New-FintaStoria 'inCollaudo'
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:StatoInTest }
            $out = Invoke-Giro $script:Dati @{ Card = 5 }
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            Should -Invoke Add-AdoCommento -Times 0 -Exactly
            $out | Should -Match 'card 5: in coda, un altra card dello stesso componente e in Test \(stime, 1/1: card 6\)'
        }

        It 'Ready to merge: CompletaPr completa sul commit di testa letto nell istantanea, non su quello riletto (D52, gruppo 4)' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 1; UrlLog = $null; UltimoCommit = 'c-letto' }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; prId = 9 } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Complete-AdoPr -Times 1 -Exactly -ParameterFilter { $Id -eq 9 -and $Commit -eq 'c-letto' }
        }

        It 'Ready to merge con PR attiva: chiede il completamento, ma la card non si sposta prima che la PR sia completata' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 1; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; prId = 9 } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Complete-AdoPr -Times 1 -Exactly -ParameterFilter { $Id -eq 9 }
            Should -Invoke Set-AdoCard -Times 0 -Exactly
        }

        It 'Ready to merge: completamento chiesto e PR ancora aperta al giro dopo: on-hold con il motivo, nessun secondo completamento' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 1; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ passateFatte = @('prNonCompletata'); ramo = 'feature/5-x'; prId = 9; completaPr = '9@20' } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Complete-AdoPr -Times 0 -Exactly
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
            Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'PR 9' -and $Testo -match 'ancora aperta' }
        }

        It 'Ready to merge: se la PR non si completa la card non si sposta' {
            Mock Complete-AdoPr { throw 'TF401398: la policy Build non e soddisfatta' }
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 1; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; prId = 9 } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $Stato -eq 'Ready to release' }
        }

        It 'Ready to merge senza una PR attiva sul ramo: on-hold, niente da completare' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ passateFatte = @('nessuna PR da completare sul ramo della card'); ramo = 'feature/5-x'; prId = 9 } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Complete-AdoPr -Times 0 -Exactly
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
            Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'nessuna PR da completare' }
        }

        It 'Ready to release con la PR ancora aperta: non si completa niente da qui' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daRilasciare')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daRilasciare'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 1; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; prId = 9; cartella = 'C:/wt/card-5' } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Complete-AdoPr -Times 0 -Exactly
            Should -Invoke Remove-WorktreeCard -Times 0 -Exactly
            Should -Invoke Set-AdoCard -Times 0 -Exactly
        }

        It 'CompletaPr chiama Complete-AdoPr con il prId dello stato' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 1; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; prId = 9 } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Complete-AdoPr -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'Acme.AI' -and $Repo -eq 'Acme.AI' -and $Id -eq 9 }
            Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
        }

        It 'CompletaPr completa la PR attiva sul ramo, non un prId rimasto di una PR abbandonata' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 1; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; prId = 8 } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Complete-AdoPr -Times 1 -Exactly -ParameterFilter { $Id -eq 9 }
        }

        It 'CompletaPr senza una PR attiva con un Id ripiega sul prId salvato' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = $null; Stato = 'active'; Validazione = 'verde'; BuildId = 1; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; prId = 8 } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Complete-AdoPr -Times 1 -Exactly -ParameterFilter { $Id -eq 8 }
        }

        It 'CompletaPr senza nessun id di PR mette la card in on-hold e non completa niente' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = $null; Stato = 'active'; Validazione = 'verde'; BuildId = 1; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x' } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Complete-AdoPr -Times 0 -Exactly
            Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'Non so quale PR' }
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        }

        It 'CompletaPr ricorda la richiesta e lo scrive nel log; la card resta in Ready to merge finche la PR non e completata' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 1; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; prId = 9 } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Complete-AdoPr -Times 1 -Exactly
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            (Get-StatoFinale $script:Dati)['5']['completaPr'] | Should -Be '9@20'
            (Get-Content (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Select-Object -First 1).FullName -Raw) | Should -Match 'card 5: chiesto il completamento della PR 9'
            # al giro dopo la PR e completata: la card passa in Ready to release
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Complete-AdoPr -Times 1 -Exactly
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq 'Ready to release' }
        }

        It 'Ready to merge legge anche la PR completata del ramo' {
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; prId = 9 } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Get-AdoPr -ParameterFilter { $Ramo -eq 'feature/5-x' -and $AncheCompletate }
        }

        It 'CompletaPr rifiutata da una policy mette la card in on-hold con il testo dell errore' {
            Mock Complete-AdoPr { throw 'TF401398: la policy Build non e soddisfatta' }
            $global:Mondo.Cards = @(New-FintaCard 5 'daUnire')
            $global:Mondo.Storia['5'] = New-FintaStoria 'daUnire'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 1; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; prId = 9 } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
            Should -Invoke Add-AdoCommento -ParameterFilter { $Id -eq 5 -and $Testo -match 'CompletaPr' -and $Testo -match 'TF401398' }
        }
    }

    Context 'la quota (D51)' {
        BeforeEach {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            # senza un ESITO una sessione con il processo vivo e una pausa, non una fine: qui il processo e gia uscito
            Mock Test-SessioneViva { $false }
            # l'ora di ripresa e nel futuro: un reset gia passato non terrebbe ferma la card nello stesso giro
            $script:Reset = (Get-Date).ToUniversalTime().AddHours(2)
            $script:Quota = @{
                five_hour = @{ Utilization = 1.0; ResetsAt = $script:Reset }
                seven_day = @{ Utilization = 0.37; ResetsAt = (Get-Date).ToUniversalTime().AddDays(3) }
            }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $script:CartellaOk } }
        }

        It 'una sessione finita sul limite: niente on-hold ne Telegram, pausa in quota.json, commento sulla card, esito limite nel registro' {
            $e = New-FintoEsito $true $null $true
            $e | Add-Member Quota $script:Quota; $e | Add-Member Limite @{ Finestra = 'five_hour'; Reset = $script:Reset }
            $global:Mondo.Esiti['sid-d'] = $e
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -ParameterFilter { $AggiungiTag -contains 'on-hold' }
            Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
            Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter {
                $Id -eq 5 -and $Testo -match '^\[smistatore\]' -and $Testo -match 'dev' -and $Testo -match 'limite di token' -and $Testo -match 'riprende da sola dopo le' -and -not $Menziona }
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['inAttesaPer'] | Should -Be 'quota'
            $s['sessione'] | Should -BeNullOrEmpty
            $s['ultimaSessione']['dev']['id'] | Should -Be 'sid-d'
            $s['ultimaSessione']['dev']['esito'] | Should -BeNullOrEmpty
            $s['ultimaSessione']['dev']['errore'] | Should -BeFalse
            $q = Get-Quota -Percorso (Join-Path $script:Dati 'quota.json')
            $q['finestraPausa'] | Should -Be 'five_hour'
            (ConvertTo-DataUtc $q['pausaFino']) | Should -Be ($script:Reset.AddMinutes([double]$script:Cfg.Limiti.margineQuotaMinuti))
            $q['fiveHour']['utilization'] | Should -Be 1
            $q['sevenDay']['utilization'] | Should -Be 0.37
            $r = Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl') | ConvertFrom-Json
            @($r).Count | Should -Be 1
            $r.esito | Should -Be 'limite'
            # i consumi si sommano come per ogni sessione finita
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Campi.Count -gt 0 }
        }

        It 'passata la pausa la card riprende la sessione con --resume e un messaggio che dice del limite di token' {
            $e = New-FintoEsito $true $null $true
            # la finestra piena e quella della pausa: il suo reset e passato con lei (D60: altrimenti la soglia delle 5 ore la fermerebbe)
            $passato = (Get-Date).ToUniversalTime().AddHours(-1)
            $e | Add-Member Quota @{ five_hour = @{ Utilization = 1.0; ResetsAt = $passato } }; $e | Add-Member Limite @{ Finestra = 'five_hour'; Reset = $passato }
            $global:Mondo.Esiti['sid-d'] = $e
            # un reset gia passato (piu il margine): al giro stesso la pausa e finita e la sessione riprende
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -ParameterFilter { $AggiungiTag -contains 'on-hold' }
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Riprendi -eq 'sid-d' -and $Messaggio -match 'limite di token' -and $Messaggio -notmatch 'tolto l.on-hold' }
            (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -BeNullOrEmpty
        }

        It 'un limite senza reset (Limite nullo) resta una sessione fallita: on-hold come prima' {
            $e = New-FintoEsito $true $null $true
            $e | Add-Member Quota $script:Quota; $e | Add-Member Limite $null
            $global:Mondo.Esiti['sid-d'] = $e
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
            (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -Be 'sessione'
        }

        It 'una sessione normale aggiorna la lettura della quota e non scrive nessuna pausa' {
            $e = New-FintoEsito $true 'fatto'
            $e | Add-Member Quota @{ five_hour = @{ Utilization = 0.38; ResetsAt = $script:Reset }; seven_day = @{ Utilization = 0.26; ResetsAt = $script:Reset.AddDays(3) } }
            $e | Add-Member Limite $null
            $global:Mondo.Esiti['sid-d'] = $e
            Invoke-Giro $script:Dati | Out-Null
            $q = Get-Quota -Percorso (Join-Path $script:Dati 'quota.json')
            $q['letta'] | Should -Not -BeNullOrEmpty
            $q['fiveHour']['utilization'] | Should -Be 0.38
            $q['sevenDay']['utilization'] | Should -Be 0.26
            (ConvertTo-DataUtc $q['fiveHour']['resetsAt']) | Should -Be $script:Reset
            $q.ContainsKey('pausaFino') | Should -BeFalse
            (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -Not -Be 'quota'
        }

        It 'una pausa gia scritta e piu lunga (limite settimanale) non si accorcia con un limite di 5 ore' {
            $lunga = (Get-Date).ToUniversalTime().AddDays(3)
            Save-Quota -Quota @{ pausaFino = $lunga.ToString('o'); finestraPausa = 'seven_day' } -Percorso (Join-Path $script:Dati 'quota.json')
            $e = New-FintoEsito $true $null $true
            $e | Add-Member Quota $script:Quota; $e | Add-Member Limite @{ Finestra = 'five_hour'; Reset = $script:Reset }
            $global:Mondo.Esiti['sid-d'] = $e
            Invoke-Giro $script:Dati | Out-Null
            $q = Get-Quota -Percorso (Join-Path $script:Dati 'quota.json')
            $q['finestraPausa'] | Should -Be 'seven_day'
            (ConvertTo-DataUtc $q['pausaFino']) | Should -Be (ConvertTo-DataUtc $lunga.ToString('o'))
        }

        It 'con -WhatIf il limite non scrive niente' {
            $e = New-FintoEsito $true $null $true
            $e | Add-Member Quota $script:Quota; $e | Add-Member Limite @{ Finestra = 'five_hour'; Reset = $script:Reset }
            $global:Mondo.Esiti['sid-d'] = $e
            $out = Invoke-Giro $script:Dati @{ WhatIf = $true }
            $out | Should -Match 'limite di token'
            Test-Path (Join-Path $script:Dati 'quota.json') | Should -BeFalse
            Should -Invoke Add-AdoCommento -Times 0 -Exactly
        }
    }

    Context 'gli on-hold che si tolgono da soli (D51, gruppo 2)' {
        BeforeEach {
            $script:Hold = @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagAttesa)
            $script:Reset = (Get-Date).ToUniversalTime().AddHours(-1)
            Mock Test-SessioneViva { $false }
        }

        It 'sessione chiusa per silenzio: causaAttesa silenzio, e Set-InAttesa scrive la riga di log dell on-hold' {
            Mock Test-SessioneViva { $true }
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            # secondo fermo (ripreseAutomatiche 1): l'on-hold resta e il segno si vede; al primo si scioglierebbe nello stesso giro
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive; ripreseAutomatiche = 1 } }
            $global:Mondo.Esiti['sid-d'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-60))
            Invoke-Giro $script:Dati | Out-Null
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['inAttesaPer'] | Should -Be 'sessione'
            $s['causaAttesa'] | Should -Be 'silenzio'
            (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'card 5: on-hold: .*silenzio.* \(per sessione\)'
        }

        It 'processo morto senza result: causaAttesa morta (al secondo fermo, cosi resta visibile)' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive; ripreseAutomatiche = 1 } }
            $global:Mondo.Esiti['sid-d'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-1))
            Invoke-Giro $script:Dati | Out-Null
            (Get-StatoFinale $script:Dati)['5']['causaAttesa'] | Should -Be 'morta'
        }

        It 'sessione fallita con un result (errore vero): causaAttesa fallita, e il giro dopo la lascia in on-hold' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive } }
            $e = New-FintoEsito $true $null $true
            $e | Add-Member Limite $null; $e | Add-Member Quota $null
            $global:Mondo.Esiti['sid-d'] = $e
            Invoke-Giro $script:Dati | Out-Null
            (Get-StatoFinale $script:Dati)['5']['causaAttesa'] | Should -Be 'fallita'
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' $script:Hold)
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -ParameterFilter { $TogliTag }
        }

        It 'primo silenzio o processo morto: niente on-hold, Telegram o menzione; un commento, la ripresa nello stesso giro con il messaggio dello smistatore, passateFatte intatte (<Caso>)' -ForEach @(@{ Caso = 'silenzio' }, @{ Caso = 'morta' }) {
                if ($caso -eq 'silenzio') { Mock Test-SessioneViva { $true } } else { Mock Test-SessioneViva { $false } }
                $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
                $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
                Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $script:CartellaOk; passateFatte = @('chiave-di-prima') } }
                $minuti = if ($caso -eq 'silenzio') { -60 } else { -1 }
                $global:Mondo.Esiti['sid-d'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes($minuti))
                Invoke-Giro $script:Dati | Out-Null
                Should -Invoke Set-AdoCard -Times 0 -ParameterFilter { $AggiungiTag -contains 'on-hold' }
                Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
                Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match '^\[smistatore\] La sessione di dev' -and $Testo -match 'una volta' -and -not $Menziona }
                Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Testo -match 'Sessione sid-nuova' }
                Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Riprendi -eq 'sid-d' -and $Messaggio -match 'chiusa dallo smistatore' -and $Messaggio -notmatch 'tolto l.on-hold' }
                $s = (Get-StatoFinale $script:Dati)['5']
                $s['ripreseAutomatiche'] | Should -Be 1
                $s['inAttesaPer'] | Should -BeNullOrEmpty
                $s['attesaToltaDaSmistatore'] | Should -BeNullOrEmpty
                @($s['passateFatte']) | Should -Be @('chiave-di-prima')
                (Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl') | ConvertFrom-Json | Select-Object -Last 1).esito | Should -Be $(if ($Caso -eq 'silenzio') { 'silenzio' } else { 'errore' })
        }

        It 'al secondo fermo uguale (ripreseAutomatiche 1) l on-hold resta' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' $script:Hold)
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'sessione'; causaAttesa = 'silenzio'; ripreseAutomatiche = 1; ultimoRuolo = 'dev'; cartella = $script:CartellaOk } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            Should -Invoke Add-AdoCommento -Times 0 -Exactly
        }

        It 'una persona che toglie il tag dopo il secondo fermo: ripreseAutomatiche si azzera e le passate si svuotano' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'sessione'; ripreseAutomatiche = 1; passateFatte = @('chiave-di-prima'); ultimoRuolo = 'dev'; cartella = $script:CartellaOk
                ultimaSessione = @{ dev = @{ id = 'sid-d'; esito = $null; fine = $null } } } }
            Invoke-Giro $script:Dati | Out-Null
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['ripreseAutomatiche'] | Should -Be 0
            @($s['passateFatte']).Count | Should -Be 0
        }

        It 'limite di prima di D51 con il reset passato: TogliAttesa con Per quota, poi la ripresa con DopoQuota' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione' $script:Hold)
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'sessione'; ultimoRuolo = 'reviewer'; ramo = 'feature/5-x'; cartella = $script:CartellaOk
                ultimaSessione = @{ reviewer = @{ id = 'sid-v'; esito = $null; fine = '2026-11-20T10:00:00Z'; errore = $true; testo = "You've hit your 5-hour limit - resets 9pm" } } } }
            $e = New-FintoEsito $true $null $true "You've hit your 5-hour limit - resets 9pm"
            $e | Add-Member Limite @{ Finestra = 'five_hour'; Reset = $script:Reset }
            $global:Mondo.Esiti['sid-v'] = $e
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Get-EsitoSessione -ParameterFilter { $Id -eq 'sid-v' }
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $TogliTag -contains 'on-hold' }
            Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Testo -match "tolgo l'on-hold: .*limite" }
            (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -Be 'quota'
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'reviewer' -and $Riprendi -eq 'sid-v' -and $Messaggio -match 'limite di token' }
        }

        It 'limite con il reset non ancora passato, o senza reset: resta on-hold' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione' $script:Hold)
            $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'sessione'; ultimoRuolo = 'reviewer'; ramo = 'feature/5-x'; cartella = $script:CartellaOk
                ultimaSessione = @{ reviewer = @{ id = 'sid-v'; esito = $null; errore = $true; testo = "You've hit your 5-hour limit" } } } }
            $e = New-FintoEsito $true $null $true "You've hit your 5-hour limit"
            $e | Add-Member Limite @{ Finestra = 'five_hour'; Reset = (Get-Date).ToUniversalTime().AddHours(2) }
            $global:Mondo.Esiti['sid-v'] = $e
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            $e.Limite = $null
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -Exactly
        }

        It 'il jsonl di una sessione si legge solo per le card in on-hold per il limite' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' $script:Hold)
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'sessione'; causaAttesa = 'fallita'; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'sid-d'; errore = $true; testo = 'hit your limit' } } } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Get-EsitoSessione -Times 0 -Exactly
        }

        It 'on-hold per validazioni rosse con la validazione ora verde: TogliAttesa con Per limite, poi contatori a zero e reviewer' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' $script:Hold)
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 78; UrlLog = 'https://log/78' }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'limite'; rosseDiFila = 3; ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'
                ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-20T10:00:00Z' } } } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $TogliTag -contains 'on-hold' }
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['inAttesaPer'] | Should -Be 'limite'
            $s['rosseDiFila'] | Should -Be 3
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            Invoke-Giro $script:Dati | Out-Null
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['rosseDiFila'] | Should -Be 0
            $s['attesaToltaDaSmistatore'] | Should -BeNullOrEmpty
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'reviewer' }
        }

        It 'on-hold per il deploy non si scioglie mai' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inDeployTest' $script:Hold)
            $global:Mondo.Storia['5'] = New-FintaStoria 'inDeployTest'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'deploy'; causaAttesa = 'silenzio'; ramo = 'feature/5-x'; cartella = $script:CartellaOk } }
            Invoke-Giro $script:Dati | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -Exactly
        }

        It 'con -WhatIf dice che toglierebbe l on-hold e non scrive niente' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo' $script:Hold)
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 78; UrlLog = 'https://log/78' }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'limite'; rosseDiFila = 3; ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'dev' } }
            $out = Invoke-Giro $script:Dati @{ WhatIf = $true }
            $out | Should -Match 'TogliAttesa'
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -Be 'limite'
        }
    }

    It 'la ripresa dopo on-hold riprende la sessione di prima con --resume e svuota inAttesaPer' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'sessione'; cartella = $script:CartellaOk; ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'sid-vecchia'; esito = $null; fine = $null } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'reviewer' -and $Riprendi -eq 'sid-vecchia' }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['inAttesaPer'] | Should -BeNullOrEmpty
        $s['sessione']['ripresa'] | Should -BeTrue
    }

    It 'la ripresa dopo on-hold dice alla sessione di rileggere il brief e i commenti, che possono essere cambiati' {
        # card 23: la sessione ripresa ha rifatto la conclusione di prima ("non c'e niente di nuovo") con la regola gia cambiata
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'sessione'; cartella = $script:CartellaOk; ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'sid-vecchia'; esito = $null; fine = $null } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter {
            $Messaggio -match 'on-hold' -and $Messaggio -match 'ruoli[\\/]reviewer\.md' -and $Messaggio -match 'commenti' }
    }

    It 'AzzeraContatori azzera i contatori nello stato' {
        $global:Mondo.Cards = @(New-FintaCard 5 'daChiarire')
        $global:Mondo.Storia['5'] = New-FintaStoria 'daChiarire'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'limite'; giriRevisione = 2; rosseDiFila = 3; giriCollaudo = 2 } }
        Invoke-Giro $script:Dati | Out-Null
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['giriRevisione'] | Should -Be 0
        $s['giriCollaudo'] | Should -Be 0
        $s['rosseDiFila'] | Should -Be 0
        $s['inAttesaPer'] | Should -BeNullOrEmpty
    }

    It 'un limite per repo si calcola su tutte le card: Ready to develop aspetta se un altra e In development sullo stesso repo' {
        $global:Mondo.Cards = @((New-FintaCard 5 'pronto'), (New-FintaCard 6 'inSviluppo' -Assegnata 'u-collega'))
        $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'; $global:Mondo.Storia['6'] = New-FintaStoria 'inSviluppo'
        $out = Invoke-Giro $script:Dati
        Should -Invoke Set-AdoCard -Times 0 -Exactly
        Should -Invoke Add-AdoCommento -Times 0 -Exactly
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
    }

    Context 'le card della funzionalita (D52, gruppo 3)' {
        BeforeEach {
            # La Feature 7 con le sue figlie: le card 5 e 6 (della funzionalita) e la 22, la card di chiusura. Il ramo della funzionalita su
            # origin lo da Get-AdoRamoCard; Publish-RamoFunzionalita lo crea.
            $script:RadiceF = New-RadiceDiProva -Cartella $TestDrive -Limiti @{ funzionalitaAttive = $true }
            $global:Fx = @{ Feature = 'New'; Ramo = $null; Creato = 0; TagChiusura = $script:Cfg.Stati.tagChiusura; StatoCard = (St 'pronto'); StatoChiusura = (St 'bozza') }
            Mock Get-AdoFeature { [pscustomobject]@{ Id = 7; Tipo = 'Feature'; Titolo = 'La funzione'; Stato = $global:Fx.Feature; Tag = @(); Area = 'x'; FigliIds = @(5, 6, 22) } }
            Mock Get-AdoFigliFeature { @(
                    [pscustomobject]@{ Id = 5; Stato = $global:Fx.StatoCard; Tag = @(); Tipo = 'User Story' }
                    [pscustomobject]@{ Id = 6; Stato = $global:Fx.StatoCard; Tag = @(); Tipo = 'User Story' }
                    [pscustomobject]@{ Id = 22; Stato = $global:Fx.StatoChiusura; Tag = @($global:Fx.TagChiusura); Tipo = 'User Story' }) }
            Mock Get-AdoRamoCard { $global:Fx.Ramo }
            Mock Publish-RamoFunzionalita { $global:Fx.Creato++; $global:Fx.Ramo = 'feature/f7-la-funzione'; 'feature/f7-la-funzione' }
            Mock Set-AdoStatoFeature { 1 }
            $global:CartellaWt = Join-Path $TestDrive 'wt-card-5'
            New-Item -ItemType Directory $global:CartellaWt -Force | Out-Null
        }
        BeforeAll {
            # una card figlia della Feature 7, con la sua storia nello stato dato
            function New-FintaFunz($Id, [string]$Chiave) {
                $c = New-FintaCard $Id $Chiave
                $c | Add-Member -NotePropertyName PadreId -NotePropertyValue 7
                $global:Mondo.Storia["$Id"] = New-FintaStoria $Chiave
                $c
            }
        }

        It 'Ready to develop senza il ramo: lo crea nella copia principale, il worktree parte da li, la Feature passa Active, dev parte con la base' {
            $global:Mondo.Cards = @(New-FintaFunz 5 'pronto')
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
            Should -Invoke Publish-RamoFunzionalita -Times 1 -Exactly -ParameterFilter {
                $Principale -eq 'C:/develop/GIT/Acme.AI' -and $Feature.Id -eq 7 -and $TagBug -eq 'bug' }
            Should -Invoke New-WorktreeCard -Times 1 -Exactly -ParameterFilter { $Base -eq 'feature/f7-la-funzione' -and $Card.Id -eq 5 }
            Should -Invoke Set-AdoStatoFeature -Times 1 -Exactly -ParameterFilter { $FeatureId -eq 7 -and $Stato -eq 'Active' }
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq (St 'inSviluppo') }
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Base -eq 'feature/f7-la-funzione' }
            (Get-StatoFinale $script:Dati)['5']['destinazione'] | Should -Be 'feature/f7-la-funzione'
        }

        It 'due card della stessa Feature nello stesso giro: il ramo si crea una volta e la Feature si attiva una volta' {
            $radice = New-RadiceDiProva -Cartella $TestDrive -Limiti @{ cardInSviluppoPerRepo = 5; sessioniAttive = 5; funzionalitaAttive = $true }
            $global:Mondo.Cards = @((New-FintaFunz 5 'pronto'), (New-FintaFunz 6 'pronto'))
            Invoke-Giro $script:Dati @{ Radice = $radice } | Out-Null
            Should -Invoke Publish-RamoFunzionalita -Times 1 -Exactly
            Should -Invoke Set-AdoStatoFeature -Times 1 -Exactly
            Should -Invoke New-WorktreeCard -Times 2 -Exactly -ParameterFilter { $Base -eq 'feature/f7-la-funzione' }
            Should -Invoke Start-SessioneRuolo -Times 2 -Exactly -ParameterFilter { $Ruolo -eq 'dev' }
        }

        It 'con il ramo gia su origin e la Feature Active non crea e non aggiorna niente: solo il worktree dalla base' {
            $global:Fx.Ramo = 'feature/f7-gia-pubblicato'; $global:Fx.Feature = 'Active'
            $global:Mondo.Cards = @(New-FintaFunz 5 'pronto')
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
            Should -Invoke Publish-RamoFunzionalita -Times 0 -Exactly
            Should -Invoke Set-AdoStatoFeature -Times 0 -Exactly
            Should -Invoke New-WorktreeCard -Times 1 -Exactly -ParameterFilter { $Base -eq 'feature/f7-gia-pubblicato' }
        }

        It 'se la creazione del ramo fallisce la card va in on-hold con il motivo e il worktree non si crea' {
            Mock Publish-RamoFunzionalita { throw 'push rifiutato' }
            $global:Mondo.Cards = @(New-FintaFunz 5 'pronto')
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
            Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'push rifiutato' -and $Testo -match 'CreaRamoFunzionalita' }
            Should -Invoke New-WorktreeCard -Times 0 -Exactly
        }

        It 'una card isolata non cambia: il worktree senza base, nessuna destinazione salvata, dev parte con develop' {
            $global:Mondo.Cards = @(New-FintaCard 5 'pronto')
            $global:Mondo.Storia['5'] = New-FintaStoria 'pronto'
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
            Should -Invoke New-WorktreeCard -Times 1 -Exactly -ParameterFilter { -not $Base }
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Base -eq 'develop' }
            Should -Invoke Publish-RamoFunzionalita -Times 0 -Exactly
            (Get-StatoFinale $script:Dati)['5'].Contains('destinazione') | Should -BeFalse
        }

        It 'ApriPr apre la PR verso la destinazione salvata nello stato della card' {
            $global:Mondo.Cards = @(New-FintaFunz 5 'inSviluppo')
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; destinazione = 'feature/f7-la-funzione'; cartella = $script:CartellaOk; ultimoRuolo = 'dev'
                ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
            Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/5-x' -and $Destinazione -eq 'feature/f7-la-funzione' }
            Should -Invoke Get-AdoPr -ParameterFilter { $Destinazione -eq 'feature/f7-la-funzione' }
        }

        It 'ApriPr di una card isolata va verso develop, anche con uno stato di prima di D52 senza destinazione' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
            $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' } } } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
            Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter { $Destinazione -eq 'develop' }
        }

        It 'RimuoviWorktree passa la destinazione: il ramo locale si cancella se e unito nel ramo della funzionalita' {
            $global:Fx.Ramo = 'feature/f7-la-funzione'; $global:Fx.Feature = 'Active'; $global:Fx.StatoChiusura = (St 'inCollaudo')
            $global:Mondo.Cards = @(New-FintaFunz 5 'inFeature')
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; destinazione = 'feature/f7-la-funzione'; cartella = 'C:/wt/card-5'; prId = 9 } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
            Should -Invoke Remove-WorktreeCard -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/5-x' -and $Destinazione -eq 'feature/f7-la-funzione' }
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['cartella'] | Should -BeNullOrEmpty
            $s['ramo'] | Should -BeNullOrEmpty
            Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $Stato }
        }

        It 'In feature branch con la card di chiusura in Ready to release: la card la segue' {
            $global:Fx.Ramo = 'feature/f7-la-funzione'; $global:Fx.Feature = 'Active'; $global:Fx.StatoChiusura = (St 'daRilasciare')
            $global:Mondo.Cards = @(New-FintaFunz 5 'inFeature')
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = $null; cartella = $null; prId = 9; destinazione = 'feature/f7-la-funzione' } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq (St 'daRilasciare') }
        }

        It 'una lettura della funzionalita fallita: la card non fa niente, nessun on-hold, e il giro lo scrive nel log' {
            Mock Get-AdoFeature { throw 'ADO non risponde' }
            $global:Mondo.Cards = @(New-FintaFunz 5 'pronto')
            $out = Invoke-Giro $script:Dati @{ Radice = $script:RadiceF }
            Should -Invoke New-WorktreeCard -Times 0 -Exactly
            Should -Invoke Set-AdoCard -Times 0 -Exactly
            Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
            (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'card 5: .*non si legge.*ADO non risponde'
        }

        It 'con l interruttore funzionalitaAttive spento una chiusura taggata a mano non accende niente: la card e isolata e la Feature non si legge' {
            $global:Mondo.Cards = @(New-FintaFunz 5 'pronto')
            # spento esplicitamente: non dipende dal valore di config/limiti.json
            Invoke-Giro $script:Dati @{ Radice = (New-RadiceDiProva -Cartella $TestDrive -Limiti @{ funzionalitaAttive = $false }) } | Out-Null
            Should -Invoke Get-AdoFeature -Times 0 -Exactly
            Should -Invoke Publish-RamoFunzionalita -Times 0 -Exactly
            Should -Invoke New-WorktreeCard -Times 1 -Exactly -ParameterFilter { -not $Base }
            (Get-StatoFinale $script:Dati)['5'].Contains('destinazione') | Should -BeFalse
        }

        It 'AggiornaFeature che fallisce non ferma la card: una riga ERRORE nel log, niente on-hold, la card va avanti' {
            Mock Set-AdoStatoFeature { throw 'permesso negato' }
            $global:Mondo.Cards = @(New-FintaFunz 5 'pronto')
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
            Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Stato -eq (St 'inSviluppo') }
            Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' }
            (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'ERRORE.*Feature 7.*permesso negato'
        }

        It 'RilanciaScadute rilancia le validazioni della PR verso la destinazione salvata' {
            Mock Start-AdoRivalutazione { 1 }
            $global:Mondo.Cards = @(New-FintaFunz 5 'daUnire')
            $global:Mondo.Pr['feature/5-x'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'scaduta'; BuildId = 58; UrlLog = $null }
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; destinazione = 'feature/f7-la-funzione'; cartella = $script:CartellaOk; prId = 9 } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
            Should -Invoke Start-AdoRivalutazione -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/5-x' -and $Destinazione -eq 'feature/f7-la-funzione' -and $Scadute }
        }

        Context 'presa in carico' {
            It 'una card In feature branch senza stato locale non ricrea il worktree: salva il prId della PR collegata e basta' {
                $global:Fx.Ramo = 'feature/f7-la-funzione'; $global:Fx.Feature = 'Active'; $global:Fx.StatoChiusura = (St 'inCollaudo')
                Mock Get-AdoPrCollegata { [pscustomobject]@{ Id = 951; Stato = 'completed' } }
                $global:Mondo.Cards = @(New-FintaFunz 5 'inFeature')
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke New-WorktreeDaRemoto -Times 0 -Exactly
                Should -Invoke New-WorktreeCard -Times 0 -Exactly
                (Get-StatoFinale $script:Dati)['5']['prId'] | Should -Be 951
                Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
            }
            It 'una card In feature branch con la PR collegata non completata va in on-hold: non so cosa e unito' {
                $global:Fx.Ramo = 'feature/f7-la-funzione'; $global:Fx.Feature = 'Active'; $global:Fx.StatoChiusura = (St 'inCollaudo')
                Mock Get-AdoPrCollegata { [pscustomobject]@{ Id = 951; Stato = 'active' } }
                $global:Mondo.Cards = @(New-FintaFunz 5 'inFeature')
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
                Should -Invoke New-WorktreeDaRemoto -Times 0 -Exactly
            }
            It 'una card della funzionalita presa in carico in development salva la destinazione: la sua PR non deve finire su develop' {
                $global:Fx.Ramo = 'feature/f7-la-funzione'; $global:Fx.Feature = 'Active'
                $global:Mondo.Cards = @(New-FintaFunz 5 'inSviluppo')
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke New-WorktreeDaRemoto -Times 1 -Exactly
                (Get-StatoFinale $script:Dati)['5']['destinazione'] | Should -Be 'feature/f7-la-funzione'
            }
            It 'una card della funzionalita senza ramo suo su origin riparte dalla base, non da develop' {
                Mock New-WorktreeDaRemoto { $null }
                $global:Fx.Ramo = 'feature/f7-la-funzione'; $global:Fx.Feature = 'Active'
                $global:Mondo.Cards = @(New-FintaFunz 5 'inSviluppo')
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke New-WorktreeCard -Times 1 -Exactly -ParameterFilter { $Base -eq 'feature/f7-la-funzione' }
                (Get-StatoFinale $script:Dati)['5']['destinazione'] | Should -Be 'feature/f7-la-funzione'
            }
            It 'una card Ready to release della funzionalita si adotta con la sola PR collegata, anche se il ramo della funzionalita non c e piu su origin' {
                Mock New-WorktreeDaRemoto { $null }
                $global:Fx.Ramo = $null; $global:Fx.Feature = 'Active'; $global:Fx.StatoChiusura = (St 'daRilasciare')
                Mock Get-AdoPrCollegata { [pscustomobject]@{ Id = 951; Stato = 'completed' } }
                $global:Mondo.Cards = @(New-FintaFunz 5 'daRilasciare')
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                (Get-StatoFinale $script:Dati)['5']['prId'] | Should -Be 951
                Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
                Should -Invoke New-WorktreeCard -Times 0 -Exactly
            }
            It 'una card In feature branch salva la destinazione adottandola: il giro dopo e ancora della funzionalita' {
                $global:Fx.Ramo = 'feature/f7-la-funzione'; $global:Fx.Feature = 'Active'; $global:Fx.StatoChiusura = (St 'inCollaudo')
                Mock Get-AdoPrCollegata { [pscustomobject]@{ Id = 951; Stato = 'completed' } }
                $global:Mondo.Cards = @(New-FintaFunz 5 'inFeature')
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                (Get-StatoFinale $script:Dati)['5']['destinazione'] | Should -Be 'feature/f7-la-funzione'
            }
        }

        # D52, gruppo 4: la card di chiusura (22) della Feature 7, con le sorelle 5 e 6. Non ha worktree: nello stato ha come ramo quello della
        # funzionalita, come destinazione develop e la cartella vuota.
        Context 'la card di chiusura (gruppo 4)' {
            BeforeEach {
                $global:Fx.Ramo = 'feature/f7-la-funzione'; $global:Fx.Feature = 'Active'; $global:Fx.StatoCard = (St 'inFeature')
                Mock Get-AdoErroriBuild { 'errori della build' }
                Mock Start-AdoRivalutazione { 1 }
                $script:PrFunz = 'feature/f7-la-funzione'
                $script:StatoChiusura = { param($Altro = @{}) $s = @{ ramo = 'feature/f7-la-funzione'; destinazione = 'develop'; cartella = $null; ultimoRuolo = 'responsabile' }; foreach ($k in $Altro.Keys) { $s[$k] = $Altro[$k] }; $s }
            }

            It 'Ready to develop senza il ramo salvato: lo imposta dalla funzionalita (destinazione develop, nessuna cartella) e non crea ne worktree ne PR nello stesso giro' {
                $global:Fx.StatoChiusura = (St 'pronto')
                $global:Mondo.Cards = @(New-FintaFunz 22 'pronto')
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                $s = (Get-StatoFinale $script:Dati)['22']
                $s['ramo'] | Should -Be 'feature/f7-la-funzione'
                $s['destinazione'] | Should -Be 'develop'
                $s['cartella'] | Should -BeNullOrEmpty
                Should -Invoke New-WorktreeCard -Times 0 -Exactly
                Should -Invoke New-WorktreeDaRemoto -Times 0 -Exactly
                Should -Invoke New-AdoPr -Times 0 -Exactly
                Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
            }

            It 'Ready to develop con il ramo salvato e senza PR: apre la PR ramo della funzionalita -> develop, titolo feat, e ne salva il prId' {
                $global:Fx.StatoChiusura = (St 'pronto')
                $global:Mondo.Cards = @(New-FintaFunz 22 'pronto')
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke New-AdoPr -Times 1 -Exactly -ParameterFilter {
                    $Ramo -eq 'feature/f7-la-funzione' -and $Destinazione -eq 'develop' -and $Titolo -eq 'feat: Titolo della card 22' -and $CardId -eq 22 }
                (Get-StatoFinale $script:Dati)['22']['prId'] | Should -Be 77
                Should -Invoke New-WorktreeCard -Times 0 -Exactly
                Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
            }

            It 'la PR verde la porta In Deploying to test; la sessione di dev non parte mai' {
                $global:Fx.StatoChiusura = (St 'pronto')
                $global:Mondo.Cards = @(New-FintaFunz 22 'pronto')
                $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null; UltimoCommit = 'c1' }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 22 -and $Stato -eq (St 'inDeployTest') }
                Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
                (Get-StatoFinale $script:Dati)['22']['prId'] | Should -Be 9
            }

            It 'la PR rossa, con la build gia gestita dal responsabile (ciRossaGestita), la ferma senza on-hold e senza sessioni, e il log dice perche' {
                $global:Fx.StatoChiusura = (St 'pronto')
                $global:Mondo.Cards = @(New-FintaFunz 22 'pronto')
                $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'rossa'; BuildId = 58; UrlLog = 'https://ado/58'; UltimoCommit = 'c1' }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ ciRossaGestita = 58 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Get-AdoErroriBuild -Times 1 -Exactly -ParameterFilter { $BuildId -eq 58 }
                Should -Invoke Set-AdoCard -Times 0 -Exactly
                Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
                (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'card 22: .*validazione della PR e rossa.*errori della build'
            }

            It 'Deploying to test accoda il deploy dal ramo della funzionalita salvato' {
                $global:Fx.StatoChiusura = (St 'inDeployTest')
                $global:Mondo.Cards = @(New-FintaFunz 22 'inDeployTest')
                $global:Mondo.Commenti['22'] = @(New-CommentoDeploy 40 @('deployStime'))
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Start-AdoDeployTest -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/f7-la-funzione' }
            }

            It 'Automated test: il collaudatore parte nel worktree in sola lettura della chiusura (detached su origin/<ramo>), con la base develop e l impronta D39' {
                Mock Update-WorktreeChiusura { [pscustomobject]@{ Cartella = $global:CartellaWt; Ramo = $null } }
                $global:Fx.StatoChiusura = (St 'inCollaudo')
                $global:Mondo.Cards = @(New-FintaFunz 22 'inCollaudo')
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ runId = 555; runDopoRev = 20 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Update-WorktreeChiusura -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/f7-la-funzione' -and $Card.Id -eq 22 }
                Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter {
                    $Ruolo -eq 'collaudatore' -and $Cartella -eq $global:CartellaWt -and $Base -eq 'develop' }
                Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
                $st = (Get-StatoFinale $script:Dati)['22']
                $st['cartella'] | Should -Be $global:CartellaWt
                $st['ramo'] | Should -Be 'feature/f7-la-funzione'
                $st['sessione']['impronta'] | Should -Not -BeNullOrEmpty
            }

            It 'la ripresa del collaudatore (on-hold tolto: <Per>) rinnova il worktree e riprende la sessione' -ForEach @(@{ Per = 'sessione' }, @{ Per = 'quota' }) {
                Mock Update-WorktreeChiusura { [pscustomobject]@{ Cartella = $global:CartellaWt; Ramo = $null } }
                $global:Fx.StatoChiusura = (St 'inCollaudo')
                $global:Mondo.Cards = @(New-FintaFunz 22 'inCollaudo')
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ runId = 555; runDopoRev = 20; inAttesaPer = $Per; ultimoRuolo = 'collaudatore'; cartella = $global:CartellaWt
                    ultimaSessione = @{ collaudatore = @{ id = 'c1'; ruolo = 'collaudatore'; inizio = '2026-11-02T09:00:00Z'; fine = $null; esito = $null; errore = $false; motivo = 'collaudo' } } }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Update-WorktreeChiusura -Times 1 -Exactly
                Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'collaudatore' -and $Riprendi -eq 'c1' -and $Cartella -eq $global:CartellaWt }
                Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
            }

            It 'se il worktree della chiusura non si prepara la card va in on-hold con il motivo e il collaudatore non parte' {
                Mock Update-WorktreeChiusura { throw 'git fetch fallito' }
                $global:Fx.StatoChiusura = (St 'inCollaudo')
                $global:Mondo.Cards = @(New-FintaFunz 22 'inCollaudo')
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ runId = 555; runDopoRev = 20 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Start-SessioneRuolo -Times 0 -Exactly -ParameterFilter { $Ruolo -eq 'collaudatore' }
            }

            It 'una card isolata senza worktree continua a non far partire il collaudatore: la regola resta' {
                $global:Mondo.Cards = @(New-FintaCard 5 'inCollaudo')
                $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'
                Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $null; ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'fatto'; fine = '2026-11-01T10:00:00Z' }; reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T11:00:00Z' } } } }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Start-SessioneRuolo -Times 0 -Exactly -ParameterFilter { $Ruolo -eq 'collaudatore' }
            }

            It 'Ready to merge con il commit diverso dal deploy: torna in Ready to develop e ricorda la testa della PR (ritornoCommit)' {
                $global:Fx.StatoChiusura = (St 'daUnire')
                $global:Mondo.Cards = @(New-FintaFunz 22 'daUnire')
                $global:Mondo.Run['555'] = [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded'; Url = 'u'; SourceVersion = 'c1' }
                $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null; UltimoCommit = 'c2' }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ runId = 555; runDopoRev = 20 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 22 -and $Stato -eq (St 'pronto') }
                Should -Invoke Complete-AdoPr -Times 0 -Exactly
                (Get-StatoFinale $script:Dati)['22']['ritornoCommit'] | Should -Be 'c2'
            }

            It 'Ready to merge, PR completata: Ready to release, la Feature Resolved e ricordata nello stato; nessun worktree da togliere' {
                $global:Fx.StatoChiusura = (St 'daUnire')
                $global:Mondo.Cards = @(New-FintaFunz 22 'daUnire')
                $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null; UltimoCommit = 'c1' }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 22 -and $Stato -eq (St 'daRilasciare') }
                Should -Invoke Set-AdoStatoFeature -Times 1 -Exactly -ParameterFilter { $FeatureId -eq 7 -and $Stato -eq 'Resolved' }
                (Get-StatoFinale $script:Dati)['22']['featureDaChiudere'] | Should -Be 7
                Should -Invoke Remove-WorktreeCard -Times 0 -Exactly
            }

            It 'se la Feature non passa Resolved (errore) la card va comunque in Ready to release, e il giro dopo riprova senza ricordarla ancora' {
                Mock Set-AdoStatoFeature { throw 'permesso negato' }
                $global:Fx.StatoChiusura = (St 'daUnire')
                $global:Mondo.Cards = @(New-FintaFunz 22 'daUnire')
                $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null; UltimoCommit = 'c1' }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 22 -and $Stato -eq (St 'daRilasciare') }
                (Get-StatoFinale $script:Dati)['22']['featureDaChiudere'] | Should -BeNullOrEmpty
                # il giro dopo: la card e in Ready to release, la Feature e ancora Active
                $global:Fx.StatoChiusura = (St 'daRilasciare')
                $global:Mondo.Cards = @(New-FintaFunz 22 'daRilasciare')
                Mock Set-AdoStatoFeature { 1 }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                # due chiamate in tutto: quella fallita del primo giro e la nuova (i Mock contano anche la prima)
                Should -Invoke Set-AdoStatoFeature -Times 2 -Exactly -ParameterFilter { $FeatureId -eq 7 -and $Stato -eq 'Resolved' }
                (Get-StatoFinale $script:Dati)['22']['featureDaChiudere'] | Should -Be 7
            }

            # D52, gruppo 5: le correzioni. Il responsabile ha finito in Automated test (collaudo respinto) dopo aver scritto la correzione.
            Context 'le correzioni e la Bug allinea-develop (gruppo 5)' {
                BeforeEach {
                    # come i creatori veri: DopoNascita gira appena la Bug esiste (e li lo smistatore scrive la marca sulla card di chiusura)
                    Mock New-CardCorrezioneFunzionalita { if ($DopoNascita) { [void](& $DopoNascita ([pscustomobject]@{ Id = 300 })) }; [pscustomobject]@{ Id = 300 } }
                    Mock New-CardAllineaDevelop { if ($DopoNascita) { [void](& $DopoNascita ([pscustomobject]@{ Id = 400 })) }; [pscustomobject]@{ Id = 400 } }
                    $global:Fx.StatoChiusura = (St 'inCollaudo')
                    $global:Mondo.Cards = @(New-FintaFunz 22 'inCollaudo')
                    $script:SessioneResp = @{ responsabile = @{ id = 'r1'; ruolo = 'responsabile'; inizio = '2026-11-02T11:00:00Z'; fine = '2026-11-02T11:30:00Z'; esito = 'fatto'; errore = $false; motivo = 'collaudoRespinto' } }
                    $script:PartenzaCorr = { Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ runId = 555; runDopoRev = 20; ultimaSessione = $script:SessioneResp }) } }
                }

                It 'la correzione tecnica diventa una Bug figlia della Feature (area della Feature, assegnata allo smistatore), e la chiave si ricorda' {
                    $global:Mondo.Commenti['22'] = @(New-CommentoCorrezione 55 'tecnico')
                    & $script:PartenzaCorr
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke New-CardCorrezioneFunzionalita -Times 1 -Exactly -ParameterFilter {
                        $Feature.Id -eq 7 -and $Chiusura -eq 22 -and $Correzione.Id -eq 55 -and $Correzione.Tipo -eq 'tecnico' -and
                        $Correzione.Titolo -eq 'Il totale non somma' -and $Correzione.Descrizione -eq 'Il totale ignora le righe scontate.' }
                    @((Get-StatoFinale $script:Dati)['22']['correzioniFatte']) | Should -Contain '55'
                    Should -Invoke Add-AdoCommento -Times 0 -Exactly -ParameterFilter { $Id -eq 300 }
                    Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
                    (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'card 22: .*correzione.*Bug 300'
                }

                It 'appena la Bug esiste scrive sulla card di chiusura il commento con la marca (Correzione #<commento> -> Bug <id>), con la configurazione data da lui' {
                    $global:Mondo.Commenti['22'] = @(New-CommentoCorrezione 55 'tecnico')
                    & $script:PartenzaCorr
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 22 -and $Testo -eq '[smistatore] Correzione #55 -> Bug 300' }
                    Should -Invoke New-CardCorrezioneFunzionalita -Times 1 -Exactly -ParameterFilter { $null -ne $Config -and $Config.Stati.tagAgenti -eq 'agents' }
                }

                It 'stato locale vuoto con i commenti storici (la correzione e la marca della sua Bug): nessuna Bug nuova' {
                    $global:Mondo.Commenti['22'] = @((New-CommentoCorrezione 55 'tecnico'), [pscustomobject]@{ Id = 56; Autore = 'Titolare'; Quando = '2026-11-02T11:31:00Z'; Testo = '[smistatore] Correzione #55 -> Bug 300' })
                    & $script:PartenzaCorr
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke New-CardCorrezioneFunzionalita -Times 0 -Exactly
                }

                It 'una correzione, una Bug: il giro dopo non la rifa' {
                    $global:Mondo.Commenti['22'] = @(New-CommentoCorrezione 55 'tecnico')
                    & $script:PartenzaCorr
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke New-CardCorrezioneFunzionalita -Times 1 -Exactly
                }

                It 'la correzione di prodotto resta in Draft (lo decide la card creata) e la Bug porta un commento che menziona Titolare' {
                    $global:Mondo.Commenti['22'] = @(New-CommentoCorrezione 56 'prodotto' 'Quale arrotondamento')
                    Mock New-CardCorrezioneFunzionalita { [pscustomobject]@{ Id = 301 } }
                    & $script:PartenzaCorr
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke New-CardCorrezioneFunzionalita -Times 1 -Exactly -ParameterFilter { $Correzione.Tipo -eq 'prodotto' }
                    Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 301 -and $Menziona -eq 'u-ric' -and $Testo -like '[[]smistatore]*#22*' }
                    @((Get-StatoFinale $script:Dati)['22']['correzioniFatte']) | Should -Contain '56'
                }

                It 'se la Bug non si crea la card va in on-hold con il motivo e la chiave non si ricorda: si riprova quando la persona toglie il tag' {
                    Mock New-CardCorrezioneFunzionalita { throw 'ADO non risponde' }
                    $global:Mondo.Commenti['22'] = @(New-CommentoCorrezione 55 'tecnico')
                    & $script:PartenzaCorr
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 22 -and $AggiungiTag -contains 'on-hold' }
                    @(@((Get-StatoFinale $script:Dati)['22']['correzioniFatte']) | Where-Object { $null -ne $_ }).Count | Should -Be 0
                }

                It 'la CI rossa con errori di codice lancia il responsabile con gli errori in allegato e ricorda la build' {
                    $global:Fx.StatoChiusura = (St 'pronto')
                    $global:Mondo.Cards = @(New-FintaFunz 22 'pronto')
                    $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'rossa'; BuildId = 58; UrlLog = 'https://ado/58'; UltimoCommit = 'c1' }
                    Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura) }
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter {
                        $Ruolo -eq 'responsabile' -and $Allegato -like '*errori della build*' -and $Allegato -like '*https://ado/58*' -and $Messaggio -like '*ciRossa*' }
                    (Get-StatoFinale $script:Dati)['22']['ciRossaGestita'] | Should -Be 58
                    (Get-StatoFinale $script:Dati)['22']['ciRosseDiFila'] | Should -Be 1
                    Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
                }

                It 'il collaudo respinto conta in giriCollaudo anche sulla card di chiusura' {
                    $global:Mondo.Commenti['22'] = @()
                    Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ runId = 555; runDopoRev = 20; ultimoRuolo = 'collaudatore'
                        ultimaSessione = @{ collaudatore = @{ id = 'c1'; ruolo = 'collaudatore'; inizio = '2026-11-02T09:00:00Z'; fine = '2026-11-02T10:00:00Z'; esito = 'respinta'; testo = 'il filtro non somma'; errore = $false } } }) }
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'responsabile' -and $Messaggio -like '*collaudoRespinto*' }
                    (Get-StatoFinale $script:Dati)['22']['giriCollaudo'] | Should -Be 1
                }

                It 'PR in conflitto con develop: lo smistatore crea da se la Bug allinea-develop, senza responsabile, e ricorda il commit' {
                    $global:Fx.StatoChiusura = (St 'pronto')
                    $global:Mondo.Cards = @(New-FintaFunz 22 'pronto')
                    $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'conflitti'; BuildId = 58; UrlLog = $null; UltimoCommit = 'c1' }
                    Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura) }
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke New-CardAllineaDevelop -Times 1 -Exactly -ParameterFilter { $Feature.Id -eq 7 -and $Ramo -eq 'feature/f7-la-funzione' }
                    @((Get-StatoFinale $script:Dati)['22']['allineaFatti']) | Should -Contain 'c1'
                    Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
                    (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'card 22: .*allinea-develop.*Bug 400'
                }

                It 'la Bug allinea-develop scrive la sua marca con il commit di testa sulla card di chiusura' {
                    $global:Fx.StatoChiusura = (St 'pronto')
                    $global:Mondo.Cards = @(New-FintaFunz 22 'pronto')
                    $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'conflitti'; BuildId = 58; UrlLog = $null; UltimoCommit = 'c1' }
                    Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura) }
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 22 -and $Testo -eq '[smistatore] Allinea-develop @c1 -> Bug 400' }
                }

                It 'la CI verde azzera i giri del responsabile per la CI rossa (ciRosseDiFila)' {
                    $global:Fx.StatoChiusura = (St 'pronto')
                    $global:Mondo.Cards = @(New-FintaFunz 22 'pronto')
                    $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null; UltimoCommit = 'c1' }
                    Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ ciRosseDiFila = 2 }) }
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    (Get-StatoFinale $script:Dati)['22']['ciRosseDiFila'] | Should -Be 0
                }

                It 'PR ancora in conflitto al giro dopo (stesso commit): non crea una seconda Bug' {
                    $global:Fx.StatoChiusura = (St 'pronto')
                    $global:Mondo.Cards = @(New-FintaFunz 22 'pronto')
                    $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'active'; Validazione = 'conflitti'; BuildId = 58; UrlLog = $null; UltimoCommit = 'c1' }
                    Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura) }
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke New-CardAllineaDevelop -Times 1 -Exactly
                }

                It 'dev di una card con il tag allinea-develop parte con un messaggio che lo dice; una card qualunque no' {
                    $global:CartellaWt = $script:CartellaOk
                    $c = New-FintaFunz 5 'pronto'; $c.Tag = @('agents', 'allinea-develop')
                    $global:Fx.Ramo = 'feature/f7-la-funzione'; $global:Fx.Feature = 'Active'
                    $global:Mondo.Cards = @($c)
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Messaggio -like '*allinea-develop*origin/develop*' }
                }

                It 'dev di una card senza il tag allinea-develop non riceve la riga' {
                    $global:CartellaWt = $script:CartellaOk
                    $global:Fx.Ramo = 'feature/f7-la-funzione'; $global:Fx.Feature = 'Active'
                    $global:Mondo.Cards = @(New-FintaFunz 5 'pronto')
                    Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                    Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Messaggio -notlike '*allinea-develop*' }
                }
            }

            It 'Ready to release con il worktree in sola lettura: lo toglie (Remove-WorktreeCard) e tiene il ramo salvato, che serve a leggere la PR' {
                $global:Fx.Ramo = $null; $global:Fx.Feature = 'Resolved'; $global:Fx.StatoChiusura = (St 'daRilasciare')
                $global:Mondo.Cards = @(New-FintaFunz 22 'daRilasciare')
                $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null; UltimoCommit = 'c1' }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ prId = 9; featureDaChiudere = 7; cartella = 'C:/wt/Acme.AI/card-22' }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Remove-WorktreeCard -Times 1 -Exactly -ParameterFilter { $Id -eq 22 -and $Ramo -eq 'feature/f7-la-funzione' -and $Cartella -eq 'C:/wt/Acme.AI/card-22' }
                $st = (Get-StatoFinale $script:Dati)['22']
                $st['cartella'] | Should -BeNullOrEmpty
                $st['ramo'] | Should -Be 'feature/f7-la-funzione'
            }

            It 'Ready to release con la PR completata e il ramo della funzionalita cancellato dal merge: niente worktree da togliere, niente errori, niente on-hold' {
                $global:Fx.Ramo = $null; $global:Fx.Feature = 'Resolved'; $global:Fx.StatoChiusura = (St 'daRilasciare')
                $global:Mondo.Cards = @(New-FintaFunz 22 'daRilasciare')
                $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null; UltimoCommit = 'c1' }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ prId = 9; featureDaChiudere = 7 }) }
                $out = Invoke-Giro $script:Dati @{ Radice = $script:RadiceF }
                Should -Invoke Remove-WorktreeCard -Times 0 -Exactly
                Should -Invoke New-WorktreeDaRemoto -Times 0 -Exactly
                Should -Invoke Set-AdoCard -Times 0 -Exactly
                Should -Invoke Set-AdoStatoFeature -Times 0 -Exactly
                $log = Join-Path $script:Dati 'log'
                $testo = if (Test-Path $log) { (Get-ChildItem $log -Filter 'smistatore-*.log' | Get-Content -Raw) } else { '' }
                $testo | Should -Not -Match 'ERRORE|WARN'
            }

            It 'Feature Closed: con la card di chiusura Closed (non piu fra le attive) la Feature si chiude e esce dall elenco' {
                $closed = New-FintaCard 22 'chiusa'
                $global:Mondo.Cards = @()
                Mock Get-AdoCard { param($Id) if ($Id -eq 22) { $closed } }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ prId = 9; featureDaChiudere = 7 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Get-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 22 }
                Should -Invoke Set-AdoStatoFeature -Times 1 -Exactly -ParameterFilter { $FeatureId -eq 7 -and $Stato -eq 'Closed' }
                (Get-StatoFinale $script:Dati)['22']['featureDaChiudere'] | Should -BeNullOrEmpty
                # il giro dopo non legge piu niente
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Get-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 22 }
            }

            It 'Feature Closed: una card di chiusura ne Closed ne attiva (Draft) lascia una riga di log, una volta sola, e il ricordo resta' {
                $bozza = New-FintaCard 22 'bozza'
                $global:Mondo.Cards = @()
                Mock Get-AdoCard { param($Id) if ($Id -eq 22) { $bozza } }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ featureDaChiudere = 7 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                $log = Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw
                ([regex]::Matches($log, 'card 22: .*Draft.*Feature 7')).Count | Should -Be 1
                Should -Invoke Set-AdoStatoFeature -Times 0 -Exactly
                (Get-StatoFinale $script:Dati)['22']['featureDaChiudere'] | Should -Be 7
            }

            It 'Feature Closed: una Feature gia Removed non si rimette Closed, e smette di aspettare' {
                $closed = New-FintaCard 22 'chiusa'
                $global:Fx.Feature = 'Removed'
                $global:Mondo.Cards = @()
                Mock Get-AdoCard { param($Id) if ($Id -eq 22) { $closed } }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ featureDaChiudere = 7 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Set-AdoStatoFeature -Times 0 -Exactly
                (Get-StatoFinale $script:Dati)['22']['featureDaChiudere'] | Should -BeNullOrEmpty
            }

            It 'Feature Closed: una Feature gia Closed non si riscrive, e smette di aspettare' {
                $closed = New-FintaCard 22 'chiusa'
                $global:Fx.Feature = 'Closed'
                $global:Mondo.Cards = @()
                Mock Get-AdoCard { param($Id) if ($Id -eq 22) { $closed } }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ featureDaChiudere = 7 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Set-AdoStatoFeature -Times 0 -Exactly
                (Get-StatoFinale $script:Dati)['22']['featureDaChiudere'] | Should -BeNullOrEmpty
            }

            It 'Ready to release senza stato locale (presa in carico): il ramo e la PR si prendono dalla PR collegata, e il giro dopo la Feature passa Resolved e nasce featureDaChiudere' {
                Mock Get-AdoPrCollegata { [pscustomobject]@{ Id = 9; Stato = 'completed'; Ramo = 'feature/f7-la-funzione'; Progetto = 'P'; Repo = 'R'; Titolo = 't' } }
                $global:Fx.Ramo = $null; $global:Fx.Feature = 'Active'; $global:Fx.StatoChiusura = (St 'daRilasciare')
                $global:Mondo.Cards = @(New-FintaFunz 22 'daRilasciare')
                $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null; UltimoCommit = 'c1' }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                $st = (Get-StatoFinale $script:Dati)['22']
                $st['ramo'] | Should -Be 'feature/f7-la-funzione'
                $st['destinazione'] | Should -Be 'develop'
                $st['cartella'] | Should -BeNullOrEmpty
                Should -Invoke New-WorktreeDaRemoto -Times 0 -Exactly
                Should -Invoke Set-AdoStatoFeature -Times 0 -Exactly
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Set-AdoStatoFeature -Times 1 -Exactly -ParameterFilter { $FeatureId -eq 7 -and $Stato -eq 'Resolved' }
                (Get-StatoFinale $script:Dati)['22']['featureDaChiudere'] | Should -Be 7
            }

            It 'Feature Closed: se la card di chiusura e ancora fra le attive (Ready to release) non si legge niente in piu e la Feature resta Resolved' {
                $global:Fx.Feature = 'Resolved'; $global:Fx.StatoChiusura = (St 'daRilasciare')
                $global:Mondo.Cards = @(New-FintaFunz 22 'daRilasciare')
                $global:Mondo.Pr['feature/f7-la-funzione'] = [pscustomobject]@{ Id = 9; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null; UltimoCommit = 'c1' }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ prId = 9; featureDaChiudere = 7 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Get-AdoCard -Times 0 -Exactly
                Should -Invoke Set-AdoStatoFeature -Times 0 -Exactly
                (Get-StatoFinale $script:Dati)['22']['featureDaChiudere'] | Should -Be 7
            }

            It 'Feature Closed: una card di chiusura Removed smette di aspettare la chiusura senza chiudere la Feature' {
                $rimossa = New-FintaCard 22 'rimossa'
                $global:Mondo.Cards = @()
                Mock Get-AdoCard { param($Id) if ($Id -eq 22) { $rimossa } }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ featureDaChiudere = 7 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Set-AdoStatoFeature -Times 0 -Exactly
                (Get-StatoFinale $script:Dati)['22']['featureDaChiudere'] | Should -BeNullOrEmpty
            }

            It 'Feature Closed: in -WhatIf non scrive niente' {
                $closed = New-FintaCard 22 'chiusa'
                $global:Mondo.Cards = @()
                Mock Get-AdoCard { param($Id) if ($Id -eq 22) { $closed } }
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ featureDaChiudere = 7 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF; WhatIf = $true } | Out-Null
                Should -Invoke Set-AdoStatoFeature -Times 0 -Exactly
                (Get-StatoFinale $script:Dati)['22']['featureDaChiudere'] | Should -Be 7
            }

            It 'la card di chiusura ceduta a un altro non prova a togliere un worktree: lo stato si dimentica e basta' {
                $c = New-FintaFunz 22 'inCollaudo'; $c.AssegnataA = [pscustomobject]@{ Id = 'u-altro'; Nome = 'Un collega' }
                $global:Mondo.Cards = @($c)
                Set-StatoDiPartenza $script:Dati @{ '22' = (& $script:StatoChiusura @{ prId = 9 }) }
                Invoke-Giro $script:Dati @{ Radice = $script:RadiceF } | Out-Null
                Should -Invoke Remove-WorktreeCard -Times 0 -Exactly
                (Get-StatoFinale $script:Dati).ContainsKey('22') | Should -BeFalse
            }
        }
    }
}

Describe 'Smistatore: ultimoCommento' {
    BeforeEach {
        $script:Dati = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:Dati | Out-Null
        $global:Mondo = @{ Cards = @(); Commenti = @{}; Storia = @{}; Pr = @{}; Run = @{}; Esiti = @{}; Task = @{} }
        Mock Get-AdoUtenteCorrente { [pscustomobject]@{ Id = 'u-ric'; Nome = 'Titolare' } }
        Mock Get-AdoCardAttive { @($global:Mondo.Cards | ForEach-Object { if (-not $_.PSObject.Properties['PadreId']) { $_ | Add-Member -NotePropertyName PadreId -NotePropertyValue 1 }; $_ }) }; Mock Get-AdoFeatureAperte { @([pscustomobject]@{ Id = 1; Titolo = 'Raggruppa'; Stato = 'Active'; Tag = @(); Area = 'x'; Rank = $null }) }; Mock Get-AdoFeature { [pscustomobject]@{ Id = 1; Tipo = 'Feature'; Titolo = 'Raggruppa'; Stato = 'Active'; Tag = @(); Area = 'x'; FigliIds = @() } } -ParameterFilter { $Id -eq 1 }; Mock Get-AdoFigliFeature { @() } -ParameterFilter { @($FigliIds).Count -eq 0 }
        Mock Get-AdoCard { param($Id) $global:Mondo.Cards | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
        Mock Get-AdoCommenti { param($Id, $DopoId = 0) @($global:Mondo.Commenti["$Id"] | Where-Object { $null -ne $_ -and $_.Id -gt $DopoId }) }
        Mock Get-AdoStoriaStato { param($Id) @($global:Mondo.Storia["$Id"]) }
        Mock Get-AdoTaskFigli { param($CardId) @($global:Mondo.Task["$CardId"] | Where-Object { $null -ne $_ }) }
        Mock Get-AdoCardPredecessori { param($CardId) if ($global:Mondo.ContainsKey('Predecessori')) { @($global:Mondo.Predecessori["$CardId"] | Where-Object { $null -ne $_ }) } else { @() } }
        Mock Get-AdoPr { $null }
        Mock Get-AdoRun { $null }
        Mock Set-AdoCard { 55 }
        Mock Add-AdoCommento { 900 }
        Mock Start-SessioneRuolo { [pscustomobject]@{ Id = 'sid-nuova'; Pid = 5151; Avvio = '2026-11-16T09:00:00.0000000Z'; Ripresa = $false } }
        Mock Get-EsitoSessione { param($Id) $global:Mondo.Esiti[$Id] }
        Mock Stop-Sessione { }
        Mock New-WorktreeCard { [pscustomobject]@{ Cartella = $global:CartellaWt; Ramo = 'feature/5-titolo-della-card' } }
        Mock Remove-WorktreeCard { [pscustomobject]@{ RamoCancellato = $true } }
        Mock Start-AdoDeployTest { 555 }
        Mock Get-AdoParametriDeploy { param($Progetto, $PipelineId, $Ramo) @($global:Mondo.ParametriDeploy) }
        Mock Complete-AdoPr { }
        Mock Test-SessioneViva { $true }
        Mock Send-TelegramAvviso { $true }
        $global:Mondo.Cards = @(New-FintaCard 5 'daChiarire')
        $global:Mondo.Storia['5'] = New-FintaStoria 'daChiarire'
    }

    It 'avanza quando una sessione e stata lanciata sulla card' {
        $global:Mondo.Commenti['5'] = @(
            [pscustomobject]@{ Id = 11; Autore = 'Mario'; Testo = 'Ecco la risposta'; Quando = '2026-11-01T10:00:00Z' }
            [pscustomobject]@{ Id = 12; Autore = 'Mario'; Testo = 'e un altra cosa'; Quando = '2026-11-01T10:01:00Z' })
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'responsabile' -and $Messaggio -match 'Motivo: commento' }
        (Get-StatoFinale $script:Dati)['5']['ultimoCommento'] | Should -Be 12
    }

    It 'avanza quando i commenti nuovi sono tutti di agenti' {
        $global:Mondo.Commenti['5'] = @(
            [pscustomobject]@{ Id = 11; Autore = 'Titolare'; Testo = '[responsabile] Domanda aperta'; Quando = '2026-11-01T10:00:00Z' }
            [pscustomobject]@{ Id = 13; Autore = 'Titolare'; Testo = '[smistatore] Sessione avviata'; Quando = '2026-11-01T10:01:00Z' })
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        (Get-StatoFinale $script:Dati)['5']['ultimoCommento'] | Should -Be 13
    }

    It 'NON avanza se un limite blocca l azione: il commento di una persona resta nuovo' {
        $global:Mondo.Commenti['5'] = @([pscustomobject]@{ Id = 11; Autore = 'Mario'; Testo = 'Ecco la risposta'; Quando = '2026-11-01T10:00:00Z' })
        # un altra card ha gia la sessione attiva e il limite e 1: limite di sessioni raggiunto
        $radice = New-RadiceDiProva -Cartella $TestDrive -Limiti @{ sessioniAttive = 1 }
        Set-StatoDiPartenza $script:Dati @{ '9' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-altra'); ultimoRuolo = 'dev' } }
        $global:Mondo.Cards += New-FintaCard 9 'inSviluppo'
        $global:Mondo.Storia['9'] = New-FintaStoria 'inSviluppo'
        $global:Mondo.Esiti['sid-altra'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-1))
        Invoke-Giro $script:Dati @{ Radice = $radice } | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        $s = Get-StatoFinale $script:Dati
        $s['5']['ultimoCommento'] | Should -Be 0
        # liberato il posto, al giro dopo il commento e ancora nuovo e parte la sessione
        $global:Mondo.Esiti['sid-altra'] = New-FintoEsito $true 'fatto'
        Invoke-Giro $script:Dati @{ Radice = $radice } | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Card -eq 5 }
        (Get-StatoFinale $script:Dati)['5']['ultimoCommento'] | Should -Be 11
    }
}

Describe 'Smistatore: avvisi' {
    BeforeEach {
        $script:Dati = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:Dati | Out-Null
        $global:Mondo = @{ Cards = @(); Commenti = @{}; Storia = @{}; Pr = @{}; Run = @{}; Esiti = @{}; Task = @{} }
        Mock Get-AdoUtenteCorrente { [pscustomobject]@{ Id = 'u-ric'; Nome = 'Titolare' } }
        Mock Get-AdoCardAttive { @($global:Mondo.Cards | ForEach-Object { if (-not $_.PSObject.Properties['PadreId']) { $_ | Add-Member -NotePropertyName PadreId -NotePropertyValue 1 }; $_ }) }; Mock Get-AdoFeatureAperte { @([pscustomobject]@{ Id = 1; Titolo = 'Raggruppa'; Stato = 'Active'; Tag = @(); Area = 'x'; Rank = $null }) }; Mock Get-AdoFeature { [pscustomobject]@{ Id = 1; Tipo = 'Feature'; Titolo = 'Raggruppa'; Stato = 'Active'; Tag = @(); Area = 'x'; FigliIds = @() } } -ParameterFilter { $Id -eq 1 }; Mock Get-AdoFigliFeature { @() } -ParameterFilter { @($FigliIds).Count -eq 0 }
        Mock Get-AdoCard { param($Id) $global:Mondo.Cards | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
        Mock Get-AdoCommenti { @() }
        Mock Get-AdoStoriaStato { param($Id) @($global:Mondo.Storia["$Id"]) }
        Mock Get-AdoTaskFigli { param($CardId) @($global:Mondo.Task["$CardId"] | Where-Object { $null -ne $_ }) }
        Mock Get-AdoCardPredecessori { param($CardId) if ($global:Mondo.ContainsKey('Predecessori')) { @($global:Mondo.Predecessori["$CardId"] | Where-Object { $null -ne $_ }) } else { @() } }
        Mock Get-AdoPr { $null }
        Mock Get-AdoRun { param($Progetto, $RunId) $global:Mondo.Run["$RunId"] }
        Mock Set-AdoCard { 55 }
        Mock Add-AdoCommento { 900 }
        Mock Start-SessioneRuolo { [pscustomobject]@{ Id = 'sid-nuova'; Pid = 5151; Avvio = '2026-11-16T09:00:00.0000000Z'; Ripresa = $false } }
        Mock Get-EsitoSessione { $null }
        Mock Stop-Sessione { }
        Mock New-WorktreeCard { [pscustomobject]@{ Cartella = $global:CartellaWt; Ramo = 'feature/5-titolo-della-card' } }
        Mock Remove-WorktreeCard { [pscustomobject]@{ RamoCancellato = $true } }
        Mock Start-AdoDeployTest { 555 }
        Mock Get-AdoParametriDeploy { param($Progetto, $PipelineId, $Ramo) @($global:Mondo.ParametriDeploy) }
        Mock Complete-AdoPr { }
        Mock Test-SessioneViva { $true }
        Mock Send-TelegramAvviso { $true }
        # Human test, deploy riuscito, card con prova umana: Avvisa il richiedente che puo provare
        $global:Mondo.Cards = @(New-FintaCard 5 'inProvaUmana' -Tag @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagProvaUmana))
        $global:Mondo.Storia['5'] = New-FintaStoria 'inProvaUmana'
        $global:Mondo.Run['300'] = [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded' }
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ prId = 9; runId = 300; runDopoRev = 20; ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z'; testo = 'ok' } } } }
    }

    It 'Avvisa: commento [smistatore] con menzione e avviso segnato, una volta sola, senza Telegram' {
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match '^\[smistatore\]' -and $Menziona -eq 'u-rich' }
        @((Get-StatoFinale $script:Dati)['5']['avvisi']) | Should -Contain 'testPronto@20'
        # al giro dopo l avviso non si ripete
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Add-AdoCommento -Times 1 -Exactly
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 0 -Exactly
    }

    It 'D42: la prima attesa lancia il responsabile e ricorda cosa ha evitato: nessun on-hold' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ prId = 9; giriRevisione = 2; ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'bloccante'; fine = '2026-11-01T10:00:00Z'; testo = 'rilievi' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'responsabile' -and $Allegato -match 'troppi giri di revisione' -and $Allegato -match 'rilievi' }
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag -contains 'on-hold' }
        $sc = (Get-StatoFinale $script:Dati)['5']
        $sc['attesaInEsame']['per'] | Should -Be 'limite'
        $sc['attesaInEsame']['ruolo'] | Should -Be 'reviewer'
        $sc['attesaInEsame']['motivo'] | Should -Match 'troppi giri di revisione'
        $sc['attesaInEsame']['chiave'] | Should -Be 'troppi giri di revisione'
        @($sc['passateFatte']) | Should -Be @('troppi giri di revisione')
        $sc['ultimaSessione']['responsabile']['motivo'] | Should -Be 'attesa'
    }

    It 'D42: se il responsabile della passata non parte la passata non conta: al giro dopo riparte' {
        Mock Start-SessioneRuolo { throw 'claude non trovato' } -ParameterFilter { $Ruolo -eq 'responsabile' }
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ prId = 9; giriRevisione = 2; passateFatte = @('un altra attesa'); ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'bloccante'; fine = '2026-11-01T10:00:00Z'; testo = 'rilievi' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Testo -match 'LanciaSessione e fallita' }
        $sc = (Get-StatoFinale $script:Dati)['5']
        $sc['attesaInEsame'] | Should -BeNullOrEmpty
        @($sc['passateFatte']) | Should -Be @('un altra attesa')
        $sc['ultimoRuolo'] | Should -Be 'reviewer'
    }

    It 'D42: il responsabile chiude bloccato: on-hold con il motivo di prima, il ruolo di prima torna ultimo, la passata resta fatta' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ prId = 9; giriRevisione = 2; passateFatte = @('troppi giri di revisione'); ultimoRuolo = 'responsabile'
            attesaInEsame = @{ motivo = 'troppi giri di revisione'; per = 'limite'; ruolo = 'reviewer'; chiave = 'troppi giri di revisione' }
            ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'bloccante'; fine = '2026-11-01T10:00:00Z'; testo = 'rilievi' }
                responsabile = @{ id = 'r2'; esito = 'bloccato'; fine = '2026-11-01T11:00:00Z'; motivo = 'attesa' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Testo -match 'troppi giri di revisione \(il responsabile ha guardato' -and $Menziona -eq 'u-ric' }
        Should -Invoke Start-SessioneRuolo -Times 0 -Exactly
        $sc = (Get-StatoFinale $script:Dati)['5']
        $sc['inAttesaPer'] | Should -Be 'limite'
        $sc['ultimoRuolo'] | Should -Be 'reviewer'
        $sc['attesaInEsame'] | Should -BeNullOrEmpty
        # l'on-hold non svuota l'elenco: lo svuota la persona quando toglie il tag
        @($sc['passateFatte']) | Should -Be @('troppi giri di revisione')
    }

    It 'D42: la passata chiusa senza un ruolo di prima lascia la card senza ultimo ruolo' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ prId = 9; passateFatte = @('x'); ultimoRuolo = 'responsabile'
            attesaInEsame = @{ motivo = 'x'; per = 'limite'; ruolo = $null; chiave = 'x' }
            ultimaSessione = @{ responsabile = @{ id = 'r2'; esito = 'bloccato'; fine = '2026-11-01T11:00:00Z'; motivo = 'attesa' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        (Get-StatoFinale $script:Dati)['5']['ultimoRuolo'] | Should -BeNullOrEmpty
    }

    It 'D42: la passata finita senza ESITO va in on-hold ma resta aperta: la ripresa la chiude' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ prId = 9; giriRevisione = 2; passateFatte = @('troppi giri di revisione'); ultimoRuolo = 'responsabile'
            attesaInEsame = @{ motivo = 'troppi giri di revisione'; per = 'limite'; ruolo = 'reviewer'; chiave = 'troppi giri di revisione' }
            ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'bloccante'; fine = '2026-11-01T10:00:00Z'; testo = 'rilievi' }
                responsabile = @{ id = 'r2'; esito = $null; fine = '2026-11-01T11:00:00Z'; motivo = 'attesa' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        $sc = (Get-StatoFinale $script:Dati)['5']
        $sc['inAttesaPer'] | Should -Be 'sessione'
        $sc['attesaInEsame']['motivo'] | Should -Be 'troppi giri di revisione'
        # tolto il tag riparte il responsabile, con il motivo della passata
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'responsabile' -and $Riprendi -eq 'r2' }
        $sc = (Get-StatoFinale $script:Dati)['5']
        $sc['sessione']['motivo'] | Should -Be 'attesa'
        $sc['attesaInEsame']['motivo'] | Should -Be 'troppi giri di revisione'
        @($sc['passateFatte']).Count | Should -Be 0
    }

    It 'D42: una persona toglie l on-hold: l elenco delle passate si svuota' {
        $wt = New-Item -ItemType Directory (Join-Path $TestDrive 'wt-d42') -Force
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ inAttesaPer = 'sessione'; passateFatte = @('senzaEsito', 'troppi giri di revisione'); ramo = 'feature/5-x'; cartella = $wt.FullName
            ultimoRuolo = 'dev'; ultimaSessione = @{ dev = @{ id = 'd1'; esito = 'bloccato'; fine = '2026-11-01T10:00:00Z' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and $Riprendi -eq 'd1' -and $Messaggio -match "ha tolto l'on-hold" }
        @((Get-StatoFinale $script:Dati)['5']['passateFatte']).Count | Should -Be 0
    }

    It 'D42: la ripresa dopo il fatto del responsabile dice che il responsabile ha esaminato l attesa, non che una persona ha tolto l on-hold' {
        $wt = New-Item -ItemType Directory (Join-Path $TestDrive 'wt-d42') -Force
        Mock Get-ImprontaWorktree { @{ ramo = 'feature/5-x'; testa = 'aaa1111aaa'; stato = ''; diff = '' } }
        $global:Mondo.Cards = @(New-FintaCard 5 'inCollaudo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ prId = 9; passateFatte = @('il collaudatore non riesce a provare: il suo resoconto e nel commento sulla card'); ultimoRuolo = 'responsabile'
            ramo = 'feature/5-x'; cartella = $wt.FullName
            attesaInEsame = @{ motivo = 'il collaudatore non riesce a provare: il suo resoconto e nel commento sulla card'; per = 'sessione'; ruolo = 'collaudatore'; chiave = 'il collaudatore non riesce a provare: il suo resoconto e nel commento sulla card' }
            ultimaSessione = @{ collaudatore = @{ id = 'c1'; esito = 'bloccato'; inizio = '2026-11-01T09:30:00Z'; fine = '2026-11-01T10:00:00Z'; motivo = 'collaudo' }
                responsabile = @{ id = 'r2'; esito = 'fatto'; fine = '2026-11-01T11:00:00Z'; motivo = 'attesa' } } } }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter {
            $Ruolo -eq 'collaudatore' -and $Riprendi -eq 'c1' -and $Messaggio -match 'responsabile ha esaminato' -and $Messaggio -match 'commento' -and $Messaggio -notmatch "ha tolto l'on-hold"
        }
        $sc = (Get-StatoFinale $script:Dati)['5']
        $sc['attesaInEsame'] | Should -BeNullOrEmpty
        $sc['ultimoRuolo'] | Should -Be 'collaudatore'
    }

    It 'MettiInAttesa non manda Telegram: restano il commento con la menzione e la riga di log' {
        # reviewer bloccante con giriRevisione al limite
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ prId = 9; giriRevisione = 2; passateFatte = @('troppi giri di revisione'); ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'bloccante'; fine = '2026-11-01T10:00:00Z'; testo = 'rilievi' } } } }   # passata del responsabile gia fatta
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Testo -match '^\[smistatore\]' -and $Testo -match 'revisione' -and $Menziona -eq 'u-ric' }
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
        (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'card 5: on-hold: .*revisione.*\(per limite\)'
        (Get-StatoFinale $script:Dati)['5']['inAttesaPer'] | Should -Be 'limite'
    }
}

Describe 'Smistatore: sessioni morte, orfane e comportamenti di contorno' {
    BeforeEach {
        $script:Dati = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:Dati | Out-Null
        $global:Mondo = @{ Cards = @(); Commenti = @{}; Storia = @{}; Pr = @{}; Run = @{}; Esiti = @{}; Attive = $null; Task = @{} }
        Mock Get-AdoUtenteCorrente { [pscustomobject]@{ Id = 'u-ric'; Nome = 'Titolare' } }
        Mock Get-AdoCardAttive { if ($null -ne $global:Mondo.Attive) { @($global:Mondo.Attive | ForEach-Object { if (-not $_.PSObject.Properties['PadreId']) { $_ | Add-Member -NotePropertyName PadreId -NotePropertyValue 1 }; $_ }) } else { @($global:Mondo.Cards | ForEach-Object { if (-not $_.PSObject.Properties['PadreId']) { $_ | Add-Member -NotePropertyName PadreId -NotePropertyValue 1 }; $_ }) } }; Mock Get-AdoFeatureAperte { @([pscustomobject]@{ Id = 1; Titolo = 'Raggruppa'; Stato = 'Active'; Tag = @(); Area = 'x'; Rank = $null }) }; Mock Get-AdoFeature { [pscustomobject]@{ Id = 1; Tipo = 'Feature'; Titolo = 'Raggruppa'; Stato = 'Active'; Tag = @(); Area = 'x'; FigliIds = @() } } -ParameterFilter { $Id -eq 1 }; Mock Get-AdoFigliFeature { @() } -ParameterFilter { @($FigliIds).Count -eq 0 }
        Mock Get-AdoCard { param($Id) $global:Mondo.Cards | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
        Mock Get-AdoCommenti { param($Id, $DopoId = 0) @($global:Mondo.Commenti["$Id"] | Where-Object { $null -ne $_ -and $_.Id -gt $DopoId }) }
        Mock Get-AdoStoriaStato { param($Id) @($global:Mondo.Storia["$Id"]) }
        Mock Get-AdoTaskFigli { param($CardId) @($global:Mondo.Task["$CardId"] | Where-Object { $null -ne $_ }) }
        Mock Get-AdoCardPredecessori { param($CardId) if ($global:Mondo.ContainsKey('Predecessori')) { @($global:Mondo.Predecessori["$CardId"] | Where-Object { $null -ne $_ }) } else { @() } }
        Mock Get-AdoPr { $null }
        Mock Get-AdoRun { param($Progetto, $RunId) $global:Mondo.Run["$RunId"] }
        Mock Set-AdoCard { 55 }
        Mock Add-AdoCommento { 900 }
        Mock Start-SessioneRuolo { [pscustomobject]@{ Id = 'sid-nuova'; Pid = 5151; Avvio = '2026-11-16T09:00:00.0000000Z'; Ripresa = [bool]$Riprendi } }
        Mock Get-EsitoSessione { param($Id) $global:Mondo.Esiti[$Id] }
        Mock Get-ErroriSessione { 'ultima riga dal file degli errori' }
        Mock Stop-Sessione { }
        Mock New-WorktreeCard { [pscustomobject]@{ Cartella = $global:CartellaWt; Ramo = 'feature/5-titolo-della-card' } }
        Mock Remove-WorktreeCard { [pscustomobject]@{ RamoCancellato = $true } }
        Mock Start-AdoDeployTest { 555 }
        Mock Get-AdoParametriDeploy { param($Progetto, $PipelineId, $Ramo) @($global:Mondo.ParametriDeploy) }
        Mock Complete-AdoPr { }
        Mock Test-SessioneViva { $true }
        Mock Send-TelegramAvviso { $true }
    }

    # I2: un claude che muore senza result
    It 'un processo morto senza result chiude subito la sessione come errore, senza aspettare il silenzio' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        # secondo fermo (ripreseAutomatiche 1): la prima volta non c'e on-hold, la sessione si riprende da sola (D51)
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive; ripreseAutomatiche = 1 } }
        Mock Test-SessioneViva { $false }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-1))   # scritto un minuto fa: non e silenzio
        $out = Invoke-Giro $script:Dati
        Should -Invoke Test-SessioneViva -ParameterFilter { $ProcessoId -eq 4242 -and (ConvertTo-DataUtc $Avvio) -eq (ConvertTo-DataUtc '2026-11-16T08:00:00.0000000Z') }
        Should -Invoke Stop-Sessione -Times 0 -Exactly   # non c'e piu niente da uccidere
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Testo -match '^\[smistatore\]' -and $Testo -match 'dev' -and $Testo -notmatch 'file degli errori' }
        # le righe degli errori vanno nel log, non nel commento
        Should -Invoke Send-TelegramAvviso -Times 0 -Exactly
        (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'ultima riga dal file degli errori'
        $r = (Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl') | ConvertFrom-Json)
        $r.esito | Should -Be 'errore'
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['sessione'] | Should -BeNullOrEmpty
        $s['inAttesaPer'] | Should -Be 'sessione'
        $s['ultimaSessione']['dev']['errore'] | Should -BeTrue
        $s['ultimaSessione']['dev']['id'] | Should -Be 'sid-d'   # ha scritto eventi: la sessione esiste e si puo riprendere
    }

    It 'se la sessione non ha scritto nessun evento non esiste: togliendo il tag ne parte una nuova, non un --resume' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        # secondo fermo: la prima volta non c'e on-hold (D51)
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive; ripreseAutomatiche = 1 } }
        Mock Test-SessioneViva { $false }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $false $null $false $null 'x' 0
        Invoke-Giro $script:Dati | Out-Null
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['sessione'] | Should -BeNullOrEmpty
        $s['ultimaSessione']['dev']['id'] | Should -BeNullOrEmpty
        # Titolare toglie il tag di attesa (la card ora non lo ha): riparte dev, nuova
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Ruolo -eq 'dev' -and -not $Riprendi }
    }

    It 'un processo vivo senza result e senza silenzio non si tocca' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-d'); ultimoRuolo = 'dev'; cartella = $TestDrive } }
        $global:Mondo.Esiti['sid-d'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-1))
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Set-AdoCard -Times 0 -Exactly
        (Get-StatoFinale $script:Dati)['5']['sessione']['id'] | Should -Be 'sid-d'
    }

    # M7: il ripiego sull'inizio quando non c'e il file di uscita
    It 'senza file di uscita il silenzio si conta dall inizio della sessione' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inSviluppo'; New-FintaCard 6 'inSviluppo')
        $global:Mondo.Storia['5'] = New-FintaStoria 'inSviluppo'; $global:Mondo.Storia['6'] = New-FintaStoria 'inSviluppo'
        $vecchia = New-SessioneInCorso 'dev' 'sid-v'; $vecchia['inizio'] = (Get-Date).ToUniversalTime().AddMinutes(-60).ToString('o')
        $recente = New-SessioneInCorso 'dev' 'sid-n'; $recente['inizio'] = (Get-Date).ToUniversalTime().AddMinutes(-2).ToString('o')
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = $vecchia; ultimoRuolo = 'dev' }; '6' = @{ sessione = $recente; ultimoRuolo = 'dev' } }
        $global:Mondo.Esiti['sid-v'] = $null; $global:Mondo.Esiti['sid-n'] = $null
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Stop-Sessione -Times 1 -Exactly
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $AggiungiTag -contains 'on-hold' }
        $s = Get-StatoFinale $script:Dati
        $s['5']['sessione'] | Should -BeNullOrEmpty
        $s['6']['sessione']['id'] | Should -Be 'sid-n'
    }

    # I5: sessioni orfane
    It 'una sessione finita su una card la cui area e uscita dalla mappa si chiude lo stesso: registro con repo nullo e nessuna scrittura sulla card' {
        $global:Mondo.Cards = @(New-FintaCard 8 'inSviluppo' -Area $script:AreaIgnota)
        $global:Mondo.Storia['8'] = New-FintaStoria 'inSviluppo'
        Set-StatoDiPartenza $script:Dati @{ '8' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-o'); ultimoRuolo = 'dev' } }
        $global:Mondo.Esiti['sid-o'] = New-FintoEsito $true 'fatto'
        Invoke-Giro $script:Dati | Out-Null
        $r = (Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl') | ConvertFrom-Json)
        $r.card | Should -Be 8
        $r.repo | Should -BeNullOrEmpty
        $r.esito | Should -Be 'fatto'
        Should -Invoke Set-AdoCard -Times 0 -Exactly
        Should -Invoke Add-AdoCommento -Times 0 -Exactly
        (Get-StatoFinale $script:Dati)['8']['sessione'] | Should -BeNullOrEmpty
    }

    It 'una sessione finita su una card cancellata (404) si chiude lo stesso e libera il posto per le altre' {
        Mock Get-AdoCard { throw 'Chiamata ad Azure DevOps fallita (Get .../workitems/9): 404 Not Found' }
        $global:Mondo.Cards = @(New-FintaCard 5 'nuova')
        $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
        Set-StatoDiPartenza $script:Dati @{ '9' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-x'); ultimoRuolo = 'dev' } }
        $global:Mondo.Esiti['sid-x'] = New-FintoEsito $true 'fatto'
        Invoke-Giro $script:Dati | Out-Null
        $r = (Get-Content (Join-Path $script:Dati 'registro-sessioni.jsonl') | ConvertFrom-Json)
        $r.card | Should -Be 9
        $r.repo | Should -BeNullOrEmpty
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $Id -eq 9 }
        $s = Get-StatoFinale $script:Dati
        $s['9']['sessione'] | Should -BeNullOrEmpty
        # con il limite di una sola sessione attiva, la card 5 ora parte
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly -ParameterFilter { $Card -eq 5 }
    }

    It 'una sessione silenziosa su una card cancellata si chiude: log e stato, niente scritture sulla card' {
        Mock Get-AdoCard { throw '404' }
        $global:Mondo.Cards = @()
        Set-StatoDiPartenza $script:Dati @{ '9' = @{ sessione = (New-SessioneInCorso 'dev' 'sid-x'); ultimoRuolo = 'dev' } }
        $global:Mondo.Esiti['sid-x'] = New-FintoEsito $false $null $false ((Get-Date).ToUniversalTime().AddMinutes(-60))
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Stop-Sessione -Times 1 -Exactly
        Should -Invoke Set-AdoCard -Times 0 -Exactly
        Should -Invoke Add-AdoCommento -Times 0 -Exactly
        (Get-StatoFinale $script:Dati)['9']['sessione'] | Should -BeNullOrEmpty
    }

    # M7: la chiusura di una sessione su una card che non e tra le attive
    It 'una sessione finita su una card fuori dalle attive (letta a parte) si chiude e somma i consumi' {
        $global:Mondo.Cards = @(New-FintaCard 5 'daChiarire' -Tokens 100 -Minuti 5)
        $global:Mondo.Attive = @()
        $global:Mondo.Storia['5'] = New-FintaStoria 'daChiarire'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ sessione = (New-SessioneInCorso); ultimoRuolo = 'responsabile' } }
        $global:Mondo.Esiti['sid-1'] = New-FintoEsito $true 'domande'
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Get-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 }
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Campi['Custom.TotalTokens'] -eq 3710 }
        (Get-StatoFinale $script:Dati)['5']['sessione'] | Should -BeNullOrEmpty
    }

    # M1: il commento "Sessione avviata" che fallisce non mette in on-hold una sessione che lavora
    It 'se il commento Sessione avviata fallisce, la sessione resta in corso e la card non va in on-hold' {
        Mock Add-AdoCommento { throw 'ADO non risponde' } -ParameterFilter { $Testo -match 'Sessione sid-nuova' }
        $global:Mondo.Cards = @(New-FintaCard 5 'nuova')
        $global:Mondo.Storia['5'] = New-FintaStoria 'nuova'
        $out = Invoke-Giro $script:Dati
        Should -Invoke Start-SessioneRuolo -Times 1 -Exactly
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
        (Get-StatoFinale $script:Dati)['5']['sessione']['id'] | Should -Be 'sid-nuova'
        (Get-ChildItem (Join-Path $script:Dati 'log') -Filter 'smistatore-*.log' | Get-Content -Raw) | Should -Match 'ADO non risponde'
    }

    # M7: Avvisa richiedente
    It 'Avvisa richiedente menziona chi ha creato la card; senza creatore, Titolare' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inProvaUmana' -Tag @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagProvaUmana))
        $global:Mondo.Storia['5'] = New-FintaStoria 'inProvaUmana'
        $global:Mondo.Run['300'] = [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded' }
        $stato = @{ prId = 9; ultimoRuolo = 'reviewer'; runId = 300; runDopoRev = 20; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } }
        Set-StatoDiPartenza $script:Dati @{ '5' = $stato }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'deploy in Test e riuscito' -and $Menziona -eq 'u-rich' }
        @((Get-StatoFinale $script:Dati)['5']['avvisi']) | Should -Contain 'testPronto@20'
        # senza creatore
        $c = New-FintaCard 6 'inProvaUmana' -Tag @($script:Cfg.Stati.tagAgenti, $script:Cfg.Stati.tagProvaUmana); $c.CreataDa = $null
        $global:Mondo.Cards = @($c)
        $global:Mondo.Storia['6'] = New-FintaStoria 'inProvaUmana'
        Set-StatoDiPartenza $script:Dati @{ '6' = $stato }
        Invoke-Giro $script:Dati | Out-Null
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 6 -and $Menziona -eq 'u-ric' }
    }
}

Describe 'Smistatore: gli ambienti di collaudo Docker (D59)' {
    BeforeAll {
        # una radice di prova in cui il componente stime ha la voce collaudo
        function New-RadiceCollaudo {
            $r = New-RadiceDiProva -Cartella $TestDrive -Limiti @{ funzionalitaAttive = $true }
            $f = Join-Path $r 'config/mappa.json'
            $m = Get-Content $f -Raw | ConvertFrom-Json
            $m.aree[0] | Add-Member -NotePropertyName collaudo -NotePropertyValue ([pscustomobject]@{ compose = 'collaudo/stime/compose.yaml'; porte = @('WEB', 'API'); url = [pscustomobject]@{ WebApp = 'WEB'; Api = 'API' } })
            $m | ConvertTo-Json -Depth 8 | Set-Content $f
            $r
        }
        function Get-LogGiro($Dati) { (Get-ChildItem (Join-Path $Dati 'log') -Filter 'smistatore-*.log' -ErrorAction SilentlyContinue | Get-Content -Raw) }
    }
    BeforeEach {
        $script:Dati = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:Dati | Out-Null
        $script:CartellaOk = Join-Path $TestDrive 'wt-coll'
        New-Item -ItemType Directory $script:CartellaOk -Force | Out-Null
        $script:RadiceC = New-RadiceCollaudo
        $global:Mondo = @{ Cards = @(); Commenti = @{}; Storia = @{}; Pr = @{}; Run = @{}; Esiti = @{}; Task = @{}; ParametriDeploy = @() }
        Mock Get-AdoUtenteCorrente { [pscustomobject]@{ Id = 'u-ric'; Nome = 'Titolare' } }
        Mock Get-AdoCardAttive { @($global:Mondo.Cards) }
        Mock Get-AdoCard { param($Id) $global:Mondo.Cards | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
        Mock Get-AdoCommenti { param($Id, $DopoId = 0) @($global:Mondo.Commenti["$Id"] | Where-Object { $null -ne $_ -and $_.Id -gt $DopoId }) }
        Mock Get-AdoStoriaStato { param($Id) @($global:Mondo.Storia["$Id"]) }
        Mock Get-AdoTaskFigli { @() }
        Mock Get-AdoCardPredecessori { @() }
        Mock Get-AdoPr { param($Progetto, $Repo, $Ramo, [switch]$AncheCompletate) $global:Mondo.Pr[$Ramo] }
        Mock Get-AdoRun { throw 'un componente con collaudo non ha run di deploy' }
        Mock Set-AdoCard { 55 }
        Mock Add-AdoCommento { 900 }
        Mock Start-SessioneRuolo { [pscustomobject]@{ Id = 'sid-nuova'; Pid = 5151; Avvio = '2026-11-16T09:00:00.0000000Z'; Ripresa = $false } }
        Mock Get-EsitoSessione { $null }
        Mock Stop-Sessione { }
        Mock Start-AdoDeployTest { throw 'non si accoda nessun deploy' }
        Mock Test-SessioneViva { $true }
        Mock Send-TelegramAvviso { $true }
        Mock Get-ImprontaWorktree { @{ ramo = 'x'; testa = 'a'; stato = ''; diff = '' } }
        # docker non si lancia mai: i punti che lo toccano sono sostituiti
        Mock Start-AmbienteCollaudo { [pscustomobject]@{ Progetto = "card-$($Richiesta.Card)"; Pid = 999; Avvio = '2026-11-26T10:00:00.0000000Z'; Log = 'C:\dati\collaudo\log.log'
                Url = [ordered]@{ WebApp = 'http://localhost:21100'; Api = 'http://localhost:21101' } } }
        Mock Remove-AmbienteCollaudo { $true }
        Mock Get-ProgettiCollaudo { @() }
        Mock Get-EsitoAmbienteCollaudo { [pscustomobject]@{ Stato = 'inProgress'; Esito = $null; Log = 'C:\dati\collaudo\card-5.log'; Url = $null } }
        $script:InTestC = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } }
    }

    It 'Deploying to test: crea l ambiente dal worktree della card nello slot 1, salva lo stato e commenta senza accodare nessun deploy' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inDeployTest'); $global:Mondo.Storia['5'] = New-FintaStoria 'inDeployTest'
        Set-StatoDiPartenza $script:Dati @{ '5' = $script:InTestC }
        Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
        Should -Invoke Start-AmbienteCollaudo -Times 1 -Exactly -ParameterFilter {
            $Richiesta.Card -eq 5 -and $Richiesta.Slot -eq 1 -and $Richiesta.Cartella -eq $script:CartellaOk -and $Richiesta.Compose -eq 'collaudo/stime/compose.yaml' -and $Richiesta.FileCredenziali -like '*collaudo*Acme.AI.json' }
        Should -Invoke Start-AdoDeployTest -Times 0 -Exactly
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['collaudoSlot'] | Should -Be 1
        $s['collaudoProgetto'] | Should -Be 'card-5'
        $s['collaudoPid'] | Should -Be 999
        $s['collaudoAvvio'] | Should -Not -BeNullOrEmpty
        $s['runDopoRev'] | Should -Be 20
        $s['collaudoUrl']['WebApp'] | Should -Be 'http://localhost:21100'
        Should -Invoke Add-AdoCommento -Times 1 -Exactly -ParameterFilter { $Id -eq 5 -and $Testo -match 'Ambiente di collaudo in creazione' }
    }

    It 'lo slot e il piu piccolo non usato dalle altre card nello stato' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inDeployTest'); $global:Mondo.Storia['5'] = New-FintaStoria 'inDeployTest'
        Set-StatoDiPartenza $script:Dati @{ '5' = $script:InTestC; '6' = @{ collaudoSlot = 1; collaudoProgetto = 'card-6' }; '7' = @{ collaudoSlot = 3; collaudoProgetto = 'card-7' } }
        Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
        Should -Invoke Start-AmbienteCollaudo -Times 1 -Exactly -ParameterFilter { $Richiesta.Slot -eq 2 }
        (Get-StatoFinale $script:Dati)['5']['collaudoSlot'] | Should -Be 2
    }

    It 'una card che ha gia uno slot lo tiene quando l ambiente si ricrea' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inDeployTest'); $global:Mondo.Storia['5'] = New-FintaStoria 'inDeployTest'
        $st = [hashtable]::new($script:InTestC); $st['collaudoSlot'] = 3; $st['collaudoProgetto'] = 'card-5'; $st['runDopoRev'] = 12
        Set-StatoDiPartenza $script:Dati @{ '5' = $st }
        Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
        Should -Invoke Start-AmbienteCollaudo -Times 1 -Exactly -ParameterFilter { $Richiesta.Slot -eq 3 }
    }

    It 'senza worktree utilizzabile la creazione fallisce e la card va in on-hold (nessun processo avviato)' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inDeployTest'); $global:Mondo.Storia['5'] = New-FintaStoria 'inDeployTest'
        $st = [hashtable]::new($script:InTestC); $st['cartella'] = Join-Path $TestDrive 'non-esiste'
        Set-StatoDiPartenza $script:Dati @{ '5' = $st }
        Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
        Should -Invoke Start-AmbienteCollaudo -Times 0 -Exactly
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $AggiungiTag }
    }

    It 'ambiente pronto: la card passa in Automated test e il commento ha gli URL e i nomi (mai i valori) delle COLLAUDO_*' {
        Mock Get-EsitoAmbienteCollaudo { [pscustomobject]@{ Stato = 'completed'; Esito = 'succeeded'; Log = 'C:\dati\collaudo\card-5.log'; Url = $null } }
        $global:Mondo.Cards = @(New-FintaCard 5 'inDeployTest'); $global:Mondo.Storia['5'] = New-FintaStoria 'inDeployTest'
        $st = [hashtable]::new($script:InTestC); $st['collaudoSlot'] = 1; $st['collaudoProgetto'] = 'card-5'; $st['runDopoRev'] = 20; $st['collaudoPid'] = 999; $st['collaudoAvvio'] = '2026-11-26T10:00:00Z'
        $st['collaudoUrl'] = @{ WebApp = 'http://localhost:21100' }
        Set-StatoDiPartenza $script:Dati @{ '5' = $st }
        Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Stato -eq (St 'inCollaudo') }
        Should -Invoke Add-AdoCommento -Times 1 -ParameterFilter { $Id -eq 5 -and $Testo -match 'WebApp: http://localhost:21100' -and $Testo -match 'COLLAUDO_' -and $Testo -match 'Acme\.AI\.json' }
        Should -Invoke Start-AmbienteCollaudo -Times 0 -Exactly
    }

    It 'ambiente non creato: on-hold con il log nel commento' {
        Mock Get-EsitoAmbienteCollaudo { [pscustomobject]@{ Stato = 'completed'; Esito = 'failed'; Log = 'C:\dati\collaudo\card-5.log'; Url = $null } }
        $global:Mondo.Cards = @(New-FintaCard 5 'inDeployTest'); $global:Mondo.Storia['5'] = New-FintaStoria 'inDeployTest'
        $st = [hashtable]::new($script:InTestC); $st['collaudoSlot'] = 1; $st['collaudoProgetto'] = 'card-5'; $st['runDopoRev'] = 20; $st['collaudoPid'] = 999; $st['collaudoAvvio'] = '2026-11-26T10:00:00Z'
        $st['passateFatte'] = @('deployFallito')
        Set-StatoDiPartenza $script:Dati @{ '5' = $st }
        Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
        Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $AggiungiTag }
        Should -Invoke Add-AdoCommento -Times 1 -ParameterFilter { $Testo -match 'ambiente di collaudo non creato, log: C:\\dati\\collaudo\\card-5\.log' }
    }

    It 'la card che esce dal Test butta l ambiente, azzera i campi e commenta' {
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione'); $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; collaudoSlot = 2; collaudoProgetto = 'card-5'; collaudoPid = 1; runDopoRev = 20; collaudoUrl = @{ WebApp = 'x' } } }
        Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
        Should -Invoke Remove-AmbienteCollaudo -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'card-5' }
        $s = (Get-StatoFinale $script:Dati)['5']
        $s['collaudoSlot'] | Should -BeNullOrEmpty; $s['collaudoProgetto'] | Should -BeNullOrEmpty; $s['collaudoUrl'] | Should -BeNullOrEmpty; $s['runDopoRev'] | Should -BeNullOrEmpty
        Should -Invoke Add-AdoCommento -Times 1 -ParameterFilter { $Id -eq 5 -and $Testo -match 'Ambiente di collaudo buttato' }
    }

    It 'se docker non riesce a buttare l ambiente i campi restano (si riprova al giro dopo) e il giro non va in on-hold' {
        Mock Remove-AmbienteCollaudo { $false }
        $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione'); $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
        Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; collaudoSlot = 2; collaudoProgetto = 'card-5' } }
        $out = Invoke-Giro $script:Dati @{ Radice = $script:RadiceC }
        (Get-StatoFinale $script:Dati)['5']['collaudoProgetto'] | Should -Be 'card-5'
        Should -Invoke Set-AdoCard -Times 0 -Exactly -ParameterFilter { $AggiungiTag }
        $out | Should -Match 'WARN card 5: .*ambiente di collaudo'
    }

    Context 'correzioni: stato senza contenitori, processo di creazione, card ceduta' {
        It 'una card chiusa con un ambiente nello stato ma senza contenitori in docker: lo slot si libera' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione'); $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '40' = @{ collaudoSlot = 2; collaudoProgetto = 'card-40'; collaudoPid = 321; collaudoAvvio = '2026-11-26T10:00:00Z'; runDopoRev = 4; ramo = 'x' } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
            Should -Invoke Remove-AmbienteCollaudo -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'card-40' -and $ProcessoId -eq 321 -and (ConvertTo-DataUtc $Avvio).Hour -eq 10 }
            $s = (Get-StatoFinale $script:Dati)['40']
            $s['collaudoSlot'] | Should -BeNullOrEmpty; $s['collaudoProgetto'] | Should -BeNullOrEmpty
        }
        It 'una card in Test con l ambiente nello stato non e un orfano' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inCollaudo'); $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ collaudoSlot = 1; collaudoProgetto = 'card-5'; ramo = 'x'; cartella = $script:CartellaOk; runDopoRev = 20; ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
            Should -Invoke Remove-AmbienteCollaudo -Times 0 -Exactly
        }
        It 'se docker non butta l ambiente dello stato i campi restano e il giro non fallisce' {
            Mock Remove-AmbienteCollaudo { $false }
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione'); $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '40' = @{ collaudoSlot = 2; collaudoProgetto = 'card-40' } }
            $out = Invoke-Giro $script:Dati @{ Radice = $script:RadiceC }
            (Get-StatoFinale $script:Dati)['40']['collaudoSlot'] | Should -Be 2
            $out | Should -Match 'WARN .*card-40 non buttato'
        }
        It 'la card che esce dal Test ferma il processo di creazione prima del down (pid e avvio dello stato)' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione'); $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = $script:CartellaOk; collaudoSlot = 2; collaudoProgetto = 'card-5'; collaudoPid = 777; collaudoAvvio = '2026-11-26T10:00:00Z' } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
            Should -Invoke Remove-AmbienteCollaudo -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'card-5' -and $ProcessoId -eq 777 -and (ConvertTo-DataUtc $Avvio).Hour -eq 10 }
        }
        It 'una card ceduta a un collega: l ambiente si butta prima di togliere il worktree' {
            $global:OrdineS = [System.Collections.Generic.List[string]]::new()
            Mock Remove-AmbienteCollaudo { $global:OrdineS.Add("ambiente $Progetto"); $true }
            Mock Remove-WorktreeCard { $global:OrdineS.Add('worktree'); [pscustomobject]@{ RamoCancellato = $true } }
            $global:Mondo.Cards = @(New-FintaCard 5 'inCollaudo' -Assegnata 'u-collega'); $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; collaudoSlot = 1; collaudoProgetto = 'card-5' } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
            @($global:OrdineS)[0..1] | Should -Be @('ambiente card-5', 'worktree')
            (Get-StatoFinale $script:Dati).Contains('5') | Should -BeFalse
            Remove-Variable OrdineS -Scope Global
        }
        It 'una card ceduta il cui ambiente non si butta resta segnata come ceduta, con lo slot ancora suo e il worktree al suo posto' {
            Mock Remove-AmbienteCollaudo { $false }
            Mock Remove-WorktreeCard { throw 'non doveva toccarlo' }
            $global:Mondo.Cards = @(New-FintaCard 5 'inCollaudo' -Assegnata 'u-collega'); $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; cartella = 'C:/wt/card-5'; collaudoSlot = 1; collaudoProgetto = 'card-5' } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
            Should -Invoke Remove-WorktreeCard -Times 0 -Exactly
            $s = (Get-StatoFinale $script:Dati)['5']
            $s['ceduta'] | Should -BeTrue; $s['collaudoSlot'] | Should -Be 1
        }
    }

    Context 'orfani' {
        It 'butta i progetti di card che non sono in uno stato di Test (o non esistono piu) e lascia quelli in Test' {
            Mock Get-ProgettiCollaudo { @('card-5', 'card-9', 'card-11') }
            $global:Mondo.Cards = @((New-FintaCard 5 'inCollaudo'), (New-FintaCard 9 'inRevisione'))
            $global:Mondo.Storia['5'] = New-FintaStoria 'inCollaudo'; $global:Mondo.Storia['9'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ collaudoSlot = 1; collaudoProgetto = 'card-5'; ramo = 'x'; cartella = $script:CartellaOk; runDopoRev = 20; ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } }
                '9' = @{ ramo = 'y'; cartella = $script:CartellaOk } }
            $out = Invoke-Giro $script:Dati @{ Radice = $script:RadiceC }
            Should -Invoke Remove-AmbienteCollaudo -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'card-9' }
            Should -Invoke Remove-AmbienteCollaudo -Times 1 -Exactly -ParameterFilter { $Progetto -eq 'card-11' }
            Should -Invoke Remove-AmbienteCollaudo -Times 0 -Exactly -ParameterFilter { $Progetto -eq 'card-5' }
            (Get-LogGiro $script:Dati) | Should -Match 'ambiente di collaudo orfano card-9'
        }
        It 'docker che non risponde non ferma il giro: un avviso nel log e le card avanzano' {
            Mock Get-ProgettiCollaudo { throw 'docker non risponde' }
            $global:Mondo.Cards = @(New-FintaCard 5 'inDeployTest'); $global:Mondo.Storia['5'] = New-FintaStoria 'inDeployTest'
            Set-StatoDiPartenza $script:Dati @{ '5' = $script:InTestC }
            $out = Invoke-Giro $script:Dati @{ Radice = $script:RadiceC }
            $out | Should -Match 'WARN .*orfani.*docker non risponde'
            Should -Invoke Start-AmbienteCollaudo -Times 1 -Exactly
            Should -Invoke Remove-AmbienteCollaudo -Times 0 -Exactly
        }
        It 'senza nessuna voce collaudo nella mappa non chiede niente a docker' {
            $global:Mondo.Cards = @(New-FintaCard 5 'inRevisione'); $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Invoke-Giro $script:Dati @{ Radice = (New-RadiceDiProva -Cartella $TestDrive) } | Out-Null
            Should -Invoke Get-ProgettiCollaudo -Times 0 -Exactly
        }
    }

    Context 'la card di chiusura di una funzionalita (D52)' {
        BeforeEach {
            $global:FxC = @{ InFeature = (St 'inFeature'); InDeployTest = (St 'inDeployTest'); TagChiusura = $script:Cfg.Stati.tagChiusura }
            Mock Get-AdoFeature { [pscustomobject]@{ Id = 7; Tipo = 'Feature'; Titolo = 'La funzione'; Stato = 'Active'; Tag = @(); Area = 'x'; FigliIds = @(5, 22) } }
            Mock Get-AdoFigliFeature { @(
                    [pscustomobject]@{ Id = 5; Stato = $global:FxC.InFeature; Tag = @(); Tipo = 'User Story' }
                    [pscustomobject]@{ Id = 22; Stato = $global:FxC.InDeployTest; Tag = @($global:FxC.TagChiusura); Tipo = 'User Story' }) }
            Mock Get-AdoRamoCard { 'feature/f7-la-funzione' }
            $global:CartellaChiusura = Join-Path $TestDrive 'wt-chiusura'
            New-Item -ItemType Directory $global:CartellaChiusura -Force | Out-Null
            Mock Update-WorktreeChiusura { [pscustomobject]@{ Cartella = $global:CartellaChiusura; Ramo = $null } }
        }
        It 'l ambiente si crea dal worktree della chiusura aggiornato al ramo della funzionalita' {
            $c = New-FintaCard 22 'inDeployTest'; $c | Add-Member -NotePropertyName PadreId -NotePropertyValue 7
            $global:Mondo.Cards = @($c); $global:Mondo.Storia['22'] = New-FintaStoria 'inDeployTest'
            Set-StatoDiPartenza $script:Dati @{ '22' = @{ ramo = 'feature/f7-la-funzione'; destinazione = 'develop'; cartella = $null } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
            Should -Invoke Update-WorktreeChiusura -Times 1 -Exactly -ParameterFilter { $Ramo -eq 'feature/f7-la-funzione' -and $Card.Id -eq 22 }
            Should -Invoke Start-AmbienteCollaudo -Times 1 -Exactly -ParameterFilter { $Richiesta.Card -eq 22 -and $Richiesta.Cartella -eq $global:CartellaChiusura }
        }
        It 'una card figlia della funzionalita con la voce collaudo non crea nessun ambiente: va in Ready to merge come prima' {
            $c = New-FintaCard 5 'inRevisione'; $c | Add-Member -NotePropertyName PadreId -NotePropertyValue 7
            $global:Mondo.Cards = @($c); $global:Mondo.Storia['5'] = New-FintaStoria 'inRevisione'
            Set-StatoDiPartenza $script:Dati @{ '5' = @{ ramo = 'feature/5-x'; destinazione = 'feature/f7-la-funzione'; cartella = $script:CartellaOk; ultimoRuolo = 'reviewer'; ultimaSessione = @{ reviewer = @{ id = 'r1'; esito = 'superata'; fine = '2026-11-01T10:00:00Z' } } } }
            Invoke-Giro $script:Dati @{ Radice = $script:RadiceC } | Out-Null
            Should -Invoke Start-AmbienteCollaudo -Times 0 -Exactly
            Should -Invoke Set-AdoCard -Times 1 -Exactly -ParameterFilter { $Stato -eq (St 'daUnire') }
        }
    }
}

AfterAll { $env:ATTREZZI_DATI = $script:DatiPrimaIsolamento }
