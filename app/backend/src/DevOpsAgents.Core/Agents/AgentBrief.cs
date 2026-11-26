using System.Text;
using DevOpsAgents.Core.Configuration;

namespace DevOpsAgents.Core.Agents;

/// <summary>
/// La sezione del brief per una sessione con il server MCP degli agenti: i brief dei ruoli descrivono card.ps1 e memoria.ps1 (li usa anche lo
/// smistatore PowerShell), e questa sezione, in fondo, dice quale strumento prende il posto di ciascun comando. Un solo brief per le due versioni.
/// </summary>
public static class AgentBrief
{
    /// <summary>Il nome del server nella --mcp-config: gli strumenti arrivano all'agente come mcp__agenti__&lt;nome&gt;.</summary>
    public const string ServerName = "agenti";

    public static string ToolId(string tool) => $"mcp__{ServerName}__{tool}";

    private static readonly Dictionary<string, string> Notes = new()
    {
        ["commenta"] = "il testo nel parametro `testo`",
        ["criteri"] = "i criteri completi nel parametro `testo`",
        ["sposta"] = "la chiave dello stato nel parametro `stato`",
        ["crea-task"] = "le righe `=== <titolo>` e i testi nel parametro `testo`",
        ["senza-test"] = "il motivo nel parametro `motivo`",
        ["prova-umana"] = "il motivo nel parametro `motivo`",
        ["deploy"] = "i nomi nel parametro `parametri` (un elenco) e il perche in `perche`, invece delle due parti del testo",
        ["correzione"] = "natura, titolo e descrizione in tre parametri (`natura`, `titolo`, `descrizione`) invece del testo con `=== <titolo>`",
        ["titolo-pr"] = "il titolo nel parametro `titolo`",
        ["descrizione-pr"] = "il markdown nel parametro `testo`, senza file",
    };

    public static string McpSection(string role, int? taskId, IReadOnlyDictionary<string, RoleSettings> roles)
    {
        var commands = CardTools.AvailableFor(role, taskId, roles);
        var b = new StringBuilder();
        b.AppendLine();
        b.AppendLine("## Gli attrezzi della card in questa sessione");
        b.AppendLine();
        b.AppendLine("In questa sessione `card.ps1` non si usa: i suoi comandi sono strumenti MCP, gia legati a questa card e al tuo ruolo (la card non");
        b.AppendLine("si passa mai). Dove il brief scrive `card.ps1 <comando>`, usa lo strumento della tabella. Il testo va nei parametri dello");
        b.AppendLine("strumento: niente stdin, niente here-string, niente file temporanei. Gli strumenti che il tuo ruolo non ha non ci sono, e un");
        b.AppendLine("rifiuto torna come errore dello strumento con lo stesso messaggio di `card.ps1`.");
        b.AppendLine();
        b.AppendLine("| Nel brief | Strumento | Come |");
        b.AppendLine("| --- | --- | --- |");
        foreach (var c in commands)
            b.AppendLine($"| `card.ps1 {c}` | `{ToolId("card_" + c.Replace('-', '_'))}` | {Notes.GetValueOrDefault(c, "nessun parametro")} |");
        if (role == "mentore")
        {
            foreach (var (c, how) in new[] {
                ("leggi", "`ruolo` e `repo`"), ("scrivi", "`ruolo`, `dove` e i quattro campi della lezione come parametri, invece del JSON"),
                ("rivedi", "`id` e i quattro campi"), ("togli", "`id`"), ("conflitto", "il testo nel parametro `testo`; la card e questa") })
                b.AppendLine($"| `memoria.ps1 {c}` | `{ToolId("memoria_" + c)}` | {how} |");
        }
        return b.ToString();
    }
}
