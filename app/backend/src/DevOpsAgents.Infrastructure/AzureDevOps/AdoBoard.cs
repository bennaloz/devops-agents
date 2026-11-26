using System.Text.Json.Nodes;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;
using static DevOpsAgents.Infrastructure.AzureDevOps.AdoClient;

namespace DevOpsAgents.Infrastructure.AzureDevOps;

/// <summary>La board su Azure DevOps Boards: le stesse chiamate di src/Ado.psm1.</summary>
public sealed class AdoBoard(AdoClient ado, string boardProject, StateNames names) : IBoard
{
    private const string ChildLink = "System.LinkTypes.Hierarchy-Forward";
    private const string ParentLink = "System.LinkTypes.Hierarchy-Reverse";
    private const string PredecessorLink = "System.LinkTypes.Dependency-Reverse";

    public async Task<IReadOnlyList<Card>> GetActiveCardsAsync(CancellationToken ct = default)
    {
        var q = $"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '{boardProject}' " +
                $"AND [System.WorkItemType] IN ('User Story', 'Bug') AND [System.Tags] CONTAINS '{names.AgentsTag}' " +
                $"AND [System.State] <> '{names[StateKeys.Draft]}' AND [System.State] <> '{names[StateKeys.Closed]}' ORDER BY [System.Id]";
        var r = await ado.SendAsync(HttpMethod.Post, $"/{E(boardProject)}/_apis/wit/wiql?api-version=7.1", new { query = q }, ct: ct);
        var ids = r.Items("workItems").Select(w => w.Int("id")!.Value).ToList();
        var cards = new List<Card>();
        foreach (var chunk in ids.Chunk(200))
        {
            var batch = await ado.GetAsync($"/_apis/wit/workitems?ids={string.Join(',', chunk)}&errorPolicy=Omit&api-version=7.1", ct);
            cards.AddRange(batch.Items("value").Select(ToCard).Where(c => !string.Equals(c.State, names[StateKeys.Removed], StringComparison.OrdinalIgnoreCase)));
        }
        return cards.OrderBy(c => c.Id).ToList();
    }

    public static Card ToCard(JsonNode wi)
    {
        var f = wi["fields"];
        return new Card(
            wi.Int("id")!.Value, wi.Int("rev") ?? 0, f.Str("System.Title") ?? "", f.Str("System.State") ?? "",
            (f.Str("System.Tags") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries),
            f.Str("System.AreaPath"), ToPerson(f?["System.AssignedTo"]), ToPerson(f?["System.CreatedBy"]), f.Str("System.WorkItemType"));
    }

    private static Person? ToPerson(JsonNode? u) => u is null ? null : new Person(u.Str("id") ?? "", u.Str("displayName") ?? "", u.Str("uniqueName"));

    public async Task<IReadOnlyList<Comment>> GetCommentsAsync(int cardId, CancellationToken ct = default)
    {
        var all = new List<Comment>();
        var baseUrl = $"/{E(boardProject)}/_apis/wit/workItems/{cardId}/comments";
        var url = $"{baseUrl}?order=asc&api-version=7.1-preview.4";
        var seen = new HashSet<string>();
        while (true)
        {
            var r = await ado.GetAsync(url, ct);
            all.AddRange(r.Items("comments").Select(c => new Comment(c.Int("id")!.Value, c.Str("createdBy", "displayName") ?? "", c.Str("text") ?? "", c.Date("createdDate") ?? default)));
            var token = r.Str("continuationToken");
            if (string.IsNullOrEmpty(token) || !seen.Add(token)) break;
            url = $"{baseUrl}?order=asc&continuationToken={E(token)}&api-version=7.1-preview.4";
        }
        return all;
    }

    public async Task<IReadOnlyList<StateChange>> GetStateHistoryAsync(int cardId, CancellationToken ct = default)
    {
        var changes = new List<StateChange>();
        string? previous = null;
        for (var skip = 0; ; skip += 200)
        {
            var r = await ado.GetAsync($"/_apis/wit/workitems/{cardId}/revisions?$top=200&$skip={skip}&api-version=7.1", ct);
            var page = r.Items("value").ToList();
            foreach (var rev in page)
            {
                var f = rev["fields"];
                var state = f.Str("System.State");
                if (state != previous)
                    changes.Add(new StateChange(rev.Int("rev")!.Value, previous, state ?? "", f.Date("System.ChangedDate") ?? default, f.Str("System.ChangedBy", "id"), f.Str("System.ChangedBy", "displayName")));
                previous = state;
            }
            if (page.Count < 200) break;
        }
        return changes;
    }

    private async Task<List<JsonNode>> RelatedAsync(int cardId, string rel, CancellationToken ct)
    {
        var wi = await ado.GetAsync($"/_apis/wit/workitems/{cardId}?$expand=relations&api-version=7.1", ct);
        var ids = wi.Items("relations").Where(r => r.Str("rel") == rel)
            .Select(r => int.TryParse(r.Str("url")?.Split('/').Last(), out var id) ? id : 0).Where(id => id > 0).ToList();
        if (ids.Count == 0) return [];
        var batch = await ado.GetAsync($"/_apis/wit/workitems?ids={string.Join(',', ids)}&$expand=relations&errorPolicy=Omit&api-version=7.1", ct);
        return batch.Items("value").ToList();
    }

    public async Task<IReadOnlyList<WorkTask>> GetTasksAsync(int cardId, CancellationToken ct = default) =>
        (await RelatedAsync(cardId, ChildLink, ct)).Where(t => t["fields"].Str("System.WorkItemType") == "Task")
            .Select(t => new WorkTask(t.Int("id")!.Value, t["fields"].Str("System.Title") ?? "", t["fields"].Str("System.State") ?? "")).OrderBy(t => t.Id).ToList();

    public async Task<IReadOnlyList<Predecessor>> GetPredecessorsAsync(int cardId, CancellationToken ct = default) =>
        (await RelatedAsync(cardId, PredecessorLink, ct)).Select(p => new Predecessor(p.Int("id")!.Value, p["fields"].Str("System.State") ?? "",
            p.Items("relations").Where(r => r.Str("rel") == ParentLink).Select(r => int.TryParse(r.Str("url")?.Split('/').Last(), out var id) ? id : (int?)null).FirstOrDefault()))
            .OrderBy(p => p.Id).ToList();

    private Task PatchAsync(int cardId, JsonArray ops, CancellationToken ct) =>
        ado.SendAsync(HttpMethod.Patch, $"/_apis/wit/workitems/{cardId}?api-version=7.1", ops, "application/json-patch+json", ct);

    public Task SetStateAsync(int cardId, string stateName, CancellationToken ct = default) =>
        PatchAsync(cardId, [new JsonObject { ["op"] = "add", ["path"] = "/fields/System.State", ["value"] = stateName }], ct);

    public async Task AddTagAsync(int cardId, string tag, CancellationToken ct = default)
    {
        // il test sulla revisione evita di perdere un tag scritto da una persona nel frattempo
        var wi = await ado.GetAsync($"/_apis/wit/workitems/{cardId}?api-version=7.1", ct);
        var card = ToCard(wi!);
        if (card.Tags.Contains(tag, StringComparer.OrdinalIgnoreCase)) return;
        await PatchAsync(cardId, [
            new JsonObject { ["op"] = "test", ["path"] = "/rev", ["value"] = card.Rev },
            new JsonObject { ["op"] = "replace", ["path"] = "/fields/System.Tags", ["value"] = string.Join("; ", card.Tags.Append(tag)) },
        ], ct);
    }

    public Task AddCommentAsync(int cardId, string markdown, CancellationToken ct = default) =>
        ado.SendAsync(HttpMethod.Post, $"/{E(boardProject)}/_apis/wit/workItems/{cardId}/comments?format=markdown&api-version=7.1-preview.4", new { text = markdown }, ct: ct);

    public async Task AddLinkAsync(int cardId, string url, string? comment = null, CancellationToken ct = default)
    {
        var wi = await ado.GetAsync($"/_apis/wit/workitems/{cardId}?$expand=relations&api-version=7.1", ct);
        if (wi.Items("relations").Any(r => r.Str("rel") == "Hyperlink" && r.Str("url") == url)) return;
        var value = new JsonObject { ["rel"] = "Hyperlink", ["url"] = url };
        if (comment is not null) value["attributes"] = new JsonObject { ["comment"] = comment };
        await PatchAsync(cardId, [new JsonObject { ["op"] = "add", ["path"] = "/relations/-", ["value"] = value }], ct);
    }

    public async Task<Person> GetCurrentUserAsync(CancellationToken ct = default)
    {
        var r = await ado.GetAsync("/_apis/connectionData?api-version=7.1-preview", ct);
        var u = r?["authenticatedUser"];
        return new Person(u.Str("id") ?? "", u.Str("providerDisplayName") ?? "");
    }

    public string CardUrl(int cardId) => $"{ado.Organization}/{E(boardProject)}/_workitems/edit/{cardId}";
}
