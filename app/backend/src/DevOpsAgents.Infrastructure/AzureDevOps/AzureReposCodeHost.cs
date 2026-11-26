using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;
using static DevOpsAgents.Infrastructure.AzureDevOps.AdoClient;

namespace DevOpsAgents.Infrastructure.AzureDevOps;

/// <summary>Il codice su Azure Repos: PR e validazioni (le policy di build), come Get-AdoPr e compagne in src/Ado.psm1.</summary>
public sealed class AzureReposCodeHost(AdoClient ado) : ICodeHost
{
    public const string Signature = "🤖 Generated with [Claude Code](https://claude.com/claude-code)";

    public bool NeedsCardLink => false;

    private static string RepoUrl(AreaMapping a) => $"/{E(a.AdoProject)}/_apis/git/repositories/{E(a.Repo)}";

    private Task<System.Text.Json.Nodes.JsonNode?> ListAsync(AreaMapping a, string branch, string destination, string status, CancellationToken ct) =>
        ado.GetAsync($"{RepoUrl(a)}/pullrequests?searchCriteria.sourceRefName=refs/heads/{branch}&searchCriteria.targetRefName=refs/heads/{destination}&searchCriteria.status={status}&api-version=7.1", ct);

    public async Task<PullRequestInfo?> GetPullRequestAsync(AreaMapping area, string branch, string destination, bool includeCompleted, CancellationToken ct = default)
    {
        var list = (await ListAsync(area, branch, destination, includeCompleted ? "all" : "active", ct)).Items("value").ToList();
        var pr = list.FirstOrDefault(p => p.Str("status") == PrStatuses.Active);
        if (pr is null)
        {
            var done = includeCompleted ? list.FirstOrDefault(p => p.Str("status") == PrStatuses.Completed) : null;
            return done is null ? null : new PullRequestInfo(done.Int("pullRequestId")!.Value, PrStatuses.Completed, Validations.None, null, null, done.Str("lastMergeSourceCommit", "commitId"));
        }

        var projectId = pr.Str("repository", "project", "id");
        var head = pr.Str("lastMergeSourceCommit", "commitId");
        var artifact = E($"vstfs:///CodeReview/CodeReviewId/{projectId}/{pr.Int("pullRequestId")}");
        var ev = await ado.GetAsync($"/{projectId}/_apis/policy/evaluations?artifactId={artifact}&api-version=7.1-preview.1", ct);

        // Ogni valutazione di build diventa verde / rossa / inCorso / scaduta. Una build che non e girata sul commit di testa
        // vale inCorso, qualunque sia il suo esito: un esito vecchio non fa partire niente dopo un nuovo push.
        var results = ev.Items("value")
            .Where(e => e.Str("configuration", "type", "displayName") == "Build" && e.Str("status") != "notApplicable")
            .Select(e =>
            {
                var c = e["context"];
                var build = c.Int("buildId");
                string v = c.Bool("isExpired") == true ? Validations.Expired : e.Str("status") switch
                {
                    "approved" => Validations.Green,
                    "rejected" or "broken" => Validations.Red,
                    _ => Validations.Running,
                };
                if (v is Validations.Green or Validations.Red && (build is null || c.Str("lastMergeSourceCommitId") != head || c.Bool("buildIsNotCurrent") == true))
                    v = Validations.Running;
                return (Validation: v, BuildId: build);
            }).ToList();

        // Il giudice e la PR unibile: conflitti fermano tutto; senza build applicabili la PR e unibile a merge controllato.
        var merge = pr.Str("mergeStatus");
        var validation = merge == "succeeded" ? Validations.Green : Validations.Running;
        int? buildId = null;
        if (merge == "conflicts") validation = Validations.Conflicts;
        else if (results.Count > 0)
        {
            (string V, int? B) pick(string v) => results.Where(r => r.Validation == v).Select(r => (r.Validation, r.BuildId)).LastOrDefault();
            if (results.Any(r => r.Validation == Validations.Running)) (validation, buildId) = pick(Validations.Running);
            else if (results.Any(r => r.Validation == Validations.Red)) (validation, buildId) = pick(Validations.Red);
            else if (results.Any(r => r.Validation == Validations.Expired)) (validation, buildId) = pick(Validations.Expired);
            else (validation, buildId) = (Validations.Green, results[^1].BuildId);
        }
        var log = buildId is { } b ? $"{ado.Organization}/{E(area.AdoProject)}/_build/results?buildId={b}" : null;
        return new PullRequestInfo(pr.Int("pullRequestId")!.Value, PrStatuses.Active, validation, buildId, log, head);
    }

    public async Task<(int Id, string Url)> CreatePullRequestAsync(AreaMapping area, string branch, string destination, string title, string description, int cardId, CancellationToken ct = default)
    {
        var body = new Dictionary<string, object>
        {
            ["sourceRefName"] = $"refs/heads/{branch}",
            ["targetRefName"] = $"refs/heads/{destination}",
            ["title"] = title,
            ["description"] = $"{description}\n\n{Signature}",
        };
        if (cardId > 0) body["workItemRefs"] = new[] { new { id = cardId.ToString() } };
        var r = await ado.SendAsync(HttpMethod.Post, $"{RepoUrl(area)}/pullrequests?api-version=7.1", body, ct: ct);
        var id = r.Int("pullRequestId")!.Value;
        return (id, PullRequestUrl(area, id));
    }

    public async Task CompletePullRequestAsync(AreaMapping area, int prId, string? commit, CancellationToken ct = default)
    {
        var url = $"{RepoUrl(area)}/pullrequests/{prId}?api-version=7.1";
        commit ??= (await ado.GetAsync(url, ct)).Str("lastMergeSourceCommit", "commitId");
        // noFastForward = merge commit: il ramo assorbito si riconosce con merge-base --is-ancestor
        await ado.SendAsync(HttpMethod.Patch, url, new
        {
            status = "completed",
            lastMergeSourceCommit = new { commitId = commit },
            completionOptions = new { deleteSourceBranch = true, mergeStrategy = "noFastForward" },
        }, ct: ct);
    }

    public async Task<int> RequeueValidationsAsync(AreaMapping area, string branch, string destination, bool expiredOnly, CancellationToken ct = default)
    {
        var pr = (await ListAsync(area, branch, destination, "active", ct)).Items("value").FirstOrDefault(p => p.Str("status") == PrStatuses.Active);
        if (pr is null) return 0;
        var projectId = pr.Str("repository", "project", "id");
        var artifact = E($"vstfs:///CodeReview/CodeReviewId/{projectId}/{pr.Int("pullRequestId")}");
        var ev = await ado.GetAsync($"/{projectId}/_apis/policy/evaluations?artifactId={artifact}&api-version=7.1-preview.1", ct);
        var todo = ev.Items("value").Where(e => e.Str("configuration", "type", "displayName") == "Build")
            .Where(e => expiredOnly ? e["context"].Bool("isExpired") == true : e.Str("status") is "rejected" or "broken").ToList();
        foreach (var e in todo)
            await ado.SendAsync(HttpMethod.Patch, $"/{projectId}/_apis/policy/evaluations/{e.Str("evaluationId")}?api-version=7.1-preview.1", ct: ct);
        return todo.Count;
    }

    public string PullRequestUrl(AreaMapping area, int prId) => $"{ado.Organization}/{E(area.AdoProject)}/_git/{E(area.Repo)}/pullrequest/{prId}";
}

/// <summary>Il deploy in Test su Azure Pipelines, per i repo di Azure Repos e di GitHub.</summary>
public sealed class AzurePipelinesCi(AdoClient ado) : ICiService
{
    public async Task<int> QueueTestDeployAsync(AreaMapping area, string branch, IReadOnlyList<string> on, IReadOnlyList<string> off, CancellationToken ct = default)
    {
        if (area.DeployPipeline is not { } pipeline) throw new InvalidOperationException($"L'area {area.Area} non ha pipelineDeploy nella mappa");
        if (on.Count == 0) throw new InvalidOperationException("nessun parametro di deploy, non accodo niente");
        var parameters = off.ToDictionary(p => p, _ => "false");
        foreach (var p in on) parameters[p] = "true";
        var r = await ado.SendAsync(HttpMethod.Post, $"/{E(area.AdoProject)}/_apis/pipelines/{pipeline}/runs?api-version=7.1", new
        {
            resources = new { repositories = new { self = new { refName = $"refs/heads/{branch}" } } },
            templateParameters = parameters,
        }, ct: ct);
        return r.Int("id")!.Value;
    }

    public async Task<PipelineRun> GetRunAsync(AreaMapping area, int runId, CancellationToken ct = default)
    {
        var r = await ado.GetAsync($"/{E(area.AdoProject)}/_apis/build/builds/{runId}?api-version=7.1", ct);
        return new PipelineRun(r.Str("status") ?? "", r.Str("result"), $"{ado.Organization}/{E(area.AdoProject)}/_build/results?buildId={runId}", r.Str("sourceVersion"));
    }
}
