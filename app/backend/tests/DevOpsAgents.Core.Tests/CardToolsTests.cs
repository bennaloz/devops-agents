using DevOpsAgents.Core.Agents;
using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Model;
using DevOpsAgents.Core.Ports;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>Una board con una card sola (e la sua Feature), una PR e i parametri di deploy: registra ogni scrittura.</summary>
internal sealed class CardDesk : ICardEditor, ICodeHost, ICodeHostResolver, IPullRequestEditor, IDeployParameters
{
    public Dictionary<int, CardDetail> Cards { get; } = new();
    public Dictionary<int, List<Comment>> Comments { get; } = new();
    public List<TaskDetail> Tasks { get; } = [];
    public Dictionary<int, WorkItemInfo> Items { get; } = new();
    public Dictionary<int, List<Card>> Children { get; } = new();
    public int? LinkedPr { get; set; }
    public (string Status, string Branch)? Pr { get; set; }
    public string PrDescription { get; set; } = "[Card 7](https://board/7)\n\nvecchia";
    public List<string> Branches { get; } = [];
    public List<string> DeployParams { get; } = ["deployApi", "deployWeb"];
    public List<string> Writes { get; } = [];
    public int FailTaskAfter { get; set; } = int.MaxValue;
    private int _next = 500;

    public CardDesk Add(int id, string stateKey, string type = "User Story", int? parent = null, params string[] tags)
    {
        Cards[id] = new(new Card(id, 3, $"Card {id}", Fx.N(stateKey), tags, Fx.Area.Area, null, null, type, parent), "la descrizione", "i criteri");
        return this;
    }

    public Task<CardDetail> GetCardAsync(int id, CancellationToken ct = default) => Task.FromResult(Cards[id]);
    public Task<IReadOnlyList<Comment>> GetCommentsAsync(int id, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<Comment>>(Comments.GetValueOrDefault(id) ?? []);
    public Task<IReadOnlyList<TaskDetail>> GetTaskDetailsAsync(int id, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<TaskDetail>>(Tasks.OrderBy(t => t.Id).ToList());
    public Task<WorkItemInfo> GetWorkItemAsync(int id, CancellationToken ct = default) => Items.TryGetValue(id, out var w) ? Task.FromResult(w) : throw new HttpRequestException($"404 {id}");
    public Task<IReadOnlyList<Card>> GetFeatureChildrenAsync(int id, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<Card>>(Children.GetValueOrDefault(id) ?? []);
    public Task<int?> GetLinkedPullRequestIdAsync(int id, CancellationToken ct = default) => Task.FromResult(LinkedPr);
    public Task AddCommentAsync(int id, string md, CancellationToken ct = default) { Writes.Add($"commento {id} {md}"); return Task.CompletedTask; }
    public Task AddTagAsync(int id, string tag, CancellationToken ct = default) { Writes.Add($"tag {id} {tag}"); return Task.CompletedTask; }
    public Task<int> MoveAsync(int id, string state, CancellationToken ct = default) { Writes.Add($"stato {id} {state}"); return Task.FromResult(4); }
    public Task SetCriteriaAsync(int id, string md, CancellationToken ct = default) { Writes.Add($"criteri {id} {md}"); return Task.CompletedTask; }
    public Task<TaskDetail> CreateTaskAsync(int id, string title, string text, string area, CancellationToken ct = default)
    {
        if (Writes.Count(w => w.StartsWith("task ")) >= FailTaskAfter) throw new HttpRequestException("500");
        var t = new TaskDetail(_next++, title, "New", text);
        Writes.Add($"task {id} {title}");
        Tasks.Add(t);
        return Task.FromResult(t);
    }
    public Task SetTaskStateAsync(int id, string state, CancellationToken ct = default) { Writes.Add($"statoTask {id} {state}"); return Task.CompletedTask; }
    public string CardUrl(int id) => $"https://board/{id}";

    // ICodeHost (solo quello che usano gli strumenti)
    public ICodeHost For(AreaMapping area) => this;
    public bool NeedsCardLink => false;
    public Task<(string Status, string Branch)?> GetPullRequestByIdAsync(AreaMapping area, int prId, CancellationToken ct = default) => Task.FromResult(Pr);
    public Task<int> RequeueValidationsAsync(AreaMapping area, string branch, string destination, bool expiredOnly, CancellationToken ct = default) { Writes.Add($"rilancia {branch}"); return Task.FromResult(1); }
    public Task<IReadOnlyList<string>> ListBranchesAsync(AreaMapping area, string prefix, CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<string>>(Branches.Where(b => b.StartsWith(prefix, StringComparison.Ordinal)).ToList());
    public Task<PullRequestInfo?> GetPullRequestAsync(AreaMapping area, string branch, string destination, bool includeCompleted, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<(int Id, string Url)> CreatePullRequestAsync(AreaMapping area, string branch, string destination, string title, string description, int cardId, CancellationToken ct = default) => throw new NotSupportedException();
    public Task CompletePullRequestAsync(AreaMapping area, int prId, string? commit, CancellationToken ct = default) => throw new NotSupportedException();
    public string PullRequestUrl(AreaMapping area, int prId) => $"https://pr/{prId}";

    public Task<string> GetDescriptionAsync(AreaMapping area, int prId, CancellationToken ct = default) => Task.FromResult(PrDescription);
    public Task SetDescriptionAsync(AreaMapping area, int prId, string description, CancellationToken ct = default) { Writes.Add($"descrizionePr {prId} {description}"); return Task.CompletedTask; }
    public Task SetTitleAsync(AreaMapping area, int prId, string title, CancellationToken ct = default) { Writes.Add($"titoloPr {prId} {title}"); return Task.CompletedTask; }

    public string? DeployBranchRead { get; private set; }
    public Task<IReadOnlyList<string>> GetAsync(AreaMapping area, string branch, CancellationToken ct = default) { DeployBranchRead = branch; return Task.FromResult<IReadOnlyList<string>>(DeployParams); }
}

public class CardToolsTests
{
    private static readonly IReadOnlyDictionary<string, RoleSettings> Roles = new Dictionary<string, RoleSettings>
    {
        ["responsabile"] = new("opus", "", "ruoli/responsabile.md", [], null, [new(K.New, K.Ready), new(K.InDevelopment, K.NeedsClarification)]),
        ["dev"] = new("opus", "", "ruoli/dev.md", [], null, []),
        ["collaudatore"] = new("sonnet", "", "ruoli/collaudatore.md", []),
        ["mentore"] = new("sonnet", "", "ruoli/mentore.md", []),
    };

    private static (CardTools Tools, CardDesk Desk, List<(int, int)> Revs) Make(string role, string stateKey = K.New, int? task = null, AreaMapping? area = null, Action<CardDesk>? setup = null)
    {
        var desk = new CardDesk().Add(7, stateKey);
        setup?.Invoke(desk);
        var revs = new List<(int, int)>();
        var tools = new CardTools(new AgentSession(7, role, task), desk, desk, Fx.Names, Roles, [area ?? Fx.Area], desk, (c, r) => revs.Add((c, r)));
        return (tools, desk, revs);
    }

    private static string Sig(string role) => CardTools.Signature(role);

    [Fact]
    public void Ogni_ruolo_vede_solo_i_suoi_strumenti()
    {
        Assert.Equal(["leggi", "commenta", "sposta", "criteri", "crea-task", "senza-test", "prova-umana", "deploy", "correzione", "titolo-pr", "descrizione-pr"], Make("responsabile").Tools.Available());
        Assert.Equal(["leggi", "commenta", "titolo-pr", "descrizione-pr"], Make("dev").Tools.Available());
        Assert.Equal(["leggi", "commenta", "chiudi-task", "titolo-pr", "descrizione-pr"], Make("dev", task: 12).Tools.Available());
        Assert.Equal(["leggi", "commenta"], Make("collaudatore").Tools.Available());
    }

    [Fact]
    public async Task Il_commento_ha_prefisso_e_firma_una_volta_sola()
    {
        var (t, d, _) = Make("dev");
        Assert.Equal("Commento aggiunto.", await t.CommentAsync($"[dev] [dev] fatto\n\n{Sig("dev")}"));
        Assert.Equal($"commento 7 [dev] fatto\n\n{Sig("dev")}", Assert.Single(d.Writes));
        await Assert.ThrowsAsync<CardToolException>(() => t.CommentAsync("  "));
    }

    [Fact]
    public async Task Sposta_solo_lungo_le_transizioni_del_ruolo_e_ricorda_la_revisione()
    {
        var (t, d, revs) = Make("responsabile");
        Assert.Equal("Card spostata in 'pronto'.", await t.MoveAsync(K.Ready));
        Assert.Equal($"stato 7 {Fx.N(K.Ready)}", Assert.Single(d.Writes));
        Assert.Equal((7, 4), Assert.Single(revs));
        var e = await Assert.ThrowsAsync<CardToolException>(() => t.MoveAsync(K.ReadyToMerge));
        Assert.Contains("da 'nuova' a 'daUnire'", e.Message);
        Assert.Contains("non e una chiave", (await Assert.ThrowsAsync<CardToolException>(() => t.MoveAsync("tagAgenti"))).Message);
        Assert.Contains("non puo spostare", (await Assert.ThrowsAsync<CardToolException>(() => Make("dev").Tools.MoveAsync(K.Ready))).Message);
    }

    [Fact]
    public async Task I_criteri_li_scrive_solo_il_responsabile()
    {
        var (t, d, _) = Make("responsabile");
        await t.SetCriteriaAsync("- uno\n- due\n");
        Assert.Equal("criteri 7 - uno\n- due", Assert.Single(d.Writes));
        Assert.Contains("solo responsabile", (await Assert.ThrowsAsync<CardToolException>(() => Make("reviewer").Tools.SetCriteriaAsync("x"))).Message);
    }

    [Fact]
    public async Task I_task_si_creano_in_ordine_e_un_doppione_non_ne_crea_nessuno()
    {
        var (t, d, _) = Make("responsabile", setup: x => x.Tasks.Add(new(400, "Vecchio  Task", "Active", "")));
        Assert.Equal("Creati 2 task, nell'ordine: #500, #501.", await t.CreateTasksAsync("=== Primo\nfai uno\n=== Secondo\nfai due"));
        Assert.Equal(["task 7 Primo", "task 7 Secondo"], d.Writes);
        d.Writes.Clear();
        var e = await Assert.ThrowsAsync<CardToolException>(() => t.CreateTasksAsync("=== Terzo\nx\n=== vecchio task\ny"));
        Assert.Contains("'vecchio task' esiste gia come #400", e.Message);
        Assert.Contains("compare 2 volte", (await Assert.ThrowsAsync<CardToolException>(() => t.CreateTasksAsync("=== A\nx\n=== a\ny"))).Message);
        Assert.Contains("prima del primo titolo", (await Assert.ThrowsAsync<CardToolException>(() => t.CreateTasksAsync("ciao\n=== A\nx"))).Message);
        Assert.Contains("non ha testo", (await Assert.ThrowsAsync<CardToolException>(() => t.CreateTasksAsync("=== A\n\n=== B\ny"))).Message);
        Assert.Empty(d.Writes);
    }

    [Fact]
    public async Task Un_task_che_non_nasce_dice_quali_ci_sono_gia()
    {
        var (t, _, _) = Make("responsabile", setup: x => x.FailTaskAfter = 1);
        var e = await Assert.ThrowsAsync<CardToolException>(() => t.CreateTasksAsync("=== A\nx\n=== B\ny\n=== C\nz"));
        Assert.Contains("'B' non riuscita (gia creati: #500;", e.Message);
    }

    [Fact]
    public async Task Dev_chiude_solo_il_task_della_sessione()
    {
        var (t, d, _) = Make("dev", task: 12, setup: x => { x.Tasks.Add(new(12, "il mio", "Active", "")); x.Tasks.Add(new(13, "altro", "Closed", "")); });
        Assert.Contains("non e quello di questa sessione", (await Assert.ThrowsAsync<CardToolException>(() => t.CloseTaskAsync(13))).Message);
        Assert.Equal("Task 12 chiuso.", await t.CloseTaskAsync());
        Assert.Equal("statoTask 12 Closed", Assert.Single(d.Writes));
        Assert.Contains("non e di un task", (await Assert.ThrowsAsync<CardToolException>(() => Make("dev").Tools.CloseTaskAsync())).Message);
    }

    [Fact]
    public async Task Senza_test_e_prova_umana_mettono_il_tag_e_il_motivo()
    {
        var (t, d, _) = Make("responsabile");
        await t.NoTestAsync("solo documentazione");
        await t.HumanTestAsync("il colore lo giudica una persona");
        Assert.Equal(["tag 7 no-test-deploy", $"commento 7 [responsabile] Niente prova in Test (tag no-test-deploy): solo documentazione\n\n{Sig("responsabile")}",
            "tag 7 human-test", $"commento 7 [responsabile] Prova di una persona in Human test (tag human-test): il colore lo giudica una persona\n\n{Sig("responsabile")}"], d.Writes);
        await Assert.ThrowsAsync<CardToolException>(() => t.NoTestAsync(""));
    }

    [Fact]
    public async Task Il_deploy_controlla_i_nomi_sullo_YAML_del_ramo_della_card()
    {
        var (t, d, _) = Make("responsabile", setup: x => x.Branches.Add("feature/7-preventivi"));
        Assert.Equal("Deploy in Test: deployApi (parametri letti sul ramo feature/7-preventivi).", await t.DeployAsync(["deployApi, deployApi"], "tocca l'API"));
        Assert.Equal($"commento 7 [responsabile] {CardTools.DeployMark} deployApi\n\nPerche: tocca l'API\n\n{Sig("responsabile")}", Assert.Single(d.Writes));
        var e = await Assert.ThrowsAsync<CardToolException>(() => t.DeployAsync(["deployDb"], "x"));
        Assert.Contains("sconosciuto: deployDb. Sul ramo feature/7-preventivi la pipeline 115 ha questi parametri deploy*: deployApi, deployWeb", e.Message);
        // il commento scritto e la scelta che lo smistatore rilegge
        Assert.Equal(["deployApi"], CardTools.DeployChoice([new Comment(1, "x", d.Writes[0]["commento 7 ".Length..], Fx.T0)]));
    }

    [Fact]
    public async Task Il_deploy_senza_ramo_legge_develop_e_con_due_rami_si_ferma()
    {
        var (t, d, _) = Make("responsabile");
        await t.DeployAsync(["deployWeb"], "web");
        Assert.Equal("develop", d.DeployBranchRead);
        var (t2, _, _) = Make("responsabile", setup: x => x.Branches.AddRange(["feature/7-a", "fix/7-b", "feature/70-altro"]));
        Assert.Contains("piu di un ramo della card 7: feature/7-a, fix/7-b", (await Assert.ThrowsAsync<CardToolException>(() => t2.DeployAsync(["deployWeb"], "web"))).Message);
    }

    [Fact]
    public async Task Un_componente_con_l_ambiente_di_collaudo_non_ha_deploy_da_scegliere()
    {
        var (t, d, _) = Make("responsabile", area: Fx.Area with { TestEnvironment = Fx.Env });
        Assert.Equal(CardTools.NoDeployForTestEnvironment, await t.DeployAsync(["deployApi"], "x"));
        Assert.Empty(d.Writes);
        Assert.Contains(CardTools.NoDeployForTestEnvironment, await t.ReadAsync());
    }

    [Fact]
    public void I_parametri_deploy_si_leggono_dallo_YAML()
    {
        const string yaml = "﻿trigger: none\nparameters:\n  - name: deployApi # l'API\n    type: boolean\n    default: false\n  - name: 'deployWeb'\n    type: \"boolean\"\n  - name: ambiente\n    type: string\n  - name: Deployzero\n    type: boolean\n  -   name: deployAltro\n      type: boolean\nstages:\n  - name: deployFinto\n    type: boolean\n";
        Assert.Equal(["deployApi", "deployWeb", "deployAltro"], CardTools.DeployParametersFromYaml(yaml));
        Assert.Empty(CardTools.DeployParametersFromYaml("steps:\n  - script: echo"));
    }

    [Fact]
    public async Task La_correzione_vale_solo_sulla_card_di_chiusura()
    {
        var (t, d, _) = Make("responsabile", setup: x =>
        {
            x.Add(7, K.AutomatedTest, parent: 10, tags: ["collaudo-funzionalita"]);
            x.Items[10] = new(10, "Feature", "Active", "Preventivi", Fx.Area.Area, [7, 8]);
            x.Children[10] = [x.Cards[7].Card, new Card(8, 1, "Sorella", Fx.N(K.InFeatureBranch), [], Fx.Area.Area, WorkItemType: "User Story", ParentId: 10)];
        });
        Assert.Equal("Correzione tecnico scritta: 'Totale sbagliato'. Lo smistatore ne fa una Bug figlia della Feature.", await t.CorrectionAsync("tecnico", " Totale sbagliato ", "il totale non somma l'IVA"));
        Assert.Equal($"commento 7 [responsabile] Correzione: tecnico\nTitolo: Totale sbagliato\n\nil totale non somma l'IVA\n\n{Sig("responsabile")}", Assert.Single(d.Writes));
        await Assert.ThrowsAsync<CardToolException>(() => t.CorrectionAsync("boh", "a", "b"));
        Assert.Contains("solo sulla card di chiusura", (await Assert.ThrowsAsync<CardToolException>(() => Make("responsabile").Tools.CorrectionAsync("prodotto", "a", "b"))).Message);
    }

    [Fact]
    public async Task Il_deploy_della_card_di_chiusura_legge_il_ramo_della_funzionalita()
    {
        var (t, d, _) = Make("responsabile", setup: x =>
        {
            x.Add(7, K.DeployingToTest, parent: 10, tags: ["collaudo-funzionalita"]);
            x.Items[10] = new(10, "Feature", "Active", "Preventivi", Fx.Area.Area, [7]);
            x.Children[10] = [x.Cards[7].Card];
            x.Branches.AddRange(["feature/f10-preventivi", "feature/7-vecchio"]);
        });
        await t.DeployAsync(["deployApi"], "api");
        Assert.Equal("feature/f10-preventivi", d.DeployBranchRead);
    }

    [Fact]
    public async Task Leggi_mostra_card_funzionalita_task_e_ultimi_commenti()
    {
        var (t, _, _) = Make("dev", task: 12, setup: x =>
        {
            x.Add(8, K.InDevelopment, parent: 10, tags: ["agents"]);
            x.Cards[7] = x.Cards[8] with { Card = x.Cards[8].Card with { Id = 7 } };
            x.Items[10] = new(10, "Feature", "Active", "Preventivi", Fx.Area.Area, [7, 90]);
            x.Children[10] = [x.Cards[7].Card, new Card(90, 1, "Collaudo", Fx.N(K.New), ["collaudo-funzionalita"], Fx.Area.Area, WorkItemType: "User Story", ParentId: 10)];
            x.Tasks.Add(new(12, "il mio", "Active", "fai questo"));
            x.Comments[7] = Enumerable.Range(1, 12).Select(i => new Comment(i, "Titolare", $"commento {i}", Fx.T0)).ToList();
            x.Comments[7].Add(new Comment(0, "x", $"[responsabile] {CardTools.DeployMark} deployApi", Fx.T0));
        });
        var text = await t.ReadAsync();
        Assert.StartsWith("Card 7 - Card 8\nTipo: User Story | Stato: In development | Area: DevOps.Agents\\AI\\Stime\n\nTAG\nagents\n\nFUNZIONALITA\nFeature 10 [Active] Preventivi\ncard di chiusura: #90\nquesta card e una sorella\nsorelle (1):\n#7 [In development] Card 8 (agents)\n\nDESCRIZIONE\nla descrizione", text);
        Assert.Contains("DEPLOY IN TEST\ndeployApi\n", text);
        Assert.Contains("#12 [Active] il mio <- il tuo task\nfai questo", text);
        Assert.Contains("COMMENTI (ultimi 10, dal piu vecchio al piu nuovo)\n#3 Titolare", text);
        Assert.DoesNotContain("commento 2\n", text);
    }

    [Fact]
    public async Task Una_Feature_che_non_si_legge_non_ferma_la_lettura()
    {
        var (t, _, _) = Make("dev", setup: x => x.Add(7, K.InDevelopment, parent: 99));
        Assert.Contains("FUNZIONALITA\nla Feature 99 non si legge: 404 99", await t.ReadAsync());
    }

    [Fact]
    public async Task Il_titolo_della_PR_si_cambia_solo_con_una_PR_attiva_e_rilancia_le_validazioni()
    {
        var (t, d, _) = Make("dev");
        Assert.Contains("non ha una PR attiva", (await Assert.ThrowsAsync<CardToolException>(() => t.SetPrTitleAsync("nuovo"))).Message);
        d.LinkedPr = 33; d.Pr = ("active", "feature/7-x");
        Assert.Equal("Titolo della PR 33 cambiato in 'feat: nuovo'. Validazioni rilanciate: 1.", await t.SetPrTitleAsync(" feat: nuovo "));
        Assert.Equal(["titoloPr 33 feat: nuovo", "rilancia feature/7-x"], d.Writes);
        Assert.Contains("solo dev e responsabile", (await Assert.ThrowsAsync<CardToolException>(() => Make("reviewer").Tools.SetPrTitleAsync("x"))).Message);
    }

    [Fact]
    public async Task La_descrizione_senza_PR_si_salva_sulla_card_e_con_la_PR_tiene_il_link()
    {
        var (t, d, _) = Make("dev");
        Assert.StartsWith("La card 7 non ha ancora una PR: descrizione salvata sulla card (5 caratteri)", await t.SetPrDescriptionAsync(" testo "));
        Assert.Equal($"commento 7 [dev] {CardTools.PrDescriptionMark}\n\ntesto\n\n{Sig("dev")}", Assert.Single(d.Writes));
        d.Writes.Clear();
        d.LinkedPr = 33; d.Pr = ("active", "feature/7-x");
        Assert.StartsWith("Descrizione della PR 33 scritta", await t.SetPrDescriptionAsync("nuova"));
        Assert.Equal("descrizionePr 33 [Card 7](https://board/7)\n\nnuova", Assert.Single(d.Writes));
        Assert.Contains("Accorciala", (await Assert.ThrowsAsync<CardToolException>(() => t.SetPrDescriptionAsync(new string('x', CardTools.PrTextLimit)))).Message);
    }
}

public class AgentBriefTests
{
    private static readonly IReadOnlyDictionary<string, RoleSettings> Roles = new Dictionary<string, RoleSettings>
    {
        ["responsabile"] = new("opus", "", "b", [], null, [new(K.New, K.Ready)]),
        ["collaudatore"] = new("sonnet", "", "b", []),
        ["mentore"] = new("sonnet", "", "b", []),
    };

    [Fact]
    public void La_sezione_MCP_del_brief_elenca_solo_gli_strumenti_del_ruolo()
    {
        var c = AgentBrief.McpSection("collaudatore", null, Roles);
        Assert.Contains("| `card.ps1 leggi` | `mcp__agenti__card_leggi` | nessun parametro |", c);
        Assert.Contains("| `card.ps1 commenta` | `mcp__agenti__card_commenta` | il testo nel parametro `testo` |", c);
        Assert.DoesNotContain("sposta", c);
        Assert.Contains("`mcp__agenti__card_deploy` | i nomi nel parametro `parametri`", AgentBrief.McpSection("responsabile", null, Roles));
        Assert.Contains("| `memoria.ps1 scrivi` | `mcp__agenti__memoria_scrivi` |", AgentBrief.McpSection("mentore", null, Roles));
    }
}
