using System.Text.RegularExpressions;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Model;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Decisions;

/// <summary>Il contesto del giro, uguale per tutte le card: limiti, sessioni in corso, posti occupati, quota, ora.</summary>
public sealed record DecisionContext(
    StateNames Names,
    Limits Limits,
    DateTimeOffset Now,
    int ActiveSessions = 0,
    IReadOnlyList<int>? CardsWithSession = null,
    IReadOnlyDictionary<string, IReadOnlyList<int>>? InDevelopmentByRepo = null,
    IReadOnlyDictionary<string, IReadOnlyList<int>>? InTestByComponent = null,
    QuotaInfo? Quota = null,
    /// <summary>D51: la soglia della riserva settimanale ignorata fino al reset (override dalla vista).</summary>
    bool IgnoreWeeklyReserve = false);

/// <summary>
/// Il motore decisionale: dato lo stato di una card, cosa fare adesso. Funzione pura, nessun modello, nessuna chiamata:
/// e la conversione di Get-Decisione (src/Decisioni.psm1) per le card isolate (senza funzionalita D52).
/// </summary>
public sealed class DecisionEngine
{
    // Un commento di agente comincia con [ruolo], eventualmente dentro un involucro html con la menzione.
    private static readonly Regex AgentComment = new(@"^(?:\s|&nbsp;|<a\b[^>]*>[^<]*</a>|<[^>]*>|@)*\[(?:responsabile|dev|reviewer|collaudatore|mentore|smistatore)\]", RegexOptions.Compiled);
    private static readonly Regex ResponsabileComment = new(@"^(?:\s|&nbsp;|<a\b[^>]*>[^<]*</a>|<[^>]*>|@)*\[responsabile\]", RegexOptions.Compiled);

    public static bool IsPersonComment(Comment c) => !AgentComment.IsMatch(c.Text);

    public Decision Decide(Snapshot snapshot, DecisionContext ctx)
    {
        var names = ctx.Names;
        var tags = snapshot.Card.Tags;
        var local = snapshot.Local;

        if (!tags.Contains(names.AgentsTag, StringComparer.OrdinalIgnoreCase)) return Decision.Nothing;
        if (tags.Contains(names.OnHoldTag, StringComparer.OrdinalIgnoreCase))
            return new Decision([], new BlockReason("onHold", Detail: local.WaitingFor));
        if (local.RunningSession is not null) return Decision.Nothing;

        var actions = new List<AgentAction>();
        var waiting = local.WaitingFor;
        // Lo stato e cambiato dopo l'ultima sessione (qualcuno ha spostato la card a mano): la sessione a meta non c'entra piu.
        if (waiting is "sessione" or "quota" && StateChangedAfterLastSession(snapshot)) waiting = "limite";

        Env? env = null;
        if (waiting is "sessione" or "quota")
        {
            // l'on-hold e stato tolto: si riprende la sessione rimasta a meta, sul suo task
            var role = local.LastRole;
            if (role is null) return Decision.Nothing;
            actions.Add(new LaunchSession(role, "ripresa", null, true, local.Of(role)?.TaskId));
        }
        else
        {
            var effective = local;
            var reset = false;
            var resetDeploy = false;
            if (waiting is "limite" or "deploy")
            {
                // contatori a zero, poi si decide come se non fossero mai stati raggiunti
                effective = local.Clone();
                effective.ResetCounters();
                if (local.RunId is not null && snapshot.Run is { Status: "completed" } run && run.Result != "succeeded")
                {
                    // dopo un deploy fallito chi toglie il tag ha sistemato la causa: si riaccoda il deploy
                    effective.RunId = null; effective.RunAfterRev = null;
                    resetDeploy = true;
                }
                reset = true;
            }
            env = new Env(snapshot, ctx, effective);
            if (env.Key is null) return Decision.Nothing;

            if (env.LastRole is not null && env.Last is { IsFinished: true } && string.IsNullOrWhiteSpace(env.Last.Outcome))
                actions.Add(new PutOnHold($"La sessione di {env.LastRole} e finita senza riga ESITO", "sessione", WaitKind: "senzaEsito"));
            else
                actions.AddRange(StateActions(env));

            if (resetDeploy) actions.Insert(0, new ResetDeploy());
            if (reset) actions.Insert(0, new ResetCounters());
        }

        // al limite di sessioni attive non parte niente, nemmeno gli spostamenti legati al lancio: al giro dopo si riprova
        var launches = actions.OfType<LaunchSession>().ToList();
        if (launches.Count > 0 && ctx.ActiveSessions >= ctx.Limits.ActiveSessions)
            return new Decision([], new BlockReason("limiteSessioni", launches[0].Role, $"{ctx.ActiveSessions}/{ctx.Limits.ActiveSessions}", ctx.CardsWithSession));
        if (launches.Count > 0 && QuotaBlock(ctx) is { } quota)
            return new Decision([], quota with { Role = launches[0].Role });

        BlockReason? reason = null;
        if (env is not null && actions.All(a => a is ResetCounters or ResetDeploy)) reason = StartBlock(env);
        return new Decision(actions, reason);
    }

    // ---- per stato -----------------------------------------------------------------------------------------------

    private IEnumerable<AgentAction> StateActions(Env a) => a.Key switch
    {
        K.New => NewCard(a),
        K.NeedsClarification => NeedsClarification(a),
        K.Ready => Ready(a),
        K.InDevelopment => InDevelopment(a),
        K.InReview => InReview(a),
        K.DeployingToTest => DeployingToTest(a),
        K.AutomatedTest => AutomatedTest(a),
        K.HumanTest => HumanTest(a),
        K.ReadyToMerge => ReadyToMerge(a),
        K.ReadyToRelease => ReadyToRelease(a),
        _ => [], // bozza, inRilascio, chiusa, rimossa: niente da fare
    };

    private IEnumerable<AgentAction> NewCard(Env a)
    {
        if (StartBlock(a) is not null) return [];
        // il responsabile ha gia finito su questa card e la card e ancora in New: non ha portato avanti niente
        if (a.LastRole == "responsabile" && a.Last is { IsFinished: true } last)
        {
            var since = a.Entry?.When;
            if (last.End is null || since is null || last.End >= since)
                return [new PutOnHold("responsabile ha finito ma la card e rimasta in New", "sessione")];
        }
        return [new LaunchSession("responsabile", "nuova")];
    }

    private IEnumerable<AgentAction> NeedsClarification(Env a) =>
        a.S.NewComments.Any(IsPersonComment) ? [new LaunchSession("responsabile", "commento")] : [];

    private IEnumerable<AgentAction> Ready(Env a)
    {
        if (StartBlock(a) is not null) return [];
        return [new CreateWorktree(), new MoveCard(K.InDevelopment), new LaunchSession("dev", "pronto", null, false, a.FirstOpenTask)];
    }

    private IEnumerable<AgentAction> InDevelopment(Env a)
    {
        var outcome = a.Last?.Outcome;
        if (a.LastRole == "responsabile" && outcome == "fatto")
            return [new LaunchSession("dev", "decisione", ResponsabileText(a, a.Last), false, a.FirstOpenTask)];
        if (a.LastRole == "responsabile" && outcome == "bloccato" && a.Last?.Reason != "attesa")
            return [new PutOnHold("il responsabile non riesce a sbloccare la card: la sua diagnosi e nel commento", "sessione")];
        if (a.LastRole is null && a.OpenTasks.Count > 0) return [new LaunchSession("dev", "task", null, false, a.FirstOpenTask)];
        if (a.LastRole is null) return a.S.Pr is null ? [new LaunchSession("dev", "presaInCarico")] : PrActions(a);
        if (a.LastRole is not ("dev" or "responsabile"))
        {
            // la card e tornata In development dopo reviewer o collaudatore: o una decisione del responsabile, o un task aperto
            var resp = a.Local.Of("responsabile");
            if (resp is { Outcome: "fatto", End: not null } && (a.Last?.End is null || resp.End > a.Last.End))
                return [new LaunchSession("dev", "decisione", ResponsabileText(a, resp), false, a.FirstOpenTask)];
            if (a.OpenTasks.Count > 0) return [new LaunchSession("dev", "taskAggiunto", null, false, a.FirstOpenTask)];
            return [new PutOnHold($"la card e tornata In development dopo {a.LastRole}, senza task aperti ne indicazioni del responsabile", "limite")];
        }
        if (a.LastRole != "dev") return [];
        switch (outcome)
        {
            case "bloccato":
                if (a.Last?.Reason == "decisione" && a.Local.Of("responsabile")?.Reason == "bloccato")
                    return [new PutOnHold("dev e ancora bloccato dopo la decisione del responsabile", "sessione", Direct: true)];
                return [new LaunchSession("responsabile", "bloccato", a.Last?.Text)];
            case "rilancia":
                if (a.Last?.Reason != "rossa")
                    return [new PutOnHold("dev chiede di rilanciare la validazione, ma non era partito per una validazione rossa", "sessione")];
                if (a.Local.RelaunchOf == a.Last.Id) return PrActions(a);
                if (a.Local.Relaunches >= 1)
                    return [new PutOnHold("dev chiede di nuovo di rilanciare la validazione: il test che fallisce va guardato da una persona", "limite")];
                return [new RequeueValidation(a.Last.Id)];
            case "bivio":
                return [new LaunchSession("responsabile", "bivio", a.Last?.Text)];
            case "fatto":
                if (a.OpenTasks.Count > 0)
                {
                    var own = a.Last?.TaskId;
                    if (own is not null && a.OpenTasks.Any(t => t.Id == own))
                        return [new PutOnHold($"dev ha finito ma il task {own} e ancora aperto: non l'ha chiuso", "sessione", WaitKind: "taskNonChiuso")];
                    return [new LaunchSession("dev", "taskSuccessivo", null, false, a.FirstOpenTask)];
                }
                return PrActions(a);
            default:
                return [];
        }
    }

    private IEnumerable<AgentAction> PrActions(Env a)
    {
        var pr = a.S.Pr;
        if (pr is null) return [new OpenPr()];
        switch (pr.Validation)
        {
            case Validations.Red:
                if (pr.BuildId is not null && pr.BuildId == a.Local.HandledRedBuild) return [];
                if (a.Local.RedInARow >= a.Ctx.Limits.RedInARow) return [new PutOnHold("troppe validazioni rosse di fila", "limite")];
                return [new LaunchSession("dev", "rossa", pr.LogUrl)];
            case Validations.Green:
                return [new MoveCard(K.InReview), new LaunchSession("reviewer", "verde")];
            case Validations.Expired:
                return [new RequeueExpiredValidations()];
            case Validations.Conflicts:
                if (a.LastRole == "dev" && a.Last?.Reason == "conflitti")
                    return [new PutOnHold($"la PR ha ancora conflitti con {a.Local.Destination ?? "develop"} dopo che dev ha provato a risolverli", null)];
                return [new LaunchSession("dev", "conflitti")];
            case Validations.Running:
                var end = a.Last?.End;
                if (end is null || (a.Ctx.Now - end.Value).TotalMinutes <= a.Ctx.Limits.ValidationMinutes) return [];
                var key = $"validazioneLunga@{a.Last!.Id}";
                if (a.Local.Notices.Contains(key)) return [];
                return [new Notify("titolare", key, $"La validazione della PR e in corso da piu di {a.Ctx.Limits.ValidationMinutes} minuti dalla fine di dev: controlla la build ({pr.LogUrl}).")];
            default:
                return [];
        }
    }

    private IEnumerable<AgentAction> InReview(Env a)
    {
        if (a.LastRole is null) return [new LaunchSession("reviewer", "presaInCarico")];
        if (a.LastRole == "dev" && a.Last?.Outcome == "fatto" && a.OpenTasks.Count == 0 && a.S.Pr?.Validation == Validations.Green)
            return [new LaunchSession("reviewer", "verde")];
        if (a.LastRole != "reviewer") return [];
        var outcome = a.Last?.Outcome;
        if (outcome != "bloccante" && a.OpenTasks.Count > 0) return TaskAdded(a);
        switch (outcome)
        {
            case "bloccante":
                if (a.Local.ReviewRounds >= a.Ctx.Limits.ReviewRounds) return [new PutOnHold("troppi giri di revisione", "limite")];
                return [new MoveCard(K.InDevelopment), new LaunchSession("dev", "rilievi", a.Last?.Text)];
            case "superata":
                if (!ReviewPassed(a) || StartBlock(a) is not null) return [];
                return [new MoveCard(WithoutTest(a) ? K.ReadyToMerge : K.DeployingToTest)];
            default:
                return [];
        }
    }

    /// <summary>Le regole comuni agli stati di Test; null se nessuna vale e decide lo stato.</summary>
    private IReadOnlyList<AgentAction>? CommonInTest(Env a)
    {
        if (a.Entry is null) return [];
        if (a.OpenTasks.Count > 0) return TaskAdded(a).ToList();
        if (!ReviewPassed(a))
        {
            var before = PreviousState(a);
            return before is null ? [] : [new MoveBack(before, "La revisione non e superata")];
        }
        if (WithoutTest(a)) return [new MoveCard(K.ReadyToMerge)];
        return null;
    }

    private IEnumerable<AgentAction> DeployingToTest(Env a)
    {
        if (CommonInTest(a) is { } common) return common;
        if (!RunValid(a))
        {
            var component = a.S.Area?.Component ?? "";
            if (Others(a.Ctx.InTestByComponent, component, a.Id).Count >= a.Ctx.Limits.CardsInTestPerComponent)
                return [new MoveBack(K.InReview, "Un altra card dello stesso componente e gia in test")];
            var selected = (a.S.Deploy?.Selected ?? []).Where(p => !string.IsNullOrWhiteSpace(p)).ToList();
            if (selected.Count == 0) return [new PutOnHold("manca la scelta del deploy in Test del responsabile", "deploy")];
            if (!string.IsNullOrEmpty(a.S.Deploy!.AllowedError))
                return [new PutOnHold($"non riesco a leggere i parametri del deploy in Test: {a.S.Deploy.AllowedError}", "deploy", WaitKind: "parametriDeployIlleggibili")];
            IReadOnlyList<string> off = [];
            if (a.S.Deploy.Allowed is { } allowed)
            {
                var unknown = selected.Where(p => !allowed.Contains(p, StringComparer.Ordinal)).ToList();
                if (unknown.Count > 0) return [new PutOnHold($"parametro di deploy sconosciuto: {string.Join(", ", unknown)}", "deploy", WaitKind: "parametroDeploySconosciuto")];
                off = allowed.Where(p => !selected.Contains(p, StringComparer.Ordinal)).ToList();
            }
            return [new QueueTestDeploy(a.EntryRev, selected, off)];
        }
        if (a.S.Run is not { Status: "completed" } run) return [];
        if (run.Result != "succeeded")
        {
            var label = run.Url is not null ? $"[run {a.Local.RunId}]({run.Url})" : $"run {a.Local.RunId}";
            return [new PutOnHold($"deploy in Test fallito ({label}): sistemata la causa, togli il tag e il deploy si rilancia", "deploy", WaitKind: "deployFallito")];
        }
        return [new MoveCard(HumanTestRequested(a) ? K.HumanTest : K.AutomatedTest)];
    }

    private IEnumerable<AgentAction> AutomatedTest(Env a)
    {
        if (CommonInTest(a) is { } common) return common;
        if (a.S.NewComments.Any(IsPersonComment)) return [new LaunchSession("responsabile", "commentoInCollaudo")];

        var test = a.Local.Of("collaudatore");
        var since = a.Entry?.When;
        var when = test?.Start ?? test?.End;
        var valid = test is { IsFinished: true } && (since is null || (when is not null && when >= since));
        if (a.LastRole == "responsabile" && a.Last is { IsFinished: true } && a.Last.Reason == "collaudoRespinto")
            return [new PutOnHold("responsabile ha letto il collaudo respinto ma la card e rimasta In Automated test", "sessione")];
        if (valid && a.LastRole is "collaudatore" or "responsabile")
        {
            switch (test!.Outcome)
            {
                case "superata": return [new MoveCard(K.ReadyToMerge)];
                case "respinta":
                    if (a.Local.TestRounds >= a.Ctx.Limits.TestRounds) return [new PutOnHold("troppi collaudi respinti di fila", "limite")];
                    return [new LaunchSession("responsabile", "collaudoRespinto", test.Text)];
                case "bloccato": return [new PutOnHold("il collaudatore non riesce a provare: il suo resoconto e nel commento sulla card", "sessione")];
                default: return [new PutOnHold($"il collaudatore ha chiuso con un esito che non conosco ('{test.Outcome}')", "sessione", WaitKind: "esitoCollaudoSconosciuto")];
            }
        }
        var url = a.S.Area?.TestUrl;
        var attachment = url is not null
            ? $"Ambiente di Test: {url}"
            : "Nella mappa non c'e l'indirizzo dell'ambiente di Test (urlTest) per questo repo. Non provare a ricavarlo: chiudi con ESITO=bloccato e scrivi che manca urlTest nella mappa.";
        return [new LaunchSession("collaudatore", "collaudo", attachment)];
    }

    private IEnumerable<AgentAction> HumanTest(Env a)
    {
        if (CommonInTest(a) is { } common) return common;
        if (a.S.NewComments.Any(IsPersonComment)) return [new LaunchSession("responsabile", "verificaInTest")];
        var key = $"testPronto@{a.EntryRev}";
        if (a.Local.Notices.Contains(key)) return [];
        return [new Notify("richiedente", key, "Il deploy in Test e riuscito: la card aspetta la tua verifica.")];
    }

    private IEnumerable<AgentAction> ReadyToMerge(Env a)
    {
        if (a.Entry is null) return [];
        if (a.OpenTasks.Count > 0) return TaskAdded(a);
        var pr = a.S.Pr;
        if (pr?.Status == PrStatuses.Completed) return [new MoveCard(K.ReadyToRelease)];
        if (pr?.Status == PrStatuses.Active)
        {
            if (pr.Validation == Validations.Conflicts)
                return [new MoveBack(K.InDevelopment, $"La PR e in conflitto con {a.Local.Destination ?? "develop"}: la card torna In development e dev allinea il ramo"), new LaunchSession("dev", "conflitti")];
            if (pr.Validation == Validations.Expired) return [new RequeueExpiredValidations()];
            if (pr.Validation == Validations.Running) return [];
            if (a.Local.CompletePrKey == $"{pr.Id}@{a.EntryRev}")
                return [new PutOnHold($"il completamento della PR {pr.Id} e stato chiesto ma la PR e ancora aperta (validazione: {pr.Validation})", "limite", WaitKind: "prNonCompletata")];
            return [new CompletePr(a.EntryRev, pr.HeadCommit)];
        }
        return [new PutOnHold("nessuna PR da completare sul ramo della card", "limite")];
    }

    private IEnumerable<AgentAction> ReadyToRelease(Env a)
    {
        if (a.S.Pr?.Status == PrStatuses.Completed) return a.Local.Folder is not null ? [new RemoveWorktree()] : [];
        if (a.S.Pr is null && a.Local.PrId is not null && a.Local.Branch is null && a.Local.Folder is null) return [];
        if (a.Entry is null) return [];
        return a.OpenTasks.Count > 0 ? TaskAdded(a) : [];
    }

    private static IEnumerable<AgentAction> TaskAdded(Env a)
    {
        if (a.OpenTasks.Count == 0) return [];
        return [new MoveBack(K.InDevelopment, "C'e un task aperto aggiunto dopo lo sviluppo: la card torna In development"), new LaunchSession("dev", "taskAggiunto", null, false, a.FirstOpenTask)];
    }

    // ---- blocchi -------------------------------------------------------------------------------------------------

    /// <summary>Perche una card che potrebbe partire aspetta: predecessori non uniti, posto occupato nel repo o nel componente.</summary>
    private static BlockReason? StartBlock(Env a)
    {
        if (a.Key == K.InReview) return EntryInTestBlock(a);
        if (a.Key is not (K.New or K.Ready)) return null;
        var waiting = a.S.Predecessors.Where(p => !PredecessorMerged(a.Ctx.Names, p)).Select(p => p.Id).ToList();
        var role = a.Key == K.New ? "responsabile" : "dev";
        if (waiting.Count > 0) return new BlockReason("predecessori", role, Cards: waiting);
        if (a.Key != K.Ready) return null;
        var repo = a.S.Area?.Repo ?? "";
        var others = Others(a.Ctx.InDevelopmentByRepo, repo, a.Id);
        if (others.Count >= a.Ctx.Limits.CardsInDevelopmentPerRepo) return new BlockReason("limiteRepo", "dev", repo, others);
        return null;
    }

    private static BlockReason? EntryInTestBlock(Env a)
    {
        if (WithoutTest(a)) return null;
        if (a.LastRole != "reviewer" || a.Last?.Outcome != "superata" || !ReviewPassed(a) || a.OpenTasks.Count > 0) return null;
        var component = a.S.Area?.Component ?? "";
        var others = Others(a.Ctx.InTestByComponent, component, a.Id);
        if (others.Count >= a.Ctx.Limits.CardsInTestPerComponent)
            return new BlockReason("limiteTest", HumanTestRequested(a) ? null : "collaudatore", component, others);
        return null;
    }

    private static bool PredecessorMerged(StateNames names, Predecessor p) => names.KeyOf(p.State) switch
    {
        K.Releasing or K.Closed => true,
        K.ReadyToRelease => p.PrId is not null && string.IsNullOrWhiteSpace(p.Folder),
        _ => false,
    };

    private static BlockReason? QuotaBlock(DecisionContext ctx)
    {
        if (ctx.Quota is not { } q) return null;
        if (q.PauseUntil is { } pause && pause > ctx.Now) return new BlockReason("quota", Detail: $"limite fino a {pause:o}");
        if (!ctx.IgnoreWeeklyReserve && q.WeeklyUtilization is { } use && use >= ctx.Limits.WeeklyQuotaThreshold && q.WeeklyResetsAt is { } reset && reset > ctx.Now)
            return new BlockReason("quota", Detail: $"riserva settimanale ({use:P0}) fino a {reset:o}");
        return null;
    }

    // ---- aiuti ---------------------------------------------------------------------------------------------------

    private static bool ReviewPassed(Env a)
    {
        var rev = a.Local.Of("reviewer");
        if (rev is not { IsFinished: true, Outcome: "superata" }) return false;
        var dev = a.Local.Of("dev");
        if (dev is not { IsFinished: true }) return true;
        return rev.End > dev.End;
    }

    private static bool WithoutTest(Env a) =>
        (a.Ctx.Names.NoTestTag is { } t && a.S.Card.Tags.Contains(t, StringComparer.OrdinalIgnoreCase)) || a.S.Area?.DeployPipeline is null;

    private static bool HumanTestRequested(Env a) =>
        a.Ctx.Names.HumanTestTag is { } t && a.S.Card.Tags.Contains(t, StringComparer.OrdinalIgnoreCase);

    private static bool RunValid(Env a) => a.Local.RunId is not null && a.Local.RunAfterRev is { } r && a.Entry is not null && r == a.Entry.Rev;

    private static string? PreviousState(Env a)
    {
        if (a.Entry is null) return null;
        var before = a.Ctx.Names.KeyOf(a.Entry.From);
        return before is not null && K.InTest.Contains(before) ? K.InReview : before;
    }

    private static IReadOnlyList<int> Others(IReadOnlyDictionary<string, IReadOnlyList<int>>? table, string key, int id) =>
        table is not null && table.TryGetValue(key, out var l) ? l.Where(x => x != id).ToList() : [];

    private static string? ResponsabileText(Env a, SessionRecord? s)
    {
        var own = a.S.NewComments.Where(c => ResponsabileComment.IsMatch(c.Text)).ToList();
        return own.Count > 0 ? own[^1].Text : s?.Text;
    }

    private static bool StateChangedAfterLastSession(Snapshot s)
    {
        var last = s.Local.LastSession;
        var when = last?.End ?? last?.Start;
        if (when is null) return false;
        var entry = s.History.OrderBy(h => h.Rev).LastOrDefault(h => string.Equals(h.To, s.Card.State, StringComparison.OrdinalIgnoreCase));
        return entry is not null && entry.When > when;
    }

    /// <summary>L'ambiente di una decisione (New-Ambiente): la card letta con le chiavi, l'ingresso nello stato, i task aperti.</summary>
    private sealed class Env
    {
        public Env(Snapshot s, DecisionContext ctx, CardLocalState local)
        {
            S = s; Ctx = ctx; Local = local;
            Id = s.Card.Id;
            Key = ctx.Names.KeyOf(s.Card.State);
            Entry = s.History.OrderBy(h => h.Rev).LastOrDefault(h => string.Equals(h.To, s.Card.State, StringComparison.OrdinalIgnoreCase));
            EntryRev = Entry?.Rev ?? s.Card.Rev;
            LastRole = local.LastRole;
            Last = local.LastSession;
            var closed = ctx.Names.ClosedTaskStates.ToHashSet(StringComparer.OrdinalIgnoreCase);
            OpenTasks = s.Tasks.Where(t => !closed.Contains(t.State)).OrderBy(t => t.Id).ToList();
        }

        public Snapshot S { get; }
        public DecisionContext Ctx { get; }
        public CardLocalState Local { get; }
        public int Id { get; }
        public string? Key { get; }
        public StateChange? Entry { get; }
        public int EntryRev { get; }
        public string? LastRole { get; }
        public SessionRecord? Last { get; }
        public IReadOnlyList<WorkTask> OpenTasks { get; }
        public int? FirstOpenTask => OpenTasks.Count > 0 ? OpenTasks[0].Id : null;
    }
}
