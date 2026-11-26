#requires -Version 7
# I dati inventati per la pagina d'esempio dell'ufficio: scene che mostrano tutti i comportamenti senza bisogno di sessioni vere.
# Passano da Get-ModelloUfficio come i dati veri: se la forma del dato cambia, cambia anche l'esempio, e un test lo vede.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'VistaUfficio.psm1') -Global

function Get-EsempioUfficio {
    [CmdletBinding()]
    param([datetime]$Adesso = [datetime]::UtcNow)
    $adesso = $Adesso.ToUniversalTime()
    $ruoli = 'responsabile', 'dev', 'collaudatore', 'reviewer', 'mentore'
    $flusso = Get-RuoliFlusso
    $titoli = @{
        1031 = 'Allarmi sulle soglie di potenza'; 1033 = "Correggere l'arrotondamento dell'IVA"; 1040 = 'Importare le stime di costo'
        1041 = 'Filtro per periodo nei report'; 1042 = 'Pannello consumi per edificio'; 1044 = 'Export dei report in PDF'; 1046 = 'Login con SSO'
        1050 = 'Migrare la tabella delle letture'; 1052 = 'Notifiche push'; 1051 = 'Scegliere il formato delle esportazioni'
        1055 = 'Anagrafica fornitori'; 1057 = 'Calcolo degli incentivi'; 1060 = 'Storico delle fatture'; 1061 = 'Pagina di benvenuto'; 1062 = 'Mappa degli impianti'
        1063 = 'Ricerca globale'; 1064 = 'Log delle modifiche'; 1036 = 'Notifiche via mail'; 1047 = 'Filtro per cliente'; 1048 = 'Esportazione CSV'
        1049 = 'Tema scuro'; 1053 = 'Ordinamento delle colonne'; 1054 = 'Ricerca per codice'; 1058 = 'Controllo dei duplicati'; 1059 = 'Stampa del riepilogo'
    }
    function Riga([int]$Id, $Ruolo, [string]$Chiave) { [pscustomobject]@{ Id = $Id; Ruolo = $Ruolo; Titolo = $titoli[$Id]; Chiave = $Chiave; UrlCard = "https://esempio.invalid/card/$Id" } }
    function Viva([int]$Id, [string]$Ruolo, [string]$Chiave, $Task, [int]$Minuti, [string]$TokenTesto) {
        [pscustomobject]@{ Id = $Id; Ruolo = $Ruolo; Titolo = $titoli[$Id]; Chiave = $Chiave; UrlCard = "https://esempio.invalid/card/$Id"; Task = $Task
            TitoloTask = $(if ($Task) { 'Scrivere i test del caricamento' } else { $null }); Minuti = $Minuti; Token = $(if ($TokenTesto) { 48200 } else { 0 }); TokenTesto = $TokenTesto }
    }
    function Voce([int]$Id, [string]$Verbo, [string]$Testo) { [pscustomobject]@{ Id = $Id; Titolo = $titoli[$Id]; UrlCard = "https://esempio.invalid/card/$Id"; Verbo = $Verbo; Testo = $Testo } }
    function Finita([string]$Ruolo, [int]$MinutiFa) { @{ ultimoRuolo = $Ruolo; ultimaSessione = @{ $Ruolo = @{ id = "sid-$Ruolo"; fine = $adesso.AddMinutes(-$MinutiFa).ToString('o') } } } }
    function Code([hashtable]$PerRuolo) { @($PerRuolo.Keys | ForEach-Object { [pscustomobject]@{ Ruolo = $_; Coda = @($PerRuolo[$_]) } }) }
    function Modello([object[]]$InCorso, [object[]]$Coda, [object[]]$Agenti, $Operatore, $Stato, $Quota, $Smistatore, [string]$Errore = '') {
        $m = Get-ModelloUfficio -Ruoli $ruoli -Flusso $flusso -InCorso $InCorso -Coda $Coda -Agenti $Agenti -Operatore $Operatore -Stato $Stato -Adesso $adesso `
            -Quota $Quota -Smistatore $Smistatore -ErroreAdo $Errore -Secondi 5
        $m.esempio = $true
        $m
    }
    $libera = @{ Blocco = $null; Uso = 0.42; Soglia = 0.9 }
    $ferma = @{ InGiro = $false; Ultimo = '2026-11-24 14:05:11'; Prossimo = '2026-11-24 14:10' }
    $inGiro = @{ InGiro = $true; Ultimo = '2026-11-24 14:05:11'; Prossimo = '2026-11-24 14:10' }
    $nessuna = [pscustomobject]@{ Fermano = @(); NonFermano = @() }

    # code e card per la bacheca, uguali in piu scene
    $codaReviewer = @((Riga 1040 'reviewer' 'inRevisione'), (Riga 1041 'reviewer' 'inRevisione'), (Riga 1044 'reviewer' 'inRevisione'), (Riga 1046 'reviewer' 'inRevisione'))
    $codaDev = @((Riga 1050 'dev' 'pronto'), (Riga 1052 'dev' 'pronto'))
    $altre = @((Riga 1060 'collaudatore' 'inCollaudo'), (Riga 1061 $null 'nuova'), (Riga 1062 $null 'nuova'), (Riga 1063 $null 'daUnire'), (Riga 1064 $null 'inDeployTest'))

    # 1: nessuna sessione: una consegna in avanti, un rimando indietro, la fila alla porta di Titolare
    $voci1 = [pscustomobject]@{ Fermano = @(Voce 1051 'Rispondi' 'serve il formato scelto') ; NonFermano = @((Voce 1055 'Prova in Test' 'tocca a te provarla'), (Voce 1057 'Rilascia' 'pronta per la produzione')) }
    $coda1 = @($codaReviewer) + @($codaDev) + @($altre) + @((Riga 1033 'responsabile' 'daChiarire'), (Riga 1051 $null 'daChiarire'), (Riga 1055 $null 'inProvaUmana'), (Riga 1057 $null 'daRilasciare'))
    $stato1 = @{ '1040' = (Finita 'dev' 4); '1033' = (Finita 'collaudatore' 3); '1051' = @{ ultimoRuolo = 'mentore' } }
    $agenti1 = Code @{ reviewer = $codaReviewer; dev = $codaDev; responsabile = @(Riga 1033 'responsabile' 'daChiarire'); collaudatore = @(Riga 1060 'collaudatore' 'inCollaudo') }
    $s1 = Modello @() $coda1 $agenti1 $voci1 $stato1 $libera $ferma

    # 2: due sessioni al lavoro e tre agenti fermi; lo smistatore sta facendo il giro
    # piu sessioni dello stesso ruolo: la prima siede alla scrivania del ruolo, le altre al tavolo dei portatili
    $viva = @((Viva 1042 'dev' 'inSviluppo' 7 14 '48.2k token'), (Viva 1047 'dev' 'inSviluppo' $null 6 $null), (Viva 1048 'dev' 'inSviluppo' $null 2 $null),
        (Viva 1031 'collaudatore' 'inCollaudo' $null 3 $null), (Viva 1036 'collaudatore' 'inCollaudo' $null 9 $null))
    $coda2 = @($codaReviewer) + @($codaDev) + @($altre | Where-Object Id -ne 1060)
    $s2 = Modello $viva $coda2 (Code @{ reviewer = $codaReviewer; dev = $codaDev }) $nessuna @{} $libera $inGiro

    # 2b: tante sessioni: il tavolo dei portatili si riempie e chi non trova posto lavora nell'open space, oltre la porta
    # (ruoli mescolati: al tavolo dev e reviewer, nell'open space reviewer e collaudatore; i posti vanno nell'ordine del flusso e per card)
    $tante = @($viva) + @((Viva 1049 'dev' 'inSviluppo' $null 1 $null), (Viva 1054 'reviewer' 'inRevisione' $null 5 $null),
        (Viva 1058 'reviewer' 'inRevisione' $null 8 $null), (Viva 1059 'reviewer' 'inRevisione' $null 3 $null))
    $s2b = Modello $tante $coda2 (Code @{ reviewer = $codaReviewer; dev = $codaDev }) $nessuna @{} $libera $inGiro

    # 3: la riserva settimanale e oltre la soglia: lo smistatore dorme, a tutta scena
    $blocco = @{ Tipo = 'quota'; Causa = 'riserva'; Fino = $adesso.AddDays(2).ToString('o'); Uso = 0.93; Soglia = 0.9 }
    $s3 = Modello @() ($codaReviewer + $codaDev + $altre) (Code @{ reviewer = $codaReviewer; dev = $codaDev; collaudatore = @(Riga 1060 'collaudatore' 'inCollaudo') }) $nessuna @{} @{ Blocco = $blocco; Uso = 0.93; Soglia = 0.9 } $ferma

    # 4: Azure DevOps non risponde: restano le sessioni in corso
    $s4 = Modello @(Viva 1042 'dev' 'inSviluppo' $null 22 '12.0k token') @() @() $nessuna @{} $libera $ferma 'timeout dopo 30 secondi'

    @{
        esempio = $true
        scenari = @(
            @{ nome = 'Consegna, rimando e fila alla porta (nessuna sessione)'; modello = $s1; fermoDaMinuti = 0 }
            @{ nome = 'Giornata di lavoro con lo smistatore in giro'; modello = $s2; fermoDaMinuti = 0 }
            @{ nome = 'Tante sessioni: tavolo dei portatili pieno e open space'; modello = $s2b; fermoDaMinuti = 0 }
            @{ nome = 'Pausa: riserva settimanale oltre la soglia'; modello = $s3; fermoDaMinuti = 0 }
            @{ nome = 'Azure DevOps non risponde'; modello = $s4; fermoDaMinuti = 0 }
            @{ nome = 'Dati fermi da 7 minuti (simulato)'; modello = $s2; fermoDaMinuti = 7 }
        )
    }
}

Export-ModuleMember -Function Get-EsempioUfficio
