using System.Diagnostics;
using DevOpsAgents.Core.Agents;
using DevOpsAgents.Core.Memory;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;
using DevOpsAgents.Infrastructure.Local;
using Xunit;

namespace DevOpsAgents.Infrastructure.Tests;

/// <summary>Le PR della memoria in memoria: chi crea e chi aggiorna, con lo stato che il test decide.</summary>
internal sealed class FakeMemoryPrs : ICodeHost, IPullRequestEditor
{
    public List<(int Id, string Status, string? Head, string Description)> Prs { get; } = [];
    public bool FailList { get; set; }
    public bool FailWrite { get; set; }
    public bool NeedsCardLink => false;

    public Task<IReadOnlyList<(int Id, string Status, string? HeadCommit)>> ListPullRequestsAsync(AreaMapping area, string branch, string destination, CancellationToken ct = default) =>
        FailList ? throw new HttpRequestException("503") : Task.FromResult<IReadOnlyList<(int, string, string?)>>(Prs.OrderByDescending(p => p.Id).Select(p => (p.Id, p.Status, p.Head)).ToList());
    public Task<(int Id, string Url)> CreatePullRequestAsync(AreaMapping area, string branch, string destination, string title, string description, int cardId, CancellationToken ct = default)
    {
        if (FailWrite) throw new HttpRequestException("la PR non si crea");
        Prs.Add((Prs.Count + 1, "active", null, description));
        return Task.FromResult((Prs.Count, $"https://pr/{Prs.Count}"));
    }
    public Task<string> GetDescriptionAsync(AreaMapping area, int prId, CancellationToken ct = default) => Task.FromResult(Prs.Single(p => p.Id == prId).Description);
    public Task SetDescriptionAsync(AreaMapping area, int prId, string description, CancellationToken ct = default)
    {
        var i = Prs.FindIndex(p => p.Id == prId);
        Prs[i] = Prs[i] with { Description = description };
        return Task.CompletedTask;
    }
    public Task SetTitleAsync(AreaMapping area, int prId, string title, CancellationToken ct = default) => Task.CompletedTask;
    public Task<PullRequestInfo?> GetPullRequestAsync(AreaMapping area, string branch, string destination, bool includeCompleted, CancellationToken ct = default) => throw new NotSupportedException();
    public Task CompletePullRequestAsync(AreaMapping area, int prId, string? commit, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<int> RequeueValidationsAsync(AreaMapping area, string branch, string destination, bool expiredOnly, CancellationToken ct = default) => throw new NotSupportedException();
    public string PullRequestUrl(AreaMapping area, int prId) => "";
    public Task<IReadOnlyList<string>> ListBranchesAsync(AreaMapping area, string prefix, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<PullRequestRef?> GetPullRequestByIdAsync(AreaMapping area, int prId, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<bool> ContainsCommitAsync(AreaMapping area, string commit, string inCommit, CancellationToken ct = default) => throw new NotSupportedException();
}

public class GitMemoryWriterTests
{
    static GitMemoryWriterTests()
    {
        foreach (var k in new[] { "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME" }) Environment.SetEnvironmentVariable(k, "Prova");
        foreach (var k in new[] { "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL" }) Environment.SetEnvironmentVariable(k, "prova@example.invalid");
    }

    private static string Git(string dir, params string[] args)
    {
        var psi = new ProcessStartInfo("git") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        psi.ArgumentList.Add("-C"); psi.ArgumentList.Add(dir);
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException($"git {string.Join(' ', args)}: {o}");
        return o.Trim();
    }

    private static readonly LessonFields Lesson = new("quando la build fallisce sui test lenti", "rilancia una volta", "sono instabili", "42");

    /// <summary>Un origin con develop e la lezione dev-001 stabile, la copia degli attrezzi clonata, il worktree della memoria da creare.</summary>
    private static (GitMemoryWriter W, FakeMemoryPrs Prs, string Origin, string Source, string Worktree) World(int cap = 25)
    {
        var tmp = Directory.CreateTempSubdirectory("memoria").FullName;
        var origin = Path.Combine(tmp, "origin.git");
        Git(tmp, "init", "-q", "--bare", origin);
        var seed = Path.Combine(tmp, "seed");
        Git(tmp, "clone", "-q", origin, seed);
        Git(seed, "checkout", "-q", "-b", "develop");
        Directory.CreateDirectory(Path.Combine(seed, "memoria", "dev"));
        File.WriteAllText(Path.Combine(seed, "memoria", "dev", "comune.md"), MemoryRules.LessonText("dev-001", Lesson) + "\n");
        Git(seed, "add", "-A"); Git(seed, "commit", "-q", "-m", "seed"); Git(seed, "push", "-q", "origin", "develop");
        var source = Path.Combine(tmp, "DevOps.Agents");
        Git(tmp, "clone", "-q", "-b", "develop", origin, source);
        var wt = Path.Combine(tmp, "_wt", "DevOps.Agents", "memoria");
        var prs = new FakeMemoryPrs();
        var w = new GitMemoryWriter(new MemoryWriterOptions(source, wt, Tx.AzureArea with { Repo = "DevOps.Agents" }, ["dev", "reviewer", "mentore"], ["Acme.AI"], cap, PrTextLimit: 4000, MutexWaitSeconds: 5),
            prs, prs, null, 42);
        return (w, prs, origin, source, wt);
    }

    [Fact]
    public async Task Una_lezione_nuova_va_sul_ramo_in_prova_con_un_id_nuovo_e_apre_la_PR_della_memoria()
    {
        if (OperatingSystem.IsWindows()) return;
        var (w, prs, origin, _, wt) = World();
        Assert.Equal("Lezione dev-002 scritta.", await w.WriteAsync("dev", "Acme.AI", Lesson with { Situation = " quando il deploy scade " }));
        var file = Git(origin, "show", $"{MemoryRules.TrialBranch}:memoria/dev/Acme.AI.md");
        Assert.Equal(MemoryRules.LessonText("dev-002", Lesson with { Situation = "quando il deploy scade" }), file);
        var pr = Assert.Single(prs.Prs);
        Assert.Contains("- dev-002: quando il deploy scade", pr.Description);
        Assert.DoesNotContain("dev-001", pr.Description);

        // con la PR attiva si riparte dal ramo: l'id continua e la descrizione si aggiorna
        Assert.Equal("Lezione dev-003 scritta.", await w.WriteAsync("dev", "comune", Lesson with { Situation = "terza" }));
        Assert.Single(prs.Prs);
        Assert.Contains("- dev-003: terza", prs.Prs[0].Description);
        Assert.Contains("- dev-002:", prs.Prs[0].Description);

        Assert.Equal("Lezione dev-003 rivista.", await w.ReviseAsync("dev-003", Lesson with { Situation = "terza rivista" }));
        Assert.Equal("Lezione dev-002 tolta.", await w.RemoveAsync("dev-002"));
        Assert.Contains("terza rivista", Git(origin, "show", $"{MemoryRules.TrialBranch}:memoria/dev/comune.md"));
        Assert.Equal("", Git(origin, "show", $"{MemoryRules.TrialBranch}:memoria/dev/Acme.AI.md"));
        Assert.Contains("non c'e nessuna lezione con id 'dev-009'", (await Assert.ThrowsAsync<CardToolException>(() => w.RemoveAsync("dev-009"))).Message);
        Assert.True(Directory.Exists(wt));

        // la lettura vede develop e, con la PR attiva, le lezioni in prova con l'etichetta
        var read = await w.ReadAsync("dev", "Acme.AI");
        Assert.Contains("## memoria di dev, comune:\n### dev-001\n", read);
        Assert.Contains("### dev-003 (in prova)", read);
        Assert.Contains("## memoria di dev, Acme.AI:\n(nessuna lezione)", read);
    }

    [Fact]
    public async Task Dopo_la_fusione_si_riparte_da_develop_e_l_id_non_si_riusa()
    {
        if (OperatingSystem.IsWindows()) return;
        var (w, prs, origin, _, _) = World();
        await w.WriteAsync("dev", "comune", Lesson with { Situation = "seconda" });
        // la PR si unisce: il ramo in prova e in develop
        var tmp = Path.Combine(Path.GetDirectoryName(origin)!, "merge");
        Git(Path.GetDirectoryName(origin)!, "clone", "-q", "-b", "develop", origin, tmp);
        Git(tmp, "merge", "-q", "--no-ff", "-m", "merge", $"origin/{MemoryRules.TrialBranch}");
        Git(tmp, "push", "-q", "origin", "develop");
        prs.Prs[0] = prs.Prs[0] with { Status = "completed" };
        Assert.Equal("Lezione dev-003 scritta.", await w.WriteAsync("dev", "comune", Lesson with { Situation = "terza" }));
        Assert.Equal(2, prs.Prs.Count);
        Assert.DoesNotContain("seconda", prs.Prs[1].Description);
        Assert.Contains("- dev-003: terza", prs.Prs[1].Description);
    }

    [Fact]
    public async Task Il_conflitto_scrive_un_commit_vuoto_e_la_nota_nella_PR_e_vale_solo_per_la_card_della_sessione()
    {
        if (OperatingSystem.IsWindows()) return;
        var (w, prs, _, _, _) = World();
        Assert.StartsWith("Nota aggiunta alla PR della memoria", await w.ConflictAsync(42, "la correzione chiede l'opposto\ndella regola 3"));
        Assert.Equal(["Card 42: la correzione chiede l'opposto della regola 3"], MemoryRules.ConflictNotes(Assert.Single(prs.Prs).Description));
        // una scrittura dopo tiene la nota
        await w.WriteAsync("dev", "comune", Lesson);
        Assert.Single(MemoryRules.ConflictNotes(prs.Prs[0].Description));
        Assert.Contains("solo per la card della sessione (42)", (await Assert.ThrowsAsync<CardToolException>(() => w.ConflictAsync(7, "x"))).Message);
    }

    [Fact]
    public async Task I_rifiuti_vengono_prima_di_git_e_una_PR_che_non_si_aggiorna_non_fa_ripetere_la_lezione()
    {
        if (OperatingSystem.IsWindows()) return;
        var (w, prs, origin, _, wt) = World(cap: 1);
        Assert.Contains("ruolo sconosciuto: 'boh'", (await Assert.ThrowsAsync<CardToolException>(() => w.WriteAsync("boh", "comune", Lesson))).Message);
        Assert.Contains("repo sconosciuto: 'acme.ai'", (await Assert.ThrowsAsync<CardToolException>(() => w.WriteAsync("dev", "acme.ai", Lesson))).Message);
        Assert.Contains("va scritto su una riga sola", (await Assert.ThrowsAsync<CardToolException>(() => w.WriteAsync("dev", "comune", Lesson with { Why = "a\nb" }))).Message);
        Assert.Contains("id di lezione non valido", (await Assert.ThrowsAsync<CardToolException>(() => w.RemoveAsync("dev"))).Message);
        Assert.False(Directory.Exists(wt));
        Assert.Contains("ha gia 1 lezioni (tetto 1)", (await Assert.ThrowsAsync<CardToolException>(() => w.WriteAsync("dev", "comune", Lesson))).Message);
        prs.FailWrite = true;
        Assert.Equal("lezione dev-002 scritta; PR non aggiornata: la PR non si crea", await w.WriteAsync("dev", "Acme.AI", Lesson));
        Assert.Contains("dev-002", Git(origin, "show", $"{MemoryRules.TrialBranch}:memoria/dev/Acme.AI.md"));
        prs.FailList = true;
        Assert.Contains("503", (await Assert.ThrowsAsync<HttpRequestException>(() => w.WriteAsync("dev", "Acme.AI", Lesson))).Message);
        Assert.Contains("le PR della memoria non si leggono, solo develop: 503", await w.ReadAsync("dev", "comune"));
    }

    [Fact]
    public async Task Una_cartella_al_posto_del_worktree_che_git_non_conosce_non_si_tocca()
    {
        if (OperatingSystem.IsWindows()) return;
        var (w, _, _, _, wt) = World();
        Directory.CreateDirectory(wt);
        File.WriteAllText(Path.Combine(wt, "mio.txt"), "non toccare");
        Assert.Contains("non e un worktree registrato", (await Assert.ThrowsAsync<CardToolException>(() => w.WriteAsync("dev", "comune", Lesson))).Message);
        Assert.True(File.Exists(Path.Combine(wt, "mio.txt")));
    }

    [Fact]
    public void Il_lucchetto_ha_lo_stesso_nome_di_memoria_ps1()
    {
        // Get-NomeMutexMemoria: percorso completo, barre in avanti, minuscolo, SHA-256, i primi 16 caratteri
        Assert.Matches("^Global\\\\DevOps\\.Agents\\.Memoria-[0-9a-f]{16}$", GitMemoryWriter.MutexName("/x/_wt/DevOps.Agents/memoria"));
        Assert.Equal(GitMemoryWriter.MutexName("/x/_wt/DevOps.Agents/memoria/"), GitMemoryWriter.MutexName("/X/_wt/devops.agents/MEMORIA"));
    }
}
