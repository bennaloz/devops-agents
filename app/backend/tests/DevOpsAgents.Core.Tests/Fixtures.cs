using System.Text.Json;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;

namespace DevOpsAgents.Core.Tests;

/// <summary>Le card di prova. I nomi degli stati vengono da config/stati.json del repo, come nei test PowerShell.</summary>
internal static class Fx
{
    public static readonly DateTimeOffset T0 = new(2026, 11, 2, 9, 0, 0, TimeSpan.Zero);

    public static readonly StateNames Names = LoadNames();

    private static StateNames LoadNames()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "config", "stati.json"))) dir = dir.Parent;
        if (dir is null) throw new InvalidOperationException("config/stati.json non trovato risalendo dalla cartella dei test");
        var json = File.ReadAllText(Path.Combine(dir.FullName, "config", "stati.json"));
        return new StateNames(JsonSerializer.Deserialize<Dictionary<string, string>>(json)!);
    }

    public static string N(string key) => Names[key];

    /// <summary>
    /// L'on-hold deciso: diretto, o (D42) la passata del responsabile che lo precede (AvviaPassataAttesa + responsabile "attesa"): in tutti e
    /// due i casi il motivo, il per e il tipo sono quelli dell'on-hold.
    /// </summary>
    public static PutOnHold Hold(Decision d)
    {
        var real = d.Actions.Where(a => a is not ResetCounters and not ResetDeploy and not ResetHoldReviews).ToList();
        if (real is [PutOnHold h]) return h;
        if (real is [StartHoldReview r, LaunchSession { Role: "responsabile", Reason: "attesa" }])
            return new PutOnHold(r.Reason, r.For, WaitKind: r.Key == r.Reason ? null : r.Key);
        throw new Xunit.Sdk.XunitException($"nessun on-hold: {string.Join(", ", d.Actions.Select(a => a.Kind))}");
    }

    public static DecisionContext Ctx(int active = 0, Limits? limits = null, QuotaInfo? quota = null,
        Dictionary<string, IReadOnlyList<int>>? inDev = null, Dictionary<string, IReadOnlyList<int>>? inTest = null) =>
        new(Names, limits ?? new Limits(), T0.AddHours(1), active, [], inDev, inTest, quota);

    public static readonly TestEnvironmentSpec Env = new("collaudo/compose.yml", ["web", "api"], new Dictionary<string, string> { ["app"] = "web", ["api"] = "api" });

    public static readonly AreaMapping Area = new("DevOps.Agents\\AI\\Stime", "Acme.AI", "C:/develop/GIT/Acme.AI", "Acme.AI", "stime", 115, "https://srv-app-test:5480");

    /// <summary>Una card in quello stato, entrata alla revisione 10 un'ora fa, con il tag agents.</summary>
    public static CardBuilder Card(string stateKey) => new(stateKey);

    public static readonly FeatureInfo Feature10 = new(10, "Preventivi", "Active", [], "DevOps.Agents\\AI\\Stime", 1000);

    /// <summary>D52: una funzionalita con la card di chiusura 90 nello stato dato e le sorelle date (id, chiave di stato).</summary>
    public static FeatureContext Feature(bool closing = false, string closingState = StateKeys.New, string? branch = "feature/f10-preventivi", FeatureInfo? feature = null, params (int Id, string State)[] siblings) =>
        new(feature ?? Feature10, closing, 90, Names[closingState], branch, siblings.Select(x => new Sibling(x.Id, Names[x.State], [])).ToList());

    public static SessionRecord Session(string role, string? outcome, string? reason = null, int minutesAfterT0 = 30, string? text = null, int? task = null, bool finished = true) =>
        new()
        {
            Id = $"{role}-{minutesAfterT0}", Role = role, Reason = reason, Start = T0.AddMinutes(minutesAfterT0 - 10),
            End = finished ? T0.AddMinutes(minutesAfterT0) : null, Outcome = outcome, Text = text, TaskId = task,
        };
}

internal sealed class CardBuilder(string stateKey)
{
    private readonly List<string> _tags = [Fx.Names.AgentsTag];
    private readonly List<Comment> _comments = [];
    private readonly List<WorkTask> _tasks = [];
    private readonly List<Predecessor> _preds = [];
    private readonly List<StateChange> _history = [];
    private PullRequestInfo? _pr;
    private PipelineRun? _run;
    private DeployChoice? _deploy;
    private AreaMapping? _area = Fx.Area;
    private string? _from = StateKeys.Ready;
    private int? _parent;
    private FeatureContext? _feature;
    private string? _buildErrors;
    private readonly List<Comment> _all = [];
    public CardLocalState Local { get; } = new();

    // una card in uno stato con il ramo ha il suo ramo nello stato locale (senza, e una presa in carico da un altro PC)
    private readonly bool _withBranch = StateKeys.WithBranch.Contains(stateKey);
    private bool _noBranch;
    public CardBuilder NoBranch() { Local.Branch = null; _noBranch = true; return this; }

    public CardBuilder Tag(string tag) { _tags.Add(tag); return this; }
    public CardBuilder Parent(int featureId) { _parent = featureId; return this; }
    /// <summary>D52: la funzionalita della card (Feature 10, card di chiusura 90).</summary>
    public CardBuilder InFeature(FeatureContext f) { _feature = f; _parent = f.Feature.Id; return this; }
    public CardBuilder BuildErrors(string text) { _buildErrors = text; return this; }
    public CardBuilder OldComment(string author, string text) { _all.Add(new Comment(100 + _all.Count, author, text, Fx.T0)); return this; }
    public CardBuilder NoAgentsTag() { _tags.Remove(Fx.Names.AgentsTag); return this; }
    public CardBuilder OnHold(string? per = null) { _tags.Add(Fx.Names.OnHoldTag); Local.WaitingFor = per; return this; }
    public CardBuilder WaitingFor(string per) { Local.WaitingFor = per; return this; }
    public CardBuilder From(string key) { _from = key; return this; }
    public CardBuilder PersonComment(string text = "Ecco la risposta") { _comments.Add(new Comment(_comments.Count + 1, "Anna", text, Fx.T0.AddMinutes(40))); return this; }
    public CardBuilder AgentComment(string text) { _comments.Add(new Comment(_comments.Count + 1, "Titolare", text, Fx.T0.AddMinutes(40))); return this; }
    public CardBuilder Task(int id, string stateKey = "taskAttivo") { _tasks.Add(new WorkTask(id, $"task {id}", Fx.N(stateKey))); return this; }
    public CardBuilder Predecessor(int id, string stateKey, int? prId = null, string? folder = null) { _preds.Add(new Predecessor(id, Fx.N(stateKey), null, prId, folder)); return this; }
    public CardBuilder Pr(string validation, string status = PrStatuses.Active, int? buildId = 7, string? head = "HEAD1") { _pr = new PullRequestInfo(5, status, validation, buildId, "https://log/7", head); return this; }
    public CardBuilder Run(string status, string? result, int runId = 70, int? afterRev = 10) { _run = new PipelineRun(status, result, "https://run/70"); Local.RunId = runId; Local.RunAfterRev = afterRev; return this; }
    public CardBuilder Deploy(params string[] selected) { _deploy = new DeployChoice(selected); return this; }
    public CardBuilder Deploy(string[] selected, string[] allowed) { _deploy = new DeployChoice(selected, allowed); return this; }
    public CardBuilder NoPipeline() { _area = Fx.Area with { DeployPipeline = null }; return this; }
    public CardBuilder NoTestUrl() { _area = Fx.Area with { TestUrl = null }; return this; }
    public CardBuilder WithTestEnvironment() { _area = Fx.Area with { TestEnvironment = Fx.Env }; return this; }
    public CardBuilder NoHistory() { _from = null; return this; }

    public CardBuilder Last(SessionRecord s)
    {
        Local.LastSessionByRole[s.Role] = s;
        Local.LastRole = s.Role;
        return this;
    }

    /// <summary>Una sessione passata del ruolo, senza farla diventare l'ultima.</summary>
    public CardBuilder Earlier(SessionRecord s) { Local.LastSessionByRole[s.Role] = s; return this; }

    public CardBuilder With(Action<CardLocalState> change) { change(Local); return this; }

    public Snapshot Build()
    {
        if (_withBranch && Local.Branch is null && !_noBranch) Local.Branch = "feature/42-card";
        var history = new List<StateChange>(_history);
        if (_from is not null) history.Add(new StateChange(10, Fx.N(_from), Fx.N(stateKey), Fx.T0));
        var card = new Card(42, 12, "Importare le stime", Fx.N(stateKey), _tags, _area?.Area, ParentId: _parent);
        return new Snapshot(card, Local, _area, _comments, history, _tasks, _preds, _pr, _run, _deploy, _feature, _all.Concat(_comments).ToList(), _buildErrors);
    }
}
