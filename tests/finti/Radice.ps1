# Una radice di prova: config/ e ruoli/ del repo copiati in una cartella nuova, con i limiti indicati al posto di quelli
# di config/limiti.json. Serve ai test che dipendono da un limite: il valore lo dichiara il test, non il file reale, che
# cambia (sessioniAttive e passato da 1 a 3 il 18/11/2026 e quattro test si sono rotti).
#   . (Join-Path $PSScriptRoot 'finti/Radice.ps1')
#   $radice = New-RadiceDiProva -Cartella $TestDrive -Limiti @{ sessioniAttive = 1 }
function New-RadiceDiProva {
    param([Parameter(Mandatory)][string]$Cartella, [hashtable]$Limiti = @{})
    $repo = Split-Path -Parent $PSScriptRoot | Split-Path -Parent
    $radice = Join-Path $Cartella ([guid]::NewGuid().ToString('N'))
    Copy-Item (Join-Path $repo 'config') (Join-Path $radice 'config') -Recurse
    Copy-Item (Join-Path $repo 'ruoli') (Join-Path $radice 'ruoli') -Recurse
    $file = Join-Path $radice 'config/limiti.json'
    $l = Get-Content $file -Raw | ConvertFrom-Json
    foreach ($k in $Limiti.Keys) { $l.$k = $Limiti[$k] }
    $l | ConvertTo-Json | Set-Content $file
    $radice
}
