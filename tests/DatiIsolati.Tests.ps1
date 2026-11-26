# D53: Get-Config e Get-ConfigSupervisore leggono gli override da impostazioni.json nella cartella dati. Un test che li chiama senza una cartella
# sua leggerebbe quella vera di chi lancia i test, e passerebbe o fallirebbe a seconda delle sue impostazioni. La guardia: ogni file di test che
# chiama una delle due funzioni (o l'installazione delle attivita pianificate, che legge gli intervalli) isola ATTREZZI_DATI.
# La guardia e PARZIALE: vede solo le chiamate dirette nei file di test. Chi arriva a Get-Config attraverso un modulo (Card.psm1, MemoriaRepo.psm1,
# Sessioni.psm1, memoria.ps1) non si vede: quei file di test sono isolati a mano (Card, Memoria, MemoriaRepo, Sessioni, Task) e un file nuovo che
# li usa va isolato allo stesso modo.
Describe 'I test non leggono la cartella dati vera (D53)' {
    BeforeAll {
        $script:ChiamanoLaConfig = @(Get-ChildItem $PSScriptRoot -Filter '*.Tests.ps1' | Where-Object { $_.Name -ne 'DatiIsolati.Tests.ps1' } | Where-Object {
            $righe = @(Get-Content $_.FullName | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*Mock ' })
            @($righe | Where-Object { $_ -match '(=|\(|^|\{|;|\|)\s*Get-Config(Supervisore)?\b' -or $_ -match '\$script:Install\s+-Pianificazione\b' }).Count -gt 0
        })
    }
    It 'ci sono file che chiamano la config (la guardia non e vuota)' {
        $script:ChiamanoLaConfig.Count | Should -BeGreaterThan 3
    }
    It 'ognuno di quei file imposta ATTREZZI_DATI su una cartella sua' {
        $senza = @($script:ChiamanoLaConfig | Where-Object { (Get-Content $_.FullName -Raw) -notmatch '\$env:ATTREZZI_DATI\s*=' } | ForEach-Object Name)
        $senza | Should -BeNullOrEmpty -Because "questi test leggerebbero impostazioni.json vero: $($senza -join ', ')"
    }
}
