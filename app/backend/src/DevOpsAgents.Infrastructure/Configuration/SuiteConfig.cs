using System.Text.Json;
using System.Text.Json.Nodes;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Model;

namespace DevOpsAgents.Infrastructure.Configuration;

/// <summary>
/// La configurazione della suite, letta dagli stessi file della versione PowerShell (config/*.json nella radice del repo):
/// le due versioni lavorano sulla stessa board con le stesse regole.
/// </summary>
public sealed record SuiteConfig(
    string Root,
    string Organization,
    string BoardProject,
    StateNames Names,
    Limits Limits,
    IReadOnlyDictionary<string, RoleSettings> Roles,
    IReadOnlyList<AreaMapping> Areas,
    AreaMapping? Memory = null)
{
    /// <summary>
    /// D46: il repo della PR della memoria: quello degli attrezzi, nel progetto della board (come MemoriaRepo.psm1). La voce "memoria" di
    /// mappa.json lo cambia (repo, progettoAdo, sorgente, repoGithub): la legge solo la versione .NET.
    /// </summary>
    public AreaMapping MemoryArea => Memory ?? new AreaMapping("memoria", "DevOps.Agents", Root, BoardProject, "memoria", null, null);

    public static SuiteConfig Load(string root)
    {
        JsonNode Read(string name)
        {
            var p = Path.Combine(root, "config", $"{name}.json");
            if (!File.Exists(p)) throw new FileNotFoundException($"File di configurazione mancante: {p}", p);
            return JsonNode.Parse(File.ReadAllText(p)) ?? throw new InvalidDataException($"{p} e vuoto");
        }

        var stati = Read("stati").AsObject().ToDictionary(kv => kv.Key, kv => kv.Value!.GetValue<string>());
        var l = Read("limiti");
        int I(string k, int d) => l[k]?.GetValue<int>() ?? d;
        var limits = new Limits
        {
            ActiveSessions = I("sessioniAttive", 3),
            CardsInDevelopmentPerRepo = I("cardInSviluppoPerRepo", 1),
            CardsInTestPerComponent = I("cardInTestPerComponente", 1),
            ReviewRounds = I("giriRevisione", 2),
            TestRounds = I("giriCollaudo", 2),
            RedInARow = I("rosseDiFila", 3),
            SilenceMinutes = I("silenzioMinuti", 45),
            ValidationMinutes = I("validazioneMinuti", 60),
            IntervalMinutes = I("intervalloMinuti", 2),
            WeeklyQuotaThreshold = l["sogliaQuotaSettimanale"]?.GetValue<double>() ?? 0.70,
            FiveHourQuotaThreshold = l["sogliaQuota5Ore"]?.GetValue<double>(),
            TestEnvironments = I("ambientiCollaudo", 3),
        };

        var roles = new Dictionary<string, RoleSettings>();
        foreach (var (name, node) in Read("ruoli").AsObject())
        {
            var brief = node!["brief"]!.GetValue<string>();
            if (!File.Exists(Path.Combine(root, brief))) throw new InvalidDataException($"Ruolo '{name}': il brief '{brief}' non esiste");
            roles[name] = new RoleSettings(node["modello"]!.GetValue<string>(), node["sforzo"]?.GetValue<string>() ?? "",
                brief, node["strumenti"]!.AsArray().Select(t => t!.GetValue<string>()).ToList(), node["advisor"]?.GetValue<string>(),
                node["transizioni"]?.AsArray().Select(t => new RoleTransition(t![0]!.GetValue<string>(), t[1]!.GetValue<string>())).ToList() ?? []);
        }

        var m = Read("mappa");
        var board = m["progettoBoard"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(board)) throw new InvalidDataException("mappa.json: manca 'progettoBoard' (il progetto della board)");
        var org = (m["organizzazione"]?.GetValue<string>() ?? "https://acme.visualstudio.com").TrimEnd('/');
        var areas = new List<AreaMapping>();
        foreach (var a in m["aree"]?.AsArray() ?? [])
        {
            var source = a!["sorgente"]?.GetValue<string>() ?? "ado";
            var gh = a["repoGithub"]?.GetValue<string>();
            var kind = source switch
            {
                "ado" => SourceControl.AzureRepos,
                "github" => SourceControl.GitHub,
                _ => throw new InvalidDataException($"mappa.json: l'area '{a["area"]}' ha sorgente '{source}': valori ammessi ado o github"),
            };
            if (kind == SourceControl.GitHub && (gh is null || !System.Text.RegularExpressions.Regex.IsMatch(gh, @"^[\w.-]+/[\w.-]+$")))
                throw new InvalidDataException($"mappa.json: l'area '{a["area"]}' ha sorgente github ma 'repoGithub' manca o non e nella forma <owner>/<repo>");
            areas.Add(new AreaMapping(
                a["area"]!.GetValue<string>(), a["repo"]!.GetValue<string>(), a["cartella"]?.GetValue<string>() ?? "",
                a["progettoAdo"]!.GetValue<string>(), a["componente"]?.GetValue<string>() ?? "",
                a["pipelineDeploy"]?.GetValue<int>(), a["urlTest"]?.GetValue<string>(), kind, gh, TestEnvironmentOf(a)));
        }
        AreaMapping? memory = null;
        if (m["memoria"] is JsonObject mm)
        {
            var gh = mm["sorgente"]?.GetValue<string>() == "github";
            memory = new AreaMapping("memoria", mm["repo"]?.GetValue<string>() ?? "DevOps.Agents", root, mm["progettoAdo"]?.GetValue<string>() ?? board!, "memoria", null, null,
                gh ? SourceControl.GitHub : SourceControl.AzureRepos, mm["repoGithub"]?.GetValue<string>());
        }
        return new SuiteConfig(root, org, board!, new StateNames(stati), limits with { MemoryCap = I("tettoMemoria", 25) }, roles, areas, memory);
    }

    /// <summary>config/supervisore.json: soglie e orari del supervisore (D51).</summary>
    public static DevOpsAgents.Core.Supervision.SupervisorSettings LoadSupervisor(string root)
    {
        var p = Path.Combine(root, "config", "supervisore.json");
        if (!File.Exists(p)) return new();
        var o = JsonNode.Parse(File.ReadAllText(p))!;
        int I(string k, int d) => o[k]?.GetValue<int>() ?? d;
        var rel = o["rilasci"];
        var byArea = (rel?["perArea"] as JsonObject)?.ToDictionary(kv => kv.Key, kv => (kv.Value!["card"]?.GetValue<int>() ?? 5, kv.Value!["giorni"]?.GetValue<int>() ?? 7))
            ?? new Dictionary<string, (int, int)>();
        return new()
        {
            IntervalMinutes = I("intervalloMinuti", 5),
            MinutesWithoutRound = I("minutiSenzaGiro", 10),
            CardErrorsInARow = I("erroriDiFilaPerCard", 5),
            HoursWithoutMovement = I("oreSenzaMovimento", 6),
            UrgentReminderHours = I("oreRicordoUrgente", 4),
            SummaryTimes = o["orariRiepilogo"]?.AsArray().Select(x => TimeSpan.Parse(x!.GetValue<string>(), System.Globalization.CultureInfo.InvariantCulture)).ToList() ?? [new(8, 30, 0), new(14, 0, 0)],
            PatNoticeDays = I("giorniPreavvisoPat", 7),
            ReleaseCards = rel?["predefinito"]?["card"]?.GetValue<int>() ?? 5,
            ReleaseDays = rel?["predefinito"]?["giorni"]?.GetValue<int>() ?? 7,
            ReleaseByArea = byArea,
        };
    }

    /// <summary>D59: la voce collaudo di un'area (compose, porte, url); ogni URL deve nominare una porta dell'elenco.</summary>
    private static TestEnvironmentSpec? TestEnvironmentOf(JsonNode a)
    {
        if (a["collaudo"] is not JsonObject c) return null;
        var compose = c["compose"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(compose)) throw new InvalidDataException($"mappa.json: la voce collaudo dell'area '{a["area"]}' non ha 'compose'");
        var ports = c["porte"]?.AsArray().Select(p => p!.GetValue<string>()).ToList() ?? [];
        var urls = c["url"]?.AsObject().ToDictionary(kv => kv.Key, kv => kv.Value!.GetValue<string>()) ?? [];
        foreach (var (name, port) in urls)
            if (!ports.Contains(port)) throw new InvalidDataException($"mappa.json: l'URL '{name}' del collaudo dell'area '{a["area"]}' usa la porta '{port}', che non e fra le porte");
        return new TestEnvironmentSpec(compose, ports, urls);
    }

    /// <summary>La radice del repo: la cartella che contiene config/stati.json, risalendo da <paramref name="start"/>.</summary>
    public static string FindRoot(string start)
    {
        for (var d = new DirectoryInfo(start); d is not null; d = d.Parent)
            if (File.Exists(Path.Combine(d.FullName, "config", "stati.json"))) return d.FullName;
        throw new DirectoryNotFoundException($"Nessuna cartella con config/stati.json sopra {start}: indica DevOpsAgents:Root");
    }

    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = true };
}
