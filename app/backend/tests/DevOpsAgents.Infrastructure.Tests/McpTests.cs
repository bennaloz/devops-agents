using System.Text.Json.Nodes;
using DevOpsAgents.Core.Agents;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Ports;
using DevOpsAgents.Infrastructure.Configuration;
using DevOpsAgents.Infrastructure.Local;
using DevOpsAgents.Infrastructure.Secrets;
using DevOpsAgents.Mcp;
using ModelContextProtocol.Protocol;
using Xunit;

namespace DevOpsAgents.Infrastructure.Tests;

public class McpTests
{
    private static readonly SuiteConfig Suite = SuiteConfig.Load(Tx.Root);

    private static IReadOnlyList<string> Tools(string role, int? task = null, IMemoryWriter? memory = null)
    {
        var session = new AgentSession(7, role, task);
        // l'elenco non tocca la board: nessuna chiamata finche un agente non usa uno strumento
        var card = new CardTools(session, null!, null!, Suite.Names, Suite.Roles, Suite.Areas);
        return ToolCatalog.Build(card, session, memory).Select(t => t.ProtocolTool.Name).ToList();
    }

    [Fact]
    public void Il_server_espone_solo_gli_strumenti_del_ruolo_con_le_transizioni_di_ruoli_json()
    {
        Assert.Equal(["card_leggi", "card_commenta", "card_sposta", "card_criteri", "card_crea_task", "card_senza_test", "card_prova_umana", "card_deploy",
            "card_correzione", "card_titolo_pr", "card_descrizione_pr"], Tools("responsabile"));
        Assert.Equal(["card_leggi", "card_commenta", "card_chiudi_task", "card_titolo_pr", "card_descrizione_pr"], Tools("dev", 12));
        Assert.Equal(["card_leggi", "card_commenta"], Tools("reviewer"));
        Assert.Equal(["card_leggi", "card_commenta", "memoria_leggi", "memoria_scrivi", "memoria_rivedi", "memoria_togli", "memoria_conflitto"],
            Tools("mentore", memory: new PowerShellMemoryWriter(Tx.Root)));
        Assert.Contains(Suite.Roles["responsabile"].Transitions!, t => t == new RoleTransition(StateKeys.New, StateKeys.Ready));
    }

    [Fact]
    public async Task Un_rifiuto_torna_come_errore_dello_strumento_con_il_messaggio()
    {
        var ok = await ToolCatalog.Run(() => Task.FromResult("fatto"));
        Assert.Equal((false, "fatto"), (ok.IsError ?? false, ((TextContentBlock)ok.Content[0]).Text));
        var no = await ToolCatalog.Run(() => throw new CardToolException("solo responsabile"));
        Assert.Equal((true, "card: solo responsabile"), (no.IsError ?? false, ((TextContentBlock)no.Content[0]).Text));
        var http = await ToolCatalog.Run(() => throw new HttpRequestException("401"), "memoria");
        Assert.Equal("memoria: HttpRequestException: 401", ((TextContentBlock)http.Content[0]).Text);
    }

    [Fact]
    public void La_sessione_con_MCP_ha_il_solo_server_degli_agenti_legato_a_card_ruolo_e_task()
    {
        var json = ClaudeSessionRunner.McpConfig(["dotnet", "/opt/mcp/devops-agents-mcp.dll"], 42, "dev", 12, "/r", "/dati");
        var s = JsonNode.Parse(json)!["mcpServers"]!.AsObject();
        Assert.Equal("agenti", Assert.Single(s).Key);
        Assert.Equal("dotnet", s["agenti"]!["command"]!.GetValue<string>());
        Assert.Equal(["/opt/mcp/devops-agents-mcp.dll", "--card", "42", "--ruolo", "dev", "--task", "12", "--root", "/r", "--dati", "/dati"],
            s["agenti"]!["args"]!.AsArray().Select(x => x!.GetValue<string>()));
        var a = ClaudeSessionRunner.Arguments(new RoleSettings("opus", "", "b", ["Read"]), "b", "m", "S1", false, json);
        Assert.Equal(["Read", "mcp__agenti", "--strict-mcp-config", "--mcp-config", json], a.SkipWhile(x => x != "--allowedTools").Skip(1).Take(5));
    }

    [Fact]
    public async Task Con_il_server_MCP_il_brief_ha_la_tabella_degli_strumenti_e_claude_riceve_la_config()
    {
        if (OperatingSystem.IsWindows()) return;
        var data = Directory.CreateTempSubdirectory("dati").FullName;
        var script = Path.Combine(data, "claude-finto.sh");
        File.WriteAllText(script, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ATTREZZI_DATI/argomenti.txt\"\nprintf '%s\\n' '{\"type\":\"result\",\"result\":\"ESITO=fatto\"}'\n");
        var runner = new ClaudeSessionRunner(Suite, new TokenStore(Directory.CreateTempSubdirectory("claude").FullName),
            new ClaudeRunnerOptions { Executable = "/bin/sh", PrefixArguments = [script], DataDir = data, McpServer = ["/opt/devops-agents-mcp"] });
        var id = await runner.StartAsync(new SessionRequest("dev", 42, Tx.AzureArea, null, "m", null, false, 12, null));
        SessionResult? r = null;
        for (var i = 0; i < 50 && r is null; i++) { await Task.Delay(100); r = await runner.PollAsync(id); }
        Assert.Equal("fatto", r!.Outcome);
        var args = File.ReadAllLines(Path.Combine(data, "argomenti.txt"));
        var config = args[Array.IndexOf(args, "--mcp-config") + 1];
        Assert.Contains("\"--card\",\"42\",\"--ruolo\",\"dev\",\"--task\",\"12\"", config);
        var brief = File.ReadAllText(args[Array.IndexOf(args, "--append-system-prompt-file") + 1]);
        Assert.StartsWith(File.ReadAllText(Path.Combine(Tx.Root, "ruoli", "dev.md")).TrimEnd()[..200], brief);
        Assert.Contains("| `card.ps1 chiudi-task` | `mcp__agenti__card_chiudi_task` |", brief);
        Assert.DoesNotContain("card_crea_task", brief);
    }

    [Fact]
    public async Task La_memoria_passa_i_campi_a_memoria_ps1_come_JSON_e_un_suo_errore_torna_come_rifiuto()
    {
        if (OperatingSystem.IsWindows()) return;
        var dir = Directory.CreateTempSubdirectory("pwsh").FullName;
        var fake = Path.Combine(dir, "pwsh");
        File.WriteAllText(fake, "#!/bin/sh\nfor a in \"$@\"; do last=\"$a\"; done\ncase \"$*\" in *togli*) echo \"memoria: non c'e nessuna lezione con id '$last'\" >&2; exit 1;; esac\necho \"args: $* card=$ATTREZZI_CARD\"\ncat\n");
        File.SetUnixFileMode(fake, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var m = new PowerShellMemoryWriter(Tx.Root, 42, fake);
        var o = await m.WriteAsync("dev", "Acme.AI", new LessonFields("quando \"x\"", "fai y", "perche z", "42"));
        Assert.Contains("memoria.ps1 scrivi dev Acme.AI card=42", o);
        var json = JsonNode.Parse(o[o.IndexOf('{')..])!;
        Assert.Equal(("quando \"x\"", "fai y", "perche z", "42"), (json["situazione"]!.GetValue<string>(), json["cosaFare"]!.GetValue<string>(), json["perche"]!.GetValue<string>(), json["card"]!.GetValue<string>()));
        var e = await Assert.ThrowsAsync<CardToolException>(() => m.RemoveAsync("dev-007"));
        Assert.Equal("non c'e nessuna lezione con id 'dev-007'", e.Message);
    }
}
