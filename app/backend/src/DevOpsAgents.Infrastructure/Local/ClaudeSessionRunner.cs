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
    /// <summary>La cartella ~/.claude (le credenziali di prova del collaudatore); nei test una finta.</summary>
    public string? ClaudeDir { get; init; }
    /// <summary>
    /// Il server MCP degli agenti (devops-agents-mcp): il comando e i suoi primi argomenti, per esempio ["dotnet", ".../devops-agents-mcp.dll"].
    /// Con questo le sessioni usano gli strumenti MCP al posto di card.ps1 e memoria.ps1; senza, card.ps1 come la versione PowerShell.
    /// </summary>
    public IReadOnlyList<string>? McpServer { get; init; }
    /// <summary>
    /// Gli hook .NET (devops-agents-hook): il comando e i suoi primi argomenti. Con questo ogni sessione riceve gli hook PreToolUse con --settings,
    /// anche se in ~/.claude/settings.json non sono installati; senza, valgono solo quelli installati (gli hook PowerShell).
    /// </summary>
    public IReadOnlyList<string>? HookCommand { get; init; }
    /// <summary>D46: il worktree fisso della memoria, che il server MCP del mentore usa per scrivere; null = il suo predefinito.</summary>
    public string? MemoryWorktree { get; init; }
}

/// <summary>
/// Le sessioni dei ruoli con claude -p, come Start-SessioneRuolo (src/Sessioni.psm1): modello, sforzo, advisor, brief del
/// ruolo, strumenti, eventi stream-json su file. La sessione riceve solo i token in sola lettura. L'unico server MCP e quello degli agenti
/// (se configurato), legato alla card e al ruolo della sessione; nessun altro (--strict-mcp-config).
/// </summary>
public sealed class ClaudeSessionRunner(SuiteConfig config, TokenStore tokens, ClaudeRunnerOptions options, IMemorySource? memory = null) : ISessionRunner
{
    private static readonly Regex Esito = new(@"(?m)^[\s`*]*ESITO=([^\s`*]+)[\s`*]*$", RegexOptions.Compiled);
    private static readonly Regex Lezione = new(@"(?m)^[\s`*]*LEZIONE:\s*([A-Za-z]+-\d+)(?:\s*\(in prova\))?[\s`*]*$", RegexOptions.Compiled);
    private readonly ConcurrentDictionary<string, Process> _processes = new();
    // chi copia l'uscita del processo nel file: si aspetta prima di leggere l'esito, o l'ultima riga puo mancare
    private readonly ConcurrentDictionary<string, Task> _pumps = new();

    public IReadOnlyCollection<string> Running => _processes.Where(p => !p.Value.HasExited).Select(p => p.Key).ToList();

    private string LogPath(string id) => Path.Combine(options.DataDir, "sessioni", $"{id}.jsonl");

    public static IReadOnlyList<string> Arguments(RoleSettings role, string brief, string message, string sessionId, bool resume, string? mcpConfig = null, string? settings = null)
    {
        var a = new List<string> { "-p", message, "--model", role.Model };
        if (!string.IsNullOrEmpty(role.Effort)) a.AddRange(["--effort", role.Effort]);
        if (!string.IsNullOrEmpty(role.Advisor)) a.AddRange(["--advisor", role.Advisor]);
        a.AddRange(["--output-format", "stream-json", "--verbose", resume ? "--resume" : "--session-id", sessionId, "--append-system-prompt-file", brief]);
        a.Add("--tools"); a.AddRange(role.Tools);
        // il server degli agenti espone solo gli strumenti del ruolo: si permettono tutti quelli che ha
        a.Add("--allowedTools"); a.AddRange(role.Tools); if (mcpConfig is not null) a.Add($"mcp__{Core.Agents.AgentBrief.ServerName}");
        a.AddRange(["--strict-mcp-config", "--mcp-config", mcpConfig ?? "{\"mcpServers\":{}}"]);
        if (settings is not null) a.AddRange(["--settings", settings]);
        a.AddRange(["--permission-mode", "acceptEdits"]);
        return a;
    }

    /// <summary>Le impostazioni della sessione con i soli hook PreToolUse .NET, uno per regola con il matcher di setup/Install-Attrezzi.ps1.</summary>
    public static string HookSettings(IReadOnlyList<string> hook, string root)
    {
        static string Q(string x) => x.Contains(' ') || x.Contains('"') ? $"\"{x.Replace("\"", "\\\"")}\"" : x;
        var pre = new System.Text.Json.Nodes.JsonArray();
        foreach (var (name, matcher) in Core.Hooks.HookRules.Matchers)
        {
            var command = string.Join(' ', hook.Select(Q).Concat([name, "--root", Q(root.Replace('\\', '/'))]));
            pre.Add(new JsonObject { ["matcher"] = matcher, ["hooks"] = new System.Text.Json.Nodes.JsonArray(new JsonObject { ["type"] = "command", ["command"] = command }) });
        }
        return new JsonObject { ["hooks"] = new JsonObject { ["PreToolUse"] = pre } }.ToJsonString();
    }

    /// <summary>La --mcp-config con il solo server degli agenti, legato a card, ruolo e task della sessione.</summary>
    public static string McpConfig(IReadOnlyList<string> server, int cardId, string role, int? taskId, string root, string dataDir, string? memoryWorktree = null)
    {
        var args = new System.Text.Json.Nodes.JsonArray();
        foreach (var x in server.Skip(1)) args.Add(x);
        foreach (var x in new[] { "--card", cardId.ToString(), "--ruolo", role }) args.Add(x);
        if (taskId is { } t) { args.Add("--task"); args.Add(t.ToString()); }
        foreach (var x in new[] { "--root", root, "--dati", dataDir }) args.Add(x);
        if (memoryWorktree is not null && role == "mentore") { args.Add("--worktree-memoria"); args.Add(memoryWorktree); }
        return new JsonObject { ["mcpServers"] = new JsonObject { [Core.Agents.AgentBrief.ServerName] = new JsonObject { ["command"] = server[0], ["args"] = args } } }
            .ToJsonString();
    }

    private bool UsesMcp(string role) => options.McpServer is { Count: > 0 } && role != "supervisore";

    public async Task<string> StartAsync(SessionRequest r, CancellationToken ct = default)
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
        var mcp = UsesMcp(r.Role) ? McpConfig(options.McpServer!, r.CardId, r.Role, r.TaskId, config.Root, options.DataDir, options.MemoryWorktree) : null;
        var hooks = options.HookCommand is { Count: > 0 } h ? HookSettings(h, config.Root) : null;
        foreach (var a in Arguments(role, await BriefAsync(r.Role, role, r.Area.Repo, id, r.TaskId, ct), r.Message, id, r.Resume, mcp, hooks)) psi.ArgumentList.Add(a);

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
        // le COLLAUDO_* di chi lancia non passano mai; il collaudatore riceve le credenziali di prova del repo (~/.claude/collaudo/<repo>.json)
        foreach (var k in env.Keys.Where(k => k.StartsWith("COLLAUDO_", StringComparison.Ordinal)).ToList()) env.Remove(k);
        if (r.Role == "collaudatore")
            foreach (var (k, v) in DockerTestEnvironments.Credentials(Path.Combine(options.ClaudeDir ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude"), "collaudo", $"{r.Area.Repo}.json")))
                env[k] = v;

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
        return id;
    }

    /// <summary>
    /// D46: il brief della sessione: quello del ruolo, con in fondo la sezione Memoria (lezioni stabili e in prova del repo) e, con il server
    /// MCP, la tabella degli strumenti che prendono il posto di card.ps1, in un file accanto all'uscita della sessione. Senza nessuna delle
    /// due, o se la lettura della memoria non riesce, il brief del ruolo.
    /// </summary>
    private async Task<string> BriefAsync(string roleName, RoleSettings role, string repo, string id, int? taskId, CancellationToken ct)
    {
        var path = Path.Combine(config.Root, role.Brief);
        var files = memory is null ? [] : await memory.GetAsync(roleName, repo, ct);
        var mcp = UsesMcp(roleName);
        if (files.Count == 0 && !mcp) return path;
        var composed = await File.ReadAllTextAsync(path, ct);
        if (files.Count > 0) composed = Core.Memory.Lessons.BriefWithMemory(composed, files);
        if (mcp) composed = composed.TrimEnd() + "\n" + Core.Agents.AgentBrief.McpSection(roleName, taskId, config.Roles);
        var target = Path.Combine(options.DataDir, "sessioni", $"{id}.brief.md");
        await File.WriteAllTextAsync(target, composed, ct);
        return target;
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
            return new SessionResult(null, $"chiusa dallo smistatore: nessun evento da {config.Limits.SilenceMinutes} minuti", NoResultCause: "silenzio");
        }
        if (p is not null)
        {
            await p.WaitForExitAsync(ct);
            _processes.TryRemove(sessionId, out _);
        }
        if (_pumps.TryRemove(sessionId, out var pump)) await pump.WaitAsync(TimeSpan.FromSeconds(10), ct);
        return ParseResult(log);
    }

    /// <summary>
    /// L'esito della sessione dal suo flusso, come Get-EsitoSessione: l'ultima riga ESITO= dell'evento result, la quota dall'ultimo
    /// rate_limit_event (finestre five_hour e seven_day), il limite di token dall'evento rejected o, in mancanza, dal testo
    /// "hit your ... limit" con una finestra piena. Un limite senza un reset leggibile non e un limite.
    /// </summary>
    public static SessionResult ParseResult(string logPath)
    {
        if (!File.Exists(logPath)) return new SessionResult(null, "la sessione non ha scritto niente", NoResultCause: "morta");
        string? text = null;
        JsonNode? final = null;
        Core.Model.QuotaInfo? quota = null;
        JsonNode? rejected = null;
        foreach (var line in File.ReadLines(logPath))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonNode? n;
            try { n = JsonNode.Parse(line); } catch (System.Text.Json.JsonException) { continue; }
            var type = n?["type"]?.GetValue<string>();
            if (type == "result") { final = n; text = n!["result"]?.GetValue<string>() ?? ""; }
            else if (type == "rate_limit_event")
            {
                var info = n!["rate_limit_info"];
                if (info?["unifiedWindows"] is JsonObject w)
                    quota = new Core.Model.QuotaInfo(null, Utilization(w["seven_day"]), Epoch(w["seven_day"]?["resetsAt"]), Utilization(w["five_hour"]), Epoch(w["five_hour"]?["resetsAt"]));
                if (info?["status"]?.GetValue<string>() == "rejected") rejected = info;
            }
        }
        if (text is null) return new SessionResult(null, "la sessione e terminata senza evento result", Quota: quota, NoResultCause: "morta");
        var m = Esito.Matches(text);
        var outcome = m.Count > 0 ? m[^1].Groups[1].Value : null;
        DateTimeOffset? reset = null;
        if (rejected is not null) reset = Epoch(rejected["resetsAt"]);
        else if (text.Contains("hit your", StringComparison.OrdinalIgnoreCase) && text.Contains("limit", StringComparison.OrdinalIgnoreCase) && quota is not null)
            reset = quota.FiveHourUtilization >= 1 ? quota.FiveHourResetsAt : quota.WeeklyUtilization >= 1 ? quota.WeeklyResetsAt : null;
        // un comando negato non e un errore se la sessione ha chiuso lo stesso con un esito; senza esito la sessione e fallita
        var isError = final?["is_error"] is JsonValue e && e.TryGetValue<bool>(out var b) && b;
        var subtypeKo = final?["subtype"] is JsonValue st && st.TryGetValue<string>(out var sub) && sub != "success";
        var denied = final?["permission_denials"] is JsonArray d && d.Count > 0;
        var failed = (isError || subtypeKo || (denied && outcome is null)) && reset is null;
        // D46: le lezioni che il ruolo dice di aver seguito, una riga LEZIONE: <id> ciascuna (con l'etichetta in prova copiata dal titolo)
        var lessons = Lezione.Matches(text).Select(x => x.Groups[1].Value).Distinct().ToList();
        return new SessionResult(outcome, text, reset is not null, reset, quota, failed, Lessons: lessons);
    }

    private static double? Utilization(JsonNode? w) => w?["utilization"] is JsonValue v && v.TryGetValue<double>(out var d) ? d : null;

    /// <summary>I resetsAt dei rate_limit_event sono secondi dal 1970.</summary>
    private static DateTimeOffset? Epoch(JsonNode? n) =>
        n is JsonValue v && (v.TryGetValue<double>(out var d) || (v.TryGetValue<string>(out var s) && double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out d)))
            ? DateTimeOffset.FromUnixTimeSeconds((long)d) : null;
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
