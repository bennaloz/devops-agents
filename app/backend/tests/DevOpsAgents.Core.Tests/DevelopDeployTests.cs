using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Orchestration;
using DevOpsAgents.Core.Supervision;
using DevOpsAgents.Core.View;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>D61: Ready to deploy (test) fra il merge in develop e Ready to release. I casi del Describe D61 di Decisioni.Tests.ps1.</summary>
public class DevelopDeployTests
{
    private readonly DecisionEngine _e = new();
    private Decision D(CardBuilder b) => _e.Decide(b.Build(), Fx.Ctx());
    private static string[] Kinds(Decision d) => d.Actions.Select(a => a.Kind).ToArray();
    private static CardBuilder Waiting() => Fx.Card(K.ReadyToDeployTest).Pr(Validations.None, PrStatuses.Completed).With(s => s.PrId = 5);

    [Fact]
    public void Con_il_deploy_di_develop_che_contiene_il_merge_va_in_Ready_to_release()
    {
        var d = D(Waiting().DevelopDeploy(contained: true));
        Assert.Equal(K.ReadyToRelease, Assert.IsType<MoveCard>(Assert.Single(d.Actions)).State);
    }

    [Fact]
    public void Senza_un_deploy_che_lo_contenga_aspetta_e_intanto_toglie_il_worktree()
    {
        Assert.Empty(D(Waiting().DevelopDeploy(contained: false)).Actions);
        Assert.Empty(D(Waiting()).Actions);
        Assert.Equal(["RimuoviWorktree"], Kinds(D(Waiting().DevelopDeploy(contained: false).With(s => s.Folder = "/wt/42"))));
        Assert.Equal(["RimuoviWorktree", "SpostaCard"], Kinds(D(Waiting().DevelopDeploy(contained: true).With(s => s.Folder = "/wt/42"))));
    }

    [Fact]
    public void Un_componente_senza_deploy_in_Test_va_dritto_in_Ready_to_release()
    {
        Assert.Equal(K.ReadyToRelease, Assert.IsType<MoveCard>(Assert.Single(D(Waiting().NoPipeline()).Actions)).State);
    }

    [Fact]
    public void Un_task_aggiunto_riporta_la_card_indietro_come_in_Ready_to_release()
    {
        var d = D(Fx.Card(K.ReadyToDeployTest).Pr(Validations.None, PrStatuses.Active).Task(7).DevelopDeploy(contained: true));
        Assert.DoesNotContain(d.Actions, a => a is MoveCard { State: K.ReadyToRelease });
        Assert.NotEmpty(d.Actions);
    }

    [Fact]
    public void Una_card_della_funzionalita_segue_la_card_di_chiusura()
    {
        CardBuilder FeatureCard(string closing) => Fx.Card(K.ReadyToDeployTest).InFeature(Fx.Feature(closingState: closing))
            .Pr(Validations.None, PrStatuses.Completed).With(s => { s.Destination = "feature/f10-preventivi"; s.PrId = 5; });
        Assert.Empty(D(FeatureCard(K.ReadyToDeployTest)).Actions);
        Assert.Equal(K.ReadyToRelease, Assert.IsType<MoveCard>(Assert.Single(D(FeatureCard(K.ReadyToRelease)).Actions)).State);
    }

    [Fact]
    public void In_feature_branch_la_card_segue_la_chiusura_in_Ready_to_deploy_test_e_poi_in_Ready_to_release()
    {
        CardBuilder InFeature(string closing) => Fx.Card(K.InFeatureBranch).InFeature(Fx.Feature(closingState: closing)).Pr(Validations.None, PrStatuses.Completed)
            .With(s => { s.Destination = "feature/f10-preventivi"; s.PrId = 5; });
        Assert.Equal(K.ReadyToDeployTest, Assert.IsType<MoveCard>(Assert.Single(D(InFeature(K.ReadyToDeployTest)).Actions)).State);
        Assert.Equal(K.ReadyToRelease, Assert.IsType<MoveCard>(Assert.Single(D(InFeature(K.ReadyToRelease)).Actions)).State);
    }

    [Fact]
    public void Un_predecessore_in_Ready_to_deploy_test_e_unito_come_in_Ready_to_release()
    {
        var waits = D(Fx.Card(K.Ready).Parent(10).Predecessor(41, K.ReadyToDeployTest, prId: 3, folder: "/wt/41"));
        var goes = D(Fx.Card(K.Ready).Parent(10).Predecessor(41, K.ReadyToDeployTest, prId: 3));
        Assert.Equal("predecessori", waits.Reason?.Type);
        Assert.NotEqual("predecessori", goes.Reason?.Type);
    }

    [Fact]
    public void Una_Bug_unita_in_develop_propone_il_mentore_gia_in_Ready_to_deploy_test()
    {
        var bug = Fx.Card(K.ReadyToMerge).Pr(Validations.None, PrStatuses.Completed).Build();
        bug = bug with { Card = bug.Card with { WorkItemType = "Bug" } };
        var d = _e.Decide(bug, Fx.Ctx());
        Assert.Contains(d.Actions, a => a is MoveCard { State: K.ReadyToDeployTest });
        Assert.Contains(d.Actions, a => a is LaunchMentor { Trigger: "bug" });
    }
}

public class DevelopDeployDispatcherTests
{
    [Fact]
    public async Task Il_commit_di_merge_si_ricorda_e_il_deploy_di_develop_che_lo_contiene_porta_la_card_in_Ready_to_release()
    {
        var w = new World();
        w.Add(42, K.ReadyToDeployTest);
        w.State[42] = new CardLocalState { Branch = "feature/42-card", PrId = 5 };
        w.Prs["feature/42-card"] = new PullRequestInfo(5, PrStatuses.Completed, Validations.None, MergeCommit: "M42");
        var d = w.Dispatcher();

        // nessun deploy di develop riuscito: la card aspetta, e la voce del supervisore la conta
        var r = await d.RunRoundAsync(whatIf: false);
        Assert.Equal("M42", w.State[42].MergeCommit);
        Assert.Equal(Fx.N(K.ReadyToDeployTest), w.Cards.Single().State);
        Assert.True(r.Cards.Single().WaitsDevelopDeploy);

        // un deploy che non contiene il merge non basta
        w.DevelopDeploy = new DeployedRun(80, "D1", "https://run/80");
        await d.RunRoundAsync(whatIf: false);
        Assert.Equal(Fx.N(K.ReadyToDeployTest), w.Cards.Single().State);

        w.Contained.Add(("M42", "D1"));
        await d.RunRoundAsync(whatIf: false);
        Assert.Equal(Fx.N(K.ReadyToRelease), w.Cards.Single().State);
    }
}

public class DevelopDeploySupervisorTests
{
    private static CardReport C(int id, bool waits = true) =>
        new(id, $"Card {id}", Fx.N(K.ReadyToDeployTest), K.ReadyToDeployTest, "A", "Titolare", $"https://board/{id}", [], null, null, null, WaitsDevelopDeploy: waits);

    [Fact]
    public void Le_card_che_aspettano_il_deploy_di_develop_sono_una_voce_sola_che_non_si_ricorda_ogni_giorno()
    {
        var one = Supervisor.DevelopDeploys([C(7)]);
        Assert.Equal(("deploy-test", "La card #7 e unita in develop e aspetta un deploy di develop in Test.", false), (one.Key, one.Text, one.Remind));
        var two = Supervisor.DevelopDeploys([C(9), C(7)]);
        Assert.Equal("2 card unite in develop aspettano un deploy di develop in Test: #7, #9.", two.Text);
        Assert.Equal(["#7 Card 7", "#9 Card 9"], two.Lines);
        Assert.Equal(["7", "9"], two.Elements);
        Assert.Equal("https://board/7", two.Link);
    }

    [Fact]
    public void Nell_ufficio_la_card_e_una_voce_da_fare_che_non_ferma_il_flusso()
    {
        var round = new RoundReport(Fx.T0, Fx.T0, false, [C(7), C(8, waits: false)], []);
        var (_, _, todo) = Office.Rows(round, new Dictionary<int, CardLocalState>(), Fx.T0);
        var t = Assert.Single(todo);
        Assert.Equal((7, "deployTest", false), (t.Id, t.Verb, t.Stops));
    }
}
