using System.Net;
using System.Text.Json.Nodes;
using DevOpsAgents.Core.Supervision;
using DevOpsAgents.Infrastructure.AzureDevOps;

namespace DevOpsAgents.Infrastructure.Notifications;

/// <summary>Dove vanno gli avvisi del supervisore. Senza Telegram configurato restano nel log.</summary>
public interface INotifier
{
    bool Configured { get; }
    /// <summary>Manda un messaggio HTML nel topic (urgenti, riepilogo, rilasci). Non lancia: un invio fallito si scrive nel log e si riprova al giro dopo.</summary>
    Task<bool> SendAsync(string topic, string html, CancellationToken ct = default);
}

/// <summary>I testi su Telegram, come Format-UrgenteTelegram e Format-RiepilogoTelegram: la cosa, a capo l'azione esatta, il link.</summary>
public static class TelegramFormat
{
    public static string Escape(string s) => WebUtility.HtmlEncode(s);

    private static string Item(Notice n)
    {
        var p = n.Problem;
        var lines = new List<string> { $"• {Escape(p.Text)}{(n.Reminder && n.Waiting.Length > 0 ? $" <i>(aspetta da {Escape(n.Waiting)})</i>" : "")}" };
        foreach (var l in p.Lines ?? []) lines.Add($"   {Escape(l)}");
        lines.Add($"   → {Escape(p.Action)}{(p.Link is { Length: > 0 } link ? $" — <a href=\"{Escape(link)}\">apri</a>" : "")}");
        return string.Join("\n", lines);
    }

    public static string Urgent(Notice n) => $"🚨 <b>{(n.Reminder ? "Ancora aperto" : "Urgente")}</b>\n{Item(n)}";

    public static string Summary(IReadOnlyList<Notice> items) => $"📋 <b>Riepilogo</b> — {items.Count} {(items.Count == 1 ? "voce" : "voci")}\n\n{string.Join("\n\n", items.Select(Item))}";

    public static string Releases(IReadOnlyList<Notice> items) => $"🚀 <b>Rilasci in attesa</b>\n\n{string.Join("\n\n", items.Select(Item))}";
}

/// <summary>
/// Telegram: il token del bot e l'id della chat (dalla cartella ~/.claude e dalla cartella dati, come il PowerShell). In un gruppo forum il bot
/// crea da solo i topic Urgenti, Riepilogo e Rilasci (gli id restano in telegram-topic.json); senza il permesso, o fuori da un forum, tutto va
/// nel topic generale. Il token non compare mai in un messaggio d'errore.
/// </summary>
public sealed class TelegramNotifier(HttpClient http, string? token, string? chatId, string topicsFile) : INotifier
{
    private static readonly Dictionary<string, string> TopicNames = new() { ["urgenti"] = "Urgenti", ["riepilogo"] = "Riepilogo", ["rilasci"] = "Rilasci" };

    public bool Configured => !string.IsNullOrWhiteSpace(token) && !string.IsNullOrWhiteSpace(chatId);

    public static TelegramNotifier FromFiles(HttpClient http, string claudeDir, string dataDir)
    {
        string? Read(string p) => File.Exists(p) && File.ReadAllText(p).Trim() is { Length: > 0 } v ? v : null;
        var token = Environment.GetEnvironmentVariable("DEVOPS_AGENTS_TELEGRAM_TOKEN") ?? Read(Path.Combine(claudeDir, "telegram-token.txt"));
        var chat = Environment.GetEnvironmentVariable("DEVOPS_AGENTS_TELEGRAM_CHAT") ?? Read(Path.Combine(dataDir, "telegram-chat.txt"));
        return new TelegramNotifier(http, token, chat, Path.Combine(dataDir, "telegram-topic.json"));
    }

    private async Task<JsonNode?> CallAsync(string method, object body, CancellationToken ct)
    {
        var url = $"https://api.telegram.org/bot{token}/{method}";
        using var res = await http.PostAsync(url, new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json"), ct);
        var text = await res.Content.ReadAsStringAsync(ct);
        var json = JsonNode.Parse(text);
        if (!res.IsSuccessStatusCode || json?["ok"]?.GetValue<bool>() != true)
            throw new HttpRequestException($"Telegram {method}: {(int)res.StatusCode} {json?["description"]}".Replace(token ?? "\u0000", "***"));
        return json["result"];
    }

    /// <summary>L'id del topic, creato al primo uso; null (topic generale) se la chat non e un forum o il bot non puo gestire i topic.</summary>
    private async Task<int?> TopicAsync(string topic, CancellationToken ct)
    {
        var saved = File.Exists(topicsFile) ? JsonNode.Parse(File.ReadAllText(topicsFile)) as JsonObject ?? new JsonObject() : new JsonObject();
        if (saved[topic] is JsonValue v && v.TryGetValue<int>(out var id)) return id;
        if (saved["senzaTopic"] is JsonValue no && no.TryGetValue<bool>(out var b) && b) return null;
        try
        {
            var r = await CallAsync("createForumTopic", new { chat_id = chatId, name = TopicNames.GetValueOrDefault(topic, topic) }, ct);
            var newId = r!["message_thread_id"]!.GetValue<int>();
            saved[topic] = newId;
            File.WriteAllText(topicsFile, saved.ToJsonString());
            return newId;
        }
        catch (HttpRequestException)
        {
            saved["senzaTopic"] = true;
            File.WriteAllText(topicsFile, saved.ToJsonString());
            return null;
        }
    }

    public async Task<bool> SendAsync(string topic, string html, CancellationToken ct = default)
    {
        if (!Configured) return false;
        try
        {
            var thread = await TopicAsync(topic, ct);
            object body = thread is { } t
                ? new { chat_id = chatId, text = html, parse_mode = "HTML", disable_web_page_preview = true, message_thread_id = t }
                : new { chat_id = chatId, text = html, parse_mode = "HTML", disable_web_page_preview = true };
            await CallAsync("sendMessage", body, ct);
            return true;
        }
        catch (HttpRequestException) { return false; }
    }
}
