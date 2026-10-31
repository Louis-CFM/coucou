#if !APPSTORE
import AppKit
import Foundation
import PDFKit

/// One mail a plan will send, ready to show and to send.
struct PreparedMail: Identifiable, Equatable {
    let id = UUID()
    var to: [String]
    var cc: [String] = []
    var subject: String
    var body: String
    var attachments: [URL] = []
    /// Why it can't be sent (no page found, bad address): shown in red, skipped.
    var problem: String? = nil
}

/// A plan of the chat, from its card appearing to its last mail sent.
struct MailPlanRun: Equatable {
    enum Phase: Equatable {
        case preparing
        case ready
        case countdown(Int)
        case running(done: Int, total: Int)
        case done(ok: Int, failed: Int)
        case cancelled
    }

    var phase: Phase = .preparing
    var sorts: [(action: MailRuleAction, messages: [MailMessage])] = []
    var replies: [(message: MailMessage, body: String)] = []
    var mails: [PreparedMail] = []
    var saves: [(message: MailMessage, folder: String)] = []
    /// What could not be prepared, in orange.
    var notes: [String] = []
    var testSentTo: String? = nil

    var stepCount: Int {
        sorts.reduce(0) { $0 + $1.messages.count } + replies.count + mails.filter { $0.problem == nil }.count + saves.count
    }

    static func == (a: MailPlanRun, b: MailPlanRun) -> Bool {
        a.phase == b.phase && a.mails == b.mails && a.notes == b.notes && a.testSentTo == b.testSentTo
            && a.sorts.count == b.sorts.count && a.replies.count == b.replies.count && a.saves.count == b.saves.count
    }
}

/// The chat's Mail switch: gives the AI the latest messages, then turns the plan it writes
/// (MailPlan.swift) into a card. Nothing runs before the user's click on Run, and a 5-second
/// countdown lets them stop it. GitHub build only (Apple Events).
@MainActor
final class MailAgent: ObservableObject {
    static let shared = MailAgent()

    /// Plans by the id of the chat message that holds them.
    @Published private(set) var runs: [UUID: MailPlanRun] = [:]

    /// The messages of the last list sent to the AI, by their number.
    private var numbered: [Int: MailMessage] = [:]
    private var accounts: [(name: String, address: String)] = []
    private var cancelled = Set<UUID>()
    private let mail = MailController.shared

    /// Where a plan's files are made (saved attachments, PDF pages); emptied at launch.
    private let workDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-mail-plans", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        return dir
    }()

    /// The address a test goes to: the first account's.
    var myAddress: String? { accounts.first(where: { !$0.address.isEmpty })?.address }

    // MARK: - Before the turn

    /// The user's request with the latest messages under it, for the AI.
    func decorate(_ query: String) async -> String {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == MailController.bundleId }) else {
            return query + "\n\n<mail>Mail is closed: ask the user to open the Mail app, then to ask again.</mail>"
        }
        if case .success(let v) = await mail.runAppleScript(MailScript.accountsScript), let text = v.first {
            accounts = text.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
                return f.count >= 2 ? (f[0], f[1]) : nil
            }
        }
        var list: [MailMessage] = []
        if case .success(let v) = await mail.runAppleScript(MailController.listScript(perInbox: 20)), let text = v.first {
            list = Array(MailController.parseList(text).messages.sorted { $0.date > $1.date }.prefix(40))
        }
        numbered = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($0.offset + 1, $0.element) })
        let named = Set(MailAgentPrompt.mentioned(in: query, senders: list.map(\.sender), subjects: list.map(\.subject)))
        var lines: [MailAgentPrompt.Line] = []
        for (i, m) in list.enumerated() {
            var line = MailAgentPrompt.Line(number: i + 1, sender: m.sender, subject: m.subject, date: m.date,
                                            isRead: m.isRead, account: m.account)
            // The messages the request names get their text; the newest ones their attachments.
            if named.contains(i) || i < 8 {
                let d = await details(m, textLimit: named.contains(i) ? 3000 : 300)
                line.attachments = d.attachments
                line.text = d.text
            }
            lines.append(line)
        }
        return query + MailAgentPrompt.snapshot(lines, accounts: accounts)
    }

    private func details(_ m: MailMessage, textLimit: Int) async -> (attachments: [String], text: String) {
        let script = MailScript.detailsScript(account: m.account, mailbox: m.mailbox, messageId: m.messageId, textLimit: textLimit)
        guard case .success(let v) = await mail.runAppleScript(script), let out = v.first else { return ([], "") }
        let parts = out.split(separator: "\u{1E}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let names = (parts.first ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let text = (parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
        return (names, text)
    }

    // MARK: - The card

    /// Called when a chat message holding a plan is shown: prepares it once.
    func show(_ plan: MailPlan, for id: UUID) {
        guard runs[id] == nil else { return }
        runs[id] = MailPlanRun()
        Task { await prepare(plan, id: id) }
    }

    private func prepare(_ plan: MailPlan, id: UUID) async {
        var run = MailPlanRun()
        func message(_ n: Int) -> MailMessage? {
            if let m = numbered[n] { return m }
            run.notes.append(String(format: String(localized: "mail.plan.missing %lld"), Int64(n)))
            return nil
        }
        for action in plan.actions {
            switch action {
            case .sort(let act, let numbers):
                let ms = numbers.compactMap(message)
                if !ms.isEmpty { run.sorts.append((action: act, messages: ms)) }
            case .reply(let n, let body):
                if let m = message(n) { run.replies.append((message: m, body: body)) }
            case .saveAttachments(let n, let folder):
                if let m = message(n) { run.saves.append((message: m, folder: folder)) }
            case .send(let out):
                var files: [URL] = []
                if let n = out.attachmentsFrom, let m = message(n) {
                    files += await saveAttachments(of: m, onlyName: nil)
                }
                for path in out.files {
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    if FileManager.default.fileExists(atPath: url.path) { files.append(url) }
                    else { run.notes.append(String(format: String(localized: "mail.plan.file-missing %@"), path)) }
                }
                let bad = (out.to + out.cc).first { !MailAddress.isValid($0) }
                run.mails.append(PreparedMail(to: out.to, cc: out.cc, subject: out.subject, body: out.body,
                                              attachments: files,
                                              problem: bad.map { _ in String(localized: "mail.plan.bad-address") }))
            case .merge(let merge):
                let source = merge.fromMessage.flatMap { message($0) }
                await prepareMerge(merge, source: source, into: &run)
            }
        }
        run.phase = .ready
        runs[id] = run
    }

    private func prepareMerge(_ merge: MailMerge, source: MailMessage?, into run: inout MailPlanRun) async {
        // The PDF: a file on the Mac, or one of a message's attachments.
        var pdf: URL?
        if let file = merge.file {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { pdf = url }
            else { run.notes.append(String(format: String(localized: "mail.plan.file-missing %@"), file)) }
        } else if let m = source {
            var name = merge.attachment
            if name == nil {
                name = await details(m, textLimit: 1).attachments.first { $0.lowercased().hasSuffix(".pdf") }
            }
            if let name {
                pdf = await saveAttachments(of: m, onlyName: name).first
            }
            if pdf == nil { run.notes.append(String(localized: "mail.plan.no-pdf")) }
        }
        var pageFiles: [URL] = []
        var pageTexts: [String] = []
        if let pdf, let doc = PDFDocument(url: pdf) {
            if merge.splitPages {
                let dir = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    pageTexts.append(page.string ?? "")
                    let single = PDFDocument()
                    if let copy = page.copy() as? PDFPage { single.insert(copy, at: 0) }
                    // Named after its recipient once matched; page order for now.
                    let url = dir.appendingPathComponent("p\(i + 1).pdf")
                    single.write(to: url)
                    pageFiles.append(url)
                }
            }
        } else if pdf != nil {
            run.notes.append(String(localized: "mail.plan.no-pdf"))
        }
        let assignments: [MailMergeMatching.Assignment]
        if merge.splitPages {
            assignments = MailMergeMatching.assign(pages: pageTexts, recipients: merge.recipients, byKey: merge.matchByKey)
        } else {
            assignments = merge.recipients.map { .init(recipient: $0, page: nil, ambiguous: false) }
        }
        for a in assignments {
            var files: [URL] = []
            var problem: String? = nil
            if merge.splitPages {
                if let p = a.page, p < pageFiles.count {
                    // The recipient gets "Plans - Bordeaux.pdf", not "p3.pdf".
                    let named = pageFiles[p].deletingLastPathComponent().appendingPathComponent(
                        MailMergeMatching.pageFileName(base: pdf?.lastPathComponent ?? "Plan.pdf", key: a.recipient.key, page: p))
                    try? FileManager.default.removeItem(at: named)
                    try? FileManager.default.copyItem(at: pageFiles[p], to: named)
                    files = [named]
                } else {
                    problem = String(localized: "mail.plan.no-page")
                }
            } else if let pdf {
                files = [pdf]
            }
            if !MailAddress.isValid(a.recipient.email) { problem = String(localized: "mail.plan.bad-address") }
            run.mails.append(PreparedMail(to: [a.recipient.email],
                                          subject: MailMergeMatching.fill(merge.subject, a.recipient),
                                          body: MailMergeMatching.fill(merge.body, a.recipient),
                                          attachments: files, problem: problem))
        }
    }

    /// Saves a message's attachments in a fresh folder of the work directory.
    private func saveAttachments(of m: MailMessage, onlyName: String?) async -> [URL] {
        let dir = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = MailScript.saveAttachmentsScript(account: m.account, mailbox: m.mailbox, messageId: m.messageId,
                                                      folder: dir.path, onlyName: onlyName)
        guard case .success(let v) = await mail.runAppleScript(script), let out = v.first else { return [] }
        return out.split(separator: "\n").map { dir.appendingPathComponent(String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Running (each one after a click)

    /// Sends the first mail of the plan to the user's own address, "[Test]" in front.
    func sendTest(_ id: UUID) {
        guard let run = runs[id], let me = myAddress, let first = run.mails.first(where: { $0.problem == nil }) else { return }
        Task {
            let script = MailScript.sendScript(from: nil, to: [me], cc: [], subject: "[Test] " + first.subject,
                                               body: first.body, attachments: first.attachments.map(\.path))
            if case .success = await mail.runAppleScript(script) { runs[id]?.testSentTo = me }
        }
    }

    /// Run: 5 seconds to change one's mind, then every step in order.
    func start(_ id: UUID) {
        guard let run = runs[id], run.phase == .ready || run.phase == .cancelled else { return }
        cancelled.remove(id)
        Task {
            for s in stride(from: 5, through: 1, by: -1) {
                if cancelled.contains(id) { runs[id]?.phase = .cancelled; return }
                runs[id]?.phase = .countdown(s)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if cancelled.contains(id) { runs[id]?.phase = .cancelled; return }
            await execute(run, id: id)
        }
    }

    func cancel(_ id: UUID) {
        cancelled.insert(id)
        if case .countdown = runs[id]?.phase { runs[id]?.phase = .cancelled }
    }

    private func execute(_ run: MailPlanRun, id: UUID) async {
        let total = run.stepCount
        var ok = 0, failed = 0
        func step(_ success: Bool) {
            if success { ok += 1 } else { failed += 1 }
            runs[id]?.phase = .running(done: ok + failed, total: total)
        }
        runs[id]?.phase = .running(done: 0, total: total)
        for (action, messages) in run.sorts {
            for m in messages {
                if cancelled.contains(id) { break }
                step(await mail.perform(action, on: m, reason: .manual))
            }
        }
        for (m, body) in run.replies {
            let script = MailScript.replyDraftScript(account: m.account, mailbox: m.mailbox, messageId: m.messageId, body: body)
            if case .success = await mail.runAppleScript(script) { step(true) } else { step(false) }
        }
        for (m, folder) in run.saves {
            let path = (folder as NSString).expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let script = MailScript.saveAttachmentsScript(account: m.account, mailbox: m.mailbox, messageId: m.messageId, folder: path)
            if case .success = await mail.runAppleScript(script) { step(true) } else { step(false) }
        }
        for (i, out) in run.mails.enumerated() where out.problem == nil {
            if cancelled.contains(id) { break }
            let script = MailScript.sendScript(from: nil, to: out.to, cc: out.cc, subject: out.subject, body: out.body,
                                               attachments: out.attachments.map(\.path))
            if case .success = await mail.runAppleScript(script) {
                step(true)
                MailTriageStore.shared.recordSent(MailSentEntry(date: Date(), to: out.to, subject: out.subject,
                                                                attachments: out.attachments.map(\.lastPathComponent)))
            } else {
                step(false)
            }
            // A pause between mails: the provider sees a person, not a burst.
            if i < run.mails.count - 1 { try? await Task.sleep(nanoseconds: 1_200_000_000) }
        }
        runs[id]?.phase = .done(ok: ok, failed: failed)
    }
}
#endif
