BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/CosaFare.psm1') -Force -Global
}

Describe 'Get-IndicazioniPersona' {
    It 'legge le tre righe in testa al testo, con o senza accento, elenco e grassetto' {
        $t = "**Per Titolare:** rilancia la validazione del gateway sulla PR 1146`n- Perché: il test e instabile, verde in locale`nPerche non gli agenti: dev non rilancia una build (D38)`n`nDiagnosi lunga...`nESITO=bloccato"
        $i = Get-IndicazioniPersona $t
        $i.Gesto | Should -Be 'rilancia la validazione del gateway sulla PR 1146'
        $i.Perche | Should -Be 'il test e instabile, verde in locale'
        $i.PercheNonAgenti | Should -Be 'dev non rilancia una build (D38)'
        $i.Fonte | Should -Be 'agente'
    }
    It 'senza la riga Per Titolare non ci sono indicazioni' {
        Get-IndicazioniPersona "Perche: qualcosa`nESITO=bloccato" | Should -BeNullOrEmpty
        Get-IndicazioniPersona '' | Should -BeNullOrEmpty
    }
    It 'vale la prima occorrenza di ogni riga' {
        (Get-IndicazioniPersona "Per Titolare: primo`nPer Titolare: secondo").Gesto | Should -Be 'primo'
    }
}

Describe 'Get-IndicazioniAttesa' {
    It 'le righe del ruolo, completate dal predefinito dove mancano' {
        $i = Get-IndicazioniAttesa 'Per Titolare: rilancia la validazione sulla PR 7' 'dev chiede di nuovo di rilanciare la validazione: il test che fallisce va guardato da una persona' 'limite' ''
        $i.Fonte | Should -Be 'agente'
        $i.Gesto | Should -Be 'rilancia la validazione sulla PR 7'
        $i.Perche | Should -Match 'seconda volta'
        $i.PercheNonAgenti | Should -Match 'supervisore non rilancia le validazioni'
    }
    It 'un on-hold di Close-Sessione ignora le righe della sessione: lo ha deciso lo smistatore' {
        $i = Get-IndicazioniAttesa 'Per Titolare: altro' 'x' 'sessione' 'scritture'
        $i.Fonte | Should -Be 'predefinita'
        $i.Gesto | Should -Match 'worktree'
    }
    It 'ogni caso predefinito ha gesto, perche e perche non gli agenti' {
        foreach ($c in @(@('m', 'sessione', 'fallita'), @('m', 'sessione', 'silenzio'), @('m', 'sessione', 'morta'), @('troppe validazioni rosse di fila', 'limite', ''),
                @('m', 'deploy', ''), @('m', $null, ''), @('m', 'sessione', ''))) {
            $i = Get-IndicazioniAttesa '' $c[0] $c[1] $c[2]
            $i.Fonte | Should -Be 'predefinita'
            $i.Gesto | Should -Not -BeNullOrEmpty; $i.Perche | Should -Not -BeNullOrEmpty; $i.PercheNonAgenti | Should -Not -BeNullOrEmpty
        }
        (Get-IndicazioniAttesa '' 'troppe validazioni rosse di fila' 'limite' '').Perche | Should -Be 'troppe validazioni rosse di fila'
    }
}

Describe 'Get-RigheCosaFare e Format-CosaFare' {
    BeforeAll { $script:Ind = [ordered]@{ Gesto = 'rilancia la validazione sulla PR 1146'; Perche = 'test instabile'; PercheNonAgenti = 'D38'; Fonte = 'agente' } }
    It 'i passi in ordine, poi perche, perche non gli agenti e l avviso su Draft e New' {
        $r = @(Get-RigheCosaFare $script:Ind 'limite')
        $r[0] | Should -Be '1. rilancia la validazione sulla PR 1146'
        $r[1] | Should -Be "2. Togli l'on-hold: i contatori ripartono da zero e lo smistatore riprende la card dallo stato in cui e."
        $r[2] | Should -Be 'Perche: test instabile'
        $r[3] | Should -Be "Perche non l'hanno fatto gli agenti: D38"
        $r[4] | Should -Match '^Non riportarla in Draft o in New'
        $r.Count | Should -Be 5
    }
    It 'l effetto di togliere l on-hold dipende da inAttesaPer' {
        Get-EffettoTogliAttesa 'sessione' | Should -Match "riparte l'agente"
        Get-EffettoTogliAttesa 'deploy' | Should -Match 'riaccoda il deploy'
        Get-EffettoTogliAttesa 'limite' | Should -Match 'contatori ripartono'
        Get-EffettoTogliAttesa $null | Should -Match 'prossimo giro'
    }
    It 'senza indicazioni non c e la sezione' {
        @(Get-RigheCosaFare $null 'limite').Count | Should -Be 0
        Format-CosaFare $null 'limite' | Should -Be ''
    }
    It 'nel commento un paragrafo per riga sotto il titolo' {
        $t = Format-CosaFare $script:Ind 'deploy'
        $t | Should -Match '^\*\*Cosa fare\*\*\n\n1\. rilancia'
        $t | Should -Match "\n\n2\. Togli l'on-hold: lo smistatore dimentica il run fallito"
    }
}

Describe 'Get-UltimaSessioneCard' {
    It 'la sessione finita per ultima, la senza fine conta dall inizio' {
        $sc = @{ ultimaSessione = @{
                dev = @{ inizio = '2026-11-26T08:00:00Z'; fine = '2026-11-26T09:00:00Z'; testo = 'd' }
                responsabile = @{ inizio = '2026-11-26T10:00:00Z'; testo = 'r' } } }
        $u = Get-UltimaSessioneCard $sc
        $u.Ruolo | Should -Be 'responsabile'; $u.Sessione.testo | Should -Be 'r'
        Get-UltimaSessioneCard @{} | Should -BeNullOrEmpty
    }
}

Describe 'Format-GestoPredecessoreInAttesa' {
    It 'il gesto della predecessora, poi togliere l on-hold' {
        Format-GestoPredecessoreInAttesa @{ Gesto = 'rilancia la validazione del gateway sulla PR 1146.' } | Should -Be "e in on-hold: rilancia la validazione del gateway sulla PR 1146, poi togli l'on-hold"
    }
    It 'senza indicazioni rimanda al commento' {
        Format-GestoPredecessoreInAttesa $null | Should -Match 'commento dello smistatore'
    }
}
