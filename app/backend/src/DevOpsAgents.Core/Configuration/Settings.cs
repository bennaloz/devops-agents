namespace DevOpsAgents.Core.Configuration;

/// <summary>
/// Le chiavi degli stati e dei tag di config/stati.json (le stesse dell'originale): il codice usa le chiavi, la board i nomi.
/// </summary>
public static class StateKeys
{
    public const string Draft = "bozza";
    public const string New = "nuova";
    public const string NeedsClarification = "daChiarire";
    public const string Ready = "pronto";
    public const string InDevelopment = "inSviluppo";
    public const string InReview = "inRevisione";
    public const string DeployingToTest = "inDeployTest";
    public const string AutomatedTest = "inCollaudo";
    public const string HumanTest = "inProvaUmana";
    public const string ReadyToMerge = "daUnire";
    public const string InFeatureBranch = "inFeature";
    public const string ReadyToRelease = "daRilasciare";
    public const string Releasing = "inRilascio";
    public const string Closed = "chiusa";
    public const string Removed = "rimossa";

    public static readonly string[] InTest = [DeployingToTest, AutomatedTest, HumanTest];
    /// <summary>Gli stati in cui la card ha un ramo e (di solito) un worktree.</summary>
    public static readonly string[] WithBranch = [InDevelopment, InReview, DeployingToTest, AutomatedTest, HumanTest, ReadyToMerge, InFeatureBranch, ReadyToRelease];
}

/// <summary>config/stati.json letto: chiave -> nome sulla board, in tutte e due le direzioni.</summary>
public sealed class StateNames
{
    private readonly IReadOnlyDictionary<string, string> _byKey;

    public StateNames(IReadOnlyDictionary<string, string> byKey) => _byKey = byKey;

    public string this[string key] => _byKey.TryGetValue(key, out var v) ? v : throw new KeyNotFoundException($"stati.json: manca la chiave '{key}'");

    public string? Get(string key) => _byKey.TryGetValue(key, out var v) ? v : null;

    /// <summary>La chiave di uno stato della card dal suo nome (senza distinzione di maiuscole), o null. Gli stati dei task e della Feature non contano.</summary>
    public string? KeyOf(string? name)
    {
        if (string.IsNullOrEmpty(name)) return null;
        foreach (var (k, v) in _byKey)
        {
            if (k.StartsWith("tag", StringComparison.Ordinal) || k.StartsWith("task", StringComparison.Ordinal) || k.StartsWith("feature", StringComparison.Ordinal)) continue;
            if (string.Equals(v, name, StringComparison.OrdinalIgnoreCase)) return k;
        }
        return null;
    }

    public string AgentsTag => this["tagAgenti"];
    public string OnHoldTag => this["tagAttesa"];
    public string? NoTestTag => Get("tagSenzaTest");
    public string? HumanTestTag => Get("tagProvaUmana");
    /// <summary>D60: il tag della pausa, su una Feature o su una card sola.</summary>
    public string? PausedTag => Get("tagPausa");
    /// <summary>D52: la card di chiusura, la Feature di correzione (ramo bugfix/), la Bug che allinea il ramo della funzionalita a develop.</summary>
    public string? ClosingTag => Get("tagChiusura");
    public string? BugFeatureTag => Get("tagBugFeature");
    public string? AlignTag => Get("tagAllinea");
    public IEnumerable<string> ClosedTaskStates => new[] { Get("taskChiuso"), Get("taskRimosso") }.Where(s => s is not null)!;
}

/// <summary>config/limiti.json.</summary>
public sealed record Limits
{
    public int ActiveSessions { get; init; } = 3;
    public int CardsInDevelopmentPerRepo { get; init; } = 1;
    public int CardsInTestPerComponent { get; init; } = 1;
    public int ReviewRounds { get; init; } = 2;
    public int TestRounds { get; init; } = 2;
    public int RedInARow { get; init; } = 3;
    public int SilenceMinutes { get; init; } = 45;
    public int ValidationMinutes { get; init; } = 60;
    public int IntervalMinutes { get; init; } = 2;
    public double WeeklyQuotaThreshold { get; init; } = 0.70;
    /// <summary>D60: oltre questa parte della finestra di 5 ore non parte nessuna sessione nuova fino al suo reset.</summary>
    public double? FiveHourQuotaThreshold { get; init; } = 0.60;
    /// <summary>D59: quanti ambienti Docker di collaudo insieme, per i componenti con la voce collaudo.</summary>
    public int TestEnvironments { get; init; } = 3;
    /// <summary>D46: quante lezioni al massimo in un file di memoria (tettoMemoria).</summary>
    public int MemoryCap { get; init; } = 25;
}

/// <summary>Un ruolo di config/ruoli.json: modello, sforzo, brief e strumenti della sessione claude -p.</summary>
public sealed record RoleSettings(string Model, string Effort, string Brief, IReadOnlyList<string> Tools, string? Advisor = null,
    IReadOnlyList<RoleTransition>? Transitions = null);

/// <summary>Uno spostamento che il ruolo puo fare con card sposta (config/ruoli.json, transizioni): dalla chiave dello stato alla chiave.</summary>
public sealed record RoleTransition(string From, string To);
