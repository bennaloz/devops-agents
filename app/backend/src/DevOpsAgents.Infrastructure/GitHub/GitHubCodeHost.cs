using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;
using DevOpsAgents.Infrastructure.AzureDevOps;

namespace DevOpsAgents.Infrastructure.GitHub;

/// <summary>
/// Il codice su GitHub (area con "sorgente": "github"): PR, controlli sul commit di testa, merge, rilanci. Come src/GitHub.psm1.
/// Le build di Azure Pipelines che validano un repo GitHub si rilanciano su Azure DevOps (<paramref name="ado"/>).
/// </summary>
public sealed class GitHubCodeHost(HttpClient http, Func<string> token, AdoClient? ado = null) : ICodeHost, IPullRequestEditor
{
    public const string Api = "https://api.github.com";
    public bool NeedsCardLink => true;

    private static string Repo(AreaMapping a)
    {
        if (a.GitHubRepo is not { } r || !Regex.IsMatch(r, @"^[\w.-]+/[\w.-]+$")) throw new InvalidOperationException($"repoGithub '{a.GitHubRepo}' non e nella forma <owner>/<repo>");
        return r;
    }

    private async Task<JsonNode?> SendAsync(HttpMethod method, string path, object? body = null, string? accept = null, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(method, $"{Api}{path}");
        var t = token();
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", t);
        req.Headers.Accept.ParseAdd(accept ?? "application/vnd.github+json");
        req.Headers.UserAgent.ParseAdd("DevOps.Agents");
        req.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        if (body is not null) req.Content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        using var res = await http.SendAsync(req, ct);
        var text = await res.Content.ReadAsStringAsync(ct);
        if (!res.IsSuccessStatusCode)
            throw new HttpRequestException($"Chiamata a GitHub fallita ({method} {Api}{path}): {(int)res.StatusCode} {(text.Length > 500 ? text[..500] : text)}".Replace(t, "***"), null, res.StatusCode);
        if (string.IsNullOrWhiteSpace(text)) return null;
        try { return JsonNode.Parse(text); } catch (System.Text.Json.JsonException) { return JsonValue.Create(text); }
    }

    public static string StatusOf(JsonNode pr) => pr.Str("state") == "open" ? PrStatuses.Active : pr["merged_at"] is not null ? PrStatuses.Completed : PrStatuses.Abandoned;

    private async Task<List<JsonNode>> ListAsync(string repo, string branch, string destination, string state, CancellationToken ct)
    {
        var owner = repo.Split('/')[0];
        var r = await SendAsync(HttpMethod.Get, $"/repos/{repo}/pulls?head={Uri.EscapeDataString($"{owner}:{branch}")}&base={Uri.EscapeDataString(destination)}&state={state}&per_page=100", ct: ct);
        return r.Items().OrderByDescending(p => p.Int("number")).ToList();
    }

    /// <summary>Un controllo (check run o status) diventa verde / rossa / inCorso.</summary>
    public static string OutcomeOf(JsonNode c)
    {
        if (c["state"] is not null)
            return c.Str("state") switch { "success" => Validations.Green, "failure" or "error" => Validations.Red, _ => Validations.Running };
        if (c.Str("status") != "completed") return Validations.Running;
        return c.Str("conclusion") switch
        {
            "success" or "neutral" or "skipped" => Validations.Green,
            "failure" or "timed_out" or "cancelled" or "action_required" or "startup_failure" => Validations.Red,
            _ => Validations.Running,
        };
    }

    /// <summary>Da dove viene un controllo: una build di Azure Pipelines (buildId) o un run di GitHub Actions.</summary>
    public static (string? Url, int? AdoBuild, long? ActionsRun) OriginOf(JsonNode c)
    {
        var url = c.Str("details_url") ?? c.Str("target_url") ?? c.Str("html_url");
        var b = Regex.Match(url ?? "", @"[?&]buildId=(\d+)");
        var r = Regex.Match(url ?? "", @"/actions/runs/(\d+)");
        return (url, b.Success ? int.Parse(b.Groups[1].Value) : null, r.Success ? long.Parse(r.Groups[1].Value) : null);
    }

    private async Task<List<JsonNode>> ChecksAsync(string repo, string sha, CancellationToken ct)
    {
        var runs = await SendAsync(HttpMethod.Get, $"/repos/{repo}/commits/{sha}/check-runs?per_page=100", ct: ct);
        var status = await SendAsync(HttpMethod.Get, $"/repos/{repo}/commits/{sha}/status", ct: ct);
        return runs.Items("check_runs").Concat(status.Items("statuses")).ToList();
    }

    public async Task<PullRequestInfo?> GetPullRequestAsync(AreaMapping area, string branch, string destination, bool includeCompleted, CancellationToken ct = default)
    {
        var repo = Repo(area);
        var list = await ListAsync(repo, branch, destination, includeCompleted ? "all" : "open", ct);
        var open = list.FirstOrDefault(p => StatusOf(p) == PrStatuses.Active);
        if (open is null)
        {
            var merged = includeCompleted ? list.FirstOrDefault(p => StatusOf(p) == PrStatuses.Completed) : null;
            return merged is null ? null : new PullRequestInfo(merged.Int("number")!.Value, PrStatuses.Completed, Validations.None, null, null, merged.Str("head", "sha"));
        }
        // l'elenco non porta mergeable: si rilegge la PR. null = GitHub lo sta ancora calcolando
        var pr = (await SendAsync(HttpMethod.Get, $"/repos/{repo}/pulls/{open.Int("number")}", ct: ct))!;
        var head = pr.Str("head", "sha")!;
        var mergeable = pr.Bool("mergeable");
        var state = pr.Str("mergeable_state");
        var checks = (await ChecksAsync(repo, head, ct)).Select(c => (V: OutcomeOf(c), O: OriginOf(c))).ToList();

        string validation;
        (string V, (string? Url, int? AdoBuild, long? ActionsRun) O)? chosen = null;
        if (state == "dirty" || mergeable == false) validation = Validations.Conflicts;
        else if (checks.Any(c => c.V == Validations.Running)) { validation = Validations.Running; chosen = checks.Last(c => c.V == Validations.Running); }
        else if (checks.Any(c => c.V == Validations.Red)) { validation = Validations.Red; chosen = checks.Last(c => c.V == Validations.Red); }
        else if (mergeable is null || state == "unknown") validation = Validations.Running;
        else { validation = Validations.Green; if (checks.Count > 0) chosen = checks[^1]; }

        var build = chosen?.O.AdoBuild;
        var log = build is { } b && ado is not null ? $"{ado.Organization}/{Uri.EscapeDataString(area.AdoProject)}/_build/results?buildId={b}" : chosen?.O.Url;
        return new PullRequestInfo(pr.Int("number")!.Value, PrStatuses.Active, validation, build, log, head);
    }

    public async Task<(int Id, string Url)> CreatePullRequestAsync(AreaMapping area, string branch, string destination, string title, string description, int cardId, CancellationToken ct = default)
    {
        // AB#<id>: se sul repo c'e l'app Azure Boards la PR compare anche sulla card; il collegamento sicuro e il link sulla card
        var body = $"{description}\n\n{AzureReposCodeHost.Signature}" + (cardId > 0 ? $"\n\nAB#{cardId}" : "");
        var r = await SendAsync(HttpMethod.Post, $"/repos/{Repo(area)}/pulls", new { title, head = branch, @base = destination, body }, ct: ct);
        return (r.Int("number")!.Value, r.Str("html_url")!);
    }

    public async Task CompletePullRequestAsync(AreaMapping area, int prId, string? commit, CancellationToken ct = default)
    {
        var repo = Repo(area);
        var pr = await SendAsync(HttpMethod.Get, $"/repos/{repo}/pulls/{prId}", ct: ct);
        commit ??= pr.Str("head", "sha");
        // merge commit sul commit verificato: se la testa e cambiata dopo, GitHub rifiuta
        await SendAsync(HttpMethod.Put, $"/repos/{repo}/pulls/{prId}/merge", new { merge_method = "merge", sha = commit }, ct: ct);
        if (pr.Str("head", "ref") is { } branch)
        {
            try { await SendAsync(HttpMethod.Delete, $"/repos/{repo}/git/refs/heads/{branch}", ct: ct); }
            catch (HttpRequestException) { /* gia cancellato da GitHub (l'opzione del repo): non e un errore */ }
        }
    }

    public async Task<int> RequeueValidationsAsync(AreaMapping area, string branch, string destination, bool expiredOnly, CancellationToken ct = default)
    {
        if (expiredOnly) return 0; // su GitHub un controllo e legato al commit: non ci sono validazioni scadute
        var repo = Repo(area);
        var pr = (await ListAsync(repo, branch, destination, "open", ct)).FirstOrDefault();
        if (pr is null) return 0;
        var red = (await ChecksAsync(repo, pr.Str("head", "sha")!, ct)).Where(c => OutcomeOf(c) == Validations.Red).Select(OriginOf).ToList();
        var runs = red.Where(o => o.ActionsRun is not null).Select(o => o.ActionsRun!.Value).Distinct().ToList();
        foreach (var run in runs) await SendAsync(HttpMethod.Post, $"/repos/{repo}/actions/runs/{run}/rerun-failed-jobs", ct: ct);
        var builds = red.Where(o => o.AdoBuild is not null).Select(o => o.AdoBuild!.Value).Distinct().ToList();
        if (ado is not null)
            foreach (var b in builds)
                await ado.SendAsync(HttpMethod.Patch, $"/{Uri.EscapeDataString(area.AdoProject)}/_apis/build/builds/{b}?retry=true&api-version=7.1", ct: ct);
        return runs.Count + (ado is null ? 0 : builds.Count);
    }

    public string PullRequestUrl(AreaMapping area, int prId) => $"https://github.com/{Repo(area)}/pull/{prId}";

    public async Task<IReadOnlyList<string>> ListBranchesAsync(AreaMapping area, string prefix, CancellationToken ct = default) =>
        (await SendAsync(HttpMethod.Get, $"/repos/{Repo(area)}/git/matching-refs/heads/{prefix}", ct: ct)).Items()
            .Select(r => (r.Str("ref") ?? "").Replace("refs/heads/", "")).Where(n => n.Length > 0).ToList();

    public async Task<(string Status, string Branch)?> GetPullRequestByIdAsync(AreaMapping area, int prId, CancellationToken ct = default)
    {
        var pr = await SendAsync(HttpMethod.Get, $"/repos/{Repo(area)}/pulls/{prId}", ct: ct);
        return pr is null ? null : (StatusOf(pr), pr.Str("head", "ref") ?? "");
    }

    public async Task<string> GetDescriptionAsync(AreaMapping area, int prId, CancellationToken ct = default) =>
        (await SendAsync(HttpMethod.Get, $"/repos/{Repo(area)}/pulls/{prId}", ct: ct)).Str("body") ?? "";

    /// <summary>Come Set-GhPr: il testo e la firma.</summary>
    public Task SetDescriptionAsync(AreaMapping area, int prId, string description, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Patch, $"/repos/{Repo(area)}/pulls/{prId}", new { body = $"{description}\n\n{AzureReposCodeHost.Signature}" }, ct: ct);

    public Task SetTitleAsync(AreaMapping area, int prId, string title, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Patch, $"/repos/{Repo(area)}/pulls/{prId}", new { title }, ct: ct);

    /// <summary>Un file del repo sul ramo, come testo (lo YAML di una pipeline di Azure Pipelines su un repo GitHub).</summary>
    public async Task<string> GetFileAsync(string repo, string path, string branch, CancellationToken ct = default)
    {
        if (!Regex.IsMatch(repo, @"^[\w.-]+/[\w.-]+$")) throw new InvalidOperationException($"repo GitHub '{repo}' non e nella forma <owner>/<repo>");
        var p = string.Join('/', path.TrimStart('/').Split('/').Select(Uri.EscapeDataString));
        var r = await SendAsync(HttpMethod.Get, $"/repos/{repo}/contents/{p}?ref={Uri.EscapeDataString(branch)}", accept: "application/vnd.github.raw+json", ct: ct);
        return r is JsonValue v && v.TryGetValue<string>(out var text) ? text : r?.ToJsonString() ?? "";
    }
}

/// <summary>Sceglie Azure Repos o GitHub per l'area.</summary>
public sealed class CodeHostResolver(AzureReposCodeHost azure, GitHubCodeHost github) : ICodeHostResolver
{
    public ICodeHost For(AreaMapping area) => area.Source == SourceControl.GitHub ? github : azure;
}
