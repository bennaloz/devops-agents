using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Orchestration;
using DevOpsAgents.Core.Ports;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>D59: il collaudo nell'ambiente Docker della card. Le regole del motore e il lavoro dello smistatore.</summary>
public class TestEnvironmentTests
{
    private readonly DecisionEngine _engine = new();

    private static CardBuilder InTest(string state) =>
        Fx.Card(state).WithTestEnvironment().From(K.InReview).Earlier(Fx.Session("dev", "fatto", minutesAfterT0: 5)).Last(Fx.Session("reviewer", "superata", minutesAfterT0: 10));

    [Fact]
    public void Deploying_to_test_con_la_voce_collaudo_crea_l_ambiente_senza_chiedere_i_parametri_del_deploy()
    {
        var c = Assert.IsType<CreateTestEnvironment>(Assert.Single(_engine.Decide(InTest(K.DeployingToTest).Build(), Fx.Ctx()).Actions));
        Assert.Equal(10, c.Rev);
    }

    [Fact]
    public void Gli_ambienti_sono_un_limite_comune_a_tutti_i_componenti_non_uno_per_componente()
    {
        // il componente ha gia una card in test: senza ambienti sarebbe fermo, con gli ambienti conta solo ambientiCollaudo
        var ctx = Fx.Ctx(inTest: new() { ["stime"] = [41] }) with { CardsWithTestEnvironment = [41] };
        Assert.IsType<CreateTestEnvironment>(_engine.Decide(InTest(K.DeployingToTest).Build(), ctx).Actions[0]);
        var full = Fx.Ctx() with { CardsWithTestEnvironment = [41, 43, 44, 42] };
        var back = Assert.IsType<MoveBack>(Assert.Single(_engine.Decide(InTest(K.DeployingToTest).Build(), full).Actions));
        Assert.Equal((K.InReview, "Gli ambienti di collaudo sono tutti occupati"), (back.State, back.Reason));
    }

    [Fact]
    public void Con_gli_ambienti_tutti_occupati_la_card_aspetta_in_review_senza_on_hold()
    {
        var d = _engine.Decide(Fx.Card(K.InReview).WithTestEnvironment().Last(Fx.Session("reviewer", "superata")).Build(), Fx.Ctx() with { CardsWithTestEnvironment = [41, 43, 44] });
        Assert.Empty(d.Actions);
        Assert.Equal(("limiteAmbienti", "collaudatore"), (d.Reason!.Type, d.Reason.Role));
    }

    [Fact]
    public void Un_ambiente_non_creato_va_in_attesa_deploy_con_il_log()
    {
        var h = Fx.Hold(_engine.Decide(InTest(K.DeployingToTest).Run("completed", "failed").Build(), Fx.Ctx()));
        Assert.Equal(("deploy", "deployFallito"), (h.For, h.WaitKind));
        Assert.Contains("ambiente di collaudo non creato, log: https://run/70", h.Reason);
    }

    [Fact]
    public void Il_collaudatore_riceve_gli_URL_dell_ambiente_della_card_e_senza_si_ferma()
    {
        var l = (LaunchSession)_engine.Decide(InTest(K.AutomatedTest).With(s => s.TestUrls = new() { ["app"] = "http://localhost:21100" }).Build(), Fx.Ctx()).Actions[0];
        Assert.Equal("Ambiente di collaudo della card:\n- app: http://localhost:21100", l.Attachment);
        Assert.Contains("ESITO=bloccato", ((LaunchSession)_engine.Decide(InTest(K.AutomatedTest).Build(), Fx.Ctx()).Actions[0]).Attachment);
    }

    [Theory]
    [InlineData(K.ReadyToMerge)]
    [InlineData(K.InDevelopment)]
    [InlineData(K.Closed)]
    public void L_ambiente_si_butta_quando_la_card_lascia_il_Test_prima_di_tutto_il_resto(string state)
    {
        var d = _engine.Decide(Fx.Card(state).Pr(Validations.Green).With(s => { s.TestProject = "card-42"; s.TestSlot = 1; }).Build(), Fx.Ctx());
        Assert.IsType<DiscardTestEnvironment>(d.Actions[0]);
    }

    [Fact]
    public void L_ambiente_si_butta_anche_in_on_hold_con_una_sessione_o_senza_il_tag_ma_non_finche_la_card_e_in_Test()
    {
        Assert.IsType<DiscardTestEnvironment>(Assert.Single(_engine.Decide(Fx.Card(K.InDevelopment).OnHold("limite").With(s => s.TestProject = "card-42").Build(), Fx.Ctx()).Actions));
        Assert.IsType<DiscardTestEnvironment>(Assert.Single(_engine.Decide(Fx.Card(K.InDevelopment).NoAgentsTag().With(s => s.TestSlot = 2).Build(), Fx.Ctx()).Actions));
        Assert.DoesNotContain(_engine.Decide(InTest(K.HumanTest).With(s => s.TestProject = "card-42").Build(), Fx.Ctx()).Actions, a => a is DiscardTestEnvironment);
    }

    // ---- smistatore ----

    private sealed class Envs : ITestEnvironments
    {
        public List<string> Calls { get; } = [];
        public List<string> Known { get; } = [];
        public PipelineRun Status { get; set; } = new("inProgress", null, "log");
        public bool Fail { get; set; }
        public Task<TestEnvironmentStarted> StartAsync(AreaMapping area, int cardId, int slot, string folder, CancellationToken ct = default)
        {
            Calls.Add($"crea card-{cardId} slot {slot} da {folder}");
            return Task.FromResult(new TestEnvironmentStarted($"card-{cardId}", new Dictionary<string, string> { ["app"] = $"http://localhost:{21000 + slot * 100}" }, "log", Fx.T0));
        }
        public Task<PipelineRun> GetStatusAsync(int cardId, DateTimeOffset startedAt, CancellationToken ct = default) => Task.FromResult(Status);
        public Task<bool> RemoveAsync(string project, string? folder, CancellationToken ct = default) { Calls.Add($"butta {project}"); return Task.FromResult(!Fail); }
        public Task<IReadOnlyList<string>> ListProjectsAsync(CancellationToken ct = default) => Task.FromResult<IReadOnlyList<string>>(Known.ToList());
    }

    private sealed class WorldWithFolders(World w) : IWorkspace
    {
        public Task<(string Branch, string Folder)> CreateWorktreeAsync(AreaMapping a, Card c, string? b, CancellationToken ct = default) => w.CreateWorktreeAsync(a, c, b, ct);
        public Task RemoveWorktreeAsync(AreaMapping a, string f, CancellationToken ct = default) => w.RemoveWorktreeAsync(a, f, ct);
        public bool Exists(string folder) => folder.StartsWith("/wt/");
        public Task<string> PublishFeatureBranchAsync(AreaMapping a, FeatureInfo f, bool bug, CancellationToken ct = default) => w.PublishFeatureBranchAsync(a, f, bug, ct);
        public Task<string> UpdateClosingWorktreeAsync(AreaMapping a, Card c, string branch, CancellationToken ct = default) => w.UpdateClosingWorktreeAsync(a, c, branch, ct);
        public Task<(string Branch, string Folder)?> CreateWorktreeFromRemoteAsync(AreaMapping a, Card c, CancellationToken ct = default) => w.CreateWorktreeFromRemoteAsync(a, c, ct);
    }

    private static Dispatcher D(World w, Envs e) =>
        new(w, w, w, new WorldWithFolders(w), w, w, new DecisionEngine(), Fx.Names, new Limits(), [Fx.Area with { TestEnvironment = Fx.Env }], w, NullLogger<Dispatcher>.Instance, null, null, null, e);

    private static void Reviewed(World w, int id, string state)
    {
        w.Add(id, state);
        w.History[id] = [new StateChange(10, Fx.N(K.InReview), Fx.N(state), Fx.T0)];
        w.State[id] = new CardLocalState { Branch = $"feature/{id}", Folder = $"/wt/{id}", LastRole = "reviewer" };
        w.State[id].LastSessionByRole["dev"] = Fx.Session("dev", "fatto", minutesAfterT0: 5);
        w.State[id].LastSessionByRole["reviewer"] = Fx.Session("reviewer", "superata", minutesAfterT0: 10);
    }

    [Fact]
    public async Task L_ambiente_si_crea_nel_primo_slot_libero_dal_worktree_e_gli_URL_restano_nello_stato()
    {
        var w = new World();
        var e = new Envs();
        Reviewed(w, 42, K.DeployingToTest);
        Reviewed(w, 43, K.AutomatedTest);
        w.State[43].TestSlot = 1; w.State[43].TestProject = "card-43"; w.State[43].TestStartedAt = Fx.T0;
        await D(w, e).RunRoundAsync(whatIf: false);
        Assert.Contains("crea card-42 slot 2 da /wt/42", e.Calls);
        var s = w.State[42];
        Assert.Equal((2, "card-42", 10), (s.TestSlot!.Value, s.TestProject, s.RunAfterRev!.Value));
        Assert.Equal("http://localhost:21200", s.TestUrls!["app"]);
        Assert.Contains(w.Writes, x => x.Contains("Ambiente di collaudo in creazione"));
    }

    [Fact]
    public async Task L_esito_dell_ambiente_si_legge_come_un_run_creato_la_card_va_in_collaudo()
    {
        var w = new World();
        var e = new Envs { Status = new PipelineRun("completed", "succeeded", "log") };
        Reviewed(w, 42, K.DeployingToTest);
        w.State[42].TestSlot = 1; w.State[42].TestProject = "card-42"; w.State[42].TestStartedAt = Fx.T0; w.State[42].RunAfterRev = 10;
        await D(w, e).RunRoundAsync(whatIf: false);
        Assert.Contains($"stato 42 {Fx.N(K.AutomatedTest)}", w.Writes);
    }

    [Fact]
    public async Task Gli_ambienti_orfani_si_buttano_quelli_delle_card_in_Test_no_e_un_errore_di_docker_si_riprova()
    {
        var w = new World();
        var e = new Envs();
        e.Known.AddRange(["card-42", "card-77"]);
        Reviewed(w, 42, K.AutomatedTest);
        w.State[42].TestProject = "card-42";
        w.State[50] = new CardLocalState { TestProject = "card-50", TestSlot = 3 }; // card chiusa, non piu attiva
        await D(w, e).RunRoundAsync(whatIf: false);
        Assert.Contains("butta card-77", e.Calls);
        Assert.Contains("butta card-50", e.Calls);
        Assert.DoesNotContain("butta card-42", e.Calls);
        Assert.Null(w.State[50].TestSlot);

        var f = new Envs { Fail = true };
        w.State[50].TestSlot = 3;
        await D(w, f).RunRoundAsync(whatIf: false);
        Assert.Equal(3, w.State[50].TestSlot);
    }
}

public class TestEnvironmentRetryTests
{
    [Fact]
    public void Tolto_l_on_hold_dopo_un_ambiente_non_creato_si_dimentica_l_esito_e_l_ambiente_si_ricrea()
    {
        var b = Fx.Card(K.DeployingToTest).WithTestEnvironment().From(K.InReview).Earlier(Fx.Session("dev", "fatto", minutesAfterT0: 5))
            .Last(Fx.Session("reviewer", "superata", minutesAfterT0: 10)).WaitingFor("deploy").Run("completed", "failed")
            .With(s => { s.RunId = null; s.TestProject = "card-42"; s.TestSlot = 1; });
        var d = new DecisionEngine().Decide(b.Build(), Fx.Ctx());
        Assert.Equal(["AzzeraContatori", "AzzeraDeploy", "CreaAmbienteCollaudo"], d.Actions.Select(a => a.Kind));
    }
}
