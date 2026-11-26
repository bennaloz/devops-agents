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
    /// <summary>Gli override della vista sulle soglie di quota (D51, D60), validi fino al reset della loro finestra.</summary>
    QuotaOverrides? QuotaOverrides = null,
    /// <summary>
    /// D60: le Feature aperte delle aree della mappa, per id. Con l'elenco, una card in New senza Feature non parte e la pausa di una
    /// Feature ferma le sue card; senza (null) le regole D60 sulle Feature non valgono.
    /// </summary>
    IReadOnlyDictionary<int, FeatureInfo>? Features = null,
    /// <summary>D59: le card in uno stato di Test il cui componente ha l'ambiente di collaudo (i posti di ambientiCollaudo).</summary>
    IReadOnlyList<int>? CardsWithTestEnvironment = null);

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

    /// <summary>
    /// La decisione su una card. D59: l'ambiente di collaudo di una card che non e piu in uno stato di Test si butta prima di tutto il
    /// resto, anche in on-hold, con una sessione, in pausa o senza il tag: occupa un posto e delle porte.
    /// </summary>
    public Decision Decide(Snapshot snapshot, DecisionContext ctx)
    {
        var d = DecideCard(snapshot, ctx);
        if (snapshot.Local.TestProject is null && snapshot.Local.TestSlot is null) return d;
        var key = ctx.Names.KeyOf(snapshot.Card.State);
        if (key is null || K.InTest.Contains(key)) return d;
        return d with { Actions = [new DiscardTestEnvironment(), .. d.Actions] };
    }

    private Decision DecideCard(Snapshot snapshot, DecisionContext ctx)
    {
        var names = ctx.Names;
        var tags = snapshot.Card.Tags;
        var local = snapshot.Local;

        if (!tags.Contains(names.AgentsTag, StringComparer.OrdinalIgnoreCase)) return Decision.Nothing;
        if (tags.Contains(names.OnHoldTag, StringComparer.OrdinalIgnoreCase))
        {
            // D51: alcuni on-hold si tolgono da soli, solo se un dato dice che la causa non c'e piu
            if (HoldReleased(snapshot, ctx) is { } released) return new Decision([released], null);
            return new Decision([], new BlockReason("onHold", Detail: local.WaitingFor));
        }
        if (local.RunningSession is not null) return Decision.Nothing;
        // D60: una card in pausa (tag sulla card o sulla sua Feature) e una card nuova senza Feature restano ferme. La sessione in
        // corso finisce, ma non ne parte un'altra e la card non si sposta.
        if (PriorityStop(snapshot.Card, ctx) is { } stop) return new Decision([], stop);
        // D52: la funzionalita della card non si e letta. Non e una card isolata (partirebbe dal ramo sbagliato): aspetta una lettura.
        if (snapshot.Feature?.Error is { } fe) return new Decision([], new BlockReason("funzionalitaIllegibile", Detail: fe));

        var actions = new List<AgentAction>();
        var waiting = local.WaitingFor;
        // D42, D51: una persona ha tolto l'on-hold (non lo smistatore, non la pausa di quota): ogni attesa ha di nuovo la sua passata
        var bySystem = local.ResumedBySystem;
        var resetPasses = waiting is not null && waiting != "quota" && !bySystem && (local.PassesDone.Count > 0 || local.AutoResumes > 0);
        var afterReview = false;
        CloseHoldReview? closeReview = null;
        // D42: il responsabile ha finito la passata prima di un on-hold: cosa succede dipende dal suo esito
        if (local.HoldInReview is { } review && waiting != "sessione" && local.LastRole == "responsabile")
        {
            var resp = local.Of("responsabile");
            if (resp is { IsFinished: true, Reason: "attesa" } && !string.IsNullOrWhiteSpace(resp.Outcome))
            {
                closeReview = new CloseHoldReview(review.Role);
                var outcome = resp.Outcome;
                // le domande spostano la card solo da New e da In development: fuori da li servirebbe un on-hold
                if (outcome == "domande" && names.KeyOf(snapshot.Card.State) != K.NeedsClarification) outcome = "domandeFuori";
                switch (outcome)
                {
                    case "fatto":
                        // come se una persona avesse tolto l'on-hold, con l'ultimo ruolo di prima della passata
                        waiting = review.For;
                        afterReview = true;
                        local = local.Clone();
                        local.LastRole = review.Role;
                        break;
                    case "domande":
                        return new Decision([closeReview], null);
                    case "domandeFuori":
                        return new Decision([closeReview, new PutOnHold($"{review.Reason} (il responsabile ha domande per te: sono nel commento sulla card)", review.For)], null);
                    default:
                        return new Decision([closeReview, new PutOnHold($"{review.Reason} (il responsabile ha guardato: la sua diagnosi e nel commento sulla card)", review.For)], null);
                }
            }
        }
        // Lo stato e cambiato dopo l'ultima sessione (qualcuno ha spostato la card a mano): la sessione a meta non c'entra piu.
        if (waiting is "sessione" or "quota" && StateChangedAfterLastSession(snapshot)) waiting = "limite";

        Env? env = null;
        if (waiting is "sessione" or "quota")
        {
            // l'on-hold e stato tolto: si riprende la sessione rimasta a meta, sul suo task
            var role = local.LastRole;
            if (role is null) return Decision.Nothing;
            var kind = afterReview ? "dopoPassata" : waiting == "quota" ? "dopoQuota" : bySystem ? "dopoRipresaAutomatica" : null;
            actions.Add(new LaunchSession(role, "ripresa", null, true, local.Of(role)?.TaskId, ClosingWorktree: role == "collaudatore" && snapshot.Feature is { IsClosing: true, Error: null }, ResumeKind: kind));
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
                if ((local.RunId is not null || local.TestProject is not null) && snapshot.Run is { Status: "completed" } run && run.Result != "succeeded")
                {
                    // dopo un deploy fallito chi toglie il tag ha sistemato la causa: si riaccoda il deploy
                    effective.RunId = null; effective.RunAfterRev = null;
                    resetDeploy = true;
                }
                // D52: per la CI rossa della card di chiusura non si rilancia il responsabile sulla stessa build: si rilancia la validazione
                effective.CiRedRetry = true;
                if (resetPasses) effective.PassesDone.Clear();
                reset = true;
            }
            env = new Env(snapshot, ctx, effective);
            if (env.Key is null) return Decision.Nothing;

            if (env.LastRole is not null && env.Last is { IsFinished: true } && string.IsNullOrWhiteSpace(env.Last.Outcome))
                actions.Add(new PutOnHold($"La sessione di {env.LastRole} e finita senza riga ESITO", "sessione", WaitKind: "senzaEsito"));
            else
            {
                actions.AddRange(StateActions(env));
                if (actions.Count == 0 && ResponsabileWithoutFollowUp(env))
                    actions.Add(new PutOnHold("il responsabile ha finito ma nessuna regola sa come proseguire: leggi il suo commento", "sessione"));
            }
            // D42: un on-hold passa prima dal responsabile, una volta per tipo di attesa
            var converted = ConvertHoldsForResponsabile(env, actions).ToList();
            actions.Clear();
            actions.AddRange(converted);

            if (resetDeploy) actions.Insert(0, new ResetDeploy());
            // D52: la CI della card di chiusura e tornata verde: i giri del responsabile per la CI rossa ripartono da zero
            if (env.IsClosing && env.Local.CiRedInARow > 0 && ClosingCiGreen(env)) actions.Insert(0, new ResetCiRed());
            if (reset) actions.Insert(0, new ResetCounters());
        }

        // D46: il mentore parte dopo il limite: se il limite ferma il lancio correttivo, non parte neanche lui, e riparte al giro dopo
        var onHoldRemoved = waiting is not null && waiting != "quota" && !bySystem && !afterReview;
        if (closeReview is not null) actions.Insert(0, closeReview);
        if (resetPasses) actions.Insert(0, new ResetHoldReviews());

        // al limite di sessioni attive non parte niente, nemmeno gli spostamenti legati al lancio: al giro dopo si riprova
        var launches = actions.OfType<LaunchSession>().ToList();
        if (launches.Count > 0 && ctx.ActiveSessions >= ctx.Limits.ActiveSessions)
            return new Decision([], new BlockReason("limiteSessioni", launches[0].Role, $"{ctx.ActiveSessions}/{ctx.Limits.ActiveSessions}", ctx.CardsWithSession));
        if (launches.Count > 0 && QuotaBlock(ctx) is { } quota)
            return new Decision([], quota with { Role = launches[0].Role });

        var mentorEnv = env ?? new Env(snapshot, ctx, local);
        if (mentorEnv.Key is not null) actions.AddRange(MentorActions(mentorEnv, actions, onHoldRemoved));

        BlockReason? reason = null;
        if (env is not null && actions.All(a => a is LaunchMentor or ResetCounters or ResetDeploy or ResetCiRed or CloseHoldReview or ResetHoldReviews)) reason = StartBlock(env) ?? ClosingInDraft(env);
        return new Decision(actions, reason);
    }

    // ---- per stato -----------------------------------------------------------------------------------------------

    private IEnumerable<AgentAction> StateActions(Env a)
    {
        // D52: la funzionalita non c'e piu: nessuna regola sa dove portare la card, e il motivo (StartBlock) lo dice a una persona
        if (a.Path == "perduta") return [];
        // la card e arrivata da un altro PC (riassegnata dalla board): il lavoro e sul ramo pubblicato
        if (ToAdopt(a))
        {
            // una sessione avviata da poco dall'altro smistatore potrebbe essere ancora viva: si aspetta
            if (RecentForeignSession(a)) return [];
            return [new AdoptCard(a.IsFeatureCard ? a.Feature!.Branch : null, a.IsFeatureCard)];
        }
        if (a.IsClosing)
        {
            // la correzione scritta dal responsabile diventa una Bug figlia della Feature, da sola in questo giro
            if (CorrectionToDo(a) is { } c)
                return [new CreateCorrection(c.Key, c.Nature, c.Title, c.Description, a.Feature!.Feature.Id, a.Id)];
            var inTest = K.InTest.Contains(a.Key!) || a.Key == K.ReadyToMerge;
            // una sorella non ancora unita cambierebbe il ramo sotto il collaudo: la card torna in Ready to develop e aspetta
            if (inTest && SiblingsNotMerged(a) is { Count: > 0 } open)
                return [new MoveBack(K.Ready, $"La sorella {string.Join(", ", open.Select(x => $"#{x.Id}"))} non e ancora unita nel ramo della funzionalita: il ramo cambierebbe sotto il collaudo, la card di chiusura torna in Ready to develop e aspetta")];
            // in Ready to release senza stato locale il ramo non c'e piu: lo dice la PR collegata alla card
            if (a.Key == K.ReadyToRelease && a.Local.Branch is null) return [new SetClosingBranch(null, FromLinkedPr: true)];
            // senza ramo salvato la chiusura lo prende dalla funzionalita; non ha un worktree da creare
            if ((inTest || a.Key == K.Ready) && a.Local.Branch is null && !(a.Key == K.Ready && StartBlock(a) is not null))
                return a.Feature!.Branch is { } br ? [new SetClosingBranch(br)]
                    : [new PutOnHold("il ramo della funzionalita non c e su origin: la card di chiusura non sa quale ramo provare", "limite")];
        }
        return StateActionsOf(a);
    }

    private IEnumerable<AgentAction> StateActionsOf(Env a) => a.Key switch
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
        K.InFeatureBranch => InFeatureBranch(a),
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
        if (StartBlock(a) is { } block) return a.IsClosing ? ClosingBlockActions(a, block) : [];
        if (a.IsClosing) return ReadyClosing(a);
        var actions = new List<AgentAction>();
        if (a.IsFeatureCard)
        {
            // D52: il ramo della funzionalita nasce da origin/develop alla prima card in sviluppo; il worktree parte da li e la PR ci va
            var f = a.Feature!;
            if (f.Branch is null) actions.Add(new CreateFeatureBranch(f.Feature.Id));
            actions.Add(new CreateWorktree(f.Branch, FeatureCard: true));
            if (string.Equals(f.Feature.State, a.Ctx.Names.Get("featureNuova"), StringComparison.OrdinalIgnoreCase))
                actions.Add(new UpdateFeature(f.Feature.Id, "featureAttiva"));
        }
        else actions.Add(new CreateWorktree());
        actions.Add(new MoveCard(K.InDevelopment));
        actions.Add(new LaunchSession("dev", "pronto", null, false, a.FirstOpenTask));
        return actions;
    }

    /// <summary>D52: la card di chiusura in Ready to develop apre la PR ramo della funzionalita -> develop e, verde, va al deploy.</summary>
    private static IEnumerable<AgentAction> ReadyClosing(Env a)
    {
        if (a.S.Pr is null) return [new OpenPr()];
        return a.S.Pr.Validation switch
        {
            Validations.Green => [new MoveCard(K.DeployingToTest)],
            Validations.Expired => [new RequeueExpiredValidations()],
            Validations.Red => a.Local.Relaunches >= 1
                ? [new PutOnHold($"la validazione della PR e rossa senza errori di codice anche dopo un rilancio: sembra infrastruttura, guarda la build ({a.S.Pr.LogUrl})", "limite")]
                : [new RequeueValidation("")],
            _ => [],
        };
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
        if (!a.IsClosing && !ReviewPassed(a))
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
            if (TestSlotBlock(a, null) is { } block)
                // la card di chiusura non e passata da In review: aspetta in Ready to develop
                return [new MoveBack(a.IsClosing ? K.Ready : K.InReview, block.Type == "limiteAmbienti" ? "Gli ambienti di collaudo sono tutti occupati" : "Un altra card dello stesso componente e gia in test")];
            // D59: l'ambiente Docker della card al posto del deploy: nessun parametro da scegliere
            if (a.S.Area?.TestEnvironment is not null) return [new CreateTestEnvironment(a.EntryRev)];
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
            // D52: la card di chiusura con la build o i test falliti non e un deploy da rilanciare: il responsabile scrive la correzione
            if (a.IsClosing && ClosingCiBlock(a) is { } ci) return ClosingBlockActions(a, ci);
            if (a.S.Area?.TestEnvironment is not null)
                return [new PutOnHold($"ambiente di collaudo non creato, log: {run.Url}: sistemata la causa, togli il tag e l'ambiente si ricrea", "deploy", WaitKind: "deployFallito")];
            var label = run.Url is not null ? $"[run {a.Local.RunId}]({run.Url})" : $"run {a.Local.RunId}";
            return [new PutOnHold($"deploy in Test fallito ({label}): sistemata la causa, togli il tag e il deploy si rilancia", "deploy", WaitKind: "deployFallito")];
        }
        // la card di chiusura passa sempre dal collaudo automatico (poi, con human-test, dalla persona)
        return [new MoveCard(HumanTestRequested(a) && !a.IsClosing ? K.HumanTest : K.AutomatedTest)];
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
                case "superata": return [new MoveCard(a.IsClosing && HumanTestRequested(a) ? K.HumanTest : K.ReadyToMerge)];
                case "respinta":
                    if (a.Local.TestRounds >= a.Ctx.Limits.TestRounds) return [new PutOnHold("troppi collaudi respinti di fila", "limite")];
                    return [new LaunchSession("responsabile", "collaudoRespinto", test.Text)];
                case "bloccato": return [new PutOnHold("il collaudatore non riesce a provare: il suo resoconto e nel commento sulla card", "sessione")];
                default: return [new PutOnHold($"il collaudatore ha chiuso con un esito che non conosco ('{test.Outcome}')", "sessione", WaitKind: "esitoCollaudoSconosciuto")];
            }
        }
        if (a.S.Area?.TestEnvironment is not null)
        {
            // D59: l'ambiente e quello della card, creato in Deploying to test: gli URL stanno nello stato locale
            var urls = a.Local.TestUrls is { Count: > 0 } u ? string.Join("\n", u.Select(kv => $"- {kv.Key}: {kv.Value}")) : null;
            return [new LaunchSession("collaudatore", "collaudo", ClosingWorktree: a.IsClosing, Attachment: urls is not null
                ? $"Ambiente di collaudo della card:\n{urls}"
                : "Nello stato della card non ci sono gli indirizzi dell'ambiente di collaudo. Non provare a ricavarli: chiudi con ESITO=bloccato e scrivi che mancano gli indirizzi dell'ambiente di collaudo della card.")];
        }
        var url = a.S.Area?.TestUrl;
        var attachment = url is not null
            ? $"Ambiente di Test: {url}"
            : "Nella mappa non c'e l'indirizzo dell'ambiente di Test (urlTest) per questo repo. Non provare a ricavarlo: chiudi con ESITO=bloccato e scrivi che manca urlTest nella mappa.";
        return [new LaunchSession("collaudatore", "collaudo", attachment, ClosingWorktree: a.IsClosing)];
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
        if (pr?.Status == PrStatuses.Completed)
        {
            if (a.IsClosing) return [new MoveCard(K.ReadyToRelease), .. FeatureResolved(a)];
            // D52: la PR di una card della funzionalita e entrata nel ramo della funzionalita, non in develop
            return [new MoveCard(a.IsFeatureCard ? K.InFeatureBranch : K.ReadyToRelease)];
        }
        if (pr?.Status == PrStatuses.Active)
        {
            if (a.IsClosing && ClosingCiBlock(a) is { Type: "conflittiFunzionalita" or "ciRossaFunzionalita" } ci) return ClosingBlockActions(a, ci);
            if (pr.Validation == Validations.Conflicts)
                return [new MoveBack(K.InDevelopment, $"La PR e in conflitto con {a.Local.Destination ?? "develop"}: la card torna In development e dev allinea il ramo"), new LaunchSession("dev", "conflitti")];
            if (pr.Validation == Validations.Expired) return [new RequeueExpiredValidations()];
            if (pr.Validation == Validations.Running) return [];
            if (StartBlock(a) is not null) return [];
            // D52: la PR della funzionalita si completa solo sul commit provato in Test; se il ramo e cambiato si rifa il giro dal deploy
            if (a.IsClosing && !WithoutTest(a))
            {
                var tested = a.S.Run?.SourceVersion;
                var head = pr.HeadCommit;
                if (string.IsNullOrWhiteSpace(tested) || string.IsNullOrWhiteSpace(head) || tested != head)
                {
                    if (head is { Length: > 0 } && a.Local.ReturnCommit == head)
                        return [new PutOnHold($"la card e gia tornata in Ready to develop per la testa {head} della PR e il commit del deploy ({tested}) non coincide ancora: guarda il ramo della funzionalita e il run del deploy", "limite")];
                    return [new MoveBack(K.Ready, "Il ramo della funzionalita e cambiato dopo il deploy in Test (il commit della PR non e quello provato): la card torna in Ready to develop e si rifa il deploy", head)];
                }
            }
            if (a.Local.CompletePrKey == $"{pr.Id}@{a.EntryRev}")
                return [new PutOnHold($"il completamento della PR {pr.Id} e stato chiesto ma la PR e ancora aperta (validazione: {pr.Validation})", "limite", WaitKind: "prNonCompletata")];
            return [new CompletePr(a.EntryRev, pr.HeadCommit)];
        }
        return [new PutOnHold("nessuna PR da completare sul ramo della card", "limite")];
    }

    private IEnumerable<AgentAction> ReadyToRelease(Env a)
    {
        if (a.IsClosing)
        {
            if (a.S.Pr?.Status != PrStatuses.Completed) return [];
            return [.. a.Local.Folder is not null ? [new RemoveWorktree(Closing: true)] : Array.Empty<AgentAction>(), .. FeatureResolved(a)];
        }
        if (a.S.Pr?.Status == PrStatuses.Completed) return a.Local.Folder is not null ? [new RemoveWorktree()] : [];
        if (a.S.Pr is null && a.Local.PrId is not null && a.Local.Branch is null && a.Local.Folder is null) return [];
        if (a.Entry is null) return [];
        return a.OpenTasks.Count > 0 ? TaskAdded(a) : [];
    }

    /// <summary>D52: la card e nel ramo della funzionalita; quando la card di chiusura e rilasciata, la segue in Ready to release.</summary>
    private static IEnumerable<AgentAction> InFeatureBranch(Env a)
    {
        if (StartBlock(a) is not null) return [];
        var actions = new List<AgentAction>();
        if (a.Local.Folder is not null) actions.Add(new RemoveWorktree());
        if (a.Ctx.Names.KeyOf(a.Feature?.ClosingState) is K.ReadyToRelease or K.Releasing or K.Closed) actions.Add(new MoveCard(K.ReadyToRelease));
        if (a.OpenTasks.Count > 0 && a.Local.Folder is not null)
        {
            var key = $"taskInFeature@{a.EntryRev}";
            if (!a.Local.Notices.Contains(key))
                actions.Add(new Notify("titolare", key, "C'e un task aperto su una card In feature branch: il suo lavoro e gia nel ramo della funzionalita, il lavoro nuovo va in una card nuova della funzionalita."));
        }
        return actions;
    }

    private static IEnumerable<AgentAction> FeatureResolved(Env a)
    {
        var f = a.Feature!.Feature;
        var names = a.Ctx.Names;
        if (string.Equals(f.State, names.Get("featureChiusa"), StringComparison.OrdinalIgnoreCase)) return [];
        if (string.Equals(f.State, names.Get("featureRisolta"), StringComparison.OrdinalIgnoreCase) && a.Local.FeatureToClose is not null) return [];
        return [new UpdateFeature(f.Id, "featureRisolta", CloseLater: true)];
    }

    private static bool SiblingMerged(StateNames names, Sibling s) => names.KeyOf(s.State) is K.InFeatureBranch or K.ReadyToRelease or K.Releasing or K.Closed;

    private static List<Sibling> SiblingsNotMerged(Env a) => (a.Feature?.Siblings ?? []).Where(s => !SiblingMerged(a.Ctx.Names, s)).ToList();

    /// <summary>D52: la CI della card di chiusura (validazione della PR verso develop o build del deploy) che ferma la card, se c'e.</summary>
    private static BlockReason? ClosingCiBlock(Env a)
    {
        var pr = a.S.Pr;
        BlockReason Conflicts() => new("conflittiFunzionalita", Detail: a.Local.Branch);
        BlockReason? Red(string source, int? build, string? url) =>
            string.IsNullOrWhiteSpace(a.S.BuildErrors) ? null : new BlockReason("ciRossaFunzionalita", Detail: $"{source}|{build}|{url}");
        switch (a.Key)
        {
            case K.Ready when pr is not null:
                return pr.Validation switch
                {
                    Validations.Conflicts => Conflicts(),
                    Validations.Red => Red("validazione", pr.BuildId, pr.LogUrl),
                    Validations.Green when !WithoutTest(a) => TestSlotBlock(a, null),
                    _ => null,
                };
            case K.DeployingToTest:
                if (!RunValid(a) || a.S.Run is not { Status: "completed" } run || run.Result == "succeeded") return null;
                return Red("deploy", a.Local.RunId, run.Url);
            case K.ReadyToMerge when pr is { Status: PrStatuses.Active }:
                return pr.Validation switch
                {
                    Validations.Conflicts => Conflicts(),
                    Validations.Red => Red("validazione", pr.BuildId, pr.LogUrl),
                    _ => null,
                };
            default:
                return null;
        }
    }

    private static bool ClosingCiGreen(Env a) =>
        a.S.Pr?.Validation == Validations.Green ||
        (K.InTest.Contains(a.Key!) && RunValid(a) && a.S.Run is { Status: "completed", Result: "succeeded" });

    /// <summary>D52: cosa fa la card di chiusura davanti a un blocco della sua CI: il responsabile scrive la correzione, o una Bug allinea-develop.</summary>
    private static IEnumerable<AgentAction> ClosingBlockActions(Env a, BlockReason block)
    {
        switch (block.Type)
        {
            case "ciRossaFunzionalita":
            {
                var parts = (block.Detail ?? "||").Split('|');
                var (source, build, url) = (parts[0], parts[1], parts[2]);
                if (string.IsNullOrWhiteSpace(build)) return [];
                if (a.Local.CiRedHandled == build)
                {
                    if (a.Local.CiRedRetry && source == "validazione") return [new RequeueValidation("")];
                    if (a.LastRole == "responsabile" && a.Last is { IsFinished: true, Reason: "ciRossa" })
                        return [new PutOnHold($"il responsabile ha guardato la CI rossa della card di chiusura (build {build}) e non ha scritto una correzione: serve una persona, la sua diagnosi e nel commento sulla card", "limite", Direct: true)];
                    return [];
                }
                if (a.Ctx.Limits.RedInARow > 0 && a.Local.CiRedInARow >= a.Ctx.Limits.RedInARow)
                    return [new PutOnHold($"troppe sessioni del responsabile per la CI rossa della card di chiusura ({a.Ctx.Limits.RedInARow} di fila): una persona guarda la build ({url})", "limite", Direct: true)];
                var where = source == "deploy" ? "Il deploy in Test della card di chiusura ha la build o i test falliti" : "La validazione della PR della card di chiusura e rossa";
                var link = string.IsNullOrEmpty(url) ? "" : $", {url}";
                return [new LaunchSession("responsabile", "ciRossa",
                    $"{where} (build {build}{link}), con errori di codice. Scrivi la correzione (card.ps1 correzione) se la causa e nel codice della funzionalita.\n\nErrori:\n{a.S.BuildErrors}", Build: build)];
            }
            case "conflittiFunzionalita":
            {
                var head = a.S.Pr?.HeadCommit ?? "";
                var done = a.Local.AlignDone.Concat(BugsCreated(a.S.AllComments, "Allinea-develop @"));
                if (head.Length > 0 && done.Contains(head))
                {
                    var alive = (a.Feature?.Siblings ?? []).Any(s => a.Ctx.Names.AlignTag is { } t && s.Tags.Contains(t, StringComparer.OrdinalIgnoreCase));
                    return alive ? [] : [new PutOnHold($"la PR {block.Detail} verso develop ha ancora conflitti e la Bug allinea-develop per questo commit non c'e piu (rimossa senza unirla?): una persona decide", "limite", Direct: true)];
                }
                return [new CreateAlignDevelop(a.Feature!.Feature.Id, block.Detail ?? "", head)];
            }
            default:
                return [];
        }
    }

    // ---- correzioni (D52) ----------------------------------------------------------------------------------------

    public sealed record Correction(string Key, string Nature, string Title, string Description);

    private static readonly Regex CorrectionHead = new(@"^\[responsabile\]\s*Correzione:\s*(tecnico|prodotto)\s*$", RegexOptions.Compiled);
    private static readonly Regex CorrectionTitle = new(@"^Titolo:\s*(\S.*?)\s*$", RegexOptions.Compiled);

    /// <summary>Le correzioni scritte dal responsabile ("[responsabile] Correzione: tecnico|prodotto", poi "Titolo: ...", poi la descrizione).</summary>
    public static IEnumerable<Correction> CorrectionsWritten(IEnumerable<Comment>? comments)
    {
        foreach (var c in (comments ?? []).OrderBy(c => c.Id))
        {
            var lines = WhatToDo.PlainText(c.Text).Split('\n');
            var m = CorrectionHead.Match(lines[0]);
            if (!m.Success) continue;
            var i = 1;
            while (i < lines.Length && string.IsNullOrWhiteSpace(lines[i])) i++;
            if (i >= lines.Length || CorrectionTitle.Match(lines[i]) is not { Success: true } t) continue;
            var body = lines.Skip(i + 1).Where(l => l.Trim() != "\u2014 scritto da Claude (responsabile)");
            yield return new Correction(c.Id.ToString(), m.Groups[1].Value, t.Groups[1].Value, string.Join("\n", body).Trim());
        }
    }

    /// <summary>Le chiavi delle Bug gia create, dai commenti "[smistatore] &lt;marca&gt;&lt;chiave&gt; -&gt; Bug &lt;id&gt;": valgono da ogni PC.</summary>
    public static IEnumerable<string> BugsCreated(IEnumerable<Comment>? comments, string mark) =>
        (comments ?? []).Select(c => Regex.Match(WhatToDo.PlainText(c.Text).Split('\n')[0], $@"^\[smistatore\]\s*{Regex.Escape(mark)}(\S+)\s+->\s+Bug\s+\d+\s*$"))
            .Where(m => m.Success).Select(m => m.Groups[1].Value);

    private static Correction? CorrectionToDo(Env a)
    {
        var done = a.Local.CorrectionsDone.Concat(BugsCreated(a.S.AllComments, "Correzione #")).ToHashSet();
        return CorrectionsWritten(a.S.AllComments).FirstOrDefault(c => !done.Contains(c.Key));
    }

    // ---- D46: il mentore -----------------------------------------------------------------------------------------

    private static readonly string[] CorrectionFromCommentStates = [K.Ready, K.InDevelopment, K.InReview, K.DeployingToTest, K.AutomatedTest, K.ReadyToMerge];

    /// <summary>
    /// Quando parte il mentore (Get-AzioniMentore): dev rilanciato dopo la decisione del responsabile su un blocco o un bivio, o con i rilievi
    /// del reviewer; un commento di persona nello stato (o un on-hold tolto: la lezione va a chi si era fermato); la card tornata In development
    /// dalla prova umana; una Bug che va in rilascio. Una volta per correzione.
    /// </summary>
    private static IEnumerable<LaunchMentor> MentorActions(Env a, IReadOnlyList<AgentAction> actions, bool onHoldRemoved)
    {
        var proposals = new List<LaunchMentor>();
        foreach (var l in actions.OfType<LaunchSession>().Where(l => l.Role == "dev"))
        {
            var resp = a.Local.Of("responsabile");
            if (l.Reason == "decisione" && resp?.Reason is "bloccato" or "bivio")
                proposals.Add(new LaunchMentor(["dev"], "responsabile", "decisione", l.Attachment, $"decisione@{resp.Id}"));
            else if (l.Reason == "rilievi")
                proposals.Add(new LaunchMentor(["dev"], "reviewer", "rilievi", l.Attachment, $"rilievi@{a.Local.Of("reviewer")?.Id}"));
        }
        var since = a.Entry?.When;
        var person = a.S.NewComments.Where(c => IsPersonComment(c) && (since is null || c.When >= since)).ToList();
        if (person.Count > 0 && CorrectionFromCommentStates.Contains(a.Key!))
        {
            var key = $"commento@{person.Max(c => c.Id)}";
            var text = string.Join("\n\n", person.Select(c => $"{c.Author}: {c.Text}"));
            proposals.Add(onHoldRemoved
                ? new LaunchMentor([a.LastRole ?? "responsabile"], "persona", "onHoldTolto", text, key)
                : new LaunchMentor(["responsabile"], "persona", "commento", text, key));
        }
        if (a.Key == K.InDevelopment && a.Entry is not null && a.Ctx.Names.KeyOf(a.Entry.From) == K.HumanTest)
        {
            var all = a.S.AllComments ?? a.S.NewComments;
            var text = string.Join("\n\n", all.Where(IsPersonComment).Select(c => $"{c.Author}: {c.Text}"));
            proposals.Add(new LaunchMentor(["collaudatore", "reviewer"], "persona", "provaUmana", text, $"provaUmana@{a.EntryRev}"));
        }
        if (string.Equals(a.S.Card.WorkItemType, "Bug", StringComparison.OrdinalIgnoreCase) && a.S.Pr?.Id is { } prId && actions.Any(x => x is MoveCard { State: K.ReadyToRelease }))
            proposals.Add(new LaunchMentor(["dev", "collaudatore", "reviewer"], "bug", "bug", $"{a.S.Card.Title}\n\nPR {prId}", $"bug@{prId}"));
        return proposals.Where(p => !a.Local.MentorsDone.Contains(p.Key));
    }

    // ---- D42, D51, presa in carico ----------------------------------------------------------------------------------

    /// <summary>D42: ogni on-hold non diretto passa prima dal responsabile, una volta per tipo di attesa (la chiave e il tipo, o il motivo).</summary>
    private static IEnumerable<AgentAction> ConvertHoldsForResponsabile(Env a, IEnumerable<AgentAction> actions)
    {
        foreach (var action in actions)
        {
            if (action is not PutOnHold h) { yield return action; continue; }
            var key = h.WaitKind ?? h.Reason;
            if (h.Direct || a.LastRole == "responsabile" || a.Local.PassesDone.Contains(key)) { yield return h; continue; }
            yield return new StartHoldReview(h.Reason, h.For, a.LastRole, key);
            yield return new LaunchSession("responsabile", "attesa", HoldAttachment(a, h));
        }
    }

    private static string HoldAttachment(Env a, PutOnHold h)
    {
        var lines = new List<string> { $"La card stava per andare in on-hold per una persona. Motivo: {h.Reason}" };
        if (a.LastRole is not null && !string.IsNullOrWhiteSpace(a.Last?.Text))
            lines.Add($"Ultima sessione ({a.LastRole}{(a.Last.Outcome is { } o ? $", esito {o}" : "")}):\n{a.Last.Text}");
        if (a.S.Run?.Url is { } run) lines.Add($"Run del deploy in Test: {run}");
        if (a.S.Pr?.LogUrl is { } build) lines.Add($"Build della PR: {build}");
        return string.Join("\n\n", lines);
    }

    /// <summary>Il responsabile ha finito una passata, un blocco o un bivio e nessuna regola sa come proseguire.</summary>
    private static bool ResponsabileWithoutFollowUp(Env a) =>
        a.LastRole == "responsabile" && a.Last is { IsFinished: true } l && l.Reason is "attesa" or "bloccato" or "bivio" &&
        a.Key != K.NeedsClarification && StartBlock(a) is null;

    /// <summary>
    /// D51: l'on-hold per il limite di rosse di fila (o per un secondo rilancia di dev) si toglie da solo quando la validazione della PR e verde.
    /// Mai per i giri di revisione o di collaudo, e mai senza un dato che lo dica.
    /// </summary>
    public static RemoveOnHold? HoldReleased(Snapshot s, DecisionContext ctx)
    {
        var l = s.Local;
        if (l.WaitingFor != "limite") return null;
        if (l.ReviewRounds >= ctx.Limits.ReviewRounds || l.TestRounds >= ctx.Limits.TestRounds) return null;
        var reds = l.RedInARow >= ctx.Limits.RedInARow || (l.Relaunches >= 1 && l.Of("dev")?.Outcome == "rilancia");
        return reds && s.Pr?.Validation == Validations.Green ? new RemoveOnHold("la validazione della PR ora e verde", "limite") : null;
    }

    /// <summary>Presa in carico: una card in uno stato con il ramo, senza niente nello stato locale di questo PC.</summary>
    private static bool ToAdopt(Env a) =>
        !a.IsClosing && a.Key is not null && K.WithBranch.Contains(a.Key) && a.Local.Branch is null && a.Local.Folder is null &&
        a.Local.PrId is null && a.LastRole is null && a.Local.LastSessionByRole.Count == 0;

    private static readonly Regex ForeignSession = new(@"^(?:\s|&nbsp;|<a\b[^>]*>[^<]*</a>|<[^>]*>|@)*\[smistatore\] Sessione \S+ (avviata|ripresa)", RegexOptions.Compiled);

    private static bool RecentForeignSession(Env a) =>
        a.S.NewComments.Any(c => ForeignSession.IsMatch(c.Text) && (a.Ctx.Now - c.When).TotalMinutes < a.Ctx.Limits.SilenceMinutes);

    private static IEnumerable<AgentAction> TaskAdded(Env a)
    {
        if (a.OpenTasks.Count == 0) return [];
        return [new MoveBack(K.InDevelopment, "C'e un task aperto aggiunto dopo lo sviluppo: la card torna In development"), new LaunchSession("dev", "taskAggiunto", null, false, a.FirstOpenTask)];
    }

    // ---- blocchi -------------------------------------------------------------------------------------------------

    /// <summary>Perche una card che potrebbe partire aspetta: predecessori non uniti, posto occupato nel repo o nel componente.</summary>
    private static BlockReason? StartBlock(Env a)
    {
        if (a.Path == "perduta") return new BlockReason("funzionalitaPerduta", Detail: a.Local.Destination ?? "develop");
        if (a.Key == K.InFeatureBranch)
            return a.Local.Folder is null || a.S.Pr?.Status == PrStatuses.Completed ? null : new BlockReason("inFeatureSenzaPrUnita", Detail: a.Local.Destination);
        if (a.Key == K.InReview) return EntryInTestBlock(a);
        if (a.Key == K.ReadyToMerge) return a.IsClosing ? ClosingCiBlock(a) : FeatureTestBlock(a);
        if (a.IsClosing && a.Key == K.DeployingToTest) return ClosingCiBlock(a);
        if (a.Key is not (K.New or K.Ready)) return null;
        var featureId = a.IsFeatureCard || a.IsClosing ? a.Feature!.Feature.Id : (int?)null;
        var waiting = a.S.Predecessors.Where(p => !PredecessorMerged(a.Ctx.Names, p, featureId)).Select(p => p.Id).ToList();
        var role = a.Key == K.New ? "responsabile" : a.IsClosing ? null : "dev";
        if (a.IsClosing)
        {
            // la card di chiusura aspetta tutte le sue sorelle, senza link Predecessor messi a mano
            if (a.Feature!.Siblings.Count == 0) return new BlockReason("senzaSorelle", role, Detail: a.Feature.Feature.Id.ToString());
            var all = SiblingsNotMerged(a).Select(x => x.Id).Concat(waiting).ToList();
            if (all.Count > 0) return new BlockReason("predecessori", role, "sorelle", all);
            return a.Key == K.Ready ? ClosingCiBlock(a) : null;
        }
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
        return TestSlotBlock(a, HumanTestRequested(a) ? null : "collaudatore");
    }

    /// <summary>
    /// Il posto in Test: per un componente con l'ambiente di collaudo (D59) uno degli ambientiCollaudo, comuni a tutti i componenti;
    /// altrimenti uno per componente (cardInTestPerComponente).
    /// </summary>
    private static BlockReason? TestSlotBlock(Env a, string? role)
    {
        if (a.S.Area?.TestEnvironment is not null)
        {
            var busy = (a.Ctx.CardsWithTestEnvironment ?? []).Where(x => x != a.Id).ToList();
            return busy.Count >= a.Ctx.Limits.TestEnvironments ? new BlockReason("limiteAmbienti", role, $"{busy.Count}/{a.Ctx.Limits.TestEnvironments}", busy) : null;
        }
        var component = a.S.Area?.Component ?? "";
        var others = Others(a.Ctx.InTestByComponent, component, a.Id);
        return others.Count >= a.Ctx.Limits.CardsInTestPerComponent ? new BlockReason("limiteTest", role, component, others) : null;
    }

    /// <summary>D52: una card della funzionalita non completa la sua PR mentre la card di chiusura e in collaudo: il ramo non cambia sotto.</summary>
    private static BlockReason? FeatureTestBlock(Env a)
    {
        if (!a.IsFeatureCard) return null;
        var closing = a.Ctx.Names.KeyOf(a.Feature!.ClosingState);
        return closing is not null && (K.InTest.Contains(closing) || closing == K.ReadyToMerge)
            ? new BlockReason("attesaCollaudoFunzionalita", Detail: a.Feature.ClosingState, Cards: [a.Feature.ClosingCardId]) : null;
    }

    /// <summary>D52: una card della funzionalita In feature branch, con la card di chiusura ancora in Draft e le sorelle tutte unite.</summary>
    private static BlockReason? ClosingInDraft(Env a)
    {
        if (a.Key != K.InFeatureBranch || !a.IsFeatureCard) return null;
        var f = a.Feature!;
        if (a.Ctx.Names.KeyOf(f.ClosingState) != K.Draft || f.Siblings.Count == 0 || SiblingsNotMerged(a).Count > 0) return null;
        return new BlockReason("chiusuraInBozza", Detail: $"sposta la card #{f.ClosingCardId} in New", Cards: [f.ClosingCardId]);
    }

    private static bool PredecessorMerged(StateNames names, Predecessor p, int? featureId = null) => names.KeyOf(p.State) switch
    {
        K.Releasing or K.Closed => true,
        // In feature branch vale come unita solo per una sorella della stessa Feature: solo lei parte dal ramo che la contiene
        K.InFeatureBranch => featureId is not null && p.ParentId == featureId,
        K.ReadyToRelease => p.PrId is not null && string.IsNullOrWhiteSpace(p.Folder),
        _ => false,
    };

    /// <summary>D60: pausa (della card o della sua Feature) o card nuova senza una Feature aperta come padre.</summary>
    public static BlockReason? PriorityStop(Card card, DecisionContext ctx)
    {
        if (ctx.Names.PausedTag is { } paused && card.Tags.Contains(paused, StringComparer.OrdinalIgnoreCase)) return new BlockReason("pausa");
        if (ctx.Features is null) return null;
        var feature = card.ParentId is { } p && ctx.Features.TryGetValue(p, out var f) ? f : null;
        if (feature is not null && feature.HasTag(ctx.Names.PausedTag)) return new BlockReason("pausa", Detail: feature.Title, Cards: [feature.Id]);
        // in New serve una Feature aperta: un padre che non lo e (Epic, Feature chiusa o fuori dalle aree) vale come nessun padre
        if (feature is null && ctx.Names.KeyOf(card.State) == K.New) return new BlockReason("senzaFeature");
        return null;
    }

    public static bool IsPaused(Card card, DecisionContext ctx) => PriorityStop(card, ctx) is { Type: "pausa" };

    /// <summary>D51, D60: la pausa dopo il limite di token, la finestra di 5 ore oltre la sua soglia, la riserva settimanale.</summary>
    public static BlockReason? QuotaBlock(DecisionContext ctx)
    {
        if (ctx.Quota is not { } q) return null;
        if (q.PauseUntil is { } pause && pause > ctx.Now) return new BlockReason("quota", Detail: $"limite di token fino a {pause:o}");
        var o = ctx.QuotaOverrides;
        // la soglia sulle 5 ore: quella della vista vale fino al reset della finestra; ignorare la riserva settimanale non la salta
        var five = o?.FiveHourThreshold is { } ft && o.FiveHourUntil > ctx.Now ? ft : ctx.Limits.FiveHourQuotaThreshold;
        if (five is { } t5 && q.FiveHourUtilization is { } u5 && u5 >= t5 && q.FiveHourResetsAt is { } r5 && r5 > ctx.Now)
            return new BlockReason("quota", Detail: $"finestra di 5 ore al {u5:P0} (soglia {t5:P0}) fino a {r5:o}");
        var weeklyValid = o?.WeeklyUntil > ctx.Now;
        var weekly = weeklyValid && o!.WeeklyThreshold is { } wt ? wt : ctx.Limits.WeeklyQuotaThreshold;
        var ignore = weeklyValid && o!.IgnoreWeeklyReserve;
        if (!ignore && q.WeeklyUtilization is { } use && use >= weekly && q.WeeklyResetsAt is { } reset && reset > ctx.Now)
            return new BlockReason("quota", Detail: $"riserva settimanale al {use:P0} (soglia {weekly:P0}) fino a {reset:o}");
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

    /// <summary>Senza Test: il tag no-test-deploy, nessuna pipeline di deploy, o una card della funzionalita (D52: va in Test la funzionalita intera).</summary>
    private static bool WithoutTest(Env a) =>
        (a.Ctx.Names.NoTestTag is { } t && a.S.Card.Tags.Contains(t, StringComparer.OrdinalIgnoreCase)) ||
        a.S.Area?.DeployPipeline is null || a.IsFeatureCard;

    private static bool HumanTestRequested(Env a) =>
        a.Ctx.Names.HumanTestTag is { } t && a.S.Card.Tags.Contains(t, StringComparer.OrdinalIgnoreCase);

    // un run salvato e un run di pipeline o un ambiente di collaudo (D59, Test-RunSalvato)
    private static bool RunValid(Env a) => (a.Local.RunId is not null || a.Local.TestProject is not null) && a.Local.RunAfterRev is { } r && a.Entry is not null && r == a.Entry.Rev;

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
        public FeatureContext? Feature => S.Feature;
        public bool IsClosing => Feature is { Error: null, IsClosing: true };
        public bool IsFeatureCard => Path == "funzionalita";

        /// <summary>
        /// D52: la strada della card. "funzionalita" se e una card (non di chiusura) di una funzionalita valida; "isolata" se no; "perduta" se
        /// la card aveva gia cominciato sul ramo della funzionalita (o e In feature branch) e la funzionalita non c'e piu.
        /// </summary>
        public string Path
        {
            get
            {
                var valid = Feature is { Error: null, IsClosing: false };
                var traced = Local.Branch is not null || Local.Folder is not null || Local.PrId is not null || Local.Destination is not null;
                if (Key is K.New or K.NeedsClarification or K.Ready || !traced) return valid ? "funzionalita" : "isolata";
                var onBranch = (Local.Destination ?? "develop") != "develop";
                if (onBranch && valid) return "funzionalita";
                var running = Key is K.InDevelopment or K.InReview or K.DeployingToTest or K.AutomatedTest or K.HumanTest or K.ReadyToMerge or K.InFeatureBranch;
                return running && (onBranch || Key == K.InFeatureBranch) ? "perduta" : "isolata";
            }
        }
    }
}
