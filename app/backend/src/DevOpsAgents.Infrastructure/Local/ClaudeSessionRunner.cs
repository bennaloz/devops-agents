using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Ports;
using DevOpsAgents.Infrastructure.Configuration;
using DevOpsAgents.Infrastructure.Secrets;

namespace DevOpsAgents.Infrastructure.Local;

public sealed record ClaudeRunnerOptions
{
    /// <summary>L'eseguibile della CLI (claude); nei test uno script finto.</summary>
    public string Executable { get; init; } = "claude";
    /// <summary>Argomenti messi davanti a quelli della sessione (per uno script finto: il suo percorso).</summary>
    public IReadOnlyList<string> PrefixArguments { get; init; } = [];
    public required string DataDir { get; init; }
}

/// <summary>
/// Le sessioni dei ruoli con claude -p, come Start-SessioneRuolo (src/Sessioni.psm1): modello, sforzo, advisor, brief del
/// ruolo, strumenti, nessun MCP, eventi stream-json su file. La sessione riceve solo i token in sola lettura.
/// </summary>
public sealed class ClaudeSessionRunner(SuiteConfig config, TokenStore tokens, ClaudeRunnerOptions options) : ISessionRunner
{
    private static readonly Regex Esito = new(@"(?m)^[\s`*]*ESITO=([^\s`*]+)[\s`*]*$", RegexOptions.Compiled);
    private static readonly Regex TokenLimit = new(@"(?i)(usage limit|limit reached|rate limit)", RegexOptions.Compiled);
    private readonly ConcurrentDictionary<string, Process> _processes = new();
    // chi copia l'uscita del processo nel file: si aspetta prima di leggere l'esito, o l'ultima riga puo mancare
    private readonly ConcurrentDictionary<string, Task> _pumps = new();

    public IReadOnlyCollection<string> Running => _processes.Where(p => !p.Value.HasExited).Select(p => p.Key).ToList();

    private string LogPath(string id) => Path.Combine(options.DataDir, "sessioni", $"{id}.jsonl");

    public static IReadOnlyList<string> Arguments(RoleSettings role, string brief, string message, string sessionId, bool resume)
    {
        var a = new List<string> { "-p", message, "--model", role.Model };
        if (!string.IsNullOrEmpty(role.Effort)) a.AddRange(["--effort", role.Effort]);
        if (!string.IsNullOrEmpty(role.Advisor)) a.AddRange(["--advisor", role.Advisor]);
        a.AddRange(["--output-format", "stream-json", "--verbose", resume ? "--resume" : "--session-id", sessionId, "--append-system-prompt-file", brief]);
        a.Add("--tools"); a.AddRange(role.Tools);
        a.Add("--allowedTools"); a.AddRange(role.Tools);
        a.AddRange(["--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--permission-mode", "acceptEdits"]);
        return a;
    }

    public Task<string> StartAsync(SessionRequest r, CancellationToken ct = default)
    {
        if (!config.Roles.TryGetValue(r.Role, out var role)) throw new InvalidOperationException($"Ruolo sconosciuto: {r.Role}");
        var id = r.Resume && r.SessionId is not null ? r.SessionId : Guid.NewGuid().ToString();
        Directory.CreateDirectory(Path.Combine(options.DataDir, "sessioni"));
        var psi = new ProcessStartInfo(options.Executable)
        {
            WorkingDirectory = r.WorkingFolder is { Length: > 0 } f && Directory.Exists(f) ? f : config.Root,
            RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
        };
        foreach (var a in options.PrefixArguments) psi.ArgumentList.Add(a);
        foreach (var a in Arguments(role, Path.Combine(config.Root, role.Brief), r.Message, id, r.Resume)) psi.ArgumentList.Add(a);

        // le variabili che leggono hook e card.ps1; mai i token di chi lancia, solo quelli in lettura
        var env = psi.Environment;
        env["ATTREZZI_CARD"] = r.CardId.ToString();
        env["ATTREZZI_RUOLO"] = r.Role;
        env["ATTREZZI_DATI"] = options.DataDir;
        env["ATTREZZI_BASE"] = r.BaseBranch ?? "develop";
        if (r.TaskId is { } t) env["ATTREZZI_TASK"] = t.ToString(); else env.Remove("ATTREZZI_TASK");
        foreach (var k in new[] { "AZURE_DEVOPS_EXT_PAT", "GH_TOKEN", "GITHUB_TOKEN", "DEVOPS_AGENTS_ADO_PAT", "DEVOPS_AGENTS_GITHUB_TOKEN" }) env.Remove(k);
        if (tokens.AzureDevOpsReadOnly is { } adoRead) env["AZURE_DEVOPS_EXT_PAT"] = adoRead;
        if (tokens.GitHubReadOnly is { } ghRead) env["GH_TOKEN"] = ghRead;

        var p = Process.Start(psi) ?? throw new InvalidOperationException($"{options.Executable} non parte");
        var log = LogPath(id);
        _pumps[id] = Task.Run(async () =>
        {
            await using var w = new StreamWriter(log, append: true);
            string? line;
            while ((line = await p.StandardOutput.ReadLineAsync()) is not null) { await w.WriteLineAsync(line); await w.FlushAsync(); }
        }, CancellationToken.None);
        _ = p.StandardError.ReadToEndAsync(CancellationToken.None);
        _processes[id] = p;
        return Task.FromResult(id);
    }

    public async Task<SessionResult?> PollAsync(string sessionId, CancellationToken ct = default)
    {
        var log = LogPath(sessionId);
        if (_processes.TryGetValue(sessionId, out var p) && !p.HasExited)
        {
            // in silenzio da troppo: si chiude e conta come finita senza esito (Close-Sessione dell'originale)
            var last = File.Exists(log) ? File.GetLastWriteTimeUtc(log) : p.StartTime.ToUniversalTime();
            if ((DateTime.UtcNow - last).TotalMinutes <= config.Limits.SilenceMinutes) return null;
            try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            _processes.TryRemove(sessionId, out _);
            return new SessionResult(null, $"chiusa dallo smistatore: nessun evento da {config.Limits.SilenceMinutes} minuti");
        }
        if (p is not null)
        {
            await p.WaitForExitAsync(ct);
            _processes.TryRemove(sessionId, out _);
        }
        if (_pumps.TryRemove(sessionId, out var pump)) await pump.WaitAsync(TimeSpan.FromSeconds(10), ct);
        return ParseResult(log);
    }

    /// <summary>L'esito dalla riga "type":"result" del flusso: l'ultima riga ESITO= del testo, e se la sessione e finita sul limite di token.</summary>
    public static SessionResult ParseResult(string logPath)
    {
        if (!File.Exists(logPath)) return new SessionResult(null, "la sessione non ha scritto niente");
        string? text = null;
        foreach (var line in File.ReadLines(logPath))
        {
            if (!line.Contains("\"result\"")) continue;
            JsonNode? n;
            try { n = JsonNode.Parse(line); } catch (System.Text.Json.JsonException) { continue; }
            if (n?["type"]?.GetValue<string>() == "result") text = n["result"]?.GetValue<string>() ?? "";
        }
        if (text is null) return new SessionResult(null, "la sessione e terminata senza evento result");
        var m = Esito.Matches(text);
        var outcome = m.Count > 0 ? m[^1].Groups[1].Value : null;
        return new SessionResult(outcome, text, outcome is null && TokenLimit.IsMatch(text));
    }
}

/// <summary>Lo stato locale delle card su file JSON, nella cartella dati (scrittura atomica: un file temporaneo e poi lo scambio).</summary>
public sealed class JsonStateStore(string path) : IStateStore
{
    public async Task<Dictionary<int, Core.Model.CardLocalState>> LoadAsync(CancellationToken ct = default)
    {
        if (!File.Exists(path)) return new();
        await using var s = File.OpenRead(path);
        return await System.Text.Json.JsonSerializer.DeserializeAsync<Dictionary<int, Core.Model.CardLocalState>>(s, SuiteConfig.Json, ct) ?? new();
    }

    public async Task SaveAsync(IReadOnlyDictionary<int, Core.Model.CardLocalState> state, CancellationToken ct = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var tmp = path + ".tmp";
        await using (var s = File.Create(tmp)) await System.Text.Json.JsonSerializer.SerializeAsync(s, state, SuiteConfig.Json, ct);
        File.Move(tmp, path, overwrite: true);
    }
}
