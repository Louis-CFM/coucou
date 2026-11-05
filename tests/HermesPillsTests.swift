import Foundation

@main
enum HermesPillsTests {
    static var failures = 0

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)\n    got:      \(got)\n    expected: \(expected)"); failures += 1 }
    }

    static func main() {
        print("HermesPills.taskIds")
        let ids = HermesPills.taskIds(for: ["Alfred", "codex", "My Agent 2", "Zoë", "!!!"])
        check("plain name", ids["codex"], "agent_hermes_codex")
        check("upper case is lowered", ids["Alfred"], "agent_hermes_alfred")
        check("spaces and digits", ids["My Agent 2"], "agent_hermes_myagent2")
        check("non a-z characters are dropped", ids["Zoë"], "agent_hermes_zo")
        check("name without usable characters gets a hash key", ids["!!!"]?.hasPrefix("agent_hermes_x"), true)
        check("keeps dashes", HermesPills.taskIds(for: ["a-b"])["a-b"], "agent_hermes_a-b")
        check("long names are capped", HermesPills.taskIds(for: [String(repeating: "a", count: 80)]).values.first?.count,
              HermesPills.taskPrefix.count + HermesPills.maxKeyLength)

        print("collisions")
        let c = HermesPills.taskIds(for: ["Alfred", "alfred", "ALFRED"])
        check("three names, three ids", Set(c.values).count, 3)
        check("smallest raw name keeps the plain key", c["ALFRED"], "agent_hermes_alfred")
        check("order does not matter", HermesPills.taskIds(for: ["ALFRED", "alfred", "Alfred"]), c)
        check("same result with another neighbour", HermesPills.taskIds(for: ["alfred", "x"])["alfred"] != c["alfred"], true)
        let long = String(repeating: "a", count: 40)
        let cl = HermesPills.taskIds(for: [long, long + "!", long.uppercased()])
        check("collisions after the cap stay distinct", Set(cl.values).count, 3)
        check("and within the cap", cl.values.allSatisfy { $0.count <= HermesPills.taskPrefix.count + HermesPills.maxKeyLength }, true)

        print("no collision with other ids")
        check("external agent id is not a Hermes id", HermesPills.isTaskId("agent_codex"), false)
        check("hermes external agent id", HermesPills.isTaskId("agent_hermes"), false)
        check("cmux id", HermesPills.isTaskId("agent_cmux_abc"), false)
        check("catalog ids", HermesPills.isTaskId("ai_hermes") || HermesPills.isTaskId("integration_claude"), false)
        check("prefix alone", HermesPills.isTaskId("agent_hermes_"), false)
        check("nil", HermesPills.isTaskId(nil), false)
        check("hermes id", HermesPills.isTaskId("agent_hermes_codex"), true)

        print("inverse")
        let names = ["Alfred", "codex", "alfred"]
        for n in names { check("round trip \(n)", HermesPills.agentName(forTaskId: HermesPills.taskIds(for: names)[n]!, in: names), n) }
        check("unknown id", HermesPills.agentName(forTaskId: "agent_hermes_nope", in: names), nil)
        check("not a hermes id", HermesPills.agentName(forTaskId: "agent_cmux_codex", in: names), nil)

        print("reconcile")
        let r1 = HermesPills.reconcile(existingIds: ["integration_claude"], agents: ["Alfred", "codex"])
        check("adds both at launch", r1.add.map { $0.name }, ["Alfred", "codex"])
        check("add carries id", r1.add.map { $0.id }, ["agent_hermes_alfred", "agent_hermes_codex"])
        check("nothing to remove", r1.remove, [])
        let r2 = HermesPills.reconcile(existingIds: ["agent_hermes_alfred", "agent_hermes_codex", "agent_cmux_1"], agents: ["Alfred"])
        check("removes the disconnected one only", r2.remove, ["agent_hermes_codex"])
        check("nothing added", r2.add.count, 0)
        check("no agents, no Hermes pill, nothing else touched",
              HermesPills.reconcile(existingIds: ["integration_claude", "agent_cmux_1", "agent_codex"], agents: []).remove, [])
        check("no agents adds nothing", HermesPills.reconcile(existingIds: [], agents: []).add.count, 0)

        print("progress sent to the iPhone")
        let hp = HermesPills.publishedProgress(taskId: "agent_hermes_alfred", stepIndex: 6, stepCount: 7)
        check("a Hermes pill sends no step numbers", [hp.stepIndex, hp.stepCount], [0, 0])
        let cp = HermesPills.publishedProgress(taskId: "agent_cmux_w1", stepIndex: 6, stepCount: 7)
        check("another pill keeps its numbers", [cp.stepIndex, cp.stepCount], [6, 7])

        print("subtitle")
        check("profile", HermesPills.subtitle(profile: "work", baseURL: "https://a.example.com"), "Hermes · work")
        check("default profile shows host", HermesPills.subtitle(profile: "default", baseURL: "https://a.example.com"), "Hermes · a.example.com")
        check("empty profile shows host", HermesPills.subtitle(profile: "", baseURL: "http://127.0.0.1:8642"), "Hermes · 127.0.0.1")
        check("no host", HermesPills.subtitle(profile: "", baseURL: "nonsense"), "Hermes")

        print("PillLook")
        let a = PillLook.appearance(key: "alfred", takenColors: [])
        check("stable", PillLook.appearance(key: "alfred", takenColors: []).color, a.color)
        check("taken colour is skipped", PillLook.appearance(key: "alfred", takenColors: [a.color]).color != a.color, true)

        if failures > 0 { print("\n\(failures) FAILED"); exit(1) }
        print("\nAll tests passed")
    }
}
