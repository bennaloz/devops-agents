using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

// devops-agents: la riga di comando per le persone. Parla con il servizio (API su localhost) e non tocca ne la board ne i repo da sola.
// Gli agenti continuano a usare card.ps1, che conosce hook e brief.

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
