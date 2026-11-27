using System.Text.Json.Nodes;
using DevOpsAgents.Core.Supervision;
using Xunit;

namespace DevOpsAgents.Core.Tests;

/// <summary>D51, le pipeline e la diagnosi: i casi di tests/Supervisione.Tests.ps1 e di Ado.Tests.ps1 sul modo di leggere un run.</summary>
public class PipelineRulesTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 26, 10, 0, 0, TimeSpan.Zero);

    private static RunInfo Run(int id, string pipeline = "build-ci", string branch = "develop", string status = "concluso", string? result = "failed", int def = 5,
        string kind = "ci", string project = "Acme.AI", DateTimeOffset? start = null) =>
        new(id, project, pipeline, branch, "Titolare", status, null, start, null, result, def, kind, $"https://run/{id}");

    private static PipelineView View(IReadOnlyList<RunInfo>? failed = null, IReadOnlyList<RunInfo>? active = null, Dictionary<int, string>? reasons = null,
        Dictionary<string, (int, string?)>? latest = null, IReadOnlyList<AgentPool>? pools = null) =>
        new(true, null, active ?? [], [], failed ?? [], [], pools ?? [], true, [], reasons ?? new(), latest ?? new());

    [Fact]
    public void Tipo_e_ramo_di_un_run()
    {
        Assert.Equal(["rilascio", "pr", "rilascio", "pr", "ci", "ci", "pianificato", "manuale", "altro"],
            new[] { PipelineRules.Kind("x", null, true), PipelineRules.Kind("x", "pullRequest", false), PipelineRules.Kind("deploy-test", "manual", false),
                PipelineRules.Kind("pr-validation", "manual", false), PipelineRules.Kind("x", "individualCI", false), PipelineRules.Kind("build-ci", null, false),
                PipelineRules.Kind("x", "schedule", false), PipelineRules.Kind("x", "manual", false), PipelineRules.Kind("x", null, false) });
        Assert.Equal(["develop", "PR #12"], new[] { PipelineRules.Branch("refs/heads/develop"), PipelineRules.Branch("refs/pull/12/merge") });
    }

    private static JsonArray Records(params string[] json) => new(json.Select(j => JsonNode.Parse(j)).ToArray());

    [Fact]
    public void La_fase_di_un_run_dalla_timeline()
    {
        var approval = PipelineRules.PhaseOf(Records(
            """{"id":"s","type":"Stage","name":"Produzione","state":"inProgress"}""",
            """{"id":"c","parentId":"s","type":"Checkpoint","state":"inProgress"}""",
            """{"id":"a","parentId":"c","type":"Checkpoint.Approval","state":"inProgress"}"""));
        Assert.Equal((true, "Produzione"), (approval.Approval, approval.Stage));
        var check = PipelineRules.PhaseOf(Records("""{"id":"s","type":"Stage","name":"Test","state":"pending","order":1}""", """{"id":"c","type":"Checkpoint","state":"inProgress"}"""));
        Assert.Equal(("controllo", "Test"), (check.Waiting, check.Stage));
        var agent = PipelineRules.PhaseOf(Records("""{"id":"s","type":"Stage","name":"Build","state":"inProgress"}""", """{"id":"j","parentId":"s","type":"Job","name":"Compila","state":"pending"}"""));
        Assert.Equal(("agente", "Compila"), (agent.Waiting, agent.Stage));
        var running = PipelineRules.PhaseOf(Records("""{"id":"s","type":"Stage","name":"__default","state":"inProgress"}""",
            """{"id":"j","parentId":"s","type":"Job","name":"Test","state":"inProgress","workerName":"srv-build-1"}"""));
        Assert.Equal(("Test", null, "srv-build-1"), (running.Stage, running.Waiting, running.Workers.Single()));
    }

    [Fact]
    public void I_falliti_si_dividono_come_nel_PowerShell()
    {
        var infra = new[] { "lost communication with the server", "agent .* was not found" };
        var failed = new[]
        {
            Run(1), Run(2, def: 6), Run(3, def: 7), Run(4, def: 8), Run(5, def: 9, branch: "main"), Run(6, def: 10), Run(7, def: 11),
            Run(20, kind: "pr"), Run(21, pipeline: "deploy-test"), Run(22, branch: "feature/42-x"), Run(23, project: "Altro"), Run(24, def: 115), Run(25, result: "canceled"),
        };
        var reasons = new Dictionary<int, string> { [1] = "lost communication with the server", [2] = "agent srv-1 was not found", [3] = "error CS1002", [4] = "lost communication with the server",
            [5] = "lost communication with the server", [6] = "lost communication with the server", [7] = "lost communication with the server" };
        var latest = new Dictionary<string, (int, string?)> { ["Acme.AI|5|develop"] = (1, "failed"), ["Acme.AI|6|develop"] = (9, "succeeded"), ["Acme.AI|8|develop"] = (4, "failed"), ["Acme.AI|10|develop"] = (6, "failed"), ["Acme.AI|11|develop"] = (7, "failed") };
        var reruns = new Dictionary<string, Rerun> { ["6"] = new(Now, 70), ["99"] = new(Now, 7) };
        var g = PipelineRules.GroupFailed(View(failed, reasons: reasons, latest: latest), ["Acme.AI"], [115], reruns,
            [new("Acme.AI", 5), new("Acme.AI", 9), new("Acme.AI", 10), new("Acme.AI", 11)], infra);
        Assert.Equal([1], g.Rerunnable.Select(r => r.Id));
        Assert.Equal([2], g.Superseded.Select(r => r.Id));
        Assert.Equal([3], g.WithoutCause.Select(r => r.Id));
        Assert.Equal([4, 5], g.ToConfigure.Select(r => r.Id));
        Assert.Equal([6], g.AlreadyRerun.Select(r => r.Id));
        Assert.Equal([7], g.Repeated.Select(r => r.Id));
    }

    [Fact]
    public void I_problemi_delle_pipeline()
    {
        var pools = new[] { new AgentPool("Interni", [new AgentInfo("srv-1", false, true), new AgentInfo("srv-2", false, false), new AgentInfo("srv-3", true, true)]) };
        var active = new[] { Run(30, status: "inAttesa", result: null) with { Stage = "Produzione" }, Run(31, status: "inCoda", result: null, start: Now.AddMinutes(-90)), Run(32, status: "inCoda", result: null, start: Now.AddMinutes(-10)) };
        var g = new PipelineRules.FailedGroups([], [Run(40, branch: "main")], [], [Run(41)], [], []);
        var p = PipelineRules.Problems(View(active: active, pools: pools), Now, "https://acme.visualstudio.com", 60, g, new Dictionary<string, Rerun> { ["50"] = new(Now.AddHours(-1), null) }).ToList();
        Assert.Equal(["approvazione-30", "agente-offline-Interni-srv-1", "coda-31", "run-fallito-40", "run-fallito-41", "rilancio-fallito-50"], p.Select(x => x.Key));
        Assert.True(p[0].Urgent && p[1].Urgent);
        Assert.Contains("(fase Produzione)", p[0].Text);
        Assert.Contains("rilancialo a mano (il supervisore rilancia solo develop)", p[3].Action);
        Assert.True(p[4].Diagnose);
        Assert.Equal("lettura-pipeline", Assert.Single(PipelineRules.Problems(PipelineView.Unread("401"), Now, "", 60, g, new Dictionary<string, Rerun>())).Key);
    }

    [Fact]
    public void La_diagnosi_una_alla_volta_con_il_tetto_del_giorno_e_una_volta_per_problema()
    {
        var s = new SupervisorState();
        s.Problems["b"] = new OpenProblem { Problem = new Problem("b", "t", "a", Diagnose: true) };
        s.Problems["a"] = new OpenProblem { Problem = new Problem("a", "t", "a") };
        var utc = TimeZoneInfo.Utc;
        Assert.Equal("b", DiagnosisRules.Next(s, Now, utc, 3, false, 0, 3));
        Assert.Null(DiagnosisRules.Next(s, Now, utc, 3, true, 0, 3));
        Assert.Null(DiagnosisRules.Next(s, Now, utc, 3, false, 3, 3));
        DiagnosisRules.Count(s, Now, utc); DiagnosisRules.Count(s, Now, utc); DiagnosisRules.Count(s, Now, utc);
        Assert.Null(DiagnosisRules.Next(s, Now, utc, 3, false, 0, 3));
        Assert.Equal("b", DiagnosisRules.Next(s, Now.AddDays(1), utc, 3, false, 0, 3));
        s.Problems["b"].Diagnosis = DiagnosisRules.Failed;
        Assert.Null(DiagnosisRules.Next(s, Now.AddDays(1), utc, 3, false, 0, 3));
        Assert.Equal("la causa e il DNS fai questo", DiagnosisRules.Text("la causa e il DNS\n\nfai questo\nESITO=diagnosi"));
        Assert.Contains("ESITO=diagnosi", DiagnosisRules.Message(new Problem("k", "Il run e fallito", "aprilo", "https://run/1")));
    }

    [Fact]
    public void La_diagnosi_resta_sul_problema_aperto_e_va_nel_riepilogo()
    {
        var s = new SupervisorState();
        var o = new Observation(Now, TimeZoneInfo.Utc, false, Now, [], null, new Dictionary<int, double>(), null, null);
        var p = new Problem("run-fallito-41", "Il run e fallito", "aprilo", Diagnose: true);
        Supervisor.Update(s, [p], o);
        s.Problems["run-fallito-41"].Diagnosis = "la causa e il DNS";
        Supervisor.Update(s, [p], o);
        Assert.Equal("la causa e il DNS", s.Problems["run-fallito-41"].Diagnosis);
        var plan = Supervisor.Plan(s, o, new SupervisorSettings());
        Assert.Contains("Diagnosi: la causa e il DNS", Assert.Single(plan.Summary).Problem.Lines!);
    }
}
