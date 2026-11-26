using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;

namespace DevOpsAgents.Infrastructure.Secrets;

/// <summary>
/// I token: prima la variabile d'ambiente, poi il file in ~/.claude con lo stesso nome della versione PowerShell
/// (pat-smistatore.txt, pat-github.txt, ...). Un file puo essere in chiaro o cifrato con DPAPI da ConvertFrom-SecureString
/// (solo Windows, solo l'utente che l'ha scritto). Il valore non si scrive mai nei log.
/// </summary>
public sealed class TokenStore(string? claudeDir = null)
{
    private readonly string _dir = claudeDir ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");

    public string AzureDevOps => Get("DEVOPS_AGENTS_ADO_PAT", "pat-smistatore.txt", "pat.txt")
        ?? throw new InvalidOperationException("PAT di Azure DevOps mancante: imposta DEVOPS_AGENTS_ADO_PAT o lancia setup/Install-Attrezzi.ps1 -Pat");

    public string GitHub => Get("DEVOPS_AGENTS_GITHUB_TOKEN", "pat-github.txt")
        ?? throw new InvalidOperationException("Token di GitHub mancante: imposta DEVOPS_AGENTS_GITHUB_TOKEN o lancia setup/Install-Attrezzi.ps1 -PatGitHub");

    /// <summary>I token in sola lettura che ricevono le sessioni dei ruoli (AZURE_DEVOPS_EXT_PAT, GH_TOKEN); null se non ci sono.</summary>
    public string? AzureDevOpsReadOnly => Get("DEVOPS_AGENTS_ADO_PAT_READ", "pat-smistatore-lettura.txt", "pat-read-only.txt");
    public string? GitHubReadOnly => Get("DEVOPS_AGENTS_GITHUB_TOKEN_READ", "pat-github-lettura.txt");

    private string? Get(string env, params string[] files)
    {
        var v = Environment.GetEnvironmentVariable(env);
        if (!string.IsNullOrWhiteSpace(v)) return v.Trim();
        foreach (var f in files)
        {
            var p = Path.Combine(_dir, f);
            if (!File.Exists(p)) continue;
            var text = File.ReadAllText(p).Trim();
            if (text.Length == 0) continue;
            return Decode(text, p);
        }
        return null;
    }

    /// <summary>In chiaro, o il formato di ConvertFrom-SecureString senza chiave: l'esadecimale di un blob DPAPI con il testo in UTF-16.</summary>
    public static string Decode(string text, string path)
    {
        if (!text.StartsWith("01000000d08c9ddf", StringComparison.OrdinalIgnoreCase)) return text;
        if (!OperatingSystem.IsWindows()) throw new InvalidOperationException($"{path} e cifrato con DPAPI: si legge solo su Windows, con l'utente che l'ha scritto");
        return Unprotect(text);
    }

    [SupportedOSPlatform("windows")]
    private static string Unprotect(string hex) =>
        Encoding.Unicode.GetString(ProtectedData.Unprotect(Convert.FromHexString(hex), null, DataProtectionScope.CurrentUser));
}
