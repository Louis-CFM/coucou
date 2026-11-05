import Foundation

// MARK: - Fixtures (the transcription of the owner's screenshot)

private let heredoc1 = "python3 << 'PY' from __future__ import annotations import json, os, sys, tim…"
private let heredoc2 = "python3 << 'PY' import json from pathlib import Path from datetime import d…"
private let stepsA: [(String, String)] = [
    ("search_files", "act_"), ("read_file", "ad-spends-account-sync-abort.md"), ("read_file", "pause_restricted_pages.py"),
    ("terminal", heredoc1), ("read_file", "adri_emma_diag.json"), ("terminal", heredoc2),
]
private let interimText = "Os dois ads que entregavam ontem estão DISAPPROVED. Vou puxar o horário da morte e o adset sem bater no code 17."
private let stepsB: [(String, String)] = [
    ("terminal", heredoc1), ("terminal", heredoc1), ("terminal", heredoc1),
    ("search_files", "AE - PLAY 01 IB"), ("search_files", "Emma Baker"), ("read_file", "welcome_ib_recreate.jsonl"),
]

private let emmaLead = "Emma Baker (Conta 06, campanha Emma Baker - España - ES - 1)"
private let emmaBody = "O único ad que gastava, Emma Baker - 01_final_protected VF, foi pra DISAPPROVED ontem 07/10 09:25 BRT. Motivo: proposta de cunho sexual / linguagem sexualmente explícita. Hourly bate: 00h–08h normal, 09h R$ 6,94 (hora cortada), depois zero. Hoje 0 imp. Adset ACTIVE, orçamento R$ 260,69 intacto (não gastou nada). O irmão antigo tá PAUSED desde 19/09. Ninguém pausou isso no NORDER."
private let adriLead = "Adri Neves (Conta 06, Adri Neves - v3)"
private let adriLines = [
    "Levou dois cortes ontem, mesmo motivo.",
    "O ad que carregava a manhã, AE - PLAY 01 IB R, foi DISAPPROVED e o watchdog apagou/recriou 07/10 13:15 BRT como AE - PLAY 01 IB R R. Por isso o hourly da campanha segue até 12h (~R$ 286) e despenca 13h.",
    "O clone novo gastou R$ 50,28 (13h–15h) e tomou o mesmo reprova 15:34 BRT. Hoje 0 imp.",
    "Campanha/adset ACTIVE (teto R$ 574,65). Último toque humano no adset: Lucas no NORDER em 01/10 20:38 (budget). Não foi ontem. O AE - PLAY 01 original tá PAUSED desde 15/09.",
]
private let contaLine = "Conta 06: 14 campanhas com spend ontem, 12 hoje. Saíram exatamente essas duas."
private let receitaLine = "Receita residual no Redron (Adri ~US$ 49, Emma ~US$ 25) é tráfego de ontem, não spend novo."
private let askLine = "Religar o ad reprovado não adianta. Precisa post/criativo novo no mesmo adset, icebreaker diferente do irmão morto. Não mexi em nada. Quer que eu recrie as duas?"
private let verdictLine = "Não é pause, não é sync da Conta 06 e não é 2490134. Meta derrubou o anúncio que entregava. Campanha e adset das duas seguem ACTIVE. Página publicada nas duas."

private let answerPlain = [
    verdictLine,
    emmaLead + "\n" + emmaBody,
    adriLead + "\n" + adriLines.joined(separator: "\n"),
    contaLine, receitaLine, askLine,
].joined(separator: "\n\n")

private let answerMarkdown = """
## Emma Baker e Adri Neves

Os dois ads que entregavam ontem estão **DISAPPROVED**. Campanha e adset das duas seguem ACTIVE, e a página está publicada nas duas.

### O que mudou ontem

| Conta | Ad | Status | Gasto ontem |
|:--|:--|:-:|--:|
| Emma Baker | 01_final_protected VF | DISAPPROVED | R$ 6,94 |
| Adri Neves | AE - PLAY 01 IB R R | DISAPPROVED | R$ 50,28 |
| Adri Neves | AE - PLAY 01 | PAUSED | R$ 0,00 |

- Hourly da Emma cortou às **09h**, depois zero
- Hourly da Adri segue até 12h (~R$ 286) e despenca 13h
- Ninguém pausou isso no NORDER

### Como conferi

```python
ads = api.get(f"{act}/ads", fields="name,effective_status")
dead = [a for a in ads if a["effective_status"] == "DISAPPROVED"]
print(len(dead), "ads reprovados")
```

Não mexi em nada. Quer que eu recrie as duas?
"""

// MARK: - Harness

@main
enum ChatAnswerStyleTests {
    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    // Builders
    static func step(_ id: Int, _ tool: String, _ label: String = "x", _ status: ChatStep.Status = .done) -> ChatSegment {
        ChatSegment(id: id, kind: .step(ChatStep(callId: "c\(id)", tool: tool, label: label, detail: nil, status: status)))
    }
    static func text(_ id: Int, _ t: String, _ role: ChatSegment.TextRole) -> ChatSegment {
        ChatSegment(id: id, kind: .text(t, role: role))
    }
    static func note(_ id: Int, _ t: String = "note") -> ChatSegment { ChatSegment(id: id, kind: .note(t)) }
    static func hidden(_ id: Int) -> ChatSegment { ChatSegment(id: id, kind: .hiddenSteps) }

    static func screenshotTurn(answerRole: ChatSegment.TextRole? = .answer) -> [ChatSegment] {
        var segs: [ChatSegment] = []
        var id = 0
        for s in stepsA { segs.append(step(id, s.0, s.1)); id += 1 }
        segs.append(text(id, interimText, .interim)); id += 1
        for s in stepsB { segs.append(step(id, s.0, s.1)); id += 1 }
        if let role = answerRole { segs.append(text(id, answerPlain, role)) }
        return segs
    }

    static func shape(_ items: [ChatTurnLayout.Item]) -> String {
        items.map { item -> String in
            switch item {
            case .group(_, let mode): return "group:\(mode)"
            case .card(_, _, let open): return open ? "card:open" : "card"
            case .note: return "note"
            case .moment: return "moment"
            }
        }.joined(separator: ",")
    }

    static func cardShape(_ items: [CardItem]) -> String {
        items.map { item -> String in
            switch item {
            case .verdict: return "verdict"
            case .section(let lead, _): return "section(\(lead.prefix(4)))"
            case .ask: return "ask"
            case .block(let b, let closed):
                let name: String
                switch b {
                case .paragraph: name = "p"
                case .heading: name = "h"
                case .table: name = "table"
                case .codeBlock: name = "code"
                case .listItem: name = "li"
                default: name = "other"
                }
                return closed ? name : name + "~"
            case .hairline: return "hr"
            case .attachment(let id): return "att\(id)"
            }
        }.joined(separator: " ")
    }

    /// The marks of a plain string as (substring, kind).
    static func marks(_ s: String) -> [(String, MarkKind)] {
        ChatAnswerRules.marks(inPlain: s).map { (String(s[$0.range]), $0.kind) }
    }
    static func texts(_ s: String) -> [String] { marks(s).map { $0.0 } }
    static func isStatus(_ k: MarkKind) -> Bool { if case .status = k { return true }; return false }

    static func paragraphs(_ blocks: [MDBlock]) -> [String] {
        blocks.compactMap { if case .paragraph(let t) = $0 { return t }; return nil }
    }

    static func main() {
        let layout = ChatTurnLayout.self

        print("Work group")
        checkTrue("1 screenshot turn finished: [folded, card]",
                  shape(layout.items(segments: screenshotTurn(), running: false)) == "group:folded,card")
        checkTrue("2 running, last step running, no answer: [live]", {
            var segs = screenshotTurn(answerRole: nil)
            if case .step(var s) = segs[segs.count - 1].kind { s.status = .running; segs[segs.count - 1].kind = .step(s) }
            return shape(layout.items(segments: segs, running: true)) == "group:live"
        }())
        checkTrue("3 running with an open text after the group: [live, card open]",
                  shape(layout.items(segments: screenshotTurn(answerRole: .open), running: true)) == "group:live,card:open")
        checkTrue("4 open text sealed by a new tool: one live group that holds the sentence, no card", {
            var segs = screenshotTurn(answerRole: nil)
            segs.append(text(100, "uma frase", .interim)); segs.append(step(101, "terminal", "x", .running))
            let items = layout.items(segments: segs, running: true)
            guard shape(items) == "group:live", case .group(let g, _) = items[0] else { return false }
            return g.rows.contains { $0.id == 100 }
        }())
        checkTrue("5a 1 step finished: rows", shape(layout.items(segments: [step(0, "terminal")], running: false)) == "group:rows")
        checkTrue("5b 2 steps finished: rows", shape(layout.items(segments: [step(0, "a"), step(1, "b")], running: false)) == "group:rows")
        checkTrue("5c 3 steps finished: folded",
                  shape(layout.items(segments: [step(0, "a"), step(1, "b"), step(2, "c")], running: false)) == "group:folded")
        checkTrue("6 2 steps with an interim text: folded",
                  shape(layout.items(segments: [step(0, "a"), text(1, "oi", .interim), step(2, "b")], running: false)) == "group:folded")
        checkTrue("7 hiddenSteps row and 60 steps: folded, more", {
            var segs: [ChatSegment] = [hidden(0)]
            for i in 1...60 { segs.append(step(i, "terminal")) }
            let items = layout.items(segments: segs, running: false)
            guard shape(items) == "group:folded", case .group(let g, _) = items[0] else { return false }
            let s = ChatWorkSummary(group: g)
            return s.more && s.count == 60
        }())
        checkTrue("7b hiddenSteps row with one step: folded",
                  shape(layout.items(segments: [hidden(0), step(1, "a")], running: false)) == "group:folded")
        checkTrue("8 interim text only, no step: rows",
                  shape(layout.items(segments: [text(0, "pensando", .interim)], running: false)) == "group:rows")
        checkTrue("9a note between steps: after the group", {
            let segs = [step(0, "a"), note(1), step(2, "b"), step(3, "c"), text(4, "ok", .answer)]
            return shape(layout.items(segments: segs, running: false)) == "group:folded,note,card"
        }())
        checkTrue("9b note after the answer: after the card", {
            let segs = [step(0, "a"), text(1, "ok", .answer), note(2)]
            return shape(layout.items(segments: segs, running: false)) == "group:rows,card,note"
        }())
        checkTrue("10 text with no work rows: [card]",
                  shape(layout.items(segments: [text(0, "oi", .answer)], running: false)) == "card")
        checkTrue("11 whitespace only text: no item",
                  layout.items(segments: [text(0, " \n ", .answer)], running: false).isEmpty
                  && layout.items(segments: [text(0, "  ", .open)], running: true).isEmpty)
        checkTrue("12 startsExpanded: group with interim and no answer", {
            let segs = [step(0, "a"), text(1, "falei", .interim), step(2, "b"), step(3, "c")]
            return layout.startsExpanded(layout.items(segments: segs, running: false))
        }())
        checkTrue("12b startsExpanded false with an answer",
                  !layout.startsExpanded(layout.items(segments: screenshotTurn(), running: false)))
        checkTrue("12c startsExpanded false for a live group",
                  !layout.startsExpanded(layout.items(segments: [step(0, "a", "x", .running), text(1, "x", .interim)], running: true)))
        checkTrue("13 every segment id is in exactly one item", {
            var segs = screenshotTurn()
            segs.insert(note(200), at: 3)
            segs.append(note(201))
            let items = layout.items(segments: segs, running: false)
            var seen: [Int] = []
            for item in items {
                switch item {
                case .group(let g, _): seen += g.rows.map(\.id)
                case .card(let id, _, _): seen.append(id)
                case .note(let id, _): seen.append(id)
                case .moment(let id, _): seen.append(id)
                }
            }
            return seen.sorted() == segs.map(\.id).sorted() && Set(seen).count == seen.count
        }())
        checkTrue("13b item ids are unique", {
            let items = layout.items(segments: screenshotTurn(), running: false)
            return Set(items.map(\.id)).count == items.count
        }())

        print("Summary")
        let shotGroup: ChatTurnLayout.WorkGroup = {
            guard case .group(let g, _) = layout.items(segments: screenshotTurn(), running: false)[0] else { fatalError() }
            return g
        }()
        let shot = ChatWorkSummary(group: shotGroup)
        checkTrue("14 screenshot: count 12, terminal 5, read_file 4, search_files 3",
                  shot.count == 12 && !shot.more
                  && shot.tools.map(\.tool) == ["terminal", "read_file", "search_files"]
                  && shot.tools.map(\.count) == [5, 4, 3])
        checkTrue("15 tie keeps the order of first appearance", {
            let g = ChatTurnLayout.WorkGroup(id: 0, rows: [step(0, "b"), step(1, "a"), step(2, "a"), step(3, "b")])
            return ChatWorkSummary(group: g).tools.map(\.tool) == ["b", "a"]
        }())
        checkTrue("16 five tools: limit 3 → 3 shown, extra 2; limit 0 → extra 5", {
            let g = ChatTurnLayout.WorkGroup(id: 0, rows: ["a", "b", "c", "d", "e"].enumerated().map { step($0.offset, $0.element) })
            let s = ChatWorkSummary(group: g)
            return s.shown(limit: 3).tools.count == 3 && s.shown(limit: 3).extra == 2
                && s.shown(limit: 0).tools.isEmpty && s.shown(limit: 0).extra == 5
        }())
        checkTrue("17 symbols",
                  ChatWorkSummary.symbol(for: "terminal") == "terminal" && ChatWorkSummary.symbol(for: "read_file") == "doc.text"
                  && ChatWorkSummary.symbol(for: "search_files") == "magnifyingglass" && ChatWorkSummary.symbol(for: "web_search") == "globe"
                  && ChatWorkSummary.symbol(for: "browser_click") == "wrench" && ChatWorkSummary.symbol(for: "Terminal") == "wrench")
        checkTrue("18 state", {
            func st(_ rows: [ChatSegment]) -> ChatWorkSummary.State { ChatWorkSummary(group: .init(id: 0, rows: rows)).state }
            return st([step(0, "a"), step(1, "a")]) == .done
                && st([step(0, "a"), step(1, "a", "x", .stopped)]) == .stopped
                && st([step(0, "a"), step(1, "a", "x", .running)]) == .running
                && st([step(0, "a", "x", .running), step(1, "a", "x", .stopped)]) == .stopped
        }())
        checkTrue("19a liveStep: the last running step and its number", {
            let rows = [step(0, "a"), step(1, "b", "x", .running), text(2, "frase", .interim), step(3, "c", "x", .running), step(4, "d")]
            guard let live = ChatWorkSummary.liveStep(group: .init(id: 0, rows: rows)) else { return false }
            return live.segmentId == 3 && live.step.tool == "c" && live.number == 3
        }())
        checkTrue("19b liveStep: none running → the last step", {
            let rows = [step(0, "a"), step(1, "b")]
            guard let live = ChatWorkSummary.liveStep(group: .init(id: 0, rows: rows)) else { return false }
            return live.segmentId == 1 && live.number == 2
        }())
        checkTrue("19c liveStep: hiddenSteps → number nil, and no step → nil", {
            let rows = [hidden(0), step(1, "a", "x", .running)]
            guard let live = ChatWorkSummary.liveStep(group: .init(id: 0, rows: rows)) else { return false }
            return live.number == nil && ChatWorkSummary.liveStep(group: .init(id: 0, rows: [text(0, "x", .interim)])) == nil
        }())
        checkTrue("19d liveSentence: the last interim text", {
            let rows = [text(0, "um", .interim), step(1, "a"), text(2, "dois", .interim)]
            return ChatWorkSummary.liveSentence(group: .init(id: 0, rows: rows)) == "dois"
                && ChatWorkSummary.liveSentence(group: .init(id: 0, rows: [step(0, "a")])) == nil
        }())

        print("Lead")
        let rules = ChatAnswerRules.self
        checkTrue("20 Emma lead", {
            let r = rules.lead(of: emmaLead + "\n" + emmaBody)
            return r.lead == emmaLead && r.lines == [emmaBody]
        }())
        checkTrue("21 Adri lead and four lines in order", {
            let r = rules.lead(of: adriLead + "\n" + adriLines.joined(separator: "\n"))
            return r.lead == adriLead && r.lines == adriLines
        }())
        checkTrue("22 one line: no lead", rules.lead(of: verdictLine).lead == nil)
        checkTrue("23 first line ends with a period: no lead", rules.lead(of: "Levou dois cortes ontem, mesmo motivo.\nOutra linha").lead == nil)
        checkTrue("24 '. ' inside the first line: no lead", rules.lead(of: "Um. Dois\nOutra linha").lead == nil)
        checkTrue("24b '! ' and '? ' inside: no lead",
                  rules.lead(of: "Oi! Tudo\nx").lead == nil && rules.lead(of: "Oi? Tudo\nx").lead == nil)
        checkTrue("25 70 characters is a lead, 71 is not", {
            let l70 = String(repeating: "a", count: 70), l71 = String(repeating: "a", count: 71)
            let body = "O corpo da secao vem aqui."
            return rules.lead(of: l70 + "\n" + body).lead == l70 && rules.lead(of: l71 + "\n" + body).lead == nil
        }())
        checkTrue("26 final punctuation: no lead", ".!?:;…,".allSatisfy { rules.lead(of: "Titulo\(String($0))\nx").lead == nil })
        checkTrue("27 no letter in the first line: no lead", rules.lead(of: "2490134\nx").lead == nil)
        checkTrue("28 capitals only: lead, and no status mark", {
            let r = rules.lead(of: "NORDER BRT\nES IB R fechou tudo.")
            return r.lead == "NORDER BRT" && r.lines == ["ES IB R fechou tudo."] && marks("NORDER BRT\nES IB R").isEmpty
        }())
        checkTrue("29 round trip over the fixture paragraphs", {
            for p in paragraphs(ChatMarkdown.parse(answerPlain)) {
                let want = p.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let r = rules.lead(of: p)
                if (r.lead.map { [$0] } ?? []) + r.lines != want { return false }
            }
            return true
        }())
        checkTrue("29b blank and padded lines are dropped, nothing else",
                  rules.lead(of: "  Titulo  \n\n \t Corpo da secao. \n").lines == ["Corpo da secao."])

        print("Sections")
        let plain = ChatMarkdown.parse(answerPlain)
        checkTrue("30 answerPlain, verdict on, finished",
                  cardShape(rules.sections(blocks: plain, streaming: false, verdict: true))
                  == "verdict hr section(Emma) hr section(Adri) hr p p ask")
        checkTrue("30b strips and lines of the sections", {
            let items = rules.sections(blocks: plain, streaming: false, verdict: true)
            guard case .section(let lead, let lines) = items[2] else { return false }
            return lead == emmaLead && rules.statusStrip(lines: lines) == ["DISAPPROVED", "ACTIVE", "PAUSED"] && lines == [emmaBody]
        }())
        checkTrue("31 verdict off: the first item is a plain block",
                  cardShape(rules.sections(blocks: plain, streaming: false, verdict: false)).hasPrefix("p hr section(Emma)"))
        let md = ChatMarkdown.parse(answerMarkdown)
        checkTrue("32 answerMarkdown: no section, no verdict, ask last", {
            let shape = cardShape(rules.sections(blocks: md, streaming: false, verdict: true))
            return !shape.contains("section") && !shape.contains("verdict") && shape.hasSuffix("ask") && shape.hasPrefix("h p h table")
        }())
        checkTrue("33 lead shaped paragraph after a heading: plain block", {
            let blocks = ChatMarkdown.parse("## T\n\nTitulo curto\nO corpo do texto vai aqui.")
            return cardShape(rules.sections(blocks: blocks, streaming: false, verdict: false)) == "h p"
        }())
        checkTrue("34 lead shaped paragraph before the first heading: section", {
            let blocks = ChatMarkdown.parse("Titulo curto\nO corpo do texto vai aqui.\n\n## T\n\nTitulo curto\nO corpo.")
            return cardShape(rules.sections(blocks: blocks, streaming: false, verdict: false)) == "section(Titu) hr h p"
        }())
        checkTrue("35a streaming: last block open, never a section", {
            // The open last block is lead shaped (it would be a section once closed): the streaming rule keeps it body.
            let open = "Titulo curto\nO corpo do texto vai aqui."
            guard rules.lead(of: open).lead == "Titulo curto" else { return false }
            let blocks = ChatMarkdown.parse("Um paragrafo\nSegunda linha do texto.\n\n" + open, streaming: true)
            return cardShape(rules.sections(blocks: blocks, streaming: true, verdict: false)) == "section(Um p) hr p~"
        }())
        checkTrue("35b the open first paragraph with verdict on is the verdict", {
            let blocks = ChatMarkdown.parse("Não é pause, não é sync", streaming: true)
            return cardShape(rules.sections(blocks: blocks, streaming: true, verdict: true)) == "verdict"
        }())
        checkTrue("35c qualifying first line and a second line begun: plain open block", {
            let blocks = ChatMarkdown.parse("Emma Baker (Conta 06)\nO único ad que gastava, Emma Baker - 01_final_protected VF, foi pra DISAPPROVED ontem", streaming: true)
            return cardShape(rules.sections(blocks: blocks, streaming: true, verdict: true)) == "p~"
        }())
        checkTrue("35d open paragraph is body, even a question at the end", {
            let blocks = ChatMarkdown.parse("a\n\nQuer?", streaming: true)
            return !cardShape(rules.sections(blocks: blocks, streaming: true, verdict: false)).contains("ask")
        }())
        checkTrue("36 the strip is not part of the section: one switch, one pure function", {
            let items = rules.sections(blocks: plain, streaming: false, verdict: true)
            guard case .section(_, let lines) = items[2] else { return false }
            return ChatAnswerRules.showsStatusStrip && rules.statusStrip(lines: lines) == ["DISAPPROVED", "ACTIVE", "PAUSED"]
        }())
        checkTrue("36b no character lost: every paragraph text is drawn", {
            let items = rules.sections(blocks: plain, streaming: false, verdict: true)
            var drawn: [String] = []
            for item in items {
                switch item {
                case .verdict(let t), .ask(let t): drawn.append(t)
                case .section(let lead, let lines): drawn.append(lead); drawn += lines
                case .block(.paragraph(let t), _): drawn.append(t)
                default: break
                }
            }
            let want = paragraphs(plain).flatMap { $0.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
            // Verdict and ask keep their paragraph as written (newlines kept); sections split into lines.
            return drawn.flatMap { $0.components(separatedBy: "\n") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } == want
        }())
        checkTrue("36c a rule block is one hairline, never two", {
            let blocks = ChatMarkdown.parse("Titulo curto\nO corpo vai aqui.\n\n---\n\nfim")
            return cardShape(rules.sections(blocks: blocks, streaming: false, verdict: false)) == "section(Titu) hr p"
        }())

        print("Status")
        checkTrue("37 each of the 11 words alone", {
            let words: [(String, StatusKind)] = [("ACTIVE", .good), ("PAUSED", .warn), ("PENDING", .warn), ("PENDING_REVIEW", .warn),
                                                 ("IN_PROCESS", .warn), ("WITH_ISSUES", .warn), ("DISAPPROVED", .bad),
                                                 ("REJECTED", .bad), ("FAILED", .bad), ("ARCHIVED", .mute), ("DELETED", .mute)]
            return words.allSatisfy { marks($0.0).count == 1 && marks($0.0)[0].1 == .status($0.0, $0.1) }
        }())
        checkTrue("37b a cell that is exactly one status word",
                  rules.statusOnly(" DISAPPROVED ")?.kind == .bad && rules.statusOnly("PAUSED")?.word == "PAUSED"
                  && rules.statusOnly("ACTIVE ads") == nil && rules.statusOnly("Active") == nil && rules.statusOnly("") == nil)
        checkTrue("38 near misses stay plain",
                  ["REACTIVE", "ACTIVE_ADS", "PAUSED2", "Active", "active", "xACTIVE", "ACTIVEx", "_ACTIVE"].allSatisfy { marks($0).isEmpty })
        checkTrue("39 PENDING_REVIEW is one mark", texts("PENDING_REVIEW") == ["PENDING_REVIEW"])
        checkTrue("40 punctuation stays outside",
                  texts("ACTIVE.") == ["ACTIVE"] && texts("(ACTIVE)") == ["ACTIVE"] && texts("ACTIVE,") == ["ACTIVE"])
        checkTrue("41 other capitals stay plain", marks("NORDER BRT AE - PLAY 01 IB R R VF PY").isEmpty)
        checkTrue("42 code span: no mark", {
            let a = (try? AttributedString(markdown: "veja `DISAPPROVED` e `R$ 6,94` e ACTIVE",
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString("")
            let words = rules.marks(in: a).map { String(a[$0.range].characters) }
            return words == ["ACTIVE"]
        }())
        checkTrue("43 link text and url: no mark", {
            let a = (try? AttributedString(markdown: "[ACTIVE](https://example.com/PAUSED) e [R$ 6,94](https://example.com)",
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString("")
            return rules.marks(in: a).isEmpty
        }())
        checkTrue("44 bold status is marked", {
            let a = (try? AttributedString(markdown: "foi **DISAPPROVED** ontem",
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString("")
            return rules.marks(in: a).map { String(a[$0.range].characters) } == ["DISAPPROVED"]
        }())
        checkTrue("45 strip order and distinct", {
            return rules.statusStrip(lines: [emmaBody]) == ["DISAPPROVED", "ACTIVE", "PAUSED"]
                && rules.statusStrip(lines: ["ACTIVE e ACTIVE", "PAUSED ACTIVE"]) == ["ACTIVE", "PAUSED"]
                && rules.statusStrip(lines: ["sem nada", "`ACTIVE`"]).isEmpty
        }())
        checkTrue("46 right to left text and bidi controls", {
            let s = "مرحبا ACTIVE שלום \u{2067}FAILED\u{2069}"
            let m = ChatAnswerRules.marks(inPlain: s)
            return m.map { String(s[$0.range]) } == ["ACTIVE", "FAILED"]
        }())

        print("Amounts and times")
        let amountKind = MarkKind.amount
        checkTrue("47 amounts, exact ranges", {
            for a in ["R$ 6,94", "R$ 260,69", "R$ 50,28", "R$ 574,65", "~R$ 286", "~US$ 49", "~US$ 25"] {
                let m = marks("gastou \(a) hoje")
                if m.count != 1 || m[0].0 != a || m[0].1 != amountKind { return false }
            }
            return texts("(~R$ 286)") == ["~R$ 286"]
        }())
        checkTrue("48 grouped digits and a final period",
                  texts("R$1.234,56") == ["R$1.234,56"] && texts("US$ 1,234.50") == ["US$ 1,234.50"]
                  && texts("custou R$ 286.") == ["R$ 286"] && texts("R$ 286,") == ["R$ 286"]
                  && texts("R$\u{00A0}12") == ["R$\u{00A0}12"])
        checkTrue("49 not amounts", ["R$", "R$ x", "R$  5", "XR$ 5", "$ 5", "€ 5", "286", "2490134", "50%"].allSatisfy { marks($0).isEmpty })
        checkTrue("50 dates and times", {
            let one = marks("ontem 07/10 09:25 BRT")
            return one.count == 1 && one[0].0 == "07/10 09:25" && one[0].1 == .time
                && texts("19/09") == ["19/09"] && texts("em 15/09.") == ["15/09"] && texts("01/10 20:38") == ["01/10 20:38"]
                && texts("tomou 15:34 BRT") == ["15:34"] && texts("07/10/2026") == ["07/10/2026"]
                && texts("10:30:15") == ["10:30:15"] && texts("07/10/26") == ["07/10/26"]
        }())
        checkTrue("51 plain hours and labels",
                  ["00h–08h", "13h", "12h", "BRT", "Conta 06", "v3", "code 17", "0 imp", "14 campanhas"].allSatisfy { marks($0).isEmpty })
        checkTrue("52 not dates or times", ["50/50", "24/7", "2007/10", "16:9", "1:1", "25:00", "12:345", "1/2", "src/10/20x", "10:30/11:30"].allSatisfy { marks($0).isEmpty })
        checkTrue("53 amount in a link and in a code span: no mark", {
            let a = (try? AttributedString(markdown: "[R$ 6,94](https://example.com) e `R$ 7,00` e 09:25",
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString("")
            return rules.marks(in: a).map { String(a[$0.range].characters) } == ["09:25"]
        }())
        checkTrue("54 ranges of the fixtures are inside and never overlap", {
            for s in [answerPlain, answerMarkdown, adriLines.joined(separator: " ")] {
                let m = ChatAnswerRules.marks(inPlain: s)
                for (i, a) in m.enumerated() {
                    if a.range.lowerBound < s.startIndex || a.range.upperBound > s.endIndex || a.range.isEmpty { return false }
                    for b in m[(i + 1)...] where a.range.overlaps(b.range) { return false }
                }
            }
            return true
        }())
        checkTrue("54b a status, an amount and a time in one line", {
            let m = marks("ACTIVE R$ 1,00 07/10")
            return m.map { $0.0 } == ["ACTIVE", "R$ 1,00", "07/10"]
        }())


        print("Review round 2: dates, times, amounts, leads")
        checkTrue("68 m2: a date never touches a colon", {
            ["10:30/11:30", "07/10:30", "10:07/10", "a 07/10:30 b"].allSatisfy { marks($0).isEmpty }
        }())
        checkTrue("69 m10: a bare date needs an end, a punctuation, a date word or a time", {
            texts("passou 10/12 testes").isEmpty && texts("12/12 ok").isEmpty && texts("teste 07/10 foi").isEmpty
                && texts("desde 19/09 foi") == ["19/09"] && texts("dia 07/10 tem") == ["07/10"]
                && texts("até 07/10 depois") == ["07/10"] && texts("ate 07/10 depois") == ["07/10"]
                && texts("em 07/10 foi") == ["07/10"] && texts("no 07/10 foi") == ["07/10"] && texts("na 07/10 foi") == ["07/10"]
                && texts("Ontem 07/10 foi") == ["07/10"] && texts("hoje 07/10 foi") == ["07/10"]
                && texts("on 07/10 was") == ["07/10"] && texts("Since 07/10 was") == ["07/10"]
                && texts("until 07/10 was") == ["07/10"] && texts("from 07/10 was") == ["07/10"]
                && texts("veja 07/10, depois") == ["07/10"] && texts("foi 07/10. Depois") == ["07/10"] && texts("(07/10) ok") == ["07/10"]
                && texts("vale 07/10") == ["07/10"] && texts("vale 07/10\noutra") == ["07/10"]
        }())
        checkTrue("69b m10: a year or a time always marks", {
            texts("passou 07/10/2026 testes") == ["07/10/2026"] && texts("foi 07/10/26 testes") == ["07/10/26"]
                && texts("passou 07/10 09:25 testes") == ["07/10 09:25"] && texts("passou 07/10 9:25 testes") == ["07/10 9:25"]
        }())
        checkTrue("69c m10: a bare time needs a two digit hour", {
            texts("às 9:05").isEmpty && texts("placar 2:15").isEmpty && texts("João 3:16").isEmpty
                && texts("às 09:05") == ["09:05"] && texts("tomou 15:34 BRT") == ["15:34"] && texts("10:30:15") == ["10:30:15"]
        }())
        checkTrue("69d m10 known cases, still marked (the rule cannot tell them apart)", {
            // A count at the end of the text, or before punctuation, and an aspect ratio with a two digit hour.
            texts("nota 10/10") == ["10/10"] && texts("passou 10/12.") == ["10/12"] && texts("16:10") == ["16:10"]
        }())
        checkTrue("70 m11: an amount followed by a glued letter, a magnitude word or a ratio is not marked", {
            ["R$ 1,5 mil", "R$ 1,5 Mil", "R$ 2 milhão", "R$ 2 milhao", "R$ 2 milhões", "R$ 2 milhoes", "R$ 2 bi", "R$ 2 k", "R$ 2 K",
             "R$ 2 bilhões", "US$5k", "US$ 5m", "R$ 12:30", "US$ 07/10", "R$ 5/2"].allSatisfy { s in !marks(s).contains { $0.1 == amountKind } }
                // The number after the colon or the slash may still be read as a time or a date, on its own.
                && texts("R$ 12:30") == ["12:30"] && texts("US$ 07/10") == ["07/10"]
        }())
        checkTrue("70b m11: near misses stay amounts", {
            texts("R$ 5 milagres") == ["R$ 5"] && texts("R$ 5 kits") == ["R$ 5"] && texts("R$ 5/mês") == ["R$ 5"]
                && texts("R$ 5: ok") == ["R$ 5"] && texts("R$ 5 por mês") == ["R$ 5"] && texts("R$ 5,") == ["R$ 5"]
        }())
        checkTrue("70c m11: a leading minus belongs to the amount", {
            texts("-R$ 5") == ["-R$ 5"] && texts("(-R$ 5,00)") == ["-R$ 5,00"] && texts("saldo −R$ 5") == ["−R$ 5"]
                && texts("-~R$ 5") == ["-~R$ 5"] && texts("x-R$ 5") == ["R$ 5"] && texts("5-R$ 3") == ["R$ 3"]
        }())
        checkTrue("71 m3: no lead when the second line has the shape of the first", {
            rules.lead(of: "Nome: Emma\nIdade: 30\nCidade: SP").lead == nil
                && rules.lead(of: "Conta 06\nConta 07\nConta 08").lead == nil
                && rules.lead(of: "Abraço\nAlfred").lead == nil
        }())
        checkTrue("71b m3: no lead on a closing quote or bracket after a sentence end", {
            let body = "O corpo da secao continua aqui com bastante texto para nao ser curto."
            return rules.lead(of: "Fim.\"\n" + body).lead == nil && rules.lead(of: "Pergunta?)\n" + body).lead == nil
                && rules.lead(of: "Fim!”\n" + body).lead == nil && rules.lead(of: "Fim.')\n" + body).lead == nil
                && rules.lead(of: "Nome (a vista)\n" + body).lead == "Nome (a vista)"
        }())
        checkTrue("71c m3: no lead on a URL", {
            let body = "O corpo da secao continua aqui com bastante texto para nao ser curto."
            return rules.lead(of: "https://example.com/a\n" + body).lead == nil && rules.lead(of: "http://example.com\n" + body).lead == nil
        }())
        checkTrue("71d m3: no lead when the first line is the first half of a wrapped sentence", {
            rules.lead(of: "I looked at the build and found that the tests are failing because\nthe fixture is missing from the repo.").lead == nil
        }())
        checkTrue("71e m3: real leads stay (fixtures and a short body)", {
            rules.lead(of: emmaLead + "\n" + emmaBody).lead == emmaLead
                && rules.lead(of: adriLead + "\n" + adriLines.joined(separator: "\n")).lead == adriLead
                && rules.lead(of: "Resumo\nTudo certo.").lead == "Resumo"
                // Known case: a greeting followed by a sentence is read as a title and a body.
                && rules.lead(of: "Oi Caio\nTudo certo por aqui.").lead == "Oi Caio"
        }())


        print("Review round 2: strip, open markers, dots, header")
        checkTrue("72 m1: the strip uses the scan of the body: a word in a bare URL, a link or a code span is no capsule", {
            rules.statusStrip(lines: ["veja https://x.com/ACTIVE"]).isEmpty
                && rules.statusStrip(lines: ["veja [o log ACTIVE](https://x.io/PAUSED)"]).isEmpty
                && rules.statusStrip(lines: ["veja `FAILED` e <https://x.io/DELETED>"]).isEmpty
                && rules.statusStrip(lines: ["veja https://x.com/ACTIVE e PAUSED"]) == ["PAUSED"]
        }())
        checkTrue("72b n1: the strip and the tinted body agree on emphasis", {
            rules.statusStrip(lines: ["_ACTIVE_ e **PAUSED**"]) == ["ACTIVE", "PAUSED"]
        }())
        checkTrue("73 m1 cost: sections of a 200 000 character answer with code and links", {
            var parts: [String] = []
            var i = 0
            var size = 0
            while size < 200_000 {
                let p = "Titulo da secao \(i) com `codigo` aqui\nO ad foi DISAPPROVED em 07/10 09:25 e custou R$ 6,94, veja [o log](https://x.io/\(i)) agora.\nOutra linha com `ACTIVE` e <b>x</b> mais texto para encher a linha numero \(i).\nTerceira linha ACTIVE PAUSED R$ 12,00 depois."
                parts.append(p); size += p.count + 2; i += 1
            }
            let blocks = ChatMarkdown.parse(parts.joined(separator: "\n\n"))
            var best = Double.infinity
            var count = 0
            for _ in 0..<3 {
                let t0 = Date()
                count = rules.sections(blocks: blocks, streaming: false, verdict: true).count
                best = min(best, Date().timeIntervalSince(t0))
            }
            print("    (\(i) sections, \(size) characters, sections() \(String(format: "%.1f", best * 1000)) ms, \(count) items)")
            return best < 0.05 && count > i
        }())
        checkTrue("74 m4: which body lines leave a marker open", {
            let open = ["**nota importante que", "[o log", "veja `codigo", "_isso", "~~riscado", "veja [o log](https://x.io"]
            let closed = ["nota **importante** aqui", "veja [o log](https://x.io)", "um `codigo` e `outro`", "snake_case_name e a_b", "5 * 3 = 15",
                          "a ``x ` y`` b", "[x] tarefa", "\\*escapado e \\[ solto", "**a** e _b_ e ~~c~~", "ACTIVE R$ 6,94 07/10", ""]
            return open.allSatisfy { rules.leavesMarkerOpen($0) } && closed.allSatisfy { !rules.leavesMarkerOpen($0) }
        }())
        checkTrue("74b m4: markdown that spans two lines is drawn as one text", {
            let split = ["**nota importante que", "continua aqui**"]
            let link = ["veja [o log", "completo](https://x.io)", "outra"]
            let fine = ["linha **um**", "linha dois"]
            return rules.bodyTexts(lines: split) == ["**nota importante que\ncontinua aqui**"]
                && rules.bodyTexts(lines: link) == ["veja [o log\ncompleto](https://x.io)\noutra"]
                && rules.bodyTexts(lines: fine) == fine && rules.bodyTexts(lines: []) == []
        }())
        checkTrue("74c m4: joining only adds newlines between the lines", {
            let lines = ["a **b", "c** d", "e"]
            return rules.bodyTexts(lines: lines).joined().replacingOccurrences(of: "\n", with: "") == lines.joined()
        }())
        let L = ChatTurnLayout.self
        checkTrue("75 m7/F2: the anchor replaces the dots when the turn draws a live box or its own dots", {
            func r(_ segs: [ChatSegment]?, typing: Bool = true, streaming: Bool = true) -> Bool {
                L.anchorReplacesDots(typing: typing, streamingLast: streaming, lastSegments: segs)
            }
            // A note only: the block shows its own dots (F2), so the surface block must not draw a second set.
            return r([note(0)]) && !r([]) && !r(nil)
                && r([step(0, "a", "x", .running)]) && r([step(0, "a")]) && r([hidden(0)]) && r([text(0, "frase", .interim)])
                && r([note(0), step(1, "a", "x", .running)]) && !r([note(0), text(1, "ok", .open)])
                && r([step(0, "a"), text(1, "ok", .answer)]) && !r([text(0, "ok", .answer)])
                && !r([step(0, "a")], typing: false) && !r([step(0, "a")], streaming: false)
        }())
        checkTrue("75b m7: a work group in the segments is what hasWork asks for", {
            let segs = [note(0)]
            let items = L.items(segments: segs, running: true)
            let hasGroup = items.contains { if case .group = $0 { return true }; return false }
            return !hasGroup && !L.hasWork(segs) && L.hasWork([step(0, "a")]) && L.hasWork([text(0, "x", .interim)]) && !L.hasWork([text(0, "x", .answer)])
        }())
        checkTrue("75c F2: a running turn that draws neither a live group nor a card shows its own dots, whatever the surface flag", {
            func dots(_ segs: [ChatSegment], running: Bool, typing: Bool = false) -> Bool {
                L.showsOwnDots(items: L.items(segments: segs, running: running), running: running, typing: typing)
            }
            return dots([note(0)], running: true)                                    // the only row is a note
                && dots([note(0), note(1)], running: true)
                && dots([text(0, "  ", .open)], running: true)                       // nothing drawn yet
                && dots([], running: true) && dots([], running: false, typing: true) && !dots([], running: false)
                && !dots([note(0)], running: false)                                  // a finished turn never
                && !dots([step(0, "a", "x", .running)], running: true)               // the live box has its own
                && !dots([note(0), step(1, "a")], running: true)
                && !dots([text(0, "frase", .interim)], running: true)
                && !dots([text(0, "ok", .open)], running: true)                      // an open card is on screen
                && !dots([text(0, "ok", .answer)], running: true)                    // so is a closed one
                && !dots([step(0, "a"), step(1, "b"), step(2, "c"), text(3, "ok", .answer)], running: true)
                && !dots([step(0, "a")], running: false)
        }())
        let H = ChatTurnHeader.self
        checkTrue("76 m8: answered needs an answer text", {
            func seg(_ role: ChatSegment.TextRole, _ t: String = "ok") -> ChatSegment { text(0, t, role) }
            return H.hasAnswer(segments: [], content: "oi") && !H.hasAnswer(segments: [], content: "")
                && H.hasAnswer(segments: [step(0, "a"), seg(.answer)], content: "")
                && !H.hasAnswer(segments: [step(0, "a"), seg(.interim)], content: "tem content")
                && !H.hasAnswer(segments: [step(0, "a"), note(1)], content: "")
                && !H.hasAnswer(segments: [seg(.answer, "")], content: "x")
        }())
        checkTrue("77 m9: a finished message is working only while it runs (the surface flag does not label an old reply)", {
            // The label has no typing input: the pending placeholder carries `.working` itself.
            H.label(running: true, isNotice: false, hasAnswer: false) == .working
                && H.label(running: true, isNotice: false, hasAnswer: true) == .working
                && H.label(running: false, isNotice: false, hasAnswer: true) == .answered
                && H.label(running: false, isNotice: false, hasAnswer: false) == .none
                && H.label(running: true, isNotice: true, hasAnswer: true) == .none
        }())
        checkTrue("78 n2: a text that ends with a rule has no trailing hairline", {
            let blocks = ChatMarkdown.parse("Um paragrafo.\n\n---")
            let shape = cardShape(rules.sections(blocks: blocks, streaming: false, verdict: false))
            let two = cardShape(rules.sections(blocks: ChatMarkdown.parse("Um.\n\n---\n\n---"), streaming: false, verdict: false))
            return shape == "p" && two == "p"
        }())

        checkTrue("79 m10: every date and time of the fixtures is still marked (one by one)", {
            let lines = [emmaBody] + adriLines
            let got = lines.flatMap { line in marks(line).filter { $0.1 == .time }.map { $0.0 } }
            let want = ["07/10 09:25", "19/09", "07/10 13:15", "15:34", "01/10 20:38", "15/09"]
            let short = marks("A campanha da Emma segue ACTIVE e gastou R$ 6,94 ontem às 09:25.").filter { $0.1 == .time }.map { $0.0 }
            return got == want && short == ["09:25"]
        }())
        checkTrue("79b m11: every amount of the fixtures is still marked", {
            let lines = [emmaBody] + adriLines + [receitaLine]
            let got = lines.flatMap { line in marks(line).filter { $0.1 == .amount }.map { $0.0 } }
            return got == ["R$ 6,94", "R$ 260,69", "~R$ 286", "R$ 50,28", "R$ 574,65", "~US$ 49", "~US$ 25"]
        }())

        print("Review round 3: strip scan, dates, amounts, leads")
        checkTrue("80 F1: the strip scans the texts the body draws (a marker open over two lines hides a word)", {
            rules.statusStrip(lines: ["veja `codigo", "ACTIVE` fim"]).isEmpty
                && rules.statusStrip(lines: ["veja [o log ACTIVE", "completo](https://x.io) PAUSED"]) == ["PAUSED"]
                && rules.statusStrip(lines: ["linha ACTIVE", "linha PAUSED"]) == ["ACTIVE", "PAUSED"]
        }())
        checkTrue("81 F4: a date before a colon and a space or the end is marked, before a colon and a digit it is not", {
            texts("07/10: caiu") == ["07/10"] && texts("em 07/10: caiu") == ["07/10"] && texts("campanha 07/10:") == ["07/10"]
                && texts("07/10:\nlinha") == ["07/10"]
                && marks("10:30/11:30").isEmpty && marks("07/10:30").isEmpty && marks("a 07/10:30 b").isEmpty
                // the two times case stays plain
                && texts("10:30-11:30") == ["10:30", "11:30"]
        }())
        checkTrue("82 lead: a short title over one short body line with no final period is a lead (reviewer inputs, round 2)", {
            let inputs = [
                "Emma Baker (Conta 06)\nAdset ACTIVE, orçamento intacto",
                "Emma Baker (Conta 06)\nMeta derrubou o anúncio que entregava (política de conteúdo adulto)",
                "Como conferi\nRodei o script e bateu com o painel",
                "Emma Baker (Conta 06)\n**DISAPPROVED** desde ontem",
            ]
            return inputs.allSatisfy { rules.lead(of: $0).lead == $0.components(separatedBy: "\n")[0] }
        }())
        checkTrue("82b lead: a short title over a body that starts in lower case is a lead", {
            let inputs = [
                "Build\nxcodebuild falhou no target CoucouPhone…",
                "Emma Baker (Conta 06)\niOS e Android afetados…",
                "Resumo\nnenhum erro encontrado…",
            ]
            return inputs.allSatisfy { rules.lead(of: $0).lead == $0.components(separatedBy: "\n")[0] }
        }())
        checkTrue("82c lead: a colon deep in the body is not a key and value list", {
            let r = rules.lead(of: "Conta 06: Emma Baker\nO ad foi DISAPPROVED ontem. Motivo: proposta de cunho sexual.")
            return r.lead == "Conta 06: Emma Baker" && r.lines == ["O ad foi DISAPPROVED ontem. Motivo: proposta de cunho sexual."]
        }())
        checkTrue("82d lead: what real text loses stays excluded (peers, key and value, wrapped sentence, sign off)", {
            rules.lead(of: "Nome: Emma\nIdade: 30").lead == nil
                && rules.lead(of: "Nome: Emma\nIdade: 30\nCidade: SP").lead == nil
                && rules.lead(of: "Conta 06\nConta 07\nConta 08").lead == nil
                && rules.lead(of: "Emma Baker (Conta 06)\nAdset ACTIVE\nOrçamento R$ 260,69\nIrmão PAUSED desde 19/09").lead == nil
                && rules.lead(of: "Abraço\nAlfred").lead == nil
                && rules.lead(of: "Conta 06: Emma Baker\nOutra chave: valor").lead == nil
                && rules.lead(of: "I looked at the build and found that the tests are failing because\nthe fixture is missing").lead == nil
                && rules.lead(of: "Resumo da investigacao de ontem na conta seis do cliente\nnenhum erro encontrado").lead == nil
        }())
        checkTrue("82e lead: the real fixtures keep their leads", {
            rules.lead(of: emmaLead + "\n" + emmaBody).lead == emmaLead
                && rules.lead(of: adriLead + "\n" + adriLines.joined(separator: "\n")).lead == adriLead
        }())
        checkTrue("83 dates: both dates of a range are marked", {
            texts("07/10 a 08/10") == ["07/10", "08/10"] && texts("de 07/10 a 08/10") == ["07/10", "08/10"]
                && texts("07/10-08/10") == ["07/10", "08/10"] && texts("07/10 – 08/10") == ["07/10", "08/10"]
                && texts("07/10 — 08/10") == ["07/10", "08/10"] && texts("07/10 - 08/10 testes") == ["07/10", "08/10"]
                && texts("entre 07/10 e 08/10") == ["07/10", "08/10"] && texts("07/10 e 08/10 foram") == ["07/10", "08/10"]
                && texts("07/10 ate 08/10 foi") == ["07/10", "08/10"] && texts("07/10 até 08/10 foi") == ["07/10", "08/10"]
                && texts("07/10 to 08/10 was") == ["07/10", "08/10"] && texts("07/10 and 08/10 were") == ["07/10", "08/10"]
                && texts("07/10 a 08/10/2026 ok") == ["07/10", "08/10/2026"]
                // a connector alone, or a word that only starts like one, is not a range
                && texts("07/10 a casa") .isEmpty && texts("07/10 and testes").isEmpty && texts("07/10 abc 08/10 foi") == []
        }())
        checkTrue("84 dates: de, do, da, of and the weekdays are date words", {
            texts("o deploy de 07/10 passou") == ["07/10"] && texts("do 07/10 foi") == ["07/10"]
                && texts("da 07/10 foi") == ["07/10"] && texts("of 07/10 was") == ["07/10"]
                && ["sexta 07/10 foi", "Sexta-feira 07/10 foi", "terça 07/10 foi", "terca-feira 07/10 foi", "segunda 07/10 foi",
                    "quarta 07/10 foi", "quinta 07/10 foi", "sábado 07/10 foi", "sabado 07/10 foi", "domingo 07/10 foi",
                    "Monday 07/10 was", "tuesday 07/10 was", "Wednesday 07/10 was", "thursday 07/10 was", "friday 07/10 was",
                    "Saturday 07/10 was", "sunday 07/10 was"].allSatisfy { texts($0) == ["07/10"] }
        }())
        checkTrue("84b dates: a bare date before an opening parenthesis is marked", {
            texts("07/10 (terça)") == ["07/10"] && texts("07/10(terça)") == ["07/10"] && texts("07/10 (terça) foi") == ["07/10"]
        }())
        checkTrue("84c dates: the false positives that are plain today stay plain", {
            texts("passou 10/12 testes").isEmpty && texts("12/12 ok").isEmpty && texts("placar 2:15").isEmpty
                && texts("João 3:16").isEmpty && texts("às 9:05").isEmpty && texts("teste 07/10 foi").isEmpty
        }())
        checkTrue("84d dates: known wrong cases, recorded", {
            // Plain, though they are dates: no date word, and no rule for "às", a bullet or a lone date before a word.
            texts("Reunião 07/10 às 15h").isEmpty && texts("07/10 caiu").isEmpty && texts("- 07/10 caiu").isEmpty
                // Marked, though they are counts: the date words also precede a count.
                && texts("em 10/12 testes") == ["10/12"] && texts("de 10/12 testes") == ["10/12"]
                && texts("10/12 e 11/12 testes") == ["10/12", "11/12"]
        }())
        checkTrue("85 amounts: mi, MM and M as a whole word are short forms of million", {
            ["R$ 5 mi", "R$ 1,5 mi", "R$ 5 MM", "R$ 5 M", "US$ 2 mm", "R$ 5\u{00A0}Mi", "R$ 5 M."].allSatisfy { s in
                !marks(s).contains { $0.1 == amountKind }
            }
        }())
        checkTrue("85b amounts: near misses of the short forms stay amounts", {
            texts("R$ 5 mês") == ["R$ 5"] && texts("R$ 5 mim") == ["R$ 5"] && texts("R$ 5 Mbps") == ["R$ 5"]
                && texts("R$ 5 m2") == ["R$ 5"] && texts("R$ 5 mi2") == ["R$ 5"]
        }())

        print("Ask")
        func ask(_ blocks: [MDBlock], streaming: Bool = false) -> [Bool] {
            blocks.enumerated().map { rules.isAsk(block: $0.element, index: $0.offset, count: blocks.count, streaming: streaming) }
        }
        checkTrue("55 answerPlain finished: the last paragraph is the ask", ask(plain).last == true && ask(plain).dropLast().allSatisfy { !$0 })
        checkTrue("56 streaming: no ask", ask(plain, streaming: true).allSatisfy { !$0 })
        checkTrue("57 the whole answer is one question: no ask", ask(ChatMarkdown.parse("Quer que eu recrie as duas?")) == [false])
        checkTrue("58 question in the middle: no ask", ask(ChatMarkdown.parse("Quer?\n\nFeito.")).allSatisfy { !$0 })
        checkTrue("59 two paragraphs ending in ?: only the last", ask(ChatMarkdown.parse("Quer?\n\nE agora?")) == [false, true])
        checkTrue("60 question mark inside code: no ask", ask(ChatMarkdown.parse("a\n\nveja `a?`")).allSatisfy { !$0 })
        checkTrue("61 **Quer?** is an ask", ask(ChatMarkdown.parse("a\n\n**Quer?**")) == [false, true]
                  && ask(ChatMarkdown.parse("a\n\nquer _isso?_")) == [false, true])
        checkTrue("62 401 characters: no ask, 400: ask", {
            let q400 = String(repeating: "a", count: 399) + "?", q401 = String(repeating: "a", count: 400) + "?"
            return ask(ChatMarkdown.parse("a\n\n" + q400)) == [false, true] && ask(ChatMarkdown.parse("a\n\n" + q401)) == [false, false]
        }())
        checkTrue("63 a list item ending in ? is not an ask", ask(ChatMarkdown.parse("a\n\n- quer?")).allSatisfy { !$0 })
        checkTrue("63b full width question mark", ask(ChatMarkdown.parse("a\n\nquer？")) == [false, true])
        checkTrue("63c ask beats lead and keeps its newlines", {
            let blocks = ChatMarkdown.parse("a\n\nTitulo curto\nquer isso?")
            let items = rules.sections(blocks: blocks, streaming: false, verdict: false)
            guard case .ask(let t) = items.last else { return false }
            return t == "Titulo curto\nquer isso?"
        }())

        print("Header")
        let label = ChatTurnHeader.label
        checkTrue("64 labels",
                  label(true, false, true) == .working && label(false, true, true) == .none
                  && label(false, false, false) == .none && label(false, false, true) == .answered)

        print("Hostile and size")
        checkTrue("65 200 000 characters of marks: fast, capped", {
            let big = String(String(repeating: "ACTIVE R$ 1,00 07/10 ", count: 10_000).prefix(200_000))
            let t0 = Date()
            let m = ChatAnswerRules.marks(inPlain: big)
            let dt = Date().timeIntervalSince(t0)
            print("    (\(String(format: "%.3f", dt)) s, \(m.count) marks)")
            return dt < 2 && m.count == ChatAnswerRules.maxMarksPerBlock
        }())
        checkTrue("66 200 000 characters, one line, no space", {
            let big = String(repeating: "a", count: 200_000)
            let t0 = Date()
            let r = rules.lead(of: big)
            let ok = r.lead == nil && r.lines == [big] && ChatAnswerRules.marks(inPlain: big).isEmpty
            return ok && Date().timeIntervalSince(t0) < 2
        }())
        checkTrue("66b 200 000 characters of capitals and digits", {
            let big = String(repeating: "AB12:", count: 40_000)
            let t0 = Date()
            _ = ChatAnswerRules.marks(inPlain: big)
            return Date().timeIntervalSince(t0) < 2
        }())
        checkTrue("67 empty, newlines, a lone question mark: no crash", {
            _ = rules.lead(of: "")
            _ = rules.lead(of: "\n\n\n")
            _ = rules.lead(of: "?")
            _ = ChatAnswerRules.marks(inPlain: "")
            let one = rules.sections(blocks: ChatMarkdown.parse("?"), streaming: false, verdict: true)
            let none = rules.sections(blocks: [], streaming: false, verdict: true)
            return cardShape(one) == "verdict" && none.isEmpty
        }())

        // MARK: Media directives in the card
        let voiceText = "Primeiro áudio. 6s.\n\n[[audio_as_voice]]\nMEDIA:/tmp/a.ogg\n\nOuve e me fala o ajuste."
        let voice = ChatMediaDirectives.extract(voiceText, streaming: false)
        checkTrue("media-1 a row sits where the directive was: verdict, row, body", {
            let items = rules.sections(blocks: ChatMarkdown.parse(voice.marked), streaming: false, verdict: true, attachments: voice.attachments.count)
            return cardShape(items) == "verdict att0 p"
        }())
        checkTrue("media-2 a question before the row is still the ask; the row follows it", {
            let r = ChatMediaDirectives.extract("Resumo curto.\n\nQuer que eu mande?\n\nMEDIA:/tmp/a.png", streaming: false)
            let items = rules.sections(blocks: ChatMarkdown.parse(r.marked), streaming: false, verdict: false, attachments: r.attachments.count)
            return cardShape(items).contains("ask") && cardShape(items).hasSuffix("att0")
        }())
        checkTrue("media-3 only directives: the card is only the row", {
            let r = ChatMediaDirectives.extract("[[audio_as_voice]]\nMEDIA:/tmp/a.ogg", streaming: false)
            return cardShape(rules.sections(blocks: ChatMarkdown.parse(r.marked), streaming: false, verdict: true, attachments: r.attachments.count)) == "att0"
        }())
        checkTrue("media-4 a title tag is never a lead", {
            rules.lead(of: "[[something_else]]\nresto do texto aqui").lead == nil
        }())
        checkTrue("media-5 a text with directives and the same without them have the same card, plus the row", {
            let plain = rules.sections(blocks: ChatMarkdown.parse(voice.text), streaming: false, verdict: true)
            let marked = rules.sections(blocks: ChatMarkdown.parse(voice.marked), streaming: false, verdict: true, attachments: voice.attachments.count)
            return marked.filter { if case .attachment = $0 { return false }; return true } == plain
        }())
        checkTrue("media-6 items: a text that is only a held back directive makes no card, with media on", {
            let seg = [ChatSegment(id: 0, kind: .text("[[audio_as", role: .open))]
            return ChatTurnLayout.items(segments: seg, running: true, media: true).isEmpty
                && ChatTurnLayout.items(segments: seg, running: true, media: false).count == 1
        }())
        checkTrue("media-7 items: a text that is only directives still makes its card", {
            let seg = [ChatSegment(id: 0, kind: .text("[[audio_as_voice]]\nMEDIA:/tmp/a.ogg", role: .answer))]
            return shape(ChatTurnLayout.items(segments: seg, running: false, media: true)) == "card"
        }())
        // A guard, not a proof of this change: `hasAnswer` was not touched (it holds on main too). It pins that a turn made of
        // one directive still counts as an answer for the header.
        checkTrue("media-8 (guard, holds on main too) hasAnswer: a turn that is only a file is an answer", ChatTurnHeader.hasAnswer(
            segments: [ChatSegment(id: 0, kind: .text("MEDIA:/tmp/a.png", role: .answer))], content: "MEDIA:/tmp/a.png"))
        checkTrue("media-9 a paragraph that only looks like a slot is a paragraph, unless the parse made that row (Aegis N1)", {
            let forged = ChatMarkdown.parse("antes\n\n\(ChatMediaDirectives.slotLine(0))\n\ndepois")
            let none = rules.sections(blocks: forged, streaming: false, verdict: false)
            let real = rules.sections(blocks: forged, streaming: false, verdict: false, attachments: 1)
            return !cardShape(none).contains("att") && cardShape(none).contains("p") && cardShape(real).contains("att0")
        }())
        checkTrue("media-10 the typing anchor agrees with the list: a held back directive is no card, so the block shows its own dots and the anchor gives way", {
            let seg = [ChatSegment(id: 0, kind: .step(ChatStep(callId: "c", tool: "bash", label: "ls", detail: nil, status: .running))), ChatSegment(id: 1, kind: .text("[[audio_as", role: .open))]
            // A turn with work and a text that is only the start of a directive: the work box is alive, the dots give way.
            let on = ChatTurnLayout.anchorReplacesDots(typing: true, streamingLast: true, lastSegments: seg, media: true)
            let onlyHeld = [ChatSegment(id: 0, kind: .text("[[audio_as", role: .open))]
            let a = ChatTurnLayout.anchorReplacesDots(typing: true, streamingLast: true, lastSegments: onlyHeld, media: true)
            let b = ChatTurnLayout.anchorReplacesDots(typing: true, streamingLast: true, lastSegments: onlyHeld, media: false)
            return on && a && !b
        }())

        timelineCases()

        print(failures == 0 ? "\nAll ChatAnswerStyle tests passed." : "\n\(failures) ChatAnswerStyle test(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - cmux timeline rows (edits and moments)

    static func edit(_ id: Int, _ path: String = "A.swift", added: Int = 3, removed: Int = 1, diffId: Int? = nil) -> ChatSegment {
        ChatSegment(id: id, kind: .edit(ChatEdit(callId: "e\(id)", tool: "Edita", symbol: "pencil", name: path, path: "/p/" + path,
                                                 added: added, removed: removed, isNewFile: false, tooLarge: false, preview: [], diffId: diffId)))
    }
    static func moment(_ id: Int, _ kind: ChatMoment.Kind, _ outcome: ChatMoment.Outcome, key: String = "") -> ChatSegment {
        ChatSegment(id: id, kind: .moment(ChatMoment(kind: kind, callId: key, text: "t", more: 0, outcome: outcome)))
    }

    static func timelineCases() {
        print("ChatTurnLayout: edits and moments")
        let answer = text(99, "Done.", .answer)

        // 44
        let t44 = [step(0, "Lê"), step(1, "Executa"), edit(2), step(3, "Lê"), answer]
        let i44 = ChatTurnLayout.items(segments: t44, running: false)
        checkTrue("44 steps, an edit, steps, an answer: one folded group that holds the edit, then the card",
                  shape(i44) == "group:folded,card" && {
                      if case .group(let g, _) = i44[0] { return g.rows.count == 4 && g.rows.contains { if case .edit = $0.kind { return true }; return false } }
                      return false
                  }())

        // 45
        checkTrue("45 one step and one edit, no interim: mode rows",
                  shape(ChatTurnLayout.items(segments: [step(0, "Lê"), edit(1)], running: false)) == "group:rows")
        checkTrue("45b three rows with an edit fold",
                  shape(ChatTurnLayout.items(segments: [step(0, "Lê"), edit(1), edit(2, "B.swift")], running: false)) == "group:folded")

        // 46
        let t46 = [step(0, "Lê"), moment(1, .permission, .waiting, key: "k"), step(2, "Executa", "x", .running)]
        let i46 = ChatTurnLayout.items(segments: t46, running: true)
        checkTrue("46 a waiting moment in the middle of a run: emitted right after the group, never inside it",
                  shape(i46) == "group:live,moment" && {
                      if case .group(let g, _) = i46[0] { return g.rows.count == 2 && !g.rows.contains { if case .moment = $0.kind { return true }; return false } }
                      return false
                  }())

        // 47
        let t47 = [step(0, "Lê"), step(1, "Lê"), step(2, "Lê"),
                   moment(3, .permission, .denied, key: "a"), moment(4, .question, .answered("A")),
                   moment(5, .permission, .handled, key: "b"), answer]
        let i47 = ChatTurnLayout.items(segments: t47, running: false)
        checkTrue("47 a denied permission and an answered question stay outside, a handled permission stays in the group",
                  shape(i47) == "group:folded,moment,moment,card" && {
                      if case .group(let g, _) = i47[0] { return g.rows.count == 4 && g.rows.last?.id == 5 }
                      return false
                  }())
        checkTrue("47b a handled question stays outside",
                  shape(ChatTurnLayout.items(segments: [step(0, "Lê"), moment(1, .question, .handled)], running: false)) == "group:rows,moment")
        checkTrue("47c an in terminal permission stays outside",
                  shape(ChatTurnLayout.items(segments: [step(0, "Lê"), moment(1, .permission, .inTerminal, key: "k")], running: false)) == "group:rows,moment")
        checkTrue("47d a moment alone, with no group before it, is its own item",
                  shape(ChatTurnLayout.items(segments: [moment(0, .permission, .waiting, key: "k")], running: true)) == "moment")

        // 48
        let t48 = [step(0, "Lê"), moment(1, .permission, .allowed, key: "z"), step(2, "Lê"), step(3, "Lê")]
        let i48 = ChatTurnLayout.items(segments: t48, running: false)
        checkTrue("48 an allowed moment with no step is a row of the group and does not count",
                  shape(i48) == "group:folded" && {
                      if case .group(let g, _) = i48[0] { return g.rows.count == 4 && ChatWorkSummary(group: g).count == 3 }
                      return false
                  }())

        // 49
        let g49 = ChatTurnLayout.WorkGroup(id: 0, rows: [step(0, "Lê"), edit(1), edit(2, "B.swift"), step(3, "Executa")])
        let s49 = ChatWorkSummary(group: g49)
        checkTrue("49 ChatWorkSummary: an edit counts in count and in its tool chip",
                  s49.count == 4 && s49.tools.first == ChatWorkSummary.ToolCount(tool: "Edita", count: 2, symbol: "pencil"))
        checkTrue("49b the other tools keep no symbol of their own", s49.tools.contains { $0.tool == "Lê" && $0.symbol == nil })

        // 50
        let g50 = ChatTurnLayout.WorkGroup(id: 0, rows: [edit(0, "A.swift", added: 12, removed: 3, diffId: 1), step(1, "Lê"),
                                                         edit(2, "B.swift", added: 40, removed: 0, diffId: 2),
                                                         edit(3, "A.swift", added: 2, removed: 1, diffId: 3)])
        let f50 = ChatWorkSummary.files(group: g50)
        checkTrue("50 files(group:): two edits of one path are one entry with summed counts and the newest diff id, in order of first edit",
                  f50.map(\.name) == ["A.swift", "B.swift"] && f50[0].added == 14 && f50[0].removed == 4 && f50[0].diffId == 3
                  && f50[1].added == 40 && f50[1].removed == 0)
        let many = ChatTurnLayout.WorkGroup(id: 0, rows: (0..<60).map { edit($0, "f\($0).swift") })
        checkTrue("50b at most 40 files", ChatWorkSummary.files(group: many).count == 40)

        // 51
        checkTrue("51 hasWork: an edit is work, a moment alone is not",
                  ChatTurnLayout.hasWork([edit(0)]) && !ChatTurnLayout.hasWork([moment(0, .permission, .waiting, key: "k")])
                  && !ChatTurnLayout.hasWork([moment(0, .question, .answered("x"))]))

        // 52
        let waitOnly = ChatTurnLayout.items(segments: [moment(0, .permission, .waiting, key: "k")], running: true)
        let deniedOnly = ChatTurnLayout.items(segments: [moment(0, .permission, .denied, key: "k")], running: true)
        checkTrue("52 showsOwnDots: false for a running turn whose only item is a waiting moment, true when it is a denied one",
                  !ChatTurnLayout.showsOwnDots(items: waitOnly, running: true, typing: true)
                  && ChatTurnLayout.showsOwnDots(items: deniedOnly, running: true, typing: true))
        checkTrue("52b the typing anchor gives way to a block that waits for the user",
                  ChatTurnLayout.anchorReplacesDots(typing: true, streamingLast: true, lastSegments: [moment(0, .permission, .waiting, key: "k")])
                  && !ChatTurnLayout.anchorReplacesDots(typing: false, streamingLast: true, lastSegments: [moment(0, .permission, .waiting, key: "k")]))

        // 53
        let g53 = ChatTurnLayout.WorkGroup(id: 0, rows: [step(0, "Lê"), step(1, "Executa", "x", .running), edit(2)])
        checkTrue("53 liveStep: the running step, else the last row, an edit included",
                  ChatWorkSummary.liveStep(group: g53)?.segmentId == 1
                  && ChatWorkSummary.liveStep(group: .init(id: 0, rows: [step(0, "Lê"), edit(1)]))?.segmentId == 1
                  && ChatWorkSummary.liveStep(group: .init(id: 0, rows: [step(0, "Lê"), edit(1)]))?.step.tool == "Edita")
        checkTrue("53b a running step that waits for the user is not the live one",
                  ChatWorkSummary.liveStep(group: .init(id: 0, rows: [step(0, "Lê"), step(1, "Executa", "x", .running)]), awaiting: ["c1"])?.segmentId == 0
                  && ChatWorkSummary.liveStep(group: .init(id: 0, rows: [step(0, "Executa", "x", .running)]), awaiting: ["c0"]) == nil)
        checkTrue("53c with no awaiting key nothing changes (the default)",
                  ChatWorkSummary.liveStep(group: g53) == ChatWorkSummary.liveStep(group: g53, awaiting: []))

        // 53d: a request handled in the terminal is most likely allowed there: its running step is the live one
        let t53d = [step(0, "Lê"), step(1, "Executa", "x", .running), moment(2, .permission, .handled, key: "c1")]
        let i53d = ChatTurnLayout.items(segments: t53d, running: true)
        checkTrue("53d a handled permission is not awaiting: its running step is the live step",
                  ChatTurnLayout.awaitingKeys(i53d) == []
                  && ChatWorkSummary.liveStep(group: { if case .group(let g, _) = i53d[0] { return g }; return .init(id: 0, rows: []) }(),
                                              awaiting: ChatTurnLayout.awaitingKeys(i53d))?.segmentId == 1)
        checkTrue("53e a permission that was allowed, denied or handled is not in the set, one that waits or is in the terminal is",
                  ChatTurnLayout.awaitingKeys(ChatTurnLayout.items(segments: [step(0, "Lê"), moment(1, .permission, .allowed, key: "k"), moment(2, .permission, .denied, key: "d")], running: false)) == []
                  && ChatTurnLayout.awaitingKeys(ChatTurnLayout.items(segments: [step(0, "Lê"), moment(1, .permission, .waiting, key: "w"), moment(2, .permission, .inTerminal, key: "t")], running: true)) == ["w", "t"])

        // 54
        let t54 = [step(0, "Lê"), edit(1), step(2, "Executa", "x", .running), moment(3, .permission, .waiting, key: "c2")]
        let i54 = ChatTurnLayout.items(segments: t54, running: true)
        checkTrue("54 a running turn with an edit and a waiting moment: the group is live, the moment follows it",
                  shape(i54) == "group:live,moment" && ChatTurnLayout.awaitingKeys(i54) == ["c2"])
        checkTrue("54b the header says the turn waits for the user, and only then",
                  ChatTurnHeader.turnLabel(running: true, isNotice: false, hasAnswer: false, waitsForUser: ChatTurnLayout.waitsForUser(t54)) == .waitingForYou
                  && ChatTurnHeader.turnLabel(running: true, isNotice: false, hasAnswer: false, waitsForUser: ChatTurnLayout.waitsForUser([step(0, "Lê")])) == .working
                  && ChatTurnHeader.label(running: false, isNotice: false, hasAnswer: true) == .answered
                  && ChatTurnHeader.turnLabel(running: true, isNotice: true, hasAnswer: false, waitsForUser: true) == .none)

        // 55: a turn with only steps and text gives exactly the items it gives today
        let screenshot = screenshotTurn()
        checkTrue("55 a turn with only steps and text: the screenshot turn is still one folded group and one card",
                  shape(ChatTurnLayout.items(segments: screenshot, running: false)) == "group:folded,card"
                  && shape(ChatTurnLayout.items(segments: screenshotTurn(answerRole: .open), running: true)) == "group:live,card:open"
                  && shape(ChatTurnLayout.items(segments: [step(0, "a"), step(1, "b"), note(2)], running: false)) == "group:rows,note"
                  && ChatTurnHeader.label(running: true, isNotice: false, hasAnswer: false) == .working
                  && ChatWorkSummary.liveStep(group: .init(id: 0, rows: [step(0, "a"), step(1, "b", "x", .running)]))?.number == 2)

        // 56: the mail plan card is drawn only for a shared chat turn asked with Mail on
        let planText = "Done.\n```coucou-mail\n{\"actions\":[]}\n```"
        checkTrue("56 mail plan: asked with Mail on, the block is a plan card",
                  ChatTurnLayout.shouldShowMailPlan(askedWithMail: true, text: planText))
        checkTrue("56b mail plan: Mail off or a Hermes agent (never asked with Mail), the block is plain markdown",
                  !ChatTurnLayout.shouldShowMailPlan(askedWithMail: false, text: planText))
        checkTrue("56c mail plan: no block in the text, no plan",
                  !ChatTurnLayout.shouldShowMailPlan(askedWithMail: true, text: "Just text"))
    }
}
