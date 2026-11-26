using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>D42 (passata del responsabile), D51 (on-hold sciolti e riprese automatiche), presa in carico da un altro PC.</summary>
public class HoldReviewTests
{
    private readonly DecisionEngine _e = new();
    private Decision D(CardBuilder b, DecisionContext? c = null) => _e.Decide(b.Build(), c ?? Fx.Ctx());
    private static string[] Kinds(Decision d) => d.Actions.Select(a => a.Kind).ToArray();

    [Fact]
    public void Un_on_hold_passa_prima_dal_responsabile_con_il_motivo_e_l_ultima_sessione_una_volta_per_tipo()
    {
        var b = Fx.Card(K.InDevelopment).Pr(Validations.Red).Last(Fx.Session("dev", "fatto", text: "ho provato")).With(s => s.RedInARow = 3);
        var d = D(b);
        Assert.Equal(["AvviaPassataAttesa", "LanciaSessione"], Kinds(d));
        var r = (StartHoldReview)d.Actions[0];
        Assert.Equal(("troppe validazioni rosse di fila", "limite", "dev"), (r.Reason, r.For, r.Role));
        var l = (LaunchSession)d.Actions[1];
        Assert.Equal(("responsabile", "attesa"), (l.Role, l.Reason));
        Assert.Contains("Ultima sessione (dev, esito fatto):\nho provato", l.Attachment);
        Assert.Contains("Build della PR: https://log/7", l.Attachment);
        // gia esaminata: l'on-hold e diretto
        Assert.IsType<PutOnHold>(Assert.Single(D(b.With(s => s.PassesDone.Add(r.Key))).Actions));
    }

    [Fact]
    public void Un_on_hold_diretto_o_dopo_il_responsabile_non_passa_da_lui()
    {
        var direct = Fx.Card(K.InDevelopment).Earlier(Fx.Session("responsabile", "fatto", reason: "bloccato", minutesAfterT0: 20)).Last(Fx.Session("dev", "bloccato", reason: "decisione"));
        Assert.True(Assert.IsType<PutOnHold>(Assert.Single(D(direct).Actions)).Direct);
        var afterResp = Fx.Card(K.InDevelopment).Last(Fx.Session("responsabile", "bloccato", reason: "bloccato"));
        Assert.IsType<PutOnHold>(Assert.Single(D(afterResp).Actions));
    }

    private static CardBuilder Reviewed(string outcome, string state = K.InDevelopment) =>
        Fx.Card(state).Pr(Validations.Red).Earlier(Fx.Session("dev", "fatto", minutesAfterT0: 10)).Last(Fx.Session("responsabile", outcome, reason: "attesa", minutesAfterT0: 30))
            .With(s => { s.RedInARow = 3; s.HoldInReview = new HoldReview("troppe validazioni rosse di fila", "limite", "dev", "troppe validazioni rosse di fila"); s.PassesDone.Add("troppe validazioni rosse di fila"); });

    [Fact]
    public void Il_responsabile_ha_sistemato_la_causa_si_riparte_come_se_una_persona_avesse_tolto_l_on_hold()
    {
        var d = D(Reviewed("fatto"));
        Assert.Equal("ChiudiPassataAttesa", d.Actions[0].Kind);
        Assert.Equal("dev", ((CloseHoldReview)d.Actions[0]).Role);
        // per 'limite' i contatori ripartono e la rossa torna a dev
        Assert.Contains(d.Actions, a => a is ResetCounters);
        Assert.Contains(d.Actions, a => a is LaunchSession { Role: "dev", Reason: "rossa" });
    }

    [Fact]
    public void Il_responsabile_bloccato_o_con_domande_fuori_da_Needs_clarification_va_in_on_hold_con_il_motivo_di_prima()
    {
        var d = D(Reviewed("bloccato"));
        Assert.Equal(["ChiudiPassataAttesa", "MettiInAttesa"], Kinds(d));
        Assert.Contains("la sua diagnosi e nel commento", ((PutOnHold)d.Actions[1]).Reason);
        Assert.Contains("ha domande per te", ((PutOnHold)D(Reviewed("domande")).Actions[1]).Reason);
        Assert.Equal(["ChiudiPassataAttesa"], Kinds(D(Reviewed("domande", K.NeedsClarification))));
    }

    [Fact]
    public void Una_persona_che_toglie_l_on_hold_azzera_le_passate_lo_smistatore_e_la_quota_no()
    {
        var b = Fx.Card(K.InReview).WaitingFor("limite").Last(Fx.Session("reviewer", "bloccante")).With(s => s.PassesDone.Add("x"));
        Assert.Equal("AzzeraPassateAttesa", D(b).Actions[0].Kind);
        Assert.DoesNotContain(D(b.With(s => s.ResumedBySystem = true)).Actions, a => a is ResetHoldReviews);
    }

    [Fact]
    public void La_validazione_tornata_verde_toglie_da_sola_l_on_hold_per_le_rosse_di_fila_non_quello_per_i_giri_di_revisione()
    {
        var reds = Fx.Card(K.InDevelopment).OnHold("limite").Pr(Validations.Green).With(s => s.RedInARow = 3);
        var r = Assert.IsType<RemoveOnHold>(Assert.Single(D(reds).Actions));
        Assert.Equal(("la validazione della PR ora e verde", "limite"), (r.Cause, r.For));
        Assert.Equal("onHold", D(Fx.Card(K.InDevelopment).OnHold("limite").Pr(Validations.Red).With(s => s.RedInARow = 3)).Reason!.Type);
        Assert.Equal("onHold", D(Fx.Card(K.InReview).OnHold("limite").Pr(Validations.Green).With(s => { s.RedInARow = 3; s.ReviewRounds = 2; })).Reason!.Type);
    }

    [Fact]
    public void Una_sessione_chiusa_dallo_smistatore_si_riprende_da_sola_e_il_messaggio_lo_dice()
    {
        var l = Assert.IsType<LaunchSession>(Assert.Single(D(Fx.Card(K.InDevelopment).NoHistory().WaitingFor("sessione").With(s => s.ResumedBySystem = true).Last(Fx.Session("dev", null, finished: false))).Actions));
        Assert.Equal(("ripresa", "dopoRipresaAutomatica"), (l.Reason, l.ResumeKind));
        Assert.Contains("chiusa dallo smistatore", Orchestration.Dispatcher.ComposeMessage(l, Fx.Card(K.InDevelopment).Build()));
        Assert.Equal("dopoQuota", ((LaunchSession)D(Fx.Card(K.InDevelopment).NoHistory().WaitingFor("quota").Last(Fx.Session("dev", null))).Actions[0]).ResumeKind);
    }

    [Fact]
    public void Una_card_arrivata_da_un_altro_PC_si_prende_in_carico_ma_non_se_la_sua_sessione_e_partita_da_poco()
    {
        var adopt = Fx.Card(K.InReview).NoBranch();
        Assert.IsType<AdoptCard>(Assert.Single(D(adopt).Actions));
        var recent = Fx.Card(K.InReview).NoBranch().AgentComment("[smistatore] Sessione abc avviata: ruolo reviewer, cartella x.");
        Assert.Empty(D(recent).Actions);
        // una card della funzionalita si riprende dal ramo della funzionalita
        var feature = Fx.Card(K.InDevelopment).NoBranch().InFeature(Fx.Feature());
        var a = Assert.IsType<AdoptCard>(Assert.Single(D(feature).Actions));
        Assert.Equal(("feature/f10-preventivi", true), (a.Base, a.FeatureCard));
    }
}

public class SessionCloseTests
{
    private static World OneRunning(SessionResult result, int autoResumes = 0)
    {
        var w = new World();
        w.Add(42, K.InDevelopment);
        w.State[42] = new CardLocalState { Branch = "b", Folder = "/wt/42", LastRole = "dev", RunningSession = "s9", AutoResumes = autoResumes };
        w.State[42].LastSessionByRole["dev"] = Fx.Session("dev", null, finished: false);
        w.Results["s9"] = result;
        return w;
    }

    [Fact]
    public async Task Una_sessione_senza_risultato_la_prima_volta_si_riprende_da_sola_senza_on_hold()
    {
        var w = OneRunning(new SessionResult(null, "x", NoResultCause: "silenzio"));
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.DoesNotContain(w.Writes, x => x.StartsWith("tag"));
        Assert.Contains(w.Writes, x => x.Contains("La riprendo da sola, una volta"));
        var s = w.Started.Single();
        Assert.True(s.Resume);
        Assert.Contains("chiusa dallo smistatore", s.Message);
        Assert.Equal(1, w.State[42].AutoResumes);
    }

    [Fact]
    public async Task La_seconda_volta_va_in_on_hold_con_la_causa_e_il_gesto_predefinito()
    {
        var w = OneRunning(new SessionResult(null, "x", NoResultCause: "morta"), autoResumes: 1);
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Contains($"tag 42 {Fx.Names.OnHoldTag}", w.Writes);
        Assert.Equal(("morta", "predefinita"), (w.State[42].HoldCause, w.State[42].OnHoldIndications!.Source));
        Assert.Empty(w.Started);
    }

    [Fact]
    public async Task Una_sessione_fallita_va_in_on_hold_e_non_si_riprova()
    {
        var w = OneRunning(new SessionResult(null, "errore", Failed: true));
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Contains(w.Writes, x => x.Contains("e fallita"));
        Assert.Equal("fallita", w.State[42].HoldCause);
    }

    [Fact]
    public async Task La_presa_in_carico_ricrea_il_worktree_dal_ramo_pubblicato()
    {
        var w = new World();
        w.Add(42, K.InReview);
        w.RemoteBranches[42] = "feature/42-card";
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Contains("worktree remoto 42 feature/42-card", w.Writes);
        Assert.Equal(("feature/42-card", "/wt/42"), (w.State[42].Branch, w.State[42].Folder));
        Assert.Contains(w.Writes, x => x.StartsWith("commento 42 [smistatore] Card presa in carico da Titolare"));
    }

    [Fact]
    public async Task Rilasciata_altrove_senza_ramo_si_ricorda_la_PR_collegata_e_non_fa_altro()
    {
        var w = new World { LinkedPr = 77 };
        w.Add(42, K.ReadyToRelease);
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Equal(77, w.State[42].PrId);
        Assert.Empty(w.Writes);
    }
}
