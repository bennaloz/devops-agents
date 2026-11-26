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
    string? WorkItemType = null);

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
    string? GitHubRepo = null);

/// <summary>La scelta del deploy in Test fatta dal responsabile, e i parametri che lo YAML ammette (se letti).</summary>
public sealed record DeployChoice(IReadOnlyList<string> Selected, IReadOnlyList<string>? Allowed = null, string? AllowedError = null);

/// <summary>La quota dell'abbonamento: pausa dopo il limite di token, e l'uso settimanale (D51).</summary>
public sealed record QuotaInfo(DateTimeOffset? PauseUntil, double? WeeklyUtilization, DateTimeOffset? WeeklyResetsAt);

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
    public int ReviewRounds { get; set; }
    public int RedInARow { get; set; }
    public int TestRounds { get; set; }
    public int Relaunches { get; set; }
    public string? RelaunchOf { get; set; }
    public int? HandledRedBuild { get; set; }
    public string? CompletePrKey { get; set; }
    public int LastCommentId { get; set; }
    public List<string> Notices { get; set; } = new();

    [JsonIgnore] public SessionRecord? LastSession => LastRole is not null && LastSessionByRole.TryGetValue(LastRole, out var s) ? s : null;

    public SessionRecord? Of(string role) => LastSessionByRole.TryGetValue(role, out var s) ? s : null;

    public CardLocalState Clone()
    {
        var c = (CardLocalState)MemberwiseClone();
        c.LastSessionByRole = new Dictionary<string, SessionRecord>(LastSessionByRole);
        c.Notices = new List<string>(Notices);
        return c;
    }

    public void ResetCounters()
    {
        ReviewRounds = 0; RedInARow = 0; TestRounds = 0; Relaunches = 0;
        CompletePrKey = null; WaitingFor = null;
    }
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
    DeployChoice? Deploy = null);
