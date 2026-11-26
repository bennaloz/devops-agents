namespace DevOpsAgents.Core.Decisions;

/// <summary>Un'azione che il motore decide e lo smistatore esegue. I nomi corrispondono a quelli di Decisioni.psm1.</summary>
public abstract record AgentAction
{
    /// <summary>Il nome dell'azione nell'originale PowerShell (LanciaSessione, SpostaCard, ...): serve al confronto in parallelo.</summary>
    public abstract string Kind { get; }
}

/// <summary>LanciaSessione: una sessione claude -p del ruolo, con il motivo e l'allegato.</summary>
public sealed record LaunchSession(string Role, string Reason, string? Attachment = null, bool Resume = false, int? TaskId = null) : AgentAction
{
    public override string Kind => "LanciaSessione";
}

/// <summary>MettiInAttesa: tag on-hold, commento con la menzione, e come ripartire (For: sessione, limite, deploy).</summary>
public sealed record PutOnHold(string Reason, string? For, bool Direct = false, string? WaitKind = null) : AgentAction
{
    public override string Kind => "MettiInAttesa";
}

/// <summary>SpostaCard: avanti nel flusso, verso la chiave di stato data.</summary>
public sealed record MoveCard(string State) : AgentAction
{
    public override string Kind => "SpostaCard";
}

/// <summary>RiportaIndietro: la card torna a uno stato precedente, con un commento che dice perche.</summary>
public sealed record MoveBack(string State, string Reason) : AgentAction
{
    public override string Kind => "RiportaIndietro";
}

/// <summary>CreaWorktree: il ramo della card da origin/develop (o dalla base) in un worktree dedicato.</summary>
public sealed record CreateWorktree(string? Base = null) : AgentAction
{
    public override string Kind => "CreaWorktree";
}

public sealed record RemoveWorktree : AgentAction
{
    public override string Kind => "RimuoviWorktree";
}

public sealed record OpenPr : AgentAction
{
    public override string Kind => "ApriPr";
}

/// <summary>CompletaPr: merge della PR sul commit verificato. Rev evita di chiederlo due volte per lo stesso ingresso.</summary>
public sealed record CompletePr(int Rev, string? Commit) : AgentAction
{
    public override string Kind => "CompletaPr";
}

/// <summary>AccodaDeployTest: la pipeline di deploy con i parametri scelti a true e gli altri deploy* a false.</summary>
public sealed record QueueTestDeploy(int Rev, IReadOnlyList<string> Parameters, IReadOnlyList<string> Off) : AgentAction
{
    public override string Kind => "AccodaDeployTest";
}

/// <summary>D59: CreaAmbienteCollaudo, l'ambiente Docker della card al posto del deploy in Test. Rev vale come runDopoRev.</summary>
public sealed record CreateTestEnvironment(int Rev) : AgentAction
{
    public override string Kind => "CreaAmbienteCollaudo";
}

/// <summary>D59: ButtaAmbienteCollaudo, quando la card lascia gli stati di Test.</summary>
public sealed record DiscardTestEnvironment : AgentAction
{
    public override string Kind => "ButtaAmbienteCollaudo";
}

public sealed record RequeueExpiredValidations : AgentAction
{
    public override string Kind => "RilanciaScadute";
}

public sealed record RequeueValidation(string SessionId) : AgentAction
{
    public override string Kind => "RilanciaValidazione";
}

/// <summary>Avvisa: un commento con la menzione a chi deve fare un gesto; Key evita di ripeterlo.</summary>
public sealed record Notify(string Who, string Key, string Text) : AgentAction
{
    public override string Kind => "Avvisa";
}

public sealed record ResetCounters : AgentAction
{
    public override string Kind => "AzzeraContatori";
}

public sealed record ResetDeploy : AgentAction
{
    public override string Kind => "AzzeraDeploy";
}

/// <summary>Perche una card non si muove, per la vista: on-hold, predecessori, limite di sessioni, quota, ...</summary>
public sealed record BlockReason(string Type, string? Role = null, string? Detail = null, IReadOnlyList<int>? Cards = null);

public sealed record Decision(IReadOnlyList<AgentAction> Actions, BlockReason? Reason)
{
    public static readonly Decision Nothing = new([], null);
}
