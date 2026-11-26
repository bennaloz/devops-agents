using System.Text.Json.Serialization;

namespace DevOpsAgents.Core.Model;

/// <summary>Una persona della board (chi crea, chi ha in carico una card).</summary>
public sealed record Person(string Id, string Name, string? UniqueName = null);

/// <summary>La card come la legge la board. <see cref="State"/> e il nome dello stato sul processo (es. "In development").</summary>
public sealed record Card(
    int Id,
    int Rev,
    string Title,
    string State,
    IReadOnlyList<string> Tags,
    string? Area,
    Person? AssignedTo = null,
    Person? CreatedBy = null,
    string? WorkItemType = null,
    /// <summary>Il padre (la Feature, D60): l'ordine e la pausa delle card vengono da li.</summary>
    int? ParentId = null);

/// <summary>Una Feature aperta delle aree della mappa (D60): la priorita e l'ordine del backlog (StackRank), la pausa e il tag paused.</summary>
public sealed record FeatureInfo(int Id, string Title, string State, IReadOnlyList<string> Tags, string? Area, double? Rank)
{
    public bool HasTag(string? tag) => tag is not null && Tags.Contains(tag, StringComparer.OrdinalIgnoreCase);
}

public sealed record Comment(int Id, string Author, string Text, DateTimeOffset When);

/// <summary>Un cambio di stato della card: da <see cref="From"/> a <see cref="To"/> alla revisione <see cref="Rev"/>.</summary>
public sealed record StateChange(int Rev, string? From, string To, DateTimeOffset When, string? ById = null, string? ByName = null);

public sealed record WorkTask(int Id, string Title, string State);

/// <summary>Una card precedente (link Predecessor): finche non e unita, la successiva non parte.</summary>
public sealed record Predecessor(int Id, string State, int? ParentId = null, int? PrId = null, string? Folder = null);

/// <summary>
/// La PR della card, uguale per Azure Repos e GitHub. Status: active, completed, abandoned.
/// Validation: verde, rossa, inCorso, scaduta, conflitti, assente.
/// </summary>
public sealed record PullRequestInfo(int Id, string Status, string Validation, int? BuildId = null, string? LogUrl = null, string? HeadCommit = null);

public static class Validations
{
    public const string Green = "verde";
    public const string Red = "rossa";
    public const string Running = "inCorso";
    public const string Expired = "scaduta";
    public const string Conflicts = "conflitti";
    public const string None = "assente";
}

public static class PrStatuses
{
    public const string Active = "active";
    public const string Completed = "completed";
    public const string Abandoned = "abandoned";
}

/// <summary>Un run di pipeline (il deploy in Test). Status: notStarted, inProgress, completed. Result: succeeded, failed, ...</summary>
public sealed record PipelineRun(string Status, string? Result, string? Url, string? SourceVersion = null);

/// <summary>Dove sta il codice di un'area.</summary>
public enum SourceControl { AzureRepos, GitHub }

/// <summary>Una voce di config/mappa.json: un'area della board e il repo che la realizza.</summary>
public sealed record AreaMapping(
    string Area,
    string Repo,
    string Folder,
    string AdoProject,
    string Component,
    int? DeployPipeline,
    string? TestUrl,
    SourceControl Source = SourceControl.AzureRepos,
    string? GitHubRepo = null,
    /// <summary>D59: la voce collaudo della mappa. Con questa, la card si collauda nel suo ambiente Docker invece che in Test.</summary>
    TestEnvironmentSpec? TestEnvironment = null);

/// <summary>
/// D59: l'ambiente di collaudo di un componente (voce collaudo di config/mappa.json): il file compose (relativo al worktree), i nomi
/// delle porte (nell'ordine: portaBase + slot*100 + indice) e gli URL da dare al collaudatore (nome -> nome della porta).
/// </summary>
public sealed record TestEnvironmentSpec(string Compose, IReadOnlyList<string> Ports, IReadOnlyDictionary<string, string> Urls);

/// <summary>La scelta del deploy in Test fatta dal responsabile, e i parametri che lo YAML ammette (se letti).</summary>
public sealed record DeployChoice(IReadOnlyList<string> Selected, IReadOnlyList<string>? Allowed = null, string? AllowedError = null);

/// <summary>
/// La quota dell'abbonamento (quota.json): la pausa dopo il limite di token (D51), l'uso della finestra settimanale e di quella
/// di 5 ore (D60) letti dall'ultimo rate_limit_event di una sessione.
/// </summary>
public sealed record QuotaInfo(DateTimeOffset? PauseUntil, double? WeeklyUtilization, DateTimeOffset? WeeklyResetsAt,
    double? FiveHourUtilization = null, DateTimeOffset? FiveHourResetsAt = null);

/// <summary>Gli override della vista sulle soglie di quota, validi fino al reset della loro finestra (soglia-quota.json).</summary>
public sealed record QuotaOverrides(double? WeeklyThreshold = null, bool IgnoreWeeklyReserve = false, DateTimeOffset? WeeklyUntil = null,
    double? FiveHourThreshold = null, DateTimeOffset? FiveHourUntil = null);

/// <summary>Una sessione di un ruolo sulla card, come la registra lo smistatore.</summary>
public sealed class SessionRecord
{
    public required string Id { get; init; }
    public required string Role { get; init; }
    /// <summary>Perche e partita: nuova, pronto, rossa, rilievi, ripresa, ...</summary>
    public string? Reason { get; init; }
    public DateTimeOffset? Start { get; init; }
    public DateTimeOffset? End { get; set; }
    /// <summary>La riga ESITO=... con cui ha chiuso: fatto, bloccato, bivio, superata, bloccante, respinta, domande, rilancia.</summary>
    public string? Outcome { get; set; }
    /// <summary>Il testo del riepilogo della sessione (diventa l'allegato del ruolo dopo).</summary>
    public string? Text { get; set; }
    public int? TaskId { get; init; }
    [JsonIgnore] public bool IsFinished => End is not null;
}

/// <summary>
/// Lo stato locale di una card (stato.json dell'originale): ramo, cartella, PR, run, sessioni e contatori.
/// Lo scrive solo lo smistatore.
/// </summary>
public sealed class CardLocalState
{
    public string? Branch { get; set; }
    public string? Folder { get; set; }
    /// <summary>Il ramo verso cui va la PR: develop, o il ramo della funzionalita.</summary>
    public string? Destination { get; set; }
    public int? PrId { get; set; }
    public int? RunId { get; set; }
    /// <summary>La revisione di ingresso nello stato per cui e stato accodato il run: un run vecchio non vale dopo un nuovo ingresso.</summary>
    public int? RunAfterRev { get; set; }
    /// <summary>L'id della sessione in corso, se c'e.</summary>
    public string? RunningSession { get; set; }
    public string? LastRole { get; set; }
    public Dictionary<string, SessionRecord> LastSessionByRole { get; set; } = new();
    /// <summary>Come ripartire quando una persona toglie l'on-hold: sessione, limite, deploy, quota.</summary>
    public string? WaitingFor { get; set; }
    /// <summary>D57: cosa deve fare una persona per l'on-hold in corso (gesto, perche, perche non gli agenti).</summary>
    public Decisions.Indications? OnHoldIndications { get; set; }
    public int ReviewRounds { get; set; }
    public int RedInARow { get; set; }
    public int TestRounds { get; set; }
    public int Relaunches { get; set; }
    public string? RelaunchOf { get; set; }
    public int? HandledRedBuild { get; set; }
    public string? CompletePrKey { get; set; }
    public int LastCommentId { get; set; }
    /// <summary>D59: lo slot, il progetto compose, il processo che lo crea e gli URL dell'ambiente di collaudo della card.</summary>
    public int? TestSlot { get; set; }
    public string? TestProject { get; set; }
    public DateTimeOffset? TestStartedAt { get; set; }
    public Dictionary<string, string>? TestUrls { get; set; }
    public List<string> Notices { get; set; } = new();
    /// <summary>D52: le correzioni gia diventate Bug (id del commento), le teste per cui c'e gia una Bug allinea-develop.</summary>
    public List<string> CorrectionsDone { get; set; } = new();
    public List<string> AlignDone { get; set; } = new();
    /// <summary>D52: la testa della PR con cui la card di chiusura e tornata in Ready to develop: un secondo ritorno per la stessa e un on-hold.</summary>
    public string? ReturnCommit { get; set; }
    /// <summary>D52: la Feature da chiudere quando la card di chiusura sara chiusa.</summary>
    public int? FeatureToClose { get; set; }
    /// <summary>D52: la CI rossa della card di chiusura gia data al responsabile (build), quante di fila, e se va rilanciata dopo un on-hold.</summary>
    public string? CiRedHandled { get; set; }
    public int CiRedInARow { get; set; }
    public bool CiRedRetry { get; set; }
    /// <summary>Gli errori della build letti una volta per build (D52): build e testo.</summary>
    public string? BuildErrorsOf { get; set; }
    public string? BuildErrors { get; set; }

    [JsonIgnore] public SessionRecord? LastSession => LastRole is not null && LastSessionByRole.TryGetValue(LastRole, out var s) ? s : null;

    public SessionRecord? Of(string role) => LastSessionByRole.TryGetValue(role, out var s) ? s : null;

    public CardLocalState Clone()
    {
        var c = (CardLocalState)MemberwiseClone();
        if (TestUrls is not null) c.TestUrls = new Dictionary<string, string>(TestUrls);
        c.LastSessionByRole = new Dictionary<string, SessionRecord>(LastSessionByRole);
        c.Notices = new List<string>(Notices);
        c.CorrectionsDone = new List<string>(CorrectionsDone);
        c.AlignDone = new List<string>(AlignDone);
        return c;
    }

    public void ResetCounters()
    {
        ReviewRounds = 0; RedInARow = 0; TestRounds = 0; Relaunches = 0; CiRedInARow = 0;
        CompletePrKey = null; WaitingFor = null; ReturnCommit = null;
    }
}

/// <summary>Una card sorella nella stessa Feature (D52): per sapere se e unita nel ramo della funzionalita.</summary>
public sealed record Sibling(int Id, string State, IReadOnlyList<string> Tags);

/// <summary>
/// D52: la funzionalita di una card, se la sua Feature ha una card di chiusura. IsClosing: questa card e la card di chiusura.
/// Branch: il ramo della funzionalita su origin (null se non c'e ancora). Siblings: le altre card della Feature (senza le Removed).
/// Error: la funzionalita non si e letta (la card allora non fa niente).
/// </summary>
public sealed record FeatureContext(FeatureInfo Feature, bool IsClosing, int ClosingCardId, string? ClosingState, string? Branch, IReadOnlyList<Sibling> Siblings, string? Error = null)
{
    public static FeatureContext Failed(string error) => new(new FeatureInfo(0, "", "", [], null, null), false, 0, null, null, [], error);
}

/// <summary>Tutto cio che serve per decidere su una card, letto una volta per giro.</summary>
public sealed record Snapshot(
    Card Card,
    CardLocalState Local,
    AreaMapping? Area,
    IReadOnlyList<Comment> NewComments,
    IReadOnlyList<StateChange> History,
    IReadOnlyList<WorkTask> Tasks,
    IReadOnlyList<Predecessor> Predecessors,
    PullRequestInfo? Pr = null,
    PipelineRun? Run = null,
    DeployChoice? Deploy = null,
    /// <summary>D52: la funzionalita della card (null per una card isolata).</summary>
    FeatureContext? Feature = null,
    /// <summary>Tutti i commenti, letti e no: le correzioni scritte dal responsabile e le Bug gia create stanno li.</summary>
    IReadOnlyList<Comment>? AllComments = null,
    /// <summary>D52: per la card di chiusura, gli errori di codice della build rossa (validazione o deploy); null se non ce ne sono.</summary>
    string? BuildErrors = null);
