# Un finto "docker" per i test di Collaudo.psm1: stampa gli argomenti, e a richiesta l'ambiente; esce con un codice o dorme.
if ($args -contains 'fallisci') { Write-Output 'fallito'; exit 3 }
if ($args -contains 'dormi') { Start-Sleep -Seconds 30; exit 0 }
Write-Output ('argomenti: ' + ($args -join ' '))
if ($args -contains 'stampa-env') {
    Write-Output ('WSLENV=' + $env:WSLENV)
    Write-Output ('COLLAUDO_HOST=' + $env:COLLAUDO_HOST)
}
exit 0
