using System.Diagnostics;
using System.Net.Http.Headers;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using DevOpsAgents.Core.Hooks;

namespace DevOpsAgents.Infrastructure.Setup;

/// <summary>
/// L'installazione in .NET, come setup/Install-Attrezzi.ps1: gli hook .NET in ~/.claude/settings.json, le skill del sistema, i token di GitHub
/// e i due PAT di Azure DevOps. La pianificazione non serve piu: smistatore, supervisore e dashboard sono il servizio (Windows o systemd).
/// Ogni passo scrive su Output quello che ha fatto; un errore lancia con un messaggio che non contiene mai un token.
/// </summary>
public sealed class Installer(string claudeDir, TextWriter output)
{
    // ---- gli hook -------------------------------------------------------------------------------------------------

    /// <summary>
    /// Aggiunge a settings.json le cinque voci PreToolUse con il comando .NET (senza toccare le altre chiavi, senza duplicare una voce gia
    /// presente: il confronto non guarda barre e maiuscole), dopo una copia di salvataggio accanto al file.
    /// </summary>
    public void InstallHooks(IReadOnlyList<string> hookCommand, string root)
    {
        var file = Path.Combine(claudeDir, "settings.json");
        Directory.CreateDirectory(claudeDir);
        var text = File.Exists(file) ? File.ReadAllText(file) : "";
        var settings = string.IsNullOrWhiteSpace(text) ? new JsonObject() : JsonNode.Parse(text) as JsonObject ?? throw new InvalidDataException($"{file} non e un oggetto JSON");
        if (settings["hooks"] is not JsonObject hooks) settings["hooks"] = hooks = new JsonObject();
        if (hooks["PreToolUse"] is not JsonArray pre) hooks["PreToolUse"] = pre = new JsonArray();
        static string Norm(string? c) => (c ?? "").Replace('\\', '/').ToLowerInvariant();
        var existing = pre.SelectMany(v => v?["hooks"] as JsonArray ?? []).Select(h => Norm(h?["command"]?.GetValue<string>())).ToHashSet();
        static string Q(string x) => x.Contains(' ') ? $"\"{x}\"" : x;
        var added = 0;
        foreach (var (name, matcher) in HookRules.Matchers)
        {
            var command = string.Join(' ', hookCommand.Select(x => Q(x.Replace('\\', '/'))).Concat([name, "--root", Q(root.Replace('\\', '/').TrimEnd('/'))]));
            if (existing.Contains(Norm(command))) continue;
            pre.Add(new JsonObject { ["matcher"] = matcher, ["hooks"] = new JsonArray(new JsonObject { ["type"] = "command", ["command"] = command }) });
            added++;
        }
        if (added == 0) { output.WriteLine("Hook: tutte le voci erano gia presenti, niente da fare"); return; }
        if (File.Exists(file))
        {
            var copy = $"{file}.bak-{DateTime.Now:yyyyMMdd-HHmmss-fff}";
            File.Copy(file, copy);
            output.WriteLine($"Hook: copia di salvataggio in {copy}");
        }
        File.WriteAllText(file, settings.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
        output.WriteLine($"Hook: aggiunte {added} voci a {file}");
    }

    // ---- le skill -------------------------------------------------------------------------------------------------

    /// <summary>
    /// I collegamenti delle skill: regole-sviluppo -> regole/ e devops-agents -> skills/devops-agents/ del repo (giunzioni su Windows, link
    /// simbolici altrove). Un collegamento che c'e e punta altrove non si tocca; quello del nome vecchio (card-agenti) si toglie se puntava al repo.
    /// </summary>
    public void InstallSkills(string root)
    {
        var skills = Path.Combine(claudeDir, "skills");
        Directory.CreateDirectory(skills);
        foreach (var (name, rel) in new[] { ("regole-sviluppo", "regole"), ("devops-agents", "skills/devops-agents") })
        {
            var link = Path.Combine(skills, name);
            var target = Path.GetFullPath(Path.Combine(root, rel));
            if (!Directory.Exists(target)) throw new DirectoryNotFoundException($"Manca {target} nel repo degli attrezzi");
            var info = new DirectoryInfo(link);
            if (info.Exists || info.LinkTarget is not null)
            {
                if (info.LinkTarget is { } t && Same(Path.GetFullPath(t, skills), target)) { output.WriteLine($"Regole: collegamento gia presente ({link})"); continue; }
                throw new InvalidOperationException($"Esiste gia {link} e non e il collegamento atteso verso {target}: non lo tocco");
            }
            CreateLink(link, target);
            output.WriteLine($"Regole: creato il collegamento {link} -> {target}");
        }
        var old = new DirectoryInfo(Path.Combine(skills, "card-agenti"));
        if (old.LinkTarget is { } ot && Path.GetFullPath(ot, skills).StartsWith(Path.GetFullPath(root).TrimEnd('/', '\\') + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            old.Delete();
            output.WriteLine($"Regole: tolto il collegamento del nome vecchio {old.FullName}");
        }
    }

    private static bool Same(string a, string b) => string.Equals(a.TrimEnd('/', '\\'), b.TrimEnd('/', '\\'), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static void CreateLink(string link, string target)
    {
        if (!OperatingSystem.IsWindows()) { Directory.CreateSymbolicLink(link, target); return; }
        // una giunzione non chiede i permessi da amministratore che chiede un link simbolico
        var psi = new ProcessStartInfo("cmd.exe") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in new[] { "/c", "mklink", "/J", link, target }) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException($"mklink /J {link} non riuscito: {p.StandardError.ReadToEnd()}");
    }

    // ---- i token --------------------------------------------------------------------------------------------------

    /// <summary>
    /// Un token su file: su Windows cifrato con DPAPI per l'utente, nel formato di ConvertFrom-SecureString (lo leggono anche gli script
    /// PowerShell); altrove in chiaro, leggibile solo dall'utente.
    /// </summary>
    public static void WriteToken(string path, string value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        if (OperatingSystem.IsWindows()) { File.WriteAllText(path, Protect(value), new UTF8Encoding(false)); return; }
        File.WriteAllText(path, value, new UTF8Encoding(false));
        File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }

    [SupportedOSPlatform("windows")]
    private static string Protect(string value) =>
        Convert.ToHexString(ProtectedData.Protect(Encoding.Unicode.GetBytes(value), null, DataProtectionScope.CurrentUser)).ToLowerInvariant();

    /// <summary>I due token di GitHub (fine-grained, creati a mano): pat-github.txt per lo smistatore e pat-github-lettura.txt per le sessioni.</summary>
    public void SaveGitHubTokens(string write, string read)
    {
        foreach (var (file, value, what) in new[] { ("pat-github.txt", write, "smistatore"), ("pat-github-lettura.txt", read, "lettura") })
        {
            if (string.IsNullOrWhiteSpace(value)) throw new InvalidOperationException($"Token di GitHub ({what}) vuoto: niente salvato");
            WriteToken(Path.Combine(claudeDir, file), value.Trim());
            output.WriteLine($"PatGitHub: salvato {Path.Combine(claudeDir, file)}");
        }
    }

    // ---- i PAT di Azure DevOps ------------------------------------------------------------------------------------

    public const string AdoResource = "499b84ac-1321-427f-aa17-267ca6975798";
    private const string PatApiVersion = "7.1-preview.1";

    /// <summary>az: codice e uscita (il token non si stampa mai).</summary>
    public delegate (int Code, string Output) AzRunner(params string[] args);

    public static (int Code, string Output) RunAz(params string[] args)
    {
        var psi = new ProcessStartInfo(OperatingSystem.IsWindows() ? "az.cmd" : "az") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        try
        {
            using var p = Process.Start(psi)!;
            var o = p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            p.WaitForExit();
            return (p.ExitCode, o.Trim());
        }
        catch (System.ComponentModel.Win32Exception) { return (-1, ""); }
    }

    /// <summary>Il nome dell'organizzazione: &lt;org&gt;.visualstudio.com o dev.azure.com/&lt;org&gt;.</summary>
    public static string OrganizationName(string url)
    {
        var u = new Uri(url);
        if (u.Host.EndsWith(".visualstudio.com", StringComparison.OrdinalIgnoreCase)) return u.Host.Split('.')[0];
        return u.AbsolutePath.Trim('/').Split('/')[0] is { Length: > 0 } first ? first : throw new InvalidOperationException($"Non riesco a ricavare il nome dell'organizzazione da {url}");
    }

    /// <summary>
    /// Install-Pat: con un token di az crea i due PAT (config/pat.json: scope, durata, nomi), li scrive in pat-smistatore.txt e
    /// pat-smistatore-lettura.txt con la scadenza in pat-info.json, poi revoca i vecchi. I due vanno insieme: se il secondo o la scrittura non
    /// riescono, i nuovi si revocano e i file di prima restano. Se il login di az l'ha fatto questa procedura, alla fine lo toglie.
    /// </summary>
    public async Task InstallPatAsync(string patConfigPath, string organizationUrl, HttpClient http, AzRunner? az = null, CancellationToken ct = default)
    {
        az ??= RunAz;
        var cfg = ReadPatConfig(patConfigPath);
        if (az("version", "--output", "none").Code == -1) throw new InvalidOperationException("Azure CLI (az) non c'e: installala, poi rilancia devops-agents setup --pat.");
        var org = OrganizationName(organizationUrl);
        var loginDone = false;
        var created = new Dictionary<string, (string Value, string Id, string ValidTo)>();
        try
        {
            if (az("account", "show", "--output", "none").Code != 0)
            {
                output.WriteLine("Pat: nessun login az: lo faccio ora (serve solo per creare i PAT, poi lo tolgo).");
                loginDone = true;
                if (az("login", "--allow-no-subscriptions", "--output", "none").Code != 0) throw new InvalidOperationException("az login non riuscito: nessun PAT creato.");
            }
            var (code, token) = az("account", "get-access-token", "--resource", AdoResource, "--query", "accessToken", "--output", "tsv");
            if (code != 0 || string.IsNullOrWhiteSpace(token)) throw new InvalidOperationException("az non ha dato il token per Azure DevOps: nessun PAT creato.");
            var api = $"https://vssps.dev.azure.com/{org}/_apis/tokens/pats";

            async Task RevokeAsync(string id)
            {
                using var req = new HttpRequestMessage(HttpMethod.Delete, $"{api}?authorizationId={Uri.EscapeDataString(id)}&api-version={PatApiVersion}");
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                using var res = await http.SendAsync(req, ct);
                // un PAT gia sparito risponde 404: e gia l'esito voluto
                if (!res.IsSuccessStatusCode && (int)res.StatusCode != 404) throw new HttpRequestException($"revoca del PAT {id} fallita: {(int)res.StatusCode}");
            }
            async Task RevokeNewAsync()
            {
                foreach (var (k, v) in created)
                    try { await RevokeAsync(v.Id); } catch { output.WriteLine($"Pat: non sono riuscito a revocare il PAT appena creato '{k}' (authorizationId {v.Id})."); }
            }

            var validTo = DateTime.UtcNow.AddDays(cfg.Days);
            try
            {
                foreach (var (key, name, scope) in cfg.Tokens)
                {
                    using var req = new HttpRequestMessage(HttpMethod.Post, $"{api}?api-version={PatApiVersion}")
                    {
                        Content = new StringContent(new JsonObject { ["displayName"] = name, ["scope"] = string.Join(' ', scope), ["validTo"] = validTo.ToString("o"), ["allOrgs"] = false }.ToJsonString(), Encoding.UTF8, "application/json"),
                    };
                    req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                    using var res = await http.SendAsync(req, ct);
                    var body = await res.Content.ReadAsStringAsync(ct);
                    if (!res.IsSuccessStatusCode) throw new HttpRequestException($"Chiamata all'API dei PAT fallita (POST {api}): {(int)res.StatusCode} {(body.Length > 300 ? body[..300] : body)}".Replace(token, "***"));
                    var t = JsonNode.Parse(body)?["patToken"];
                    var value = t?["token"]?.GetValue<string>();
                    if (string.IsNullOrWhiteSpace(value)) throw new InvalidOperationException($"L'API dei PAT non ha restituito il PAT '{name}'.");
                    created[key] = (value, t!["authorizationId"]?.GetValue<string>() ?? "", t["validTo"]?.ToString() ?? validTo.ToString("o"));
                    output.WriteLine($"Pat: creato '{name}' (scade {created[key].ValidTo})");
                }
            }
            catch { await RevokeNewAsync(); throw; }

            var infoPath = Path.Combine(claudeDir, "pat-info.json");
            var old = new List<string>();
            try
            {
                if (File.Exists(infoPath) && JsonNode.Parse(File.ReadAllText(infoPath)) is JsonObject info)
                {
                    foreach (var k in new[] { "smistatore", "solaLettura" }) if (info[k]?["authorizationId"]?.GetValue<string>() is { Length: > 0 } id) old.Add(id);
                    foreach (var id in info["daRevocare"] as JsonArray ?? []) if (id?.GetValue<string>() is { Length: > 0 } s) old.Add(s);
                }
            }
            catch { output.WriteLine("Pat: pat-info.json illeggibile, i PAT vecchi non si revocano da qui."); }
            old = old.Distinct().ToList();
            string Info(IReadOnlyList<string> toRevoke)
            {
                var n = new JsonObject();
                foreach (var (k, v) in created) n[k] = new JsonObject { ["authorizationId"] = v.Id, ["validTo"] = v.ValidTo };
                if (toRevoke.Count > 0) n["daRevocare"] = new JsonArray(toRevoke.Select(x => (JsonNode)JsonValue.Create(x)!).ToArray());
                return n.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true });
            }

            // solo ora, con i due PAT in mano, si scrive su disco: prima i .nuovo, poi al posto dei veri; se qualcosa non va i file di prima restano
            var targets = new[] { Path.Combine(claudeDir, "pat-smistatore.txt"), Path.Combine(claudeDir, "pat-smistatore-lettura.txt"), infoPath };
            try
            {
                WriteToken(targets[0] + ".nuovo", created["smistatore"].Value);
                WriteToken(targets[1] + ".nuovo", created["solaLettura"].Value);
                File.WriteAllText(targets[2] + ".nuovo", Info(old), new UTF8Encoding(false));
                Publish(targets);
            }
            catch (Exception e)
            {
                foreach (var t in targets) File.Delete(t + ".nuovo");
                await RevokeNewAsync();
                throw new InvalidOperationException($"Pat: scrittura dei file fallita, i PAT appena creati sono stati revocati e i file di prima sono rimasti com'erano: {e.Message}");
            }
            output.WriteLine($"Pat: scritti pat-smistatore.txt e pat-smistatore-lettura.txt{(OperatingSystem.IsWindows() ? " (cifrati con DPAPI)" : " (leggibili solo da te)")} e pat-info.json. pat.txt resta tuo.");
            var notRevoked = new List<string>();
            foreach (var id in old)
            {
                try { await RevokeAsync(id); output.WriteLine($"Pat: revocato il PAT vecchio {id}"); }
                catch (Exception e) { notRevoked.Add(id); output.WriteLine($"Pat: il PAT vecchio {id} non si e revocato ({e.Message}). Resta in pat-info.json (daRevocare): il prossimo --pat lo riprova."); }
            }
            if (old.Count > 0 && notRevoked.Count != old.Count) File.WriteAllText(infoPath, Info(notRevoked), new UTF8Encoding(false));
        }
        finally
        {
            if (loginDone) output.WriteLine(az("logout").Code == 0 ? "Pat: login az tolto." : "Pat: az logout non e riuscito: il login az e ancora attivo. Fai az logout a mano.");
        }
    }

    /// <summary>I file nuovi al posto dei veri, tutti o nessuno.</summary>
    private static void Publish(IReadOnlyList<string> targets)
    {
        var done = new List<(string Target, string? Previous)>();
        try
        {
            foreach (var t in targets)
            {
                string? prev = null;
                if (File.Exists(t)) { prev = t + ".prec"; File.Move(t, prev, true); }
                try { File.Move(t + ".nuovo", t, true); }
                catch { if (prev is not null) File.Move(prev, t, true); throw; }
                done.Add((t, prev));
            }
        }
        catch
        {
            foreach (var (t, p) in done) { File.Delete(t); if (p is not null) File.Move(p, t, true); }
            throw;
        }
        foreach (var (_, p) in done) if (p is not null) File.Delete(p);
    }

    private sealed record PatConfig(int Days, IReadOnlyList<(string Key, string Name, IReadOnlyList<string> Scope)> Tokens);

    /// <summary>config/pat.json letto e controllato prima di qualunque login: durata, e per ciascun PAT nome e scope.</summary>
    private static PatConfig ReadPatConfig(string path)
    {
        JsonNode cfg;
        try { cfg = JsonNode.Parse(File.ReadAllText(path))!; }
        catch (Exception e) { throw new InvalidDataException($"Config dei PAT illeggibile ({path}): {e.Message}"); }
        var days = cfg["durataGiorni"] is JsonValue d && d.TryGetValue<int>(out var n) && n > 0 ? n
            : throw new InvalidDataException($"Config dei PAT ({path}): durataGiorni manca o non e un numero maggiore di zero. Nessun login fatto.");
        var tokens = new List<(string, string, IReadOnlyList<string>)>();
        foreach (var k in new[] { "smistatore", "solaLettura" })
        {
            var name = cfg[k]?["nome"]?.GetValue<string>();
            if (string.IsNullOrWhiteSpace(name)) throw new InvalidDataException($"Config dei PAT ({path}): manca il nome di '{k}'. Nessun login fatto.");
            var scope = (cfg[k]?["scope"] as JsonArray ?? []).Select(x => x?.GetValue<string>()).Where(x => !string.IsNullOrWhiteSpace(x)).Cast<string>().ToList();
            if (scope.Count == 0) throw new InvalidDataException($"Config dei PAT ({path}): mancano gli scope di '{k}'. Nessun login fatto.");
            tokens.Add((k, name, scope));
        }
        return new(days, tokens);
    }
}
