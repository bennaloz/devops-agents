using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using DevOpsAgents.Core.Update;
using DevOpsAgents.Infrastructure.Configuration;

namespace DevOpsAgents.Infrastructure.Local;

/// <summary>
/// Root: la copia degli attrezzi che si aggiorna; DataDir: dove stanno impostazioni.json, aggiornamento.json e la richiesta; CheckMinutes e
/// WaitHours da supervisore.json (minutiControlloAggiornamenti, oreAttesaAggiornamento). BuildCommand: se l'avanzamento cambia app/, il comando
/// che verifica che la versione nuova compili (per esempio "dotnet build app/backend -c Release"); null per non costruire.
/// </summary>
public sealed record UpdaterOptions(string Root, string DataDir, int CheckMinutes = 30, double WaitHours = 6, string? BuildCommand = null,
    string ClaudeExecutable = "claude", int BuildTimeoutSeconds = 900);

/// <summary>
/// D53 in .NET: l'aggiornamento della copia degli attrezzi, come Invoke-AggiornamentoSuite. Le regole sono in UpdateRules; qui git, i requisiti,
/// la migrazione delle modifiche locali in impostazioni.json, l'avanzamento in fast-forward con lo smistatore fermo, la verifica (la
/// configurazione della versione nuova si legge, e se cambia app/ la versione nuova compila) e il ritorno indietro se la verifica non va.
/// Lo stato va in aggiornamento.json (stesse chiavi del PowerShell). I binari del servizio non si sostituiscono da soli: se app/ e cambiata lo
/// stato dice riavvioNecessario, e il servizio si riavvia (o si ripubblica) quando lo decide chi lo gestisce.
/// </summary>
public sealed class SuiteUpdater(UpdaterOptions o, Func<Occupancy> occupancy, Func<Func<Task<string?>>, Task<string?>> exclusive,
    Func<string, string, Task<bool>>? notify = null, string git = "git")
{
    public string StatePath => Path.Combine(o.DataDir, "aggiornamento.json");
    public string RequestPath => Path.Combine(o.DataDir, "aggiorna-suite.richiesta");
    private string SettingsPath => Path.Combine(o.DataDir, "impostazioni.json");

    /// <summary>"Aggiorna adesso": un file con l'ora, che il giro dopo legge e toglie quando ha un esito.</summary>
    public void Request()
    {
        Directory.CreateDirectory(o.DataDir);
        File.WriteAllText(RequestPath, DateTimeOffset.UtcNow.ToString("o"));
    }

    public JsonObject Status() => JsonFile.Read(StatePath) ?? new JsonObject();

    public async Task<JsonObject> RunAsync(DateTimeOffset now, bool whatIf = false, Action<string>? log = null, CancellationToken ct = default)
    {
        log ??= _ => { };
        var state = Status();
        var settings = JsonFile.Read(SettingsPath) ?? new JsonObject();
        var auto = settings["aggiornamentoAutomatico"] is JsonValue av && av.TryGetValue<bool>(out var ab) ? ab : true;
        var configured = settings["canale"] is JsonValue cv && cv.TryGetValue<string>(out var cs) ? cs : null;
        var local = Local();
        var channel = UpdateRules.Channel(configured, local.Branch);
        var requested = File.Exists(RequestPath);

        var lastCheck = JsonFile.Date(state["ultimoControllo"]);
        var checkError = state["erroreControllo"]?.GetValue<string>();
        if (UpdateRules.CheckDue(lastCheck, o.CheckMinutes, now, requested))
        {
            if (whatIf) log("aggiornamento: git fetch origin (controllo dovuto)");
            else
            {
                var f = Git(true, "fetch", "origin", "--quiet");
                lastCheck = now;
                checkError = f.Code == 0 ? null : $"git fetch origin e fallito: {f.Output}";
                if (checkError is not null) log($"aggiornamento: {checkError}");
            }
        }

        var tip = Tip(channel);
        var relation = UpdateRules.Relation(local.Head, tip?.Hash, tip is not null && Ancestor(local.Head, tip.Value.Hash), tip is not null && Ancestor(tip.Value.Hash, local.Head));
        var prs = new JsonArray();
        if (relation == "indietro")
        {
            var baseUrl = UpdateRules.PrBaseUrl(Git(true, "config", "--get", "remote.origin.url").Output);
            foreach (var p in UpdateRules.PrsFromLog(Git(false, "log", $"HEAD..refs/remotes/origin/{channel}", "--first-parent", "--format=%s").Output.Split('\n')))
                prs.Add(new JsonObject { ["numero"] = p.Number, ["titolo"] = p.Title, ["url"] = baseUrl is null ? null : $"{baseUrl}{p.Number}" });
        }
        string? localChannel = null;
        var localDiverges = false;
        if (tip is not null && local.Branch != channel)
        {
            var h = Git(true, "rev-parse", "--verify", "--quiet", $"refs/heads/{channel}^{{commit}}");
            if (h.Code == 0 && h.Output.Length > 0) { localChannel = h.Output; localDiverges = !Ancestor(localChannel, tip.Value.Hash); }
        }

        var discarded = state["scartato"]?.GetValue<string>();
        UpdateStep? step = null;
        string? error = null;
        try
        {
            step = UpdateRules.Step(new UpdateObservation(local.Head, tip?.Hash, discarded, auto, requested, relation, local.Modified,
                () => UpdateRules.Missing(RequirementsOf(channel), InstalledVersions()), occupancy, localDiverges));
        }
        catch (Exception e) { error = e.Message; log($"aggiornamento: {error}"); }

        var stamp = now.ToString("o");
        var previous = state["ultimoEsito"] as JsonObject;
        JsonObject outcome = new() { ["esito"] = "errore", ["quando"] = stamp, ["errore"] = error };
        var waitNotified = state["attesaSegnalata"] is JsonValue wv && wv.TryGetValue<bool>(out var wb) && wb;
        var restart = state["riavvioNecessario"] is JsonValue rv && rv.TryGetValue<bool>(out var rb) && rb;
        if (step is not null)
        {
            outcome = step.Outcome switch
            {
                "invariato" => previous?.DeepClone().AsObject() ?? new JsonObject { ["esito"] = "aggiornato", ["quando"] = stamp },
                "modificheLocali" => new JsonObject { ["esito"] = "modificheLocali", ["quando"] = stamp, ["file"] = Arr(step.Files!) },
                "requisitiMancanti" => new JsonObject
                {
                    ["esito"] = "requisitiMancanti", ["quando"] = stamp,
                    ["elenco"] = new JsonArray(step.Missing!.Select(m => (JsonNode)new JsonObject { ["nome"] = m.Name, ["richiesta"] = m.Required, ["trovata"] = m.Found }).ToArray()),
                },
                UpdateRules.WaitingForSessions => Waiting(previous, tip!.Value.Hash, step.Occupancy!, now),
                _ => new JsonObject { ["esito"] = step.Outcome, ["quando"] = stamp },
            };
            // gia aggiornato e gia detto: la data dell'esito e quella dell'aggiornamento, non dell'ultimo controllo
            if (step.Outcome == "aggiornato" && previous?["esito"]?.GetValue<string>() == "aggiornato") outcome = previous.DeepClone().AsObject();
        }

        var installed = Version(channel, local.Head, local.Date);
        JsonNode? available = tip is not null && relation != "uguale" ? Version(channel, tip.Value.Hash, tip.Value.Date) : null;
        if (step is { Advance: true })
        {
            if (whatIf)
                log($"aggiornamento: avanzerei {local.Branch} da {local.Head[..7]} a {tip!.Value.Hash[..7]} (canale {channel}){(step.Migrate ? $", migrando prima {string.Join(", ", step.Files!)} in impostazioni.json" : "")}, poi la verifica");
            else
            {
                var (o2, d2, appChanged) = await AdvanceAsync(channel, local, localChannel, tip!.Value, step, prs, now, log, ct);
                outcome = o2;
                if (d2 is not null) discarded = d2;
                if (outcome["esito"]?.GetValue<string>() == "aggiornato") { waitNotified = false; restart = restart || appChanged; prs = []; }
                local = Local();
                installed = Version(channel, local.Head, local.Date);
                var tip2 = Tip(channel);
                available = tip2 is not null && tip2.Value.Hash != local.Head ? Version(channel, tip2.Value.Hash, tip2.Value.Date) : null;
            }
        }
        else if (whatIf && step is not null) log($"aggiornamento: {step.Outcome}");

        if (!whatIf && outcome["esito"]?.GetValue<string>() == UpdateRules.WaitingForSessions && outcome["oltreSoglia"]?.GetValue<bool>() == true && !waitNotified && notify is not null)
            waitNotified = await notify("aggiornamenti", $"⏳ <b>Aggiornamento della suite in attesa</b>\nc'e una versione nuova ma da oltre {o.WaitHours} ore ci sono sessioni di agenti in corso: non forzo, aggiorno appena finiscono.");

        var result = new JsonObject
        {
            ["canale"] = channel, ["automatico"] = auto, ["installata"] = installed, ["disponibile"] = available,
            ["ultimoControllo"] = lastCheck?.ToString("o"), ["erroreControllo"] = checkError, ["ultimoEsito"] = outcome,
            ["scartato"] = discarded, ["attesaSegnalata"] = waitNotified, ["prInArrivo"] = prs, ["riavvioNecessario"] = restart,
        };
        if (!whatIf)
        {
            JsonFile.Write(StatePath, result);
            if (requested && outcome["esito"]?.GetValue<string>() != UpdateRules.WaitingForSessions) File.Delete(RequestPath);
        }
        return result;
    }

    private JsonObject Waiting(JsonObject? previous, string commit, Occupancy occ, DateTimeOffset now)
    {
        // l'attesa conta dal primo giro in cui c'e stata, finche il commit da installare e lo stesso
        var same = previous?["esito"]?.GetValue<string>() == UpdateRules.WaitingForSessions && previous["commit"]?.GetValue<string>() == commit;
        var since = same ? JsonFile.Date(previous!["da"]) ?? now : now;
        return new JsonObject
        {
            ["esito"] = UpdateRules.WaitingForSessions, ["quando"] = now.ToString("o"), ["da"] = since.ToString("o"), ["commit"] = commit,
            ["sessioni"] = occ.Sessions, ["processi"] = occ.Rounds, ["oltreSoglia"] = UpdateRules.WaitedTooLong(since, now, o.WaitHours),
        };
    }

    /// <summary>
    /// L'avanzamento vero, con lo smistatore fermo (exclusive): ricontrolla le sessioni, migra, avanza in fast-forward, verifica; se la verifica
    /// non va torna alla versione di prima. Restituisce l'esito, il commit scartato (se scartato) e se app/ e cambiata.
    /// </summary>
    private async Task<(JsonObject Outcome, string? Discarded, bool AppChanged)> AdvanceAsync(string channel, LocalCopy before, string? localChannel,
        (string Hash, DateTimeOffset? Date) tip, UpdateStep step, JsonArray prs, DateTimeOffset now, Action<string> log, CancellationToken ct)
    {
        var stamp = now.ToString("o");
        JsonObject? result = null;
        string? discarded = null;
        var appChanged = false;
        await exclusive(async () =>
        {
            var occ = occupancy();
            if (occ.Sessions > 0 || occ.Rounds > 0)
            {
                log("aggiornamento: nel frattempo e partita una sessione, aspetto");
                result = Waiting(null, tip.Hash, occ, now);
                return null;
            }
            if (step.Migrate)
            {
                try { Migrate(step.Files!); }
                catch (Exception e)
                {
                    log($"aggiornamento: migrazione delle modifiche locali non riuscita: {e.Message}");
                    result = new JsonObject { ["esito"] = "modificheLocali", ["quando"] = stamp, ["file"] = Arr(step.Files!), ["errore"] = e.Message };
                    return null;
                }
                log($"aggiornamento: le modifiche locali di {string.Join(", ", step.Files!)} sono in impostazioni.json, i file sono ripristinati");
            }
            string? error;
            try
            {
                if (before.Branch == channel) Git(false, "merge", "--ff-only", $"refs/remotes/origin/{channel}");
                else Git(false, "checkout", "-B", channel, $"refs/remotes/origin/{channel}");
                appChanged = Git(false, "diff", "--name-only", before.Head, "HEAD", "--", "app").Output.Length > 0;
                error = await VerifyAsync(appChanged, ct);
            }
            catch (Exception e) { error = e.Message; }
            if (error is null) return null;

            var headNow = Git(true, "rev-parse", "HEAD").Output;
            var branchNow = Git(true, "rev-parse", "--abbrev-ref", "HEAD").Output;
            if (headNow != before.Head || branchNow != before.Branch)
            {
                try { Restore(before, channel, localChannel); }
                catch (Exception e)
                {
                    // la copia non e tornata: non e verificata e non e quella di prima. Mai "aggiornato": errore, con dove e rimasta, e un avviso urgente
                    var at = Git(true, "rev-parse", "HEAD").Output;
                    var msg = $"il ritorno alla versione di prima non e riuscito ({e.Message}); copia lasciata a {at}, dopo l'errore: {error}";
                    log($"aggiornamento: {msg}");
                    if (notify is not null) await notify("urgenti", $"🚨 <b>Aggiornamento della suite: la copia e rimasta a meta</b>\n{System.Net.WebUtility.HtmlEncode(msg)}");
                    result = new JsonObject { ["esito"] = "errore", ["quando"] = stamp, ["errore"] = msg, ["copiaLasciataA"] = at, ["commitScartato"] = tip.Hash };
                    discarded = tip.Hash;
                    return null;
                }
            }
            appChanged = false;
            log($"aggiornamento a {tip.Hash[..7]} fallito, tornato a {before.Head[..7]}: {error}");
            if (notify is not null) await notify("aggiornamenti", $"⚠️ <b>Aggiornamento della suite fallito, tornato alla versione di prima</b>\ncommit scartato: {tip.Hash[..7]}\n{System.Net.WebUtility.HtmlEncode(error)}");
            result = new JsonObject { ["esito"] = "fallitoTornatoIndietro", ["quando"] = stamp, ["errore"] = error, ["commitScartato"] = tip.Hash };
            discarded = tip.Hash;
            return null;
        });
        if (result is not null) return (result, discarded, false);
        log($"aggiornamento: {before.Head[..7]} -> {tip.Hash[..7]} (canale {channel}), {prs.Count} PR{(appChanged ? ", app/ cambiata: serve un riavvio del servizio" : "")}");
        if (notify is not null)
        {
            var lines = new List<string> { $"🔄 <b>Suite aggiornata</b>: {UpdateRules.FormatVersion(channel, before.Head[..7], before.Date)} → {UpdateRules.FormatVersion(channel, tip.Hash[..7], tip.Date)}" };
            lines.AddRange(prs.Select(p => $"PR {p!["numero"]}: {System.Net.WebUtility.HtmlEncode(p["titolo"]?.GetValue<string>() ?? "")}"));
            if (appChanged) lines.Add("il servizio .NET e cambiato: va riavviato per usarlo");
            await notify("aggiornamenti", string.Join("\n", lines));
        }
        return (new JsonObject { ["esito"] = "aggiornato", ["quando"] = stamp, ["da"] = before.Head[..7], ["a"] = tip.Hash[..7] }, null, appChanged);
    }

    /// <summary>La verifica della versione appena avanzata: la configurazione si legge e, se app/ e cambiata, la versione nuova compila.</summary>
    private async Task<string?> VerifyAsync(bool appChanged, CancellationToken ct)
    {
        try
        {
            SuiteConfig.Load(o.Root);
            SuiteConfig.LoadSupervisor(o.Root);
        }
        catch (Exception e) { return $"la configurazione della versione nuova non si legge: {e.Message}"; }
        if (!appChanged || string.IsNullOrWhiteSpace(o.BuildCommand)) return null;
        var parts = o.BuildCommand.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var (code, output, timeout) = await RunAsync(parts[0], parts[1..], o.BuildTimeoutSeconds, ct);
        if (timeout) return $"la costruzione della versione nuova non e finita entro {o.BuildTimeoutSeconds} secondi";
        return code == 0 ? null : $"la versione nuova non compila ({o.BuildCommand}, codice {code}): {Tail(output)}";
    }

    /// <summary>
    /// Le modifiche locali dei file di config migrabili: le chiavi di primo livello diverse da HEAD vanno in impostazioni.json (senza sovrascrivere un
    /// override che c'e), poi il file torna com'e in HEAD. La migrazione e definitiva: una versione a cui si torna legge gia impostazioni.json.
    /// </summary>
    private void Migrate(IReadOnlyList<string> files)
    {
        var settings = JsonFile.Read(SettingsPath) ?? new JsonObject();
        foreach (var f in files)
        {
            var section = UpdateRules.MigratableFiles[f];
            JsonObject current;
            try { current = JsonNode.Parse(File.ReadAllText(Path.Combine(o.Root, f)))!.AsObject(); }
            catch (Exception e) { throw new InvalidOperationException($"{f} ha modifiche locali che non sono un JSON valido ({e.Message}): non le migro"); }
            var committed = JsonNode.Parse(Git(false, "show", $"HEAD:{f}").Output)!.AsObject();
            settings[section] = UpdateRules.MigrateOverrides(committed, current, settings[section] as JsonObject);
        }
        JsonFile.Write(SettingsPath, settings);
        foreach (var f in files) Git(false, "checkout", "--", f);
    }

    /// <summary>Riporta la copia com'era: sullo stesso ramo reset --keep, altrimenti il ramo (o il commit) di prima e il ramo del canale dov'era.</summary>
    private void Restore(LocalCopy before, string channel, string? localChannel)
    {
        if (before.Branch == channel) { Git(false, "reset", "--keep", before.Head); return; }
        if (before.Branch == "HEAD") Git(false, "checkout", "--detach", before.Head);
        else Git(false, "checkout", before.Branch);
        if (localChannel is not null) Git(false, "branch", "-f", channel, localChannel);
        else if (Git(true, "rev-parse", "--verify", "--quiet", $"refs/heads/{channel}").Code == 0) Git(false, "branch", "-D", channel);
    }

    // ---- git e processi ----------------------------------------------------------------------------------------------

    private sealed record LocalCopy(string Branch, string Head, DateTimeOffset? Date, IReadOnlyList<string> Modified);

    private LocalCopy Local()
    {
        var status = Git(true, "status", "--porcelain");
        if (status.Code != 0) throw new InvalidOperationException($"git status in {o.Root} e fallito: {status.Output}");
        return new(Git(false, "rev-parse", "--abbrev-ref", "HEAD").Output, Git(false, "rev-parse", "HEAD").Output,
            ParseDate(Git(false, "log", "-1", "--format=%cI", "HEAD").Output), UpdateRules.ModifiedFiles(status.RawOutput));
    }

    private (string Hash, DateTimeOffset? Date)? Tip(string channel)
    {
        var h = Git(true, "rev-parse", "--verify", "--quiet", $"refs/remotes/origin/{channel}^{{commit}}");
        if (h.Code != 0 || h.Output.Length == 0) return null;
        return (h.Output, ParseDate(Git(false, "log", "-1", "--format=%cI", $"refs/remotes/origin/{channel}").Output));
    }

    private bool Ancestor(string a, string b) => Git(true, "merge-base", "--is-ancestor", a, b).Code == 0;

    /// <summary>I requisiti della versione nuova, letti dal commit di origine senza estrarlo; null se il file non c'e.</summary>
    private JsonObject? RequirementsOf(string channel)
    {
        var r = Git(true, "show", $"refs/remotes/origin/{channel}:config/requisiti.json");
        if (r.Code != 0) return null;
        try { return JsonNode.Parse(r.RawOutput)?.AsObject(); }
        catch (Exception e) { throw new InvalidOperationException($"config/requisiti.json di origin/{channel} non e un JSON valido: {e.Message}"); }
    }

    /// <summary>
    /// Le versioni installate dei programmi che i requisiti possono chiedere. claude e dotnet sempre; powershell solo se c'e (la versione .NET
    /// non ne ha bisogno: assente, il suo requisito non blocca).
    /// </summary>
    private IReadOnlyDictionary<string, string?> InstalledVersions()
    {
        string? First(string exe, params string[] args)
        {
            try { var (code, output, _) = RunAsync(exe, args, 30, CancellationToken.None).GetAwaiter().GetResult(); return code == 0 ? output.Split('\n').FirstOrDefault(l => l.Trim().Length > 0)?.Trim() : null; }
            catch { return null; }
        }
        var v = new Dictionary<string, string?> { ["claude"] = First(o.ClaudeExecutable, "--version"), ["dotnet"] = First("dotnet", "--version") };
        if (First("pwsh", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()") is { } ps) v["powershell"] = ps;
        return v;
    }

    private static DateTimeOffset? ParseDate(string s) => DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d) ? d : null;

    private static JsonObject Version(string channel, string hash, DateTimeOffset? date) =>
        new() { ["canale"] = channel, ["hash"] = hash.Length >= 7 ? hash[..7] : hash, ["data"] = date?.ToString("o") };

    private static JsonArray Arr(IEnumerable<string> items) => new(items.Select(x => (JsonNode)JsonValue.Create(x)!).ToArray());

    private static string Tail(string s) => s.Length > 800 ? "..." + s[^800..] : s;

    private (int Code, string Output, string RawOutput) Git(bool allowError, params string[] args)
    {
        var psi = new ProcessStartInfo(git) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, StandardOutputEncoding = Encoding.UTF8 };
        psi.ArgumentList.Add("-C"); psi.ArgumentList.Add(o.Root);
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["GIT_TERMINAL_PROMPT"] = "0";
        psi.Environment["GCM_INTERACTIVE"] = "never";
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("git non parte");
        var err = p.StandardError.ReadToEndAsync();
        var output = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        var all = (output + err.Result).Trim();
        if (p.ExitCode != 0 && !allowError) throw new InvalidOperationException($"git {string.Join(' ', args)} in {o.Root} e fallito: {all}");
        return (p.ExitCode, p.ExitCode == 0 ? output.Trim() : all, output);
    }

    private async Task<(int Code, string Output, bool Timeout)> RunAsync(string exe, string[] args, int timeoutSeconds, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(exe) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, WorkingDirectory = o.Root };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi) ?? throw new InvalidOperationException($"{exe} non parte");
        var output = p.StandardOutput.ReadToEndAsync(ct);
        var error = p.StandardError.ReadToEndAsync(ct);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        try { await p.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            return (-1, "", true);
        }
        return (p.ExitCode, (await output) + (await error), false);
    }
}
