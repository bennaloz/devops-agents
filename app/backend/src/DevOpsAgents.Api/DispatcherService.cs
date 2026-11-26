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
    /// <summary>
    /// Il server MCP degli agenti (devops-agents-mcp, l'eseguibile o la dll): le sessioni lo usano al posto di card.ps1. Vuoto: lo si cerca
    /// accanto all'API (bin o ../mcp); "off": niente MCP, le sessioni usano card.ps1 come la versione PowerShell.
    /// </summary>
    public string? McpServer { get; init; }

    /// <summary>Il comando del server MCP, o null se spento o non trovato.</summary>
    public IReadOnlyList<string>? McpCommand(string baseDir)
    {
        if (string.Equals(McpServer, "off", StringComparison.OrdinalIgnoreCase)) return null;
        var path = McpServer is { Length: > 0 } p ? p
            : new[] { Path.Combine(baseDir, "devops-agents-mcp.dll"), Path.Combine(baseDir, "..", "mcp", "devops-agents-mcp.dll") }.FirstOrDefault(File.Exists);
        if (path is null) return null;
        return path.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ? ["dotnet", Path.GetFullPath(path)] : [path];
    }
}

/// <summary>I client della dashboard: ricevono ogni giro appena finito.</summary>
public sealed class LiveHub : Hub;

/// <summary>Lo smistatore come servizio: un giro alla volta, a intervallo o a richiesta, e l'ultimo resoconto per la dashboard.</summary>
public sealed class DispatcherService(Dispatcher dispatcher, IHubContext<LiveHub> hub, ApiOptions options, TimeSpan interval, ILogger<DispatcherService> logger) : BackgroundService
{
    private readonly SemaphoreSlim _one = new(1, 1);
    public RoundReport? Last { get; private set; }
    /// <summary>Gli ultimi giri interrotti (quando e perche): il supervisore li guarda per "il giro si interrompe a ogni giro" e il PAT rifiutato.</summary>
    public IReadOnlyList<(DateTimeOffset When, string Error)> Errors => _errors.ToList();
    private readonly System.Collections.Concurrent.ConcurrentQueue<(DateTimeOffset, string)> _errors = new();
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
            _errors.Enqueue((DateTimeOffset.UtcNow, e.Message));
            while (_errors.Count > 20) _errors.TryDequeue(out _);
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
