using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Orchestration;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Supervision;

/// <summary>config/supervisore.json (le chiavi che usa questa versione).</summary>
public sealed record SupervisorSettings
{
    public int IntervalMinutes { get; init; } = 5;
    public int MinutesWithoutRound { get; init; } = 10;
    public int CardErrorsInARow { get; init; } = 5;
    public int HoursWithoutMovement { get; init; } = 6;
    public int UrgentReminderHours { get; init; } = 4;
    public IReadOnlyList<TimeSpan> SummaryTimes { get; init; } = [new(8, 30, 0), new(14, 0, 0)];
    public int PatNoticeDays { get; init; } = 7;
    public int ReleaseCards { get; init; } = 5;
    public int ReleaseDays { get; init; } = 7;
    public IReadOnlyDictionary<string, (int Cards, int Days)> ReleaseByArea { get; init; } = new Dictionary<string, (int, int)>();
    /// <summary>D53: ogni quanti minuti l'aggiornamento della suite fa fetch, e dopo quante ore di attesa delle sessioni lo dice.</summary>
    public int UpdateCheckMinutes { get; init; } = 30;
    public double UpdateWaitHours { get; init; } = 6;
    /// <summary>Le pipeline: oltre quanti minuti in coda un run e un problema, quali il supervisore puo rilanciare, i testi di un guasto dell'infrastruttura.</summary>
    public int QueueMinutes { get; init; } = 60;
    public IReadOnlyList<RerunnablePipeline> Rerunnable { get; init; } = [];
    public IReadOnlyList<string> InfrastructureTexts { get; init; } = [];
    /// <summary>Quante diagnosi con un modello al giorno, al piu.</summary>
    public int DiagnosesPerDay { get; init; } = 3;
}

/// <summary>
/// Un problema: Key lo identifica fra un giro e l'altro (e il modo di non avvisare due volte), Action e il gesto esatto che tocca a una
/// persona. Elements: gli elementi di una voce aggregata (i rilasci): uno nuovo la fa riapparire. Topic: dove va su Telegram.
/// </summary>
public sealed record Problem(string Key, string Text, string Action, string? Link = null, bool Urgent = false,
    IReadOnlyList<string>? Lines = null, IReadOnlyList<string>? Elements = null, bool Remind = true, string Topic = "riepilogo", bool Diagnose = false);

/// <summary>Quello che il supervisore ha visto: lo smistatore (ultimo giro, errori), le card dell'ultimo giro, quota e token.</summary>
public sealed record Observation(
    DateTimeOffset Now,
    TimeZoneInfo Zone,
    bool DispatcherAutoRun,
    DateTimeOffset? LastRound,
    IReadOnlyList<(DateTimeOffset When, string Error)> RoundErrors,
    RoundReport? Round,
    IReadOnlyDictionary<int, double> HoursWithoutMovement,
    BlockReason? QuotaBlock,
    DateTimeOffset? PatExpiry,
    string? CardUrlBase = null,
    PipelineView? Pipelines = null,
    string? OrganizationUrl = null,
    IReadOnlyCollection<string>? MapProjects = null,
    IReadOnlyCollection<int>? DeployDefinitions = null);

/// <summary>Un problema aperto, come in supervisore.json: quando e comparso, l'ultimo avviso, gli elementi gia avvisati.</summary>
public sealed class OpenProblem
{
    public required Problem Problem { get; set; }
    public DateTimeOffset FirstSeen { get; set; }
    public DateTimeOffset LastSeen { get; set; }
    public DateTimeOffset? LastNotice { get; set; }
    public int Absences { get; set; }
    public List<string> Notified { get; set; } = [];
    /// <summary>D51: la diagnosi del modello (o "diagnosi non riuscita"), che resta finche il problema e aperto.</summary>
    public string? Diagnosis { get; set; }
}

/// <summary>La sessione di diagnosi in corso: l'id, il problema, quando e partita, l'impronta della copia degli attrezzi al lancio.</summary>
public sealed record DiagnosisRun(string SessionId, string Key, DateTimeOffset Started, string? Fingerprint);

public sealed class SupervisorState
{
    public Dictionary<string, OpenProblem> Problems { get; set; } = new();
    /// <summary>Le fasce di riepilogo gia mandate ("2026-11-26 08:30").</summary>
    public List<string> Summaries { get; set; } = [];
    /// <summary>Quante volte di fila la stessa card ha dato errore nel giro, e da quando una card e in Ready to release.</summary>
    public Dictionary<int, int> CardErrorStreak { get; set; } = new();
    public Dictionary<int, DateTimeOffset> ReleaseSince { get; set; } = new();
    /// <summary>La firma di ogni card (stato, motivo, sessione) e da quando e uguale: una card ferma da ore senza motivo e un problema.</summary>
    public Dictionary<int, CardSignature> Signatures { get; set; } = new();
    public DateTimeOffset? LastRun { get; set; }
    /// <summary>I rilanci fatti dal supervisore (id del run fallito -> quando e il run nuovo), una volta per run.</summary>
    public Dictionary<string, Rerun> Reruns { get; set; } = new();
    public DiagnosisRun? Diagnosis { get; set; }
    public string? DiagnosisDay { get; set; }
    public int DiagnosesToday { get; set; }
}

public sealed record CardSignature(string Value, DateTimeOffset Since);

/// <summary>Una voce da mandare: il problema, se e un ricordo e da quanto aspetta.</summary>
public sealed record Notice(string Key, Problem Problem, bool Reminder, string Waiting);

public sealed record NoticePlan(IReadOnlyList<Notice> Urgent, IReadOnlyList<Notice> Summary, IReadOnlyList<Notice> Releases, IReadOnlyList<string> Slots, bool SendSummary);

/// <summary>
/// D51: il supervisore, senza modello. Controlla al posto di una persona e la chiama solo per cio che serve a lei. I controlli sono puri
/// (Supervisione.psm1): ricevono l'osservazione e restituiscono problemi; il piano degli avvisi dice cosa mandare e quando.
/// </summary>
public static class Supervisor
{
    /// <summary>Le ore da cui ogni card ha la stessa firma, senza azioni: quanto e ferma.</summary>
    public static IReadOnlyDictionary<int, double> HoursStill(SupervisorState state, DateTimeOffset now) =>
        state.Signatures.ToDictionary(kv => kv.Key, kv => (now - kv.Value.Since).TotalHours);

    public static IReadOnlyList<Problem> Check(Observation o, SupervisorSettings cfg, SupervisorState state, StateNames names)
    {
        var problems = new List<Problem>();
        problems.AddRange(Dispatcher(o, cfg));
        problems.AddRange(Cards(o, cfg, state, names));
        if (o.QuotaBlock is { Type: "quota" } q && q.Detail is { } d)
        {
            // la finestra di 5 ore non si segnala: e un freno voluto, che passa da solo a ogni reset (D60)
            if (d.StartsWith("limite di token")) problems.Add(new Problem("quota-pausa", $"Gli agenti sono fermi per il {d}.", "niente da fare: riprendono da soli dopo il reset"));
            else if (d.StartsWith("riserva settimanale")) problems.Add(new Problem("quota-riserva", $"Gli agenti non partono: {d}.", "alza la soglia o ignora la riserva dalla dashboard"));
        }
        problems.AddRange(Pat(o, cfg));
        if (o.Pipelines is { } p)
        {
            var groups = PipelineRules.GroupFailed(p, o.MapProjects ?? [], o.DeployDefinitions ?? [], state.Reruns, cfg.Rerunnable, cfg.InfrastructureTexts);
            problems.AddRange(PipelineRules.Problems(p, o.Now, o.OrganizationUrl ?? "", cfg.QueueMinutes, groups, state.Reruns));
        }
        return problems;
    }

    private static IEnumerable<Problem> Dispatcher(Observation o, SupervisorSettings cfg)
    {
        if (o.DispatcherAutoRun && (o.LastRound is null || (o.Now - o.LastRound.Value).TotalMinutes > cfg.MinutesWithoutRound))
        {
            var when = o.LastRound is { } l ? $"ultimo giro alle {TimeZoneInfo.ConvertTime(l, o.Zone):HH:mm}" : "nessun giro registrato";
            yield return new Problem("smistatore-fermo", $"Lo smistatore non gira da piu di {cfg.MinutesWithoutRound} minuti ({when}).",
                "controlla il servizio DevOps.Agents e il suo log; riavvialo se serve", Urgent: true);
        }
        var recent = o.RoundErrors.Where(e => (o.Now - e.When).TotalMinutes <= cfg.MinutesWithoutRound && !IsPatRejected(e.Error)).ToList();
        if (recent.Count >= 2)
            yield return new Problem("smistatore-giro-interrotto",
                $"Il giro dello smistatore si interrompe a ogni giro ({recent.Count} volte negli ultimi {cfg.MinutesWithoutRound} minuti): {Short(recent[^1].Error, 220)}",
                "leggi il log del servizio e correggi la causa", Urgent: true);
    }

    public static bool IsPatRejected(string? error) => error is not null && (error.Contains("PAT di Azure DevOps e scaduto o revocato") || error.Contains(" 401 "));

    private static IEnumerable<Problem> Pat(Observation o, SupervisorSettings cfg)
    {
        const string command = "pwsh -NoProfile -File setup/Install-Attrezzi.ps1 -Pat";
        if (o.RoundErrors.Any(e => (o.Now - e.When).TotalMinutes <= cfg.MinutesWithoutRound && IsPatRejected(e.Error)))
            yield return new Problem("pat-rifiutato", "Azure DevOps rifiuta il PAT dello smistatore (scaduto o revocato): le card non avanzano.", command, Urgent: true);
        if (o.PatExpiry is { } exp && exp <= o.Now.AddDays(cfg.PatNoticeDays))
        {
            var date = TimeZoneInfo.ConvertTime(exp, o.Zone).ToString("dd/MM/yyyy");
            yield return new Problem("pat-scadenza", exp <= o.Now ? $"Il PAT dello smistatore e scaduto il {date}." : $"Il PAT dello smistatore scade il {date}.", command);
        }
    }

    private static IEnumerable<Problem> Cards(Observation o, SupervisorSettings cfg, SupervisorState state, StateNames names)
    {
        if (o.Round is not { } round) yield break;
        // le card che aspettano una card in on-hold (D57: il gesto della predecessora sblocca anche loro)
        var waitingOn = new Dictionary<int, List<int>>();
        foreach (var c in round.Cards)
            if (c.Reason is { Type: "predecessori", Cards: { } preds })
                foreach (var p in preds) (waitingOn.TryGetValue(p, out var l) ? l : waitingOn[p] = []).Add(c.Id);

        var releases = new List<CardReport>();
        var closingInDraft = new HashSet<int>();
        foreach (var c in round.Cards)
        {
            var title = Short(c.Title, 70);
            if (c.Error is { } err)
            {
                var streak = state.CardErrorStreak.GetValueOrDefault(c.Id);
                if (streak >= cfg.CardErrorsInARow)
                    yield return new Problem($"card-{c.Id}-errori", $"La card #{c.Id} ({title}) e saltata per errore {streak} giri di fila: {Short(err, 200)}",
                        "leggi l'errore e il log del servizio, poi correggi la causa", c.Url, Urgent: true);
                continue;
            }
            if (c.Reason is { Type: "chiusuraInBozza", Cards: [var closing, ..] } cb && closingInDraft.Add(closing))
            {
                yield return new Problem($"chiusura-{closing}-bozza", $"La card di chiusura #{closing} e in Draft e le sorelle della funzionalita sono tutte unite nel ramo: aspetta te.",
                    cb.Detail ?? $"sposta la card #{closing} in New", $"{o.CardUrlBase}{closing}");
                continue;
            }
            if (c.Reason?.Type == "onHold")
            {
                var lines = (c.WhatToDo ?? []).Skip(1).ToList();
                if (waitingOn.TryGetValue(c.Id, out var deps)) lines.Add($"Tiene ferme anche: {string.Join(", ", deps.Select(d => $"#{d}"))}");
                var action = c.WhatToDo is [var first, ..] ? first.TrimStart('1', '.', ' ') : $"risolvi la causa e togli il tag {names.OnHoldTag} dalla card";
                yield return new Problem($"card-{c.Id}-sblocca", $"Card #{c.Id} ({title}): in on-hold", action, c.Url, Lines: lines);
                continue;
            }
            if (c.Actions.Count > 0 || c.RunningRole is not null) continue;
            switch (c.StateKey)
            {
                case K.ReadyToRelease when c.Reason is null:
                    releases.Add(c);
                    continue;
                case K.HumanTest when c.Reason is null:
                    yield return new Problem($"card-{c.Id}-prova", $"Card #{c.Id} ({title}): aspetta la tua prova in Test", "prova la card in Test e scrivi l'esito in un commento sulla card", c.Url);
                    continue;
                case K.NeedsClarification when c.Reason is null:
                    yield return new Problem($"card-{c.Id}-rispondi", $"Card #{c.Id} ({title}): il responsabile ha delle domande", "rispondi alla domanda del responsabile con un commento sulla card", c.Url);
                    continue;
            }
            var hours = o.HoursWithoutMovement.GetValueOrDefault(c.Id);
            if (c.Reason is null && hours >= cfg.HoursWithoutMovement && c.StateKey is not (K.Draft or K.Releasing or K.Closed or K.Removed or K.InFeatureBranch))
                yield return new Problem($"ferma-{c.Id}", $"La card #{c.Id} ({title}) e ferma da {(int)hours} ore in {c.State} e nessuna regola dice perche.", "apri la card e guarda perche non si muove", c.Url);
        }
        if (releases.Count > 0 && Releases(releases, cfg, state, o) is { } r) yield return r;
    }

    /// <summary>I rilasci in attesa, una voce sola con una riga per area; un'area oltre la soglia (card o giorni) va in cima. Non e un urgente.</summary>
    private static Problem? Releases(List<CardReport> cards, SupervisorSettings cfg, SupervisorState state, Observation o)
    {
        var lines = new List<(bool Over, int Count, string Line)>();
        foreach (var g in cards.GroupBy(c => c.Area ?? "(senza area)").OrderBy(g => g.Key))
        {
            var (maxCards, maxDays) = cfg.ReleaseByArea.TryGetValue(g.Key, out var t) ? t : (cfg.ReleaseCards, cfg.ReleaseDays);
            var oldest = g.Select(c => state.ReleaseSince.GetValueOrDefault(c.Id, o.Now)).Min();
            var days = (int)Math.Floor((o.Now - oldest).TotalDays);
            var why = new List<string>();
            if (g.Count() >= maxCards) why.Add($"{g.Count()} card (soglia {maxCards})");
            if (days >= maxDays) why.Add($"{days} giorni (soglia {maxDays})");
            var text = $"{g.Key}: {g.Count()} card ({string.Join(", ", g.Select(c => $"#{c.Id}"))}), la piu vecchia aspetta da {days} giorni";
            lines.Add((why.Count > 0, g.Count(), why.Count > 0 ? $"OLTRE SOGLIA - {text} - {string.Join(", ", why)}" : text));
        }
        var ordered = lines.OrderByDescending(l => l.Over).ThenByDescending(l => l.Count).Select(l => l.Line).ToList();
        // la voce torna ogni giorno solo se un'area e oltre soglia; altrimenti solo quando entra una card nuova
        return new Problem("rilasci", "Rilasci in attesa", "rilascia in produzione le card pronte", Lines: ordered,
            Elements: cards.Select(c => c.Id.ToString()).ToList(), Remind: lines.Any(l => l.Over), Topic: "rilasci");
    }

    /// <summary>
    /// I problemi aperti dopo questo controllo: uno nuovo entra con il primo visto; uno che non si vede piu si chiude senza messaggi dopo due
    /// assenze di fila (una lettura che salta non lo riapre come nuovo). Aggiorna anche le serie di errori per card e l'ingresso nel rilascio.
    /// </summary>
    public static void Update(SupervisorState state, IReadOnlyList<Problem> problems, Observation o, int maxAbsences = 2)
    {
        var next = new Dictionary<string, OpenProblem>();
        foreach (var p in problems)
        {
            var before = state.Problems.GetValueOrDefault(p.Key);
            next[p.Key] = new OpenProblem { Problem = p, FirstSeen = before?.FirstSeen ?? o.Now, LastSeen = o.Now, LastNotice = before?.LastNotice, Notified = before?.Notified ?? [], Diagnosis = before?.Diagnosis };
        }
        foreach (var (k, e) in state.Problems)
        {
            if (next.ContainsKey(k)) continue;
            if (++e.Absences < maxAbsences) next[k] = e;
        }
        state.Problems = next;
        if (o.Round is { } round)
        {
            state.CardErrorStreak = round.Cards.Where(c => c.Error is not null).ToDictionary(c => c.Id, c => state.CardErrorStreak.GetValueOrDefault(c.Id) + 1);
            var releasing = round.Cards.Where(c => c.StateKey == K.ReadyToRelease).Select(c => c.Id).ToHashSet();
            state.ReleaseSince = releasing.ToDictionary(id => id, id => state.ReleaseSince.TryGetValue(id, out var since) ? since : o.Now);
            state.Signatures = round.Cards.ToDictionary(c => c.Id, c =>
            {
                var sig = $"{c.State}|{c.Reason?.Type}|{c.RunningRole}|{c.Actions.Count}";
                return state.Signatures.TryGetValue(c.Id, out var old) && old.Value == sig && c.Actions.Count == 0 ? old : new CardSignature(sig, o.Now);
            });
        }
    }

    /// <summary>
    /// Cosa mandare adesso. Gli urgenti subito, e di nuovo dopo oreRicordoUrgente se ancora aperti. Il resto nel riepilogo agli orari dei
    /// giorni feriali (o al primo giro dopo una lunga assenza), solo se c'e una voce nuova o da ricordare, una volta al giorno. I rilasci a parte.
    /// </summary>
    public static NoticePlan Plan(SupervisorState state, Observation o, SupervisorSettings cfg)
    {
        var local = TimeZoneInfo.ConvertTime(o.Now, o.Zone);
        var urgent = new List<Notice>();
        var summary = new List<Notice>();
        foreach (var (k, e) in state.Problems.OrderBy(kv => kv.Key))
        {
            if (e.Absences > 0) continue;
            var waiting = Waiting(o.Now - e.FirstSeen);
            if (e.Problem.Urgent)
            {
                if (e.LastNotice is null || (o.Now - e.LastNotice.Value).TotalHours >= cfg.UrgentReminderHours) urgent.Add(new Notice(k, e.Problem, e.LastNotice is not null, waiting));
                continue;
            }
            var withDiagnosis = e.Diagnosis is { Length: > 0 } dg ? e.Problem with { Lines = (e.Problem.Lines ?? []).Append($"Diagnosi: {dg}").ToList() } : e.Problem;
            var elements = e.Problem.Elements ?? [];
            var fresh = elements.Any(x => !e.Notified.Contains(x));
            if (e.LastNotice is null || (elements.Count > 0 && fresh)) summary.Add(new Notice(k, withDiagnosis, false, ""));
            else if (elements.Count > 0 && !e.Problem.Remind) continue;
            else if (TimeZoneInfo.ConvertTime(e.LastNotice.Value, o.Zone).Date < local.Date) summary.Add(new Notice(k, withDiagnosis, true, waiting));
        }
        var slots = new List<string>();
        if (local.DayOfWeek is not (DayOfWeek.Saturday or DayOfWeek.Sunday))
            foreach (var t in cfg.SummaryTimes)
            {
                var key = $"{local:yyyy-MM-dd} {t:hh\\:mm}";
                if (local.TimeOfDay >= t && !state.Summaries.Contains(key)) slots.Add(key);
            }
        var back = state.LastRun is { } last && (o.Now - last).TotalMinutes > 3 * cfg.IntervalMinutes;
        var due = slots.Count > 0 || back || state.LastRun is null;
        var releases = summary.Where(n => n.Problem.Topic == "rilasci").ToList();
        var rest = summary.Where(n => n.Problem.Topic != "rilasci").ToList();
        return new NoticePlan(urgent, due ? rest : [], due ? releases : [], slots, due && (rest.Count > 0 || releases.Count > 0));
    }

    /// <summary>Segna come avvisato quello che e partito (e le fasce di riepilogo usate).</summary>
    public static void Register(SupervisorState state, NoticePlan plan, IEnumerable<Notice> sent, DateTimeOffset now)
    {
        foreach (var n in sent)
            if (state.Problems.TryGetValue(n.Key, out var e))
            {
                e.LastNotice = now;
                e.Notified = (e.Problem.Elements ?? []).ToList();
            }
        state.Summaries.AddRange(plan.Slots);
        if (state.Summaries.Count > 50) state.Summaries.RemoveRange(0, state.Summaries.Count - 50);
        state.LastRun = now;
    }

    public static string Waiting(TimeSpan t) => t.TotalDays >= 1 ? $"{(int)t.TotalDays} g" : t.TotalHours >= 1 ? $"{(int)t.TotalHours} h" : $"{Math.Max(1, (int)t.TotalMinutes)} min";

    private static string Short(string? s, int max)
    {
        var one = (s ?? "").Replace('\n', ' ').Replace('\r', ' ').Trim();
        return one.Length <= max ? one : one[..(max - 1)] + "…";
    }
}
