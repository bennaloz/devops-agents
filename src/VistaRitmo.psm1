#requires -Version 7
# Il ritmo delle letture lente della vista. Funzioni pure: Vista.ps1 le chiama a ogni giro.
Set-StrictMode -Version Latest

# Se in questo giro vanno lette le lezioni in prova (git piu Azure DevOps: una lettura lenta, solo per la pagina HTML).
# $Trascorsi sono i secondi dall'ultimo tentativo ($null = mai tentato), $Secondi il ritmo (-SecondiMemoria).
# Con -Segui il primo disegno non le aspetta: la sezione dice "lettura in corso" e la lettura parte subito dopo il disegno, non
# prima. Senza -Segui la pagina e una sola e deve averle.
function Test-LeggiLezioniOra([bool]$Html, [bool]$Segui, [bool]$PrimoDisegno, $Trascorsi, [int]$Secondi) {
    if (-not $Html) { return $false }
    if ($Segui -and $PrimoDisegno) { return $false }
    $null -eq $Trascorsi -or $Trascorsi -ge $Secondi
}

Export-ModuleMember -Function Test-LeggiLezioniOra
