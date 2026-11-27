BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Decisioni.psm1') -Force

    $script:Stati = Get-Content (Join-Path $PSScriptRoot '../config/stati.json') -Raw | ConvertFrom-Json
    $script:Limiti = Get-Content (Join-Path $PSScriptRoot '../config/limiti.json') -Raw | ConvertFrom-Json
    # le sessioni attive che riempiono il limite configurato: i test del limite non dipendono dal suo valore
    $script:AlLimite = [int]$script:Limiti.sessioniAttive

    function script:Nome($chiave) { $script:Stati.$chiave }

    function script:New-Contesto {
        @{
            Stati = $script:Stati; Limiti = $script:Limiti; SessioniAttive = 0
            InSviluppoPerRepo = @{}; InTestPerComponente = @{}; Titolare = 'u-titolare'
            # D60: la Feature padre delle card di prova (PadreId 1), aperta e non in pausa
            Feature = @{ '1' = @{ Rank = $null; Pausa = $false; Titolo = 'Raggruppa' } }
        }
    }

    # Card valida con il tag agents, senza on-hold, senza sessione attiva, nello stato dato. L'ingresso nello stato e'
    # la revisione 7, fatta dal richiedente; Rev della card e' 10.
    function script:New-Ist([string]$Chiave, [string]$Da = 'inRevisione', [string]$Chi = 'u-richiedente') {
        @{
            Card      = [pscustomobject]@{ Id = 100; Rev = 10; Tipo = 'User Story'; Stato = (script:Nome $Chiave); Tag = @($script:Stati.tagAgenti); PadreId = 1 }
            Commenti  = @()
            Storia    = @([pscustomobject]@{ Rev = 7; Da = (script:Nome $Da); A = (script:Nome $Chiave); Chi = $Chi; ChiNome = 'x'; Quando = '2026-11-01T10:00:00Z' })
            Pr        = $null
            Run       = $null
            RevNostre = @()
            Voce      = [pscustomobject]@{ repo = 'Acme.AI'; componente = 'stime'; pipelineDeploy = 115; urlTest = 'https://test.example.invalid/stime' }
            # la scelta del deploy in Test del responsabile (D43) e i parametri deploy* che lo YAML della pipeline ha sul ramo
            Deploy    = @{ Scelta = @('deployStime'); AmmessiLetti = $true; Ammessi = @('deployStime', 'deployDatabases') }
            StatoCard = [ordered]@{
                ultimoCommento = 0; giriRevisione = 0; rosseDiFila = 0; rossaGestita = $null; inAttesaPer = $null
                avvisi = @(); ramo = 'feature/x'; cartella = 'C:/wt/x'; prId = $null; runId = $null; runDopoRev = $null
                sessione = $null; ultimoRuolo = $null; ultimaSessione = @{}
            }
        }
    }

    function script:Set-Stato($i, [string]$Chiave) {
        $i.Card.Stato = script:Nome $Chiave
        $i.Storia[0].A = script:Nome $Chiave
    }

    function script:Set-Sessione($i, [string]$Ruolo, $Esito, [string]$Testo = '', [string]$Fine = '2026-11-02T10:00:00Z', $Task = $null) {
        $i.StatoCard.ultimoRuolo = $Ruolo
        $i.StatoCard.ultimaSessione[$Ruolo] = @{ id = "s-$Ruolo"; fine = $Fine; esito = $Esito; testo = $Testo; task = $Task }
    }

    # I task della card come li porta l'istantanea: id, titolo, stato. Il valore e 'aperto' (nome New di un task appena
    # creato, non e in stati.json perche il codice non lo usa), 'attivo' (taskAttivo), oppure una chiave di stati.json.
    function script:Set-Task($i, [hashtable]$Task) {
        $i.Task = @($Task.GetEnumerator() | Sort-Object Key | ForEach-Object {
            $v = $_.Value; $stato = switch ($v) { 'aperto' { 'New' } 'attivo' { script:Nome 'taskAttivo' } default { script:Nome $v } }
            [pscustomobject]@{ Id = [int]$_.Key; Titolo = "Task $($_.Key)"; Stato = $stato }
        })
    }

    function script:Set-Run($i, [string]$Esito = 'succeeded', [string]$Stato = 'completed') {
        $i.StatoCard.runId = 9; $i.StatoCard.runDopoRev = 7
        $i.Run = [pscustomobject]@{ Stato = $Stato; Esito = $Esito }
    }

    # Deploying to test per gesto di Titolare, con la revisione superata: la base dei casi 21-27. Gli altri stati di Test
    # (Automated test, Human test) si ottengono con Set-Stato: l'ingresso resta la revisione 7.
    function script:New-InTest {
        $i = script:New-Ist 'inDeployTest' 'inRevisione' -Chi 'u-titolare'
        script:Set-Sessione $i 'dev' 'fatto' -Fine '2026-11-02T10:00:00Z'
        script:Set-Sessione $i 'reviewer' 'superata' -Fine '2026-11-03T10:00:00Z'
        $i
    }

    # D42: segna come gia fatta la passata del responsabile per le attese che la card darebbe adesso, con la chiave che
    # Get-Decisione ne ricava: l'on-hold che ne segue e quello di sempre.
    function script:Set-PassataFatta($i, $c = (script:New-Contesto)) {
        $i.StatoCard.passateFatte = @(@(Get-Azioni -Istantanea $i -Contesto $c) | Where-Object { $_.Tipo -eq 'AvviaPassataAttesa' } | ForEach-Object { $_.Chiave })
    }

    # Il mentore (D46) ha i suoi test in fondo: qui si guarda il flusso della card, senza i suoi lanci.
    function script:Senza-Mentore($Azioni) { @(@($Azioni) | Where-Object { $_.Tipo -ne 'LanciaMentore' }) }

    function script:Test-Azioni($Reali, $Attese) {
        $Reali = @(script:Senza-Mentore $Reali)
        $Reali.Count | Should -Be @($Attese).Count -Because "azioni reali: $(($Reali | ForEach-Object { $_.Tipo }) -join ', ')"
        for ($n = 0; $n -lt @($Attese).Count; $n++) {
            foreach ($k in $Attese[$n].Keys) {
                $Reali[$n][$k] | Should -Be $Attese[$n][$k] -Because "azione $n, campo $k"
            }
        }
    }
}

Describe 'Get-Azioni: tabella dei casi' {
    BeforeDiscovery {
        $script:Casi = @(
            @{ N = '1 Draft'; Mod = { param($i, $c) script:Set-Stato $i 'bozza' }; Att = @() }
            @{ N = '2 tag on-hold'; Mod = { param($i, $c) $i.Card.Tag += $script:Stati.tagAttesa }; Att = @() }
            @{ N = '3 sessione attiva'; Mod = { param($i, $c) $i.StatoCard.sessione = @{ id = 's'; ruolo = 'dev'; pid = 1 } }; Att = @() }
            @{ N = '4 New'; Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile' })
               Mod = { param($i, $c) script:Set-Stato $i 'nuova' } }
            @{ N = '5 New, limite di sessioni'; Mod = { param($i, $c) script:Set-Stato $i 'nuova'; $c.SessioniAttive = $script:AlLimite }; Att = @() }
            @{ N = '6 Needs clarification, commento di una persona'; Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile' })
               Mod = { param($i, $c) script:Set-Stato $i 'daChiarire'; $i.Commenti = @([pscustomobject]@{ Id = 1; Autore = 'Anna'; Testo = 'Ecco le risposte' }) } }
            @{ N = '7 Needs clarification, commento [responsabile]'; Att = @()
               Mod = { param($i, $c) script:Set-Stato $i 'daChiarire'; $i.Commenti = @([pscustomobject]@{ Id = 1; Autore = 'Titolare'; Testo = '[responsabile] Ho due domande' }) } }
            @{ N = '8 Ready to develop'
               Att = @(@{ Tipo = 'CreaWorktree' }, @{ Tipo = 'SpostaCard'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev' })
               Mod = { param($i, $c) script:Set-Stato $i 'pronto' } }
            @{ N = '9 Ready to develop, un altro dello stesso repo in sviluppo'; Att = @()
               Mod = { param($i, $c) script:Set-Stato $i 'pronto'; $c.InSviluppoPerRepo = @{ 'Acme.AI' = @(100, 200) } } }
            # i conflitti li risolve dev e li racconta sulla card; una scelta che non sa fare diventa un bivio per responsabile
            @{ N = '10c dev fatto, PR con conflitti verso develop: dev li risolve'; Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'conflitti' })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
                       $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'conflitti'; BuildId = $null; UrlLog = $null } } }
            @{ N = '10d dev ha gia provato a risolvere i conflitti e restano: on-hold'; Att = @(@{ Tipo = 'MettiInAttesa' })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
                       $i.StatoCard.ultimaSessione['dev']['motivo'] = 'conflitti'
                       $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'conflitti'; BuildId = $null; UrlLog = $null } } }
            # D49 (card 11, 20/11): il responsabile, nella passata prima dell'on-hold (D42), riporta la card In development e
            # aggiunge un task. La passata non cambia ultimoRuolo, che resta il collaudatore: la card restava ferma in silenzio.
            @{ N = '10f tornata In development dalla passata del responsabile dopo il collaudo: dev parte sulla sua decisione'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'decisione' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'collaudatore' 'bloccato' '' '2026-11-02T10:00:00Z'
                   $i.StatoCard.ultimaSessione['responsabile'] = @{ id = 's-resp'; fine = '2026-11-02T11:00:00Z'; esito = 'fatto'; motivo = 'attesa'; testo = 'allinea il ramo'; task = $null }
                   script:Set-Task $i @{ 45 = 'aperto' } } }
            @{ N = '10g tornata In development a mano dopo il collaudo, con un task aperto: dev parte sul task'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'taskAggiunto' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'collaudatore' 'bloccato'
                   script:Set-Task $i @{ 45 = 'aperto' } } }
            @{ N = '10h tornata In development dopo il collaudo, senza task e senza indicazioni: on-hold con il motivo'
               Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'collaudatore' 'bloccato' } }
            @{ N = '10 dev fatto, PR assente'; Att = @(@{ Tipo = 'ApriPr' })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto' } }
            @{ N = '11 dev bivio'; Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Allegato = 'Quale libreria?' })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'bivio' 'Quale libreria?' } }
            @{ N = '12 dev bloccato: prima guarda il responsabile (D40)'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Allegato = 'non posso rinominare la PR' })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'bloccato' 'non posso rinominare la PR' } }
            @{ N = '12d dev di nuovo bloccato dopo la decisione su un suo blocco: decide una persona'; Diretta = $true
               Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'sessione' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'
                   $i.StatoCard.ultimaSessione['responsabile'] = @{ id = 's-resp'; fine = '2026-11-02T09:00:00Z'; esito = 'fatto'; motivo = 'bloccato' }
                   script:Set-Sessione $i 'dev' 'bloccato'; $i.StatoCard.ultimaSessione['dev'].motivo = 'decisione' } }
            @{ N = '12f responsabile bloccato su un blocco o un bivio di dev: on-hold diretto, non resta ferma in silenzio'; Diretta = $true
               Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'sessione' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'responsabile' 'bloccato' 'serve un permesso'
                   $i.StatoCard.ultimaSessione['responsabile'].motivo = 'bloccato' } }
            @{ N = '12e dev bloccato dopo una decisione su un bivio: guarda ancora il responsabile'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'
                   $i.StatoCard.ultimaSessione['responsabile'] = @{ id = 's-resp'; fine = '2026-11-02T09:00:00Z'; esito = 'fatto'; motivo = 'bivio' }
                   script:Set-Sessione $i 'dev' 'bloccato'; $i.StatoCard.ultimaSessione['dev'].motivo = 'decisione' } }
            # D38: dev partito per una rossa la giudica instabile (non si riproduce, non c'entra con la card): la validazione
            # si rilancia una volta, poi si segue la PR. Un secondo rilancio lo decide una persona.
            @{ N = '12b dev rilancia dopo una rossa: si rilancia la validazione'; Att = @(@{ Tipo = 'RilanciaValidazione'; Sessione = 's-dev' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'rilancia'; $i.StatoCard.ultimaSessione['dev'].motivo = 'rossa'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 55; UrlLog = 'http://log/55' }
                   $i.StatoCard.rossaGestita = 55; $i.StatoCard.rosseDiFila = 1 } }
            @{ N = '12c rilancio gia fatto per la sessione, validazione in corso: si aspetta'; Att = @()
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'rilancia'; $i.StatoCard.ultimaSessione['dev'].motivo = 'rossa'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'inCorso'; BuildId = 60; UrlLog = 'http://log/60' }
                   $i.StatoCard.rossaGestita = 55; $i.StatoCard.rilanci = 1; $i.StatoCard.rilancioDi = 's-dev' } }
            @{ N = '12d rilancio gia fatto, validazione verde: va dal reviewer'
               Att = @(@{ Tipo = 'SpostaCard'; Stato = 'inRevisione' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'reviewer' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'rilancia'; $i.StatoCard.ultimaSessione['dev'].motivo = 'rossa'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 60; UrlLog = $null }
                   $i.StatoCard.rossaGestita = 55; $i.StatoCard.rilanci = 1; $i.StatoCard.rilancioDi = 's-dev' } }
            @{ N = '12e rilancio gia fatto, rossa di nuovo: riparte dev con la rossa'; Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'rossa' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'rilancia'; $i.StatoCard.ultimaSessione['dev'].motivo = 'rossa'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 60; UrlLog = 'http://log/60' }
                   $i.StatoCard.rossaGestita = 55; $i.StatoCard.rosseDiFila = 1; $i.StatoCard.rilanci = 1; $i.StatoCard.rilancioDi = 's-dev' } }
            @{ N = '12f secondo rilancio chiesto sulla card: on-hold'; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'rilancia'; $i.StatoCard.ultimaSessione['dev'].motivo = 'rossa'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 60; UrlLog = 'http://log/60' }
                   $i.StatoCard.rossaGestita = 60; $i.StatoCard.rilanci = 1; $i.StatoCard.rilancioDi = 's-dev-prima' } }
            @{ N = '12g rilancia da una sessione che non era per una rossa: on-hold'; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'sessione' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'rilancia'; $i.StatoCard.ultimaSessione['dev'].motivo = 'task'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 55; UrlLog = 'http://log/55' } } }
            @{ N = '13 rossa non gestita, rosseDiFila 1'; Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Allegato = 'http://log/55' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 55; UrlLog = 'http://log/55' }
                   $i.StatoCard.rossaGestita = 50; $i.StatoCard.rosseDiFila = 1 } }
            @{ N = '13b rossa gia gestita'; Att = @()
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 55; UrlLog = 'http://log/55' }
                   $i.StatoCard.rossaGestita = 55; $i.StatoCard.rosseDiFila = 1 } }
            @{ N = '14 rossa non gestita, rosseDiFila 3'; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 56; UrlLog = 'http://log/56' }
                   $i.StatoCard.rossaGestita = 55; $i.StatoCard.rosseDiFila = 3 } }
            @{ N = '15 validazione in corso'; Att = @()
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'inCorso'; BuildId = 57; UrlLog = 'http://log/57' } } }
            # D47: una validazione scaduta (develop e cambiato) non e in corso: nessuno la rifarebbe. Qui serve per andare dal
            # reviewer, quindi lo smistatore la rilancia.
            @{ N = '15e validazione scaduta dopo dev: lo smistatore la rilancia'; Att = @(@{ Tipo = 'RilanciaScadute' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'scaduta'; BuildId = 57; UrlLog = 'http://log/57' } } }
            # Contesto.Adesso: l'ora del giro. Una validazione in corso da troppo dopo la fine di dev (fine 2026-11-02T10:00Z)
            # e un segnale che qualcosa non va (build bloccata, esito non letto): un avviso, una volta per sessione di dev.
            @{ N = '15b validazione in corso da 90 minuti dopo la fine di dev: un avviso'
               Att = @(@{ Tipo = 'Avvisa'; Chi = 'titolare'; Chiave = 'validazioneLunga@s-dev' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'; $c.Adesso = '2026-11-02T11:30:00Z'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'inCorso'; BuildId = 57; UrlLog = 'http://log/57' } } }
            @{ N = '15c validazione in corso da 20 minuti: niente'; Att = @()
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'; $c.Adesso = '2026-11-02T10:20:00Z'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'inCorso'; BuildId = 57; UrlLog = 'http://log/57' } } }
            @{ N = '15d validazione lunga, avviso gia mandato per questa sessione di dev: niente'; Att = @()
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'; $c.Adesso = '2026-11-02T11:30:00Z'
                   $i.StatoCard.avvisi = @('validazioneLunga@s-dev')
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'inCorso'; BuildId = 57; UrlLog = 'http://log/57' } } }
            @{ N = '16 validazione verde'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'inRevisione' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'reviewer' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = 'http://log/58' } } }
            @{ N = '17 reviewer bloccante, giriRevisione 1'
               Att = @(@{ Tipo = 'SpostaCard'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Allegato = 'Manca il test' })
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'bloccante' 'Manca il test'; $i.StatoCard.giriRevisione = 1 } }
            @{ N = '18 reviewer bloccante, giriRevisione 2'; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'bloccante' 'Manca il test'; $i.StatoCard.giriRevisione = 2 } }
            # revisione superata: la card passa da sola in Deploying to test, senza avviso e senza aspettare un gesto
            @{ N = '19 reviewer superata: la card passa in Deploying to test'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'inDeployTest' })
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata' } }
            @{ N = '19b reviewer superata, un altra card dello stesso componente e in Test: resta In review'; Att = @()
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'
                       $c.InTestPerComponente = @{ stime = @(200) } } }
            @{ N = '19c reviewer superata, in Test c e un altro componente: passa in Deploying to test'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'inDeployTest' })
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'
                       $c.InTestPerComponente = @{ altro = @(200) } } }
            # niente da provare in Test (tag no-test-deploy, o componente senza deploy in Test): dalla revisione dritti a Ready to merge
            @{ N = '19d reviewer superata con il tag no-test-deploy: dritta in Ready to merge, niente deploy'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'daUnire' })
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'; $i.Card.Tag += $script:Stati.tagSenzaTest } }
            @{ N = '19e reviewer superata, il componente non ha un deploy in Test: dritta in Ready to merge'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'daUnire' })
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'; $i.Voce = [pscustomobject]@{ repo = 'Acme.AI'; componente = 'stime' } } }
            @{ N = '19f reviewer superata con no-test-deploy: il posto in Test occupato da un altra card non conta'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'daUnire' })
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'; $i.Card.Tag += $script:Stati.tagSenzaTest
                       $c.InTestPerComponente = @{ stime = @(200) } } }
            @{ N = '20 reviewer superata ma dev ha rimesso mano al codice dopo: niente'; Att = @()
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'
                       script:Set-Sessione $i 'dev' 'fatto' -Fine '2026-11-04T10:00:00Z' } }
            @{ N = '21 Deploying to test entrata dallo smistatore o da chiunque, nessun run'; Att = @(@{ Tipo = 'AccodaDeployTest'; Rev = 7 })   # Rev: la revisione d'ingresso in Deploying to test, che diventa runDopoRev
               Mod = { param($i, $c) } }
            @{ N = '21 bis Deploying to test con il tag no-test-deploy messo dopo: niente deploy, passa in Ready to merge'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'daUnire' })
               Mod = { param($i, $c) $i.Card.Tag += $script:Stati.tagSenzaTest } }
            @{ N = '22 Deploying to test spostata da un altro utente: si accoda lo stesso il deploy'; Att = @(@{ Tipo = 'AccodaDeployTest'; Rev = 7 })
               Mod = { param($i, $c) $i.Storia[0].Chi = 'u-altro' } }
            @{ N = '23 Deploying to test, revisione non superata: stato precedente'; Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inSviluppo' })
               Mod = { param($i, $c) $i.Storia[0].Da = (script:Nome 'inSviluppo'); script:Set-Sessione $i 'reviewer' 'bloccante' } }
            @{ N = '24 Deploying to test, un altro dello stesso componente in test'; Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inRevisione' })
               Mod = { param($i, $c) $c.InTestPerComponente = @{ stime = @(100, 200) } } }
            # a deploy riuscito la card va dal collaudatore (Automated test) o, con human-test, dalla persona (Human test)
            @{ N = '25 deploy riuscito: la card passa in Automated test'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'inCollaudo' })
               Mod = { param($i, $c) script:Set-Run $i } }
            @{ N = '25 bis deploy riuscito con il tag human-test: la card passa in Human test'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'inProvaUmana' })
               Mod = { param($i, $c) script:Set-Run $i; $i.Card.Tag += $script:Stati.tagProvaUmana } }
            @{ N = '25 bis a deploy in corso si aspetta'; Att = @()
               Mod = { param($i, $c) script:Set-Run $i 'succeeded' 'inProgress' } }
            @{ N = '25 bis b deploy riuscito dopo un ingresso piu recente del run: il run non vale, si riaccoda'; Att = @(@{ Tipo = 'AccodaDeployTest'; Rev = 7 })
               Mod = { param($i, $c) script:Set-Run $i; $i.StatoCard.runDopoRev = 5 } }
            # in Automated test prova un modello (spec, sezione 20)
            @{ N = '25 ter0 Automated test, nessun collaudo: parte il collaudatore, con l indirizzo dell ambiente di Test'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'collaudatore'; Motivo = 'collaudo'; Allegato = 'Ambiente di Test: https://test.example.invalid/stime' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo' } }
            @{ N = '25 ter collaudo superato: la card passa in Ready to merge'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'daUnire' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'superata' 'Tutti i criteri verificati' -Fine '2026-11-04T10:00:00Z' } }
            @{ N = '25 quater collaudo respinto: il resoconto va a responsabile'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'collaudoRespinto'; Allegato = 'Il criterio 2 non e rispettato' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'respinta' 'Il criterio 2 non e rispettato' -Fine '2026-11-04T10:00:00Z' } }
            @{ N = '25 quinquies collaudo respinto per la terza volta: on-hold per limite'; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'respinta' 'ancora' -Fine '2026-11-04T10:00:00Z'; $i.StatoCard.giriCollaudo = 2 } }
            @{ N = '25 sexies collaudatore bloccato (ambiente giu, credenziali mancanti): on-hold, con un motivo corto'
               Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'sessione'; Motivo = 'il collaudatore non riesce a provare: il suo resoconto e nel commento sulla card' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'bloccato' 'Login rifiutato' -Fine '2026-11-04T10:00:00Z' } }
            @{ N = '25 septies responsabile ha letto il collaudo respinto ma la card e ancora In Automated test: on-hold'; Diretta = $true; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'sessione' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'respinta' 'x' -Fine '2026-11-04T10:00:00Z'
                       script:Set-Sessione $i 'responsabile' 'fatto' 'ho creato i task' -Fine '2026-11-04T11:00:00Z'
                       $i.StatoCard.ultimaSessione['responsabile']['motivo'] = 'collaudoRespinto' } }
            # in Human test, dopo una verifica di responsabile su un commento, si aspetta la persona
            @{ N = '25 octies responsabile ha risposto a un commento e lascia la card In Human test: niente'; Att = @()
               Mod = { param($i, $c) script:Set-Stato $i 'inProvaUmana'; $i.StatoCard.avvisi = @('testPronto@7')
                       script:Set-Sessione $i 'responsabile' 'fatto' 'ho chiesto' -Fine '2026-11-04T11:00:00Z'
                       $i.StatoCard.ultimaSessione['responsabile']['motivo'] = 'verificaInTest' } }
            # un esito fuori dalla lista non lascia la card ferma in silenzio
            @{ N = '25 nonies collaudatore con un esito sconosciuto: on-hold con il motivo'; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'sessione' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'superato' 'x' -Fine '2026-11-04T10:00:00Z' } }
            # Human test: l'avviso al richiedente va dato una volta per ingresso, con la revisione d'ingresso nella chiave
            @{ N = '25 decies Human test all ingresso: avviso al richiedente, anche senza il tag human-test'; Att = @(@{ Tipo = 'Avvisa'; Chi = 'richiedente'; Chiave = 'testPronto@7' })
               Mod = { param($i, $c) script:Set-Stato $i 'inProvaUmana' } }
            @{ N = '25 decies bis Human test con l avviso gia dato per questo ingresso: niente'; Att = @()
               Mod = { param($i, $c) script:Set-Stato $i 'inProvaUmana'; $i.StatoCard.avvisi = @('testPronto@7') } }
            @{ N = '25 decies ter Human test con l avviso di un ingresso precedente: si avvisa di nuovo'; Att = @(@{ Tipo = 'Avvisa'; Chiave = 'testPronto@7' })
               Mod = { param($i, $c) script:Set-Stato $i 'inProvaUmana'; $i.StatoCard.avvisi = @('testPronto@3') } }
            # l'esito di un collaudo vale solo per l'ingresso in Automated test in cui e stato fatto
            @{ N = '25 undecies esito di un collaudo di prima del ritorno In Automated test: si rifa il collaudo'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'collaudatore'; Motivo = 'collaudo' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'superata' 'x' -Fine '2026-10-30T10:00:00Z'
                       $i.StatoCard.ultimaSessione['collaudatore']['inizio'] = '2026-10-30T09:00:00Z' } }
            # senza urlTest nella mappa il collaudatore non va a cercarlo nei file di configurazione
            @{ N = '25 duodecies la mappa non ha urlTest: il collaudatore si ferma, non lo cerca nei file del repo'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'collaudatore'; Motivo = 'collaudo' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; $i.Voce = [pscustomobject]@{ repo = 'Acme.AI'; componente = 'stime'; pipelineDeploy = 115 } } }
            # togliere l'on-hold per limite azzera anche i collaudi respinti
            @{ N = '25 terdecies on-hold per troppi collaudi tolto: contatori azzerati, il resoconto va a responsabile'
               Att = @(@{ Tipo = 'AzzeraContatori' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'collaudoRespinto' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'respinta' 'no' -Fine '2026-11-04T10:00:00Z'
                       $i.StatoCard.giriCollaudo = 2; $i.StatoCard.inAttesaPer = 'limite' } }
            # un commento di una persona in Automated test conta piu dell'esito del collaudo: prima responsabile
            @{ N = '25 vicies Automated test con un commento di persona non letto e nessun collaudo: parte responsabile'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'commentoInCollaudo' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; $i.Commenti = @([pscustomobject]@{ Id = 4; Autore = 'Anna'; Testo = 'Manca la colonna Totale' }) } }
            @{ N = '25 vicies bis Automated test, collaudo superato e un commento non letto: prima responsabile, non Ready to merge'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'commentoInCollaudo' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'superata' 'ok' -Fine '2026-11-04T10:00:00Z'
                       $i.Commenti = @([pscustomobject]@{ Id = 4; Autore = 'Anna'; Testo = 'Controlla anche il totale' }) } }
            @{ N = '25 vicies ter responsabile ha letto il commento e non ha trovato niente: vale il collaudo superato'
               Att = @(@{ Tipo = 'SpostaCard'; Stato = 'daUnire' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'superata' 'ok' -Fine '2026-11-04T10:00:00Z'
                       script:Set-Sessione $i 'responsabile' 'fatto' 'nessun difetto' -Fine '2026-11-04T11:00:00Z'
                       $i.StatoCard.ultimaSessione['responsabile']['motivo'] = 'commentoInCollaudo' } }
            @{ N = '25 vicies quater responsabile ha letto il commento e non ha trovato niente: un collaudo respinto va a responsabile con collaudoRespinto'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'collaudoRespinto'; Allegato = 'Il criterio 2 no' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'respinta' 'Il criterio 2 no' -Fine '2026-11-04T10:00:00Z'
                       script:Set-Sessione $i 'responsabile' 'fatto' 'nessun difetto' -Fine '2026-11-04T11:00:00Z'
                       $i.StatoCard.ultimaSessione['responsabile']['motivo'] = 'commentoInCollaudo' } }
            @{ N = '25 vicies quinquies responsabile ha risposto a un commento prima del collaudo: parte il collaudatore, non resta ferma'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'collaudatore'; Motivo = 'collaudo' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'
                       script:Set-Sessione $i 'responsabile' 'fatto' 'risposto' -Fine '2026-11-04T11:00:00Z'
                       $i.StatoCard.ultimaSessione['responsabile']['motivo'] = 'commentoInCollaudo' } }
            @{ N = '25 vicies sexies card portata a mano da Human test ad Automated test dopo verificaInTest: parte il collaudatore, non resta ferma'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'collaudatore'; Motivo = 'collaudo' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'
                       script:Set-Sessione $i 'responsabile' 'fatto' 'ho chiesto' -Fine '2026-11-04T11:00:00Z'
                       $i.StatoCard.ultimaSessione['responsabile']['motivo'] = 'verificaInTest' } }
            # tornata In review per una revisione non piu superata, con la PR verde: riparte reviewer
            @{ N = 'R1 In review dopo il ritorno da Automated test: dev ha finito dopo la revisione e la PR e verde, riparte reviewer'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'reviewer'; Motivo = 'verde' })
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata' -Fine '2026-11-03T10:00:00Z'
                       script:Set-Sessione $i 'dev' 'fatto' -Fine '2026-11-04T10:00:00Z'
                       $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
            # in tutti e tre gli stati: task aggiunto, revisione non piu superata, no-test-deploy
            @{ N = '25 quaterdecies Automated test con un task aggiunto: torna In development'
               Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'taskAggiunto'; Task = 63 })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; script:Set-Task $i @{ 63 = 'aperto' } } }
            @{ N = '25 quindecies Human test con un task aggiunto: torna In development'
               Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'taskAggiunto'; Task = 63 })
               Mod = { param($i, $c) script:Set-Stato $i 'inProvaUmana'; script:Set-Task $i @{ 63 = 'aperto' } } }
            @{ N = '25 sedecies Deploying to test con un task aggiunto: torna In development'
               Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'taskAggiunto'; Task = 63 })
               Mod = { param($i, $c) script:Set-Task $i @{ 63 = 'aperto' } } }
            @{ N = '25 septdecies Automated test, revisione non piu superata: torna In review, non in Deploying to test'
               Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inRevisione' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; $i.Storia[0].Da = (script:Nome 'inDeployTest'); script:Set-Sessione $i 'dev' 'fatto' -Fine '2026-11-04T10:00:00Z' } }
            @{ N = '25 duodevicies Human test, revisione non piu superata: torna In review'
               Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inRevisione' })
               Mod = { param($i, $c) script:Set-Stato $i 'inProvaUmana'; $i.Storia[0].Da = (script:Nome 'inDeployTest'); script:Set-Sessione $i 'dev' 'fatto' -Fine '2026-11-04T10:00:00Z' } }
            @{ N = '25 undevicies Automated test con no-test-deploy messo dopo: passa in Ready to merge'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'daUnire' })
               Mod = { param($i, $c) script:Set-Stato $i 'inCollaudo'; $i.Card.Tag += $script:Stati.tagSenzaTest } }
            @{ N = '26 run fallito'; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'deploy' })
               Mod = { param($i, $c) script:Set-Run $i 'failed' } }
            # togliere l'on-hold dopo un deploy fallito rilancia il deploy: rileggere lo stesso run fallito rimetterebbe l'on-hold
            @{ N = '26 bis on-hold per deploy fallito tolto: si dimentica il run e si riaccoda il deploy'
               Att = @(@{ Tipo = 'AzzeraContatori' }, @{ Tipo = 'AzzeraDeploy' }, @{ Tipo = 'AccodaDeployTest'; Rev = 7 })
               Mod = { param($i, $c) script:Set-Run $i 'failed'; $i.StatoCard.inAttesaPer = 'deploy' } }
            # le card messe in on-hold prima di questa regola hanno inAttesaPer = limite: vale lo stesso, conta il run fallito
            @{ N = '26 ter on-hold per limite tolto con il run fallito: si riaccoda il deploy'
               Att = @(@{ Tipo = 'AzzeraContatori' }, @{ Tipo = 'AzzeraDeploy' }, @{ Tipo = 'AccodaDeployTest'; Rev = 7 })
               Mod = { param($i, $c) script:Set-Run $i 'failed'; $i.StatoCard.inAttesaPer = 'limite' } }
            @{ N = '27 Human test, commento di una persona: verifica del responsabile'; Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'verificaInTest' })
               Mod = { param($i, $c) script:Set-Stato $i 'inProvaUmana'; $i.StatoCard.avvisi = @('testPronto@7'); $i.Commenti = @([pscustomobject]@{ Id = 4; Autore = 'Anna'; Testo = 'Confermo, funziona' }) } }
            # Card 23: la card passava in Ready to release insieme alla richiesta di completamento, e la PR restava aperta
            # per un conflitto. Ora si chiede il completamento e si sposta la card solo quando la PR risulta completata.
            @{ N = '28 Ready to merge, PR aperta: si chiede il completamento, la card resta qui'
               Att = @(@{ Tipo = 'CompletaPr'; Rev = 7 })
               Mod = { param($i, $c) $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
            @{ N = '28b Ready to merge, PR completata: la card passa in Ready to deploy (test) (D61)'
               Att = @(@{ Tipo = 'SpostaCard'; Stato = 'daDeployTest' })
               Mod = { param($i, $c) $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null } } }
            @{ N = '28c Ready to merge, completamento gia chiesto e la PR e ancora aperta: on-hold con il motivo'
               Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
               Mod = { param($i, $c) $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null }
                       $i.StatoCard.completaPr = '3@7' } }
            @{ N = '28d Ready to merge, completamento chiesto in un ingresso precedente: si richiede'
               Att = @(@{ Tipo = 'CompletaPr'; Rev = 7 })
               Mod = { param($i, $c) $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null }
                       $i.StatoCard.completaPr = '3@2' } }
            @{ N = '28e Ready to merge, PR in conflitto con develop: torna In development e dev allinea il ramo'
               Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'conflitti' })
               Mod = { param($i, $c) $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'conflitti'; BuildId = $null; UrlLog = $null } } }
            # D47: al merge le validazioni scadute si rilanciano e si aspetta il verde; prima (collaudo, Test) no, perche
            # develop cambia ancora e scadrebbero di nuovo.
            @{ N = '28f Ready to merge, validazione scaduta: si rilancia, niente completamento'
               Att = @(@{ Tipo = 'RilanciaScadute' })
               Mod = { param($i, $c) $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'scaduta'; BuildId = 58; UrlLog = $null } } }
            @{ N = '28g Ready to merge, validazione in corso: si aspetta, niente completamento'; Att = @()
               Mod = { param($i, $c) $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'inCorso'; BuildId = 58; UrlLog = $null } } }
            @{ N = '29 Ready to merge spostata a mano da un altro utente (salta il Test), PR aperta: stessa cosa'
               Att = @(@{ Tipo = 'CompletaPr' })
               Mod = { param($i, $c) $i.Storia[0].Chi = 'u-altro'
                       $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
            @{ N = '30 Ready to release, PR completata, worktree presente'; Att = @(@{ Tipo = 'RimuoviWorktree' })
               Mod = { param($i, $c) $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'completed'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
            @{ N = '30b Ready to release, PR ancora aperta: nessun CompletaPr, si aspetta'; Att = @()
               Mod = { param($i, $c) $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
            @{ N = '30c Ready to release, PR completata e worktree gia tolto: niente'; Att = @()
               Mod = { param($i, $c) $i.StatoCard.cartella = $null
                       $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'completed'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
            @{ N = '31 ultima sessione finita senza riga ESITO'; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'sessione' })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' $null } }
            @{ N = '32 New, responsabile finito e card ancora in New'; Diretta = $true; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'sessione' })
               Mod = { param($i, $c) script:Set-Stato $i 'nuova'; script:Set-Sessione $i 'responsabile' 'fatto' -Fine '2026-11-01T10:05:00Z' } }
            @{ N = '33 In development, ultima sessione di responsabile fatto'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Allegato = '[responsabile] Decisione: usa la libreria A' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'responsabile' 'fatto' 'testo di sessione'
                   $i.Commenti = @([pscustomobject]@{ Id = 9; Autore = 'Titolare'; Testo = '[responsabile] Decisione: usa la libreria A' }) } }
            @{ N = '34 on-hold tolto, inAttesaPer sessione'; Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Riprendi = $true })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'bloccato'; $i.StatoCard.inAttesaPer = 'sessione' } }
            @{ N = '35 on-hold tolto, inAttesaPer limite: contatori azzerati, poi le azioni normali'
               Att = @(@{ Tipo = 'AzzeraContatori' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Allegato = 'http://log/56' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 56; UrlLog = 'http://log/56' }
                   $i.StatoCard.rossaGestita = 55; $i.StatoCard.rosseDiFila = 3; $i.StatoCard.inAttesaPer = 'limite' } }
            @{ N = '36 Ready to merge, nessuna PR sul ramo: on-hold'; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
               Mod = { param($i, $c) $i.Pr = $null } }
            @{ N = '37 Ready to merge, PR abbandonata: on-hold'; Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
               Mod = { param($i, $c) $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'abandoned'; Validazione = 'assente'; BuildId = $null; UrlLog = $null } } }
            @{ N = '37b Ready to merge con un task aperto: torna In development, dev sul task'
               Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'taskAggiunto' })
               Mod = { param($i, $c) script:Set-Task $i @{ 63 = 'aperto' }
                       $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
        )
        $script:CasiAttesa = @($script:Casi | Where-Object { -not $_.Diretta -and @($_.Att | Where-Object { $_.Tipo -eq 'MettiInAttesa' }).Count -gt 0 })
    }

    # D42: i casi che finiscono in MettiInAttesa si provano due volte. Qui la passata del responsabile e gia stata fatta:
    # l'on-hold e quello di sempre. Sotto, la prima volta. I casi Diretta partono senza passata fatta: vanno dritti
    # alla persona per una ragione loro, che il test fissa.
    It 'caso <N>' -ForEach $script:Casi {
        $i = script:New-Ist 'inSviluppo'
        if ($N -match '^(2[1-7]) ') { $i = script:New-InTest }
        elseif ($N -match '^(28|29|36|37)') { $i = script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare' }
        elseif ($N -match '^30') { $i = script:New-Ist 'daRilasciare' 'daUnire' 'u-titolare' }
        $c = script:New-Contesto
        & $Mod $i $c
        if (-not $Diretta -and @($Att | Where-Object { $_.Tipo -eq 'MettiInAttesa' }).Count -gt 0) { script:Set-PassataFatta $i $c }
        script:Test-Azioni @(Get-Azioni -Istantanea $i -Contesto $c) $Att
    }

    It 'caso <N>: la prima volta passa dal responsabile' -ForEach $script:CasiAttesa {
        $i = script:New-Ist 'inSviluppo'
        if ($N -match '^(2[1-7]) ') { $i = script:New-InTest }
        elseif ($N -match '^(28|29|36|37)') { $i = script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare' }
        elseif ($N -match '^30') { $i = script:New-Ist 'daRilasciare' 'daUnire' 'u-titolare' }
        $c = script:New-Contesto
        & $Mod $i $c
        $att = @($Att | Where-Object { $_.Tipo -eq 'MettiInAttesa' })[0]
        $r = @(Get-Azioni -Istantanea $i -Contesto $c)
        @($r | Where-Object { $_.Tipo -eq 'MettiInAttesa' }).Count | Should -Be 0
        $avvia = @($r | Where-Object { $_.Tipo -eq 'AvviaPassataAttesa' })
        $avvia.Count | Should -Be 1
        "$($avvia[0].Per)" | Should -Be "$($att.Per)"
        $avvia[0].Chiave | Should -Not -BeNullOrEmpty
        $lancio = @($r | Where-Object { $_.Tipo -eq 'LanciaSessione' })
        $lancio.Count | Should -Be 1
        $lancio[0].Ruolo | Should -Be 'responsabile'
        $lancio[0].Motivo | Should -Be 'attesa'
        $lancio[0].Allegato | Should -Match ([regex]::Escape($avvia[0].Motivo))
        $r.IndexOf($avvia[0]) | Should -BeLessThan $r.IndexOf($lancio[0])
    }
}

Describe 'Get-Azioni: oltre la tabella' {
    It 'un run che vale non viene tolto da un altro della stessa componente arrivato dopo' {
        $i = script:New-InTest; script:Set-Run $i 'succeeded' 'inProgress'
        $c = script:New-Contesto; $c.InTestPerComponente = @{ stime = @(100, 200) }
        @(Get-Azioni -Istantanea $i -Contesto $c).Count | Should -Be 0
    }
    It 'un run di una revisione precedente non vale: si accoda di nuovo' {
        $i = script:New-InTest; script:Set-Run $i; $i.StatoCard.runDopoRev = 3
        @((Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Tipo) | Should -Be @('AccodaDeployTest')
    }
    It 'Deploying to test entrata dallo smistatore (revisione in RevNostre): si accoda il deploy, non si riporta indietro' {
        $i = script:New-InTest; $i.RevNostre = @(7)
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        $r.Count | Should -Be 1
        $r[0].Tipo | Should -Be 'AccodaDeployTest'
    }
    It 'la revisione superata decade se dev rimette mano al codice' {
        $i = script:New-InTest; script:Set-Sessione $i 'dev' 'fatto' -Fine '2026-11-04T10:00:00Z'
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        $r[0].Tipo | Should -Be 'RiportaIndietro'
    }
    It 'al limite di sessioni il caso 35 non parte e non azzera niente' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
        $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 56; UrlLog = 'u' }
        $i.StatoCard.rosseDiFila = 3; $i.StatoCard.inAttesaPer = 'limite'
        $c = script:New-Contesto; $c.SessioniAttive = $script:AlLimite
        @(Get-Azioni -Istantanea $i -Contesto $c).Count | Should -Be 0
    }
    It 'la definizione dei tre stati di Test e una sola, in Comune' {
        @(Get-StatiInTest) | Should -Be @('inDeployTest', 'inCollaudo', 'inProvaUmana')
    }
    It 'e pura: non modifica lo StatoCard dell istantanea' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
        $i.StatoCard.rosseDiFila = 3; $i.StatoCard.inAttesaPer = 'limite'
        $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 56; UrlLog = 'u' }
        $null = Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)
        $i.StatoCard.rosseDiFila | Should -Be 3
        $i.StatoCard.inAttesaPer | Should -Be 'limite'
    }
    It 'senza il tag agents non fa nulla, in nessuno stato' {
        foreach ($k in 'nuova', 'pronto', 'inSviluppo', 'inDeployTest', 'inCollaudo', 'inProvaUmana') {
            $i = script:New-Ist $k; $i.Card.Tag = @()
            @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Count | Should -Be 0
        }
    }
    It 'un commento con involucro html e menzione davanti a [dev] non e di una persona' {
        $i = script:New-Ist 'daChiarire'
        $i.Commenti = @([pscustomobject]@{ Id = 1; Autore = 'x'; Testo = '<div><a href="#" data-vss-mention="version:2.0,abc">@</a> [dev] fatto</div>' })
        @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Count | Should -Be 0
    }
    It 'il modulo esporta Get-Azioni, i predecessori in attesa la definizione di commento di una persona e quando leggere il deploy' {
        @((Get-Module Decisioni).ExportedFunctions.Keys | Sort-Object) | Should -Be @('Format-DomandaOperatore', 'Format-MotivoCoda', 'Get-AttesaSciolta', 'Get-AttivitaOperatore', 'Get-Azioni', 'Get-BloccoQuota', 'Get-CampiContatori', 'Get-Decisione', 'Get-FermoPriorita', 'Get-GestoAtteso', 'Get-MappaFeature', 'Get-OrdineCard', 'Get-OrdineFeature', 'Get-OverrideSogliaQuota', 'Get-PredecessoriInAttesa', 'Get-RankRiordino', 'Get-RiepilogoQuota', 'Get-SlotCollaudoLibero', 'Get-Soglia5OreEffettiva', 'Get-SogliaQuotaEffettiva', 'Get-TitoloPr', 'Get-UltimoCommentoDiRuolo', 'Test-CardInPausa', 'Test-CommentoDiPersona', 'Test-DeployDaLeggere', 'Test-OnHoldPerLimite', 'Test-PredecessoreUnito')
    }
}

Describe 'Get-AttivitaOperatore: cosa aspetta da una persona una card che nessun agente prendera' {
    BeforeAll {
        function script:Att($i, $c = $null) {
            if ($null -eq $c) { $c = script:New-Contesto }
            Get-AttivitaOperatore -Istantanea $i -Contesto $c -Decisione (Get-Decisione -Istantanea $i -Contesto $c)
        }
    }
    It 'on-hold: sblocca, con il testo del motivo, e ferma il flusso' {
        $i = script:New-Ist 'inSviluppo'; $i.Card.Tag = @($script:Stati.tagAgenti, $script:Stati.tagAttesa); $i.StatoCard.inAttesaPer = 'limite'
        $r = script:Att $i
        $r.Attivita | Should -Be 'sblocca'; $r.Ferma | Should -BeTrue
        $r.Testo | Should -Be 'in on-hold, togliendo il tag i contatori ripartono da zero'
    }
    It 'Human test con l avviso dato: prova, e ferma il flusso' {
        $i = script:New-InTest; script:Set-Stato $i 'inProvaUmana'; script:Set-Run $i; $i.Card.Tag += $script:Stati.tagProvaUmana; $i.StatoCard.avvisi = @('testPronto@7')
        $r = script:Att $i
        $r.Attivita | Should -Be 'prova'; $r.Ferma | Should -BeTrue
    }
    It 'Human test, avviso dato e un commento di persona: va al responsabile, non e una prova' {
        $i = script:New-InTest; script:Set-Stato $i 'inProvaUmana'; script:Set-Run $i; $i.Card.Tag += $script:Stati.tagProvaUmana; $i.StatoCard.avvisi = @('testPronto@7')
        $i.Commenti = @([pscustomobject]@{ Id = 9; Autore = 'Titolare'; Testo = 'provata, ok' })
        $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
        $d.Azioni[0].Ruolo | Should -Be 'responsabile'
        script:Att $i | Should -BeNullOrEmpty
    }
    It 'Human test con un task aggiunto: va a dev, non e una prova' {
        $i = script:New-InTest; script:Set-Stato $i 'inProvaUmana'; script:Set-Run $i; $i.Card.Tag += $script:Stati.tagProvaUmana; $i.StatoCard.avvisi = @('testPronto@7')
        script:Set-Task $i @{ 61 = 'aperto' }
        $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
        @($d.Azioni | Where-Object { $_.Tipo -eq 'LanciaSessione' })[0].Ruolo | Should -Be 'dev'
        script:Att $i | Should -BeNullOrEmpty
    }
    It 'Da chiarire senza commenti di persona: rispondi; con un commento il responsabile parte e non e piu un tuo gesto' {
        $i = script:New-Ist 'daChiarire'
        $r = script:Att $i
        $r.Attivita | Should -Be 'rispondi'; $r.Ferma | Should -BeTrue
        $i.Commenti = @([pscustomobject]@{ Id = 9; Autore = 'Titolare'; Testo = 'ecco la risposta' })
        script:Att $i | Should -BeNullOrEmpty
    }
    It 'Ready to release: rilascia, che non ferma nessuno' {
        $i = script:New-Ist 'daRilasciare'; $i.StatoCard.prId = 5
        $r = script:Att $i
        $r.Attivita | Should -Be 'rilascia'; $r.Ferma | Should -BeFalse
    }
    It 'D61: Ready to deploy (test): aspetta il deploy di develop, che non ferma nessuno' {
        $i = script:New-Ist 'daDeployTest'; $i.StatoCard.prId = 5
        $r = script:Att $i
        $r.Attivita | Should -Be 'deployTest'; $r.Ferma | Should -BeFalse
    }
    It 'D61: Ready to deploy (test) senza deploy in Test (nessuna pipeline): nessuna attivita, passa da sola' {
        $i = script:New-Ist 'daDeployTest'; $i.StatoCard.prId = 5; $i.Voce = [pscustomobject]@{ repo = 'Acme.AI'; componente = 'stime' }
        script:Att $i | Should -BeNullOrEmpty
    }
    It 'Ready to release con un task aggiunto: torna a dev, non e un rilascio' {
        $i = script:New-Ist 'daRilasciare'; $i.StatoCard.prId = 5; script:Set-Task $i @{ 61 = 'aperto' }
        $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
        @($d.Azioni | Where-Object { $_.Tipo -eq 'LanciaSessione' })[0].Ruolo | Should -Be 'dev'
        script:Att $i | Should -BeNullOrEmpty
    }
    It 'il limite di sessioni lascia la card all agente: nessuna attivita' {
        $c = script:New-Contesto; $c.Limiti = $script:Limiti.PSObject.Copy(); $c.Limiti.sessioniAttive = 1; $c.SessioniAttive = 1; $c.ConSessione = @(7)
        $d = Get-Decisione -Istantanea (script:New-Ist 'nuova') -Contesto $c
        $d.Motivo.Tipo | Should -Be 'limiteSessioni'
        script:Att (script:New-Ist 'nuova') $c | Should -BeNullOrEmpty
    }
    It 'una card senza il tag agents non aspetta niente da te' {
        $i = script:New-Ist 'daRilasciare'; $i.Card.Tag = @()
        script:Att $i | Should -BeNullOrEmpty
    }
}

Describe 'Get-UltimoCommentoDiRuolo' {
    It 'da l ultimo commento firmato dal ruolo come testo semplice, senza menzione ne html' {
        $c = @(
            [pscustomobject]@{ Id = 1; Testo = '<div><a href="#" data-vss-mention="version:2.0,abc">@Titolare</a> [responsabile] Prima domanda?</div>' }
            [pscustomobject]@{ Id = 2; Testo = 'una risposta di persona' }
            [pscustomobject]@{ Id = 3; Testo = '<div>[responsabile] Quale  formato &amp; quale <b>lingua</b>?</div>' }
            [pscustomobject]@{ Id = 4; Testo = '[dev] fatto' })
        Get-UltimoCommentoDiRuolo $c 'responsabile' | Should -Be 'Quale formato & quale lingua?'
    }
    It 'senza commenti del ruolo da null' {
        Get-UltimoCommentoDiRuolo @([pscustomobject]@{ Id = 1; Testo = 'ciao' }) 'responsabile' | Should -BeNullOrEmpty
        Get-UltimoCommentoDiRuolo @() 'responsabile' | Should -BeNullOrEmpty
    }
}

Describe 'Il testo del commento di responsabile e la parte di domande' {
    BeforeAll {
        # un commento come quello della card 11: le domande con le opzioni, poi un registro delle decisioni lungo
        function script:New-CommentoCard11([bool]$ConOpzioni = $true, [bool]$ConDomande = $true) {
            $righe = [System.Collections.Generic.List[string]]::new()
            $righe.Add('[responsabile] Ho letto la card e il codice: prima di scrivere i criteri mi servono quattro risposte.')
            if ($ConDomande) {
                $righe.Add('DOMANDE')
                foreach ($i in 1..4) {
                    $righe.Add("D$i. Domanda numero $i sul formato di export?")
                    if ($ConOpzioni) { $righe.Add("a) opzione A della D$i"); $righe.Add("b) opzione B della D$i") }
                }
            }
            $righe.Add('REGISTRO DELLE DECISIONI')
            foreach ($i in 1..40) { $righe.Add("Decisione ${i}: scelto il comportamento standard del modulo ${i} come da codice in src/modulo${i}.ps1:10") }
            @{ Id = 1; Testo = '<div>' + (($righe | ForEach-Object { [System.Net.WebUtility]::HtmlEncode($_) }) -join '</div><div>') + '</div>' }
        }
    }
    It 'Get-UltimoCommentoDiRuolo tiene gli a capo dei blocchi HTML e toglie solo gli spazi in eccesso' {
        $c = @([pscustomobject]@{ Id = 1; Testo = '<div>[responsabile] Prima  riga</div><div>seconda<br>terza &amp; ultima</div><ul><li>uno</li><li>due</li></ul><p>fine</p>' })
        Get-UltimoCommentoDiRuolo $c 'responsabile' | Should -Be "Prima riga`nseconda`nterza & ultima`nuno`ndue`nfine"
    }
    It 'con una parte di domande mostra solo quella, una domanda per riga, con le opzioni sotto la loro domanda' {
        $t = Get-UltimoCommentoDiRuolo @([pscustomobject](script:New-CommentoCard11)) 'responsabile'
        $r = Format-DomandaOperatore $t 20 2000
        $r | Should -Not -Match 'REGISTRO|Decisione 1:'
        $r | Should -Not -Match 'DOMANDE'
        $r | Should -Not -Match 'Ho letto la card'
        @($r -split "`n").Count | Should -Be 12
        @($r -split "`n")[0] | Should -Be 'D1. Domanda numero 1 sul formato di export?'
        @($r -split "`n")[1] | Should -Be 'a) opzione A della D1'
        @($r -split "`n")[3] | Should -Be 'D2. Domanda numero 2 sul formato di export?'
        $r | Should -Not -Match 'continua sulla card'
    }
    It 'oltre il limite di righe taglia e rimanda alla card' {
        $t = Get-UltimoCommentoDiRuolo @([pscustomobject](script:New-CommentoCard11)) 'responsabile'
        $r = Format-DomandaOperatore $t 8 2000
        $righe = @($r -split "`n")
        $righe.Count | Should -Be 9
        $righe[8] | Should -Be ([string][char]0x2026 + ' continua sulla card')
        $righe[7] | Should -Be 'a) opzione A della D3'
    }
    It 'oltre il limite di caratteri taglia e rimanda alla card' {
        $t = Get-UltimoCommentoDiRuolo @([pscustomobject](script:New-CommentoCard11)) 'responsabile'
        $r = Format-DomandaOperatore $t 50 100
        $r.Length | Should -BeLessOrEqual 130
        $r | Should -Match ([regex]::Escape([string][char]0x2026 + ' continua sulla card') + '$')
        $r | Should -Not -Match 'REGISTRO'
    }
    It 'le voci D1, D2... valgono anche senza l intestazione DOMANDE' {
        $t = Get-UltimoCommentoDiRuolo @([pscustomobject](script:New-CommentoCard11 $false $false)) 'responsabile'
        $c = "Premessa`nD1. Una?`nD2. Due?`nREGISTRO DELLE DECISIONI`nx"
        Format-DomandaOperatore $c | Should -Be "D1. Una?`nD2. Due?"
    }
    It 'un elenco puntato sotto DOMANDE basta' {
        Format-DomandaOperatore "Premessa`nDomande aperte:`n- Quale formato?`n- Quale lingua?`nRegistro delle decisioni`nx" | Should -Be "- Quale formato?`n- Quale lingua?"
    }
    It 'senza una parte di domande mostra l inizio del commento con lo stesso limite e lo stesso rimando' {
        $t = Get-UltimoCommentoDiRuolo @([pscustomobject](script:New-CommentoCard11 $true $false)) 'responsabile'
        $r = Format-DomandaOperatore $t 5 2000
        $righe = @($r -split "`n")
        $righe.Count | Should -Be 6
        $righe[0] | Should -Match '^Ho letto la card'
        $righe[5] | Should -Be ([string][char]0x2026 + ' continua sulla card')
    }
    It 'una domanda scritta sulla riga di intestazione non si perde' {
        $c = "Premessa lunga`nDomanda: l'export e in CSV o in PDF?`nIpotesi: CSV`nREGISTRO DELLE DECISIONI`nx"
        Format-DomandaOperatore $c | Should -Be "Domanda: l'export e in CSV o in PDF?`nIpotesi: CSV"
    }
    It 'l intestazione da sola, anche con un qualificatore o una parentesi, non e una domanda' {
        Format-DomandaOperatore "Premessa`nDOMANDE (4)`nD1. Una?`nD2. Due?`nREGISTRO`nx" | Should -Be "D1. Una?`nD2. Due?"
        Format-DomandaOperatore "Premessa`nDomande per te`nD1. Una?`nREGISTRO`nx" | Should -Be 'D1. Una?'
    }
    It 'le opzioni in maiuscolo (A) B)) restano sotto la domanda e non chiudono la parte di domande' {
        Format-DomandaOperatore "DOMANDE`nD1. Quale formato?`nA) CSV`nB) PDF`nD2. Quale lingua?`nA) it`nREGISTRO DELLE DECISIONI`nx" |
            Should -Be "D1. Quale formato?`nA) CSV`nB) PDF`nD2. Quale lingua?`nA) it"
    }
    It 'riconosce il Markdown: **D1.** e - D1, e toglie gli asterischi dal testo mostrato' {
        Format-DomandaOperatore "Premessa`n**D1.** Quale formato?`n- D2 Quale lingua?`nREGISTRO DELLE DECISIONI`nx" | Should -Be "D1. Quale formato?`n- D2 Quale lingua?"
        Format-DomandaOperatore "Solo testo con **grassetto** qui" | Should -Be 'Solo testo con grassetto qui'
    }
    It 'un commento corto resta com e, senza rimando' {
        Format-DomandaOperatore 'Quale formato di export?' | Should -Be 'Quale formato di export?'
    }
    It 'una riga sola piu lunga del limite si taglia lo stesso' {
        $r = Format-DomandaOperatore ('parola ' * 300) 8 600
        $r.Length | Should -BeLessOrEqual 640
        $r | Should -Match 'continua sulla card$'
    }
    It 'con la scelta proposta: per ogni domanda il titolo e la proposta, senza le altre opzioni e senza le motivazioni' {
        $c = @(
            'Criteri scritti. Restano quattro scelte di prodotto.', 'DOMANDE (per Titolare). Per ognuna indico l ipotesi che prenderei.',
            'D1. Creazione senza rete. Il legame con commessa o preventivo e obbligatorio, ma la ricerca commesse funziona solo online.',
            'a) La creazione richiede la rete; tutto il resto funziona offline. <- la mia scelta: la preparazione si fa prima, di solito da PC.',
            'b) Offline si crea scrivendo a mano il numero di commessa.', 'c) Offline si crea senza legame.',
            'D2. Chi scrive. La descrizione dice operatore/admin, ma oggi scrive anche amministrativo.',
            'a) Si riusa ModificaModulo. <- la mia scelta: chi scrive si decide in un posto solo.', 'b) Policy nuova, solo operatore e admin.',
            'D3. Nomi dei piani generati dal numero piani, che la descrizione non dice come si chiamano ne se si possono rinominare a mano.',
            'a) Piano 1 ... Piano N, rinominabili a mano (per esempio Interrato, Piano terra), che non presuppone come si contano i piani. <- la mia scelta',
            'b) Nomi fissi.',
            'D4. Campi obbligatori di Inizia sopralluogo?', 'a) Solo il tecnico.', 'b) Tutti.',
            'REGISTRO DELLE DECISIONI', 'Decisione: x'
        ) -join "`n"
        $righe = @((Format-DomandaOperatore $c) -split "`n")
        $righe[0] | Should -Be 'D1. Creazione senza rete.'
        $righe[1] | Should -Be 'proposta: a) La creazione richiede la rete; tutto il resto funziona offline.'
        $righe[2] | Should -Be 'D2. Chi scrive.'
        $righe[3] | Should -Be 'proposta: a) Si riusa ModificaModulo.'
        $righe[4] | Should -Match '^D3\. Nomi dei piani generati .{20,}…$'
        $righe[4].Length | Should -BeLessOrEqual 90
        $righe[5] | Should -Match '^proposta: a\) Piano 1 \.\.\. Piano N, .*…$'
        $righe[5].Length | Should -BeLessOrEqual 110
        # senza proposta restano le opzioni, una per riga
        $righe[6..8] | Should -Be @('D4. Campi obbligatori di Inizia sopralluogo?', 'a) Solo il tecnico.', 'b) Tutti.')
        $righe.Count | Should -Be 9
        ($righe -join ' ') | Should -Not -Match 'la mia scelta|Offline si crea|continua sulla card'
    }

    It 'testo vuoto o null da null' {
        Format-DomandaOperatore $null | Should -BeNullOrEmpty
        Format-DomandaOperatore '  ' | Should -BeNullOrEmpty
    }
}
Describe 'Get-Azioni: il collaudatore senza urlTest' {
    It 'l allegato dice di fermarsi con bloccato, non di cercare nei file di configurazione (ci sono password)' {
        $i = script:New-InTest; script:Set-Stato $i 'inCollaudo'
        $i.Voce = [pscustomobject]@{ repo = 'Acme.AI'; componente = 'stime'; pipelineDeploy = 115 }
        $az = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        $az[0].Allegato | Should -Match 'ESITO=bloccato'
        $az[0].Allegato | Should -Not -Match 'configurazione'
    }
}

Describe 'Get-Azioni: card presa in carico da un altro PC (spec, sezione 19)' {
    BeforeDiscovery {
        # Senza stato locale: ne ramo, ne cartella, ne PR salvata. E una card riassegnata, o mai partita da qui.
        $script:CasiPresa = @(
            @{ N = 'P1 In development senza stato locale: si prende in carico (worktree dal ramo remoto)'; Chiave = 'inSviluppo'
               Att = @(@{ Tipo = 'AdottaCard' }); Mod = { param($i, $c) } }
            @{ N = 'P2 In review senza stato locale: si prende in carico'; Chiave = 'inRevisione'
               Att = @(@{ Tipo = 'AdottaCard' }); Mod = { param($i, $c) } }
            @{ N = 'P3 Deploying to test senza stato locale: si prende in carico'; Chiave = 'inDeployTest'
               Att = @(@{ Tipo = 'AdottaCard' }); Mod = { param($i, $c) } }
            @{ N = 'P3b Automated test senza stato locale: si prende in carico'; Chiave = 'inCollaudo'
               Att = @(@{ Tipo = 'AdottaCard' }); Mod = { param($i, $c) } }
            @{ N = 'P3c Human test senza stato locale: si prende in carico'; Chiave = 'inProvaUmana'
               Att = @(@{ Tipo = 'AdottaCard' }); Mod = { param($i, $c) } }
            @{ N = 'P4 Ready to develop senza stato locale: il percorso di sempre, non una presa in carico'; Chiave = 'pronto'
               Att = @(@{ Tipo = 'CreaWorktree' }, @{ Tipo = 'SpostaCard' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev' }); Mod = { param($i, $c) } }
            @{ N = 'P4b Ready to merge senza stato locale: si prende in carico (poi si trova la PR sul ramo)'; Chiave = 'daUnire'
               Att = @(@{ Tipo = 'AdottaCard' }); Mod = { param($i, $c) } }
            @{ N = 'P5 Ready to release gia rilasciata (PR salvata, worktree tolto): niente'; Chiave = 'daRilasciare'
               Att = @(); Mod = { param($i, $c) $i.StatoCard.prId = 9 } }
            @{ N = 'P6 presa in carico, In development con la PR verde: il percorso della PR, reviewer'; Chiave = 'inSviluppo'
               Att = @(@{ Tipo = 'SpostaCard'; Stato = 'inRevisione' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'reviewer' })
               Mod = { param($i, $c)
                   $i.StatoCard.ramo = 'feature/100-x'; $i.StatoCard.cartella = 'C:/wt/card-100'; $i.StatoCard.prId = 3
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
            @{ N = 'P7 presa in carico, In development con la PR rossa: dev con il log'; Chiave = 'inSviluppo'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'rossa'; Allegato = 'http://log/55' })
               Mod = { param($i, $c)
                   $i.StatoCard.ramo = 'feature/100-x'; $i.StatoCard.cartella = 'C:/wt/card-100'; $i.StatoCard.prId = 3
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 55; UrlLog = 'http://log/55' } } }
            @{ N = 'P8 presa in carico, In review senza sessioni: reviewer rifa la revisione'; Chiave = 'inRevisione'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'reviewer'; Motivo = 'presaInCarico' })
               Mod = { param($i, $c) $i.StatoCard.ramo = 'feature/100-x'; $i.StatoCard.cartella = 'C:/wt/card-100'; $i.StatoCard.prId = 3 } }
        )
    }

    It 'una card rilasciata qui (ramo e cartella tolti) che ha una storia di sessioni non si riprende in carico' {
        $i = script:New-Ist 'daRilasciare' 'daUnire' 'u-titolare'
        $i.StatoCard.ramo = $null; $i.StatoCard.cartella = $null; $i.StatoCard.prId = $null
        script:Set-Sessione $i 'reviewer' 'superata'
        @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)) | Where-Object { $_.Tipo -eq 'AdottaCard' } | Should -BeNullOrEmpty
    }

    It 'una sessione avviata da poco dall altro smistatore fa aspettare la presa in carico: potrebbe essere ancora viva' {
        $i = script:New-Ist 'inSviluppo'
        $i.StatoCard.ramo = $null; $i.StatoCard.cartella = $null; $i.StatoCard.prId = $null
        $i.Commenti = @([pscustomobject]@{ Id = 5; Autore = 'Collega'; Testo = '[smistatore] Sessione abc avviata: ruolo dev, cartella C:/x.'; Quando = '2026-11-02T10:00:00Z' })
        $c = script:New-Contesto; $c.Adesso = '2026-11-02T10:20:00Z'
        @(Get-Azioni -Istantanea $i -Contesto $c).Count | Should -Be 0
        $c.Adesso = '2026-11-02T11:00:00Z'   # oltre silenzioMinuti: la sessione e morta o chiusa
        @(Get-Azioni -Istantanea $i -Contesto $c)[0].Tipo | Should -Be 'AdottaCard'
    }

    It 'caso <N>' -ForEach $script:CasiPresa {
        $i = script:New-Ist $Chiave
        $i.StatoCard.ramo = $null; $i.StatoCard.cartella = $null; $i.StatoCard.prId = $null
        $c = script:New-Contesto
        & $Mod $i $c
        script:Test-Azioni @(Get-Azioni -Istantanea $i -Contesto $c) $Att
    }
}

Describe 'Test-CommentoDiPersona: la menzione davanti a un commento di agente' {
    It 'la menzione con la sola chiocciola o con il nome dentro l ancora non lo fa diventare un commento di persona' {
        Test-CommentoDiPersona ([pscustomobject]@{ Testo = '<a href="#" data-vss-mention="version:2.0,u-ric">@</a> [smistatore] Sessione avviata' }) | Should -BeFalse
        Test-CommentoDiPersona ([pscustomobject]@{ Testo = '<div><a href="#" data-vss-mention="version:2.0,u-ric">@Paolo Rossi</a> [smistatore] dev bloccato</div>' }) | Should -BeFalse
        Test-CommentoDiPersona ([pscustomobject]@{ Testo = '<a href="#" data-vss-mention="version:2.0,u-ric">@Titolare</a>&nbsp;[reviewer] ok' }) | Should -BeFalse
        # la menzione in Markdown, come la scrive Add-AdoCommento
        Test-CommentoDiPersona ([pscustomobject]@{ Testo = '@<35301cda-c28a-43af-b333-9f845966fcd3> [smistatore] dev bloccato' }) | Should -BeFalse
        # il collaudatore e un agente: il suo esito non e il commento di una persona
        Test-CommentoDiPersona ([pscustomobject]@{ Testo = '[collaudatore] Collaudo superato' }) | Should -BeFalse
    }
    It 'il mentore e un agente: il commento di un conflitto (memoria.ps1 conflitto) non rilancia il mentore come se fosse una correzione' {
        Test-CommentoDiPersona ([pscustomobject]@{ Testo = "[mentore] La correzione contraddice il brief`n`n— scritto da Claude (mentore)" }) | Should -BeFalse
    }
    It 'un commento di una persona resta tale, anche se cita un ruolo piu avanti' {
        Test-CommentoDiPersona ([pscustomobject]@{ Testo = '<a href="#" data-vss-mention="x">@Mario</a> grazie, ho visto il [smistatore]' }) | Should -BeTrue
        Test-CommentoDiPersona ([pscustomobject]@{ Testo = 'Una risposta' }) | Should -BeTrue
    }
}

Describe 'Get-Azioni: card divise in task' {
    BeforeDiscovery {
        $script:CasiTask = @(
            @{ N = 'T1 Ready to develop, due task aperti: dev sul primo'
               Att = @(@{ Tipo = 'CreaWorktree' }, @{ Tipo = 'SpostaCard'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'pronto'; Task = 61 })
               Mod = { param($i, $c) script:Set-Stato $i 'pronto'; script:Set-Task $i @{ 61 = 'aperto'; 62 = 'aperto' } } }
            @{ N = 'T2 Ready to develop, il primo task e chiuso: dev sul primo aperto'
               Att = @(@{ Tipo = 'CreaWorktree' }, @{ Tipo = 'SpostaCard' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Task = 62 })
               Mod = { param($i, $c) script:Set-Stato $i 'pronto'; script:Set-Task $i @{ 61 = 'taskChiuso'; 62 = 'aperto'; 63 = 'aperto' } } }
            @{ N = 'T3 Ready to develop, task tutti chiusi o rimossi: dev non legato a un task'
               Att = @(@{ Tipo = 'CreaWorktree' }, @{ Tipo = 'SpostaCard' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Task = $null })
               Mod = { param($i, $c) script:Set-Stato $i 'pronto'; script:Set-Task $i @{ 61 = 'taskChiuso'; 62 = 'taskRimosso' } } }
            @{ N = 'T4 Ready to develop, task rimosso in testa: non conta come aperto'
               Att = @(@{ Tipo = 'CreaWorktree' }, @{ Tipo = 'SpostaCard' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Task = 62 })
               Mod = { param($i, $c) script:Set-Stato $i 'pronto'; script:Set-Task $i @{ 61 = 'taskRimosso'; 62 = 'aperto' } } }
            @{ N = 'T5 dev fatto sul task 61 chiuso, resta il 62: parte dev sul 62, niente PR'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'taskSuccessivo'; Task = 62 })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto' -Task 61; script:Set-Task $i @{ 61 = 'taskChiuso'; 62 = 'aperto' } } }
            @{ N = 'T6 dev fatto, task chiuso, restano task aperti e la PR e gia verde: il percorso della PR non parte'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Task = 62 })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto' -Task 61; script:Set-Task $i @{ 61 = 'taskChiuso'; 62 = 'aperto' }
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
            @{ N = 'T7 dev fatto ma il suo task e ancora aperto: in attesa, non passa al successivo'
               Att = @(@{ Tipo = 'MettiInAttesa'; Per = 'sessione' })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto' -Task 61; script:Set-Task $i @{ 61 = 'aperto'; 62 = 'aperto' } } }
            @{ N = 'T8 dev fatto sull ultimo task, chiuso: parte il percorso di oggi (apre la PR)'
               Att = @(@{ Tipo = 'ApriPr' })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto' -Task 62; script:Set-Task $i @{ 61 = 'taskChiuso'; 62 = 'taskChiuso' } } }
            @{ N = 'T9 dev fatto, l ultimo task e rimosso: non conta come aperto, apre la PR'
               Att = @(@{ Tipo = 'ApriPr' })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto' -Task 61; script:Set-Task $i @{ 61 = 'taskChiuso'; 62 = 'taskRimosso' } } }
            @{ N = 'T10 task chiusi, PR verde: reviewer come oggi'
               Att = @(@{ Tipo = 'SpostaCard'; Stato = 'inRevisione' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'reviewer'; Task = $null })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto' -Task 62; script:Set-Task $i @{ 61 = 'taskChiuso'; 62 = 'taskChiuso' }
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
            @{ N = 'T11 validazione rossa con task chiusi: dev non legato a un task'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'rossa'; Task = $null })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto' -Task 62; script:Set-Task $i @{ 61 = 'taskChiuso'; 62 = 'taskChiuso' }
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 55; UrlLog = 'http://log/55' } } }
            @{ N = 'T12 rilievi del reviewer con task chiusi: dev non legato a un task'
               Att = @(@{ Tipo = 'SpostaCard'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'rilievi'; Task = $null })
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'bloccante' 'Manca il test'; script:Set-Task $i @{ 61 = 'taskChiuso' } } }
            @{ N = 'T13 dev non legato a un task (rossa) finisce con task aperti: parte il primo aperto'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Task = 62 })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'; script:Set-Task $i @{ 61 = 'taskChiuso'; 62 = 'aperto' } } }
            @{ N = 'T14 In development senza nessuna sessione e con un task aperto: dev sul primo aperto'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Task = 61 })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Task $i @{ 61 = 'aperto' } } }
            @{ N = 'T15 In development con il worktree, senza sessioni, task e PR: dev riprende il lavoro dal ramo'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'presaInCarico'; Task = $null })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Task $i @{ 61 = 'taskChiuso' } } }
            @{ N = 'T16 responsabile ha risolto il bivio con un task aperto: dev riparte su quel task'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'decisione'; Task = 61; Allegato = '[responsabile] Decisione: usa la libreria A' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'bivio' 'Quale libreria?' -Task 61; script:Set-Sessione $i 'responsabile' 'fatto' 'x'
                   script:Set-Task $i @{ 61 = 'aperto'; 62 = 'aperto' }
                   $i.Commenti = @([pscustomobject]@{ Id = 9; Autore = 'Titolare'; Testo = '[responsabile] Decisione: usa la libreria A' }) } }
            @{ N = 'T17 bivio di dev su un task: va a responsabile, che non e legato al task'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Task = $null })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'bivio' 'Quale libreria?' -Task 61; script:Set-Task $i @{ 61 = 'aperto' } } }
            @{ N = 'T18 on-hold tolto dopo un dev su un task: la sessione riprende con lo stesso task'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Riprendi = $true; Task = 61 })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'bloccato' -Task 61; script:Set-Task $i @{ 61 = 'aperto' }
                   $i.StatoCard.inAttesaPer = 'sessione' } }
            @{ N = 'T19 task aperti ma card in New: niente di diverso da oggi'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Task = $null })
               Mod = { param($i, $c) script:Set-Stato $i 'nuova'; script:Set-Task $i @{ 61 = 'aperto' } } }
            @{ N = 'T20 un task attivo conta come aperto'
               Att = @(@{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Task = 61 })
               Mod = { param($i, $c) script:Set-Stato $i 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto' -Task 60; script:Set-Task $i @{ 61 = 'attivo' } } }
            # Un task aggiunto dopo lo sviluppo: la revisione fatta non copre il lavoro nuovo, la card torna In development
            @{ N = 'T21 In revisione, revisione superata e un task aggiunto: torna In development con dev sul task'
               Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'taskAggiunto'; Task = 63 })
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'; script:Set-Task $i @{ 61 = 'taskChiuso'; 63 = 'aperto' } } }
            @{ N = 'T22 In revisione, rilievi del reviewer e un task aggiunto: prima i rilievi, il task dopo'
               Att = @(@{ Tipo = 'SpostaCard'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'rilievi' })
               Mod = { param($i, $c) script:Set-Stato $i 'inRevisione'; script:Set-Sessione $i 'reviewer' 'bloccante' 'Manca il test'; script:Set-Task $i @{ 63 = 'aperto' } } }
            @{ N = 'T23 Deploying to test per gesto di Titolare e un task aggiunto: torna In development, niente deploy'
               Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'taskAggiunto'; Task = 63 })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'inDeployTest'; $i.Storia[0].Chi = 'u-titolare'
                   script:Set-Sessione $i 'dev' 'fatto' -Fine '2026-11-02T10:00:00Z'; script:Set-Sessione $i 'reviewer' 'superata' -Fine '2026-11-03T10:00:00Z'
                   script:Set-Task $i @{ 63 = 'aperto' } } }
            @{ N = 'T24 Ready to release con la PR aperta e un task aggiunto: torna In development, la PR non si completa'
               Att = @(@{ Tipo = 'RiportaIndietro'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev'; Motivo = 'taskAggiunto'; Task = 63 })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'daRilasciare'; $i.Storia[0].Da = (script:Nome 'daUnire'); $i.Storia[0].Chi = 'u-titolare'
                   script:Set-Sessione $i 'reviewer' 'superata'; script:Set-Task $i @{ 63 = 'aperto' }
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
            @{ N = 'T25 Ready to release con la PR gia completata: il task aggiunto non riapre niente, si toglie il worktree'
               Att = @(@{ Tipo = 'RimuoviWorktree' })
               Mod = { param($i, $c)
                   script:Set-Stato $i 'daRilasciare'; $i.Storia[0].Chi = 'u-titolare'; script:Set-Task $i @{ 63 = 'aperto' }
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'completed'; Validazione = 'verde'; BuildId = 58; UrlLog = $null } } }
        )
    }

    It 'caso <N>' -ForEach $script:CasiTask {
        $i = script:New-Ist 'inSviluppo'
        $c = script:New-Contesto
        & $Mod $i $c
        if (@($Att | Where-Object { $_.Tipo -eq 'MettiInAttesa' }).Count -gt 0) { script:Set-PassataFatta $i $c }
        script:Test-Azioni @(Get-Azioni -Istantanea $i -Contesto $c) $Att
    }

    It 'senza il campo Task nell istantanea (card senza task) il percorso di oggi non cambia' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
        $i.ContainsKey('Task') | Should -BeFalse
        @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Tipo | Should -Be @('ApriPr')
    }

    It 'al limite di sessioni attive il task successivo non parte' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto' -Task 61; script:Set-Task $i @{ 61 = 'taskChiuso'; 62 = 'aperto' }
        $c = script:New-Contesto; $c.SessioniAttive = $script:AlLimite
        @(Get-Azioni -Istantanea $i -Contesto $c).Count | Should -Be 0
    }
}

Describe 'Get-Azioni: card che dipendono da altre (Predecessori)' {
    BeforeAll {
        # Un predecessore come lo porta l'istantanea: id, stato ADO, e prId/cartella dello stato locale dello smistatore.
        function script:New-Pred([int]$Id, [string]$Chiave, $PrId = $null, $Cartella = $null) {
            [pscustomobject]@{ Id = $Id; Stato = (script:Nome $Chiave); prId = $PrId; cartella = $Cartella }
        }
        function script:Get-Attese([string]$Chiave) {
            if ($Chiave -eq 'nuova') { @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile' }) }
            else { @(@{ Tipo = 'CreaWorktree' }, @{ Tipo = 'SpostaCard'; Stato = 'inSviluppo' }, @{ Tipo = 'LanciaSessione'; Ruolo = 'dev' }) }
        }
    }

    It 'in <K> con un predecessore non unito (<P.Chiave>) non fa niente' -ForEach @(
        @{ K = 'nuova'; P = @{ Chiave = 'inSviluppo' } }
        @{ K = 'pronto'; P = @{ Chiave = 'inSviluppo' } }
        @{ K = 'nuova'; P = @{ Chiave = 'daRilasciare'; PrId = 7; Cartella = 'C:/wt/a' } }
        @{ K = 'pronto'; P = @{ Chiave = 'daRilasciare'; PrId = 7; Cartella = 'C:/wt/a' } }
        @{ K = 'nuova'; P = @{ Chiave = 'daRilasciare'; PrId = $null; Cartella = $null } }
        @{ K = 'pronto'; P = @{ Chiave = 'rimossa' } }
        @{ K = 'nuova'; P = @{ Chiave = 'rimossa' } }
        @{ K = 'pronto'; P = @{ Chiave = 'daUnire'; PrId = 7 } }
    ) {
        $i = script:New-Ist $K
        $i.Predecessori = @(script:New-Pred 50 $P.Chiave $P.PrId $P.Cartella)
        @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Count | Should -Be 0
    }

    It 'in <K> con i predecessori tutti uniti (<N>) le azioni sono quelle di oggi' -ForEach @(
        @{ K = 'nuova'; N = 'inRilascio'; Preds = { @(script:New-Pred 50 'inRilascio') } }
        @{ K = 'pronto'; N = 'inRilascio'; Preds = { @(script:New-Pred 50 'inRilascio') } }
        @{ K = 'nuova'; N = 'chiusa'; Preds = { @(script:New-Pred 50 'chiusa') } }
        @{ K = 'pronto'; N = 'chiusa'; Preds = { @(script:New-Pred 50 'chiusa') } }
        @{ K = 'nuova'; N = 'daRilasciare, PR completata e worktree tolto'; Preds = { @(script:New-Pred 50 'daRilasciare' 7 $null) } }
        @{ K = 'pronto'; N = 'daRilasciare, PR completata e worktree tolto'; Preds = { @(script:New-Pred 50 'daRilasciare' 7 '') } }
        @{ K = 'pronto'; N = 'tutti e tre insieme'; Preds = { @((script:New-Pred 50 'chiusa'), (script:New-Pred 51 'inRilascio'), (script:New-Pred 52 'daRilasciare' 7 $null)) } }
    ) {
        $i = script:New-Ist $K
        $i.Predecessori = & $Preds
        script:Test-Azioni @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)) (script:Get-Attese $K)
    }

    It 'basta un predecessore non unito fra tanti' {
        $i = script:New-Ist 'pronto'
        $i.Predecessori = @((script:New-Pred 50 'chiusa'), (script:New-Pred 51 'inRevisione'))
        @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Count | Should -Be 0
    }

    It 'senza il campo Predecessori o con elenco vuoto le azioni sono quelle di oggi' {
        $i = script:New-Ist 'pronto'
        script:Test-Azioni @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)) (script:Get-Attese 'pronto')
        $i.Predecessori = @()
        script:Test-Azioni @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)) (script:Get-Attese 'pronto')
    }

    It 'gli altri stati ignorano i predecessori' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
        $i.Predecessori = @(script:New-Pred 50 'inSviluppo')
        @((Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Tipo) | Should -Be @('ApriPr')
    }
}

Describe 'Get-Decisione: perche una card non parte (una fonte sola con Get-Azioni)' {
    It 'deploy in Test fallito: il motivo dell on-hold porta il link al run' {
        $i = script:New-InTest; script:Set-Run $i 'failed'
        $i.Run | Add-Member -NotePropertyName Url -NotePropertyValue 'https://ado/run/9'
        script:Set-PassataFatta $i   # la passata del responsabile e gia stata fatta
        $az = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        $az[0].Tipo | Should -Be 'MettiInAttesa'
        $az[0].Motivo | Should -Match ([regex]::Escape('https://ado/run/9'))
    }

    It 'on-hold per sessione tolto dopo che la card e stata spostata a mano: non si riprende la sessione, si decide dallo stato nuovo' {
        # card 10: collaudatore bloccato, card portata a mano in Ready to merge, on-hold tolto: ripartiva il collaudatore
        $i = script:New-Ist 'daUnire' 'inCollaudo'
        script:Set-Sessione $i 'collaudatore' 'bloccato' -Fine '2026-11-04T10:00:00Z'
        $i.Storia[0].Quando = '2026-11-05T10:00:00Z'
        $i.StatoCard.inAttesaPer = 'sessione'
        $az = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($az | Where-Object { $_.Tipo -eq 'LanciaSessione' -and $_.Ruolo -eq 'collaudatore' }).Count | Should -Be 0
        $az[0].Tipo | Should -Be 'AzzeraContatori'
    }

    It 'on-hold per sessione tolto senza cambi di stato: si riprende la sessione' {
        $i = script:New-Ist 'inCollaudo' 'inDeployTest'
        script:Set-Sessione $i 'collaudatore' 'bloccato' -Fine '2026-11-04T10:00:00Z'
        $i.StatoCard.inAttesaPer = 'sessione'
        $az = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        $az[0].Tipo | Should -Be 'LanciaSessione'
        $az[0].Riprendi | Should -BeTrue
    }

    It 'on-hold: nessuna azione, motivo onHold con il valore di inAttesaPer' {
        $i = script:New-Ist 'inSviluppo'; $i.Card.Tag = @($script:Stati.tagAgenti, $script:Stati.tagAttesa)
        $i.StatoCard.inAttesaPer = 'sessione'
        $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo.Tipo | Should -Be 'onHold'
        $d.Motivo.InAttesaPer | Should -Be 'sessione'
    }
    It 'predecessori: motivo con i predecessori non uniti, quelli uniti no' {
        $i = script:New-Ist 'pronto'
        $i.Predecessori = @(
            [pscustomobject]@{ Id = 50; Stato = (script:Nome 'chiusa'); prId = $null; cartella = $null }
            [pscustomobject]@{ Id = 51; Stato = (script:Nome 'inRevisione'); prId = $null; cartella = $null })
        $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo.Tipo | Should -Be 'predecessori'
        @($d.Motivo.Predecessori).Count | Should -Be 1
        $d.Motivo.Predecessori[0].Id | Should -Be 51
        Format-MotivoCoda $d.Motivo | Should -Be 'aspetta le card precedenti non ancora unite: #51 (In review)'
    }
    It 'limite sessioni: nessuna azione, motivo con le card che tengono il posto' {
        $i = script:New-Ist 'nuova'
        $c = script:New-Contesto; $c.Limiti = $script:Limiti.PSObject.Copy(); $c.Limiti.sessioniAttive = 1
        $c.SessioniAttive = 1; $c.ConSessione = @(7)
        $d = Get-Decisione -Istantanea $i -Contesto $c
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo.Tipo | Should -Be 'limiteSessioni'
        Format-MotivoCoda $d.Motivo | Should -Be 'in coda, posto occupato (sessioni attive 1/1: card 7)'
    }
    It 'limite per repo: un altra card in sviluppo sul repo, motivo con la card' {
        $i = script:New-Ist 'pronto'
        $c = script:New-Contesto; $c.InSviluppoPerRepo = @{ 'Acme.AI' = @(100, 8) }
        $d = Get-Decisione -Istantanea $i -Contesto $c
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo.Tipo | Should -Be 'limiteRepo'
        Format-MotivoCoda $d.Motivo | Should -Be 'in coda, un altra card e in sviluppo su Acme.AI (1/1: card 8)'
    }
    It 'limite per componente in Test: la card con la revisione superata resta In review e il motivo dice chi occupa il posto' {
        $i = script:New-Ist 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'
        $c = script:New-Contesto; $c.InTestPerComponente = @{ stime = @(100, 8) }
        $d = Get-Decisione -Istantanea $i -Contesto $c
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo.Tipo | Should -Be 'limiteTest'
        Format-MotivoCoda $d.Motivo | Should -Be 'in coda, un altra card dello stesso componente e in Test (stime, 1/1: card 8)'
    }
    It 'una card In review che aspetta reviewer, o con la revisione non piu valida, non ha il motivo del limite per componente' {
        $c = script:New-Contesto; $c.InTestPerComponente = @{ stime = @(8) }
        $i = script:New-Ist 'inRevisione'; script:Set-Sessione $i 'reviewer' 'bloccante'; $i.StatoCard.giriRevisione = 2
        (Get-Decisione -Istantanea $i -Contesto $c).Motivo | Should -BeNullOrEmpty
        $i = script:New-Ist 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'
        script:Set-Sessione $i 'dev' 'fatto' -Fine '2026-11-04T10:00:00Z'
        (Get-Decisione -Istantanea $i -Contesto $c).Motivo | Should -BeNullOrEmpty
    }
    It 'il motivo porta il ruolo a cui andra la card: predecessori in New al responsabile, in Ready to develop a dev' {
        $pred = @([pscustomobject]@{ Id = 51; Stato = (script:Nome 'inRevisione'); prId = $null; cartella = $null })
        $i = script:New-Ist 'nuova'; $i.Predecessori = $pred
        (Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)).Motivo.Ruolo | Should -Be 'responsabile'
        $i = script:New-Ist 'pronto'; $i.Predecessori = $pred
        (Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)).Motivo.Ruolo | Should -Be 'dev'
    }
    It 'il motivo del limite per repo ha il ruolo dev, quello del limite in Test il collaudatore' {
        $i = script:New-Ist 'pronto'
        $c = script:New-Contesto; $c.InSviluppoPerRepo = @{ 'Acme.AI' = @(100, 8) }
        (Get-Decisione -Istantanea $i -Contesto $c).Motivo.Ruolo | Should -Be 'dev'
        $i = script:New-Ist 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'
        $c = script:New-Contesto; $c.InTestPerComponente = @{ stime = @(100, 8) }
        (Get-Decisione -Istantanea $i -Contesto $c).Motivo.Ruolo | Should -Be 'collaudatore'
    }
    It 'limite in Test con human-test: la prova e di una persona, il motivo non ha ruolo' {
        $i = script:New-Ist 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'
        $i.Card.Tag = @($script:Stati.tagAgenti, $script:Stati.tagProvaUmana)
        $c = script:New-Contesto; $c.InTestPerComponente = @{ stime = @(100, 8) }
        $d = Get-Decisione -Istantanea $i -Contesto $c
        $d.Motivo.Tipo | Should -Be 'limiteTest'
        $d.Motivo.Ruolo | Should -BeNullOrEmpty
    }
    It 'il motivo del limite di sessioni porta il ruolo del primo LanciaSessione fermato' {
        $c = script:New-Contesto; $c.Limiti = $script:Limiti.PSObject.Copy(); $c.Limiti.sessioniAttive = 1
        $c.SessioniAttive = 1; $c.ConSessione = @(7)
        $d = Get-Decisione -Istantanea (script:New-Ist 'nuova') -Contesto $c
        $d.Motivo.Ruolo | Should -Be 'responsabile'
        $d = Get-Decisione -Istantanea (script:New-Ist 'pronto') -Contesto $c
        $d.Motivo.Tipo | Should -Be 'limiteSessioni'
        $d.Motivo.Ruolo | Should -Be 'dev'
    }
    It 'una card pronta a partire non ha motivo e ha le azioni di Get-Azioni' {
        $i = script:New-Ist 'nuova'
        $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
        $d.Motivo | Should -BeNullOrEmpty
        @($d.Azioni).Count | Should -Be @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Count
        $d.Azioni[0].Tipo | Should -Be 'LanciaSessione'
    }
    It 'una card con la sessione in corso non e in coda: ne azioni ne motivo' {
        $i = script:New-Ist 'inSviluppo'; $i.StatoCard.sessione = @{ id = 's' }
        $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo | Should -BeNullOrEmpty
    }
    It 'una card che aspetta un evento (PR in corso) non ha ne azioni ne motivo' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
        $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'inCorso'; BuildId = 56; UrlLog = 'u' }
        $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo | Should -BeNullOrEmpty
    }
}

Describe 'Get-GestoAtteso: il gesto che spetta a una persona, dall avviso gia registrato' {
    It 'Human test con l avviso registrato: aspetta la prova del richiedente' {
        $i = script:New-InTest; script:Set-Stato $i 'inProvaUmana'; $i.StatoCard.avvisi = @('testPronto@7')
        $g = Get-GestoAtteso -Istantanea $i -Contesto (script:New-Contesto)
        $g.Tipo | Should -Be 'testPronto'
    }
    It 'senza l avviso, o con l avviso di un ingresso precedente, niente' {
        $i = script:New-InTest; script:Set-Stato $i 'inProvaUmana'
        Get-GestoAtteso -Istantanea $i -Contesto (script:New-Contesto) | Should -BeNullOrEmpty
        $i.StatoCard.avvisi = @('testPronto@3')
        Get-GestoAtteso -Istantanea $i -Contesto (script:New-Contesto) | Should -BeNullOrEmpty
    }
    It 'in In review la revisione superata non lascia nessun gesto da aspettare: passa da sola' {
        $i = script:New-Ist 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'
        $i.StatoCard.avvisi = @('revisioneSuperata@7')
        Get-GestoAtteso -Istantanea $i -Contesto (script:New-Contesto) | Should -BeNullOrEmpty
    }
    It 'il testo e lo stesso dell avviso che Get-Azioni emette (una fonte sola)' {
        $i = script:New-InTest; script:Set-Stato $i 'inProvaUmana'
        $az = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        $az[0].Tipo | Should -Be 'Avvisa'
        $i.StatoCard.avvisi = @($az[0].Chiave)
        (Get-GestoAtteso -Istantanea $i -Contesto (script:New-Contesto)).Testo | Should -Be $az[0].Testo
    }
}

Describe 'Titolo della PR' {
    # La pr-validation dei repo controlla che il tipo conventional-commit del titolo combaci col prefisso del ramo:
    # feature/* vuole feat, i rami di bug vogliono fix. Senza prefisso la validazione e rossa (card 11, PR 1019).
    It 'ramo feature: prefisso feat' {
        Get-TitoloPr -Ramo 'feature/11-efficientamento' -Titolo 'Efficientamento energetico: base' | Should -Be 'feat: Efficientamento energetico: base'
    }
    It 'ramo fix o bugfix: prefisso fix' {
        Get-TitoloPr -Ramo 'fix/12-errore' -Titolo 'Errore al salvataggio' | Should -Be 'fix: Errore al salvataggio'
        Get-TitoloPr -Ramo 'bugfix/12-errore' -Titolo 'Errore al salvataggio' | Should -Be 'fix: Errore al salvataggio'
    }
    It 'titolo gia conventional: resta com e' {
        Get-TitoloPr -Ramo 'feature/11-x' -Titolo 'feat(area): base' | Should -Be 'feat(area): base'
    }
    It 'altri rami: titolo invariato' {
        Get-TitoloPr -Ramo 'hotfix/1-x' -Titolo 'Correzione' | Should -Be 'Correzione'
    }
}


# D42: prima di ogni on-hold per una persona passa il responsabile.
Describe 'Get-Decisione: la passata del responsabile prima dell on-hold (D42)' {
    # Deploying to test con il run fallito (l'attesa 'deploy'), dopo la sessione del responsabile (motivo attesa) chiusa
    # con l'esito dato.
    BeforeAll {
        function script:New-DopoPassata($Esito, [string]$Per = 'deploy', $Ruolo = 'reviewer') {
            $i = script:New-InTest; script:Set-Run $i 'failed'
            $i.StatoCard.ultimaSessione['responsabile'] = @{ id = 's-resp'; fine = '2026-11-04T10:00:00Z'; esito = $Esito; motivo = 'attesa' }
            $i.StatoCard.ultimoRuolo = 'responsabile'
            $i.StatoCard.attesaInEsame = @{ motivo = 'deploy in Test fallito (run 9)'; per = $Per; ruolo = $Ruolo; chiave = 'deployFallito' }
            $i.StatoCard.passateFatte = @('deployFallito')
            $i
        }
        # In review con il reviewer bloccante e i giri al limite: l'attesa 'troppi giri di revisione'.
        function script:New-GiriAlLimite {
            $i = script:New-Ist 'inRevisione'
            script:Set-Sessione $i 'reviewer' 'bloccante' 'rilievi'; $i.StatoCard.giriRevisione = 2
            $i
        }
    }

    It 'la prima attesa: ricorda il motivo, il per e la chiave, lancia il responsabile con il motivo attesa e i dettagli in allegato' {
        $i = script:New-InTest; script:Set-Run $i 'failed'
        $i.Run | Add-Member -NotePropertyName Url -NotePropertyValue 'https://ado/run/9'
        $i.StatoCard.ultimaSessione['reviewer'].testo = 'revisione superata senza rilievi'
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('AvviaPassataAttesa', 'LanciaSessione')
        $r[0].Per | Should -Be 'deploy'
        $r[0].Ruolo | Should -Be 'reviewer'
        $r[0].Motivo | Should -Match 'deploy in Test fallito'
        $r[0].Chiave | Should -Be 'deployFallito'
        $r[1].Ruolo | Should -Be 'responsabile'; $r[1].Motivo | Should -Be 'attesa'
        $r[1].Allegato | Should -Match 'deploy in Test fallito'
        $r[1].Allegato | Should -Match 'revisione superata senza rilievi'
        $r[1].Allegato | Should -Match ([regex]::Escape('https://ado/run/9'))
    }

    It 'la chiave di un attesa con il testo fisso e il suo motivo' {
        $r = @(Get-Azioni -Istantanea (script:New-GiriAlLimite) -Contesto (script:New-Contesto))
        $r[0].Tipo | Should -Be 'AvviaPassataAttesa'
        $r[0].Chiave | Should -Be 'troppi giri di revisione'
    }

    It 'la chiave di un attesa con parti variabili non le contiene: <N>' -ForEach @(
        @{ N = 'deploy in Test fallito'; Chiave = 'deployFallito'; Ist = { $i = script:New-InTest; script:Set-Run $i 'failed'; $i.StatoCard.runId = 12345; $i } }
        @{ N = 'task non chiuso'; Chiave = 'taskNonChiuso'
           Ist = { $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto' -Task 61; script:Set-Task $i @{ 61 = 'aperto' }; $i } }
        @{ N = 'sessione senza ESITO'; Chiave = 'senzaEsito'; Ist = { $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' $null; $i } }
        @{ N = 'esito del collaudatore sconosciuto'; Chiave = 'esitoCollaudoSconosciuto'
           Ist = { $i = script:New-InTest; script:Set-Stato $i 'inCollaudo'; script:Set-Sessione $i 'collaudatore' 'boh' -Fine '2026-11-04T10:00:00Z'; $i } }
        @{ N = 'PR non completata'; Chiave = 'prNonCompletata'
           Ist = { $i = script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare'; $i.StatoCard.completaPr = '3@7'
                   $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null }; $i } }
    ) {
        $r = @(Get-Azioni -Istantanea (& $Ist) -Contesto (script:New-Contesto))
        $r[0].Tipo | Should -Be 'AvviaPassataAttesa'
        $r[0].Chiave | Should -Be $Chiave
    }

    It 'l allegato porta anche il link della build della PR quando c e' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
        $i.StatoCard.rosseDiFila = 3
        $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 56; UrlLog = 'http://log/56' }
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        $r[-1].Motivo | Should -Be 'attesa'
        $r[-1].Allegato | Should -Match ([regex]::Escape('http://log/56'))
    }

    It 'al limite di sessioni attive non parte niente, nemmeno la registrazione della passata' {
        $i = script:New-InTest; script:Set-Run $i 'failed'
        $c = script:New-Contesto; $c.SessioniAttive = $script:AlLimite
        @(Get-Azioni -Istantanea $i -Contesto $c).Count | Should -Be 0
    }

    It 'una passata per tipo di attesa: la stessa attesa, anche dopo un cambio di stato o con i contatori ripartiti, va dritta' {
        # i giri attraversano gli stati (In review, In development, di nuovo In review): la chiave non dipende dall'ingresso
        $i = script:New-GiriAlLimite; $i.Storia[0].Rev = 30
        $i.StatoCard.passateFatte = @('troppi giri di revisione')
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('MettiInAttesa')
        $r[0].Per | Should -Be 'limite'
    }

    It 'un altro tipo di attesa ha la sua passata' {
        $i = script:New-InTest; script:Set-Run $i 'failed'
        $i.StatoCard.passateFatte = @('troppi giri di revisione')
        @((Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Tipo) | Should -Be @('AvviaPassataAttesa', 'LanciaSessione')
    }

    It 'una persona toglie l on-hold (<Per>): l elenco delle passate si svuota prima di decidere' -ForEach @(
        @{ Per = 'limite' }
        @{ Per = 'deploy' }
    ) {
        $i = script:New-GiriAlLimite; $i.StatoCard.inAttesaPer = $Per
        $i.StatoCard.passateFatte = @('troppi giri di revisione')
        @((script:Senza-Mentore (Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))).Tipo) | Should -Be @('AzzeraPassateAttesa', 'AzzeraContatori', 'SpostaCard', 'LanciaSessione')
    }

    It 'una persona toglie l on-hold e l attesa si ripresenta subito: ha di nuovo la sua passata' {
        $i = script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare'; $i.StatoCard.inAttesaPer = 'limite'
        $i.StatoCard.passateFatte = @('nessuna PR da completare sul ramo della card')
        @((script:Senza-Mentore (Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))).Tipo) | Should -Be @('AzzeraPassateAttesa', 'AzzeraContatori', 'AvviaPassataAttesa', 'LanciaSessione')
    }

    It 'una persona toglie l on-hold per sessione: l elenco si svuota e la sessione riprende' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'bloccato'; $i.StatoCard.inAttesaPer = 'sessione'
        $i.StatoCard.passateFatte = @('senzaEsito')
        $r = @(script:Senza-Mentore (Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)))
        @($r.Tipo) | Should -Be @('AzzeraPassateAttesa', 'LanciaSessione')
        $r[1].Ruolo | Should -Be 'dev'; $r[1].Riprendi | Should -BeTrue
        $r[1].Contains('DopoPassata') | Should -BeFalse
    }

    It 'senza passate fatte l on-hold tolto non aggiunge niente' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'bloccato'; $i.StatoCard.inAttesaPer = 'sessione'
        @((script:Senza-Mentore (Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))).Tipo) | Should -Be @('LanciaSessione')
    }

    It 'il fatto del responsabile non e una persona: l elenco non si svuota' {
        $r = @(Get-Azioni -Istantanea (script:New-DopoPassata 'fatto') -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Not -Contain 'AzzeraPassateAttesa'
    }

    It 'l attesa che nasce da una sessione del responsabile va dritta alla persona' {
        $i = script:New-Ist 'nuova'; script:Set-Sessione $i 'responsabile' 'fatto' -Fine '2026-11-01T10:05:00Z'
        @((Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Tipo) | Should -Be @('MettiInAttesa')
    }

    It 'la sessione del responsabile finita senza ESITO va dritta alla persona' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'responsabile' $null
        @((Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Tipo) | Should -Be @('MettiInAttesa')
    }

    It 'responsabile fatto dopo un deploy fallito: si rilancia il deploy come quando si toglie il tag, e la passata si chiude' {
        $i = script:New-DopoPassata 'fatto'
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('ChiudiPassataAttesa', 'AzzeraContatori', 'AzzeraDeploy', 'AccodaDeployTest')
        $r[0].Ruolo | Should -Be 'reviewer'
    }

    It 'responsabile fatto per una sessione: riprende la sessione del ruolo di prima, e le dice che e passato il responsabile' {
        $i = script:New-Ist 'inCollaudo' 'inDeployTest'
        script:Set-Sessione $i 'collaudatore' 'bloccato' 'login rifiutato' -Fine '2026-11-02T10:00:00Z'
        $i.Storia[0].Quando = '2026-11-01T10:00:00Z'
        $i.StatoCard.ultimaSessione['responsabile'] = @{ id = 's-resp'; fine = '2026-11-04T10:00:00Z'; esito = 'fatto'; motivo = 'attesa' }
        $i.StatoCard.ultimoRuolo = 'responsabile'
        $i.StatoCard.attesaInEsame = @{ motivo = 'il collaudatore non riesce a provare'; per = 'sessione'; ruolo = 'collaudatore'; chiave = 'il collaudatore non riesce a provare' }
        $i.StatoCard.passateFatte = @('il collaudatore non riesce a provare')
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('ChiudiPassataAttesa', 'LanciaSessione')
        $r[1].Ruolo | Should -Be 'collaudatore'; $r[1].Motivo | Should -Be 'ripresa'; $r[1].Riprendi | Should -BeTrue
        $r[1].DopoPassata | Should -BeTrue
    }

    It 'responsabile fatto, per limite, e la stessa attesa si ripresenta: va dritta alla persona' {
        $i = script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare'
        script:Set-Sessione $i 'collaudatore' 'superata' -Fine '2026-11-02T10:00:00Z'
        $i.StatoCard.ultimaSessione['responsabile'] = @{ id = 's-resp'; fine = '2026-11-04T10:00:00Z'; esito = 'fatto'; motivo = 'attesa' }
        $i.StatoCard.ultimoRuolo = 'responsabile'
        $i.StatoCard.attesaInEsame = @{ motivo = 'nessuna PR da completare sul ramo della card'; per = 'limite'; ruolo = 'collaudatore'; chiave = 'nessuna PR da completare sul ramo della card' }
        $i.StatoCard.passateFatte = @('nessuna PR da completare sul ramo della card')
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('ChiudiPassataAttesa', 'AzzeraContatori', 'MettiInAttesa')
        $r[2].Per | Should -Be 'limite'
    }

    It 'responsabile bloccato: on-hold con il motivo di prima e il per di prima, la diagnosi e sulla card' {
        $i = script:New-DopoPassata 'bloccato'
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('ChiudiPassataAttesa', 'MettiInAttesa')
        $r[0].Ruolo | Should -Be 'reviewer'
        $r[1].Per | Should -Be 'deploy'
        $r[1].Motivo | Should -Be 'deploy in Test fallito (run 9) (il responsabile ha guardato: la sua diagnosi e nel commento sulla card)'
        $r[1].Contains('Diretta') | Should -BeFalse
        $r[1].Contains('TipoAttesa') | Should -BeFalse
    }

    It 'responsabile domande con la card in Needs clarification: la persona risponde li, nessun on-hold' {
        $i = script:New-Ist 'daChiarire' 'inSviluppo'
        script:Set-Sessione $i 'dev' 'fatto'
        $i.StatoCard.ultimaSessione['responsabile'] = @{ id = 's-resp'; fine = '2026-11-04T10:00:00Z'; esito = 'domande'; motivo = 'attesa' }
        $i.StatoCard.ultimoRuolo = 'responsabile'
        $i.StatoCard.attesaInEsame = @{ motivo = 'troppe validazioni rosse di fila'; per = 'limite'; ruolo = 'dev'; chiave = 'troppe validazioni rosse di fila' }
        @((Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Tipo) | Should -Be @('ChiudiPassataAttesa')
    }

    It 'responsabile domande fuori da Needs clarification: on-hold con il motivo di prima e il rimando alle domande' {
        # le transizioni del responsabile verso Needs clarification valgono solo da New e In development (config/ruoli.json):
        # da Deploying to test la card resta dov'e
        $r = @(Get-Azioni -Istantanea (script:New-DopoPassata 'domande') -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('ChiudiPassataAttesa', 'MettiInAttesa')
        $r[1].Per | Should -Be 'deploy'
        $r[1].Motivo | Should -Be 'deploy in Test fallito (run 9) (il responsabile ha domande per te: sono nel commento sulla card)'
    }

    It 'responsabile finito senza ESITO nella passata: on-hold dritto, la passata resta aperta' {
        $i = script:New-DopoPassata $null
        @((Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Tipo) | Should -Be @('MettiInAttesa')
    }

    It 'D39 sul responsabile in passata: tolto il tag riprende il responsabile, l esito vecchio non si applica' {
        # la sessione del responsabile e stata fermata da Close-Sessione (un ruolo in sola lettura che ha scritto): l'esito
        # che aveva scritto resta in ultimaSessione ma non vale
        $i = script:New-DopoPassata 'fatto'; $i.StatoCard.inAttesaPer = 'sessione'
        $r = @(script:Senza-Mentore (Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)))
        @($r.Tipo) | Should -Be @('AzzeraPassateAttesa', 'LanciaSessione')
        $r[1].Ruolo | Should -Be 'responsabile'; $r[1].Motivo | Should -Be 'ripresa'; $r[1].Riprendi | Should -BeTrue
    }

    It 'D39 sul responsabile in passata, sessione chiusa per silenzio o errore: tolto il tag riprende il responsabile' {
        $i = script:New-DopoPassata $null; $i.StatoCard.inAttesaPer = 'sessione'
        $i.StatoCard.ultimaSessione['responsabile'].fine = $null
        $r = @(script:Senza-Mentore (Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)))
        $r[-1].Tipo | Should -Be 'LanciaSessione'
        $r[-1].Ruolo | Should -Be 'responsabile'; $r[-1].Riprendi | Should -BeTrue
    }
}

# La rete di sicurezza: una card non resta mai ferma in silenzio dopo il responsabile.
Describe 'Get-Decisione: il responsabile ha finito e nessuna regola sa come proseguire' {
    It 'motivo <Motivo>, esito <Esito>, card in <Stato>: on-hold dritto con il rimando al suo commento' -ForEach @(
        # la passata finita con l'attesa in esame persa
        @{ Stato = 'inRevisione'; Motivo = 'attesa'; Esito = 'bloccato' }
        @{ Stato = 'inSviluppo'; Motivo = 'attesa'; Esito = 'bloccato' }
        @{ Stato = 'inRevisione'; Motivo = 'attesa'; Esito = 'fatto' }
        # domande su un bivio o un blocco di dev senza spostare la card in Needs clarification
        @{ Stato = 'inSviluppo'; Motivo = 'bivio'; Esito = 'domande' }
        @{ Stato = 'inSviluppo'; Motivo = 'bloccato'; Esito = 'domande' }
    ) {
        $i = script:New-Ist $Stato
        script:Set-Sessione $i 'dev' 'fatto' -Task 61; script:Set-Task $i @{ 61 = 'aperto' }
        script:Set-Sessione $i 'responsabile' $Esito 'il mio commento' -Fine '2026-11-04T10:00:00Z'
        $i.StatoCard.ultimaSessione['responsabile'].motivo = $Motivo
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('MettiInAttesa')
        $r[0].Per | Should -Be 'sessione'
        $r[0].Motivo | Should -Be 'il responsabile ha finito ma nessuna regola sa come proseguire: leggi il suo commento'
    }

    It 'non scatta in Needs clarification: la card aspetta le risposte di una persona' {
        $i = script:New-Ist 'daChiarire' 'inSviluppo'
        script:Set-Sessione $i 'responsabile' 'domande' -Fine '2026-11-04T10:00:00Z'
        $i.StatoCard.ultimaSessione['responsabile'].motivo = 'bivio'
        @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Count | Should -Be 0
    }

    It 'non scatta per un motivo che ha le sue regole (<Motivo>)' -ForEach @(
        @{ Motivo = 'verificaInTest' }
        @{ Motivo = 'commento' }
    ) {
        $i = script:New-InTest; script:Set-Stato $i 'inProvaUmana'; $i.StatoCard.avvisi = @('testPronto@7')
        script:Set-Sessione $i 'responsabile' 'fatto' -Fine '2026-11-04T10:00:00Z'
        $i.StatoCard.ultimaSessione['responsabile'].motivo = $Motivo
        @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Count | Should -Be 0
    }

    It 'non scatta con una sessione del responsabile non finita' {
        $i = script:New-Ist 'inRevisione'
        script:Set-Sessione $i 'responsabile' 'bloccato'
        $i.StatoCard.ultimaSessione['responsabile'].fine = $null
        $i.StatoCard.ultimaSessione['responsabile'].motivo = 'bivio'
        @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)).Count | Should -Be 0
    }
}

# D43: i parametri del deploy in Test li sceglie il responsabile con card.ps1 deploy; lo smistatore li verifica sull'elenco
# dei parametri deploy* dello YAML del ramo e accoda la run con tutti quei parametri.
Describe 'Get-Decisione: il deploy in Test scelto dal responsabile (D43)' {
    It 'accoda il deploy con tutti i parametri scelti' {
        $i = script:New-InTest; $i.Deploy = @{ Scelta = @('deployDatabases', 'deployStime'); AmmessiLetti = $true; Ammessi = @('deployStime', 'deployDatabases') }
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('AccodaDeployTest')
        @($r[0].Parametri) | Should -Be @('deployDatabases', 'deployStime')
        $r[0].Rev | Should -Be 7
    }

    It 'senza la scelta del responsabile niente deploy: la passata del responsabile con il motivo' -ForEach @(
        @{ Caso = 'nessun commento di deploy'; Deploy = @{ Scelta = $null; Ammessi = $null } }
        @{ Caso = 'un commento senza nomi'; Deploy = @{ Scelta = @(); AmmessiLetti = $true; Ammessi = @('deployStime') } }
        @{ Caso = 'l istantanea non porta il deploy'; Deploy = $null }
    ) {
        $i = script:New-InTest; $i.Deploy = $Deploy
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('AvviaPassataAttesa', 'LanciaSessione') -Because $Caso
        $r[0].Motivo | Should -Be 'manca la scelta del deploy in Test del responsabile'
        $r[0].Per | Should -Be 'deploy'
        $r[1].Ruolo | Should -Be 'responsabile'; $r[1].Motivo | Should -Be 'attesa'
        $r[1].Allegato | Should -Match 'manca la scelta del deploy in Test del responsabile'
    }

    It 'un nome che lo YAML del ramo non ha piu: niente deploy, la passata del responsabile con il nome' {
        $i = script:New-InTest; $i.Deploy = @{ Scelta = @('deployStime', 'deployVecchio', 'allowDatabaseDataLoss'); AmmessiLetti = $true; Ammessi = @('deployStime') }
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('AvviaPassataAttesa', 'LanciaSessione')
        $r[0].Motivo | Should -Be 'parametro di deploy sconosciuto: deployVecchio, allowDatabaseDataLoss'
        $r[0].Per | Should -Be 'deploy'
    }

    It 'il confronto dei nomi tiene conto di maiuscole e minuscole' {
        $i = script:New-InTest; $i.Deploy = @{ Scelta = @('DeployStime'); AmmessiLetti = $true; Ammessi = @('deployStime') }
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        $r[0].Motivo | Should -Be 'parametro di deploy sconosciuto: DeployStime'
    }

    It 'dopo la passata la stessa attesa va dritta alla persona, on-hold per deploy' -ForEach @(
        @{ Deploy = @{ Scelta = $null; Ammessi = $null }; Atteso = 'manca la scelta del deploy in Test del responsabile' }
        @{ Deploy = @{ Scelta = @('deployVecchio'); AmmessiLetti = $true; Ammessi = @('deployStime') }; Atteso = 'parametro di deploy sconosciuto: deployVecchio' }
    ) {
        $i = script:New-InTest; $i.Deploy = $Deploy
        script:Set-PassataFatta $i
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('MettiInAttesa')
        $r[0].Motivo | Should -Be $Atteso
        $r[0].Per | Should -Be 'deploy'
    }

    It 'il responsabile scrive la scelta e chiude fatto: la passata si chiude e il deploy si accoda' {
        $i = script:New-InTest; $i.Deploy = @{ Scelta = @('deployStime'); AmmessiLetti = $true; Ammessi = @('deployStime') }
        $i.StatoCard.ultimaSessione['responsabile'] = @{ id = 's-resp'; fine = '2026-11-04T10:00:00Z'; esito = 'fatto'; motivo = 'attesa' }
        $i.StatoCard.ultimoRuolo = 'responsabile'
        $i.StatoCard.attesaInEsame = @{ motivo = 'manca la scelta del deploy in Test del responsabile'; per = 'deploy'; ruolo = 'reviewer'; chiave = 'manca la scelta del deploy in Test del responsabile' }
        $i.StatoCard.passateFatte = @('manca la scelta del deploy in Test del responsabile')
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('ChiudiPassataAttesa', 'AzzeraContatori', 'AccodaDeployTest')
        @($r[2].Parametri) | Should -Be @('deployStime')
    }

    It 'senza l elenco dei parametri (nessun ramo da leggere) non giudica i nomi: decide l azione, che senza ramo si ferma' {
        $i = script:New-InTest; $i.Deploy = @{ Scelta = @('deployStime'); Ammessi = $null }
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('AccodaDeployTest')
    }

    It 'con un altra card dello stesso componente in Test torna In review prima di guardare la scelta' {
        $i = script:New-InTest; $i.Deploy = @{ Scelta = $null; Ammessi = $null }
        $c = script:New-Contesto; $c.InTestPerComponente = @{ stime = @(100, 200) }
        $r = @(Get-Azioni -Istantanea $i -Contesto $c)
        @($r.Tipo) | Should -Be @('RiportaIndietro')
    }
}

Describe 'Get-Decisione: l elenco dei parametri del deploy, letto, vuoto o illeggibile (D43)' {
    It 'un elenco letto e vuoto (lo YAML non ha booleani deploy*) rifiuta ogni nome' {
        $i = script:New-InTest; $i.Deploy = @{ Scelta = @('deployStime'); AmmessiLetti = $true; Ammessi = @() }
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('AvviaPassataAttesa', 'LanciaSessione')
        $r[0].Motivo | Should -Be 'parametro di deploy sconosciuto: deployStime'
    }

    It 'un elenco che non si e potuto leggere diventa un attesa con l errore, che passa dal responsabile' {
        $i = script:New-InTest; $i.Deploy = @{ Scelta = @('deployStime'); AmmessiLetti = $false; ErroreAmmessi = 'pipeline 115 non trovata' }
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('AvviaPassataAttesa', 'LanciaSessione')
        $r[0].Motivo | Should -Be 'non riesco a leggere i parametri del deploy in Test: pipeline 115 non trovata'
        $r[0].Per | Should -Be 'deploy'
        $r[0].Chiave | Should -Be 'parametriDeployIlleggibili'
    }

    It 'i deploy* dell elenco non scelti vanno nella run come spenti' {
        $i = script:New-InTest; $i.Deploy = @{ Scelta = @('deployStime'); AmmessiLetti = $true; Ammessi = @('deployStime', 'deployDatabases', 'deployApi') }
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r[0].Parametri) | Should -Be @('deployStime')
        @($r[0].Spenti) | Should -Be @('deployDatabases', 'deployApi')
    }
}

Describe 'Test-DeployDaLeggere: commenti e YAML solo prima di accodare il deploy (D43)' {
    It '<Caso>' -ForEach @(
        @{ Caso = 'in Deploying to test senza run: si legge'; Run = $null; Id = $null; Dopo = $null; Atteso = $true }
        @{ Caso = 'run accodata in questo ingresso, in corso: non si legge'; Run = @{ Stato = 'inProgress'; Esito = $null }; Id = 9; Dopo = 7; Atteso = $false }
        @{ Caso = 'run riuscita di questo ingresso: non si legge'; Run = @{ Stato = 'completed'; Esito = 'succeeded' }; Id = 9; Dopo = 7; Atteso = $false }
        @{ Caso = 'run di un ingresso precedente: si legge'; Run = @{ Stato = 'completed'; Esito = 'succeeded' }; Id = 9; Dopo = 3; Atteso = $true }
        @{ Caso = 'run fallita: si legge, il deploy si riaccoda quando si toglie il tag'; Run = @{ Stato = 'completed'; Esito = 'failed' }; Id = 9; Dopo = 7; Atteso = $true }
    ) {
        $i = script:New-InTest; $i.StatoCard.runId = $Id; $i.StatoCard.runDopoRev = $Dopo
        $i.Run = if ($Run) { [pscustomobject]$Run } else { $null }
        Test-DeployDaLeggere -Card $i.Card -Storia $i.Storia -StatoCard $i.StatoCard -Run $i.Run | Should -Be $Atteso
    }
}

# D51: la quota e una sola per tutti i ruoli: in pausa dopo il limite di token, o oltre la riserva settimanale, non parte
# nessuna sessione; dopo la pausa la sessione fermata riprende da sola, senza on-hold.
Describe 'Get-Decisione: la quota (D51)' {
    BeforeAll {
        function script:New-ContestoQuota($Quota) {
            $c = script:New-Contesto
            $c.Adesso = '2026-11-23T10:00:00Z'
            $c.Quota = $Quota
            $c
        }
    }

    It 'la pausa per il limite di token, ancora nel futuro, ferma i lanci con il motivo quota' {
        $c = script:New-ContestoQuota @{ pausaFino = '2026-11-23T12:05:00Z'; finestraPausa = 'five_hour' }
        $d = Get-Decisione -Istantanea (script:New-Ist 'nuova') -Contesto $c
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo.Tipo | Should -Be 'quota'
        $d.Motivo.Causa | Should -Be 'limite'
        $d.Motivo.Ruolo | Should -Be 'responsabile'
        (ConvertTo-DataUtc $d.Motivo.Fino) | Should -Be ([datetime]::Parse('2026-11-23T12:05:00Z').ToUniversalTime())
    }

    It 'la pausa gia passata non blocca' {
        $c = script:New-ContestoQuota @{ pausaFino = '2026-11-23T09:59:00Z' }
        $d = Get-Decisione -Istantanea (script:New-Ist 'nuova') -Contesto $c
        @($d.Azioni | Where-Object { $_.Tipo -eq 'LanciaSessione' }).Count | Should -Be 1
        $d.Motivo | Should -BeNullOrEmpty
    }

    It 'la riserva settimanale (seven_day oltre la soglia, reset nel futuro) ferma i lanci' {
        $c = script:New-ContestoQuota @{ sevenDay = @{ utilization = 0.71; resetsAt = '2026-11-27T10:00:00Z' } }
        $d = Get-Decisione -Istantanea (script:New-Ist 'nuova') -Contesto $c
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo.Tipo | Should -Be 'quota'; $d.Motivo.Causa | Should -Be 'riserva'
        $d.Motivo.Uso | Should -Be 0.71
        $d.Motivo.Ruolo | Should -Be 'responsabile'
    }

    It 'sotto la soglia settimanale non blocca' {
        $c = script:New-ContestoQuota @{ sevenDay = @{ utilization = 0.40; resetsAt = '2026-11-27T10:00:00Z' } }
        $d = Get-Decisione -Istantanea (script:New-Ist 'nuova') -Contesto $c
        @($d.Azioni | Where-Object { $_.Tipo -eq 'LanciaSessione' }).Count | Should -Be 1
    }

    It 'una lettura con resetsAt gia passato non blocca, anche con l uso alto' {
        $c = script:New-ContestoQuota @{ sevenDay = @{ utilization = 0.95; resetsAt = '2026-11-22T10:00:00Z' } }
        $d = Get-Decisione -Istantanea (script:New-Ist 'nuova') -Contesto $c
        @($d.Azioni | Where-Object { $_.Tipo -eq 'LanciaSessione' }).Count | Should -Be 1
        $d.Motivo | Should -BeNullOrEmpty
    }

    It 'senza quota nel contesto (quota vuota) non blocca' {
        $c = script:New-ContestoQuota @{}
        $d = Get-Decisione -Istantanea (script:New-Ist 'nuova') -Contesto $c
        @($d.Azioni | Where-Object { $_.Tipo -eq 'LanciaSessione' }).Count | Should -Be 1
    }

    It 'inAttesaPer quota senza tag: riprende la sessione del ruolo con DopoQuota, e passateFatte resta' {
        $i = script:New-Ist 'inSviluppo' 'nuova'
        script:Set-Sessione $i 'dev' $null
        $i.StatoCard.inAttesaPer = 'quota'
        $i.StatoCard.passateFatte = @('chiave-di-prima')
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-ContestoQuota @{}))
        @($r.Tipo) | Should -Be @('LanciaSessione')
        $r[0].Ruolo | Should -Be 'dev'; $r[0].Motivo | Should -Be 'ripresa'; $r[0].Riprendi | Should -BeTrue
        $r[0].DopoQuota | Should -BeTrue
        $i.StatoCard.passateFatte | Should -Be @('chiave-di-prima')
    }

    It 'inAttesaPer sessione (una persona ha tolto il tag) non porta DopoQuota' {
        $i = script:New-Ist 'inSviluppo' 'nuova'
        script:Set-Sessione $i 'dev' $null
        $i.StatoCard.inAttesaPer = 'sessione'
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-ContestoQuota @{}))
        $r[-1].Contains('DopoQuota') | Should -BeFalse
    }

    It 'inAttesaPer quota durante la pausa: la ripresa e un lancio come gli altri e il cancello lo ferma' {
        $i = script:New-Ist 'inSviluppo' 'nuova'
        script:Set-Sessione $i 'dev' $null
        $i.StatoCard.inAttesaPer = 'quota'
        $c = script:New-ContestoQuota @{ pausaFino = '2026-11-23T12:05:00Z' }
        $d = Get-Decisione -Istantanea $i -Contesto $c
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo.Tipo | Should -Be 'quota'; $d.Motivo.Ruolo | Should -Be 'dev'
    }

    It 'Format-MotivoCoda: pausa per il limite e riserva settimanale' {
        $fino = [datetime]::Parse('2026-11-23T12:05:00Z').ToUniversalTime()
        $ora = $fino.ToLocalTime().ToString('HH:mm')
        Format-MotivoCoda @{ Tipo = 'quota'; Causa = 'limite'; Fino = $fino.ToString('o') } | Should -Be "in coda, pausa per il limite di token fino alle $ora"
        $t = Format-MotivoCoda @{ Tipo = 'quota'; Causa = 'riserva'; Fino = $fino.ToString('o'); Uso = 0.71; Soglia = 0.7 }
        $t | Should -BeLike 'in coda, riserva settimanale raggiunta: uso 71%, soglia 70%, fino a *'
    }
}

# D51: tre on-hold che lo smistatore toglie da solo, solo quando un dato dice che la causa non c'e piu.
Describe 'Get-Decisione: on-hold che si tolgono da soli (D51)' {
    BeforeAll {
        function script:New-ContestoOra { $c = script:New-Contesto; $c.Adesso = '2026-11-23T10:00:00Z'; $c }
        # una card in on-hold per il limite di prima di D51: sessione fallita con il testo del limite, nessun causaAttesa
        function script:New-InHoldLimite([string]$Reset = '2026-11-23T08:00:00Z') {
            $i = script:New-Ist 'inRevisione' 'inSviluppo'
            $i.Card.Tag = @($script:Stati.tagAgenti, $script:Stati.tagAttesa)
            script:Set-Sessione $i 'reviewer' $null "You've hit your 5-hour limit - resets 9pm"
            $i.StatoCard.ultimaSessione['reviewer'].errore = $true
            $i.StatoCard.inAttesaPer = 'sessione'
            if ($Reset) { $i.LimiteUltimaSessione = @{ Finestra = 'five_hour'; Reset = [datetime]::Parse($Reset).ToUniversalTime() } }
            $i
        }
        function script:New-InHoldRosse {
            $i = script:New-Ist 'inSviluppo' 'pronto'
            $i.Card.Tag = @($script:Stati.tagAgenti, $script:Stati.tagAttesa)
            $i.StatoCard.inAttesaPer = 'limite'; $i.StatoCard.rosseDiFila = 3
            $i.Pr = [pscustomobject]@{ Id = 7; Validazione = 'verde'; BuildId = 50 }
            $i
        }
        function script:New-InHoldSilenzio([string]$Causa = 'silenzio') {
            $i = script:New-Ist 'inSviluppo' 'pronto'
            $i.Card.Tag = @($script:Stati.tagAgenti, $script:Stati.tagAttesa)
            script:Set-Sessione $i 'dev' $null
            $i.StatoCard.inAttesaPer = 'sessione'; $i.StatoCard.causaAttesa = $Causa
            $i
        }
    }

    It 'limite di prima di D51 con il reset passato (piu il margine): TogliAttesa con Per quota' {
        $d = Get-Decisione -Istantanea (script:New-InHoldLimite) -Contesto (script:New-ContestoOra)
        $d.Motivo | Should -BeNullOrEmpty
        @($d.Azioni).Count | Should -Be 1
        $d.Azioni[0].Tipo | Should -Be 'TogliAttesa'
        $d.Azioni[0].Per | Should -Be 'quota'
        $d.Azioni[0].Causa | Should -Match 'limite'
    }
    It 'limite con il reset non ancora passato, o dentro il margine: resta on-hold' {
        $d = Get-Decisione -Istantanea (script:New-InHoldLimite '2026-11-23T11:00:00Z') -Contesto (script:New-ContestoOra)
        @($d.Azioni).Count | Should -Be 0; $d.Motivo.Tipo | Should -Be 'onHold'
        $margine = [double]$script:Limiti.margineQuotaMinuti
        $dentro = [datetime]::Parse('2026-11-23T10:00:00Z').ToUniversalTime().AddMinutes(-$margine + 1).ToString('o')
        $d = Get-Decisione -Istantanea (script:New-InHoldLimite $dentro) -Contesto (script:New-ContestoOra)
        $d.Motivo.Tipo | Should -Be 'onHold'
    }
    It 'limite con il reset non leggibile: resta on-hold' {
        $d = Get-Decisione -Istantanea (script:New-InHoldLimite $null) -Contesto (script:New-ContestoOra)
        $d.Motivo.Tipo | Should -Be 'onHold'
    }
    It 'sessione fallita con un testo che non e il limite: resta on-hold anche con un reset nell istantanea' {
        $i = script:New-InHoldLimite
        $i.StatoCard.ultimaSessione['reviewer'].testo = 'Errore: comando negato'
        (Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Motivo.Tipo | Should -Be 'onHold'
    }
    It 'un fermo di D39 o una sessione fallita di oggi (causaAttesa scritto) non si scioglie, nemmeno con il testo del limite' {
        foreach ($causa in 'scritture', 'fallita') {
            $i = script:New-InHoldLimite; $i.StatoCard.causaAttesa = $causa
            (Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Motivo.Tipo | Should -Be 'onHold'
        }
    }

    It 'validazioni rosse di fila con la validazione ora verde: TogliAttesa con Per limite' {
        $d = Get-Decisione -Istantanea (script:New-InHoldRosse) -Contesto (script:New-ContestoOra)
        $d.Azioni[0].Tipo | Should -Be 'TogliAttesa'; $d.Azioni[0].Per | Should -Be 'limite'
        $d.Azioni[0].Causa | Should -Match 'verde'
    }
    It 'secondo rilancio di D38 (rilanci 1, dev con esito rilancia) con la validazione verde: TogliAttesa con Per limite' {
        $i = script:New-InHoldRosse; $i.StatoCard.rosseDiFila = 0; $i.StatoCard.rilanci = 1
        script:Set-Sessione $i 'dev' 'rilancia'
        (Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Azioni[0].Tipo | Should -Be 'TogliAttesa'
    }
    It 'validazione rossa, in corso o assente: resta on-hold' {
        foreach ($v in 'rossa', 'inCorso', 'scaduta') {
            $i = script:New-InHoldRosse; $i.Pr.Validazione = $v
            (Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Motivo.Tipo | Should -Be 'onHold' -Because $v
        }
        $i = script:New-InHoldRosse; $i.Pr = $null
        (Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Motivo.Tipo | Should -Be 'onHold'
    }
    It 'on-hold per limite ma non per le rosse (contatori sotto soglia, nessun rilancio) con la PR verde: resta on-hold' {
        $i = script:New-InHoldRosse; $i.StatoCard.rosseDiFila = 1
        (Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Motivo.Tipo | Should -Be 'onHold'
    }

    It 'secondo fermo per silenzio o morta (on-hold con causaAttesa): resta on-hold, la prima volta non c e on-hold e lo decide Close-Sessione' {
        foreach ($causa in 'silenzio', 'morta') {
            $i = script:New-InHoldSilenzio $causa; $i.StatoCard.ripreseAutomatiche = 1
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)
            @($d.Azioni).Count | Should -Be 0 -Because $causa
            $d.Motivo.Tipo | Should -Be 'onHold'
        }
    }
    It 'rosse: giri di revisione o di collaudo al limite con rilanci 1 e PR verde: resta on-hold' {
        $i = script:New-InHoldRosse; $i.StatoCard.rosseDiFila = 0; $i.StatoCard.rilanci = 1
        script:Set-Sessione $i 'dev' 'rilancia'
        $i.StatoCard.giriRevisione = [int]$script:Limiti.giriRevisione
        (Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Motivo.Tipo | Should -Be 'onHold'
        $i.StatoCard.giriRevisione = 0; $i.StatoCard.giriCollaudo = [int]$script:Limiti.giriCollaudo
        (Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Motivo.Tipo | Should -Be 'onHold'
        $i.StatoCard.giriCollaudo = 0
        (Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Azioni[0].Tipo | Should -Be 'TogliAttesa'
    }
    It 'rosse: rilanci 1 ma l ultima sessione di dev non ha esito rilancia: resta on-hold' {
        $i = script:New-InHoldRosse; $i.StatoCard.rosseDiFila = 0; $i.StatoCard.rilanci = 1
        script:Set-Sessione $i 'dev' 'fatto'
        (Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Motivo.Tipo | Should -Be 'onHold'
    }
    It 'silenzio con ripreseAutomatiche gia 1: resta on-hold' {
        $i = script:New-InHoldSilenzio; $i.StatoCard.ripreseAutomatiche = 1
        $d = Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)
        @($d.Azioni).Count | Should -Be 0; $d.Motivo.Tipo | Should -Be 'onHold'
    }
    It 'il deploy resta on-hold sempre, anche con causa, validazione verde e limite passato' {
        $i = script:New-InHoldRosse; $i.StatoCard.inAttesaPer = 'deploy'; $i.StatoCard.causaAttesa = 'silenzio'
        $i.StatoCard.ultimaSessione['dev'] = @{ id = 'x'; errore = $true; testo = 'hit your limit' }; $i.StatoCard.ultimoRuolo = 'dev'
        $i.LimiteUltimaSessione = @{ Reset = [datetime]::Parse('2026-11-01T00:00:00Z').ToUniversalTime() }
        (Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Motivo.Tipo | Should -Be 'onHold'
    }
    It 'senza on-hold (nessun tag) Get-AttesaSciolta non entra in gioco' {
        $i = script:New-InHoldRosse; $i.Card.Tag = @($script:Stati.tagAgenti)
        @((Get-Decisione -Istantanea $i -Contesto (script:New-ContestoOra)).Azioni | ForEach-Object Tipo) | Should -Not -Contain 'TogliAttesa'
    }
    It 'Get-AttivitaOperatore: un on-hold che sta per sciogliersi si mostra ancora come on-hold' {
        $i = script:New-InHoldLimite; $c = script:New-ContestoOra
        $a = Get-AttivitaOperatore -Istantanea $i -Contesto $c -Decisione (Get-Decisione -Istantanea $i -Contesto $c)
        $a.Attivita | Should -Be 'sblocca'; $a.Ferma | Should -BeTrue
    }

    It 'il giro dopo TogliAttesa (tag tolto, segno dello smistatore): passateFatte resta e niente azzeramenti' {
        $i = script:New-Ist 'inSviluppo' 'pronto'
        script:Set-Sessione $i 'dev' $null
        $i.StatoCard.inAttesaPer = 'sessione'; $i.StatoCard.attesaToltaDaSmistatore = $true
        $i.StatoCard.passateFatte = @('chiave-di-prima'); $i.StatoCard.ripreseAutomatiche = 1
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-ContestoOra))
        @($r.Tipo) | Should -Be @('LanciaSessione')
        $r[0].Motivo | Should -Be 'ripresa'; $r[0].Riprendi | Should -BeTrue
        $r[0].DopoRipresaAutomatica | Should -BeTrue
        $i.StatoCard.passateFatte | Should -Be @('chiave-di-prima')
    }
    It 'lo stesso giro senza il segno (una persona ha tolto il tag) svuota le passate e azzera ripreseAutomatiche' {
        $i = script:New-Ist 'inSviluppo' 'pronto'
        script:Set-Sessione $i 'dev' $null
        $i.StatoCard.inAttesaPer = 'sessione'
        $i.StatoCard.passateFatte = @('chiave-di-prima'); $i.StatoCard.ripreseAutomatiche = 1
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-ContestoOra))
        @($r.Tipo) | Should -Be @('AzzeraPassateAttesa', 'LanciaSessione')
    }
    It 'una persona che toglie il tag con le passate vuote ma ripreseAutomatiche acceso azzera comunque il contatore' {
        $i = script:New-Ist 'inSviluppo' 'pronto'
        script:Set-Sessione $i 'dev' $null
        $i.StatoCard.inAttesaPer = 'sessione'; $i.StatoCard.ripreseAutomatiche = 1
        @((Get-Azioni -Istantanea $i -Contesto (script:New-ContestoOra)).Tipo) | Should -Contain 'AzzeraPassateAttesa'
    }
    It 'dopo TogliAttesa con Per quota il giro dopo riprende con DopoQuota' {
        $i = script:New-Ist 'inRevisione' 'inSviluppo'
        script:Set-Sessione $i 'reviewer' $null
        $i.StatoCard.inAttesaPer = 'quota'; $i.StatoCard.attesaToltaDaSmistatore = $true
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-ContestoOra))
        $r[-1].DopoQuota | Should -BeTrue
    }
    It 'dopo TogliAttesa con Per limite: contatori a zero e si decide dallo stato (la PR verde porta al reviewer)' {
        $i = script:New-InHoldRosse; $i.Card.Tag = @($script:Stati.tagAgenti)
        $i.StatoCard.attesaToltaDaSmistatore = $true
        script:Set-Sessione $i 'dev' 'fatto'
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-ContestoOra))
        @($r.Tipo) | Should -Contain 'AzzeraContatori'
        @($r.Tipo) | Should -Contain 'LanciaSessione'
    }
}

Describe 'Get-AzioniMentore: gli inneschi del mentore (D46)' {
    BeforeAll {
        function script:Get-Mentori($i, $c = (script:New-Contesto)) { @(Get-Azioni -Istantanea $i -Contesto $c | Where-Object { $_.Tipo -eq 'LanciaMentore' }) }
        function script:New-Persona([int]$Id, [string]$Testo = 'Cosi non va') { [pscustomobject]@{ Id = $Id; Autore = 'Anna'; Testo = $Testo; Quando = '2026-11-03T10:00:00Z' } }
        # il responsabile ha deciso su un bivio di dev: dev riparte con la sua decisione
        function script:New-Decisione([string]$Motivo = 'bloccato') {
            $i = script:New-Ist 'inSviluppo'
            script:Set-Sessione $i 'responsabile' 'fatto' 'Usa la libreria X'
            $i.StatoCard.ultimaSessione['responsabile'].motivo = $Motivo
            $i
        }
        function script:New-Rilievi {
            $i = script:New-Ist 'inRevisione'
            script:Set-Sessione $i 'reviewer' 'bloccante' 'Manca il controllo del null'
            $i
        }
        # Human test fallito: la persona riporta la card In development
        function script:New-ProvaUmana { script:New-Ist 'inSviluppo' 'inProvaUmana' 'u-titolare' }
        function script:New-BugUnito {
            $i = script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare'
            $i.Card.Tipo = 'Bug'; $i.Card | Add-Member -NotePropertyName Titolo -NotePropertyValue 'Il totale e sbagliato'
            $i.Card | Add-Member -NotePropertyName Descrizione -NotePropertyValue 'Con due righe il totale e zero'
            $i.Pr = [pscustomobject]@{ Id = 31; Stato = 'completed'; Validazione = 'verde'; BuildId = 5; UrlLog = $null }
            $i
        }
    }

    It 'decisione: dopo la decisione del responsabile il mentore corregge dev, con l allegato del lancio' {
        $m = @(script:Get-Mentori (script:New-Decisione))
        $m.Count | Should -Be 1
        @($m[0].Ruoli) | Should -Be @('dev')
        $m[0].Correttore | Should -Be 'responsabile'
        $m[0].Innesco | Should -Be 'decisione'
        $m[0].Testo | Should -Be 'Usa la libreria X'
        $m[0].Chiave | Should -Be 'decisione@s-responsabile'
    }

    It 'decisione: il responsabile che ha sbloccato un dev al bivio fa partire il mentore come per il bloccato' {
        $m = @(script:Get-Mentori (script:New-Decisione 'bivio'))
        $m.Count | Should -Be 1
        $m[0].Innesco | Should -Be 'decisione'
    }

    It 'decisione: il responsabile che riporta la card da <Motivo> non corregge dev, nessun mentore (ma il lancio dev c e)' -ForEach @(
        @{ Motivo = 'collaudoRespinto' }, @{ Motivo = 'verificaInTest' }
    ) {
        $i = script:New-Decisione $Motivo
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r | Where-Object { $_.Tipo -eq 'LanciaSessione' -and $_.Ruolo -eq 'dev' -and $_.Motivo -eq 'decisione' }).Count | Should -Be 1
        @($r | Where-Object { $_.Tipo -eq 'LanciaMentore' }).Count | Should -Be 0
    }

    # D49: la passata del responsabile (D42, motivo attesa) che riporta la card In development dopo il collaudo rilancia dev
    # con motivo decisione, ma non ha sbloccato un dev bloccato o al bivio: non e una correzione del dev.
    It 'decisione: dev rilanciato da D49 dopo la passata del responsabile non fa partire il mentore' {
        $i = script:New-Ist 'inSviluppo'
        script:Set-Sessione $i 'collaudatore' 'bloccato' '' '2026-11-02T10:00:00Z'
        $i.StatoCard.ultimaSessione['responsabile'] = @{ id = 's-resp'; fine = '2026-11-02T11:00:00Z'; esito = 'fatto'; motivo = 'attesa'; testo = 'allinea il ramo'; task = $null }
        script:Set-Task $i @{ 45 = 'aperto' }
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        @($r | Where-Object { $_.Tipo -eq 'LanciaSessione' -and $_.Ruolo -eq 'dev' -and $_.Motivo -eq 'decisione' }).Count | Should -Be 1
        @($r | Where-Object { $_.Tipo -eq 'LanciaMentore' }).Count | Should -Be 0
    }

    It 'dev lanciato per <Motivo> non e una correzione: nessun mentore' -ForEach @(
        @{ Motivo = 'task'; Mod = { param($i) script:Set-Task $i @{ 200 = 'aperto' } } }
        @{ Motivo = 'presaInCarico'; Mod = { param($i) } }
        @{ Motivo = 'rossa'; Mod = { param($i)
            script:Set-Sessione $i 'dev' 'fatto'
            $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'rossa'; BuildId = 55; UrlLog = 'http://log/55' } } }
        @{ Motivo = 'conflitti'; Mod = { param($i)
            script:Set-Sessione $i 'dev' 'fatto'
            $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'conflitti'; BuildId = 55; UrlLog = $null } } }
        @{ Motivo = 'taskSuccessivo'; Mod = { param($i)
            script:Set-Sessione $i 'dev' 'fatto' -Task 100
            script:Set-Task $i @{ 100 = 'taskChiuso'; 200 = 'aperto' } } }
    ) {
        $i = script:New-Ist 'inSviluppo'
        & $Mod $i
        $r = @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto))
        # il lancio c e, con il motivo che il test dice: altrimenti non proverebbe niente
        @($r | Where-Object { $_.Tipo -eq 'LanciaSessione' -and $_.Ruolo -eq 'dev' -and $_.Motivo -eq $Motivo }).Count | Should -Be 1
        @($r | Where-Object { $_.Tipo -eq 'LanciaMentore' }).Count | Should -Be 0
    }

    It 'rilievi: i rilievi del reviewer a dev sono una correzione di dev' {
        $r = @(Get-Azioni -Istantanea (script:New-Rilievi) -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('SpostaCard', 'LanciaSessione', 'LanciaMentore')
        @($r[2].Ruoli) | Should -Be @('dev')
        $r[2].Correttore | Should -Be 'reviewer'
        $r[2].Innesco | Should -Be 'rilievi'
        $r[2].Testo | Should -Be 'Manca il controllo del null'
        $r[2].Chiave | Should -Be 'rilievi@s-reviewer'
    }

    It 'onHoldTolto: una persona toglie l on-hold, corregge l ultimo ruolo, i commenti non letti sono il testo; la chiave e quella del commento' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'bloccato'; $i.StatoCard.inAttesaPer = 'sessione'
        $i.Commenti = @(script:New-Persona 51 'Fai cosi')
        $m = @(script:Get-Mentori $i)
        $m.Count | Should -Be 1
        @($m[0].Ruoli) | Should -Be @('dev')
        $m[0].Correttore | Should -Be 'persona'
        $m[0].Innesco | Should -Be 'onHoldTolto'
        $m[0].Testo | Should -Match 'Fai cosi'
        $m[0].Chiave | Should -Be 'commento@51'
    }

    It 'onHoldTolto: un on-hold tolto dallo smistatore (D51) o la ripresa dopo la quota non sono una persona: il commento e un commento, non un on-hold tolto' -ForEach @(
        @{ Caso = 'attesaToltaDaSmistatore'; Imposta = { param($i) $i.StatoCard.inAttesaPer = 'sessione'; $i.StatoCard.attesaToltaDaSmistatore = $true } }
        @{ Caso = 'quota'; Imposta = { param($i) $i.StatoCard.inAttesaPer = 'quota' } }
    ) {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'bloccato'
        & $Imposta $i
        $i.Commenti = @(script:New-Persona 51 'Fai cosi')
        $m = @(script:Get-Mentori $i)
        $m.Count | Should -Be 1
        $m[0].Innesco | Should -Be 'commento'
        @($m[0].Ruoli) | Should -Be @('responsabile')
    }

    It 'onHoldTolto senza ultimo ruolo: il ruolo e il responsabile' {
        $i = script:New-Ist 'inSviluppo'; $i.StatoCard.inAttesaPer = 'limite'
        $i.Commenti = @(script:New-Persona 51 'Riparti')
        $m = @(script:Get-Mentori $i)
        $m.Count | Should -Be 1
        @($m[0].Ruoli) | Should -Be @('responsabile')
        $m[0].Innesco | Should -Be 'onHoldTolto'
    }

    It 'onHoldTolto senza nessun commento di persona: niente da imparare (deploy sistemato, chiusure D39), nessun mentore' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'bloccato'; $i.StatoCard.inAttesaPer = 'limite'
        @(script:Get-Mentori $i).Count | Should -Be 0
        # i commenti degli agenti non sono di persona
        $i.Commenti = @([pscustomobject]@{ Id = 54; Autore = 'x'; Testo = '[dev] Mi fermo' })
        @(script:Get-Mentori $i).Count | Should -Be 0
    }

    It 'onHoldTolto al giro N e commento ancora non letto al giro N+1: stessa chiave, il mentore parte una volta sola' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'bloccato'; $i.StatoCard.inAttesaPer = 'sessione'
        $i.Commenti = @(script:New-Persona 51 'Fai cosi')
        $primo = @(script:Get-Mentori $i)
        $primo.Count | Should -Be 1
        # al giro dopo: l on-hold non c e piu, il commento e ancora non letto, la chiave e gia fra i fatti
        $j = script:New-Ist 'inSviluppo'; script:Set-Sessione $j 'dev' 'fatto'
        $j.Commenti = @(script:New-Persona 51 'Fai cosi')
        $j.StatoCard.mentoriFatti = @($primo[0].Chiave)
        @(script:Get-Mentori $j).Count | Should -Be 0
    }

    It 'onHoldTolto non scatta dopo la passata del responsabile: il fatto del responsabile non e una persona' {
        $i = script:New-InTest; script:Set-Run $i 'failed'
        $i.StatoCard.ultimaSessione['responsabile'] = @{ id = 's-resp'; fine = '2026-11-04T10:00:00Z'; esito = 'fatto'; motivo = 'attesa' }
        $i.StatoCard.ultimoRuolo = 'responsabile'
        $i.StatoCard.attesaInEsame = @{ motivo = 'deploy in Test fallito (run 9)'; per = 'deploy'; ruolo = 'reviewer'; chiave = 'deployFallito' }
        $i.StatoCard.passateFatte = @('deployFallito')
        @(script:Get-Mentori $i).Count | Should -Be 0
    }

    It 'onHoldTolto e commento nello stesso giro: parte un mentore solo, onHoldTolto, con i commenti nel testo' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'bloccato'; $i.StatoCard.inAttesaPer = 'sessione'
        $i.Commenti = @((script:New-Persona 51 'Fai cosi'), (script:New-Persona 52 'Anzi, cosi'))
        $m = @(script:Get-Mentori $i)
        $m.Count | Should -Be 1
        $m[0].Innesco | Should -Be 'onHoldTolto'
        $m[0].Testo | Should -Match 'Fai cosi'
        $m[0].Testo | Should -Match 'Anzi, cosi'
        $m[0].Chiave | Should -Be 'commento@52'
    }

    It 'commento: un commento di persona non letto corregge il responsabile; la chiave e l id dell ultimo' {
        $i = script:New-Ist 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata' -Fine '2026-11-03T10:00:00Z'
        $i.Commenti = @((script:New-Persona 51 'Prima cosa'), (script:New-Persona 53 'Seconda cosa'), [pscustomobject]@{ Id = 54; Autore = 'x'; Testo = '[smistatore] Sessione finita' })
        $m = @(script:Get-Mentori $i)
        $m.Count | Should -Be 1
        @($m[0].Ruoli) | Should -Be @('responsabile')
        $m[0].Correttore | Should -Be 'persona'
        $m[0].Innesco | Should -Be 'commento'
        $m[0].Testo | Should -Match 'Prima cosa'
        $m[0].Testo | Should -Match 'Seconda cosa'
        $m[0].Testo | Should -Not -Match 'Sessione finita'
        $m[0].Chiave | Should -Be 'commento@53'
    }

    It 'commento: in <Stato> gli agenti portano la card e un commento di persona corregge il responsabile' -ForEach @(
        @{ Stato = 'pronto' }, @{ Stato = 'inSviluppo' }, @{ Stato = 'inRevisione' }
        @{ Stato = 'inDeployTest' }, @{ Stato = 'inCollaudo' }, @{ Stato = 'daUnire' }
    ) {
        $i = script:New-Ist $Stato
        $i.Commenti = @(script:New-Persona 51 'Non va')
        $m = @(script:Get-Mentori $i)
        $m.Count | Should -Be 1
        $m[0].Innesco | Should -Be 'commento'
    }

    It 'commento: in <Stato> la persona risponde a domande di prodotto, o nessun agente lavora piu la card: nessun mentore' -ForEach @(
        @{ Stato = 'nuova' }, @{ Stato = 'daChiarire' }, @{ Stato = 'inProvaUmana' }, @{ Stato = 'daRilasciare' }, @{ Stato = 'inRilascio' }
    ) {
        $i = script:New-Ist $Stato
        $i.Commenti = @(script:New-Persona 51 'Ecco le risposte')
        @(script:Get-Mentori $i).Count | Should -Be 0
    }

    It 'commento: una card presa in carico con ultimoCommento=0 non lancia il mentore sui commenti della sua storia, scritti prima dell ingresso nello stato' {
        $i = script:New-Ist 'pronto' 'nuova'
        $vecchio = script:New-Persona 20 'Ecco i dettagli, prima che la card fosse pronta'; $vecchio.Quando = '2026-10-25T10:00:00Z'
        $i.Commenti = @($vecchio)
        @(script:Get-Mentori $i).Count | Should -Be 0
    }

    It 'commento: la risposta scritta in daChiarire non lancia il mentore in pronto il giro dopo' {
        # la persona risponde il 31 ottobre, la card e pronta dal 1 novembre; il commento e ancora non letto
        $i = script:New-Ist 'pronto' 'daChiarire'
        $risposta = script:New-Persona 30 'La scadenza e il 15'; $risposta.Quando = '2026-10-31T18:00:00Z'
        $i.Commenti = @($risposta)
        @(script:Get-Mentori $i).Count | Should -Be 0
    }

    It 'commento: del giro N+1 conta solo quello scritto dopo l ingresso, anche se ce n e uno vecchio non letto' {
        $i = script:New-Ist 'pronto' 'daChiarire'
        $vecchio = script:New-Persona 30 'Risposta di prima'; $vecchio.Quando = '2026-10-31T18:00:00Z'
        $nuovo = script:New-Persona 31 'Cosi non va'; $nuovo.Quando = '2026-11-02T09:00:00Z'
        $i.Commenti = @($vecchio, $nuovo)
        $m = @(script:Get-Mentori $i)
        $m.Count | Should -Be 1
        $m[0].Chiave | Should -Be 'commento@31'
        $m[0].Testo | Should -Match 'Cosi non va'
        $m[0].Testo | Should -Not -Match 'Risposta di prima'
    }

    It 'onHoldTolto: il commento scritto prima dell ingresso nello stato non conta nemmeno con l on-hold tolto' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'bloccato'; $i.StatoCard.inAttesaPer = 'sessione'
        $vecchio = script:New-Persona 51 'Commento di prima'; $vecchio.Quando = '2026-10-30T10:00:00Z'
        $i.Commenti = @($vecchio)
        @(script:Get-Mentori $i).Count | Should -Be 0
    }

    It 'commento: i soli commenti di agenti non innescano niente' {
        $i = script:New-Ist 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata' -Fine '2026-11-03T10:00:00Z'
        $i.Commenti = @([pscustomobject]@{ Id = 54; Autore = 'x'; Testo = '[responsabile] Ho deciso' })
        @(script:Get-Mentori $i).Count | Should -Be 0
    }

    It 'provaUmana: la card torna In development dalla prova in Test, correggono collaudatore e reviewer' {
        $i = script:New-ProvaUmana
        $i.Commenti = @(script:New-Persona 51 'Il pulsante non fa niente')
        $i.CommentiTutti = $i.Commenti
        $m = @(script:Get-Mentori $i | Where-Object { $_.Innesco -eq 'provaUmana' })
        $m.Count | Should -Be 1
        @($m[0].Ruoli) | Should -Be @('collaudatore', 'reviewer')
        $m[0].Correttore | Should -Be 'persona'
        $m[0].Innesco | Should -Be 'provaUmana'
        $m[0].Testo | Should -Match 'Il pulsante non fa niente'
        $m[0].Chiave | Should -Be 'provaUmana@7'
    }

    It 'provaUmana: il testo e dei commenti di persona dopo l ultimo ingresso in Human test, letti o no, piu l ultimo del responsabile' {
        $i = script:New-ProvaUmana
        # entrata in Human test il 2 novembre, uscita il 5: il commento 40 e di prima, 51 e 52 sono del giro di prova, gia consumati
        $i.Storia = @(
            [pscustomobject]@{ Rev = 3; Da = (script:Nome 'inCollaudo'); A = (script:Nome 'inProvaUmana'); Chi = 'u-richiedente'; ChiNome = 'x'; Quando = '2026-11-02T09:00:00Z' }
            [pscustomobject]@{ Rev = 7; Da = (script:Nome 'inProvaUmana'); A = (script:Nome 'inSviluppo'); Chi = 'u-richiedente'; ChiNome = 'x'; Quando = '2026-11-05T10:00:00Z' }
        )
        $i.StatoCard.ultimoCommento = 53
        $prima = script:New-Persona 40 'Commento vecchio, di prima della prova'; $prima.Quando = '2026-10-30T10:00:00Z'
        $p1 = script:New-Persona 51 'Il pulsante non fa niente'; $p1.Quando = '2026-11-03T10:00:00Z'
        $p2 = script:New-Persona 52 'Anche il filtro'; $p2.Quando = '2026-11-04T10:00:00Z'
        $resp = [pscustomobject]@{ Id = 53; Autore = 'x'; Testo = '[responsabile] Ho chiesto di riprovare'; Quando = '2026-11-04T11:00:00Z' }
        $i.Commenti = @()
        $i.CommentiTutti = @($prima, $p1, $p2, $resp)
        $m = @(script:Get-Mentori $i | Where-Object { $_.Innesco -eq 'provaUmana' })
        $m.Count | Should -Be 1
        $m[0].Testo | Should -Match 'Il pulsante non fa niente'
        $m[0].Testo | Should -Match 'Anche il filtro'
        $m[0].Testo | Should -Match 'Ho chiesto di riprovare'
        $m[0].Testo | Should -Not -Match 'Commento vecchio'
    }

    It 'provaUmana: In development da un altro stato non e una prova fallita' {
        @(script:Get-Mentori (script:New-Ist 'inSviluppo' 'pronto')).Count | Should -Be 0
    }

    It 'bug: la PR di un Bug unita porta il mentore su dev, collaudatore e reviewer, con titolo, descrizione e PR' {
        $r = @(Get-Azioni -Istantanea (script:New-BugUnito) -Contesto (script:New-Contesto))
        @($r.Tipo) | Should -Be @('SpostaCard', 'LanciaMentore')
        @($r[1].Ruoli) | Should -Be @('dev', 'collaudatore', 'reviewer')
        $r[1].Correttore | Should -Be 'bug'
        $r[1].Innesco | Should -Be 'bug'
        $r[1].Testo | Should -Match 'Il totale e sbagliato'
        $r[1].Testo | Should -Match 'Con due righe il totale e zero'
        $r[1].Testo | Should -Match '31'
        $r[1].Chiave | Should -Be 'bug@31'
    }

    It 'bug: una card che non e un Bug unita non innesca' {
        $i = script:New-BugUnito; $i.Card.Tipo = 'User Story'
        @(script:Get-Mentori $i).Count | Should -Be 0
    }

    It 'la chiave gia in mentoriFatti non rilancia, le altre si' {
        $i = script:New-Decisione
        $i.StatoCard.mentoriFatti = @('decisione@s-responsabile')
        @(script:Get-Mentori $i).Count | Should -Be 0
        $i.StatoCard.mentoriFatti = @('decisione@s-altra')
        @(script:Get-Mentori $i).Count | Should -Be 1
    }

    It 'nessun innesco, nessun lancio: una card che procede senza correzioni' {
        $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
        @(script:Get-Mentori $i).Count | Should -Be 0
    }

    It 'al limite di sessioni attive non parte il lancio e non parte neanche il mentore che lo accompagna' {
        $c = script:New-Contesto; $c.SessioniAttive = $script:AlLimite
        $d = Get-Decisione -Istantanea (script:New-Decisione) -Contesto $c
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo.Tipo | Should -Be 'limiteSessioni'
    }

    It 'al limite di sessioni attive il mentore senza lancio di sessione parte lo stesso: si calcola dopo il controllo del limite' {
        $c = script:New-Contesto; $c.SessioniAttive = $script:AlLimite
        $d = Get-Decisione -Istantanea (script:New-BugUnito) -Contesto $c
        $d.Motivo | Should -BeNullOrEmpty
        @($d.Azioni | Where-Object { $_.Tipo -eq 'LanciaSessione' }).Count | Should -Be 0
        @($d.Azioni | Where-Object { $_.Tipo -eq 'LanciaMentore' -and $_.Innesco -eq 'bug' }).Count | Should -Be 1
    }

    It 'LanciaMentore non conta come lavoro: un blocco di partenza resta il motivo della card' {
        $i = script:New-Ist 'pronto'
        $i.Commenti = @(script:New-Persona 51 'Un commento')
        $c = script:New-Contesto; $c.InSviluppoPerRepo = @{ 'Acme.AI' = @(100, 200) }
        $d = Get-Decisione -Istantanea $i -Contesto $c
        @($d.Azioni | Where-Object { $_.Tipo -eq 'LanciaMentore' }).Count | Should -Be 1
        $d.Motivo.Tipo | Should -Be 'limiteRepo'
    }
}

# Integrazione di D51 (2026-11-24): l'override della soglia dalla vista, valido fino al reset, e il bypass della sola riserva.
Describe 'Get-SogliaQuotaEffettiva: soglia e bypass che valgono adesso' {
    BeforeAll {
        $script:Adesso = '2026-11-24T10:00:00Z'
        $script:Base = @{ sogliaQuotaSettimanale = 0.70 }
        function script:New-Override($Soglia = 0.85, $Ignora = $false, $Fino = '2026-11-27T10:00:00Z') {
            @{ soglia = $Soglia; ignoraRiserva = $Ignora; fino = $Fino; impostata = '2026-11-24T09:00:00Z' }
        }
    }
    It 'senza override vale limiti.json' {
        $e = Get-SogliaQuotaEffettiva $script:Base @{} $script:Adesso
        $e.Soglia | Should -Be 0.70; $e.IgnoraRiserva | Should -BeFalse; $e.DaOverride | Should -BeFalse; $e.Override | Should -Be 'nessuno'
        (Get-SogliaQuotaEffettiva $script:Base $null $script:Adesso).Override | Should -Be 'nessuno'
    }
    It 'un override valido alza la soglia fino al reset' {
        $e = Get-SogliaQuotaEffettiva $script:Base (script:New-Override 0.85) $script:Adesso
        $e.Soglia | Should -Be 0.85; $e.DaOverride | Should -BeTrue; $e.Override | Should -Be 'valido'
        (ConvertTo-DataUtc $e.Fino) | Should -Be ([datetime]::Parse('2026-11-27T10:00:00Z').ToUniversalTime())
    }
    It 'il tetto 0.95 e incluso, e 0.05 e il minimo' {
        (Get-SogliaQuotaEffettiva $script:Base (script:New-Override 0.95) $script:Adesso).Soglia | Should -Be 0.95
        (Get-SogliaQuotaEffettiva $script:Base (script:New-Override 0.05) $script:Adesso).Soglia | Should -Be 0.05
    }
    It 'oltre 0.95 o sotto 0.05 l override si ignora per intero, anche il bypass' {
        foreach ($s in 0.96, 1.0, 0.04, -1) {
            $e = Get-SogliaQuotaEffettiva $script:Base (script:New-Override $s $true) $script:Adesso
            $e.Soglia | Should -Be 0.70; $e.IgnoraRiserva | Should -BeFalse; $e.Override | Should -Be 'fuoriRange'
        }
    }
    It 'scaduto (adesso >= fino) vale limiti.json' {
        foreach ($quando in '2026-11-27T10:00:00Z', '2026-11-28T00:00:00Z') {
            $e = Get-SogliaQuotaEffettiva $script:Base (script:New-Override 0.85 $true) $quando
            $e.Soglia | Should -Be 0.70; $e.IgnoraRiserva | Should -BeFalse; $e.Override | Should -Be 'scaduto'
        }
    }
    It 'illeggibile (errore di lettura, fino mancante, tipi sbagliati) vale limiti.json' {
        foreach ($o in @{ errore = 'json rotto' }, @{ soglia = 0.9; ignoraRiserva = $false }, (script:New-Override 'alta'), (script:New-Override 0.9 'si'), (script:New-Override 0.9 $false 'non-una-data')) {
            $e = Get-SogliaQuotaEffettiva $script:Base $o $script:Adesso
            $e.Soglia | Should -Be 0.70; $e.IgnoraRiserva | Should -BeFalse; $e.Override | Should -Be 'illeggibile'
        }
    }
    It 'il bypass senza soglia lascia quella di limiti.json' {
        $e = Get-SogliaQuotaEffettiva $script:Base (script:New-Override $null $true) $script:Adesso
        $e.Soglia | Should -Be 0.70; $e.DaOverride | Should -BeFalse; $e.IgnoraRiserva | Should -BeTrue
    }
}

Describe 'Get-BloccoQuota: override e bypass (D51, 2026-11-24)' {
    BeforeAll {
        function script:New-CtxQuota($Quota, $Override = $null) {
            @{ Quota = $Quota; Adesso = '2026-11-24T10:00:00Z'; Limiti = @{ sogliaQuotaSettimanale = 0.70 }; OverrideQuota = $Override }
        }
        $script:Uso = @{ sevenDay = @{ utilization = 0.75; resetsAt = '2026-11-27T10:00:00Z' } }
        $script:Fino = '2026-11-27T10:00:00Z'
    }
    It 'senza override la riserva blocca' {
        (Get-BloccoQuota (script:New-CtxQuota $script:Uso)).Causa | Should -Be 'riserva'
    }
    It 'una soglia alzata sopra l uso sblocca; sotto l uso blocca ancora, con la soglia effettiva' {
        Get-BloccoQuota (script:New-CtxQuota $script:Uso @{ soglia = 0.80; ignoraRiserva = $false; fino = $script:Fino }) | Should -BeNullOrEmpty
        $b = Get-BloccoQuota (script:New-CtxQuota $script:Uso @{ soglia = 0.72; ignoraRiserva = $false; fino = $script:Fino })
        $b.Causa | Should -Be 'riserva'; $b.Soglia | Should -Be 0.72
    }
    It 'con il bypass la riserva non blocca' {
        Get-BloccoQuota (script:New-CtxQuota $script:Uso @{ soglia = $null; ignoraRiserva = $true; fino = $script:Fino }) | Should -BeNullOrEmpty
    }
    It 'con il bypass la pausa dopo il limite di token blocca lo stesso' {
        $q = @{ pausaFino = '2026-11-24T12:00:00Z'; sevenDay = $script:Uso.sevenDay }
        $b = Get-BloccoQuota (script:New-CtxQuota $q @{ soglia = $null; ignoraRiserva = $true; fino = $script:Fino })
        $b.Causa | Should -Be 'limite'
    }
    It 'un override scaduto non sblocca' {
        (Get-BloccoQuota (script:New-CtxQuota $script:Uso @{ soglia = 0.9; ignoraRiserva = $true; fino = '2026-11-24T09:00:00Z' })).Causa | Should -Be 'riserva'
    }
    It 'Get-RiepilogoQuota: uso, soglia, bypass e blocco per la vista; i comandi servono un reset futuro' {
        $r = Get-RiepilogoQuota (script:New-CtxQuota $script:Uso @{ soglia = 0.72; ignoraRiserva = $false; fino = $script:Fino })
        $r.Uso | Should -Be 0.75; $r.Soglia | Should -Be 0.72; $r.DaOverride | Should -BeTrue; $r.PuoImpostare | Should -BeTrue
        $r.Blocco.Causa | Should -Be 'riserva'
        $r = Get-RiepilogoQuota (script:New-CtxQuota @{})
        $r.Soglia | Should -Be 0.70; $r.Uso | Should -BeNullOrEmpty; $r.PuoImpostare | Should -BeFalse; $r.Blocco | Should -BeNullOrEmpty
    }
}

Describe 'Get-OverrideSogliaQuota: il comando POST /soglia (D51, 2026-11-24)' {
    BeforeAll {
        $script:Adesso = '2026-11-24T10:00:00Z'
        $script:Reset = '2026-11-27T10:00:00.0000000Z'
        $script:Quota = @{ sevenDay = @{ utilization = 0.75; resetsAt = $script:Reset } }
        function script:Imposta($Parametri, $Corrente = @{}, $Quota = $script:Quota) { Get-OverrideSogliaQuota $Parametri $Quota $Corrente $script:Adesso }
    }
    It 'scrive soglia, fino al reset di quota.json e quando l ha impostata' {
        $r = script:Imposta @{ soglia = '0.85' }
        $r.Esito | Should -Be 'ok'
        $r.Override.soglia | Should -Be 0.85; $r.Override.ignoraRiserva | Should -BeFalse
        (ConvertTo-DataUtc $r.Override.fino) | Should -Be (ConvertTo-DataUtc $script:Reset)
        (ConvertTo-DataUtc $r.Override.impostata) | Should -Be (ConvertTo-DataUtc $script:Adesso)
    }
    It 'il range e quello che esporta il riepilogo: fuori rifiuta, ai bordi accetta' {
        $q = Get-RiepilogoQuota @{ Quota = $script:Quota; Adesso = $script:Adesso; Limiti = @{ sogliaQuotaSettimanale = 0.70 } }
        $q.SogliaMin | Should -Be 0.05; $q.SogliaMax | Should -Be 0.95
        foreach ($v in '0.96', '1', '0.04', '-0.5', 'abc') { (script:Imposta @{ soglia = $v }).Esito | Should -Be 'errore' }
        (script:Imposta @{ soglia = '0.96' }).Messaggio | Should -Match '5% e 95%'
        (script:Imposta @{ soglia = "$($q.SogliaMax)" }).Esito | Should -Be 'ok'
        (script:Imposta @{ soglia = "$($q.SogliaMin)" }).Esito | Should -Be 'ok'
    }
    It 'soglia vuota o null toglie la soglia alzata e lascia il bypass' {
        $c = (script:Imposta @{ ignoraRiserva = '1'; soglia = '0.8' }).Override
        $o = (script:Imposta @{ soglia = 'null' } $c).Override
        $o.soglia | Should -BeNullOrEmpty; $o.ignoraRiserva | Should -BeTrue
    }
    It 'un parametro assente lascia com e quello dell override ancora valido' {
        $c = (script:Imposta @{ soglia = '0.8' }).Override
        $c = (script:Imposta @{ ignoraRiserva = '1' } $c).Override
        $c.soglia | Should -Be 0.8; $c.ignoraRiserva | Should -BeTrue
        (script:Imposta @{ ignoraRiserva = '0' } $c).Override.ignoraRiserva | Should -BeFalse
    }
    It 'un override di un reset precedente non si porta dietro: riparte da zero' {
        $vecchio = @{ soglia = 0.9; ignoraRiserva = $true; fino = '2026-11-20T10:00:00Z'; impostata = '2026-11-19T10:00:00Z' }
        $o = (script:Imposta @{ soglia = '0.8' } $vecchio).Override
        $o.soglia | Should -Be 0.8; $o.ignoraRiserva | Should -BeFalse
    }
    It 'ignoraRiserva accetta solo 1/0/true/false' {
        (script:Imposta @{ ignoraRiserva = 'forse' }).Esito | Should -Be 'errore'
        (script:Imposta @{ ignoraRiserva = 'true' }).Esito | Should -Be 'ok'
    }
    It 'senza parametri da impostare rifiuta' {
        (script:Imposta @{}).Esito | Should -Be 'errore'
        (script:Imposta @{ altro = '1' }).Esito | Should -Be 'errore'
        (script:Imposta $null).Esito | Should -Be 'errore'
    }
    It 'senza resetsAt noto (o gia passato) in quota.json rifiuta con un messaggio chiaro' {
        foreach ($q in @{}, @{ sevenDay = @{ utilization = 0.7 } }, @{ sevenDay = @{ utilization = 0.7; resetsAt = '2026-11-24T09:00:00Z' } }, $null) {
            $r = script:Imposta @{ soglia = '0.8' } @{} $q
            $r.Esito | Should -Be 'errore'; $r.Messaggio | Should -Match 'reset settimanale non e noto'; $r.Override | Should -BeNullOrEmpty
        }
    }
    It 'ripristina da ok con override nullo, anche senza resetsAt' {
        $r = script:Imposta @{ ripristina = '1' } @{} @{}
        $r.Esito | Should -Be 'ok'; $r.Override | Should -BeNullOrEmpty
    }
}

# D52, gruppo 3: le card della funzionalita fanno il loro giro fino a In feature branch. La card di chiusura non c'e ancora
# (il comando che la crea e spento), quindi le istantanee si costruiscono a mano con Funzionalita.
Describe 'D52: le card della funzionalita' {
    BeforeAll {
        # Funzionalita come la porta l'istantanea. StatoChiusura e il nome ADO dello stato della card di chiusura (qui si passa la chiave
        # di stati.json); Ramo nullo = il ramo della funzionalita non e ancora su origin.
        function script:Set-Funz($i, [string]$StatoChiusura = 'inSviluppo', $Ramo = 'feature/f7-la-funzione', [string]$StatoFeature = 'featureAttiva', [bool]$EChiusura = $false) {
            # la destinazione salvata nello stato e quella che CreaWorktree lascia: da li in poi decide lei (il ramo della funzionalita)
            $i.StatoCard.destinazione = if ($Ramo) { $Ramo } else { 'feature/f7-la-funzione' }
            $i.Funzionalita = @{
                Feature = [pscustomobject]@{ Id = 7; Titolo = 'La funzione'; Stato = $script:Stati.$StatoFeature; Tag = @(); Area = 'DevOps.Agents\AI\Stime' }
                Chiusura = 22; Sorelle = @([pscustomobject]@{ Id = 100; Stato = (script:Nome 'pronto'); Tag = @(); Tipo = 'User Story' })
                Ramo = $Ramo; EChiusura = $EChiusura; StatoChiusura = (script:Nome $StatoChiusura)
            }
            $i
        }
        function script:New-PredF([int]$Id, [string]$Chiave, $PadreId = $null, $PrId = $null, $Cartella = $null) {
            [pscustomobject]@{ Id = $Id; Stato = (script:Nome $Chiave); prId = $PrId; cartella = $Cartella; PadreId = $PadreId }
        }
        function script:Get-Az($i) { @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)) }
        function script:Con-PrAttiva($i, [string]$Validazione = 'verde') {
            $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = $Validazione; BuildId = 58; UrlLog = $null }; $i
        }
        function script:Con-PrCompletata($i) {
            $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null }; $i
        }
        function script:Senza-Locale($i) { $i.StatoCard.ramo = $null; $i.StatoCard.cartella = $null; $i }
    }

    Context 'Ready to develop (punto 1)' {
        It 'senza ramo e con la Feature New: crea il ramo, il worktree dalla base, attiva la Feature, sposta e lancia dev' {
            $i = script:Set-Funz (script:New-Ist 'pronto') -Ramo $null -StatoFeature 'featureNuova'
            $az = script:Get-Az $i
            script:Test-Azioni $az @(
                @{ Tipo = 'CreaRamoFunzionalita'; FeatureId = 7 }
                @{ Tipo = 'CreaWorktree' }
                @{ Tipo = 'AggiornaFeature'; FeatureId = 7; Stato = 'featureAttiva' }
                @{ Tipo = 'SpostaCard'; Stato = 'inSviluppo' }
                @{ Tipo = 'LanciaSessione'; Ruolo = 'dev' })
            # la base non si sa ancora (il ramo lo crea l'azione prima): la chiave c'e e vuota, la riempie chi esegue
            $az[1].Contains('Base') | Should -BeTrue
            $az[1]['Base'] | Should -BeNullOrEmpty
        }

        It 'con il ramo su origin e la Feature gia Active: solo il worktree dal ramo della funzionalita' {
            $i = script:Set-Funz (script:New-Ist 'pronto')
            script:Test-Azioni (script:Get-Az $i) @(
                @{ Tipo = 'CreaWorktree'; Base = 'feature/f7-la-funzione' }
                @{ Tipo = 'SpostaCard'; Stato = 'inSviluppo' }
                @{ Tipo = 'LanciaSessione'; Ruolo = 'dev' })
        }

        It 'una card isolata non cambia: CreaWorktree senza la chiave Base' {
            $az = script:Get-Az (script:New-Ist 'pronto')
            $az[0].Tipo | Should -Be 'CreaWorktree'
            $az[0].Contains('Base') | Should -BeFalse
            @($az | Where-Object { $_.Tipo -in 'CreaRamoFunzionalita', 'AggiornaFeature' }).Count | Should -Be 0
        }

        It 'la card di chiusura non e una card della funzionalita: niente ramo da creare, niente worktree, la Feature non la attiva (gruppo 4)' {
            $i = script:Set-Funz (script:New-Ist 'pronto') -Ramo $null -StatoFeature 'featureNuova' -EChiusura $true
            @(script:Get-Az $i | Where-Object { $_.Tipo -in 'CreaWorktree', 'CreaRamoFunzionalita', 'AggiornaFeature' }).Count | Should -Be 0
        }

        It 'una lettura della funzionalita fallita ferma la card: nessuna azione, e un motivo con il testo dell errore (stato <K>)' -ForEach @(
            @{ K = 'nuova' }, @{ K = 'pronto' }, @{ K = 'inSviluppo' }, @{ K = 'inRevisione' }, @{ K = 'daUnire' }, @{ K = 'inFeature' }
        ) {
            $i = script:New-Ist $K
            $i.Funzionalita = @{ Errore = 'ADO non risponde' }
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            @($d.Azioni | Where-Object { $_.Tipo -ne 'LanciaMentore' }).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'funzionalitaIllegibile'
            Format-MotivoCoda $d.Motivo | Should -BeLike '*ADO non risponde*'
        }
    }

    Context 'In review, revisione superata (punto 4)' {
        It 'una card della funzionalita va in Ready to merge, anche se il componente ha un deploy in Test' {
            $i = script:Set-Funz (script:New-Ist 'inRevisione'); script:Set-Sessione $i 'reviewer' 'superata'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'SpostaCard'; Stato = 'daUnire' })
        }
        It 'la stessa card isolata va in Deploying to test' {
            $i = script:New-Ist 'inRevisione'; script:Set-Sessione $i 'reviewer' 'superata'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'SpostaCard'; Stato = 'inDeployTest' })
        }
    }

    Context 'Ready to merge (punto 5)' {
        It 'con la card di chiusura in <S> la PR non si completa: nessuna azione e il motivo attesaCollaudoFunzionalita' -ForEach @(
            @{ S = 'inDeployTest' }, @{ S = 'inCollaudo' }, @{ S = 'inProvaUmana' }, @{ S = 'daUnire' }
        ) {
            $i = script:Con-PrAttiva (script:Set-Funz (script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare') -StatoChiusura $S)
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            @($d.Azioni).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'attesaCollaudoFunzionalita'
            Format-MotivoCoda $d.Motivo | Should -BeLike '*#22*'
        }

        It 'con la card di chiusura fuori dalla prova (<S>) la PR si completa' -ForEach @(
            @{ S = 'bozza' }, @{ S = 'pronto' }, @{ S = 'inSviluppo' }, @{ S = 'inRevisione' }, @{ S = 'daRilasciare' }
        ) {
            $i = script:Con-PrAttiva (script:Set-Funz (script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare') -StatoChiusura $S)
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            script:Test-Azioni $d.Azioni @(@{ Tipo = 'CompletaPr' })
            $d.Motivo | Should -BeNullOrEmpty
        }

        It 'a PR completata la card va In feature branch, anche con la chiusura in prova (il lavoro e gia nel ramo)' {
            $i = script:Con-PrCompletata (script:Set-Funz (script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare') -StatoChiusura 'inCollaudo')
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'SpostaCard'; Stato = 'inFeature' })
        }

        It 'una card isolata a PR completata va ancora in develop: Ready to deploy (test) (D61)' {
            $i = script:Con-PrCompletata (script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare')
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'SpostaCard'; Stato = 'daDeployTest' })
        }

        It 'una PR in conflitto con il ramo della funzionalita torna a dev anche mentre la chiusura e in prova' {
            $i = script:Con-PrAttiva (script:Set-Funz (script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare') -StatoChiusura 'inCollaudo') 'conflitti'
            $az = script:Get-Az $i
            $az[0].Tipo | Should -Be 'RiportaIndietro'
            $az[1].Motivo | Should -Be 'conflitti'
        }
    }

    Context 'In feature branch (punto 6)' {
        It 'con il worktree e la PR completata lo toglie; con la chiusura ancora in lavorazione la card resta dov e' {
            $i = script:Con-PrCompletata (script:Set-Funz (script:New-Ist 'inFeature' 'daUnire' 'u-titolare') -StatoChiusura 'inCollaudo')
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'RimuoviWorktree' })
        }
        It 'con il worktree ma senza la PR completata non lo toglie: nessuna azione e un motivo con il testo' {
            $i = script:Set-Funz (script:New-Ist 'inFeature' 'daUnire' 'u-titolare') -StatoChiusura 'inCollaudo'
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            @($d.Azioni).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'inFeatureSenzaPrUnita'
            Format-MotivoCoda $d.Motivo | Should -BeLike '*PR*'
        }
        It 'senza il worktree e con la chiusura ancora in lavorazione non fa niente e non e un blocco' {
            $i = script:Senza-Locale (script:Set-Funz (script:New-Ist 'inFeature' 'daUnire' 'u-titolare') -StatoChiusura 'inCollaudo')
            $i.StatoCard.prId = 9
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            @($d.Azioni).Count | Should -Be 0
            $d.Motivo | Should -BeNullOrEmpty
        }
        It 'la chiusura in Draft con tutte le sorelle unite: nessuna azione e il motivo chiusuraInBozza, con il gesto e la card di chiusura' {
            $i = script:Senza-Locale (script:Set-Funz (script:New-Ist 'inFeature' 'daUnire' 'u-titolare') -StatoChiusura 'bozza')
            $i.StatoCard.prId = 9
            $i.Funzionalita.Sorelle = @([pscustomobject]@{ Id = 100; Stato = (script:Nome 'inFeature'); Tag = @(); Tipo = 'User Story' }, [pscustomobject]@{ Id = 101; Stato = (script:Nome 'daRilasciare'); Tag = @(); Tipo = 'Bug' })
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            @($d.Azioni).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'chiusuraInBozza'
            $d.Motivo.Chiusura | Should -Be 22
            $d.Motivo.Gesto | Should -Be 'sposta la card #22 in New'
            $d.Motivo.Ruolo | Should -BeNullOrEmpty
            Format-MotivoCoda $d.Motivo | Should -BeLike '*#22*Draft*'
        }
        It 'la chiusura in Draft ma con una sorella non ancora unita, o gia in New: nessun motivo' -ForEach @(
            @{ S = 'bozza'; Altra = 'pronto' }, @{ S = 'nuova'; Altra = 'inFeature' }
        ) {
            $i = script:Senza-Locale (script:Set-Funz (script:New-Ist 'inFeature' 'daUnire' 'u-titolare') -StatoChiusura $S)
            $i.Funzionalita.Sorelle = @([pscustomobject]@{ Id = 100; Stato = (script:Nome 'inFeature'); Tag = @(); Tipo = 'User Story' }, [pscustomobject]@{ Id = 101; Stato = (script:Nome $Altra); Tag = @(); Tipo = 'User Story' })
            (Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)).Motivo | Should -BeNullOrEmpty
        }
        It 'il motivo chiusuraInBozza non nasconde il lavoro: con il worktree e la PR completata la card lo toglie' {
            $i = script:Con-PrCompletata (script:Set-Funz (script:New-Ist 'inFeature' 'daUnire' 'u-titolare') -StatoChiusura 'bozza')
            $i.Funzionalita.Sorelle = @([pscustomobject]@{ Id = 100; Stato = (script:Nome 'inFeature'); Tag = @(); Tipo = 'User Story' })
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            script:Test-Azioni @($d.Azioni) @(@{ Tipo = 'RimuoviWorktree' })
            $d.Motivo | Should -BeNullOrEmpty
        }
        It 'D61: con la chiusura in Ready to deploy (test) la card la segue li, non in Ready to release' {
            $i = script:Con-PrCompletata (script:Set-Funz (script:New-Ist 'inFeature' 'daUnire' 'u-titolare') -StatoChiusura 'daDeployTest')
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'RimuoviWorktree' }, @{ Tipo = 'SpostaCard'; Stato = 'daDeployTest' })
        }
        It 'D61: in Ready to deploy (test) segue la chiusura: aspetta finche la chiusura aspetta, poi Ready to release (<S>)' -ForEach @(
            @{ S = 'daDeployTest'; Att = @() }, @{ S = 'daRilasciare'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'daRilasciare' }) }, @{ S = 'chiusa'; Att = @(@{ Tipo = 'SpostaCard'; Stato = 'daRilasciare' }) }
        ) {
            $i = script:Senza-Locale (script:Con-PrCompletata (script:Set-Funz (script:New-Ist 'daDeployTest' 'inFeature' 'u-titolare') -StatoChiusura $S)); $i.StatoCard.prId = 9
            script:Test-Azioni @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)) $Att
        }
        It 'con la chiusura in <S> la card passa in Ready to release (dopo aver tolto il worktree, se c e)' -ForEach @(
            @{ S = 'daRilasciare' }, @{ S = 'inRilascio' }, @{ S = 'chiusa' }
        ) {
            $i = script:Con-PrCompletata (script:Set-Funz (script:New-Ist 'inFeature' 'daUnire' 'u-titolare') -StatoChiusura $S)
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'RimuoviWorktree' }, @{ Tipo = 'SpostaCard'; Stato = 'daRilasciare' })
            $null = script:Senza-Locale $i; $i.StatoCard.prId = 9
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'SpostaCard'; Stato = 'daRilasciare' })
        }
        It 'un task aperto (si legge solo finche c e il worktree) non riporta indietro la card: un solo avviso, una volta' {
            $i = script:Con-PrCompletata (script:Set-Funz (script:New-Ist 'inFeature' 'daUnire' 'u-titolare') -StatoChiusura 'inCollaudo')
            script:Set-Task $i @{ 61 = 'aperto' }
            $az = @(script:Get-Az $i)
            $az.Count | Should -Be 2
            $az[0].Tipo | Should -Be 'RimuoviWorktree'
            $az[1].Tipo | Should -Be 'Avvisa'
            $az[1].Chi | Should -Be 'titolare'
            $az[1].Testo | Should -BeLike '*card nuova della funzionalita*'
            $i.StatoCard.avvisi = @($az[1].Chiave)
            @(script:Get-Az $i).Count | Should -Be 1
        }
        It 'senza funzionalita valida (Feature rimossa, chiusura tolta) non fa niente: un motivo che dice cosa fare, e il worktree resta' {
            $i = script:Con-PrCompletata (script:New-Ist 'inFeature' 'daUnire' 'u-titolare')
            $i.StatoCard.destinazione = 'feature/f7-la-funzione'
            $i.Funzionalita = $null
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            @($d.Azioni).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'funzionalitaPerduta'
            Format-MotivoCoda $d.Motivo | Should -BeLike '*feature/f7-la-funzione*'
        }
        It 'una card isolata trascinata a mano In feature branch non perde il worktree: un motivo' {
            $i = script:Con-PrCompletata (script:New-Ist 'inFeature' 'daUnire' 'u-titolare')
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            @($d.Azioni).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'funzionalitaPerduta'
        }
    }

    Context 'la destinazione salvata decide dopo il worktree (correzioni al gruppo 3)' {
        It 'una card isolata gia con la PR verso develop, legata dopo a una Feature, resta isolata: In review superata va in Deploying to test' {
            $i = script:Set-Funz (script:New-Ist 'inRevisione'); script:Set-Sessione $i 'reviewer' 'superata'
            $i.StatoCard.destinazione = $null
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'SpostaCard'; Stato = 'inDeployTest' })
        }
        It 'la stessa card in Ready to merge a PR completata va in Ready to deploy (test), non In feature branch' {
            $i = script:Con-PrCompletata (script:Set-Funz (script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare') -StatoChiusura 'inCollaudo')
            $i.StatoCard.destinazione = $null
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'SpostaCard'; Stato = 'daDeployTest' })
        }
        It 'e non aspetta il collaudo di una funzionalita che non e la sua' {
            $i = script:Con-PrAttiva (script:Set-Funz (script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare') -StatoChiusura 'inCollaudo')
            $i.StatoCard.destinazione = $null
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'CompletaPr' })
        }
        It 'con la destinazione sul ramo della funzionalita e la funzionalita sparita (<K>): nessuna azione e il motivo funzionalitaPerduta, mai il percorso isolato' -ForEach @(
            @{ K = 'inSviluppo' }, @{ K = 'inRevisione' }, @{ K = 'inDeployTest' }, @{ K = 'inCollaudo' }, @{ K = 'inProvaUmana' }, @{ K = 'daUnire' }
        ) {
            $i = script:New-Ist $K 'inRevisione' 'u-titolare'
            $i.StatoCard.destinazione = 'feature/f7-la-funzione'
            $i.Funzionalita = $null
            script:Set-Sessione $i 'reviewer' 'superata'
            if ($K -eq 'daUnire') { $null = script:Con-PrCompletata $i }
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            @($d.Azioni | Where-Object { $_.Tipo -ne 'LanciaMentore' }).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'funzionalitaPerduta'
            Format-MotivoCoda $d.Motivo | Should -BeLike '*feature/f7-la-funzione*'
        }
        It 'una PR in conflitto nomina la destinazione vera' {
            $i = script:Con-PrAttiva (script:Set-Funz (script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare') -StatoChiusura 'bozza') 'conflitti'
            @(script:Get-Az $i)[0].Motivo | Should -BeLike '*feature/f7-la-funzione*'
        }
    }

    Context 'presa in carico (punto 7)' {
        It 'una card In feature branch senza stato locale passa da AdottaCard (che salva il prId e non ricrea il worktree)' {
            $i = script:Senza-Locale (script:Set-Funz (script:New-Ist 'inFeature' 'daUnire' 'u-titolare') -StatoChiusura 'inCollaudo')
            $i.StatoCard.destinazione = $null
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'AdottaCard'; Base = 'feature/f7-la-funzione' })
        }
        It 'con il prId salvato non si riadotta' {
            $i = script:Senza-Locale (script:Set-Funz (script:New-Ist 'inFeature' 'daUnire' 'u-titolare') -StatoChiusura 'inCollaudo')
            $i.StatoCard.prId = 9
            @(script:Get-Az $i | Where-Object { $_.Tipo -eq 'AdottaCard' }).Count | Should -Be 0
        }
    }

    Context 'predecessori (punto 8)' {
        It 'una sorella In feature branch della stessa Feature e unita: la card parte (<K>)' -ForEach @(@{ K = 'nuova' }, @{ K = 'pronto' }) {
            $i = script:Set-Funz (script:New-Ist $K)
            $i.Predecessori = @(script:New-PredF 50 'inFeature' 7)
            @(script:Get-Az $i).Count | Should -BeGreaterThan 0
            (Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)).Motivo | Should -BeNullOrEmpty
        }
        It 'un predecessore In feature branch di un altra Feature non e unito: la card aspetta' {
            $i = script:Set-Funz (script:New-Ist 'pronto')
            $i.Predecessori = @(script:New-PredF 50 'inFeature' 8)
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            @($d.Azioni).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'predecessori'
        }
        It 'un predecessore In feature branch senza padre non e unito' {
            $i = script:Set-Funz (script:New-Ist 'pronto')
            $i.Predecessori = @(script:New-PredF 50 'inFeature' $null)
            (Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)).Motivo.Tipo | Should -Be 'predecessori'
        }
        It 'una card isolata con un predecessore In feature branch aspetta: unita vuol dire in develop' {
            $i = script:New-Ist 'pronto'
            $i.Predecessori = @(script:New-PredF 50 'inFeature' 7)
            $d = Get-Decisione -Istantanea $i -Contesto (script:New-Contesto)
            @($d.Azioni).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'predecessori'
        }
        It 'Test-PredecessoreUnito: In feature branch conta solo con la stessa Feature, le altre regole non cambiano' {
            $p = script:New-PredF 50 'inFeature' 7
            Test-PredecessoreUnito $script:Stati $p 7 | Should -BeTrue
            Test-PredecessoreUnito $script:Stati $p 8 | Should -BeFalse
            Test-PredecessoreUnito $script:Stati $p | Should -BeFalse
            Test-PredecessoreUnito $script:Stati (script:New-PredF 51 'chiusa') 7 | Should -BeTrue
            Test-PredecessoreUnito $script:Stati (script:New-PredF 52 'inSviluppo' 7) 7 | Should -BeFalse
        }
    }
}

# D52, gruppo 4: la card di chiusura. Non ha worktree: lo stato locale ha come ramo quello della funzionalita, come destinazione
# develop e la cartella vuota. Aspetta le sorelle, apre la PR ramo della funzionalita -> develop, prova il ramo in Test e lo
# unisce in develop solo se e quello che ha provato.
Describe 'D52: la card di chiusura (gruppo 4)' {
    BeforeAll {
        # La chiusura come la porta l'istantanea: Sorelle e una tabella id -> chiave di stato. Id della chiusura: 100 (quello di New-Ist).
        function script:Set-Chiusura($i, $Sorelle = @{ 51 = 'inFeature' }, $Ramo = 'feature/f7-la-funzione', [string]$StatoFeature = 'featureAttiva', [bool]$ConRamo = $true) {
            $i.StatoCard.ramo = if ($ConRamo) { $Ramo } else { $null }
            $i.StatoCard.cartella = $null
            $i.StatoCard.destinazione = 'develop'
            $i.Funzionalita = @{
                Feature = [pscustomobject]@{ Id = 7; Titolo = 'La funzione'; Stato = $script:Stati.$StatoFeature; Tag = @(); Area = 'x' }
                Chiusura = 100
                Sorelle = @($Sorelle.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Id = [int]$_; Stato = (script:Nome $Sorelle[$_]); Tag = @(); Tipo = 'User Story' } })
                Ramo = $Ramo; EChiusura = $true; StatoChiusura = $i.Card.Stato
            }
            $i
        }
        function script:Get-Az($i, $c = (script:New-Contesto)) { , @(Get-Azioni -Istantanea $i -Contesto $c) }
        function script:Get-Dec($i, $c = (script:New-Contesto)) { Get-Decisione -Istantanea $i -Contesto $c }
        function script:Con-Pr($i, [string]$Validazione = 'verde', [string]$Commit = 'c-testa', [string]$Stato = 'active') {
            $i.Pr = [pscustomobject]@{ Id = 3; Stato = $Stato; Validazione = $Validazione; BuildId = 58; UrlLog = 'https://ado/build/58'; UltimoCommit = $Commit }; $i
        }
        # il run del deploy in Test valido per l'ingresso (rev 7), con il commit su cui e girato
        function script:Con-Run($i, [string]$Esito = 'succeeded', [string]$Commit = 'c-testa', [string]$Stato = 'completed') {
            $i.StatoCard.runId = 9; $i.StatoCard.runDopoRev = 7
            $i.Run = [pscustomobject]@{ Stato = $Stato; Esito = $Esito; Url = 'https://ado/build/9'; SourceVersion = $Commit }; $i
        }
        function script:Chiusura-In([string]$Chiave, $Sorelle = @{ 51 = 'inFeature' }) {
            script:Set-Chiusura (script:New-Ist $Chiave 'pronto' 'u-titolare') $Sorelle
        }
        function script:Solo-Azioni($d) { @(@($d.Azioni) | Where-Object { $_.Tipo -ne 'LanciaMentore' }) }
        function script:Funz-Sorella($i) {
            $i.StatoCard.destinazione = 'feature/f7-la-funzione'
            $i.Funzionalita = @{
                Feature = [pscustomobject]@{ Id = 7; Titolo = 'x'; Stato = $script:Stati.featureAttiva; Tag = @(); Area = 'x' }
                Chiusura = 22; Sorelle = @(); Ramo = 'feature/f7-la-funzione'; EChiusura = $false; StatoChiusura = (script:Nome 'bozza')
            }
            $i
        }
    }

    Context 'l attesa delle sorelle (punto 1)' {
        It 'senza sorelle: nessuna azione e il motivo senzaSorelle, con il ruolo di chi prendera la card (<K>)' -ForEach @(
            @{ K = 'nuova'; R = 'responsabile' }, @{ K = 'pronto'; R = $null }
        ) {
            $i = script:Set-Chiusura (script:New-Ist $K) @{}
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'senzaSorelle'
            $d.Motivo.Ruolo | Should -Be $R
            Format-MotivoCoda $d.Motivo | Should -BeLike '*sorelle*'
        }
        It 'con una sorella non unita (<S>) aspetta: motivo predecessori con la sorella, ruolo per stato (<K>)' -ForEach @(
            @{ K = 'nuova'; S = 'daUnire'; R = 'responsabile' }, @{ K = 'pronto'; S = 'inSviluppo'; R = $null }, @{ K = 'pronto'; S = 'pronto'; R = $null }, @{ K = 'nuova'; S = 'bozza'; R = 'responsabile' }
        ) {
            $i = script:Set-Chiusura (script:New-Ist $K) @{ 51 = $S; 52 = 'inFeature' }
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'predecessori'
            $d.Motivo.Ruolo | Should -Be $R
            @($d.Motivo.Predecessori).Id | Should -Be @(51)
            Format-MotivoCoda $d.Motivo | Should -BeLike '*#51*'
            Format-MotivoCoda $d.Motivo | Should -BeLike '*sorelle*'
        }
        It 'una sorella In feature branch, Ready to release, Releasing o Closed e unita: in New parte il responsabile (<S>)' -ForEach @(
            @{ S = 'inFeature' }, @{ S = 'daRilasciare' }, @{ S = 'inRilascio' }, @{ S = 'chiusa' }
        ) {
            $i = script:Set-Chiusura (script:New-Ist 'nuova') @{ 51 = $S }
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'nuova' })
        }
        It 'una sorella Removed non aspetta e non conta come sorella: la composizione di Get-ComposizioneFunzionalita la lascia fuori' {
            $figli = @(
                [pscustomobject]@{ Id = 100; Stato = (script:Nome 'nuova'); Tag = @($script:Stati.tagChiusura); Tipo = 'User Story' }
                [pscustomobject]@{ Id = 51; Stato = (script:Nome 'inFeature'); Tag = @(); Tipo = 'User Story' }
                [pscustomobject]@{ Id = 52; Stato = (script:Nome 'rimossa'); Tag = @(); Tipo = 'User Story' })
            $i = script:Set-Chiusura (script:New-Ist 'nuova') @{}
            $i.Funzionalita.Sorelle = @((Get-ComposizioneFunzionalita $script:Stati $figli).Sorelle)
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile' })
            # e se la Removed e l unica, e come non avere sorelle
            $i.Funzionalita.Sorelle = @((Get-ComposizioneFunzionalita $script:Stati @($figli[0], $figli[2])).Sorelle)
            (script:Get-Dec $i).Motivo.Tipo | Should -Be 'senzaSorelle'
        }
        It 'anche i predecessori veri (link Predecessor) contano, oltre alle sorelle' {
            $i = script:Set-Chiusura (script:New-Ist 'pronto') @{ 51 = 'inFeature' }
            $i.Predecessori = @([pscustomobject]@{ Id = 80; Stato = (script:Nome 'inSviluppo'); prId = $null; cartella = 'C:/wt/80'; PadreId = $null })
            $d = script:Get-Dec $i
            $d.Motivo.Tipo | Should -Be 'predecessori'
            @($d.Motivo.Predecessori).Id | Should -Be @(80)
        }
    }

    Context 'il ritorno indietro (punto 2)' {
        It 'in <K> con una sorella non unita torna in Ready to develop, con il numero della sorella nel motivo' -ForEach @(
            @{ K = 'inDeployTest' }, @{ K = 'inCollaudo' }, @{ K = 'inProvaUmana' }, @{ K = 'daUnire' }
        ) {
            $i = script:Chiusura-In $K @{ 51 = 'inFeature'; 52 = 'daUnire' }
            $az = script:Get-Az $i
            $az.Count | Should -Be 1
            $az[0].Tipo | Should -Be 'RiportaIndietro'
            $az[0].Stato | Should -Be 'pronto'
            $az[0].Motivo | Should -BeLike '*#52*'
            $az[0].Motivo | Should -Not -BeLike '*#51*'
        }
        It 'con tutte le sorelle unite non torna indietro' {
            $i = script:Con-Run (script:Chiusura-In 'inCollaudo')
            @(script:Get-Az $i | Where-Object { $_.Tipo -eq 'RiportaIndietro' }).Count | Should -Be 0
        }
        It 'dagli altri stati (<K>) non si tocca: Ready to develop aspetta, Ready to release e gia unita' -ForEach @(
            @{ K = 'pronto' }, @{ K = 'daRilasciare' }
        ) {
            $i = script:Chiusura-In $K @{ 51 = 'daUnire' }
            @(script:Get-Az $i | Where-Object { $_.Tipo -eq 'RiportaIndietro' }).Count | Should -Be 0
        }
        It 'in Human test in on-hold mentre una sorella entra nel ramo: in on-hold non fa niente; al primo giro senza on-hold torna indietro' {
            $i = script:Chiusura-In 'inProvaUmana' @{ 51 = 'inFeature'; 53 = 'daUnire' }
            $i.Card.Tag += $script:Stati.tagAttesa
            $i.StatoCard.inAttesaPer = 'limite'
            $d = script:Get-Dec $i
            @($d.Azioni).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'onHold'
            # la persona toglie l'on-hold
            $i.Card.Tag = @($script:Stati.tagAgenti)
            $az = script:Get-Az $i
            $ritorno = @($az | Where-Object { $_.Tipo -eq 'RiportaIndietro' })
            $ritorno.Count | Should -Be 1
            $ritorno[0].Stato | Should -Be 'pronto'
            $ritorno[0].Motivo | Should -BeLike '*#53*'
        }
    }

    Context 'New (punto 3)' {
        It 'con le sorelle unite parte il responsabile come per ogni card in New' {
            script:Test-Azioni (script:Get-Az (script:Chiusura-In 'nuova')) @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'nuova' })
        }
    }

    Context 'Ready to develop (punto 4)' {
        It 'senza il ramo salvato lo imposta dalla funzionalita, e basta: niente worktree, niente PR in questo giro' {
            $i = script:Set-Chiusura (script:New-Ist 'pronto') -ConRamo $false
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'ImpostaRamoChiusura'; Ramo = 'feature/f7-la-funzione' })
        }
        It 'senza il ramo salvato e senza il ramo su origin va in attesa: la chiusura non sa quale ramo provare' {
            $i = script:Set-Chiusura (script:New-Ist 'pronto') -ConRamo $false
            $i.Funzionalita.Ramo = $null
            $az = @(script:Get-Az $i)
            $az.Count | Should -BeGreaterThan 0
            @($az | Where-Object { $_.Tipo -in 'CreaWorktree', 'CreaRamoFunzionalita', 'ApriPr', 'ImpostaRamoChiusura' }).Count | Should -Be 0
        }
        It 'con il ramo salvato e senza PR apre la PR, senza worktree' {
            $i = script:Chiusura-In 'pronto'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'ApriPr' })
        }
        It 'il limite di card in sviluppo per repo non la ferma: non sviluppa niente' {
            $c = script:New-Contesto; $c.InSviluppoPerRepo = @{ 'Acme.AI' = @(200, 201) }
            $i = script:Chiusura-In 'pronto'
            script:Test-Azioni (script:Get-Az $i $c) @(@{ Tipo = 'ApriPr' })
        }
        It 'con la PR verde va in Deploying to test' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto')
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'SpostaCard'; Stato = 'inDeployTest' })
        }
        It 'con la PR scaduta rilancia le validazioni scadute' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'scaduta'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'RilanciaScadute' })
        }
        It 'con la PR in corso aspetta senza azioni e senza motivo' {
            $d = script:Get-Dec (script:Con-Pr (script:Chiusura-In 'pronto') 'inCorso')
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo | Should -BeNullOrEmpty
        }
        It 'con la PR in conflitto con develop e la Bug allinea-develop gia fatta (gruppo 5): nessuna azione e il motivo conflittiFunzionalita con il ramo e la destinazione' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'conflitti'
            $i.StatoCard.allineaFatti = @('c-testa')
            $i.Funzionalita.Sorelle = @($i.Funzionalita.Sorelle) + [pscustomobject]@{ Id = 70; Stato = (script:Nome 'inFeature'); Tag = @('agents', 'allinea-develop'); Tipo = 'Bug' }
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'conflittiFunzionalita'
            $d.Motivo.Ruolo | Should -BeNullOrEmpty
            Format-MotivoCoda $d.Motivo | Should -BeLike '*feature/f7-la-funzione*develop*'
        }
        It 'con la PR rossa e la build gia gestita dal responsabile (gruppo 5): nessuna azione e il motivo ciRossaFunzionalita, con gli errori della build' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'rossa'
            $i.StatoCard.ciRossaGestita = 58
            $i.ErroriBuild = "Passo 'Run tests' fallito.`nFailed A.Test_due [39 s]"
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'ciRossaFunzionalita'
            Format-MotivoCoda $d.Motivo | Should -BeLike '*Failed A.Test_due*'
            Format-MotivoCoda $d.Motivo | Should -Not -Match "`n"
        }
        It 'con la PR verde ma un altra card dello stesso componente in Test aspetta: motivo limiteTest, senza ruolo, nessuna azione' {
            $c = script:New-Contesto; $c.InTestPerComponente = @{ stime = @(200) }
            $d = script:Get-Dec (script:Con-Pr (script:Chiusura-In 'pronto')) $c
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'limiteTest'
            $d.Motivo.Ruolo | Should -BeNullOrEmpty
        }
        It 'senza deploy in Test (no-test-deploy) il limite dei posti in Test non c entra' {
            $c = script:New-Contesto; $c.InTestPerComponente = @{ stime = @(200) }
            $i = script:Con-Pr (script:Chiusura-In 'pronto'); $i.Card.Tag += $script:Stati.tagSenzaTest
            script:Test-Azioni (script:Get-Az $i $c) @(@{ Tipo = 'SpostaCard'; Stato = 'inDeployTest' })
        }
    }

    Context 'Test: task aggiunto e no-test-deploy (punto 5)' {
        It 'non ha reviewer: senza revisione superata non torna indietro, il deploy parte' {
            script:Test-Azioni (script:Get-Az (script:Chiusura-In 'inDeployTest')) @(@{ Tipo = 'AccodaDeployTest'; Rev = 7 })
        }
        It 'con no-test-deploy va dritta in Ready to merge (<K>)' -ForEach @(@{ K = 'inDeployTest' }, @{ K = 'inCollaudo' }, @{ K = 'inProvaUmana' }) {
            $i = script:Chiusura-In $K; $i.Card.Tag += $script:Stati.tagSenzaTest
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'SpostaCard'; Stato = 'daUnire' })
        }
    }

    Context 'Deploying to test (punto 6)' {
        It 'il deploy porta rev e parametri scelti; il ramo lo prende chi esegue dallo stato, che e quello della funzionalita' {
            $az = script:Get-Az (script:Chiusura-In 'inDeployTest')
            $az[0].Tipo | Should -Be 'AccodaDeployTest'
            @($az[0].Parametri) | Should -Be @('deployStime')
        }
        It 'un altra card dello stesso componente gia in Test: torna in Ready to develop, non In review (non ha reviewer)' {
            $c = script:New-Contesto; $c.InTestPerComponente = @{ stime = @(200) }
            $az = script:Get-Az (script:Chiusura-In 'inDeployTest') $c
            $az[0].Tipo | Should -Be 'RiportaIndietro'
            $az[0].Stato | Should -Be 'pronto'
        }
        It 'run in corso: aspetta' {
            $i = script:Con-Run (script:Chiusura-In 'inDeployTest') -Esito $null -Stato 'inProgress'
            (script:Get-Az $i).Count | Should -Be 0
        }
        It 'run riuscito: sempre Automated test, anche con human-test (umana: <Umana>)' -ForEach @(@{ Umana = $false }, @{ Umana = $true }) {
            $i = script:Con-Run (script:Chiusura-In 'inDeployTest')
            if ($Umana) { $i.Card.Tag += $script:Stati.tagProvaUmana }
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'SpostaCard'; Stato = 'inCollaudo' })
        }
        It 'run fallito con passi di build o test falliti e la build gia gestita dal responsabile (gruppo 5): nessuna azione e il motivo ciRossaFunzionalita con gli errori e il link al run' {
            $i = script:Con-Run (script:Chiusura-In 'inDeployTest') 'failed'
            $i.StatoCard.ciRossaGestita = 9
            $i.ErroriBuild = "Passo 'Build' fallito.`nerror CS1002"
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'ciRossaFunzionalita'
            Format-MotivoCoda $d.Motivo | Should -BeLike '*error CS1002*'
            Format-MotivoCoda $d.Motivo | Should -BeLike '*https://ado/build/9*'
        }
        It 'run fallito senza passi di build o test falliti: l on-hold di oggi (D32), che passa prima dal responsabile' {
            $i = script:Con-Run (script:Chiusura-In 'inDeployTest') 'failed'
            $az = script:Get-Az $i
            @($az | Where-Object { $_.Tipo -eq 'AvviaPassataAttesa' }).Count | Should -Be 1
            $az[-1].Tipo | Should -Be 'LanciaSessione'
            $az[-1].Motivo | Should -Be 'attesa'
            script:Set-PassataFatta $i
            $az = script:Get-Az $i
            $az[-1].Tipo | Should -Be 'MettiInAttesa'
            $az[-1].Motivo | Should -BeLike 'deploy in Test fallito*'
        }
    }

    Context 'Automated test e Human test (punti 7 e 8)' {
        It 'collaudo superata: Ready to merge; con human-test, Human test (umana: <Umana>)' -ForEach @(@{ Umana = $false; Va = 'daUnire' }, @{ Umana = $true; Va = 'inProvaUmana' }) {
            $i = script:Chiusura-In 'inCollaudo'
            if ($Umana) { $i.Card.Tag += $script:Stati.tagProvaUmana }
            script:Set-Sessione $i 'collaudatore' 'superata'; $i.StatoCard.ultimaSessione['collaudatore']['inizio'] = '2026-11-02T09:00:00Z'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'SpostaCard'; Stato = $Va })
        }
        It 'collaudo respinto: il responsabile con il motivo collaudoRespinto, come oggi' {
            $i = script:Chiusura-In 'inCollaudo'
            script:Set-Sessione $i 'collaudatore' 'respinta' 'il campo non si salva'; $i.StatoCard.ultimaSessione['collaudatore']['inizio'] = '2026-11-02T09:00:00Z'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'collaudoRespinto' })
        }
        It 'senza collaudo parte il collaudatore, e il lancio dice che serve il worktree in sola lettura della chiusura' {
            $az = script:Get-Az (script:Chiusura-In 'inCollaudo')
            script:Test-Azioni $az @(@{ Tipo = 'LanciaSessione'; Ruolo = 'collaudatore'; Motivo = 'collaudo' })
            $az[0]['WorktreeChiusura'] | Should -BeTrue
        }
        It 'la ripresa del collaudatore della chiusura (on-hold tolto, o dopo la quota) porta lo stesso marcatore: il worktree si rinnova a ogni lancio' -ForEach @(@{ Per = 'sessione' }, @{ Per = 'quota' }) {
            $i = script:Chiusura-In 'inCollaudo'
            script:Set-Sessione $i 'collaudatore' $null; $i.StatoCard.ultimaSessione['collaudatore']['fine'] = $null
            $i.StatoCard.inAttesaPer = $Per
            $az = script:Get-Az $i
            $az[-1].Tipo | Should -Be 'LanciaSessione'
            $az[-1].Motivo | Should -Be 'ripresa'
            $az[-1]['WorktreeChiusura'] | Should -BeTrue
        }
        It 'la ripresa di una card isolata non porta WorktreeChiusura' {
            $i = script:New-InTest; script:Set-Stato $i 'inCollaudo'
            script:Set-Sessione $i 'collaudatore' $null; $i.StatoCard.ultimaSessione['collaudatore']['fine'] = $null
            $i.StatoCard.inAttesaPer = 'sessione'
            $az = script:Get-Az $i
            $az[-1].Motivo | Should -Be 'ripresa'
            $az[-1].Contains('WorktreeChiusura') | Should -BeFalse
        }
        It 'un lancio di una card isolata non porta WorktreeChiusura' {
            $i = script:New-Ist 'inCollaudo' 'inDeployTest' 'u-titolare'
            script:Set-Sessione $i 'dev' 'fatto' -Fine '2026-11-02T10:00:00Z'; script:Set-Sessione $i 'reviewer' 'superata' -Fine '2026-11-03T10:00:00Z'
            $az = script:Get-Az $i
            $az[0].Tipo | Should -Be 'LanciaSessione'
            $az[0].Contains('WorktreeChiusura') | Should -BeFalse
        }
        It 'Human test: l avviso a Titolare senza commenti, il responsabile con il commento di una persona, come oggi' {
            $i = script:Chiusura-In 'inProvaUmana'; $i.Card.Tag += $script:Stati.tagProvaUmana
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'Avvisa' })
            $i.Commenti = @([pscustomobject]@{ Id = 1; Autore = 'Anna'; Testo = 'Il filtro non funziona' })
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'verificaInTest' })
        }
    }

    Context 'Ready to merge (punto 9)' {
        It 'con il commit della PR uguale a quello del deploy completa la PR' {
            $i = script:Con-Pr (script:Con-Run (script:Chiusura-In 'daUnire') 'succeeded' 'c1') 'verde' 'c1'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'CompletaPr' })
        }
        It 'con il commit diverso (il ramo e cambiato dopo il deploy) torna in Ready to develop, con il motivo' {
            $i = script:Con-Pr (script:Con-Run (script:Chiusura-In 'daUnire') 'succeeded' 'c1') 'verde' 'c2'
            $az = script:Get-Az $i
            $az.Count | Should -Be 1
            $az[0].Tipo | Should -Be 'RiportaIndietro'
            $az[0].Stato | Should -Be 'pronto'
            $az[0].Motivo | Should -BeLike '*ramo della funzionalita e cambiato dopo il deploy*'
        }
        It 'senza il run del deploy (non si sa su che commit e stato provato) non completa: torna indietro' {
            $i = script:Con-Pr (script:Chiusura-In 'daUnire') 'verde' 'c1'
            (script:Get-Az $i)[0].Tipo | Should -Be 'RiportaIndietro'
        }
        It 'senza test (no-test-deploy) non c e un deploy da confrontare: completa' {
            $i = script:Con-Pr (script:Chiusura-In 'daUnire') 'verde' 'c1'; $i.Card.Tag += $script:Stati.tagSenzaTest
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'CompletaPr' })
        }
        It 'con la PR scaduta rilancia le validazioni, con la PR in corso aspetta' {
            $base = script:Con-Run (script:Chiusura-In 'daUnire') 'succeeded' 'c1'
            script:Test-Azioni (script:Get-Az (script:Con-Pr $base 'scaduta' 'c1')) @(@{ Tipo = 'RilanciaScadute' })
            (script:Get-Az (script:Con-Pr $base 'inCorso' 'c1')).Count | Should -Be 0
        }
        It 'con la PR in conflitto con develop e la Bug allinea-develop gia fatta (gruppo 5): nessuna azione e il motivo conflittiFunzionalita, niente dev' {
            $i = script:Con-Pr (script:Con-Run (script:Chiusura-In 'daUnire') 'succeeded' 'c1') 'conflitti' 'c1'
            $i.StatoCard.allineaFatti = @('c1')
            $i.Funzionalita.Sorelle = @($i.Funzionalita.Sorelle) + [pscustomobject]@{ Id = 70; Stato = (script:Nome 'inFeature'); Tag = @('agents', 'allinea-develop'); Tipo = 'Bug' }
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'conflittiFunzionalita'
        }
        It 'a PR completata: Ready to deploy (test) e la Feature Resolved, da chiudere con la card' {
            $i = script:Con-Pr (script:Chiusura-In 'daUnire') 'assente' 'c2' 'completed'
            script:Test-Azioni (script:Get-Az $i) @(
                @{ Tipo = 'SpostaCard'; Stato = 'daDeployTest' }
                @{ Tipo = 'AggiornaFeature'; FeatureId = 7; Stato = 'featureRisolta'; DaChiudere = $true })
        }
        It 'a PR completata non guarda il commit: il merge e fatto' {
            $i = script:Con-Pr (script:Con-Run (script:Chiusura-In 'daUnire') 'succeeded' 'c1') 'assente' 'c9' 'completed'
            (script:Get-Az $i)[0].Stato | Should -Be 'daDeployTest'
        }
        It 'il ramo e andato avanti dopo il deploy (una sorella nuova): il vincolo del commit ferma il merge anche con tutte le sorelle unite' {
            $i = script:Con-Pr (script:Con-Run (script:Chiusura-In 'daUnire' @{ 51 = 'inFeature'; 53 = 'inFeature' }) 'succeeded' 'c1') 'verde' 'c-nuovo'
            $az = script:Get-Az $i
            $az[0].Tipo | Should -Be 'RiportaIndietro'
            $az[0].Motivo | Should -BeLike '*cambiato dopo il deploy*'
        }
    }

    Context 'Ready to release: la Feature Resolved si riprova se non e passata' {
        It 'con la Feature Resolved ma non ricordata nello stato (stato locale perso) la riscrive, per ricordarla' {
            $i = script:Con-Pr (script:Set-Chiusura (script:New-Ist 'daRilasciare' 'daUnire' 'u-titolare') @{ 51 = 'inFeature' } -StatoFeature 'featureRisolta') 'assente' 'c2' 'completed'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'AggiornaFeature'; FeatureId = 7; Stato = 'featureRisolta'; DaChiudere = $true })
        }
        It 'una Feature Closed non si tocca, ricordata o no' {
            $i = script:Con-Pr (script:Set-Chiusura (script:New-Ist 'daRilasciare' 'daUnire' 'u-titolare') @{ 51 = 'inFeature' } -StatoFeature 'featureChiusa') 'assente' 'c2' 'completed'
            (script:Get-Az $i).Count | Should -Be 0
        }
        It 'con la Feature ancora Active la card in Ready to release la riscrive Resolved' {
            $i = script:Con-Pr (script:Chiusura-In 'daRilasciare') 'assente' 'c2' 'completed'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'AggiornaFeature'; FeatureId = 7; Stato = 'featureRisolta'; DaChiudere = $true })
        }
        It 'con il worktree in sola lettura ancora li lo toglie, senza cancellare il ramo salvato: serve a leggere la PR (Chiusura)' {
            $i = script:Con-Pr (script:Set-Chiusura (script:New-Ist 'daRilasciare' 'daUnire' 'u-titolare') @{ 51 = 'inFeature' } -StatoFeature 'featureRisolta') 'assente' 'c2' 'completed'
            $i.StatoCard.featureDaChiudere = 7; $i.StatoCard.cartella = 'C:/wt/card-22'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'RimuoviWorktree'; Chiusura = $true })
        }
        It 'con la Feature gia Resolved o Closed non fa niente: senza worktree niente RimuoviWorktree (<F>)' -ForEach @(@{ F = 'featureRisolta' }, @{ F = 'featureChiusa' }) {
            $i = script:Con-Pr (script:Set-Chiusura (script:New-Ist 'daRilasciare' 'daUnire' 'u-titolare') @{ 51 = 'inFeature' } -StatoFeature $F) 'assente' 'c2' 'completed'
            $i.StatoCard.featureDaChiudere = 7
            (script:Get-Az $i).Count | Should -Be 0
        }
    }

    Context 'presa in carico e percorso' {
        It 'una chiusura senza stato locale (<K>) non passa da AdottaCard: imposta il ramo, senza worktree' -ForEach @(
            @{ K = 'inDeployTest' }, @{ K = 'inCollaudo' }, @{ K = 'inProvaUmana' }, @{ K = 'daUnire' }
        ) {
            $i = script:Chiusura-In $K
            $i.StatoCard.ramo = $null; $i.StatoCard.destinazione = $null
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'ImpostaRamoChiusura'; Ramo = 'feature/f7-la-funzione' })
        }
        It 'la chiusura con il ramo salvato non e mai perduta: la destinazione e develop' {
            $i = script:Con-Run (script:Chiusura-In 'inCollaudo')
            (script:Get-Dec $i).Motivo.Tipo | Should -Not -Be 'funzionalitaPerduta'
        }
        It 'una sorella (card della funzionalita) non cambia: crea il worktree dalla base, come prima' {
            $i = script:Funz-Sorella (script:New-Ist 'pronto')
            @(script:Get-Az $i | ForEach-Object { $_.Tipo }) | Should -Contain 'CreaWorktree'
        }
    }

    Context 'i due difetti noti' {
        It 'i conflitti che restano dopo dev nominano la destinazione vera, non develop' {
            $i = script:Funz-Sorella (script:New-Ist 'inSviluppo'); script:Set-Sessione $i 'dev' 'fatto'
            $i.StatoCard.ultimaSessione['dev']['motivo'] = 'conflitti'
            $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'conflitti'; BuildId = $null; UrlLog = $null }
            script:Set-PassataFatta $i
            $az = script:Get-Az $i
            $az[-1].Tipo | Should -Be 'MettiInAttesa'
            $az[-1].Motivo | Should -BeLike '*con feature/f7-la-funzione dopo*'
        }
        It 'per una card isolata il testo dice develop' {
            $i = script:New-Ist 'inSviluppo'; script:Set-Sessione $i 'dev' 'fatto'
            $i.StatoCard.ultimaSessione['dev']['motivo'] = 'conflitti'
            $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'conflitti'; BuildId = $null; UrlLog = $null }
            script:Set-PassataFatta $i
            (script:Get-Az $i)[-1].Motivo | Should -BeLike '*con develop dopo*'
        }
    }
}

# D52, gruppo 4, correzioni dopo la revisione: la CI rossa contro l'infrastruttura, il commit verificato, il ritorno per commit diverso,
# la presa in carico della card di chiusura in Ready to release.
Describe 'D52: la card di chiusura, correzioni dopo la revisione' {
    BeforeAll {
        function script:Set-Chiusura($i, $Sorelle = @{ 51 = 'inFeature' }, $Ramo = 'feature/f7-la-funzione', [string]$StatoFeature = 'featureAttiva', [bool]$ConRamo = $true) {
            $i.StatoCard.ramo = if ($ConRamo) { $Ramo } else { $null }
            $i.StatoCard.cartella = $null
            $i.StatoCard.destinazione = 'develop'
            $i.Funzionalita = @{
                Feature = [pscustomobject]@{ Id = 7; Titolo = 'La funzione'; Stato = $script:Stati.$StatoFeature; Tag = @(); Area = 'x' }
                Chiusura = 100
                Sorelle = @($Sorelle.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Id = [int]$_; Stato = (script:Nome $Sorelle[$_]); Tag = @(); Tipo = 'User Story' } })
                Ramo = $Ramo; EChiusura = $true; StatoChiusura = $i.Card.Stato
            }
            $i
        }
        function script:Get-Az($i, $c = (script:New-Contesto)) { , @(Get-Azioni -Istantanea $i -Contesto $c) }
        function script:Get-Dec($i, $c = (script:New-Contesto)) { Get-Decisione -Istantanea $i -Contesto $c }
        function script:Con-Pr($i, [string]$Validazione = 'verde', [string]$Commit = 'c-testa', [string]$Stato = 'active') {
            $i.Pr = [pscustomobject]@{ Id = 3; Stato = $Stato; Validazione = $Validazione; BuildId = 58; UrlLog = 'https://ado/build/58'; UltimoCommit = $Commit }; $i
        }
        function script:Con-Run($i, [string]$Esito = 'succeeded', [string]$Commit = 'c-testa', [string]$Stato = 'completed') {
            $i.StatoCard.runId = 9; $i.StatoCard.runDopoRev = 7
            $i.Run = [pscustomobject]@{ Stato = $Stato; Esito = $Esito; Url = 'https://ado/build/9'; SourceVersion = $Commit }; $i
        }
        function script:Chiusura-In([string]$Chiave, $Sorelle = @{ 51 = 'inFeature' }) {
            script:Set-Chiusura (script:New-Ist $Chiave 'pronto' 'u-titolare') $Sorelle
        }
    }

    Context 'la CI rossa contro l infrastruttura (punto 4)' {
        It 'validazione della PR rossa senza errori di codice: un rilancio, e il contatore dei rilanci lo conta' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'rossa'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'RilanciaValidazione' })
        }
        It 'ancora rossa dopo il rilancio: on-hold con il motivo (dopo la passata del responsabile)' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'rossa'
            $i.StatoCard.rilanci = 1
            $az = script:Get-Az $i
            @($az | Where-Object { $_.Tipo -eq 'RilanciaValidazione' }).Count | Should -Be 0
            script:Set-PassataFatta $i
            $az = script:Get-Az $i
            $az[-1].Tipo | Should -Be 'MettiInAttesa'
            $az[-1].Motivo | Should -BeLike '*senza errori di codice*'
        }
        It 'con errori di codice non si rilancia: attesa con il suo motivo (build gia gestita dal responsabile, gruppo 5), e il rilancio non conta' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'rossa'
            $i.StatoCard.ciRossaGestita = 58
            $i.ErroriBuild = "Passo 'Run tests' fallito.`nFailed A.Test_due"
            $d = script:Get-Dec $i
            @($d.Azioni | Where-Object { $_.Tipo -ne 'LanciaMentore' }).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'ciRossaFunzionalita'
        }
        It 'run di deploy fallito senza errori di codice: l on-hold di sempre (D32), non un motivo di CI rossa' {
            $i = script:Con-Run (script:Chiusura-In 'inDeployTest') 'failed'
            script:Set-PassataFatta $i
            $az = script:Get-Az $i
            $az[-1].Tipo | Should -Be 'MettiInAttesa'
            $az[-1].Motivo | Should -BeLike 'deploy in Test fallito*'
        }
    }

    Context 'il commit verificato (punto 3)' {
        It 'CompletaPr porta la testa della PR letta nell istantanea: la card di chiusura' {
            $i = script:Con-Pr (script:Con-Run (script:Chiusura-In 'daUnire') 'succeeded' 'c1') 'verde' 'c1'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'CompletaPr'; Commit = 'c1' })
        }
        It 'CompletaPr porta la testa della PR letta nell istantanea: una card isolata' {
            $i = script:New-Ist 'daUnire' 'inCollaudo' 'u-titolare'
            $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'active'; Validazione = 'verde'; BuildId = 58; UrlLog = $null; UltimoCommit = 'c7' }
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'CompletaPr'; Commit = 'c7' })
        }
    }

    Context 'il ritorno per commit diverso (punto 5)' {
        BeforeEach {
            $script:IMerge = { param($ritornoCommit = $null) $i = script:Con-Pr (script:Con-Run (script:Chiusura-In 'daUnire') 'succeeded' 'c1') 'verde' 'c2'; $i.StatoCard.ritornoCommit = $ritornoCommit; $i }
        }
        It 'il primo ritorno salva la testa della PR con cui e tornata' {
            $az = script:Get-Az (& $script:IMerge)
            $az[0].Tipo | Should -Be 'RiportaIndietro'
            $az[0].Commit | Should -Be 'c2'
        }
        It 'il secondo ritorno per la stessa testa: on-hold con il motivo, non un altro giro' {
            $i = & $script:IMerge 'c2'
            script:Set-PassataFatta $i
            $az = script:Get-Az $i
            @($az | Where-Object { $_.Tipo -eq 'RiportaIndietro' }).Count | Should -Be 0
            $az[-1].Tipo | Should -Be 'MettiInAttesa'
            $az[-1].Motivo | Should -BeLike '*c2*'
        }
        It 'una testa diversa da quella dell ultimo ritorno e un giro nuovo: torna indietro e salva la nuova' {
            $az = script:Get-Az (& $script:IMerge 'c0')
            $az[0].Tipo | Should -Be 'RiportaIndietro'
            $az[0].Commit | Should -Be 'c2'
        }
        It 'tolto l on-hold da una persona il ricordo del ritorno si azzera: la card riprova' {
            $i = & $script:IMerge 'c2'
            $i.StatoCard.inAttesaPer = 'limite'
            $az = script:Get-Az $i
            @($az | Where-Object { $_.Tipo -eq 'RiportaIndietro' }).Count | Should -Be 1
        }
    }

    Context 'Ready to release senza stato locale (punto 8)' {
        It 'la card di chiusura imposta il ramo dalla PR collegata (il ramo della funzionalita e gia cancellato dal merge)' {
            $i = script:Chiusura-In 'daRilasciare'
            $i.StatoCard.ramo = $null; $i.StatoCard.destinazione = $null
            $i.Funzionalita.Ramo = $null
            $az = script:Get-Az $i
            script:Test-Azioni $az @(@{ Tipo = 'ImpostaRamoChiusura'; DaPrCollegata = $true })
        }
    }

    Context 'senza il ramo della funzionalita (punto 10)' {
        It 'e proprio un MettiInAttesa con quel motivo, non un altra azione' {
            $i = script:Set-Chiusura (script:New-Ist 'pronto') -ConRamo $false
            $i.Funzionalita.Ramo = $null
            script:Set-PassataFatta $i
            $az = script:Get-Az $i
            script:Test-Azioni $az @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
            $az[0].Motivo | Should -BeLike '*ramo della funzionalita non c e su origin*'
        }
    }
}

# D52, gruppo 5: le correzioni. Il responsabile della card di chiusura scrive la correzione (un commento con la marca), lo smistatore
# ne fa una Bug figlia della Feature; la CI rossa e i conflitti con develop portano a una correzione o a una Bug allinea-develop.
Describe 'D52: le correzioni della card di chiusura (gruppo 5)' {
    BeforeAll {
        function script:Set-Chiusura($i, $Sorelle = @{ 51 = 'inFeature' }, $Ramo = 'feature/f7-la-funzione') {
            $i.StatoCard.ramo = $Ramo
            $i.StatoCard.cartella = $null
            $i.StatoCard.destinazione = 'develop'
            $i.Funzionalita = @{
                Feature = [pscustomobject]@{ Id = 7; Titolo = 'La funzione'; Stato = $script:Stati.featureAttiva; Tag = @(); Area = 'x' }
                Chiusura = 100
                Sorelle = @($Sorelle.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Id = [int]$_; Stato = (script:Nome $Sorelle[$_]); Tag = @(); Tipo = 'User Story' } })
                Ramo = $Ramo; EChiusura = $true; StatoChiusura = $i.Card.Stato
            }
            $i
        }
        function script:Get-Az($i, $c = (script:New-Contesto)) { , @(Get-Azioni -Istantanea $i -Contesto $c) }
        function script:Get-Dec($i, $c = (script:New-Contesto)) { Get-Decisione -Istantanea $i -Contesto $c }
        function script:Con-Pr($i, [string]$Validazione = 'verde', [string]$Commit = 'c-testa', [string]$Stato = 'active') {
            $i.Pr = [pscustomobject]@{ Id = 3; Stato = $Stato; Validazione = $Validazione; BuildId = 58; UrlLog = 'https://ado/build/58'; UltimoCommit = $Commit }; $i
        }
        function script:Con-Run($i, [string]$Esito = 'succeeded', [string]$Commit = 'c-testa', [string]$Stato = 'completed') {
            $i.StatoCard.runId = 9; $i.StatoCard.runDopoRev = 7
            $i.Run = [pscustomobject]@{ Stato = $Stato; Esito = $Esito; Url = 'https://ado/build/9'; SourceVersion = $Commit }; $i
        }
        function script:Chiusura-In([string]$Chiave, $Sorelle = @{ 51 = 'inFeature' }) {
            script:Set-Chiusura (script:New-Ist $Chiave 'pronto' 'u-titolare') $Sorelle
        }
        function script:Solo-Azioni($d) { @(@($d.Azioni) | Where-Object { $_.Tipo -ne 'LanciaMentore' }) }
        # il commento di correzione come lo scrive card.ps1 correzione (prefisso e firma di Add-CardCommento)
        function script:Commento-Correzione([int]$Id, [string]$Natura = 'tecnico', [string]$Titolo = 'Il totale non somma') {
            $corpo = ConvertTo-TestoCommentoCorrezione -Tipo $Natura -Titolo $Titolo -Descrizione 'Il totale ignora le righe scontate.'
            [pscustomobject]@{ Id = $Id; Autore = 'x'; Quando = '2026-11-02T11:00:00Z'; Testo = "[responsabile] $corpo`n`n— scritto da Claude (responsabile)" }
        }
        function script:Errori-Ci($i) { $i.ErroriBuild = "Passo 'Run tests' fallito.`nFailed A.Test_due [39 s]"; $i }
        # una card della funzionalita (non la chiusura) della Feature 7
        function script:Funz-Sorella($i) {
            $i.StatoCard.destinazione = 'feature/f7-la-funzione'
            $i.Funzionalita = @{
                Feature = [pscustomobject]@{ Id = 7; Titolo = 'x'; Stato = $script:Stati.featureAttiva; Tag = @(); Area = 'x' }
                Chiusura = 22; Sorelle = @(); Ramo = 'feature/f7-la-funzione'; EChiusura = $false; StatoChiusura = (script:Nome 'bozza')
            }
            $i
        }
    }

    Context 'CreaCorrezione: la marca del responsabile diventa una Bug' {
        BeforeEach {
            # collaudo respinto e responsabile che ha finito: e la correzione che il suo brief gli fa scrivere
            $script:I = script:Chiusura-In 'inCollaudo'
            script:Set-Sessione $script:I 'collaudatore' 'respinta' 'il filtro non somma' -Fine '2026-11-02T10:00:00Z'
            script:Set-Sessione $script:I 'responsabile' 'fatto' '' -Fine '2026-11-02T11:30:00Z'
            $script:I.StatoCard.ultimaSessione.responsabile.motivo = 'collaudoRespinto'
        }

        It 'la correzione tecnica scritta e nuova: CreaCorrezione con la chiave del commento, la natura, il titolo e la Feature, da sola' {
            $script:I.CommentiTutti = @(script:Commento-Correzione 55)
            script:Test-Azioni (script:Get-Az $script:I) @(@{ Tipo = 'CreaCorrezione'; Chiave = '55'; Natura = 'tecnico'; Titolo = 'Il totale non somma'; FeatureId = 7; Chiusura = 100 })
            (script:Get-Az $script:I)[0].Descrizione | Should -Be 'Il totale ignora le righe scontate.'
        }

        It 'stato locale vuoto (altro PC, stato perso) con il commento della Bug sulla card: la correzione non si rifa' {
            $script:I.CommentiTutti = @((script:Commento-Correzione 55), [pscustomobject]@{ Id = 56; Autore = 'x'; Quando = '2026-11-02T11:31:00Z'; Testo = "[smistatore] $(ConvertTo-TestoCommentoBugCreata -Tipo 'correzione' -Chiave '55' -Bug 300)" })
            @($script:I.StatoCard.Keys) | Should -Not -Contain 'correzioniFatte'
            @(script:Get-Az $script:I | Where-Object { $_.Tipo -eq 'CreaCorrezione' }).Count | Should -Be 0
        }

        It 'la correzione di prodotto: CreaCorrezione con natura prodotto' {
            $script:I.CommentiTutti = @(script:Commento-Correzione 56 'prodotto' 'Quale arrotondamento')
            script:Test-Azioni (script:Get-Az $script:I) @(@{ Tipo = 'CreaCorrezione'; Chiave = '56'; Natura = 'prodotto'; Titolo = 'Quale arrotondamento' })
        }

        It 'una correzione, una Bug: con la chiave in correzioniFatte non si rifa, e vale la regola delle sorelle (la Bug nuova non e unita: torna in Ready to develop)' {
            $script:I.CommentiTutti = @(script:Commento-Correzione 55)
            $script:I.StatoCard.correzioniFatte = @('55')
            $script:I.Funzionalita.Sorelle = @($script:I.Funzionalita.Sorelle) + [pscustomobject]@{ Id = 60; Stato = (script:Nome 'nuova'); Tag = @('agents'); Tipo = 'Bug' }
            script:Test-Azioni (script:Get-Az $script:I) @(@{ Tipo = 'RiportaIndietro'; Stato = 'pronto' })
        }

        It 'fra due correzioni scritte fa solo quella non ancora fatta' {
            $script:I.CommentiTutti = @((script:Commento-Correzione 55), (script:Commento-Correzione 57 'tecnico' 'Il filtro perde le righe'))
            $script:I.StatoCard.correzioniFatte = @('55')
            script:Test-Azioni (script:Get-Az $script:I) @(@{ Tipo = 'CreaCorrezione'; Chiave = '57'; Titolo = 'Il filtro perde le righe' })
        }

        It 'un commento con la stessa forma ma non del responsabile non e una correzione' {
            $c = script:Commento-Correzione 55
            $c.Testo = $c.Testo -replace '^\[responsabile\]', '[dev]'
            $script:I.CommentiTutti = @($c)
            @(script:Get-Az $script:I | Where-Object { $_.Tipo -eq 'CreaCorrezione' }).Count | Should -Be 0
        }

        It 'una card isolata non fa Bug dal commento: la correzione e solo della card di chiusura' {
            $i = script:New-Ist 'inCollaudo'
            $i.CommentiTutti = @(script:Commento-Correzione 55)
            @(script:Get-Az $i | Where-Object { $_.Tipo -eq 'CreaCorrezione' }).Count | Should -Be 0
        }

        It 'il giro intero: collaudo respinto, responsabile, correzione, Bug, ritorno in Ready to develop, Bug In feature branch, nuovo deploy' {
            # 1. il collaudo ha respinto: parte il responsabile
            $i = script:Chiusura-In 'inCollaudo'
            script:Set-Sessione $i 'collaudatore' 'respinta' 'il filtro non somma' -Fine '2026-11-02T10:00:00Z'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'collaudoRespinto' })
            # 2. il responsabile ha scritto la correzione ed e finito: lo smistatore crea la Bug
            script:Set-Sessione $i 'responsabile' 'fatto' '' -Fine '2026-11-02T11:30:00Z'
            $i.StatoCard.ultimaSessione.responsabile.motivo = 'collaudoRespinto'
            $i.CommentiTutti = @(script:Commento-Correzione 55)
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'CreaCorrezione'; Chiave = '55' })
            # 3. la Bug c'e (In New, sorella non unita) e la correzione e segnata: la chiusura torna in Ready to develop
            $i.StatoCard.correzioniFatte = @('55')
            $i.Funzionalita.Sorelle = @($i.Funzionalita.Sorelle) + [pscustomobject]@{ Id = 60; Stato = (script:Nome 'nuova'); Tag = @('agents'); Tipo = 'Bug' }
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'RiportaIndietro'; Stato = 'pronto' })
            # 4. in Ready to develop aspetta la Bug, senza azioni
            $p = script:Con-Pr (script:Chiusura-In 'pronto' @{ 51 = 'inFeature'; 60 = 'inSviluppo' })
            $d = script:Get-Dec $p
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'predecessori'
            @($d.Motivo.Predecessori | ForEach-Object { $_.Id }) | Should -Be @(60)
            # 5. la Bug e In feature branch: la PR (rivalidata sul commit nuovo) e verde e la chiusura va in Deploying to test
            $p = script:Con-Pr (script:Chiusura-In 'pronto' @{ 51 = 'inFeature'; 60 = 'inFeature' }) 'verde' 'c-nuovo'
            script:Test-Azioni (script:Get-Az $p) @(@{ Tipo = 'SpostaCard'; Stato = 'inDeployTest' })
            # 6. nuovo deploy, dal ramo della funzionalita
            script:Test-Azioni (script:Get-Az (script:Chiusura-In 'inDeployTest' @{ 51 = 'inFeature'; 60 = 'inFeature' })) @(@{ Tipo = 'AccodaDeployTest' })
        }

        It 'la Bug di prodotto in Draft ferma la chiusura come una sorella non unita (la persona la porta in New)' {
            $p = script:Con-Pr (script:Chiusura-In 'pronto' @{ 51 = 'inFeature'; 60 = 'bozza' }) 'verde'
            $d = script:Get-Dec $p
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'predecessori'
        }

        It 'giriCollaudo conta anche sulla chiusura: al limite non riparte il responsabile ma una persona' {
            $script:I.StatoCard.ultimaSessione.Remove('responsabile'); $script:I.StatoCard.ultimoRuolo = 'collaudatore'
            $script:I.StatoCard.giriCollaudo = [int]$script:Limiti.giriCollaudo
            script:Set-PassataFatta $script:I   # la passata del responsabile prima dell'on-hold e gia fatta: resta l'on-hold di sempre
            $az = script:Get-Az $script:I
            @($az | Where-Object { $_.Tipo -eq 'LanciaSessione' }).Count | Should -Be 0
            ($az | Where-Object { $_.Tipo -eq 'MettiInAttesa' } | Select-Object -First 1).Motivo | Should -BeLike '*collaudi respinti*'
        }
    }

    Context 'la CI rossa: il responsabile scrive la correzione' {
        It 'validazione della PR rossa con errori di codice (Ready to develop): lancia il responsabile con motivo ciRossa, errori e link come allegato, e la build' {
            $i = script:Errori-Ci (script:Con-Pr (script:Chiusura-In 'pronto') 'rossa')
            $az = script:Get-Az $i
            script:Test-Azioni $az @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'ciRossa'; Build = 58 })
            $az[0].Allegato | Should -BeLike '*Failed A.Test_due*'
            $az[0].Allegato | Should -BeLike '*https://ado/build/58*'
        }

        It 'una volta per build: con la build gia gestita aspetta senza azioni, con il motivo ciRossaFunzionalita' {
            $i = script:Errori-Ci (script:Con-Pr (script:Chiusura-In 'pronto') 'rossa')
            $i.StatoCard.ciRossaGestita = 58
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'ciRossaFunzionalita'
        }

        It 'una build nuova (altro id) lancia di nuovo il responsabile' {
            $i = script:Errori-Ci (script:Con-Pr (script:Chiusura-In 'pronto') 'rossa')
            $i.StatoCard.ciRossaGestita = 57
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'LanciaSessione'; Motivo = 'ciRossa'; Build = 58 })
        }

        It 'una persona che toglie un on-hold per la CI rossa della validazione: si rilancia la validazione, non il responsabile sulla stessa build' {
            $i = script:Errori-Ci (script:Con-Pr (script:Chiusura-In 'pronto') 'rossa')
            $i.StatoCard.ciRossaGestita = 58
            $i.StatoCard.ciRosseDiFila = 3
            $i.StatoCard.inAttesaPer = 'limite'
            $az = script:Get-Az $i
            @($az | Where-Object { $_.Tipo -eq 'LanciaSessione' }).Count | Should -Be 0
            @($az | Where-Object { $_.Tipo -eq 'RilanciaValidazione' }).Count | Should -Be 1
            $az[0].Tipo | Should -Be 'AzzeraContatori'
        }

        It 'AzzeraContatori e la copia di Get-Decisione azzerano gli stessi campi (un elenco solo)' {
            $campi = Get-CampiContatori
            foreach ($k in 'giriRevisione', 'rosseDiFila', 'giriCollaudo', 'rilanci', 'ciRosseDiFila') { $campi[$k] | Should -Be 0 }
            foreach ($k in 'completaPr', 'ritornoCommit', 'inAttesaPer') { $campi.Contains($k) | Should -BeTrue; $campi[$k] | Should -BeNullOrEmpty }
        }

        It 'tetto alle sessioni del responsabile per la CI rossa: con ciRosseDiFila al limite rosseDiFila non parte, on-hold per una persona' {
            $i = script:Errori-Ci (script:Con-Pr (script:Chiusura-In 'pronto') 'rossa')
            $i.StatoCard.ciRosseDiFila = [int]$script:Limiti.rosseDiFila
            $az = script:Get-Az $i
            @($az | Where-Object { $_.Tipo -eq 'LanciaSessione' }).Count | Should -Be 0
            script:Test-Azioni $az @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
            $az[0].Motivo | Should -BeLike '*CI rossa*'
        }

        It 'sotto il tetto il responsabile parte ancora' {
            $i = script:Errori-Ci (script:Con-Pr (script:Chiusura-In 'pronto') 'rossa')
            $i.StatoCard.ciRosseDiFila = [int]$script:Limiti.rosseDiFila - 1
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'LanciaSessione'; Motivo = 'ciRossa' })
        }

        It 'quando la CI torna verde il contatore si azzera (AzzeraCiRosse): validazione verde, o run riuscito' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'verde'
            $i.StatoCard.ciRosseDiFila = 2
            @(script:Get-Az $i | Where-Object { $_.Tipo -eq 'AzzeraCiRosse' }).Count | Should -Be 1
            $r = script:Con-Run (script:Chiusura-In 'inDeployTest') 'succeeded'
            $r.StatoCard.ciRosseDiFila = 1
            @(script:Get-Az $r | Where-Object { $_.Tipo -eq 'AzzeraCiRosse' }).Count | Should -Be 1
        }

        It 'a contatore gia a zero, o con la CI ancora rossa, non c e nessun AzzeraCiRosse' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'verde'
            @(script:Get-Az $i | Where-Object { $_.Tipo -eq 'AzzeraCiRosse' }).Count | Should -Be 0
            $r = script:Errori-Ci (script:Con-Pr (script:Chiusura-In 'pronto') 'rossa')
            $r.StatoCard.ciRosseDiFila = 2; $r.StatoCard.ciRossaGestita = 58
            @(script:Get-Az $r | Where-Object { $_.Tipo -eq 'AzzeraCiRosse' }).Count | Should -Be 0
        }

        It 'run del deploy fallito con errori di codice (Deploying to test): lancia il responsabile, con la build del run' {
            $i = script:Errori-Ci (script:Con-Run (script:Chiusura-In 'inDeployTest') 'failed')
            $az = script:Get-Az $i
            script:Test-Azioni $az @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'ciRossa'; Build = 9 })
            $az[0].Allegato | Should -BeLike '*https://ado/build/9*'
        }

        It 'run del deploy fallito con la build gia gestita: aspetta, senza ripassare dall on-hold di sempre' {
            $i = script:Errori-Ci (script:Con-Run (script:Chiusura-In 'inDeployTest') 'failed')
            $i.StatoCard.ciRossaGestita = 9
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'ciRossaFunzionalita'
        }

        It 'Ready to merge con la PR rossa e errori di codice: stessa strada di Ready to develop, non la PR non completata' {
            $i = script:Errori-Ci (script:Con-Pr (script:Con-Run (script:Chiusura-In 'daUnire') 'succeeded' 'c1') 'rossa' 'c1')
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'LanciaSessione'; Ruolo = 'responsabile'; Motivo = 'ciRossa'; Build = 58 })
        }

        It 'Ready to merge con la PR rossa e la build gia gestita: aspetta con il motivo, senza chiedere il completamento' {
            $i = script:Errori-Ci (script:Con-Pr (script:Con-Run (script:Chiusura-In 'daUnire') 'succeeded' 'c1') 'rossa' 'c1')
            $i.StatoCard.ciRossaGestita = 58
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'ciRossaFunzionalita'
        }

        It 'il responsabile chiude <Esito> senza una correzione scritta: on-hold per una persona con il motivo, non un attesa muta' -ForEach @(
            @{ Esito = 'bloccato' }, @{ Esito = 'fatto' }, @{ Esito = 'bivio' }, @{ Esito = 'domande' }
        ) {
            $i = script:Errori-Ci (script:Con-Pr (script:Chiusura-In 'pronto') 'rossa')
            $i.StatoCard.ciRossaGestita = 58
            script:Set-Sessione $i 'responsabile' $Esito '' -Fine '2026-11-02T11:30:00Z'
            $i.StatoCard.ultimaSessione.responsabile.motivo = 'ciRossa'
            $az = script:Get-Az $i
            script:Test-Azioni $az @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
            $az[0].Motivo | Should -BeLike '*CI rossa*'
        }

        It 'prima che il responsabile abbia finito (o mai lanciato) la build gestita aspetta soltanto, senza on-hold' {
            $i = script:Errori-Ci (script:Con-Pr (script:Chiusura-In 'pronto') 'rossa')
            $i.StatoCard.ciRossaGestita = 58
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'ciRossaFunzionalita'
        }

        It 'dopo il fatto del responsabile la correzione diventa una Bug, e la CI rossa non lo rilancia' {
            $i = script:Errori-Ci (script:Con-Pr (script:Chiusura-In 'pronto') 'rossa')
            $i.StatoCard.ciRossaGestita = 58
            script:Set-Sessione $i 'responsabile' 'fatto' '' -Fine '2026-11-02T11:30:00Z'
            $i.StatoCard.ultimaSessione.responsabile.motivo = 'ciRossa'
            $i.CommentiTutti = @(script:Commento-Correzione 61)
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'CreaCorrezione'; Chiave = '61'; Natura = 'tecnico' })
        }
    }

    Context 'i conflitti con develop: la Bug allinea-develop' {
        It 'PR in conflitto in Ready to develop: CreaAllineaDevelop con il ramo, la Feature e il commit di testa, da sola' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'conflitti' 'c-testa'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'CreaAllineaDevelop'; FeatureId = 7; Ramo = 'feature/f7-la-funzione'; Commit = 'c-testa' })
        }

        It 'PR in conflitto in Ready to merge: la stessa Bug' {
            $i = script:Con-Pr (script:Con-Run (script:Chiusura-In 'daUnire') 'succeeded' 'c1') 'conflitti' 'c1'
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'CreaAllineaDevelop'; FeatureId = 7; Ramo = 'feature/f7-la-funzione'; Commit = 'c1' })
        }

        It 'una sola alla volta: con una Bug allinea-develop non unita la chiusura aspetta le sorelle e non ne crea un altra' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto' @{ 51 = 'inFeature'; 70 = 'inSviluppo' }) 'conflitti'
            ($i.Funzionalita.Sorelle | Where-Object { $_.Id -eq 70 }).Tag = @('agents', 'allinea-develop')
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'predecessori'
        }

        It 'la Bug fatta per quel commit e unita ma la PR risulta ancora in conflitto (la validazione non si e aggiornata): non si rifa, aspetta con il motivo' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'conflitti' 'c-testa'
            $i.StatoCard.allineaFatti = @('c-testa')
            $i.Funzionalita.Sorelle = @($i.Funzionalita.Sorelle) + [pscustomobject]@{ Id = 70; Stato = (script:Nome 'inFeature'); Tag = @('agents', 'allinea-develop'); Tipo = 'Bug' }
            $d = script:Get-Dec $i
            @(script:Solo-Azioni $d).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'conflittiFunzionalita'
        }

        It 'commit gia fatto e nessuna sorella allinea-develop viva (rimossa senza unirla): on-hold per una persona con il motivo, non un attesa muta' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'conflitti' 'c-testa'
            $i.StatoCard.allineaFatti = @('c-testa')
            $az = script:Get-Az $i
            script:Test-Azioni $az @(@{ Tipo = 'MettiInAttesa'; Per = 'limite' })
            $az[0].Motivo | Should -BeLike '*allinea-develop*'
        }

        It 'stato locale vuoto con il commento di allinea-develop sulla card: nessuna Bug nuova per quel commit' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'conflitti' 'c-testa'
            $i.CommentiTutti = @([pscustomobject]@{ Id = 56; Autore = 'x'; Quando = '2026-11-02T11:31:00Z'; Testo = "[smistatore] $(ConvertTo-TestoCommentoBugCreata -Tipo 'allinea' -Chiave 'c-testa' -Bug 400)" })
            $i.Funzionalita.Sorelle = @($i.Funzionalita.Sorelle) + [pscustomobject]@{ Id = 70; Stato = (script:Nome 'inFeature'); Tag = @('agents', 'allinea-develop'); Tipo = 'Bug' }
            @(script:Get-Az $i | Where-Object { $_.Tipo -eq 'CreaAllineaDevelop' }).Count | Should -Be 0
        }

        It 'la Bug allinea-develop in Ready to develop, senza task, fa partire dev dal ramo della funzionalita (senza il responsabile)' {
            $i = script:Funz-Sorella (script:New-Ist 'pronto')
            $i.Card.Tag = @('agents', 'allinea-develop'); $i.Card.Tipo = 'Bug'
            $i.StatoCard.ramo = $null; $i.StatoCard.cartella = $null
            $az = script:Get-Az $i
            @($az | ForEach-Object { $_.Tipo }) | Should -Be @('CreaWorktree', 'SpostaCard', 'LanciaSessione')
            $az[0].Base | Should -Be 'feature/f7-la-funzione'
            $az[2].Ruolo | Should -Be 'dev'
            $az[2].Motivo | Should -Be 'pronto'
            $az[2].Task | Should -BeNullOrEmpty
        }

        It 'un commit di testa nuovo (la Bug e stata unita e il conflitto c e ancora) puo avere la sua Bug' {
            $i = script:Con-Pr (script:Chiusura-In 'pronto') 'conflitti' 'c-nuovo'
            $i.StatoCard.allineaFatti = @('c-testa')
            script:Test-Azioni (script:Get-Az $i) @(@{ Tipo = 'CreaAllineaDevelop'; Commit = 'c-nuovo' })
        }
    }
}

Describe 'D59: l ambiente Docker di collaudo al posto del deploy in Test' {
    BeforeAll {
        # Un componente con la voce collaudo: niente pipelineDeploy ne urlTest, il Test e l ambiente della card
        function script:New-VoceCollaudo {
            [pscustomobject]@{ repo = 'Acme.AI'; componente = 'stime'
                collaudo = [pscustomobject]@{ compose = 'collaudo/stime/compose.yaml'; porte = @('WEB', 'API'); url = [pscustomobject]@{ WebApp = 'WEB'; Api = 'API' } } }
        }
        function script:New-IstColl([string]$Chiave = 'inDeployTest') {
            $i = script:New-Ist $Chiave 'inRevisione' -Chi 'u-titolare'
            $i.Voce = script:New-VoceCollaudo; $i.Deploy = $null
            script:Set-Sessione $i 'dev' 'fatto' -Fine '2026-11-02T10:00:00Z'
            script:Set-Sessione $i 'reviewer' 'superata' -Fine '2026-11-03T10:00:00Z'
            $i
        }
        # l ambiente creato per l ingresso (rev 7) e il suo esito, nella forma del run di deploy
        function script:Con-Ambiente($i, [string]$Esito = 'succeeded', [string]$Stato = 'completed') {
            $i.StatoCard.collaudoSlot = 1; $i.StatoCard.collaudoProgetto = 'card-100'; $i.StatoCard.runDopoRev = 7
            $i.StatoCard.collaudoUrl = [ordered]@{ WebApp = 'http://localhost:21100'; Api = 'http://localhost:21101' }
            $i.Run = [pscustomobject]@{ Stato = $Stato; Esito = $Esito; Url = $null; Log = 'C:\dati\collaudo\card-100.log' }
            $i
        }
        function script:Get-AzColl($i, $c = (script:New-Contesto)) { , @(Get-Azioni -Istantanea $i -Contesto $c) }
        function script:Contesto-Ambienti([int[]]$Altre) { $c = script:New-Contesto; $c.AmbientiCollaudo = @($Altre); $c }
        function script:Funz-Collaudo($i, [bool]$EChiusura) {
            $i.StatoCard.destinazione = if ($EChiusura) { 'develop' } else { 'feature/f7-la-funzione' }
            $i.Funzionalita = @{
                Feature = [pscustomobject]@{ Id = 7; Titolo = 'La funzione'; Stato = $script:Stati.featureAttiva; Tag = @(); Area = 'x' }
                Chiusura = $(if ($EChiusura) { 100 } else { 22 }); Sorelle = @(); Ramo = 'feature/f7-la-funzione'; EChiusura = $EChiusura; StatoChiusura = (script:Nome 'inDeployTest')
            }
            if ($EChiusura) { $i.StatoCard.cartella = $null }
            $i
        }
    }

    Context 'ingresso e limite' {
        It 'In review superata con la voce collaudo: va in Deploying to test (non e senza Test)' {
            $i = script:New-IstColl 'inRevisione'
            script:Test-Azioni (script:Get-AzColl $i) @(@{ Tipo = 'SpostaCard'; Stato = 'inDeployTest' })
        }
        It 'senza pipelineDeploy e senza collaudo la card resta senza Test (come prima)' {
            $i = script:New-IstColl 'inRevisione'; $i.Voce = [pscustomobject]@{ repo = 'Acme.AI'; componente = 'stime' }
            script:Test-Azioni (script:Get-AzColl $i) @(@{ Tipo = 'SpostaCard'; Stato = 'daUnire' })
        }
        It 'con ambientiCollaudo card gia in Test, di qualunque componente, resta In review: motivo limiteAmbienti con le card' {
            $i = script:New-IstColl 'inRevisione'
            $n = [int]$script:Limiti.ambientiCollaudo
            $altre = @(1..$n | ForEach-Object { 200 + $_ })
            $d = Get-Decisione -Istantanea $i -Contesto (script:Contesto-Ambienti ($altre + 100))
            @($d.Azioni).Count | Should -Be 0
            $d.Motivo.Tipo | Should -Be 'limiteAmbienti'
            $d.Motivo.Ruolo | Should -Be 'collaudatore'
            Format-MotivoCoda $d.Motivo | Should -Be "in coda, gli ambienti di collaudo sono tutti occupati ($n/${n}: card $($altre -join ', '))"
        }
        It 'un posto in meno del limite: la card passa' {
            $i = script:New-IstColl 'inRevisione'
            $altre = @(1..([int]$script:Limiti.ambientiCollaudo - 1) | ForEach-Object { 200 + $_ })
            script:Test-Azioni (script:Get-AzColl $i (script:Contesto-Ambienti $altre)) @(@{ Tipo = 'SpostaCard'; Stato = 'inDeployTest' })
        }
        It 'con human-test il motivo del limite non ha ruolo' {
            $i = script:New-IstColl 'inRevisione'; $i.Card.Tag = @($script:Stati.tagAgenti, $script:Stati.tagProvaUmana)
            $n = [int]$script:Limiti.ambientiCollaudo
            $d = Get-Decisione -Istantanea $i -Contesto (script:Contesto-Ambienti (1..$n | ForEach-Object { 200 + $_ }))
            $d.Motivo.Tipo | Should -Be 'limiteAmbienti'
            $d.Motivo.Ruolo | Should -BeNullOrEmpty
        }
        It 'il limite per componente (cardInTestPerComponente) non conta per la voce collaudo' {
            $i = script:New-IstColl 'inRevisione'
            $c = script:New-Contesto; $c.InTestPerComponente = @{ stime = @(100, 8) }
            script:Test-Azioni (script:Get-AzColl $i $c) @(@{ Tipo = 'SpostaCard'; Stato = 'inDeployTest' })
        }
    }

    Context 'Deploying to test' {
        It 'crea l ambiente con la revisione d ingresso, senza scegliere i parametri del deploy' {
            $i = script:New-IstColl; $i.Deploy = @{ Scelta = @(); AmmessiLetti = $true; Ammessi = @() }
            script:Test-Azioni (script:Get-AzColl $i) @(@{ Tipo = 'CreaAmbienteCollaudo'; Rev = 7 })
        }
        It 'la voce senza collaudo accoda ancora il deploy come prima' {
            $i = script:New-Ist 'inDeployTest' 'inRevisione' -Chi 'u-titolare'
            script:Set-Sessione $i 'dev' 'fatto'; script:Set-Sessione $i 'reviewer' 'superata' -Fine '2026-11-03T10:00:00Z'
            (script:Get-AzColl $i)[0].Tipo | Should -Be 'AccodaDeployTest'
        }
        It 'oltre il limite degli ambienti torna In review senza on-hold' {
            $i = script:New-IstColl
            $n = [int]$script:Limiti.ambientiCollaudo
            $az = script:Get-AzColl $i (script:Contesto-Ambienti (1..$n | ForEach-Object { 200 + $_ }))
            script:Test-Azioni $az @(@{ Tipo = 'RiportaIndietro'; Stato = 'inRevisione' })
        }
        It 'ambiente in creazione: aspetta' {
            $i = script:Con-Ambiente (script:New-IstColl) -Esito $null -Stato 'inProgress'
            (script:Get-AzColl $i).Count | Should -Be 0
        }
        It 'ambiente pronto: Automated test, o Human test con il tag (umana: <Umana>)' -ForEach @(@{ Umana = $false; Atteso = 'inCollaudo' }, @{ Umana = $true; Atteso = 'inProvaUmana' }) {
            $i = script:Con-Ambiente (script:New-IstColl)
            if ($Umana) { $i.Card.Tag += $script:Stati.tagProvaUmana }
            script:Test-Azioni (script:Get-AzColl $i) @(@{ Tipo = 'SpostaCard'; Stato = $Atteso })
        }
        It 'ambiente non creato: on-hold deployFallito (dopo la passata del responsabile) con il log nel motivo' {
            $i = script:Con-Ambiente (script:New-IstColl) -Esito 'failed'
            script:Set-PassataFatta $i
            $az = script:Get-AzColl $i
            $az[-1].Tipo | Should -Be 'MettiInAttesa'
            $az[-1].Per | Should -Be 'deploy'
            $az[-1].Motivo | Should -Be 'ambiente di collaudo non creato, log: C:\dati\collaudo\card-100.log: sistemata la causa, togli il tag e l ambiente si ricrea'
        }
        It 'tolto il tag dopo il fallimento: si dimentica l esito e si ricrea l ambiente' {
            $i = script:Con-Ambiente (script:New-IstColl) -Esito 'failed'
            $i.StatoCard.inAttesaPer = 'deploy'
            $az = script:Get-AzColl $i
            @($az | ForEach-Object { $_.Tipo }) | Should -Contain 'AzzeraDeploy'
            $az[-1].Tipo | Should -Be 'CreaAmbienteCollaudo'
        }
    }

    Context 'uscita dagli stati di Test' {
        It 'una card fuori dal Test con un ambiente lo butta, come prima azione, in <Chiave>' -ForEach @(
            @{ Chiave = 'inRevisione' }, @{ Chiave = 'inSviluppo' }, @{ Chiave = 'daUnire' }, @{ Chiave = 'daRilasciare' }, @{ Chiave = 'chiusa' }, @{ Chiave = 'rimossa' }, @{ Chiave = 'pronto' }
        ) {
            $i = script:Con-Ambiente (script:New-IstColl $Chiave)
            $az = script:Get-AzColl $i
            $az[0].Tipo | Should -Be 'ButtaAmbienteCollaudo'
        }
        It 'anche con l on-hold, con una sessione in corso e senza il tag degli agenti' {
            $i = script:Con-Ambiente (script:New-IstColl 'inSviluppo'); $i.Card.Tag += $script:Stati.tagAttesa
            (script:Get-AzColl $i)[0].Tipo | Should -Be 'ButtaAmbienteCollaudo'
            $i = script:Con-Ambiente (script:New-IstColl 'inSviluppo'); $i.StatoCard.sessione = @{ id = 's'; ruolo = 'dev'; pid = 1 }
            (script:Get-AzColl $i)[0].Tipo | Should -Be 'ButtaAmbienteCollaudo'
            $i = script:Con-Ambiente (script:New-IstColl 'inSviluppo'); $i.Card.Tag = @()
            (script:Get-AzColl $i)[0].Tipo | Should -Be 'ButtaAmbienteCollaudo'
        }
        It 'nei tre stati di Test l ambiente resta: <Chiave>' -ForEach @(@{ Chiave = 'inDeployTest' }, @{ Chiave = 'inCollaudo' }, @{ Chiave = 'inProvaUmana' }) {
            $i = script:Con-Ambiente (script:New-IstColl $Chiave)
            @(script:Get-AzColl $i | Where-Object { $_.Tipo -eq 'ButtaAmbienteCollaudo' }).Count | Should -Be 0
        }
        It 'senza ambiente salvato non c e niente da buttare' {
            $i = script:New-IstColl 'inSviluppo'
            @(script:Get-AzColl $i | Where-Object { $_.Tipo -eq 'ButtaAmbienteCollaudo' }).Count | Should -Be 0
        }
    }

    Context 'il collaudatore' {
        It 'riceve gli URL dell ambiente della card al posto di urlTest' {
            $i = script:Con-Ambiente (script:New-IstColl 'inCollaudo')
            $az = script:Get-AzColl $i
            $az[0].Tipo | Should -Be 'LanciaSessione'; $az[0].Ruolo | Should -Be 'collaudatore'
            $az[0].Allegato | Should -Match 'Ambiente di collaudo della card'
            $az[0].Allegato | Should -Match 'WebApp: http://localhost:21100'
            $az[0].Allegato | Should -Match 'Api: http://localhost:21101'
            $az[0].Allegato | Should -Not -Match 'urlTest'
        }
        It 'senza URL salvati si ferma con ESITO=bloccato' {
            $i = script:Con-Ambiente (script:New-IstColl 'inCollaudo'); $i.StatoCard.collaudoUrl = $null
            (script:Get-AzColl $i)[0].Allegato | Should -Match 'ESITO=bloccato'
        }
        It 'la voce con urlTest e il deploy resta com era' {
            $i = script:New-InTest; script:Set-Stato $i 'inCollaudo'
            (script:Get-AzColl $i)[0].Allegato | Should -Be 'Ambiente di Test: https://test.example.invalid/stime'
        }
    }

    Context 'la funzionalita (D52): solo la card di chiusura ha un ambiente' {
        It 'la card di chiusura con la voce collaudo crea l ambiente dal ramo della funzionalita (azione per la card di chiusura)' {
            $i = script:Funz-Collaudo (script:New-IstColl) $true
            $i.StatoCard.ramo = 'feature/f7-la-funzione'
            script:Test-Azioni (script:Get-AzColl $i) @(@{ Tipo = 'CreaAmbienteCollaudo'; Rev = 7; Chiusura = $true })
        }
        It 'una card figlia con la voce collaudo non ha ambiente: va dritta in Ready to merge' {
            $i = script:Funz-Collaudo (script:New-IstColl 'inRevisione') $false
            script:Test-Azioni (script:Get-AzColl $i) @(@{ Tipo = 'SpostaCard'; Stato = 'daUnire' })
        }
        It 'la chiusura che ha un ambiente pronto passa al collaudo automatico' {
            $i = script:Con-Ambiente (script:Funz-Collaudo (script:New-IstColl) $true)
            $i.StatoCard.ramo = 'feature/f7-la-funzione'
            script:Test-Azioni (script:Get-AzColl $i) @(@{ Tipo = 'SpostaCard'; Stato = 'inCollaudo' })
        }
    }
}

Describe 'D59: lo slot e gli URL dell ambiente di collaudo' {
    It 'Get-SlotCollaudoLibero: il piu piccolo non usato, 0 se sono tutti presi' {
        Get-SlotCollaudoLibero @() 3 | Should -Be 1
        Get-SlotCollaudoLibero @(1, 3) 3 | Should -Be 2
        Get-SlotCollaudoLibero @(2, 1) 3 | Should -Be 3
        Get-SlotCollaudoLibero @(1, 2, 3) 3 | Should -Be 0
        Get-SlotCollaudoLibero $null 2 | Should -Be 1
    }
    It 'ConvertTo-ElencoUrlCollaudo: nome: url, da una tabella o da un oggetto riletto dallo stato; vuoto senza URL' {
        ConvertTo-ElencoUrlCollaudo ([ordered]@{ WebApp = 'http://h:1'; Api = 'http://h:2' }) | Should -Be "- WebApp: http://h:1`n- Api: http://h:2"
        ConvertTo-ElencoUrlCollaudo ('{ "WebApp": "http://h:1" }' | ConvertFrom-Json) | Should -Be '- WebApp: http://h:1'
        ConvertTo-ElencoUrlCollaudo $null | Should -BeNullOrEmpty
    }
}

Describe 'D61: Ready to deploy (test), in Ready to release con il deploy di develop che contiene la card' {
    BeforeAll {
        function script:Dt($i) { , @(Get-Azioni -Istantanea $i -Contesto (script:New-Contesto)) }
        function script:New-Dt([bool]$Contenuto, [bool]$ConDeploy = $true) {
            $i = script:New-Ist 'daDeployTest' 'daUnire' 'u-titolare'
            $i.Pr = [pscustomobject]@{ Id = 3; Stato = 'completed'; Validazione = 'assente'; BuildId = $null; UrlLog = $null }
            $i.StatoCard.cartella = $null; $i.StatoCard.ramo = $null; $i.StatoCard.prId = 3; $i.StatoCard.commitMerge = 'm1'
            $i.DeployDevelop = if ($ConDeploy) { [pscustomobject]@{ Contenuto = $Contenuto; RunId = 900; Url = 'https://x/900' } } else { $null }
            $i
        }
    }
    It 'il deploy di develop riuscito contiene il merge: Ready to release' {
        script:Test-Azioni (script:Dt (script:New-Dt $true)) @(@{ Tipo = 'SpostaCard'; Stato = 'daRilasciare' })
    }
    It 'l ultimo deploy di develop non contiene ancora il merge: aspetta' {
        script:Test-Azioni (script:Dt (script:New-Dt $false)) @()
    }
    It 'nessun deploy letto (Azure DevOps non risponde, o merge non ancora noto): aspetta' {
        script:Test-Azioni (script:Dt (script:New-Dt $false -ConDeploy $false)) @()
    }
    It 'con il worktree ancora presente lo toglie, e se il deploy la contiene avanza nello stesso giro' {
        $i = script:New-Dt $true; $i.StatoCard.cartella = 'C:/wt/x'; $i.StatoCard.ramo = 'feature/x'
        script:Test-Azioni (script:Dt $i) @(@{ Tipo = 'RimuoviWorktree' }, @{ Tipo = 'SpostaCard'; Stato = 'daRilasciare' })
    }
    It 'un componente senza deploy in Test (niente pipelineDeploy) va dritto in Ready to release' {
        $i = script:New-Dt $false -ConDeploy $false; $i.Voce = [pscustomobject]@{ repo = 'Acme.AI'; componente = 'stime' }
        script:Test-Azioni (script:Dt $i) @(@{ Tipo = 'SpostaCard'; Stato = 'daRilasciare' })
    }
    It 'un predecessore in Ready to deploy (test) a PR completata e worktree tolto e unito: il lavoro e in develop' {
        Test-PredecessoreUnito (script:New-Contesto).Stati ([pscustomobject]@{ Stato = 'Ready to deploy (test)'; prId = 7; cartella = $null }) | Should -BeTrue
    }
}
