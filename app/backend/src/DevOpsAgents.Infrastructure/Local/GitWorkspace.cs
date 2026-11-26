using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;

namespace DevOpsAgents.Infrastructure.Local;

/// <summary>
/// I worktree delle card: &lt;radice&gt;/&lt;repo&gt;/card-&lt;id&gt;, sul ramo feature/&lt;id&gt;-&lt;titolo&gt; (fix/ per un Bug), da origin/&lt;base&gt;.
/// Se il ramo c'e gia su origin (card presa in carico da un altro PC) si riparte da li. La copia principale non si tocca.
/// </summary>
public sealed class GitWorkspace(string worktreeRoot, string git = "git") : IWorkspace
{
    public static string BranchName(Card card)
    {
        var prefix = string.Equals(card.WorkItemType, "Bug", StringComparison.OrdinalIgnoreCase) ? "fix" : "feature";
        return $"{prefix}/{card.Id}-{Slug(card.Title)}";
    }

    public static string Slug(string title)
    {
        var plain = new StringBuilder();
        foreach (var ch in title.Normalize(NormalizationForm.FormD))
            if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark) plain.Append(ch);
        var s = Regex.Replace(plain.ToString().ToLowerInvariant(), "[^a-z0-9]+", "-").Trim('-');
        if (s.Length > 40) s = s[..40].TrimEnd('-');
        return s.Length == 0 ? "card" : s;
    }

    public async Task<(string Branch, string Folder)> CreateWorktreeAsync(AreaMapping area, Card card, string? baseBranch, CancellationToken ct = default)
    {
        var folder = Path.Combine(worktreeRoot, area.Repo, $"card-{card.Id}");
        var branch = BranchName(card);
        await RunAsync(area.Folder, ct, "fetch", "origin");
        if (Directory.Exists(folder)) return (branch, folder);
        var remote = (await RunAsync(area.Folder, ct, "ls-remote", "--heads", "origin", branch)).Trim();
        if (remote.Length > 0)
            await RunAsync(area.Folder, ct, "worktree", "add", "-B", branch, folder, $"origin/{branch}");
        else
            await RunAsync(area.Folder, ct, "worktree", "add", "-b", branch, folder, $"origin/{baseBranch ?? "develop"}");
        await RunAsync(folder, ct, "push", "-u", "origin", branch);
        return (branch, folder);
    }

    public async Task RemoveWorktreeAsync(AreaMapping area, string folder, CancellationToken ct = default)
    {
        // lavoro non pubblicato: il worktree resta, e chi decide lo vede nell'errore
        var dirty = (await RunAsync(folder, ct, "status", "--porcelain")).Trim();
        if (dirty.Length > 0) throw new InvalidOperationException($"Il worktree {folder} ha modifiche non pubblicate: lo lascio");
        await RunAsync(area.Folder, ct, "worktree", "remove", folder);
    }

    private async Task<string> RunAsync(string dir, CancellationToken ct, params string[] args)
    {
        var psi = new ProcessStartInfo(git) { WorkingDirectory = dir, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("git non parte");
        var stdout = p.StandardOutput.ReadToEndAsync(ct);
        var stderr = p.StandardError.ReadToEndAsync(ct);
        await p.WaitForExitAsync(ct);
        if (p.ExitCode != 0) throw new InvalidOperationException($"git {string.Join(' ', args)} in {dir}: {await stderr}");
        return await stdout;
    }
}
