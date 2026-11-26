using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Api.Demo;

/// <summary>
/// Un mondo simulato in memoria per la modalita demo: board, repo, pipeline, worktree e sessioni finte. Le sessioni finiscono al
/// giro dopo con l'esito tipico del ruolo, le PR diventano verdi, i deploy riescono: il flusso si vede avanzare giro dopo giro
/// senza Azure DevOps, GitHub ne claude. Niente esce dal processo.
/// </summary>
public sealed class DemoWorld : IBoard, ICodeHost, ICodeHostResolver, ICiService, IWorkspace, ISessionRunner, IStateStore
{
    public static readonly Person Me = new("demo-1", "Titolare");
    private readonly object _lock = new();
    private readonly StateNames _names;
    private readonly IClock _clock;
    private readonly List<Card> _cards = [];
    private readonly Dictionary<int, List<Comment>> _comments = new();
    private readonly Dictionary<int, List<StateChange>> _history = new();
    private readonly Dictionary<string, (int Card, string Role, int Polls)> _sessions = new();
    private readonly Dictionary<string, (int Id, int Reads, string Status)> _prs = new();
    private Dictionary<int, CardLocalState> _state = new();
    private int _nextId = 1, _nextComment = 1;

    public DemoWorld(StateNames names, IReadOnlyList<AreaMapping> areas, IClock clock)
    {
        _names = names;
        _clock = clock;
        var a = areas.FirstOrDefault()?.Area ?? "DevOps.Agents\\Demo";
        var b = areas.Skip(1).FirstOrDefault()?.Area ?? a;
        Seed(101, "Importare le stime dal foglio Excel", K.New, a);
        Seed(102, "Esportare il rapporto finale in PDF", K.Ready, a, deploy: "deployStime");
        Seed(103, "Filtro per data nelle ricerche", K.Ready, b, deploy: "deployStime");
        Seed(104, "Correggere il totale delle righe", K.NeedsClarification, b);
        Seed(105, "Pagina di stato del servizio", K.ReadyToRelease, a);
        Seed(106, "Card di un collega", K.Ready, b, assigned: new Person("demo-2", "Anna"));
        _comments[104].Add(new Comment(_nextComment++, "Titolare", "[responsabile] Domande: il totale include l'IVA?", clock.Now.AddHours(-2)));
    }

    private void Seed(int id, string title, string key, string area, string? deploy = null, Person? assigned = null)
    {
        _cards.Add(new Card(id, 5, title, _names[key], [_names.AgentsTag], area, assigned ?? Me, Me, "User Story"));
        _history[id] = [new StateChange(5, _names[K.Draft], _names[key], _clock.Now.AddHours(-3))];
        _comments[id] = deploy is null ? [] : [new Comment(_nextComment++, "Titolare", $"[responsabile] Parametri del deploy in Test: {deploy}\n\nPerche: demo", _clock.Now.AddHours(-3))];
    }

    private Card CardById(int id) => _cards.Single(c => c.Id == id);

    private void Move(int id, string stateName)
    {
        var i = _cards.FindIndex(c => c.Id == id);
        var old = _cards[i];
        _cards[i] = old with { State = stateName, Rev = old.Rev + 1 };
        _history[id].Add(new StateChange(old.Rev + 1, old.State, stateName, _clock.Now));
    }

    // ---- IBoard ----
    public Task<IReadOnlyList<Card>> GetActiveCardsAsync(CancellationToken ct = default)
    {
        lock (_lock) return Task.FromResult<IReadOnlyList<Card>>(_cards.Where(c => _names.KeyOf(c.State) != K.Closed).ToList());
    }
    public Task<IReadOnlyList<Comment>> GetCommentsAsync(int id, CancellationToken ct = default) { lock (_lock) return Task.FromResult<IReadOnlyList<Comment>>(_comments[id].ToList()); }
    public Task<IReadOnlyList<StateChange>> GetStateHistoryAsync(int id, CancellationToken ct = default) { lock (_lock) return Task.FromResult<IReadOnlyList<StateChange>>(_history[id].ToList()); }
    public Task<IReadOnlyList<WorkTask>> GetTasksAsync(int id, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<WorkTask>>([]);
    public Task<IReadOnlyList<Predecessor>> GetPredecessorsAsync(int id, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<Predecessor>>([]);
    public Task SetStateAsync(int id, string state, CancellationToken ct = default) { lock (_lock) Move(id, state); return Task.CompletedTask; }
    public Task AddTagAsync(int id, string tag, CancellationToken ct = default)
    {
        lock (_lock) { var i = _cards.FindIndex(c => c.Id == id); _cards[i] = _cards[i] with { Tags = _cards[i].Tags.Append(tag).ToList() }; }
        return Task.CompletedTask;
    }
    public Task AddCommentAsync(int id, string md, CancellationToken ct = default) { lock (_lock) _comments[id].Add(new Comment(_nextComment++, "smistatore", md, _clock.Now)); return Task.CompletedTask; }
    public Task AddLinkAsync(int id, string url, string? comment = null, CancellationToken ct = default) => Task.CompletedTask;
    public Task<Person> GetCurrentUserAsync(CancellationToken ct = default) => Task.FromResult(Me);
    public string CardUrl(int id) => $"#card-{id}";

    // ---- ICodeHost ----
    public ICodeHost For(AreaMapping area) => this;
    public bool NeedsCardLink => false;
    public Task<PullRequestInfo?> GetPullRequestAsync(AreaMapping a, string branch, string dest, bool completed, CancellationToken ct = default)
    {
        lock (_lock)
        {
            if (!_prs.TryGetValue(branch, out var pr)) return Task.FromResult<PullRequestInfo?>(null);
            _prs[branch] = pr with { Reads = pr.Reads + 1 };
            if (pr.Status == PrStatuses.Completed) return Task.FromResult<PullRequestInfo?>(completed ? new PullRequestInfo(pr.Id, PrStatuses.Completed, Validations.None) : null);
            var v = pr.Reads >= 1 ? Validations.Green : Validations.Running;
            return Task.FromResult<PullRequestInfo?>(new PullRequestInfo(pr.Id, PrStatuses.Active, v, 900 + pr.Id, "#build", "HEAD"));
        }
    }
    public Task<(int Id, string Url)> CreatePullRequestAsync(AreaMapping a, string branch, string dest, string title, string desc, int cardId, CancellationToken ct = default)
    {
        lock (_lock) { var id = _nextId++; _prs[branch] = (id, 0, PrStatuses.Active); return Task.FromResult((id, $"#pr-{id}")); }
    }
    public Task CompletePullRequestAsync(AreaMapping a, int id, string? commit, CancellationToken ct = default)
    {
        lock (_lock) foreach (var (k, v) in _prs.ToList()) if (v.Id == id) _prs[k] = v with { Status = PrStatuses.Completed };
        return Task.CompletedTask;
    }
    public Task<int> RequeueValidationsAsync(AreaMapping a, string b, string d, bool expired, CancellationToken ct = default) => Task.FromResult(0);
    public string PullRequestUrl(AreaMapping a, int id) => $"#pr-{id}";

    // ---- ICiService ----
    public Task<int> QueueTestDeployAsync(AreaMapping a, string b, IReadOnlyList<string> on, IReadOnlyList<string> off, CancellationToken ct = default) { lock (_lock) return Task.FromResult(_nextId++); }
    public Task<PipelineRun> GetRunAsync(AreaMapping a, int id, CancellationToken ct = default) => Task.FromResult(new PipelineRun("completed", "succeeded", "#run"));

    // ---- IWorkspace ----
    public Task<(string Branch, string Folder)> CreateWorktreeAsync(AreaMapping a, Card c, string? b, CancellationToken ct = default) =>
        Task.FromResult(($"feature/{c.Id}-demo", $"demo://wt/card-{c.Id}"));
    public Task RemoveWorktreeAsync(AreaMapping a, string f, CancellationToken ct = default) => Task.CompletedTask;

    // ---- ISessionRunner: finiscono al giro dopo, con l'esito tipico del ruolo ----
    public IReadOnlyCollection<string> Running { get { lock (_lock) return _sessions.Keys.ToList(); } }
    public Task<string> StartAsync(SessionRequest r, CancellationToken ct = default)
    {
        lock (_lock) { var id = $"demo-{_nextId++}"; _sessions[id] = (r.CardId, r.Role, 0); return Task.FromResult(id); }
    }
    public Task<SessionResult?> PollAsync(string id, CancellationToken ct = default)
    {
        lock (_lock)
        {
            if (!_sessions.TryGetValue(id, out var s)) return Task.FromResult<SessionResult?>(new SessionResult("fatto", "demo"));
            if (s.Polls == 0) { _sessions[id] = s with { Polls = 1 }; return Task.FromResult<SessionResult?>(null); }
            _sessions.Remove(id);
            var key = _names.KeyOf(CardById(s.Card).State);
            // il responsabile, nella realta, sposta la card con card.ps1: qui lo fa la demo
            if (s.Role == "responsabile" && key is K.New or K.NeedsClarification) Move(s.Card, _names[K.Ready]);
            var outcome = s.Role switch { "reviewer" or "collaudatore" => "superata", _ => "fatto" };
            return Task.FromResult<SessionResult?>(new SessionResult(outcome, $"[{s.Role}] sessione simulata\nESITO={outcome}"));
        }
    }

    // ---- IStateStore ----
    public Task<Dictionary<int, CardLocalState>> LoadAsync(CancellationToken ct = default) { lock (_lock) return Task.FromResult(_state.ToDictionary(kv => kv.Key, kv => kv.Value)); }
    public Task SaveAsync(IReadOnlyDictionary<int, CardLocalState> s, CancellationToken ct = default) { lock (_lock) _state = s.ToDictionary(); return Task.CompletedTask; }
}
