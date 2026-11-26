using System.ComponentModel;
using DevOpsAgents.Core.Agents;
using DevOpsAgents.Core.Ports;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace DevOpsAgents.Mcp;

/// <summary>
/// Gli strumenti MCP di una sessione: quelli di card.ps1 che il ruolo puo usare (CardTools.Available) e, per il mentore, quelli di
/// memoria.ps1. La card, il ruolo e il task sono fissati all'avvio del server: nessuno strumento li prende come argomento.
/// Un rifiuto torna all'agente come errore dello strumento, con il messaggio di card.ps1.
/// </summary>
public static class ToolCatalog
{
    /// <summary>Il nome MCP di un comando di card.ps1: crea-task diventa card_crea_task.</summary>
    public static string ToolName(string command) => "card_" + command.Replace('-', '_');

    public static IReadOnlyList<McpServerTool> Build(CardTools card, AgentSession session, IMemoryWriter? memory)
    {
        var tools = new List<McpServerTool>();
        void Add(string command, string description, Delegate handler, bool readOnly = false) =>
            tools.Add(McpServerTool.Create(handler, new McpServerToolCreateOptions { Name = ToolName(command), Description = description, ReadOnly = readOnly, Destructive = false }));

        foreach (var command in card.Available())
        {
            switch (command)
            {
                case "leggi":
                    Add(command, $"Legge la card {session.CardId}: tipo, stato, area, tag, la funzionalita (D52) se ne fa parte, descrizione, criteri, deploy in Test, task e gli ultimi commenti.",
                        (CancellationToken ct) => Run(() => card.ReadAsync(ct)), readOnly: true);
                    break;
                case "commenta":
                    Add(command, $"Scrive un commento sulla card {session.CardId}, in markdown. Il prefisso [{session.Role}] e la firma li mette lo strumento.",
                        ([Description("Il testo del commento, in markdown")] string testo, CancellationToken ct) => Run(() => card.CommentAsync(testo, ct)));
                    break;
                case "sposta":
                    Add(command, $"Sposta la card {session.CardId} in un altro stato, dato con la chiave di config/stati.json. Il ruolo {session.Role} puo fare solo questi spostamenti: " +
                        string.Join(", ", card.Transitions().Select(t => $"{t.From} -> {t.To}")) + ".",
                        ([Description("La chiave dello stato di arrivo (per esempio pronto, daChiarire)")] string stato, CancellationToken ct) => Run(() => card.MoveAsync(stato, ct)));
                    break;
                case "criteri":
                    Add(command, "Riscrive i criteri di accettazione della card, in markdown (tutti: il testo sostituisce quello di prima).",
                        ([Description("I criteri di accettazione completi, in markdown")] string testo, CancellationToken ct) => Run(() => card.SetCriteriaAsync(testo, ct)));
                    break;
                case "crea-task":
                    Add(command, "Crea i task figli della card, nell'ordine di esecuzione. Ogni task comincia con una riga '=== <titolo>' e sotto ha il testo: cosa fare e da cosa si vede che e fatto. Un doppione (stesso titolo) non ne crea nessuno.",
                        ([Description("I task: righe '=== <titolo>' e sotto il testo di ciascuno")] string testo, CancellationToken ct) => Run(() => card.CreateTasksAsync(testo, ct)));
                    break;
                case "chiudi-task":
                    Add(command, $"Chiude il task {session.TaskId} di questa sessione, quando e fatto.",
                        (CancellationToken ct) => Run(() => card.CloseTaskAsync(null, ct)));
                    break;
                case "senza-test":
                    Add(command, "Niente prova in Test per la card: aggiunge il tag e scrive il motivo. Dopo la revisione la card va dritta in Ready to merge.",
                        ([Description("Perche nessun criterio si verifica nell'ambiente di Test")] string motivo, CancellationToken ct) => Run(() => card.NoTestAsync(motivo, ct)));
                    break;
                case "prova-umana":
                    Add(command, "Una parte della card la prova una persona in Human test: aggiunge il tag human-test e scrive il motivo.",
                        ([Description("Quale criterio lo giudica una persona (colore, layout, un'impressione)")] string motivo, CancellationToken ct) => Run(() => card.HumanTestAsync(motivo, ct)));
                    break;
                case "deploy":
                    Add(command, "Sceglie i parametri del deploy in Test (D43): i booleani deploy* dello YAML della pipeline del componente, letti sul ramo della card. Un nome che lo YAML non ha si rifiuta. La scelta va in un commento sulla card: vale l'ultima.",
                        ([Description("I nomi dei parametri deploy* da accendere")] string[] parametri, [Description("Il perche: cosa della card tocca quei componenti")] string perche, CancellationToken ct) =>
                            Run(() => card.DeployAsync(parametri, perche, ct)));
                    break;
                case "correzione":
                    Add(command, "D52, solo sulla card di chiusura: scrive una correzione dopo un collaudo respinto o una CI rossa. Lo smistatore ne fa una Bug figlia della Feature, una per correzione.",
                        ([Description("tecnico: il comportamento atteso e gia nei criteri; prodotto: serve una scelta che spetta a una persona")] string natura,
                         [Description("Il titolo della correzione")] string titolo,
                         [Description("Cosa correggere e da cosa si vede che e corretto")] string descrizione, CancellationToken ct) =>
                            Run(() => card.CorrectionAsync(natura, titolo, descrizione, ct)));
                    break;
                case "titolo-pr":
                    Add(command, "Cambia il titolo della PR della card (l'unica che puoi toccare) e rilancia le validazioni rosse, perche il nuovo titolo conti.",
                        ([Description("Il titolo nuovo della PR")] string titolo, CancellationToken ct) => Run(() => card.SetPrTitleAsync(titolo, ct)));
                    break;
                case "descrizione-pr":
                    Add(command, $"Scrive la descrizione della PR della card, in markdown, sotto il link alla card che resta in testa (al massimo {CardTools.PrTextLimit} caratteri, link compreso). Senza PR il testo si salva sulla card e lo smistatore lo mette nella PR quando la apre.",
                        ([Description("La descrizione della PR, in markdown")] string testo, CancellationToken ct) => Run(() => card.SetPrDescriptionAsync(testo, ct)));
                    break;
            }
        }

        if (session.Role == "mentore" && memory is not null)
        {
            void Mem(string name, string description, Delegate handler, bool readOnly = false) =>
                tools.Add(McpServerTool.Create(handler, new McpServerToolCreateOptions { Name = name, Description = description, ReadOnly = readOnly, Destructive = false }));
            const string fields = "I quattro campi della lezione: la situazione in cui vale, cosa fare, perche, e la card da cui nasce.";
            Mem("memoria_leggi", "Le lezioni di un ruolo per un repo (comune.md e <repo>.md), stabili e in prova.",
                ([Description("Il ruolo (una chiave di config/ruoli.json)")] string ruolo, [Description("Il repo, come in config/mappa.json")] string repo, CancellationToken ct) =>
                    Run(() => memory.ReadAsync(ruolo, repo, ct), "memoria"), readOnly: true);
            Mem("memoria_scrivi", $"Scrive una lezione nuova nella memoria del ruolo, in prova nella PR della memoria. {fields}",
                ([Description("Il ruolo a cui va la lezione")] string ruolo, [Description("comune, o il repo di config/mappa.json")] string dove,
                 string situazione, string cosaFare, string perche, string card, CancellationToken ct) =>
                    Run(() => memory.WriteAsync(ruolo, dove, new LessonFields(situazione, cosaFare, perche, card), ct), "memoria"));
            Mem("memoria_rivedi", $"Riscrive una lezione esistente, con lo stesso id. {fields}",
                ([Description("L'id della lezione, <ruolo>-<NNN>")] string id, string situazione, string cosaFare, string perche, string card, CancellationToken ct) =>
                    Run(() => memory.ReviseAsync(id, new LessonFields(situazione, cosaFare, perche, card), ct), "memoria"));
            Mem("memoria_togli", "Toglie una lezione dalla memoria.",
                ([Description("L'id della lezione, <ruolo>-<NNN>")] string id, CancellationToken ct) => Run(() => memory.RemoveAsync(id, ct), "memoria"));
            Mem("memoria_conflitto", $"La correzione contraddice una regola scritta: nessuna lezione, una nota nella PR della memoria e un commento sulla card {session.CardId}.",
                ([Description("Quale regola scritta contraddice la correzione, e come")] string testo, CancellationToken ct) => Run(() => memory.ConflictAsync(session.CardId, testo, ct), "memoria"));
        }
        return tools;
    }

    /// <summary>Il risultato dello strumento come testo; un rifiuto o un errore della board come errore, con il suo messaggio.</summary>
    public static async Task<CallToolResult> Run(Func<Task<string>> action, string who = "card")
    {
        try
        {
            return new CallToolResult { Content = [new TextContentBlock { Text = await action() }] };
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            var message = e is CardToolException ? e.Message : $"{e.GetType().Name}: {e.Message}";
            return new CallToolResult { IsError = true, Content = [new TextContentBlock { Text = $"{who}: {message}" }] };
        }
    }
}
