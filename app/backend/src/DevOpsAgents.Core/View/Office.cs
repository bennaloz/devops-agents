using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Orchestration;

namespace DevOpsAgents.Core.View;

/// <summary>Una riga dell'ufficio: una card con il ruolo che ci lavora (sessione in corso) o che la prendera (coda).</summary>
public sealed record OfficeRow(int Id, string Role, string Title, string? Url, string? StateKey, int? Task = null, int? Minutes = null);

/// <summary>Una voce per una persona: la card, il gesto, e se ferma il flusso (una card in on-hold) o no.</summary>
public sealed record OfficeTodo(int Id, string Title, string? Url, string Verb, string Text, bool Stops);

/// <summary>
/// L'ufficio degli agenti (VistaUfficio.psm1): cosa fa ogni personaggio (al PC, al caffe, a parlare con un altro), le consegne fra ruoli, la
/// fila alla porta di chi deve decidere, la bacheca a muro e la quota. Funzione pura: riceve le righe e lo stato, non legge disco, rete ne orologio.
/// Il disegno e il gioco su canvas di src/ufficio, che legge questo dato in ufficio.json.
/// </summary>
public static class Office
{
    public static readonly string[] Flow = ["responsabile", "dev", "reviewer", "collaudatore"];

    private static readonly (string Key, string Title, string Short)[] Columns =
    [
        ("nuova", "Nuove", "NEW"), ("daChiarire", "Da chiarire", "CHIAR"), ("pronto", "Pronte da sviluppare", "PRONT"), ("inSviluppo", "In sviluppo", "DEV"),
        ("inRevisione", "In revisione", "REV"), ("inDeployTest", "Deploy in Test", "DEPL"), ("inCollaudo", "Collaudo automatico", "COLL"),
        ("inProvaUmana", "Prova in Test", "TEST"), ("daUnire", "Da unire", "MERGE"), ("daDeployTest", "Da deployare in Test", "DTEST"),
        ("daRilasciare", "Da rilasciare", "REL"),
    ];

    public static string Direction(string from, string to)
    {
        var i = Array.IndexOf(Flow, from); var j = Array.IndexOf(Flow, to);
        return i < 0 || j < 0 ? "laterale" : j > i ? "avanti" : "indietro";
    }

    public sealed record Seat(string Role, string Place, int? Id, string? Title, int? Task, int Others, string? With, string? Bubble, string? Direction);
    public sealed record Handover(int Id, string? Title, string From, string To);

    /// <summary>
    /// Get-PostazioniUfficio: un ruolo con una sessione sta al PC sulla card piu piccola; senza, al caffe. Una consegna e una card il cui ultimo
    /// ruolo e diverso da quello che la lavora adesso, con la sessione di quell'ultimo ruolo finita da meno della finestra; i due si parlano, se
    /// nessuno dei due siede su un'altra card. Un ruolo gia in una consegna non ne apre una seconda: vince la prima, in ordine di card.
    /// </summary>
    public static (IReadOnlyList<Seat> Seats, IReadOnlyList<Handover> Handovers) Seats(IReadOnlyList<string> roles, IReadOnlyList<OfficeRow> running,
        IReadOnlyList<OfficeRow> queue, IReadOnlyDictionary<int, CardLocalState> state, DateTimeOffset now, int windowMinutes = 60)
    {
        var sitting = roles.ToDictionary(r => r, _ => new List<int>());
        var titles = new Dictionary<int, string>();
        var worker = new Dictionary<int, string>();
        foreach (var s in running.OrderBy(s => s.Id))
        {
            titles[s.Id] = s.Title;
            if (!roles.Contains(s.Role)) continue;
            sitting[s.Role].Add(s.Id);
            worker[s.Id] = s.Role;
        }
        foreach (var c in queue)
        {
            titles.TryAdd(c.Id, c.Title);
            worker.TryAdd(c.Id, c.Role);
        }
        var handovers = new List<Handover>();
        var busy = new HashSet<string>();
        foreach (var (id, b) in worker.OrderBy(kv => kv.Key))
        {
            if (!roles.Contains(b) || !state.TryGetValue(id, out var sc)) continue;
            var a = sc.LastRole;
            if (string.IsNullOrEmpty(a) || a == b || !roles.Contains(a)) continue;
            if (sc.LastSessionByRole.GetValueOrDefault(a)?.End is not { } end || (now - end).TotalMinutes > windowMinutes) continue;
            if (busy.Contains(a) || busy.Contains(b)) continue;
            if (sitting[a].Any(x => x != id) || sitting[b].Any(x => x != id)) continue;
            busy.Add(a); busy.Add(b);
            handovers.Add(new Handover(id, titles.GetValueOrDefault(id), a, b));
        }
        var seats = roles.Select(r =>
        {
            var ids = sitting[r];
            if (ids.Count == 0) return new Seat(r, "caffe", null, null, null, 0, null, null, null);
            return new Seat(r, "pc", ids[0], titles.GetValueOrDefault(ids[0]), running.First(x => x.Id == ids[0] && x.Role == r).Task, ids.Count - 1, null, null, null);
        }).ToList();
        foreach (var h in handovers)
            foreach (var (who, with, dir) in new[] { (h.From, h.To, "da"), (h.To, h.From, "a") })
            {
                var i = seats.FindIndex(s => s.Role == who);
                var s = seats[i] with { With = with, Direction = dir, Bubble = $"#{h.Id} {h.Title}" };
                if (!(s.Place == "pc" && s.Id == h.Id)) s = s with { Place = "parla", Id = h.Id, Title = h.Title, Task = null, Others = 0 };
                seats[i] = s;
            }
        return (seats, handovers);
    }

    /// <summary>
    /// Le righe dall'ultimo giro: la sessione in corso di ogni card (ruolo, da quanto), la coda (le card per cui il giro deciderebbe una sessione), le
    /// voci per una persona (le card in on-hold fermano il flusso, quelle da rilasciare no).
    /// </summary>
    public static (List<OfficeRow> Running, List<OfficeRow> Queue, List<OfficeTodo> Todo) Rows(RoundReport? round, IReadOnlyDictionary<int, CardLocalState> state, DateTimeOffset now)
    {
        var running = new List<OfficeRow>(); var queue = new List<OfficeRow>(); var todo = new List<OfficeTodo>();
        foreach (var c in round?.Cards ?? [])
        {
            if (c.RunningRole is { } r)
            {
                var start = state.GetValueOrDefault(c.Id)?.LastSessionByRole.GetValueOrDefault(r)?.Start;
                running.Add(new OfficeRow(c.Id, r, c.Title, c.Url, c.StateKey, state.GetValueOrDefault(c.Id)?.LastSessionByRole.GetValueOrDefault(r)?.TaskId,
                    start is { } st ? (int)(now - st).TotalMinutes : null));
                continue;
            }
            var launch = c.Actions.Select(a => Regex.Match(a, @"^LanciaSessione (\w+)")).FirstOrDefault(m => m.Success);
            if (launch is not null) queue.Add(new OfficeRow(c.Id, launch.Groups[1].Value, c.Title, c.Url, c.StateKey));
            if (c.Reason?.Type == "onHold") todo.Add(new OfficeTodo(c.Id, c.Title, c.Url, "sblocca", c.WhatToDo is { Count: > 0 } w ? string.Join(" ", w) : "la card e in on-hold", true));
            else if (c.WaitsDevelopDeploy && c.Reason is null) todo.Add(new OfficeTodo(c.Id, c.Title, c.Url, "deployTest", "unita in develop: aspetta un deploy di develop in Test che la contenga", false));
            else if (c.StateKey == "daRilasciare") todo.Add(new OfficeTodo(c.Id, c.Title, c.Url, "rilascia", "la card aspetta il rilascio in produzione", false));
        }
        return (running, queue, todo);
    }

    /// <summary>Get-ModelloUfficio: il dato che la pagina dell'ufficio mostra come vero, nella forma che il gioco legge.</summary>
    public static JsonObject Model(IReadOnlyList<string> roles, RoundReport? round, IReadOnlyDictionary<int, CardLocalState> state, DateTimeOffset now,
        QuotaInfo? quota, BlockReason? quotaBlock, double weeklyThreshold, bool? inRound, DateTimeOffset? next, string? boardError = null, int seconds = 5)
    {
        var order = Flow.Where(roles.Contains).Concat(roles.Where(r => !Flow.Contains(r))).ToList();
        var (running, queue, todo) = Rows(round, state, now);
        var (seats, handovers) = Seats(order, running, queue, state, now);
        JsonObject Session(OfficeRow s) => new() { ["id"] = s.Id, ["titolo"] = s.Title, ["urlCard"] = s.Url, ["task"] = s.Task, ["titoloTask"] = null, ["minuti"] = s.Minutes, ["tokenTesto"] = null, ["tokenUsati"] = 0 };
        var others = new JsonArray();
        var characters = new JsonArray();
        foreach (var r in order)
        {
            var mine = running.Where(s => s.Role == r).OrderBy(s => s.Id).ToList();
            JsonObject? session = null;
            if (mine.Count > 0)
            {
                session = Session(mine[0]);
                session["altre"] = mine.Count - 1;
                foreach (var s in mine.Skip(1)) { var o = Session(s); o["ruolo"] = r; others.Add(o); }
            }
            var waiting = queue.Where(q => q.Role == r).ToList();
            characters.Add(new JsonObject
            {
                ["ruolo"] = r, ["sessione"] = session, ["codaTotale"] = waiting.Count,
                ["coda"] = new JsonArray(waiting.Select(q => (JsonNode)new JsonObject { ["id"] = q.Id, ["titolo"] = q.Title, ["urlCard"] = q.Url }).ToArray()),
            });
        }
        var withSession = running.Select(s => s.Role).ToHashSet();
        var line = new JsonArray();
        var inLine = new HashSet<string>();
        foreach (var t in todo.Where(t => t.Stops).OrderBy(t => t.Id))
        {
            var last = state.GetValueOrDefault(t.Id)?.LastRole;
            if (string.IsNullOrEmpty(last) || !order.Contains(last) || withSession.Contains(last) || !inLine.Add(last)) continue;
            line.Add(new JsonObject { ["ruolo"] = last, ["id"] = t.Id });
        }
        var all = running.Concat(queue).ToList();
        var board = boardError is not null ? null : new JsonArray(Columns.Select(c => (JsonNode)new JsonObject
        {
            ["chiave"] = c.Key, ["titolo"] = c.Title, ["sigla"] = c.Short, ["conteggio"] = (round?.Cards ?? []).Count(x => x.StateKey == c.Key),
        }).ToArray());
        return new JsonObject
        {
            ["generata"] = now.UtcDateTime.ToString("o"), ["secondi"] = seconds, ["esempio"] = false, ["erroreAdo"] = boardError ?? "",
            ["personaggi"] = characters, ["altreSessioni"] = others,
            ["consegne"] = new JsonArray(handovers.Select(h => (JsonNode)new JsonObject
            {
                ["id"] = h.Id, ["titolo"] = h.Title, ["urlCard"] = all.FirstOrDefault(x => x.Id == h.Id)?.Url, ["da"] = h.From, ["a"] = h.To, ["verso"] = Direction(h.From, h.To),
            }).ToArray()),
            ["daFareTu"] = new JsonArray(todo.Select(t => (JsonNode)new JsonObject { ["id"] = t.Id, ["titolo"] = t.Title, ["urlCard"] = t.Url, ["verbo"] = t.Verb, ["testo"] = t.Text, ["ferma"] = t.Stops }).ToArray()),
            ["fila"] = line, ["board"] = board, ["quota"] = Quota(quota, quotaBlock, weeklyThreshold),
            ["smistatore"] = new JsonObject { ["inGiro"] = inRound, ["ultimoGiro"] = round?.Finished.UtcDateTime.ToString("o"), ["prossimoGiro"] = next?.UtcDateTime.ToString("o") },
        };
    }

    /// <summary>La quota come la mostra la pagina (Get-QuotaUfficio): libera, riserva, limite (della finestra di 5 ore o settimanale), o sconosciuta.</summary>
    public static JsonObject Quota(QuotaInfo? q, BlockReason? block, double threshold)
    {
        var use = q?.WeeklyUtilization;
        if (block is { Type: "quota" } b)
        {
            var d = b.Detail ?? "";
            var state = d.StartsWith("riserva", StringComparison.Ordinal) ? "riserva" : "limite";
            var five = d.Contains("5 ore", StringComparison.Ordinal);
            return new JsonObject
            {
                ["stato"] = state, ["uso"] = use, ["soglia"] = threshold, ["fino"] = q?.PauseUntil?.UtcDateTime.ToString("o"), ["alzata"] = false, ["ignorata"] = false,
                ["finestra"] = state == "limite" ? (five ? "cinqueOre" : "settimana") : null, ["usoFinestra"] = five ? q?.FiveHourUtilization : state == "limite" ? use : null,
            };
        }
        return new JsonObject { ["stato"] = use is null ? "sconosciuta" : "libera", ["uso"] = use, ["soglia"] = threshold, ["fino"] = null, ["alzata"] = false, ["ignorata"] = false, ["finestra"] = null, ["usoFinestra"] = null };
    }

    /// <summary>La pagina: il modello del gioco con il codice e il dato dentro (New-PaginaUfficio); nel dato mai un "&lt;".</summary>
    public static string Page(string folder, JsonObject model)
    {
        string Read(string f) => File.ReadAllText(Path.Combine(folder, f));
        var script = string.Join("\n", new[] { "font.js", "mondo.js", "persone.js", "scena.js", "cervello.js", "entita.js", "openspace.js", "interfaccia.js", "principale.js" }.Select(Read));
        return Read("ufficio.html").Replace("@@SCRIPT@@", script).Replace("@@DATI@@", Json(model));
    }

    public static string Json(JsonObject model) => model.ToJsonString().Replace("<", "\\u003c");
}
