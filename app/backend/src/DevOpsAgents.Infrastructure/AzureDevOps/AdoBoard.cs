using System.Text.Json.Nodes;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;
using static DevOpsAgents.Infrastructure.AzureDevOps.AdoClient;

namespace DevOpsAgents.Infrastructure.AzureDevOps;

/// <summary>La board su Azure DevOps Boards: le stesse chiamate di src/Ado.psm1.</summary>
public sealed class AdoBoard(AdoClient ado, string boardProject, StateNames names) : IBoard, ICardEditor
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
            var batch = await ado.GetAsync($"/_apis/wit/workitems?ids={string.Join(',', chunk)}&$expand=relations&errorPolicy=Omit&api-version=7.1", ct);
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
            f.Str("System.AreaPath"), ToPerson(f?["System.AssignedTo"]), ToPerson(f?["System.CreatedBy"]), f.Str("System.WorkItemType"), ParentOf(wi));
    }

    /// <summary>Il padre dalla relazione Hierarchy-Reverse, o dal campo System.Parent se la lettura non porta le relazioni.</summary>
    private static int? ParentOf(JsonNode wi) =>
        wi.Items("relations").Where(r => r.Str("rel") == ParentLink).Select(r => int.TryParse(r.Str("url")?.Split('/').Last(), out var id) ? id : (int?)null).FirstOrDefault()
        ?? wi["fields"].Int("System.Parent");

    public const string RankField = "Microsoft.VSTS.Common.StackRank";

    /// <summary>La PR collegata alla card: il link di una PR di Azure Repos (ArtifactLink), o il link a una PR di GitHub; la piu recente.</summary>
    public async Task<int?> GetLinkedPullRequestIdAsync(int cardId, CancellationToken ct = default)
    {
        var wi = await ado.GetAsync($"/_apis/wit/workitems/{cardId}?$expand=relations&api-version=7.1", ct);
        var ids = wi.Items("relations").Select(r =>
        {
            var url = r.Str("url") ?? "";
            var m = r.Str("rel") == "ArtifactLink" ? System.Text.RegularExpressions.Regex.Match(url, @"^vstfs:///Git/PullRequestId/.*%2[fF](\d+)$")
                : r.Str("rel") == "Hyperlink" ? System.Text.RegularExpressions.Regex.Match(url, @"^https://github\.com/[\w.-]+/[\w.-]+/pull/(\d+)/?$") : null;
            return m is { Success: true } ? int.Parse(m.Groups[1].Value) : (int?)null;
        }).Where(x => x is not null).Select(x => x!.Value).ToList();
        return ids.Count == 0 ? null : ids.Max();
    }

    public async Task<IReadOnlyList<Card>> GetFeatureChildrenAsync(int featureId, CancellationToken ct = default) =>
        (await RelatedAsync(featureId, ChildLink, ct)).Select(ToCard).OrderBy(c => c.Id).ToList();

    /// <summary>
    /// Come New-AdoCard: la Bug nasce con titolo, area, descrizione (ReproSteps, markdown), criteri, assegnatario e padre; poi tag e stato in
    /// una seconda scrittura (Set-TagCardNata). Se la seconda fallisce la Bug c'e gia: l'errore lo dice, per non ricrearla.
    /// </summary>
    public async Task<int> CreateBugAsync(NewBug bug, CancellationToken ct = default)
    {
        var project = bug.Area.Split('\\')[0];
        JsonArray ops =
        [
            new JsonObject { ["op"] = "add", ["path"] = "/fields/System.Title", ["value"] = bug.Title },
            new JsonObject { ["op"] = "add", ["path"] = "/fields/System.AreaPath", ["value"] = bug.Area },
            new JsonObject { ["op"] = "add", ["path"] = "/multilineFieldsFormat/Microsoft.VSTS.TCM.ReproSteps", ["value"] = "Markdown" },
            new JsonObject { ["op"] = "add", ["path"] = "/fields/Microsoft.VSTS.TCM.ReproSteps", ["value"] = bug.Description },
            new JsonObject { ["op"] = "add", ["path"] = "/fields/System.AssignedTo", ["value"] = bug.AssignedTo },
            new JsonObject { ["op"] = "add", ["path"] = "/relations/-", ["value"] = new JsonObject { ["rel"] = ParentLink, ["url"] = $"{ado.Organization}/_apis/wit/workItems/{bug.ParentId}" } },
        ];
        if (bug.Criteria is { Length: > 0 } criteria)
        {
            ops.Add(new JsonObject { ["op"] = "add", ["path"] = "/multilineFieldsFormat/Microsoft.VSTS.Common.AcceptanceCriteria", ["value"] = "Markdown" });
            ops.Add(new JsonObject { ["op"] = "add", ["path"] = "/fields/Microsoft.VSTS.Common.AcceptanceCriteria", ["value"] = criteria });
        }
        var created = await ado.SendAsync(HttpMethod.Post, $"/{E(project)}/_apis/wit/workitems/$Bug?api-version=7.1", ops, "application/json-patch+json", ct);
        var id = created.Int("id")!.Value;
        try
        {
            JsonArray then = [new JsonObject { ["op"] = "add", ["path"] = "/fields/System.Tags", ["value"] = string.Join("; ", bug.Tags) }];
            if (bug.InitialState is { } k) then.Add(new JsonObject { ["op"] = "add", ["path"] = "/fields/System.State", ["value"] = names[k] });
            await PatchAsync(id, then, ct);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            throw new InvalidOperationException($"La Bug {id} e nata ma non e a posto: {e.Message}. Non ricrearla: completarla a mano (tag {string.Join(" e ", bug.Tags)}, stato {(bug.InitialState is { } s ? names[s] : names[StateKeys.Draft])})", e);
        }
        return id;
    }

    public async Task<IReadOnlyList<FeatureInfo>> GetOpenFeaturesAsync(IReadOnlyList<string> areas, CancellationToken ct = default)
    {
        if (areas.Count == 0) return [];
        var under = string.Join(" OR ", areas.Select(a => $"[System.AreaPath] UNDER '{a.Replace("'", "''")}'"));
        var q = $"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '{boardProject}' AND [System.WorkItemType] = 'Feature' " +
                $"AND [System.State] <> '{names["featureChiusa"]}' AND [System.State] <> '{names["featureRimossa"]}' AND ({under}) ORDER BY [System.Id]";
        var r = await ado.SendAsync(HttpMethod.Post, $"/{E(boardProject)}/_apis/wit/wiql?api-version=7.1", new { query = q }, ct: ct);
        var ids = r.Items("workItems").Select(w => w.Int("id")!.Value).ToList();
        var features = new List<FeatureInfo>();
        foreach (var chunk in ids.Chunk(200))
        {
            var batch = await ado.GetAsync($"/_apis/wit/workitems?ids={string.Join(',', chunk)}&errorPolicy=Omit&api-version=7.1", ct);
            foreach (var w in batch.Items("value"))
            {
                var f = w["fields"];
                var rank = f?[RankField] is System.Text.Json.Nodes.JsonValue v && v.TryGetValue<double>(out var d) ? d : (double?)null;
                features.Add(new FeatureInfo(w.Int("id")!.Value, f.Str("System.Title") ?? "", f.Str("System.State") ?? "",
                    (f.Str("System.Tags") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries), f.Str("System.AreaPath"), rank));
            }
        }
        return features;
    }

    public Task SetRankAsync(int workItemId, double rank, CancellationToken ct = default) =>
        PatchAsync(workItemId, [new JsonObject { ["op"] = "add", ["path"] = $"/fields/{RankField}", ["value"] = rank }], ct);

    public async Task RemoveTagAsync(int cardId, string tag, CancellationToken ct = default)
    {
        var wi = await ado.GetAsync($"/_apis/wit/workitems/{cardId}?api-version=7.1", ct);
        var card = ToCard(wi!);
        var rest = card.Tags.Where(t => !string.Equals(t, tag, StringComparison.OrdinalIgnoreCase)).ToList();
        if (rest.Count == card.Tags.Count) return;
        JsonArray ops = [new JsonObject { ["op"] = "test", ["path"] = "/rev", ["value"] = card.Rev }];
        ops.Add(rest.Count > 0
            ? new JsonObject { ["op"] = "replace", ["path"] = "/fields/System.Tags", ["value"] = string.Join("; ", rest) }
            : new JsonObject { ["op"] = "remove", ["path"] = "/fields/System.Tags" });
        await PatchAsync(cardId, ops, ct);
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
        // l'indirizzo (properties.Account) serve ad assegnare le Bug che crea lo smistatore
        return new Person(u.Str("id") ?? "", u.Str("providerDisplayName") ?? "", u?["properties"]?["Account"]?["$value"]?.ToString());
    }

    // ---- ICardEditor: gli strumenti degli agenti sulla loro card (card.ps1, il server MCP) ----------------------------------

    private const string CriteriaField = "Microsoft.VSTS.Common.AcceptanceCriteria";
    private static string DescriptionField(string? type) => type == "Bug" ? "Microsoft.VSTS.TCM.ReproSteps" : "System.Description";

    public async Task<CardDetail> GetCardAsync(int cardId, CancellationToken ct = default)
    {
        var wi = await ado.GetAsync($"/_apis/wit/workitems/{cardId}?$expand=relations&api-version=7.1", ct);
        var card = ToCard(wi!);
        return new CardDetail(card, wi!["fields"].Str(DescriptionField(card.WorkItemType)), wi["fields"].Str(CriteriaField));
    }

    public async Task<IReadOnlyList<TaskDetail>> GetTaskDetailsAsync(int cardId, CancellationToken ct = default) =>
        (await RelatedAsync(cardId, ChildLink, ct)).Where(t => t["fields"].Str("System.WorkItemType") == "Task")
            .Select(t => new TaskDetail(t.Int("id")!.Value, t["fields"].Str("System.Title") ?? "", t["fields"].Str("System.State") ?? "", t["fields"].Str("System.Description")))
            .OrderBy(t => t.Id).ToList();

    public async Task<WorkItemInfo> GetWorkItemAsync(int id, CancellationToken ct = default)
    {
        var wi = await ado.GetAsync($"/_apis/wit/workitems/{id}?$expand=relations&api-version=7.1", ct);
        var f = wi?["fields"];
        var children = wi.Items("relations").Where(r => r.Str("rel") == ChildLink)
            .Select(r => int.TryParse(r.Str("url")?.Split('/').Last(), out var c) ? c : 0).Where(c => c > 0).OrderBy(c => c).ToList();
        return new WorkItemInfo(wi.Int("id") ?? id, f.Str("System.WorkItemType") ?? "", f.Str("System.State") ?? "", f.Str("System.Title") ?? "", f.Str("System.AreaPath"), children);
    }

    public async Task<int> MoveAsync(int cardId, string stateName, CancellationToken ct = default)
    {
        var r = await ado.SendAsync(HttpMethod.Patch, $"/_apis/wit/workitems/{cardId}?api-version=7.1",
            new JsonArray(new JsonObject { ["op"] = "add", ["path"] = "/fields/System.State", ["value"] = stateName }), "application/json-patch+json", ct);
        return r.Int("rev") ?? 0;
    }

    /// <summary>In markdown: in html un testo con a capo ed elenchi diventa una riga sola (il formato vale se il campo cambia nella stessa patch).</summary>
    public Task SetCriteriaAsync(int cardId, string markdown, CancellationToken ct = default) =>
        PatchAsync(cardId, [
            new JsonObject { ["op"] = "add", ["path"] = $"/multilineFieldsFormat/{CriteriaField}", ["value"] = "Markdown" },
            new JsonObject { ["op"] = "add", ["path"] = $"/fields/{CriteriaField}", ["value"] = markdown },
        ], ct);

    public async Task<TaskDetail> CreateTaskAsync(int cardId, string title, string description, string area, CancellationToken ct = default)
    {
        var project = area.Split('\\')[0];
        JsonArray ops =
        [
            new JsonObject { ["op"] = "add", ["path"] = "/fields/System.Title", ["value"] = title },
            new JsonObject { ["op"] = "add", ["path"] = "/fields/System.AreaPath", ["value"] = area },
            new JsonObject { ["op"] = "add", ["path"] = "/multilineFieldsFormat/System.Description", ["value"] = "Markdown" },
            new JsonObject { ["op"] = "add", ["path"] = "/fields/System.Description", ["value"] = description },
            new JsonObject { ["op"] = "add", ["path"] = "/relations/-", ["value"] = new JsonObject { ["rel"] = ParentLink, ["url"] = $"{ado.Organization}/_apis/wit/workItems/{cardId}" } },
        ];
        var t = await ado.SendAsync(HttpMethod.Post, $"/{E(project)}/_apis/wit/workitems/$Task?api-version=7.1", ops, "application/json-patch+json", ct);
        return new TaskDetail(t.Int("id")!.Value, t?["fields"].Str("System.Title") ?? title, t?["fields"].Str("System.State") ?? "", description);
    }

    public Task SetTaskStateAsync(int taskId, string stateName, CancellationToken ct = default) => SetStateAsync(taskId, stateName, ct);

    public string CardUrl(int cardId) => $"{ado.Organization}/{E(boardProject)}/_workitems/edit/{cardId}";
}
