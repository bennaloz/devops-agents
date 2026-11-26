#requires -Version 7
# La pagina dell'ufficio (ufficio.html, scritta dalla vista con -Html e servita con lei): un videogioco su canvas, tutto in un file.
# Compone il HTML dai file del gioco in src/ufficio/ (font, mondo, personaggi, scena, cervello, entita, interfaccia, ciclo) e incorpora
# il dato (il modello di VistaUfficio.psm1, Get-ModelloUfficio) come JSON. Nessuna risorsa esterna: la pagina porta una Content-Security-Policy
# che le impedisce di parlare con altri indirizzi che non siano il proprio server, perche i titoli delle card non devono uscire.
# Sola lettura: la pagina non scrive su Azure DevOps, non lancia sessioni, non sposta card. Il dato lo rilegge da sola (ufficio.json).
Set-StrictMode -Version Latest

# L'ordine conta: ogni file usa quelli prima (stesso oggetto U). Il nome del file dice cosa contiene, e ognuno ha una sola ragione per cambiare.
$script:FileGioco = 'font.js', 'mondo.js', 'persone.js', 'scena.js', 'cervello.js', 'entita.js', 'openspace.js', 'interfaccia.js', 'principale.js'

function Get-CartellaGioco { Join-Path $PSScriptRoot 'ufficio' }

# Il dato per la pagina: JSON compatto, senza mai un "<" (un titolo con </script> non puo chiudere il blocco in cui sta).
function ConvertTo-JsonUfficio($Dato) {
    # il segno di escape JSON per "<" e una barra rovescia, una u e 003c: scritto in due pezzi per non farlo leggere a nessun altro strumento
    ($Dato | ConvertTo-Json -Depth 10 -Compress).Replace('<', ('\' + 'u003c'))
}

function Read-FileGioco([string]$Nome) { [IO.File]::ReadAllText((Join-Path (Get-CartellaGioco) $Nome), [Text.UTF8Encoding]::new($false)) }

# La pagina per un modello vero (Get-ModelloUfficio) oppure, per la pagina d'esempio, per un oggetto con esempio = true e scenari = elenco
# di { nome, modello, fermoDaMinuti } fra cui la pagina fa scegliere.
function New-PaginaUfficio {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)]$Modello)
    $script = (($script:FileGioco | ForEach-Object { Read-FileGioco $_ }) -join "`n")
    $dato = ConvertTo-JsonUfficio $Modello
    # prima lo script e poi il dato: un titolo che contiene il segnaposto non puo finire nel codice
    (Read-FileGioco 'ufficio.html').Replace('@@SCRIPT@@', $script).Replace('@@DATI@@', $dato)
}

Export-ModuleMember -Function ConvertTo-JsonUfficio, New-PaginaUfficio, Get-CartellaGioco
