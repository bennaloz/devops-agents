using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Ports;
using DevOpsAgents.Core.Supervision;
using DevOpsAgents.Infrastructure.Configuration;
using DevOpsAgents.Infrastructure.Notifications;

namespace DevOpsAgents.Api;

/// <summary>
/// Il supervisore come servizio (D51), ogni intervalloMinuti di config/supervisore.json: guarda lo smistatore e le card dell'ultimo giro,
/// tiene i problemi aperti in supervisore.json (cartella dati) e manda urgenti, riepiloghi e rilasci su Telegram, o li scrive nel log.
/// Non fa niente da solo: deploy, approvazioni, merge e card restano alle persone e allo smistatore.
/// </summary>
public sealed class SupervisorService(DispatcherService dispatcher, ApiOptions options, SupervisorSettings settings, SuiteConfig suite, IQuotaStore quota,
    INotifier notifier, IClock clock, string statePath, ILogger<SupervisorService> logger, IServiceProvider? services = null) : BackgroundService
{
    private readonly SemaphoreSlim _one = new(1, 1);
    public SupervisorState State { get; private set; } = Load(statePath);
    public NoticePlan? LastPlan { get; private set; }

    private static SupervisorState Load(string path)
    {
        try { return File.Exists(path) ? System.Text.Json.JsonSerializer.Deserialize<SupervisorState>(File.ReadAllText(path), SuiteConfig.Json) ?? new() : new(); }
        catch (System.Text.Json.JsonException) { return new(); }
    }

    public async Task<NoticePlan> RunOnceAsync(bool whatIf = false, CancellationToken ct = default)
    {
        await _one.WaitAsync(ct);
        try
        {
            var now = clock.Now;
            var q = await quota.LoadAsync(ct);
            var ctx = new DecisionContext(suite.Names, suite.Limits, now, Quota: q, QuotaOverrides: await quota.LoadOverridesAsync(ct));
            // D51: le pipeline di tutta l'organizzazione, dal vivo; una lettura che non riesce e un problema, non un giro fermo
            var reader = services?.GetService(typeof(IPipelineReader)) as IPipelineReader;
            var projects = suite.Areas.Select(a => a.AdoProject).Distinct().ToList();
            var deploys = suite.Areas.Where(a => a.DeployPipeline is not null).Select(a => a.DeployPipeline!.Value).ToList();
            PipelineView? pipelines = null;
            if (reader is not null)
            {
                try { pipelines = await reader.ReadAsync(projects, deploys, now, ct); }
                catch (Exception e) when (e is not OperationCanceledException) { pipelines = PipelineView.Unread(e.Message); }
            }
            var quotaBlock = DecisionEngine.QuotaBlock(ctx);
            var o = new Observation(now, TimeZoneInfo.Local, options.AutoRun, dispatcher.Last?.Finished, dispatcher.Errors, dispatcher.Last,
                Supervisor.HoursStill(State, now), quotaBlock, null, null, pipelines, suite.Organization, projects, deploys);
            LastPipelines = pipelines;
            var problems = Supervisor.Check(o, settings, State, suite.Names);
            Supervisor.Update(State, problems, o);
            if (!whatIf)
            {
                if (pipelines is { Read: true } && reader is not null) await RerunAsync(pipelines, projects, deploys, reader, now, ct);
                await DiagnoseAsync(now, quotaBlock is not null, ct);
            }
            var plan = Supervisor.Plan(State, o, settings);
            LastPlan = plan;
            if (whatIf) return plan;
            var sent = new List<Notice>();
            foreach (var n in plan.Urgent)
                if (await SendAsync("urgenti", TelegramFormat.Urgent(n), ct)) sent.Add(n);
            if (plan.SendSummary)
            {
                var rest = plan.Summary.ToList();
                if (rest.Count > 0 && await SendAsync("riepilogo", TelegramFormat.Summary(rest), ct)) sent.AddRange(rest);
                if (plan.Releases.Count > 0 && await SendAsync("rilasci", TelegramFormat.Releases(plan.Releases), ct)) sent.AddRange(plan.Releases);
            }
            Supervisor.Register(State, plan, sent, now);
            Directory.CreateDirectory(Path.GetDirectoryName(statePath)!);
            await File.WriteAllTextAsync(statePath, System.Text.Json.JsonSerializer.Serialize(State, SuiteConfig.Json), ct);
            // D53: l'aggiornamento della suite, a ogni giro (il fetch solo ogni minutiControlloAggiornamenti): mai fatale per il giro
            if (services?.GetService(typeof(DevOpsAgents.Infrastructure.Local.SuiteUpdater)) is DevOpsAgents.Infrastructure.Local.SuiteUpdater updater)
            {
                try { await updater.RunAsync(now, log: m => logger.LogInformation("{Message}", m), ct: ct); }
                catch (Exception e) when (e is not OperationCanceledException) { logger.LogError(e, "aggiornamento della suite interrotto"); }
            }
            return plan;
        }
        finally { _one.Release(); }
    }

    public PipelineView? LastPipelines { get; private set; }

    /// <summary>
    /// Il solo gesto sulle pipeline che il supervisore fa da solo: rilanciare un run fallito per infrastruttura, delle pipeline in pipelineRilanciabili,
    /// solo develop, una volta per run. Niente deploy, approvazioni o merge.
    /// </summary>
    private async Task RerunAsync(PipelineView p, IReadOnlyCollection<string> projects, IReadOnlyCollection<int> deploys, IPipelineReader reader, DateTimeOffset now, CancellationToken ct)
    {
        var g = PipelineRules.GroupFailed(p, projects, deploys, State.Reruns, settings.Rerunnable, settings.InfrastructureTexts);
        foreach (var r in g.Rerunnable)
        {
            int? id = null;
            try { id = await reader.RerunAsync(r, ct); logger.LogInformation("supervisore: rilanciato il run {Run} ({Pipeline}, {Branch}) fallito per infrastruttura: nuovo run {New}", r.Id, r.Pipeline, r.Branch, id); }
            catch (Exception e) when (e is not OperationCanceledException) { logger.LogError("supervisore: il rilancio del run {Run} non e riuscito: {Error}", r.Id, e.Message); }
            State.Reruns[r.Id.ToString()] = new Rerun(now, id);
        }
        // i rilanci si ricordano una settimana
        foreach (var k in State.Reruns.Where(kv => (now - kv.Value.When).TotalDays > 7).Select(kv => kv.Key).ToList()) State.Reruns.Remove(k);
    }

    /// <summary>
    /// D51: la diagnosi con un modello (ruolo supervisore), in sola lettura, per un problema che nessuna regola spiega. Si legge l'esito della sessione
    /// in corso; se ha cambiato la copia degli attrezzi lo si dice. Poi, se le regole lo permettono, se ne lancia una.
    /// </summary>
    private async Task DiagnoseAsync(DateTimeOffset now, bool quotaBlocked, CancellationToken ct)
    {
        if (services?.GetService(typeof(ISessionRunner)) is not ISessionRunner runner || options.Mode != "live" || suite.Areas.Count == 0) return;
        if (State.Diagnosis is { } d)
        {
            var r = await runner.PollAsync(d.SessionId, ct);
            if (r is null) return;
            var text = r.NoResultCause is null && !r.Failed && r.Outcome == "diagnosi" && DiagnosisRules.Text(r.Text) is { Length: > 0 } t ? t : DiagnosisRules.Failed;
            if (d.Fingerprint is not null && Fingerprint() is { } after && after != d.Fingerprint) text += " (attenzione: la sessione di diagnosi ha cambiato la copia degli attrezzi, controllala)";
            if (State.Problems.TryGetValue(d.Key, out var open)) open.Diagnosis = text;
            State.Diagnosis = null;
            logger.LogInformation("supervisore: diagnosi di {Key}: {Text}", d.Key, text);
        }
        if (DiagnosisRules.Next(State, now, TimeZoneInfo.Local, settings.DiagnosesPerDay, quotaBlocked, runner.Running.Count, suite.Limits.ActiveSessions) is not { } key) return;
        DiagnosisRules.Count(State, now, TimeZoneInfo.Local);
        var folder = Path.Combine(Path.GetDirectoryName(statePath)!, "diagnosi", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var id = await runner.StartAsync(new SessionRequest("supervisore", 0, suite.Areas[0], folder, DiagnosisRules.Message(State.Problems[key].Problem), null, false, null, null), ct);
            State.Diagnosis = new DiagnosisRun(id, key, now, Fingerprint());
            logger.LogInformation("supervisore: lanciata la diagnosi {Id} per {Key}", id, key);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            State.Problems[key].Diagnosis = DiagnosisRules.Failed;
            logger.LogError("supervisore: la diagnosi di {Key} non e partita: {Error}", key, e.Message);
        }
    }

    /// <summary>L'impronta della copia degli attrezzi (HEAD e git status): una sessione di diagnosi e in sola lettura e non deve cambiarla.</summary>
    private string? Fingerprint()
    {
        try
        {
            string Git(params string[] args)
            {
                var psi = new System.Diagnostics.ProcessStartInfo("git") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
                psi.ArgumentList.Add("-C"); psi.ArgumentList.Add(suite.Root);
                foreach (var a in args) psi.ArgumentList.Add(a);
                using var p = System.Diagnostics.Process.Start(psi)!;
                var o = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                return o;
            }
            return Git("rev-parse", "HEAD") + Git("status", "--porcelain");
        }
        catch { return null; }
    }

    /// <summary>Senza Telegram gli avvisi vanno solo nel log, e contano come mandati (il log e il canale).</summary>
    private async Task<bool> SendAsync(string topic, string html, CancellationToken ct)
    {
        if (!notifier.Configured) { logger.LogWarning("supervisore [{Topic}]: {Text}", topic, html); return true; }
        var ok = await notifier.SendAsync(topic, html, ct);
        if (!ok) logger.LogWarning("supervisore: messaggio Telegram ({Topic}) non mandato, riprovo al giro dopo", topic);
        return ok;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(Math.Max(1, settings.IntervalMinutes)));
        do
        {
            try { await RunOnceAsync(ct: stoppingToken); }
            catch (Exception e) when (e is not OperationCanceledException) { logger.LogError(e, "giro del supervisore interrotto"); }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
