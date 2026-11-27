using DevOpsAgents.Core.Model;

namespace DevOpsAgents.Core.Ports;

/// <summary>Una card letta per intero: i campi lunghi (descrizione o passi di una Bug, criteri) oltre a quelli del giro.</summary>
public sealed record CardDetail(Card Card, string? Description, string? Criteria);

/// <summary>Un task figlio della card, con il suo testo.</summary>
public sealed record TaskDetail(int Id, string Title, string State, string? Description);

/// <summary>Un work item qualunque (il padre di una card: la Feature, o altro), con i figli.</summary>
public sealed record WorkItemInfo(int Id, string Type, string State, string Title, string? Area, IReadOnlyList<int> ChildIds);

/// <summary>
/// Quello che gli strumenti degli agenti (card.ps1, il server MCP) leggono e scrivono sulla board: una card sola, quella della sessione.
/// Le operazioni che servono anche al giro hanno lo stesso nome di <see cref="IBoard"/>: la board di Azure DevOps le implementa una volta.
/// </summary>
public interface ICardEditor
{
    Task<CardDetail> GetCardAsync(int cardId, CancellationToken ct = default);
    Task<IReadOnlyList<Comment>> GetCommentsAsync(int cardId, CancellationToken ct = default);
    /// <summary>I task figli, in ordine di id (l'ordine di esecuzione).</summary>
    Task<IReadOnlyList<TaskDetail>> GetTaskDetailsAsync(int cardId, CancellationToken ct = default);
    Task<WorkItemInfo> GetWorkItemAsync(int id, CancellationToken ct = default);
    Task<IReadOnlyList<Card>> GetFeatureChildrenAsync(int featureId, CancellationToken ct = default);
    Task<int?> GetLinkedPullRequestIdAsync(int cardId, CancellationToken ct = default);
    Task AddCommentAsync(int cardId, string markdown, CancellationToken ct = default);
    Task AddTagAsync(int cardId, string tag, CancellationToken ct = default);
    /// <summary>Sposta la card e restituisce la revisione scritta (lo smistatore la riconosce come nostra).</summary>
    Task<int> MoveAsync(int cardId, string stateName, CancellationToken ct = default);
    /// <summary>I criteri di accettazione, in markdown.</summary>
    Task SetCriteriaAsync(int cardId, string markdown, CancellationToken ct = default);
    /// <summary>Un Task figlio della card, nella stessa area, con il testo in markdown.</summary>
    Task<TaskDetail> CreateTaskAsync(int cardId, string title, string description, string area, CancellationToken ct = default);
    Task SetTaskStateAsync(int taskId, string stateName, CancellationToken ct = default);
    string CardUrl(int cardId);
}

/// <summary>Titolo e descrizione di una PR: Azure Repos e GitHub. La firma in fondo alla descrizione la mette chi implementa.</summary>
public interface IPullRequestEditor
{
    Task<string> GetDescriptionAsync(AreaMapping area, int prId, CancellationToken ct = default);
    Task SetDescriptionAsync(AreaMapping area, int prId, string description, CancellationToken ct = default);
    Task SetTitleAsync(AreaMapping area, int prId, string title, CancellationToken ct = default);
    /// <summary>Le PR dal ramo verso la destinazione, di ogni stato, dalla piu recente: numero, stato (active, completed, abandoned), commit di testa.</summary>
    Task<IReadOnlyList<(int Id, string Status, string? HeadCommit)>> ListPullRequestsAsync(AreaMapping area, string branch, string destination, CancellationToken ct = default);
}

/// <summary>D43: i parametri del deploy in Test che il responsabile puo scegliere: i booleani deploy* dello YAML della pipeline, sul ramo.</summary>
public interface IDeployParameters
{
    Task<IReadOnlyList<string>> GetAsync(AreaMapping area, string branch, CancellationToken ct = default);
}

/// <summary>
/// D46: la memoria dei ruoli scritta dal mentore (leggi, scrivi, rivedi, togli, conflitto). Il testo arriva gia strutturato; chi implementa
/// fa worktree, commit, push e PR della memoria.
/// </summary>
public interface IMemoryWriter
{
    Task<string> ReadAsync(string role, string repo, CancellationToken ct = default);
    Task<string> WriteAsync(string role, string where, LessonFields lesson, CancellationToken ct = default);
    Task<string> ReviseAsync(string id, LessonFields lesson, CancellationToken ct = default);
    Task<string> RemoveAsync(string id, CancellationToken ct = default);
    Task<string> ConflictAsync(int cardId, string text, CancellationToken ct = default);
}

/// <summary>Una lezione del mentore: i quattro campi di memoria.ps1 scrivi.</summary>
public sealed record LessonFields(string Situation, string WhatToDo, string Why, string Card);

/// <summary>Un work item da creare: la descrizione in markdown (nei passi di riproduzione per una Bug), i criteri (non per una Feature), i link.</summary>
public sealed record NewWorkItem(string Type, string Title, string Area, string Description, string? Criteria, IReadOnlyList<string> Tags, string AssignedTo,
    IReadOnlyList<int> Predecessors, int? ParentId);

/// <summary>La creazione di card e Feature (card.ps1 crea): fuori dai ruoli, la usa una persona o la sessione di design.</summary>
public interface ICardCreator
{
    /// <summary>Crea il work item senza toccarne lo stato (lo decide la board): restituisce id e stato in cui e nato.</summary>
    Task<(int Id, string State)> CreateWorkItemAsync(NewWorkItem item, CancellationToken ct = default);
    /// <summary>Tag ed eventualmente stato, in una scrittura: il via agli agenti a una card appena nata.</summary>
    Task TagNewAsync(int id, IReadOnlyList<string> tags, string? stateName, CancellationToken ct = default);
    Task<Person> GetCurrentUserAsync(CancellationToken ct = default);
}
