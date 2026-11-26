using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>I casi di Decisioni.Tests.ps1 per le card isolate: stesso stato in ingresso, stesse azioni in uscita.</summary>
public class DecisionEngineTests
{
    private readonly DecisionEngine _engine = new();

    private Decision Decide(CardBuilder b, DecisionContext? ctx = null) => _engine.Decide(b.Build(), ctx ?? Fx.Ctx());

    private static string[] Kinds(Decision d) => d.Actions.Select(a => a.Kind).ToArray();

    // ---- filtri d'ingresso ------------------------------------------------------------------------------------------

    [Theory]
    [InlineData(K.New)]
    [InlineData(K.Ready)]
    [InlineData(K.InDevelopment)]
    [InlineData(K.ReadyToMerge)]
    public void Senza_il_tag_agents_non_fa_nulla_in_nessuno_stato(string state)
    {
        var d = Decide(Fx.Card(state).NoAgentsTag());
        Assert.Empty(d.Actions);
        Assert.Null(d.Reason);
    }

    [Fact]
    public void On_hold_nessuna_azione_e_il_motivo_porta_inAttesaPer()
    {
        var d = Decide(Fx.Card(K.InDevelopment).OnHold("limite"));
        Assert.Empty(d.Actions);
        Assert.Equal("onHold", d.Reason!.Type);
        Assert.Equal("limite", d.Reason.Detail);
    }

    [Fact]
    public void Con_una_sessione_in_corso_non_fa_niente()
    {
        var d = Decide(Fx.Card(K.InDevelopment).With(l => l.RunningSession = "s1"));
        Assert.Empty(d.Actions);
    }

    [Fact]
    public void E_pura_non_modifica_lo_stato_locale_dell_istantanea()
    {
        var b = Fx.Card(K.InReview).WaitingFor("limite").With(l => { l.ReviewRounds = 2; l.RedInARow = 1; })
            .Last(Fx.Session("reviewer", "bloccante"));
        var snap = b.Build();
        _engine.Decide(snap, Fx.Ctx());
        Assert.Equal(2, snap.Local.ReviewRounds);
        Assert.Equal("limite", snap.Local.WaitingFor);
    }

    // ---- New, Needs clarification, Ready ----------------------------------------------------------------------------

    [Fact]
    public void New_lancia_il_responsabile()
    {
        var d = Decide(Fx.Card(K.New).From(K.Draft));
        var l = Assert.IsType<LaunchSession>(Assert.Single(d.Actions));
        Assert.Equal(("responsabile", "nuova"), (l.Role, l.Reason));
    }

    [Fact]
    public void New_dopo_che_il_responsabile_ha_finito_senza_spostarla_va_in_attesa()
    {
        var d = Decide(Fx.Card(K.New).From(K.Draft).Last(Fx.Session("responsabile", "fatto")));
        var h = Fx.Hold(d);
        Assert.Equal("sessione", h.For);
    }

    [Fact]
    public void Needs_clarification_senza_commenti_di_persona_aspetta_con_un_commento_lancia_il_responsabile()
    {
        Assert.Empty(Decide(Fx.Card(K.NeedsClarification).AgentComment("[responsabile] Domande")).Actions);
        var l = Assert.IsType<LaunchSession>(Assert.Single(Decide(Fx.Card(K.NeedsClarification).PersonComment()).Actions));
        Assert.Equal(("responsabile", "commento"), (l.Role, l.Reason));
    }

    [Theory]
    [InlineData("[dev] fatto")]
    [InlineData("<div><a href=\"#\" data-vss-mention=\"x\">@Titolare</a> [smistatore] dev bloccato</div>")]
    [InlineData("&nbsp;[mentore] conflitto")]
    public void Un_commento_di_agente_anche_con_involucro_html_e_menzione_non_e_di_una_persona(string text) =>
        Assert.False(DecisionEngine.IsPersonComment(new Comment(1, "x", text, Fx.T0)));

    [Fact]
    public void Un_commento_di_persona_resta_tale_anche_se_cita_un_ruolo_piu_avanti() =>
        Assert.True(DecisionEngine.IsPersonComment(new Comment(1, "x", "<a>@Mario</a> grazie, ho visto il [smistatore]", Fx.T0)));

    [Fact]
    public void Ready_crea_il_worktree_sposta_in_development_e_lancia_dev_sul_primo_task_aperto()
    {
        var d = Decide(Fx.Card(K.Ready).Task(8).Task(7).Task(6, "taskChiuso"));
        Assert.Equal(["CreaWorktree", "SpostaCard", "LanciaSessione"], Kinds(d));
        Assert.Equal(K.InDevelopment, ((MoveCard)d.Actions[1]).State);
        Assert.Equal(7, ((LaunchSession)d.Actions[2]).TaskId);
    }

    [Fact]
    public void Ready_con_un_predecessore_non_unito_non_parte_e_il_motivo_lo_dice()
    {
        var d = Decide(Fx.Card(K.Ready).Predecessor(30, K.InReview).Predecessor(31, K.Closed));
        Assert.Empty(d.Actions);
        Assert.Equal("predecessori", d.Reason!.Type);
        Assert.Equal([30], d.Reason.Cards!);
    }

    [Fact]
    public void Predecessore_in_Ready_to_release_unito_solo_con_la_PR_e_senza_worktree()
    {
        Assert.Empty(Decide(Fx.Card(K.Ready).Predecessor(30, K.ReadyToRelease, prId: 9, folder: "C:/wt")).Actions);
        Assert.NotEmpty(Decide(Fx.Card(K.Ready).Predecessor(30, K.ReadyToRelease, prId: 9)).Actions);
    }

    [Fact]
    public void Ready_con_il_repo_gia_occupato_da_un_altra_card_aspetta()
    {
        var ctx = Fx.Ctx(inDev: new() { ["Acme.AI"] = [41] });
        var d = Decide(Fx.Card(K.Ready), ctx);
        Assert.Empty(d.Actions);
        Assert.Equal("limiteRepo", d.Reason!.Type);
        Assert.Equal([41], d.Reason.Cards!);
    }

    // ---- In development ---------------------------------------------------------------------------------------------

    [Fact]
    public void Dev_fatto_senza_PR_apre_la_PR()
    {
        var d = Decide(Fx.Card(K.InDevelopment).Last(Fx.Session("dev", "fatto")));
        Assert.IsType<OpenPr>(Assert.Single(d.Actions));
    }

    [Fact]
    public void Dev_fatto_con_la_PR_verde_va_in_revisione()
    {
        var d = Decide(Fx.Card(K.InDevelopment).Pr(Validations.Green).Last(Fx.Session("dev", "fatto")));
        Assert.Equal(["SpostaCard", "LanciaSessione"], Kinds(d));
        Assert.Equal("reviewer", ((LaunchSession)d.Actions[1]).Role);
    }

    [Fact]
    public void Validazione_rossa_rilancia_dev_con_il_log_poi_dopo_troppe_di_fila_va_in_attesa()
    {
        var l = Assert.IsType<LaunchSession>(Assert.Single(Decide(Fx.Card(K.InDevelopment).Pr(Validations.Red).Last(Fx.Session("dev", "fatto"))).Actions));
        Assert.Equal(("dev", "rossa", "https://log/7"), (l.Role, l.Reason, l.Attachment));

        var d = Decide(Fx.Card(K.InDevelopment).Pr(Validations.Red).Last(Fx.Session("dev", "fatto")).With(s => s.RedInARow = 3));
        Assert.Equal("limite", Fx.Hold(d).For);
    }

    [Fact]
    public void Una_rossa_gia_gestita_per_la_stessa_build_non_rilancia()
    {
        var d = Decide(Fx.Card(K.InDevelopment).Pr(Validations.Red, buildId: 7).Last(Fx.Session("dev", "fatto")).With(s => s.HandledRedBuild = 7));
        Assert.Empty(d.Actions);
    }

    [Fact]
    public void Conflitti_lancia_dev_e_se_li_ha_gia_provati_va_in_attesa()
    {
        Assert.Equal("conflitti", ((LaunchSession)Decide(Fx.Card(K.InDevelopment).Pr(Validations.Conflicts).Last(Fx.Session("dev", "fatto"))).Actions[0]).Reason);
        var d = Decide(Fx.Card(K.InDevelopment).Pr(Validations.Conflicts).Last(Fx.Session("dev", "fatto", reason: "conflitti")));
        Fx.Hold(d);
    }

    [Fact]
    public void Validazione_scaduta_si_rilancia()
    {
        var d = Decide(Fx.Card(K.InDevelopment).Pr(Validations.Expired).Last(Fx.Session("dev", "fatto")));
        Assert.IsType<RequeueExpiredValidations>(Assert.Single(d.Actions));
    }

    [Fact]
    public void Validazione_in_corso_da_troppo_avvisa_una_volta()
    {
        var b = Fx.Card(K.InDevelopment).Pr(Validations.Running).Last(Fx.Session("dev", "fatto", minutesAfterT0: -30));
        var n = Assert.IsType<Notify>(Assert.Single(_engine.Decide(b.Build(), Fx.Ctx()).Actions));
        Assert.Equal("validazioneLunga@dev--30", n.Key);
        b.With(s => s.Notices.Add(n.Key));
        Assert.Empty(_engine.Decide(b.Build(), Fx.Ctx()).Actions);
        Assert.Empty(Decide(Fx.Card(K.InDevelopment).Pr(Validations.Running).Last(Fx.Session("dev", "fatto"))).Actions);
    }

    [Fact]
    public void Dev_bloccato_chiama_il_responsabile_con_il_testo_e_dopo_la_sua_decisione_va_in_attesa_diretta()
    {
        var l = (LaunchSession)Decide(Fx.Card(K.InDevelopment).Last(Fx.Session("dev", "bloccato", text: "non so"))).Actions[0];
        Assert.Equal(("responsabile", "bloccato", "non so"), (l.Role, l.Reason, l.Attachment));

        var d = Decide(Fx.Card(K.InDevelopment).Earlier(Fx.Session("responsabile", "fatto", reason: "bloccato", minutesAfterT0: 20))
            .Last(Fx.Session("dev", "bloccato", reason: "decisione")));
        Assert.True(Fx.Hold(d).Direct);
    }

    [Fact]
    public void Dev_al_bivio_chiama_il_responsabile()
    {
        var l = (LaunchSession)Decide(Fx.Card(K.InDevelopment).Last(Fx.Session("dev", "bivio", text: "A o B?"))).Actions[0];
        Assert.Equal(("responsabile", "bivio", "A o B?"), (l.Role, l.Reason, l.Attachment));
    }

    [Fact]
    public void Responsabile_fatto_rilancia_dev_con_il_suo_ultimo_commento()
    {
        var d = Decide(Fx.Card(K.InDevelopment).AgentComment("[responsabile] prima").AgentComment("[responsabile] Decido A").Last(Fx.Session("responsabile", "fatto", text: "riepilogo")));
        var l = (LaunchSession)d.Actions[0];
        Assert.Equal(("dev", "decisione", "[responsabile] Decido A"), (l.Role, l.Reason, l.Attachment));
    }

    [Fact]
    public void Rilancia_vale_solo_dopo_una_rossa_e_una_volta()
    {
        Fx.Hold(Decide(Fx.Card(K.InDevelopment).Last(Fx.Session("dev", "rilancia", reason: "pronto"))));
        Assert.IsType<RequeueValidation>(Decide(Fx.Card(K.InDevelopment).Last(Fx.Session("dev", "rilancia", reason: "rossa"))).Actions[0]);
        var d = Decide(Fx.Card(K.InDevelopment).Last(Fx.Session("dev", "rilancia", reason: "rossa")).With(s => s.Relaunches = 1));
        Assert.Equal("limite", Fx.Hold(d).For);
    }

    [Fact]
    public void Dev_fatto_con_il_suo_task_ancora_aperto_va_in_attesa_con_un_altro_task_aperto_lo_prende()
    {
        var d = Decide(Fx.Card(K.InDevelopment).Task(7).Last(Fx.Session("dev", "fatto", task: 7)));
        Assert.Equal("taskNonChiuso", Fx.Hold(d).WaitKind);
        var l = (LaunchSession)Decide(Fx.Card(K.InDevelopment).Task(7, "taskChiuso").Task(8).Last(Fx.Session("dev", "fatto", task: 7))).Actions[0];
        Assert.Equal(("taskSuccessivo", 8), (l.Reason, l.TaskId));
    }

    [Fact]
    public void Tornata_in_development_dopo_il_reviewer_senza_task_ne_decisioni_va_in_attesa()
    {
        var d = Decide(Fx.Card(K.InDevelopment).Last(Fx.Session("collaudatore", "respinta")));
        Assert.Equal("limite", Fx.Hold(d).For);
    }

    [Fact]
    public void Presa_in_carico_senza_sessioni_lancia_dev()
    {
        Assert.Equal("presaInCarico", ((LaunchSession)Decide(Fx.Card(K.InDevelopment)).Actions[0]).Reason);
    }

    // ---- In review --------------------------------------------------------------------------------------------------

    [Fact]
    public void Revisione_bloccante_torna_a_dev_con_i_rilievi_oltre_il_limite_attesa()
    {
        var d = Decide(Fx.Card(K.InReview).Last(Fx.Session("reviewer", "bloccante", text: "file.cs:10")));
        Assert.Equal(["SpostaCard", "LanciaSessione"], Kinds(d));
        Assert.Equal(("dev", "rilievi", "file.cs:10"), (((LaunchSession)d.Actions[1]).Role, ((LaunchSession)d.Actions[1]).Reason, ((LaunchSession)d.Actions[1]).Attachment));
        var limite = Decide(Fx.Card(K.InReview).Last(Fx.Session("reviewer", "bloccante")).With(s => s.ReviewRounds = 2));
        Assert.Equal("limite", Fx.Hold(limite).For);
    }

    [Fact]
    public void Revisione_superata_va_in_deploy_o_dritta_in_ready_to_merge_senza_pipeline()
    {
        var con = Decide(Fx.Card(K.InReview).Earlier(Fx.Session("dev", "fatto", minutesAfterT0: 10)).Last(Fx.Session("reviewer", "superata", minutesAfterT0: 30)));
        Assert.Equal(K.DeployingToTest, Assert.IsType<MoveCard>(Assert.Single(con.Actions)).State);
        var senza = Decide(Fx.Card(K.InReview).NoPipeline().Last(Fx.Session("reviewer", "superata")));
        Assert.Equal(K.ReadyToMerge, Assert.IsType<MoveCard>(Assert.Single(senza.Actions)).State);
        var tag = Decide(Fx.Card(K.InReview).Tag(Fx.Names.NoTestTag!).Last(Fx.Session("reviewer", "superata")));
        Assert.Equal(K.ReadyToMerge, Assert.IsType<MoveCard>(Assert.Single(tag.Actions)).State);
    }

    [Fact]
    public void La_revisione_superata_decade_se_dev_rimette_mano_al_codice_dopo()
    {
        var d = Decide(Fx.Card(K.InReview).Earlier(Fx.Session("reviewer", "superata", minutesAfterT0: 10)).Last(Fx.Session("dev", "fatto", minutesAfterT0: 30)));
        Assert.Empty(d.Actions);
    }

    [Fact]
    public void Revisione_superata_con_il_componente_occupato_in_test_aspetta()
    {
        var ctx = Fx.Ctx(inTest: new() { ["stime"] = [41] });
        var d = Decide(Fx.Card(K.InReview).Last(Fx.Session("reviewer", "superata")), ctx);
        Assert.Empty(d.Actions);
        Assert.Equal("limiteTest", d.Reason!.Type);
        Assert.Equal("collaudatore", d.Reason.Role);
    }

    // ---- Test -------------------------------------------------------------------------------------------------------

    private static CardBuilder InTest(string state) =>
        Fx.Card(state).From(K.InReview).Earlier(Fx.Session("dev", "fatto", minutesAfterT0: 5)).Last(Fx.Session("reviewer", "superata", minutesAfterT0: 10));

    [Fact]
    public void Deploying_to_test_accoda_il_deploy_con_i_parametri_scelti_e_spegne_gli_altri()
    {
        var d = Decide(InTest(K.DeployingToTest).Deploy(["deployStime"], ["deployStime", "deployDatabases"]));
        var q = Assert.IsType<QueueTestDeploy>(Assert.Single(d.Actions));
        Assert.Equal(10, q.Rev);
        Assert.Equal(["deployStime"], q.Parameters);
        Assert.Equal(["deployDatabases"], q.Off);
    }

    [Fact]
    public void Deploying_to_test_senza_scelta_o_con_un_parametro_sconosciuto_va_in_attesa_deploy()
    {
        Assert.Equal("deploy", Fx.Hold(Decide(InTest(K.DeployingToTest))).For);
        var d = Decide(InTest(K.DeployingToTest).Deploy(["deployX"], ["deployStime"]));
        Assert.Equal("parametroDeploySconosciuto", Fx.Hold(d).WaitKind);
    }

    [Fact]
    public void Un_run_di_una_revisione_precedente_non_vale_si_accoda_di_nuovo()
    {
        var d = Decide(InTest(K.DeployingToTest).Deploy("deployStime").Run("completed", "succeeded", afterRev: 3));
        Assert.IsType<QueueTestDeploy>(Assert.Single(d.Actions));
    }

    [Fact]
    public void Deploy_riuscito_va_in_automated_test_o_in_human_test_con_il_tag()
    {
        Assert.Equal(K.AutomatedTest, ((MoveCard)Decide(InTest(K.DeployingToTest).Run("completed", "succeeded")).Actions[0]).State);
        Assert.Equal(K.HumanTest, ((MoveCard)Decide(InTest(K.DeployingToTest).Tag(Fx.Names.HumanTestTag!).Run("completed", "succeeded")).Actions[0]).State);
        Assert.Empty(Decide(InTest(K.DeployingToTest).Run("inProgress", null)).Actions);
    }

    [Fact]
    public void Deploy_fallito_il_motivo_dell_on_hold_porta_il_link_al_run()
    {
        var h = Fx.Hold(Decide(InTest(K.DeployingToTest).Run("completed", "failed")));
        Assert.Equal("deploy", h.For);
        Assert.Contains("[run 70](https://run/70)", h.Reason);
    }

    [Fact]
    public void Tolto_l_on_hold_dopo_un_deploy_fallito_si_dimentica_il_run_e_si_riaccoda()
    {
        var d = Decide(InTest(K.DeployingToTest).Deploy("deployStime").Run("completed", "failed").WaitingFor("deploy"));
        Assert.Equal(["AzzeraContatori", "AzzeraDeploy", "AccodaDeployTest"], Kinds(d));
    }

    [Fact]
    public void In_test_senza_revisione_superata_torna_indietro()
    {
        var d = Decide(Fx.Card(K.AutomatedTest).From(K.DeployingToTest).Last(Fx.Session("dev", "fatto")));
        var b = Assert.IsType<MoveBack>(Assert.Single(d.Actions));
        Assert.Equal(K.InReview, b.State);
    }

    [Fact]
    public void Un_task_aggiunto_in_test_riporta_la_card_a_dev()
    {
        var d = Decide(InTest(K.AutomatedTest).Task(9));
        Assert.Equal(["RiportaIndietro", "LanciaSessione"], Kinds(d));
        Assert.Equal(9, ((LaunchSession)d.Actions[1]).TaskId);
    }

    [Fact]
    public void Automated_test_lancia_il_collaudatore_con_l_ambiente_e_senza_urlTest_dice_di_fermarsi()
    {
        Assert.Equal("Ambiente di Test: https://srv-app-test:5480", ((LaunchSession)Decide(InTest(K.AutomatedTest)).Actions[0]).Attachment);
        Assert.Contains("ESITO=bloccato", ((LaunchSession)Decide(InTest(K.AutomatedTest).NoTestUrl()).Actions[0]).Attachment);
    }

    [Fact]
    public void Collaudo_superato_va_in_ready_to_merge_respinto_al_responsabile_oltre_il_limite_attesa()
    {
        var ok = Decide(InTest(K.AutomatedTest).Last(Fx.Session("collaudatore", "superata", minutesAfterT0: 70)));
        Assert.Equal(K.ReadyToMerge, ((MoveCard)ok.Actions[0]).State);
        var ko = (LaunchSession)Decide(InTest(K.AutomatedTest).Last(Fx.Session("collaudatore", "respinta", minutesAfterT0: 70, text: "manca il totale"))).Actions[0];
        Assert.Equal(("responsabile", "collaudoRespinto", "manca il totale"), (ko.Role, ko.Reason, ko.Attachment));
        var limite = Decide(InTest(K.AutomatedTest).Last(Fx.Session("collaudatore", "respinta", minutesAfterT0: 70)).With(s => s.TestRounds = 2));
        Assert.Equal("limite", Fx.Hold(limite).For);
    }

    [Fact]
    public void Un_collaudo_di_prima_dell_ingresso_nello_stato_non_vale()
    {
        var d = Decide(InTest(K.AutomatedTest).Last(Fx.Session("collaudatore", "superata", minutesAfterT0: -30)));
        Assert.Equal("collaudatore", ((LaunchSession)d.Actions[0]).Role);
    }

    [Fact]
    public void Human_test_avvisa_una_volta_e_un_commento_di_persona_va_al_responsabile()
    {
        var n = Assert.IsType<Notify>(Assert.Single(Decide(InTest(K.HumanTest)).Actions));
        Assert.Equal(("richiedente", "testPronto@10"), (n.Who, n.Key));
        Assert.Empty(Decide(InTest(K.HumanTest).With(s => s.Notices.Add("testPronto@10"))).Actions);
        Assert.Equal("verificaInTest", ((LaunchSession)Decide(InTest(K.HumanTest).PersonComment("Confermo")).Actions[0]).Reason);
    }

    // ---- Ready to merge e Ready to release --------------------------------------------------------------------------

    [Fact]
    public void Ready_to_merge_completa_la_PR_sul_commit_di_testa_una_volta()
    {
        var c = Assert.IsType<CompletePr>(Assert.Single(Decide(Fx.Card(K.ReadyToMerge).Pr(Validations.Green)).Actions));
        Assert.Equal((10, "HEAD1"), (c.Rev, c.Commit));
        var d = Decide(Fx.Card(K.ReadyToMerge).Pr(Validations.Green).With(s => s.CompletePrKey = "5@10"));
        Assert.Equal("prNonCompletata", Fx.Hold(d).WaitKind);
    }

    [Fact]
    public void Ready_to_merge_con_la_PR_completata_va_in_ready_to_release_con_conflitti_torna_a_dev()
    {
        Assert.Equal(K.ReadyToRelease, ((MoveCard)Decide(Fx.Card(K.ReadyToMerge).Pr(Validations.None, PrStatuses.Completed)).Actions[0]).State);
        Assert.Equal(["RiportaIndietro", "LanciaSessione"], Kinds(Decide(Fx.Card(K.ReadyToMerge).Pr(Validations.Conflicts))));
        Assert.Empty(Decide(Fx.Card(K.ReadyToMerge).Pr(Validations.Running)).Actions);
        Fx.Hold(Decide(Fx.Card(K.ReadyToMerge)));
    }

    [Fact]
    public void Ready_to_release_toglie_il_worktree_dopo_il_merge()
    {
        Assert.IsType<RemoveWorktree>(Assert.Single(Decide(Fx.Card(K.ReadyToRelease).Pr(Validations.None, PrStatuses.Completed).With(s => s.Folder = "C:/wt")).Actions));
        Assert.Empty(Decide(Fx.Card(K.ReadyToRelease).Pr(Validations.None, PrStatuses.Completed)).Actions);
    }

    // ---- riprese, limiti, quota -------------------------------------------------------------------------------------

    [Fact]
    public void On_hold_per_sessione_tolto_senza_cambi_di_stato_si_riprende_la_sessione_sul_suo_task()
    {
        var d = Decide(Fx.Card(K.InDevelopment).NoHistory().WaitingFor("sessione").Last(Fx.Session("dev", "bloccato", task: 7)));
        var l = Assert.IsType<LaunchSession>(Assert.Single(d.Actions));
        Assert.Equal(("dev", "ripresa", true, 7), (l.Role, l.Reason, l.Resume, l.TaskId));
    }

    [Fact]
    public void On_hold_per_sessione_tolto_dopo_uno_spostamento_a_mano_si_decide_dallo_stato_nuovo()
    {
        // la card e entrata in Ready to merge (T0) dopo la fine della sessione del collaudatore (T0 - 30 min)
        var d = Decide(Fx.Card(K.ReadyToMerge).Pr(Validations.Green).WaitingFor("sessione").Last(Fx.Session("collaudatore", "superata", minutesAfterT0: -30)));
        Assert.Equal(["AzzeraContatori", "CompletaPr"], Kinds(d));
    }

    [Fact]
    public void Una_sessione_finita_senza_ESITO_va_in_attesa()
    {
        var d = Decide(Fx.Card(K.InDevelopment).Last(Fx.Session("dev", null)));
        Assert.Equal("senzaEsito", Fx.Hold(d).WaitKind);
    }

    [Fact]
    public void Al_limite_di_sessioni_non_parte_niente_e_il_motivo_dice_chi_aspetta()
    {
        var d = Decide(Fx.Card(K.Ready), Fx.Ctx(active: 3));
        Assert.Empty(d.Actions);
        Assert.Equal(("limiteSessioni", "dev"), (d.Reason!.Type, d.Reason.Role));
    }

    [Fact]
    public void Al_limite_di_sessioni_i_contatori_non_si_azzerano()
    {
        var d = Decide(Fx.Card(K.InReview).WaitingFor("limite").Last(Fx.Session("reviewer", "bloccante")), Fx.Ctx(active: 3));
        Assert.Empty(d.Actions);
    }

    [Fact]
    public void La_pausa_per_il_limite_di_token_e_la_riserva_settimanale_fermano_i_lanci_non_gli_altri_gesti()
    {
        var pausa = Fx.Ctx(quota: new QuotaInfo(Fx.T0.AddHours(2), null, null));
        Assert.Equal("quota", Decide(Fx.Card(K.New), pausa).Reason!.Type);
        var riserva = Fx.Ctx(quota: new QuotaInfo(null, 0.9, Fx.T0.AddDays(2)));
        Assert.Equal("quota", Decide(Fx.Card(K.New), riserva).Reason!.Type);
        Assert.IsType<CompletePr>(Decide(Fx.Card(K.ReadyToMerge).Pr(Validations.Green), riserva).Actions[0]);
        var passata = Fx.Ctx(quota: new QuotaInfo(Fx.T0, 0.9, Fx.T0.AddMinutes(30)));
        Assert.IsType<LaunchSession>(Decide(Fx.Card(K.New), passata).Actions[0]);
    }

    [Fact]
    public void Gli_stati_finali_non_fanno_niente()
    {
        foreach (var s in new[] { K.Draft, K.Releasing, K.Closed, K.Removed })
            Assert.Empty(Decide(Fx.Card(s)).Actions);
    }
}
