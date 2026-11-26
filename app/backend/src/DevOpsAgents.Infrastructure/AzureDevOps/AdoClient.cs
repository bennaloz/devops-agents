using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

namespace DevOpsAgents.Infrastructure.AzureDevOps;

/// <summary>Le chiamate REST ad Azure DevOps con il PAT. Un 401 dice di rinnovare il PAT; il PAT non finisce mai in un messaggio.</summary>
public sealed class AdoClient
{
    private readonly HttpClient _http;
    private readonly Func<string> _pat;

    public AdoClient(HttpClient http, string organization, Func<string> pat)
    {
        _http = http;
        _pat = pat;
        Organization = organization.TrimEnd('/');
    }

    public string Organization { get; }

    public static string E(string s) => Uri.EscapeDataString(s);

    public async Task<JsonNode?> SendAsync(HttpMethod method, string url, object? body = null, string contentType = "application/json", CancellationToken ct = default)
    {
        var full = url.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? url : $"{Organization}{url}";
        using var req = new HttpRequestMessage(method, full);
        var pat = _pat();
        req.Headers.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.ASCII.GetBytes($":{pat}")));
        if (body is not null)
        {
            var json = body is string s ? s : body is JsonNode n ? n.ToJsonString() : System.Text.Json.JsonSerializer.Serialize(body);
            req.Content = new StringContent(json, Encoding.UTF8);
            req.Content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        }
        using var res = await _http.SendAsync(req, ct);
        var text = await res.Content.ReadAsStringAsync(ct);
        if (!res.IsSuccessStatusCode)
        {
            var detail = text.Length > 500 ? text[..500] + "..." : text;
            var hint = res.StatusCode == HttpStatusCode.Unauthorized ? " - il PAT di Azure DevOps e scaduto o revocato: rilancia setup/Install-Attrezzi.ps1 -Pat" : "";
            throw new HttpRequestException($"Chiamata ad Azure DevOps fallita ({method} {full}): {(int)res.StatusCode} {detail}{hint}".Replace(pat, "***"), null, res.StatusCode);
        }
        return string.IsNullOrWhiteSpace(text) ? null : TryParse(text);
    }

    private static JsonNode? TryParse(string text)
    {
        try { return JsonNode.Parse(text); }
        catch (System.Text.Json.JsonException) { return JsonValue.Create(text); }
    }

    public Task<JsonNode?> GetAsync(string url, CancellationToken ct = default) => SendAsync(HttpMethod.Get, url, null, ct: ct);
}

internal static class JsonExt
{
    public static string? Str(this JsonNode? n, params string[] path)
    {
        var cur = n;
        foreach (var p in path) cur = cur?[p];
        return cur is JsonValue v && v.TryGetValue<string>(out var s) ? s : cur?.ToString();
    }

    public static int? Int(this JsonNode? n, params string[] path)
    {
        var cur = n;
        foreach (var p in path) cur = cur?[p];
        if (cur is not JsonValue v) return null;
        if (v.TryGetValue<int>(out var i)) return i;
        if (v.TryGetValue<long>(out var l)) return (int)l;
        return v.TryGetValue<string>(out var s) && int.TryParse(s, out var x) ? x : null;
    }

    public static bool? Bool(this JsonNode? n, string name) => n?[name] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;

    public static IEnumerable<JsonNode> Items(this JsonNode? n, string? name = null)
    {
        var arr = (name is null ? n : n?[name]) as JsonArray;
        return arr is null ? [] : arr.Where(x => x is not null).Select(x => x!);
    }

    public static DateTimeOffset? Date(this JsonNode? n, params string[] path) =>
        DateTimeOffset.TryParse(n.Str(path), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out var d) ? d : null;
}
