using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;
using DevOpsAgents.Infrastructure.AzureDevOps;
using DevOpsAgents.Infrastructure.Configuration;
using DevOpsAgents.Infrastructure.GitHub;
using DevOpsAgents.Infrastructure.Local;
using DevOpsAgents.Infrastructure.Secrets;
using Xunit;

namespace DevOpsAgents.Infrastructure.Tests;

/// <summary>Un server HTTP finto: risponde secondo l'URL e registra ogni richiesta (metodo, URL, corpo).</summary>
internal sealed class FakeHttp(Func<HttpRequestMessage, string, (HttpStatusCode, string)> respond) : HttpMessageHandler
{
    public List<(string Method, string Url, string Body)> Calls { get; } = [];

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct);
        Calls.Add((request.Method.Method, request.RequestUri!.ToString(), body));
        var (code, text) = respond(request, body);
        return new HttpResponseMessage(code) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
    }

    public static (HttpStatusCode, string) Ok(string json) => (HttpStatusCode.OK, json);
}

internal static class Tx
{
    public static readonly string Root = SuiteConfig.FindRoot(AppContext.BaseDirectory);
    public static readonly AreaMapping AzureArea = new("DevOps.Agents\\AI\\Stime", "Acme.AI", "", "Acme.AI", "stime", 115, null);
    public static readonly AreaMapping GitHubArea = new("DevOps.Agents\\Web", "Acme.Web", "", "Acme.Web", "web", 120, null, SourceControl.GitHub, "acme/web");
    public static AdoClient Ado(FakeHttp h) => new(new HttpClient(h), "https://acme.visualstudio.com", () => "SEGRETO");
    public static GitHubCodeHost Gh(FakeHttp h, FakeHttp? ado = null) => new(new HttpClient(h), () => "SEGRETO-GH", ado is null ? null : Ado(ado));

    public static string Check(string conclusion = "success", string status = "completed", string url = "https://github.com/acme/web/actions/runs/77/job/1") =>
        $$"""{ "status": "{{status}}", "conclusion": "{{conclusion}}", "details_url": "{{url}}" }""";

    public static string GhPr(int n = 7, string state = "open", bool? mergeable = true, string mergeableState = "clean", string? merged = null) =>
        $$"""{ "number": {{n}}, "state": "{{state}}", "merged_at": {{(merged is null ? "null" : $"\"{merged}\"")}}, "mergeable": {{(mergeable is null ? "null" : mergeable.Value ? "true" : "false")}}, "mergeable_state": "{{mergeableState}}", "html_url": "https://github.com/acme/web/pull/{{n}}", "title": "T", "head": { "sha": "HEAD1", "ref": "feature/42-x" } }""";
}

public class SuiteConfigTests
{
    [Fact]
    public void Legge_la_configurazione_della_suite_dagli_stessi_file_della_versione_PowerShell()
    {
        var c = SuiteConfig.Load(Tx.Root);
        Assert.Equal("DevOps.Agents", c.BoardProject);
        Assert.Equal("https://acme.visualstudio.com", c.Organization);
        Assert.Equal("In development", c.Names[StateKeys.InDevelopment]);
        Assert.Equal(StateKeys.HumanTest, c.Names.KeyOf("human test"));
        Assert.Equal("opus", c.Roles["dev"].Model);
        Assert.Contains("Edit", c.Roles["dev"].Tools);
        Assert.Equal(2, c.Limits.ReviewRounds);
        Assert.Contains(c.Areas, a => a.Repo == "Acme.AI" && a.DeployPipeline == 115 && a.Source == SourceControl.AzureRepos);
    }

    [Theory]
    [InlineData("\"sorgente\": \"github\"", "repoGithub")]
    [InlineData("\"sorgente\": \"gitlab\"", "ado o github")]
    public void Una_sorgente_sbagliata_in_mappa_si_ferma_con_un_errore_che_lo_dice(string field, string message)
    {
        var root = Directory.CreateTempSubdirectory("cfg").FullName;
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "config"));
            foreach (var f in Directory.GetFiles(Path.Combine(Tx.Root, "config"))) File.Copy(f, Path.Combine(root, "config", Path.GetFileName(f)));
            CopyDir(Path.Combine(Tx.Root, "ruoli"), Path.Combine(root, "ruoli"));
            var p = Path.Combine(root, "config", "mappa.json");
            File.WriteAllText(p, File.ReadAllText(p).Replace("\"repo\": \"Acme.AI\",", $"\"repo\": \"Acme.AI\", {field},"));
            var e = Assert.Throws<InvalidDataException>(() => SuiteConfig.Load(root));
            Assert.Contains(message, e.Message);
        }
        finally { Directory.Delete(root, true); }
    }

    private static void CopyDir(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from)) File.Copy(f, Path.Combine(to, Path.GetFileName(f)));
    }
}

public class TokenStoreTests
{
    [Fact]
    public void La_variabile_d_ambiente_vince_sul_file_e_il_file_in_chiaro_si_legge()
    {
        var dir = Directory.CreateTempSubdirectory("claude").FullName;
        File.WriteAllText(Path.Combine(dir, "pat-github.txt"), " ghp_file \n");
        Assert.Equal("ghp_file", new TokenStore(dir).GitHub);
        Environment.SetEnvironmentVariable("DEVOPS_AGENTS_GITHUB_TOKEN", "ghp_env");
        try { Assert.Equal("ghp_env", new TokenStore(dir).GitHub); }
        finally { Environment.SetEnvironmentVariable("DEVOPS_AGENTS_GITHUB_TOKEN", null); }
        Assert.Null(new TokenStore(dir).AzureDevOpsReadOnly);
    }

    [Fact]
    public void Un_file_cifrato_con_DPAPI_fuori_da_Windows_dice_perche_non_si_legge()
    {
        if (OperatingSystem.IsWindows()) return;
        var e = Assert.Throws<InvalidOperationException>(() => TokenStore.Decode("01000000d08c9ddf0115d1118c7a00c04fc297eb", "pat.txt"));
        Assert.Contains("DPAPI", e.Message);
    }
}

public class AzureReposTests
{
    private static FakeHttp Server(string mergeStatus, string evaluations, string prStatus = "active") => new((r, _) =>
    {
        var u = r.RequestUri!.ToString();
        if (u.Contains("/pullrequests?")) return FakeHttp.Ok($$"""{ "value": [ { "pullRequestId": 5, "status": "{{prStatus}}", "mergeStatus": "{{mergeStatus}}", "repository": { "project": { "id": "P1" } }, "lastMergeSourceCommit": { "commitId": "HEAD1" } } ] }""");
        if (u.Contains("/policy/evaluations")) return FakeHttp.Ok($$"""{ "value": [ {{evaluations}} ] }""");
        return (HttpStatusCode.NotFound, "{}");
    });

    private static string Eval(string status, string commit = "HEAD1", int build = 70, bool expired = false) =>
        $$"""{ "status": "{{status}}", "evaluationId": "e1", "configuration": { "type": { "displayName": "Build" } }, "context": { "buildId": {{build}}, "lastMergeSourceCommitId": "{{commit}}", "isExpired": {{(expired ? "true" : "false")}} } }""";

    private static Task<PullRequestInfo?> Get(FakeHttp h, bool completed = false) => new AzureReposCodeHost(Tx.Ado(h)).GetPullRequestAsync(Tx.AzureArea, "feature/42-x", "develop", completed);

    [Fact]
    public async Task Una_build_approvata_sul_commit_di_testa_e_verde_con_il_link_alla_build()
    {
        var pr = await Get(Server("succeeded", Eval("approved")));
        Assert.Equal((5, Validations.Green, 70, "HEAD1"), (pr!.Id, pr.Validation, pr.BuildId, pr.HeadCommit));
        Assert.Equal("https://acme.visualstudio.com/Acme.AI/_build/results?buildId=70", pr.LogUrl);
    }

    [Fact]
    public async Task Un_esito_su_un_commit_vecchio_vale_in_corso_una_scaduta_e_scaduta_i_conflitti_vincono()
    {
        Assert.Equal(Validations.Running, (await Get(Server("succeeded", Eval("rejected", commit: "VECCHIO"))))!.Validation);
        Assert.Equal(Validations.Red, (await Get(Server("succeeded", Eval("rejected"))))!.Validation);
        Assert.Equal(Validations.Expired, (await Get(Server("succeeded", Eval("queued", expired: true))))!.Validation);
        Assert.Equal(Validations.Conflicts, (await Get(Server("conflicts", Eval("approved"))))!.Validation);
    }

    [Fact]
    public async Task Senza_PR_attiva_con_le_completate_la_PR_unita()
    {
        var h = Server("succeeded", "", prStatus: "completed");
        Assert.Null(await Get(h));
        Assert.Equal(PrStatuses.Completed, (await Get(h, completed: true))!.Status);
    }

    [Fact]
    public async Task Il_merge_e_con_merge_commit_sul_commit_verificato_e_cancella_il_ramo()
    {
        var h = new FakeHttp((_, _) => FakeHttp.Ok("{}"));
        await new AzureReposCodeHost(Tx.Ado(h)).CompletePullRequestAsync(Tx.AzureArea, 5, "VERIFICATO");
        var body = JsonNode.Parse(h.Calls.Single().Body)!;
        Assert.Equal("PATCH", h.Calls.Single().Method);
        Assert.Equal("VERIFICATO", body["lastMergeSourceCommit"]!["commitId"]!.GetValue<string>());
        Assert.Equal("noFastForward", body["completionOptions"]!["mergeStrategy"]!.GetValue<string>());
        Assert.True(body["completionOptions"]!["deleteSourceBranch"]!.GetValue<bool>());
    }

    [Fact]
    public async Task Un_401_dice_di_rinnovare_il_PAT_senza_mostrarlo()
    {
        var h = new FakeHttp((_, _) => (HttpStatusCode.Unauthorized, "token SEGRETO non valido"));
        var e = await Assert.ThrowsAsync<HttpRequestException>(() => Get(h));
        Assert.Contains("Install-Attrezzi.ps1 -Pat", e.Message);
        Assert.DoesNotContain("SEGRETO", e.Message);
    }

    [Fact]
    public async Task Il_deploy_accoda_la_pipeline_sul_ramo_con_i_parametri_scelti_a_true_e_gli_altri_a_false()
    {
        var h = new FakeHttp((_, _) => FakeHttp.Ok("""{ "id": 70 }"""));
        var id = await new AzurePipelinesCi(Tx.Ado(h)).QueueTestDeployAsync(Tx.AzureArea, "feature/42-x", ["deployStime"], ["deployDatabases"]);
        Assert.Equal(70, id);
        var (method, url, b) = h.Calls.Single();
        Assert.Equal(("POST", "https://acme.visualstudio.com/Acme.AI/_apis/pipelines/115/runs?api-version=7.1"), (method, url));
        var body = JsonNode.Parse(b)!;
        Assert.Equal("refs/heads/feature/42-x", body["resources"]!["repositories"]!["self"]!["refName"]!.GetValue<string>());
        Assert.Equal("true", body["templateParameters"]!["deployStime"]!.GetValue<string>());
        Assert.Equal("false", body["templateParameters"]!["deployDatabases"]!.GetValue<string>());
    }
}

public class AdoBoardTests
{
    private static readonly StateNames Names = SuiteConfig.Load(Tx.Root).Names;

    [Fact]
    public async Task Le_card_attive_vengono_dalla_WIQL_con_il_tag_e_senza_le_rimosse()
    {
        var h = new FakeHttp((r, _) => r.RequestUri!.ToString().Contains("/wiql")
            ? FakeHttp.Ok("""{ "workItems": [ { "id": 41 }, { "id": 42 } ] }""")
            : FakeHttp.Ok("""{ "value": [ { "id": 41, "rev": 3, "fields": { "System.Title": "Tolta", "System.State": "Removed", "System.Tags": "agents" } }, { "id": 42, "rev": 7, "fields": { "System.Title": "Importare", "System.State": "In development", "System.Tags": "agents; human-test", "System.AreaPath": "DevOps.Agents\\AI\\Stime", "System.AssignedTo": { "id": "u-1", "displayName": "Paolo Rossi" }, "System.WorkItemType": "Bug" } } ] }"""));
        var cards = await new AdoBoard(Tx.Ado(h), "DevOps.Agents", Names).GetActiveCardsAsync();
        var c = Assert.Single(cards);
        Assert.Equal((42, 7, "In development", "u-1", "Bug"), (c.Id, c.Rev, c.State, c.AssignedTo!.Id, c.WorkItemType));
        Assert.Equal(["agents", "human-test"], c.Tags);
        var wiql = JsonNode.Parse(h.Calls[0].Body)!["query"]!.GetValue<string>();
        Assert.Contains("[System.Tags] CONTAINS 'agents'", wiql);
        Assert.Contains("[System.State] <> 'Draft'", wiql);
    }

    [Fact]
    public async Task La_storia_tiene_solo_i_cambi_di_stato_con_chi_e_quando()
    {
        var h = new FakeHttp((_, _) => FakeHttp.Ok("""{ "value": [ { "rev": 1, "fields": { "System.State": "New", "System.ChangedDate": "2026-11-01T08:00:00Z", "System.ChangedBy": { "id": "u-1", "displayName": "A" } } }, { "rev": 2, "fields": { "System.State": "New", "System.ChangedDate": "2026-11-01T09:00:00Z", "System.ChangedBy": { "id": "u-1", "displayName": "A" } } }, { "rev": 3, "fields": { "System.State": "Ready to develop", "System.ChangedDate": "2026-11-01T10:00:00Z", "System.ChangedBy": { "id": "u-2", "displayName": "B" } } } ] }"""));
        var s = await new AdoBoard(Tx.Ado(h), "DevOps.Agents", Names).GetStateHistoryAsync(42);
        Assert.Equal(2, s.Count);
        Assert.Equal((3, "New", "Ready to develop", "u-2"), (s[1].Rev, s[1].From, s[1].To, s[1].ById));
    }

    [Fact]
    public async Task Le_Feature_aperte_si_leggono_solo_dalle_aree_della_mappa_con_il_rank_e_il_padre_delle_card_dalla_relazione()
    {
        var h = new FakeHttp((r, _) => r.RequestUri!.ToString().Contains("/wiql")
            ? FakeHttp.Ok("""{ "workItems": [ { "id": 10 } ] }""")
            : FakeHttp.Ok("""{ "value": [ { "id": 10, "rev": 2, "fields": { "System.Title": "Preventivi", "System.State": "Active", "System.Tags": "paused", "Microsoft.VSTS.Common.StackRank": 1500.5 } } ] }"""));
        var f = Assert.Single(await new AdoBoard(Tx.Ado(h), "DevOps.Agents", Names).GetOpenFeaturesAsync(["DevOps.Agents\\AI\\Stime", "D'Area"]));
        Assert.Equal((10, "Preventivi", 1500.5, true), (f.Id, f.Title, f.Rank!.Value, f.HasTag("paused")));
        var wiql = JsonNode.Parse(h.Calls[0].Body)!["query"]!.GetValue<string>();
        Assert.Contains("[System.WorkItemType] = 'Feature'", wiql);
        Assert.Contains("[System.AreaPath] UNDER 'D''Area'", wiql);
        Assert.Contains("[System.State] <> 'Closed'", wiql);

        var card = AdoBoard.ToCard(JsonNode.Parse("""{ "id": 42, "rev": 1, "fields": { "System.State": "New" }, "relations": [ { "rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://x/_apis/wit/workItems/10" } ] }""")!);
        Assert.Equal(10, card.ParentId);
    }

    [Fact]
    public async Task Il_rank_si_scrive_nel_campo_StackRank_e_il_tag_si_toglie_con_il_test_sulla_revisione()
    {
        var h = new FakeHttp((r, _) => r.Method == HttpMethod.Get
            ? FakeHttp.Ok("""{ "id": 10, "rev": 4, "fields": { "System.Tags": "agents; paused" } }""") : FakeHttp.Ok("{}"));
        var b = new AdoBoard(Tx.Ado(h), "DevOps.Agents", Names);
        await b.SetRankAsync(10, 2500);
        var rank = JsonNode.Parse(h.Calls.Last().Body)!.AsArray()[0]!;
        Assert.Equal(("/fields/Microsoft.VSTS.Common.StackRank", 2500.0), (rank["path"]!.GetValue<string>(), rank["value"]!.GetValue<double>()));
        await b.RemoveTagAsync(10, "PAUSED");
        var ops = JsonNode.Parse(h.Calls.Last().Body)!.AsArray();
        Assert.Equal(("test", 4), (ops[0]!["op"]!.GetValue<string>(), ops[0]!["value"]!.GetValue<int>()));
        Assert.Equal("agents", ops[1]!["value"]!.GetValue<string>());
    }

    [Fact]
    public async Task Il_link_alla_PR_si_aggiunge_una_volta_sola()
    {
        var has = false;
        var h = new FakeHttp((r, _) => r.Method == HttpMethod.Get
            ? FakeHttp.Ok(has ? """{ "id": 42, "relations": [ { "rel": "Hyperlink", "url": "https://github.com/acme/web/pull/9" } ] }""" : """{ "id": 42, "relations": [] }""")
            : FakeHttp.Ok("{}"));
        var b = new AdoBoard(Tx.Ado(h), "DevOps.Agents", Names);
        await b.AddLinkAsync(42, "https://github.com/acme/web/pull/9", "PR 9");
        var patch = JsonNode.Parse(h.Calls.Single(c => c.Method == "PATCH").Body)!.AsArray()[0]!;
        Assert.Equal("Hyperlink", patch["value"]!["rel"]!.GetValue<string>());
        has = true;
        await b.AddLinkAsync(42, "https://github.com/acme/web/pull/9");
        Assert.Single(h.Calls, c => c.Method == "PATCH");
    }
}

public class GitHubCodeHostTests
{
    private static FakeHttp Server(string pr, params string[] checks) => new((r, _) =>
    {
        var u = r.RequestUri!.ToString();
        if (u.Contains("/pulls?")) return FakeHttp.Ok($"[{Tx.GhPr()}]");
        if (u.EndsWith("/pulls/7")) return FakeHttp.Ok(pr);
        if (u.Contains("/check-runs")) return FakeHttp.Ok($$"""{ "check_runs": [{{string.Join(',', checks)}}] }""");
        if (u.EndsWith("/status")) return FakeHttp.Ok("""{ "statuses": [] }""");
        return FakeHttp.Ok("{}");
    });

    [Fact]
    public async Task Controlli_verdi_sul_commit_di_testa_PR_verde_e_la_query_cerca_il_ramo_del_proprietario()
    {
        var h = Server(Tx.GhPr(), Tx.Check());
        var pr = await Tx.Gh(h).GetPullRequestAsync(Tx.GitHubArea, "feature/42-x", "develop", false);
        Assert.Equal((7, PrStatuses.Active, Validations.Green, "HEAD1"), (pr!.Id, pr.Status, pr.Validation, pr.HeadCommit));
        Assert.StartsWith("https://api.github.com/repos/acme/web/pulls?head=acme%3Afeature%2F42-x&base=develop&state=open", h.Calls[0].Url);
    }

    [Fact]
    public async Task Un_controllo_rosso_di_Azure_Pipelines_porta_il_buildId_e_il_link_alla_build()
    {
        var pr = await Tx.Gh(Server(Tx.GhPr(), Tx.Check("failure", url: "https://dev.azure.com/acme/x/_build/results?buildId=55"), Tx.Check()), new FakeHttp((_, _) => FakeHttp.Ok("{}")))
            .GetPullRequestAsync(Tx.GitHubArea, "feature/42-x", "develop", false);
        Assert.Equal((Validations.Red, 55), (pr!.Validation, pr.BuildId));
        Assert.Equal("https://acme.visualstudio.com/Acme.Web/_build/results?buildId=55", pr.LogUrl);
    }

    [Fact]
    public async Task In_corso_vince_su_rosso_i_conflitti_su_tutto_unione_da_calcolare_e_in_corso()
    {
        var gh = (FakeHttp h) => Tx.Gh(h).GetPullRequestAsync(Tx.GitHubArea, "feature/42-x", "develop", false);
        Assert.Equal(Validations.Running, (await gh(Server(Tx.GhPr(), Tx.Check("failure"), Tx.Check(null!, "in_progress"))))!.Validation);
        Assert.Equal(Validations.Conflicts, (await gh(Server(Tx.GhPr(mergeable: false, mergeableState: "dirty"), Tx.Check())))!.Validation);
        Assert.Equal(Validations.Running, (await gh(Server(Tx.GhPr(mergeable: null, mergeableState: "unknown"), Tx.Check())))!.Validation);
    }

    [Fact]
    public async Task La_PR_si_apre_con_AB_card_nella_descrizione()
    {
        var h = new FakeHttp((_, _) => FakeHttp.Ok("""{ "number": 15, "html_url": "https://github.com/acme/web/pull/15" }"""));
        var (id, url) = await Tx.Gh(h).CreatePullRequestAsync(Tx.GitHubArea, "feature/42-x", "develop", "T", "D", 42);
        Assert.Equal((15, "https://github.com/acme/web/pull/15"), (id, url));
        var body = JsonNode.Parse(h.Calls.Single().Body)!;
        Assert.Equal(("feature/42-x", "develop"), (body["head"]!.GetValue<string>(), body["base"]!.GetValue<string>()));
        Assert.EndsWith("AB#42", body["body"]!.GetValue<string>());
    }

    [Fact]
    public async Task Il_merge_e_un_merge_commit_sul_commit_verificato_poi_il_ramo_si_cancella_anche_se_gia_cancellato()
    {
        var h = new FakeHttp((r, _) => r.Method == HttpMethod.Get ? FakeHttp.Ok(Tx.GhPr()) : r.Method == HttpMethod.Delete ? (HttpStatusCode.UnprocessableEntity, "{}") : FakeHttp.Ok("{}"));
        await Tx.Gh(h).CompletePullRequestAsync(Tx.GitHubArea, 7, "VERIFICATO");
        var put = h.Calls.Single(c => c.Method == "PUT");
        Assert.EndsWith("/pulls/7/merge", put.Url);
        Assert.Equal("VERIFICATO", JsonNode.Parse(put.Body)!["sha"]!.GetValue<string>());
        Assert.Contains(h.Calls, c => c.Method == "DELETE" && c.Url.EndsWith("/git/refs/heads/feature/42-x"));
    }

    [Fact]
    public async Task Il_rilancio_rifa_una_volta_per_run_i_job_falliti_di_Actions_e_la_build_di_Azure_Pipelines()
    {
        var ado = new FakeHttp((_, _) => FakeHttp.Ok("{}"));
        var h = Server(Tx.GhPr(), Tx.Check("failure", url: "https://github.com/acme/web/actions/runs/77/job/1"), Tx.Check("failure", url: "https://github.com/acme/web/actions/runs/77/job/2"),
            Tx.Check("failure", url: "https://dev.azure.com/acme/x/_build/results?buildId=55"), Tx.Check(url: "https://github.com/acme/web/actions/runs/78/job/1"));
        var n = await Tx.Gh(h, ado).RequeueValidationsAsync(Tx.GitHubArea, "feature/42-x", "develop", false);
        Assert.Equal(2, n);
        Assert.Single(h.Calls, c => c.Method == "POST" && c.Url.EndsWith("/actions/runs/77/rerun-failed-jobs"));
        Assert.DoesNotContain(h.Calls, c => c.Url.Contains("/runs/78/"));
        Assert.Contains(ado.Calls, c => c.Method == "PATCH" && c.Url.Contains("/Acme.Web/_apis/build/builds/55?retry=true"));
        Assert.Equal(0, await Tx.Gh(h, ado).RequeueValidationsAsync(Tx.GitHubArea, "feature/42-x", "develop", true));
    }

    [Fact]
    public async Task Un_errore_di_GitHub_non_mostra_il_token()
    {
        var h = new FakeHttp((_, _) => (HttpStatusCode.Unauthorized, "Bad credentials SEGRETO-GH"));
        var e = await Assert.ThrowsAsync<HttpRequestException>(() => Tx.Gh(h).GetPullRequestAsync(Tx.GitHubArea, "b", "develop", false));
        Assert.DoesNotContain("SEGRETO-GH", e.Message);
    }

    [Fact]
    public void Il_resolver_sceglie_la_sorgente_dell_area()
    {
        var azure = new AzureReposCodeHost(Tx.Ado(new FakeHttp((_, _) => FakeHttp.Ok("{}"))));
        var gh = Tx.Gh(new FakeHttp((_, _) => FakeHttp.Ok("{}")));
        var r = new CodeHostResolver(azure, gh);
        Assert.Same(gh, r.For(Tx.GitHubArea));
        Assert.Same(azure, r.For(Tx.AzureArea));
    }
}

public class LocalTests
{
    [Theory]
    [InlineData("Importare le stime dal foglio Excel", "importare-le-stime-dal-foglio-excel")]
    [InlineData("Perché è così? (v2)", "perche-e-cosi-v2")]
    [InlineData("!!!", "card")]
    public void Lo_slug_del_ramo_e_ascii_minuscolo(string title, string slug) => Assert.Equal(slug, GitWorkspace.Slug(title));

    [Fact]
    public void Il_ramo_di_un_Bug_e_fix_quello_di_una_storia_feature()
    {
        Assert.Equal("fix/7-crash", GitWorkspace.BranchName(new Card(7, 1, "Crash", "New", [], null, WorkItemType: "Bug")));
        Assert.Equal("feature/8-nuovo", GitWorkspace.BranchName(new Card(8, 1, "Nuovo", "New", [], null, WorkItemType: "User Story")));
    }

    [Fact]
    public async Task Il_worktree_nasce_da_origin_develop_si_pubblica_e_si_toglie_solo_se_pulito()
    {
        var tmp = Directory.CreateTempSubdirectory("git").FullName;
        void Git(string dir, params string[] args)
        {
            var psi = new ProcessStartInfo("git") { WorkingDirectory = dir, RedirectStandardError = true, RedirectStandardOutput = true };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi)!;
            p.WaitForExit();
            Assert.True(p.ExitCode == 0, $"git {string.Join(' ', args)}: {p.StandardError.ReadToEnd()}");
        }
        var origin = Path.Combine(tmp, "origin.git");
        var main = Path.Combine(tmp, "main");
        Git(tmp, "init", "--bare", "-b", "develop", origin);
        Git(tmp, "clone", origin, main);
        Git(main, "-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "--allow-empty", "-m", "primo");
        Git(main, "push", "origin", "HEAD:develop");

        var ws = new GitWorkspace(Path.Combine(tmp, "_wt"));
        var area = Tx.AzureArea with { Folder = main };
        var (branch, folder) = await ws.CreateWorktreeAsync(area, new Card(42, 1, "Importare le stime", "Ready", [], null), null);
        Assert.Equal("feature/42-importare-le-stime", branch);
        Assert.True(Directory.Exists(folder));
        Git(main, "ls-remote", "--exit-code", "--heads", "origin", branch);

        File.WriteAllText(Path.Combine(folder, "nuovo.txt"), "x");
        await Assert.ThrowsAsync<InvalidOperationException>(() => ws.RemoveWorktreeAsync(area, folder));
        File.Delete(Path.Combine(folder, "nuovo.txt"));
        await ws.RemoveWorktreeAsync(area, folder);
        Assert.False(Directory.Exists(folder));
        Directory.Delete(tmp, true);
    }

    [Fact]
    public void Gli_argomenti_di_claude_sono_quelli_della_versione_PowerShell()
    {
        var role = new RoleSettings("opus", "high", "ruoli/dev.md", ["Read", "Edit"], "fable");
        var a = ClaudeSessionRunner.Arguments(role, "/r/ruoli/dev.md", "msg", "S1", resume: false);
        Assert.Equal(["-p", "msg", "--model", "opus", "--effort", "high", "--advisor", "fable", "--output-format", "stream-json", "--verbose", "--session-id", "S1",
            "--append-system-prompt-file", "/r/ruoli/dev.md", "--tools", "Read", "Edit", "--allowedTools", "Read", "Edit",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--permission-mode", "acceptEdits"], a);
        Assert.Contains("--resume", ClaudeSessionRunner.Arguments(role, "b", "m", "S1", resume: true));
    }

    [Fact]
    public void L_esito_e_l_ultima_riga_ESITO_dell_evento_result_anche_tra_backtick()
    {
        var log = Path.GetTempFileName();
        File.WriteAllLines(log, [
            """{"type":"assistant","message":{}}""",
            """{"type":"result","result":"Fatto.\nESITO=bivio\n\n`ESITO=fatto`"}""",
            """{"type":"system","subtype":"task_summary"}""",
        ]);
        Assert.Equal("fatto", ClaudeSessionRunner.ParseResult(log).Outcome);
        // un testo che parla di limiti senza evento rejected ne finestra piena non e un limite di token
        File.WriteAllLines(log, ["""{"type":"result","result":"Claude usage limit reached"}"""]);
        Assert.False(ClaudeSessionRunner.ParseResult(log).HitTokenLimit);
    }

    [Fact]
    public void La_quota_viene_dall_ultimo_rate_limit_event_e_il_limite_dall_evento_rejected_con_il_suo_reset()
    {
        var log = Path.GetTempFileName();
        File.WriteAllLines(log, [
            """{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.2,"resetsAt":1700000000},"seven_day":{"utilization":0.1,"resetsAt":1700500000}}}}""",
            """{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1700003600,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1700003600},"seven_day":{"utilization":0.3,"resetsAt":1700500000}}}}""",
            """{"type":"result","result":"You've hit your limit"}""",
        ]);
        var r = ClaudeSessionRunner.ParseResult(log);
        Assert.True(r.HitTokenLimit);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1700003600), r.LimitResetsAt);
        Assert.Equal((1.0, 0.3), (r.Quota!.FiveHourUtilization!.Value, r.Quota.WeeklyUtilization!.Value));
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1700500000), r.Quota.WeeklyResetsAt);
        // senza rejected: "hit your ... limit" e una finestra piena
        File.WriteAllLines(log, [
            """{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1700003600}}}}""",
            """{"type":"result","result":"You've hit your session limit"}""",
        ]);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1700003600), ClaudeSessionRunner.ParseResult(log).LimitResetsAt);
    }

    [Fact]
    public async Task Impostazioni_e_quota_si_salvano_nel_formato_della_versione_PowerShell()
    {
        var dir = Directory.CreateTempSubdirectory("dati").FullName;
        File.WriteAllText(Path.Combine(dir, "impostazioni.json"), """{ "canale": "main", "pausaSistema": false }""");
        var s = new JsonSettingsStore(Path.Combine(dir, "impostazioni.json"));
        Assert.False((await s.LoadAsync()).Paused);
        await s.SaveAsync(new SystemSettings(true));
        var json = JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "impostazioni.json")))!;
        Assert.True(json["pausaSistema"]!.GetValue<bool>());
        Assert.Equal("main", json["canale"]!.GetValue<string>());

        var q = new JsonQuotaStore(dir);
        Assert.Null(await q.LoadAsync());
        var reset = new DateTimeOffset(2026, 11, 27, 10, 0, 0, TimeSpan.Zero);
        await q.SaveAsync(new QuotaInfo(reset, 0.5, reset.AddDays(3), 0.7, reset));
        var back = (await q.LoadAsync())!;
        Assert.Equal((reset, 0.5, 0.7), (back.PauseUntil!.Value, back.WeeklyUtilization!.Value, back.FiveHourUtilization!.Value));
        Assert.Equal(0.5, JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "quota.json")))!["sevenDay"]!["utilization"]!.GetValue<double>());
        File.WriteAllText(Path.Combine(dir, "soglia-quota.json"), """{ "soglia": 0.9, "ignoraRiserva": true, "fino": "2026-11-30T00:00:00Z", "soglia5Ore": 0.8, "fino5Ore": "2026-11-27T10:00:00Z" }""");
        var o = (await q.LoadOverridesAsync())!;
        Assert.Equal((0.9, true, 0.8), (o.WeeklyThreshold!.Value, o.IgnoreWeeklyReserve, o.FiveHourThreshold!.Value));
    }

    [Fact]
    public async Task Una_sessione_parte_con_i_soli_token_in_lettura_e_il_suo_esito_si_legge_alla_fine()
    {
        if (OperatingSystem.IsWindows()) return;
        var data = Directory.CreateTempSubdirectory("dati").FullName;
        var claude = Directory.CreateTempSubdirectory("claude").FullName;
        File.WriteAllText(Path.Combine(claude, "pat-github-lettura.txt"), "ghp_lettura");
        var script = Path.Combine(data, "claude-finto.sh");
        // scrive l'ambiente che vede e un evento result con l'esito
        File.WriteAllText(script, """
            #!/bin/sh
            echo "{\"type\":\"system\",\"env\":\"$ATTREZZI_RUOLO $ATTREZZI_CARD $GH_TOKEN ${GITHUB_TOKEN:-niente}\"}"
            printf '%s\n' '{"type":"result","result":"ok\nESITO=fatto"}'
            """.Replace("\r\n", "\n"));
        Environment.SetEnvironmentVariable("GITHUB_TOKEN", "di-chi-lancia");
        try
        {
            var runner = new ClaudeSessionRunner(SuiteConfig.Load(Tx.Root), new TokenStore(claude), new ClaudeRunnerOptions { Executable = "/bin/sh", PrefixArguments = [script], DataDir = data });
            var id = await runner.StartAsync(new SessionRequest("dev", 42, Tx.AzureArea, null, "messaggio", null, false, null, null));
            SessionResult? r = null;
            for (var i = 0; i < 50 && r is null; i++) { await Task.Delay(100); r = await runner.PollAsync(id); }
            Assert.Equal("fatto", r!.Outcome);
            var env = File.ReadLines(Path.Combine(data, "sessioni", $"{id}.jsonl")).First();
            Assert.Contains("dev 42 ghp_lettura niente", env);
        }
        finally { Environment.SetEnvironmentVariable("GITHUB_TOKEN", null); }
    }

    [Fact]
    public async Task Lo_stato_locale_si_salva_e_si_rilegge_uguale()
    {
        var path = Path.Combine(Directory.CreateTempSubdirectory("stato").FullName, "stato.json");
        var store = new JsonStateStore(path);
        var s = new CardLocalState { Branch = "feature/42-x", LastRole = "dev", RedInARow = 2, Notices = ["testPronto@10"] };
        s.LastSessionByRole["dev"] = new SessionRecord { Id = "S1", Role = "dev", Reason = "pronto", Start = DateTimeOffset.UnixEpoch, End = DateTimeOffset.UnixEpoch.AddHours(1), Outcome = "fatto" };
        await store.SaveAsync(new Dictionary<int, CardLocalState> { [42] = s });
        var back = (await store.LoadAsync())[42];
        Assert.Equal(("feature/42-x", 2, "fatto", "testPronto@10"), (back.Branch, back.RedInARow, back.LastSession!.Outcome, back.Notices.Single()));
        Assert.Empty(await new JsonStateStore(path + ".nonce").LoadAsync());
    }
}


public class DockerTestEnvironmentTests
{
    private static readonly TestEnvironmentSpec Spec = new("collaudo/compose.yml", ["web", "api"], new Dictionary<string, string> { ["app"] = "web" });

    [Fact]
    public void Porte_URL_e_variabili_vengono_dallo_slot_e_le_credenziali_dal_file_del_repo()
    {
        Assert.Equal(21201, DockerTestEnvironments.Ports(Spec, 21000, 2)["api"]);
        Assert.Equal("http://localhost:21200", DockerTestEnvironments.Urls(Spec, "localhost", 21000, 2)["app"]);
        var file = Path.GetTempFileName();
        File.WriteAllText(file, """{ "utente": "prova", "password-admin": "x", "annidato": { "no": 1 } }""");
        var v = DockerTestEnvironments.Variables(Spec, "localhost", 21000, 1, file);
        Assert.Equal(("localhost", "21100", "21101", "prova", "x"), (v["COLLAUDO_HOST"], v["COLLAUDO_PORTA_WEB"], v["COLLAUDO_PORTA_API"], v["COLLAUDO_UTENTE"], v["COLLAUDO_PASSWORD_ADMIN"]));
        Assert.False(v.ContainsKey("COLLAUDO_ANNIDATO"));
        File.WriteAllText(file, "non json segreto");
        var e = Assert.Throws<InvalidDataException>(() => DockerTestEnvironments.Variables(Spec, "h", 1, 1, file));
        Assert.DoesNotContain("segreto", e.Message);
    }

    [Fact]
    public void La_voce_collaudo_della_mappa_si_legge_e_un_URL_su_una_porta_sconosciuta_e_un_errore()
    {
        var root = Directory.CreateTempSubdirectory("cfg").FullName;
        Directory.CreateDirectory(Path.Combine(root, "config"));
        foreach (var f in Directory.GetFiles(Path.Combine(Tx.Root, "config"))) File.Copy(f, Path.Combine(root, "config", Path.GetFileName(f)));
        Directory.CreateDirectory(Path.Combine(root, "ruoli"));
        foreach (var f in Directory.GetFiles(Path.Combine(Tx.Root, "ruoli"))) File.Copy(f, Path.Combine(root, "ruoli", Path.GetFileName(f)));
        var p = Path.Combine(root, "config", "mappa.json");
        var orig = File.ReadAllText(p);
        File.WriteAllText(p, orig.Replace("\"repo\": \"Acme.AI\",", "\"repo\": \"Acme.AI\", \"collaudo\": { \"compose\": \"collaudo/c.yml\", \"porte\": [\"web\"], \"url\": { \"app\": \"web\" } },"));
        var area = SuiteConfig.Load(root).Areas.First(a => a.Repo == "Acme.AI");
        Assert.Equal(("collaudo/c.yml", "web"), (area.TestEnvironment!.Compose, area.TestEnvironment.Urls["app"]));
        File.WriteAllText(p, orig.Replace("\"repo\": \"Acme.AI\",", "\"repo\": \"Acme.AI\", \"collaudo\": { \"compose\": \"c.yml\", \"porte\": [\"web\"], \"url\": { \"app\": \"db\" } },"));
        Assert.Contains("'db'", Assert.Throws<InvalidDataException>(() => SuiteConfig.Load(root)).Message);
        Assert.NotNull(DockerSettings.Load(Tx.Root));
    }

    /// <summary>Un docker finto: scrive gli argomenti e le variabili che vede, ed esce con il codice deciso dal file "esito".</summary>
    private static (DockerTestEnvironments Envs, string Calls, string Dir) FakeDocker(int code = 0, double creationMinutes = 1)
    {
        var dir = Directory.CreateTempSubdirectory("docker").FullName;
        var calls = Path.Combine(dir, "chiamate.txt");
        var script = Path.Combine(dir, "docker.sh");
        File.WriteAllText(script, $"""
            #!/bin/sh
            echo "$* | porta=$COLLAUDO_PORTA_WEB utente=$COLLAUDO_UTENTE wslenv=$WSLENV" >> "{calls}"
            case "$*" in *"ps -a"*) echo "com.docker.compose.project=card-9,acme.collaudo=1";; esac
            case "$*" in *"volume ls -q"*) echo "card-9_db";; esac
            exit {code}
            """.Replace("\r\n", "\n"));
        var claude = Path.Combine(dir, "claude");
        Directory.CreateDirectory(Path.Combine(claude, "collaudo"));
        File.WriteAllText(Path.Combine(claude, "collaudo", "Acme.AI.json"), """{ "utente": "prova" }""");
        var settings = new DockerSettings(["/bin/sh", script], "localhost", 21000, creationMinutes, 1);
        return (new DockerTestEnvironments(settings, Path.Combine(dir, "dati"), claude), calls, dir);
    }

    [Fact]
    public async Task La_creazione_fa_down_e_up_con_le_variabili_solo_al_figlio_e_l_esito_si_legge_come_un_run()
    {
        if (OperatingSystem.IsWindows()) return;
        var (envs, calls, dir) = FakeDocker();
        var area = Tx.AzureArea with { TestEnvironment = Spec };
        var started = await envs.StartAsync(area, 42, 1, dir);
        Assert.Equal("card-42", started.Project);
        PipelineRun status;
        var i = 0;
        do { await Task.Delay(100); status = await envs.GetStatusAsync(42, started.StartedAt); } while (status.Status != "completed" && ++i < 50);
        Assert.Equal("succeeded", status.Result);
        var lines = File.ReadAllLines(calls);
        Assert.StartsWith("compose -p card-42 -f collaudo/compose.yml down -v | porta=21100 utente=prova", lines[0]);
        Assert.StartsWith("compose -p card-42 -f collaudo/compose.yml up -d --build --wait", lines[1]);
        Assert.Contains("COLLAUDO_UTENTE/u", lines[1]);
        Assert.Null(Environment.GetEnvironmentVariable("COLLAUDO_UTENTE"));
        // un esito di un avvio diverso non vale per questo
        Assert.Equal("failed", (await new DockerTestEnvironments(new DockerSettings(["/bin/sh"], "h", 1, 1, 1), Path.Combine(dir, "dati")).GetStatusAsync(42, started.StartedAt.AddMinutes(5))).Result);
    }

    [Fact]
    public async Task Un_up_che_fallisce_e_un_ambiente_non_creato()
    {
        if (OperatingSystem.IsWindows()) return;
        var (envs, _, dir) = FakeDocker(code: 1);
        var started = await envs.StartAsync(Tx.AzureArea with { TestEnvironment = Spec }, 42, 1, dir);
        PipelineRun status;
        var i = 0;
        do { await Task.Delay(100); status = await envs.GetStatusAsync(42, started.StartedAt); } while (status.Status != "completed" && ++i < 50);
        Assert.Equal("failed", status.Result);
        Assert.Contains("compose up: codice 1", File.ReadAllText(started.LogPath));
    }

    [Fact]
    public async Task Buttare_fa_down_v_e_toglie_i_volumi_rimasti_elencare_trova_i_progetti_card()
    {
        if (OperatingSystem.IsWindows()) return;
        var (envs, calls, _) = FakeDocker();
        Assert.True(await envs.RemoveAsync("card-9", null));
        var lines = File.ReadAllLines(calls);
        Assert.StartsWith("compose -p card-9 down -v", lines[0]);
        Assert.StartsWith("volume ls -q --filter label=com.docker.compose.project=card-9", lines[1]);
        Assert.StartsWith("volume rm card-9_db", lines[2]);
        Assert.Equal(["card-9"], await envs.ListProjectsAsync());
        var (broken, _, _) = FakeDocker(code: 1);
        Assert.False(await broken.RemoveAsync("card-9", null));
        await Assert.ThrowsAsync<InvalidOperationException>(() => broken.ListProjectsAsync());
    }
}
