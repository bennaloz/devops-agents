using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DevOpsAgents.Core.Supervision;

/// <summary>
/// Un run di pipeline come lo vedono supervisore e dashboard. Status: inCoda, inCorso, inAttesa (un'approvazione o una validazione manuale),
/// concluso. Kind: rilascio, pr, ci, pianificato, manuale, altro. Waiting: perche un run "in corso" non gira (controllo dell'environment, agente).
/// </summary>
public sealed record RunInfo(int Id, string Project, string Pipeline, string Branch, string? Author, string Status, string? Stage, DateTimeOffset? Start,
    DateTimeOffset? End, string? Result, int DefinitionId, string Kind, string? Url, bool Orchestrator = false, IReadOnlyList<string>? Components = null,
    string? Waiting = null, string? SourceVersion = null, IReadOnlyDictionary<string, string>? TemplateParameters = null, string? Agent = null, string? Pool = null);

public sealed record AgentInfo(string Name, bool Online, bool Enabled, int? JobBuildId = null, string? JobPipeline = null, string? JobUrl = null);

public sealed record AgentPool(string Pool, IReadOnlyList<AgentInfo> Agents);

/// <summary>
/// Le pipeline di tutta l'organizzazione lette in un giro: i run vivi, gli orchestrator di rilascio, i falliti delle ultime 24 ore, gli agenti dei
/// pool interni, e per i falliti che il supervisore guarda il motivo (dai log) e l'ultimo run della stessa definizione e dello stesso ramo.
/// </summary>
public sealed record PipelineView(bool Read, string? Error, IReadOnlyList<RunInfo> Active, IReadOnlyList<RunInfo> Orchestrators, IReadOnlyList<RunInfo> Failed,
    IReadOnlyList<string> Errors, IReadOnlyList<AgentPool> Pools, bool AgentsRead, IReadOnlyList<string> AgentErrors,
    IReadOnlyDictionary<int, string> Reasons, IReadOnlyDictionary<string, (int Id, string? Result)> Latest)
{
    public static PipelineView Unread(string error) => new(false, error, [], [], [], [], [], false, [], new Dictionary<int, string>(), new Dictionary<string, (int, string?)>());
}

/// <summary>Una pipeline che il supervisore puo rilanciare da solo (pipelineRilanciabili): una persona la aggiunge.</summary>
public sealed record RerunnablePipeline(string Project, int DefinitionId);

/// <summary>Un rilancio fatto dal supervisore: quando, e il run nuovo (null se non si sa se e partito).</summary>
public sealed record Rerun(DateTimeOffset When, int? New);

/// <summary>D51, le pipeline: le regole pure di Supervisione.psm1 (sezione 5) e di Ado.psm1 sul modo di leggere un run.</summary>
public static class PipelineRules
{
    /// <summary>Il tipo di un run (Get-TipoRun).</summary>
    public static string Kind(string name, string? reason, bool orchestrator)
    {
        if (orchestrator) return "rilascio";
        if (reason == "pullRequest") return "pr";
        if (Regex.IsMatch(name, "(?i)release|deploy|rilascio")) return "rilascio";
        if (Regex.IsMatch(name, @"(?i)pr-validation|\bpr\b")) return "pr";
        if (reason is "individualCI" or "batchedCI" || Regex.IsMatch(name, @"(?i)build-ci|\bci\b")) return "ci";
        if (reason == "schedule") return "pianificato";
        return reason == "manual" ? "manuale" : "altro";
    }

    /// <summary>refs/heads/develop diventa develop, refs/pull/12/merge diventa "PR #12".</summary>
    public static string Branch(string? sourceBranch) =>
        Regex.Replace(Regex.Replace(sourceBranch ?? "", "^refs/heads/", ""), @"^refs/pull/(\d+)/merge$", "PR #$1");

    public sealed record Phase(bool Approval, string? Stage, string? Waiting, IReadOnlyList<string> Workers);

    /// <summary>
    /// Dove e fermo un run in corso, dalla timeline (Get-FaseRun): l'approvazione o la validazione manuale che aspetta (con la fase che la
    /// chiede), un controllo dell'environment senza job che girano, un job che aspetta un agente sotto uno stage partito, o la fase che gira.
    /// </summary>
    public static Phase PhaseOf(JsonArray? records)
    {
        var recs = (records ?? []).OfType<JsonObject>().ToList();
        string? S(JsonNode? n, string k) => n?[k] is JsonValue v && v.TryGetValue<string>(out var s) ? s : n?[k]?.ToString();
        var byId = recs.Where(r => S(r, "id") is not null).GroupBy(r => S(r, "id")!).ToDictionary(g => g.Key, g => g.First());
        var workers = recs.Where(r => S(r, "type") == "Job").Select(r => S(r, "workerName")).Where(w => !string.IsNullOrEmpty(w)).Cast<string>().ToList();
        bool Running(JsonObject r, string type) => S(r, "type") == type && S(r, "state") == "inProgress";
        JsonObject? UpToStage(JsonObject? r, int max)
        {
            for (var i = 0; i < max && r is not null && S(r, "type") != "Stage"; i++) r = S(r, "parentId") is { } p && byId.TryGetValue(p, out var x) ? x : null;
            return r;
        }
        var approval = recs.FirstOrDefault(r => Running(r, "Checkpoint.Approval") || (Running(r, "Task") && S(r["task"], "name") == "ManualValidation"));
        if (approval is not null) return new(true, UpToStage(approval, 6) is { } st ? S(st, "name") : null, null, workers);
        var jobsRunning = recs.Any(r => Running(r, "Job"));
        if (!jobsRunning)
        {
            var check = recs.FirstOrDefault(r => (S(r, "type") ?? "").StartsWith("Checkpoint", StringComparison.Ordinal) && S(r, "state") == "inProgress");
            if (check is not null)
            {
                var st = UpToStage(check, 6) ?? recs.Where(r => S(r, "type") == "Stage" && S(r, "state") != "completed").OrderBy(r => r["order"] is JsonValue o && o.TryGetValue<int>(out var n) ? n : 0).FirstOrDefault();
                return new(false, st is null ? null : S(st, "name"), "controllo", workers);
            }
            var liveStages = recs.Where(r => Running(r, "Stage")).Select(r => S(r, "id")).ToHashSet();
            var pending = recs.FirstOrDefault(r => S(r, "type") == "Job" && S(r, "state") == "pending" && UpToStage(r, 4) is { } st && liveStages.Contains(S(st, "id")));
            if (pending is not null) return new(false, S(pending, "name"), "agente", workers);
        }
        // lo stage "__default" e quello implicito delle pipeline senza stage: non dice niente, si mostra il job
        var stage = recs.FirstOrDefault(r => Running(r, "Stage") && !(S(r, "name") ?? "").StartsWith("__", StringComparison.Ordinal));
        var job = stage is null ? recs.FirstOrDefault(r => Running(r, "Job")) : null;
        return new(false, S(stage ?? job, "name"), null, workers);
    }

    /// <summary>Un motivo che dice "guasto dell'infrastruttura" (testiInfrastruttura di supervisore.json), non un errore del codice.</summary>
    public static bool IsInfrastructure(string? reason, IReadOnlyList<string> texts) =>
        !string.IsNullOrWhiteSpace(reason) && texts.Any(t => Regex.IsMatch(reason, $"(?i){t}"));

    /// <summary>
    /// I run falliti che il supervisore guarda: dei progetti della mappa, esito failed, mai una validazione di PR (le gestisce D38), un rilascio o
    /// una pipeline di deploy (nessuno tocca il deploy), mai un ramo di una card (feature/, fix/).
    /// </summary>
    public static IReadOnlyList<RunInfo> ToExamine(IEnumerable<RunInfo> failed, IReadOnlyCollection<string> projects, IReadOnlyCollection<int> deployDefinitions) =>
        failed.Where(f => f.Result == "failed" && projects.Contains(f.Project) && f.Kind is not ("pr" or "rilascio") && !deployDefinitions.Contains(f.DefinitionId)
            && !Regex.IsMatch(f.Pipeline, "(?i)orchestrator|deploy|release|rilascio") && !Regex.IsMatch(f.Branch, "^(feature|fix)/")).ToList();

    public static string LatestKey(RunInfo r) => $"{r.Project}|{r.DefinitionId}|{r.Branch}";

    /// <summary>I falliti da guardare divisi come in Get-FallitiInfrastruttura.</summary>
    public sealed record FailedGroups(List<RunInfo> Rerunnable, List<RunInfo> ToConfigure, List<RunInfo> Repeated, List<RunInfo> WithoutCause, List<RunInfo> Superseded, List<RunInfo> AlreadyRerun);

    public static FailedGroups GroupFailed(PipelineView p, IReadOnlyCollection<string> projects, IReadOnlyCollection<int> deployDefinitions,
        IReadOnlyDictionary<string, Rerun> reruns, IReadOnlyList<RerunnablePipeline> rerunnable, IReadOnlyList<string> infraTexts)
    {
        var g = new FailedGroups([], [], [], [], [], []);
        var ours = reruns.Values.Where(r => r.New is not null).Select(r => r.New!.Value).ToHashSet();
        foreach (var f in ToExamine(p.Failed, projects, deployDefinitions))
        {
            var latest = p.Latest.TryGetValue(LatestKey(f), out var l) ? l : ((int Id, string? Result)?)null;
            if (latest is { } lt && lt.Id > f.Id && lt.Result == "succeeded") { g.Superseded.Add(f); continue; }
            if (!IsInfrastructure(p.Reasons.GetValueOrDefault(f.Id), infraTexts)) { g.WithoutCause.Add(f); continue; }
            if (reruns.ContainsKey(f.Id.ToString())) { g.AlreadyRerun.Add(f); continue; }
            if (ours.Contains(f.Id)) { g.Repeated.Add(f); continue; }
            var listed = rerunnable.Any(r => r.Project == f.Project && r.DefinitionId == f.DefinitionId);
            if (listed && f.Branch == "develop" && latest is { } last && last.Id == f.Id) g.Rerunnable.Add(f); else g.ToConfigure.Add(f);
        }
        return g;
    }

    /// <summary>I problemi delle pipeline (Get-ProblemiPipeline): letture fallite, approvazioni, agenti offline, code lunghe, falliti, rilanci non partiti.</summary>
    public static IEnumerable<Problem> Problems(PipelineView p, DateTimeOffset now, string orgUrl, int queueMinutes, FailedGroups f, IReadOnlyDictionary<string, Rerun> reruns)
    {
        const string access = "controlla l'accesso ad Azure DevOps e il log del servizio";
        if (!p.Read) { yield return new Problem("lettura-pipeline", $"Non riesco a leggere le pipeline di Azure DevOps: {Short(p.Error, 200)}", access); yield break; }
        if (p.Errors.Count > 0) yield return new Problem("lettura-pipeline-progetti", $"Non riesco a leggere le pipeline di alcuni progetti: {Short(string.Join(" ", p.Errors.Take(2)), 240)}", access);
        if (!p.AgentsRead) yield return new Problem("lettura-agenti", $"Non riesco a leggere gli agenti dei pool interni: {Short(string.Join(" ", p.AgentErrors.Take(2)), 240)}", "controlla che il PAT dello smistatore abbia il permesso sui pool di agenti");
        var all = p.Active.Concat(p.Orchestrators).ToList();
        foreach (var r in all.Where(r => r.Status == "inAttesa"))
            yield return new Problem($"approvazione-{r.Id}", $"Il run {r.Pipeline} sul ramo {r.Branch} aspetta la tua approvazione{(r.Stage is { } st ? $" (fase {st})" : "")}.", "apri il run e approvalo o rifiutalo", r.Url, Urgent: true);
        foreach (var pool in p.Pools)
            foreach (var a in pool.Agents.Where(a => a.Enabled && !a.Online))
                yield return new Problem($"agente-offline-{pool.Pool}-{a.Name}", $"L'agente {a.Name} del pool {pool.Pool} e offline.", $"riavvia il servizio dell'agente {a.Name} sul suo server (pool {pool.Pool})", $"{orgUrl}/_settings/agentpools", Urgent: true);
        foreach (var r in all.Where(r => r.Status == "inCoda" && r.Start is { } s && (now - s).TotalMinutes > queueMinutes))
            yield return new Problem($"coda-{r.Id}", $"Il run {r.Pipeline} ({r.Branch}) e in coda {Supervisor.Waiting(now - r.Start!.Value)}.", "controlla gli agenti del pool: se sono occupati o offline sbloccali", r.Url);
        foreach (var r in f.Repeated)
            yield return new Problem($"run-fallito-{r.Id}", $"Il run {r.Pipeline} ({r.Branch}) e fallito di nuovo per infrastruttura dopo il rilancio automatico.", "controlla l'agente e rilancia a mano il run", r.Url);
        foreach (var r in f.ToConfigure)
            yield return new Problem($"run-fallito-{r.Id}", $"Il run {r.Pipeline} ({r.Branch}) e fallito per un guasto dell'infrastruttura.",
                r.Branch == "develop" ? $"si potrebbe rilanciare: aggiungi la pipeline (progetto {r.Project}, definizioneId {r.DefinitionId}) a pipelineRilanciabili in config/supervisore.json, oppure rilancialo a mano" : "rilancialo a mano (il supervisore rilancia solo develop)", r.Url);
        foreach (var r in f.WithoutCause)
            yield return new Problem($"run-fallito-{r.Id}", $"Il run {r.Pipeline} ({r.Branch}) e fallito e il motivo non e un guasto noto dell'infrastruttura.", "apri il run, leggi l'errore e decidi se rilanciarlo o correggere il codice", r.Url, Diagnose: true);
        // un rilancio che non e partito (o di cui non si sa): una volta per run, per un giorno
        foreach (var (id, e) in reruns.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            if (e.New is null && (now - e.When).TotalHours <= 24)
                yield return new Problem($"rilancio-fallito-{id}", $"Il rilancio automatico del run {id} non e riuscito (o non si sa se sia partito).", $"guarda il run {id} e il log del supervisore, e rilancialo a mano se serve", orgUrl);
    }

    private static string Short(string? s, int max)
    {
        var one = Regex.Replace(s ?? "", @"\s+", " ").Trim();
        return one.Length <= max ? one : one[..(max - 1)] + "…";
    }
}

/// <summary>
/// D51: la diagnosi con un modello, per un problema che nessuna regola sa spiegare (Diagnose). Una sessione per volta, al piu diagnosiAlGiorno al
/// giorno, mai con la quota che blocca o con le sessioni al limite, una volta per problema (anche "non riuscita": resta finche il problema e aperto).
/// </summary>
public static class DiagnosisRules
{
    public const string Failed = "diagnosi non riuscita";
    public const int MaxChars = 600;

    public static string? Next(SupervisorState s, DateTimeOffset now, TimeZoneInfo zone, int perDay, bool quotaBlocked, int activeSessions, int sessionLimit)
    {
        if (quotaBlocked || (sessionLimit > 0 && activeSessions >= sessionLimit) || s.Diagnosis is not null) return null;
        var today = TimeZoneInfo.ConvertTime(now, zone).ToString("yyyy-MM-dd");
        if (s.DiagnosisDay == today && s.DiagnosesToday >= perDay) return null;
        return s.Problems.OrderBy(kv => kv.Key, StringComparer.Ordinal).Where(kv => kv.Value.Problem.Diagnose && string.IsNullOrWhiteSpace(kv.Value.Diagnosis)).Select(kv => kv.Key).FirstOrDefault();
    }

    /// <summary>Una diagnosi in lancio conta nel tetto del giorno prima ancora di sapere se la sessione e partita: meglio una in meno che una in piu.</summary>
    public static void Count(SupervisorState s, DateTimeOffset now, TimeZoneInfo zone)
    {
        var today = TimeZoneInfo.ConvertTime(now, zone).ToString("yyyy-MM-dd");
        s.DiagnosesToday = s.DiagnosisDay == today ? s.DiagnosesToday + 1 : 1;
        s.DiagnosisDay = today;
    }

    /// <summary>Il testo della diagnosi: senza la riga ESITO, su una riga, al piu MaxChars caratteri; vuoto se non c'e niente.</summary>
    public static string Text(string? text)
    {
        var t = Regex.Replace(Regex.Replace(text ?? "", @"(?m)^[\s`*]*ESITO=\S+[\s`*]*$", ""), @"\s+", " ").Trim();
        return t.Length <= MaxChars ? t : t[..(MaxChars - 1)] + "…";
    }

    /// <summary>Il messaggio della sessione di diagnosi: il problema, il gesto, le righe, e come chiudere.</summary>
    public static string Message(Problem p) => string.Join("\n", new[]
    {
        "Diagnosi di un problema che il supervisore non sa spiegare con le sue regole. Sei in sola lettura: leggi, non cambiare niente.",
        $"Problema: {p.Text}", $"Gesto previsto per una persona: {p.Action}",
    }.Concat(p.Link is { } l ? [$"Link: {l}"] : []).Concat((p.Lines ?? []).Select(x => $"- {x}"))
     .Concat(["Scrivi in poche righe la causa probabile e cosa fare, poi chiudi con ESITO=diagnosi (o ESITO=bloccato se non puoi capirlo)."]));
}
