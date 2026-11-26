Set-StrictMode -Version Latest

# Avvisi in uscita su Telegram. Nessun modello. Il file del bot si legge dentro la funzione che fa la chiamata e il suo
# contenuto non si stampa, non va in un argomento di riga di comando, non finisce in un log o in un'eccezione: l'API
# vuole il valore nell'indirizzo, e i messaggi d'errore di Invoke-RestMethod possono citare l'indirizzo.

Import-Module (Join-Path $PSScriptRoot 'Comune.psm1') -Global
Import-Module (Join-Path $PSScriptRoot 'Stato.psm1') -Global

$script:ApiBase = 'https://api.telegram.org'
$script:TimeoutSec = 15
$script:AnteprimaMax = 300

function Get-TelegramPercorsoTokenPredefinito {
    Join-Path $HOME '.claude/telegram-token.txt'
}

function Get-TelegramPercorsoChatPredefinito([string]$CartellaDati) {
    if (-not $CartellaDati) { $CartellaDati = Get-CartellaDati }
    Join-Path $CartellaDati 'telegram-chat.txt'
}

function Read-FileNonVuoto([string]$Percorso) {
    if (-not (Test-Path -LiteralPath $Percorso -PathType Leaf)) { return $null }
    $t = ([IO.File]::ReadAllText($Percorso)).Trim()
    if ($t -eq '') { return $null }
    $t
}

# Configurato = esistono e non sono vuoti il file del bot e quello dell'id della chat.
function Test-TelegramConfigurato {
    [CmdletBinding()]
    param([string]$CartellaDati, [Alias('PercorsoToken')][string]$FileBot = (Get-TelegramPercorsoTokenPredefinito))
    $null -ne (Read-FileNonVuoto $FileBot) -and $null -ne (Read-FileNonVuoto (Get-TelegramPercorsoChatPredefinito $CartellaDati))
}

# Dall'anteprima escono il codice e i tag: i messaggi lasciano la rete aziendale e non devono portare codice ne dati di
# clienti. Si toglie prima il codice (recintato, poi in linea), poi i tag, poi si decodificano le entita.
function ConvertTo-AnteprimaTelegram {
    [CmdletBinding()]
    param([AllowNull()][string]$Testo, [int]$Max = $script:AnteprimaMax)
    if ([string]::IsNullOrWhiteSpace($Testo)) { return '' }
    $t = $Testo
    $t = [regex]::Replace($t, '(?s)(`{3}|~{3}).*?(\1|\z)', ' ')
    $t = [regex]::Replace($t, '(?is)<pre\b.*?(</pre\s*>|\z)', ' ')
    $t = [regex]::Replace($t, '(?is)<code\b.*?(</code\s*>|\z)', ' ')
    $t = [regex]::Replace($t, '`[^`]*`', ' ')
    # i tag di blocco separano le parole, quelli in linea (b, i, a, span) no
    $t = [regex]::Replace($t, '(?i)</?(?:p|div|br|li|ul|ol|tr|td|th|table|h[1-6]|blockquote|hr)\b[^>]*>', ' ')
    $t = [regex]::Replace($t, '<[^>]*>', '')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = [regex]::Replace($t, '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 1).TrimEnd() + [char]0x2026 }
    $t
}

# Testo semplice, senza parse_mode.
function Format-MessaggioTelegram {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Titolo, [string]$Testo, [Parameter(Mandatory)][string]$Url)
    $righe = [System.Collections.Generic.List[string]]::new()
    $righe.Add(([regex]::Replace($Titolo, '\s+', ' ')).Trim())
    $anteprima = ConvertTo-AnteprimaTelegram -Testo $Testo
    if ($anteprima) { $righe.Add(''); $righe.Add($anteprima) }
    $righe.Add(''); $righe.Add($Url)
    $righe -join "`n"
}

function Hide-Valore([string]$Testo, [string]$Valore) {
    if ([string]::IsNullOrEmpty($Testo)) { return $Testo }
    if ($Valore) {
        foreach ($v in @($Valore, [uri]::EscapeDataString($Valore), [uri]::EscapeUriString($Valore), [Net.WebUtility]::UrlEncode($Valore))) {
            if ($v) { $Testo = $Testo.Replace($v, '***') }
        }
    }
    # in ogni caso, qualunque cosa che abbia la forma di un valore del bot dentro un indirizzo
    [regex]::Replace($Testo, 'bot\d+(?::|%3A)[^\s/"''<>]+', 'bot***', 'IgnoreCase')
}

# La sola funzione che parla con la rete: i test la sostituiscono. Un errore esce riscritto senza il valore segreto.
function Invoke-TelegramApi {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Metodo, [Parameter(Mandatory)]$Corpo)
    $chiamata = @{
        Method = 'Post'; Uri = "$script:ApiBase/bot$Token/$Metodo"; TimeoutSec = $script:TimeoutSec
        ContentType = 'application/json; charset=utf-8'
        Body = [Text.Encoding]::UTF8.GetBytes(($Corpo | ConvertTo-Json -Compress -Depth 5))
    }
    $messaggio = $null
    # -Verbose e -Debug esplicitamente spenti: il flusso verbose di Invoke-RestMethod stampa "POST <indirizzo>", e
    # l'indirizzo porta il valore del bot (vale anche con $VerbosePreference globale o -Verbose sullo smistatore).
    try { return Invoke-RestMethod @chiamata -Verbose:$false -Debug:$false }
    catch {
        $msg = [string]$_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $d = [string]$_.ErrorDetails.Message
            if ($d.Length -gt 300) { $d = $d.Substring(0, 300) + '...' }
            $msg = "$msg - $d"
        }
        $messaggio = Hide-Valore $msg $Token
    }
    # Fuori dal catch: l'eccezione nuova non porta con se l'errore originale (e il suo indirizzo).
    throw "Invio a Telegram fallito (metodo $Metodo): $messaggio"
}

# $true se il messaggio e partito, $false se Telegram non e configurato (non e un errore).
function Send-TelegramAvviso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Titolo, [string]$Testo, [Parameter(Mandatory)][string]$Url,
        [string]$CartellaDati, [Alias('PercorsoToken')][string]$FileBot = (Get-TelegramPercorsoTokenPredefinito)
    )
    $bot = Read-FileNonVuoto $FileBot
    $chat = Read-FileNonVuoto (Get-TelegramPercorsoChatPredefinito $CartellaDati)
    if ($null -eq $bot -or $null -eq $chat) { return $false }
    $errore = $null
    try {
        [void](Invoke-TelegramApi -Token $bot -Metodo 'sendMessage' -Corpo @{
            chat_id = $chat; text = (Format-MessaggioTelegram -Titolo $Titolo -Testo $Testo -Url $Url)
        })
    }
    catch { $errore = Hide-Valore ([string]$_.Exception.Message) $bot }
    if ($errore) { throw $errore }
    $true
}


# ---- i topic del gruppo (D51) --------------------------------------------------------------------------------------
# La chat e un gruppo con i topic: un topic per tipo di notifica, creato dal bot (createForumTopic). Gli id stanno in
# telegram-topic.json nella cartella dati (non segreto): nome logico -> message_thread_id, piu l'ultimo tentativo di creazione
# fallito (si riprova solo dopo un'ora) e se la voce "dai al bot il permesso" e gia stata detta.

$script:NomiTopic = [ordered]@{ urgenti = 'Urgenti'; riepilogo = 'Riepilogo'; rilasci = 'Rilasci'; diagnosi = 'Diagnosi'; aggiornamenti = 'Aggiornamenti' }
$script:OreFraTentativiTopic = 1
$script:TopicNonEsiste = 'message thread not found|TOPIC_DELETED|TOPIC_ID_INVALID'

function Get-TelegramPercorsoTopic([string]$CartellaDati) {
    if (-not $CartellaDati) { $CartellaDati = Get-CartellaDati }
    Join-Path $CartellaDati 'telegram-topic.json'
}

# Un file illeggibile o rovinato vale come vuoto: al peggio si ricrea un topic, non si ferma il messaggio.
function Read-StatoTopic([string]$CartellaDati) {
    $s = $null
    try { $s = Get-Stato -Percorso (Get-TelegramPercorsoTopic $CartellaDati) -Tentativi 3 -AttesaMs 50 } catch { $s = $null }
    if ($s -isnot [System.Collections.IDictionary]) { $s = @{} }
    if ($s['topic'] -isnot [System.Collections.IDictionary]) { $s['topic'] = @{} }
    if (-not $s.Contains('fallita')) { $s['fallita'] = $null }
    if (-not $s.Contains('permessoAvvisato')) { $s['permessoAvvisato'] = $false }
    $s
}

function Save-StatoTopic($Stato, [string]$CartellaDati) {
    Save-Stato -Stato $Stato -Percorso (Get-TelegramPercorsoTopic $CartellaDati)
}

function Write-LogTelegram([scriptblock]$Log, [string]$Messaggio) {
    if ($Log) { try { & $Log $Messaggio } catch { } }
}

# L'id del topic di quel nome logico (urgenti, riepilogo, rilasci, diagnosi): quello salvato, altrimenti lo crea. $null se non c'e e
# non si riesce a crearlo (bot senza il permesso "Gestisci topic", chat che non e un forum, errore dell'API): chi manda scrive nel
# topic generale. Dopo un fallimento non si richiama l'API per un'ora. -Dimentica toglie prima l'id salvato (il topic e stato
# cancellato a mano) e ne crea uno nuovo.
function Get-TelegramTopicId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('urgenti', 'riepilogo', 'rilasci', 'diagnosi', 'aggiornamenti')][string]$Nome,
        [string]$CartellaDati, [Alias('PercorsoToken')][string]$FileBot = (Get-TelegramPercorsoTokenPredefinito),
        [scriptblock]$Log, [datetime]$Adesso = [datetime]::UtcNow, [switch]$Dimentica
    )
    $bot = Read-FileNonVuoto $FileBot
    $chat = Read-FileNonVuoto (Get-TelegramPercorsoChatPredefinito $CartellaDati)
    if ($null -eq $bot -or $null -eq $chat) { return $null }
    $stato = Read-StatoTopic $CartellaDati
    if ($stato['topic'].Contains($Nome)) {
        if (-not $Dimentica) { return [int64]$stato['topic'][$Nome] }
        $stato['topic'].Remove($Nome)
    }
    $fallita = $stato['fallita']
    if ($fallita) {
        $q = ConvertTo-DataUtc (Get-Campo $fallita 'quando')
        if ($q -and ($Adesso.ToUniversalTime() - $q).TotalHours -lt $script:OreFraTentativiTopic) {
            # l'id dimenticato va comunque tolto dal file
            if ($Dimentica) { try { Save-StatoTopic $stato $CartellaDati } catch { } }
            return $null
        }
    }
    $id = $null; $errore = $null
    try {
        $r = Invoke-TelegramApi -Token $bot -Metodo 'createForumTopic' -Corpo @{ chat_id = $chat; name = $script:NomiTopic[$Nome] }
        $id = Get-Campo (Get-Campo $r 'result') 'message_thread_id'
        if (-not $id) { $errore = 'la risposta di createForumTopic non ha message_thread_id' }
    }
    catch { $errore = Hide-Valore ([string]$_.Exception.Message) $bot }
    if ($errore) {
        $stato['fallita'] = @{ quando = $Adesso.ToUniversalTime().ToString('o'); errore = $errore }
        try { Save-StatoTopic $stato $CartellaDati } catch { Write-LogTelegram $Log "telegram-topic.json non si salva: $($_.Exception.Message)" }
        Write-LogTelegram $Log "Telegram: topic '$($script:NomiTopic[$Nome])' non creato, il messaggio va nel topic generale: $errore"
        return $null
    }
    $stato['topic'][$Nome] = [int64]$id
    $stato['fallita'] = $null
    $stato['permessoAvvisato'] = $false
    try { Save-StatoTopic $stato $CartellaDati } catch { Write-LogTelegram $Log "telegram-topic.json non si salva (il topic '$($script:NomiTopic[$Nome])' si ricreera): $($_.Exception.Message)" }
    Write-LogTelegram $Log "Telegram: creato il topic '$($script:NomiTopic[$Nome])'"
    [int64]$id
}

# $null se i topic vanno bene; altrimenti l'errore dell'ultima creazione fallita e se la voce del permesso e gia stata detta.
function Get-TelegramProblemaTopic {
    [CmdletBinding()]
    param([string]$CartellaDati)
    $s = Read-StatoTopic $CartellaDati
    if (-not $s['fallita']) { return $null }
    [pscustomobject]@{ Errore = [string](Get-Campo $s['fallita'] 'errore'); Avvisato = [bool]$s['permessoAvvisato'] }
}

function Set-TelegramPermessoAvvisato([string]$CartellaDati) {
    $s = Read-StatoTopic $CartellaDati
    if (-not $s['fallita']) { return }
    $s['permessoAvvisato'] = $true
    Save-StatoTopic $s $CartellaDati
}

# ---- il testo (HTML, solo per i messaggi del supervisore) ----------------------------------------------------------
# Il testo variabile (titoli delle card, righe di log, diagnosi) passa da ConvertTo-AnteprimaTelegram (niente codice ne tag) e poi
# dall'escape HTML: i soli tag che escono sono quelli scritti qui, <b> e <a href>.

function ConvertTo-HtmlEscapato([AllowNull()][string]$T) {
    if ($null -eq $T) { return '' }
    $T.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function ConvertTo-HtmlTelegram {
    [CmdletBinding()]
    param([AllowNull()][string]$Testo, [int]$Max = $script:AnteprimaMax)
    ConvertTo-HtmlEscapato (ConvertTo-AnteprimaTelegram -Testo $Testo -Max $Max)
}

# Il testo e gia escapato; l'indirizzo si escapa come valore di attributo.
function Get-LinkHtml([string]$Url, [string]$TestoHtml) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return $TestoHtml }
    $u = (ConvertTo-HtmlEscapato $Url.Trim()).Replace('"', '&quot;')
    "<a href=""$u"">$TestoHtml</a>"
}

$script:GiorniBrevi = 'dom', 'lun', 'mar', 'mer', 'gio', 'ven', 'sab'
# "Supervisore · lun 23/11 14:00", in ora locale.
function Format-IntestazioneTelegram([datetime]$Adesso) {
    $l = $Adesso.ToLocalTime()
    'Supervisore ' + [char]0x00B7 + ' ' + $script:GiorniBrevi[[int]$l.DayOfWeek] + ' ' + $l.ToString('dd\/MM HH\:mm', [cultureinfo]::InvariantCulture)
}

# Titolo, poi i blocchi separati da una riga vuota, sotto il limite di Telegram (contato sul testo con i tag): quelli che non entrano
# non si mandano e l'ultima riga dice quanti mancano.
$script:LimiteMessaggio = 4096
function Join-BlocchiTelegram([string]$Testa, [string[]]$Blocchi, [int]$Max, [string]$Singolare, [string]$Plurale) {
    $blocchi = @($Blocchi | Where-Object { $null -ne $_ })
    $testo = $Testa
    $inclusi = 0
    foreach ($b in $blocchi) {
        $mancanti = $blocchi.Count - $inclusi - 1
        # lo spazio per l'ultima riga si tiene da parte finche ce ne sono altri
        $riserva = if ($mancanti -gt 0) { 60 } else { 0 }
        if (($testo + "`n`n" + $b).Length + $riserva -gt $Max) { break }
        $testo += "`n`n" + $b
        $inclusi++
    }
    if ($inclusi -lt $blocchi.Count) {
        $n = $blocchi.Count - $inclusi
        $testo += "`n`n... e altre $n " + $(if ($n -eq 1) { $Singolare } else { $Plurale }) + ' (guarda la vista)'
    }
    $testo
}

# Urgente: "🔴 cosa" in grassetto, poi l'azione con il link.
function Format-UrgenteTelegram {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Voce, [Parameter(Mandatory)][datetime]$Adesso, [string]$LinkPredefinito)
    $cosa = (ConvertTo-HtmlTelegram -Testo ([string](Get-Campo $Voce 'Testo')) -Max 400).TrimEnd('.')
    $riga = [string][char]::ConvertFromUtf32(0x1F534) + " <b>$cosa</b>"
    if ([bool](Get-Campo $Voce 'Ricordo')) {
        $attesa = [string](Get-Campo $Voce 'Attesa')
        $riga += ' (ancora aperto' + $(if ($attesa) { ", $attesa" } else { '' }) + ')'
    }
    $azione = ConvertTo-HtmlTelegram -Testo ([string](Get-Campo $Voce 'Azione')) -Max 300
    $link = [string](Get-Campo $Voce 'Link'); if (-not $link) { $link = $LinkPredefinito }
    (Format-IntestazioneTelegram $Adesso) + "`n`n" + $riga + $(if ($azione) { "`n" + (Get-LinkHtml $link $azione) } else { '' })
}

# Il riepilogo (D51): una voce per punto, "N. cosa" e a capo "→ azione" con il link sull'azione. $Voci: oggetti con Testo, Azione,
# Link (e Attesa, il "da quanto" di una voce ricordata; Diagnosi, se c'e una diagnosi: sta nel suo topic).
function Format-RiepilogoTelegram {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Voci, [Parameter(Mandatory)][datetime]$Adesso, [int]$Max = $script:LimiteMessaggio)
    $voci = @($Voci | Where-Object { $null -ne $_ })
    $titolo = "<b>$($voci.Count) " + $(if ($voci.Count -eq 1) { 'cosa' } else { 'cose' }) + ' per te</b>'
    $i = 0
    $blocchi = foreach ($v in $voci) {
        $i++
        $r = "$i. " + (ConvertTo-HtmlTelegram -Testo ([string](Get-Campo $v 'Testo')) -Max 260).TrimEnd('.')
        $attesa = [string](Get-Campo $v 'Attesa')
        if ($attesa) { $r += " ($(ConvertTo-HtmlEscapato $attesa))" }
        $azione = ConvertTo-HtmlTelegram -Testo ([string](Get-Campo $v 'Azione')) -Max 220
        if ($azione) { $r += "`n" + [char]0x2192 + ' ' + (Get-LinkHtml ([string](Get-Campo $v 'Link')) $azione) }
        foreach ($rg in @(Get-Campo $v 'Righe')) { $rr = ConvertTo-HtmlTelegram -Testo ([string]$rg) -Max 240; if ($rr) { $r += "`n   - $rr" } }
        # la diagnosi del modello ha un messaggio suo, nel topic Diagnosi
        if (-not [string]::IsNullOrWhiteSpace([string](Get-Campo $v 'Diagnosi'))) { $r += "`ndiagnosi nel topic Diagnosi" }
        $r
    }
    Join-BlocchiTelegram ((Format-IntestazioneTelegram $Adesso) + "`n`n" + $titolo) @($blocchi) $Max 'voce' 'voci'
}

# La diagnosi di un problema: un messaggio nel topic Diagnosi.
function Format-DiagnosiTelegram {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Problema, [Parameter(Mandatory)][string]$Diagnosi, [Parameter(Mandatory)][datetime]$Adesso)
    $p = (ConvertTo-HtmlTelegram -Testo $Problema -Max 400).TrimEnd('.')
    (Format-IntestazioneTelegram $Adesso) + "`n`n" + [char]::ConvertFromUtf32(0x1F50E) + " <b>$p</b>`n" + (ConvertTo-HtmlTelegram -Testo $Diagnosi -Max 600)
}

# D53, gli aggiornamenti della suite: un messaggio nel topic Aggiornamenti. $Tipo e aggiornato (Da, A, le PR entrate, ciascuna con Numero,
# Titolo e Url), fallito (A e il commit scartato, Errore), attesa (le sessioni tengono ferma la copia da Ore ore).
function Format-AggiornamentoTelegram {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('aggiornato', 'fallito', 'attesa', 'copiaRotta')][string]$Tipo, [Parameter(Mandatory)][datetime]$Adesso,
        [string]$Da, [string]$A, [object[]]$Pr = @(), [string]$Errore, [int]$Ore)
    $testa = Format-IntestazioneTelegram $Adesso
    switch ($Tipo) {
        'aggiornato' {
            $righe = @("$testa`n`n" + [char]::ConvertFromUtf32(0x1F504) + " <b>Suite aggiornata</b>: $(ConvertTo-HtmlTelegram -Testo $Da -Max 80) " + [char]0x2192 + " $(ConvertTo-HtmlTelegram -Testo $A -Max 80)")
            foreach ($p in @($Pr | Where-Object { $_ })) {
                $t = ConvertTo-HtmlTelegram -Testo ([string]$p.Titolo) -Max 120
                $righe += (Get-LinkHtml ([string](Get-Campo $p 'Url')) "PR $($p.Numero)") + ": $t"
            }
            $righe -join "`n"
        }
        'fallito' {
            "$testa`n`n" + [char]::ConvertFromUtf32(0x26A0) + " <b>Aggiornamento della suite fallito, tornato alla versione di prima</b>`ncommit scartato: $(ConvertTo-HtmlTelegram -Testo $A -Max 80)`n$(ConvertTo-HtmlTelegram -Testo $Errore -Max 600)"
        }
        'copiaRotta' {
            "$testa`n`n" + [char]::ConvertFromUtf32(0x1F6A8) + " <b>Aggiornamento della suite: la copia e rimasta a meta</b>`nil ritorno alla versione di prima non e riuscito, la copia e lasciata a $(ConvertTo-HtmlTelegram -Testo $A -Max 80). Va sistemata a mano.`n$(ConvertTo-HtmlTelegram -Testo $Errore -Max 600)"
        }
        'attesa' {
            "$testa`n`n" + [char]::ConvertFromUtf32(0x23F3) + " <b>Aggiornamento della suite in attesa</b>`nc'e una versione nuova ($(ConvertTo-HtmlTelegram -Testo $A -Max 80)) ma da oltre $Ore ore ci sono sessioni di agenti in corso: non forzo, aggiorno appena finiscono."
        }
    }
}

# L'area come la si legge: gli ultimi due pezzi del percorso, "AI · Stime".
function Format-AreaBreve([string]$Area) {
    $p = @($Area -split '[\\/]' | Where-Object { $_ })
    if ($p.Count -gt 2) { $p = $p[-2..-1] }
    $p -join (' ' + [char]0x00B7 + ' ')
}

# I rilasci in attesa (D51), nel topic Rilasci. $Gruppi, gia in ordine (oltre soglia in cima): Area, Card (Id, Titolo, Url), Giorni,
# OltreCard, OltreGiorni, MaxCard, MaxGiorni, Progetto, LinkRilascio (la pipeline orchestrator del progetto, o vuoto).
function Format-RilasciTelegram {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Gruppi, [Parameter(Mandatory)][datetime]$Adesso, [int]$Max = $script:LimiteMessaggio)
    $gruppi = @($Gruppi | Where-Object { $null -ne $_ })
    # le card vere (una funzionalita e una voce con piu card); i gruppi senza NumeroCard sono fatti di card isolate
    $conta = { param($g) $n = Get-Campo $g 'NumeroCard'; if ($null -ne $n) { [int]$n } else { @($g.Card).Count } }
    $tot = 0; foreach ($g in $gruppi) { $tot += (& $conta $g) }
    $titolo = "<b>Da rilasciare in produzione: $tot card</b>"
    $blocchi = foreach ($g in $gruppi) {
        $n = & $conta $g
        $da = if ([int]$g.Giorni -eq 0) { 'da meno di un giorno' } elseif ([int]$g.Giorni -eq 1) { 'da 1 giorno' } else { "da $($g.Giorni) giorni" }
        $oltre = [bool]$g.OltreCard -or [bool]$g.OltreGiorni
        $riga = $(if ($oltre) { [string][char]0x26A0 + [char]0xFE0F + ' ' } else { '' }) + "<b>$(ConvertTo-HtmlEscapato (Format-AreaBreve ([string]$g.Area)))</b>: $n card, la pi" + [char]0x00F9 + " vecchia aspetta $da"
        if ($oltre) {
            $soglie = @(); if ($g.OltreCard) { $soglie += "$($g.MaxCard) card" }; if ($g.OltreGiorni) { $soglie += "$($g.MaxGiorni) giorni" }
            $riga += " (soglia: $($soglie -join ' e '))"
        }
        $righe = @($riga)
        foreach ($c in @($g.Card)) {
            $righe += '   ' + (Get-LinkHtml ([string]$c.Url) "#$($c.Id)") + ' ' + (ConvertTo-HtmlTelegram -Testo ([string]$c.Titolo) -Max 60)
        }
        $righe += if ($g.LinkRilascio) { '   ' + [char]0x2192 + ' ' + (Get-LinkHtml ([string]$g.LinkRilascio) 'lancia il rilascio') }
                  else { '   rilascio: nessuna pipeline orchestrator nel progetto ' + (ConvertTo-HtmlEscapato ([string]$g.Progetto)) }
        $righe -join "`n"
    }
    Join-BlocchiTelegram ((Format-IntestazioneTelegram $Adesso) + "`n`n" + $titolo) @($blocchi) $Max 'area' 'aree'
}

# ---- l'invio -------------------------------------------------------------------------------------------------------

# Manda un messaggio gia formattato in HTML nel topic indicato. $true se e partito, $false se Telegram non e configurato. Senza
# topic o se non c'e e non si riesce a crearlo, il messaggio va nel topic generale (e -Log lo dice). Se il topic salvato non esiste
# piu (cancellato a mano) lo si dimentica e lo si ricrea una volta. Stessi riguardi di Invoke-TelegramApi per il valore del bot.
function Send-TelegramMessaggio {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Testo, [ValidateSet('', 'urgenti', 'riepilogo', 'rilasci', 'diagnosi', 'aggiornamenti')][string]$Topic = '',
        [string]$CartellaDati, [Alias('PercorsoToken')][string]$FileBot = (Get-TelegramPercorsoTokenPredefinito),
        [scriptblock]$Log, [datetime]$Adesso = [datetime]::UtcNow
    )
    $bot = Read-FileNonVuoto $FileBot
    $chat = Read-FileNonVuoto (Get-TelegramPercorsoChatPredefinito $CartellaDati)
    if ($null -eq $bot -or $null -eq $chat) { return $false }
    $id = $null
    if ($Topic) { $id = Get-TelegramTopicId -Nome $Topic -CartellaDati $CartellaDati -FileBot $FileBot -Log $Log -Adesso $Adesso }
    $invia = {
        param($IdTopic)
        $corpo = @{ chat_id = $chat; text = $Testo; parse_mode = 'HTML'; link_preview_options = @{ is_disabled = $true } }
        if ($IdTopic) { $corpo['message_thread_id'] = [int64]$IdTopic }
        [void](Invoke-TelegramApi -Token $bot -Metodo 'sendMessage' -Corpo $corpo)
    }
    $errore = $null; $mancante = $false
    try { & $invia $id }
    catch {
        $errore = Hide-Valore ([string]$_.Exception.Message) $bot
        if ($id -and $errore -match $script:TopicNonEsiste) { $mancante = $true; $errore = $null }
    }
    if ($mancante) {
        Write-LogTelegram $Log "Telegram: il topic '$($script:NomiTopic[$Topic])' non esiste piu, lo ricreo"
        $id = Get-TelegramTopicId -Nome $Topic -CartellaDati $CartellaDati -FileBot $FileBot -Log $Log -Adesso $Adesso -Dimentica
        try { & $invia $id }
        catch { $errore = Hide-Valore ([string]$_.Exception.Message) $bot }
    }
    if ($errore) { throw $errore }
    $true
}

Export-ModuleMember -Function Test-TelegramConfigurato, ConvertTo-AnteprimaTelegram, Format-MessaggioTelegram,
    Invoke-TelegramApi, Send-TelegramAvviso, Get-TelegramPercorsoTokenPredefinito, Get-TelegramPercorsoTopic, Get-TelegramTopicId,
    Get-TelegramProblemaTopic, Set-TelegramPermessoAvvisato, ConvertTo-HtmlTelegram, Format-IntestazioneTelegram, Format-UrgenteTelegram,
    Format-RiepilogoTelegram, Format-DiagnosiTelegram, Format-AggiornamentoTelegram, Format-RilasciTelegram, Send-TelegramMessaggio
