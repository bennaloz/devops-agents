using System.Diagnostics;
using DevOpsAgents.Core.Memory;
using DevOpsAgents.Core.Ports;

namespace DevOpsAgents.Infrastructure.Local;

/// <summary>
/// D46: le lezioni lette da git nella copia degli attrezzi: memoria/&lt;ruolo&gt;/{comune,&lt;repo&gt;}.md su origin/develop (stabili) e sul ramo
/// memoria/in-prova (in prova) se non e gia unito in develop. Un fetch ogni cinque minuti al piu. Non lancia mai: se git non risponde,
/// niente memoria (la memoria e un di piu e non ferma il lancio).
/// </summary>
public sealed class GitMemorySource(string suiteRoot, string git = "git") : IMemorySource
{
    public const string TrialBranch = "memoria/in-prova";
    private DateTimeOffset _lastFetch = DateTimeOffset.MinValue;

    public async Task<IReadOnlyList<MemoryFile>> GetAsync(string role, string repo, CancellationToken ct = default)
    {
        try
        {
            if (DateTimeOffset.UtcNow - _lastFetch > TimeSpan.FromMinutes(5))
            {
                await RunAsync(ct, "fetch", "--prune", "origin");
                _lastFetch = DateTimeOffset.UtcNow;
            }
            if (await RunAsync(ct, "rev-parse", "--verify", "--quiet", "origin/develop") is null) return [];
            var trialRef = $"origin/{TrialBranch}";
            var trial = await RunAsync(ct, "rev-parse", "--verify", "--quiet", trialRef) is not null
                && await RunAsync(ct, "merge-base", "--is-ancestor", trialRef, "origin/develop") is null;
            var files = new List<MemoryFile>();
            foreach (var name in new[] { "comune", repo }.Distinct())
            {
                var path = $"memoria/{role}/{name}.md";
                files.Add(new MemoryFile(name, await RunAsync(ct, "show", $"origin/develop:{path}"), trial ? await RunAsync(ct, "show", $"{trialRef}:{path}") : null));
            }
            return files;
        }
        catch (Exception e) when (e is not OperationCanceledException) { return []; }
    }

    /// <summary>L'uscita del comando, o null se esce con un errore.</summary>
    private async Task<string?> RunAsync(CancellationToken ct, params string[] args)
    {
        var psi = new ProcessStartInfo(git) { WorkingDirectory = suiteRoot, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var output = p.StandardOutput.ReadToEndAsync(ct);
        _ = p.StandardError.ReadToEndAsync(ct);
        await p.WaitForExitAsync(ct);
        return p.ExitCode == 0 ? await output : null;
    }
}
