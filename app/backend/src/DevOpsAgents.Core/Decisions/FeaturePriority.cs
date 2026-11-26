using DevOpsAgents.Core.Model;

namespace DevOpsAgents.Core.Decisions;

/// <summary>
/// D60: l'ordine delle Feature e quindi delle card. La priorita e l'ordine del backlog (StackRank): le Feature con un rank prima,
/// per rank; quelle mai ordinate dopo, per id. Dentro la stessa Feature le card vanno per id; le card senza Feature in fondo.
/// Come Get-OrdineFeature, Get-OrdineCard e Get-RankRiordino di src/Decisioni.psm1.
/// </summary>
public static class FeaturePriority
{
    public static IReadOnlyList<FeatureInfo> Order(IEnumerable<FeatureInfo> features) =>
        features.OrderBy(f => f.Rank is null).ThenBy(f => f.Rank ?? 0).ThenBy(f => f.Id).ToList();

    public static IReadOnlyList<Card> OrderCards(IEnumerable<Card> cards, IEnumerable<FeatureInfo> features)
    {
        var position = Order(features).Select((f, i) => (f.Id, i)).ToDictionary(x => x.Id, x => x.i);
        return cards.OrderBy(c => c.ParentId is { } p && position.TryGetValue(p, out var i) ? i : int.MaxValue).ThenBy(c => c.Id).ToList();
    }

    /// <summary>
    /// I rank da scrivere per mettere la Feature <paramref name="id"/> subito dopo <paramref name="after"/> (0 = in cima).
    /// Se tutte hanno un rank si scrive solo quella spostata, a meta fra le vicine; altrimenti si rinumera 1000, 2000, ... e si
    /// scrivono solo quelle che cambiano.
    /// </summary>
    public static IReadOnlyList<(int Id, double Rank)> Rerank(IEnumerable<FeatureInfo> features, int id, int after)
    {
        var order = Order(features).ToList();
        var moved = order.FirstOrDefault(f => f.Id == id) ?? throw new ArgumentException($"la Feature {id} non e fra quelle aperte");
        if (after == id) throw new ArgumentException("una Feature non va dopo se stessa");
        order.Remove(moved);
        var index = 0;
        if (after != 0)
        {
            var before = order.FindLastIndex(f => f.Id == after);
            if (before < 0) throw new ArgumentException($"la Feature {after} non e fra quelle aperte");
            index = before + 1;
        }
        order.Insert(index, moved);

        if (order.All(f => f.Rank is not null))
        {
            double? prev = index > 0 ? order[index - 1].Rank : null;
            double? next = index < order.Count - 1 ? order[index + 1].Rank : null;
            var rank = (prev, next) switch
            {
                (null, null) => moved.Rank!.Value,
                (null, { } n) => n - 1000,
                ({ } p, null) => p + 1000,
                ({ } p, { } n) => (p + n) / 2,
            };
            if ((prev is null || rank > prev) && (next is null || rank < next))
                return rank == moved.Rank ? [] : [(moved.Id, rank)];
        }
        var writes = new List<(int, double)>();
        for (var j = 0; j < order.Count; j++)
        {
            var r = (j + 1) * 1000.0;
            if (order[j].Rank != r) writes.Add((order[j].Id, r));
        }
        return writes;
    }
}
