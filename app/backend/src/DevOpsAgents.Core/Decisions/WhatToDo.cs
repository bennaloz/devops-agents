using System.Text.RegularExpressions;
using DevOpsAgents.Core.Model;

namespace DevOpsAgents.Core.Decisions;

/// <summary>D57: cosa deve fare una persona davanti a un on-hold. Fonte: "agente" (le righe del ruolo) o "predefinita".</summary>
public sealed record Indications(string Action, string? Why, string? WhyNotAgents, string Source);

/// <summary>
/// D57: il gesto, perche serve, perche non l'hanno fatto gli agenti e cosa succede togliendo l'on-hold. Funzioni pure, come
/// src/CosaFare.psm1. Il gesto lo scrive il ruolo che ha visto la causa, di solito il responsabile, con le righe "Per il titolare:",
/// "Perche:" e "Perche non gli agenti:" in testa al suo testo; quando mancano vale il testo predefinito, per inAttesaPer e causa.
/// </summary>
public static class WhatToDo
{
    private static readonly (string Key, string Label)[] Labels =
    [
        ("Action", "Per (?:il )?titolare"),
        ("WhyNotAgents", "Perch(?:e|é|è) non gli agenti"),
        ("Why", "Perch(?:e|é|è)"),
    ];

    public const string DraftWarning = "Non riportarla in Draft o in New: lo smistatore la tratterebbe come una card nuova e perderebbe la PR e il ramo.";

    /// <summary>Le righe del ruolo in un testo, o null senza la riga del gesto. Vale la prima occorrenza; il markdown intorno si toglie.</summary>
    public static Indications? FromText(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var found = new Dictionary<string, string>();
        foreach (var line in text.Split('\n'))
        {
            foreach (var (key, label) in Labels)
            {
                if (found.ContainsKey(key)) continue;
                var m = Regex.Match(line.TrimEnd('\r'), $@"^\s*(?:[-*+>]\s*|\d+[.)]\s*)*[*_]*(?:{label})[*_]*\s*:[*_]*\s*(.+?)\s*$", RegexOptions.IgnoreCase);
                if (m.Success) { found[key] = Regex.Replace(m.Groups[1].Value, @"\*\*|__", "").Trim(); break; }
            }
        }
        return found.TryGetValue("Action", out var a) ? new Indications(a, found.GetValueOrDefault("Why"), found.GetValueOrDefault("WhyNotAgents"), "agente") : null;
    }

    /// <summary>Il testo predefinito per il motivo, inAttesaPer e la causa di una sessione chiusa dallo smistatore (silenzio, morta, fallita, scritture).</summary>
    public static Indications Defaults(string reason, string? waitingFor, string? cause)
    {
        var (g, p, n) = (cause, waitingFor) switch
        {
            ("scritture", _) => ("guarda il worktree della card: rimettilo com'era o tieni cio che serve", "un ruolo in sola lettura ha cambiato il worktree (D39)",
                "lo smistatore non decide quali modifiche tenere: una scrittura non prevista la valuta una persona"),
            ("fallita", _) => ("leggi nel registro delle sessioni perche la sessione e fallita (un errore o comandi negati dai permessi) e togli la causa",
                "la sessione e fallita: un nuovo tentativo uguale fallirebbe di nuovo", "lo smistatore non riprova una sessione fallita e il supervisore non riavvia le sessioni delle card (D51)"),
            ("silenzio" or "morta", _) => ("leggi l'ultimo commento e il registro delle sessioni della card e capisci perche la sessione si ferma", "la sessione si e fermata per la seconda volta",
                "lo smistatore riprende da solo una sessione ferma una volta sola (D51): la seconda volta serve qualcuno che capisca perche"),
            (_, "limite") when reason.Contains("rilanciare la validazione") => (
                "apri il log della build della PR e guarda il test che fallisce: se e instabile rilancia la validazione, se e un errore vero scrivi sulla card cosa correggere",
                "dev ha chiesto per la seconda volta di rilanciare la validazione (D38)",
                "dev non puo rilanciare una build, lo smistatore la rilancia una volta sola (D38) e il supervisore non rilancia le validazioni delle PR delle card (D51)"),
            (_, "limite") => ("leggi gli ultimi commenti della card e togli la causa, oppure scrivi sulla card come proseguire", reason,
                "gli agenti hanno gia riprovato fino al limite di config/limiti.json e il responsabile non ha trovato una correzione (D42)"),
            (_, "deploy") => ("apri il run del deploy in Test (il link e nei commenti della card) e togli la causa", "il deploy in Test e fallito",
                "il responsabile non puo rilanciare un deploy e il supervisore non tocca i deploy (D51)"),
            _ => ("leggi gli ultimi commenti della card e togli la causa", reason,
                "nessun agente ha il permesso o il dato per farlo, e il supervisore da solo riavvia solo la vista e i run falliti per infrastruttura (D51)"),
        };
        return new Indications(g, p, n, "predefinita");
    }

    /// <summary>Le righe del ruolo completate con il predefinito dove mancano. Un on-hold dello smistatore (con una causa) non usa le righe della sessione.</summary>
    public static Indications Resolve(string? sessionText, string reason, string? waitingFor, string? cause)
    {
        var defaults = Defaults(reason, waitingFor, cause);
        var agent = string.IsNullOrEmpty(cause) ? FromText(sessionText) : null;
        return agent is null ? defaults : agent with { Why = agent.Why ?? defaults.Why, WhyNotAgents = agent.WhyNotAgents ?? defaults.WhyNotAgents };
    }

    public static string EffectOfRemovingOnHold(string? waitingFor) => waitingFor switch
    {
        "sessione" => "riparte l'agente che si era fermato, e trova il tuo intervento",
        "limite" => "i contatori ripartono da zero e lo smistatore riprende la card dallo stato in cui e",
        "deploy" => "lo smistatore dimentica il run fallito e riaccoda il deploy in Test",
        _ => "lo smistatore riprende la card dallo stato in cui e, al prossimo giro",
    };

    public static IReadOnlyList<string> Lines(Indications i, string? waitingFor)
    {
        var lines = new List<string> { $"1. {i.Action}", $"2. Togli l'on-hold: {EffectOfRemovingOnHold(waitingFor)}." };
        if (i.Why is { Length: > 0 }) lines.Add($"Perche: {i.Why}");
        if (i.WhyNotAgents is { Length: > 0 }) lines.Add($"Perche non l'hanno fatto gli agenti: {i.WhyNotAgents}");
        lines.Add(DraftWarning);
        return lines;
    }

    /// <summary>La sezione in Markdown per il commento di on-hold: un paragrafo per riga (gli a capo singoli si perdono).</summary>
    public static string Format(Indications i, string? waitingFor) => "**Cosa fare**\n\n" + string.Join("\n\n", Lines(i, waitingFor));

    /// <summary>La sessione finita per ultima sulla card (senza fine conta dal suo inizio).</summary>
    public static SessionRecord? LatestSession(CardLocalState s) =>
        s.LastSessionByRole.Values.Where(x => (x.End ?? x.Start) is not null).OrderBy(x => x.End ?? x.Start).LastOrDefault();

    /// <summary>D58: la marca del commento che porta la descrizione della PR scritta prima che la PR esistesse.</summary>
    public const string SavedPrDescriptionMark = "Descrizione della PR:";

    /// <summary>
    /// D58: la descrizione salvata da dev o responsabile con descrizione-pr: vale l'ultima, senza la firma del ruolo. null se non c'e.
    /// </summary>
    public static string? SavedPrDescription(IEnumerable<Comment> comments)
    {
        string? text = null;
        foreach (var c in comments.OrderBy(c => c.Id))
        {
            var plain = PlainText(c.Text);
            foreach (var role in new[] { "dev", "responsabile" })
            {
                var m = Regex.Match(plain, $@"^\[{role}\]\s*{Regex.Escape(SavedPrDescriptionMark)}\s*\r?\n+");
                if (!m.Success) continue;
                var body = plain[m.Length..].TrimEnd();
                var signature = $"— scritto da Claude ({role})";
                if (body.EndsWith(signature)) body = body[..^signature.Length].TrimEnd();
                if (body.Length > 0) text = body;
            }
        }
        return text;
    }

    /// <summary>Il testo di un commento senza l'html della board: blocchi e a capo diventano righe.</summary>
    public static string PlainText(string html)
    {
        var t = Regex.Replace(html, @"<br\s*/?>|</(div|p|li|h\d)>", "\n", RegexOptions.IgnoreCase);
        t = Regex.Replace(t, "<[^>]+>", "");
        return System.Net.WebUtility.HtmlDecode(t).Replace("\r\n", "\n").Trim();
    }

    /// <summary>Il titolo della PR: Conventional Commits dal ramo (feature/ -> feat:, fix/ -> fix:), se il titolo non lo e gia.</summary>
    public static string PrTitle(string branch, string title)
    {
        title = title.Trim();
        if (Regex.IsMatch(title, @"^[a-z]+(\([^)]*\))?!?:")) return title;
        var type = Regex.IsMatch(branch, "^feature[/-]") ? "feat" : Regex.IsMatch(branch, "^(bug)?fix[/-]") ? "fix" : null;
        return type is null ? title : $"{type}: {title}";
    }
}
