using DevOpsAgents.Core.Agents;
using DevOpsAgents.Core.Ports;
using DevOpsAgents.Infrastructure.AzureDevOps;
using DevOpsAgents.Infrastructure.Configuration;
using DevOpsAgents.Infrastructure.GitHub;
using DevOpsAgents.Infrastructure.Local;
using DevOpsAgents.Infrastructure.Secrets;
using DevOpsAgents.Mcp;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

// Il server MCP degli agenti: lo lancia claude -p per la sessione di un ruolo (--mcp-config dello smistatore), su stdio.
//   devops-agents-mcp --card <id> --ruolo <ruolo> [--task <id>] [--root <repo degli attrezzi>] [--dati <cartella dati>] [--elenca]
// Card, ruolo e task li decide lo smistatore al lancio: nessuno strumento li prende come argomento, cosi una sessione non scrive su
// un'altra card. I token li legge il server (variabili DEVOPS_AGENTS_* o ~/.claude), non la sessione. --elenca stampa gli strumenti
// del ruolo ed esce (per i controlli e per chi scrive i brief).

var opts = Args.Parse(args);
if (opts.Error is { } usage)
{
    Console.Error.WriteLine($"devops-agents-mcp: {usage}");
    Console.Error.WriteLine("uso: devops-agents-mcp --card <id> --ruolo <ruolo> [--task <id>] [--root <cartella>] [--dati <cartella>] [--elenca]");
    return 2;
}

var root = opts.Root ?? SuiteConfig.FindRoot(AppContext.BaseDirectory);
var suite = SuiteConfig.Load(root);
if (!suite.Roles.ContainsKey(opts.Role!)) { Console.Error.WriteLine($"devops-agents-mcp: ruolo sconosciuto '{opts.Role}' (config/ruoli.json: {string.Join(", ", suite.Roles.Keys)})"); return 2; }
var session = new AgentSession(opts.Card!.Value, opts.Role!, opts.Task);
var tokens = new TokenStore();
var http = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
var ado = new AdoClient(http, suite.Organization, () => tokens.AzureDevOps);
var board = new AdoBoard(ado, suite.BoardProject, suite.Names);
var github = new GitHubCodeHost(http, () => tokens.GitHub, ado);
var code = new CodeHostResolver(new AzureReposCodeHost(ado), github);
var deploy = new AzurePipelinesDeployParameters(ado, github);
// le revisioni scritte dagli strumenti, come Add-RevNostra: un file per card, a sole aggiunte (lo smistatore gira in un altro processo)
void OwnRevision(int card, int rev)
{
    if (opts.DataDir is not { } dir) return;
    var folder = Path.Combine(dir, "rev-nostre");
    Directory.CreateDirectory(folder);
    File.AppendAllText(Path.Combine(folder, $"{card}.txt"), $"{rev}\n");
}
var cardTools = new CardTools(session, board, code, suite.Names, suite.Roles, suite.Areas, deploy, OwnRevision);
var memory = session.Role == "mentore" ? new PowerShellMemoryWriter(root, session.CardId) : null;
var tools = ToolCatalog.Build(cardTools, session, memory);

if (opts.List)
{
    foreach (var t in tools) Console.WriteLine(t.ProtocolTool.Name);
    return 0;
}

var builder = Host.CreateApplicationBuilder([]);
// stdout e il canale MCP: i log vanno su stderr, che claude scrive nel suo log
builder.Logging.ClearProviders();
builder.Logging.AddConsole(o => o.LogToStandardErrorThreshold = LogLevel.Trace);
builder.Logging.SetMinimumLevel(LogLevel.Warning);
builder.Services.AddMcpServer(o =>
    {
        o.ServerInfo = new() { Name = "devops-agents", Version = typeof(ToolCatalog).Assembly.GetName().Version?.ToString() ?? "1.0.0" };
        o.ServerInstructions = $"Gli attrezzi della card {session.CardId} per il ruolo {session.Role}" + (session.TaskId is { } t ? $" (task {t})" : "") +
            ": leggerla, commentarla e quello che il ruolo puo fare. Valgono solo per questa card. Al posto di card.ps1, che il brief nomina, usa questi strumenti.";
    })
    .WithStdioServerTransport()
    .WithTools(tools);
await builder.Build().RunAsync();
return 0;

internal sealed record Args(int? Card, string? Role, int? Task, string? Root, string? DataDir, bool List, string? Error)
{
    public static Args Parse(string[] a)
    {
        int? card = null, task = null; string? role = null, root = null, data = null; var list = false;
        for (var i = 0; i < a.Length; i++)
        {
            string Next() => i + 1 < a.Length ? a[++i] : throw new ArgumentException($"manca il valore di {a[i]}");
            try
            {
                switch (a[i])
                {
                    case "--card": card = int.TryParse(Next(), out var c) && c > 0 ? c : throw new ArgumentException("--card vuole l'id della card"); break;
                    case "--ruolo": role = Next(); break;
                    case "--task": task = int.TryParse(Next(), out var t) && t > 0 ? t : throw new ArgumentException("--task vuole l'id del task"); break;
                    case "--root": root = Next(); break;
                    case "--dati": data = Next(); break;
                    case "--elenca": list = true; break;
                    default: return new(null, null, null, null, null, false, $"argomento sconosciuto: {a[i]}");
                }
            }
            catch (ArgumentException e) { return new(null, null, null, null, null, false, e.Message); }
        }
        if (card is null || string.IsNullOrWhiteSpace(role)) return new(null, null, null, null, null, false, "mancano --card e --ruolo (li mette lo smistatore)");
        return new(card, role, task, root, data, list, null);
    }
}
