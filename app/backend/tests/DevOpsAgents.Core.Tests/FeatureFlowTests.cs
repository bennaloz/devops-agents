using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>D52: le card della funzionalita e la card di chiusura. I casi dei Describe D52 di Decisioni.Tests.ps1.</summary>
public class FeatureCardTests
{
    private readonly DecisionEngine _e = new();
    private Decision D(CardBuilder b) => _e.Decide(b.Build(), Fx.Ctx());
    private static string[] Kinds(Decision d) => d.Actions.Select(a => a.Kind).ToArray();
    private static FeatureContext F(params (int, string)[] sib) => Fx.Feature(siblings: sib);

    [Fact]
    public void Senza_ramo_e_con_la_Feature_New_crea_il_ramo_il_worktree_dalla_base_attiva_la_Feature_sposta_e_lancia_dev()
    {
        var f = Fx.Feature(branch: null, feature: Fx.Feature10 with { State = "New" });
        var d = D(Fx.Card(K.Ready).InFeature(f));
        Assert.Equal(["CreaRamoFunzionalita", "CreaWorktree", "AggiornaFeature", "SpostaCard", "LanciaSessione"], Kinds(d));
        Assert.Equal((null, true), (((CreateWorktree)d.Actions[1]).Base, ((CreateWorktree)d.Actions[1]).FeatureCard));
        Assert.Equal("featureAttiva", ((UpdateFeature)d.Actions[2]).State);
    }

    [Fact]
    public void Con_il_ramo_su_origin_e_la_Feature_gia_Active_solo_il_worktree_dal_ramo_della_funzionalita()
    {
        var d = D(Fx.Card(K.Ready).InFeature(F()));
        Assert.Equal(["CreaWorktree", "SpostaCard", "LanciaSessione"], Kinds(d));
        Assert.Equal("feature/f10-preventivi", ((CreateWorktree)d.Actions[0]).Base);
    }

    [Theory]
    [InlineData(K.Ready)]
    [InlineData(K.InDevelopment)]
    public void Una_lettura_della_funzionalita_fallita_ferma_la_card_con_il_testo_dell_errore(string state)
    {
        var d = D(Fx.Card(state).InFeature(FeatureContext.Failed("timeout")));
        Assert.Empty(d.Actions);
        Assert.Equal(("funzionalitaIllegibile", "timeout"), (d.Reason!.Type, d.Reason.Detail));
    }

    [Fact]
    public void Una_card_della_funzionalita_va_in_Ready_to_merge_anche_se_il_componente_ha_un_deploy_in_Test()
    {
        var d = D(Fx.Card(K.InReview).InFeature(F()).With(s => { s.Branch = "feature/42-x"; s.Destination = "feature/f10-preventivi"; }).Last(Fx.Session("reviewer", "superata")));
        Assert.Equal(K.ReadyToMerge, Assert.IsType<MoveCard>(Assert.Single(d.Actions)).State);
    }

    private static CardBuilder Merge(string closingState) =>
        Fx.Card(K.ReadyToMerge).InFeature(Fx.Feature(closingState: closingState)).With(s => { s.Branch = "feature/42-x"; s.Destination = "feature/f10-preventivi"; });

    [Theory]
    [InlineData(K.DeployingToTest)]
    [InlineData(K.AutomatedTest)]
    [InlineData(K.HumanTest)]
    [InlineData(K.ReadyToMerge)]
    public void Con_la_card_di_chiusura_in_prova_la_PR_non_si_completa(string closing)
    {
        var d = D(Merge(closing).Pr(Validations.Green));
        Assert.Empty(d.Actions);
        Assert.Equal(("attesaCollaudoFunzionalita", 90), (d.Reason!.Type, d.Reason.Cards![0]));
    }

    [Fact]
    public void Con_la_chiusura_fuori_dalla_prova_la_PR_si_completa_e_completata_va_In_feature_branch()
    {
        Assert.IsType<CompletePr>(D(Merge(K.New).Pr(Validations.Green)).Actions[0]);
        Assert.Equal(K.InFeatureBranch, ((MoveCard)D(Merge(K.AutomatedTest).Pr(Validations.None, PrStatuses.Completed)).Actions[0]).State);
        Assert.Equal(["RiportaIndietro", "LanciaSessione"], Kinds(D(Merge(K.AutomatedTest).Pr(Validations.Conflicts))));
    }

    private static CardBuilder InFeatureBranch(string closing, (int, string)[]? sib = null, string? folder = "/wt/42") =>
        Fx.Card(K.InFeatureBranch).InFeature(Fx.Feature(closingState: closing, siblings: sib ?? [])).Pr(Validations.None, PrStatuses.Completed)
            .With(s => { s.Branch = "feature/42-x"; s.Destination = "feature/f10-preventivi"; s.Folder = folder; });

    [Fact]
    public void In_feature_branch_toglie_il_worktree_e_segue_la_chiusura_rilasciata()
    {
        Assert.Equal(["RimuoviWorktree"], Kinds(D(InFeatureBranch(K.AutomatedTest))));
        Assert.Empty(D(InFeatureBranch(K.AutomatedTest, folder: null)).Actions);
        Assert.Equal(["RimuoviWorktree", "SpostaCard"], Kinds(D(InFeatureBranch(K.ReadyToRelease))));
        Assert.Equal(K.ReadyToRelease, ((MoveCard)D(InFeatureBranch(K.Closed, folder: null)).Actions[0]).State);
    }

    [Fact]
    public void La_chiusura_in_Draft_con_tutte_le_sorelle_unite_dice_di_spostarla_in_New()
    {
        var d = D(InFeatureBranch(K.Draft, [(43, K.InFeatureBranch)], folder: null));
        Assert.Equal(("chiusuraInBozza", "sposta la card #90 in New"), (d.Reason!.Type, d.Reason.Detail));
        Assert.Null(D(InFeatureBranch(K.Draft, [(43, K.InDevelopment)], folder: null)).Reason);
    }

    [Theory]
    [InlineData(K.InDevelopment)]
    [InlineData(K.ReadyToMerge)]
    [InlineData(K.InFeatureBranch)]
    public void Sul_ramo_della_funzionalita_e_senza_funzionalita_la_card_e_perduta_mai_isolata(string state)
    {
        var d = D(Fx.Card(state).Pr(Validations.Green).Last(Fx.Session("dev", "fatto")).With(s => { s.Branch = "feature/42-x"; s.Destination = "feature/f10-preventivi"; }));
        Assert.Empty(d.Actions);
        Assert.Equal("funzionalitaPerduta", d.Reason!.Type);
    }

    [Fact]
    public void Una_card_isolata_con_la_PR_verso_develop_legata_dopo_a_una_Feature_resta_isolata()
    {
        var d = D(Fx.Card(K.InReview).InFeature(F()).With(s => { s.Branch = "feature/42-x"; s.Destination = "develop"; }).Last(Fx.Session("reviewer", "superata")));
        Assert.Equal(K.DeployingToTest, ((MoveCard)d.Actions[0]).State);
    }

    [Fact]
    public void Un_predecessore_In_feature_branch_e_unito_solo_per_una_sorella_della_stessa_Feature()
    {
        Predecessor P(int? parent) => new(30, Fx.N(K.InFeatureBranch), parent);
        var sister = Fx.Card(K.Ready).InFeature(F()).Build() with { Predecessors = [P(10)] };
        Assert.NotEmpty(_e.Decide(sister, Fx.Ctx()).Actions);
        var other = Fx.Card(K.Ready).InFeature(F()).Build() with { Predecessors = [P(11)] };
        Assert.Equal("predecessori", _e.Decide(other, Fx.Ctx()).Reason!.Type);
        var isolated = Fx.Card(K.Ready).Build() with { Predecessors = [P(10)] };
        Assert.Equal("predecessori", _e.Decide(isolated, Fx.Ctx()).Reason!.Type);
    }
}

public class ClosingCardTests
{
    private readonly DecisionEngine _e = new();
    private Decision D(CardBuilder b) => _e.Decide(b.Build(), Fx.Ctx());
    private static string[] Kinds(Decision d) => d.Actions.Select(a => a.Kind).ToArray();
    private static FeatureContext C(string? branch = "feature/f10-preventivi", params (int, string)[] sib) => Fx.Feature(closing: true, branch: branch, siblings: sib);
    private static readonly (int, string)[] Merged = [(43, K.InFeatureBranch), (44, K.ReadyToRelease)];

    private static CardBuilder Closing(string state, (int, string)[]? sib = null) =>
        Fx.Card(state).InFeature(C(sib: sib ?? Merged)).With(s => { s.Branch = "feature/f10-preventivi"; s.Destination = "develop"; });

    [Fact]
    public void Senza_sorelle_non_parte()
    {
        var d = D(Fx.Card(K.New).From(K.Draft).InFeature(C()));
        Assert.Equal(("senzaSorelle", "responsabile"), (d.Reason!.Type, d.Reason.Role));
    }

    [Fact]
    public void Con_una_sorella_non_unita_aspetta_e_con_le_sorelle_unite_parte_il_responsabile()
    {
        var d = D(Fx.Card(K.New).From(K.Draft).InFeature(C(sib: [(43, K.InDevelopment), (44, K.InFeatureBranch)])));
        Assert.Equal(("predecessori", "sorelle"), (d.Reason!.Type, d.Reason.Detail));
        Assert.Equal([43], d.Reason.Cards!);
        Assert.Equal("responsabile", ((LaunchSession)D(Fx.Card(K.New).From(K.Draft).InFeature(C(sib: Merged))).Actions[0]).Role);
    }

    [Theory]
    [InlineData(K.DeployingToTest)]
    [InlineData(K.AutomatedTest)]
    [InlineData(K.HumanTest)]
    [InlineData(K.ReadyToMerge)]
    public void Una_sorella_non_unita_fa_tornare_la_chiusura_in_Ready_to_develop(string state)
    {
        var b = Assert.IsType<MoveBack>(Assert.Single(D(Closing(state, [(43, K.InFeatureBranch), (45, K.Ready)])).Actions));
        Assert.Equal(K.Ready, b.State);
        Assert.Contains("#45", b.Reason);
    }

    [Fact]
    public void Senza_il_ramo_salvato_lo_imposta_dalla_funzionalita_e_senza_ramo_su_origin_va_in_attesa()
    {
        var d = D(Fx.Card(K.Ready).InFeature(C(sib: Merged)));
        Assert.Equal("feature/f10-preventivi", Assert.IsType<SetClosingBranch>(Assert.Single(d.Actions)).Branch);
        Fx.Hold(D(Fx.Card(K.Ready).InFeature(C(branch: null, sib: Merged))));
    }

    [Fact]
    public void In_Ready_to_develop_apre_la_PR_verso_develop_e_verde_va_al_deploy_senza_dev_ne_reviewer()
    {
        Assert.IsType<OpenPr>(Assert.Single(D(Closing(K.Ready)).Actions));
        Assert.Equal(K.DeployingToTest, ((MoveCard)Assert.Single(D(Closing(K.Ready).Pr(Validations.Green)).Actions)).State);
        Assert.IsType<RequeueValidation>(Assert.Single(D(Closing(K.Ready).Pr(Validations.Red)).Actions));
    }

    [Fact]
    public void La_PR_in_conflitto_crea_una_Bug_allinea_develop_una_sola_per_testa()
    {
        var a = Assert.IsType<CreateAlignDevelop>(Assert.Single(D(Closing(K.Ready).Pr(Validations.Conflicts)).Actions));
        Assert.Equal((10, "feature/f10-preventivi", "HEAD1"), (a.FeatureId, a.Branch, a.Commit));
        // la Bug per quella testa esiste gia (commento dello smistatore, da ogni PC): aspetta come una sorella non unita
        var bug = new Sibling(77, Fx.N(K.InDevelopment), [Fx.Names.AlignTag!]);
        var withBug = Fx.Feature(closing: true, siblings: [(43, K.InFeatureBranch)]) with { Siblings = [new Sibling(43, Fx.N(K.InFeatureBranch), []), bug] };
        var waiting = Fx.Card(K.Ready).InFeature(withBug).With(s => { s.Branch = "feature/f10-preventivi"; s.Destination = "develop"; })
            .Pr(Validations.Conflicts).OldComment("x", "[smistatore] Allinea-develop @HEAD1 -> Bug 77");
        var d = D(waiting);
        Assert.Empty(d.Actions);
        Assert.Equal([77], d.Reason!.Cards!);
        // la Bug per quella testa c'era ma non c'e piu (rimossa senza unirla): una persona decide
        var gone = Closing(K.Ready, [(43, K.InFeatureBranch)]).Pr(Validations.Conflicts).OldComment("x", "[smistatore] Allinea-develop @HEAD1 -> Bug 77");
        Assert.True(Fx.Hold(D(gone)).Direct);
    }

    [Fact]
    public void La_CI_rossa_con_errori_di_codice_va_al_responsabile_una_volta_per_build_poi_a_una_persona()
    {
        var l = Assert.IsType<LaunchSession>(Assert.Single(D(Closing(K.Ready).Pr(Validations.Red).BuildErrors("Failed Test1")).Actions));
        Assert.Equal(("responsabile", "ciRossa", "7"), (l.Role, l.Reason, l.Build));
        Assert.Contains("Failed Test1", l.Attachment);
        Assert.Empty(D(Closing(K.Ready).Pr(Validations.Red).BuildErrors("x").With(s => s.CiRedHandled = "7")).Actions);
        var after = Closing(K.Ready).Pr(Validations.Red).BuildErrors("x").With(s => s.CiRedHandled = "7").Last(Fx.Session("responsabile", "fatto", reason: "ciRossa"));
        Assert.True(Fx.Hold(D(after)).Direct);
    }

    [Fact]
    public void Il_collaudatore_della_chiusura_lavora_nel_worktree_in_sola_lettura_e_con_human_test_dopo_va_dalla_persona()
    {
        var test = Closing(K.AutomatedTest).From(K.DeployingToTest);
        Assert.True(((LaunchSession)D(test).Actions[0]).ClosingWorktree);
        var passed = Closing(K.AutomatedTest).From(K.DeployingToTest).Tag(Fx.Names.HumanTestTag!).Last(Fx.Session("collaudatore", "superata", minutesAfterT0: 70));
        Assert.Equal(K.HumanTest, ((MoveCard)D(passed).Actions[0]).State);
    }

    [Fact]
    public void A_PR_completata_Ready_to_deploy_test_e_la_Feature_Resolved_da_chiudere_con_la_card()
    {
        var d = D(Closing(K.ReadyToMerge).Pr(Validations.None, PrStatuses.Completed));
        Assert.Equal(["SpostaCard", "AggiornaFeature"], Kinds(d));
        Assert.Equal(K.ReadyToDeployTest, ((MoveCard)d.Actions[0]).State);
        var u = (UpdateFeature)d.Actions[1];
        Assert.Equal(("featureRisolta", true), (u.State, u.CloseLater));
        var closed = Fx.Feature(closing: true, feature: Fx.Feature10 with { State = "Closed" }, siblings: Merged);
        Assert.Equal(["SpostaCard"], Kinds(D(Fx.Card(K.ReadyToMerge).InFeature(closed).With(s => s.Branch = "b").Pr(Validations.None, PrStatuses.Completed))));
    }

    [Fact]
    public void Il_merge_si_ferma_se_il_ramo_e_andato_avanti_dopo_il_deploy_e_al_secondo_ritorno_per_la_stessa_testa_va_in_attesa()
    {
        var moved = Closing(K.ReadyToMerge).Pr(Validations.Green, head: "NUOVO").Run("completed", "succeeded").With(s => s.RunId = 70);
        var back = Assert.IsType<MoveBack>(Assert.Single(D(moved).Actions));
        Assert.Equal((K.Ready, "NUOVO"), (back.State, back.Commit));
        Fx.Hold(D(moved.With(s => s.ReturnCommit = "NUOVO")));
    }

    [Fact]
    public void La_correzione_scritta_dal_responsabile_diventa_una_Bug_una_volta_sola()
    {
        const string text = "[responsabile] Correzione: tecnico\nTitolo: Il totale non somma l IVA\n\nIl totale va calcolato con l IVA.\n— scritto da Claude (responsabile)";
        var c = Assert.IsType<CreateCorrection>(Assert.Single(D(Closing(K.AutomatedTest).OldComment("Titolare", text)).Actions));
        Assert.Equal(("tecnico", "Il totale non somma l IVA", "Il totale va calcolato con l IVA.", 10, 42), (c.Nature, c.Title, c.Description, c.FeatureId, c.ClosingCardId));
        Assert.DoesNotContain(D(Closing(K.AutomatedTest).OldComment("Titolare", text).With(s => s.CorrectionsDone.Add(c.Key))).Actions, a => a is CreateCorrection);
        // su una card isolata un commento cosi non fa Bug
        Assert.DoesNotContain(D(Fx.Card(K.AutomatedTest).OldComment("Titolare", text)).Actions, a => a is CreateCorrection);
    }
}

public class FeatureDispatcherTests
{
    private static World WithFeature(out FeatureInfo f)
    {
        var w = new World();
        f = new FeatureInfo(10, "Preventivi", "New", [], "DevOps.Agents\\AI\\Stime", 1000);
        w.Features.Add(f);
        return w;
    }

    private static Card Child(World w, int id, string state, IEnumerable<string>? extraTags = null)
    {
        w.Add(id, state);
        var i = w.Cards.FindIndex(c => c.Id == id);
        w.Cards[i] = w.Cards[i] with { ParentId = 10, Tags = w.Cards[i].Tags.Concat(extraTags ?? []).ToList() };
        if (!w.Children.TryGetValue(10, out var list)) w.Children[10] = list = [];
        list.Add(w.Cards[i]);
        return w.Cards[i];
    }

    [Fact]
    public async Task La_prima_card_della_funzionalita_crea_e_pubblica_il_ramo_il_worktree_parte_da_li_e_la_Feature_diventa_Active()
    {
        var w = WithFeature(out _);
        Child(w, 42, K.Ready);
        Child(w, 90, K.Draft, [Fx.Names.ClosingTag!]);
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Equal(["ramo feature/f10-x", "worktree 42 da feature/f10-x", $"stato 10 {Fx.N("featureAttiva")}", $"stato 42 {Fx.N(K.InDevelopment)}",
            "commento 42 [smistatore] Sessione s1 avviata: ruolo dev, cartella /wt/42."], w.Writes);
        Assert.Equal("feature/f10-x", w.State[42].Destination);
    }

    [Fact]
    public async Task Una_Feature_senza_card_di_chiusura_raggruppa_soltanto_le_card_vanno_in_develop_una_per_una()
    {
        var w = WithFeature(out _);
        Child(w, 42, K.Ready);
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Equal("worktree 42", w.Writes[0]);
        Assert.Equal("develop", w.State[42].Destination);
    }

    [Fact]
    public async Task La_card_di_chiusura_scrive_la_correzione_come_Bug_figlia_tecnica_in_New_assegnata_e_lo_segna_sulla_card()
    {
        var w = WithFeature(out _);
        Child(w, 43, K.InFeatureBranch);
        var closing = Child(w, 90, K.AutomatedTest, [Fx.Names.ClosingTag!]);
        w.Branches.Add("feature/f10-x");
        w.Comments[90] = [new Comment(7, "Titolare", "[responsabile] Correzione: tecnico\nTitolo: Totale senza IVA\n\nVa sommata l IVA.", Fx.T0)];
        w.State[90] = new CardLocalState { Branch = "feature/f10-x", Destination = "develop" };
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        var bug = Assert.Single(w.Bugs);
        Assert.Equal(("Totale senza IVA", 10, K.New, "titolare@example.invalid"), (bug.Title, bug.ParentId, bug.InitialState, bug.AssignedTo));
        Assert.Contains("Va sommata l IVA.", bug.Description);
        Assert.Contains("commento 90 [smistatore] Correzione #7 -> Bug 501", w.Writes);
        Assert.Equal(["7"], w.State[90].CorrectionsDone);
    }

    [Fact]
    public async Task Il_collaudatore_della_chiusura_parte_nel_worktree_in_sola_lettura_del_ramo_della_funzionalita()
    {
        var w = WithFeature(out _);
        Child(w, 43, K.InFeatureBranch);
        Child(w, 90, K.AutomatedTest, [Fx.Names.ClosingTag!]);
        w.Branches.Add("feature/f10-x");
        w.History[90] = [new StateChange(10, Fx.N(K.DeployingToTest), Fx.N(K.AutomatedTest), Fx.T0)];
        w.State[90] = new CardLocalState { Branch = "feature/f10-x", Destination = "develop" };
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Contains("chiusura 90 feature/f10-x", w.Writes);
        var s = Assert.Single(w.Started);
        Assert.Equal(("collaudatore", "/wt/90"), (s.Role, s.WorkingFolder));
    }

    [Fact]
    public async Task Una_lettura_della_Feature_che_fallisce_ferma_solo_le_sue_card_con_il_motivo()
    {
        var w = WithFeature(out _);
        Child(w, 42, K.Ready);
        Child(w, 90, K.Draft, [Fx.Names.ClosingTag!]);
        w.Branches.AddRange(["feature/f10-a", "bugfix/f10-b"]);
        var r = await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Equal("funzionalitaIllegibile", r.Cards.Single(c => c.Id == 42).Reason!.Type);
        Assert.Contains("piu di un ramo", r.Cards.Single(c => c.Id == 42).Reason!.Detail);
    }
}
