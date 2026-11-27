using System.Text.Json.Nodes;
using DevOpsAgents.Core.Memory;
using DevOpsAgents.Core.Ports;
using Xunit;

namespace DevOpsAgents.Core.Tests;

/// <summary>I casi di tests/Memoria.Tests.ps1 sulle regole pure della memoria (D46).</summary>
public class MemoryRulesTests
{
    private static string L(string role, int n, string situation = "quando succede") =>
        MemoryRules.LessonText($"{role}-{n:000}", new LessonFields(situation, "fai cosi", "perche si", "42"));

    [Fact]
    public void Il_blocco_e_un_titolo_con_l_id_e_quattro_righe_e_si_rilegge_per_campi()
    {
        Assert.Equal("### dev-007\n- Situazione: s\n- Cosa fare: c\n- Perché: p\n- Card: 42", MemoryRules.LessonText("dev-007", new("s", "c", "p", "42")));
        var l = Assert.Single(MemoryRules.Read("intro\n\n" + L("dev", 7) + "\n\n### non-una-lezione\n- Situazione: x\n"));
        Assert.Equal(("dev-007", "dev", 7, "quando succede", "fai cosi", "perche si", "42"), (l.Id, l.Role, l.Number, l.Situation, l.WhatToDo, l.Why, l.Card));
        Assert.Empty(MemoryRules.Read(null));
    }

    [Fact]
    public void I_campi_vuoti_o_su_piu_righe_sono_errori_che_li_nominano()
    {
        Assert.Empty(MemoryRules.FieldErrors(new("a", "b", "c", "1")));
        Assert.Equal(["manca il campo 'situazione' o e vuoto", "il campo 'perche' va scritto su una riga sola"], MemoryRules.FieldErrors(new(" ", "b", "c\nd", "1")));
    }

    [Fact]
    public void Il_prossimo_id_e_il_massimo_del_ruolo_piu_uno_anche_con_buchi()
    {
        Assert.Equal("dev-001", MemoryRules.NextId("dev", [null]));
        Assert.Equal("dev-010", MemoryRules.NextId("dev", [L("dev", 2), L("dev", 9) + "\n\n" + L("reviewer", 30)]));
        Assert.Equal("dev-013", MemoryRules.NextId("dev", [MemoryRules.HistoricalHeadings("dev", "+### dev-012\n-### dev-004\n ### reviewer-099\n")]));
    }

    [Fact]
    public void Aggiunge_sostituisce_e_toglie_un_blocco_e_null_se_l_id_non_c_e()
    {
        var t = MemoryRules.Add(null, L("dev", 1));
        Assert.Equal(L("dev", 1) + "\n", t);
        t = MemoryRules.Add(t, L("dev", 2));
        Assert.Equal(L("dev", 1) + "\n\n" + L("dev", 2) + "\n", t);
        Assert.Contains("nuova", MemoryRules.Replace(t, "dev-001", L("dev", 1, "nuova")));
        Assert.Equal(L("dev", 2) + "\n", MemoryRules.Remove(t, "dev-001"));
        Assert.Null(MemoryRules.Replace(t, "dev-009", "x"));
        Assert.Equal("", MemoryRules.Remove(L("dev", 1), "dev-001"));
        Assert.False(MemoryRules.IsFull(string.Join("\n\n", Enumerable.Range(1, 24).Select(i => L("dev", i))), 25));
        Assert.True(MemoryRules.IsFull(string.Join("\n\n", Enumerable.Range(1, 25).Select(i => L("dev", i))), 25));
    }

    [Fact]
    public void In_prova_e_cio_che_develop_non_ha_identico_maiuscole_comprese()
    {
        var develop = L("dev", 1) + "\n\n" + L("dev", 2);
        var trial = L("dev", 1) + "\n\n" + L("dev", 2, "QUANDO SUCCEDE") + "\n\n" + L("dev", 3);
        Assert.Equal([false, true, true], MemoryRules.WithLabels(develop, trial).Select(l => l.InTrial));
        Assert.All(MemoryRules.WithLabels(develop, null), l => Assert.False(l.InTrial));
        Assert.StartsWith("### dev-001\n", MemoryRules.Text(MemoryRules.WithLabels(develop, trial)));
        Assert.Contains("### dev-003 (in prova)\n", MemoryRules.Text(MemoryRules.WithLabels(develop, trial)));
    }

    [Fact]
    public void La_descrizione_oltre_il_limite_omette_le_lezioni_piu_vecchie_e_tiene_le_note()
    {
        var lessons = Enumerable.Range(1, 20).SelectMany(i => MemoryRules.Read(L("dev", i, new string('x', 100)))).ToList();
        var d = MemoryRules.PrDescription(lessons, ["Card 4: la regola\n  dice altro", "Card 4: la regola dice altro"], null, 600);
        Assert.True(d.Length <= 600);
        Assert.Contains("- dev-020:", d);
        Assert.DoesNotContain("- dev-001:", d);
        Assert.Contains("non elencate: la descrizione ha un limite di 600 caratteri", d);
        Assert.Equal(["Card 4: la regola dice altro"], MemoryRules.ConflictNotes(d));
        Assert.Contains("Nessuna lezione in prova.", MemoryRules.PrDescription([], [], null, 4000));
        Assert.Empty(MemoryRules.ConflictNotes(MemoryRules.PrDescription([], [], null, 4000)));
    }

    private static JsonNode Row(string when, int card, string kind, string role, string? lesson = null, string? outcome = null) =>
        new JsonObject { ["data"] = when, ["card"] = card, ["tipo"] = kind, ["ruolo"] = role, ["lezione"] = lesson, ["esito"] = outcome };

    private static readonly DateTimeOffset Now = new(2026, 11, 25, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Il_riassunto_conta_per_ruolo_e_settimana_ISO()
    {
        var s = MemoryRules.Summarize([
            Row("2026-11-17T08:00:00Z", 5, "blocco", "dev"), Row("2026-11-18T08:00:00Z", 5, "blocco", "dev"), Row("2026-11-18T09:00:00Z", 6, "onHold", "dev"),
            Row("2026-11-19T09:00:00Z", 6, "correzione", "dev"), Row("2026-11-19T10:00:00Z", 7, "lezioneApplicata", "dev", "dev-001"),
            Row("2026-11-22T23:59:00Z", 1, "blocco", "reviewer"), Row("2026-11-23T00:01:00Z", 2, "blocco", "reviewer"),
            Row("rotta", 1, "blocco", "dev"), Row("2026-11-19T10:00:00Z", 1, "sconosciuto", "dev"), null], Now, null);
        var dev = Assert.Single(s.Rows, r => r.Role == "dev");
        Assert.Equal((2, 1, 1, 1, "2026-W47", "2026-11-16"), (dev.Blocks, dev.OnHold, dev.Corrections, dev.LessonsApplied, dev.Week, dev.Monday));
        Assert.Equal(["2026-W48", "2026-W47"], s.Rows.Where(r => r.Role == "reviewer").Select(r => r.Week));
        Assert.Equal("2026-W53", Assert.Single(MemoryRules.Summarize([Row("2027-01-03T10:00:00Z", 1, "blocco", "dev")], new(2027, 1, 5, 0, 0, 0, TimeSpan.Zero), null).Rows).Week);
    }

    [Fact]
    public void Una_lezione_ha_evitato_un_blocco_solo_alle_condizioni_di_Memoria_psm1()
    {
        var known = Enumerable.Range(1, 9).ToDictionary(i => $"dev-{i:000}", _ => 3);
        var s = MemoryRules.Summarize([
            Row("2026-11-18T08:00:00Z", 5, "lezioneApplicata", "dev", "dev-001", "finito"),
            Row("2026-11-18T08:00:00Z", 3, "lezioneApplicata", "dev", "dev-002", "finito"),
            Row("2026-11-18T08:00:00Z", 9, "lezioneApplicata", "dev", "dev-003", "bloccato"),
            Row("2026-11-18T08:00:00Z", 10, "lezioneApplicata", "dev", "dev-004", "bivio"),
            Row("2026-11-18T08:00:00Z", 11, "lezioneApplicata", "dev", "dev-005", "finito"), Row("2026-11-18T10:00:00Z", 11, "onHold", "dev"),
            Row("2026-11-18T08:00:00Z", 12, "lezioneApplicata", "dev", "dev-006", "finito"), Row("2026-11-18T10:00:00Z", 12, "blocco", "reviewer"),
            Row("2026-11-18T08:00:00Z", 13, "lezioneApplicata", "dev", "dev-007"), Row("2026-11-18T07:00:00Z", 13, "blocco", "dev"),
            Row("2026-11-18T08:00:00Z", 14, "lezioneApplicata", "dev", "dev-008", "finito"), Row("2026-11-18T10:00:00Z", 14, "correzione", "dev"),
            Row("2026-11-18T08:00:00Z", 15, "lezioneApplicata", "dev", "dev-009", "finito"), Row("2026-11-18T10:00:00Z", 15, "blocco", "dev")], Now, known);
        Assert.Equal(["dev-001", "dev-006", "dev-007"], s.Avoided.Select(a => a.Lesson));
        var lines = MemoryRules.SummaryLines(s);
        Assert.Equal("## Apprendimento (ultime 4 settimane intere piu quella in corso)", lines[0]);
        Assert.Contains("- dev-001 (dev): card 5", lines);
        var d = MemoryRules.PrDescription([], ["Card 1: nota"], s, 4000);
        Assert.Contains("## Apprendimento", d);
        Assert.True(MemoryRules.PrDescription([], ["Card 1: nota"], s, 200).Length <= 200);
    }
}
