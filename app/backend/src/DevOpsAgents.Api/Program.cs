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
using DevOpsAgents.Infrastructure.Secrets;

var builder = WebApplication.CreateBuilder(args);
var options = builder.Configuration.GetSection("DevOpsAgents").Get<ApiOptions>() ?? new ApiOptions();
var root = options.Root ?? SuiteConfig.FindRoot(builder.Environment.ContentRootPath);
var suite = SuiteConfig.Load(root);
var dataDir = options.DataDir ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DevOps.Agents.Net");
Directory.CreateDirectory(dataDir);

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
    builder.Services.AddSingleton<IBoard>(sp => new AdoBoard(sp.GetRequiredService<AdoClient>(), suite.BoardProject, suite.Names));
    builder.Services.AddSingleton(sp => new AzureReposCodeHost(sp.GetRequiredService<AdoClient>()));
    builder.Services.AddSingleton(sp => new GitHubCodeHost(sp.GetRequiredService<IHttpClientFactory>().CreateClient("github"), () => tokens.GitHub, sp.GetRequiredService<AdoClient>()));
    builder.Services.AddSingleton<ICodeHostResolver, CodeHostResolver>();
    builder.Services.AddSingleton<ICiService>(sp => new AzurePipelinesCi(sp.GetRequiredService<AdoClient>()));
    builder.Services.AddSingleton<IWorkspace>(new GitWorkspace(options.WorktreeRoot));
    builder.Services.AddSingleton<ISessionRunner>(new ClaudeSessionRunner(suite, tokens, new ClaudeRunnerOptions { Executable = options.ClaudeExecutable, DataDir = dataDir }));
    builder.Services.AddSingleton<IStateStore>(new JsonStateStore(Path.Combine(dataDir, "stato.json")));
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

builder.Services.AddSingleton(sp => new Dispatcher(
    sp.GetRequiredService<IBoard>(), sp.GetRequiredService<ICodeHostResolver>(), sp.GetRequiredService<ICiService>(), sp.GetRequiredService<IWorkspace>(),
    sp.GetRequiredService<ISessionRunner>(), sp.GetRequiredService<IStateStore>(), sp.GetRequiredService<DecisionEngine>(), suite.Names, suite.Limits,
    suite.Areas, sp.GetRequiredService<IClock>(), sp.GetRequiredService<ILogger<Dispatcher>>(), new DispatcherOptions { OnlyMine = options.OnlyMine }));
builder.Services.AddSingleton(sp => new DispatcherService(sp.GetRequiredService<Dispatcher>(), sp.GetRequiredService<Microsoft.AspNetCore.SignalR.IHubContext<LiveHub>>(),
    options, TimeSpan.FromMinutes(Math.Max(1, suite.Limits.IntervalMinutes)), sp.GetRequiredService<ILogger<DispatcherService>>()));
builder.Services.AddHostedService(sp => sp.GetRequiredService<DispatcherService>());

var app = builder.Build();
app.UseCors();
app.UseDefaultFiles();
app.UseStaticFiles();

// Le scritture vogliono un'intestazione propria: un form o un link da un altro sito non la puo mettere senza preflight CORS.
const string Header = "X-DevOps-Agents";
static bool Allowed(HttpRequest r) => r.Headers.ContainsKey(Header);

var api = app.MapGroup("/api");
api.MapGet("/status", (DispatcherService svc, ApiOptions o, SuiteConfig s) => new
{
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
