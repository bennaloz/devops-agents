using DevOpsAgents.Core.Configuration;
using DevOpsAgents.Core.Decisions;
using DevOpsAgents.Core.Model;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;
using K = DevOpsAgents.Core.Configuration.StateKeys;

namespace DevOpsAgents.Core.Tests;

/// <summary>D57 e D58: i casi di CosaFare.Tests.ps1 e l'apertura della PR con la descrizione salvata.</summary>
public class WhatToDoTests
{
    [Fact]
    public void Legge_le_tre_righe_in_testa_al_testo_con_o_senza_accento_elenco_e_grassetto()
    {
        var i = WhatToDo.FromText("**Per il titolare:** rilancia la validazione del gateway sulla PR 1146\n- Perché: il test e instabile, verde in locale\nPerche non gli agenti: dev non rilancia una build (D38)\n\nDiagnosi lunga...\nESITO=bloccato")!;
        Assert.Equal(("rilancia la validazione del gateway sulla PR 1146", "il test e instabile, verde in locale", "dev non rilancia una build (D38)", "agente"), (i.Action, i.Why, i.WhyNotAgents, i.Source));
        Assert.Equal("primo", WhatToDo.FromText("Per Titolare: primo\nPer il titolare: secondo")!.Action);
        Assert.Null(WhatToDo.FromText("Perche: qualcosa\nESITO=bloccato"));
        Assert.Null(WhatToDo.FromText(""));
    }

    [Fact]
    public void Le_righe_del_ruolo_si_completano_dal_predefinito_e_un_on_hold_dello_smistatore_le_ignora()
    {
        var i = WhatToDo.Resolve("Per il titolare: rilancia la validazione sulla PR 7", "dev chiede di nuovo di rilanciare la validazione: il test che fallisce va guardato da una persona", "limite", null);
        Assert.Equal(("agente", "rilancia la validazione sulla PR 7"), (i.Source, i.Action));
        Assert.Contains("seconda volta", i.Why);
        Assert.Contains("supervisore non rilancia le validazioni", i.WhyNotAgents);
        var s = WhatToDo.Resolve("Per il titolare: altro", "x", "sessione", "scritture");
        Assert.Equal("predefinita", s.Source);
        Assert.Contains("worktree", s.Action);
    }

    [Theory]
    [InlineData("m", "sessione", "fallita")]
    [InlineData("m", "sessione", "silenzio")]
    [InlineData("m", "sessione", "morta")]
    [InlineData("troppe validazioni rosse di fila", "limite", null)]
    [InlineData("m", "deploy", null)]
    [InlineData("m", null, null)]
    [InlineData("m", "sessione", null)]
    public void Ogni_caso_predefinito_ha_gesto_perche_e_perche_non_gli_agenti(string reason, string? per, string? cause)
    {
        var i = WhatToDo.Resolve("", reason, per, cause);
        Assert.Equal("predefinita", i.Source);
        Assert.False(string.IsNullOrEmpty(i.Action) || string.IsNullOrEmpty(i.Why) || string.IsNullOrEmpty(i.WhyNotAgents));
    }

    [Fact]
    public void I_passi_in_ordine_poi_perche_perche_non_gli_agenti_e_l_avviso_su_Draft_e_New()
    {
        var i = new Indications("rilancia la validazione sulla PR 1146", "test instabile", "D38", "agente");
        Assert.Equal([
            "1. rilancia la validazione sulla PR 1146",
            "2. Togli l'on-hold: i contatori ripartono da zero e lo smistatore riprende la card dallo stato in cui e.",
            "Perche: test instabile", "Perche non l'hanno fatto gli agenti: D38", WhatToDo.DraftWarning], WhatToDo.Lines(i, "limite"));
        Assert.StartsWith("**Cosa fare**\n\n1. rilancia", WhatToDo.Format(i, "deploy"));
        Assert.Contains("\n\n2. Togli l'on-hold: lo smistatore dimentica il run fallito", WhatToDo.Format(i, "deploy"));
        Assert.Contains("riparte l'agente", WhatToDo.EffectOfRemovingOnHold("sessione"));
        Assert.Contains("prossimo giro", WhatToDo.EffectOfRemovingOnHold(null));
    }

    [Fact]
    public void La_sessione_finita_per_ultima_la_senza_fine_conta_dall_inizio()
    {
        var s = new CardLocalState();
        s.LastSessionByRole["dev"] = Fx.Session("dev", "fatto", minutesAfterT0: 60);
        s.LastSessionByRole["responsabile"] = Fx.Session("responsabile", null, minutesAfterT0: 130, finished: false);
        Assert.Equal("responsabile", WhatToDo.LatestSession(s)!.Role);
        Assert.Null(WhatToDo.LatestSession(new CardLocalState()));
    }

    [Fact]
    public void La_descrizione_salvata_e_l_ultima_di_dev_o_responsabile_senza_la_firma()
    {
        Comment C(int id, string t) => new(id, "x", t, Fx.T0);
        Assert.Equal("Seconda\n\n| a | b |", WhatToDo.SavedPrDescription([
            C(1, "[dev] Descrizione della PR:\n\nPrima"),
            C(3, "<div>[responsabile] Descrizione della PR:</div><div>Seconda</div><div></div><div>| a | b |</div><div>— scritto da Claude (responsabile)</div>"),
            C(2, "[reviewer] Descrizione della PR:\nNo"),
        ]));
        Assert.Null(WhatToDo.SavedPrDescription([C(1, "ciao")]));
    }

    [Theory]
    [InlineData("feature/42-x", "Importare le stime", "feat: Importare le stime")]
    [InlineData("fix/7-y", "Crash", "fix: Crash")]
    [InlineData("feature/42-x", "fix(api): gia convenzionale", "fix(api): gia convenzionale")]
    [InlineData("altro", "Titolo", "Titolo")]
    public void Il_titolo_della_PR_segue_Conventional_Commits_dal_ramo(string branch, string title, string expected) =>
        Assert.Equal(expected, WhatToDo.PrTitle(branch, title));

    [Fact]
    public async Task L_on_hold_usa_il_gesto_scritto_dal_responsabile_e_la_dashboard_riceve_i_passi()
    {
        var w = new World();
        w.Add(42, K.InDevelopment);
        // il responsabile, chiamato da dev bloccato, non riesce a sbloccare la card e scrive il gesto per il titolare
        w.State[42] = new CardLocalState { Branch = "b", LastRole = "responsabile" };
        w.State[42].LastSessionByRole["dev"] = Fx.Session("dev", "bloccato", minutesAfterT0: 20);
        w.State[42].LastSessionByRole["responsabile"] = Fx.Session("responsabile", "bloccato", reason: "bloccato", minutesAfterT0: 40, text: "Per il titolare: dai accesso al database di prova\nPerche: manca il permesso\n\nDiagnosi...\nESITO=bloccato");
        var r = await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Contains(w.Writes, x => x.Contains("**Cosa fare**\n\n1. dai accesso al database di prova"));
        Assert.Equal("1. dai accesso al database di prova", r.Cards.Single().WhatToDo![0]);
    }

    [Fact]
    public async Task La_PR_si_apre_con_il_titolo_dal_ramo_e_sotto_il_link_la_descrizione_salvata()
    {
        var w = new World();
        w.Add(42, K.InDevelopment);
        w.Comments[42] = [new Comment(5, "x", "[dev] Descrizione della PR:\n\n## Misure\n- passo 1", Fx.T0)];
        w.State[42] = new CardLocalState { Branch = "feature/42-card", LastRole = "dev" };
        w.State[42].LastSessionByRole["dev"] = Fx.Session("dev", "fatto");
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Equal(("feat: Card 42", "[Card 42](https://board/42): Card 42\n\n## Misure\n- passo 1"), (w.LastPrTitle, w.LastPrDescription));
        w.Comments[42] = [new Comment(5, "x", "[dev] Descrizione della PR:\n\n" + new string('x', 5000), Fx.T0)];
        w.State[42].PrId = null; w.Prs.Clear();
        await w.Dispatcher().RunRoundAsync(whatIf: false);
        Assert.Equal("[Card 42](https://board/42): Card 42", w.LastPrDescription);
    }
}
