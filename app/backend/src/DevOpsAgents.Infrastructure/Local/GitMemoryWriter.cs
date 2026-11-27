using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DevOpsAgents.Core.Agents;
using DevOpsAgents.Core.Memory;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;

namespace DevOpsAgents.Infrastructure.Local;

/// <summary>
/// Dove e come si scrive la memoria. Source: la copia principale degli attrezzi (un clone con origin); Worktree: il worktree fisso del ramo
/// memoria/in-prova; Area: il repo della PR della memoria (quello degli attrezzi); Roles e Repos: cosa ammettono ruolo e &lt;repo|comune&gt;.
/// </summary>
public sealed record MemoryWriterOptions(string Source, string Worktree, AreaMapping Area, IReadOnlyList<string> Roles, IReadOnlyList<string> Repos, int Cap,
    string? DataDir = null, int PrTextLimit = 0, int MutexWaitSeconds = 120);

/// <summary>
/// D46: la memoria dei ruoli scritta in .NET, come src/memoria.ps1: un worktree fisso registrato nella copia degli attrezzi, un lucchetto fra
/// processi (lo stesso nome del PowerShell: le due versioni non scrivono insieme), la base di scrittura (PR attiva: il ramo; ramo unito o chiuso:
/// develop con push --force-with-lease; commit che nessuna PR copre: il ramo), commit, push e PR con le lezioni in prova, le note di conflitto
/// e il riassunto dell'apprendimento. Un errore prima del push lancia e non lascia niente a meta; uno dopo (la PR) no: la lezione e pubblicata.
/// </summary>
public sealed class GitMemoryWriter(MemoryWriterOptions o, ICodeHost host, IPullRequestEditor prs, ICardEditor? board = null, int? sessionCard = null, string git = "git") : IMemoryWriter
{
    private string Branch => MemoryRules.TrialBranch;
    private string TrialRef => $"origin/{MemoryRules.TrialBranch}";
    private int Limit => o.PrTextLimit > 0 ? o.PrTextLimit : CardTools.PrTextLimit;

    // ---- controlli, prima di toccare git e la rete -------------------------------------------------------------------

    private void AssertRole(string role)
    {
        if (!o.Roles.Contains(role)) throw new CardToolException($"ruolo sconosciuto: '{role}' (i ruoli sono le chiavi di config/ruoli.json: {string.Join(", ", o.Roles)})");
    }

    /// <summary>&lt;repo|comune&gt; diventa il nome di un file: solo i repo della mappa (nome esatto) e comune, cosi niente esce dalla cartella del ruolo.</summary>
    private void AssertWhere(string name)
    {
        if (name != "comune" && !o.Repos.Contains(name, StringComparer.Ordinal))
            throw new CardToolException($"repo sconosciuto: '{name}' (comune o un repo di config/mappa.json: {string.Join(", ", o.Repos)})");
    }

    private static void AssertFields(LessonFields l)
    {
        var e = MemoryRules.FieldErrors(l);
        if (e.Count > 0) throw new CardToolException($"lezione rifiutata: {string.Join("; ", e)}");
    }

    private string RoleOf(string id)
    {
        var m = Regex.Match(id ?? "", @"^(.+)-\d+$");
        if (!m.Success) throw new CardToolException($"id di lezione non valido: '{id}' (la forma e <ruolo>-<NNN>)");
        AssertRole(m.Groups[1].Value);
        return m.Groups[1].Value;
    }

    private static LessonFields Trim(LessonFields l) => new(l.Situation.Trim(), l.WhatToDo.Trim(), l.Why.Trim(), l.Card.Trim());

    // ---- i comandi ---------------------------------------------------------------------------------------------------

    public Task<string> ReadAsync(string role, string repo, CancellationToken ct = default)
    {
        AssertRole(role); AssertWhere(repo);
        return Task.Run(() => Read(role, repo, ct), ct);
    }

    public Task<string> WriteAsync(string role, string where, LessonFields lesson, CancellationToken ct = default)
    {
        AssertRole(role); AssertWhere(where); AssertFields(lesson);
        var l = Trim(lesson);
        return SaveAsync(() =>
        {
            var path = FilePath(role, where);
            var text = ReadFile(path);
            if (MemoryRules.IsFull(text, o.Cap))
                throw new CardToolException($"{MemoryRules.PathOf(role, where)} ha gia {MemoryRules.Read(text).Count} lezioni (tetto {o.Cap}): consolida prima di aggiungere. " +
                    "Unisci i doppioni (rivedi e togli), e per le lezioni confermate piu volte proponi nella PR la promozione a regola " +
                    "(CLAUDE.md del repo o brief del ruolo) togliendole dalla memoria.");
            // un id non si riusa: conta tutta la storia (develop, ramo in prova, reflog), non solo i file di oggi
            var id = MemoryRules.NextId(role, [HistoricalHeadings(role)]);
            WriteFile(path, MemoryRules.Add(text, MemoryRules.LessonText(id, l)));
            return id;
        }, $"chore(memoria): lezione per {role} in {where} (card {l.Card})", null, "scritta", ct);
    }

    public Task<string> ReviseAsync(string id, LessonFields lesson, CancellationToken ct = default)
    {
        var role = RoleOf(id);
        AssertFields(lesson);
        var l = Trim(lesson);
        return SaveAsync(() =>
        {
            var file = FileOf(role, id) ?? throw new CardToolException($"non c'e nessuna lezione con id '{id}'");
            WriteFile(file, MemoryRules.Replace(ReadFile(file), id, MemoryRules.LessonText(id, l))!);
            return id;
        }, $"chore(memoria): rivede la lezione {id}", null, "rivista", ct);
    }

    public Task<string> RemoveAsync(string id, CancellationToken ct = default)
    {
        var role = RoleOf(id);
        return SaveAsync(() =>
        {
            var file = FileOf(role, id) ?? throw new CardToolException($"non c'e nessuna lezione con id '{id}'");
            WriteFile(file, MemoryRules.Remove(ReadFile(file), id)!);
            return id;
        }, $"chore(memoria): toglie la lezione {id}", null, "tolta", ct);
    }

    /// <summary>La correzione contraddice una regola scritta: nessuna lezione, una nota nella PR della memoria e un commento sulla card.</summary>
    public async Task<string> ConflictAsync(int cardId, string text, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new CardToolException("manca il testo del conflitto: quale regola scritta contraddice la correzione");
        // in una sessione di agente la card e quella della sessione: una sessione non commenta le card degli altri
        if (sessionCard is { } s && s != cardId) throw new CardToolException($"conflitto vale solo per la card della sessione ({s}), non per la {cardId}");
        var note = $"Card {cardId}: {string.Join(" ", Regex.Split(text.Trim(), @"\s*\r?\n\s*"))}";
        var (_, prError) = await Task.Factory.StartNew(() => Save(() => "", $"chore(memoria): nota di conflitto per la card {cardId}", note, ct), ct, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        // la nota vive solo nella PR: se non ci e arrivata si fallisce prima di commentare la card, e il tentativo dopo non fa doppioni
        if (prError is not null) throw new CardToolException($"la nota di conflitto non e nella PR della memoria: {prError}");
        if (board is not null) await board.AddCommentAsync(cardId, CardTools.CommentBody("mentore", text.Trim()), ct);
        return $"Nota aggiunta alla PR della memoria e commento sulla card {cardId}.";
    }

    // ---- la lettura: develop, e il ramo in prova solo con una PR attiva ------------------------------------------------

    private string Read(string role, string repo, CancellationToken ct)
    {
        var reasons = new List<string>();
        var sections = new List<string>();
        var fetch = Git(o.Source, true, "fetch", "--prune", "origin");
        if (fetch.Code != 0) reasons.Add($"fetch fallito, letti i riferimenti git che ci sono: {fetch.Output}");
        if (!RefExists(o.Source, "origin/develop")) reasons.Add($"origin/develop non si legge in {o.Source}: niente memoria");
        else
        {
            var trial = false;
            try
            {
                if (prs.ListPullRequestsAsync(o.Area, Branch, "develop", ct).GetAwaiter().GetResult().Any(p => p.Status == PrStatuses.Active))
                {
                    if (RefExists(o.Source, TrialRef)) trial = true;
                    else reasons.Add($"c'e una PR attiva ma {TrialRef} non si legge: solo develop");
                }
            }
            catch (Exception e) when (e is not OperationCanceledException) { reasons.Add($"le PR della memoria non si leggono, solo develop: {e.Message}"); }
            foreach (var name in new[] { "comune", repo }.Distinct())
            {
                var path = MemoryRules.PathOf(role, name);
                var lessons = MemoryRules.WithLabels(Show(o.Source, "origin/develop", path), trial ? Show(o.Source, TrialRef, path) : null);
                sections.Add($"## memoria di {role}, {name}:\n{(lessons.Count > 0 ? MemoryRules.Text(lessons).TrimEnd() : "(nessuna lezione)")}");
            }
        }
        if (sections.Count == 0) sections.Add("(memoria non disponibile)");
        return string.Join("\n\n", sections.Concat(reasons.Select(r => $"({r})")));
    }

    // ---- la scrittura: lucchetto, base, modifica, commit, push, PR -------------------------------------------------------

    private async Task<string> SaveAsync(Func<string> modify, string message, string? note, string verb, CancellationToken ct)
    {
        // il lucchetto e un mutex con nome: si prende e si lascia sullo stesso thread, quindi la scrittura gira su un thread suo
        var (id, prError) = await Task.Factory.StartNew(() => Save(modify, message, note, ct), ct, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        // con la PR non aggiornata la lezione e scritta lo stesso: il mentore non deve riprovare, creerebbe doppioni
        return prError is not null ? $"lezione {id} scritta; PR non aggiornata: {prError}" : $"Lezione {id} {verb}.";
    }

    /// <summary>Il nome del mutex di memoria.ps1 per lo stesso worktree: le due versioni si aspettano a vicenda.</summary>
    public static string MutexName(string worktree)
    {
        var key = Path.GetFullPath(worktree).Replace('\\', '/').TrimEnd('/').ToLowerInvariant();
        return "Global\\DevOps.Agents.Memoria-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key)))[..16].ToLowerInvariant();
    }

    private (string Id, string? PrError) Save(Func<string> modify, string message, string? note, CancellationToken ct)
    {
        using var mutex = new Mutex(false, MutexName(o.Worktree));
        bool taken;
        try { taken = mutex.WaitOne(TimeSpan.FromSeconds(o.MutexWaitSeconds)); }
        catch (AbandonedMutexException) { taken = true; } // il mentore precedente e morto a meta
        if (!taken) throw new CardToolException($"un'altra scrittura della memoria e in corso da piu di {o.MutexWaitSeconds} secondi: riprova fra poco");
        try
        {
            var (baseRef, force, active) = EnterBase(ct);
            var id = modify();
            Git(o.Worktree, false, "add", "-A");
            var changed = Git(o.Worktree, true, "diff", "--cached", "--quiet").Code != 0;
            if (changed) Git(o.Worktree, false, "commit", "-q", "-m", message);
            else if (note is not null) Git(o.Worktree, false, "commit", "-q", "--allow-empty", "-m", message);
            var refspec = $"{Branch}:{Branch}";
            if (force) Git(o.Worktree, false, "push", "-q", "--force-with-lease", "origin", refspec);
            else Git(o.Worktree, false, "push", "-q", "origin", refspec);

            string? prError = null;
            try
            {
                var notes = new List<string>();
                if (active is { } a) notes.AddRange(MemoryRules.ConflictNotes(prs.GetDescriptionAsync(o.Area, a, ct).GetAwaiter().GetResult()));
                if (note is not null) notes.Add(note);
                var description = MemoryRules.PrDescription(InTrialLessons(), notes, Summary(), Limit);
                if (active is { } pr) prs.SetDescriptionAsync(o.Area, pr, description, ct).GetAwaiter().GetResult();
                else host.CreatePullRequestAsync(o.Area, Branch, "develop", MemoryRules.PrTitle, description, 0, ct).GetAwaiter().GetResult();
            }
            catch (Exception e) when (e is not OperationCanceledException) { prError = string.Join(" ", Regex.Split(e.Message, @"\s*\r?\n\s*")); }
            return (id, prError);
        }
        finally { mutex.ReleaseMutex(); }
    }

    /// <summary>
    /// Prepara il worktree dalla base giusta (Get-BaseScrittura). Le lezioni di un ramo si buttano solo se qualcuno le ha chiuse: PR unita (la
    /// testa e in develop) o chiusa su quella testa. Se le PR non si leggono lancia, prima di toccare niente.
    /// </summary>
    private (string Base, bool Force, int? ActivePr) EnterBase(CancellationToken ct)
    {
        AssertWorktree();
        Git(o.Worktree, false, "fetch", "--prune", "origin");
        var list = prs.ListPullRequestsAsync(o.Area, Branch, "develop", ct).GetAwaiter().GetResult();
        int? active = list.Where(p => p.Status == PrStatuses.Active).Select(p => (int?)p.Id).FirstOrDefault();
        (string, bool, int?) choice;
        if (!RefExists(o.Worktree, TrialRef)) choice = ("origin/develop", false, active);
        else if (active is not null) choice = (TrialRef, false, active);
        else if (Git(o.Worktree, true, "merge-base", "--is-ancestor", TrialRef, "origin/develop").Code == 0) choice = ("origin/develop", true, null);
        else
        {
            var head = Git(o.Worktree, false, "rev-parse", TrialRef).Output;
            choice = list.Any(p => p.Status != PrStatuses.Active && p.HeadCommit == head) ? ("origin/develop", true, null) : (TrialRef, false, null);
        }
        // -f: un tentativo fallito prima potrebbe aver lasciato file modificati; la base buona e quella pubblicata
        Git(o.Worktree, false, "checkout", "-q", "-f", "--no-track", "-B", Branch, choice.Item1);
        Git(o.Worktree, false, "clean", "-fdq", "--", MemoryRules.Folder);
        return choice;
    }

    /// <summary>
    /// Il worktree fisso deve essere davvero un worktree registrato della copia degli attrezzi: una cartella qualunque allo stesso percorso non e
    /// nostra e non la si tocca. Se la cartella e sparita ma git la ricorda, si ripulisce con prune e si ricrea.
    /// </summary>
    private void AssertWorktree()
    {
        var registered = Registered();
        if (Directory.Exists(o.Worktree))
        {
            if (!registered) throw new CardToolException($"la cartella {o.Worktree} esiste ma non e un worktree registrato di {o.Source}: non la tocco");
            return;
        }
        if (registered) Git(o.Source, false, "worktree", "prune");
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(o.Worktree))!);
        Git(o.Source, false, "fetch", "origin");
        Git(o.Source, false, "worktree", "add", "-q", "--no-track", "-B", Branch, o.Worktree, "origin/develop");
    }

    private static string Comparable(string p) => Path.GetFullPath(p).Replace('\\', '/').TrimEnd('/').ToLowerInvariant();

    private bool Registered()
    {
        var want = Comparable(o.Worktree);
        return Git(o.Source, false, "worktree", "list", "--porcelain").Output.Split('\n').Skip(1)
            .Where(l => l.StartsWith("worktree ", StringComparison.Ordinal)).Any(l => Comparable(l[9..].TrimEnd('\r')) == want);
    }

    // ---- i file del worktree ---------------------------------------------------------------------------------------------

    private string FilePath(string role, string name) => Path.Combine(o.Worktree, MemoryRules.PathOf(role, name));

    private static string? ReadFile(string path) => File.Exists(path) ? File.ReadAllText(path, new UTF8Encoding(false)) : null;

    private static void WriteFile(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text, new UTF8Encoding(false));
    }

    /// <summary>La lezione puo stare in comune.md o in un &lt;repo&gt;.md: si cerca in tutti i file del ruolo.</summary>
    private string? FileOf(string role, string id)
    {
        var dir = Path.Combine(o.Worktree, MemoryRules.Folder, role);
        return Directory.Exists(dir) ? Directory.GetFiles(dir, "*.md").OrderBy(f => f, StringComparer.Ordinal).FirstOrDefault(f => MemoryRules.Read(ReadFile(f)).Any(l => l.Id == id)) : null;
    }

    private IEnumerable<string> MemoryFiles()
    {
        var root = Path.Combine(o.Worktree, MemoryRules.Folder);
        return Directory.Exists(root) ? Directory.GetFiles(root, "*.md", SearchOption.AllDirectories).OrderBy(f => f, StringComparer.Ordinal) : [];
    }

    /// <summary>Le lezioni del worktree che su develop non ci sono identiche: la parte in prova, che la descrizione della PR elenca.</summary>
    private IReadOnlyList<LessonEntry> InTrialLessons() =>
        MemoryFiles().SelectMany(f =>
        {
            var rel = Path.GetRelativePath(o.Worktree, f).Replace('\\', '/');
            return MemoryRules.WithLabels(Show(o.Worktree, "origin/develop", rel), ReadFile(f) ?? "").Where(l => l.InTrial);
        }).ToList();

    /// <summary>Il riassunto dell'apprendimento dal registro della cartella dati; registro assente o illeggibile: nessun riassunto, e la lezione si scrive lo stesso.</summary>
    private MemoryRules.LearningSummary? Summary()
    {
        try
        {
            if (o.DataDir is null) return null;
            var file = Path.Combine(o.DataDir, "registro-apprendimento.jsonl");
            if (!File.Exists(file)) return null;
            using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var sr = new StreamReader(fs, Encoding.UTF8);
            var rows = sr.ReadToEnd().Split('\n').Where(l => !string.IsNullOrWhiteSpace(l)).Select(l => { try { return JsonNode.Parse(l); } catch { return null; } });
            var known = MemoryRules.KnownOrigins(MemoryFiles().SelectMany(f => MemoryRules.Read(ReadFile(f))));
            return MemoryRules.Summarize(rows, DateTimeOffset.UtcNow, known);
        }
        catch { return null; }
    }

    // ---- git ---------------------------------------------------------------------------------------------------------

    /// <summary>Le intestazioni "### ruolo-NNN" di tutta la storia del ruolo: develop, il ramo in prova su origin e il reflog del ramo locale.</summary>
    private string HistoricalHeadings(string role)
    {
        var dir = $"{MemoryRules.Folder}/{role}";
        var log = new StringBuilder();
        var refs = new[] { "origin/develop", TrialRef }.Where(r => RefExists(o.Worktree, r)).ToArray();
        if (refs.Length > 0) log.AppendLine(Git(o.Worktree, true, ["log", "--format=", "-p", "--no-renames", .. refs, "--", dir]).Output);
        if (RefExists(o.Worktree, $"refs/heads/{Branch}"))
            log.AppendLine(Git(o.Worktree, true, "log", "-g", "--format=", "-p", "--no-renames", $"refs/heads/{Branch}", "--", dir).Output);
        return MemoryRules.HistoricalHeadings(role, log.ToString());
    }

    private bool RefExists(string dir, string r) => Git(dir, true, "rev-parse", "--verify", "--quiet", r).Code == 0;

    private string? Show(string dir, string r, string path)
    {
        var x = Git(dir, true, "show", $"{r}:{path}");
        return x.Code == 0 ? x.Output : null;
    }

    private (int Code, string Output) Git(string dir, bool allowError, params string[] args)
    {
        var psi = new ProcessStartInfo(git) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, StandardOutputEncoding = Encoding.UTF8 };
        psi.ArgumentList.Add("-C"); psi.ArgumentList.Add(dir);
        foreach (var a in args) psi.ArgumentList.Add(a);
        // nessun prompt di credenziali: una scrittura non deve restare appesa ad aspettare una persona
        psi.Environment["GIT_TERMINAL_PROMPT"] = "0";
        psi.Environment["GCM_INTERACTIVE"] = "never";
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("git non parte");
        var err = p.StandardError.ReadToEndAsync();
        var output = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        var all = (output + err.Result).Trim();
        if (p.ExitCode != 0 && !allowError) throw new InvalidOperationException($"git {string.Join(' ', args)} in {dir} e fallito: {all}");
        return (p.ExitCode, args[0] == "show" ? output : all);
    }
}
