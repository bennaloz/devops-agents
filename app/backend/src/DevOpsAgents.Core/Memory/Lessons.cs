using System.Text.RegularExpressions;

namespace DevOpsAgents.Core.Memory;

/// <summary>Una lezione della memoria di un ruolo (D46): il blocco "### ruolo-NNN" con situazione, cosa fare, perche, card.</summary>
public sealed record Lesson(string Id, string Text, bool InTrial = false);

/// <summary>Il file di memoria di un ruolo per un nome (comune, o il repo): il testo su develop (stabile) e sul ramo in prova (null se non c'e).</summary>
public sealed record MemoryFile(string Name, string? Develop, string? InTrial);

/// <summary>
/// D46: le lezioni nel brief del ruolo, come Memoria.psm1. Le stabili (develop) valgono come sono, quelle solo sul ramo in prova portano
/// l'etichetta "(in prova)" nel titolo. Prima le comuni, poi quelle del repo.
/// </summary>
public static class Lessons
{
    public const string TrialLabel = "(in prova)";

    public static IReadOnlyList<Lesson> Read(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return [];
        var blocks = new List<List<string>>();
        List<string>? current = null;
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            var line = raw.TrimEnd();
            if (line.StartsWith("### ")) blocks.Add(current = []);
            current?.Add(line);
        }
        var result = new List<Lesson>();
        foreach (var b in blocks)
        {
            var m = Regex.Match(b[0], @"^###\s+(.+)-(\d+)\s*$");
            if (!m.Success) continue;
            while (b.Count > 1 && b[^1].Length == 0) b.RemoveAt(b.Count - 1);
            result.Add(new Lesson($"{m.Groups[1].Value}-{m.Groups[2].Value}", string.Join("\n", b)));
        }
        return result;
    }

    /// <summary>Le lezioni da servire: quelle del ramo in prova se c'e (con l'etichetta su quelle che develop non ha), altrimenti quelle di develop.</summary>
    public static IReadOnlyList<Lesson> WithLabels(string? develop, string? inTrial)
    {
        var stable = Read(develop).Select(l => l.Text).ToHashSet(StringComparer.Ordinal);
        return Read(inTrial ?? develop).Select(l => l with { InTrial = !stable.Contains(l.Text) }).ToList();
    }

    public static string Text(IEnumerable<Lesson> lessons) =>
        string.Join("\n\n", lessons.Select(l => l.InTrial ? Regex.Replace(l.Text, "^([^\n]*)", $"$1 {TrialLabel}") : l.Text));

    /// <summary>Il brief del ruolo con in fondo la sezione Memoria; senza lezioni, il brief com'e.</summary>
    public static string BriefWithMemory(string brief, IEnumerable<MemoryFile> files)
    {
        var ordered = files.Where(f => f.Name == "comune").Concat(files.Where(f => f.Name != "comune"));
        var sections = new List<string>();
        foreach (var f in ordered)
        {
            var lessons = WithLabels(f.Develop, f.InTrial);
            if (lessons.Count == 0) continue;
            var title = f.Name == "comune" ? "## Lezioni comuni a tutti i repo" : $"## Lezioni del repo {f.Name}";
            sections.Add($"{title}\n\n{Text(lessons).TrimEnd()}");
        }
        return sections.Count == 0 ? brief : $"{brief.TrimEnd()}\n\n# Memoria\n\n{string.Join("\n\n", sections)}\n";
    }
}
