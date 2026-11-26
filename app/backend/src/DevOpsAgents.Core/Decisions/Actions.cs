namespace DevOpsAgents.Core.Decisions;

/// <summary>Un'azione che il motore decide e lo smistatore esegue. I nomi corrispondono a quelli di Decisioni.psm1.</summary>
public abstract record AgentAction
{
    /// <summary>Il nome dell'azione nell'originale PowerShell (LanciaSessione, SpostaCard, ...): serve al confronto in parallelo.</summary>
    public abstract string Kind { get; }
}

/// <summary>LanciaSessione: una sessione claude -p del ruolo, con il motivo e l'allegato.</summary>
public sealed record LaunchSession(string Role, string Reason, string? Attachment = null, bool Resume = false, int? TaskId = null,
    /// <summary>D52: il collaudatore della card di chiusura lavora in un worktree in sola lettura del ramo della funzionalita.</summary>
    bool ClosingWorktree = false,
    /// <summary>D52: la build della CI rossa data al responsabile della card di chiusura.</summary>
    string? Build = null,
    /// <summary>Come riparte una sessione ripresa: dopoPassata (D42), dopoQuota, dopoRipresaAutomatica (D51); null se l'ha sbloccata una persona.</summary>
    string? ResumeKind = null) : AgentAction
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
public sealed record MoveBack(string State, string Reason, string? Commit = null) : AgentAction
{
    public override string Kind => "RiportaIndietro";
}

/// <summary>CreaWorktree: il ramo della card da origin/develop (o dalla base) in un worktree dedicato.</summary>
public sealed record CreateWorktree(string? Base = null, bool FeatureCard = false) : AgentAction
{
    public override string Kind => "CreaWorktree";
}

public sealed record RemoveWorktree(bool Closing = false) : AgentAction
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

/// <summary>D52: CreaRamoFunzionalita, il ramo della funzionalita da origin/develop, pubblicato (se non c'e gia).</summary>
public sealed record CreateFeatureBranch(int FeatureId) : AgentAction
{
    public override string Kind => "CreaRamoFunzionalita";
}

/// <summary>D52: AggiornaFeature, lo stato della Feature (chiave di stati.json). CloseLater: ricordarla da chiudere con la card di chiusura.</summary>
public sealed record UpdateFeature(int FeatureId, string State, bool CloseLater = false) : AgentAction
{
    public override string Kind => "AggiornaFeature";
}

/// <summary>D52: ImpostaRamoChiusura, il ramo della card di chiusura e quello della funzionalita; la PR va verso develop, senza worktree.</summary>
public sealed record SetClosingBranch(string? Branch, bool FromLinkedPr = false) : AgentAction
{
    public override string Kind => "ImpostaRamoChiusura";
}

/// <summary>D52: CreaCorrezione, la correzione scritta dal responsabile diventa una Bug figlia della Feature.</summary>
public sealed record CreateCorrection(string Key, string Nature, string Title, string Description, int FeatureId, int ClosingCardId) : AgentAction
{
    public override string Kind => "CreaCorrezione";
}

/// <summary>D52: CreaAllineaDevelop, la PR della funzionalita verso develop e in conflitto: una Bug allinea-develop per quella testa.</summary>
public sealed record CreateAlignDevelop(int FeatureId, string Branch, string Commit) : AgentAction
{
    public override string Kind => "CreaAllineaDevelop";
}

/// <summary>D42: AvviaPassataAttesa, il responsabile esamina l'attesa prima dell'on-hold.</summary>
public sealed record StartHoldReview(string Reason, string? For, string? Role, string Key) : AgentAction
{
    public override string Kind => "AvviaPassataAttesa";
}

public sealed record CloseHoldReview(string? Role) : AgentAction
{
    public override string Kind => "ChiudiPassataAttesa";
}

/// <summary>D42: una persona ha tolto l'on-hold: ogni tipo di attesa ha di nuovo la sua passata, e le riprese automatiche ripartono.</summary>
public sealed record ResetHoldReviews : AgentAction
{
    public override string Kind => "AzzeraPassateAttesa";
}

/// <summary>D51: TogliAttesa, un on-hold che lo smistatore toglie perche un dato dice che la causa non c'e piu.</summary>
public sealed record RemoveOnHold(string Cause, string? For) : AgentAction
{
    public override string Kind => "TogliAttesa";
}

/// <summary>AdottaCard: la card e arrivata da un altro PC, il lavoro e sul ramo pubblicato. Base: il ramo della funzionalita (D52).</summary>
public sealed record AdoptCard(string? Base = null, bool FeatureCard = false) : AgentAction
{
    public override string Kind => "AdottaCard";
}

public sealed record ResetCiRed : AgentAction
{
    public override string Kind => "AzzeraCiRosse";
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
