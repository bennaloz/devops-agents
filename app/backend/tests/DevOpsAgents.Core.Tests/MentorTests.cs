using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Memory;
using DevOpsAgents.Core.Model;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>D46: quando parte il mentore e come le lezioni entrano nel brief.</summary>
public class MentorTests
{
    private readonly DecisionEngine _e = new();
    private Decision D(CardBuilder b, DecisionContext? c = null) => _e.Decide(b.Build(), c ?? Fx.Ctx());

    [Fact]
    public void Dopo_la_decisione_del_responsabile_su_un_blocco_di_dev_parte_il_mentore_per_dev_una_volta()
    {
        var b = Fx.Card(K.InDevelopment).Earlier(Fx.Session("dev", "bloccato", minutesAfterT0: 10)).Last(Fx.Session("responsabile", "fatto", reason: "bloccato", minutesAfterT0: 20, text: "usa A"));
        var m = Assert.IsType<LaunchMentor>(D(b).Actions.Last());
        Assert.Equal(("dev", "responsabile", "decisione", "decisione@responsabile-20"), (string.Join(",", m.Roles), m.Corrector, m.Trigger, m.Key));
        Assert.DoesNotContain(D(b.With(s => s.MentorsDone.Add(m.Key))).Actions, a => a is LaunchMentor);
    }

    [Fact]
    public void Un_commento_di_persona_nello_stato_istruisce_il_responsabile_un_on_hold_tolto_chi_si_era_fermato()
    {
        var comment = Fx.Card(K.InDevelopment).Last(Fx.Session("dev", "fatto", minutesAfterT0: 10)).PersonComment("No, cosi non va");
        var m = D(comment).Actions.OfType<LaunchMentor>().Single();
        Assert.Equal(("responsabile", "commento", "commento@1"), (string.Join(",", m.Roles), m.Trigger, m.Key));
        Assert.Contains("Anna: No, cosi non va", m.Text);
        var unblocked = Fx.Card(K.InDevelopment).WaitingFor("limite").Last(Fx.Session("dev", "fatto", minutesAfterT0: 10)).PersonComment("Ho sistemato io");
        Assert.Equal(("dev", "onHoldTolto"), (string.Join(",", D(unblocked).Actions.OfType<LaunchMentor>().Single().Roles), D(unblocked).Actions.OfType<LaunchMentor>().Single().Trigger));
    }

    [Fact]
    public void Una_card_tornata_dalla_prova_umana_istruisce_collaudatore_e_reviewer()
    {
        var m = D(Fx.Card(K.InDevelopment).From(K.HumanTest).Task(7).OldComment("Anna", "Il totale e sbagliato")).Actions.OfType<LaunchMentor>().Single();
        Assert.Equal(("collaudatore,reviewer", "provaUmana", "provaUmana@10"), (string.Join(",", m.Roles), m.Trigger, m.Key));
        Assert.Contains("Il totale e sbagliato", m.Text);
    }

    [Fact]
    public void Il_mentore_non_parte_se_il_limite_di_sessioni_ferma_il_lancio_correttivo()
    {
        var b = Fx.Card(K.InReview).Last(Fx.Session("reviewer", "bloccante"));
        Assert.Empty(D(b, Fx.Ctx(active: 3)).Actions);
    }

    private const string Develop = "### dev-001\n- Situazione: a\n- Cosa fare: b\n- Perché: c\n- Card: 11\n\n### dev-002\n- Situazione: d\n- Cosa fare: e\n- Perché: f\n- Card: 12\n";

    [Fact]
    public void Le_lezioni_del_ramo_in_prova_che_develop_non_ha_portano_l_etichetta()
    {
        var trial = Develop + "\n### dev-003\n- Situazione: g\n- Cosa fare: h\n- Perché: i\n- Card: 13\n";
        var l = Lessons.WithLabels(Develop, trial);
        Assert.Equal([("dev-001", false), ("dev-002", false), ("dev-003", true)], l.Select(x => (x.Id, x.InTrial)));
        Assert.StartsWith("### dev-003 (in prova)", Lessons.Text(l.Skip(2)));
        Assert.All(Lessons.WithLabels(Develop, null), x => Assert.False(x.InTrial));
        Assert.Empty(Lessons.Read("niente lezioni qui"));
    }

    [Fact]
    public void Il_brief_ha_in_fondo_la_memoria_prima_le_comuni_poi_il_repo_e_senza_lezioni_resta_com_e()
    {
        var b = Lessons.BriefWithMemory("# Brief di dev\n", [new MemoryFile("Acme.AI", Develop, null), new MemoryFile("comune", "### dev-010\n- Situazione: x", null)]);
        Assert.Equal("# Brief di dev\n\n# Memoria\n\n## Lezioni comuni a tutti i repo\n\n### dev-010\n- Situazione: x\n\n## Lezioni del repo Acme.AI\n\n" + Develop.TrimEnd() + "\n", b);
        Assert.Equal("# Brief", Lessons.BriefWithMemory("# Brief", [new MemoryFile("comune", null, null)]));
    }
}
