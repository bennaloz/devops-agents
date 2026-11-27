using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

// devops-agents: la riga di comando per le persone. Parla con il servizio (API su localhost) e non tocca ne la board ne i repo da sola.
// Gli agenti usano gli strumenti del server MCP (o card.ps1 con lo smistatore PowerShell), non questa riga di comando.

var url = Environment.GetEnvironmentVariable("DEVOPS_AGENTS_URL") ?? "http://localhost:18800";
var http = new HttpClient { BaseAddress = new Uri(url), Timeout = TimeSpan.FromMinutes(5) };
http.DefaultRequestHeaders.Add("X-DevOps-Agents", "1");

return await Cli.RunAsync(args, http, Console.Out);

public static class Cli
{
    public const string Usage = """
        devops-agents <comando>

          stato                         stato del servizio: modalita, scrittura, pausa, ultimo giro
          giro [--prova] [--card <id>]  un giro dello smistatore adesso (--prova: non scrive niente)
          pausa | riprendi              la pausa di tutto il sistema (D60)
          feature                       le Feature in ordine di priorita
          feature pausa <id>            mette in pausa una Feature (e riprendi <id>)
          feature sposta <id> <dopo>    la mette subito dopo la Feature <dopo> (0 = in cima)
          da-fare                       cosa aspetta una persona, secondo il supervisore
          aggiornamento                 lo stato dell'aggiornamento della suite (D53)
          aggiorna                      aggiorna la suite adesso (al prossimo giro del supervisore)
          setup [--hook] [--regole] [--pat] [--pat-github] [--root <repo>] [--claude <cartella>]
                                        installa hook .NET, skill, PAT di Azure DevOps e token di GitHub (in locale)
          crea --tipo <User Story|Bug|Feature> --titolo <testo> --area <area> --file <markdown>
               [--feature <id>] [--dopo <id>[,<id>...]] [--senza-test] [--prova-umana] [--bug] [--raggruppa]
                                        crea una card figlia di una Feature, o una Feature (card.ps1 crea)

        Il servizio si raggiunge su DEVOPS_AGENTS_URL (default http://localhost:18800).
        """;

    public static async Task<int> RunAsync(string[] args, HttpClient http, TextWriter output)
    {
        try
        {
            switch (args)
            {
                case ["stato"]:
                {
                    var s = await http.GetFromJsonAsync<JsonObject>("/api/status");
                    output.WriteLine($"modalita {s!["mode"]}, scrittura {(s["allowWrites"]!.GetValue<bool>() ? "accesa" : "spenta")}, " +
                        $"giro automatico {(s["autoRun"]!.GetValue<bool>() ? "acceso" : "spento")}, sistema {(s["systemPaused"]!.GetValue<bool>() ? "IN PAUSA" : "attivo")}, " +
                        $"ultimo giro {s["lastRound"]?.ToString() ?? "mai"}");
                    return 0;
                }
                case ["giro", .. var rest]:
                {
                    var whatIf = rest.Contains("--prova");
                    var cardIndex = Array.IndexOf(rest, "--card");
                    var card = cardIndex >= 0 && cardIndex + 1 < rest.Length ? $"&card={int.Parse(rest[cardIndex + 1])}" : "";
                    var res = await http.PostAsync($"/api/round?whatIf={whatIf.ToString().ToLowerInvariant()}{card}", null);
                    if (res.StatusCode == System.Net.HttpStatusCode.Conflict) { output.WriteLine("un giro e gia in corso"); return 2; }
                    res.EnsureSuccessStatusCode();
                    var r = await res.Content.ReadFromJsonAsync<JsonObject>();
                    foreach (var line in r!["log"]!.AsArray()) output.WriteLine(line);
                    if (r["log"]!.AsArray().Count == 0) output.WriteLine("niente da fare");
                    return 0;
                }
                case ["pausa"] or ["riprendi"]:
                    (await http.PostAsync($"/api/system/pause?active={(args[0] == "pausa").ToString().ToLowerInvariant()}", null)).EnsureSuccessStatusCode();
                    output.WriteLine(args[0] == "pausa" ? "sistema in pausa: le sessioni in corso finiscono, nessuna card parte" : "sistema ripreso");
                    return 0;
                case ["feature"]:
                {
                    var fs = await http.GetFromJsonAsync<JsonArray>("/api/features");
                    var i = 0;
                    foreach (var f in fs!) output.WriteLine($"{++i,3}. #{f!["id"]} {f["title"]}{(f["paused"]!.GetValue<bool>() ? " (in pausa)" : "")}");
                    return 0;
                }
                case ["feature", "pausa" or "riprendi", var id]:
                    await PostOk(http, $"/api/features/{int.Parse(id)}/pause?active={(args[1] == "pausa").ToString().ToLowerInvariant()}");
                    output.WriteLine($"Feature {id}: {(args[1] == "pausa" ? "in pausa" : "ripresa")}");
                    return 0;
                case ["feature", "sposta", var id, var after]:
                    await PostOk(http, $"/api/features/{int.Parse(id)}/move?after={int.Parse(after)}");
                    output.WriteLine($"Feature {id} spostata dopo {after}");
                    return 0;
                case ["da-fare"]:
                {
                    var s = await http.GetFromJsonAsync<JsonObject>("/api/supervisor");
                    var ps = s!["problems"]!.AsArray();
                    if (ps.Count == 0) output.WriteLine("niente da fare per te");
                    foreach (var p in ps)
                    {
                        output.WriteLine($"{(p!["urgent"]!.GetValue<bool>() ? "[URGENTE] " : "")}{p["text"]}");
                        output.WriteLine($"   -> {p["action"]}{(p["link"] is { } l ? $" ({l})" : "")}");
                    }
                    return 0;
                }
                case ["crea", .. var rest]:
                    return await CreateAsync(rest, http, output);
                case ["aggiornamento"]:
                {
                    var u = await http.GetFromJsonAsync<JsonObject>("/api/update");
                    if (u!["spento"] is not null) { output.WriteLine("aggiornamento della suite spento"); return 0; }
                    var e = u["ultimoEsito"];
                    output.WriteLine($"canale {u["canale"]}, installata {u["installata"]?["hash"]}, disponibile {u["disponibile"]?["hash"]?.ToString() ?? "niente di nuovo"}, " +
                        $"esito {e?["esito"]}{(e?["errore"] is { } err ? $" ({err})" : "")}{(u["riavvioNecessario"]?.GetValue<bool>() == true ? ", serve un riavvio del servizio" : "")}");
                    foreach (var p in u["prInArrivo"]?.AsArray() ?? []) output.WriteLine($"  PR {p!["numero"]}: {p["titolo"]}");
                    return 0;
                }
                case ["aggiorna"]:
                    await PostOk(http, "/api/update");
                    output.WriteLine("richiesta fatta: la suite si aggiorna al prossimo giro del supervisore (devops-agents aggiornamento per l'esito)");
                    return 0;
                case ["setup", .. var rest]:
                    return await SetupAsync(rest, output);
                default:
                    output.WriteLine(Usage);
                    return args.Length == 0 || args is ["--help" or "-h" or "aiuto"] ? 0 : 1;
            }
        }
        catch (HttpRequestException e)
        {
            output.WriteLine($"il servizio non risponde su {http.BaseAddress}: {e.Message}");
            return 3;
        }
    }

    /// <summary>
    /// card.ps1 crea: il markdown con le sezioni Descrizione, Criteri di accettazione, Recinto, Riferimenti. Ogni card sta in una Feature (D60);
    /// -Tipo Feature crea la funzionalita con la card di chiusura (D52), con --raggruppa solo la Feature. Mai dentro una sessione di ruolo.
    /// </summary>
    private static async Task<int> CreateAsync(string[] a, HttpClient http, TextWriter output)
    {
        if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("ATTREZZI_RUOLO")))
        {
            output.WriteLine("card: 'crea' non e permesso dentro una sessione di ruolo");
            return 1;
        }
        string? Value(string name) => Array.IndexOf(a, name) is var i and >= 0 && i + 1 < a.Length ? a[i + 1] : null;
        bool Flag(string name) => a.Contains(name);
        var missing = new[] { "--tipo", "--titolo", "--area", "--file" }.Where(n => Value(n) is null).ToList();
        if (missing.Count > 0) { output.WriteLine($"card: manca {string.Join(", ", missing)}"); return 1; }
        var file = Value("--file")!;
        if (!File.Exists(file)) { output.WriteLine($"card: File non trovato: '{file}'"); return 1; }
        var after = Value("--dopo")?.Split([',', ' '], StringSplitOptions.RemoveEmptyEntries).Select(int.Parse).ToArray();
        var body = new JsonObject
        {
            ["type"] = Value("--tipo"), ["title"] = Value("--titolo"), ["area"] = Value("--area"), ["text"] = await File.ReadAllTextAsync(file),
            ["after"] = after is null ? null : new JsonArray(after.Select(x => (JsonNode)x).ToArray()),
            ["noTest"] = Flag("--senza-test"), ["humanTest"] = Flag("--prova-umana"), ["bug"] = Flag("--bug"), ["group"] = Flag("--raggruppa"),
            ["feature"] = Value("--feature") is { } f ? int.Parse(f) : null,
        };
        var res = await http.PostAsync("/api/cards", new StringContent(body.ToJsonString(), System.Text.Encoding.UTF8, "application/json"));
        var text = await res.Content.ReadAsStringAsync();
        var json = text.TrimStart().StartsWith('{') ? JsonNode.Parse(text) : null;
        if (!res.IsSuccessStatusCode) { output.WriteLine($"card: {json?["error"]?.ToString() ?? $"{(int)res.StatusCode} {res.ReasonPhrase}"}"); return 1; }
        output.WriteLine(json?["message"]?.ToString());
        return 0;
    }

    /// <summary>
    /// Install-Attrezzi.ps1 in .NET, in locale: --hook (gli hook .NET in ~/.claude/settings.json), --regole (le skill), --pat (i due PAT di Azure
    /// DevOps con az), --pat-github (i token di GitHub, chiesti senza mostrarli). La pianificazione non c'e piu: il servizio la sostituisce.
    /// </summary>
    private static async Task<int> SetupAsync(string[] a, TextWriter output)
    {
        string? Value(string name) => Array.IndexOf(a, name) is var i and >= 0 && i + 1 < a.Length ? a[i + 1] : null;
        var steps = new[] { "--hook", "--regole", "--pat", "--pat-github" }.Where(a.Contains).ToList();
        if (steps.Count == 0) { output.WriteLine("setup: indica cosa installare: --hook, --regole, --pat, --pat-github"); return 1; }
        var root = Value("--root") ?? DevOpsAgents.Infrastructure.Configuration.SuiteConfig.FindRoot(Directory.GetCurrentDirectory());
        var claude = Value("--claude") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
        var installer = new DevOpsAgents.Infrastructure.Setup.Installer(claude, output);
        try
        {
            if (steps.Contains("--regole")) installer.InstallSkills(root);
            if (steps.Contains("--hook"))
            {
                var dll = Path.Combine(AppContext.BaseDirectory, "devops-agents-hook.dll");
                var hook = Value("--hook-cmd") is { } h ? h.Split(' ') : File.Exists(dll) ? ["dotnet", dll] : ["devops-agents-hook"];
                installer.InstallHooks(hook, root);
            }
            if (steps.Contains("--pat-github"))
            {
                var w = Environment.GetEnvironmentVariable("DEVOPS_AGENTS_GITHUB_TOKEN") ?? ReadSecret("Incolla il token di GitHub per lo smistatore (scrittura, non si vede): ");
                var r = Environment.GetEnvironmentVariable("DEVOPS_AGENTS_GITHUB_TOKEN_READ") ?? ReadSecret("Incolla il token di GitHub per le sessioni (sola lettura, non si vede): ");
                installer.SaveGitHubTokens(w, r);
            }
            // --pat per ultimo: apre il browser per il login di az, e un login interrotto non deve bloccare il resto
            if (steps.Contains("--pat"))
            {
                var suite = DevOpsAgents.Infrastructure.Configuration.SuiteConfig.Load(root);
                await installer.InstallPatAsync(Path.Combine(root, "config", "pat.json"), suite.Organization, new HttpClient());
            }
            return 0;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            output.WriteLine($"setup: {e.Message}");
            return 1;
        }
    }

    private static string ReadSecret(string prompt)
    {
        Console.Write(prompt);
        var sb = new System.Text.StringBuilder();
        if (Console.IsInputRedirected) return Console.ReadLine() ?? "";
        while (true)
        {
            var k = Console.ReadKey(intercept: true);
            if (k.Key == ConsoleKey.Enter) break;
            if (k.Key == ConsoleKey.Backspace) { if (sb.Length > 0) sb.Length--; continue; }
            sb.Append(k.KeyChar);
        }
        Console.WriteLine();
        return sb.ToString();
    }

    private static async Task PostOk(HttpClient http, string path)
    {
        var res = await http.PostAsync(path, null);
        if (!res.IsSuccessStatusCode)
        {
            var body = await res.Content.ReadAsStringAsync();
            var error = body.Length > 0 && body.TrimStart().StartsWith('{') ? JsonNode.Parse(body)?["error"]?.ToString() : null;
            throw new HttpRequestException(error ?? $"{(int)res.StatusCode} {res.ReasonPhrase}");
        }
    }
}
