BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Ado.psm1') -Force

    # Una risposta di GitHub come la restituisce Invoke-RestMethod: oggetti, non testo.
    function global:New-RispostaGh([string]$Json) { $Json | ConvertFrom-Json }
    function global:New-PrGh([int]$Numero, [string]$Stato = 'open', [string]$Sha = 'HEAD1', $Merged = $null, $Mergeable = $true, [string]$MergeableState = 'clean', [string]$Ramo = 'feature/42-x') {
        [pscustomobject]@{ number = $Numero; state = $Stato; merged_at = $Merged; title = "PR $Numero"; html_url = "https://github.com/acme/web/pull/$Numero"
            mergeable = $Mergeable; mergeable_state = $MergeableState; body = 'descrizione'
            head = [pscustomobject]@{ sha = $Sha; ref = $Ramo } }
    }
    function global:New-CheckGh([string]$Status = 'completed', [string]$Conclusion = 'success', [string]$Url = 'https://github.com/acme/web/actions/runs/77/job/1') {
        [pscustomobject]@{ status = $Status; conclusion = $Conclusion; details_url = $Url }
    }
}

Describe 'GitHub: gli esiti dei controlli' {
    It 'un check run concluso diventa verde o rosso, uno in corso inCorso' {
        Get-EsitoControlloGh (New-CheckGh 'completed' 'success') | Should -Be 'verde'
        Get-EsitoControlloGh (New-CheckGh 'completed' 'skipped') | Should -Be 'verde'
        Get-EsitoControlloGh (New-CheckGh 'completed' 'failure') | Should -Be 'rossa'
        Get-EsitoControlloGh (New-CheckGh 'completed' 'timed_out') | Should -Be 'rossa'
        Get-EsitoControlloGh (New-CheckGh 'in_progress' $null) | Should -Be 'inCorso'
        Get-EsitoControlloGh (New-CheckGh 'queued' $null) | Should -Be 'inCorso'
    }

    It 'uno status classico segue il suo state' {
        Get-EsitoControlloGh ([pscustomobject]@{ state = 'success' }) | Should -Be 'verde'
        Get-EsitoControlloGh ([pscustomobject]@{ state = 'error' }) | Should -Be 'rossa'
        Get-EsitoControlloGh ([pscustomobject]@{ state = 'pending' }) | Should -Be 'inCorso'
    }

    It "l'origine: un run di Azure Pipelines porta il buildId, uno di Actions il run" {
        $ado = Get-OrigineControlloGh (New-CheckGh -Url 'https://dev.azure.com/acme/0000/_build/results?buildId=4321&view=logs')
        $ado.BuildIdAdo | Should -Be 4321
        $ado.RunActions | Should -BeNullOrEmpty
        $gh = Get-OrigineControlloGh (New-CheckGh -Url 'https://github.com/acme/web/actions/runs/987/job/5')
        $gh.RunActions | Should -Be 987
        $gh.BuildIdAdo | Should -BeNullOrEmpty
    }

    It 'lo stato della PR con i nomi di Azure DevOps' {
        ConvertTo-StatoPrGh (New-PrGh 1 'open') | Should -Be 'active'
        ConvertTo-StatoPrGh (New-PrGh 1 'closed' -Merged '2026-11-20T10:00:00Z') | Should -Be 'completed'
        ConvertTo-StatoPrGh (New-PrGh 1 'closed') | Should -Be 'abandoned'
    }

    It 'il link di una PR sulla card si riconosce, un altro link no' {
        $l = ConvertFrom-GhUrlPr 'https://github.com/acme/web/pull/12'
        $l.RepoGh | Should -Be 'acme/web'
        $l.Id | Should -Be 12
        ConvertFrom-GhUrlPr 'https://github.com/acme/web/issues/12' | Should -BeNullOrEmpty
        ConvertFrom-GhUrlPr 'https://acme.visualstudio.com/P/_git/R/pullrequest/12' | Should -BeNullOrEmpty
    }
}

Describe 'GitHub: chiamate' {
    BeforeEach {
        Mock Get-GhIntestazione -ModuleName GitHub { @{ Authorization = 'Bearer SEGRETO-FINTO'; Accept = 'application/vnd.github+json' } }
    }

    It 'Get-GhPr: PR attiva con controlli verdi sul commit di testa' {
        Mock Invoke-RestMethod -ModuleName GitHub {
            switch -Wildcard ([string]$Uri) {
                '*/pulls?head=*' { @(New-PrGh 7) }
                '*/pulls/7' { New-PrGh 7 }
                '*/commits/HEAD1/check-runs*' { [pscustomobject]@{ check_runs = @(New-CheckGh) } }
                '*/commits/HEAD1/status' { [pscustomobject]@{ statuses = @() } }
                default { throw "chiamata inattesa $Uri" }
            }
        }
        $pr = Get-GhPr 'acme/web' 'feature/42-x' -Destinazione 'develop'
        $pr.Id | Should -Be 7
        $pr.Stato | Should -Be 'active'
        $pr.Validazione | Should -Be 'verde'
        $pr.UltimoCommit | Should -Be 'HEAD1'
        $pr.RunActions | Should -Be 77
        Should -Invoke Invoke-RestMethod -ModuleName GitHub -Times 1 -Exactly -ParameterFilter {
            $Uri -like 'https://api.github.com/repos/acme/web/pulls?head=acme%3Afeature%2F42-x&base=develop&state=open*' }
    }

    It 'Get-GhPr: un controllo in corso vince su uno rosso, uno rosso su uno verde' {
        $global:FxCheck = @((New-CheckGh 'completed' 'failure' 'https://dev.azure.com/acme/x/_build/results?buildId=55'), (New-CheckGh))
        Mock Invoke-RestMethod -ModuleName GitHub {
            switch -Wildcard ([string]$Uri) {
                '*/pulls?head=*' { @(New-PrGh 7) }
                '*/pulls/7' { New-PrGh 7 }
                '*/check-runs*' { [pscustomobject]@{ check_runs = $global:FxCheck } }
                '*/status' { [pscustomobject]@{ statuses = @() } }
            }
        }
        $rossa = Get-GhPr 'acme/web' 'feature/42-x'
        $rossa.Validazione | Should -Be 'rossa'
        $rossa.BuildId | Should -Be 55
        $global:FxCheck += New-CheckGh 'in_progress' $null
        (Get-GhPr 'acme/web' 'feature/42-x').Validazione | Should -Be 'inCorso'
    }

    It 'Get-GhPr: conflitti, e unione ancora da calcolare' {
        $global:FxPr = New-PrGh 7 -Mergeable $false -MergeableState 'dirty'
        Mock Invoke-RestMethod -ModuleName GitHub {
            switch -Wildcard ([string]$Uri) {
                '*/pulls?head=*' { @(New-PrGh 7) }
                '*/pulls/7' { $global:FxPr }
                '*/check-runs*' { [pscustomobject]@{ check_runs = @(New-CheckGh) } }
                '*/status' { [pscustomobject]@{ statuses = @() } }
            }
        }
        (Get-GhPr 'acme/web' 'feature/42-x').Validazione | Should -Be 'conflitti'
        $global:FxPr = New-PrGh 7 -Mergeable $null -MergeableState 'unknown'
        (Get-GhPr 'acme/web' 'feature/42-x').Validazione | Should -Be 'inCorso'
    }

    It 'Get-GhPr: senza PR attiva, con -AncheCompletate, la PR unita' {
        Mock Invoke-RestMethod -ModuleName GitHub { @(New-PrGh 9 'closed' 'HEAD9' '2026-11-20T10:00:00Z') }
        Get-GhPr 'acme/web' 'feature/42-x' | Should -BeNullOrEmpty
        $pr = Get-GhPr 'acme/web' 'feature/42-x' -AncheCompletate
        $pr.Id | Should -Be 9
        $pr.Stato | Should -Be 'completed'
        $pr.Validazione | Should -Be 'assente'
        $pr.UltimoCommit | Should -Be 'HEAD9'
    }

    It 'New-GhPr apre la PR verso la destinazione con AB#<card> nella descrizione' {
        Mock Invoke-RestMethod -ModuleName GitHub { [pscustomobject]@{ number = 15; html_url = 'https://github.com/acme/web/pull/15' } }
        $r = New-GhPr 'acme/web' 'feature/42-x' 'Titolo' 'Testo' 42 'develop'
        $r.Id | Should -Be 15
        $r.Url | Should -Be 'https://github.com/acme/web/pull/15'
        Should -Invoke Invoke-RestMethod -ModuleName GitHub -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -eq 'https://api.github.com/repos/acme/web/pulls' -and
            ($Body | ConvertFrom-Json).head -eq 'feature/42-x' -and ($Body | ConvertFrom-Json).base -eq 'develop' -and ($Body | ConvertFrom-Json).body -match 'AB#42$' }
    }

    It 'Complete-GhPr unisce con merge commit sul commit verificato e cancella il ramo' {
        Mock Invoke-RestMethod -ModuleName GitHub { if ($Method -eq 'Get') { New-PrGh 7 -Sha 'NUOVO' } }
        Complete-GhPr 'acme/web' 7 'VERIFICATO'
        Should -Invoke Invoke-RestMethod -ModuleName GitHub -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Put' -and $Uri -like '*/pulls/7/merge' -and ($Body | ConvertFrom-Json).sha -eq 'VERIFICATO' -and ($Body | ConvertFrom-Json).merge_method -eq 'merge' }
        Should -Invoke Invoke-RestMethod -ModuleName GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'Delete' -and $Uri -like '*/git/refs/heads/feature/42-x' }
    }

    It 'Complete-GhPr: un ramo gia cancellato da GitHub non e un errore' {
        Mock Invoke-RestMethod -ModuleName GitHub {
            if ($Method -eq 'Get') { return New-PrGh 7 }
            if ($Method -eq 'Delete') { throw 'Reference does not exist' }
        }
        { Complete-GhPr 'acme/web' 7 } | Should -Not -Throw
    }

    It 'Start-GhRivalutazione rilancia una volta per run i job falliti di Actions e restituisce le build di Azure Pipelines' {
        Mock Invoke-RestMethod -ModuleName GitHub {
            switch -Wildcard ([string]$Uri) {
                '*/pulls?head=*' { @(New-PrGh 7) }
                '*/check-runs*' { [pscustomobject]@{ check_runs = @(
                            (New-CheckGh 'completed' 'failure' 'https://github.com/acme/web/actions/runs/77/job/1'),
                            (New-CheckGh 'completed' 'failure' 'https://github.com/acme/web/actions/runs/77/job/2'),
                            (New-CheckGh 'completed' 'failure' 'https://dev.azure.com/acme/x/_build/results?buildId=55'),
                            (New-CheckGh 'completed' 'success' 'https://github.com/acme/web/actions/runs/78/job/1')) } }
                '*/status' { [pscustomobject]@{ statuses = @() } }
                '*/rerun-failed-jobs' { $null }
            }
        }
        $r = Start-GhRivalutazione 'acme/web' 'feature/42-x'
        $r.Actions | Should -Be 1
        $r.BuildAdo | Should -Be @(55)
        Should -Invoke Invoke-RestMethod -ModuleName GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' -and $Uri -like '*/actions/runs/77/rerun-failed-jobs' }
        Should -Invoke Invoke-RestMethod -ModuleName GitHub -Times 0 -Exactly -ParameterFilter { $Uri -like '*/actions/runs/78/*' }
    }

    It 'Start-GhRivalutazione -Scadute non fa niente: su GitHub non ci sono validazioni scadute' {
        Mock Invoke-RestMethod -ModuleName GitHub { throw 'nessuna chiamata' }
        $r = Start-GhRivalutazione 'acme/web' 'feature/42-x' -Scadute
        $r.Actions | Should -Be 0
        @($r.BuildAdo).Count | Should -Be 0
    }

    It 'Get-GhRami: i nomi dei rami con il prefisso' {
        Mock Invoke-RestMethod -ModuleName GitHub { @([pscustomobject]@{ ref = 'refs/heads/feature/42-x' }, [pscustomobject]@{ ref = 'refs/heads/feature/420-y' }) }
        Get-GhRami 'acme/web' 'feature/42' | Should -Be @('feature/42-x', 'feature/420-y')
        Should -Invoke Invoke-RestMethod -ModuleName GitHub -ParameterFilter { $Uri -eq 'https://api.github.com/repos/acme/web/git/matching-refs/heads/feature/42' }
    }

    It 'un errore di GitHub non mostra il token' {
        Mock Invoke-RestMethod -ModuleName GitHub { throw 'Unauthorized: Bearer SEGRETO-FINTO' }
        $msg = try { Get-GhRami 'acme/web' 'feature/1'; '' } catch { $_.Exception.Message }
        $msg | Should -BeLike 'Chiamata a GitHub fallita*'
        $msg | Should -Not -BeLike '*SEGRETO-FINTO*'
    }

    It 'un repoGithub sbagliato si ferma prima della chiamata' {
        Mock Invoke-RestMethod -ModuleName GitHub { throw 'nessuna chiamata' }
        { Get-GhRami 'acme' 'feature/1' } | Should -Throw '*<owner>/<repo>*'
    }
}

Describe 'Ado: il codice di un area su GitHub' {
    BeforeEach {
        Mock Get-AdoIntestazione -ModuleName Ado { @{ Authorization = 'Basic SEGRETO-FINTO' } }
        Mock Get-AdoMappaLetta -ModuleName Ado {
            '{ "progettoBoard": "DevOps.Agents",
               "aree": [ { "area": "DevOps.Agents\\Web", "repo": "Acme.Web", "progettoAdo": "Acme.Web", "sorgente": "github", "repoGithub": "acme/web" },
                         { "area": "DevOps.Agents\\AI", "repo": "Acme.AI", "progettoAdo": "Acme.AI" } ],
               "attrezzi": { "repo": "DevOps.Agents", "sorgente": "github", "repoGithub": "acme/devops-agents" } }' | ConvertFrom-Json
        }
    }

    It 'Get-SorgenteRepo: github per le aree che lo dicono e per gli attrezzi, ado per le altre e per i repo sconosciuti' {
        $g = Get-SorgenteRepo -Progetto 'Acme.Web' -Repo 'Acme.Web'
        $g.Tipo | Should -Be 'github'
        $g.RepoGh | Should -Be 'acme/web'
        (Get-SorgenteRepo -Progetto 'DevOps.Agents' -Repo 'DevOps.Agents').RepoGh | Should -Be 'acme/devops-agents'
        (Get-SorgenteRepo -Progetto 'Acme.AI' -Repo 'Acme.AI').Tipo | Should -Be 'ado'
        (Get-SorgenteRepo -Progetto 'Altro' -Repo 'Altro').Tipo | Should -Be 'ado'
    }

    It 'Get-AdoPr su un area GitHub passa da GitHub e apre il log di Azure Pipelines sulla pagina della build' {
        Mock Get-GhPr -ModuleName Ado { [pscustomobject]@{ Id = 7; Stato = 'active'; Validazione = 'rossa'; BuildId = 55; UrlLog = 'x'; UltimoCommit = 'H'; RunActions = $null } }
        Mock Invoke-RestMethod -ModuleName Ado { throw 'nessuna chiamata ad Azure DevOps' }
        $pr = Get-AdoPr -Progetto 'Acme.Web' -Repo 'Acme.Web' -Ramo 'feature/42-x'
        $pr.Validazione | Should -Be 'rossa'
        $pr.UrlLog | Should -Be 'https://acme.visualstudio.com/Acme.Web/_build/results?buildId=55'
        Should -Invoke Get-GhPr -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $RepoGh -eq 'acme/web' -and $Ramo -eq 'feature/42-x' }
    }

    It 'New-AdoPr su un area GitHub apre la PR su GitHub e mette il link sulla card' {
        Mock New-GhPr -ModuleName Ado { [pscustomobject]@{ Id = 15; Url = 'https://github.com/acme/web/pull/15' } }
        Mock Invoke-RestMethod -ModuleName Ado { if ($Method -eq 'Get') { [pscustomobject]@{ id = 42; relations = @() } } }
        $id = New-AdoPr -Progetto 'Acme.Web' -Repo 'Acme.Web' -Ramo 'feature/42-x' -Titolo 'T' -Descrizione 'D' -CardId 42
        $id | Should -Be 15
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Uri -like '*/_apis/wit/workitems/42?*' -and $ContentType -eq 'application/json-patch+json' -and
            (@($Body | ConvertFrom-Json)[0].value.rel -eq 'Hyperlink') -and (@($Body | ConvertFrom-Json)[0].value.url -eq 'https://github.com/acme/web/pull/15') }
    }

    It 'New-AdoPr: un link che la card ha gia non si aggiunge' {
        Mock New-GhPr -ModuleName Ado { [pscustomobject]@{ Id = 15; Url = 'https://github.com/acme/web/pull/15' } }
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Method -eq 'Get') { [pscustomobject]@{ id = 42; relations = @([pscustomobject]@{ rel = 'Hyperlink'; url = 'https://github.com/acme/web/pull/15' }) } }
        }
        [void](New-AdoPr -Progetto 'Acme.Web' -Repo 'Acme.Web' -Ramo 'feature/42-x' -Titolo 'T' -Descrizione 'D' -CardId 42)
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 0 -Exactly -ParameterFilter { $Method -eq 'Patch' }
    }

    It 'Get-AdoPrCollegata ritrova la PR di GitHub dal link sulla card, con progetto e repo della mappa' {
        Mock Invoke-RestMethod -ModuleName Ado { [pscustomobject]@{ id = 42; relations = @(
                    [pscustomobject]@{ rel = 'Hyperlink'; url = 'https://github.com/acme/web/pull/3' },
                    [pscustomobject]@{ rel = 'Hyperlink'; url = 'https://github.com/acme/web/pull/15' },
                    [pscustomobject]@{ rel = 'Hyperlink'; url = 'https://esempio.invalid/altro' }) } }
        Mock Get-GhPrSingola -ModuleName Ado { New-PrGh 15 'closed' -Merged '2026-11-20T10:00:00Z' }
        $pr = Get-AdoPrCollegata -CardId 42
        $pr.Id | Should -Be 15
        $pr.Stato | Should -Be 'completed'
        $pr.Progetto | Should -Be 'Acme.Web'
        $pr.Repo | Should -Be 'Acme.Web'
        $pr.Ramo | Should -Be 'feature/42-x'
        Should -Invoke Get-GhPrSingola -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $RepoGh -eq 'acme/web' -and $Id -eq 15 }
    }

    It 'Start-AdoRivalutazione su un area GitHub conta i run di Actions e rilancia le build di Azure Pipelines' {
        Mock Start-GhRivalutazione -ModuleName Ado { [pscustomobject]@{ Actions = 1; BuildAdo = @(55, 56) } }
        Mock Invoke-RestMethod -ModuleName Ado { $null }
        Start-AdoRivalutazione -Progetto 'Acme.Web' -Repo 'Acme.Web' -Ramo 'feature/42-x' | Should -Be 3
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Method -eq 'Patch' -and $Uri -like '*/Acme.Web/_apis/build/builds/55?retry=true*' }
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Method -eq 'Patch' -and $Uri -like '*/Acme.Web/_apis/build/builds/56?retry=true*' }
    }

    It 'Get-AdoRamoCard su un area GitHub filtra i rami come su Azure Repos' {
        Mock Get-GhRami -ModuleName Ado { if ($Prefisso -eq 'feature/42') { @('feature/42-x', 'feature/420-y') } else { @() } }
        Get-AdoRamoCard -Progetto 'Acme.Web' -Repo 'Acme.Web' -CardId 42 | Should -Be 'feature/42-x'
    }

    It 'Get-AdoUrlPr: il link alla PR su GitHub' {
        Get-AdoUrlPr -Progetto 'Acme.Web' -Repo 'Acme.Web' -Id 15 | Should -Be 'https://github.com/acme/web/pull/15'
        Get-AdoUrlPr -Progetto 'Acme.AI' -Repo 'Acme.AI' -Id 15 | Should -Be 'https://acme.visualstudio.com/Acme.AI/_git/Acme.AI/pullrequest/15'
    }

    It 'Get-AdoParametriDeploy legge lo YAML da GitHub quando la pipeline e su un repo GitHub' {
        Mock Invoke-RestMethod -ModuleName Ado {
            [pscustomobject]@{ configuration = [pscustomobject]@{ path = '/ci/deploy.yml'; repository = [pscustomobject]@{ id = 'acme/web'; type = 'gitHub' } } }
        }
        Mock Get-GhFile -ModuleName Ado { "parameters:`n- name: deployWeb`n  type: boolean`n  default: false`nsteps: []" }
        Get-AdoParametriDeploy -Progetto 'Acme.Web' -PipelineId 9 -Ramo 'feature/42-x' | Should -Be @('deployWeb')
        Should -Invoke Get-GhFile -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $RepoGh -eq 'acme/web' -and $Percorso -eq '/ci/deploy.yml' -and $Ramo -eq 'feature/42-x' }
    }
}
