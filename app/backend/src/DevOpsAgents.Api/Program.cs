using DevOpsAgents.Core.Agents;
using System.Text.Json.Serialization;
using DevOpsAgents.Api;
using DevOpsAgents.Api.Demo;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Orchestration;
using DevOpsAgents.Core.Ports;
using DevOpsAgents.Infrastructure.AzureDevOps;
using DevOpsAgents.Infrastructure.Configuration;
using DevOpsAgents.Infrastructure.GitHub;
using DevOpsAgents.Infrastructure.Local;
using DevOpsAgents.Infrastructure.Notifications;
using DevOpsAgents.Infrastructure.Secrets;

var builder = WebApplication.CreateBuilder(args);
// come servizio Windows (sc create) o systemd (Type=notify): fuori da li non cambia niente
builder.Host.UseWindowsService(o => o.ServiceName = "DevOps.Agents");
builder.Host.UseSystemd();
var options = builder.Configuration.GetSection("DevOpsAgents").Get<ApiOptions>() ?? new ApiOptions();
var root = options.Root ?? SuiteConfig.FindRoot(builder.Environment.ContentRootPath);
var dataDir = options.DataDir ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DevOps.Agents.Net");
Directory.CreateDirectory(dataDir);
// D53: gli override locali di limiti e supervisore stanno in impostazioni.json della cartella dati (dal vivo), fuori dal repo
var settingsFile = options.Mode == "live" ? Path.Combine(dataDir, "impostazioni.json") : null;
var suite = SuiteConfig.Load(root, settingsFile);

// solo da questo PC: la dashboard avvia giri e vede le card
builder.WebHost.UseUrls(builder.Configuration["Urls"] ?? "http://localhost:18800");
builder.Services.ConfigureHttpJsonOptions(o =>
{
    o.SerializerOptions.Converters.Add(new JsonStringEnumConverter());
    o.SerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
});
builder.Services.AddSignalR().AddJsonProtocol(o => o.PayloadSerializerOptions.Converters.Add(new JsonStringEnumConverter()));
builder.Services.AddCors(o => o.AddDefaultPolicy(p => p.WithOrigins("http://localhost:4200").AllowAnyHeader().AllowAnyMethod().AllowCredentials()));
builder.Services.AddSingleton(options);
builder.Services.AddSingleton(suite);
builder.Services.AddSingleton<IClock, SystemClock>();
builder.Services.AddSingleton<DecisionEngine>();

if (options.Mode == "live")
{
    var tokens = new TokenStore();
    builder.Services.AddSingleton(tokens);
    builder.Services.AddHttpClient();
    builder.Services.AddSingleton(sp => new AdoClient(sp.GetRequiredService<IHttpClientFactory>().CreateClient("ado"), suite.Organization, () => tokens.AzureDevOps));
    builder.Services.AddSingleton(sp => new AdoBoard(sp.GetRequiredService<AdoClient>(), suite.BoardProject, suite.Names));
    builder.Services.AddSingleton<IBoard>(sp => sp.GetRequiredService<AdoBoard>());
    builder.Services.AddSingleton<ICardEditor>(sp => sp.GetRequiredService<AdoBoard>());
    builder.Services.AddSingleton<ICardCreator>(sp => sp.GetRequiredService<AdoBoard>());
    builder.Services.AddSingleton(sp => new AzureReposCodeHost(sp.GetRequiredService<AdoClient>()));
    builder.Services.AddSingleton(sp => new GitHubCodeHost(sp.GetRequiredService<IHttpClientFactory>().CreateClient("github"), () => tokens.GitHub, sp.GetRequiredService<AdoClient>()));
    builder.Services.AddSingleton<ICodeHostResolver, CodeHostResolver>();
    builder.Services.AddSingleton<ICiService>(sp => new AzurePipelinesCi(sp.GetRequiredService<AdoClient>()));
    builder.Services.AddSingleton<IWorkspace>(new GitWorkspace(options.WorktreeRoot));
    builder.Services.AddSingleton<ISessionRunner>(new ClaudeSessionRunner(suite, tokens, new ClaudeRunnerOptions { Executable = options.ClaudeExecutable, DataDir = dataDir, McpServer = options.McpCommand(AppContext.BaseDirectory), HookCommand = options.HookCommandOf(AppContext.BaseDirectory), MemoryWorktree = Path.Combine(options.WorktreeRoot, "DevOps.Agents", "memoria") }, new GitMemorySource(root)));
    builder.Services.AddSingleton<IStateStore>(new JsonStateStore(Path.Combine(dataDir, "stato.json")));
    // D59: gli ambienti Docker di collaudo, se config/collaudo.json c'e
    if (DockerSettings.Load(root) is { } docker) builder.Services.AddSingleton<ITestEnvironments>(new DockerTestEnvironments(docker, dataDir));
}
else
{
    builder.Services.AddSingleton(sp => new DemoWorld(suite.Names, suite.Areas, sp.GetRequiredService<IClock>()));
    builder.Services.AddSingleton<IBoard>(sp => sp.GetRequiredService<DemoWorld>());
    builder.Services.AddSingleton<ICodeHostResolver>(sp => sp.GetRequiredService<DemoWorld>());
    builder.Services.AddSingleton<ICiService>(sp => sp.GetRequiredService<DemoWorld>());
    builder.Services.AddSingleton<IWorkspace>(sp => sp.GetRequiredService<DemoWorld>());
    builder.Services.AddSingleton<ISessionRunner>(sp => sp.GetRequiredService<DemoWorld>());
    builder.Services.AddSingleton<IStateStore>(sp => sp.GetRequiredService<DemoWorld>());
}

// impostazioni.json e quota.json nella cartella dati (la demo nella sua sottocartella, per non toccare quelle vere)
var storeDir = options.Mode == "live" ? dataDir : Path.Combine(dataDir, "demo");
builder.Services.AddSingleton<ISettingsStore>(new JsonSettingsStore(Path.Combine(storeDir, "impostazioni.json")));
builder.Services.AddSingleton<IQuotaStore>(new JsonQuotaStore(storeDir));
builder.Services.AddSingleton(sp => new PriorityService(sp.GetRequiredService<IBoard>(), sp.GetRequiredService<ISettingsStore>(), suite.Names, suite.Areas));
builder.Services.AddSingleton(sp => new Dispatcher(
    sp.GetRequiredService<IBoard>(), sp.GetRequiredService<ICodeHostResolver>(), sp.GetRequiredService<ICiService>(), sp.GetRequiredService<IWorkspace>(),
    sp.GetRequiredService<ISessionRunner>(), sp.GetRequiredService<IStateStore>(), sp.GetRequiredService<DecisionEngine>(), suite.Names, suite.Limits,
    suite.Areas, sp.GetRequiredService<IClock>(), sp.GetRequiredService<ILogger<Dispatcher>>(), new DispatcherOptions { OnlyMine = options.OnlyMine, SuiteRoot = root, MentorFolders = Path.Combine(dataDir, "mentori") },
    sp.GetRequiredService<ISettingsStore>(), sp.GetRequiredService<IQuotaStore>(), sp.GetService<ITestEnvironments>(), sp.GetRequiredService<ILearningLog>()));
// D46: il registro dell'apprendimento (la demo nella sua sottocartella)
builder.Services.AddSingleton<ILearningLog>(new JsonlLearningLog(options.Mode == "live" ? dataDir : Path.Combine(dataDir, "demo")));
builder.Services.AddSingleton(sp => new DispatcherService(sp.GetRequiredService<Dispatcher>(), sp.GetRequiredService<Microsoft.AspNetCore.SignalR.IHubContext<LiveHub>>(),
    options, TimeSpan.FromMinutes(Math.Max(1, suite.Limits.IntervalMinutes)), sp.GetRequiredService<ILogger<DispatcherService>>()));
builder.Services.AddHostedService(sp => sp.GetRequiredService<DispatcherService>());
// D51: il supervisore, con Telegram se ci sono token e chat (~/.claude/telegram-token.txt, <dati>/telegram-chat.txt)
builder.Services.AddSingleton(SuiteConfig.LoadSupervisor(root, settingsFile));
builder.Services.AddSingleton<INotifier>(sp => options.Mode == "live"
    ? TelegramNotifier.FromFiles(new HttpClient(), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude"), dataDir)
    : new TelegramNotifier(new HttpClient(), null, null, Path.Combine(storeDir, "telegram-topic.json")));
builder.Services.AddSingleton(sp => new SupervisorService(sp.GetRequiredService<DispatcherService>(), options, sp.GetRequiredService<DevOpsAgents.Core.Supervision.SupervisorSettings>(),
    suite, sp.GetRequiredService<IQuotaStore>(), sp.GetRequiredService<INotifier>(), sp.GetRequiredService<IClock>(), Path.Combine(storeDir, "supervisore.json"),
    sp.GetRequiredService<ILogger<SupervisorService>>(), sp));
builder.Services.AddHostedService(sp => sp.GetRequiredService<SupervisorService>());
// D53: l'aggiornamento della copia degli attrezzi, dal vivo e se non e spento (nel container la versione e l'immagine)
if (options.Mode == "live" && options.AutoUpdate)
    builder.Services.AddSingleton(sp =>
    {
        var sup = sp.GetRequiredService<DevOpsAgents.Core.Supervision.SupervisorSettings>();
        var disp = sp.GetRequiredService<DispatcherService>();
        var runner = sp.GetRequiredService<ISessionRunner>();
        var notifier = sp.GetRequiredService<INotifier>();
        return new SuiteUpdater(new UpdaterOptions(root, dataDir, sup.UpdateCheckMinutes, sup.UpdateWaitHours, options.UpdateBuild, options.ClaudeExecutable),
            () => new DevOpsAgents.Core.Update.Occupancy(runner.Running.Count, disp.Running ? 1 : 0),
            action => disp.RunExclusiveAsync(action),
            async (topic, html) => !notifier.Configured || await notifier.SendAsync(topic, html, CancellationToken.None));
    });

var app = builder.Build();
app.UseCors();
app.UseDefaultFiles();
app.UseStaticFiles();

// Le scritture vogliono un'intestazione propria: un form o un link da un altro sito non la puo mettere senza preflight CORS.
const string Header = "X-DevOps-Agents";
static bool Allowed(HttpRequest r) => r.Headers.ContainsKey(Header);

var api = app.MapGroup("/api");
api.MapGet("/status", async (DispatcherService svc, ApiOptions o, SuiteConfig s, PriorityService p) => new
{
    systemPaused = await p.IsSystemPausedAsync(),
    mode = o.Mode,
    allowWrites = o.AllowWrites,
    autoRun = o.AutoRun,
    running = svc.Running,
    nextRun = svc.NextRun,
    lastRound = svc.Last?.Finished,
    intervalMinutes = s.Limits.IntervalMinutes,
    boardProject = s.BoardProject,
    organization = o.Mode == "live" ? s.Organization : null,
});
api.MapGet("/round", (DispatcherService svc) => svc.Last is { } r ? Results.Ok(r) : Results.NoContent());
api.MapPost("/round", async (HttpRequest req, DispatcherService svc, bool? whatIf, int? card, CancellationToken ct) =>
{
    if (!Allowed(req)) return Results.StatusCode(StatusCodes.Status403Forbidden);
    var r = await svc.RunNowAsync(whatIf ?? true, card, ct);
    return r is null ? Results.Conflict(new { error = "un giro e gia in corso" }) : Results.Ok(r);
});
// D60: le Feature in ordine di priorita, la loro pausa, il riordino e la pausa del sistema. Dopo ogni cambio un giro di prova
// aggiorna la dashboard (le card in pausa mostrano subito il motivo).
api.MapGet("/features", (PriorityService p, CancellationToken ct) => p.GetFeaturesAsync(ct));
api.MapPost("/features/{id:int}/pause", async (HttpRequest req, PriorityService p, DispatcherService svc, int id, bool active, CancellationToken ct) =>
{
    if (!Allowed(req)) return Results.StatusCode(StatusCodes.Status403Forbidden);
    try { await p.SetFeaturePausedAsync(id, active, ct); } catch (ArgumentException e) { return Results.BadRequest(new { error = e.Message }); }
    _ = await svc.RunNowAsync(true, ct: ct);
    return Results.Ok(await p.GetFeaturesAsync(ct));
});
api.MapPost("/features/{id:int}/move", async (HttpRequest req, PriorityService p, DispatcherService svc, int id, int after, CancellationToken ct) =>
{
    if (!Allowed(req)) return Results.StatusCode(StatusCodes.Status403Forbidden);
    try { await p.MoveAsync(id, after, ct); } catch (ArgumentException e) { return Results.BadRequest(new { error = e.Message }); }
    _ = await svc.RunNowAsync(true, ct: ct);
    return Results.Ok(await p.GetFeaturesAsync(ct));
});
api.MapPost("/system/pause", async (HttpRequest req, PriorityService p, DispatcherService svc, bool active, CancellationToken ct) =>
{
    if (!Allowed(req)) return Results.StatusCode(StatusCodes.Status403Forbidden);
    await p.SetSystemPausedAsync(active, ct);
    _ = await svc.RunNowAsync(true, ct: ct);
    return Results.Ok(new { systemPaused = active });
});
// D51: cosa aspetta una persona, secondo il supervisore (i problemi aperti), e un suo giro a richiesta (di prova: non manda niente)
// card.ps1 crea: una card figlia di una Feature, o una Feature (con la card di chiusura, o -Raggruppa). Solo dal vivo: la board e quella vera.
api.MapPost("/cards", async (HttpRequest req, IServiceProvider sp, SuiteConfig s, CreateRequest body, CancellationToken ct) =>
{
    if (!Allowed(req)) return Results.StatusCode(StatusCodes.Status403Forbidden);
    if (sp.GetService<ICardCreator>() is not { } creator || sp.GetService<ICardEditor>() is not { } editor)
        return Results.Conflict(new { error = "in modalita demo non si creano card: serve Mode=live" });
    try
    {
        var created = await new CardCreator(creator, editor, s.Names, s.Areas, s.Limits.FeaturesEnabled).CreateAsync(body, ct: ct);
        return Results.Ok(created);
    }
    catch (CardToolException e) { return Results.BadRequest(new { error = e.Message }); }
});

api.MapGet("/supervisor", (SupervisorService s) => new
{
    problems = s.State.Problems.Values.OrderByDescending(p => p.Problem.Urgent).ThenBy(p => p.FirstSeen)
        .Select(p => new { key = p.Problem.Key, text = p.Problem.Text, action = p.Problem.Action, link = p.Problem.Link, urgent = p.Problem.Urgent, lines = p.Problem.Lines, since = p.FirstSeen, lastNotice = p.LastNotice }),
    lastRun = s.State.LastRun,
});
api.MapPost("/supervisor", async (HttpRequest req, SupervisorService s, CancellationToken ct) =>
{
    if (!Allowed(req)) return Results.StatusCode(StatusCodes.Status403Forbidden);
    var plan = await s.RunOnceAsync(whatIf: true, ct);
    return Results.Ok(new { urgent = plan.Urgent.Count, summary = plan.Summary.Count + plan.Releases.Count });
});
// D53: lo stato dell'aggiornamento della suite e "aggiorna adesso" (il giro dopo del supervisore lo esegue)
api.MapGet("/update", (IServiceProvider sp) => sp.GetService<SuiteUpdater>() is { } u ? Results.Ok(u.Status()) : Results.Ok(new { spento = true }));
api.MapPost("/update", (HttpRequest req, IServiceProvider sp) =>
{
    if (!Allowed(req)) return Results.StatusCode(StatusCodes.Status403Forbidden);
    if (sp.GetService<SuiteUpdater>() is not { } u) return Results.Conflict(new { error = "l'aggiornamento della suite e spento (AutoUpdate=false, o modalita demo)" });
    u.Request();
    return Results.Accepted();
});

api.MapGet("/config", (SuiteConfig s) => new
{
    states = StatesInFlow.Select(k => new { key = k, name = s.Names.Get(k) }).Where(x => x.name is not null),
    areas = s.Areas.Select(a => new { a.Area, a.Repo, a.Component, source = a.Source.ToString(), a.GitHubRepo, a.DeployPipeline, a.TestUrl }),
    roles = s.Roles.Select(r => new { name = r.Key, r.Value.Model, r.Value.Effort, r.Value.Advisor }),
    limits = s.Limits,
});
app.MapHub<LiveHub>("/hub");
app.MapFallbackToFile("index.html");
app.Run();

public partial class Program
{
    /// <summary>Gli stati nell'ordine del flusso: le colonne della kanban.</summary>
    internal static readonly string[] StatesInFlow =
    [
        DevOpsAgents.Core.Configuration.StateKeys.New, DevOpsAgents.Core.Configuration.StateKeys.NeedsClarification, DevOpsAgents.Core.Configuration.StateKeys.Ready,
        DevOpsAgents.Core.Configuration.StateKeys.InDevelopment, DevOpsAgents.Core.Configuration.StateKeys.InReview, DevOpsAgents.Core.Configuration.StateKeys.DeployingToTest,
        DevOpsAgents.Core.Configuration.StateKeys.AutomatedTest, DevOpsAgents.Core.Configuration.StateKeys.HumanTest, DevOpsAgents.Core.Configuration.StateKeys.ReadyToMerge,
        DevOpsAgents.Core.Configuration.StateKeys.InFeatureBranch, DevOpsAgents.Core.Configuration.StateKeys.ReadyToRelease,
    ];
}
