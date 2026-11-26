BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Decisioni.psm1') -Force
    $script:Stati = Get-Content (Join-Path $PSScriptRoot '../config/stati.json') -Raw | ConvertFrom-Json
    function script:Card([int]$Id, $Padre = $null, [string]$Chiave = 'pronto', [string[]]$Tag = @()) {
        [pscustomobject]@{ Id = $Id; Stato = $script:Stati.$Chiave; Tag = @($script:Stati.tagAgenti) + $Tag; PadreId = $Padre }
    }
    function script:Feature([int]$Id, $Rank = $null, [string[]]$Tag = @()) {
        [pscustomobject]@{ Id = $Id; Titolo = "F$Id"; Rank = $Rank; Tag = $Tag }
    }
}

Describe 'Get-FermoPriorita: pausa e Feature obbligatoria (D60)' {
    BeforeAll {
        $script:Ctx = @{ Stati = $script:Stati; Feature = (Get-MappaFeature @((script:Feature 10 1000 @($script:Stati.tagPausa)), (script:Feature 20 2000)) $script:Stati) }
    }
    It 'una card figlia di una Feature in pausa e ferma, e il motivo dice quale Feature' {
        $m = Get-FermoPriorita (script:Card 1 10) $script:Ctx
        $m.Tipo | Should -Be 'pausa'; $m.Feature | Should -Be 10
    }
    It 'una card figlia di una Feature non in pausa va' {
        Get-FermoPriorita (script:Card 2 20) $script:Ctx | Should -BeNullOrEmpty
    }
    It 'il tag di pausa sulla card la ferma anche se la Feature va' {
        $m = Get-FermoPriorita (script:Card 3 20 'pronto' @($script:Stati.tagPausa)) $script:Ctx
        $m.Tipo | Should -Be 'pausa'; $m.Feature | Should -BeNullOrEmpty
    }
    It 'una card in New senza Feature non parte; oltre New finisce il suo giro' {
        (Get-FermoPriorita (script:Card 4 $null 'nuova') $script:Ctx).Tipo | Should -Be 'senzaFeature'
        Get-FermoPriorita (script:Card 5 $null 'inSviluppo') $script:Ctx | Should -BeNullOrEmpty
    }
    It 'una Feature che non e fra le aperte lette non mette in pausa; in New conta come nessuna Feature' {
        Get-FermoPriorita (script:Card 6 99) $script:Ctx | Should -BeNullOrEmpty
        (Get-FermoPriorita (script:Card 8 99 'nuova') $script:Ctx).Tipo | Should -Be 'senzaFeature'
    }
    It 'Test-CardInPausa: solo la pausa, non la Feature mancante' {
        Test-CardInPausa (script:Card 1 10 'inSviluppo') $script:Ctx | Should -BeTrue
        Test-CardInPausa (script:Card 4 $null 'nuova') $script:Ctx | Should -BeFalse
        Test-CardInPausa (script:Card 2 20 'inSviluppo') $script:Ctx | Should -BeFalse
    }
    It 'Get-Decisione non lancia niente per una card in pausa e dice il motivo' {
        $ist = @{ Card = (script:Card 7 10 'pronto'); StatoCard = @{} }
        $ctx = $script:Ctx.Clone(); $ctx.Limiti = @{ sessioniAttive = 3 }; $ctx.SessioniAttive = 0
        $d = Get-Decisione -Istantanea $ist -Contesto $ctx
        @($d.Azioni).Count | Should -Be 0
        $d.Motivo.Tipo | Should -Be 'pausa'
        Format-MotivoCoda $d.Motivo | Should -Match 'Feature #10'
    }
}

Describe 'Get-OrdineCard e Get-OrdineFeature: la priorita dal backlog (D60)' {
    It 'le Feature vanno per Stack Rank, quelle mai ordinate in fondo per id' {
        $o = Get-OrdineFeature @((script:Feature 5), (script:Feature 3 2000), (script:Feature 4), (script:Feature 9 500))
        @($o | ForEach-Object Id) | Should -Be @(9, 3, 4, 5)
    }
    It 'le card seguono la Feature padre, poi le Feature senza rank, poi le card senza Feature; a parita per id' {
        $m = Get-MappaFeature @((script:Feature 10 2000), (script:Feature 20 1000), (script:Feature 30)) $script:Stati
        $card = @((script:Card 1), (script:Card 2 10), (script:Card 3 20), (script:Card 4 30), (script:Card 5 20), (script:Card 6 77))
        @(Get-OrdineCard $card $m | ForEach-Object Id) | Should -Be @(3, 5, 2, 4, 1, 6)
    }
}

Describe 'Get-RankRiordino: lo spostamento dalla vista (D60)' {
    It 'mai ordinate: si numerano tutte nell ordine nuovo' {
        $r = Get-RankRiordino @((script:Feature 1), (script:Feature 2), (script:Feature 3)) 3 0
        @($r | ForEach-Object { "$($_.Id)=$($_.Rank)" }) | Should -Be @('3=1000', '1=2000', '2=3000')
    }
    It 'con tutte ordinate scrive solo la Feature spostata, a meta fra le vicine' {
        $f = @((script:Feature 1 1000), (script:Feature 2 2000), (script:Feature 3 3000), (script:Feature 4 4000))
        @(Get-RankRiordino $f 2 3 | ForEach-Object { "$($_.Id)=$($_.Rank)" }) | Should -Be @('2=3500')
        @(Get-RankRiordino $f 4 0 | ForEach-Object { "$($_.Id)=$($_.Rank)" }) | Should -Be @('4=0')
        @(Get-RankRiordino $f 1 4 | ForEach-Object { "$($_.Id)=$($_.Rank)" }) | Should -Be @('1=5000')
    }
    It 'senza spazio fra le vicine rinumera e scrive solo quelle che cambiano' {
        $f = @((script:Feature 1 1000), (script:Feature 2 1000), (script:Feature 3 3000))
        @(Get-RankRiordino $f 3 1 | ForEach-Object { "$($_.Id)=$($_.Rank)" }) | Should -Be @('3=2000', '2=3000')
    }
    It 'rifiuta id e posizioni che non sono fra le Feature aperte' {
        $f = @((script:Feature 1 1000), (script:Feature 2 2000))
        { Get-RankRiordino $f 9 0 } | Should -Throw '*9*'
        { Get-RankRiordino $f 1 9 } | Should -Throw '*9*'
        { Get-RankRiordino $f 1 1 } | Should -Throw
    }
}

Describe 'La soglia delle 5 ore (D60)' {
    BeforeAll {
        $script:Adesso = '2026-11-26T10:00:00Z'
        $script:Reset5 = '2026-11-26T12:00:00.0000000Z'
        $script:Quota = @{ fiveHour = @{ utilization = 0.72; resetsAt = $script:Reset5 }; sevenDay = @{ utilization = 0.13; resetsAt = '2026-12-03T02:00:00Z' } }
        $script:Limiti = @{ sogliaQuotaSettimanale = 0.70; sogliaQuota5Ore = 0.60 }
        function script:Ctx5($Quota = $script:Quota, $Override = $null) { @{ Quota = $Quota; Adesso = $script:Adesso; Limiti = $script:Limiti; OverrideQuota = $Override } }
    }
    It 'oltre la soglia blocca fino al reset della finestra' {
        $b = Get-BloccoQuota (script:Ctx5)
        $b.Causa | Should -Be 'cinqueOre'; $b.Soglia | Should -Be 0.60
        (ConvertTo-DataUtc $b.Fino) | Should -Be (ConvertTo-DataUtc $script:Reset5)
        Format-MotivoCoda $b | Should -Match 'soglia delle 5 ore'
    }
    It 'un reset gia passato non blocca' {
        $q = @{ fiveHour = @{ utilization = 0.9; resetsAt = '2026-11-26T09:00:00Z' } }
        Get-BloccoQuota (script:Ctx5 $q) | Should -BeNullOrEmpty
        (Get-RiepilogoQuota (script:Ctx5 $q)).Uso5Ore | Should -Be 0
    }
    It 'ignorare la riserva settimanale non salta la soglia delle 5 ore' {
        (Get-BloccoQuota (script:Ctx5 $script:Quota @{ soglia = $null; ignoraRiserva = $true; fino = '2026-12-03T02:00:00Z' })).Causa | Should -Be 'cinqueOre'
    }
    It 'alzata dalla vista sopra l uso sblocca, e scade al reset della finestra' {
        $r = Get-OverrideSogliaQuota @{ soglia5Ore = '0.8' } $script:Quota @{} $script:Adesso
        $r.Esito | Should -Be 'ok'
        $r.Override.soglia5Ore | Should -Be 0.8
        (ConvertTo-DataUtc $r.Override.fino5Ore) | Should -Be (ConvertTo-DataUtc $script:Reset5)
        Get-BloccoQuota (script:Ctx5 $script:Quota $r.Override) | Should -BeNullOrEmpty
        $q = Get-RiepilogoQuota (script:Ctx5 $script:Quota $r.Override)
        $q.Soglia5Ore | Should -Be 0.8; $q.DaOverride5Ore | Should -BeTrue
        (Get-Soglia5OreEffettiva $script:Limiti $r.Override '2026-11-26T12:30:00Z').DaOverride | Should -BeFalse
    }
    It 'cambiare la soglia settimanale lascia quella delle 5 ore, e viceversa' {
        $c = (Get-OverrideSogliaQuota @{ soglia5Ore = '0.8' } $script:Quota @{} $script:Adesso).Override
        $o = (Get-OverrideSogliaQuota @{ soglia = '0.85' } $script:Quota $c $script:Adesso).Override
        $o.soglia | Should -Be 0.85; $o.soglia5Ore | Should -Be 0.8
        $o2 = (Get-OverrideSogliaQuota @{ soglia5Ore = '0.7' } $script:Quota $o $script:Adesso).Override
        $o2.soglia | Should -Be 0.85; $o2.soglia5Ore | Should -Be 0.7
    }
    It 'rifiuta una soglia fuori range' {
        (Get-OverrideSogliaQuota @{ soglia5Ore = '0.99' } $script:Quota @{} $script:Adesso).Esito | Should -Be 'errore'
    }
}
