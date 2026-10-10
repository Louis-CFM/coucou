// BetterStackTests.swift — standalone tests for BetterStack.swift.
// Run from repo root:
//   swiftc -parse-as-library NotchBuddy/Sources/App/BetterStack.swift \
//     NotchBuddy/Tests/BetterStackTests.swift -o /tmp/betterstack-tests && /tmp/betterstack-tests

import Foundation

@main
struct BetterStackTests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        if ok { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 }
    }

    // Shapes from https://betterstack.com/docs/uptime/api/list-all-incidents/
    // and https://betterstack.com/docs/uptime/api/list-all-existing-monitors/
    static let incidentsJSON = """
    {"data":[
      {"id":"101","type":"incident","attributes":{"name":"api.example.com","url":"https://api.example.com",
        "cause":"Status 502","started_at":"2026-10-10T08:00:00.000Z","acknowledged_at":null,
        "resolved_at":null,"status":"Started"}},
      {"id":"102","type":"incident","attributes":{"name":"shop.example.com","cause":"Timeout",
        "started_at":"2026-10-10T09:30:00Z","acknowledged_at":"2026-10-10T09:31:00Z",
        "resolved_at":null,"status":"Acknowledged"}},
      {"id":"103","type":"incident","attributes":{"name":"old","started_at":"2026-10-09T09:30:00Z",
        "resolved_at":"2026-10-09T10:00:00Z","status":"Resolved"}},
      {"type":"incident","attributes":{"name":"no id"}}
    ],"pagination":{"first":"x","last":"x","prev":null,"next":null}}
    """

    static let monitorsJSON = """
    {"data":[
      {"id":"1","type":"monitor","attributes":{"url":"https://a.example","pronounceable_name":"Site A","status":"up"}},
      {"id":"2","type":"monitor","attributes":{"url":"https://b.example","pronounceable_name":"Site B","status":"down"}},
      {"id":"3","type":"monitor","attributes":{"url":"https://c.example","status":"down"}},
      {"id":"4","type":"monitor","attributes":{"url":"https://d.example","status":"paused"}}
    ],"pagination":{"first":"x","last":"x","prev":null,"next":null}}
    """

    static func main() {
        let incidents = BetterStackAPI.incidents(from: Data(incidentsJSON.utf8)) ?? []
        check(incidents.count == 2, "drops resolved rows and rows without an id")
        check(incidents.first?.id == "102", "newest incident first")
        check(incidents.first?.acknowledged == true, "acknowledged_at set → acknowledged")
        check(incidents.last?.acknowledged == false, "acknowledged_at null → not acknowledged")
        check(incidents.last?.cause == "Status 502", "cause kept")
        check(incidents.last?.startedAt != nil, "fractional-second timestamps parse")
        check(incidents.first?.startedAt != nil, "plain timestamps parse")
        check(incidents.first?.webURL(team: "t1")?.absoluteString == "https://incidents.betterstack.com/team/t1/incidents/102", "web link")

        check(BetterStackAPI.incidents(from: Data("{\"errors\":\"Unauthorized\"}".utf8)) == nil,
              "non-list body → nil")
        check(BetterStackAPI.incidents(from: Data("{\"data\":[]}".utf8))?.isEmpty == true,
              "empty list → no incidents")

        let down = BetterStackAPI.downMonitors(from: Data(monitorsJSON.utf8)) ?? []
        check(down.map(\.id) == ["2", "3"], "only monitors with status down")
        check(down.first?.name == "Site B", "pronounceable_name is the name")
        check(down.last?.name == "https://c.example", "url when no pronounceable_name")

        let a = incidents[1], b = incidents[0]
        check(BetterStackAPI.change(previous: nil, current: [a]) == .none, "first poll is silent")
        check(BetterStackAPI.change(previous: [a.id: a.name], current: [a]) == .none, "same incidents → none")
        check(BetterStackAPI.change(previous: [a.id: a.name], current: [a, b]) == .opened(b), "new incident → opened")
        check(BetterStackAPI.change(previous: [a.id: a.name, b.id: b.name], current: [b]) == .resolved(name: a.name),
              "incident gone → resolved")
        check(BetterStackAPI.change(previous: [a.id: a.name], current: [b]) == .opened(b),
              "opened wins over resolved in the same poll")

        // Links: the team's own pages; without a team, the incident list.
        check(BetterStackAPI.team(from: "t5969") == "t5969", "team ID as Better Stack shows it")
        check(BetterStackAPI.team(from: " 5969 ") == "t5969", "team number alone")
        check(BetterStackAPI.team(from: "https://incidents.betterstack.com/team/t5969/incidents/1030114436") == "t5969",
              "team from a pasted dashboard link")
        check(BetterStackAPI.team(from: "") == nil && BetterStackAPI.team(from: "t59x") == nil
              && BetterStackAPI.team(from: "../t1") == nil, "anything else is no team")
        check(a.webURL(team: "t5969")?.absoluteString == "https://incidents.betterstack.com/team/t5969/incidents/101",
              "incident link with the team")
        check(a.webURL(team: nil) == BetterStackAPI.dashboardURL, "no team: the incident list, not a 404")
        check(down[0].webURL(team: "t5969")?.absoluteString == "https://incidents.betterstack.com/team/t5969/monitors/2",
              "monitor link with the team")

        print(failures == 0 ? "All Better Stack tests passed." : "\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
