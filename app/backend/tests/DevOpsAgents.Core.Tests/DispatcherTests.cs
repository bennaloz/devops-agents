using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Orchestration;
using DevOpsAgents.Core.Ports;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>Un mondo finto in memoria: board, repo, pipeline, worktree, sessioni e stato. Registra ogni scrittura.</summary>
internal sealed class World : IBoard, ICodeHost, ICodeHostResolver, ICiService, IWorkspace, ISessionRunner, IStateStore, IClock
{
    public static readonly Person Me = new("u-1", "Titolare");
    public List<Card> Cards { get; } = [];
    public Dictionary<int, List<Comment>> Comments { get; } = new();
    public Dictionary<int, List<StateChange>> History { get; } = new();
    public Dictionary<int, CardLocalState> State { get; set; } = new();
    public Dictionary<string, PullRequestInfo> Prs { get; } = new();
    public Dictionary<string, SessionResult?> Results { get; } = new();
    public List<string> Writes { get; } = [];
    public bool LinksPr { get; set; }
    public DateTimeOffset Now { get; set; } = Fx.T0.AddHours(1);
    private int _sessions;

    public Card Add(int id, string stateKey, Person? assigned = null, string area = "DevOps.Agents\\AI\\Stime")
    {
        var c = new Card(id, 12, $"Card {id}", Fx.N(stateKey), [Fx.Names.AgentsTag], area, assigned ?? Me);
        Cards.Add(c);
        History[id] = [new StateChange(10, Fx.N(K.New), Fx.N(stateKey), Fx.T0)];
        return c;
    }

    // IBoard
    public Task<IReadOnlyList<Card>> GetActiveCardsAsync(CancellationToken ct = default) => Task.FromResult<IReadOnlyList<Card>>(Cards.ToList());
    public Task<IReadOnlyList<Comment>> GetCommentsAsync(int id, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<Comment>>(Comments.GetValueOrDefault(id) ?? []);
    public Task<IReadOnlyList<StateChange>> GetStateHistoryAsync(int id, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<StateChange>>(History.GetValueOrDefault(id) ?? []);
    public Task<IReadOnlyList<WorkTask>> GetTasksAsync(int id, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<WorkTask>>([]);
    public Task<IReadOnlyList<Predecessor>> GetPredecessorsAsync(int id, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<Predecessor>>([]);
    public Task SetStateAsync(int id, string state, CancellationToken ct = default)
    {
        Writes.Add($"stato {id} {state}");
        var i = Cards.FindIndex(c => c.Id == id);
        var old = Cards[i];
        Cards[i] = old with { State = state, Rev = old.Rev + 1 };
        History[id].Add(new StateChange(old.Rev + 1, old.State, state, Now));
        return Task.CompletedTask;
    }
    public Task AddTagAsync(int id, string tag, CancellationToken ct = default) { Writes.Add($"tag {id} {tag}"); return Task.CompletedTask; }
    public Task AddCommentAsync(int id, string md, CancellationToken ct = default) { Writes.Add($"commento {id} {md}"); return Task.CompletedTask; }
    public Task AddLinkAsync(int id, string url, string? comment = null, CancellationToken ct = default) { Writes.Add($"link {id} {url}"); return Task.CompletedTask; }
    public Task<Person> GetCurrentUserAsync(CancellationToken ct = default) => Task.FromResult(Me);
    public string CardUrl(int id) => $"https://board/{id}";
    public List<FeatureInfo> Features { get; } = [];
    public Task RemoveTagAsync(int id, string tag, CancellationToken ct = default) { Writes.Add($"togli {id} {tag}"); return Task.CompletedTask; }
    public Task<IReadOnlyList<FeatureInfo>> GetOpenFeaturesAsync(IReadOnlyList<string> areas, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<FeatureInfo>>(Features.ToList());
    public Task SetRankAsync(int id, double rank, CancellationToken ct = default) { Writes.Add($"rank {id} {rank}"); return Task.CompletedTask; }

    // ICodeHost
    public ICodeHost For(AreaMapping area) => this;
    public bool NeedsCardLink => LinksPr;
    public Task<PullRequestInfo?> GetPullRequestAsync(AreaMapping a, string branch, string dest, bool completed, CancellationToken ct = default) => Task.FromResult(Prs.GetValueOrDefault(branch));
    public Task<(int Id, string Url)> CreatePullRequestAsync(AreaMapping a, string branch, string dest, string title, string desc, int cardId, CancellationToken ct = default)
    {
        Writes.Add($"pr {branch}->{dest}");
        Prs[branch] = new PullRequestInfo(99, PrStatuses.Active, Validations.Running);
        return Task.FromResult((99, "https://github.com/acme/web/pull/99"));
    }
    public Task CompletePullRequestAsync(AreaMapping a, int id, string? commit, CancellationToken ct = default) { Writes.Add($"merge {id}"); return Task.CompletedTask; }
    public Task<int> RequeueValidationsAsync(AreaMapping a, string b, string d, bool expired, CancellationToken ct = default) { Writes.Add("rilancio"); return Task.FromResult(1); }
    public string PullRequestUrl(AreaMapping a, int id) => $"https://pr/{id}";

    // ICiService
    public Task<int> QueueTestDeployAsync(AreaMapping a, string b, IReadOnlyList<string> on, IReadOnlyList<string> off, CancellationToken ct = default) { Writes.Add("deploy"); return Task.FromResult(70); }
    public Task<PipelineRun> GetRunAsync(AreaMapping a, int id, CancellationToken ct = default) => Task.FromResult(new PipelineRun("inProgress", null, null));

    // IWorkspace
    public Task<(string Branch, string Folder)> CreateWorktreeAsync(AreaMapping a, Card c, string? b, CancellationToken ct = default)
    {
        Writes.Add($"worktree {c.Id}");
        return Task.FromResult(($"feature/{c.Id}-card", $"/wt/{c.Id}"));
    }
    public Task RemoveWorktreeAsync(AreaMapping a, string f, CancellationToken ct = default) { Writes.Add($"rimuovi {f}"); return Task.CompletedTask; }

    // ISessionRunner
    public List<SessionRequest> Started { get; } = [];
    public IReadOnlyCollection<string> Running => Results.Where(r => r.Value is null).Select(r => r.Key).ToList();
    public Task<string> StartAsync(SessionRequest r, CancellationToken ct = default)
    {
        Started.Add(r);
        var id = $"s{++_sessions}";
        Results[id] = null;
        return Task.FromResult(id);
    }
    public Task<SessionResult?> PollAsync(string id, CancellationToken ct = default) => Task.FromResult(Results.GetValueOrDefault(id));

    // IStateStore
    public Task<Dictionary<int, CardLocalState>> LoadAsync(CancellationToken ct = default) => Task.FromResult(State);
    public Task SaveAsync(IReadOnlyDictionary<int, CardLocalState> s, CancellationToken ct = default) { State = s.ToDictionary(); return Task.CompletedTask; }

    public Dispatcher Dispatcher(bool onlyMine = true) =>
        new(this, this, this, this, this, this, new DecisionEngine(), Fx.Names, new Limits(), [Fx.Area], this, NullLogger<Dispatcher>.Instance, new DispatcherOptions { OnlyMine = onlyMine });
}

public class DispatcherTests
{
    [Fact]
    public async Task Un_giro_di_prova_dice_cosa_farebbe_e_non_scrive_niente()
    {
        var w = new World();
        w.Add(42, K.Ready);
        var r = await w.Dispatcher().RunRoundAsync(whatIf: true);
        Assert.Empty(w.Writes);
        Assert.Empty(w.Started);
        Assert.Empty(w.State[42].LastSessionByRole);
        Assert.Equal(["CreaWorktree", "SpostaCard -> inSviluppo", "LanciaSessione dev (pronto)"], r.Cards.Single().Actions);
        Assert.Contains(r.Log, l => l.StartsWith("card 42: farei"));
    }

    [Fact]
    public async Task Ready_crea_il_worktree_sposta_la_card_e_lancia_dev_nel_worktree()
    {
        var w = new World();
        w.Add(42, K.Ready);
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Equal(["worktree 42", $"stato 42 {Fx.N(K.InDevelopment)}"], w.Writes);
        var s = Assert.Single(w.Started);
        Assert.Equal(("dev", "/wt/42"), (s.Role, s.WorkingFolder));
        Assert.Contains("Motivo del lancio: pronto", s.Message);
        Assert.Equal("s1", w.State[42].RunningSession);
        Assert.Equal("feature/42-card", w.State[42].Branch);
    }

    [Fact]
    public async Task Dalla_card_pronta_alla_PR_la_sessione_finita_si_registra_e_al_giro_dopo_si_apre_la_PR_con_il_link_sulla_card()
    {
        var w = new World { LinksPr = true };
        w.Add(42, K.Ready);
        var d = w.Dispatcher();
        await d.RunRoundAsync(whatIf: false);

        // la sessione e ancora in corso: niente di nuovo
        await d.RunRoundAsync(whatIf: false);
        Assert.Single(w.Started);

        w.Results["s1"] = new SessionResult("fatto", "riepilogo");
        await d.RunRoundAsync(whatIf: false);
        var local = w.State[42];
        Assert.Null(local.RunningSession);
        Assert.Equal("fatto", local.Of("dev")!.Outcome);
        Assert.Contains("pr feature/42-card->develop", w.Writes);
        Assert.Contains("link 42 https://github.com/acme/web/pull/99", w.Writes);
        Assert.Equal(99, local.PrId);
    }

    [Fact]
    public async Task Senza_link_per_Azure_Repos_la_PR_non_aggiunge_un_link()
    {
        var w = new World { LinksPr = false };
        w.Add(42, K.InDevelopment);
        w.State[42] = new CardLocalState { Branch = "feature/42-card", Folder = "/wt/42", LastRole = "dev" };
        w.State[42].LastSessionByRole["dev"] = Fx.Session("dev", "fatto");
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Contains("pr feature/42-card->develop", w.Writes);
        Assert.DoesNotContain(w.Writes, x => x.StartsWith("link"));
    }

    [Fact]
    public async Task Solo_le_card_mie_a_meno_di_spegnere_il_filtro()
    {
        var w = new World();
        w.Add(42, K.Ready, new Person("u-2", "Anna"));
        Assert.Empty((await w.Dispatcher().RunRoundAsync(whatIf: true)).Cards);
        Assert.Single((await w.Dispatcher(onlyMine: false).RunRoundAsync(whatIf: true)).Cards);
    }

    [Fact]
    public async Task Due_card_pronte_sullo_stesso_repo_parte_solo_la_prima_e_la_seconda_dice_perche()
    {
        var w = new World();
        w.Add(42, K.Ready);
        w.Add(43, K.Ready);
        var r = await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Single(w.Started);
        var second = r.Cards.Single(c => c.Id == 43);
        Assert.Empty(second.Actions);
        Assert.Equal("limiteRepo", second.Reason!.Type);
    }

    [Fact]
    public async Task Un_area_non_mappata_e_un_motivo_non_un_errore()
    {
        var w = new World();
        w.Add(42, K.Ready, area: "Altro\\Area");
        var r = await w.Dispatcher().RunRoundAsync(whatIf: true);
        Assert.Equal("areaNonMappata", r.Cards.Single().Reason!.Type);
    }

    [Fact]
    public async Task L_on_hold_mette_il_tag_e_un_commento_con_la_menzione()
    {
        var w = new World();
        w.Add(42, K.InDevelopment);
        w.State[42] = new CardLocalState { Branch = "b", LastRole = "dev" };
        w.State[42].LastSessionByRole["dev"] = Fx.Session("dev", null);
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Contains($"tag 42 {Fx.Names.OnHoldTag}", w.Writes);
        Assert.Contains(w.Writes, x => x.StartsWith("commento 42 @Titolare [smistatore] on-hold: La sessione di dev e finita senza riga ESITO"));
        Assert.Equal("sessione", w.State[42].WaitingFor);
    }

    [Fact]
    public void La_scelta_del_deploy_e_l_ultima_scritta_dal_responsabile()
    {
        var c = Dispatcher.ParseDeployChoice([
            new Comment(1, "x", "[responsabile] Parametri del deploy in Test: deployA\n\nPerche: x", Fx.T0),
            new Comment(3, "x", "<div>[responsabile] Parametri del deploy in Test: `deployB`, deployC</div><div>Perche: y</div>", Fx.T0),
            new Comment(2, "x", "[dev] Parametri del deploy in Test: deployZ", Fx.T0),
        ]);
        Assert.Equal(["deployB", "deployC"], c!.Selected);
        Assert.Null(Dispatcher.ParseDeployChoice([new Comment(1, "x", "ciao", Fx.T0)]));
    }
}

public class DispatcherPriorityTests
{
    private sealed class Settings(bool paused) : ISettingsStore
    {
        public SystemSettings Value { get; private set; } = new(paused);
        public Task<SystemSettings> LoadAsync(CancellationToken ct = default) => Task.FromResult(Value);
        public Task SaveAsync(SystemSettings s, CancellationToken ct = default) { Value = s; return Task.CompletedTask; }
    }

    private sealed class Quota : IQuotaStore
    {
        public QuotaInfo? Value { get; set; }
        public Task<QuotaInfo?> LoadAsync(CancellationToken ct = default) => Task.FromResult(Value);
        public Task SaveAsync(QuotaInfo q, CancellationToken ct = default) { Value = q; return Task.CompletedTask; }
        public Task<QuotaOverrides?> LoadOverridesAsync(CancellationToken ct = default) => Task.FromResult<QuotaOverrides?>(null);
        public Task SaveOverridesAsync(QuotaOverrides o, CancellationToken ct = default) => Task.CompletedTask;
    }

    private static Dispatcher D(World w, ISettingsStore? s = null, IQuotaStore? q = null) =>
        new(w, w, w, w, w, w, new DecisionEngine(), Fx.Names, new Limits(), [Fx.Area], w, NullLogger<Dispatcher>.Instance, null, s, q);

    private static Card WithParent(World w, int id, string state, int parent)
    {
        var c = w.Add(id, state);
        w.Cards[w.Cards.FindIndex(x => x.Id == id)] = c with { ParentId = parent };
        return c;
    }

    [Fact]
    public async Task Il_sistema_in_pausa_chiude_le_sessioni_finite_ma_non_lancia_e_non_sposta_niente()
    {
        var w = new World();
        w.Features.Add(new FeatureInfo(10, "F", "Active", [], null, 1000));
        WithParent(w, 42, K.Ready, 10);
        WithParent(w, 43, K.InDevelopment, 10);
        w.State[43] = new CardLocalState { Branch = "b", LastRole = "dev", RunningSession = "s9" };
        w.State[43].LastSessionByRole["dev"] = Fx.Session("dev", null, finished: false);
        w.Results["s9"] = new SessionResult("fatto", "ok");
        var r = await D(w, new Settings(true)).RunRoundAsync(whatIf: false);
        Assert.True(r.SystemPaused);
        Assert.Empty(w.Writes);
        Assert.Empty(w.Started);
        Assert.All(r.Cards, c => Assert.Equal("pausaSistema", c.Reason!.Type));
        Assert.Null(w.State[43].RunningSession);
        Assert.Equal("fatto", w.State[43].Of("dev")!.Outcome);
    }

    [Fact]
    public async Task Il_posto_libero_del_repo_va_alla_card_della_Feature_piu_in_alto()
    {
        var w = new World();
        w.Features.Add(new FeatureInfo(10, "Bassa", "Active", [], null, 2000));
        w.Features.Add(new FeatureInfo(20, "Alta", "Active", [], null, 1000));
        WithParent(w, 42, K.Ready, 10);
        WithParent(w, 43, K.Ready, 20);
        var r = await D(w).RunRoundAsync(whatIf: false);
        Assert.Equal(43, Assert.Single(w.Started).CardId);
        Assert.Equal([43, 42], r.Cards.Select(c => c.Id));
        Assert.Equal([20, 10], r.Features!.Select(f => f.Id));
    }

    [Fact]
    public async Task Una_card_in_pausa_non_tiene_il_posto_in_sviluppo_del_suo_repo()
    {
        var w = new World();
        w.Features.Add(new FeatureInfo(10, "Ferma", "Active", [Fx.Names.PausedTag!], null, 1000));
        w.Features.Add(new FeatureInfo(20, "Va", "Active", [], null, 2000));
        WithParent(w, 42, K.InDevelopment, 10);
        WithParent(w, 43, K.Ready, 20);
        var r = await D(w).RunRoundAsync(whatIf: false);
        Assert.Equal("pausa", r.Cards.Single(c => c.Id == 42).Reason!.Type);
        Assert.Equal(43, Assert.Single(w.Started).CardId);
    }

    [Fact]
    public async Task La_quota_letta_da_una_sessione_finita_si_salva_e_sul_limite_di_token_scrive_la_pausa()
    {
        var w = new World();
        w.Add(43, K.InDevelopment);
        w.State[43] = new CardLocalState { Branch = "b", LastRole = "dev", RunningSession = "s9" };
        w.State[43].LastSessionByRole["dev"] = Fx.Session("dev", null, finished: false);
        var reset = Fx.T0.AddHours(4);
        w.Results["s9"] = new SessionResult(null, "hit your limit", true, reset, new QuotaInfo(null, 0.4, Fx.T0.AddDays(3), 1.0, reset));
        var q = new Quota();
        await D(w, null, q).RunRoundAsync(whatIf: false);
        Assert.Equal((0.4, 1.0, reset.AddMinutes(5)), (q.Value!.WeeklyUtilization!.Value, q.Value.FiveHourUtilization!.Value, q.Value.PauseUntil!.Value));
        Assert.Equal("quota", w.State[43].WaitingFor);
        Assert.Empty(w.Started);
    }

    [Fact]
    public async Task Il_servizio_di_priorita_mette_in_pausa_riprende_e_riordina_scrivendo_solo_il_necessario()
    {
        var w = new World();
        w.Features.AddRange([new FeatureInfo(1, "A", "Active", [], null, 1000), new FeatureInfo(2, "B", "Active", [Fx.Names.PausedTag!], null, 2000)]);
        var s = new Settings(false);
        var p = new PriorityService(w, s, Fx.Names, [Fx.Area]);
        await p.SetFeaturePausedAsync(1, true);
        await p.SetFeaturePausedAsync(2, false);
        await p.SetFeaturePausedAsync(2, true); // gia in pausa: niente
        Assert.Equal([$"tag 1 {Fx.Names.PausedTag}", $"togli 2 {Fx.Names.PausedTag}"], w.Writes);
        Assert.Equal([2], await p.MoveAsync(2, 0));
        Assert.Contains("rank 2 0", w.Writes);
        await p.SetSystemPausedAsync(true);
        Assert.True(await p.IsSystemPausedAsync());
    }
}
