using DevOpsAgents.Core.Agents;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

internal sealed class FakeCreator : ICardCreator
{
    public List<NewWorkItem> Created { get; } = [];
    public List<string> Tagged { get; } = [];
    public string BornState { get; set; } = "Draft";
    public string? Email { get; set; } = "titolare@example.invalid";
    public bool FailClosing { get; set; }
    public Task<(int Id, string State)> CreateWorkItemAsync(NewWorkItem item, CancellationToken ct = default)
    {
        if (FailClosing && item.ParentId is not null && item.Title.StartsWith("Collaudo")) throw new HttpRequestException("500");
        Created.Add(item);
        return Task.FromResult((900 + Created.Count, BornState));
    }
    public Task TagNewAsync(int id, IReadOnlyList<string> tags, string? stateName, CancellationToken ct = default) { Tagged.Add($"{id} {string.Join(",", tags)}"); return Task.CompletedTask; }
    public Task<Person> GetCurrentUserAsync(CancellationToken ct = default) => Task.FromResult(new Person("u", "Titolare", Email));
}

public class CardCreatorTests
{
    private const string Text = "## Descrizione\nil preventivo in PDF\n\n## Criteri di accettazione\n- si apre\n\n## Recinto\nsolo export\n\n## Riferimenti\nmail del 3/11\n";

    private static (CardCreator C, FakeCreator F, CardDesk D) Make(bool enabled = true, Action<CardDesk>? setup = null)
    {
        var d = new CardDesk();
        d.Items[10] = new(10, "Feature", "Active", "Preventivi", Fx.Area.Area, [90]);
        d.Children[10] = [new Card(90, 1, "Collaudo", Fx.N(K.New), ["collaudo-funzionalita"], Fx.Area.Area, WorkItemType: "User Story", ParentId: 10)];
        d.Items[20] = new(20, "Feature", "New", "Gruppo", "Altra\\Area", []);
        setup?.Invoke(d);
        var f = new FakeCreator();
        return (new CardCreator(f, d, Fx.Names, [Fx.Area, Fx.Area with { Area = "Altra\\Area" }], enabled), f, d);
    }

    [Fact]
    public async Task Una_card_figlia_nasce_assegnata_con_predecessori_e_padre_e_riceve_i_tag_dopo()
    {
        var (c, f, _) = Make();
        var r = await c.CreateAsync(new("User Story", "PDF", Fx.Area.Area, Text, [5, 6], NoTest: true, Feature: 10));
        Assert.Equal("Card 901 creata: https://board/901", r.Message);
        var w = Assert.Single(f.Created);
        Assert.Equal(("User Story", "titolare@example.invalid", 10, "- si apre"), (w.Type, w.AssignedTo, w.ParentId, w.Criteria));
        Assert.Equal([5, 6], w.Predecessors);
        Assert.Equal("## Descrizione\nil preventivo in PDF\n\n## Recinto\nsolo export\n\n## Riferimenti\nmail del 3/11", w.Description);
        Assert.Empty(w.Tags);
        Assert.Equal("901 agents,no-test-deploy", Assert.Single(f.Tagged));
    }

    [Fact]
    public async Task Una_Feature_D52_nasce_con_la_card_di_chiusura_e_raggruppa_senza()
    {
        var (c, f, _) = Make();
        var r = await c.CreateAsync(new("Feature", "Preventivi", Fx.Area.Area, Text, Bug: true));
        Assert.Equal((901, 902), (r.Id, r.ClosingId));
        Assert.Equal(["bug"], f.Created[0].Tags);
        Assert.Null(f.Created[0].Criteria);
        Assert.Equal(("Collaudo funzionalità: Preventivi", 901, "- si apre"), (f.Created[1].Title, f.Created[1].ParentId, f.Created[1].Criteria));
        Assert.Equal("902 agents,collaudo-funzionalita", Assert.Single(f.Tagged));
        var (c2, f2, _) = Make();
        Assert.Null((await c2.CreateAsync(new("Feature", "Gruppo", Fx.Area.Area, Text, Group: true))).ClosingId);
        Assert.Single(f2.Created);
    }

    [Theory]
    [InlineData("Task", null, false, false, "Tipo non valido")]
    [InlineData("User Story", null, true, false, "-Bug vale solo con -Tipo Feature")]
    [InlineData("User Story", null, false, true, "-Raggruppa vale solo")]
    [InlineData("Feature", null, true, true, "non vanno insieme")]
    [InlineData("Feature", 10, false, false, "una Feature non ha una Feature padre")]
    [InlineData("User Story", null, false, false, "ogni card sta in una Feature")]
    [InlineData("User Story", 30, false, false, "404")]
    public async Task I_parametri_sbagliati_si_rifiutano_prima_di_creare(string type, int? feature, bool bug, bool group, string message)
    {
        var (c, f, _) = Make();
        var e = await Assert.ThrowsAnyAsync<Exception>(() => c.CreateAsync(new(type, "T", Fx.Area.Area, Text, Bug: bug, Group: group, Feature: feature)));
        Assert.Contains(message, e.Message);
        Assert.Empty(f.Created);
    }

    [Fact]
    public async Task Le_sezioni_l_area_e_la_Feature_si_controllano()
    {
        var (c, f, d) = Make(setup: x => x.Items[11] = new(11, "Feature", "Resolved", "Fatta", Fx.Area.Area, []));
        Assert.Contains("Manca la sezione '## Recinto'", (await Assert.ThrowsAsync<CardToolException>(() => c.CreateAsync(new("Bug", "T", Fx.Area.Area, "## Descrizione\nx\n## Criteri di accettazione\ny\n## Riferimenti\nz", Feature: 10)))).Message);
        Assert.Contains("La sezione '## Riferimenti' e vuota", (await Assert.ThrowsAsync<CardToolException>(() => c.CreateAsync(new("Bug", "T", Fx.Area.Area, Text.Replace("mail del 3/11", ""), Feature: 10)))).Message);
        Assert.Contains("Area sconosciuta nella mappa: 'Boh'", (await Assert.ThrowsAsync<CardToolException>(() => c.CreateAsync(new("Bug", "T", "Boh", Text, Feature: 10)))).Message);
        Assert.Contains("e gia in develop", (await Assert.ThrowsAsync<CardToolException>(() => c.CreateAsync(new("Bug", "T", Fx.Area.Area, Text, Feature: 11)))).Message);
        Assert.Contains("sta in un'area sola", (await Assert.ThrowsAsync<CardToolException>(() => c.CreateAsync(new("Bug", "T", "Altra\\Area", Text, Feature: 10)))).Message);
        // una Feature che raggruppa (senza card di chiusura) accetta card di aree diverse
        await c.CreateAsync(new("Bug", "T", Fx.Area.Area, Text, Feature: 20));
        Assert.Single(f.Created);
        d.Cards.Clear();
    }

    [Fact]
    public async Task Senza_indirizzo_o_nata_fuori_bozza_o_con_D52_spenta_non_si_procede()
    {
        var (c, f, _) = Make();
        f.Email = null;
        Assert.Contains("senza assegnatario", (await Assert.ThrowsAsync<CardToolException>(() => c.CreateAsync(new("Bug", "T", Fx.Area.Area, Text, Feature: 10)))).Message);
        f.Email = "x@example.invalid"; f.BornState = "New";
        Assert.Contains("e nata nello stato 'New' invece di 'Draft'", (await Assert.ThrowsAsync<CardToolException>(() => c.CreateAsync(new("Bug", "T", Fx.Area.Area, Text, Feature: 10)))).Message);
        Assert.Empty(f.Tagged);
        Assert.Contains("D52 non è ancora attiva", (await Assert.ThrowsAsync<CardToolException>(() => Make(enabled: false).C.CreateAsync(new("Feature", "T", Fx.Area.Area, Text)))).Message);
        Assert.Contains("non e permesso dentro una sessione di ruolo", (await Assert.ThrowsAsync<CardToolException>(() => c.CreateAsync(new("Bug", "T", Fx.Area.Area, Text, Feature: 10), inRoleSession: true))).Message);
    }

    [Fact]
    public async Task Una_card_di_chiusura_che_non_nasce_dice_di_non_rifare_la_Feature()
    {
        var (c, f, _) = Make();
        f.FailClosing = true;
        var e = await Assert.ThrowsAsync<CardToolException>(() => c.CreateAsync(new("Feature", "Preventivi", Fx.Area.Area, Text)));
        Assert.StartsWith("La Feature 901 e nata ma la sua card di chiusura no: 500. Non creare un'altra Feature", e.Message);
    }
}
