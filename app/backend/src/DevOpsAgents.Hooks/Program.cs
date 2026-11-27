using System.Text;
using DevOpsAgents.Core.Hooks;

// Gli hook PreToolUse di Claude Code (hooks/*.ps1 in .NET): Claude Code manda l'input JSON su stdin.
//   devops-agents-hook <deny-commit-outside-worktree|deny-secrets-in-repo|deny-pat|deny-identita|deny-host-collaudo> [--root <repo degli attrezzi>]
// Exit 2 = chiamata bloccata, lo stderr torna al modello. Exit 0 = passa. Il ruolo viene da ATTREZZI_RUOLO, che lo smistatore mette
// nell'ambiente di claude e il comando del modello non tocca. Un errore dell'hook stesso non blocca il lavoro: lo dice e passa.

if (args.Length == 0 || !HookRules.Names.Contains(args[0]))
{
    Console.Error.WriteLine($"uso: devops-agents-hook <{string.Join("|", HookRules.Names)}> [--root <cartella>]");
    return 0;
}
string? root = null;
for (var i = 1; i < args.Length - 1; i++) if (args[i] == "--root") root = args[i + 1];
root ??= FindRoot(AppContext.BaseDirectory);
var config = root is null ? "config" : Path.Combine(root, "config");

Console.InputEncoding = new UTF8Encoding(false);
Console.OutputEncoding = new UTF8Encoding(false);
try
{
    var payload = await Console.In.ReadToEndAsync();
    string? Read(string name)
    {
        var p = Path.Combine(config, name);
        return File.Exists(p) ? File.ReadAllText(p) : name == "mappa.json" ? throw new FileNotFoundException($"{p} non trovato") : null;
    }
    var v = HookRules.Run(args[0], payload, new HookContext(Environment.GetEnvironmentVariable("ATTREZZI_RUOLO"), Read, config.Replace('\\', '/')));
    if (v.Message is { } m) Console.Error.WriteLine(m);
    return v.ExitCode;
}
catch (Exception e)
{
    Console.Error.WriteLine($"hook {args[0]}: errore, controllo saltato - {e.Message}");
    return 0;
}

static string? FindRoot(string start)
{
    for (var d = new DirectoryInfo(start); d is not null; d = d.Parent)
        if (File.Exists(Path.Combine(d.FullName, "config", "stati.json"))) return d.FullName;
    return null;
}
