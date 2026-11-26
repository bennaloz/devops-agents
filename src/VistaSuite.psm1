Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Aggiornamento.psm1') -Global

# D53: il riquadro Suite della vista. Qui le frasi e gli allarmi che la pagina mostra; i dati e le regole sono di Aggiornamento.psm1 (che
# scrive aggiornamento.json) e il disegno e di VistaHtml.psm1 (Format-SezioneSuite). La vista non aggiorna niente: legge.

# Una frase per requisito mancante, per la vista, il log e Telegram. Legge sia la forma di Get-RequisitiMancanti sia quella salvata in aggiornamento.json.
function Format-RequisitoMancante($R) {
    $nome = [string](Get-Campo $R 'Nome'); if (-not $nome) { $nome = [string](Get-Campo $R 'nome') }
    $rich = [string](Get-Campo $R 'Richiesta'); if (-not $rich) { $rich = [string](Get-Campo $R 'richiesta') }
    $trov = [string](Get-Campo $R 'Trovata'); if (-not $trov) { $trov = [string](Get-Campo $R 'trovata') }
    if ($trov) { "$nome`: serve la versione $rich o piu nuova, c'e la $trov" } else { "$nome`: serve la versione $rich o piu nuova, ma non e installato o non risponde" }
}

# Cosa mostra la vista (riquadro Suite) dallo stato di aggiornamento.json e dall'interruttore di impostazioni.json. Solo regole di
# lettura: la vista non aggiorna niente. Stato e la frase dell'ultimo esito, Allarme dice se chi guarda deve fare qualcosa.
function ConvertTo-ModelloSuite($Stato, [bool]$Automatico) {
    $m = [ordered]@{ Letto = $false; Canale = $null; Automatico = $Automatico; Installata = 'non nota'; Disponibile = $null; UltimoControllo = 'mai'
        ErroreControllo = $null; Esito = $null; Stato = 'nessun controllo ancora fatto dal supervisore'; Allarme = $false; Pr = @() }
    if ($null -eq $Stato -or @($Stato.Keys).Count -eq 0) { return [pscustomobject]$m }
    $m.Letto = $true
    $m.Canale = [string](Get-Campo $Stato 'canale')
    $m.Installata = Format-VersioneSuite (Get-Campo $Stato 'installata')
    $disp = Get-Campo $Stato 'disponibile'
    $m.Disponibile = if ($disp) { Format-VersioneSuite $disp } else { $null }
    $c = ConvertTo-DataUtc (Get-Campo $Stato 'ultimoControllo')
    $m.UltimoControllo = if ($c) { $c.ToLocalTime().ToString('dd/MM HH:mm', [cultureinfo]::InvariantCulture) } else { 'mai' }
    $m.ErroreControllo = [string](Get-Campo $Stato 'erroreControllo')
    $m.Pr = @(@(Get-Campo $Stato 'prInArrivo') | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject]@{ Numero = [int](Get-Campo $_ 'numero'); Titolo = [string](Get-Campo $_ 'titolo'); Url = [string](Get-Campo $_ 'url') } })
    $e = Get-Campo $Stato 'ultimoEsito'
    $nome = [string](Get-Campo $e 'esito')
    $m.Esito = $nome
    $canale = if ($m.Canale) { "origin/$($m.Canale)" } else { 'origin' }
    switch ($nome) {
        'aggiornato' { $m.Stato = "aggiornata all'ultima versione$(if ($m.Disponibile) { ' disponibile' })" }
        'daAggiornare' { $m.Stato = "c'e una versione nuova e l'aggiornamento automatico e spento: premi Aggiorna adesso" }
        'inAttesaSessioni' {
            $da = ConvertTo-DataUtc (Get-Campo $e 'da')
            $m.Stato = "in attesa che finiscano le sessioni degli agenti$(if ($da) { ' (dal ' + $da.ToLocalTime().ToString('dd/MM HH:mm', [cultureinfo]::InvariantCulture) + ')' })"
            if ([bool](Get-Campo $e 'oltreSoglia')) { $m.Stato += ': l''attesa dura da molto, non forzo'; $m.Allarme = $true }
        }
        'requisitiMancanti' { $m.Stato = 'non aggiorno, la versione nuova chiede di piu: ' + ((@(Get-Campo $e 'elenco') | ForEach-Object { Format-RequisitoMancante $_ }) -join '; '); $m.Allarme = $true }
        'modificheLocali' { $m.Stato = 'non aggiorno, la copia ha modifiche locali: ' + (@(Get-Campo $e 'file') -join ', '); $m.Allarme = $true }
        'copiaAvanti' { $m.Stato = "non aggiorno: la copia e avanti rispetto a $canale"; $m.Allarme = $true }
        'divergente' { $m.Stato = "non aggiorno: la copia e divergente da $canale"; $m.Allarme = $true }
        'ramoCanaleDivergente' { $m.Stato = "non aggiorno: il ramo locale $($m.Canale) ha commit che $canale non ha, e passare al canale li perderebbe: sistemali a mano"; $m.Allarme = $true }
        'fallitoTornatoIndietro' {
            $m.Stato = "l'ultimo aggiornamento e fallito ed e tornato alla versione di prima (commit scartato $(([string](Get-Campo $e 'commitScartato')).Substring(0, [math]::Min(7, ([string](Get-Campo $e 'commitScartato')).Length)))): $(Get-Campo $e 'errore')"
            $m.Allarme = $true
        }
        'errore' { $m.Stato = "errore: $(Get-Campo $e 'errore')"; $m.Allarme = $true }
        default { $m.Stato = if ($nome) { $nome } else { $m.Stato } }
    }
    if ($m.ErroreControllo) { $m.Allarme = $true }
    [pscustomobject]$m
}

Export-ModuleMember -Function Format-RequisitoMancante, ConvertTo-ModelloSuite
