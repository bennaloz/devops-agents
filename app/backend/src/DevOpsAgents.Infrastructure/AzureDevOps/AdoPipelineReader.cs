using System.Text.Json.Nodes;
using DevOpsAgents.Core.Ports;
using DevOpsAgents.Core.Supervision;
using static DevOpsAgents.Infrastructure.AzureDevOps.AdoClient;

namespace DevOpsAgents.Infrastructure.AzureDevOps;

/// <summary>
/// Le pipeline di tutti i progetti (Get-AdoBuildPipeline e compagne di src/Ado.psm1): run in corso, in coda o in attesa di approvazione, i falliti o
/// annullati delle ultime ore, gli ultimi run degli orchestrator di rilascio, gli agenti dei pool interni; per i falliti che il supervisore guarda il
/// motivo e l'ultimo run della stessa definizione sul ramo. Un progetto che non risponde non ferma gli altri. Solo GET, tranne il rilancio.
/// </summary>
public sealed class AdoPipelineReader(AdoClient ado, int hours = 24, int lastOrchestratorRuns = 5) : IPipelineReader
{
    public async Task<PipelineView> ReadAsync(IReadOnlyCollection<string> mapProjects, IReadOnlyCollection<int> deployDefinitions, DateTimeOffset now, CancellationToken ct = default)
    {
        List<string> projects;
        try { projects = (await ado.GetAsync("/_apis/projects?$top=500&api-version=7.1", ct)).Items("value").Select(p => p.Str("name")!).ToList(); }
        catch (Exception e) when (e is not OperationCanceledException) { return PipelineView.Unread(e.Message); }
        var active = new List<RunInfo>(); var failed = new List<RunInfo>(); var orch = new List<RunInfo>(); var errors = new List<string>();
        var since = E(now.UtcDateTime.AddHours(-hours).ToString("o"));
        foreach (var p in projects)
        {
            var b = $"/{E(p)}/_apis/build/builds";
            List<JsonNode> live, closed;
            try
            {
                live = (await ado.GetAsync($"{b}?statusFilter=inProgress,notStarted,postponed&$top=100&api-version=7.1", ct)).Items("value").ToList();
                closed = (await ado.GetAsync($"{b}?statusFilter=completed&resultFilter=failed,canceled&minTime={since}&$top=100&api-version=7.1", ct)).Items("value").ToList();
            }
            catch (Exception e) when (e is not OperationCanceledException) { errors.Add($"{p}: {e.Message}"); continue; }
            // i release-orchestrator (cercati per nome) hanno il loro blocco: gli ultimi run, in corso o conclusi
            try
            {
                var ids = (await ado.GetAsync($"/{E(p)}/_apis/build/definitions?name=*orchestrator*&api-version=7.1", ct)).Items("value")
                    .Where(d => (d.Str("name") ?? "").Contains("orchestrator", StringComparison.OrdinalIgnoreCase)).Select(d => d.Int("id")!.Value).ToList();
                if (ids.Count > 0)
                {
                    var ob = (await ado.GetAsync($"{b}?definitions={string.Join(',', ids)}&queryOrder=queueTimeDescending&$top={lastOrchestratorRuns}&api-version=7.1", ct)).Items("value").ToList();
                    var obIds = ob.Select(x => x.Int("id")).ToHashSet();
                    live = live.Where(x => !obIds.Contains(x.Int("id"))).ToList();
                    closed = closed.Where(x => !obIds.Contains(x.Int("id"))).ToList();
                    foreach (var x in ob) orch.Add(await ToRunAsync(x, p, true, ct));
                }
            }
            catch (Exception e) when (e is not OperationCanceledException) { errors.Add($"{p} (orchestrator): {e.Message}"); }
            foreach (var x in live) active.Add(await ToRunAsync(x, p, false, ct));
            failed.AddRange(closed.Select(x => Run(x, p, "concluso", null, null, false)));
        }
        var agentErrors = new List<string>();
        var pools = await PoolsAsync(agentErrors, ct);
        // il motivo e l'ultimo run di quella definizione e ramo solo per i falliti che il supervisore guarda, e al piu per i dieci piu recenti
        var reasons = new Dictionary<int, string>();
        var latest = new Dictionary<string, (int, string?)>();
        foreach (var f in PipelineRules.ToExamine(failed, mapProjects, deployDefinitions).OrderByDescending(f => f.Id).Take(10))
        {
            try { reasons[f.Id] = await FailureReasonAsync(f.Project, f.Id, ct); } catch (Exception e) when (e is not OperationCanceledException) { reasons[f.Id] = ""; }
            var k = PipelineRules.LatestKey(f);
            if (latest.ContainsKey(k) || f.Branch.StartsWith("PR #", StringComparison.Ordinal)) continue;
            try
            {
                var u = (await ado.GetAsync($"/{E(f.Project)}/_apis/build/builds?definitions={f.DefinitionId}&branchName={E($"refs/heads/{f.Branch}")}&queryOrder=queueTimeDescending&$top=1&api-version=7.1", ct)).Items("value").FirstOrDefault();
                if (u is not null) latest[k] = (u.Int("id")!.Value, u.Str("result"));
            }
            catch (Exception e) when (e is not OperationCanceledException) { }
        }
        return new PipelineView(true, null, active, orch, failed, errors, pools, agentErrors.Count == 0, agentErrors, reasons, latest);
    }

    private async Task<RunInfo> ToRunAsync(JsonNode b, string project, bool orchestrator, CancellationToken ct)
    {
        var status = b.Str("status");
        if (status == "completed") return Run(b, project, "concluso", null, null, orchestrator);
        if (status != "inProgress") return Run(b, project, "inCoda", null, null, orchestrator);
        var phase = new PipelineRules.Phase(false, null, null, []);
        try { phase = PipelineRules.PhaseOf((await ado.GetAsync($"/{E(project)}/_apis/build/builds/{b.Int("id")}/timeline?api-version=7.1", ct))?["records"] as JsonArray); }
        catch (Exception e) when (e is not OperationCanceledException) { }
        return Run(b, project, phase.Approval ? "inAttesa" : phase.Waiting is not null ? "inCoda" : "inCorso", phase.Stage, phase.Waiting, orchestrator, phase.Workers);
    }

    private RunInfo Run(JsonNode b, string project, string status, string? stage, string? waiting, bool orchestrator, IReadOnlyList<string>? workers = null)
    {
        var def = b["definition"];
        var name = def.Str("name") ?? "";
        var tp = (b["templateParameters"] as JsonObject)?.ToDictionary(kv => kv.Key, kv => kv.Value?.ToString() ?? "");
        var components = tp?.Where(kv => kv.Key.StartsWith("deploy", StringComparison.Ordinal) && kv.Value == "true").Select(kv => kv.Key).ToList();
        var start = b.Date(status == "inCoda" ? "queueTime" : "startTime") ?? b.Date("queueTime");
        // su che agenti gira: "Azure Pipelines N" e "Hosted Agent" sono quelli di Microsoft, ogni altro nome e un agente nostro
        var mine = (workers ?? []).Where(w => !w.StartsWith("Azure Pipelines", StringComparison.Ordinal) && !w.StartsWith("Hosted Agent", StringComparison.Ordinal)).Distinct().ToList();
        var hosted = (workers ?? []).Count > mine.Count;
        var pool = (workers ?? []).Count == 0 ? null : mine.Count == 0 ? "cloud" : hosted ? "misto" : "interno";
        return new RunInfo(b.Int("id")!.Value, project, name, PipelineRules.Branch(b.Str("sourceBranch")), b.Str("requestedFor", "displayName"), status, stage,
            start, b.Date("finishTime"), b.Str("result"), def.Int("id") ?? 0, PipelineRules.Kind(name, b.Str("reason"), orchestrator),
            $"{ado.Organization}/{E(project)}/_build/results?buildId={b.Int("id")}", orchestrator, components, waiting, b.Str("sourceVersion"), tp,
            mine.Count > 0 ? string.Join(", ", mine) : null, pool);
    }

    /// <summary>Gli agenti dei pool interni (non ospitati da Microsoft), con lo stato e il lavoro che stanno facendo.</summary>
    private async Task<IReadOnlyList<AgentPool>> PoolsAsync(List<string> errors, CancellationToken ct)
    {
        List<JsonNode> pools;
        try { pools = (await ado.GetAsync("/_apis/distributedtask/pools?api-version=7.1", ct)).Items("value").Where(p => p.Bool("isHosted") != true).ToList(); }
        catch (Exception e) when (e is not OperationCanceledException) { errors.Add($"pool degli agenti: {e.Message}"); return []; }
        var result = new List<AgentPool>();
        foreach (var p in pools)
        {
            List<JsonNode> agents;
            try { agents = (await ado.GetAsync($"/_apis/distributedtask/pools/{p.Int("id")}/agents?includeAssignedRequest=true&api-version=7.1", ct)).Items("value").ToList(); }
            catch (Exception e) when (e is not OperationCanceledException) { errors.Add($"agenti del pool {p.Str("name")}: {e.Message}"); continue; }
            if (agents.Count == 0) continue;
            result.Add(new AgentPool(p.Str("name") ?? "", agents.OrderBy(a => a.Str("name"), StringComparer.Ordinal).Select(a =>
            {
                var rq = a["assignedRequest"];
                return new AgentInfo(a.Str("name") ?? "", a.Str("status") == "online", a.Bool("enabled") != false, rq?["owner"].Int("id"), rq?["definition"].Str("name"), rq?["owner"]?["_links"]?["web"].Str("href"));
            }).ToList()));
        }
        return result;
    }

    /// <summary>Il motivo di un fallimento (Get-AdoMotivoFallimento): i messaggi dei passi falliti e le ultime righe del log del primo passo fallito.</summary>
    public async Task<string> FailureReasonAsync(string project, int buildId, CancellationToken ct = default)
    {
        var t = await ado.GetAsync($"/{E(project)}/_apis/build/builds/{buildId}/timeline?api-version=7.1", ct);
        var failedRecs = t.Items("records").Where(r => r.Str("result") == "failed").ToList();
        var lines = failedRecs.SelectMany(r => r.Items("issues")).Select(i => i.Str("message")?.Trim()).Where(m => !string.IsNullOrEmpty(m)).Cast<string>().ToList();
        if (failedRecs.FirstOrDefault(r => r.Str("type") == "Task")?["log"].Str("url") is { Length: > 0 } url)
        {
            try
            {
                var log = (await ado.GetAsync($"{url}?api-version=7.1", ct))?.ToString() ?? "";
                lines.AddRange(log.Split('\n').Select(l => System.Text.RegularExpressions.Regex.Replace(l, @"^\d{4}-\d\d-\d\dT[\d:.]+Z ?", "").TrimEnd()).Where(l => l.Length > 0).TakeLast(15));
            }
            catch (Exception e) when (e is not OperationCanceledException) { }
        }
        var text = string.Join("\n", lines);
        return text.Length > 2000 ? text[..2000] : text;
    }

    /// <summary>Start-AdoRilancioRun: la stessa definizione, lo stesso ramo, la stessa versione e gli stessi parametri. Un ramo di PR non si rilancia.</summary>
    public async Task<int> RerunAsync(RunInfo run, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(run.Branch) || run.Branch.StartsWith("PR #", StringComparison.Ordinal)) throw new InvalidOperationException($"'{run.Branch}' non e un ramo, non rilancio niente");
        var body = new JsonObject { ["definition"] = new JsonObject { ["id"] = run.DefinitionId }, ["sourceBranch"] = $"refs/heads/{run.Branch}" };
        if (!string.IsNullOrWhiteSpace(run.SourceVersion)) body["sourceVersion"] = run.SourceVersion;
        if (run.TemplateParameters is { Count: > 0 } tp) body["templateParameters"] = new JsonObject(tp.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)kv.Value)));
        var r = await ado.SendAsync(HttpMethod.Post, $"/{E(run.Project)}/_apis/build/builds?api-version=7.1", body, ct: ct);
        return r.Int("id")!.Value;
    }
}
