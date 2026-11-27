BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Ado.psm1') -Force
    # I nomi di stato e di tag passano solo da config/stati.json, mai scritti qui.
    $global:FxSt = Get-Content (Join-Path $PSScriptRoot '../config/stati.json') -Raw | ConvertFrom-Json
    function Expand-Stati([string]$Testo) {
        foreach ($k in $global:FxSt.PSObject.Properties.Name) { $Testo = $Testo.Replace("__${k}__", [string]$global:FxSt.$k) }
        $Testo
    }


    $script:WiJson = @'
{ "id": 42, "rev": 7, "fields": {
    "System.WorkItemType": "User Story", "System.Title": "Titolo", "System.Description": "<p>desc</p>",
    "Microsoft.VSTS.Common.AcceptanceCriteria": "criteri", "System.State": "__pronto__",
    "System.Tags": "__tagAgenti__; __tagAttesa__", "System.AreaPath": "DevOps.Agents\\AI\\Stime",
    "System.CreatedBy": { "id": "u-1", "displayName": "Mario Rossi" },
    "System.AssignedTo": { "id": "u-2", "displayName": "Anna Bianchi", "uniqueName": "anna@example.invalid" } } }
'@
    $script:WiJson = Expand-Stati $script:WiJson

    # Una PR attiva con testa HEAD1 e le valutazioni di policy passate dal chiamante.
    # Come le restituisce Azure DevOps (verificato il 2026-11-17 sulla PR 967): il contesto della valutazione porta
    # lastMergeSourceCommitId, il commit del ramo su cui e' girata la build (default HEAD1 = la testa). La build invece
    # porta in sourceVersion il commit di merge e non ha pr.sourceCommit in triggerInfo.
    function Set-FintoPr($Valutazioni, $MergeStatus = 'succeeded') {
        $global:FxVal = $Valutazioni
        $global:FxMerge = $MergeStatus
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*pullrequests?*') {
                ('{ "value": [ { "pullRequestId": 9, "status": "active", "mergeStatus": "' + $global:FxMerge + '", "lastMergeSourceCommit": { "commitId": "HEAD1" }, "repository": { "project": { "id": "pid-1" } } } ] }') | ConvertFrom-Json
            }
            elseif ($Uri -like '*policy/evaluations*') { [pscustomobject]@{ value = $global:FxVal } }
            elseif ($Uri -like '*_apis/build/builds/*') {
                $id = [int](([string]$Uri -replace '^.*/builds/(\d+).*$', '$1'))
                $v = @($global:FxVal) | Where-Object { $_.context.buildId -eq $id } | Select-Object -First 1
                [pscustomobject]@{ id = $id; sourceVersion = 'MERGE-' + $id; triggerInfo = [pscustomobject]@{} }
            }
        }
    }
    function Nuova-Valutazione($Stato, $BuildId, $CommitBuild = 'HEAD1', $Tipo = 'Build') {
        [pscustomobject]@{
            status = $Stato; configuration = [pscustomobject]@{ type = [pscustomobject]@{ displayName = $Tipo } }
            context = [pscustomobject]@{ buildId = $BuildId; lastMergeSourceCommitId = $CommitBuild; buildIsNotCurrent = $false }
        }
    }
}

Describe 'Ado' {
    BeforeEach {
        # Il PAT non si legge nei test: la funzione privata e' sostituita.
        Mock Get-AdoIntestazione -ModuleName Ado { @{ Authorization = 'Basic SEGRETO-FINTO' } }
    }

    It 'Get-AdoCard legge e traduce la card' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        $c = Get-AdoCard -Id 42
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and $Uri -like "https://acme.visualstudio.com/_apis/wit/workitems/42?*" }
        $c.Id | Should -Be 42
        $c.Rev | Should -Be 7
        $c.Tipo | Should -Be 'User Story'
        $c.Titolo | Should -Be 'Titolo'
        $c.Criteri | Should -Be 'criteri'
        $c.Stato | Should -Be $global:FxSt.pronto
        $c.Tag | Should -Be @($global:FxSt.tagAgenti, $global:FxSt.tagAttesa)
        $c.Area | Should -Be 'DevOps.Agents\AI\Stime'
        $c.CreataDa.Nome | Should -Be 'Mario Rossi'
        # l'assegnatario e il padrone della card: lo smistatore che la fa avanzare (spec, sezione 19)
        $c.AssegnataA.Id | Should -Be 'u-2'
        $c.AssegnataA.Nome | Should -Be 'Anna Bianchi'
    }

    It 'una card Bug ha la descrizione in ReproSteps, una User Story in System.Description' {
        # in un Bug System.Description non esiste: i passi per riprodurre sono la descrizione (stesso campo che New-AdoCard scrive)
        $global:FxWi = $script:WiJson -replace '"System.WorkItemType": "User Story"', '"System.WorkItemType": "Bug"' `
            -replace '"System.Description": "<p>desc</p>"', '"Microsoft.VSTS.TCM.ReproSteps": "<p>passi</p>"'
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        $bug = Get-AdoCard -Id 42
        $bug.Tipo | Should -Be 'Bug'
        $bug.Descrizione | Should -Be '<p>passi</p>'
        $global:FxWi = $script:WiJson
        (Get-AdoCard -Id 42).Descrizione | Should -Be '<p>desc</p>'
    }

    It 'una card senza assegnatario ha AssegnataA nullo' {
        $global:FxWi = $script:WiJson -replace ',\s*"System.AssignedTo": \{[^}]*\}', ''
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        (Get-AdoCard -Id 42).AssegnataA | Should -BeNullOrEmpty
    }

    It 'Get-AdoCard legge i campi dei consumi (0 se la card non li ha ancora) e Get-AdoCampiConsumi ne da i nomi' {
        $campi = Get-AdoCampiConsumi
        $campi.Totale | Should -Be 'Custom.TotalTokens'
        $campi.Minuti | Should -Be 'Custom.AgentMinutes'
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        $c = Get-AdoCard -Id 42
        $c.ConsumoTotale | Should -Be 0
        $c.MinutiAgente | Should -Be 0
        $global:FxWi = $script:WiJson.Replace('"System.State"', '"Custom.TotalTokens": 1500, "Custom.AgentMinutes": 7, "System.State"')
        $c = Get-AdoCard -Id 42
        $c.ConsumoTotale | Should -Be 1500
        $c.MinutiAgente | Should -Be 7
    }

    It 'Get-AdoCardAttive esclude bozza e chiusa e rilegge ogni card' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Method -eq 'Post') { '{ "workItems": [ { "id": 42 } ] }' | ConvertFrom-Json } else { $global:FxWi | ConvertFrom-Json }
        }
        $r = @(Get-AdoCardAttive)
        $r.Count | Should -Be 1
        $r[0].Id | Should -Be 42
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -like "https://acme.visualstudio.com/DevOps.Agents/_apis/wit/wiql?*" -and
            $Body -like "*[[]System.TeamProject] = 'DevOps.Agents'*" -and $Body -like "*[[]System.WorkItemType] IN ('User Story', 'Bug')*" -and
            $Body -like "*CONTAINS '$($global:FxSt.tagAgenti)'*" -and $Body -like "*<> '$($global:FxSt.bozza)'*" -and $Body -like "*<> '$($global:FxSt.chiusa)'*" }
    }

    It 'Set-AdoCard scrive stato, criteri e campi e restituisce la nuova rev' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 42, "rev": 8 }' | ConvertFrom-Json }
        $rev = Set-AdoCard -Id 42 -Stato $global:FxSt.inCollaudo -Criteri 'nuovi' -Campi @{ 'Custom.TotalTokens' = 1500 }
        $rev | Should -Be 8
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Uri -like "https://acme.visualstudio.com/_apis/wit/workitems/42?*" -and
            $ContentType -eq 'application/json-patch+json' -and
            $Body -like "*`"path`":`"/fields/System.State`",`"value`":`"$($global:FxSt.inCollaudo)`"*" -and
            $Body -like '*"path":"/fields/Microsoft.VSTS.Common.AcceptanceCriteria","value":"nuovi"*' -and
            $Body -like '*"path":"/multilineFieldsFormat/Microsoft.VSTS.Common.AcceptanceCriteria","value":"Markdown"*' -and
            $Body -like '*"path":"/fields/Custom.TotalTokens","value":1500*' }
    }

    It 'Set-AdoCard sui tag controlla la revisione letta: un tag aggiunto nel frattempo fa fallire la patch invece di sparire' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Method -eq 'Get') { $global:FxWi | ConvertFrom-Json } else { '{ "id": 42, "rev": 9 }' | ConvertFrom-Json }
        }
        Set-AdoCard -Id 42 -AggiungiTag 'nuovo' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and ($Body | ConvertFrom-Json)[0].op -eq 'test' -and ($Body | ConvertFrom-Json)[0].path -eq '/rev' -and ($Body | ConvertFrom-Json)[0].value -eq 7 }
    }

    It 'Set-AdoCard senza tag non aggiunge il controllo della revisione' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 42, "rev": 9 }' | ConvertFrom-Json }
        Set-AdoCard -Id 42 -Stato 'x' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Method -eq 'Patch' -and $Body -notlike '*"op":"test"*' }
    }

    It 'Set-AdoCard aggiunge e toglie tag partendo da quelli attuali' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Method -eq 'Get') { $global:FxWi | ConvertFrom-Json } else { '{ "id": 42, "rev": 9 }' | ConvertFrom-Json }
        }
        Set-AdoCard -Id 42 -AggiungiTag 'nuovo' -TogliTag $global:FxSt.tagAttesa | Should -Be 9
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Body -like "*`"op`":`"replace`",`"path`":`"/fields/System.Tags`",`"value`":`"$($global:FxSt.tagAgenti); nuovo`"*" }
    }

    It 'New-AdoCard crea la card con tag e senza stato e restituisce la card tradotta' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        $c = New-AdoCard -Tipo 'User Story' -Titolo 'Nuova' -Area 'DevOps.Agents\AI\Stime' -Descrizione 'desc' -Criteri 'crit' -Tag $global:FxSt.tagAgenti
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -like 'https://acme.visualstudio.com/DevOps.Agents/_apis/wit/workitems/$User*Story?*' -and
            $ContentType -eq 'application/json-patch+json' -and
            $Body -like '*"path":"/fields/System.Title","value":"Nuova"*' -and
            $Body -like '*"path":"/fields/System.AreaPath","value":"DevOps.Agents\\AI\\Stime"*' -and
            $Body -like '*"path":"/fields/System.Description","value":"desc"*' -and
            $Body -like '*"path":"/fields/Microsoft.VSTS.Common.AcceptanceCriteria","value":"crit"*' -and
            $Body -like '*"path":"/multilineFieldsFormat/System.Description","value":"Markdown"*' -and
            $Body -like '*"path":"/multilineFieldsFormat/Microsoft.VSTS.Common.AcceptanceCriteria","value":"Markdown"*' -and
            $Body -like "*`"path`":`"/fields/System.Tags`",`"value`":`"$($global:FxSt.tagAgenti)`"*" -and
            $Body -notlike '*System.State*' -and $Body -notlike '*System.AssignedTo*' }
        $c.Id | Should -Be 42
    }

    It 'New-AdoCard -AssegnataA assegna la card' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        New-AdoCard -Tipo 'User Story' -Titolo 'Nuova' -Area 'DevOps.Agents\AI\Stime' -Descrizione 'd' -Criteri 'c' -AssegnataA 'anna@example.invalid' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Body -like '*"path":"/fields/System.AssignedTo","value":"anna@example.invalid"*' }
    }

    It 'New-AdoCard con -Dopo scrive una relazione Predecessor per ogni card precedente' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        New-AdoCard -Tipo 'User Story' -Titolo 'Nuova' -Area 'DevOps.Agents\AI\Stime' -Descrizione 'd' -Criteri 'c' -Dopo 11, 12 | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Body -like '*"path":"/relations/-","value":{"rel":"System.LinkTypes.Dependency-Reverse","url":"https://acme.visualstudio.com/_apis/wit/workItems/11"}*' -and
            $Body -like '*"rel":"System.LinkTypes.Dependency-Reverse","url":"https://acme.visualstudio.com/_apis/wit/workItems/12"*' }
    }

    It 'New-AdoCard senza -Dopo non scrive relazioni' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        New-AdoCard -Tipo 'Bug' -Titolo 'T' -Area 'DevOps.Agents\AI\Stime' -Descrizione 'd' -Criteri 'c' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Body -notlike '*relations*' }
    }

    It 'Get-AdoCardPredecessori legge le relazioni Predecessor e restituisce id e stato in ordine di id' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*workitems/42?*') {
                '{ "id": 42, "rev": 3, "fields": {}, "relations": [
                    { "rel": "System.LinkTypes.Hierarchy-Forward", "url": "https://acme.visualstudio.com/_apis/wit/workItems/99" },
                    { "rel": "System.LinkTypes.Dependency-Reverse", "url": "https://acme.visualstudio.com/_apis/wit/workItems/31" },
                    { "rel": "System.LinkTypes.Dependency-Reverse", "url": "https://acme.visualstudio.com/_apis/wit/workItems/30" },
                    { "rel": "System.LinkTypes.Dependency-Forward", "url": "https://acme.visualstudio.com/_apis/wit/workItems/80" } ] }' | ConvertFrom-Json
            }
            else {
                '{ "count": 2, "value": [
                    { "id": 31, "fields": { "System.State": "Closed" } },
                    { "id": 30, "fields": { "System.State": "In review", "System.Tags": "agents; no-test-deploy" } } ] }' | ConvertFrom-Json
            }
        }
        $p = @(Get-AdoCardPredecessori -CardId 42)
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and $Uri -like '*_apis/wit/workitems?ids=30,31&*' }
        $p.Count | Should -Be 2
        $p[0].Id | Should -Be 30
        $p[0].Stato | Should -Be 'In review'
        $p[1].Id | Should -Be 31
        $p[1].Stato | Should -Be 'Closed'
        @($p[0].Tag) | Should -Be @('agents', 'no-test-deploy')
        @($p[1].Tag).Count | Should -Be 0
    }

    It 'Get-AdoCardPredecessori su una card senza predecessori restituisce un elenco vuoto senza altre chiamate' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 42, "rev": 3, "fields": {} }' | ConvertFrom-Json }
        @(Get-AdoCardPredecessori -CardId 42).Count | Should -Be 0
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly
    }

    It 'New-AdoCard per un Bug scrive la descrizione nei passi di riproduzione' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        New-AdoCard -Tipo 'Bug' -Titolo 'Rotto' -Area 'DevOps.Agents\AI\Stime' -Descrizione 'passi' -Criteri 'crit' -Tag $global:FxSt.tagAgenti | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*workitems/$Bug?*' -and
            $Body -like '*"path":"/fields/Microsoft.VSTS.TCM.ReproSteps","value":"passi"*' -and
            $Body -like '*"path":"/multilineFieldsFormat/Microsoft.VSTS.TCM.ReproSteps","value":"Markdown"*' -and
            $Body -notlike '*System.Description*' }
    }

    It 'D52: New-AdoCard per una Feature non scrive i criteri (il tipo non ha il campo) e crea una Feature' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        New-AdoCard -Tipo 'Feature' -Titolo 'F' -Area 'DevOps.Agents\AI\Stime' -Descrizione 'desc' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*workitems/$Feature?*' -and
            $Body -like '*"path":"/fields/System.Description","value":"desc"*' -and
            $Body -notlike '*AcceptanceCriteria*' }
    }

    It 'D52: New-AdoCard per una Feature con -Criteri e un errore: il tipo non li ha, non si perdono in silenzio' {
        Mock Invoke-RestMethod -ModuleName Ado { throw 'non doveva scrivere' }
        { New-AdoCard -Tipo 'Feature' -Titolo 'F' -Area 'DevOps.Agents\AI\Stime' -Descrizione 'd' -Criteri 'c' } | Should -Throw '*criteri*'
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 0 -Exactly
    }

    It 'D52: New-AdoCard senza -Criteri per una card non scrive il campo dei criteri' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        New-AdoCard -Tipo 'User Story' -Titolo 'T' -Area 'DevOps.Agents\AI\Stime' -Descrizione 'd' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Body -notlike '*AcceptanceCriteria*' }
    }

    It 'Get-AdoStoriaStato restituisce solo i cambi di stato' {
        Mock Invoke-RestMethod -ModuleName Ado {
            @'
{ "value": [
 { "rev": 1, "fields": { "System.State": "__bozza__", "System.ChangedBy": { "displayName": "A" }, "System.ChangedDate": "2026-11-01T10:00:00Z" } },
 { "rev": 2, "fields": { "System.State": "__bozza__", "System.ChangedBy": { "displayName": "A" }, "System.ChangedDate": "2026-11-01T11:00:00Z" } },
 { "rev": 3, "fields": { "System.State": "__nuova__", "System.ChangedBy": { "displayName": "B", "id": "id-b" }, "System.ChangedDate": "2026-11-01T12:00:00Z" } } ] }
'@ | ForEach-Object { (Expand-Stati $_) | ConvertFrom-Json }
        }
        $s = @(Get-AdoStoriaStato -Id 42)
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and $Uri -like "https://acme.visualstudio.com/_apis/wit/workitems/42/revisions*" }
        $s.Count | Should -Be 2
        $s[1].Rev | Should -Be 3
        $s[1].Da | Should -Be $global:FxSt.bozza
        $s[1].A | Should -Be $global:FxSt.nuova
        $s[1].Chi | Should -Be 'id-b'
        $s[1].ChiNome | Should -Be 'B'
        $s[1].Quando | Should -Not -BeNullOrEmpty
    }

    It 'Get-AdoCommenti filtra per DopoId' {
        Mock Invoke-RestMethod -ModuleName Ado {
            '{ "comments": [ { "id": 5, "text": "a", "createdBy": { "displayName": "X" }, "createdDate": "d1" }, { "id": 8, "text": "b", "createdBy": { "displayName": "Y" }, "createdDate": "d2" } ] }' | ConvertFrom-Json
        }
        $c = @(Get-AdoCommenti -Id 42 -DopoId 5)
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and $Uri -like "https://acme.visualstudio.com/DevOps.Agents/_apis/wit/workItems/42/comments*" }
        $c.Count | Should -Be 1
        $c[0].Id | Should -Be 8
        $c[0].Autore | Should -Be 'Y'
        $c[0].Testo | Should -Be 'b'
    }

    It 'Add-AdoCommento scrive il testo e restituisce l id, con menzione facoltativa' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 77 }' | ConvertFrom-Json }
        Add-AdoCommento -Id 42 -Testo 'ciao' | Should -Be 77
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -like "https://acme.visualstudio.com/DevOps.Agents/_apis/wit/workItems/42/comments*" -and $Body -eq '{"text":"ciao"}' }
        # in Markdown: in html a capo ed elenchi diventano una riga sola (verificato il 2026-11-17 sulla card 9)
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*comments?format=markdown&*' }
        Add-AdoCommento -Id 42 -Testo 'ciao' -Menziona 'u-1' | Should -Be 77
        # la menzione in Markdown e @<id>: Azure DevOps la rende come menzione e avvisa la persona
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Body -eq '{"text":"@<u-1> ciao"}' }
    }

    It 'New-AdoPr punta a develop, collega la card e chiude con la firma' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "pullRequestId": 12 }' | ConvertFrom-Json }
        New-AdoPr -Progetto 'Acme.AI' -Repo 'Acme.AI' -Ramo 'feature/x' -Titolo 'T' -Descrizione 'D' -CardId 42 | Should -Be 12
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -like "https://acme.visualstudio.com/Acme.AI/_apis/git/repositories/Acme.AI/pullrequests?*" -and
            $Body -like '*"sourceRefName":"refs/heads/feature/x"*' -and $Body -like '*"targetRefName":"refs/heads/develop"*' -and
            $Body -like '*"workItemRefs":[[]{"id":"42"}[]]*' -and
            $Body -like '*Generated with [[]Claude Code[]](https://claude.com/claude-code)"*' }
    }

    It 'New-AdoPr senza card (la PR della memoria) non porta workItemRefs' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "pullRequestId": 13 }' | ConvertFrom-Json }
        New-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'memoria/in-prova' -Titolo 'T' -Descrizione 'D' | Should -Be 13
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Body -like '*"sourceRefName":"refs/heads/memoria/in-prova"*' -and $Body -notlike '*workItemRefs*' }
    }

    It 'Get-AdoDescrizionePr legge la descrizione della PR' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "pullRequestId": 12, "description": "testo della PR" }' | ConvertFrom-Json }
        Get-AdoDescrizionePr -Progetto 'P' -Repo 'R' -Id 12 | Should -Be 'testo della PR'
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Method -eq 'Get' -and $Uri -like '*/pullrequests/12?*' }
    }

    It 'Set-AdoDescrizionePr cambia la descrizione e rimette la firma' {
        Mock Invoke-RestMethod -ModuleName Ado { $null }
        Set-AdoDescrizionePr -Progetto 'P' -Repo 'R' -Id 12 -Descrizione 'nuova'
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Uri -like '*/pullrequests/12?*' -and $Body -like '*"description":"nuova*Generated with*' }
    }

    It 'Get-AdoLimiteTestoPr: un testo lungo quanto il massimo, con la firma, arriva a 4000 caratteri; uno in piu li supera' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "pullRequestId": 12 }' | ConvertFrom-Json }
        $massimo = Get-AdoLimiteTestoPr
        [void](New-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'r' -Titolo 'T' -Descrizione ('x' * $massimo))
        Set-AdoDescrizionePr -Progetto 'P' -Repo 'R' -Id 12 -Descrizione ('x' * $massimo)
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 2 -Exactly -ParameterFilter { ($Body | ConvertFrom-Json).description.Length -eq 4000 }
        Set-AdoDescrizionePr -Progetto 'P' -Repo 'R' -Id 12 -Descrizione ('x' * ($massimo + 1))
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { ($Body | ConvertFrom-Json).description.Length -eq 4001 }
    }

    It 'Complete-AdoPr completa la PR sull ultimo commit' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Method -eq 'Get') { '{ "pullRequestId": 12, "lastMergeSourceCommit": { "commitId": "abc" } }' | ConvertFrom-Json } else { $null }
        }
        Complete-AdoPr -Progetto 'Acme.AI' -Repo 'Acme.AI' -Id 12
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Uri -like '*/pullrequests/12?*' -and
            $Body -like '*"status":"completed"*' -and $Body -like '*"commitId":"abc"*' }
    }

    It 'Complete-AdoPr -Commit completa su quel commit e non su quello riletto: se la testa e cambiata Azure DevOps rifiuta' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Method -eq 'Get') { '{ "pullRequestId": 12, "lastMergeSourceCommit": { "commitId": "nuovo" } }' | ConvertFrom-Json } else { $null }
        }
        Complete-AdoPr -Progetto 'Acme.AI' -Repo 'Acme.AI' -Id 12 -Commit 'verificato'
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Body -like '*"commitId":"verificato"*' -and $Body -notlike '*nuovo*' }
    }

    It 'Complete-AdoPr chiede ad Azure DevOps di cancellare il ramo sorgente' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Method -eq 'Get') { '{ "pullRequestId": 12, "lastMergeSourceCommit": { "commitId": "abc" } }' | ConvertFrom-Json } else { $null }
        }
        Complete-AdoPr -Progetto 'Acme.AI' -Repo 'Acme.AI' -Id 12
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Body -like '*"completionOptions":{*"deleteSourceBranch":true*' }
    }

    It 'Complete-AdoPr dichiara la strategia di merge: merge commit, da cui Remove-WorktreeCard riconosce il ramo assorbito' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Method -eq 'Get') { '{ "pullRequestId": 12, "lastMergeSourceCommit": { "commitId": "abc" } }' | ConvertFrom-Json } else { $null }
        }
        Complete-AdoPr -Progetto 'Acme.AI' -Repo 'Acme.AI' -Id 12
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Body -like '*"mergeStrategy":"noFastForward"*' }
    }

    It 'Start-AdoDeployTest accoda la pipeline sul ramo con tutti i parametri a true, e nessun altro' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 555 }' | ConvertFrom-Json }
        Start-AdoDeployTest -Progetto 'Acme.AI' -PipelineId 115 -Ramo 'feature/x' -Parametri @('deployStime', 'deployDatabases') | Should -Be 555
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -like "https://acme.visualstudio.com/Acme.AI/_apis/pipelines/115/runs?*" -and
            $Body -like '*"refName":"refs/heads/feature/x"*' -and
            (@(($Body | ConvertFrom-Json).templateParameters.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" } | Sort-Object) -join ';') -eq 'deployDatabases=true;deployStime=true' }
    }

    It 'Start-AdoDeployTest mette a false i deploy* non scelti, cosi un default true non parte da solo' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 555 }' | ConvertFrom-Json }
        Start-AdoDeployTest -Progetto 'Acme.AI' -PipelineId 115 -Ramo 'feature/x' -Parametri @('deployStime') -Spenti @('deployDatabases', 'deployApi') | Should -Be 555
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            (@(($Body | ConvertFrom-Json).templateParameters.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" } | Sort-Object) -join ';') -eq 'deployApi=false;deployDatabases=false;deployStime=true' }
    }

    It 'Start-AdoDeployTest: un nome scelto e anche fra gli spenti resta acceso' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 555 }' | ConvertFrom-Json }
        Start-AdoDeployTest -Progetto 'P' -PipelineId 1 -Ramo 'r' -Parametri @('deployA') -Spenti @('deployA', 'deployB') | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            (@(($Body | ConvertFrom-Json).templateParameters.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" } | Sort-Object) -join ';') -eq 'deployA=true;deployB=false' }
    }

    It 'Start-AdoDeployTest senza parametri non accoda niente' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 555 }' | ConvertFrom-Json }
        { Start-AdoDeployTest -Progetto 'Acme.AI' -PipelineId 115 -Ramo 'feature/x' -Parametri @() } | Should -Throw
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 0 -Exactly
    }

    It 'Get-AdoRun restituisce stato ed esito' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "status": "completed", "result": "succeeded" }' | ConvertFrom-Json }
        $r = Get-AdoRun -Progetto 'Acme.AI' -RunId 555
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and $Uri -like "https://acme.visualstudio.com/Acme.AI/_apis/build/builds/555?*" }
        $r.Stato | Should -Be 'completed'
        $r.Esito | Should -Be 'succeeded'
        $r.Url | Should -Be 'https://acme.visualstudio.com/Acme.AI/_build/results?buildId=555'
    }

    It 'Get-AdoUrlBuild da il link alla pagina del run, con il progetto codificato' {
        Get-AdoUrlBuild -Progetto 'Progetto Uno' -Id 7 | Should -Be 'https://acme.visualstudio.com/Progetto%20Uno/_build/results?buildId=7'
    }

    It 'Get-AdoRun di una run ancora in corso (senza il campo result) da esito nullo, senza rompersi' {
        # come la restituisce Azure DevOps mentre gira (card 9, 2026-11-18): il campo result non c'e ancora
        Mock Invoke-RestMethod -ModuleName Ado { '{ "status": "inProgress" }' | ConvertFrom-Json }
        $r = Get-AdoRun -Progetto 'Acme.AI' -RunId 555
        $r.Stato | Should -Be 'inProgress'
        $r.Esito | Should -BeNullOrEmpty
    }

    It 'Get-AdoUtenteCorrente restituisce id e nome del titolare' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "authenticatedUser": { "id": "u-9", "providerDisplayName": "Titolare", "properties": { "Account": { "$type": "System.String", "$value": "titolare@example.invalid" } } } }' | ConvertFrom-Json }
        $u = Get-AdoUtenteCorrente
        # l'indirizzo serve a assegnare una card: System.AssignedTo lo accetta come identita
        $u.Email | Should -Be 'titolare@example.invalid'
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and $Uri -like "https://acme.visualstudio.com/_apis/connectionData*" }
        $u.Id | Should -Be 'u-9'
        $u.Nome | Should -Be 'Titolare'
    }

    Context 'Get-AdoPrCollegata' {
        # Come la restituisce Azure DevOps (card 6, 2026-11-17): la PR e una relazione ArtifactLink "Pull Request" della card,
        # e il suo stato si legge a livello di organizzazione.
        It 'trova la PR collegata piu recente e ne legge lo stato' {
            Mock Invoke-RestMethod -ModuleName Ado {
                if ($Uri -like '*workitems/6?*relations*') {
                    '{ "id": 6, "relations": [
                        { "rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/p1%2fr1%2f940", "attributes": { "name": "Pull Request" } },
                        { "rel": "ArtifactLink", "url": "vstfs:///Git/Commit/p1%2fr1%2fabc", "attributes": { "name": "Fixed in Commit" } },
                        { "rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/p1%2fr1%2f951", "attributes": { "name": "Pull Request" } } ] }' | ConvertFrom-Json
                }
                elseif ($Uri -like '*/_apis/git/pullrequests/951?*') { '{ "pullRequestId": 951, "status": "completed", "title": "feat: base", "sourceRefName": "refs/heads/feature/6-x",
                    "repository": { "name": "r1", "project": { "name": "p1" } } }' | ConvertFrom-Json }
                else { throw "chiamata inattesa: $Uri" }
            }
            $r = Get-AdoPrCollegata -CardId 6
            $r.Id | Should -Be 951
            $r.Stato | Should -Be 'completed'
            # card.ps1 titolo-pr rinomina la PR e ne rilancia la validazione: servono progetto, repo e ramo
            $r.Progetto | Should -Be 'p1'; $r.Repo | Should -Be 'r1'; $r.Ramo | Should -Be 'feature/6-x'; $r.Titolo | Should -Be 'feat: base'
        }

        It 'senza PR collegate restituisce niente' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 6 }' | ConvertFrom-Json }
            Get-AdoPrCollegata -CardId 6 | Should -BeNullOrEmpty
        }
    }

    Context 'Get-AdoErroriBuild' {
        # Come li restituisce Azure DevOps (build 6954, 2026-11-17): la timeline con i passi e l'url del log di ciascuno,
        # e il log come testo, una riga per evento con l'orario davanti.
        BeforeEach {
            $global:FxLog = @(
                '2026-11-17T15:18:14Z   Passed A.Test_uno [5 s]'
                '2026-11-17T15:26:39Z [xUnit.net 00:06:13.66]     A.Test_due [FAIL]'
                '2026-11-17T15:26:41Z   Failed A.Test_due [39 s]'
                '2026-11-17T15:26:41Z   Error Message:'
                '2026-11-17T15:26:41Z    Assert.True() Failure'
                '2026-11-17T15:26:41Z   Stack Trace:'
                '2026-11-17T15:26:41Z      at A.Test_due() in C:\x\A.cs:line 12'
                '2026-11-17T15:26:53Z   Passed A.Test_tre [1 ms]'
                '2026-11-17T15:30:38Z ##[error]Error: The process dotnet.exe failed with exit code 1'
            ) -join "`n"
            Mock Invoke-RestMethod -ModuleName Ado {
                if ($Uri -like '*/timeline?*') {
                    '{ "records": [
                        { "type": "Task", "name": "Build", "result": "succeeded", "log": { "url": "https://x/logs/10" } },
                        { "type": "Task", "name": "Run tests", "result": "failed", "log": { "url": "https://x/logs/16" } },
                        { "type": "Job", "name": "Job", "result": "failed" } ] }' | ConvertFrom-Json
                }
                elseif ($Uri -like 'https://x/logs/16*') { $global:FxLog }
                else { throw "chiamata inattesa: $Uri" }
            }
        }

        It 'riporta il passo fallito, i test falliti con il loro messaggio e gli errori, senza i test passati' {
            $t = Get-AdoErroriBuild -Progetto 'Acme.AI' -BuildId 6954
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*/Acme.AI/_apis/build/builds/6954/timeline?*' }
            $t | Should -Match 'Run tests'
            $t | Should -Match 'Failed A\.Test_due'
            $t | Should -Match 'Assert\.True\(\) Failure'
            $t | Should -Match 'A\.cs:line 12'
            $t | Should -Match 'exit code 1'
            $t | Should -Not -Match 'Test_uno'
            $t | Should -Not -Match 'Test_tre'
            $t | Should -Not -Match '2026-11-17T'
        }

        It 'senza passi falliti lo dice, invece di restituire niente' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "records": [ { "type": "Task", "name": "Build", "result": "succeeded" } ] }' | ConvertFrom-Json }
            Get-AdoErroriBuild -Progetto 'P' -BuildId 1 | Should -Match 'nessun passo fallito'
        }

        # D52 (gruppo 4): la CI rossa della card di chiusura e del codice solo se un passo fallito ha test falliti o errori di compilazione;
        # il resto (agente perso, timeout, un passo di deploy) e infrastruttura, e vale null
        It 'con -SoloCodice: test falliti in un passo fallito sono errori di codice' {
            $t = Get-AdoErroriBuild -Progetto 'Acme.AI' -BuildId 6954 -SoloCodice
            $t | Should -Match 'Failed A\.Test_due'
        }
        It 'con -SoloCodice: un errore di compilazione (<Err>) e un errore di codice' -ForEach @(
            @{ Err = 'CS1002' }, @{ Err = 'MSB4018' }, @{ Err = 'NU1101' }, @{ Err = 'TS2304' }
        ) {
            $global:FxLog = "2026-11-17T15:30:38Z ##[error]Program.cs(12,5): error $Err : qualcosa non va"
            (Get-AdoErroriBuild -Progetto 'P' -BuildId 1 -SoloCodice) | Should -Match "error $Err"
        }
        It 'con -SoloCodice: un passo fallito senza test falliti ne errori di compilazione (timeout, agente perso) da null, anche con ##[error]' {
            $global:FxLog = "2026-11-17T15:30:38Z ##[error]The job running on agent X ran longer than the maximum time of 60 minutes"
            Get-AdoErroriBuild -Progetto 'P' -BuildId 1 -SoloCodice | Should -BeNullOrEmpty
        }
        It 'con -SoloCodice: senza passi falliti da null; senza -SoloCodice il testo di sempre' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "records": [ { "type": "Task", "name": "Build", "result": "succeeded" } ] }' | ConvertFrom-Json }
            Get-AdoErroriBuild -Progetto 'P' -BuildId 1 -SoloCodice | Should -BeNullOrEmpty
            Get-AdoErroriBuild -Progetto 'P' -BuildId 1 | Should -Match 'nessun passo fallito'
        }
    }

    Context 'Get-AdoMotivoFallimento' {
        It 'riporta le issues dei record falliti e le ultime righe del log del passo fallito' {
            Mock Invoke-RestMethod -ModuleName Ado {
                if ($Uri -like '*/timeline?*') {
                    '{ "records": [
                        { "type": "Task", "name": "Build", "result": "succeeded" },
                        { "type": "Task", "name": "Test", "result": "failed", "log": { "url": "https://x/logs/7" }, "issues": [ { "type": "error", "message": "The agent lost communication with the server" } ] },
                        { "type": "Job", "name": "Job", "result": "failed", "issues": [] } ] }' | ConvertFrom-Json
                }
                elseif ($Uri -like 'https://x/logs/7*') { "2026-11-20T10:00:00Z riga uno`n2026-11-20T10:00:01Z Timeout expired`n" }
                else { throw "chiamata inattesa: $Uri" }
            }
            $t = Get-AdoMotivoFallimento -Progetto 'Acme.AI' -BuildId 55
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*/Acme.AI/_apis/build/builds/55/timeline?*' }
            $t | Should -Match 'lost communication with the server'
            $t | Should -Match 'Timeout expired'
            $t | Should -Not -Match '2026-11-20T'
        }
        It 'senza record falliti restituisce un testo vuoto, e un log che non si legge non ferma la lettura' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "records": [ { "type": "Task", "name": "Build", "result": "succeeded" } ] }' | ConvertFrom-Json }
            Get-AdoMotivoFallimento -Progetto 'P' -BuildId 1 | Should -BeNullOrEmpty
            Mock Invoke-RestMethod -ModuleName Ado {
                if ($Uri -like '*/timeline?*') { '{ "records": [ { "type": "Task", "result": "failed", "log": { "url": "https://x/logs/9" }, "issues": [ { "message": "boom" } ] } ] }' | ConvertFrom-Json }
                else { throw 'log non leggibile' }
            }
            Get-AdoMotivoFallimento -Progetto 'P' -BuildId 1 | Should -Be 'boom'
        }
    }

    Context 'Get-AdoUltimoRun' {
        It 'l ultimo run di una definizione su un ramo, con il suo esito; $null se non ce ne sono' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [ { "id": 905, "status": "completed", "result": "succeeded" } ] }' | ConvertFrom-Json }
            $r = Get-AdoUltimoRun -Progetto 'Acme.AI' -DefinizioneId 20 -Ramo 'develop'
            $r.Id | Should -Be 905; $r.Esito | Should -Be 'succeeded'
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Get' -and $Uri -like '*definitions=20*' -and $Uri -like '*branchName=refs%2Fheads%2Fdevelop*' -and $Uri -like '*$top=1*'
            }
            Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [] }' | ConvertFrom-Json }
            Get-AdoUltimoRun -Progetto 'P' -DefinizioneId 1 -Ramo 'develop' | Should -BeNullOrEmpty
        }
    }

    Context 'D61: il deploy di develop in Test e il commit di merge' {
        It 'Get-AdoUltimoRunRiuscito: l ultimo run riuscito sul ramo, con il commit deployato; $null se non ce ne sono' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [ { "id": 77, "sourceVersion": "abc", "finishTime": "2026-11-27T08:00:00Z" } ] }' | ConvertFrom-Json }
            $r = Get-AdoUltimoRunRiuscito -Progetto 'Acme.AI' -DefinizioneId 115 -Ramo 'develop'
            $r.Id | Should -Be 77; $r.Commit | Should -Be 'abc'; $r.Url | Should -BeLike '*buildId=77*'
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
                $Uri -like '*definitions=115*' -and $Uri -like '*branchName=refs%2Fheads%2Fdevelop*' -and $Uri -like '*resultFilter=succeeded*' -and $Uri -like '*statusFilter=completed*'
            }
            Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [] }' | ConvertFrom-Json }
            Get-AdoUltimoRunRiuscito -Progetto 'P' -DefinizioneId 1 -Ramo 'develop' | Should -BeNullOrEmpty
        }
        It 'Test-AdoCommitContenuto: vero se l antenato comune e il commit stesso, falso altrimenti, vero senza chiamate se sono lo stesso commit' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "commonCommit": "m1", "aheadCount": 0, "behindCount": 3 }' | ConvertFrom-Json }
            Test-AdoCommitContenuto -Progetto 'P' -Repo 'R' -Commit 'm1' -In 'd9' | Should -BeTrue
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*diffs/commits?baseVersion=m1*targetVersion=d9*' }
            Mock Invoke-RestMethod -ModuleName Ado { '{ "commonCommit": "x0" }' | ConvertFrom-Json }
            Test-AdoCommitContenuto -Progetto 'P' -Repo 'R' -Commit 'm1' -In 'd9' | Should -BeFalse
            Test-AdoCommitContenuto -Progetto 'P' -Repo 'R' -Commit 'd9' -In 'd9' | Should -BeTrue
        }
    }

    Context 'Get-AdoAgentiPool: gli errori di lettura' {
        It 'senza -Errori un pool che non risponde non c e (come per la vista); con -Errori lo dice' {
            Mock Invoke-RestMethod -ModuleName Ado { throw 'HTTP 403' }
            @(Get-AdoAgentiPool).Count | Should -Be 0
            $e = [System.Collections.Generic.List[string]]::new()
            @(Get-AdoAgentiPool -Errori $e).Count | Should -Be 0
            $e.Count | Should -Be 1
            $e[0] | Should -Match 'HTTP 403'
        }
    }

    Context 'Start-AdoRilancioRun' {
        It 'accoda un build della stessa definizione sullo stesso ramo e restituisce l id nuovo' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 777 }' | ConvertFrom-Json }
            Start-AdoRilancioRun -Progetto 'Acme.AI' -DefinizioneId 12 -Ramo 'develop' | Should -Be 777
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Post' -and $Uri -like '*/Acme.AI/_apis/build/builds?api-version=7.1' -and
                $Body -match '"id":12' -and $Body -match '"sourceBranch":"refs/heads/develop"'
            }
        }
        It 'rilancia con la stessa versione di sorgente e gli stessi parametri del run originale' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 778 }' | ConvertFrom-Json }
            $par = '{ "deployStime": true, "nome": "x" }' | ConvertFrom-Json
            Start-AdoRilancioRun -Progetto 'Acme.AI' -DefinizioneId 12 -Ramo 'develop' -SourceVersion 'abc123' -ParametriTemplate $par | Should -Be 778
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
                $Body -match '"sourceVersion":"abc123"' -and $Body -match '"templateParameters"' -and $Body -match '"deployStime":"True"' -and $Body -match '"nome":"x"'
            }
        }
        It 'un ramo che non e un ramo (la validazione di una PR) non si rilancia' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 1 }' | ConvertFrom-Json }
            { Start-AdoRilancioRun -Progetto 'P' -DefinizioneId 1 -Ramo 'PR #12' } | Should -Throw '*non e un ramo*'
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 0 -Exactly
        }
    }

    Context 'Start-AdoRivalutazione' {
        It 'riaccoda solo le valutazioni di build rosse della PR attiva del ramo, e dice quante' {
            $rossa = Nuova-Valutazione 'rejected' 100; $rossa | Add-Member evaluationId 'ev-rossa'
            $rotta = Nuova-Valutazione 'broken' 101; $rotta | Add-Member evaluationId 'ev-rotta'
            $verde = Nuova-Valutazione 'approved' 102; $verde | Add-Member evaluationId 'ev-verde'
            $revisori = Nuova-Valutazione 'rejected' $null 'HEAD1' 'Minimum number of reviewers'; $revisori | Add-Member evaluationId 'ev-revisori'
            Set-FintoPr @($rossa, $rotta, $verde, $revisori)
            Start-AdoRivalutazione -Progetto 'Acme.AI' -Repo 'Acme.AI' -Ramo 'feature/x' | Should -Be 2
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 2 -Exactly -ParameterFilter { $Method -eq 'Patch' }
            foreach ($id in 'ev-rossa', 'ev-rotta') {
                Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
                    $Method -eq 'Patch' -and $Uri -like "https://acme.visualstudio.com/pid-1/_apis/policy/evaluations/$id`?api-version=*" }
            }
        }

        It 'con -Scadute riaccoda solo le valutazioni di build scadute, non le rosse ne le altre' {
            $scaduta = Nuova-Valutazione 'queued' 100; $scaduta.context | Add-Member isExpired $true; $scaduta | Add-Member evaluationId 'ev-scaduta'
            $rossa = Nuova-Valutazione 'rejected' 101; $rossa | Add-Member evaluationId 'ev-rossa'
            $verde = Nuova-Valutazione 'approved' 102; $verde | Add-Member evaluationId 'ev-verde'
            Set-FintoPr @($scaduta, $rossa, $verde)
            Start-AdoRivalutazione -Progetto 'Acme.AI' -Repo 'Acme.AI' -Ramo 'feature/x' -Scadute | Should -Be 1
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Patch' -and $Uri -like 'https://acme.visualstudio.com/pid-1/_apis/policy/evaluations/ev-scaduta?api-version=*' }
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Method -eq 'Patch' }
        }

        It 'con -Destinazione cerca la PR attiva verso quel ramo, senza verso develop' {
            $rossa = Nuova-Valutazione 'rejected' 100; $rossa | Add-Member evaluationId 'ev-rossa'
            Set-FintoPr @($rossa)
            Start-AdoRivalutazione -Progetto 'P' -Repo 'R' -Ramo 'feature/x' -Destinazione 'feature/f7-la-funzione' | Should -Be 1
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*targetRefName=refs/heads/feature/f7-la-funzione&*' }
            Start-AdoRivalutazione -Progetto 'P' -Repo 'R' -Ramo 'feature/x' | Should -Be 1
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*targetRefName=refs/heads/develop&*' }
        }

        It 'senza PR attiva sul ramo non riaccoda niente e da 0' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [] }' | ConvertFrom-Json }
            Start-AdoRivalutazione -Progetto 'P' -Repo 'R' -Ramo 'feature/x' | Should -Be 0
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 0 -Exactly -ParameterFilter { $Method -eq 'Patch' }
        }

        # D52 (gruppo 4): con valutazioni ma nessuna da rilanciare l'elenco era vuoto, e `.Count` su null in StrictMode lanciava un errore
        It 'con le valutazioni della PR ma nessuna da rilanciare da 0, senza errori (rosse: <Cosa>)' -ForEach @(
            @{ Cosa = 'solo verdi'; Scadute = $false }, @{ Cosa = 'solo verdi, con -Scadute'; Scadute = $true }
        ) {
            $verde = Nuova-Valutazione 'approved' 102; $verde | Add-Member evaluationId 'ev-verde'
            Set-FintoPr @($verde)
            $n = if ($Scadute) { Start-AdoRivalutazione -Progetto 'P' -Repo 'R' -Ramo 'feature/x' -Scadute } else { Start-AdoRivalutazione -Progetto 'P' -Repo 'R' -Ramo 'feature/x' }
            $n | Should -Be 0
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 0 -Exactly -ParameterFilter { $Method -eq 'Patch' }
        }
    }

    Context 'Get-AdoPrDelRamo' {
        It 'elenca le PR del ramo verso develop di ogni stato, con id, stato e commit sorgente, dalla piu recente' {
            Mock Invoke-RestMethod -ModuleName Ado {
                '{ "value": [ { "pullRequestId": 7, "status": "abandoned", "lastMergeSourceCommit": { "commitId": "AAA" } },
                  { "pullRequestId": 9, "status": "active", "lastMergeSourceCommit": { "commitId": "BBB" } },
                  { "pullRequestId": 8, "status": "completed" } ] }' | ConvertFrom-Json
            }
            $r = @(Get-AdoPrDelRamo -Progetto 'Acme.AI' -Repo 'Acme.AI' -Ramo 'memoria/in-prova')
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Get' -and $Uri -like 'https://acme.visualstudio.com/Acme.AI/_apis/git/repositories/Acme.AI/pullrequests?*' -and
                $Uri -like '*sourceRefName=refs/heads/memoria/in-prova*' -and $Uri -like '*targetRefName=refs/heads/develop*' -and $Uri -like '*searchCriteria.status=all*' }
            $r.Count | Should -Be 3
            ($r | ForEach-Object Id) -join ',' | Should -Be '9,8,7'
            $r[0].Stato | Should -Be 'active'
            $r[0].CommitSorgente | Should -Be 'BBB'
            $r[1].CommitSorgente | Should -BeNullOrEmpty
            $r[2].Stato | Should -Be 'abandoned'
        }

        It 'senza PR restituisce una lista vuota' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [] }' | ConvertFrom-Json }
            @(Get-AdoPrDelRamo -Progetto 'P' -Repo 'R' -Ramo 'x').Count | Should -Be 0
        }

        It 'un errore di Azure DevOps non diventa una lista vuota: chi chiama deve saperlo' {
            Mock Invoke-RestMethod -ModuleName Ado { throw 'rete giu' }
            { Get-AdoPrDelRamo -Progetto 'P' -Repo 'R' -Ramo 'x' } | Should -Throw '*rete giu*'
        }
    }

    Context 'Get-AdoPr' {
        It 'senza PR restituisce null' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [] }' | ConvertFrom-Json }
            Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x' | Should -BeNullOrEmpty
        }

        It 'cerca la PR attiva del ramo verso develop' {
            Set-FintoPr @((Nuova-Valutazione 'approved' 100))
            Get-AdoPr -Progetto 'Acme.AI' -Repo 'Acme.AI' -Ramo 'feature/x' | Out-Null
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Get' -and $Uri -like "https://acme.visualstudio.com/Acme.AI/_apis/git/repositories/Acme.AI/pullrequests?*" -and
                $Uri -like '*sourceRefName=refs/heads/feature/x*' -and $Uri -like '*targetRefName=refs/heads/develop*' }
        }

        It 'senza -AncheCompletate cerca solo le PR attive' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [] }' | ConvertFrom-Json }
            Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x' | Out-Null
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*searchCriteria.status=active*' }
        }

        It '-AncheCompletate trova la PR completata del ramo, senza leggere le policy' {
            Mock Invoke-RestMethod -ModuleName Ado {
                '{ "value": [ { "pullRequestId": 9, "status": "completed", "lastMergeSourceCommit": { "commitId": "HEAD1" }, "repository": { "project": { "id": "pid-1" } } } ] }' | ConvertFrom-Json
            }
            $r = Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x' -AncheCompletate
            Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*searchCriteria.status=all*' }
            $r.Id | Should -Be 9
            $r.Stato | Should -Be 'completed'
            $r.Validazione | Should -Be 'assente'
        }

        It '-AncheCompletate preferisce la PR attiva e ignora quelle abbandonate' {
            Mock Invoke-RestMethod -ModuleName Ado {
                if ($Uri -like '*pullrequests?*') {
                    '{ "value": [ { "pullRequestId": 7, "status": "abandoned" }, { "pullRequestId": 8, "status": "completed", "repository": { "project": { "id": "p" } } },
                      { "pullRequestId": 9, "status": "active", "lastMergeSourceCommit": { "commitId": "HEAD1" }, "repository": { "project": { "id": "pid-1" } } } ] }' | ConvertFrom-Json
                }
                else { '{ "value": [] }' | ConvertFrom-Json }
            }
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x' -AncheCompletate).Id | Should -Be 9
        }

        It '-AncheCompletate con solo PR abbandonate restituisce null' {
            Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [ { "pullRequestId": 7, "status": "abandoned" } ] }' | ConvertFrom-Json }
            Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x' -AncheCompletate | Should -BeNullOrEmpty
        }

        It 'approved vale verde' {
            Set-FintoPr @((Nuova-Valutazione 'approved' 100))
            $r = Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x'
            $r.Id | Should -Be 9
            $r.Stato | Should -Be 'active'
            $r.Validazione | Should -Be 'verde'
            $r.BuildId | Should -Be 100
            $r.UrlLog | Should -BeLike '*buildId=100'
        }

        It 'rejected vale rossa' {
            Set-FintoPr @((Nuova-Valutazione 'rejected' 101))
            $r = Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x'
            $r.Validazione | Should -Be 'rossa'
            $r.BuildId | Should -Be 101
        }

        It 'queued e running valgono inCorso' {
            foreach ($s in 'queued', 'running') {
                Set-FintoPr @((Nuova-Valutazione $s $null))
                (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'inCorso'
            }
        }

        It 'senza policy di build applicabili e senza conflitti la PR e unibile: vale verde' {
            Set-FintoPr @((Nuova-Valutazione 'approved' 1 'HEAD1' 'Minimum number of reviewers'))
            $r = Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x'
            $r.Validazione | Should -Be 'verde'
            $r.BuildId | Should -BeNullOrEmpty
            $r.UrlLog | Should -BeNullOrEmpty
        }

        It 'senza nessuna valutazione e senza conflitti vale verde' {
            Set-FintoPr @()
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'verde'
        }

        It 'con conflitti verso develop vale conflitti, anche con la build verde' {
            Set-FintoPr @((Nuova-Valutazione 'approved' 100)) 'conflicts'
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'conflitti'
        }

        It 'senza build e con il controllo di unione non ancora finito vale inCorso' {
            Set-FintoPr @() 'queued'
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'inCorso'
        }

        It 'una build verde di un commit precedente a quello di testa vale inCorso' {
            Set-FintoPr @((Nuova-Valutazione 'approved' 100 'VECCHIO'))
            $r = Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x'
            $r.Validazione | Should -Be 'inCorso'
        }

        It 'una build rossa di un commit precedente a quello di testa vale inCorso, non rossa' {
            Set-FintoPr @((Nuova-Valutazione 'rejected' 101 'VECCHIO'))
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'inCorso'
        }

        It 'broken vale rossa' {
            Set-FintoPr @((Nuova-Valutazione 'broken' 102))
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'rossa'
        }

        # D47: con la scadenza "subito" su develop, ogni merge in develop fa scadere le validazioni delle altre PR. ADO la
        # rimette in queued con context.isExpired: non e in corso, nessuno la rifa da solo.
        It 'una valutazione scaduta vale scaduta, non inCorso' {
            $v = Nuova-Valutazione 'queued' 100; $v.context | Add-Member isExpired $true
            Set-FintoPr @($v)
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'scaduta'
        }

        It 'scaduta prevale su verde, ma una in corso o una rossa prevalgono su scaduta' {
            $scaduta = Nuova-Valutazione 'queued' 100; $scaduta.context | Add-Member isExpired $true
            Set-FintoPr @($scaduta, (Nuova-Valutazione 'approved' 101))
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'scaduta'
            Set-FintoPr @($scaduta, (Nuova-Valutazione 'rejected' 102))
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'rossa'
            Set-FintoPr @($scaduta, (Nuova-Valutazione 'running' 103))
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'inCorso'
        }

        It 'una valutazione di build senza context vale inCorso senza rompersi' {
            Set-FintoPr @([pscustomobject]@{ status = 'queued'; configuration = [pscustomobject]@{ type = [pscustomobject]@{ displayName = 'Build' } } })
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'inCorso'
        }

        It 'un contesto senza buildId vale inCorso senza rompersi' {
            Set-FintoPr @([pscustomobject]@{ status = 'queued'; configuration = [pscustomobject]@{ type = [pscustomobject]@{ displayName = 'Build' } }
                context = [pscustomobject]@{} })
            (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').Validazione | Should -Be 'inCorso'
        }
    }


    It 'Get-AdoCardAttive scarta le card rimosse' {
        $global:FxWi = $script:WiJson.Replace('"System.State": "' + $global:FxSt.pronto + '"', '"System.State": "' + $global:FxSt.rimossa + '"')
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Method -eq 'Post') { '{ "workItems": [ { "id": 42 } ] }' | ConvertFrom-Json } else { $global:FxWi | ConvertFrom-Json }
        }
        @(Get-AdoCardAttive).Count | Should -Be 0
    }

    It 'Chi di Get-AdoStoriaStato e confrontabile con Id di Get-AdoUtenteCorrente' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*connectionData*') { '{ "authenticatedUser": { "id": "guid-1", "providerDisplayName": "Paolo Rossi" } }' | ConvertFrom-Json }
            else { ('{ "value": [ { "rev": 1, "fields": { "System.State": "' + $global:FxSt.bozza + '", "System.ChangedBy": { "displayName": "Rossi Paolo - Acme S.p.A.", "id": "guid-1" }, "System.ChangedDate": "d" } } ] }') | ConvertFrom-Json }
        }
        $utente = Get-AdoUtenteCorrente
        @(Get-AdoStoriaStato -Id 2)[0].Chi | Should -Be $utente.Id
    }

    It 'Set-AdoCard -TogliTag sull ultimo tag svuota il campo con una op remove' {
        $global:FxWi = $script:WiJson.Replace('"System.Tags": "' + $global:FxSt.tagAgenti + '; ' + $global:FxSt.tagAttesa + '"', '"System.Tags": "' + $global:FxSt.tagAgenti + '"')
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Method -eq 'Get') { $global:FxWi | ConvertFrom-Json } else { '{ "id": 42, "rev": 9 }' | ConvertFrom-Json }
        }
        Set-AdoCard -Id 42 -TogliTag $global:FxSt.tagAgenti -Stato $global:FxSt.bozza | Should -Be 9
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Body -like '*"op":"remove","path":"/fields/System.Tags"*' -and
            $Body -notlike '*"path":"/fields/System.Tags","value"*' }
    }

    It 'Set-AdoCard -TogliTag toglie un tag e lascia gli altri, anche insieme a -Stato' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Method -eq 'Get') { $global:FxWi | ConvertFrom-Json } else { '{ "id": 42, "rev": 9 }' | ConvertFrom-Json }
        }
        Set-AdoCard -Id 42 -TogliTag $global:FxSt.tagAgenti -Stato $global:FxSt.bozza | Should -Be 9
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Body -like "*`"op`":`"replace`",`"path`":`"/fields/System.Tags`",`"value`":`"$($global:FxSt.tagAttesa)`"*" -and
            $Body -like "*`"path`":`"/fields/System.State`",`"value`":`"$($global:FxSt.bozza)`"*" }
    }

    It 'un errore HTTP riporta il corpo della risposta, ripulito dal PAT' {
        Mock Invoke-RestMethod -ModuleName Ado {
            $er = [System.Management.Automation.ErrorRecord]::new([Exception]::new('Response status code does not indicate success: 403 (Forbidden).'), 'x', 'NotSpecified', $null)
            $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"message":"TF401019: scope mancante SEGRETO-FINTO"}')
            throw $er
        }
        $msg = try { Get-AdoCard -Id 1; '' } catch { $_.Exception.Message }
        $msg | Should -BeLike '*403*'
        $msg | Should -BeLike '*TF401019*'
        $msg | Should -Not -BeLike '*SEGRETO-FINTO*'
    }

    It 'ogni chiamata REST ha un tempo massimo di 30 secondi' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 1, "rev": 2, "value": [], "comments": [], "fields": {} }' | ConvertFrom-Json }
        Get-AdoCard -Id 1 | Out-Null
        Set-AdoCard -Id 1 -Stato 'x' | Out-Null
        Get-AdoCommenti -Id 1 | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 3 -Exactly -ParameterFilter { $TimeoutSec -eq 30 }
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 0 -Exactly -ParameterFilter { $TimeoutSec -ne 30 }
    }

    It 'Get-AdoStoriaStato legge tutte le pagine delle revisioni' {
        # 203 revisioni: lo stato cambia a ogni revisione, l'ultimo cambio e' alla 203 (terza pagina parziale)
        Mock Invoke-RestMethod -ModuleName Ado {
            $skip = if ($Uri -match '[$]skip=(\d+)') { [int]$Matches[1] } else { 0 }
            $fine = [Math]::Min($skip + 200, 203)
            $v = foreach ($n in ($skip + 1)..$fine) {
                [pscustomobject]@{ rev = $n; fields = [pscustomobject]@{ 'System.State' = "S$n"
                    'System.ChangedBy' = [pscustomobject]@{ displayName = 'A' }; 'System.ChangedDate' = 'd' } }
            }
            [pscustomobject]@{ value = @($v) }
        }
        $s = @(Get-AdoStoriaStato -Id 42)
        $s.Count | Should -Be 203
        $s[-1].Rev | Should -Be 203
        $s[-1].A | Should -Be 'S203'
    }

    It 'Get-AdoCommenti legge tutte le pagine seguendo il continuationToken' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*continuationToken=TOK2*') {
                '{ "comments": [ { "id": 3, "text": "c", "createdBy": { "displayName": "Z" }, "createdDate": "d" } ] }' | ConvertFrom-Json
            }
            else {
                '{ "continuationToken": "TOK2", "comments": [ { "id": 1, "text": "a", "createdBy": { "displayName": "Z" }, "createdDate": "d" }, { "id": 2, "text": "b", "createdBy": { "displayName": "Z" }, "createdDate": "d" } ] }' | ConvertFrom-Json
            }
        }
        $c = @(Get-AdoCommenti -Id 42)
        $c.Count | Should -Be 3
        $c[-1].Id | Should -Be 3
        @(Get-AdoCommenti -Id 42 -DopoId 2).Count | Should -Be 1
    }

    It 'nessuna funzione scrive il PAT in un messaggio di errore' {
        Mock Invoke-RestMethod -ModuleName Ado { throw 'Unauthorized: Authorization: Basic SEGRETO-FINTO; token SEGRETO-FINTO' }
        $chiamate = @(
            { Get-AdoCard -Id 1 }, { Get-AdoCardAttive }, { Set-AdoCard -Id 1 -Stato 'x' }, { Get-AdoStoriaStato -Id 1 },
            { Get-AdoCommenti -Id 1 }, { Add-AdoCommento -Id 1 -Testo 't' }, { Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'r' },
            { New-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'r' -Titolo 't' -Descrizione 'd' -CardId 1 },
            { Complete-AdoPr -Progetto 'P' -Repo 'R' -Id 1 }, { Start-AdoDeployTest -Progetto 'P' -PipelineId 1 -Ramo 'r' -Parametri 'p' }, { Get-AdoParametriDeploy -Progetto 'P' -PipelineId 1 -Ramo 'r' },
            { Get-AdoRamoCard -Progetto 'P' -Repo 'R' -CardId 1 },
            { Get-AdoRun -Progetto 'P' -RunId 1 }, { Get-AdoUtenteCorrente }
        )
        foreach ($c in $chiamate) {
            $msg = try { & $c; '' } catch { $_.Exception.Message }
            $msg | Should -Not -BeNullOrEmpty
            $msg | Should -Not -BeLike '*SEGRETO-FINTO*'
        }
    }
}

Describe 'Get-AdoUrlCard' {
    It 'il link alla card sta qui: organizzazione, progetto della board, id' {
        Get-AdoUrlCard -Id 5 | Should -Be 'https://acme.visualstudio.com/DevOps.Agents/_workitems/edit/5'
    }
    It 'con un progetto dato lo codifica' {
        Get-AdoUrlCard -Id 7 -Progetto 'Il Mio Progetto' | Should -Be 'https://acme.visualstudio.com/Il%20Mio%20Progetto/_workitems/edit/7'
    }
}

Describe 'Ado: task figli della card' {
    BeforeEach {
        Mock Get-AdoIntestazione -ModuleName Ado { @{ Authorization = 'Basic SEGRETO-FINTO' } }
    }

    It 'New-AdoTask crea un Task figlio della card, con la stessa area, e lo restituisce tradotto' {
        Mock Invoke-RestMethod -ModuleName Ado {
            '{ "id": 61, "rev": 1, "fields": { "System.WorkItemType": "Task", "System.Title": "Primo", "System.Description": "testo", "System.State": "New" } }' | ConvertFrom-Json }
        $t = New-AdoTask -CardId 42 -Titolo 'Primo' -Descrizione 'testo' -Area 'DevOps.Agents\AI\Stime'
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -like 'https://acme.visualstudio.com/DevOps.Agents/_apis/wit/workitems/$Task?*' -and
            $ContentType -eq 'application/json-patch+json' -and
            $Body -like '*"path":"/fields/System.Title","value":"Primo"*' -and
            $Body -like '*"path":"/fields/System.Description","value":"testo"*' -and
            $Body -like '*"path":"/multilineFieldsFormat/System.Description","value":"Markdown"*' -and
            $Body -like '*"path":"/fields/System.AreaPath","value":"DevOps.Agents\\AI\\Stime"*' -and
            $Body -like '*"path":"/relations/-"*' -and
            $Body -like '*"rel":"System.LinkTypes.Hierarchy-Reverse"*' -and
            $Body -like '*"url":"https://acme.visualstudio.com/_apis/wit/workItems/42"*' -and
            $Body -notlike '*System.State*' }
        $t.Id | Should -Be 61
        $t.Titolo | Should -Be 'Primo'
        $t.Descrizione | Should -Be 'testo'
        $t.Stato | Should -Be 'New'
    }

    It 'Get-AdoTaskFigli legge le relazioni verso i figli e restituisce i Task in ordine di id, scartando gli altri figli' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*workitems/42?*') {
                '{ "id": 42, "rev": 3, "fields": {}, "relations": [
                    { "rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://acme.visualstudio.com/_apis/wit/workItems/10" },
                    { "rel": "System.LinkTypes.Hierarchy-Forward", "url": "https://acme.visualstudio.com/_apis/wit/workItems/63" },
                    { "rel": "System.LinkTypes.Hierarchy-Forward", "url": "https://acme.visualstudio.com/_apis/wit/workItems/61" },
                    { "rel": "System.LinkTypes.Hierarchy-Forward", "url": "https://acme.visualstudio.com/_apis/wit/workItems/70" } ] }' | ConvertFrom-Json
            }
            else {
                '{ "count": 3, "value": [
                    { "id": 70, "fields": { "System.WorkItemType": "Bug", "System.Title": "Altro", "System.State": "New" } },
                    { "id": 63, "fields": { "System.WorkItemType": "Task", "System.Title": "Secondo", "System.Description": "d2", "System.State": "Closed" } },
                    { "id": 61, "fields": { "System.WorkItemType": "Task", "System.Title": "Primo", "System.Description": "d1", "System.State": "New" } } ] }' | ConvertFrom-Json
            }
        }
        $t = @(Get-AdoTaskFigli -CardId 42)
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and $Uri -like '*workitems/42?*expand=relations*' }
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and $Uri -like '*_apis/wit/workitems?ids=61,63,70&*' }
        $t.Count | Should -Be 2
        $t[0].Id | Should -Be 61
        $t[0].Titolo | Should -Be 'Primo'
        $t[0].Stato | Should -Be 'New'
        $t[1].Id | Should -Be 63
        $t[1].Descrizione | Should -Be 'd2'
        $t[1].Stato | Should -Be 'Closed'
    }

    It 'Get-AdoTaskFigli su una card senza figli non chiede altro e restituisce un elenco vuoto' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 42, "rev": 3, "fields": {} }' | ConvertFrom-Json }
        @(Get-AdoTaskFigli -CardId 42).Count | Should -Be 0
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly
    }

    It 'Set-AdoTaskStato scrive solo lo stato e restituisce la nuova rev' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 61, "rev": 4 }' | ConvertFrom-Json }
        Set-AdoTaskStato -Id 61 -Stato 'Closed' | Should -Be 4
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Uri -like 'https://acme.visualstudio.com/_apis/wit/workitems/61?*' -and
            $ContentType -eq 'application/json-patch+json' -and
            $Body -like '*"path":"/fields/System.State","value":"Closed"*' }
    }

    It 'le funzioni dei task non scrivono il PAT in un messaggio di errore' {
        Mock Invoke-RestMethod -ModuleName Ado { throw 'Unauthorized: Authorization: Basic SEGRETO-FINTO' }
        foreach ($c in @({ New-AdoTask -CardId 1 -Titolo 't' -Descrizione 'd' -Area 'P\A' }, { Get-AdoTaskFigli -CardId 1 }, { Set-AdoTaskStato -Id 1 -Stato 'x' })) {
            $msg = try { & $c; '' } catch { $_.Exception.Message }
            $msg | Should -Not -BeNullOrEmpty
            $msg | Should -Not -BeLike '*SEGRETO-FINTO*'
        }
    }
}


Describe 'Get-AdoUrlPr' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot '../src/Ado.psm1') -Force }
    It 'da il link alla pagina della PR, con progetto e repo codificati' {
        Get-AdoUrlPr -Progetto 'Progetto Uno' -Repo 'Repo Due' -Id 9 | Should -Be 'https://acme.visualstudio.com/Progetto%20Uno/_git/Repo%20Due/pullrequest/9'
    }
}

Describe 'Ado: il PAT' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot '../src/Ado.psm1') -Force }

    It 'Get-AdoIntestazione manda il PAT letto da Read-FilePat come Basic' {
        Mock Read-FilePat -ModuleName Ado { 'pat-finto' }
        $h = & (Get-Module Ado) { Get-AdoIntestazione }
        $h.Authorization | Should -Be ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':pat-finto')))
    }

    It 'senza PAT dice di rilanciare -Pat, senza altro nel messaggio' {
        Mock Read-FilePat -ModuleName Ado { '' }
        { & (Get-Module Ado) { Get-AdoIntestazione } } | Should -Throw '*Install-Attrezzi.ps1 -Pat*'
    }

    It 'una risposta 401 da un messaggio chiaro: PAT scaduto o revocato, rilancia -Pat' {
        Mock Get-AdoIntestazione -ModuleName Ado { @{ Authorization = 'Basic SEGRETO-FINTO' } }
        Mock Invoke-RestMethod -ModuleName Ado {
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 401 (Unauthorized).', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Unauthorized))
        }
        $msg = try { Get-AdoCard -Id 1; '' } catch { $_.Exception.Message }
        $msg | Should -Match 'PAT scaduto o revocato'
        $msg | Should -Match 'Install-Attrezzi.ps1 -Pat'
        $msg | Should -Not -Match 'SEGRETO-FINTO'
    }
}

# D43: i parametri che il responsabile puo scegliere per il deploy in Test sono i booleani deploy* dello YAML della pipeline,
# letto sul ramo: il percorso dalla definizione della pipeline, il contenuto dal repo.
Describe 'Ado: i parametri del deploy in Test' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/Ado.psm1') -Force
        $script:YamlPieno = @"
trigger: none

parameters:
  - name: deployForms
    displayName: 'Deploy Forms'
    type: boolean
    default: false
  - name: deployDatabases # il DACPAC
    type: boolean
    default: false
  - name: allowDatabaseDataLoss
    type: boolean
    default: false
  - name: forceRedeploy
    type: boolean
  - name: deployTarget
    type: string
    default: auto
    values:
      - auto
      - name
  - name: "deployApi"
    type: 'boolean'
  - type: boolean
    name: deployWorker

variables:
  - name: deployFinto
    value: true
  - name: deployVariabile
    type: boolean

stages:
- stage: Deploy
  jobs:
  - job: X
"@
    }
    AfterAll { Remove-Variable FxYaml -Scope Global -ErrorAction SilentlyContinue }
    BeforeEach {
        $global:FxYaml = $script:YamlPieno
        Mock Get-AdoIntestazione -ModuleName Ado { @{ Authorization = 'Basic SEGRETO-FINTO' } }
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*/_apis/pipelines/58?*') {
                '{ "id": 58, "configuration": { "type": "yaml", "path": "/azure-pipelines/deploy.yml", "repository": { "id": "repo-guid", "type": "azureReposGit" } } }' | ConvertFrom-Json
            }
            elseif ($Uri -like '*/_apis/git/repositories/repo-guid/items?*') { [pscustomobject]@{ path = '/azure-pipelines/deploy.yml'; content = $global:FxYaml } }
            else { throw "chiamata inattesa: $Uri" }
        }
    }

    It 'restituisce i booleani il cui nome comincia con deploy, nell ordine dello YAML' {
        @(Get-AdoParametriDeploy -Progetto 'Acme.Workflow' -PipelineId 58 -Ramo 'feature/11-x') | Should -Be @('deployForms', 'deployDatabases', 'deployApi', 'deployWorker')
    }

    It 'legge lo YAML dal percorso e dal repo della definizione, sul ramo dato' {
        [void](Get-AdoParametriDeploy -Progetto 'Acme.Workflow' -PipelineId 58 -Ramo 'feature/11-x')
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and $Uri -like 'https://acme.visualstudio.com/Acme.Workflow/_apis/git/repositories/repo-guid/items?*' -and
            $Uri -like '*path=%2Fazure-pipelines%2Fdeploy.yml*' -and $Uri -like '*versionDescriptor.version=feature%2F11-x*' -and
            $Uri -like '*versionDescriptor.versionType=branch*' -and $Uri -like '*includeContent=true*' }
    }

    It 'gli altri booleani restano esclusi, e cosi le variabili e i parametri non booleani' {
        $p = @(Get-AdoParametriDeploy -Progetto 'P' -PipelineId 58 -Ramo 'develop')
        $p | Should -Not -Contain 'allowDatabaseDataLoss'
        $p | Should -Not -Contain 'forceRedeploy'
        $p | Should -Not -Contain 'deployTarget'
        $p | Should -Not -Contain 'deployFinto'
        $p | Should -Not -Contain 'deployVariabile'
    }

    It 'la sezione parameters puo avere gli elementi a inizio riga, e righe con a capo di Windows' {
        $global:FxYaml = "parameters:`r`n- name: deployForms`r`n  type: boolean`r`n- name: confirmProductionDatabasePublish`r`n  type: boolean`r`nstages: []`r`n"
        @(Get-AdoParametriDeploy -Progetto 'P' -PipelineId 58 -Ramo 'develop') | Should -Be @('deployForms')
    }

    It 'uno YAML con il BOM in testa si legge lo stesso' {
        $global:FxYaml = [string][char]0xFEFF + "parameters:`n- name: deployForms`n  type: boolean`n"
        @(Get-AdoParametriDeploy -Progetto 'P' -PipelineId 58 -Ramo 'develop') | Should -Be @('deployForms')
    }

    It 'conta solo il type al rientro delle chiavi del parametro, non uno annidato nel default' {
        $global:FxYaml = @"
parameters:
  - name: deployOggetto
    default:
      type: boolean
      name: x
    type: object
  - name: deployVero
    displayName: Vero
    type: boolean
"@
        @(Get-AdoParametriDeploy -Progetto 'P' -PipelineId 58 -Ramo 'develop') | Should -Be @('deployVero')
    }

    It 'uno YAML senza parameters da un elenco vuoto' {
        $global:FxYaml = "trigger: none`nstages: []`n"
        @(Get-AdoParametriDeploy -Progetto 'P' -PipelineId 58 -Ramo 'develop').Count | Should -Be 0
    }

    It 'una definizione senza il percorso dello YAML da un errore che lo dice' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 58, "configuration": { "type": "designerJson" } }' | ConvertFrom-Json }
        { Get-AdoParametriDeploy -Progetto 'P' -PipelineId 58 -Ramo 'develop' } | Should -Throw '*58*YAML*'
    }
}

Describe 'Ado: il ramo della card su origin' {
    BeforeEach {
        Mock Get-AdoIntestazione -ModuleName Ado { @{ Authorization = 'Basic SEGRETO-FINTO' } }
    }

    It 'trova il ramo feature/11-... o fix/11-..., non quello di un altra card con lo stesso inizio' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*filter=heads%2Ffeature%2F11*') { '{ "value": [ { "name": "refs/heads/feature/110-altra" }, { "name": "refs/heads/feature/11-schema" } ] }' | ConvertFrom-Json }
            else { '{ "value": [] }' | ConvertFrom-Json }
        }
        Get-AdoRamoCard -Progetto 'Acme.Workflow' -Repo 'Acme.Workflow' -CardId 11 | Should -Be 'feature/11-schema'
    }

    It 'D52: con -FeatureId trova il ramo della funzionalita (feature/f7-... o bugfix/f7-...), non quello di una card ne di un altra Feature' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*filter=heads%2Ffeature%2Ff7*') { '{ "value": [ { "name": "refs/heads/feature/f70-altra" }, { "name": "refs/heads/feature/f7-filtro" } ] }' | ConvertFrom-Json }
            else { '{ "value": [] }' | ConvertFrom-Json }
        }
        Get-AdoRamoCard -Progetto 'P' -Repo 'R' -FeatureId 7 | Should -Be 'feature/f7-filtro'
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*filter=heads%2Fbugfix%2Ff7*') { '{ "value": [ { "name": "refs/heads/bugfix/f7-errore" } ] }' | ConvertFrom-Json }
            else { '{ "value": [ { "name": "refs/heads/feature/7-card-con-id-7" } ] }' | ConvertFrom-Json }
        }
        Get-AdoRamoCard -Progetto 'P' -Repo 'R' -FeatureId 7 | Should -Be 'bugfix/f7-errore'
    }

    It 'D52: -FeatureId senza ramo pubblicato da null, con due rami errore' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [] }' | ConvertFrom-Json }
        Get-AdoRamoCard -Progetto 'P' -Repo 'R' -FeatureId 7 | Should -BeNullOrEmpty
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*feature*') { '{ "value": [ { "name": "refs/heads/feature/f7-a" } ] }' | ConvertFrom-Json }
            else { '{ "value": [ { "name": "refs/heads/bugfix/f7-b" } ] }' | ConvertFrom-Json }
        }
        { Get-AdoRamoCard -Progetto 'P' -Repo 'R' -FeatureId 7 } | Should -Throw '*feature/f7-a*bugfix/f7-b*'
    }

    It 'nessun ramo pubblicato: null' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [ { "name": "refs/heads/fix/112-x" } ] }' | ConvertFrom-Json }
        Get-AdoRamoCard -Progetto 'P' -Repo 'R' -CardId 11 | Should -BeNullOrEmpty
    }

    It 'piu di un ramo della card: errore, quale usare lo decide una persona' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*feature*') { '{ "value": [ { "name": "refs/heads/feature/11-a" } ] }' | ConvertFrom-Json }
            else { '{ "value": [ { "name": "refs/heads/fix/11-b" } ] }' | ConvertFrom-Json }
        }
        { Get-AdoRamoCard -Progetto 'P' -Repo 'R' -CardId 11 } | Should -Throw '*feature/11-a*fix/11-b*'
    }
}

Describe 'Get-AdoBuildPipeline: i run di tutti i progetti' {
    BeforeAll {
        $script:Adesso = [datetime]::Parse('2026-11-20T12:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        function global:New-Risposta([string]$Json) { $Json | ConvertFrom-Json }
    }
    BeforeEach {
        $global:Chiamate = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod -ModuleName Ado {
            $u = $Uri.OriginalString; $global:Chiamate.Add($u)
            if ($Method -ne 'Get') { throw "scrittura non ammessa: $Method" }
            switch -Wildcard ($u) {
                '*/_apis/projects?*' { New-Risposta '{ "value": [ { "name": "Alfa" }, { "name": "Beta" }, { "name": "Con Spazio" } ] }' }
                '*/Alfa/_apis/build/builds/10/timeline*' { New-Risposta '{ "records": [ { "id": "s1", "type": "Stage", "name": "Build", "state": "completed" }, { "id": "s2", "type": "Stage", "name": "DeployProd", "state": "pending" }, { "id": "c1", "parentId": "s2", "type": "Checkpoint", "name": "Checkpoint", "state": "inProgress" }, { "id": "a1", "parentId": "c1", "type": "Checkpoint.Approval", "name": "Approval", "state": "inProgress" } ] }' }
                '*/Alfa/_apis/build/builds/30/timeline*' { New-Risposta '{ "records": [ { "id": "s2", "type": "Stage", "name": "Prod", "state": "pending" }, { "id": "c1", "parentId": "s2", "type": "Checkpoint", "state": "inProgress" }, { "id": "a1", "parentId": "c1", "type": "Checkpoint.Approval", "state": "inProgress" } ] }' }
                '*/Alfa/_apis/build/definitions*' { New-Risposta '{ "value": [ { "id": 115, "name": "Alfa release-orchestrator" }, { "id": 116, "name": "altra-cosa" } ] }' }
                '*/Alfa/_apis/build/builds?definitions=115*' { New-Risposta '{ "value": [
                    { "id": 30, "status": "inProgress", "queueTime": "2026-11-20T11:00:00Z", "startTime": "2026-11-20T11:01:00Z", "sourceBranch": "refs/heads/release/1.2", "definition": { "name": "Alfa release-orchestrator" }, "requestedFor": { "displayName": "Mario Rossi" }, "templateParameters": { "deployApi": "true", "deployWeb": "false", "forceRedeploy": "true" } },
                    { "id": 31, "status": "completed", "result": "succeeded", "queueTime": "2026-11-19T09:00:00Z", "finishTime": "2026-11-19T09:30:00Z", "sourceBranch": "refs/heads/release/1.1", "definition": { "name": "Alfa release-orchestrator" }, "templateParameters": { "deployWeb": "true" } } ] }' }
                '*/Alfa/_apis/build/builds/11/timeline*' { New-Risposta '{ "records": [ { "id": "s0", "type": "Stage", "name": "__default", "state": "inProgress" }, { "id": "s1", "type": "Stage", "name": "Test", "state": "inProgress" }, { "id": "j1", "parentId": "s1", "type": "Job", "name": "Build", "state": "inProgress", "workerName": "acme-sh-agent" } ] }' }
                '*/_apis/distributedtask/pools/9/jobrequests*' { New-Risposta '{ "value": [
                    { "requestId": 1, "queueTime": "2026-11-20T10:00:00Z", "assignTime": "2026-11-20T10:01:00Z", "owner": { "id": 99 } },
                    { "requestId": 3, "queueTime": "2026-11-20T11:55:00Z", "owner": { "id": 12 } },
                    { "requestId": 2, "queueTime": "2026-11-20T11:20:00Z", "owner": { "id": 15 } } ] }' }
                '*/_apis/distributedtask/pools/9/agents*' { New-Risposta '{ "value": [
                    { "name": "sh-2", "status": "offline", "enabled": true },
                    { "name": "sh-1", "status": "online", "enabled": true, "assignedRequest": { "requestId": 1, "owner": { "id": 99, "_links": { "web": { "href": "https://acme.visualstudio.com/Alfa/_build/results?buildId=99" } } }, "definition": { "name": "api pr-validation" } } } ] }' }
                '*/_apis/distributedtask/pools?api-version*' { New-Risposta '{ "value": [ { "id": 9, "name": "acme-internal", "isHosted": false } ] }' }
                '*/Alfa/_apis/build/builds/16/timeline*' { New-Risposta '{ "records": [ { "id": "s1", "type": "Stage", "name": "Deploy", "state": "pending", "order": 2 }, { "id": "c1", "parentId": "s1", "type": "Checkpoint", "state": "inProgress" }, { "id": "t1", "parentId": "c1", "type": "Checkpoint.TaskCheck", "state": "inProgress" } ] }' }
                '*/Alfa/_apis/build/builds/15/timeline*' { New-Risposta '{ "records": [ { "id": "s1", "type": "Stage", "name": "Branch coordinated deploy", "state": "inProgress" }, { "id": "p1", "parentId": "s1", "type": "Phase", "name": "Deploy", "state": "pending" }, { "id": "j1", "parentId": "p1", "type": "Job", "name": "Resolve and deploy", "state": "pending" } ] }' }
                '*/Alfa/_apis/build/builds/14/timeline*' { New-Risposta '{ "records": [ { "id": "s0", "type": "Stage", "name": "__default", "state": "inProgress" }, { "id": "j1", "parentId": "s0", "type": "Job", "name": "Compila", "state": "inProgress" } ] }' }
                '*/Alfa/_apis/build/builds/13/timeline*' { New-Risposta '{ "records": [ { "id": "s1", "type": "Stage", "name": "Manual release approval", "state": "inProgress" }, { "id": "j1", "parentId": "s1", "type": "Job", "name": "Confirm", "state": "inProgress" }, { "id": "t1", "parentId": "j1", "type": "Task", "name": "ManualValidation", "state": "inProgress", "task": { "name": "ManualValidation" } } ] }' }
                '*/Alfa/_apis/build/builds?statusFilter=inProgress*' { New-Risposta '{ "value": [
                    { "id": 10, "status": "inProgress", "queueTime": "2026-11-20T10:00:00Z", "startTime": "2026-11-20T10:01:00Z", "sourceBranch": "refs/heads/develop", "definition": { "name": "deploy" }, "requestedFor": { "displayName": "Mario Rossi" } },
                    { "id": 11, "status": "inProgress", "queueTime": "2026-11-20T11:00:00Z", "startTime": "2026-11-20T11:30:00Z", "sourceBranch": "refs/heads/feature/x", "definition": { "name": "build-ci" }, "requestedFor": { "displayName": "Anna" }, "queue": { "name": "Interno", "pool": { "name": "Interno", "isHosted": false } } },
                    { "id": 13, "status": "inProgress", "queueTime": "2026-11-20T11:40:00Z", "startTime": "2026-11-20T11:41:00Z", "sourceBranch": "refs/heads/develop", "definition": { "name": "rilascio" } },
                    { "id": 14, "status": "inProgress", "queueTime": "2026-11-20T11:45:00Z", "startTime": "2026-11-20T11:46:00Z", "sourceBranch": "refs/heads/develop", "definition": { "name": "senza-stage" } },
                    { "id": 16, "status": "inProgress", "queueTime": "2026-11-20T11:35:00Z", "startTime": "2026-11-20T11:36:00Z", "sourceBranch": "refs/heads/develop", "definition": { "name": "con-lock" } },
                    { "id": 15, "status": "inProgress", "queueTime": "2026-11-20T11:30:00Z", "startTime": "2026-11-20T11:31:00Z", "sourceBranch": "refs/heads/develop", "definition": { "name": "rilascio-a-job" } },
                    { "id": 12, "status": "notStarted", "queueTime": "2026-11-20T11:50:00Z", "sourceBranch": "refs/pull/7/merge", "definition": { "name": "build-ci" } } ] }' }
                '*/Alfa/_apis/build/builds?statusFilter=completed*' { New-Risposta '{ "value": [
                    { "id": 20, "status": "completed", "result": "failed", "queueTime": "2026-11-20T08:00:00Z", "startTime": "2026-11-20T08:01:00Z", "finishTime": "2026-11-20T08:20:00Z", "sourceBranch": "refs/heads/develop", "definition": { "name": "build-ci" }, "requestedFor": { "displayName": "Mario Rossi" } },
                    { "id": 21, "status": "completed", "result": "canceled", "queueTime": "2026-11-20T09:00:00Z", "finishTime": "2026-11-20T09:05:00Z", "sourceBranch": "refs/heads/x", "definition": { "name": "build-ci" } } ] }' }
                '*/Beta/*' { throw 'HTTP 403' }
                '*/Con%20Spazio/_apis/build/builds?*' { New-Risposta '{ "value": [] }' }
                default { throw "url inattesa: $u" }
            }
        }
        $script:R = Get-AdoBuildPipeline -Adesso $script:Adesso
    }

    It 'conta i run in corso, in coda, in attesa di approvazione e i falliti (non gli annullati)' {
        $R.InCorso | Should -Be 2
        $R.InCoda | Should -Be 3   # il 12 non partito, il 15 con il job che aspetta un agente, il 16 fermo su un controllo
        $R.InAttesa | Should -Be 3   # il run 10, il 13 (ManualValidation) e l'orchestratore 30
        $R.NumFalliti | Should -Be 1
        @($R.Falliti).Count | Should -Be 2
    }

    It 'mette i release-orchestrator in un blocco proprio: componenti deploy* a true, stage, approvazione, esito' {
        @($R.Orchestratori).Count | Should -Be 2
        $o = $R.Orchestratori | Where-Object Id -eq 30
        $o.Stato | Should -Be 'inAttesa'; $o.Fase | Should -Be 'Prod'; $o.Ramo | Should -Be 'release/1.2'
        @($o.Componenti) | Should -Be @('deployApi')          # forceRedeploy non e un componente, deployWeb e false
        ($R.Orchestratori | Where-Object Id -eq 31).Esito | Should -Be 'succeeded'
        $R.Orchestratori[0].Id | Should -Be 30                  # prima gli attivi
        @($R.Attivi | Where-Object Id -in 30, 31).Count | Should -Be 0   # non si ripetono fra gli altri run
    }

    It 'dice la fase dei run in corso e quella che aspetta l approvazione' {
        ($R.Attivi | Where-Object Id -eq 10).Stato | Should -Be 'inAttesa'
        ($R.Attivi | Where-Object Id -eq 10).Fase | Should -Be 'DeployProd'
        ($R.Attivi | Where-Object Id -eq 11).Fase | Should -Be 'Test'
        ($R.Attivi | Where-Object Id -eq 14).Fase | Should -Be 'Compila'   # lo stage implicito __default non si mostra
        ($R.Attivi | Where-Object Id -eq 12).Stato | Should -Be 'inCoda'
        # partito ma con il solo job in attesa di un agente: e in coda, e la fase dice quale job aspetta
        ($R.Attivi | Where-Object Id -eq 15).Stato | Should -Be 'inCoda'
        ($R.Attivi | Where-Object Id -eq 15).Fase | Should -Be 'Resolve and deploy'
        ($R.Attivi | Where-Object Id -eq 15).Attende | Should -Be 'agente'
        # fermo su un controllo dell'environment (lock esclusivo) senza job che girano: non occupa un agente, e in coda
        ($R.Attivi | Where-Object Id -eq 16).Stato | Should -Be 'inCoda'
        ($R.Attivi | Where-Object Id -eq 16).Attende | Should -Be 'controllo'
        ($R.Attivi | Where-Object Id -eq 16).Fase | Should -Be 'Deploy'
        # la posizione in coda e quella di ADO: le richieste non ancora assegnate del pool, in ordine di accodamento
        ($R.Attivi | Where-Object Id -eq 15).PosizioneCoda | Should -Be 1
        ($R.Attivi | Where-Object Id -eq 12).PosizioneCoda | Should -Be 2
        ($R.Attivi | Where-Object Id -eq 12).PoolCoda | Should -Be 'acme-internal'
        # l'agente di un run in coda e il pool in cui aspetta (interno, non ospitato), non una stima
        ($R.Attivi | Where-Object Id -eq 12).Agente | Should -Be 'interno'
        ($R.Attivi | Where-Object Id -eq 12).Pool | Should -Be 'acme-internal'
        ($R.Attivi | Where-Object Id -eq 12).AgenteStimato | Should -BeFalse
        # un task ManualValidation in corso e un'attesa di una persona come l'approvazione, con lo stage che la chiede
        ($R.Attivi | Where-Object Id -eq 13).Stato | Should -Be 'inAttesa'
        ($R.Attivi | Where-Object Id -eq 13).Fase | Should -Be 'Manual release approval'
    }

    It 'porta progetto, pipeline, ramo senza refs/heads, autore, link al run e data in UTC' {
        $b = $R.Attivi | Where-Object Id -eq 11
        $b.Progetto | Should -Be 'Alfa'
        $b.Pipeline | Should -Be 'build-ci'
        $b.Ramo | Should -Be 'feature/x'
        $b.Autore | Should -Be 'Anna'
        $b.Url | Should -Be 'https://acme.visualstudio.com/Alfa/_build/results?buildId=11'
        $b.Inizio.ToUniversalTime().ToString('HH:mm') | Should -Be '11:30'
        ($R.Attivi | Where-Object Id -eq 12).Ramo | Should -Be 'PR #7'   # il ramo di una validazione di PR e la PR
        # l'agente e quello che esegue i job (workerName), non la coda del run ("queue": Interno nel mock)
        $b.Agente | Should -Be 'interno'; $b.Pool | Should -Be 'acme-sh-agent'; $b.AgenteStimato | Should -BeFalse
        ($R.Attivi | Where-Object Id -eq 10).Agente | Should -Be ''   # senza coda nella risposta: non si inventa
        ($R.Attivi | Where-Object Id -eq 12).Autore | Should -Be ''   # nessun requestedFor: non rompe
    }

    It 'un progetto che non risponde finisce in Errori e non ferma gli altri' {
        @($R.Errori).Count | Should -Be 1 -Because ($R.Errori -join ' | ')
        $R.Errori[0] | Should -BeLike 'Beta: *'
        @($R.Attivi).Count | Should -Be 7
    }

    It 'chiede i falliti con il filtro sulle ultime 24 ore e codifica il nome del progetto' {
        $global:Chiamate | Should -Contain 'https://acme.visualstudio.com/Alfa/_apis/build/builds?statusFilter=completed&resultFilter=failed,canceled&minTime=2026-11-19T12%3A00%3A00.0000000Z&$top=100&api-version=7.1'
        ($global:Chiamate | Where-Object { $_ -like '*/Con%20Spazio/_apis/build/builds?*' }).Count | Should -Be 2
    }

    It 'riconosce gli agenti dai nomi dei job: Microsoft-hosted e cloud, un nome nostro e interno, tutti e due misto' {
        InModuleScope Ado {
            (Get-AgenteDaLavoratori @('Azure Pipelines 3')).Agente | Should -Be 'cloud'
            (Get-AgenteDaLavoratori @('Hosted Agent')).Agente | Should -Be 'cloud'
            (Get-AgenteDaLavoratori @('acme-sh-agent')).Agente | Should -Be 'interno'
            $m = Get-AgenteDaLavoratori @('acme-sh-agent', 'Azure Pipelines 1')
            $m.Agente | Should -Be 'misto'; $m.Nome | Should -Be 'acme-sh-agent, Microsoft-hosted'
            (Get-AgenteDaLavoratori @()).Agente | Should -Be ''
        }
    }

    It 'il tipo del run: rilascio, pr, ci, pianificato, manuale' {
        InModuleScope Ado {
            Get-TipoRun 'X release-orchestrator' 'manual' $false | Should -Be 'rilascio'
            Get-TipoRun 'qualunque' 'manual' $true | Should -Be 'rilascio'
            Get-TipoRun 'Api - pr-validation' 'pullRequest' $false | Should -Be 'pr'
            Get-TipoRun 'Api - build-ci' 'manual' $false | Should -Be 'ci'
            Get-TipoRun 'Ingest' 'batchedCI' $false | Should -Be 'ci'
            Get-TipoRun 'notturna' 'schedule' $false | Should -Be 'pianificato'
            Get-TipoRun 'prova' 'manual' $false | Should -Be 'manuale'
        }
    }

    It 'legge gli agenti dei pool interni: stato e lavoro in corso, in ordine di nome' {
        @($R.AgentiPool).Count | Should -Be 1
        $R.AgentiPool[0].Pool | Should -Be 'acme-internal'
        @($R.AgentiPool[0].Agenti | ForEach-Object Nome) | Should -Be @('sh-1', 'sh-2')
        $a = $R.AgentiPool[0].Agenti[0]
        $a.Online | Should -BeTrue
        $a.Lavoro.BuildId | Should -Be 99
        $a.Lavoro.Pipeline | Should -Be 'api pr-validation'
        $a.Lavoro.Url | Should -Be 'https://acme.visualstudio.com/Alfa/_build/results?buildId=99'
        $R.AgentiPool[0].Agenti[1].Online | Should -BeFalse
        $R.AgentiPool[0].Agenti[1].Lavoro | Should -BeNullOrEmpty
    }

    It 'e di sola lettura: solo GET' {
        Should -Invoke Invoke-RestMethod -ModuleName Ado -ParameterFilter { $Method -ne 'Get' } -Times 0 -Exactly
    }
}

Describe 'Ado: la Feature e la destinazione delle PR (D52)' {
    BeforeEach {
        Mock Get-AdoIntestazione -ModuleName Ado { @{ Authorization = 'Basic SEGRETO-FINTO' } }
    }

    It 'Get-AdoCard legge anche le relazioni e porta PadreId (null senza padre)' {
        Mock Invoke-RestMethod -ModuleName Ado {
            '{ "id": 42, "rev": 3, "fields": { "System.WorkItemType": "User Story", "System.State": "New" }, "relations": [
                { "rel": "System.LinkTypes.Hierarchy-Forward", "url": "https://acme.visualstudio.com/_apis/wit/workItems/99" },
                { "rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://acme.visualstudio.com/_apis/wit/workItems/7" } ] }' | ConvertFrom-Json
        }
        (Get-AdoCard -Id 42).PadreId | Should -Be 7
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*workitems/42?*expand=relations*' }
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 43, "rev": 3, "fields": { "System.State": "New" } }' | ConvertFrom-Json }
        (Get-AdoCard -Id 43).PadreId | Should -BeNullOrEmpty
    }

    It 'Get-AdoFeature legge in una chiamata i campi del padre e gli id delle figlie' {
        Mock Invoke-RestMethod -ModuleName Ado {
            '{ "id": 7, "fields": { "System.WorkItemType": "Feature", "System.Title": "Una funzionalita", "System.State": "New",
                "System.Tags": "bug; altro", "System.AreaPath": "DevOps.Agents\\AI\\Stime" }, "relations": [
                { "rel": "System.LinkTypes.Hierarchy-Forward", "url": "https://acme.visualstudio.com/_apis/wit/workItems/21" },
                { "rel": "System.LinkTypes.Hierarchy-Forward", "url": "https://acme.visualstudio.com/_apis/wit/workItems/20" },
                { "rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://acme.visualstudio.com/_apis/wit/workItems/1" } ] }' | ConvertFrom-Json
        }
        $f = Get-AdoFeature -Id 7
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly
        $f.Id | Should -Be 7
        $f.Tipo | Should -Be 'Feature'
        $f.Titolo | Should -Be 'Una funzionalita'
        $f.Stato | Should -Be 'New'
        @($f.Tag) | Should -Be @('bug', 'altro')
        $f.Area | Should -Be 'DevOps.Agents\AI\Stime'
        @($f.FigliIds) | Should -Be @(20, 21)
    }

    It 'Get-AdoFeature senza relazioni ne tag da figlie vuote e tag vuoti' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 7, "fields": { "System.WorkItemType": "Epic" } }' | ConvertFrom-Json }
        $f = Get-AdoFeature -Id 7
        $f.Tipo | Should -Be 'Epic'
        @($f.FigliIds).Count | Should -Be 0
        @($f.Tag).Count | Should -Be 0
    }

    It 'Get-AdoFigliFeature -FigliIds legge solo il lotto, con errorPolicy=Omit, e salta i work item omessi' {
        Mock Invoke-RestMethod -ModuleName Ado {
            '{ "count": 2, "value": [ null, { "id": 20, "fields": { "System.WorkItemType": "Bug", "System.State": "New", "System.Tags": "agents" } } ] }' | ConvertFrom-Json
        }
        $f = @(Get-AdoFigliFeature -FigliIds 20, 21)
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*_apis/wit/workitems?ids=20,21&*' -and $Uri -like '*errorPolicy=Omit*' }
        $f.Count | Should -Be 1
        $f[0].Id | Should -Be 20
        @($f[0].Tag) | Should -Be @('agents')
    }

    It 'Get-AdoFigliFeature -FigliIds vuoto non chiama niente' {
        Mock Invoke-RestMethod -ModuleName Ado { throw 'non doveva leggere' }
        @(Get-AdoFigliFeature -FigliIds @()).Count | Should -Be 0
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 0 -Exactly
    }

    It 'Get-AdoFigliFeature legge le figlie (Hierarchy-Forward) con id, stato, tag e tipo, in ordine di id' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*workitems/7?*') {
                '{ "id": 7, "fields": {}, "relations": [
                    { "rel": "System.LinkTypes.Hierarchy-Forward", "url": "https://acme.visualstudio.com/_apis/wit/workItems/21" },
                    { "rel": "System.LinkTypes.Hierarchy-Forward", "url": "https://acme.visualstudio.com/_apis/wit/workItems/20" },
                    { "rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://acme.visualstudio.com/_apis/wit/workItems/1" } ] }' | ConvertFrom-Json
            }
            else {
                '{ "count": 2, "value": [
                    { "id": 21, "fields": { "System.WorkItemType": "Bug", "System.State": "Removed" } },
                    { "id": 20, "fields": { "System.WorkItemType": "User Story", "System.State": "In development", "System.Title": "Titolo venti", "System.Tags": "agents; collaudo-funzionalita" } } ] }' | ConvertFrom-Json
            }
        }
        $f = @(Get-AdoFigliFeature -FeatureId 7)
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*_apis/wit/workitems?ids=20,21&*' }
        $f.Count | Should -Be 2
        $f[0].Id | Should -Be 20
        $f[0].Stato | Should -Be 'In development'
        @($f[0].Tag) | Should -Be @('agents', 'collaudo-funzionalita')
        $f[0].Tipo | Should -Be 'User Story'
        $f[0].Titolo | Should -Be 'Titolo venti'
        $f[1].Tipo | Should -Be 'Bug'
        @($f[1].Tag).Count | Should -Be 0
    }

    It 'Get-AdoFigliFeature senza figlie restituisce un elenco vuoto' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 7, "fields": {} }' | ConvertFrom-Json }
        @(Get-AdoFigliFeature -FeatureId 7).Count | Should -Be 0
    }

    It 'Set-AdoStatoFeature scrive lo stato sulla Feature' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "id": 7, "rev": 4 }' | ConvertFrom-Json }
        Set-AdoStatoFeature -FeatureId 7 -Stato 'Active'
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Uri -like '*_apis/wit/workitems/7?*' -and $Body -like '*"path":"/fields/System.State","value":"Active"*' }
    }

    It 'New-AdoCard con -Padre scrive la relazione verso il padre nella stessa creazione' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        New-AdoCard -Tipo 'User Story' -Titolo 'Figlia' -Area 'DevOps.Agents\AI\Stime' -Descrizione 'd' -Criteri 'c' -Padre 7 | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter {
            $Body -like '*"path":"/relations/-","value":{"rel":"System.LinkTypes.Hierarchy-Reverse","url":"https://acme.visualstudio.com/_apis/wit/workItems/7"}*' }
    }

    It 'New-AdoCard senza -Padre non scrive il link verso il padre' {
        $global:FxWi = $script:WiJson
        Mock Invoke-RestMethod -ModuleName Ado { $global:FxWi | ConvertFrom-Json }
        New-AdoCard -Tipo 'User Story' -Titolo 'T' -Area 'DevOps.Agents\AI\Stime' -Descrizione 'd' -Criteri 'c' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Body -notlike '*Hierarchy-Reverse*' }
    }

    It 'Get-AdoCardPredecessori porta PadreId, l id del padre di ciascun predecessore, nella stessa lettura' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*workitems/42?*') {
                '{ "id": 42, "fields": {}, "relations": [
                    { "rel": "System.LinkTypes.Dependency-Reverse", "url": "https://acme.visualstudio.com/_apis/wit/workItems/31" },
                    { "rel": "System.LinkTypes.Dependency-Reverse", "url": "https://acme.visualstudio.com/_apis/wit/workItems/30" } ] }' | ConvertFrom-Json
            }
            else {
                '{ "count": 2, "value": [
                    { "id": 31, "fields": { "System.State": "Closed" } },
                    { "id": 30, "fields": { "System.State": "In review" }, "relations": [
                        { "rel": "System.LinkTypes.Hierarchy-Forward", "url": "https://acme.visualstudio.com/_apis/wit/workItems/88" },
                        { "rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://acme.visualstudio.com/_apis/wit/workItems/7" } ] } ] }' | ConvertFrom-Json
            }
        }
        $p = @(Get-AdoCardPredecessori -CardId 42)
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 2 -Exactly
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Uri -like '*_apis/wit/workitems?ids=30,31&*' -and $Uri -like '*expand=relations*' }
        $p[0].PadreId | Should -Be 7
        $p[1].PadreId | Should -BeNullOrEmpty
    }

    It 'Get-AdoPr, New-AdoPr e Get-AdoPrDelRamo puntano a develop se non si dice altro' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [], "pullRequestId": 5 }' | ConvertFrom-Json }
        Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x' | Out-Null
        Get-AdoPrDelRamo -Progetto 'P' -Repo 'R' -Ramo 'feature/x' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 2 -Exactly -ParameterFilter { $Method -eq 'Get' -and $Uri -like '*targetRefName=refs/heads/develop&*' }
        New-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x' -Titolo 'T' -Descrizione 'D' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' -and $Body -like '*"targetRefName":"refs/heads/develop"*' }
    }

    It 'Get-AdoPr, New-AdoPr e Get-AdoPrDelRamo con -Destinazione puntano al ramo dato' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "value": [], "pullRequestId": 5 }' | ConvertFrom-Json }
        Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x' -Destinazione 'feature/f7-prova' | Out-Null
        Get-AdoPrDelRamo -Progetto 'P' -Repo 'R' -Ramo 'feature/x' -Destinazione 'feature/f7-prova' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 2 -Exactly -ParameterFilter { $Method -eq 'Get' -and $Uri -like '*targetRefName=refs/heads/feature/f7-prova&*' }
        New-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x' -Titolo 'T' -Descrizione 'D' -Destinazione 'feature/f7-prova' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName Ado -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' -and $Body -like '*"targetRefName":"refs/heads/feature/f7-prova"*' }
    }

    It 'Get-AdoPr porta UltimoCommit, anche per la PR completata' {
        Mock Invoke-RestMethod -ModuleName Ado {
            if ($Uri -like '*policy/evaluations*') { '{ "value": [] }' | ConvertFrom-Json }
            else { '{ "value": [ { "pullRequestId": 9, "status": "active", "mergeStatus": "succeeded", "lastMergeSourceCommit": { "commitId": "ABC123" }, "repository": { "project": { "id": "pid-1" } } } ] }' | ConvertFrom-Json }
        }
        (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x').UltimoCommit | Should -Be 'ABC123'
        Mock Invoke-RestMethod -ModuleName Ado {
            '{ "value": [ { "pullRequestId": 9, "status": "completed", "lastMergeSourceCommit": { "commitId": "DEF456" }, "repository": { "project": { "id": "pid-1" } } } ] }' | ConvertFrom-Json
        }
        (Get-AdoPr -Progetto 'P' -Repo 'R' -Ramo 'feature/x' -AncheCompletate).UltimoCommit | Should -Be 'DEF456'
    }

    It 'Get-AdoRun porta SourceVersion, nullo se la run non lo ha' {
        Mock Invoke-RestMethod -ModuleName Ado { '{ "status": "completed", "result": "succeeded", "sourceVersion": "COMMIT9" }' | ConvertFrom-Json }
        (Get-AdoRun -Progetto 'P' -RunId 5).SourceVersion | Should -Be 'COMMIT9'
        Mock Invoke-RestMethod -ModuleName Ado { '{ "status": "inProgress" }' | ConvertFrom-Json }
        (Get-AdoRun -Progetto 'P' -RunId 5).SourceVersion | Should -BeNullOrEmpty
    }
}
