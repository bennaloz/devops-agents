using System.Diagnostics;
using System.Text;
using System.Text.Json;
using DevOpsAgents.Core.Ports;

namespace DevOpsAgents.Infrastructure.Local;

/// <summary>
/// D46: la memoria dei ruoli scritta con src/memoria.ps1, che ne fa worktree, mutex, commit, push e PR. Lo strumento MCP passa i campi gia
/// strutturati; il JSON arriva a memoria.ps1 da stdin come lo scriverebbe il mentore. Finche la scrittura non e portata in .NET, il mentore
/// non usa PowerShell: lo usa il server MCP, con i token che ha lui.
/// </summary>
public sealed class PowerShellMemoryWriter(string root, int? sessionCard = null, string pwsh = "pwsh") : IMemoryWriter
{
    public Task<string> ReadAsync(string role, string repo, CancellationToken ct = default) => RunAsync(["leggi", role, repo], null, ct);

    public Task<string> WriteAsync(string role, string where, LessonFields l, CancellationToken ct = default) => RunAsync(["scrivi", role, where], Json(l), ct);

    public Task<string> ReviseAsync(string id, LessonFields l, CancellationToken ct = default) => RunAsync(["rivedi", id], Json(l), ct);

    public Task<string> RemoveAsync(string id, CancellationToken ct = default) => RunAsync(["togli", id], null, ct);

    public Task<string> ConflictAsync(int cardId, string text, CancellationToken ct = default) => RunAsync(["conflitto", cardId.ToString()], text, ct);

    public static string Json(LessonFields l) =>
        JsonSerializer.Serialize(new Dictionary<string, string> { ["situazione"] = l.Situation, ["cosaFare"] = l.WhatToDo, ["perche"] = l.Why, ["card"] = l.Card });

    private async Task<string> RunAsync(IReadOnlyList<string> args, string? stdin, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(pwsh)
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = root,
        };
        foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-File", Path.Combine(root, "src", "memoria.ps1") }.Concat(args)) psi.ArgumentList.Add(a);
        // memoria.ps1 conflitto accetta solo la card della sessione, come card.ps1
        if (sessionCard is { } c) psi.Environment["ATTREZZI_CARD"] = c.ToString();
        using var p = Process.Start(psi) ?? throw new InvalidOperationException($"{pwsh} non parte: la memoria dei ruoli si scrive con PowerShell 7");
        if (stdin is not null) await p.StandardInput.WriteAsync(stdin);
        p.StandardInput.Close();
        var output = p.StandardOutput.ReadToEndAsync(ct);
        var error = p.StandardError.ReadToEndAsync(ct);
        await p.WaitForExitAsync(ct);
        var o = (await output).Trim();
        var e = (await error).Trim();
        if (p.ExitCode != 0)
            throw new Core.Agents.CardToolException(System.Text.RegularExpressions.Regex.Replace(e.Length > 0 ? e : o, "^memoria:\\s*", ""));
        return o;
    }
}
