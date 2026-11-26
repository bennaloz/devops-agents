# Prova gli hook di PreToolUse senza passare da Claude Code: genera l'input JSON che
# l'harness manderebbe su stdin e confronta l'exit code (2 = bloccato, 0 = passa).
#   pwsh -NoProfile -File hooks/Test-Hooks.ps1
$ErrorActionPreference = 'Stop'
$hooks = $PSScriptRoot

# Riempie i segnaposto delle chiavi sensibili nei casi di prova (vedi i casi sui segreti).
function Fx([string]$testo) {
    $nomi = [ordered]@{ '{T}' = 'To' + 'ken'; '{LT}' = 'to' + 'ken'; '{UT}' = 'TO' + 'KEN'; '{P}' = 'Pass' + 'word'; '{LP}' = 'pass' + 'word'
        '{K}' = 'Api' + 'Key'; '{S}' = 'Client' + 'Secret' }
    foreach ($n in $nomi.Keys) { $testo = $testo.Replace($n, $nomi[$n]) }
    $testo
}

$cases = @(
    @{ Hook = 'deny-commit-outside-worktree.ps1'; Expected = 2; What = 'commit nella working copy'
       Input = @{ cwd = 'C:/develop/GIT/Acme.AI'; tool_input = @{ command = 'git commit -m x' } } }
    @{ Hook = 'deny-commit-outside-worktree.ps1'; Expected = 0; What = 'commit nel worktree'
       Input = @{ cwd = 'C:/develop/GIT/_wt/Acme.AI/slug'; tool_input = @{ command = 'git commit -m x' } } }
    @{ Hook = 'deny-commit-outside-worktree.ps1'; Expected = 0; What = 'commit con -C nel worktree'
       Input = @{ cwd = 'C:/develop/GIT'; tool_input = @{ command = 'git -C "C:/develop/GIT/_wt/Acme.AI/slug" commit -m x' } } }
    @{ Hook = 'deny-commit-outside-worktree.ps1'; Expected = 0; What = 'cd nel worktree poi commit'
       Input = @{ cwd = 'C:/develop/GIT'; tool_input = @{ command = 'cd /c/develop/GIT/_wt/Acme.AI/slug && git commit -m x' } } }
    @{ Hook = 'deny-commit-outside-worktree.ps1'; Expected = 0; What = 'git log innocuo'
       Input = @{ cwd = 'C:/develop/GIT/Acme.AI'; tool_input = @{ command = 'git log --oneline' } } }

    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'password vera in appsettings'
       Input = @{ tool_input = @{ file_path = 'C:/x/appsettings.Test.json'; content = '{ "ConnectionStrings": { "Db": "Server=a;Password=Zuppa2026!" } }' } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'secret in uno script ps1'
       Input = @{ tool_input = @{ file_path = 'C:/x/deploy.ps1'; content = '$env:Keycloak__ClientSecret = "8f3a9c21-bb10-4e77"' } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'template con segnaposto'
       Input = @{ tool_input = @{ file_path = 'C:/x/appsettings.Test.template.json'; content = '{ "Password": "{{DB_PASSWORD}}" }' } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'segnaposto changeme'
       Input = @{ tool_input = @{ file_path = 'C:/x/appsettings.json'; content = '{ "Password": "changeme" }' } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'codice .cs che nomina password'
       Input = @{ tool_input = @{ file_path = 'C:/x/Service.cs'; content = 'var password = cfg["Secret"];' } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'config senza segreti'
       Input = @{ tool_input = @{ file_path = 'C:/x/appsettings.json'; content = '{ "Serilog": { "MinimumLevel": "Information" } }' } } }

    # Commit in un repo diverso da Acme.AI, con lo strumento Bash e con PowerShell
    @{ Hook = 'deny-commit-outside-worktree.ps1'; Expected = 2; What = 'commit nella working copy di un altro repo (Bash)'
       Input = @{ tool_name = 'Bash'; cwd = 'C:/develop/GIT/DevOps.Agents'; tool_input = @{ command = 'git commit -m x' } } }
    @{ Hook = 'deny-commit-outside-worktree.ps1'; Expected = 2; What = 'commit nella working copy di un altro repo (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; cwd = 'C:/develop/GIT/Acme.Agenda'; tool_input = @{ command = 'git commit -m x' } } }
    @{ Hook = 'deny-commit-outside-worktree.ps1'; Expected = 0; What = 'commit nel worktree (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; cwd = 'C:/develop/GIT/_wt/DevOps.Agents/slug'; tool_input = @{ command = 'git commit -m x' } } }
    @{ Hook = 'deny-commit-outside-worktree.ps1'; Expected = 0; What = 'Set-Location nel worktree poi commit (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; cwd = 'C:/develop/GIT'; tool_input = @{ command = 'Set-Location C:\develop\GIT\_wt\Acme.AI\slug; git commit -m x' } } }
    @{ Hook = 'deny-commit-outside-worktree.ps1'; Expected = 2; What = 'Set-Location nella working copy poi commit (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; cwd = 'C:/develop/GIT/_wt/Acme.AI/slug'; tool_input = @{ command = 'Set-Location C:\develop\GIT\Acme.AI; git commit -m x' } } }

    # Il PAT: Bash, PowerShell e Read
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'cat del file del PAT (Bash)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'cat ~/.claude/pat.txt' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'Get-Content del file del PAT (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Get-Content $HOME\.claude\pat.txt -Raw' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'variabile del PAT (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = '$env:AZURE_DEVOPS_EXT_PAT' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'Read del file del PAT'
       Input = @{ tool_name = 'Read'; tool_input = @{ file_path = 'C:/Users/x/.claude/pat.txt' } } }
    # le credenziali di collaudo arrivano al collaudatore nell'ambiente: il file non si legge
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'Read del file delle credenziali di collaudo'
       Input = @{ tool_name = 'Read'; tool_input = @{ file_path = 'C:/Users/x/.claude/collaudo/Acme.AI.json' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'Get-Content del file delle credenziali di collaudo'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Get-Content $HOME\.claude\collaudo\Acme.AI.json' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'una chiamata che usa le credenziali dall ambiente passa'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Invoke-RestMethod -Uri $env:COLLAUDO_TOKENURL -Method Post -Body @{ username = $env:COLLAUDO_UTENTE }' } } }
    # il PAT in lettura la sessione lo usa dall'ambiente senza vederlo, come quello pieno
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'Read del file del PAT in lettura'
       Input = @{ tool_name = 'Read'; tool_input = @{ file_path = 'C:/Users/x/.claude/pat-read-only.txt' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'cat del file del PAT in lettura (Bash)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'cat ~/.claude/pat-read-only.txt' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'script che usa il PAT dall ambiente senza nominarlo'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = "pwsh -NoProfile -File azure-pipelines/scripts/orchestrator/queue-branch-builds.ps1 -BuildSourceBranch 'refs/heads/develop' -DryRun" } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'chiamata a card.ps1 (Bash)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'pwsh -NoProfile -File C:/develop/GIT/DevOps.Agents/src/card.ps1 leggi' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'chiamata a card.ps1 (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'pwsh -NoProfile -File C:/develop/GIT/DevOps.Agents/src/card.ps1 commenta "il file pat.txt non va letto"' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'card.ps1 concatenato con la lettura del PAT'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'pwsh -File C:/x/src/card.ps1 leggi; Get-Content ~/.claude/pat.txt' } } }
    # card.ps1 vuole i testi lunghi su stdin: il testo puo nominare il PAT (card 10, 17/11/2026: i criteri dicevano
    # da quale variabile lo script di provisioning legge il PAT, e la sessione di responsabile e finita in on-hold)
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'responsabile' }; What = 'testo su stdin a card.ps1 (here-string PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = "@'`n1. Il PAT si legge da AZURE_DEVOPS_EXT_PAT.`n'@ | pwsh -NoProfile -File C:/x/src/card.ps1 criteri" } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'testo su stdin a card.ps1 (heredoc Bash)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = "pwsh -NoProfile -File C:/x/src/card.ps1 commenta <<'EOF'`nil file pat.txt non va letto`nEOF" } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'here-string a card.ps1 seguito da altro comando'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = "@'`nAZURE_DEVOPS_EXT_PAT`n'@ | pwsh -File C:/x/src/card.ps1 commenta; Get-Content ~/.claude/pat.txt" } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'here-string con il PAT verso un altro comando'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = "@'`nAZURE_DEVOPS_EXT_PAT`n'@ | Set-Content x.txt" } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'here-string doppio (espande la variabile del PAT)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = "@`"`n`$env:AZURE_DEVOPS_EXT_PAT`n`"@ | pwsh -File C:/x/src/card.ps1 commenta" } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'heredoc Bash non quotato (espande la variabile del PAT)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = "pwsh -File C:/x/src/card.ps1 commenta <<EOF`n`$AZURE_DEVOPS_EXT_PAT`nEOF" } } }
    # Il login di az: la sessione non prende un token ne arriva alla cache dei token
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'az account get-access-token (Bash)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'az account get-access-token in maiuscolo (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'az account Get-Access-Token -o json' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'cambio di AZURE_CONFIG_DIR (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = '$env:AZURE_CONFIG_DIR = "$HOME\.azure"; az account show' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'AZURE_CONFIG_DIR davanti a un comando (Bash)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'AZURE_CONFIG_DIR=~/.azure az repos pr list' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'lettura della cache dei token in .azure (Bash)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'cat ~/.azure/msal_token_cache.json' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'Get-ChildItem della cartella .azure (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Get-ChildItem $HOME\.azure' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'Read della cache dei token in .azure'
       Input = @{ tool_name = 'Read'; tool_input = @{ file_path = 'C:/Users/x/.azure/msal_token_cache.json' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'az login (Bash)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'az login --use-device-code' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'AZ LOGIN in maiuscolo (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'AZ  Login' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = '' }; What = 'az login fuori da un ruolo'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'az login' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'msal_token_cache senza la cartella .azure (Bash)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'find / -name msal_token_cache.json' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'Read di pat-smistatore.txt'
       Input = @{ tool_name = 'Read'; tool_input = @{ file_path = 'C:/Users/x/.claude/pat-smistatore.txt' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'cat di pat-smistatore-lettura.txt (Bash)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'cat ~/.claude/pat-smistatore-lettura.txt' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'un file path.txt non e un file del PAT'
       Input = @{ tool_name = 'Read'; tool_input = @{ file_path = 'C:/x/path.txt' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'card.ps1 concatenato con get-access-token'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'pwsh -File C:/x/src/card.ps1 leggi; az account get-access-token' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'chiamata a card.ps1 il cui testo nomina get-access-token'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'pwsh -NoProfile -File C:/x/src/card.ps1 commenta "il login usa az account get-access-token"' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'az repos senza toccare il login (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'az repos pr list --status active' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'un percorso azure-pipelines non e la cartella .azure'
       Input = @{ tool_name = 'Read'; tool_input = @{ file_path = 'C:/develop/GIT/Acme.AI/azure-pipelines/build-paths.json' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = '' }; What = 'get-access-token fuori da un ruolo'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'az account get-access-token' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; What = 'comando innocuo (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'git status' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; What = 'Read di un file qualunque'
       Input = @{ tool_name = 'Read'; tool_input = @{ file_path = 'C:/x/README.md' } } }
    # Fuori da una sessione di ruolo il PAT si carica nello stesso comando di az: e' l'uso normale e deve passare
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = '' }; What = 'az con il PAT fuori da un ruolo (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = '$env:AZURE_DEVOPS_EXT_PAT = (Get-Content $HOME\.claude\pat.txt -Raw).Trim(); az repos pr list' } } }
    @{ Hook = 'deny-pat.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = '' }; What = 'Read del file del PAT fuori da un ruolo'
       Input = @{ tool_name = 'Read'; tool_input = @{ file_path = 'C:/Users/x/.claude/pat.txt' } } }
    # L'identita: attivo solo dentro una sessione di ruolo (ATTREZZI_RUOLO nell'ambiente dell'hook)
    @{ Hook = 'deny-identita.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'cambio di ATTREZZI_CARD (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = '$env:ATTREZZI_CARD = 456; pwsh -File C:/x/src/card.ps1 leggi' } } }
    @{ Hook = 'deny-identita.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'cambio di ATTREZZI_TASK (PowerShell): il task e quello della sessione'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = '$env:ATTREZZI_TASK = 63; pwsh -File C:/x/src/card.ps1 chiudi-task' } } }
    @{ Hook = 'deny-identita.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'chiudi-task e crea-task da una sessione di ruolo'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'pwsh -NoProfile -File C:/develop/GIT/DevOps.Agents/src/card.ps1 chiudi-task' } } }
    @{ Hook = 'deny-identita.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'cambio di ATTREZZI_RUOLO (Bash)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'ATTREZZI_RUOLO=responsabile pwsh -File C:/x/src/card.ps1 sposta pronto' } } }
    @{ Hook = 'deny-identita.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'SetEnvironmentVariable (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = '[Environment]::SetEnvironmentVariable("ATTREZZI_" + "CARD", "5")' } } }
    @{ Hook = 'deny-identita.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'Import-Module di un modulo sotto src (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Import-Module C:/develop/GIT/DevOps.Agents/src/Ado.psm1; Set-AdoCard -Id 5 -Stato "Human test"' } } }
    @{ Hook = 'deny-identita.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'dot-source di un modulo sotto src (PowerShell)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = '. C:\develop\GIT\DevOps.Agents\src\Card.psm1' } } }
    @{ Hook = 'deny-identita.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'chiamata a card.ps1 da una sessione di ruolo'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'pwsh -NoProfile -File C:/develop/GIT/DevOps.Agents/src/card.ps1 leggi' } } }
    @{ Hook = 'deny-identita.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'git status da una sessione di ruolo'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'git status' } } }
    @{ Hook = 'deny-identita.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = '' }; What = 'fuori da un ruolo non fa niente (Import-Module)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Import-Module C:/develop/GIT/DevOps.Agents/src/Ado.psm1' } } }
    @{ Hook = 'deny-identita.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = '' }; What = 'fuori da un ruolo non fa niente (ATTREZZI_CARD)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'ATTREZZI_CARD=5 echo ok' } } }

    # Segreti: un nome con la parola token seguito da codice non e un segreto, un valore scritto nel file si.
    # Le chiavi sono scritte come segnaposto ({T}, {P}, ...) e riempite da Fx: cosi questo file non contiene a sua
    # volta niente che sembri un segreto (l'hook sulle scritture lo leggerebbe).
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'falso positivo: assegnazione da Get-Content (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Lettura.ps1'; content = (Fx '${T} = Get-Content -LiteralPath $percorso -Raw') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'falso positivo: campo di un oggetto da una somma (psm1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Conti.psm1'; content = (Fx '[pscustomobject]@{ Total{T}s = $totale.Somma }') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'falso positivo: assegnazione da un campo (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Registro.ps1'; content = (Fx '${LT}In = $Esito.{T}In') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'falso positivo: campo = cmdlet (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Auth.ps1'; content = (Fx '$h = @{ {T} = Get-{T}Corrente }') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'falso positivo: campo = cast e variabile (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Conti.ps1'; content = (Fx '{T}Out = [int64]$x.Uscita') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'falso positivo: valore = (espressione) (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Auth.ps1'; content = (Fx '${LT} = (Get-Content $f).Trim()') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'falso positivo: valore = chiamata di metodo (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Auth.ps1'; content = (Fx '${LT} = Get{T}Corrente($utente)') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'falso positivo: valore letto da variabile in uno script sh'
       Input = @{ tool_input = @{ file_path = 'C:/x/deploy.sh'; content = (Fx '{LT}=$ALTRA_VARIABILE') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'falso positivo: Edit con new_string che legge un file (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Auth.ps1'; old_string = 'x'; new_string = (Fx '    ${T} = Get-Content ~/.claude/file.txt -Raw') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: valore tra apici singoli (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Auth.ps1'; content = (Fx '${T} = ''ghp_a1b2c3d4e5f6g7''') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: valore tra virgolette (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Auth.ps1'; content = (Fx '${T} = "ghp_a1b2c3d4e5f6g7"') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: un valore tra apici che sembra un comando (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Auth.ps1'; content = (Fx '${T} = "Get-Content"') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: chiave in una hashtable (psm1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Conf.psm1'; content = (Fx '@{ {K} = ''abcdef123456'' }') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: password dentro una stringa di connessione (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Db.ps1'; content = (Fx '$conn = "Server=a;Database=b;{P}=Zuppa2026!"') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: valore senza apici dentro un here-string (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Scrivi.ps1'; content = (Fx "@'`nUser=x`n{P}=Zuppa2026!`n'@ | Set-Content c.ini") } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: export in uno script sh'
       Input = @{ tool_input = @{ file_path = 'C:/x/deploy.sh'; content = (Fx 'export API_{UT}=abcdef123456') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: valore in un file yaml'
       Input = @{ tool_input = @{ file_path = 'C:/x/pipeline.yml'; content = (Fx '{LT}: ghp_abcdef123456') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: valore in un file json'
       Input = @{ tool_input = @{ file_path = 'C:/x/appsettings.json'; content = (Fx '{ "{LT}": "abcdef123456" }') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: password in un file ini'
       Input = @{ tool_input = @{ file_path = 'C:/x/conn.ini'; content = (Fx '{LP}=Zuppa2026!') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: password json che comincia con il dollaro'
       Input = @{ tool_input = @{ file_path = 'C:/x/appsettings.json'; content = (Fx '{ "{P}": "$uperSegreta99" }') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: nel new_string di un Edit (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Auth.ps1'; old_string = 'x'; new_string = (Fx '$env:Keycloak__{S} = "8f3a9c21-bb10-4e77"') } } }
    # Un indirizzo non e un segreto: una chiave come tokenUrl o tokenEndpoint dice dove chiederlo, non lo contiene.
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 0; What = 'falso positivo: indirizzo in una chiave con token nel nome (json)'
       Input = @{ tool_input = @{ file_path = 'C:/x/collaudo.json'; content = (Fx '{ "{LT}Url": "https://srv-test:8443/realms/X/protocol/openid-connect/{LT}" }') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: password dentro un indirizzo (json)'
       Input = @{ tool_input = @{ file_path = 'C:/x/collaudo.json'; content = (Fx '{ "{LT}Url": "https://utente:Zuppa2026!@srv-test/{LT}" }') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: token nella query di un indirizzo (json)'
       Input = @{ tool_input = @{ file_path = 'C:/x/collaudo.json'; content = (Fx '{ "url": "https://srv-test/api?{LT}=ghp_a1b2c3d4e5f6" }') } } }
    # Forme che il vecchio hook bloccava: un valore dentro una stringa, o un letterale di ripiego, non e codice.
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: valore predefinito in ${NOME:-valore} (sh)'
       Input = @{ tool_input = @{ file_path = 'C:/x/deploy.sh'; content = (Fx 'API_{UT}=${API_{UT}:-ghp_a1b2c3d4e5f6g7h8}') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: password che comincia con il dollaro in una stringa di connessione tra apici (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Db.ps1'; content = (Fx '$c = ''Server=a;{P}=$uperSegreta99''') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: password a forma di chiamata di metodo in una stringa tra apici (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Db.ps1'; content = (Fx '$c = ''Server=a;{P}=Estate(2026)x''') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: password a forma di verbo-nome in una stringa tra apici (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Db.ps1'; content = (Fx '$c = ''Server=a;{P}=Open-Sesame2026''') } } }
    @{ Hook = 'deny-secrets-in-repo.ps1'; Expected = 2; What = 'segreto vero: letterale di ripiego dopo ?? (ps1)'
       Input = @{ tool_input = @{ file_path = 'C:/x/Auth.ps1'; content = (Fx '${LT} = $env:X ?? ''ghp_a1b2c3d4e5f6g7h8''') } } }
    # Host del collaudatore: solo quelli di Test della mappa, Azure DevOps e localhost
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'host di Test della mappa con porta della mappa'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Invoke-RestMethod -Uri https://srv-app-test:5480/api/health' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'host di Test con una porta diversa (Keycloak 8443)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Invoke-RestMethod -Uri "https://srv-app-test:8443/realms/x/protocol/openid-connect/token" -Method Post' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'Azure DevOps ammesso (visualstudio.com)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'az pipelines runs list --org https://acme.visualstudio.com/' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'Azure DevOps ammesso (dev.azure.com)'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'curl -s https://dev.azure.com/acme/_apis/projects' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'localhost e 127.0.0.1 ammessi'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'curl http://localhost:5000/health && curl http://127.0.0.1:5001/x' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'host di produzione (sso)'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Invoke-RestMethod -Uri https://sso.acme.com/realms/x/protocol/openid-connect/token' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'host di produzione (formsapi) in Bash'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'curl -s "https://formsapi.acme.com/api/forms"' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'un host ammesso e uno no nello stesso comando'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'irm https://srv-app-test:5480/a; irm https://formsapi.acme.com/b' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = '-Uri con host senza schema'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Invoke-WebRequest -Uri formsapi.acme.com/api' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'curl con host senza schema'
       Input = @{ tool_name = 'Bash'; tool_input = @{ command = 'curl -sk formsapi.acme.com:443/api' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 2; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'WebFetch verso un host non ammesso'
       Input = @{ tool_name = 'WebFetch'; tool_input = @{ url = 'https://sso.acme.com/'; prompt = 'x' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'comando senza URL'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'pwsh -NoProfile -File C:/x/src/card.ps1 leggi' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'collaudatore' }; What = 'URL in variabile'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Invoke-RestMethod -Uri $env:COLLAUDO_URLLOGIN -Method Post; irm "https://$env:HOSTX/api"' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = 'dev' }; What = 'stesso host di produzione in una sessione dev'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Invoke-RestMethod -Uri https://sso.acme.com/realms/x' } } }
    @{ Hook = 'deny-host-collaudo.ps1'; Expected = 0; Env = @{ ATTREZZI_RUOLO = '' }; What = 'stesso host di produzione in una sessione interattiva'
       Input = @{ tool_name = 'PowerShell'; tool_input = @{ command = 'Invoke-RestMethod -Uri https://sso.acme.com/realms/x' } } }
)

$temp = [IO.Path]::GetTempFileName()
$failed = 0
foreach ($case in $cases) {
    # L'ambiente del processo figlio: ATTREZZI_RUOLO vale solo dove il caso lo dice (altrimenti e' tolto)
    $vecchioRuolo = $env:ATTREZZI_RUOLO
    $env:ATTREZZI_RUOLO = if ($case.ContainsKey('Env')) { $case.Env.ATTREZZI_RUOLO } else { $null }
    $case.Input | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $temp -Encoding utf8 -NoNewline
    # PowerShell non ha la redirezione '<': lo stdin si passa dalla pipeline.
    Get-Content -Path $temp -Raw | & pwsh -NoProfile -File (Join-Path $hooks $case.Hook) > $null 2> $null
    $actual = $LASTEXITCODE
    $env:ATTREZZI_RUOLO = $vecchioRuolo
    if ($actual -eq $case.Expected) {
        Write-Host ("  OK       exit {0}  {1}" -f $actual, $case.What)
    }
    else {
        Write-Host ("  DIVERSO  exit {0} (atteso {1})  {2}" -f $actual, $case.Expected, $case.What) -ForegroundColor Red
        $failed++
    }
}
Remove-Item $temp -Force

Write-Host ""
if ($failed -eq 0) { Write-Host ("{0} casi, tutti come attesi" -f $cases.Count) }
else { Write-Host ("{0} casi su {1} diversi dall'atteso" -f $failed, $cases.Count) -ForegroundColor Red }
exit $failed
