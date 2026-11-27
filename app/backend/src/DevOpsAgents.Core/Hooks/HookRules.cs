using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DevOpsAgents.Core.Hooks;

/// <summary>
/// L'esito di un hook: Deny blocca la chiamata (exit 2) e Message (stderr) torna al modello; altrimenti passa (exit 0), con un eventuale avviso.
/// Output va su stdout: il JSON che Claude Code legge (systemMessage, l'avviso per l'utente di suggest-compact).
/// </summary>
public sealed record HookVerdict(bool Deny, string? Message = null, string? Output = null)
{
    public static readonly HookVerdict Pass = new(false);
    public int ExitCode => Deny ? 2 : 0;
}

/// <summary>
/// Quello che gli hook leggono oltre all'input: il ruolo della sessione (ATTREZZI_RUOLO) e i file di config del repo. Per suggest-compact:
/// Env (le variabili COMPACT_*), ReadTail (la coda del transcript, null se non c'e) e il gradino gia avvisato per sessione (ReadStep, WriteStep).
/// </summary>
public sealed record HookContext(string? Role, Func<string, string?> ReadConfig, string ConfigDir = "config",
    Func<string, string?>? Env = null, Func<string, string?>? ReadTail = null, Func<string, int?>? ReadStep = null, Action<string, int>? WriteStep = null);

/// <summary>
/// Gli hook PreToolUse di Claude Code (hooks/*.ps1), con le stesse regole e gli stessi messaggi: presidi contro l'errore, non recinzioni.
/// I casi di prova sono quelli di hooks/Test-Hooks.ps1. Le espressioni hanno IgnoreCase dove PowerShell usa -match (che non distingue le
/// maiuscole) e niente dove usa [regex]::Matches.
/// </summary>
public static class HookRules
{
    public static readonly string[] Names = ["deny-commit-outside-worktree", "deny-secrets-in-repo", "deny-pat", "deny-identita", "deny-host-collaudo", "deny-no-verify", "suggest-compact"];

    /// <summary>Gli strumenti su cui si aggancia ciascun hook (il matcher di settings.json, come setup/Install-Attrezzi.ps1).</summary>
    public static readonly IReadOnlyDictionary<string, string> Matchers = new Dictionary<string, string>
    {
        ["deny-commit-outside-worktree"] = "Bash|PowerShell",
        ["deny-secrets-in-repo"] = "Write|Edit",
        ["deny-pat"] = "Bash|PowerShell|Read",
        ["deny-identita"] = "Bash|PowerShell",
        ["deny-host-collaudo"] = "Bash|PowerShell|WebFetch",
        ["deny-no-verify"] = "Bash|PowerShell",
        ["suggest-compact"] = "Edit|Write",
    };

    private const RegexOptions I = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
    private static bool M(string input, string pattern) => Regex.IsMatch(input, pattern, I);

    public static HookVerdict Run(string hook, string payloadJson, HookContext ctx)
    {
        // gli hook di ruolo non leggono nemmeno l'input fuori da una sessione di ruolo
        if (hook is "deny-pat" or "deny-identita" && string.IsNullOrWhiteSpace(ctx.Role)) return HookVerdict.Pass;
        if (hook == "deny-host-collaudo" && ctx.Role != "collaudatore") return HookVerdict.Pass;
        JsonNode? payload;
        try { payload = JsonNode.Parse(payloadJson); }
        catch (JsonException e) { return new(false, $"hook: input non interpretabile, controllo saltato - {e.Message}"); }
        var input = payload?["tool_input"];
        string S(JsonNode? n, string name) => n?[name] is JsonValue v ? (v.TryGetValue<string>(out var s) ? s : v.ToJsonString()) : n?[name]?.ToJsonString() ?? "";
        return hook switch
        {
            "deny-commit-outside-worktree" => CommitOutsideWorktree(S(input, "command"), S(payload, "cwd")),
            "deny-secrets-in-repo" => SecretsInRepo(S(input, "file_path"), string.Concat(new[] { "content", "new_string", "new_str" }.Select(f => S(input, f)).Where(v => v.Length > 0).Select(v => "\n" + v))),
            "deny-pat" => Pat(S(input, "command"), S(input, "file_path")),
            "deny-identita" => Identity(S(input, "command")),
            "deny-host-collaudo" => TesterHosts(string.Join("\n", new[] { S(input, "command"), S(input, "url") }.Where(x => x.Length > 0)), ctx),
            "deny-no-verify" => NoVerify(S(input, "command")),
            "suggest-compact" => SuggestCompact(S(payload, "transcript_path"), S(payload, "session_id"), ctx),
            _ => throw new ArgumentException($"hook sconosciuto: '{hook}' ({string.Join(", ", Names)})"),
        };
    }

    // ---- deny-commit-outside-worktree ----------------------------------------------------------------------------------

    /// <summary>Un git commit si fa solo in un worktree sotto _wt: la working copy principale non e nostra.</summary>
    public static HookVerdict CommitOutsideWorktree(string command, string cwd)
    {
        if (string.IsNullOrWhiteSpace(command)) return HookVerdict.Pass;
        // git come comando (a inizio riga o dopo ; & | ( {), le sue opzioni globali, poi commit: le parole dentro un testo non contano
        if (!Regex.IsMatch(command, @"(?im)(?:^|[;&|({])\s*git(?:\.exe)?(?:\s+(?:-[Cc]\s+(?:""[^""]*""|'[^']*'|\S+)|--\S+))*\s+commit\b", I)) return HookVerdict.Pass;
        if (M(command, @"(?i)\bcommit-tree\b") || M(command, "(?i)--dry-run")) return HookVerdict.Pass;
        var target = cwd;
        Match m;
        if ((m = Regex.Match(command, @"(?i)\bgit\s+-C\s+""?([^""\s]+)""?", I)).Success) target = m.Groups[1].Value;
        else if ((m = Regex.Match(command, @"(?i)(?:^|&&|;)\s*(?:cd|chdir|pushd|sl|Push-Location|Set-Location)(?:\s+-(?:LiteralPath|Path))?\s+""?([^""&;]+?)""?\s*(?:&&|;|$)", I)).Success)
            target = m.Groups[1].Value.Trim();
        if (target.Replace('/', '\\').ToLowerInvariant().Contains("\\_wt\\")) return HookVerdict.Pass;
        return new(true, $"""
            Commit bloccato: non sei in un worktree.

              percorso rilevato: {target}

            La working copy principale non e' nostra - l'utente ha altre sessioni aperte e cambia ramo
            mentre lavoriamo. Si committa solo sotto C:\develop\GIT\_wt\<repo>\<slug>.

              git fetch origin
              git worktree add "C:\develop\GIT\_wt\<repo>\<slug>" -b <ramo> origin/develop

            Vedi la skill 'worktree'. Se il commit deve davvero avvenire qui, chiedilo all'utente.
            """);
    }

    // ---- deny-secrets-in-repo ----------------------------------------------------------------------------------------

    private static readonly HashSet<string> ApprovedVerbs = new(("Add,Clear,Close,Copy,Enter,Exit,Find,Format,Get,Hide,Join,Lock,Move,New,Open,Optimize,Push,Pop,Redo,Remove,Rename,Reset," +
        "Resize,Search,Select,Set,Show,Skip,Split,Step,Switch,Undo,Unlock,Watch,Connect,Disconnect,Read,Receive,Send,Write,Backup,Checkpoint,Compare,Compress,Convert," +
        "ConvertFrom,ConvertTo,Dismount,Edit,Expand,Export,Group,Import,Initialize,Limit,Merge,Mount,Out,Publish,Restore,Save,Sync,Unpublish,Update,Debug,Measure,Ping," +
        "Repair,Resolve,Test,Trace,Approve,Assert,Build,Complete,Confirm,Deny,Deploy,Disable,Enable,Install,Invoke,Register,Request,Restart,Resume,Start,Stop,Submit," +
        "Suspend,Uninstall,Unregister,Wait,Use,Block,Grant,Protect,Revoke,Unblock,Unprotect").Split(','), StringComparer.OrdinalIgnoreCase);

    /// <summary>Un segreto (una chiave sensibile con un valore vero) non si scrive in un file di configurazione o in uno script del repo.</summary>
    public static HookVerdict SecretsInRepo(string path, string content)
    {
        if (string.IsNullOrWhiteSpace(path)) return HookVerdict.Pass;
        if (M(path, @"(?i)\.template\.")) return HookVerdict.Pass;
        if (!M(path, @"(?i)\.(json|config|xml|yml|yaml|ps1|psm1|env|ini|sh)$")) return HookVerdict.Pass;
        if (string.IsNullOrWhiteSpace(content)) return HookVerdict.Pass;
        const string pattern = @"(?i)(password|pwd|apikey|api_key|clientsecret|client_secret|accesskey|token)[a-z_]*\s*[""']?\s*[:=]\s*([""']?)([^""'\s,;}]{6,})";
        var isPowerShell = M(path, @"(?i)\.(ps1|psm1)$");
        var isCode = isPowerShell || M(path, @"(?i)\.sh$");

        bool LooksLikeCode(string quote, string value, string before, string after)
        {
            if (!isCode) return false;
            if (before.Count(c => c == '\'') % 2 != 0 || before.Count(c => c == '"') % 2 != 0) return false;
            if (quote != "'" && M(value, @"^\$\{?[\w:]+\}?(\.\w+(\(\w*\))?)*$")) return !M(after, @"[""']");
            if (quote != "'" && M(value, @"^\$")) return false;
            if (!isPowerShell || quote != "") return false;
            if (M(value, @"^[\[(@{]")) return true;
            if (M(value, @"^[A-Za-z_][\w.:]*\(")) return true;
            var v = Regex.Match(value, @"^([A-Za-z]+)-[A-Za-z]\w*$", I);
            return v.Success && ApprovedVerbs.Contains(v.Groups[1].Value);
        }

        foreach (Match match in Regex.Matches(content, pattern))
        {
            var value = match.Groups[3].Value;
            if (M(value, @"(?i)^(\{\{|<|\$\(|%|\*{3}|changeme|placeholder|your|xxx|todo|secret|env:)")) continue;
            if (M(value, "(?i)^(true|false|null|none|empty|0)$")) continue;
            // un indirizzo dice dove chiedere il segreto, non lo contiene; con utente e password prima della @ si
            if (M(value, @"(?i)^https?://[^/@\s]+(/|$)") && !value.Contains('@')) continue;
            var lineStart = match.Index == 0 ? 0 : content.LastIndexOf('\n', match.Index - 1) + 1;
            var before = content[lineStart..match.Index];
            var end = match.Index + match.Length;
            var lineEnd = content.IndexOf('\n', end);
            if (lineEnd < 0) lineEnd = content.Length;
            if (LooksLikeCode(match.Groups[2].Value, value, before, content[end..lineEnd])) continue;
            return new(true, $"""
                Scrittura bloccata: sembra un segreto in un file del repo.

                  file:   {path}
                  chiave: {match.Groups[1].Value}

                I segreti non si committano mai. Nei file del repo solo valori non segreti (endpoint,
                livelli di log, host senza password). Il segreto va in un ADO Library Variable Group
                dell'ambiente (variabile SECRET, iniettata al deploy come variabile d'ambiente del
                servizio), oppure in 'dotnet user-secrets' per lo sviluppo locale. Al suo posto si committa
                un appsettings.{"{Env}"}.template.json con il segnaposto.

                Se e' un falso positivo, dillo all'utente invece di aggirare l'hook.
                """);
        }
        return HookVerdict.Pass;
    }

    // ---- deny-pat ----------------------------------------------------------------------------------------------------

    /// <summary>In una sessione di ruolo il PAT, i token di GitHub, il login di az e le credenziali di collaudo non si leggono ne si nominano.</summary>
    public static HookVerdict Pat(string command, string filePath)
    {
        var text = string.Join("\n", new[] { command, filePath }.Where(x => x.Length > 0));
        if (string.IsNullOrWhiteSpace(text)) return HookVerdict.Pass;
        if (!M(text, @"(?i)pat(-[\w-]+)?\.txt|AZURE_DEVOPS_EXT_PAT|\bGH_TOKEN\b|\bGITHUB_TOKEN\b|\bgh\s+auth\s+(token|login)\b|\.claude[\\/]collaudo|get-access-token|\baz(\.cmd)?\s+login\b|msal_token_cache|AZURE_CONFIG_DIR|(^|[\s\\/~""'=:])\.azure([\s\\/""']|$)"))
            return HookVerdict.Pass;
        // una sola chiamata a card.ps1 puo nominare il file nel testo di un commento; un testo letterale in testa (here-string a apici
        // singoli con una pipe, heredoc con il delimitatore quotato) si toglie, e il resto deve essere comunque la sola chiamata
        var c = command;
        Match m;
        if ((m = Regex.Match(c, @"(?s)^\s*@'\r?\n.*?\r?\n'@\s*\|(?<resto>.*)$", I)).Success) c = m.Groups["resto"].Value;
        else if ((m = Regex.Match(c, @"(?s)^(?<resto>[^\r\n]*?)\s*<<-?\s*'(?<fine>\w+)'\r?\n.*\r?\n\k<fine>\s*$", I)).Success) c = m.Groups["resto"].Value + " ";
        if (M(c, @"(?i)^\s*(pwsh|powershell)(\.exe)?\s+(-\w+\s+)*-File\s+""?[^\s""]*card\.ps1""?\s") &&
            !M(Regex.Replace(Regex.Replace(c, "\"[^\"]*\"", "", I), "'[^']*'", "", I), "[;&|`\r\n]"))
            return HookVerdict.Pass;
        return new(true, """
            Bloccato: il PAT di Azure DevOps e il login di az non si leggono ne si nominano.

            Le chiamate ad Azure DevOps passano da card.ps1 (leggi, commenta, criteri, sposta), che carica il PAT da solo
            dentro il suo processo. Non chiamare az per prendere un token e non toccare AZURE_CONFIG_DIR ne la cartella .azure. Se ti serve qualcosa che card.ps1 non fa, chiedilo all'utente.
            """);
    }

    // ---- deny-identita -----------------------------------------------------------------------------------------------

    /// <summary>In una sessione di ruolo non si cambiano le variabili ATTREZZI_* e non si caricano a mano i moduli di src/.</summary>
    public static HookVerdict Identity(string command)
    {
        if (string.IsNullOrWhiteSpace(command)) return HookVerdict.Pass;
        var variables = M(command, "(?i)ATTREZZI_");
        var module = M(command, @"(?i)(\bimport-module\b|\bipmo\b|\busing\s+module\b|(?:^|[;&|(]\s*)\.\s+\S)") && M(command, @"(?i)\.psm1\b|[/\\]src[/\\]");
        if (!(variables || module)) return HookVerdict.Pass;
        return new(true, """
            Bloccato: in questa sessione la card si legge e si scrive solo con card.ps1.

            Non si cambiano le variabili d'ambiente della sessione e non si caricano a mano i moduli di src/.
            Se card.ps1 ti nega un gesto, il gesto non e' tuo: scrivilo in un commento e chiudi con l'ESITO previsto.
            """);
    }

    // ---- deny-host-collaudo ------------------------------------------------------------------------------------------

    /// <summary>
    /// Gli host che il collaudatore puo chiamare: quelli degli urlTest della mappa (qualunque porta), l'organizzazione e Azure DevOps, GitHub
    /// se un'area e su GitHub, l'host degli ambienti di collaudo (config/collaudo.json), localhost e 127.0.0.1. Errore se un file non si legge.
    /// </summary>
    public static HashSet<string> TesterAllowedHosts(string? mappaJson, string? collaudoJson)
    {
        var allowed = new HashSet<string>(["acme.visualstudio.com", "dev.azure.com", "localhost", "127.0.0.1"], StringComparer.OrdinalIgnoreCase);
        var map = JsonNode.Parse(mappaJson ?? throw new FileNotFoundException("mappa.json non trovato"));
        static string? HostOf(string? u) => Uri.TryCreate(u, UriKind.Absolute, out var x) && x.Host.Length > 0 ? x.Host : null;
        var areas = map?["aree"]?.AsArray().Where(a => a is not null).ToList() ?? [];
        if (areas.Any(a => a!["sorgente"]?.GetValue<string>() == "github")) { allowed.Add("github.com"); allowed.Add("api.github.com"); }
        if (HostOf(map?["organizzazione"]?.GetValue<string>()) is { } org) allowed.Add(org);
        foreach (var a in areas) if (HostOf(a!["urlTest"]?.GetValue<string>()) is { } h) allowed.Add(h);
        if (collaudoJson is not null && JsonNode.Parse(collaudoJson)?["host"]?.GetValue<string>() is { Length: > 0 } th) allowed.Add(th);
        return allowed;
    }

    /// <summary>Gli host nominati nel testo: negli URL e, senza schema, dopo -Uri o come primo argomento di curl e wget.</summary>
    public static IReadOnlyList<string> HostsIn(string text)
    {
        var found = Regex.Matches(text, @"(?i)\bhttps?://(?:[^/\s@""'`]*@)?(?<h>[^/:\s""'`?#\)\]]+)").Select(m => m.Groups["h"].Value).ToList();
        foreach (Match m in Regex.Matches(text, @"(?i)(?:-Uri\s+|\b(?:curl|wget)(?:\.exe)?\s+(?:-\S+\s+)*)[""']?(?<h>[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)+)(?::\d+)?(?:[/""'\s;|&]|$)"))
            if (!M(m.Groups["h"].Value, "^(?i)https?$")) found.Add(m.Groups["h"].Value);
        return found;
    }

    public static HookVerdict TesterHosts(string text, HookContext ctx)
    {
        if (string.IsNullOrWhiteSpace(text)) return HookVerdict.Pass;
        var mappa = $"{ctx.ConfigDir}/mappa.json";
        var collaudo = $"{ctx.ConfigDir}/collaudo.json";
        HashSet<string> allowed;
        try { allowed = TesterAllowedHosts(ctx.ReadConfig("mappa.json"), null); }
        catch (Exception e) { return new(true, $"Bloccato: non riesco a leggere gli host di Test da {mappa} ({e.Message}). Chiudi con ESITO=bloccato."); }
        try { if (ctx.ReadConfig("collaudo.json") is { } c) allowed.UnionWith(TesterAllowedHosts("{}", c)); }
        catch (Exception e) { return new(true, $"Bloccato: non riesco a leggere l'host degli ambienti di collaudo da {collaudo} ({e.Message}). Chiudi con ESITO=bloccato."); }
        foreach (var h in HostsIn(text))
        {
            // un host costruito con variabili non si puo valutare: passa
            if (M(h, "[${}%]")) continue;
            if (!allowed.Contains(h.TrimEnd('.')))
                return new(true, $"""
                    Bloccato: l'host '{h}' non e' tra quelli che il collaudatore puo chiamare.

                    Gli host ammessi sono quelli degli urlTest di config/mappa.json (ambiente di Test, qualunque porta), l'host degli
                    ambienti di collaudo di config/collaudo.json, Azure DevOps, localhost e 127.0.0.1. Se per provare la card ti serviva davvero questo indirizzo, chiudi con ESITO=bloccato e scrivi
                    il motivo sulla card.
                    """);
        }
        return HookVerdict.Pass;
    }

    // ---- deny-no-verify ----------------------------------------------------------------------------------------------

    /// <summary>
    /// Un comando git che salta gli hook di git (--no-verify, commit -n, core.hooksPath) si rifiuta, in ogni sessione. Prima del controllo si
    /// tolgono i corpi degli heredoc e delle here-string e il testo fra virgolette: un messaggio di commit che nomina --no-verify non e un aggiramento.
    /// </summary>
    public static HookVerdict NoVerify(string command)
    {
        if (string.IsNullOrWhiteSpace(command) || !M(command, @"\bgit\b")) return HookVerdict.Pass;
        var text = Regex.Replace(command, @"(?s)<<-?\s*['""]?(\w+)['""]?.*?\n\s*\1\b", "", I);
        text = Regex.Replace(text, @"(?s)@'.*?\n'@", "", I);
        text = Regex.Replace(text, @"(?s)@"".*?\n""@", "", I);
        var unquoted = Regex.Replace(text, @"(?s)'[^']*'|""[^""]*""", "\"\"", I);
        string? reason = null;
        if (M(unquoted, @"--no-verify\b")) reason = "--no-verify";
        else if (M(text, @"\bcore\.hooksPath\b")) reason = "core.hooksPath";
        else
            // commit -n (anche dentro un gruppo di flag corti come -anm), solo nel pezzo di comando fino al prossimo separatore
            foreach (var piece in Regex.Split(unquoted, @"&&|\|\||[;|\n]"))
            {
                var m = Regex.Match(piece, @"\bgit\b.*\bcommit\b(.*)$", I);
                if (m.Success && M(m.Groups[1].Value, @"(?<=\s)-[a-zA-Z]*n[a-zA-Z]*\b")) { reason = "commit -n"; break; }
            }
        if (reason is null) return HookVerdict.Pass;
        return new(true, $"""
            Bloccato: il comando salta gli hook di git ({reason}).

            Gli hook di git sono controlli del repo. Se uno fallisce, leggi l'errore e correggi la causa.
            Se pensi che l'hook sbagli, dillo all'utente: saltarlo lo decide lui, e il comando lo lancia lui.
            """);
    }

    // ---- suggest-compact ---------------------------------------------------------------------------------------------

    public const int CompactThresholdDefault = 150000, CompactIntervalDefault = 75000;

    /// <summary>Il contesto della sessione: l'ultimo "usage" del transcript (input + cache letta + cache creata), fuori dalle sidechain; 0 se non c'e.</summary>
    public static long ContextTokens(string tail)
    {
        var lines = tail.Split('\n');
        for (var i = lines.Length - 1; i >= 0; i--)
        {
            var line = lines[i];
            if (!line.Contains("\"usage\"") || Regex.IsMatch(line, "\"isSidechain\":true")) continue;
            JsonNode? entry;
            try { entry = JsonNode.Parse(line); } catch (JsonException) { continue; }   // la prima riga della coda puo essere tagliata
            if (entry?["message"]?["usage"] is not JsonObject u) continue;
            long N(string k) => u[k] is JsonValue v && v.TryGetValue<long>(out var n) ? n : 0;
            return N("input_tokens") + N("cache_read_input_tokens") + N("cache_creation_input_tokens");
        }
        return 0;
    }

    /// <summary>Il gradino raggiunto: null sotto la soglia, 0 alla soglia, 1 a soglia+intervallo, ...</summary>
    public static long? CompactStep(long tokens, int threshold, int interval) => tokens < threshold ? null : (tokens - threshold) / interval;

    /// <summary>
    /// Quando il contesto supera la soglia avvisa l'utente che e un buon momento per /compact: una volta per gradino, per sessione. Non blocca
    /// mai. COMPACT_SOGLIA_TOKEN e COMPACT_INTERVALLO_TOKEN cambiano soglia e intervallo.
    /// </summary>
    public static HookVerdict SuggestCompact(string transcriptPath, string sessionId, HookContext ctx)
    {
        if (string.IsNullOrWhiteSpace(transcriptPath) || ctx.ReadTail?.Invoke(transcriptPath) is not { } tail) return HookVerdict.Pass;
        if (string.IsNullOrWhiteSpace(sessionId)) sessionId = Path.GetFileNameWithoutExtension(transcriptPath);
        static int Positive(string? s, int d) => int.TryParse(s, out var n) && n > 0 ? n : d;
        var threshold = Positive(ctx.Env?.Invoke("COMPACT_SOGLIA_TOKEN"), CompactThresholdDefault);
        var interval = Positive(ctx.Env?.Invoke("COMPACT_INTERVALLO_TOKEN"), CompactIntervalDefault);
        var tokens = ContextTokens(tail);
        if (CompactStep(tokens, threshold, interval) is not { } step) return HookVerdict.Pass;
        var key = Regex.Replace(sessionId, @"[^\w-]", "_");
        if (step <= (ctx.ReadStep?.Invoke(key) ?? -1)) return HookVerdict.Pass;
        ctx.WriteStep?.Invoke(key, (int)step);
        var message = $"Contesto a {Math.Round(tokens / 1000.0)}k token: se hai chiuso una fase, e' un buon momento per /compact.";
        return new(false, Output: new JsonObject { ["systemMessage"] = message }.ToJsonString());
    }
}
