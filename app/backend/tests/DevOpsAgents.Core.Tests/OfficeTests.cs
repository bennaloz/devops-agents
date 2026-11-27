using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Orchestration;
using DevOpsAgents.Core.View;
using Xunit;

namespace DevOpsAgents.Core.Tests;

/// <summary>Le regole dell'ufficio (tests/VistaUfficio.Tests.ps1): postazioni, consegne, fila, bacheca, quota.</summary>
public class OfficeTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 26, 10, 0, 0, TimeSpan.Zero);
    private static readonly string[] Roles = ["responsabile", "dev", "reviewer", "collaudatore", "mentore"];

    private static CardLocalState Last(string role, int minutesAgo)
    {
        var s = new CardLocalState { LastRole = role };
        s.LastSessionByRole[role] = new SessionRecord { Id = "x", Role = role, Start = Now.AddMinutes(-minutesAgo - 10), End = Now.AddMinutes(-minutesAgo) };
        return s;
    }

    [Fact]
    public void Al_PC_chi_ha_una_sessione_al_caffe_gli_altri_e_le_consegne_recenti_si_parlano()
    {
        var running = new[] { new OfficeRow(10, "dev", "A", null, "inSviluppo") };
        var queue = new[] { new OfficeRow(20, "reviewer", "C", null, "inRevisione"), new OfficeRow(30, "collaudatore", "D", null, "inCollaudo") };
        var state = new Dictionary<int, CardLocalState> { [10] = Last("responsabile", 5), [20] = Last("dev", 5), [30] = Last("reviewer", 120) };
        var (seats, handovers) = Office.Seats(Roles, running, queue, state, Now);
        var dev = seats.Single(s => s.Role == "dev");
        Assert.Equal(("pc", 10, 0), (dev.Place, dev.Id, dev.Others));
        // la consegna responsabile -> dev sulla 10: il dev resta al PC, il responsabile va a parlare; il dev e gia in una consegna, quindi
        // niente consegna dev -> reviewer sulla 20; la 30 e finita da troppo
        Assert.Equal(1, Office.Seats(Roles, [running[0], new OfficeRow(12, "dev", "B", null, "inSviluppo")], [], state, Now).Seats.Single(s => s.Role == "dev").Others);
        Assert.Empty(Office.Seats(Roles, [running[0], new OfficeRow(12, "dev", "B", null, "inSviluppo")], [], state, Now).Handovers);
        var h = Assert.Single(handovers);
        Assert.Equal((10, "responsabile", "dev"), (h.Id, h.From, h.To));
        Assert.Equal(("parla", "dev", "da"), (seats.Single(s => s.Role == "responsabile").Place, seats.Single(s => s.Role == "responsabile").With, seats.Single(s => s.Role == "responsabile").Direction));
        Assert.Equal(["caffe", "caffe"], new[] { seats.Single(s => s.Role == "reviewer").Place, seats.Single(s => s.Role == "collaudatore").Place });
        Assert.Equal(["avanti", "indietro", "laterale"], new[] { Office.Direction("responsabile", "dev"), Office.Direction("collaudatore", "dev"), Office.Direction("mentore", "dev") });
    }

    [Fact]
    public void Il_modello_ha_personaggi_coda_fila_bacheca_e_quota()
    {
        var round = new RoundReport(Now, Now, false,
        [
            new CardReport(10, "A", "In development", "inSviluppo", null, null, "u10", [], null, "dev", null),
            new CardReport(20, "B", "Ready to develop", "pronto", null, null, "u20", ["LanciaSessione dev (pronto)"], null, null, null),
            new CardReport(30, "C", "In review", "inRevisione", null, null, "u30", [], new BlockReason("onHold"), null, null, WhatToDo: ["togli il tag"]),
            new CardReport(40, "D", "Ready to release", "daRilasciare", null, null, "u40", [], null, null, null),
        ], []);
        var state = new Dictionary<int, CardLocalState> { [30] = new() { LastRole = "reviewer" } };
        var m = Office.Model(Roles, round, state, Now, new QuotaInfo(null, 0.4, null), null, 0.7, false, Now.AddMinutes(2));
        var dev = m["personaggi"]!.AsArray().Single(p => p!["ruolo"]!.GetValue<string>() == "dev")!;
        Assert.Equal((10, 1), (dev["sessione"]!["id"]!.GetValue<int>(), dev["codaTotale"]!.GetValue<int>()));
        Assert.Equal("reviewer", m["fila"]![0]!["ruolo"]!.GetValue<string>());
        Assert.Equal([true, false], m["daFareTu"]!.AsArray().Select(x => x!["ferma"]!.GetValue<bool>()));
        Assert.Equal(1, m["board"]!.AsArray().Single(c => c!["chiave"]!.GetValue<string>() == "daRilasciare")!["conteggio"]!.GetValue<int>());
        Assert.Equal("libera", m["quota"]!["stato"]!.GetValue<string>());
        Assert.Equal("riserva", Office.Quota(new QuotaInfo(null, 0.8, null), new BlockReason("quota", Detail: "riserva settimanale"), 0.7)["stato"]!.GetValue<string>());
        Assert.Equal("cinqueOre", Office.Quota(null, new BlockReason("quota", Detail: "finestra di 5 ore oltre la soglia"), 0.7)["finestra"]!.GetValue<string>());
        Assert.DoesNotContain("<", Office.Json(new System.Text.Json.Nodes.JsonObject { ["t"] = "</script>" }));
    }
}
