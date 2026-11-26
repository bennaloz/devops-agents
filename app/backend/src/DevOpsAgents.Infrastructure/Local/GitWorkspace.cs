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
        // con la base (D52) si pota: il ramo della card gia unito e cancellato resterebbe come ref remoto vecchio
        if (baseBranch is not null) await RunAsync(area.Folder, ct, "fetch", "--prune", "origin");
        else await RunAsync(area.Folder, ct, "fetch", "origin");
        if (Directory.Exists(folder)) return (branch, folder);
        var remote = (await RunAsync(area.Folder, ct, "ls-remote", "--heads", "origin", branch)).Trim();
        if (remote.Length > 0)
            await RunAsync(area.Folder, ct, "worktree", "add", "-B", branch, folder, $"origin/{branch}");
        else
            await RunAsync(area.Folder, ct, "worktree", "add", "-b", branch, folder, $"origin/{baseBranch ?? "develop"}");
        await RunAsync(folder, ct, "push", "-u", "origin", branch);
        return (branch, folder);
    }

    /// <summary>D52: il nome del ramo della funzionalita: feature/f&lt;id&gt;-&lt;titolo&gt;, o bugfix/ se la Feature ha il tag bug.</summary>
    public static string FeatureBranchName(FeatureInfo f, bool bug)
    {
        var slug = Slug(f.Title);
        return $"{(bug ? "bugfix" : "feature")}/f{f.Id}{(slug == "card" && f.Title.Trim().Length == 0 ? "" : "-" + slug)}";
    }

    public static bool IsFeatureBranch(string name, int featureId) => Regex.IsMatch(name, $@"^(feature|bugfix)/f{featureId}(-.*)?$");

    private async Task<string?> FindFeatureBranchAsync(AreaMapping area, int featureId, CancellationToken ct)
    {
        await RunAsync(area.Folder, ct, "fetch", "--prune", "origin");
        var refs = (await RunAsync(area.Folder, ct, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/feature/", "refs/remotes/origin/bugfix/"))
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(r => r.StartsWith("origin/") ? r["origin/".Length..] : r).Where(r => IsFeatureBranch(r, featureId)).ToList();
        if (refs.Count > 1) throw new InvalidOperationException($"Su origin c'e piu di un ramo della funzionalita {featureId}: {string.Join(", ", refs)}. Quale continuare lo decide una persona");
        return refs.SingleOrDefault();
    }

    public async Task<string> PublishFeatureBranchAsync(AreaMapping area, FeatureInfo feature, bool bug, CancellationToken ct = default)
    {
        if (await FindFeatureBranchAsync(area, feature.Id, ct) is { } found) return found;
        var name = FeatureBranchName(feature, bug);
        try { await RunAsync(area.Folder, ct, "push", "origin", $"refs/remotes/origin/develop:refs/heads/{name}"); return name; }
        catch (InvalidOperationException e)
        {
            // un altro smistatore l'ha pubblicato nel frattempo: si usa il suo; se non c'e il rifiuto e un errore vero
            return await FindFeatureBranchAsync(area, feature.Id, ct)
                ?? throw new InvalidOperationException($"git push del ramo {name} della funzionalita {feature.Id} rifiutato: {e.Message}", e);
        }
    }

    public async Task<string> UpdateClosingWorktreeAsync(AreaMapping area, Card card, string branch, CancellationToken ct = default)
    {
        var folder = Path.Combine(worktreeRoot, area.Repo, $"card-{card.Id}");
        await RunAsync(area.Folder, ct, "fetch", "--prune", "origin");
        try { await RunAsync(area.Folder, ct, "rev-parse", "--verify", "--quiet", $"refs/remotes/origin/{branch}"); }
        catch (InvalidOperationException) { throw new InvalidOperationException($"Su origin non c'e il ramo {branch} della funzionalita: il worktree della card di chiusura {card.Id} non si puo creare"); }
        if (Directory.Exists(folder))
        {
            var current = (await RunAsync(folder, ct, "branch", "--show-current")).Trim();
            if (current.Length > 0) throw new InvalidOperationException($"Il worktree {folder} e sul ramo '{current}', non e detached: non e quello della card di chiusura, non lo uso");
            await RunAsync(folder, ct, "checkout", "--detach", "--force", $"origin/{branch}");
        }
        else await RunAsync(area.Folder, ct, "worktree", "add", "--detach", folder, $"origin/{branch}");
        return folder;
    }

    /// <summary>
    /// Come New-WorktreeDaRemoto: il ramo feature/&lt;id&gt; o fix/&lt;id&gt; pubblicato su origin, in un worktree; null se non c'e. Un ramo locale
    /// con commit non pubblicati non si sovrascrive; una cartella gia presente va bene solo se e sul ramo di questa card.
    /// </summary>
    public async Task<(string Branch, string Folder)?> CreateWorktreeFromRemoteAsync(AreaMapping area, Card card, CancellationToken ct = default)
    {
        var folder = Path.Combine(worktreeRoot, area.Repo, $"card-{card.Id}");
        if (Directory.Exists(folder))
        {
            var current = (await RunAsync(folder, ct, "branch", "--show-current")).Trim();
            if (!Regex.IsMatch(current, $@"^(feature|fix)/{card.Id}(-.*)?$")) throw new InvalidOperationException($"La cartella {folder} e sul ramo '{current}', che non e della card {card.Id}: non la uso");
            return (current, folder);
        }
        await RunAsync(area.Folder, ct, "fetch", "--prune", "origin");
        var remotes = (await RunAsync(area.Folder, ct, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/feature/", "refs/remotes/origin/fix/"))
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Where(r => Regex.IsMatch(r, $@"^origin/(feature|fix)/{card.Id}(-.*)?$")).ToList();
        if (remotes.Count == 0) return null;
        if (remotes.Count > 1) throw new InvalidOperationException($"Su origin c'e piu di un ramo della card {card.Id}: {string.Join(", ", remotes)}. Quale continuare lo decide una persona");
        var branch = remotes[0]["origin/".Length..];
        var hasLocal = await SucceedsAsync(area.Folder, ct, "rev-parse", "--verify", "--quiet", $"refs/heads/{branch}");
        if (hasLocal && !await SucceedsAsync(area.Folder, ct, "merge-base", "--is-ancestor", $"refs/heads/{branch}", remotes[0]))
            throw new InvalidOperationException($"Il ramo locale {branch} ha commit non pubblicati che {remotes[0]} non contiene: non lo sovrascrivo");
        await RunAsync(area.Folder, ct, "worktree", "add", "-B", branch, folder, remotes[0]);
        return (branch, folder);
    }

    private async Task<bool> SucceedsAsync(string dir, CancellationToken ct, params string[] args)
    {
        try { await RunAsync(dir, ct, args); return true; } catch (InvalidOperationException) { return false; }
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
