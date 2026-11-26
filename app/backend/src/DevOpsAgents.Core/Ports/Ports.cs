using DevOpsAgents.Core.Model;

namespace DevOpsAgents.Core.Ports;

/// <summary>La board delle card (Azure DevOps Boards). Una sola implementazione oggi; l'interfaccia tiene fuori i dettagli del processo.</summary>
public interface IBoard
{
    /// <summary>Le card attive con il tag degli agenti (le Draft escluse), con stato, tag, area e assegnatario.</summary>
    Task<IReadOnlyList<Card>> GetActiveCardsAsync(CancellationToken ct = default);
    Task<IReadOnlyList<Comment>> GetCommentsAsync(int cardId, CancellationToken ct = default);
    Task<IReadOnlyList<StateChange>> GetStateHistoryAsync(int cardId, CancellationToken ct = default);
    Task<IReadOnlyList<WorkTask>> GetTasksAsync(int cardId, CancellationToken ct = default);
    Task<IReadOnlyList<Predecessor>> GetPredecessorsAsync(int cardId, CancellationToken ct = default);
    Task SetStateAsync(int cardId, string stateName, CancellationToken ct = default);
    Task AddTagAsync(int cardId, string tag, CancellationToken ct = default);
    Task AddCommentAsync(int cardId, string markdown, CancellationToken ct = default);
    /// <summary>Un link sulla card (la PR di GitHub, che la board non collega da sola).</summary>
    Task AddLinkAsync(int cardId, string url, string? comment = null, CancellationToken ct = default);
    Task<Person> GetCurrentUserAsync(CancellationToken ct = default);
    string CardUrl(int cardId);
}

/// <summary>Dove sta il codice di un'area: Azure Repos o GitHub. Stessi oggetti per le due sorgenti.</summary>
public interface ICodeHost
{
    Task<PullRequestInfo?> GetPullRequestAsync(AreaMapping area, string branch, string destination, bool includeCompleted, CancellationToken ct = default);
    /// <summary>Apre la PR e restituisce numero e indirizzo. Con <paramref name="cardId"/> la collega alla card come puo.</summary>
    Task<(int Id, string Url)> CreatePullRequestAsync(AreaMapping area, string branch, string destination, string title, string description, int cardId, CancellationToken ct = default);
    /// <summary>Merge con merge commit sul commit verificato, e cancella il ramo sorgente.</summary>
    Task CompletePullRequestAsync(AreaMapping area, int prId, string? commit, CancellationToken ct = default);
    /// <summary>Rilancia le validazioni rosse (o, con <paramref name="expiredOnly"/>, quelle scadute). Restituisce quante.</summary>
    Task<int> RequeueValidationsAsync(AreaMapping area, string branch, string destination, bool expiredOnly, CancellationToken ct = default);
    string PullRequestUrl(AreaMapping area, int prId);
    /// <summary>true se la PR deve essere collegata alla card con un link (GitHub); Azure Repos la collega da se.</summary>
    bool NeedsCardLink { get; }
}

/// <summary>Sceglie l'implementazione di <see cref="ICodeHost"/> per l'area (config/mappa.json, chiave sorgente).</summary>
public interface ICodeHostResolver
{
    ICodeHost For(AreaMapping area);
}

/// <summary>Le pipeline: il deploy in Test e i suoi run (Azure Pipelines, anche per i repo GitHub).</summary>
public interface ICiService
{
    Task<int> QueueTestDeployAsync(AreaMapping area, string branch, IReadOnlyList<string> on, IReadOnlyList<string> off, CancellationToken ct = default);
    Task<PipelineRun> GetRunAsync(AreaMapping area, int runId, CancellationToken ct = default);
}

/// <summary>I worktree delle card sul disco: uno per card, dal ramo pubblicato o da origin/develop.</summary>
public interface IWorkspace
{
    Task<(string Branch, string Folder)> CreateWorktreeAsync(AreaMapping area, Card card, string? baseBranch, CancellationToken ct = default);
    Task RemoveWorktreeAsync(AreaMapping area, string folder, CancellationToken ct = default);
}

/// <summary>Il risultato di una sessione finita: la riga ESITO, il testo, e se e finita sul limite di token.</summary>
public sealed record SessionResult(string? Outcome, string? Text, bool HitTokenLimit = false, DateTimeOffset? LimitResetsAt = null);

/// <summary>Le sessioni dei ruoli (claude -p): avvio e controllo. Non decide niente.</summary>
public interface ISessionRunner
{
    /// <summary>Avvia la sessione e restituisce il suo id.</summary>
    Task<string> StartAsync(SessionRequest request, CancellationToken ct = default);
    /// <summary>null se la sessione e ancora in corso, altrimenti il risultato.</summary>
    Task<SessionResult?> PollAsync(string sessionId, CancellationToken ct = default);
    IReadOnlyCollection<string> Running { get; }
}

public sealed record SessionRequest(string Role, int CardId, AreaMapping Area, string? WorkingFolder, string Message, string? SessionId, bool Resume, int? TaskId, string? BaseBranch);

/// <summary>Lo stato locale delle card (stato.json): lo legge e lo scrive solo lo smistatore.</summary>
public interface IStateStore
{
    Task<Dictionary<int, CardLocalState>> LoadAsync(CancellationToken ct = default);
    Task SaveAsync(IReadOnlyDictionary<int, CardLocalState> state, CancellationToken ct = default);
}

/// <summary>L'ora: nei test e ferma.</summary>
public interface IClock
{
    DateTimeOffset Now { get; }
}

public sealed class SystemClock : IClock
{
    public DateTimeOffset Now => DateTimeOffset.UtcNow;
}
