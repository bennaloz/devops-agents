using System.Net;
using System.Text.Json.Nodes;
using DevOpsAgents.Infrastructure.Setup;
using Xunit;

namespace DevOpsAgents.Infrastructure.Tests;

public class InstallerTests
{
    private static (Installer I, string Claude, StringWriter Out) Make()
    {
        var claude = Directory.CreateTempSubdirectory("claude").FullName;
        var o = new StringWriter();
        return (new Installer(claude, o), claude, o);
    }

    [Fact]
    public void Gli_hook_si_aggiungono_una_volta_con_la_copia_e_lasciano_il_resto()
    {
        var (i, claude, o) = Make();
        var file = Path.Combine(claude, "settings.json");
        File.WriteAllText(file, """{ "model": "opus", "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "mio-hook" } ] } ] } }""");
        i.InstallHooks(["dotnet", "C:\\Program Files\\da\\devops-agents-hook.dll"], "C:\\develop\\GIT\\DevOps.Agents");
        var s = JsonNode.Parse(File.ReadAllText(file))!;
        Assert.Equal("opus", s["model"]!.GetValue<string>());
        var pre = s["hooks"]!["PreToolUse"]!.AsArray();
        Assert.Equal(8, pre.Count);
        Assert.Contains(pre, p => p!["matcher"]!.GetValue<string>() == "Bash|PowerShell|Read" &&
            p["hooks"]![0]!["command"]!.GetValue<string>() == "dotnet \"C:/Program Files/da/devops-agents-hook.dll\" deny-pat --root C:/develop/GIT/DevOps.Agents");
        Assert.Single(Directory.GetFiles(claude, "settings.json.bak-*"));
        i.InstallHooks(["dotnet", "c:/program files/da/devops-agents-hook.dll"], "c:/develop/git/devops.agents");
        Assert.Equal(8, JsonNode.Parse(File.ReadAllText(file))!["hooks"]!["PreToolUse"]!.AsArray().Count);
        Assert.Contains("tutte le voci erano gia presenti", o.ToString());
    }

    [Fact]
    public void Le_skill_sono_collegamenti_al_repo_e_uno_estraneo_non_si_tocca()
    {
        if (OperatingSystem.IsWindows()) return;
        var (i, claude, _) = Make();
        i.InstallSkills(Tx.Root);
        Assert.Equal(Path.Combine(Tx.Root, "regole"), new DirectoryInfo(Path.Combine(claude, "skills", "regole-sviluppo")).LinkTarget);
        i.InstallSkills(Tx.Root);
        var (i2, claude2, _) = Make();
        Directory.CreateDirectory(Path.Combine(claude2, "skills", "devops-agents"));
        Assert.Contains("non e il collegamento atteso", Assert.Throws<InvalidOperationException>(() => i2.InstallSkills(Tx.Root)).Message);
    }

    [Fact]
    public void Un_token_fuori_da_Windows_e_leggibile_solo_dall_utente()
    {
        if (OperatingSystem.IsWindows()) return;
        var (i, claude, _) = Make();
        i.SaveGitHubTokens("ghp_scrittura", "ghp_lettura");
        var f = Path.Combine(claude, "pat-github-lettura.txt");
        Assert.Equal("ghp_lettura", File.ReadAllText(f));
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(f));
        Assert.Equal("ghp_scrittura", new Secrets.TokenStore(claude).GitHub);
        Assert.Throws<InvalidOperationException>(() => i.SaveGitHubTokens(" ", "x"));
    }

    [Fact]
    public void Il_nome_dell_organizzazione_viene_dall_indirizzo()
    {
        Assert.Equal("acme", Installer.OrganizationName("https://acme.visualstudio.com"));
        Assert.Equal("acme", Installer.OrganizationName("https://dev.azure.com/acme/"));
    }

    private const string PatConfig = """{ "durataGiorni": 90, "smistatore": { "nome": "S", "scope": ["vso.work_write"] }, "solaLettura": { "nome": "L", "scope": ["vso.code"] } }""";

    [Fact]
    public async Task I_PAT_nascono_insieme_si_scrivono_e_i_vecchi_si_revocano_e_il_login_fatto_si_toglie()
    {
        if (OperatingSystem.IsWindows()) return;
        var (i, claude, o) = Make();
        var cfg = Path.Combine(claude, "pat.json");
        File.WriteAllText(cfg, PatConfig);
        File.WriteAllText(Path.Combine(claude, "pat-info.json"), """{ "smistatore": { "authorizationId": "vecchio-1" }, "daRevocare": ["vecchio-2"] }""");
        var n = 0;
        var h = new FakeHttp((r, body) => r.Method == HttpMethod.Post
            ? FakeHttp.Ok($$"""{ "patToken": { "token": "pat-{{++n}}", "authorizationId": "nuovo-{{n}}", "validTo": "2027-02-24T00:00:00Z" } }""")
            : r.RequestUri!.Query.Contains("vecchio-2") ? (HttpStatusCode.NotFound, "") : FakeHttp.Ok("{}"));
        var az = new List<string>();
        (int, string) Az(params string[] a)
        {
            az.Add(string.Join(' ', a));
            return a[0] == "account" && a[1] == "show" ? (1, "") : a[0] == "account" ? (0, "TOKEN-AZ") : (0, "");
        }
        await i.InstallPatAsync(cfg, "https://acme.visualstudio.com", new HttpClient(h), Az);
        Assert.Equal("pat-1", File.ReadAllText(Path.Combine(claude, "pat-smistatore.txt")));
        Assert.Equal("pat-2", File.ReadAllText(Path.Combine(claude, "pat-smistatore-lettura.txt")));
        var info = JsonNode.Parse(File.ReadAllText(Path.Combine(claude, "pat-info.json")))!;
        Assert.Equal("nuovo-1", info["smistatore"]!["authorizationId"]!.GetValue<string>());
        Assert.Null(info["daRevocare"]);
        Assert.Equal(2, h.Calls.Count(c => c.Method == "DELETE"));
        Assert.Contains("logout", az);
        Assert.All(h.Calls, c => Assert.StartsWith("https://vssps.dev.azure.com/acme/_apis/tokens/pats", c.Url));
        Assert.DoesNotContain("TOKEN-AZ", o.ToString());
    }

    [Fact]
    public async Task Se_il_secondo_PAT_non_nasce_il_primo_si_revoca_e_i_file_restano()
    {
        if (OperatingSystem.IsWindows()) return;
        var (i, claude, _) = Make();
        var cfg = Path.Combine(claude, "pat.json");
        File.WriteAllText(cfg, PatConfig);
        File.WriteAllText(Path.Combine(claude, "pat-smistatore.txt"), "vecchio");
        var posts = 0;
        var h = new FakeHttp((r, _) => r.Method == HttpMethod.Post
            ? (++posts == 1 ? FakeHttp.Ok("""{ "patToken": { "token": "pat-1", "authorizationId": "nuovo-1" } }""") : (HttpStatusCode.BadRequest, "no TOKEN-AZ"))
            : FakeHttp.Ok("{}"));
        var e = await Assert.ThrowsAsync<HttpRequestException>(() => i.InstallPatAsync(cfg, "https://acme.visualstudio.com", new HttpClient(h), a => a[0] == "account" && a[1] == "get-access-token" ? (0, "TOKEN-AZ") : (0, "")));
        Assert.DoesNotContain("TOKEN-AZ", e.Message);
        Assert.Contains(h.Calls, c => c.Method == "DELETE" && c.Url.Contains("nuovo-1"));
        Assert.Equal("vecchio", File.ReadAllText(Path.Combine(claude, "pat-smistatore.txt")));
        await Assert.ThrowsAsync<InvalidDataException>(() => { File.WriteAllText(cfg, "{}"); return i.InstallPatAsync(cfg, "https://acme.visualstudio.com", new HttpClient(h)); });
    }
}
