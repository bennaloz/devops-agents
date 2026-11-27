using System.Text.Json.Nodes;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Orchestration;
using DevOpsAgents.Core.Ports;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

internal sealed class MemoryLearningLog : ILearningLog
{
    public List<LearningEntry> Rows { get; } = [];
    public void Add(LearningEntry entry, DateTimeOffset when) => Rows.Add(entry);
    public IReadOnlyList<JsonNode?> Read() => [];
}

/// <summary>D46: le righe del registro dell'apprendimento che scrive lo smistatore (Write-Apprendimento in src/Smistatore.ps1).</summary>
public class LearningLogTests
{
    private static Dispatcher D(World w, ILearningLog log) =>
        new(w, w, w, w, w, w, new DecisionEngine(), Fx.Names, new Limits(), [Fx.Area], w, NullLogger<Dispatcher>.Instance, new DispatcherOptions(), learning: log);

    [Fact]
    public async Task Una_sessione_bloccata_scrive_il_blocco_e_le_lezioni_seguite_con_l_esito()
    {
        var w = new World();
        w.Add(43, K.InDevelopment);
        w.State[43] = new CardLocalState { Branch = "b", Folder = "/wt/43", LastRole = "dev", RunningSession = "s9" };
        w.State[43].LastSessionByRole["dev"] = Fx.Session("dev", null, finished: false);
        w.Results["s9"] = new SessionResult("bloccato", "manca la stringa di connessione", Lessons: ["dev-003", "dev-007"]);
        var log = new MemoryLearningLog();
        await D(w, log).RunRoundAsync(whatIf: false);
        Assert.Contains(new LearningEntry(43, "Acme.AI", "blocco", "dev", "bloccato: manca la stringa di connessione"), log.Rows);
        Assert.Contains(new LearningEntry(43, "Acme.AI", "lezioneApplicata", "dev", "", "dev-003", "bloccato"), log.Rows);
        Assert.Contains(log.Rows, r => r.Kind == "lezioneApplicata" && r.Lesson == "dev-007");
    }

    [Fact]
    public async Task Un_on_hold_scrive_la_sua_riga_e_una_sessione_finita_bene_solo_le_lezioni()
    {
        var w = new World();
        w.Add(43, K.InDevelopment);
        w.State[43] = new CardLocalState { Branch = "b", Folder = "/wt/43", LastRole = "dev", RunningSession = "s9" };
        w.State[43].LastSessionByRole["dev"] = Fx.Session("dev", null, finished: false);
        w.Results["s9"] = new SessionResult(null, "errore", Failed: true);
        var log = new MemoryLearningLog();
        await D(w, log).RunRoundAsync(whatIf: false);
        var hold = Assert.Single(log.Rows);
        Assert.Equal(("onHold", "dev"), (hold.Kind, hold.Role));
        Assert.StartsWith("La sessione di dev e fallita", hold.Reason);
    }
}
