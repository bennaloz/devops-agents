using DevOpsAgents.Core.Orchestration;
using Microsoft.AspNetCore.SignalR;

namespace DevOpsAgents.Api;

public sealed record ApiOptions
{
    /// <summary>demo: mondo simulato in memoria. live: Azure DevOps, Azure Repos / GitHub, claude.</summary>
    public string Mode { get; init; } = "demo";
    /// <summary>Il giro automatico ogni intervalloMinuti (config/limiti.json). Spento, solo i giri chiesti dalla dashboard.</summary>
    public bool AutoRun { get; init; }
    /// <summary>Spento, ogni giro e di prova (non scrive niente): si accende quando ci si fida, come lo -WhatIf del PowerShell.</summary>
    public bool AllowWrites { get; init; }
    public bool OnlyMine { get; init; } = true;
    public string? Root { get; init; }
    public string? DataDir { get; init; }
    public string WorktreeRoot { get; init; } = "C:/develop/GIT/_wt";
    public string ClaudeExecutable { get; init; } = "claude";
}

/// <summary>I client della dashboard: ricevono ogni giro appena finito.</summary>
public sealed class LiveHub : Hub;

/// <summary>Lo smistatore come servizio: un giro alla volta, a intervallo o a richiesta, e l'ultimo resoconto per la dashboard.</summary>
public sealed class DispatcherService(Dispatcher dispatcher, IHubContext<LiveHub> hub, ApiOptions options, TimeSpan interval, ILogger<DispatcherService> logger) : BackgroundService
{
    private readonly SemaphoreSlim _one = new(1, 1);
    public RoundReport? Last { get; private set; }
    public DateTimeOffset? NextRun { get; private set; }
    public bool Running => _one.CurrentCount == 0;

    /// <summary>Un giro adesso; null se ce n'e gia uno in corso (non se ne avvia un altro, come il pulsante "giro adesso").</summary>
    public async Task<RoundReport?> RunNowAsync(bool whatIf, int? card = null, CancellationToken ct = default)
    {
        if (!await _one.WaitAsync(0, ct)) return null;
        try
        {
            var report = await dispatcher.RunRoundAsync(whatIf || !options.AllowWrites, card, ct);
            Last = report;
            await hub.Clients.All.SendAsync("round", report, ct);
            return report;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            // un giro che si interrompe (PAT scaduto, rete) non ferma il servizio: lo dice il log, il giro dopo riprova
            logger.LogError(e, "giro interrotto");
            throw;
        }
        finally { _one.Release(); }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // un primo giro di prova all'avvio: la dashboard ha subito qualcosa da mostrare
        try { await RunNowAsync(whatIf: true, ct: stoppingToken); } catch (Exception e) when (e is not OperationCanceledException) { }
        if (!options.AutoRun) return;
        using var timer = new PeriodicTimer(interval);
        NextRun = DateTimeOffset.UtcNow + interval;
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            try { await RunNowAsync(whatIf: false, ct: stoppingToken); } catch (Exception e) when (e is not OperationCanceledException) { }
            NextRun = DateTimeOffset.UtcNow + interval;
        }
    }
}
