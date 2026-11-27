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
            var o = new Observation(now, TimeZoneInfo.Local, options.AutoRun, dispatcher.Last?.Finished, dispatcher.Errors, dispatcher.Last,
                Supervisor.HoursStill(State, now), DecisionEngine.QuotaBlock(ctx), null);
            var problems = Supervisor.Check(o, settings, State, suite.Names);
            Supervisor.Update(State, problems, o);
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
