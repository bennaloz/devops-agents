using System.Text.Json.Nodes;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;

namespace DevOpsAgents.Infrastructure.Local;

/// <summary>Scrittura atomica di un file JSON: un temporaneo e poi lo scambio, cosi chi legge non trova mai un file a meta.</summary>
internal static class JsonFile
{
    public static JsonObject? Read(string path)
    {
        if (!File.Exists(path)) return null;
        try { return JsonNode.Parse(File.ReadAllText(path)) as JsonObject; }
        catch (System.Text.Json.JsonException) { return null; }
    }

    public static void Write(string path, JsonObject o)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, o.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
        File.Move(tmp, path, overwrite: true);
    }

    public static DateTimeOffset? Date(JsonNode? n) =>
        n is JsonValue v && v.TryGetValue<string>(out var s) && DateTimeOffset.TryParse(s, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out var d) ? d : null;

    public static double? Num(JsonNode? n) => n is JsonValue v && v.TryGetValue<double>(out var d) ? d : null;
}

/// <summary>impostazioni.json nella cartella dati, con le chiavi della versione PowerShell (pausaSistema). Le altre chiavi restano.</summary>
public sealed class JsonSettingsStore(string path) : ISettingsStore
{
    public Task<SystemSettings> LoadAsync(CancellationToken ct = default)
    {
        var o = JsonFile.Read(path);
        var paused = o?["pausaSistema"] is JsonValue v && v.TryGetValue<bool>(out var b) && b;
        return Task.FromResult(new SystemSettings(paused));
    }

    public Task SaveAsync(SystemSettings settings, CancellationToken ct = default)
    {
        var o = JsonFile.Read(path) ?? new JsonObject();
        o["pausaSistema"] = settings.Paused;
        JsonFile.Write(path, o);
        return Task.CompletedTask;
    }
}

/// <summary>quota.json e soglia-quota.json nella cartella dati, nel formato della versione PowerShell.</summary>
public sealed class JsonQuotaStore(string dataDir) : IQuotaStore
{
    private string QuotaPath => Path.Combine(dataDir, "quota.json");
    private string OverridesPath => Path.Combine(dataDir, "soglia-quota.json");

    public Task<QuotaInfo?> LoadAsync(CancellationToken ct = default)
    {
        var o = JsonFile.Read(QuotaPath);
        if (o is null) return Task.FromResult<QuotaInfo?>(null);
        return Task.FromResult<QuotaInfo?>(new QuotaInfo(JsonFile.Date(o["pausaFino"]),
            JsonFile.Num(o["sevenDay"]?["utilization"]), JsonFile.Date(o["sevenDay"]?["resetsAt"]),
            JsonFile.Num(o["fiveHour"]?["utilization"]), JsonFile.Date(o["fiveHour"]?["resetsAt"])));
    }

    public Task SaveAsync(QuotaInfo q, CancellationToken ct = default)
    {
        var o = JsonFile.Read(QuotaPath) ?? new JsonObject();
        o["pausaFino"] = q.PauseUntil?.ToString("o");
        o["sevenDay"] = new JsonObject { ["utilization"] = q.WeeklyUtilization, ["resetsAt"] = q.WeeklyResetsAt?.ToString("o") };
        o["fiveHour"] = new JsonObject { ["utilization"] = q.FiveHourUtilization, ["resetsAt"] = q.FiveHourResetsAt?.ToString("o") };
        JsonFile.Write(QuotaPath, o);
        return Task.CompletedTask;
    }

    public Task<QuotaOverrides?> LoadOverridesAsync(CancellationToken ct = default)
    {
        var o = JsonFile.Read(OverridesPath);
        if (o is null) return Task.FromResult<QuotaOverrides?>(null);
        var ignore = o["ignoraRiserva"] is JsonValue v && v.TryGetValue<bool>(out var b) && b;
        return Task.FromResult<QuotaOverrides?>(new QuotaOverrides(JsonFile.Num(o["soglia"]), ignore, JsonFile.Date(o["fino"]), JsonFile.Num(o["soglia5Ore"]), JsonFile.Date(o["fino5Ore"])));
    }

    public Task SaveOverridesAsync(QuotaOverrides x, CancellationToken ct = default)
    {
        JsonFile.Write(OverridesPath, new JsonObject
        {
            ["soglia"] = x.WeeklyThreshold, ["ignoraRiserva"] = x.IgnoreWeeklyReserve, ["fino"] = x.WeeklyUntil?.ToString("o"),
            ["soglia5Ore"] = x.FiveHourThreshold, ["fino5Ore"] = x.FiveHourUntil?.ToString("o"),
        });
        return Task.CompletedTask;
    }
}
