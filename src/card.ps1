#requires -Version 7
# Riga di comando per gli agenti. L'id della card e il ruolo non sono argomenti: li imposta lo smistatore
# nelle variabili d'ambiente ATTREZZI_CARD e ATTREZZI_RUOLO, cosi una sessione non puo scrivere su un'altra card.
#   card.ps1 leggi | sposta <chiave dello stato>   (leggi mostra anche i tag e, per una card di una funzionalita D52, la Feature e le sorelle)
#   <testo su stdin> | card.ps1 commenta        (il testo di commenta e criteri arriva SOLO da stdin: come argomento
#   <testo su stdin> | card.ps1 criteri         l'interprete dei comandi lo altererebbe: $, backtick, trattino iniziale)
#   <task su stdin> | card.ps1 crea-task      (solo responsabile: righe '=== <titolo>' e sotto il testo del task, in ordine)
#   <titolo su stdin> | card.ps1 titolo-pr     (dev e responsabile: rinomina la PR della card e ne rilancia la validazione)
#   <testo su stdin> | card.ps1 deploy         (solo responsabile: i parametri deploy* del deploy in Test sulla prima riga,
#                                              il perche sotto; finiscono in un commento sulla card, vale l'ultimo)
#   <testo su stdin> | card.ps1 correzione    (solo responsabile, solo sulla card di chiusura di una funzionalita D52: la prima riga e la
#                                              natura, tecnico o prodotto, poi '=== <titolo>' e sotto la descrizione, come crea-task.
#                                              Scrive un commento con la marca; la Bug figlia della Feature la crea lo smistatore)
#   card.ps1 chiudi-task [<id>]                (solo dev: chiude il task di ATTREZZI_TASK, rifiuta un id diverso)
#   <motivo su stdin> | card.ps1 senza-test   (solo responsabile: niente prova in Test, tag no-test-deploy e motivo sulla card)
#   <motivo su stdin> | card.ps1 prova-umana  (solo responsabile: la prova in Human test la fa una persona, tag human-test e motivo sulla card)
#   card.ps1 crea -Tipo <User Story|Bug|Feature> -Titolo <testo> -Area <area> -File <markdown> [-Dopo <id>[,<id>...]]   (solo fuori da un ruolo)
#       -Dopo: gli id delle card che devono essere unite prima di questa (link Predecessor). La card resta ferma, in New
#       o in Ready to develop, finche tutte le precedenti non sono unite.
#       -SenzaTest: niente da provare nell'ambiente di Test; dopo la revisione la card va dritta in Ready to merge.
#       -ProvaUmana: in Human test la prova il richiedente invece del collaudatore.
#       D52 (spenta finche funzionalitaAttive in config/limiti.json e false: i due comandi sotto si rifiutano):
#       -Tipo Feature [-Bug]: crea la Feature della funzionalita e la sua card di chiusura (User Story figlia, tag
#           collaudo-funzionalita e agents, Draft, titolo "Collaudo funzionalita: <titolo>", criteri dal file). -Bug segna la
#           funzionalita come correzione (tag bug sulla Feature). Non vale con -Feature, -Dopo, -SenzaTest, -ProvaUmana.
#       -Feature <id>: crea la card come figlia della Feature. Si rifiuta se l'area e diversa da quella della Feature, se la
#           Feature e Resolved o Closed, o se non ha una card di chiusura (allora la card si crea senza -Feature).
param(
    [Parameter(Position = 0)][string]$Comando,
    [Parameter(Position = 1)][string]$Argomento,
    [string]$Tipo, [string]$Titolo, [string]$Area, [string]$File,
    # con -File la lista "11,12" arriva come una stringa sola: si spezza qui
    [string[]]$Dopo,
    [switch]$SenzaTest,
    [switch]$ProvaUmana,
    [switch]$Bug,
    [int]$Feature
)
$ErrorActionPreference = 'Stop'

# 'crea' e il solo comando che non usa ATTREZZI_CARD e ATTREZZI_RUOLO: lo lancia una sessione di design, mai un ruolo.
if ($Comando -eq 'crea') {
    try {
        Import-Module (Join-Path $PSScriptRoot 'Card.psm1')
        foreach ($p in 'Tipo', 'Titolo', 'Area', 'File') {
            if (-not $PSBoundParameters.ContainsKey($p)) { throw "manca -$p" }
        }
        $opzioni = @{}
        if ($PSBoundParameters.ContainsKey('Dopo')) { $opzioni.Dopo = [int[]]@($Dopo | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ }) }
        if ($SenzaTest) { $opzioni.SenzaTest = $true }
        if ($ProvaUmana) { $opzioni.ProvaUmana = $true }
        if ($Bug) { $opzioni.Bug = $true }
        if ($PSBoundParameters.ContainsKey('Feature')) { $opzioni.Feature = $Feature }
        $c = New-Card -Tipo $Tipo -Titolo $Titolo -Area $Area -File $File @opzioni
        if ($Tipo -eq 'Feature') { "Feature $($c.Id) creata: $(Get-AdoUrlCard -Id $c.Id). Card di chiusura $($c.Chiusura.Id): $(Get-AdoUrlCard -Id $c.Chiusura.Id)" }
        else { "Card $($c.Id) creata: $(Get-AdoUrlCard -Id $c.Id)" }
        exit 0
    }
    catch {
        [Console]::Error.WriteLine("card: $($_.Exception.Message)")
        exit 1
    }
}

$idTesto = $env:ATTREZZI_CARD
$ruolo = $env:ATTREZZI_RUOLO
if ([string]::IsNullOrWhiteSpace($idTesto) -or [string]::IsNullOrWhiteSpace($ruolo)) {
    [Console]::Error.WriteLine('card: mancano le variabili d''ambiente ATTREZZI_CARD e/o ATTREZZI_RUOLO (le imposta lo smistatore)')
    exit 1
}
$id = 0
if (-not [int]::TryParse($idTesto, [ref]$id)) {
    [Console]::Error.WriteLine("card: ATTREZZI_CARD non e un numero: '$idTesto'")
    exit 1
}

if ($Comando -in 'commenta', 'criteri', 'crea-task', 'senza-test', 'prova-umana', 'titolo-pr', 'deploy', 'correzione') {
    if ($Argomento) {
        [Console]::Error.WriteLine("card: il testo di '$Comando' non va passato come argomento: usa stdin (il testo, poi | card.ps1 $Comando)")
        exit 1
    }
}

try {
    Import-Module (Join-Path $PSScriptRoot 'Card.psm1')
    switch ($Comando) {
        'leggi' {
            $taskSessione = 0
            [void][int]::TryParse($env:ATTREZZI_TASK, [ref]$taskSessione)
            Read-Card -Id $id -TaskSessione $taskSessione
        }
        'commenta' {
            $testo = ([Console]::In.ReadToEnd()).TrimEnd("`r", "`n")
            if ([string]::IsNullOrWhiteSpace($testo)) { throw 'manca il testo del commento (va dato su stdin)' }
            [void](Add-CardCommento -Id $id -Ruolo $ruolo -Testo $testo)
            'Commento aggiunto.'
        }
        'criteri' {
            $testo = ([Console]::In.ReadToEnd()).TrimEnd("`r", "`n")
            if ([string]::IsNullOrWhiteSpace($testo)) { throw 'manca il testo dei criteri (va dato su stdin)' }
            [void](Set-CardCriteri -Id $id -Ruolo $ruolo -Testo $testo)
            'Criteri aggiornati.'
        }
        'sposta' {
            if (-not $Argomento) { throw 'manca la chiave dello stato' }
            [void](Move-Card -Id $id -Ruolo $ruolo -Stato $Argomento)
            "Card spostata in '$Argomento'."
        }
        'crea-task' {
            $testo = ([Console]::In.ReadToEnd()).TrimEnd("`r", "`n")
            if ([string]::IsNullOrWhiteSpace($testo)) { throw 'manca il testo dei task (va dato su stdin)' }
            $creati = @(New-CardTask -Id $id -Ruolo $ruolo -Testo $testo)
            "Creati $($creati.Count) task, nell'ordine: $((@($creati | ForEach-Object { "#$($_.Id)" })) -join ', ')."
        }
        'chiudi-task' { Close-CardTask -Id $id -Ruolo $ruolo -TaskSessione $env:ATTREZZI_TASK -TaskRichiesto $Argomento }
        'senza-test' {
            $testo = ([Console]::In.ReadToEnd()).TrimEnd("`r", "`n")
            [void](Set-CardSenzaTest -Id $id -Ruolo $ruolo -Motivo $testo)
            'Niente prova in Test: tag aggiunto e motivo scritto sulla card.'
        }
        'prova-umana' {
            $testo = ([Console]::In.ReadToEnd()).TrimEnd("`r", "`n")
            [void](Set-CardProvaUmana -Id $id -Ruolo $ruolo -Motivo $testo)
            'Prova di una persona richiesta: tag human-test aggiunto e motivo scritto sulla card.'
        }
        'titolo-pr' {
            $testo = ([Console]::In.ReadToEnd()).Trim()
            Set-CardTitoloPr -Id $id -Ruolo $ruolo -Titolo $testo
        }
        'deploy' {
            $testo = ([Console]::In.ReadToEnd()).TrimEnd("`r", "`n")
            Set-CardDeploy -Id $id -Ruolo $ruolo -Testo $testo
        }
        'correzione' {
            $testo = ([Console]::In.ReadToEnd()).TrimEnd("`r", "`n")
            Add-CardCorrezione -Id $id -Ruolo $ruolo -Testo $testo
        }
        default { throw "comando sconosciuto: '$Comando' (leggi | commenta | criteri | sposta | crea-task | chiudi-task | senza-test | prova-umana | titolo-pr | deploy | correzione)" }
    }
}
catch {
    [Console]::Error.WriteLine("card: $($_.Exception.Message)")
    exit 1
}
