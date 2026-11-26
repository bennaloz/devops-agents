using System.Net;
using System.Text.Json.Nodes;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Infrastructure.AzureDevOps;
using DevOpsAgents.Infrastructure.Configuration;
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
