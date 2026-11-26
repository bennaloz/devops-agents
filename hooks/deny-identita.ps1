# Hook PreToolUse su Bash e PowerShell, attivo solo dentro una sessione di ruolo: rifiuta un comando che assegna
# o toglie le variabili ATTREZZI_*, o che carica direttamente i moduli sotto src/. In una sessione di ruolo l'unica
# strada verso la card e' card.ps1: cambiare card o ruolo, o chiamare Azure DevOps dai moduli, aggira i permessi.
# E' un presidio contro l'uso distratto, non una recinzione.
#
# L'hook gira nel processo di Claude Code, che eredita dallo smistatore ATTREZZI_RUOLO; il comando del modello
# non lo tocca. Senza ATTREZZI_RUOLO nell'ambiente (sessioni normali) l'hook non fa niente.
# Exit 2 = chiamata bloccata, lo stderr torna al modello. Exit 0 = passa.
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:ATTREZZI_RUOLO)) { exit 0 }

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
}
catch {
    [Console]::Error.WriteLine("hook: input non interpretabile, controllo saltato - $_")
    exit 0
}

$command = [string] $payload.tool_input.command
if ([string]::IsNullOrWhiteSpace($command)) { exit 0 }

$nominaVariabili = $command -match '(?i)ATTREZZI_'
# Caricare un modulo (Import-Module, ipmo, using module, dot-source) con un percorso sotto src/ o un .psm1.
$caricaModulo = $command -match '(?i)(\bimport-module\b|\bipmo\b|\busing\s+module\b|(?:^|[;&|(]\s*)\.\s+\S)' -and
    $command -match '(?i)\.psm1\b|[/\\]src[/\\]'

if (-not ($nominaVariabili -or $caricaModulo)) { exit 0 }

[Console]::Error.WriteLine(@"
Bloccato: in questa sessione la card si legge e si scrive solo con card.ps1.

Non si cambiano le variabili d'ambiente della sessione e non si caricano a mano i moduli di src/.
Se card.ps1 ti nega un gesto, il gesto non e' tuo: scrivilo in un commento e chiudi con l'ESITO previsto.
"@)
exit 2
