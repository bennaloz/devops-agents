using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DevOpsAgents.Core.Update;

/// <summary>Un requisito non soddisfatto: il programma, la versione minima, quella trovata (null se non c'e).</summary>
public sealed record MissingRequirement(string Name, string Required, string? Found);

/// <summary>Una PR entrata nel canale, dal messaggio del commit di fusione.</summary>
public sealed record IncomingPr(int Number, string Title, string? Url = null);

/// <summary>Cosa tiene ferma la copia: sessioni dei modelli aperte e giri dello smistatore in corso.</summary>
public sealed record Occupancy(int Sessions, int Rounds);

/// <summary>
/// L'osservazione da cui si decide il passo: Head (commit della copia), Tip (di origin/&lt;canale&gt;, null se non c'e), Discarded (l'ultimo
/// commit scartato), Auto (aggiornamento automatico), Requested ("aggiorna adesso"), Relation, Modified (i file di git status), e due calcoli che
/// costano e si fanno solo se servono: Requirements e Occupancy. LocalChannelDiverges: il ramo locale con il nome del canale non e antenato di origin.
/// </summary>
public sealed record UpdateObservation(string Head, string? Tip, string? Discarded, bool Auto, bool Requested, string Relation, IReadOnlyList<string> Modified,
    Func<IReadOnlyList<MissingRequirement>> Requirements, Func<Occupancy> Occupancy, bool LocalChannelDiverges = false);

/// <summary>Il passo: Advance o no, l'esito da scrivere ("invariato" lascia quello di prima), se migrare i file di config modificati.</summary>
public sealed record UpdateStep(bool Advance, string Outcome, bool Migrate = false, IReadOnlyList<string>? Files = null,
    IReadOnlyList<MissingRequirement>? Missing = null, Occupancy? Occupancy = null);

/// <summary>
/// D53: le regole pure dell'aggiornamento automatico della suite, come Aggiornamento.psm1: il canale, il confronto delle versioni, i requisiti,
/// le PR in arrivo, la relazione della copia con l'origine, il passo da fare. La copia si avanza solo in fast-forward e mai su lavoro non committato.
/// </summary>
public static class UpdateRules
{
    public static readonly string[] Channels = ["main", "develop"];

    /// <summary>I file di config che una persona puo aver cambiato a mano e che l'aggiornamento sa migrare in impostazioni.json: file -> sezione.</summary>
    public static readonly IReadOnlyDictionary<string, string> MigratableFiles = new Dictionary<string, string> { ["config/limiti.json"] = "limiti", ["config/supervisore.json"] = "supervisore" };

    /// <summary>L'unico esito che tiene viva una richiesta "aggiorna adesso": l'attesa delle sessioni.</summary>
    public const string WaitingForSessions = "inAttesaSessioni";

    /// <summary>Il canale: quello delle impostazioni se valido, altrimenti il ramo estratto se e main o develop, altrimenti main.</summary>
    public static string Channel(string? configured, string? checkedOut) =>
        configured is not null && Channels.Contains(configured) ? configured : checkedOut is not null && Channels.Contains(checkedOut) ? checkedOut : "main";

    /// <summary>La prima versione (almeno due numeri) in un testo come "2.1.328 (Claude Code)"; null se non c'e.</summary>
    public static Version? ParseVersion(string? text)
    {
        var m = Regex.Match(text ?? "", @"(\d+(?:\.\d+){1,3})");
        return m.Success && Version.TryParse(m.Groups[1].Value, out var v) ? v : null;
    }

    /// <summary>
    /// I requisiti non soddisfatti: requisiti.json (nome -> versione minima) contro le versioni trovate (nome -> testo, null se il programma non c'e).
    /// Si controllano solo i nomi che si sanno misurare: un requisito nuovo che questa versione non sa leggere non blocca.
    /// </summary>
    public static IReadOnlyList<MissingRequirement> Missing(JsonObject? requirements, IReadOnlyDictionary<string, string?> found)
    {
        var missing = new List<MissingRequirement>();
        if (requirements is null) return missing;
        foreach (var (name, node) in requirements)
        {
            if (!found.TryGetValue(name, out var text)) continue;
            var raw = node is JsonValue v && v.TryGetValue<string>(out var s) ? s : node?.ToJsonString() ?? "";
            if (ParseVersion(raw) is not { } min) continue;
            var have = ParseVersion(text);
            if (have is null || have < min) missing.Add(new(name, raw, have?.ToString()));
        }
        return missing;
    }

    /// <summary>Le PR dai messaggi dei commit sul primo genitore: "Merged PR n: titolo" (Azure DevOps) e "Merge pull request #n from ramo" (GitHub).</summary>
    public static IReadOnlyList<IncomingPr> PrsFromLog(IEnumerable<string> subjects)
    {
        var r = new List<IncomingPr>();
        foreach (var s in subjects.Where(x => !string.IsNullOrEmpty(x)))
        {
            var m = Regex.Match(s, @"^Merged PR (\d+):\s*(.*?)\s*$", RegexOptions.IgnoreCase);
            if (m.Success) { r.Add(new(int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture), m.Groups[2].Value)); continue; }
            m = Regex.Match(s, @"^Merge pull request #?(\d+) from (\S+)", RegexOptions.IgnoreCase);
            if (m.Success) r.Add(new(int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture), m.Groups[2].Value));
        }
        return r;
    }

    /// <summary>uguale, indietro (si avanza in fast-forward), avanti, divergente, o senzaOrigine se origin/&lt;canale&gt; non c'e.</summary>
    public static string Relation(string head, string? tip, bool headIsAncestorOfTip, bool tipIsAncestorOfHead) =>
        tip is null ? "senzaOrigine" : head == tip ? "uguale" : headIsAncestorOfTip ? "indietro" : tipIsAncestorOfHead ? "avanti" : "divergente";

    /// <summary>I percorsi da git status --porcelain, anche i non tracciati; un rinominato da due percorsi; senza le virgolette di git.</summary>
    public static IReadOnlyList<string> ModifiedFiles(string porcelain) =>
        Regex.Split(porcelain ?? "", "\r?\n").Where(l => l.Trim().Length > 0 && l.Length >= 4)
            .SelectMany(l => l[3..].Split(" -> ")).Select(p => p.Trim().Trim('"')).ToList();

    /// <summary>Il passo da fare: i casi in ordine, il primo che vale decide (Get-PassoAggiornamento).</summary>
    public static UpdateStep Step(UpdateObservation o)
    {
        if (o.Relation == "senzaOrigine") return new(false, "invariato");
        if (o.Relation == "uguale") return new(false, "aggiornato");
        // lo stesso commit che ha gia fallito non si riprova finche origine non va oltre; "aggiorna adesso" lo riprova
        if (o.Discarded is not null && o.Discarded == o.Tip && !o.Requested) return new(false, "invariato");
        if (o.Relation == "avanti") return new(false, "copiaAvanti");
        if (o.Relation == "divergente") return new(false, "divergente");
        if (!(o.Auto || o.Requested)) return new(false, "daAggiornare");
        // checkout -B del canale lo porta su origin: se il ramo locale con quel nome ha commit che origin non ha, li perderebbe
        if (o.LocalChannelDiverges) return new(false, "ramoCanaleDivergente");
        var files = o.Modified.Where(f => f.Length > 0).ToList();
        var migrate = false;
        if (files.Count > 0)
        {
            if (files.Any(f => !MigratableFiles.ContainsKey(f))) return new(false, "modificheLocali", Files: files);
            migrate = true;
        }
        var missing = o.Requirements();
        if (missing.Count > 0) return new(false, "requisitiMancanti", Missing: missing);
        var occ = o.Occupancy();
        if (occ.Sessions > 0 || occ.Rounds > 0) return new(false, WaitingForSessions, Occupancy: occ);
        return new(true, "aggiornato", migrate, files, Occupancy: occ);
    }

    /// <summary>Il controllo con fetch e dovuto: subito con una richiesta o senza un controllo prima, altrimenti dopo i minuti.</summary>
    public static bool CheckDue(DateTimeOffset? last, int minutes, DateTimeOffset now, bool requested) =>
        requested || last is null || (now - last.Value).TotalMinutes >= minutes;

    public static bool WaitedTooLong(DateTimeOffset? since, DateTimeOffset now, double hours) => since is not null && (now - since.Value).TotalHours >= hours;

    /// <summary>La versione come si legge: "main 4f3a2b1 (25/11/2026)".</summary>
    public static string FormatVersion(string? channel, string? hash, DateTimeOffset? date) =>
        hash is null ? "non nota" : $"{channel} {hash} ({(date is { } d ? d.ToLocalTime().ToString("dd/MM/yyyy", CultureInfo.InvariantCulture) : "data non nota")})".Trim();

    /// <summary>L'indirizzo base del repo da origin per i link alle PR: Azure DevOps (…/_git/repo) o GitHub; null se non lo riconosce.</summary>
    public static string? PrBaseUrl(string? origin)
    {
        var o = origin?.Trim() ?? "";
        var ado = Regex.Match(o, @"^(https://)(?:[^/@]+@)?([^/]+/.+?/_git/[^/]+?)/?$");
        if (ado.Success) return $"{ado.Groups[1].Value}{ado.Groups[2].Value}/pullrequest/";
        var gh = Regex.Match(o, @"^(?:https://(?:[^/@]+@)?github\.com/|git@github\.com:)([\w.-]+/[\w.-]+?)(?:\.git)?/?$");
        return gh.Success ? $"https://github.com/{gh.Groups[1].Value}/pull/" : null;
    }

    /// <summary>
    /// La migrazione di un file di config cambiato a mano: le chiavi di primo livello che differiscono da quelle del commit vanno nella sezione di
    /// impostazioni.json, senza sovrascrivere un override gia presente. Restituisce la sezione aggiornata.
    /// </summary>
    public static JsonObject MigrateOverrides(JsonObject committed, JsonObject local, JsonObject? existing)
    {
        var section = existing?.DeepClone().AsObject() ?? new JsonObject();
        foreach (var (k, v) in local)
        {
            if (section.ContainsKey(k)) continue;
            if (!committed.TryGetPropertyValue(k, out var c) || !SameValue(c, v)) section[k] = v?.DeepClone();
        }
        return section;
    }

    /// <summary>Due valori letti da JSON sono lo stesso valore: i numeri come numeri (1 e 1.0 sono uguali), il resto sul JSON.</summary>
    public static bool SameValue(JsonNode? a, JsonNode? b)
    {
        if (a is JsonValue va && b is JsonValue vb && va.TryGetValue<double>(out var da) && vb.TryGetValue<double>(out var db)) return da == db;
        return JsonNode.DeepEquals(a, b);
    }
}
