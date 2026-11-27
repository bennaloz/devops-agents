using System.Net;
using System.Text.Json.Nodes;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Infrastructure.AzureDevOps;
using DevOpsAgents.Infrastructure.Configuration;
using DevOpsAgents.Core.Ports;
using Xunit;

namespace DevOpsAgents.Infrastructure.Tests;

public class CardEditorTests
{
    private static readonly StateNames Names = SuiteConfig.Load(Tx.Root).Names;

    [Fact]
    public async Task La_card_letta_per_intero_ha_descrizione_e_criteri_secondo_il_tipo()
    {
        var h = new FakeHttp((r, _) => FakeHttp.Ok("""
            { "id": 7, "rev": 3, "fields": { "System.Title": "T", "System.State": "New", "System.WorkItemType": "Bug", "System.AreaPath": "A",
              "Microsoft.VSTS.TCM.ReproSteps": "i passi", "System.Description": "non questa", "Microsoft.VSTS.Common.AcceptanceCriteria": "i criteri" },
              "relations": [ { "rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://x/_apis/wit/workItems/10" } ] }
            """));
        var d = await new AdoBoard(Tx.Ado(h), "DevOps.Agents", Names).GetCardAsync(7);
        Assert.Equal(("i passi", "i criteri", 10), (d.Description, d.Criteria, d.Card.ParentId));
    }

    [Fact]
    public async Task Sposta_restituisce_la_revisione_e_i_criteri_vanno_in_markdown()
    {
        var h = new FakeHttp((r, _) => FakeHttp.Ok("""{ "id": 7, "rev": 9, "fields": { "System.Title": "Task", "System.State": "New" } }"""));
        var b = new AdoBoard(Tx.Ado(h), "DevOps.Agents", Names);
        Assert.Equal(9, await b.MoveAsync(7, "Ready to develop"));
        await b.SetCriteriaAsync(7, "- uno");
        var t = await b.CreateTaskAsync(7, "Task", "fai", "Acme.AI\\Stime");
        Assert.Equal(7, t.Id);
        var ops = JsonNode.Parse(h.Calls[1].Body)!.AsArray();
        Assert.Equal("/multilineFieldsFormat/Microsoft.VSTS.Common.AcceptanceCriteria", ops[0]!["path"]!.GetValue<string>());
        Assert.Equal("POST", h.Calls[2].Method);
        Assert.Contains("/Acme.AI/_apis/wit/workitems/$Task?", h.Calls[2].Url);
        Assert.Contains("Hierarchy-Reverse", h.Calls[2].Body);
        Assert.Contains("_apis/wit/workItems/7", h.Calls[2].Body);
    }

    [Fact]
    public async Task Titolo_e_descrizione_della_PR_su_Azure_Repos_e_GitHub_con_la_firma()
    {
        var ado = new FakeHttp((r, _) => FakeHttp.Ok("""{ "description": "[Card 7](u)\n\nvecchia" }"""));
        var az = new AzureReposCodeHost(Tx.Ado(ado));
        Assert.StartsWith("[Card 7]", await az.GetDescriptionAsync(Tx.AzureArea, 33));
        await az.SetDescriptionAsync(Tx.AzureArea, 33, "nuova");
        await az.SetTitleAsync(Tx.AzureArea, 33, "feat: x");
        Assert.Equal("PATCH", ado.Calls[1].Method);
        Assert.EndsWith("/Acme.AI/_apis/git/repositories/Acme.AI/pullrequests/33?api-version=7.1", ado.Calls[1].Url);
        Assert.Equal($"nuova\n\n{AzureReposCodeHost.Signature}", JsonNode.Parse(ado.Calls[1].Body)!["description"]!.GetValue<string>());
        Assert.Equal("feat: x", JsonNode.Parse(ado.Calls[2].Body)!["title"]!.GetValue<string>());

        var gh = new FakeHttp((r, _) => FakeHttp.Ok("""{ "body": "[Card 7](u)" }"""));
        var g = Tx.Gh(gh);
        await g.SetDescriptionAsync(Tx.GitHubArea, 5, "nuova");
        Assert.Equal(("PATCH", "https://api.github.com/repos/acme/web/pulls/5"), (gh.Calls[0].Method, gh.Calls[0].Url));
        Assert.Equal($"nuova\n\n{AzureReposCodeHost.Signature}", JsonNode.Parse(gh.Calls[0].Body)!["body"]!.GetValue<string>());
    }

    private const string Yaml = "parameters:\n  - name: deployApi\n    type: boolean\n  - name: altro\n    type: string\n";

    [Fact]
    public async Task I_parametri_del_deploy_si_leggono_dallo_YAML_della_pipeline_sul_ramo()
    {
        var h = new FakeHttp((r, _) => r.RequestUri!.AbsolutePath.EndsWith("/pipelines/115")
            ? FakeHttp.Ok("""{ "configuration": { "path": "/pipelines/deploy.yml", "repository": { "id": "repo-guid", "type": "azureReposGit" } } }""")
            : FakeHttp.Ok(new JsonObject { ["content"] = Yaml }.ToJsonString()));
        Assert.Equal(["deployApi"], await new AzurePipelinesDeployParameters(Tx.Ado(h)).GetAsync(Tx.AzureArea, "feature/7-x"));
        Assert.Contains("versionDescriptor.version=feature%2F7-x", h.Calls[1].Url);
        Assert.Contains("path=%2Fpipelines%2Fdeploy.yml", h.Calls[1].Url);
    }

    [Fact]
    public async Task Con_la_pipeline_su_un_repo_GitHub_lo_YAML_viene_da_GitHub()
    {
        var ado = new FakeHttp((r, _) => FakeHttp.Ok("""{ "configuration": { "path": "ci/deploy.yml", "repository": { "id": "acme/web", "fullName": "acme/web", "type": "gitHub" } } }"""));
        var gh = new FakeHttp((r, _) => (HttpStatusCode.OK, Yaml));
        Assert.Equal(["deployApi"], await new AzurePipelinesDeployParameters(Tx.Ado(ado), Tx.Gh(gh)).GetAsync(Tx.GitHubArea, "develop"));
        Assert.Equal("https://api.github.com/repos/acme/web/contents/ci/deploy.yml?ref=develop", gh.Calls[0].Url);
    }
}

public class CardCreatorAdoTests
{
    [Fact]
    public async Task La_card_nasce_con_campi_in_markdown_predecessori_e_padre_e_i_tag_arrivano_con_il_test_sulla_revisione()
    {
        var h = new FakeHttp((r, _) => FakeHttp.Ok("""{ "id": 901, "rev": 1, "fields": { "System.State": "Draft", "System.Title": "T", "System.Tags": "vecchio" } }"""));
        var b = new AdoBoard(Tx.Ado(h), "DevOps.Agents", SuiteConfig.Load(Tx.Root).Names);
        var (id, state) = await b.CreateWorkItemAsync(new("Bug", "T", "Acme.AI\\Stime", "desc", "crit", [], "t@example.invalid", [5], 10));
        Assert.Equal((901, "Draft"), (id, state));
        Assert.Contains("/Acme.AI/_apis/wit/workitems/$Bug?", h.Calls[0].Url);
        var body = h.Calls[0].Body;
        Assert.Contains("Microsoft.VSTS.TCM.ReproSteps", body);
        Assert.Contains("Dependency-Reverse", body);
        Assert.Contains("Hierarchy-Reverse", body);
        await b.TagNewAsync(901, ["agents"], null);
        Assert.Contains("\"op\":\"test\",\"path\":\"/rev\",\"value\":1", h.Calls[^1].Body);
        Assert.Contains("vecchio; agents", h.Calls[^1].Body);
        await Assert.ThrowsAsync<InvalidOperationException>(() => b.CreateWorkItemAsync(new("Feature", "F", "A\\B", "d", "c", [], "t", [], null)));
    }
}

public class AdoPipelineReaderTests
{
    [Fact]
    public async Task Le_pipeline_si_leggono_da_tutti_i_progetti_con_fasi_motivi_e_agenti()
    {
        var h = new FakeHttp((r, _) =>
        {
            var u = r.RequestUri!.PathAndQuery;
            if (u.StartsWith("/_apis/projects")) return FakeHttp.Ok("""{"value":[{"name":"Acme.AI"},{"name":"Rotto"}]}""");
            if (u.StartsWith("/Rotto/")) return (System.Net.HttpStatusCode.Forbidden, "{}");
            if (u.Contains("/definitions?name=")) return FakeHttp.Ok("""{"value":[]}""");
            if (u.Contains("statusFilter=inProgress")) return FakeHttp.Ok("""{"value":[{"id":30,"status":"inProgress","sourceBranch":"refs/heads/main","definition":{"id":9,"name":"release-app"},"reason":"manual","startTime":"2026-11-26T09:00:00Z"}]}""");
            if (u.Contains("statusFilter=completed")) return FakeHttp.Ok("""{"value":[{"id":41,"status":"completed","result":"failed","sourceBranch":"refs/heads/develop","definition":{"id":5,"name":"build-ci"},"reason":"individualCI"}]}""");
            if (u.Contains("/builds/30/timeline")) return FakeHttp.Ok("""{"records":[{"id":"s","type":"Stage","name":"Produzione","state":"inProgress"},{"id":"a","parentId":"s","type":"Checkpoint.Approval","state":"inProgress"}]}""");
            if (u.Contains("/builds/41/timeline")) return FakeHttp.Ok("""{"records":[{"type":"Task","result":"failed","issues":[{"message":"lost communication with the server"}],"log":{"url":"https://acme.visualstudio.com/Acme.AI/_apis/build/builds/41/logs/7"}}]}""");
            if (u.Contains("/logs/7")) return (System.Net.HttpStatusCode.OK, "2026-11-26T09:00:00.1234567Z ##[error]Agente perso");
            if (u.Contains("definitions=5&branchName")) return FakeHttp.Ok("""{"value":[{"id":41,"result":"failed"}]}""");
            if (u.StartsWith("/_apis/distributedtask/pools?")) return FakeHttp.Ok("""{"value":[{"id":1,"name":"Azure Pipelines","isHosted":true},{"id":2,"name":"Interni"}]}""");
            if (u.Contains("/pools/2/agents")) return FakeHttp.Ok("""{"value":[{"name":"srv-1","status":"offline","enabled":true}]}""");
            return (System.Net.HttpStatusCode.NotFound, "{}");
        });
        var v = await new AdoPipelineReader(Tx.Ado(h)).ReadAsync(["Acme.AI"], [115], new DateTimeOffset(2026, 11, 26, 10, 0, 0, TimeSpan.Zero));
        Assert.True(v.Read);
        Assert.Single(v.Errors, e => e.StartsWith("Rotto:"));
        var run = Assert.Single(v.Active);
        Assert.Equal(("inAttesa", "Produzione", "rilascio", "main"), (run.Status, run.Stage, run.Kind, run.Branch));
        Assert.Equal(41, Assert.Single(v.Failed).Id);
        Assert.Equal("lost communication with the server\n##[error]Agente perso", v.Reasons[41]);
        Assert.Equal((41, "failed"), v.Latest["Acme.AI|5|develop"]);
        Assert.Equal(("Interni", "srv-1", false), (v.Pools.Single().Pool, v.Pools.Single().Agents.Single().Name, v.Pools.Single().Agents.Single().Online));
    }

    [Fact]
    public async Task Il_rilancio_rifa_lo_stesso_run_e_un_ramo_di_PR_non_si_rilancia()
    {
        var h = new FakeHttp((r, _) => FakeHttp.Ok("""{"id":77}"""));
        var reader = new AdoPipelineReader(Tx.Ado(h));
        var run = new DevOpsAgents.Core.Supervision.RunInfo(41, "Acme.AI", "build-ci", "develop", null, "concluso", null, null, null, "failed", 5, "ci", null,
            SourceVersion: "abc123", TemplateParameters: new Dictionary<string, string> { ["deployApi"] = "true" });
        Assert.Equal(77, await reader.RerunAsync(run));
        var body = JsonNode.Parse(h.Calls[0].Body)!;
        Assert.Equal(("refs/heads/develop", "abc123", "true", 5), (body["sourceBranch"]!.GetValue<string>(), body["sourceVersion"]!.GetValue<string>(), body["templateParameters"]!["deployApi"]!.GetValue<string>(), body["definition"]!["id"]!.GetValue<int>()));
        await Assert.ThrowsAsync<InvalidOperationException>(() => reader.RerunAsync(run with { Branch = "PR #12" }));
    }
}
