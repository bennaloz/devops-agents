using DevOpsAgents.Core.Model;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>Il passo 2b (card cedute a un collega) e il 2c (D52, la Feature chiusa dopo la card di chiusura) dello smistatore.</summary>
public class CededAndFeatureCloseTests
{
    private static readonly Person Collega = new("u-2", "Collega", "collega@example.invalid");

    [Fact]
    public async Task Una_card_passata_a_un_collega_perde_worktree_e_stato_senza_scrivere_sulla_card()
    {
        var w = new World();
        w.Add(42, K.InDevelopment, Collega);
        w.State[42] = new CardLocalState { Branch = "feature/42-x", Folder = "/wt/42" };
        w.ExistingFolders.Add("/wt/42");
        var r = await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Contains("rimuovi /wt/42", w.Writes);
        Assert.False(w.State.ContainsKey(42));
        Assert.DoesNotContain(w.Writes, x => x.StartsWith("commento 42") || x.StartsWith("tag 42"));
        Assert.Contains(r.Log, l => l == "card 42: ora e assegnata a Collega: tolti worktree e stato locale");
    }

    [Fact]
    public async Task Un_worktree_sporco_resta_la_card_si_segna_ceduta_e_quando_torna_si_riprova()
    {
        var w = new World();
        var c = w.Add(42, K.InDevelopment, Collega);
        w.State[42] = new CardLocalState { Branch = "feature/42-x", Folder = "/wt/42" };
        w.ExistingFolders.Add("/wt/42");
        w.DirtyFolders.Add("/wt/42");
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.True(w.State[42].Ceded);
        Assert.DoesNotContain("rimuovi /wt/42", w.Writes);
        // torna mia, ancora sporca: on-hold con il motivo
        w.Cards[0] = c with { AssignedTo = World.Me };
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Contains(w.Writes, x => x.StartsWith("commento 42") && x.Contains("tornata assegnata a me"));
        // pulita: il worktree vecchio si toglie e lo stato riparte da zero
        w.DirtyFolders.Clear();
        w.State[42].Ceded = true;
        var r = await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Contains("rimuovi /wt/42", w.Writes);
        Assert.Contains(r.Log, l => l.StartsWith("card 42: tornata assegnata a me: tolto il worktree vecchio"));
    }

    [Fact]
    public async Task La_Feature_si_chiude_quando_la_card_di_chiusura_e_Closed_e_non_si_riscrive()
    {
        var w = new World();
        w.State[90] = new CardLocalState { FeatureToClose = 10 };
        w.Others[90] = new Card(90, 5, "Collaudo", Fx.N(K.ReadyToRelease), [], Fx.Area.Area);
        w.FeatureStates[10] = "Resolved";
        // ne attiva ne Closed (Ready to release ma non fra le attive di questo utente): lo si dice una volta
        var r1 = await w.Dispatcher().RunRoundAsync(whatIf: false);
        var r2 = await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Single(r1.Log.Concat(r2.Log), l => l.Contains("la Feature 10 resta com'e"));
        w.Others[90] = w.Others[90] with { State = Fx.N(K.Closed) };
        var prova = await w.Dispatcher().RunRoundAsync(whatIf: true);
        Assert.Contains(prova.Log, l => l == "card 90: e Closed: chiuderei la Feature 10");
        var r3 = await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Contains($"stato 10 {Fx.N("featureChiusa")}", w.Writes);
        Assert.Null(w.State[90].FeatureToClose);
        Assert.Contains(r3.Log, l => l == "card 90: Closed, la Feature 10 e ora Closed");
    }

    [Fact]
    public async Task Una_Feature_gia_chiusa_o_rimossa_non_si_tocca_e_una_card_rimossa_smette_di_aspettare()
    {
        var w = new World();
        w.State[90] = new CardLocalState { FeatureToClose = 10 };
        w.State[91] = new CardLocalState { FeatureToClose = 11 };
        w.Others[90] = new Card(90, 5, "Collaudo", Fx.N(K.Closed), [], Fx.Area.Area);
        w.Others[91] = new Card(91, 5, "Collaudo", Fx.N(K.Removed), [], Fx.Area.Area);
        w.FeatureStates[10] = "Removed";
        var r = await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.DoesNotContain(w.Writes, x => x.StartsWith("stato 10") || x.StartsWith("stato 11"));
        Assert.Contains(r.Log, l => l == "card 90: Closed, la Feature 10 e gia Removed: non la tocco");
        Assert.Contains(r.Log, l => l == "card 91: Removed, la Feature 11 non si chiude piu da qui");
        Assert.Null(w.State[91].FeatureToClose);
    }
}
