using System.Text.Json.Nodes;
using DevOpsAgents.Core.Update;
using Xunit;

namespace DevOpsAgents.Core.Tests;

/// <summary>I casi delle regole pure di tests/Aggiornamento.Tests.ps1 (D53).</summary>
public class UpdateRulesTests
{
    [Fact]
    public void Il_canale_e_quello_delle_impostazioni_poi_il_ramo_estratto_poi_main()
    {
        Assert.Equal("develop", UpdateRules.Channel("develop", "main"));
        Assert.Equal("develop", UpdateRules.Channel(null, "develop"));
        Assert.Equal("main", UpdateRules.Channel("boh", "feature/42-x"));
        Assert.Equal("main", UpdateRules.Channel(null, "HEAD"));
    }

    [Fact]
    public void Versioni_e_requisiti()
    {
        Assert.Equal(new Version(2, 1, 328), UpdateRules.ParseVersion("2.1.328 (Claude Code)"));
        Assert.Equal(new Version(7, 4, 6), UpdateRules.ParseVersion("PowerShell 7.4.6"));
        Assert.Null(UpdateRules.ParseVersion("niente"));
        var req = JsonNode.Parse("""{ "claude": "2.1", "powershell": "7.4", "nuovo": "1.0" }""")!.AsObject();
        Assert.Empty(UpdateRules.Missing(req, new Dictionary<string, string?> { ["claude"] = "2.1.0", ["powershell"] = "7.5" }));
        var m = UpdateRules.Missing(req, new Dictionary<string, string?> { ["claude"] = "2.0.9 (Claude Code)", ["powershell"] = null });
        Assert.Equal([new MissingRequirement("claude", "2.1", "2.0.9"), new MissingRequirement("powershell", "7.4", null)], m);
        Assert.Empty(UpdateRules.Missing(null, new Dictionary<string, string?>()));
    }

    [Fact]
    public void Le_PR_si_leggono_dai_messaggi_di_fusione_di_Azure_DevOps_e_GitHub()
    {
        Assert.Equal([new IncomingPr(12, "aggiunge il supervisore"), new IncomingPr(13, "feature/7-x"), new IncomingPr(14, "acme/fix")],
            UpdateRules.PrsFromLog(["Merged PR 12: aggiunge il supervisore", "Merge pull request 13 from feature/7-x into main", "Merge pull request #14 from acme/fix", "fix a mano", ""]));
    }

    [Fact]
    public void Relazione_e_file_modificati()
    {
        Assert.Equal(["senzaOrigine", "uguale", "indietro", "avanti", "divergente"],
            new[] { UpdateRules.Relation("a", null, false, false), UpdateRules.Relation("a", "a", true, true), UpdateRules.Relation("a", "b", true, false),
                UpdateRules.Relation("a", "b", false, true), UpdateRules.Relation("a", "b", false, false) });
        Assert.Equal(["config/limiti.json", "nuovo.txt", "vecchio.md", "nuovo.md", "con spazio.txt"],
            UpdateRules.ModifiedFiles(" M config/limiti.json\n?? nuovo.txt\nR  vecchio.md -> nuovo.md\n?? \"con spazio.txt\"\n"));
        Assert.Empty(UpdateRules.ModifiedFiles(""));
    }

    private static UpdateObservation Obs(string relation = "indietro", bool auto = true, bool requested = false, string? discarded = null, string[]? modified = null,
        MissingRequirement[]? missing = null, Occupancy? occ = null, bool diverges = false, Action? costly = null) =>
        new("H", relation == "senzaOrigine" ? null : "T", discarded, auto, requested, relation, modified ?? [],
            () => { costly?.Invoke(); return missing ?? []; }, () => { costly?.Invoke(); return occ ?? new(0, 0); }, diverges);

    [Fact]
    public void Il_passo_segue_i_casi_in_ordine()
    {
        Assert.True(UpdateRules.Step(Obs()).Advance);
        Assert.Equal("aggiornato", UpdateRules.Step(Obs("uguale")).Outcome);
        Assert.Equal("invariato", UpdateRules.Step(Obs("senzaOrigine")).Outcome);
        Assert.Equal("daAggiornare", UpdateRules.Step(Obs(auto: false)).Outcome);
        Assert.True(UpdateRules.Step(Obs(auto: false, requested: true)).Advance);
        Assert.Equal("invariato", UpdateRules.Step(Obs(discarded: "T")).Outcome);
        Assert.True(UpdateRules.Step(Obs(discarded: "T", requested: true)).Advance);
        Assert.Equal("copiaAvanti", UpdateRules.Step(Obs("avanti", requested: true)).Outcome);
        Assert.Equal("divergente", UpdateRules.Step(Obs("divergente")).Outcome);
        Assert.Equal("ramoCanaleDivergente", UpdateRules.Step(Obs(diverges: true)).Outcome);
        var local = UpdateRules.Step(Obs(modified: ["config/limiti.json", "src/x.ps1"]));
        Assert.Equal(("modificheLocali", 2), (local.Outcome, local.Files!.Count));
        var migrate = UpdateRules.Step(Obs(modified: ["config/limiti.json", "config/supervisore.json"]));
        Assert.True(migrate.Advance && migrate.Migrate);
        Assert.Equal("requisitiMancanti", UpdateRules.Step(Obs(missing: [new("claude", "2.1", null)], occ: new(3, 0))).Outcome);
        Assert.Equal(UpdateRules.WaitingForSessions, UpdateRules.Step(Obs(occ: new(0, 1))).Outcome);
        // requisiti e sessioni costano: non si chiamano se un caso prima ha gia deciso
        var calls = 0;
        UpdateRules.Step(Obs(modified: ["src/x.ps1"], costly: () => calls++));
        UpdateRules.Step(Obs("uguale", costly: () => calls++));
        Assert.Equal(0, calls);
    }

    [Fact]
    public void Controllo_attesa_versione_e_link_delle_PR()
    {
        var now = new DateTimeOffset(2026, 11, 25, 12, 0, 0, TimeSpan.Zero);
        Assert.True(UpdateRules.CheckDue(null, 30, now, false));
        Assert.True(UpdateRules.CheckDue(now, 30, now, true));
        Assert.False(UpdateRules.CheckDue(now.AddMinutes(-29), 30, now, false));
        Assert.True(UpdateRules.CheckDue(now.AddMinutes(-30), 30, now, false));
        Assert.True(UpdateRules.WaitedTooLong(now.AddHours(-6), now, 6));
        Assert.False(UpdateRules.WaitedTooLong(null, now, 6));
        Assert.StartsWith("main 4f3a2b1 (", UpdateRules.FormatVersion("main", "4f3a2b1", now));
        Assert.Equal("non nota", UpdateRules.FormatVersion("main", null, null));
        Assert.Equal("https://acme.visualstudio.com/DevOps.Agents/_git/DevOps.Agents/pullrequest/", UpdateRules.PrBaseUrl("https://utente@acme.visualstudio.com/DevOps.Agents/_git/DevOps.Agents"));
        Assert.Equal("https://github.com/acme/devops-agents/pull/", UpdateRules.PrBaseUrl("git@github.com:acme/devops-agents.git"));
        Assert.Null(UpdateRules.PrBaseUrl("/tmp/origin.git"));
    }

    [Fact]
    public void La_migrazione_prende_solo_le_chiavi_cambiate_e_non_sovrascrive_un_override()
    {
        var committed = JsonNode.Parse("""{ "a": 1, "b": 2, "c": [1, 2] }""")!.AsObject();
        var local = JsonNode.Parse("""{ "a": 1.0, "b": 3, "c": [1, 2], "d": true }""")!.AsObject();
        var s = UpdateRules.MigrateOverrides(committed, local, JsonNode.Parse("""{ "b": 9 }""")!.AsObject());
        Assert.Equal("""{"b":9,"d":true}""", s.ToJsonString());
    }
}
