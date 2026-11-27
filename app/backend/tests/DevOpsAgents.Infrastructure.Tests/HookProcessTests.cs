using System.Diagnostics;
using System.Text.Json.Nodes;
using DevOpsAgents.Infrastructure.Local;
using Xunit;

namespace DevOpsAgents.Infrastructure.Tests;

public class HookProcessTests
{
    private static readonly string Dll = Path.Combine(AppContext.BaseDirectory, "devops-agents-hook.dll");

    private static (int Exit, string Error) Run(string hook, string json, string? role = null)
    {
        var psi = new ProcessStartInfo("dotnet") { RedirectStandardInput = true, RedirectStandardError = true, RedirectStandardOutput = true, UseShellExecute = false };
        foreach (var a in new[] { Dll, hook, "--root", Tx.Root }) psi.ArgumentList.Add(a);
        psi.Environment.Remove("ATTREZZI_RUOLO");
        if (role is not null) psi.Environment["ATTREZZI_RUOLO"] = role;
        using var p = Process.Start(psi)!;
        p.StandardInput.Write(json);
        p.StandardInput.Close();
        var err = p.StandardError.ReadToEnd();
        p.WaitForExit();
        return (p.ExitCode, err);
    }

    [Fact]
    public void L_eseguibile_blocca_con_exit_2_e_il_messaggio_su_stderr()
    {
        var (exit, err) = Run("deny-pat", """{"tool_name":"Bash","tool_input":{"command":"cat ~/.claude/pat.txt"}}""", "dev");
        Assert.Equal(2, exit);
        Assert.StartsWith("Bloccato: il PAT", err);
        Assert.Equal(0, Run("deny-pat", """{"tool_input":{"command":"cat ~/.claude/pat.txt"}}""").Exit);
        var (e2, m2) = Run("deny-host-collaudo", """{"tool_input":{"command":"curl https://produzione.example.com/x"}}""", "collaudatore");
        Assert.Equal(2, e2);
        Assert.Contains("'produzione.example.com'", m2);
    }

    [Fact]
    public void Le_impostazioni_della_sessione_hanno_un_hook_per_regola_con_il_suo_matcher()
    {
        var json = ClaudeSessionRunner.HookSettings(["dotnet", "/opt/devops agents/hook/devops-agents-hook.dll"], "C:\\develop\\GIT\\DevOps.Agents");
        var pre = JsonNode.Parse(json)!["hooks"]!["PreToolUse"]!.AsArray();
        Assert.Equal(7, pre.Count);
        var pat = pre.Single(x => x!["matcher"]!.GetValue<string>() == "Bash|PowerShell|Read")!;
        Assert.Equal("dotnet \"/opt/devops agents/hook/devops-agents-hook.dll\" deny-pat --root C:/develop/GIT/DevOps.Agents", pat["hooks"]![0]!["command"]!.GetValue<string>());
        var a = ClaudeSessionRunner.Arguments(new("opus", "", "b", ["Read"]), "b", "m", "S1", false, null, json);
        Assert.Equal(["--settings", json, "--permission-mode", "acceptEdits"], a.TakeLast(4));
    }
}
