using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DevOpsAgents.Core.Ports;

namespace DevOpsAgents.Core.Memory;

/// <summary>Una lezione letta per campi: l'id, il ruolo e il numero dal titolo, i quattro campi dalle righe, il blocco com'e.</summary>
public sealed record LessonEntry(string Id, string Role, int Number, string Situation, string WhatToDo, string Why, string Card, string Text, bool InTrial = false);

/// <summary>
/// D46: le regole pure della memoria dei ruoli, come Memoria.psm1: il formato dei file, gli id, il tetto, la descrizione della PR della memoria
/// e il riassunto dell'apprendimento. Nessun git e nessuna rete: lavorano su testi.
/// Un file e una sequenza di blocchi separati da una riga vuota: "### ruolo-NNN" e le righe "- Situazione:", "- Cosa fare:", "- Perché:", "- Card:".
/// </summary>
public static class MemoryRules
{
    public const string TrialBranch = "memoria/in-prova";
    public const string Folder = "memoria";
    public const string ConflictsTitle = "## Conflitti con le regole scritte";
    public const string PrTitle = "memoria dei ruoli: lezioni in prova (D46)";
    public const int SummaryWeeks = 4;

    private static readonly (string Key, string Label)[] Fields = [("situazione", "Situazione"), ("cosaFare", "Cosa fare"), ("perche", "Perché"), ("card", "Card")];

    public static string PathOf(string role, string name) => $"{Folder}/{role}/{name}.md";

    public static string LessonText(string id, LessonFields l) =>
        string.Join("\n", new[] { $"### {id}", $"- Situazione: {l.Situation}", $"- Cosa fare: {l.WhatToDo}", $"- Perché: {l.Why}", $"- Card: {l.Card}" });

    public static IReadOnlyList<LessonEntry> Read(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return [];
        var blocks = new List<List<string>>();
        List<string>? current = null;
        foreach (var raw in Regex.Split(text, "\r?\n"))
        {
            var r = raw.TrimEnd();
            if (Regex.IsMatch(r, @"^###\s")) blocks.Add(current = []);
            current?.Add(r);
        }
        var result = new List<LessonEntry>();
        foreach (var b in blocks)
        {
            var m = Regex.Match(b[0], @"^###\s+(.+)-(\d+)\s*$");
            if (!m.Success) continue;
            while (b.Count > 1 && b[^1].Length == 0) b.RemoveAt(b.Count - 1);
            string F(string label) => b.Select(x => Regex.Match(x, $"^- {Regex.Escape(label)}:\\s*(.*)$")).FirstOrDefault(x => x.Success)?.Groups[1].Value ?? "";
            result.Add(new LessonEntry($"{m.Groups[1].Value}-{m.Groups[2].Value}", m.Groups[1].Value, int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture),
                F("Situazione"), F("Cosa fare"), F("Perché"), F("Card"), string.Join("\n", b)));
        }
        return result;
    }

    /// <summary>Gli errori dei quattro campi, uno per campo: vuoto o su piu righe (un a capo spezzerebbe il blocco).</summary>
    public static IReadOnlyList<string> FieldErrors(LessonFields l)
    {
        var values = new[] { l.Situation, l.WhatToDo, l.Why, l.Card };
        var errors = new List<string>();
        for (var i = 0; i < Fields.Length; i++)
        {
            if (string.IsNullOrWhiteSpace(values[i])) errors.Add($"manca il campo '{Fields[i].Key}' o e vuoto");
            else if (Regex.IsMatch(values[i], "[\r\n]")) errors.Add($"il campo '{Fields[i].Key}' va scritto su una riga sola");
        }
        return errors;
    }

    /// <summary>Il massimo fra le lezioni del ruolo nei testi dati (anche la storia) piu uno, nella forma ruolo-NNN.</summary>
    public static string NextId(string role, IEnumerable<string?> texts)
    {
        var max = texts.SelectMany(t => Read(t)).Where(l => l.Role == role).Select(l => l.Number).DefaultIfEmpty(0).Max();
        return $"{role}-{max + 1:000}";
    }

    public static bool IsFull(string? text, int cap) => Read(text).Count >= cap;

    private static string Join(IEnumerable<string> blocks)
    {
        var b = blocks.ToList();
        return b.Count == 0 ? "" : string.Join("\n\n", b) + "\n";
    }

    public static string Add(string? text, string lesson) => Join(Read(text).Select(l => l.Text).Append(lesson));

    /// <summary>Null se l'id non c'e.</summary>
    public static string? Replace(string? text, string id, string lesson)
    {
        var l = Read(text);
        return l.Any(x => x.Id == id) ? Join(l.Select(x => x.Id == id ? lesson : x.Text)) : null;
    }

    public static string? Remove(string? text, string id)
    {
        var l = Read(text);
        return l.Any(x => x.Id == id) ? Join(l.Where(x => x.Id != id).Select(x => x.Text)) : null;
    }

    /// <summary>Le lezioni con l'etichetta in prova: dal ramo in prova se c'e (null = no), altrimenti da develop; in prova se il blocco non e identico su develop.</summary>
    public static IReadOnlyList<LessonEntry> WithLabels(string? develop, string? inTrial)
    {
        var stable = Read(develop).Select(l => l.Text).ToHashSet(StringComparer.Ordinal);
        return Read(inTrial ?? develop).Select(l => l with { InTrial = !stable.Contains(l.Text) }).ToList();
    }

    public static string Text(IEnumerable<LessonEntry> lessons) =>
        Join(lessons.Select(l => l.InTrial ? Regex.Replace(l.Text, "^([^\n]*)", $"$1 {Lessons.TrialLabel}") : l.Text));

    /// <summary>Le righe "### ruolo-NNN" in un testo di git log -p (righe che cominciano con spazio, + o -): la storia degli id del ruolo.</summary>
    public static string HistoricalHeadings(string role, string log) =>
        string.Join("\n", Regex.Matches(log, $@"(?m)^[ +-](###\s+{Regex.Escape(role)}-\d+)\s*$").Select(m => m.Groups[1].Value).Distinct());

    // ---- la descrizione della PR della memoria ---------------------------------------------------------------------------

    /// <summary>Le note di conflitto gia nella descrizione: le righe "- ..." sotto il titolo della sezione.</summary>
    public static IReadOnlyList<string> ConflictNotes(string? description)
    {
        if (string.IsNullOrWhiteSpace(description)) return [];
        var inside = false;
        var notes = new List<string>();
        foreach (var line in Regex.Split(description, "\r?\n"))
        {
            if (line.Trim() == ConflictsTitle) { inside = true; continue; }
            if (!inside) continue;
            var m = Regex.Match(line, "^- (.+)$");
            if (!m.Success) break;
            notes.Add(m.Groups[1].Value.Trim());
        }
        return notes;
    }

    /// <summary>
    /// Le lezioni in prova (id e situazione) e le note di conflitto, poi il riassunto dell'apprendimento con lo spazio che resta. Se non ci sta,
    /// si omettono le lezioni piu vecchie e lo si dice; le note restano sempre.
    /// </summary>
    public static string PrDescription(IReadOnlyList<LessonEntry> inTrial, IEnumerable<string> conflicts, LearningSummary? summary, int limit)
    {
        var notes = conflicts.Where(c => !string.IsNullOrEmpty(c)).Select(c => string.Join(" ", Regex.Split(c, @"\s*\r?\n\s*")).Trim()).Distinct().ToList();
        string Build(IReadOnlyCollection<LessonEntry> shown, int omitted)
        {
            var r = new List<string> { "Lezioni dei ruoli in prova (D46): alla fusione diventano stabili.", "", "## Lezioni in prova" };
            if (inTrial.Count == 0) r.Add("Nessuna lezione in prova.");
            r.AddRange(shown.Select(x => $"- {x.Id}: {x.Situation}"));
            if (omitted > 0) r.Add($"- (altre {omitted} lezioni in prova, le piu vecchie, non elencate: la descrizione ha un limite di {limit} caratteri)");
            if (notes.Count > 0) { r.Add(""); r.Add(ConflictsTitle); r.AddRange(notes.Select(n => $"- {n}")); }
            return string.Join("\n", r);
        }
        var shown = inTrial.ToList();
        var text = Build(shown, 0);
        var lines = SummaryLines(summary);
        if (text.Length <= limit) return AppendSummary(text, lines, limit);
        var order = inTrial.Select((l, i) => (l, i)).OrderBy(x => x.l.Number).ThenBy(x => x.i).Select(x => x.l).ToList();
        var omittedCount = 0;
        foreach (var o in order)
        {
            shown.Remove(o);
            omittedCount++;
            text = Build(shown, omittedCount);
            if (text.Length <= limit) break;
        }
        return AppendSummary(text, lines, limit);
    }

    private static string AppendSummary(string text, IReadOnlyList<string> lines, int limit)
    {
        var output = text;
        for (var n = 2; n <= lines.Count; n++)
        {
            var candidate = $"{text}\n\n{string.Join("\n", lines.Take(n))}";
            if (candidate.Length > limit) break;
            output = candidate;
        }
        return output;
    }

    // ---- il riassunto dell'apprendimento (D46, "Misura") ---------------------------------------------------------------

    public sealed record LearningRow(string Week, string Monday, string Role, int Blocks, int OnHold, int Corrections, int LessonsApplied);
    public sealed record AvoidedBlock(string Role, string Lesson, IReadOnlyList<int> Cards);
    public sealed record LearningSummary(int Weeks, string Window, IReadOnlyList<LearningRow> Rows, IReadOnlyList<AvoidedBlock> Avoided);

    private static readonly string[] LearningKinds = ["blocco", "onHold", "correzione", "lezioneApplicata"];
    private static readonly string[] StopKinds = ["blocco", "onHold", "correzione"];

    public static string WindowText(int weeks) => $"ultime {weeks} settimane intere piu quella in corso";

    private static DateTime Monday(DateTime d) => d.Date.AddDays(-(((int)d.DayOfWeek + 6) % 7));

    /// <summary>Id -> card d'origine delle lezioni; un'origine che non e un numero non entra.</summary>
    public static IReadOnlyDictionary<string, int> KnownOrigins(IEnumerable<LessonEntry> lessons)
    {
        var d = new Dictionary<string, int>();
        foreach (var l in lessons) if (int.TryParse(l.Card.Trim(), out var c)) d[l.Id] = c;
        return d;
    }

    /// <summary>
    /// Per ruolo e settimana ISO (UTC): blocchi, on-hold, correzioni e lezioni applicate, nella finestra di <paramref name="weeks"/> settimane intere
    /// piu quella in corso; e le lezioni che hanno evitato un blocco (applicate su una card diversa da quella d'origine, sessione non finita
    /// bloccato o bivio, e nessuno stop del ruolo su quella card dopo). Le righe rotte del registro si ignorano.
    /// </summary>
    public static LearningSummary Summarize(IEnumerable<JsonNode?> registry, DateTimeOffset now, IReadOnlyDictionary<string, int>? known, int weeks = SummaryWeeks)
    {
        var valid = new List<(string Kind, string Role, DateTime When, int Card, string Lesson, string Outcome)>();
        foreach (var r in registry)
        {
            if (r is not JsonObject o) continue;
            string S(string k) => o[k] is JsonValue v ? (v.TryGetValue<string>(out var s) ? s : v.ToJsonString()) : "";
            var kind = S("tipo"); var role = S("ruolo");
            if (!LearningKinds.Contains(kind) || string.IsNullOrWhiteSpace(role)) continue;
            if (!DateTimeOffset.TryParse(S("data"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var when)) continue;
            if (!int.TryParse(S("card").Trim(), out var card)) continue;
            valid.Add((kind, role, when.UtcDateTime, card, S("lezione"), S("esito")));
        }
        var lastStop = new Dictionary<string, DateTime>();
        foreach (var v in valid.Where(v => StopKinds.Contains(v.Kind)))
        {
            var k = $"{v.Role}|{v.Card}";
            if (!lastStop.TryGetValue(k, out var t) || v.When > t) lastStop[k] = v.When;
        }
        var first = Monday(now.UtcDateTime).AddDays(-7 * Math.Max(weeks, 0));
        var cells = new Dictionary<string, int[]>();
        var cellInfo = new Dictionary<string, (DateTime Monday, string Role)>();
        var avoided = new Dictionary<string, (string Role, string Lesson, SortedSet<int> Cards)>();
        foreach (var v in valid.Where(v => v.When >= first))
        {
            var monday = Monday(v.When);
            var key = $"{monday:yyyy-MM-dd}|{v.Role}";
            if (!cells.TryGetValue(key, out var c)) { cells[key] = c = new int[4]; cellInfo[key] = (monday, v.Role); }
            c[Array.IndexOf(LearningKinds, v.Kind)]++;
            if (v.Kind != "lezioneApplicata" || v.Lesson.Length == 0 || known is null || !known.TryGetValue(v.Lesson, out var origin)) continue;
            if (v.Card == origin || v.Outcome is "bloccato" or "bivio") continue;
            if (lastStop.TryGetValue($"{v.Role}|{v.Card}", out var stop) && stop > v.When) continue;
            var ek = $"{v.Role}|{v.Lesson}";
            if (!avoided.TryGetValue(ek, out var e)) avoided[ek] = e = (v.Role, v.Lesson, new SortedSet<int>());
            e.Cards.Add(v.Card);
        }
        var rows = cells.Select(kv => (Info: cellInfo[kv.Key], C: kv.Value))
            .OrderByDescending(x => x.Info.Monday).ThenBy(x => x.Info.Role, StringComparer.Ordinal)
            .Select(x => new LearningRow($"{ISOWeek.GetYear(x.Info.Monday)}-W{ISOWeek.GetWeekOfYear(x.Info.Monday):00}", x.Info.Monday.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                x.Info.Role, x.C[0], x.C[1], x.C[2], x.C[3])).ToList();
        return new LearningSummary(weeks, WindowText(weeks), rows,
            avoided.Values.OrderBy(a => a.Role, StringComparer.Ordinal).ThenBy(a => a.Lesson, StringComparer.Ordinal).Select(a => new AvoidedBlock(a.Role, a.Lesson, a.Cards.ToList())).ToList());
    }

    /// <summary>Il riassunto in righe per la descrizione della PR: testata, totali per ruolo, lezioni che hanno evitato un blocco.</summary>
    public static IReadOnlyList<string> SummaryLines(LearningSummary? s)
    {
        if (s is null || (s.Rows.Count == 0 && s.Avoided.Count == 0)) return [];
        var r = new List<string> { $"## Apprendimento ({s.Window})" };
        foreach (var g in s.Rows.GroupBy(x => x.Role).OrderBy(g => g.Key, StringComparer.Ordinal))
            r.Add($"- {g.Key}: {g.Sum(x => x.Blocks)} blocchi, {g.Sum(x => x.OnHold)} on-hold, {g.Sum(x => x.Corrections)} correzioni, {g.Sum(x => x.LessonsApplied)} lezioni applicate");
        if (s.Avoided.Count > 0)
        {
            r.Add("Lezioni che hanno evitato un blocco finora (applicate su una card diversa da quella d'origine, e il ruolo non si e fermato):");
            r.AddRange(s.Avoided.Select(e => $"- {e.Lesson} ({e.Role}): card {string.Join(", ", e.Cards)}"));
        }
        return r;
    }
}
