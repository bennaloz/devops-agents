# Cosa deve fare una persona davanti a un on-hold (D57): il gesto, perche serve, perche non l'hanno fatto gli agenti e cosa
# succede togliendo l'on-hold. Funzioni pure: le usano lo smistatore (il commento di on-hold), il supervisore (la voce su
# Telegram) e la vista (la riga della card e le card che la aspettano). Il gesto lo scrive il ruolo che ha visto la causa,
# di solito il responsabile, con le righe "Per Titolare:", "Perche:" e "Perche non gli agenti:" in testa al suo testo;
# quando mancano vale il testo predefinito, per inAttesaPer e causa.

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global

# Le tre righe del ruolo, cercate a inizio riga con o senza elenco, citazione o grassetto, e con o senza accento.
$script:Etichette = [ordered]@{
    Gesto           = 'Per Titolare'
    PercheNonAgenti = 'Perch(?:e|é|è) non gli agenti'
    Perche          = 'Perch(?:e|é|è)'
}

# Le righe del ruolo in un testo: @{ Gesto; Perche; PercheNonAgenti; Fonte = 'agente' } oppure $null senza la riga "Per Titolare:".
# Vale la prima occorrenza di ogni riga; il markdown intorno all'etichetta e al testo si toglie.
function Get-IndicazioniPersona([string]$Testo) {
    if ([string]::IsNullOrWhiteSpace($Testo)) { return $null }
    $trovate = @{}
    foreach ($riga in ($Testo -split '\r?\n')) {
        foreach ($k in $script:Etichette.Keys) {
            if ($trovate.ContainsKey($k)) { continue }
            $m = [regex]::Match($riga, "^\s*(?:[-*+>]\s*|\d+[.)]\s*)*[*_]*(?:$($script:Etichette[$k]))[*_]*\s*:[*_]*\s*(.+?)\s*$", 'IgnoreCase')
            if ($m.Success) { $trovate[$k] = ($m.Groups[1].Value -replace '\*\*|__', '').Trim(); break }
        }
    }
    if (-not $trovate['Gesto']) { return $null }
    [ordered]@{ Gesto = $trovate['Gesto']; Perche = $trovate['Perche']; PercheNonAgenti = $trovate['PercheNonAgenti']; Fonte = 'agente' }
}

# Il testo predefinito quando il ruolo non ha scritto le sue righe. Motivo: quello dell'on-hold; Per: inAttesaPer; Causa:
# causaAttesa di Close-Sessione (silenzio, morta, fallita, scritture) o vuota.
function Get-IndicazioniPredefinite([string]$Motivo, $Per, [string]$Causa) {
    $g, $p, $n = switch ($true) {
        ($Causa -eq 'scritture') {
            "guarda il worktree della card: rimettilo com'era o tieni cio che serve"
            'un ruolo in sola lettura ha cambiato il worktree (D39)'
            'lo smistatore non decide quali modifiche tenere: una scrittura non prevista la valuta una persona'
            break
        }
        ($Causa -eq 'fallita') {
            'leggi nel registro delle sessioni perche la sessione e fallita (un errore o comandi negati dai permessi) e togli la causa'
            'la sessione e fallita: un nuovo tentativo uguale fallirebbe di nuovo'
            'lo smistatore non riprova una sessione fallita e il supervisore non riavvia le sessioni delle card (D51)'
            break
        }
        ($Causa -in 'silenzio', 'morta') {
            "leggi l'ultimo commento e il registro delle sessioni della card e capisci perche la sessione si ferma"
            'la sessione si e fermata per la seconda volta'
            'lo smistatore riprende da solo una sessione ferma una volta sola (D51): la seconda volta serve qualcuno che capisca perche'
            break
        }
        ($Per -eq 'limite' -and $Motivo -match 'rilanciare la validazione') {
            'apri il log della build della PR e guarda il test che fallisce: se e instabile rilancia la validazione, se e un errore vero scrivi sulla card cosa correggere'
            'dev ha chiesto per la seconda volta di rilanciare la validazione (D38)'
            'dev non puo rilanciare una build, lo smistatore la rilancia una volta sola (D38) e il supervisore non rilancia le validazioni delle PR delle card (D51)'
            break
        }
        ($Per -eq 'limite') {
            'leggi gli ultimi commenti della card e togli la causa, oppure scrivi sulla card come proseguire'
            $Motivo
            'gli agenti hanno gia riprovato fino al limite di config/limiti.json e il responsabile non ha trovato una correzione (D42)'
            break
        }
        ($Per -eq 'deploy') {
            'apri il run del deploy in Test (il link e nei commenti della card) e togli la causa'
            'il deploy in Test e fallito'
            'il responsabile non puo rilanciare un deploy e il supervisore non tocca i deploy (D51)'
            break
        }
        default {
            'leggi gli ultimi commenti della card e togli la causa'
            $Motivo
            'nessun agente ha il permesso o il dato per farlo, e il supervisore da solo riavvia solo la vista e i run falliti per infrastruttura (D51)'
        }
    }
    [ordered]@{ Gesto = $g; Perche = $p; PercheNonAgenti = $n; Fonte = 'predefinita' }
}

# Le righe del ruolo, completate con il testo predefinito dove mancano; senza le righe del ruolo, il predefinito.
function Get-IndicazioniAttesa([string]$Testo, [string]$Motivo, $Per, [string]$Causa) {
    $base = Get-IndicazioniPredefinite $Motivo $Per $Causa
    # le righe di una sessione non valgono per un on-hold di Close-Sessione: lo ha deciso lo smistatore, non il ruolo
    $agente = if ($Causa) { $null } else { Get-IndicazioniPersona $Testo }
    if ($null -eq $agente) { return $base }
    foreach ($k in 'Perche', 'PercheNonAgenti') { if (-not $agente[$k]) { $agente[$k] = $base[$k] } }
    $agente
}

# Cosa succede togliendo l'on-hold, per inAttesaPer. Con 'sessione' non si nomina il ruolo: dopo una passata D42 riparte
# chi lavorava prima del responsabile, e lo stato al momento dell'on-hold non sempre lo dice.
function Get-EffettoTogliAttesa($Per) {
    switch ($Per) {
        'sessione' { "riparte l'agente che si era fermato, e trova il tuo intervento" }
        'limite' { 'i contatori ripartono da zero e lo smistatore riprende la card dallo stato in cui e' }
        'deploy' { 'lo smistatore dimentica il run fallito e riaccoda il deploy in Test' }
        default { 'lo smistatore riprende la card dallo stato in cui e, al prossimo giro' }
    }
}

$script:AvvisoBozza = 'Non riportarla in Draft o in New: lo smistatore la tratterebbe come una card nuova e perderebbe la PR e il ramo.'

# La sezione "Cosa fare" in righe: i due passi in ordine, perche, perche non gli agenti, l'avviso. La usano vista e supervisore.
function Get-RigheCosaFare($Indicazioni, $Per) {
    if ($null -eq $Indicazioni) { return @() }
    @(
        "1. $(Get-Campo $Indicazioni 'Gesto')"
        "2. Togli l'on-hold: $(Get-EffettoTogliAttesa $Per)."
        $(if (Get-Campo $Indicazioni 'Perche') { "Perche: $(Get-Campo $Indicazioni 'Perche')" })
        $(if (Get-Campo $Indicazioni 'PercheNonAgenti') { "Perche non l'hanno fatto gli agenti: $(Get-Campo $Indicazioni 'PercheNonAgenti')" })
        $script:AvvisoBozza
    ) | Where-Object { $_ }
}

# La stessa sezione in Markdown, per il commento di on-hold sulla card: un paragrafo per riga (gli a capo singoli si perdono).
function Format-CosaFare($Indicazioni, $Per) {
    $righe = @(Get-RigheCosaFare $Indicazioni $Per)
    if ($righe.Count -eq 0) { return '' }
    "**Cosa fare**`n`n" + ($righe -join "`n`n")
}

# La sessione finita per ultima sulla card, fra quelle di ultimaSessione: @{ Ruolo; Sessione } o $null. La sessione senza fine
# conta dal suo inizio.
function Get-UltimaSessioneCard($Sc) {
    $us = Get-Campo $Sc 'ultimaSessione'
    if ($null -eq $us) { return $null }
    $ruoli = if ($us -is [System.Collections.IDictionary]) { @($us.Keys) } else { @($us.PSObject.Properties | ForEach-Object { $_.Name }) }
    $ultima = $null; $quandoUltima = $null; $ultimo = $null
    foreach ($ruolo in $ruoli) {
        $s = Get-Campo $us $ruolo
        $quando = ConvertTo-DataUtc (Get-Campo $s 'fine')
        if ($null -eq $quando) { $quando = ConvertTo-DataUtc (Get-Campo $s 'inizio') }
        if ($null -ne $quando -and ($null -eq $quandoUltima -or $quando -gt $quandoUltima)) { $ultima = $s; $quandoUltima = $quando; $ultimo = $ruolo }
    }
    if ($null -eq $ultima) { return $null }
    @{ Ruolo = $ultimo; Sessione = $ultima }
}

# Il gesto per una predecessora in on-hold, visto dalla card che la aspetta (la vista lo mette sotto "Aspetta la card #86"):
# "e in on-hold: <gesto>, poi togli l'on-hold". Senza indicazioni (on-hold di prima di D57) rimanda al commento.
function Format-GestoPredecessoreInAttesa($Indicazioni) {
    $g = [string](Get-Campo $Indicazioni 'Gesto')
    if ($g) { "e in on-hold: $($g.TrimEnd('.')), poi togli l'on-hold" } else { "e in on-hold: leggi il commento dello smistatore sulla card" }
}

Export-ModuleMember -Function Get-IndicazioniPersona, Get-IndicazioniPredefinite, Get-IndicazioniAttesa, Get-EffettoTogliAttesa, Get-RigheCosaFare, Format-CosaFare, Get-UltimaSessioneCard, Format-GestoPredecessoreInAttesa
