using System.Diagnostics;
using System.Text.Json.Nodes;
using DevOpsAgents.Core.Update;
using DevOpsAgents.Infrastructure.Local;
using Xunit;

namespace DevOpsAgents.Infrastructure.Tests;

public class SuiteUpdaterTests
{
    static SuiteUpdaterTests()
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

    private static void CopyDir(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from)) File.Copy(f, Path.Combine(to, Path.GetFileName(f)));
    }

    private sealed class World
    {
        public required string Origin, Upstream, Root, Data;
        public Occupancy Busy = new(0, 0);
        public List<string> Notices { get; } = [];
        public int Exclusive;

        public SuiteUpdater Updater() => new(new UpdaterOptions(Root, Data, 30, 6, null, "true"), () => Busy,
            async a => { Exclusive++; return await a(); }, (t, h) => { Notices.Add($"{t}: {h}"); return Task.FromResult(true); });

        /// <summary>Un commit nuovo su origin/main (dalla copia "upstream").</summary>
        public string Push(string file, string text, string message = "Merged PR 7: una novita")
        {
            File.WriteAllText(Path.Combine(Upstream, file), text);
            Git(Upstream, "add", "-A"); Git(Upstream, "commit", "-q", "-m", message); Git(Upstream, "push", "-q", "origin", "main");
            return Git(Upstream, "rev-parse", "HEAD");
        }
    }

    /// <summary>Un origin con main e la configurazione vera della suite, una copia degli attrezzi clonata, una cartella dati.</summary>
    private static World Make()
    {
        var tmp = Directory.CreateTempSubdirectory("aggiorna").FullName;
        var origin = Path.Combine(tmp, "origin.git");
        Git(tmp, "init", "-q", "--bare", "-b", "main", origin);
        var up = Path.Combine(tmp, "upstream");
        Git(tmp, "clone", "-q", origin, up);
        Git(up, "checkout", "-q", "-B", "main");
        CopyDir(Path.Combine(Tx.Root, "config"), Path.Combine(up, "config"));
        CopyDir(Path.Combine(Tx.Root, "ruoli"), Path.Combine(up, "ruoli"));
        File.WriteAllText(Path.Combine(up, "config", "requisiti.json"), """{ "dotnet": "6.0" }""");
        Git(up, "add", "-A"); Git(up, "commit", "-q", "-m", "inizio"); Git(up, "push", "-q", "origin", "main");
        var root = Path.Combine(tmp, "DevOps.Agents");
        Git(tmp, "clone", "-q", "-b", "main", origin, root);
        return new World { Origin = origin, Upstream = up, Root = root, Data = Path.Combine(tmp, "dati") };
    }

    private static readonly DateTimeOffset Now = new(2026, 11, 26, 10, 0, 0, TimeSpan.Zero);
    private static string Outcome(JsonObject s) => s["ultimoEsito"]!["esito"]!.GetValue<string>();

    [Fact]
    public async Task Una_versione_nuova_si_prende_in_fast_forward_con_lo_smistatore_fermo_e_le_PR_in_arrivo()
    {
        if (OperatingSystem.IsWindows()) return;
        var w = Make();
        var tip = w.Push("LEGGIMI.md", "nuovo");
        var s = await w.Updater().RunAsync(Now);
        Assert.Equal("aggiornato", Outcome(s));
        Assert.Equal(tip, Git(w.Root, "rev-parse", "HEAD"));
        Assert.Equal(1, w.Exclusive);
        Assert.Equal(tip[..7], s["installata"]!["hash"]!.GetValue<string>());
        Assert.Null(s["disponibile"]);
        Assert.False(s["riavvioNecessario"]!.GetValue<bool>());
        Assert.Contains(w.Notices, n => n.StartsWith("aggiornamenti: 🔄 <b>Suite aggiornata</b>") && n.Contains("PR 7: una novita"));
        Assert.Equal("aggiornato", Outcome(w.Updater().Status()));
        // un giro dopo, niente di nuovo: l'esito resta quello dell'aggiornamento
        var again = await w.Updater().RunAsync(Now.AddHours(1));
        Assert.Equal(s["ultimoEsito"]!["quando"]!.GetValue<string>(), again["ultimoEsito"]!["quando"]!.GetValue<string>());
    }

    [Fact]
    public async Task Con_l_automatico_spento_dice_che_c_e_da_aggiornare_e_la_richiesta_lo_fa()
    {
        if (OperatingSystem.IsWindows()) return;
        var w = Make();
        Directory.CreateDirectory(w.Data);
        File.WriteAllText(Path.Combine(w.Data, "impostazioni.json"), """{ "aggiornamentoAutomatico": false }""");
        w.Push("a.txt", "x");
        var s = await w.Updater().RunAsync(Now);
        Assert.Equal("daAggiornare", Outcome(s));
        Assert.Equal(7, s["prInArrivo"]![0]!["numero"]!.GetValue<int>());
        var u = w.Updater();
        u.Request();
        Assert.Equal("aggiornato", Outcome(await u.RunAsync(Now.AddMinutes(1))));
        Assert.False(File.Exists(u.RequestPath));
    }

    [Fact]
    public async Task Con_sessioni_in_corso_aspetta_e_lo_dice_oltre_la_soglia_una_volta()
    {
        if (OperatingSystem.IsWindows()) return;
        var w = Make();
        var before = Git(w.Root, "rev-parse", "HEAD");
        w.Push("a.txt", "x");
        w.Busy = new(2, 0);
        var s = await w.Updater().RunAsync(Now);
        Assert.Equal((UpdateRules.WaitingForSessions, 2), (Outcome(s), s["ultimoEsito"]!["sessioni"]!.GetValue<int>()));
        Assert.Equal(before, Git(w.Root, "rev-parse", "HEAD"));
        var later = await w.Updater().RunAsync(Now.AddHours(7));
        Assert.True(later["ultimoEsito"]!["oltreSoglia"]!.GetValue<bool>());
        Assert.Equal(Now.ToString("o"), later["ultimoEsito"]!["da"]!.GetValue<string>());
        await w.Updater().RunAsync(Now.AddHours(8));
        Assert.Single(w.Notices, n => n.Contains("in attesa"));
    }

    [Fact]
    public async Task Le_modifiche_locali_ai_limiti_vanno_in_impostazioni_e_le_altre_fermano()
    {
        if (OperatingSystem.IsWindows()) return;
        var w = Make();
        w.Push("a.txt", "x");
        var limiti = Path.Combine(w.Root, "config", "limiti.json");
        var o = JsonNode.Parse(File.ReadAllText(limiti))!.AsObject();
        o["sessioniAttive"] = 5;
        File.WriteAllText(limiti, o.ToJsonString());
        Assert.Equal("aggiornato", Outcome(await w.Updater().RunAsync(Now)));
        Assert.Equal(5, JsonNode.Parse(File.ReadAllText(Path.Combine(w.Data, "impostazioni.json")))!["limiti"]!["sessioniAttive"]!.GetValue<int>());
        Assert.Equal("", Git(w.Root, "status", "--porcelain"));
        Assert.Equal(5, Configuration.SuiteConfig.Load(w.Root, Path.Combine(w.Data, "impostazioni.json")).Limits.ActiveSessions);

        w.Push("b.txt", "y");
        File.WriteAllText(Path.Combine(w.Root, "mio.txt"), "mio");
        var s = await w.Updater().RunAsync(Now.AddHours(1));
        Assert.Equal("modificheLocali", Outcome(s));
        Assert.Equal("mio.txt", s["ultimoEsito"]!["file"]![0]!.GetValue<string>());
    }

    [Fact]
    public async Task Una_versione_che_non_si_verifica_si_scarta_si_torna_indietro_e_non_si_riprova()
    {
        if (OperatingSystem.IsWindows()) return;
        var w = Make();
        var before = Git(w.Root, "rev-parse", "HEAD");
        var bad = w.Push("config/limiti.json", "{ rotto");
        var s = await w.Updater().RunAsync(Now);
        Assert.Equal("fallitoTornatoIndietro", Outcome(s));
        Assert.Contains("la configurazione della versione nuova non si legge", s["ultimoEsito"]!["errore"]!.GetValue<string>());
        Assert.Equal(before, Git(w.Root, "rev-parse", "HEAD"));
        Assert.Equal(bad, s["scartato"]!.GetValue<string>());
        Assert.Contains(w.Notices, n => n.Contains("fallito, tornato alla versione di prima"));
        Assert.Equal("fallitoTornatoIndietro", Outcome(await w.Updater().RunAsync(Now.AddHours(1))));
        Assert.Equal(before, Git(w.Root, "rev-parse", "HEAD"));
        // origine va oltre con una correzione: si riprova
        w.Push("config/limiti.json", File.ReadAllText(Path.Combine(Tx.Root, "config", "limiti.json")), "Merged PR 8: corregge i limiti");
        Assert.Equal("aggiornato", Outcome(await w.Updater().RunAsync(Now.AddHours(2))));
    }

    [Fact]
    public async Task Un_requisito_che_manca_ferma_l_aggiornamento_e_lo_dice()
    {
        if (OperatingSystem.IsWindows()) return;
        var w = Make();
        w.Push("config/requisiti.json", """{ "dotnet": "99.0" }""");
        var s = await w.Updater().RunAsync(Now);
        Assert.Equal("requisitiMancanti", Outcome(s));
        Assert.Equal(("dotnet", "99.0"), (s["ultimoEsito"]!["elenco"]![0]!["nome"]!.GetValue<string>(), s["ultimoEsito"]!["elenco"]![0]!["richiesta"]!.GetValue<string>()));
    }

    [Fact]
    public async Task Una_prova_non_scrive_niente_e_non_avanza()
    {
        if (OperatingSystem.IsWindows()) return;
        var w = Make();
        var before = Git(w.Root, "rev-parse", "HEAD");
        Git(w.Root, "fetch", "-q");
        w.Push("a.txt", "x");
        Git(w.Root, "fetch", "-q");
        var log = new List<string>();
        await w.Updater().RunAsync(Now, whatIf: true, log: log.Add);
        Assert.Equal(before, Git(w.Root, "rev-parse", "HEAD"));
        Assert.False(File.Exists(Path.Combine(w.Data, "aggiornamento.json")));
        Assert.Contains(log, l => l.StartsWith("aggiornamento: avanzerei main"));
    }
}
