using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Orchestration;
using DevOpsAgents.Core.Supervision;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>D51: i controlli del supervisore e il piano degli avvisi, come Supervisione.Tests.ps1.</summary>
public class SupervisorTests
{
    // mercoledi 25/11/2026, 10:00 UTC, fuso UTC: le fasce di riepilogo sono 08:30 e 14:00
    private static readonly DateTimeOffset Now = new(2026, 11, 25, 10, 0, 0, TimeSpan.Zero);
    private static readonly SupervisorSettings Cfg = new();

    private static CardReport C(int id, string key, BlockReason? reason = null, string[]? actions = null, string? error = null, string? area = "A", IReadOnlyList<string>? todo = null) =>
        new(id, $"Card {id}", Fx.N(key), key, area, "Titolare", $"https://board/{id}", actions ?? [], reason, null, error, null, todo);

    private static Observation O(IEnumerable<CardReport>? cards = null, DateTimeOffset? lastRound = null, bool autoRun = true,
        IReadOnlyList<(DateTimeOffset, string)>? errors = null, BlockReason? quota = null, DateTimeOffset? pat = null, DateTimeOffset? now = null, SupervisorState? state = null) =>
        new(now ?? Now, TimeZoneInfo.Utc, autoRun, lastRound ?? (now ?? Now).AddMinutes(-2), errors ?? [],
            new RoundReport(Now, Now, false, (cards ?? []).ToList(), []), state is null ? new Dictionary<int, double>() : Supervisor.HoursStill(state, now ?? Now), quota, pat, "https://board/");

    private static IReadOnlyList<Problem> Check(Observation o, SupervisorState? s = null) => Supervisor.Check(o, Cfg, s ?? new SupervisorState(), Fx.Names);

    [Fact]
    public void Smistatore_fermo_da_troppo_e_un_urgente_solo_con_il_giro_automatico()
    {
        var p = Assert.Single(Check(O(lastRound: Now.AddMinutes(-30))));
        Assert.Equal(("smistatore-fermo", true), (p.Key, p.Urgent));
        Assert.Empty(Check(O(lastRound: Now.AddMinutes(-30), autoRun: false)));
    }

    [Fact]
    public void Due_giri_interrotti_di_fila_sono_un_urgente_il_PAT_rifiutato_e_un_urgente_a_parte_con_il_comando()
    {
        var errs = new List<(DateTimeOffset, string)> { (Now.AddMinutes(-4), "rete giu"), (Now.AddMinutes(-2), "rete giu di nuovo") };
        Assert.Contains(Check(O(errors: errs)), p => p.Key == "smistatore-giro-interrotto" && p.Urgent && p.Text.Contains("rete giu di nuovo"));
        var pat = Check(O(errors: [(Now.AddMinutes(-1), "401 - il PAT di Azure DevOps e scaduto o revocato: rilancia ...")]));
        var p = Assert.Single(pat);
        Assert.Equal(("pat-rifiutato", true), (p.Key, p.Urgent));
        Assert.Contains("-Pat", p.Action);
    }

    [Fact]
    public void Una_card_in_on_hold_e_una_voce_con_il_gesto_e_le_card_che_tiene_ferme()
    {
        var cards = new[]
        {
            C(86, K.InDevelopment, new BlockReason("onHold", Detail: "limite"), todo: ["1. rilancia la validazione del gateway", "2. Togli l'on-hold: ...", "Perche: instabile"]),
            C(74, K.Ready, new BlockReason("predecessori", "dev", Cards: [86])),
        };
        var p = Check(O(cards)).Single(x => x.Key == "card-86-sblocca");
        Assert.Equal("rilancia la validazione del gateway", p.Action);
        Assert.Contains("Tiene ferme anche: #74", p.Lines!);
    }

    [Fact]
    public void Prova_umana_domande_del_responsabile_e_rilasci_raggruppati_per_area_con_la_soglia()
    {
        var cards = Enumerable.Range(1, 5).Select(i => C(i, K.ReadyToRelease, area: "Web")).Append(C(9, K.ReadyToRelease, area: "Api"))
            .Append(C(20, K.HumanTest)).Append(C(21, K.NeedsClarification)).ToList();
        var ps = Check(O(cards));
        Assert.Contains(ps, p => p.Key == "card-20-prova");
        Assert.Contains(ps, p => p.Key == "card-21-rispondi");
        var r = ps.Single(p => p.Key == "rilasci");
        Assert.Equal("rilasci", r.Topic);
        Assert.StartsWith("OLTRE SOGLIA - Web: 5 card", r.Lines![0]);
        Assert.StartsWith("Api: 1 card (#9)", r.Lines[1]);
        Assert.True(r.Remind);
    }

    [Fact]
    public void Una_card_ferma_da_ore_senza_motivo_e_una_voce_una_che_si_muove_no()
    {
        var s = new SupervisorState();
        var card = C(42, K.InReview);
        Supervisor.Update(s, [], O([card], now: Now.AddHours(-7)));
        Assert.Contains(Check(O([card], state: s), s), p => p.Key == "ferma-42" && p.Text.Contains("7 ore"));
        Supervisor.Update(s, [], O([card with { Actions = ["SpostaCard"] }]));
        Assert.DoesNotContain(Check(O([card], state: s), s), p => p.Key == "ferma-42");
    }

    [Fact]
    public void Una_card_che_salta_per_errore_molti_giri_di_fila_e_un_urgente()
    {
        var s = new SupervisorState();
        var bad = C(42, K.InReview, error: "boom");
        for (var i = 0; i < 5; i++) Supervisor.Update(s, [], O([bad]));
        Assert.Contains(Check(O([bad]), s), p => p.Key == "card-42-errori" && p.Urgent);
    }

    [Fact]
    public void La_quota_la_pausa_e_la_riserva_sono_voci_la_finestra_di_5_ore_no()
    {
        Assert.Contains(Check(O(quota: new BlockReason("quota", Detail: "limite di token fino a x"))), p => p.Key == "quota-pausa");
        Assert.Contains(Check(O(quota: new BlockReason("quota", Detail: "riserva settimanale al 90%"))), p => p.Key == "quota-riserva");
        Assert.Empty(Check(O(quota: new BlockReason("quota", Detail: "finestra di 5 ore al 65%"))));
    }

    [Fact]
    public void Gli_urgenti_partono_subito_e_si_ricordano_dopo_le_ore_del_ricordo()
    {
        var s = new SupervisorState { LastRun = Now.AddMinutes(-5), Summaries = ["2026-11-25 08:30"] };
        var o = O(lastRound: Now.AddHours(-1));
        Supervisor.Update(s, Check(o), o);
        var plan = Supervisor.Plan(s, o, Cfg);
        var u = Assert.Single(plan.Urgent);
        Assert.False(u.Reminder);
        Supervisor.Register(s, plan, plan.Urgent, Now);
        Assert.Empty(Supervisor.Plan(s, O(lastRound: Now.AddHours(-1), now: Now.AddHours(1)), Cfg).Urgent);
        var later = O(lastRound: Now.AddHours(-1), now: Now.AddHours(5));
        Supervisor.Update(s, Check(later), later);
        Assert.True(Assert.Single(Supervisor.Plan(s, later, Cfg).Urgent).Reminder);
    }

    [Fact]
    public void Il_riepilogo_parte_alle_fasce_dei_feriali_una_volta_e_non_nel_fine_settimana()
    {
        var s = new SupervisorState { LastRun = Now.AddMinutes(-5) };
        var o = O([C(20, K.HumanTest)]);
        Supervisor.Update(s, Check(o), o);
        var plan = Supervisor.Plan(s, o, Cfg);
        Assert.True(plan.SendSummary);
        Assert.Equal(["2026-11-25 08:30"], plan.Slots);
        Supervisor.Register(s, plan, plan.Summary, Now);
        Assert.False(Supervisor.Plan(s, O([C(20, K.HumanTest)], now: Now.AddMinutes(5)), Cfg).SendSummary);
        var saturday = new DateTimeOffset(2026, 11, 28, 10, 0, 0, TimeSpan.Zero);
        var s2 = new SupervisorState { LastRun = saturday.AddMinutes(-5) };
        var o2 = O([C(20, K.HumanTest)], now: saturday);
        Supervisor.Update(s2, Check(o2), o2);
        Assert.False(Supervisor.Plan(s2, o2, Cfg).SendSummary);
    }

    [Fact]
    public void Un_problema_che_non_si_vede_piu_si_chiude_senza_messaggi_dopo_due_assenze()
    {
        var s = new SupervisorState();
        var o = O([C(20, K.HumanTest)]);
        Supervisor.Update(s, Check(o), o);
        Supervisor.Update(s, [], O());
        Assert.True(s.Problems.ContainsKey("card-20-prova"));
        Supervisor.Update(s, [], O());
        Assert.Empty(s.Problems);
    }

    [Fact]
    public void I_rilasci_tornano_solo_con_una_card_nuova_o_se_un_area_e_oltre_soglia()
    {
        var s = new SupervisorState { LastRun = Now.AddMinutes(-5) };
        var o = O([C(1, K.ReadyToRelease)]);
        Supervisor.Update(s, Check(o), o);
        var plan = Supervisor.Plan(s, o, Cfg);
        Assert.Single(plan.Releases);
        Supervisor.Register(s, plan, plan.Releases, Now);
        var tomorrow = O([C(1, K.ReadyToRelease)], now: Now.AddDays(1));
        Supervisor.Update(s, Check(tomorrow, s), tomorrow);
        Assert.Empty(Supervisor.Plan(s, tomorrow, Cfg).Releases);
        var newCard = O([C(1, K.ReadyToRelease), C(2, K.ReadyToRelease)], now: Now.AddDays(1));
        Supervisor.Update(s, Check(newCard, s), newCard);
        Assert.Single(Supervisor.Plan(s, newCard, Cfg).Releases);
    }
}
