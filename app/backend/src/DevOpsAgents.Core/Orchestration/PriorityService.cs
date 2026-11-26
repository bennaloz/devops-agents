using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;

namespace DevOpsAgents.Core.Orchestration;

/// <summary>
/// D60 dalla dashboard: l'ordine delle Feature, la pausa di una Feature (il tag paused) e la pausa del sistema. Scrive solo cio
/// che serve: il rank delle Feature che cambiano, il tag, impostazioni.json.
/// </summary>
public sealed class PriorityService(IBoard board, ISettingsStore settings, StateNames names, IReadOnlyList<AreaMapping> areas)
{
    private Task<IReadOnlyList<FeatureInfo>> OpenAsync(CancellationToken ct) => board.GetOpenFeaturesAsync(areas.Select(a => a.Area).ToList(), ct);

    public async Task<IReadOnlyList<FeatureReport>> GetFeaturesAsync(CancellationToken ct = default) =>
        FeaturePriority.Order(await OpenAsync(ct)).Select(f => new FeatureReport(f.Id, f.Title, f.State, f.Rank, f.HasTag(names.PausedTag), f.Area)).ToList();

    /// <summary>Mette la Feature subito dopo <paramref name="after"/> (0 = in cima); restituisce le Feature scritte.</summary>
    public async Task<IReadOnlyList<int>> MoveAsync(int id, int after, CancellationToken ct = default)
    {
        var writes = FeaturePriority.Rerank(await OpenAsync(ct), id, after);
        foreach (var (fid, rank) in writes) await board.SetRankAsync(fid, rank, ct);
        return writes.Select(w => w.Id).ToList();
    }

    public async Task SetFeaturePausedAsync(int id, bool paused, CancellationToken ct = default)
    {
        var tag = names.PausedTag ?? throw new InvalidOperationException("stati.json: manca 'tagPausa'");
        var feature = (await OpenAsync(ct)).FirstOrDefault(f => f.Id == id) ?? throw new ArgumentException($"la Feature {id} non e fra quelle aperte");
        if (paused == feature.HasTag(tag)) return;
        if (paused) await board.AddTagAsync(id, tag, ct); else await board.RemoveTagAsync(id, tag, ct);
    }

    public async Task SetSystemPausedAsync(bool paused, CancellationToken ct = default) =>
        await settings.SaveAsync((await settings.LoadAsync(ct)) with { Paused = paused }, ct);

    public async Task<bool> IsSystemPausedAsync(CancellationToken ct = default) => (await settings.LoadAsync(ct)).Paused;
}
