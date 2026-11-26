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

    // D52: per il giro, le figlie e il ramo di ogni Feature letti una volta, e l'utente (le Bug nuove gli vanno assegnate)
    private Dictionary<int, IReadOnlyList<Card>> _children = new();
    private Dictionary<int, string?> _featureBranches = new();
    private Dictionary<int, FeatureInfo> _features = new();
    private Person? _me;

    public async Task<RoundReport> RunRoundAsync(bool whatIf, int? onlyCard = null, CancellationToken ct = default)
    {
        var started = clock.Now;
        _children = new(); _featureBranches = new();
        var log = new List<string>();
        void Log(string m) { log.Add(m); logger.LogInformation("{Message}", m); }

        var state = await store.LoadAsync(ct);
        var active = (await board.GetActiveCardsAsync(ct)).ToDictionary(c => c.Id);
        if (!whatIf) await CloseFinishedSessionsAsync(state, active, Log, ct);

        // D60: le Feature aperte, per la pausa e per l'ordine. Se non si leggono il giro si ferma: senza, una Feature in pausa ripartirebbe.
        var features = await board.GetOpenFeaturesAsync(areas.Select(a => a.Area).ToList(), ct);
        var featureMap = features.ToDictionary(f => f.Id);
        _features = featureMap;
        var settings = settingsStore is null ? new SystemSettings() : await settingsStore.LoadAsync(ct);
        var quota = quotaStore is null ? null : await quotaStore.LoadAsync(ct);
        var overrides = quotaStore is null ? null : await quotaStore.LoadOverridesAsync(ct);
        var featureReports = FeaturePriority.Order(features).Select(f => new FeatureReport(f.Id, f.Title, f.State, f.Rank, f.HasTag(names.PausedTag), f.Area)).ToList();

        _me = await board.GetCurrentUserAsync(ct);
        var me = _options.OnlyMine ? _me : null;
        // D60: un posto libero (sessioni, repo, Test) va alla card della Feature piu in alto
        var cards = FeaturePriority.OrderCards(active.Values
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
                var activeSessions = state.Values.Count(x => x.RunningSession is not null);
                var ctx = baseCtx with
                {
                    ActiveSessions = activeSessions,
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

    /// <summary>
    /// Le sessioni finite, come Close-Sessione: l'esito si registra; una sessione senza risultato (silenzio o processo morto) la prima volta si
    /// riprende da sola senza on-hold (D51), la seconda va in on-hold con la causa; una fallita va in on-hold; sul limite di token si aspetta
    /// la quota. La quota letta dalla sessione si salva.
    /// </summary>
    private async Task CloseFinishedSessionsAsync(Dictionary<int, CardLocalState> state, Dictionary<int, Card> cards, Action<string> log, CancellationToken ct)
    {
        foreach (var (id, local) in state)
        {
            if (local.RunningSession is not { } sid || local.LastRole is not { } role) continue;
            var result = await sessions.PollAsync(sid, ct);
            // ancora in corso. Il silenzio lo giudica il runner: chiude il processo e restituisce un risultato senza esito.
            if (result is null) continue;
            var s = local.Of(role);
            var card = cards.GetValueOrDefault(id);
            local.RunningSession = null;
            if (quotaStore is not null && (result.Quota is not null || result.HitTokenLimit)) await SaveQuotaAsync(result, ct);

            if (result.NoResultCause is { } cause)
            {
                if (s is not null) { s.End = null; s.Outcome = null; s.Text = null; }
                var what = cause == "silenzio" ? $"e rimasta in silenzio per piu di {limits.SilenceMinutes} minuti ed e stata chiusa" : "e terminata senza dare un risultato (il processo non c'e piu)";
                if (card is null) { log($"card {id}: sessione {sid} chiusa ({cause}), ma la card non e piu fra le attive: nessun on-hold"); continue; }
                if (local.AutoResumes < 1)
                {
                    local.WaitingFor = "sessione"; local.ResumedBySystem = true; local.AutoResumes++; local.HoldCause = null;
                    log($"card {id}: sessione {sid} ({role}) {what}: la riprendo da sola, una volta, senza on-hold");
                    await board.AddCommentAsync(id, $"[smistatore] La sessione di {role} {what}. La riprendo da sola, una volta: se si ferma di nuovo la card va in on-hold.", ct);
                }
                else
                {
                    var reason = cause == "silenzio"
                        ? $"La sessione di {role} e rimasta in silenzio per piu di {limits.SilenceMinutes} minuti ed e stata chiusa. Si puo riprendere togliendo il tag {names.OnHoldTag}."
                        : $"La sessione di {role} e terminata senza dare un risultato (il processo non c'e piu): non riprovo da solo.";
                    await PutOnHoldAsync(card, local, reason, "sessione", cause, ct);
                    cards[id] = WithOnHold(card);
                }
                continue;
            }

            if (s is not null) { s.End = clock.Now; s.Outcome = result.Failed || result.HitTokenLimit ? null : result.Outcome; s.Text = result.Text; }
            if (result.HitTokenLimit)
            {
                local.WaitingFor = "quota";
                if (card is not null) await board.AddCommentAsync(id, $"[smistatore] La sessione di {role} si e fermata sul limite di token e riprende da sola dopo il reset.", ct);
            }
            else if (result.Failed && card is not null)
            {
                await PutOnHoldAsync(card, local, $"La sessione di {role} e fallita (errore, oppure comandi negati dai permessi): non riprovo da solo. Il registro delle sessioni ha i dettagli.", "sessione", "fallita", ct);
                cards[id] = WithOnHold(card);
            }
            else if (card is not null)
                await board.AddCommentAsync(id, $"[smistatore] Sessione {sid} finita: ruolo {role}, esito {(result.Outcome is { } o ? $"**{o}**" : "senza riga ESITO")}.", ct);
            log($"card {id}: sessione di {role} finita, ESITO={result.Outcome ?? "(nessuno)"}{(result.Failed ? ", FALLITA" : "")}");
        }
    }

    private async Task SaveQuotaAsync(SessionResult result, CancellationToken ct)
    {
        // D51: la quota e una sola per tutti i ruoli; vale l'ultima letta. Sul limite di token, pausa fino al reset (piu un margine).
        var current = await quotaStore!.LoadAsync(ct) ?? new QuotaInfo(null, null, null);
        var q = result.Quota is { } r ? current with
        {
            WeeklyUtilization = r.WeeklyUtilization ?? current.WeeklyUtilization, WeeklyResetsAt = r.WeeklyResetsAt ?? current.WeeklyResetsAt,
            FiveHourUtilization = r.FiveHourUtilization ?? current.FiveHourUtilization, FiveHourResetsAt = r.FiveHourResetsAt ?? current.FiveHourResetsAt,
        } : current;
        if (result.HitTokenLimit) q = q with { PauseUntil = (result.LimitResetsAt ?? clock.Now).AddMinutes(5) };
        await quotaStore.SaveAsync(q, ct);
    }

    /// <summary>La card del giro con il tag di on-hold appena messo: chi decide dopo, nello stesso giro, deve vederlo.</summary>
    private Card WithOnHold(Card c) => c with { Tags = c.Tags.Append(names.OnHoldTag).ToList() };

    /// <summary>Set-InAttesa: il tag, il commento con la menzione e la sezione Cosa fare (D57), come ripartire e la causa.</summary>
    private async Task PutOnHoldAsync(Card card, CardLocalState local, string reason, string? waitingFor, string? cause, CancellationToken ct)
    {
        var indications = WhatToDo.Resolve(WhatToDo.LatestSession(local)?.Text, reason, waitingFor, cause);
        await board.AddTagAsync(card.Id, names.OnHoldTag, ct);
        await board.AddCommentAsync(card.Id, $"{Mention(card)}[smistatore] {reason}\n\n{WhatToDo.Format(indications, waitingFor)}", ct);
        local.WaitingFor = waitingFor;
        local.OnHoldIndications = indications;
        local.HoldCause = cause;
        local.ResumedBySystem = false;
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
        var feature = await FeatureContextAsync(card, area, ct);
        var errors = feature is { IsClosing: true, Error: null } ? await ClosingBuildErrorsAsync(key, area, local, pr, run, ct) : null;
        return new Snapshot(card, local, area, fresh, history, tasks, preds, pr, run, deploy, feature, comments, errors);
    }

    /// <summary>
    /// D52: la funzionalita della card, se la sua Feature (aperta, delle aree della mappa) ha una card di chiusura: le sorelle (senza le
    /// Removed e senza la card stessa), lo stato della chiusura, il ramo su origin. Una lettura fallita e un errore che ferma la card.
    /// </summary>
    private async Task<FeatureContext?> FeatureContextAsync(Card card, AreaMapping area, CancellationToken ct)
    {
        if (card.ParentId is not { } fid || !_features.TryGetValue(fid, out var f)) return null;
        try
        {
            if (!_children.TryGetValue(fid, out var children)) _children[fid] = children = await board.GetFeatureChildrenAsync(fid, ct);
            var closing = children.FirstOrDefault(c => names.ClosingTag is { } t && c.Tags.Contains(t, StringComparer.OrdinalIgnoreCase));
            if (closing is null) return null;
            if (!_featureBranches.TryGetValue(fid, out var branch))
            {
                var found = new List<string>();
                foreach (var prefix in new[] { $"feature/f{fid}", $"bugfix/f{fid}" })
                    found.AddRange((await code.For(area).ListBranchesAsync(area, prefix, ct)).Where(b => System.Text.RegularExpressions.Regex.IsMatch(b, $@"^(feature|bugfix)/f{fid}(-.*)?$")));
                if (found.Count > 1) throw new InvalidOperationException($"Su origin c'e piu di un ramo della funzionalita {fid}: {string.Join(", ", found)}. Quale vale lo decide una persona");
                _featureBranches[fid] = branch = found.SingleOrDefault();
            }
            var siblings = children.Where(c => c.Id != card.Id && c.Id != closing.Id && names.KeyOf(c.State) != K.Removed)
                .Select(c => new Sibling(c.Id, c.State, c.Tags)).ToList();
            return new FeatureContext(f, card.Id == closing.Id, closing.Id, closing.State, branch, siblings);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            return FeatureContext.Failed(e.Message);
        }
    }

    /// <summary>
    /// D52: gli errori di codice della build rossa della card di chiusura (validazione della PR in Ready to develop e Ready to merge, run del
    /// deploy in Deploying to test), letti una volta per build: l'esito resta nello stato. Una lettura fallita non si ricorda: si riprova.
    /// </summary>
    private async Task<string?> ClosingBuildErrorsAsync(string? key, AreaMapping area, CardLocalState local, PullRequestInfo? pr, PipelineRun? run, CancellationToken ct)
    {
        int? build = null;
        if (key is K.Ready or K.ReadyToMerge && pr is { Status: PrStatuses.Active, Validation: Validations.Red, BuildId: { } b }) build = b;
        else if (key == K.DeployingToTest && run is { Status: "completed" } && run.Result != "succeeded" && local.RunId is { } r) build = r;
        if (build is null) return null;
        if (local.BuildErrorsOf == build.ToString()) return local.BuildErrors;
        try
        {
            var text = await ci.GetBuildErrorsAsync(area, build.Value, ct);
            local.BuildErrorsOf = build.ToString(); local.BuildErrors = text;
            return text;
        }
        catch (Exception e) when (e is not OperationCanceledException) { logger.LogWarning("errori della build {Build} non letti: {Error}", build, e.Message); return null; }
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
                // D52: per la card di chiusura l'ambiente si crea dal suo worktree in sola lettura, riportato al ramo della funzionalita
                if (s.Feature is { IsClosing: true } && local.Branch is { } closingBranch) local.Folder = await workspace.UpdateClosingWorktreeAsync(area, card, closingBranch, ct);
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
            case ResetCiRed:
                local.CiRedInARow = 0;
                break;
            case CreateFeatureBranch fb:
            {
                var feature = _features.TryGetValue(fb.FeatureId, out var fi) ? fi : throw new InvalidOperationException($"La Feature {fb.FeatureId} non e fra quelle lette dal giro: non posso creare il ramo della funzionalita");
                var bug = names.BugFeatureTag is { } bt && feature.HasTag(bt);
                // nella cache del giro: la card dopo della stessa Feature non lo ricrea, e il CreaWorktree che segue lo usa come base
                _featureBranches[fb.FeatureId] = await workspace.PublishFeatureBranchAsync(area, feature, bug, ct);
                logger.LogInformation("card {Card}: ramo della funzionalita {Branch}", card.Id, _featureBranches[fb.FeatureId]);
                break;
            }
            case UpdateFeature uf:
                // lo stato della Feature e un riepilogo per chi guarda il backlog: se non si scrive la card non si ferma, il giro dopo riprova
                try
                {
                    await board.SetStateAsync(uf.FeatureId, names[uf.State], ct);
                    if (uf.CloseLater) local.FeatureToClose = uf.FeatureId;
                    if (_features.TryGetValue(uf.FeatureId, out var old)) _features[uf.FeatureId] = old with { State = names[uf.State] };
                }
                catch (Exception e) when (e is not OperationCanceledException) { logger.LogError("card {Card}: la Feature {Feature} non e passata in {State}: {Error}", card.Id, uf.FeatureId, uf.State, e.Message); }
                break;
            case SetClosingBranch cb:
                if (cb.FromLinkedPr)
                {
                    // in Ready to release senza stato locale il ramo e gia cancellato dal merge: lo ricorda la PR della card
                    var linkedId = local.PrId ?? await board.GetLinkedPullRequestIdAsync(card.Id, ct);
                    if (linkedId is null || await code.For(area).GetPullRequestByIdAsync(area, linkedId.Value, ct) is not { Status: PrStatuses.Completed } linked)
                        throw new InvalidOperationException($"La card di chiusura {card.Id} e in Ready to release ma non ha una PR completata nota: non so quale ramo guardare");
                    local.Branch = linked.Branch;
                    local.PrId = linkedId;
                }
                else local.Branch = cb.Branch;
                local.Destination = "develop";
                local.Folder = null;
                break;
            case CreateCorrection cc:
            {
                var feature = _features.TryGetValue(cc.FeatureId, out var fi) ? fi : throw new InvalidOperationException($"La Feature {cc.FeatureId} non e fra quelle lette dal giro: non posso creare la Bug della correzione");
                var technical = cc.Nature == "tecnico";
                var bugText = $"## Descrizione\n{cc.Description}\n\n## Riferimenti\nCorrezione della funzionalita '{feature.Title}' (Feature #{feature.Id}), scritta dal responsabile sulla card di chiusura #{cc.ClosingCardId}.";
                var bugId = await board.CreateBugAsync(new NewBug(cc.Title, bugText, null, feature.Area ?? area.Area, feature.Id, [names.AgentsTag], technical ? K.New : null, Assignee()), ct);
                // la marca sulla card di chiusura vale da ogni PC: un secondo tentativo non crea una seconda Bug
                await board.AddCommentAsync(card.Id, $"[smistatore] Correzione #{cc.Key} -> Bug {bugId}", ct);
                local.CorrectionsDone.Add(cc.Key);
                if (!technical)
                    await board.AddCommentAsync(bugId, $"{Mention(card)}[smistatore] Correzione di prodotto dalla card di chiusura #{card.Id} (Feature {feature.Id}): richiede una scelta tua. La Bug resta in Draft: quando hai deciso, completa descrizione e criteri e portala in New.", ct);
                break;
            }
            case CreateAlignDevelop al:
            {
                var feature = _features.TryGetValue(al.FeatureId, out var fi) ? fi : throw new InvalidOperationException($"La Feature {al.FeatureId} non e fra quelle lette dal giro: non posso creare la Bug allinea-develop");
                var alignText = $"## Descrizione\nLa PR {al.Branch} → develop della funzionalita (Feature #{feature.Id}) ha conflitti con develop e non si puo unire.\n\n" +
                    $"Unisci origin/develop nel ramo di questa card (nato da {al.Branch}) con un merge, mai con rebase, e risolvi i conflitti tenendo il comportamento di tutte e due le parti. La PR di questa card va verso {al.Branch}.";
                var tags = new List<string> { names.AgentsTag };
                if (names.AlignTag is { } at) tags.Add(at);
                var bugId = await board.CreateBugAsync(new NewBug($"Allinea {al.Branch} a develop", alignText, $"la PR {al.Branch} → develop non ha conflitti", feature.Area ?? area.Area, feature.Id, tags, K.Ready, Assignee()), ct);
                await board.AddCommentAsync(card.Id, $"[smistatore] Allinea-develop @{al.Commit} -> Bug {bugId}", ct);
                if (al.Commit.Length > 0) local.AlignDone.Add(al.Commit);
                break;
            }
            case MoveCard m:
                await board.SetStateAsync(card.Id, names[m.State], ct);
                if (m.State == K.InReview) local.RedInARow = 0;
                // in Ready to merge il collaudo e superato (o saltato): i respinti di prima non contano piu
                if (m.State == K.ReadyToMerge) local.TestRounds = 0;
                break;
            case MoveBack b:
                await board.SetStateAsync(card.Id, names[b.State], ct);
                // D52: la testa con cui la card di chiusura e tornata indietro: un secondo ritorno per la stessa e un on-hold
                if (b.Commit is not null) local.ReturnCommit = b.Commit;
                await board.AddCommentAsync(card.Id, $"[smistatore] {b.Reason}", ct);
                break;
            case PutOnHold h:
                // D57: il commento chiude con la sezione Cosa fare: le righe del ruolo che ha visto la causa, o il testo predefinito
                await PutOnHoldAsync(card, local, h.Reason, h.For, null, ct);
                break;
            case StartHoldReview r:
                local.HoldInReview = new HoldReview(r.Reason, r.For, r.Role, r.Key);
                local.PassesDone.Add(r.Key);
                break;
            case CloseHoldReview c:
                local.HoldInReview = null;
                local.LastRole = c.Role;
                break;
            case ResetHoldReviews:
                local.PassesDone.Clear();
                local.AutoResumes = 0;
                break;
            case RemoveOnHold ro:
                await board.RemoveTagAsync(card.Id, names.OnHoldTag, ct);
                await board.AddCommentAsync(card.Id, $"[smistatore] tolgo l'on-hold: {ro.Cause}", ct);
                local.WaitingFor = ro.For;
                local.ResumedBySystem = true;
                break;
            case AdoptCard ad:
                await AdoptAsync(ad, card, area, local, ct);
                break;
            case Notify n:
                await board.AddCommentAsync(card.Id, $"{Mention(card)}[smistatore] {n.Text}", ct);
                local.Notices.Add(n.Key);
                break;
            case CreateWorktree w:
            {
                // D52: con la base vuota il ramo l'ha appena creato CreaRamoFunzionalita
                var baseBranch = w.FeatureCard ? w.Base ?? (card.ParentId is { } p && _featureBranches.TryGetValue(p, out var fb) ? fb : null)
                    ?? throw new InvalidOperationException("Il ramo della funzionalita non c e: non posso creare il worktree della card") : w.Base;
                var (branch, folder) = await workspace.CreateWorktreeAsync(area, card, baseBranch, ct);
                local.Branch = branch; local.Folder = folder; local.Destination = baseBranch ?? "develop";
                break;
            }
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
                if (r.SessionId.Length == 0) local.CiRedRetry = false;
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
        // D52: il collaudatore della card di chiusura legge il ramo della funzionalita in un worktree in sola lettura, rinnovato a ogni lancio
        if (l.ClosingWorktree && local.Branch is { } closingBranch) local.Folder = await workspace.UpdateClosingWorktreeAsync(area, s.Card, closingBranch, ct);
        if (l.Build is not null) { local.CiRedHandled = l.Build; local.CiRedInARow++; local.CiRedRetry = false; }
        var id = await sessions.StartAsync(new SessionRequest(l.Role, s.Card.Id, area, local.Folder, message,
            l.Resume ? previous?.Id : null, l.Resume, l.TaskId, local.Destination), ct);
        local.RunningSession = id;
        local.LastRole = l.Role;
        local.ResumedBySystem = false;
        local.LastSessionByRole[l.Role] = new SessionRecord { Id = id, Role = l.Role, Reason = l.Reason, Start = clock.Now, TaskId = l.TaskId };
        local.WaitingFor = null;
        // il commento dice agli altri smistatori che la card ha una sessione viva (una presa in carico aspetta, spec sezione 19)
        await board.AddCommentAsync(s.Card.Id, $"[smistatore] Sessione {id} {(l.Resume ? "ripresa" : "avviata")}: ruolo {l.Role}, cartella {local.Folder ?? "-"}.", ct);
        // i commenti letti dalla sessione non fanno ripartire nessuno
        if (s.NewComments.Count > 0) local.LastCommentId = s.NewComments.Max(c => c.Id);
        switch (l.Role, l.Reason)
        {
            case ("dev", "rossa"): local.RedInARow++; local.HandledRedBuild = s.Pr?.BuildId; break;
            case ("dev", "rilievi"): local.ReviewRounds++; break;
            case ("responsabile", "collaudoRespinto"): local.TestRounds++; break;
        }
    }

    /// <summary>
    /// Presa in carico (spec, sezione 19): il worktree dal ramo della card su origin. Senza ramo pubblicato: in Ready to release e In feature
    /// branch la card ricorda la sua PR; In development si riparte da develop (o dal ramo della funzionalita); altrove non c'e lavoro da riprendere.
    /// </summary>
    private async Task AdoptAsync(AdoptCard ad, Card card, AreaMapping area, CardLocalState local, CancellationToken ct)
    {
        var key = names.KeyOf(card.State);
        if (ad.FeatureCard && ad.Base is null && key != K.InFeatureBranch)
            throw new InvalidOperationException($"Il ramo della funzionalita non e su origin: non posso riprendere la card {card.Id} da li");
        var found = key == K.InFeatureBranch ? null : await workspace.CreateWorktreeFromRemoteAsync(area, card, ct);
        string note;
        if (found is null)
        {
            if (key is K.ReadyToRelease or K.InFeatureBranch)
            {
                // dopo il merge il ramo e cancellato: la card ricorda la sua PR
                if (await board.GetLinkedPullRequestIdAsync(card.Id, ct) is not { } prId || await code.For(area).GetPullRequestByIdAsync(area, prId, ct) is not { Status: PrStatuses.Completed })
                    throw new InvalidOperationException($"Su origin non c'e nessun ramo della card {card.Id} e nessuna PR collegata completata: non so cosa rilasciare");
                local.PrId = prId;
                if (ad.FeatureCard && ad.Base is not null) local.Destination = ad.Base;
                logger.LogInformation("card {Card}: presa in carico gia unita (PR {Pr} completata), niente da fare", card.Id, prId);
                return;
            }
            if (key != K.InDevelopment) throw new InvalidOperationException($"Su origin non c'e nessun ramo della card {card.Id}: in {card.State} non c'e lavoro da riprendere. Riportare la card in Ready to develop");
            var (branch, folder) = await workspace.CreateWorktreeAsync(area, card, ad.Base, ct);
            found = (branch, folder);
            note = $"nessun ramo pubblicato: worktree nuovo da origin/{ad.Base ?? "develop"}, ramo `{branch}`.";
        }
        else note = $"worktree ricreato dal ramo `{found.Value.Branch}` pubblicato su origin.";
        if (ad.FeatureCard) local.Destination = ad.Base;
        local.Branch = found.Value.Branch; local.Folder = found.Value.Folder;
        await board.AddCommentAsync(card.Id, $"[smistatore] Card presa in carico da {_me?.Name}: {note}", ct);
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
        if (l.Resume)
            lines.Add(l.ResumeKind switch
            {
                "dopoRipresaAutomatica" => "La tua sessione era stata chiusa dallo smistatore (in silenzio da troppo, oppure il processo era terminato senza risultato): nessuno ha tolto un on-hold. Riprendi da dove eri arrivato.",
                "dopoQuota" => "La tua sessione si era fermata per il limite di token: nessuno ha tolto un on-hold e non e cambiato niente, la quota e tornata. Continua da dove eri arrivato.",
                "dopoPassata" => "Il responsabile ha esaminato l'attesa per cui la card si stava fermando e ha sistemato la causa: leggi il suo commento sulla card, dice cosa ha cambiato.",
                _ => "Chi ha la card ha tolto l'on-hold: qualcosa e cambiato da quando ti sei fermato. Prima di concludere rileggi il brief del tuo ruolo e i commenti sulla card dopo il tuo ultimo.",
            });
        if (!string.IsNullOrWhiteSpace(l.Attachment)) lines.Add($"Allegato:\n{l.Attachment}");
        lines.Add("Chiudi con una riga ESITO=<esito> come dice il brief.");
        return string.Join("\n", lines);
    }

    private static string Mention(Card c) => c.AssignedTo is { } p ? $"@{p.Name} " : "";

    /// <summary>Le Bug nuove si assegnano all'utente dello smistatore: senza, nessuno smistatore le prenderebbe.</summary>
    private string Assignee() => _me?.UniqueName is { Length: > 0 } u ? u
        : throw new InvalidOperationException("Non trovo l'indirizzo dell'utente dello smistatore: la Bug nascerebbe senza assegnatario e nessuno smistatore la prenderebbe. Non la creo");

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
