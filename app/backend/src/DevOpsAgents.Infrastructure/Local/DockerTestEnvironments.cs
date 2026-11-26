using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;

namespace DevOpsAgents.Infrastructure.Local;

/// <summary>
/// config/collaudo.json: il comando che raggiunge docker ({cartella} = la cartella del worktree; oggi wsl -d &lt;distro&gt; --cd {cartella}
/// -- docker, domani docker --context &lt;server&gt;), l'host degli URL, la porta base e i tempi massimi.
/// </summary>
public sealed record DockerSettings(IReadOnlyList<string> Command, string Host, int PortBase, double CreationMinutes, double CommandMinutes)
{
    public static DockerSettings? Load(string root)
    {
        var p = Path.Combine(root, "config", "collaudo.json");
        if (!File.Exists(p)) return null;
        var o = JsonNode.Parse(File.ReadAllText(p))!;
        return new DockerSettings(o["comandoDocker"]!.AsArray().Select(x => x!.GetValue<string>()).ToList(), o["host"]?.GetValue<string>() ?? "localhost",
            o["portaBase"]?.GetValue<int>() ?? 21000, o["minutiCreazione"]?.GetValue<double>() ?? 30, o["minutiComandi"]?.GetValue<double>() ?? 3);
    }
}

/// <summary>
/// D59: gli ambienti Docker di collaudo, come src/Collaudo.psm1. Docker si raggiunge da un solo punto (<see cref="RunDockerAsync"/>). La
/// creazione (down -v, poi up -d --build --wait) gira in un task del servizio e scrive l'esito in collaudo/card-&lt;id&gt;.json, cosi lo si
/// ritrova anche dopo un riavvio. Le variabili (porte, credenziali di prova) vanno solo al processo figlio e mai nei log.
/// </summary>
public sealed class DockerTestEnvironments(DockerSettings settings, string dataDir, string? claudeDir = null) : ITestEnvironments
{
    private readonly string _claude = claudeDir ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
    private readonly ConcurrentDictionary<int, (Task Work, CancellationTokenSource Stop)> _running = new();
    private string Dir => Path.Combine(dataDir, "collaudo");
    private string LogOf(string project) => Path.Combine(Dir, $"{project}.log");
    private string ResultOf(int card) => Path.Combine(Dir, $"card-{card}.json");

    /// <summary>portaBase + slot*100 + indice del nome nelle porte.</summary>
    public static IReadOnlyDictionary<string, int> Ports(TestEnvironmentSpec spec, int portBase, int slot) =>
        spec.Ports.Select((name, i) => (name, i)).ToDictionary(x => x.name, x => portBase + slot * 100 + x.i);

    public static IReadOnlyDictionary<string, string> Urls(TestEnvironmentSpec spec, string host, int portBase, int slot)
    {
        var ports = Ports(spec, portBase, slot);
        return spec.Urls.ToDictionary(u => u.Key, u => $"http://{host}:{ports[u.Value]}");
    }

    /// <summary>COLLAUDO_HOST, COLLAUDO_PORTA_&lt;NOME&gt; e le chiavi del file delle credenziali di prova come COLLAUDO_&lt;CHIAVE&gt;.</summary>
    public static Dictionary<string, string> Variables(TestEnvironmentSpec spec, string host, int portBase, int slot, string? credentialsFile)
    {
        var v = new Dictionary<string, string> { ["COLLAUDO_HOST"] = host };
        foreach (var (name, port) in Ports(spec, portBase, slot)) v[$"COLLAUDO_PORTA_{Key(name)}"] = port.ToString();
        foreach (var (k, value) in Credentials(credentialsFile)) v[k] = value;
        return v;
    }

    public static string Key(string name) => Regex.Replace(name.ToUpperInvariant(), "[^A-Z0-9_]", "_");

    /// <summary>Le credenziali di prova di un repo (~/.claude/collaudo/&lt;repo&gt;.json): chiave -> COLLAUDO_&lt;CHIAVE&gt;. Il messaggio non cita il contenuto.</summary>
    public static IEnumerable<KeyValuePair<string, string>> Credentials(string? file)
    {
        if (file is null || !File.Exists(file)) yield break;
        JsonObject o;
        try { o = JsonNode.Parse(File.ReadAllText(file))!.AsObject(); }
        catch (Exception e) when (e is System.Text.Json.JsonException or InvalidOperationException) { throw new InvalidDataException($"Il file delle credenziali di collaudo {file} non e un JSON valido"); }
        foreach (var (k, n) in o)
            if (n is null || n is JsonValue) yield return new($"COLLAUDO_{Key(k)}", n?.ToString() ?? "");
    }

    public string CredentialsFile(string repo) => Path.Combine(_claude, "collaudo", $"{repo}.json");

    /// <summary>L'unico punto che lancia docker: il comando di config/collaudo.json con {cartella}, poi gli argomenti.</summary>
    public async Task<(int Code, string Output, bool TimedOut)> RunDockerAsync(string folder, IReadOnlyList<string> args, IReadOnlyDictionary<string, string>? vars, string? log, double minutes, CancellationToken ct)
    {
        if (settings.Command.Count == 0) throw new InvalidOperationException("config/collaudo.json: 'comandoDocker' e vuoto");
        var withFolder = settings.Command.Any(c => c.Contains("{cartella}"));
        var parts = settings.Command.Select(c => c.Replace("{cartella}", folder)).ToList();
        var psi = new ProcessStartInfo(parts[0]) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in parts.Skip(1).Concat(args)) psi.ArgumentList.Add(a);
        if (!withFolder) psi.WorkingDirectory = folder;
        if (vars is { Count: > 0 })
        {
            foreach (var (k, v) in vars) psi.Environment[k] = v;
            // wsl.exe passa alla distro solo le variabili elencate in WSLENV: i nomi, mai i valori
            var wslenv = new[] { psi.Environment.TryGetValue("WSLENV", out var w) ? w : null }.Where(x => !string.IsNullOrEmpty(x)).Concat(vars.Keys.Select(k => $"{k}/u"));
            psi.Environment["WSLENV"] = string.Join(':', wslenv);
        }
        if (log is not null) Append(log, $"> {parts[0]} {string.Join(' ', parts.Skip(1).Concat(args))}");
        using var p = Process.Start(psi) ?? throw new InvalidOperationException($"{parts[0]} non parte");
        var outTask = p.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var errTask = p.StandardError.ReadToEndAsync(CancellationToken.None);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        if (minutes > 0) timeout.CancelAfter(TimeSpan.FromMinutes(minutes));
        var timedOut = false;
        try { await p.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            timedOut = true;
            try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            await p.WaitForExitAsync(CancellationToken.None);
        }
        var output = ((await outTask) + (await errTask)).TrimEnd();
        if (log is not null && output.Length > 0) Append(log, output);
        return (timedOut ? -1 : p.ExitCode, output, timedOut);
    }

    private void Append(string log, string line)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(log)!);
        File.AppendAllText(log, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}\n");
    }

    public Task<TestEnvironmentStarted> StartAsync(AreaMapping area, int cardId, int slot, string folder, CancellationToken ct = default)
    {
        var spec = area.TestEnvironment ?? throw new InvalidOperationException($"L'area {area.Area} non ha la voce collaudo nella mappa");
        Directory.CreateDirectory(Dir);
        var project = $"card-{cardId}";
        var log = LogOf(project);
        File.Delete(ResultOf(cardId));
        File.Delete(log);
        var startedAt = DateTimeOffset.UtcNow;
        var vars = Variables(spec, settings.Host, settings.PortBase, slot, CredentialsFile(area.Repo));
        var stop = new CancellationTokenSource();
        var work = Task.Run(async () =>
        {
            var outcome = "failed";
            try
            {
                string[] baseArgs = ["compose", "-p", project, "-f", spec.Compose];
                var down = await RunDockerAsync(folder, [.. baseArgs, "down", "-v"], vars, log, settings.CommandMinutes, stop.Token);
                if (down.Code != 0) Append(log, $"compose down: codice {down.Code}, si prosegue");
                var up = await RunDockerAsync(folder, [.. baseArgs, "up", "-d", "--build", "--wait"], vars, log, settings.CreationMinutes, stop.Token);
                if (up.TimedOut) Append(log, $"compose up: tempo scaduto dopo {settings.CreationMinutes} minuti");
                else if (up.Code != 0) Append(log, $"compose up: codice {up.Code}");
                else outcome = "succeeded";
            }
            catch (Exception e) { Append(log, $"creazione dell'ambiente non riuscita: {e.Message}"); }
            var tmp = ResultOf(cardId) + ".tmp";
            File.WriteAllText(tmp, new JsonObject { ["esito"] = outcome, ["avvio"] = startedAt.ToString("o"), ["fine"] = DateTimeOffset.UtcNow.ToString("o"), ["log"] = log }.ToJsonString());
            File.Move(tmp, ResultOf(cardId), overwrite: true);
        }, CancellationToken.None);
        _running[cardId] = (work, stop);
        return Task.FromResult(new TestEnvironmentStarted(project, Urls(spec, settings.Host, settings.PortBase, slot), log, startedAt));
    }

    /// <summary>Dal file di esito, se e della creazione che la card ha salvato (stesso avvio); senza file, in corso se il task vive, altrimenti fallita.</summary>
    public Task<PipelineRun> GetStatusAsync(int cardId, DateTimeOffset startedAt, CancellationToken ct = default)
    {
        var log = LogOf($"card-{cardId}");
        PipelineRun? Read()
        {
            var o = JsonFile.Read(ResultOf(cardId));
            if (o is null) return null;
            if (JsonFile.Date(o["avvio"]) is { } a && Math.Abs((a - startedAt).TotalSeconds) > 2) return null;
            return new PipelineRun("completed", o["esito"]?.GetValue<string>() == "succeeded" ? "succeeded" : "failed", log);
        }
        if (Read() is { } done) return Task.FromResult(done);
        if (_running.TryGetValue(cardId, out var r) && !r.Work.IsCompleted) return Task.FromResult(new PipelineRun("inProgress", null, log));
        return Task.FromResult(Read() ?? new PipelineRun("completed", "failed", log));
    }

    public async Task<bool> RemoveAsync(string project, string? folder, CancellationToken ct = default)
    {
        Directory.CreateDirectory(Dir);
        var log = LogOf(project);
        try
        {
            if (int.TryParse(project.Replace("card-", ""), out var id) && _running.TryRemove(id, out var r))
            {
                r.Stop.Cancel();
                try { await r.Work.WaitAsync(TimeSpan.FromMinutes(1), ct); } catch (TimeoutException) { }
            }
            var dir = folder is not null && Directory.Exists(folder) ? folder : Dir;
            var down = await RunDockerAsync(dir, ["compose", "-p", project, "down", "-v"], null, log, settings.CommandMinutes, ct);
            if (down.Code != 0) { Append(log, $"compose down -v: codice {down.Code}"); return false; }
            var vols = await RunDockerAsync(dir, ["volume", "ls", "-q", "--filter", $"label=com.docker.compose.project={project}"], null, log, settings.CommandMinutes, ct);
            if (vols.Code != 0) { Append(log, $"volume ls: codice {vols.Code}"); return false; }
            var names = vols.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Where(n => !n.StartsWith('>') && Regex.IsMatch(n, @"^[\w.-]+$")).ToList();
            if (names.Count > 0)
            {
                var rm = await RunDockerAsync(dir, ["volume", "rm", .. names], null, log, settings.CommandMinutes, ct);
                if (rm.Code != 0) { Append(log, $"volume rm: codice {rm.Code}"); return false; }
            }
            return true;
        }
        catch (Exception e) when (e is not OperationCanceledException) { Append(log, $"compose down -v non riuscito: {e.Message}"); return false; }
    }

    public async Task<IReadOnlyList<string>> ListProjectsAsync(CancellationToken ct = default)
    {
        Directory.CreateDirectory(Dir);
        var found = new SortedSet<string>();
        foreach (var args in new[]
        {
            new[] { "ps", "-a", "--filter", "label=acme.collaudo", "--format", "{{.Labels}}" },
            new[] { "volume", "ls", "--filter", "label=com.docker.compose.project", "--format", "{{.Labels}}" },
        })
        {
            var r = await RunDockerAsync(Dir, args, null, null, settings.CommandMinutes, ct);
            if (r.Code != 0) throw new InvalidOperationException($"docker {args[0]} e uscito con codice {r.Code}");
            foreach (Match m in Regex.Matches(r.Output, @"com\.docker\.compose\.project=(card-\d+)(?:,|$)", RegexOptions.Multiline)) found.Add(m.Groups[1].Value);
        }
        return found.ToList();
    }
}
