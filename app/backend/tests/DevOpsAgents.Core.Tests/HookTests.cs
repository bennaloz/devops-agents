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
}
