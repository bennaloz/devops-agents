using System.Text.Json.Nodes;
using DevOpsAgents.Core.Hooks;
using Xunit;

namespace DevOpsAgents.Core.Tests;

/// <summary>
/// Gli hook .NET sugli stessi casi di hooks/Test-Hooks.ps1, esportati in Hooks/casi-hook.json (input, ruolo, host di collaudo, exit atteso).
/// Un caso nuovo si aggiunge a Test-Hooks.ps1 e si riesporta.
/// </summary>
public class HookTests
{
    private static readonly string Root = FindRoot();

    private static string FindRoot()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
            if (File.Exists(Path.Combine(d.FullName, "config", "stati.json"))) return d.FullName;
        throw new InvalidOperationException("radice del repo non trovata");
    }

    public static IEnumerable<object[]> Cases()
    {
        var file = Path.Combine(AppContext.BaseDirectory, "Hooks", "casi-hook.json");
        var i = 0;
        foreach (var c in JsonNode.Parse(File.ReadAllText(file))!.AsArray())
            yield return [i++, c!["hook"]!.GetValue<string>(), c["what"]!.GetValue<string>()];
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void Ogni_caso_di_Test_Hooks_ha_lo_stesso_esito(int index, string hook, string what)
    {
        var c = JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Hooks", "casi-hook.json")))!.AsArray()[index]!;
        var hostCollaudo = c["hostCollaudo"]?.GetValue<string>();
        string? Read(string name) => name == "collaudo.json" && hostCollaudo is not null
            ? new JsonObject { ["host"] = hostCollaudo }.ToJsonString()
            : File.Exists(Path.Combine(Root, "config", name)) ? File.ReadAllText(Path.Combine(Root, "config", name)) : null;
        var v = HookRules.Run(hook, c["input"]!.ToJsonString(), new HookContext(c["role"]?.GetValue<string>(), Read));
        Assert.True(c["expected"]!.GetValue<int>() == v.ExitCode, $"{hook}: {what} -> exit {v.ExitCode}, atteso {c["expected"]}. {v.Message}");
    }

    [Fact]
    public void Un_input_illeggibile_passa_e_lo_dice()
    {
        var v = HookRules.Run("deny-commit-outside-worktree", "non json", new HookContext(null, _ => null));
        Assert.Equal(0, v.ExitCode);
        Assert.StartsWith("hook: input non interpretabile", v.Message);
    }

    [Fact]
    public void Una_mappa_illeggibile_blocca_il_collaudatore()
    {
        var v = HookRules.Run("deny-host-collaudo", """{"tool_input":{"command":"curl http://a.example/x"}}""", new HookContext("collaudatore", n => n == "mappa.json" ? "{ rotto" : null));
        Assert.Equal(2, v.ExitCode);
        Assert.Contains("non riesco a leggere gli host di Test", v.Message);
    }

    private static string Usage(long input, long read, long created, bool sidechain = false) =>
        "{\"isSidechain\":" + (sidechain ? "true" : "false") + $",\"message\":{{\"usage\":{{\"input_tokens\":{input},\"cache_read_input_tokens\":{read},\"cache_creation_input_tokens\":{created}}}}}}}";

    [Fact]
    public void Il_contesto_e_l_ultimo_usage_fuori_dalle_sidechain_e_una_riga_tagliata_non_conta()
    {
        var tail = "usage\": tagliata}\n" + Usage(1, 2, 3) + "\n" + Usage(100, 50000, 70000) + "\n" + Usage(9, 9, 9, sidechain: true) + "\n";
        Assert.Equal(120100, HookRules.ContextTokens(tail));
        Assert.Equal(0, HookRules.ContextTokens("niente"));
    }

    [Fact]
    public void Suggest_compact_avvisa_una_volta_per_gradino_e_non_blocca_mai()
    {
        var steps = new Dictionary<string, int>();
        var tokens = 100000L;
        HookContext Ctx(Func<string, string?>? env = null) => new(null, _ => null, Env: env ?? (_ => null), ReadTail: _ => Usage(tokens, 0, 0),
            ReadStep: k => steps.TryGetValue(k, out var s) ? s : null, WriteStep: (k, s) => steps[k] = s);
        const string payload = """{"transcript_path":"/t/abc.jsonl","session_id":"s:1","tool_input":{"file_path":"x"}}""";

        Assert.Null(HookRules.Run("suggest-compact", payload, Ctx()).Output);
        tokens = 160000;
        var v = HookRules.Run("suggest-compact", payload, Ctx());
        Assert.Equal(0, v.ExitCode);
        Assert.Equal("Contesto a 160k token: se hai chiuso una fase, e' un buon momento per /compact.", JsonNode.Parse(v.Output!)!["systemMessage"]!.GetValue<string>());
        Assert.Equal(0, steps["s_1"]);
        Assert.Null(HookRules.Run("suggest-compact", payload, Ctx()).Output);   // stesso gradino
        tokens = 220000;
        Assert.Null(HookRules.Run("suggest-compact", payload, Ctx()).Output);   // 150k + 75k non ancora
        tokens = 230000;
        Assert.NotNull(HookRules.Run("suggest-compact", payload, Ctx()).Output);
        Assert.Equal(1, steps["s_1"]);
        // la soglia si cambia con l'ambiente; un valore non valido vale il default
        steps.Clear(); tokens = 60000;
        Assert.NotNull(HookRules.Run("suggest-compact", payload, Ctx(n => n == "COMPACT_SOGLIA_TOKEN" ? "50000" : null)).Output);
        steps.Clear();
        Assert.Null(HookRules.Run("suggest-compact", payload, Ctx(n => n == "COMPACT_SOGLIA_TOKEN" ? "-3" : null)).Output);
    }

    [Fact]
    public void Suggest_compact_senza_transcript_passa_in_silenzio()
    {
        var v = HookRules.Run("suggest-compact", """{"transcript_path":"/non/c/e"}""", new HookContext(null, _ => null, ReadTail: _ => null));
        Assert.Equal(0, v.ExitCode);
        Assert.Null(v.Output);
        Assert.Null(v.Message);
    }
}
