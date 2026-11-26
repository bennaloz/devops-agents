using System.Text.RegularExpressions;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;
using Microsoft.Extensions.Logging;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Orchestration;

public sealed record DispatcherOptions
{
    /// <summary>Solo le card assegnate all'utente del token (come lo smistatore PowerShell). Spento, tutte quelle con il tag.</summary>
    public bool OnlyMine { get; init; } = true;
}

/// <summary>Cosa e successo a una card in un giro: le azioni decise (ed eseguite, se non e un giro di prova), il motivo, l'errore.</summary>
public sealed record CardReport(int Id, string Title, string State, string? StateKey, string? Area, string? AssignedTo, string? Url,
    IReadOnlyList<string> Actions, BlockReason? Reason, string? RunningRole, string? Error, int? FeatureId = null,
    /// <summary>D57: per una card in on-hold, i passi in ordine per sbloccarla.</summary>
    IReadOnlyList<string>? WhatToDo = null);

/// <summary>Una Feature come la vede la dashboard: in ordine di priorita, con la pausa.</summary>
public sealed record FeatureReport(int Id, string Title, string State, double? Rank, bool Paused, string? Area);

public sealed record RoundReport(DateTimeOffset Started, DateTimeOffset Finished, bool WhatIf, IReadOnlyList<CardReport> Cards, IReadOnlyList<string> Log,
    bool SystemPaused = false, IReadOnlyList<FeatureReport>? Features = null, QuotaInfo? Quota = null);

/// <summary>
/// Lo smistatore: un giro legge le card, chiude le sessioni finite, decide con <see cref="DecisionEngine"/> ed esegue.
/// E la conversione di src/Smistatore.ps1 per il flusso principale. Con whatIf non scrive niente da nessuna parte.
/// </summary>
public sealed class Dispatcher(
    IBoard board,
    ICodeHostResolver code,
    ICiService ci,
    IWorkspace workspace,
    ISessionRunner sessions,
    IStateStore store,
    DecisionEngine engine,
    StateNames names,
    Limits limits,
    IReadOnlyList<AreaMapping> areas,
    IClock clock,
    ILogger<Dispatcher> logger,
    DispatcherOptions? options = null,
    ISettingsStore? settingsStore = null,
    IQuotaStore? quotaStore = null,
    ITestEnvironments? testEnvironments = null)
{
    private readonly DispatcherOptions _options = options ?? new DispatcherOptions();
    private const string DeployMark = "Parametri del deploy in Test:";
    /// <summary>Il tetto della descrizione di una PR su Azure DevOps (4000) meno la firma che aggiunge il provider.</summary>
    public const int PrDescriptionLimit = 4000 - 70;
    private static readonly Regex DeployLine = new(@"^\s*\[responsabile\]\s*" + Regex.Escape(DeployMark) + "(.*)$", RegexOptions.Compiled);

    public async Task<RoundReport> RunRoundAsync(bool whatIf, int? onlyCard = null, CancellationToken ct = default)
    {
        var started = clock.Now;
        var log = new List<string>();
        void Log(string m) { log.Add(m); logger.LogInformation("{Message}", m); }

        var state = await store.LoadAsync(ct);
        if (!whatIf) await CloseFinishedSessionsAsync(state, Log, ct);

        // D60: le Feature aperte, per la pausa e per l'ordine. Se non si leggono il giro si ferma: senza, una Feature in pausa ripartirebbe.
        var features = await board.GetOpenFeaturesAsync(areas.Select(a => a.Area).ToList(), ct);
        var featureMap = features.ToDictionary(f => f.Id);
        var settings = settingsStore is null ? new SystemSettings() : await settingsStore.LoadAsync(ct);
        var quota = quotaStore is null ? null : await quotaStore.LoadAsync(ct);
        var overrides = quotaStore is null ? null : await quotaStore.LoadOverridesAsync(ct);
        var featureReports = FeaturePriority.Order(features).Select(f => new FeatureReport(f.Id, f.Title, f.State, f.Rank, f.HasTag(names.PausedTag), f.Area)).ToList();

        var me = _options.OnlyMine ? await board.GetCurrentUserAsync(ct) : null;
        // D60: un posto libero (sessioni, repo, Test) va alla card della Feature piu in alto
        var cards = FeaturePriority.OrderCards((await board.GetActiveCardsAsync(ct))
            .Where(c => onlyCard is null || c.Id == onlyCard)
            .Where(c => me is null || c.AssignedTo?.Id == me.Id), features).ToList();

        var baseCtx = new DecisionContext(names, limits, clock.Now, Quota: quota, QuotaOverrides: overrides, Features: featureMap);
        var inDev = new Dictionary<string, List<int>>(StringComparer.OrdinalIgnoreCase);
        var inTest = new Dictionary<string, List<int>>(StringComparer.OrdinalIgnoreCase);
        var withEnv = new List<int>();
        foreach (var c in cards)
        {
            var key = names.KeyOf(c.State);
            if (FindArea(c) is not { } area) continue;
            // D60: una card in pausa non tiene il posto in sviluppo del suo repo; in Test si, l'ambiente resta occupato
            if (key == K.InDevelopment && !DecisionEngine.IsPaused(c, baseCtx)) Add(inDev, area.Repo, c.Id);
            if (key is not null && K.InTest.Contains(key))
            {
                Add(inTest, area.Component, c.Id);
                if (area.TestEnvironment is not null) withEnv.Add(c.Id);
            }
        }

        var reports = new List<CardReport>();
        if (settings.Paused)
        {
            // D60: il sistema in pausa chiude le sessioni finite (sopra) ma non lancia niente e non sposta card
            Log("sistema in pausa: nessuna card avanza");
            foreach (var card in cards)
                reports.Add(Report(card, [], new BlockReason("pausaSistema"), state.TryGetValue(card.Id, out var ls) && ls.RunningSession is not null ? ls.LastRole : null, null));
            if (!whatIf) await store.SaveAsync(state, ct);
            return new RoundReport(started, clock.Now, whatIf, reports, log, true, featureReports, quota);
        }
        foreach (var card in cards)
        {
            var local = state.TryGetValue(card.Id, out var l) ? l : state[card.Id] = new CardLocalState();
            var area = FindArea(card);
            var running = local.RunningSession is not null ? local.LastRole : null;
            try
            {
                if (area is null)
                {
                    reports.Add(Report(card, [], new BlockReason("areaNonMappata", Detail: card.Area), running, null));
                    continue;
                }
                var snapshot = await BuildSnapshotAsync(card, local, area, ct);
                var active = state.Values.Count(s => s.RunningSession is not null);
                var ctx = baseCtx with
                {
                    ActiveSessions = active,
                    CardsWithSession = state.Where(kv => kv.Value.RunningSession is not null).Select(kv => kv.Key).ToList(),
                    InDevelopmentByRepo = inDev.ToDictionary(kv => kv.Key, kv => (IReadOnlyList<int>)kv.Value, StringComparer.OrdinalIgnoreCase),
                    InTestByComponent = inTest.ToDictionary(kv => kv.Key, kv => (IReadOnlyList<int>)kv.Value, StringComparer.OrdinalIgnoreCase),
                    CardsWithTestEnvironment = withEnv.ToList(),
                };
                var decision = engine.Decide(snapshot, ctx);
                var described = decision.Actions.Select(Describe).ToList();
                if (!whatIf)
                {
                    foreach (var action in decision.Actions)
                    {
                        await ExecuteAsync(action, snapshot, area, local, state, ct);
                        // i posti si aggiornano nel giro: la card dopo vede quello appena occupato
                        if (action is MoveCard { State: K.InDevelopment } or MoveBack { State: K.InDevelopment }) Add(inDev, area.Repo, card.Id);
                        if (action is MoveCard m && K.InTest.Contains(m.State))
                        {
                            Add(inTest, area.Component, card.Id);
                            if (area.TestEnvironment is not null && !withEnv.Contains(card.Id)) withEnv.Add(card.Id);
                        }
                    }
                    if (local.RunningSession is not null) running = local.LastRole;
                }
                foreach (var d in described) Log($"card {card.Id}: {(whatIf ? "farei " : "")}{d}");
                if (decision.Reason is { } r) Log($"card {card.Id}: ferma ({r.Type}{(r.Detail is null ? "" : $": {r.Detail}")})");
                var todo = decision.Reason?.Type == "onHold" || decision.Actions.Any(a => a is PutOnHold)
                    ? local.OnHoldIndications is { } ind ? WhatToDo.Lines(ind, local.WaitingFor) : null : null;
                reports.Add(Report(card, described, decision.Reason, running, null) with { WhatToDo = todo });
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                Log($"card {card.Id}: errore: {e.Message}");
                reports.Add(Report(card, [], null, running, e.Message));
            }
        }

        if (!whatIf) await RemoveOrphanEnvironmentsAsync(state, cards, Log, ct);
        if (!whatIf) await store.SaveAsync(state, ct);
        return new RoundReport(started, clock.Now, whatIf, reports, log, false, featureReports, quota);
    }

    private CardReport Report(Card c, IReadOnlyList<string> actions, BlockReason? reason, string? running, string? error) =>
        new(c.Id, c.Title, c.State, names.KeyOf(c.State), c.Area, c.AssignedTo?.Name, board.CardUrl(c.Id), actions, reason, running, error, c.ParentId);

    private AreaMapping? FindArea(Card c) => areas.FirstOrDefault(a => string.Equals(a.Area, c.Area, StringComparison.OrdinalIgnoreCase));

    private static void Add(Dictionary<string, List<int>> t, string key, int id)
    {
        if (!t.TryGetValue(key, out var l)) t[key] = l = [];
        if (!l.Contains(id)) l.Add(id);
    }

    // ---- sessioni finite ---------------------------------------------------------------------------------------------

    private async Task CloseFinishedSessionsAsync(Dictionary<int, CardLocalState> state, Action<string> log, CancellationToken ct)
    {
        foreach (var (id, local) in state)
        {
            if (local.RunningSession is not { } sid || local.LastRole is not { } role) continue;
            var result = await sessions.PollAsync(sid, ct);
            var s = local.Of(role);
            // ancora in corso. Il silenzio (nessun evento da silenzioMinuti) lo giudica il runner: chiude il processo e restituisce
            // un risultato senza esito, che la regola "senza ESITO" mette in attesa.
            if (result is null) continue;
            if (s is not null) { s.End = clock.Now; s.Outcome = result.Outcome; s.Text = result.Text; }
            local.RunningSession = null;
            if (quotaStore is not null && (result.Quota is not null || result.HitTokenLimit))
            {
                // D51: la quota e una sola per tutti i ruoli; vale l'ultima letta. Sul limite di token, pausa fino al reset (piu un margine).
                var current = await quotaStore.LoadAsync(ct) ?? new QuotaInfo(null, null, null);
                var q = result.Quota is { } r ? current with
                {
                    WeeklyUtilization = r.WeeklyUtilization ?? current.WeeklyUtilization, WeeklyResetsAt = r.WeeklyResetsAt ?? current.WeeklyResetsAt,
                    FiveHourUtilization = r.FiveHourUtilization ?? current.FiveHourUtilization, FiveHourResetsAt = r.FiveHourResetsAt ?? current.FiveHourResetsAt,
                } : current;
                if (result.HitTokenLimit) q = q with { PauseUntil = (result.LimitResetsAt ?? clock.Now).AddMinutes(5) };
                await quotaStore.SaveAsync(q, ct);
            }
            if (result.HitTokenLimit) local.WaitingFor = "quota";
            log($"card {id}: sessione di {role} finita, ESITO={result.Outcome ?? "(nessuno)"}");
        }
    }

    // ---- istantanea --------------------------------------------------------------------------------------------------

    public async Task<Snapshot> BuildSnapshotAsync(Card card, CardLocalState local, AreaMapping area, CancellationToken ct)
    {
        var key = names.KeyOf(card.State);
        var comments = await board.GetCommentsAsync(card.Id, ct);
        var history = await board.GetStateHistoryAsync(card.Id, ct);
        var tasks = await board.GetTasksAsync(card.Id, ct);
        var preds = key is K.New or K.Ready ? await board.GetPredecessorsAsync(card.Id, ct) : [];
        PullRequestInfo? pr = null;
        if (local.Branch is not null && key is not null && K.WithBranch.Contains(key))
            pr = await code.For(area).GetPullRequestAsync(area, local.Branch, local.Destination ?? "develop", key is K.ReadyToMerge or K.ReadyToRelease, ct);
        // D59: l'ambiente di collaudo si legge come un run: in creazione, creato, non creato
        var run = local.TestProject is not null && local.TestStartedAt is { } envStart && testEnvironments is not null
            ? await testEnvironments.GetStatusAsync(card.Id, envStart, ct)
            : local.RunId is { } runId ? await ci.GetRunAsync(area, runId, ct) : null;
        var deploy = ParseDeployChoice(comments);
        var fresh = comments.Where(c => c.Id > local.LastCommentId).ToList();
        return new Snapshot(card, local, area, fresh, history, tasks, preds, pr, run, deploy);
    }

    /// <summary>L'ultima scelta del deploy scritta dal responsabile: "[responsabile] Parametri del deploy in Test: a, b".</summary>
    public static DeployChoice? ParseDeployChoice(IEnumerable<Comment> comments)
    {
        IReadOnlyList<string>? choice = null;
        foreach (var c in comments.OrderBy(c => c.Id))
        {
            var plain = Regex.Replace(c.Text, "<[^>]+>", "\n").Replace("&nbsp;", " ");
            var first = plain.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault();
            if (first is null) continue;
            var m = DeployLine.Match(first);
            if (!m.Success) continue;
            choice = Regex.Replace(m.Groups[1].Value, "[`*]", "").Split([',', ' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
        }
        return choice is null ? null : new DeployChoice(choice);
    }

    // ---- esecuzione --------------------------------------------------------------------------------------------------

    private async Task ExecuteAsync(AgentAction action, Snapshot s, AreaMapping area, CardLocalState local, Dictionary<int, CardLocalState> state, CancellationToken ct)
    {
        var card = s.Card;
        switch (action)
        {
            case CreateTestEnvironment env:
            {
                var envs = testEnvironments ?? throw new InvalidOperationException("Gli ambienti di collaudo non sono configurati (config/collaudo.json)");
                if (local.Folder is not { } wt || !workspace.Exists(wt))
                    throw new InvalidOperationException($"La card non ha un worktree utilizzabile (cartella salvata: '{local.Folder}'): non posso creare l'ambiente di collaudo");
                var used = state.Where(kv => kv.Key != card.Id && kv.Value.TestSlot is not null).Select(kv => kv.Value.TestSlot!.Value).ToHashSet();
                var slot = local.TestSlot ?? Enumerable.Range(1, limits.TestEnvironments).FirstOrDefault(n => !used.Contains(n));
                if (slot == 0) throw new InvalidOperationException("Nessuno slot libero per l'ambiente di collaudo");
                var started = await envs.StartAsync(area, card.Id, slot, wt, ct);
                local.TestSlot = slot; local.TestProject = started.Project; local.TestStartedAt = started.StartedAt;
                local.TestUrls = new Dictionary<string, string>(started.Urls);
                local.RunId = null; local.RunAfterRev = env.Rev;
                await board.AddCommentAsync(card.Id, "[smistatore] Ambiente di collaudo in creazione...", ct);
                break;
            }
            case DiscardTestEnvironment:
            {
                var project = local.TestProject ?? $"card-{card.Id}";
                if (testEnvironments is not null && await testEnvironments.RemoveAsync(project, local.Folder, ct))
                {
                    local.TestSlot = null; local.TestProject = null; local.TestStartedAt = null; local.TestUrls = null;
                    await board.AddCommentAsync(card.Id, $"[smistatore] Ambiente di collaudo buttato ({project}).", ct);
                }
                // un docker che non risponde non ferma la card: i campi restano e al giro dopo si riprova
                else logger.LogWarning("card {Card}: ambiente {Project} non buttato, riprovo al giro dopo", card.Id, project);
                break;
            }
            case ResetCounters:
                local.ResetCounters();
                break;
            case ResetDeploy:
                local.RunId = null; local.RunAfterRev = null;
                break;
            case MoveCard m:
                await board.SetStateAsync(card.Id, names[m.State], ct);
                if (m.State == K.InReview) local.RedInARow = 0;
                break;
            case MoveBack b:
                await board.SetStateAsync(card.Id, names[b.State], ct);
                await board.AddCommentAsync(card.Id, $"[smistatore] {b.Reason}", ct);
                break;
            case PutOnHold h:
            {
                // D57: il commento chiude con la sezione Cosa fare: le righe del ruolo che ha visto la causa, o il testo predefinito
                var indications = WhatToDo.Resolve(WhatToDo.LatestSession(local)?.Text, h.Reason, h.For, null);
                await board.AddTagAsync(card.Id, names.OnHoldTag, ct);
                await board.AddCommentAsync(card.Id, $"{Mention(card)}[smistatore] {h.Reason}\n\n{WhatToDo.Format(indications, h.For)}", ct);
                local.WaitingFor = h.For;
                local.OnHoldIndications = indications;
                break;
            }
            case Notify n:
                await board.AddCommentAsync(card.Id, $"{Mention(card)}[smistatore] {n.Text}", ct);
                local.Notices.Add(n.Key);
                break;
            case CreateWorktree w:
                var (branch, folder) = await workspace.CreateWorktreeAsync(area, card, w.Base, ct);
                local.Branch = branch; local.Folder = folder; local.Destination = w.Base ?? "develop";
                break;
            case RemoveWorktree when local.Folder is { } f:
                await workspace.RemoveWorktreeAsync(area, f, ct);
                local.Folder = null;
                break;
            case OpenPr when local.Branch is { } br:
                var host = code.For(area);
                // D58: sotto il link alla card, il testo che dev ha salvato con descrizione-pr prima che la PR esistesse, se sta nel tetto
                var description = $"[Card {card.Id}]({board.CardUrl(card.Id)}): {card.Title}";
                if (WhatToDo.SavedPrDescription(await board.GetCommentsAsync(card.Id, ct)) is { } saved)
                {
                    var joined = $"{description}\n\n{saved}";
                    if (joined.Length <= PrDescriptionLimit) description = joined;
                    else logger.LogWarning("card {Card}: la descrizione salvata non sta nel tetto della PR, la PR si apre senza", card.Id);
                }
                var (prId, url) = await host.CreatePullRequestAsync(area, br, local.Destination ?? "develop", WhatToDo.PrTitle(br, card.Title), description, card.Id, ct);
                local.PrId = prId;
                if (host.NeedsCardLink) await board.AddLinkAsync(card.Id, url, $"PR {prId}", ct);
                break;
            case CompletePr c when s.Pr is { } pr:
                await code.For(area).CompletePullRequestAsync(area, pr.Id, c.Commit, ct);
                local.CompletePrKey = $"{pr.Id}@{c.Rev}";
                break;
            case QueueTestDeploy q when local.Branch is { } br2:
                local.RunId = await ci.QueueTestDeployAsync(area, br2, q.Parameters, q.Off, ct);
                local.RunAfterRev = q.Rev;
                break;
            case RequeueExpiredValidations when local.Branch is { } br3:
                await code.For(area).RequeueValidationsAsync(area, br3, local.Destination ?? "develop", true, ct);
                break;
            case RequeueValidation r when local.Branch is { } br4:
                await code.For(area).RequeueValidationsAsync(area, br4, local.Destination ?? "develop", false, ct);
                local.Relaunches++; local.RelaunchOf = r.SessionId;
                break;
            case LaunchSession l:
                await LaunchAsync(l, s, area, local, ct);
                break;
            default:
                throw new InvalidOperationException($"azione {action.Kind} non eseguibile con lo stato locale della card (ramo {local.Branch ?? "nessuno"})");
        }
    }

    /// <summary>
    /// D59: gli ambienti che docker conosce o che lo stato ricorda, di card che non sono piu in Test, si buttano. Docker che non
    /// risponde e un avviso, non un errore del giro.
    /// </summary>
    private async Task RemoveOrphanEnvironmentsAsync(Dictionary<int, CardLocalState> state, IReadOnlyList<Card> cards, Action<string> log, CancellationToken ct)
    {
        if (testEnvironments is null) return;
        var withState = state.Where(kv => kv.Value.TestProject is not null || kv.Value.TestSlot is not null).Select(kv => kv.Key).ToList();
        if (withState.Count == 0 && !areas.Any(a => a.TestEnvironment is not null)) return;
        var projects = new SortedSet<string>(withState.Select(id => $"card-{id}"));
        if (areas.Any(a => a.TestEnvironment is not null))
        {
            try { foreach (var p in await testEnvironments.ListProjectsAsync(ct)) projects.Add(p); }
            catch (Exception e) when (e is not OperationCanceledException) { log($"ambienti di collaudo orfani: docker non risponde ({e.Message})"); }
        }
        var inTest = cards.Where(c => names.KeyOf(c.State) is { } k && K.InTest.Contains(k)).Select(c => c.Id).ToHashSet();
        foreach (var project in projects)
        {
            if (!int.TryParse(project.Replace("card-", ""), out var id) || inTest.Contains(id)) continue;
            log($"ambiente di collaudo orfano {project} (la card {id} non e in Test): lo butto");
            var folder = state.TryGetValue(id, out var ls) ? ls.Folder : null;
            if (await testEnvironments.RemoveAsync(project, folder, ct))
            {
                if (ls is not null) { ls.TestSlot = null; ls.TestProject = null; ls.TestStartedAt = null; ls.TestUrls = null; }
            }
            else log($"ambiente di collaudo orfano {project} non buttato: riprovo al giro dopo");
        }
    }

    private async Task LaunchAsync(LaunchSession l, Snapshot s, AreaMapping area, CardLocalState local, CancellationToken ct)
    {
        var previous = local.Of(l.Role);
        var message = ComposeMessage(l, s);
        var id = await sessions.StartAsync(new SessionRequest(l.Role, s.Card.Id, area, local.Folder, message,
            l.Resume ? previous?.Id : null, l.Resume, l.TaskId, local.Destination), ct);
        local.RunningSession = id;
        local.LastRole = l.Role;
        local.LastSessionByRole[l.Role] = new SessionRecord { Id = id, Role = l.Role, Reason = l.Reason, Start = clock.Now, TaskId = l.TaskId };
        local.WaitingFor = null;
        // i commenti letti dalla sessione non fanno ripartire nessuno
        if (s.NewComments.Count > 0) local.LastCommentId = s.NewComments.Max(c => c.Id);
        switch (l.Role, l.Reason)
        {
            case ("dev", "rossa"): local.RedInARow++; local.HandledRedBuild = s.Pr?.BuildId; break;
            case ("dev", "rilievi"): local.ReviewRounds++; break;
            case ("responsabile", "collaudoRespinto"): local.TestRounds++; break;
        }
    }

    /// <summary>Il messaggio della sessione: la card, perche parte, l'allegato. Il resto lo dice il brief del ruolo.</summary>
    public static string ComposeMessage(LaunchSession l, Snapshot s)
    {
        var lines = new List<string>
        {
            $"Card {s.Card.Id} nel repo {s.Area?.Repo}: {s.Card.Title}.",
            $"Motivo del lancio: {l.Reason}.",
        };
        if (l.TaskId is { } t) lines.Add($"Lavori sul task {t}.");
        if (l.Resume) lines.Add("Riprendi da dove eri arrivato: rileggi il brief del tuo ruolo e i commenti sulla card dopo il tuo ultimo.");
        if (!string.IsNullOrWhiteSpace(l.Attachment)) lines.Add($"Allegato:\n{l.Attachment}");
        lines.Add("Chiudi con una riga ESITO=<esito> come dice il brief.");
        return string.Join("\n", lines);
    }

    private static string Mention(Card c) => c.AssignedTo is { } p ? $"@{p.Name} " : "";

    public static string Describe(AgentAction a) => a switch
    {
        LaunchSession l => $"LanciaSessione {l.Role} ({l.Reason}{(l.TaskId is null ? "" : $", task {l.TaskId}")}{(l.Resume ? ", ripresa" : "")})",
        MoveCard m => $"SpostaCard -> {m.State}",
        MoveBack b => $"RiportaIndietro -> {b.State}: {b.Reason}",
        PutOnHold h => $"MettiInAttesa ({h.For ?? "-"}): {h.Reason}",
        Notify n => $"Avvisa {n.Who}: {n.Text}",
        QueueTestDeploy q => $"AccodaDeployTest [{string.Join(", ", q.Parameters)}]",
        CompletePr c => $"CompletaPr ({c.Commit})",
        _ => a.Kind,
    };
}
