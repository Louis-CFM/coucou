import Foundation

enum MailPlanTests {
    static func run() {
        parsing()
        merging()
        prompt()
        scripts()
        print("MailPlan tests: all passed")
    }

    static func parsing() {
        let answer = """
        Je prépare les 3 envois.

        ```coucou-mail
        {"summary": "3 mails", "actions": [
          {"type": "junk", "messages": [2, 3]},
          {"type": "move", "messages": 4, "mailbox": "Compta"},
          {"type": "reply", "message": 1, "body": "Merci !"},
          {"type": "send", "to": "a@b.fr, c@d.fr", "subject": "Hi", "body": "Yo", "attachments_from": "5"},
          {"type": "merge", "from_message": 1, "attachment": "plans.pdf", "match": "key",
           "recipients": [{"email": "bx@f.fr", "name": "Léa", "key": "Bordeaux"}, {"email": "ly@f.fr", "city": "Lyon"}],
           "subject": "Plan {key}", "body": "Bonjour {name}"},
          {"type": "save_attachments", "message": 1, "folder": "~/Documents/Plans"}
        ]}
        ```
        Clique sur Lancer.
        """
        let r = MailPlanParser.extract(answer)
        precondition(r.error == nil, r.error ?? "")
        precondition(r.prose == "Je prépare les 3 envois.\n\n\nClique sur Lancer." || r.prose.hasPrefix("Je prépare"), r.prose)
        precondition(!r.prose.contains("coucou-mail") && r.prose.contains("Clique sur Lancer."))
        let plan = r.plan!
        precondition(plan.summary == "3 mails" && plan.actions.count == 6)
        precondition(plan.actions[0] == .sort(.junk, messages: [2, 3]))
        precondition(plan.actions[1] == .sort(.move("Compta"), messages: [4]))
        precondition(plan.actions[2] == .reply(message: 1, body: "Merci !"))
        guard case .send(let s) = plan.actions[3] else { fatalError() }
        precondition(s.to == ["a@b.fr", "c@d.fr"] && s.attachmentsFrom == 5)
        guard case .merge(let m) = plan.actions[4] else { fatalError() }
        precondition(m.recipients.count == 2 && m.recipients[1].key == "Lyon" && m.matchByKey && m.splitPages)
        precondition(plan.actions[5] == .saveAttachments(message: 1, folder: "~/Documents/Plans"))
        precondition(plan.sendCount == 3)
        // No block, a block still streaming, a broken block.
        precondition(MailPlanParser.extract("Hello").plan == nil && MailPlanParser.extract("Hello").prose == "Hello")
        let streaming = MailPlanParser.extract("Ok\n```coucou-mail\n{\"actions\": [")
        precondition(streaming.plan == nil && streaming.error == nil && streaming.prose == "Ok")
        let broken = MailPlanParser.extract("Ok\n```coucou-mail\n{\"actions\": [{\"type\": \"send\"}]}\n```")
        precondition(broken.plan == nil && broken.error!.contains("needs \"to\""))
        let unknown = MailPlanParser.extract("```coucou-mail\n{\"actions\": [{\"type\": \"delete\", \"messages\": [1]}]}\n```")
        precondition(unknown.error!.contains("unknown type"), "no delete action exists")
    }

    static func merging() {
        let pages = ["Plan du site — BORDEAUX — RDC", "Plan Lyon 3e", "Plan Bordeaux annexe", "Marseille"]
        let rs = [MailMergeRecipient(email: "a@x.fr", name: "A", key: "Bordeaux"),
                  MailMergeRecipient(email: "b@x.fr", name: "B", key: "Lyon"),
                  MailMergeRecipient(email: "c@x.fr", name: "C", key: "Nice"),
                  MailMergeRecipient(email: "d@x.fr", name: "D", key: "Bordeaux")]
        let a = MailMergeMatching.assign(pages: pages, recipients: rs, byKey: true)
        precondition(a[0].page == 0 && a[0].ambiguous)
        precondition(a[1].page == 1 && !a[1].ambiguous)
        precondition(a[2].page == nil, "no page for Nice")
        precondition(a[3].page == 2, "the second Bordeaux takes the free page")
        let o = MailMergeMatching.assign(pages: pages, recipients: rs + rs, byKey: false)
        precondition(o.map(\.page) == [0, 1, 2, 3, nil, nil, nil, nil])
        precondition(MailMergeMatching.fill("Plan {key} pour {name} ({city})", rs[0]) == "Plan Bordeaux pour A (Bordeaux)")
        precondition(MailMergeMatching.pageFileName(base: "Plans.pdf", key: "Lyon", page: 1) == "Plans - Lyon.pdf")
        precondition(MailMergeMatching.pageFileName(base: "a/b.pdf", key: "", page: 4) == "a-b - p5.pdf")
        precondition(MailAddress.isValid("lea@franchise.fr"))
        for bad in ["lea", "lea@", "@x.fr", "lea@x", "le a@x.fr", "lea@x.fr."] { precondition(!MailAddress.isValid(bad), bad) }
    }

    static func prompt() {
        let lines = [MailAgentPrompt.Line(number: 1, sender: "Martin <m@archi.fr>", subject: "Plans franchisés",
                                          date: Date(timeIntervalSince1970: 0), isRead: false, account: "Pro",
                                          attachments: ["plans.pdf"], text: "Voici\nles plans")]
        let s = MailAgentPrompt.snapshot(lines, accounts: [("Pro", "louis@pro.fr")])
        precondition(s.contains("Accounts: Pro <louis@pro.fr>"))
        precondition(s.contains("[1] ") && s.contains("unread") && s.contains("attachments: plans.pdf"))
        precondition(s.contains("text: Voici les plans") && s.hasSuffix("</mail>"))
        precondition(MailAgentPrompt.instructions.contains("coucou-mail") && MailAgentPrompt.instructions.contains("Never invent an address"))
        let hits = MailAgentPrompt.mentioned(in: "le mail de Martin avec les plans",
                                             senders: ["Anne <a@x.fr>", "Martin <m@archi.fr>", "Paul"],
                                             subjects: ["Plans", "Plans franchisés", "Hello"])
        precondition(hits == [1, 0], "\(hits)")
        precondition(MailAgentPrompt.mentioned(in: "ok", senders: ["a"], subjects: ["b"]).isEmpty)
    }

    static func scripts() {
        let s = MailScript.sendScript(from: "louis@pro.fr", to: ["a@x.fr"], cc: ["b@x.fr"], subject: "Plan \"Lyon\"",
                                      body: "Bonjour", attachments: ["/tmp/p 1.pdf"])
        precondition(s.contains("subject:\"Plan \\\"Lyon\\\"\""))
        precondition(s.contains("set sender of m to \"louis@pro.fr\""))
        precondition(s.contains("to recipients with properties {address:\"a@x.fr\"}"))
        precondition(s.contains("cc recipients with properties {address:\"b@x.fr\"}"))
        precondition(s.contains("POSIX file \"/tmp/p 1.pdf\"") && s.contains("delay 1") && s.contains("send m"))
        precondition(!MailScript.sendScript(from: nil, to: ["a@x.fr"], cc: [], subject: "", body: "", attachments: []).contains("delay"))
        let save = MailScript.saveAttachmentsScript(account: "Pro", mailbox: "INBOX", messageId: 7, folder: "/tmp/x", onlyName: "plans.pdf")
        precondition(save.contains("(name of a) is \"plans.pdf\"") && save.contains("\"/tmp/x/\" & (name of a)"))
        let reply = MailScript.replyDraftScript(account: "Pro", mailbox: "INBOX", messageId: 7, body: "Merci")
        precondition(reply.contains("reply m with opening window") && !reply.contains("send"))
    }
}
