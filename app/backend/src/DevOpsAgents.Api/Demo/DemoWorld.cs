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
    public static readonly Person Me = new("demo-1", "Titolare", "titolare@example.invalid");
    private readonly object _lock = new();
    private readonly StateNames _names;
    private readonly IClock _clock;
    private readonly List<Card> _cards = [];
    private readonly List<FeatureInfo> _features = [];
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
        _features.Add(new FeatureInfo(10, "Preventivi", "Active", [], a, 1000));
        _features.Add(new FeatureInfo(20, "Rapporti", "Active", [], a, 2000));
        _features.Add(new FeatureInfo(30, "Ricerca", "New", [], b, null));
        Seed(101, "Importare le stime dal foglio Excel", K.New, a, parent: 10);
        Seed(102, "Esportare il rapporto finale in PDF", K.Ready, a, deploy: "deployStime", parent: 20);
        Seed(103, "Filtro per data nelle ricerche", K.Ready, b, deploy: "deployStime", parent: 10);
        Seed(104, "Correggere il totale delle righe", K.NeedsClarification, b, parent: 30);
        Seed(107, "Card senza Feature", K.New, b);
        Seed(105, "Pagina di stato del servizio", K.ReadyToRelease, a, parent: 20);
        Seed(106, "Card di un collega", K.Ready, b, assigned: new Person("demo-2", "Anna"), parent: 30);
        _comments[104].Add(new Comment(_nextComment++, "Titolare", "[responsabile] Domande: il totale include l'IVA?", clock.Now.AddHours(-2)));
    }

    private void Seed(int id, string title, string key, string area, string? deploy = null, Person? assigned = null, int? parent = null)
    {
        _cards.Add(new Card(id, 5, title, _names[key], [_names.AgentsTag], area, assigned ?? Me, Me, "User Story", parent));
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
        lock (_lock)
        {
            var i = _cards.FindIndex(c => c.Id == id);
            if (i >= 0) _cards[i] = _cards[i] with { Tags = _cards[i].Tags.Append(tag).ToList() };
            var f = _features.FindIndex(x => x.Id == id);
            if (f >= 0) _features[f] = _features[f] with { Tags = _features[f].Tags.Append(tag).ToList() };
        }
        return Task.CompletedTask;
    }
    public Task AddCommentAsync(int id, string md, CancellationToken ct = default) { lock (_lock) _comments[id].Add(new Comment(_nextComment++, "smistatore", md, _clock.Now)); return Task.CompletedTask; }
    public Task AddLinkAsync(int id, string url, string? comment = null, CancellationToken ct = default) => Task.CompletedTask;
    public Task<Person> GetCurrentUserAsync(CancellationToken ct = default) => Task.FromResult(Me);
    public Task RemoveTagAsync(int id, string tag, CancellationToken ct = default)
    {
        lock (_lock)
        {
            var i = _cards.FindIndex(c => c.Id == id);
            if (i >= 0) _cards[i] = _cards[i] with { Tags = _cards[i].Tags.Where(t => !string.Equals(t, tag, StringComparison.OrdinalIgnoreCase)).ToList() };
            var f = _features.FindIndex(x => x.Id == id);
            if (f >= 0) _features[f] = _features[f] with { Tags = _features[f].Tags.Where(t => !string.Equals(t, tag, StringComparison.OrdinalIgnoreCase)).ToList() };
        }
        return Task.CompletedTask;
    }
    public Task<IReadOnlyList<FeatureInfo>> GetOpenFeaturesAsync(IReadOnlyList<string> areas, CancellationToken ct = default) { lock (_lock) return Task.FromResult<IReadOnlyList<FeatureInfo>>(_features.ToList()); }
    public Task<IReadOnlyList<Card>> GetFeatureChildrenAsync(int featureId, CancellationToken ct = default) { lock (_lock) return Task.FromResult<IReadOnlyList<Card>>(_cards.Where(c => c.ParentId == featureId).ToList()); }
    public Task<int> CreateBugAsync(NewBug bug, CancellationToken ct = default)
    {
        lock (_lock)
        {
            var id = 200 + _nextId++;
            var key = bug.InitialState ?? K.Draft;
            _cards.Add(new Card(id, 1, bug.Title, _names[key], bug.Tags.ToList(), bug.Area, Me, Me, "Bug", bug.ParentId));
            _history[id] = [new StateChange(1, null, _names[key], _clock.Now)];
            _comments[id] = [];
            return Task.FromResult(id);
        }
    }
    public Task SetRankAsync(int id, double rank, CancellationToken ct = default)
    {
        lock (_lock) { var f = _features.FindIndex(x => x.Id == id); if (f >= 0) _features[f] = _features[f] with { Rank = rank }; }
        return Task.CompletedTask;
    }
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
    private readonly List<string> _branches = [];
    public Task<IReadOnlyList<string>> ListBranchesAsync(AreaMapping a, string prefix, CancellationToken ct = default) { lock (_lock) return Task.FromResult<IReadOnlyList<string>>(_branches.Where(b => b.StartsWith(prefix)).ToList()); }
    public Task<(string Status, string Branch)?> GetPullRequestByIdAsync(AreaMapping a, int id, CancellationToken ct = default)
    {
        lock (_lock) return Task.FromResult<(string, string)?>(_prs.Where(p => p.Value.Id == id).Select(p => ((string, string)?)(p.Value.Status, p.Key)).FirstOrDefault());
    }
    public Task<string?> GetBuildErrorsAsync(AreaMapping a, int buildId, CancellationToken ct = default) => Task.FromResult<string?>(null);
    public Task<string> PublishFeatureBranchAsync(AreaMapping a, FeatureInfo f, bool bug, CancellationToken ct = default)
    {
        lock (_lock) { var name = $"feature/f{f.Id}-demo"; if (!_branches.Contains(name)) _branches.Add(name); return Task.FromResult(name); }
    }
    public Task<string> UpdateClosingWorktreeAsync(AreaMapping a, Card c, string branch, CancellationToken ct = default) => Task.FromResult($"demo://wt/card-{c.Id}");

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
