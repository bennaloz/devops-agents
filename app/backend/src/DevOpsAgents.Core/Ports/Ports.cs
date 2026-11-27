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
    Task RemoveTagAsync(int cardId, string tag, CancellationToken ct = default);
    /// <summary>D60: le Feature aperte delle aree date, con rank e tag. Un errore ferma il giro: senza, una Feature in pausa ripartirebbe.</summary>
    Task<IReadOnlyList<FeatureInfo>> GetOpenFeaturesAsync(IReadOnlyList<string> areas, CancellationToken ct = default);
    /// <summary>D52: le card figlie di una Feature (relazione Parent), con stato e tag.</summary>
    Task<IReadOnlyList<Card>> GetFeatureChildrenAsync(int featureId, CancellationToken ct = default);
    /// <summary>D52: una Bug figlia della Feature (correzione o allinea-develop), assegnata, con i tag e lo stato iniziale. Restituisce l'id.</summary>
    Task<int> CreateBugAsync(NewBug bug, CancellationToken ct = default);
    /// <summary>La PR collegata alla card (Azure Repos: il link della PR; GitHub: il link che mette lo smistatore), la piu recente; null se nessuna.</summary>
    Task<int?> GetLinkedPullRequestIdAsync(int cardId, CancellationToken ct = default);
    /// <summary>D60: l'ordine del backlog (Microsoft.VSTS.Common.StackRank).</summary>
    Task SetRankAsync(int workItemId, double rank, CancellationToken ct = default);
    string CardUrl(int cardId);
    /// <summary>D52: una card per id, anche fuori dalle attive (Closed, Removed); null se non c'e. Serve a chiudere la Feature dopo la card di chiusura.</summary>
    Task<Card?> GetCardStateAsync(int cardId, CancellationToken ct = default) => Task.FromResult<Card?>(null);
    /// <summary>D52: lo stato di una Feature (anche Closed o Removed); null se non si sa.</summary>
    Task<string?> GetFeatureStateAsync(int featureId, CancellationToken ct = default) => Task.FromResult<string?>(null);
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
    /// <summary>D52: i rami su origin che cominciano con il prefisso (feature/f10 trova feature/f10 e feature/f10-titolo).</summary>
    Task<IReadOnlyList<string>> ListBranchesAsync(AreaMapping area, string prefix, CancellationToken ct = default);
    /// <summary>Una PR per numero: stato (active, completed, abandoned) e ramo sorgente; null se non c'e.</summary>
    Task<(string Status, string Branch)?> GetPullRequestByIdAsync(AreaMapping area, int prId, CancellationToken ct = default);
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
    /// <summary>D52: gli errori di codice di una build (test falliti, errori di compilazione) dai log dei passi falliti; null se non ce ne sono.</summary>
    Task<string?> GetBuildErrorsAsync(AreaMapping area, int buildId, CancellationToken ct = default);
}

/// <summary>D52: una Bug da creare sotto una Feature. InitialState: la chiave di stato in cui deve nascere (null = resta nello stato iniziale, Draft).</summary>
public sealed record NewBug(string Title, string Description, string? Criteria, string Area, int ParentId, IReadOnlyList<string> Tags, string? InitialState, string AssignedTo);

/// <summary>I worktree delle card sul disco: uno per card, dal ramo pubblicato o da origin/develop.</summary>
public interface IWorkspace
{
    Task<(string Branch, string Folder)> CreateWorktreeAsync(AreaMapping area, Card card, string? baseBranch, CancellationToken ct = default);
    Task RemoveWorktreeAsync(AreaMapping area, string folder, CancellationToken ct = default);
    /// <summary>D52: il ramo della funzionalita (feature/ o bugfix/f&lt;id&gt;-&lt;titolo&gt;) da origin/develop e pubblicato; se c'e gia, quello.</summary>
    Task<string> PublishFeatureBranchAsync(AreaMapping area, FeatureInfo feature, bool bug, CancellationToken ct = default);
    /// <summary>D52: il worktree in sola lettura della card di chiusura (detached su origin/&lt;ramo&gt;), creato o riportato al ramo aggiornato.</summary>
    Task<string> UpdateClosingWorktreeAsync(AreaMapping area, Card card, string branch, CancellationToken ct = default);
    /// <summary>Presa in carico (spec, sezione 19): il worktree dal ramo della card pubblicato su origin; null se su origin non c'e.</summary>
    Task<(string Branch, string Folder)?> CreateWorktreeFromRemoteAsync(AreaMapping area, Card card, CancellationToken ct = default);
    bool Exists(string folder) => Directory.Exists(folder);
}

/// <summary>Il risultato di una sessione finita: la riga ESITO, il testo, e se e finita sul limite di token.</summary>
/// <summary>
/// L'esito di una sessione. Failed: errore o comandi negati senza esito. NoResultCause: la sessione non ha dato un risultato (silenzio: chiusa
/// dallo smistatore; morta: il processo non c'e piu).
/// </summary>
public sealed record SessionResult(string? Outcome, string? Text, bool HitTokenLimit = false, DateTimeOffset? LimitResetsAt = null, QuotaInfo? Quota = null,
    bool Failed = false, string? NoResultCause = null);

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

/// <summary>Le impostazioni che cambiano dalla dashboard (impostazioni.json): per ora la pausa del sistema (D60).</summary>
public sealed record SystemSettings(bool Paused = false);

public interface ISettingsStore
{
    Task<SystemSettings> LoadAsync(CancellationToken ct = default);
    Task SaveAsync(SystemSettings settings, CancellationToken ct = default);
}

/// <summary>La quota (quota.json) e i suoi override (soglia-quota.json): una per tutti i ruoli.</summary>
public interface IQuotaStore
{
    Task<QuotaInfo?> LoadAsync(CancellationToken ct = default);
    Task SaveAsync(QuotaInfo quota, CancellationToken ct = default);
    Task<QuotaOverrides?> LoadOverridesAsync(CancellationToken ct = default);
    Task SaveOverridesAsync(QuotaOverrides overrides, CancellationToken ct = default);
}

/// <summary>D59: un ambiente di collaudo appena avviato: il progetto compose, gli URL per il collaudatore, il log.</summary>
public sealed record TestEnvironmentStarted(string Project, IReadOnlyDictionary<string, string> Urls, string LogPath, DateTimeOffset StartedAt);

/// <summary>
/// D59: gli ambienti Docker di collaudo delle card. La creazione e lunga (build, database, Keycloak): parte e si controlla ai giri dopo,
/// come un run di pipeline. Lo stato si legge nella forma di un run (inProgress, completed con succeeded o failed).
/// </summary>
public interface ITestEnvironments
{
    Task<TestEnvironmentStarted> StartAsync(AreaMapping area, int cardId, int slot, string folder, CancellationToken ct = default);
    Task<PipelineRun> GetStatusAsync(int cardId, DateTimeOffset startedAt, CancellationToken ct = default);
    /// <summary>Ferma la creazione se e in corso e fa compose down -v con i volumi rimasti; false se docker non risponde (si riprova).</summary>
    Task<bool> RemoveAsync(string project, string? folder, CancellationToken ct = default);
    /// <summary>I progetti card-&lt;id&gt; che docker conosce (contenitori con l'etichetta e volumi del progetto).</summary>
    Task<IReadOnlyList<string>> ListProjectsAsync(CancellationToken ct = default);
}

/// <summary>D46: le lezioni di un ruolo per un repo (comune.md e &lt;repo&gt;.md), stabili e in prova. Non lancia: senza memoria, niente memoria.</summary>
public interface IMemorySource
{
    Task<IReadOnlyList<DevOpsAgents.Core.Memory.MemoryFile>> GetAsync(string role, string repo, CancellationToken ct = default);
}
