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
