BeforeAll {
    $script:Hook = Join-Path $PSScriptRoot '../hooks/deny-commit-outside-worktree.ps1'
    $script:Fuori = 'C:\develop\GIT\DevOps.Agents'
    $script:Dentro = 'C:\develop\GIT\_wt\DevOps.Agents\prova'
    # Lancia l'hook come lo lancia Claude Code: il payload in JSON su stdin; ritorna il codice d'uscita (2 = bloccato).
    function Invoke-Hook([string]$Comando, [string]$Cwd = $script:Fuori) {
        $json = @{ tool_name = 'PowerShell'; cwd = $Cwd; tool_input = @{ command = $Comando } } | ConvertTo-Json -Compress
        $json | & pwsh -NoProfile -File $script:Hook 2>$null | Out-Null
        $LASTEXITCODE
    }
}

Describe 'deny-commit-outside-worktree: blocca solo un vero git commit fuori da un worktree' {
    It 'un git commit nella working copy principale e bloccato' {
        Invoke-Hook 'git commit -m "x"' | Should -Be 2
        Invoke-Hook 'git add -A; git commit -F msg.txt' | Should -Be 2
        Invoke-Hook 'git -C C:\develop\GIT\DevOps.Agents commit -m x' $script:Dentro | Should -Be 2
        Invoke-Hook 'git -c user.name=x commit -m x' | Should -Be 2
    }

    It 'un git commit in un worktree sotto _wt passa' {
        Invoke-Hook 'git commit -m "x"' $script:Dentro | Should -Be 0
        Invoke-Hook "cd $($script:Dentro) && git commit -m x" | Should -Be 0
        Invoke-Hook "git -C $($script:Dentro) commit -m x" | Should -Be 0
    }

    It 'le parole git e commit dentro un testo non sono un commit (i criteri di una card passati con una here-string)' {
        $testo = "@'`nRecinto: si tocca azure-pipelines/. Ogni modifica va in un commit sul ramo della card; git non si usa a mano.`n'@ | pwsh -NoProfile -File src/card.ps1 criteri 38"
        Invoke-Hook $testo | Should -Be 0
        Invoke-Hook 'Write-Output "dopo il git push si fa il commit"' | Should -Be 0
    }

    It 'commit-tree e --dry-run non contano; un comando senza git passa' {
        Invoke-Hook 'git commit-tree abc -m x' | Should -Be 0
        Invoke-Hook 'git commit --dry-run' | Should -Be 0
        Invoke-Hook 'Get-ChildItem' | Should -Be 0
    }
}
