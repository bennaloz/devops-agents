using DevOpsAgents.Core.Ports;
using DevOpsAgents.Core.Supervision;

namespace DevOpsAgents.Api.Demo;

/// <summary>Le pipeline della demo: un rilascio da approvare, una build in coda, un fallito per infrastruttura e uno senza causa, un agente offline.</summary>
public sealed class DemoPipelines : IPipelineReader
{
    public Task<PipelineView> ReadAsync(IReadOnlyCollection<string> mapProjects, IReadOnlyCollection<int> deployDefinitions, DateTimeOffset now, CancellationToken ct = default)
    {
        var p = mapProjects.FirstOrDefault() ?? "Acme.AI";
        RunInfo Run(int id, string pipeline, string branch, string status, string? stage, int minutesAgo, string? result, int def, string kind, bool orch = false) =>
            new(id, p, pipeline, branch, "Titolare", status, stage, now.AddMinutes(-minutesAgo), status == "concluso" ? now.AddMinutes(-minutesAgo + 6) : null, result, def, kind,
                $"https://example.invalid/{p}/_build/results?buildId={id}", orch, Agent: status == "inCorso" ? "srv-build-1" : null, Pool: status == "inCorso" ? "interno" : null);
        var failed = new[] { Run(9301, "build-ci", "develop", "concluso", null, 240, "failed", 5, "ci"), Run(9302, "build-ci", "develop", "concluso", null, 90, "failed", 6, "ci") };
        return Task.FromResult(new PipelineView(true, null,
            [Run(9310, "build-ci", "develop", "inCorso", "Test", 4, null, 5, "ci"), Run(9311, "nightly", "develop", "inCoda", null, 75, null, 7, "pianificato")],
            [Run(9320, "release-orchestrator", "main", "inAttesa", "Produzione", 30, null, 9, "rilascio", true)],
            failed, [],
            [new AgentPool("Interni", [new AgentInfo("srv-build-1", true, true, 9310, "build-ci"), new AgentInfo("srv-build-2", false, true)])], true, [],
            new Dictionary<int, string> { [9301] = "##[error] lost communication with the server", [9302] = "error CS1002: ; expected" },
            new Dictionary<string, (int, string?)> { [$"{p}|5|develop"] = (9310, null), [$"{p}|6|develop"] = (9302, "failed") }));
    }

    public Task<int> RerunAsync(RunInfo run, CancellationToken ct = default) => Task.FromResult(run.Id + 1000);
}
