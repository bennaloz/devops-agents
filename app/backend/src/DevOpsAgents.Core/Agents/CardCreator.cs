using System.Text.RegularExpressions;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;

namespace DevOpsAgents.Core.Agents;

/// <summary>Cosa creare: i parametri di card.ps1 crea. Text e il markdown con le sezioni Descrizione, Criteri di accettazione, Recinto, Riferimenti.</summary>
public sealed record CreateRequest(string Type, string Title, string Area, string Text, IReadOnlyList<int>? After = null, bool NoTest = false, bool HumanTest = false,
    bool Bug = false, bool Group = false, int? Feature = null);

/// <summary>Il risultato: la card (o la Feature) e, per una funzionalita D52, la sua card di chiusura.</summary>
public sealed record Created(int Id, int? ClosingId, string Message);

/// <summary>
/// card.ps1 crea (New-Card in src/Card.psm1): una User Story o una Bug figlia di una Feature (D60), oppure una Feature con la sua card di chiusura
/// (D52) o che soltanto raggruppa (-Raggruppa). Stessi controlli e stessi messaggi. La card nasce assegnata a chi la crea e senza tag; il tag
/// agenti (il via agli agenti) arriva solo dopo aver visto che e nata in bozza.
/// </summary>
public sealed class CardCreator(ICardCreator creator, ICardEditor board, StateNames names, IReadOnlyList<AreaMapping> areas, bool featuresEnabled = true)
{
    public static readonly string[] Sections = ["Descrizione", "Criteri di accettazione", "Recinto", "Riferimenti"];

    /// <summary>Le sezioni "## titolo" del markdown; errore se ne manca una delle quattro o e vuota.</summary>
    public static IReadOnlyDictionary<string, string> ParseSections(string text)
    {
        var sections = new Dictionary<string, List<string>>();
        List<string>? current = null;
        foreach (var line in Regex.Split(text, "\r?\n"))
        {
            var m = Regex.Match(line, @"^##\s+(.+?)\s*$");
            if (m.Success) { sections[m.Groups[1].Value] = current = []; continue; }
            current?.Add(line);
        }
        var result = new Dictionary<string, string>();
        foreach (var name in Sections)
        {
            if (!sections.TryGetValue(name, out var lines)) throw new CardToolException($"Manca la sezione '## {name}' nel file");
            var t = string.Join("\n", lines).Trim();
            if (t.Length == 0) throw new CardToolException($"La sezione '## {name}' e vuota");
            result[name] = t;
        }
        return result;
    }

    public async Task<Created> CreateAsync(CreateRequest r, bool inRoleSession = false, CancellationToken ct = default)
    {
        // un ruolo che crea card da solo aggirerebbe il via di una persona
        if (inRoleSession) throw new CardToolException("'crea' non e permesso dentro una sessione di ruolo");
        var isFeature = r.Type == "Feature";
        var child = r.Feature is not null;
        if ((isFeature || child) && !featuresEnabled)
            throw new CardToolException("D52 non è ancora attiva: nessuna Feature si crea e nessuna card si lega a una Feature (funzionalitaAttive in config/limiti.json)");
        if (r.Type is not ("User Story" or "Bug" or "Feature")) throw new CardToolException($"Tipo non valido: '{r.Type}' (User Story | Bug | Feature)");
        if (r.Bug && !isFeature) throw new CardToolException("-Bug vale solo con -Tipo Feature: segna la funzionalita come correzione");
        if (r.Group && !isFeature) throw new CardToolException("-Raggruppa vale solo con -Tipo Feature");
        if (r.Group && r.Bug) throw new CardToolException("-Raggruppa e -Bug non vanno insieme: -Bug riguarda il ramo della funzionalita, che una Feature che raggruppa non ha");
        if (child && r.Feature <= 0) throw new CardToolException($"-Feature vuole l'id di una Feature: '{r.Feature}'");
        if (isFeature)
        {
            if (child) throw new CardToolException("una Feature non ha una Feature padre: -Feature non vale con -Tipo Feature");
            foreach (var (set, name) in new[] { (r.After is { Count: > 0 }, "Dopo"), (r.NoTest, "SenzaTest"), (r.HumanTest, "ProvaUmana") })
                if (set) throw new CardToolException($"-{name} non vale con -Tipo Feature: la Feature non ha ne un ordine ne una prova sua");
        }
        var s = ParseSections(r.Text);
        if (!areas.Any(a => string.Equals(a.Area, r.Area, StringComparison.OrdinalIgnoreCase))) throw new CardToolException($"Area sconosciuta nella mappa: '{r.Area}'");
        // D60: ogni card sta in una funzionalita. Una card senza Feature lo smistatore non la fa partire da New
        if (!isFeature && !child)
            throw new CardToolException("ogni card sta in una Feature: serve -Feature <id>. Se la Feature non c'e, creala prima: -Tipo Feature -Raggruppa per raggruppare card che vanno in develop una per una, -Tipo Feature per una funzionalita D52 da provare intera");
        if (child) await AssertFeatureAcceptsAsync(r.Feature!.Value, r.Area, ct);

        var description = $"## Descrizione\n{s["Descrizione"]}\n\n## Recinto\n{s["Recinto"]}\n\n## Riferimenti\n{s["Riferimenti"]}";
        // assegnata a chi la crea: solo lo smistatore del suo utente la fa avanzare
        var me = await creator.GetCurrentUserAsync(ct);
        if (string.IsNullOrWhiteSpace(me.UniqueName))
            throw new CardToolException("Non trovo l'indirizzo dell'utente del PAT: la card nascerebbe senza assegnatario e nessuno smistatore la prenderebbe. Non la creo");
        var criteria = s["Criteri di accettazione"];

        if (isFeature)
        {
            // la Feature non la fa avanzare uno smistatore: niente tag agenti; il tag bug (con -Bug) c'e fin dalla nascita
            var tags = r.Bug && names.BugFeatureTag is { } bt ? new[] { bt } : [];
            var (fid, _) = await creator.CreateWorkItemAsync(new("Feature", r.Title, r.Area, description, null, tags, me.UniqueName!, [], null), ct);
            if (r.Group) return new(fid, null, $"Feature {fid} creata: {board.CardUrl(fid)}");
            // la card di chiusura: figlia della Feature, senza codice suo, con i criteri della funzionalita intera
            int? closing = null;
            try
            {
                var (cid, cstate) = await creator.CreateWorkItemAsync(new("User Story", $"Collaudo funzionalità: {r.Title}", r.Area, description, criteria, [], me.UniqueName!, [], fid), ct);
                closing = cid;
                await TagBornAsync(cid, cstate, [names.AgentsTag, names.ClosingTag ?? throw new CardToolException("stati.json non ha tagChiusura")], ct);
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                var what = closing is { } c ? $"la card di chiusura {c} e nata ma non e a posto" : "la sua card di chiusura no";
                throw new CardToolException($"La Feature {fid} e nata ma {what}: {e.Message}. Non creare un'altra Feature: la card di chiusura va completata a mano (figlia della Feature {fid}, tag {names.AgentsTag} e {names.ClosingTag})");
            }
            return new(fid, closing, $"Feature {fid} creata: {board.CardUrl(fid)}. Card di chiusura {closing}: {board.CardUrl(closing!.Value)}");
        }

        var (id, state) = await creator.CreateWorkItemAsync(new(r.Type, r.Title, r.Area, description, criteria, [], me.UniqueName!, r.After ?? [], r.Feature), ct);
        var t = new List<string> { names.AgentsTag };
        if (r.NoTest) t.Add(names.NoTestTag ?? throw new CardToolException("stati.json non ha tagSenzaTest"));
        if (r.HumanTest) t.Add(names.HumanTestTag ?? throw new CardToolException("stati.json non ha tagProvaUmana"));
        await TagBornAsync(id, state, t, ct);
        return new(id, null, $"Card {id} creata: {board.CardUrl(id)}");
    }

    /// <summary>Il via agli agenti solo a una card nata in bozza: in un altro stato non la si tocca, e lo si dice.</summary>
    private async Task TagBornAsync(int id, string state, IReadOnlyList<string> tags, CancellationToken ct)
    {
        if (!string.Equals(state, names[StateKeys.Draft], StringComparison.OrdinalIgnoreCase))
            throw new CardToolException($"La card {id} e nata nello stato '{state}' invece di '{names[StateKeys.Draft]}': non la sposto e non le do il tag {names.AgentsTag}, controllare a mano");
        await creator.TagNewAsync(id, tags, null, ct);
    }

    /// <summary>
    /// La Feature a cui si aggiunge una card (Assert-FeatureAccetta): una Feature, non rimossa, non gia in develop (Resolved o Closed); con la
    /// card di chiusura (D52) sta in un'area sola, senza (D60, raggruppa) le sue card possono stare in aree diverse.
    /// </summary>
    private async Task AssertFeatureAcceptsAsync(int featureId, string area, CancellationToken ct)
    {
        var f = await board.GetWorkItemAsync(featureId, ct);
        if (f.Type != "Feature") throw new CardToolException($"il work item {featureId} non e una Feature (e: {f.Type})");
        if (string.Equals(f.State, names.Get("featureRimossa"), StringComparison.OrdinalIgnoreCase))
            throw new CardToolException($"la Feature {featureId} e {f.State}: non si aggiungono card a una Feature rimossa");
        if (string.Equals(f.State, names.Get("featureRisolta"), StringComparison.OrdinalIgnoreCase) || string.Equals(f.State, names.Get("featureChiusa"), StringComparison.OrdinalIgnoreCase))
            throw new CardToolException($"la Feature {featureId} e {f.State}: la funzionalita e gia in develop, il lavoro nuovo va in una Feature nuova");
        var children = (await board.GetFeatureChildrenAsync(featureId, ct)).Where(c => names.KeyOf(c.State) != StateKeys.Removed);
        var d52 = children.Any(c => names.ClosingTag is { } t && c.Tags.Contains(t, StringComparer.Ordinal));
        if (d52 && !string.Equals(f.Area, area, StringComparison.OrdinalIgnoreCase))
            throw new CardToolException($"l'area '{area}' e diversa da quella della Feature {featureId} ('{f.Area}'): una funzionalita con la card di chiusura sta in un'area sola");
    }
}
