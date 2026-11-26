using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Orchestration;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>D60: pausa e priorita delle Feature, pausa del sistema, soglia sulle 5 ore. I casi di Priorita.Tests.ps1.</summary>
public class PriorityTests
{
    private readonly DecisionEngine _engine = new();
    private static FeatureInfo F(int id, double? rank = null, bool paused = false) =>
        new(id, $"Feature {id}", "Active", paused ? [Fx.Names.PausedTag!] : [], "DevOps.Agents\\AI\\Stime", rank);

    private static DecisionContext WithFeatures(params FeatureInfo[] fs) => Fx.Ctx() with { Features = fs.ToDictionary(f => f.Id) };

    [Fact]
    public void Una_card_figlia_di_una_Feature_in_pausa_e_ferma_e_il_motivo_dice_quale_Feature()
    {
        var d = _engine.Decide(Fx.Card(K.Ready).Parent(10).Build(), WithFeatures(F(10, paused: true)));
        Assert.Empty(d.Actions);
        Assert.Equal(("pausa", "Feature 10"), (d.Reason!.Type, d.Reason.Detail));
        Assert.Equal([10], d.Reason.Cards!);
        Assert.NotEmpty(_engine.Decide(Fx.Card(K.Ready).Parent(10).Build(), WithFeatures(F(10))).Actions);
    }

    [Fact]
    public void Il_tag_di_pausa_sulla_card_la_ferma_anche_se_la_Feature_va_e_anche_senza_elenco_di_Feature()
    {
        Assert.Equal("pausa", _engine.Decide(Fx.Card(K.Ready).Parent(10).Tag(Fx.Names.PausedTag!).Build(), WithFeatures(F(10))).Reason!.Type);
        Assert.Equal("pausa", _engine.Decide(Fx.Card(K.Ready).Tag(Fx.Names.PausedTag!).Build(), Fx.Ctx()).Reason!.Type);
    }

    [Fact]
    public void Una_card_in_New_senza_Feature_non_parte_oltre_New_finisce_il_suo_giro()
    {
        Assert.Equal("senzaFeature", _engine.Decide(Fx.Card(K.New).From(K.Draft).Build(), WithFeatures()).Reason!.Type);
        // un padre che non e fra le Feature aperte lette conta come nessuna Feature
        Assert.Equal("senzaFeature", _engine.Decide(Fx.Card(K.New).From(K.Draft).Parent(99).Build(), WithFeatures(F(10))).Reason!.Type);
        Assert.NotEmpty(_engine.Decide(Fx.Card(K.Ready).Build(), WithFeatures()).Actions);
        Assert.IsType<LaunchSession>(_engine.Decide(Fx.Card(K.New).From(K.Draft).Parent(10).Build(), WithFeatures(F(10))).Actions[0]);
    }

    [Fact]
    public void Una_card_in_pausa_con_la_sessione_in_corso_la_lascia_finire_senza_motivo_nuovo()
    {
        var d = _engine.Decide(Fx.Card(K.InDevelopment).Parent(10).With(l => l.RunningSession = "s1").Build(), WithFeatures(F(10, paused: true)));
        Assert.Empty(d.Actions);
        Assert.Null(d.Reason);
    }

    [Fact]
    public void Le_Feature_vanno_per_rank_quelle_mai_ordinate_in_fondo_per_id()
    {
        Assert.Equal([3, 1, 2, 4], FeaturePriority.Order([F(4), F(1, 2000), F(2), F(3, 1000)]).Select(f => f.Id));
    }

    [Fact]
    public void Le_card_seguono_la_Feature_padre_poi_le_Feature_senza_rank_poi_le_card_senza_Feature_a_parita_per_id()
    {
        Card C(int id, int? parent) => new(id, 1, "", "New", [], null, ParentId: parent);
        var order = FeaturePriority.OrderCards([C(5, null), C(4, 2), C(3, 1), C(2, 1), C(1, null), C(6, 3)], [F(1, 2000), F(2, 1000), F(3)]);
        Assert.Equal([4, 2, 3, 6, 1, 5], order.Select(c => c.Id));
    }

    [Fact]
    public void Riordino_mai_ordinate_si_numerano_tutte_nell_ordine_nuovo() =>
        Assert.Equal([(3, 1000.0), (1, 2000.0), (2, 3000.0)], FeaturePriority.Rerank([F(1), F(2), F(3)], 3, 0));

    [Fact]
    public void Riordino_con_tutte_ordinate_scrive_solo_la_Feature_spostata_a_meta_fra_le_vicine()
    {
        FeatureInfo[] f = [F(1, 1000), F(2, 2000), F(3, 3000), F(4, 4000)];
        Assert.Equal([(2, 3500.0)], FeaturePriority.Rerank(f, 2, 3));
        Assert.Equal([(4, 0.0)], FeaturePriority.Rerank(f, 4, 0));
        Assert.Equal([(1, 5000.0)], FeaturePriority.Rerank(f, 1, 4));
    }

    [Fact]
    public void Riordino_senza_spazio_fra_le_vicine_rinumera_e_scrive_solo_quelle_che_cambiano() =>
        Assert.Equal([(3, 2000.0), (2, 3000.0)], FeaturePriority.Rerank([F(1, 1000), F(2, 1000), F(3, 3000)], 3, 1));

    [Fact]
    public void Riordino_rifiuta_id_e_posizioni_che_non_sono_fra_le_Feature_aperte()
    {
        FeatureInfo[] f = [F(1, 1000), F(2, 2000)];
        Assert.Contains("9", Assert.Throws<ArgumentException>(() => FeaturePriority.Rerank(f, 9, 0)).Message);
        Assert.Contains("9", Assert.Throws<ArgumentException>(() => FeaturePriority.Rerank(f, 1, 9)).Message);
        Assert.Throws<ArgumentException>(() => FeaturePriority.Rerank(f, 1, 1));
    }

    private Decision WithQuota(QuotaInfo q, QuotaOverrides? o = null) =>
        _engine.Decide(Fx.Card(K.Ready).Build(), Fx.Ctx(quota: q) with { QuotaOverrides = o });

    [Fact]
    public void Oltre_la_soglia_delle_5_ore_blocca_fino_al_reset_un_reset_passato_no()
    {
        var reset = Fx.T0.AddHours(3);
        Assert.Contains("5 ore", WithQuota(new QuotaInfo(null, 0.1, null, 0.65, reset)).Reason!.Detail);
        Assert.NotEmpty(WithQuota(new QuotaInfo(null, 0.1, null, 0.65, Fx.T0)).Actions);
        Assert.NotEmpty(WithQuota(new QuotaInfo(null, 0.1, null, 0.55, reset)).Actions);
    }

    [Fact]
    public void Ignorare_la_riserva_settimanale_non_salta_la_soglia_delle_5_ore()
    {
        var q = new QuotaInfo(null, 0.9, Fx.T0.AddDays(2), 0.65, Fx.T0.AddHours(3));
        var d = WithQuota(q, new QuotaOverrides(IgnoreWeeklyReserve: true, WeeklyUntil: Fx.T0.AddDays(2)));
        Assert.Contains("5 ore", d.Reason!.Detail);
        Assert.NotEmpty(WithQuota(q with { FiveHourUtilization = 0.1 }, new QuotaOverrides(IgnoreWeeklyReserve: true, WeeklyUntil: Fx.T0.AddDays(2))).Actions);
    }

    [Fact]
    public void Alzata_dalla_vista_sopra_l_uso_sblocca_e_scade_al_reset_della_finestra()
    {
        var q = new QuotaInfo(null, 0.1, null, 0.65, Fx.T0.AddHours(3));
        Assert.NotEmpty(WithQuota(q, new QuotaOverrides(FiveHourThreshold: 0.8, FiveHourUntil: Fx.T0.AddHours(3))).Actions);
        Assert.Equal("quota", WithQuota(q, new QuotaOverrides(FiveHourThreshold: 0.8, FiveHourUntil: Fx.T0)).Reason!.Type);
    }
}
