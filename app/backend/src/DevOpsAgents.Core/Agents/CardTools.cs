using System.Text;
using System.Text.RegularExpressions;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;

namespace DevOpsAgents.Core.Agents;

/// <summary>Un rifiuto di uno strumento della card: il messaggio va all'agente cosi com'e.</summary>
public sealed class CardToolException(string message) : InvalidOperationException(message);

/// <summary>
/// La sessione a cui sono legati gli strumenti: la card, il ruolo e il task li decide lo smistatore al lancio, mai l'agente
/// (come ATTREZZI_CARD, ATTREZZI_RUOLO e ATTREZZI_TASK per card.ps1): una sessione non puo scrivere su un'altra card.
/// </summary>
public sealed record AgentSession(int CardId, string Role, int? TaskId = null);

/// <summary>
/// Gli strumenti degli agenti sulla loro card: la conversione di src/card.ps1 e src/Card.psm1, con gli stessi controlli e gli stessi
/// testi sulla board (prefisso [ruolo], firma, marche del deploy, della descrizione della PR e della correzione), cosi lo smistatore
/// PowerShell e quello .NET leggono le stesse cose. I permessi per ruolo stanno qui: il server MCP espone solo quello che il ruolo puo fare.
/// </summary>
public sealed class CardTools(
    AgentSession session,
    ICardEditor board,
    ICodeHostResolver code,
    StateNames names,
    IReadOnlyDictionary<string, RoleSettings> roles,
    IReadOnlyList<AreaMapping> areas,
    IDeployParameters? deploy = null,
    Action<int, int>? ownRevision = null)
{
    public const int MaxComments = 10;
    /// <summary>La firma che il code host mette in fondo alla descrizione di una PR.</summary>
    public const string PrSignature = "🤖 Generated with [Claude Code](https://claude.com/claude-code)";
    /// <summary>Il massimo di caratteri del testo di una PR: il limite di Azure DevOps (4000) meno la firma e il suo separatore.</summary>
    public static readonly int PrTextLimit = 4000 - 2 - PrSignature.Length;
    public const string DeployMark = "Parametri del deploy in Test:";
    public const string PrDescriptionMark = "Descrizione della PR:";
    public const string CorrectionMark = "Correzione:";
    public const string CorrectionTitleMark = "Titolo:";
    public static readonly string[] CorrectionKinds = ["tecnico", "prodotto"];
    public const string NoDeployForTestEnvironment = "si prova nell'ambiente Docker della card (D59): nessun parametro da scegliere, non e un motivo per senza-test";

    private int Id => session.CardId;
    private string Role => session.Role;

    public static string Signature(string role) => $"— scritto da Claude ({role})";

    // ---- chi puo cosa ------------------------------------------------------------------------------------------------

    /// <summary>Gli strumenti che il ruolo puo usare, per nome (quelli di card.ps1): il server MCP espone solo questi.</summary>
    public IReadOnlyList<string> Available() => AvailableFor(Role, session.TaskId, roles);

    /// <summary>Gli strumenti di un ruolo senza una board: servono anche a chi scrive il brief della sessione.</summary>
    public static IReadOnlyList<string> AvailableFor(string role, int? taskId, IReadOnlyDictionary<string, RoleSettings> roles)
    {
        var list = new List<string> { "leggi", "commenta" };
        if (roles.TryGetValue(role, out var r) && r.Transitions is { Count: > 0 }) list.Add("sposta");
        if (role == "responsabile") list.AddRange(["criteri", "crea-task", "senza-test", "prova-umana", "deploy", "correzione"]);
        if (role == "dev" && taskId is > 0) list.Add("chiudi-task");
        if (role is "dev" or "responsabile") list.AddRange(["titolo-pr", "descrizione-pr"]);
        return list;
    }

    public IReadOnlyList<RoleTransition> Transitions() =>
        roles.TryGetValue(Role, out var r) ? r.Transitions ?? [] : throw new CardToolException($"Ruolo sconosciuto: '{Role}'");

    private void Require(string what, params string[] allowed)
    {
        if (!allowed.Contains(Role)) throw new CardToolException($"Il ruolo '{Role}' non puo {what}: solo {string.Join(" e ", allowed)}");
    }

    // ---- leggi -------------------------------------------------------------------------------------------------------

    public async Task<string> ReadAsync(CancellationToken ct = default)
    {
        var detail = await board.GetCardAsync(Id, ct);
        var card = detail.Card;
        var all = (await board.GetCommentsAsync(Id, ct)).OrderBy(c => c.Id).ToList();
        var comments = all.TakeLast(MaxComments).ToList();
        var choice = DeployChoice(all);
        var tasks = await board.GetTaskDetailsAsync(Id, ct);
        var r = new List<string>
        {
            $"Card {card.Id} - {card.Title}",
            $"Tipo: {card.WorkItemType} | Stato: {card.State} | Area: {card.Area}",
            "", "TAG", card.Tags.Count > 0 ? string.Join(", ", card.Tags) : "(nessuno)", "",
        };
        r.AddRange(await FeatureLinesAsync(card, ct));
        r.AddRange(["DESCRIZIONE", detail.Description ?? "", "", "CRITERI DI ACCETTAZIONE", detail.Criteria ?? "", "", "DEPLOY IN TEST"]);
        r.Add(AreaOf(card)?.TestEnvironment is not null ? NoDeployForTestEnvironment
            : choice is { Count: > 0 } ? string.Join(", ", choice) : "nessuna scelta del responsabile (lo strumento deploy)");
        r.Add("");
        if (tasks.Count > 0)
        {
            r.Add($"TASK ({tasks.Count}, nell'ordine di esecuzione)");
            foreach (var t in tasks)
            {
                r.Add($"#{t.Id} [{t.State}] {t.Title}{(session.TaskId is > 0 && t.Id == session.TaskId ? " <- il tuo task" : "")}");
                r.Add(t.Description ?? "");
                r.Add("");
            }
        }
        r.Add($"COMMENTI (ultimi {comments.Count}, dal piu vecchio al piu nuovo)");
        foreach (var c in comments)
        {
            r.Add($"#{c.Id} {c.Author} {c.When:O}");
            r.Add(c.Text);
            r.Add("");
        }
        return string.Join("\n", r);
    }

    /// <summary>D52: la sezione FUNZIONALITA, per una card figlia di una Feature con la card di chiusura; niente per una card isolata.</summary>
    private async Task<IReadOnlyList<string>> FeatureLinesAsync(Card card, CancellationToken ct)
    {
        if (card.ParentId is not { } parent) return [];
        try
        {
            var f = await board.GetWorkItemAsync(parent, ct);
            if (f.Type != "Feature") return [];
            if (await CompositionAsync(f.Id, ct) is not var (closing, siblings)) return [];
            var r = new List<string> { "FUNZIONALITA", $"Feature {f.Id} [{f.State}] {f.Title}", $"card di chiusura: #{closing.Id}" };
            r.Add(closing.Id == card.Id ? "questa card e la card di chiusura: prova in Test le sorelle gia unite nel ramo della funzionalita" : "questa card e una sorella");
            r.Add($"sorelle ({siblings.Count}):");
            r.AddRange(siblings.Select(s => $"#{s.Id} [{s.State}] {s.Title} ({string.Join(", ", s.Tags)})"));
            r.Add("");
            return r;
        }
        catch (Exception e) when (e is not OperationCanceledException and not CardToolException)
        {
            return ["FUNZIONALITA", $"la Feature {parent} non si legge: {e.Message}", ""];
        }
    }

    /// <summary>D52: la card di chiusura (con il tag, la prima per id) e le sorelle (card, non rimosse); null se la Feature non ne ha una.</summary>
    private async Task<(Card Closing, IReadOnlyList<Card> Siblings)?> CompositionAsync(int featureId, CancellationToken ct)
    {
        var alive = (await board.GetFeatureChildrenAsync(featureId, ct)).Where(c => names.KeyOf(c.State) != StateKeys.Removed).ToList();
        var closing = alive.Where(c => names.ClosingTag is { } t && c.Tags.Contains(t, StringComparer.Ordinal)).OrderBy(c => c.Id).FirstOrDefault();
        if (closing is null) return null;
        return (closing, alive.Where(c => c.Id != closing.Id && c.WorkItemType is "User Story" or "Bug").OrderBy(c => c.Id).ToList());
    }

    /// <summary>D52: la Feature di cui questa card e la card di chiusura, o null.</summary>
    private async Task<int?> ClosingFeatureOfAsync(Card card, CancellationToken ct)
    {
        if (card.ParentId is not { } parent) return null;
        var f = await board.GetWorkItemAsync(parent, ct);
        if (f.Type != "Feature") return null;
        return await CompositionAsync(f.Id, ct) is { } p && p.Closing.Id == card.Id ? f.Id : null;
    }

    // ---- commenti, criteri, stato --------------------------------------------------------------------------------------

    public async Task<string> CommentAsync(string text, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new CardToolException("manca il testo del commento");
        await AddCommentAsync(text, ct);
        return "Commento aggiunto.";
    }

    /// <summary>Prefisso e firma li mette lo strumento; un modello che li imita non deve trovarli due volte.</summary>
    public static string CommentBody(string role, string text)
    {
        var prefix = $"[{role}]";
        var signature = Signature(role);
        var t = text.Trim();
        while (t.StartsWith(prefix, StringComparison.Ordinal)) t = t[prefix.Length..].TrimStart();
        while (t.EndsWith(signature, StringComparison.Ordinal)) t = t[..^signature.Length].TrimEnd();
        return $"{prefix} {t}\n\n{signature}";
    }

    private Task AddCommentAsync(string text, CancellationToken ct) => board.AddCommentAsync(Id, CommentBody(Role, text), ct);

    public async Task<string> SetCriteriaAsync(string text, CancellationToken ct = default)
    {
        Require("scrivere i criteri", "responsabile");
        if (string.IsNullOrWhiteSpace(text)) throw new CardToolException("manca il testo dei criteri");
        await board.SetCriteriaAsync(Id, text.TrimEnd('\r', '\n'), ct);
        return "Criteri aggiornati.";
    }

    public async Task<string> MoveAsync(string stateKey, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(stateKey)) throw new CardToolException("manca la chiave dello stato");
        var target = names.Get(stateKey);
        if (target is null || stateKey.StartsWith("tag", StringComparison.Ordinal) || stateKey.StartsWith("task", StringComparison.Ordinal) || stateKey.StartsWith("feature", StringComparison.Ordinal))
            throw new CardToolException($"Stato sconosciuto: '{stateKey}' non e una chiave di stati.json");
        var card = (await board.GetCardAsync(Id, ct)).Card;
        var from = names.KeyOf(card.State) ?? throw new CardToolException($"La card {Id} e in uno stato non previsto da stati.json: '{card.State}'");
        if (!Transitions().Any(t => t.From == from && t.To == stateKey))
            throw new CardToolException($"Il ruolo '{Role}' non puo spostare una card da '{from}' a '{stateKey}'");
        var rev = await board.MoveAsync(Id, target, ct);
        ownRevision?.Invoke(Id, rev);
        return $"Card spostata in '{stateKey}'.";
    }

    // ---- task ----------------------------------------------------------------------------------------------------------

    public sealed record TaskText(string Title, string Text);

    /// <summary>
    /// Il testo dei task: ogni task comincia con una riga "=== &lt;titolo&gt;", il testo e quello che segue fino al titolo dopo. Si valida
    /// tutto prima di creare qualunque cosa: un testo malformato non lascia task a meta.
    /// </summary>
    public static IReadOnlyList<TaskText> ParseTasks(string text)
    {
        var tasks = new List<(string Title, List<string> Lines)>();
        var before = new StringBuilder();
        foreach (var line in Regex.Split(text, "\r?\n"))
        {
            var m = Regex.Match(line, @"^===\s+(\S.*?)\s*$");
            if (m.Success) tasks.Add((m.Groups[1].Value, []));
            else if (tasks.Count == 0) before.Append(line);
            else tasks[^1].Lines.Add(line);
        }
        if (!string.IsNullOrWhiteSpace(before.ToString())) throw new CardToolException("il testo dei task deve cominciare con una riga '=== <titolo>': c'e testo prima del primo titolo");
        if (tasks.Count == 0) throw new CardToolException("nessun task nel testo: ogni task comincia con una riga '=== <titolo>'");
        return tasks.Select((t, i) =>
        {
            var body = string.Join("\n", t.Lines).Trim();
            if (body.Length == 0) throw new CardToolException($"il task {i + 1} ('{t.Title}') non ha testo: serve cosa fare e da cosa si vede che e fatto");
            return new TaskText(t.Title, body);
        }).ToList();
    }

    private static string TaskKey(string title) => Regex.Replace(title.Trim().ToLowerInvariant(), @"\s+", " ");

    public async Task<string> CreateTasksAsync(string text, CancellationToken ct = default)
    {
        Require("creare i task", "responsabile");
        if (string.IsNullOrWhiteSpace(text)) throw new CardToolException("manca il testo dei task");
        var items = ParseTasks(text);
        // aggiungere task e permesso, un doppione no: il confronto e sul titolo; un task rimosso non conta
        var removed = names.Get("taskRimosso");
        var existing = (await board.GetTaskDetailsAsync(Id, ct)).Where(t => !string.Equals(t.State, removed, StringComparison.OrdinalIgnoreCase)).ToList();
        var problems = items.Select(v => existing.FirstOrDefault(e => TaskKey(e.Title) == TaskKey(v.Title)) is { } e ? $"'{v.Title}' esiste gia come #{e.Id}" : null)
            .Where(x => x is not null).Cast<string>()
            .Concat(items.GroupBy(v => TaskKey(v.Title)).Where(g => g.Count() > 1).Select(g => $"'{g.First().Title}' compare {g.Count()} volte")).ToList();
        if (problems.Count > 0) throw new CardToolException($"nessun task creato, doppioni: {string.Join("; ", problems)}");
        var card = (await board.GetCardAsync(Id, ct)).Card;
        var created = new List<TaskDetail>();
        foreach (var v in items)
        {
            try { created.Add(await board.CreateTaskAsync(Id, v.Title, v.Text, card.Area ?? "", ct)); }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                var done = created.Count > 0 ? $"gia creati: {string.Join(", ", created.Select(c => $"#{c.Id}"))}" : "nessuno creato prima";
                throw new CardToolException($"creazione del task '{v.Title}' non riuscita ({done}; i task dopo questo non sono stati creati): {e.Message}");
            }
        }
        return $"Creati {created.Count} task, nell'ordine: {string.Join(", ", created.Select(c => $"#{c.Id}"))}.";
    }

    /// <summary>Chiude il task della sessione di dev; un id diverso si rifiuta.</summary>
    public async Task<string> CloseTaskAsync(int? requested = null, CancellationToken ct = default)
    {
        Require("chiudere un task", "dev");
        if (session.TaskId is not > 0) throw new CardToolException("questa sessione non e di un task: non c'e niente da chiudere");
        var id = session.TaskId.Value;
        if (requested is { } r && r != id) throw new CardToolException($"il task {r} non e quello di questa sessione ({id}): si chiude solo il proprio");
        var t = (await board.GetTaskDetailsAsync(Id, ct)).FirstOrDefault(x => x.Id == id) ?? throw new CardToolException($"il task {id} non e figlio della card {Id}");
        if (string.Equals(t.State, names.Get("taskChiuso"), StringComparison.OrdinalIgnoreCase)) return $"Il task {id} era gia chiuso.";
        if (string.Equals(t.State, names.Get("taskRimosso"), StringComparison.OrdinalIgnoreCase)) throw new CardToolException($"il task {id} e rimosso: non si chiude");
        await board.SetTaskStateAsync(id, names["taskChiuso"], ct);
        return $"Task {id} chiuso.";
    }

    // ---- senza-test, prova-umana, correzione -----------------------------------------------------------------------------

    public async Task<string> NoTestAsync(string reason, CancellationToken ct = default)
    {
        Require("togliere la prova in Test", "responsabile");
        if (string.IsNullOrWhiteSpace(reason)) throw new CardToolException("manca il motivo: perche nessun criterio si verifica in Test");
        var tag = names.NoTestTag ?? throw new CardToolException("stati.json non ha tagSenzaTest");
        await board.AddTagAsync(Id, tag, ct);
        await AddCommentAsync($"Niente prova in Test (tag {tag}): {reason.Trim()}", ct);
        return "Niente prova in Test: tag aggiunto e motivo scritto sulla card.";
    }

    public async Task<string> HumanTestAsync(string reason, CancellationToken ct = default)
    {
        Require("chiedere la prova di una persona", "responsabile");
        if (string.IsNullOrWhiteSpace(reason)) throw new CardToolException("manca il motivo: quale criterio lo giudica una persona");
        var tag = names.HumanTestTag ?? throw new CardToolException("stati.json non ha tagProvaUmana");
        await board.AddTagAsync(Id, tag, ct);
        await AddCommentAsync($"Prova di una persona in Human test (tag {tag}): {reason.Trim()}", ct);
        return "Prova di una persona richiesta: tag human-test aggiunto e motivo scritto sulla card.";
    }

    /// <summary>
    /// D52: la correzione sulla card di chiusura. Non crea niente: scrive un commento con la marca e la Bug la fa lo smistatore, una per commento.
    /// </summary>
    public async Task<string> CorrectionAsync(string kind, string title, string description, CancellationToken ct = default)
    {
        Require("scrivere una correzione", "responsabile");
        kind = (kind ?? "").Trim();
        if (!CorrectionKinds.Contains(kind))
            throw new CardToolException("la natura della correzione e 'tecnico' o 'prodotto': tecnico se il comportamento atteso e gia scritto nei criteri, prodotto se serve una scelta che spetta a una persona");
        if (string.IsNullOrWhiteSpace(title)) throw new CardToolException("manca il titolo della correzione");
        if (string.IsNullOrWhiteSpace(description)) throw new CardToolException($"la correzione '{title.Trim()}' non ha testo: serve cosa correggere e da cosa si vede che e corretto");
        var card = (await board.GetCardAsync(Id, ct)).Card;
        if (await ClosingFeatureOfAsync(card, ct) is null)
            throw new CardToolException($"la correzione si scrive solo sulla card di chiusura di una funzionalita: la card {Id} non lo e");
        await AddCommentAsync($"{CorrectionMark} {kind}\n{CorrectionTitleMark} {title.Trim()}\n\n{description.Trim()}", ct);
        return $"Correzione {kind} scritta: '{title.Trim()}'. Lo smistatore ne fa una Bug figlia della Feature.";
    }

    // ---- deploy in Test (D43) --------------------------------------------------------------------------------------------

    /// <summary>L'ultima scelta del deploy del responsabile ("[responsabile] Parametri del deploy in Test: a, b"); null se non c'e.</summary>
    public static IReadOnlyList<string>? DeployChoice(IEnumerable<Comment> comments)
    {
        IReadOnlyList<string>? choice = null;
        var mark = Regex.Escape(DeployMark);
        foreach (var c in comments.OrderBy(c => c.Id))
        {
            var first = PlainText(c.Text).Split('\n', 2)[0].TrimEnd('\r');
            var m = Regex.Match(first, $@"^\[responsabile\]\s*{mark}(.*)$");
            if (m.Success) choice = Regex.Replace(m.Groups[1].Value, "[`*]", "").Split([',', ' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
        }
        return choice;
    }

    /// <summary>Il testo di un commento come testo semplice: Azure DevOps puo restituirlo in html.</summary>
    public static string PlainText(string text)
    {
        var h = Regex.Replace(text, @"(?i)<br\s*/?>", "\n");
        h = Regex.Replace(h, @"(?i)</(?:div|p|li|ul|ol|h[1-6]|tr|table|blockquote|pre)\s*>", "\n");
        return System.Net.WebUtility.HtmlDecode(Regex.Replace(h, "<[^>]*>", "")).TrimStart();
    }

    public async Task<string> DeployAsync(IReadOnlyList<string> parameters, string why, CancellationToken ct = default)
    {
        Require("scegliere il deploy in Test", "responsabile");
        var chosen = parameters.SelectMany(p => p.Split([',', ' ', '\t'], StringSplitOptions.RemoveEmptyEntries)).Distinct(StringComparer.Ordinal).ToList();
        if (chosen.Count == 0) throw new CardToolException("mancano i parametri del deploy");
        if (string.IsNullOrWhiteSpace(why)) throw new CardToolException("manca il perche: cosa della card tocca quei componenti");
        var card = (await board.GetCardAsync(Id, ct)).Card;
        var area = AreaOf(card) ?? throw new CardToolException($"l'area '{card.Area}' della card non e in config/mappa.json");
        if (area.TestEnvironment is not null) return NoDeployForTestEnvironment;
        if (area.DeployPipeline is null)
            throw new CardToolException($"il componente '{area.Component}' non ha un deploy in Test (pipelineDeploy nella mappa): se nessun criterio si prova in Test usa senza-test");
        if (deploy is null) throw new CardToolException("i parametri del deploy non si possono leggere da qui (pipeline non configurate)");
        // D52: la card di chiusura non ha un ramo suo, il suo codice e nel ramo della funzionalita
        var featureId = await ClosingFeatureOfAsync(card, ct);
        var branch = await PublishedBranchAsync(area, featureId, ct) ?? "develop";
        var allowed = await deploy.GetAsync(area, branch, ct);
        var unknown = chosen.Where(n => !allowed.Contains(n, StringComparer.Ordinal)).ToList();
        if (unknown.Count > 0)
            throw new CardToolException($"parametro di deploy sconosciuto: {string.Join(", ", unknown)}. Sul ramo {branch} la pipeline {area.DeployPipeline} ha questi parametri deploy*: {(allowed.Count > 0 ? string.Join(", ", allowed) : "nessuno")}");
        await AddCommentAsync($"{DeployMark} {string.Join(", ", chosen)}\n\nPerche: {why.Trim()}", ct);
        return $"Deploy in Test: {string.Join(", ", chosen)} (parametri letti sul ramo {branch}).";
    }

    /// <summary>Il ramo della card su origin (feature/&lt;id&gt;-... o fix/&lt;id&gt;-...), o della funzionalita; null se non c'e, errore se piu di uno.</summary>
    private async Task<string?> PublishedBranchAsync(AreaMapping area, int? featureId, CancellationToken ct)
    {
        var (prefixes, idPart, of) = featureId is { } f ? (new[] { "feature", "bugfix" }, $"f{f}", $"della funzionalita {f}") : (new[] { "feature", "fix" }, $"{Id}", $"della card {Id}");
        var pattern = $"^({string.Join("|", prefixes)})/{idPart}(-.*)?$";
        var found = new List<string>();
        foreach (var p in prefixes) found.AddRange((await code.For(area).ListBranchesAsync(area, $"{p}/{idPart}", ct)).Where(b => Regex.IsMatch(b, pattern)));
        found = found.Distinct().ToList();
        if (found.Count > 1) throw new CardToolException($"Su origin c'e piu di un ramo {of}: {string.Join(", ", found)}. Quale vale lo decide una persona");
        return found.SingleOrDefault();
    }

    /// <summary>
    /// I booleani deploy* della sezione parameters di uno YAML di pipeline (ConvertFrom-YamlParametriDeploy): una lettura a righe, senza
    /// libreria YAML, che basta alla forma delle pipeline (voci "- name:" con type allo stesso rientro).
    /// </summary>
    public static IReadOnlyList<string> DeployParametersFromYaml(string yaml)
    {
        var inside = false;
        int? indent = null;
        Dictionary<string, string>? item = null;
        var column = 0;
        var items = new List<Dictionary<string, string>>();
        static string Value(string v) => Regex.Replace(v, @"\s+#.*$", "").Trim().Trim('"', '\'');
        void Key(string text, int col)
        {
            var m = Regex.Match(text, @"^(name|type):\s*(.+)$");
            if (m.Success && item is not null && col == column && !item.ContainsKey(m.Groups[1].Value)) item[m.Groups[1].Value] = Value(m.Groups[2].Value);
        }
        foreach (var line in Regex.Split(yaml.TrimStart('﻿'), "\r?\n"))
        {
            if (!inside) { if (Regex.IsMatch(line, @"^parameters:\s*(#.*)?$")) inside = true; continue; }
            if (Regex.IsMatch(line, @"^\s*(#.*)?$")) continue;
            if (Regex.IsMatch(line, @"^[^\s#-]")) break;
            var dash = Regex.Match(line, @"^((\s*)-\s+)(.*)$");
            if (dash.Success && (indent is null || dash.Groups[2].Length == indent))
            {
                indent ??= dash.Groups[2].Length;
                item = new(); items.Add(item); column = dash.Groups[1].Length;
                Key(dash.Groups[3].Value, column);
                continue;
            }
            if (item is null) continue;
            var m = Regex.Match(line, @"^(\s*)(\S.*)$");
            if (m.Success) Key(m.Groups[2].Value, m.Groups[1].Length);
        }
        return items.Where(i => i.GetValueOrDefault("type") == "boolean" && i.GetValueOrDefault("name") is { } n && n.StartsWith("deploy", StringComparison.Ordinal))
            .Select(i => i["name"]).ToList();
    }

    // ---- la PR della card ------------------------------------------------------------------------------------------------

    /// <summary>La PR attiva della card, dai suoi link (non da un id dato da fuori): l'unica che un ruolo puo toccare.</summary>
    private async Task<(AreaMapping Area, ICodeHost Host, int Id, string Branch)?> ActivePrAsync(Card card, CancellationToken ct)
    {
        if (await board.GetLinkedPullRequestIdAsync(Id, ct) is not { } prId) return null;
        var area = AreaOf(card) ?? throw new CardToolException($"l'area '{card.Area}' della card non e in config/mappa.json");
        var host = code.For(area);
        return await host.GetPullRequestByIdAsync(area, prId, ct) is { Status: PrStatuses.Active } pr ? (area, host, prId, pr.Branch) : null;
    }

    private static IPullRequestEditor Editor(ICodeHost host) =>
        host as IPullRequestEditor ?? throw new CardToolException("questa sorgente non permette di cambiare titolo e descrizione della PR");

    public async Task<string> SetPrTitleAsync(string title, CancellationToken ct = default)
    {
        Require("cambiare il titolo della PR", "dev", "responsabile");
        title = (title ?? "").Trim();
        if (title.Length == 0) throw new CardToolException("manca il titolo nuovo della PR");
        var card = (await board.GetCardAsync(Id, ct)).Card;
        var pr = await ActivePrAsync(card, ct) ?? throw new CardToolException($"la card {Id} non ha una PR attiva");
        await Editor(pr.Host).SetTitleAsync(pr.Area, pr.Id, title, ct);
        // una validazione rossa per il titolo si rilancia subito, perche il nuovo titolo conti
        var n = await pr.Host.RequeueValidationsAsync(pr.Area, pr.Branch, "develop", false, ct);
        return $"Titolo della PR {pr.Id} cambiato in '{title}'. Validazioni rilanciate: {n}.";
    }

    /// <summary>
    /// La descrizione della PR: il testo va dopo la riga con il link alla card, che resta. Senza PR il testo si salva sulla card (D58) e lo
    /// smistatore lo mette nella PR quando la apre. Il tetto si controlla prima di scrivere: un testo troppo lungo si rifiuta, non si tronca.
    /// </summary>
    public async Task<string> SetPrDescriptionAsync(string markdown, CancellationToken ct = default)
    {
        Require("scrivere la descrizione della PR", "dev", "responsabile");
        var text = (markdown ?? "").Trim();
        if (text.Length == 0) throw new CardToolException("la descrizione e vuota");
        var card = (await board.GetCardAsync(Id, ct)).Card;
        var link = $"[Card {Id}]({board.CardUrl(Id)})";
        if (await ActivePrAsync(card, ct) is not { } pr)
        {
            var room = PrTextLimit - link.Length - 2;
            if (text.Length > room) throw new CardToolException($"la descrizione e di {text.Length} caratteri: con il link alla card ne restano al massimo {room} per il testo. Accorciala");
            await AddCommentAsync($"{PrDescriptionMark}\n\n{text}", ct);
            return $"La card {Id} non ha ancora una PR: descrizione salvata sulla card ({text.Length} caratteri), la metto nella PR quando lo smistatore la apre.";
        }
        var editor = Editor(pr.Host);
        var head = (await editor.GetDescriptionAsync(pr.Area, pr.Id, ct)).Split('\n')[0].Trim();
        if (!Regex.IsMatch(head, $@"^\[Card {Id}\]\(")) head = link;
        var description = $"{head}\n\n{text}";
        if (description.Length > PrTextLimit)
            throw new CardToolException($"la descrizione e di {description.Length} caratteri, compreso il link alla card: Azure DevOps ne ammette al massimo {PrTextLimit}. Accorciala");
        await editor.SetDescriptionAsync(pr.Area, pr.Id, description, ct);
        return $"Descrizione della PR {pr.Id} scritta ({description.Length} caratteri su {PrTextLimit}).";
    }

    private AreaMapping? AreaOf(Card c) => areas.FirstOrDefault(a => string.Equals(a.Area, c.Area, StringComparison.OrdinalIgnoreCase));
}
