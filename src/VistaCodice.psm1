#requires -Version 7
# Il riavvio della vista quando cambia il suo codice. Funzioni pure sulle date dei file: Vista.ps1 le chiama a ogni giro
# di -Segui. Dopo un merge e un git pull la vista altrimenti continuerebbe a disegnare con il codice caricato all'avvio.
Set-StrictMode -Version Latest

# Le date di scrittura dei file che fanno la vista: src/*.ps1, src/*.psm1 e config/*.json sotto la radice, per percorso relativo.
function Get-DateCodice([string]$Radice) {
    $d = @{}
    foreach ($sp in @(@('src', '*.ps1'), @('src', '*.psm1'), @('config', '*.json'))) {
        $cartella = Join-Path $Radice $sp[0]
        foreach ($f in @(Get-ChildItem -LiteralPath $cartella -File -Filter $sp[1] -ErrorAction SilentlyContinue)) {
            $d["$($sp[0])/$($f.Name)"] = $f.LastWriteTimeUtc
        }
    }
    $d
}

# Cosa e cambiato rispetto all'avvio, come testo stabile (stessi cambiamenti = stesso testo); $null se niente e cambiato.
function Get-CambioCodice($Base, $Attuale) {
    $diff = foreach ($k in @(@($Base.Keys) + @($Attuale.Keys) | Sort-Object -Unique)) {
        $a = if ($Base.ContainsKey($k)) { $Base[$k].Ticks } else { 'assente' }
        $b = if ($Attuale.ContainsKey($k)) { $Attuale[$k].Ticks } else { 'assente' }
        if ($a -ne $b) { "$k=$b" }
    }
    if ($diff) { @($diff) -join ';' } else { $null }
}

# Riavvia solo se lo stesso cambiamento si vede in due giri di fila: un pull a meta scrittura cambia ancora al giro dopo.
function Get-EsitoRiavvio($Base, $Attuale, $CambioPrecedente) {
    $cambio = Get-CambioCodice $Base $Attuale
    [pscustomobject]@{ Cambio = $cambio; Riavvia = ($null -ne $cambio -and $cambio -eq $CambioPrecedente) }
}

# ---- il supervisore -------------------------------------------------------------------------------------------------
# Con -Segui il processo lanciato dall'utente non disegna: lancia la vista come figlio e lo rilancia ogni volta che esce con
# il codice di riavvio. I processi restano due qualunque sia il numero di riavvii (un rilancio dal figlio li annidarebbe).

# Il codice con cui il figlio dice "il mio codice e cambiato, rilanciami". Un codice qualunque non e un riavvio.
function Get-CodiceRiavvio { 75 }

# Gli argomenti da dare al figlio: gli stessi dell'utente (switch senza valore, gli altri col valore). -Apri solo al primo
# figlio: la pagina gia aperta si aggiorna da sola e a ogni merge si aprirebbe una scheda nuova.
function Get-ArgomentiFiglio($Parametri, [bool]$Primo) {
    $a = [System.Collections.Generic.List[string]]::new()
    foreach ($k in @($Parametri.Keys | Sort-Object)) {
        if ($k -eq 'Apri' -and -not $Primo) { continue }
        $v = $Parametri[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $a.Add("-$k") } }
        else { $a.Add("-$k"); $a.Add([string]$v) }
    }
    $a.ToArray()
}

# Il ciclo: $AvviaFiglio riceve $true al primo giro e restituisce il codice di uscita del figlio (lo fa girare e aspetta).
# Ritorna il codice con cui il supervisore deve terminare.
function Invoke-SupervisoreVista([scriptblock]$AvviaFiglio) {
    $primo = $true
    while ($true) {
        $codice = [int](& $AvviaFiglio $primo)
        if ($codice -ne (Get-CodiceRiavvio)) { return $codice }
        $primo = $false
    }
}

Export-ModuleMember -Function Get-DateCodice, Get-CambioCodice, Get-EsitoRiavvio, Get-CodiceRiavvio, Get-ArgomentiFiglio, Invoke-SupervisoreVista
