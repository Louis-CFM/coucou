import Foundation

@main
enum LinearInboxTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let now = ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z")!

    // n1 unread issue mention, n2 read, n3 snoozed until later, n4 snooze over,
    // n5 project update, n6 a kind with neither issue nor project.
    static let validJSON: Data = """
    {
      "data": {
        "notifications": {
          "nodes": [
            {"id": "n1", "category": "mentions", "readAt": null, "snoozedUntilAt": null,
             "createdAt": "2026-10-10T11:00:00.000Z", "actor": {"name": "Ana"},
             "issue": {"identifier": "ENG-12", "title": "Fix login", "url": "https://linear.app/acme/issue/ENG-12"}},
            {"id": "n2", "category": "assignments", "readAt": "2026-10-10T11:30:00.000Z", "snoozedUntilAt": null,
             "createdAt": "2026-10-10T10:00:00.000Z", "actor": {"name": "Ben"},
             "issue": {"identifier": "ENG-13", "title": "Read already", "url": "https://linear.app/acme/issue/ENG-13"}},
            {"id": "n3", "category": "commentsAndReplies", "readAt": null, "snoozedUntilAt": "2026-10-11T08:00:00.000Z",
             "createdAt": "2026-10-10T09:00:00.000Z", "actor": null,
             "issue": {"identifier": "ENG-14", "title": "Snoozed", "url": "https://linear.app/acme/issue/ENG-14"}},
            {"id": "n4", "category": "statusChanges", "readAt": null, "snoozedUntilAt": "2026-10-09T08:00:00.000Z",
             "createdAt": "2026-10-10T11:30:00Z", "actor": {"name": "Cy"},
             "issue": {"identifier": "ENG-15", "title": "Woke up", "url": "https://linear.app/acme/issue/ENG-15"}},
            {"id": "n5", "category": "postsAndUpdates", "readAt": null, "snoozedUntilAt": null,
             "createdAt": "2026-10-08T12:00:00.000Z", "actor": {"name": "Dee"},
             "project": {"name": "Q4 launch", "url": "https://linear.app/acme/project/q4"}},
            {"id": "n6", "category": "system", "readAt": null, "snoozedUntilAt": null,
             "createdAt": "2026-10-07T12:00:00.000Z", "actor": null}
          ]
        },
        "viewer": {
          "organization": {"urlKey": "acme"},
          "assignedIssues": {
            "nodes": [
              {"id": "i1", "identifier": "ENG-1", "title": "Older", "url": "https://linear.app/acme/issue/ENG-1",
               "updatedAt": "2026-10-01T00:00:00.000Z", "state": {"name": "Todo", "color": "#e2e2e2"}},
              {"id": "i2", "identifier": "ENG-2", "title": "Newer", "url": "https://linear.app/acme/issue/ENG-2",
               "updatedAt": "2026-10-09T00:00:00.000Z", "state": {"name": "In Progress", "color": "#f2c94c"}},
              {"id": "bad", "title": "No identifier"}
            ]
          }
        }
      }
    }
    """.data(using: .utf8)!

    static let errorJSON: Data = """
    {"errors": [{"message": "Authentication required, not authenticated"}], "data": null}
    """.data(using: .utf8)!

    static func main() {
        print("LinearInbox.parse")
        guard let inbox = LinearInbox.parse(validJSON, now: now) else {
            check("valid response parses", false)
            exit(1)
        }
        let ids = inbox.unread.map(\.id)
        check("read entries are dropped", !ids.contains("n2"))
        check("entries snoozed into the future are dropped", !ids.contains("n3"))
        check("entries whose snooze ended stay", ids.contains("n4"))
        check("unread sorted newest first", ids == ["n4", "n1", "n5", "n6"])

        let n1 = inbox.unread.first { $0.id == "n1" }
        check("issue key and title", n1?.key == "ENG-12" && n1?.title == "Fix login")
        check("actor name", n1?.actor == "Ana")
        check("category maps to reason", n1?.reason == .mention)
        check("issue URL kept", n1?.url == "https://linear.app/acme/issue/ENG-12")

        let n5 = inbox.unread.first { $0.id == "n5" }
        check("project entry has no key", n5?.key == nil && n5?.title == "Q4 launch")
        check("unknown category maps to other", n5?.reason == .other)

        let n6 = inbox.unread.first { $0.id == "n6" }
        check("entry without target opens the workspace inbox", n6?.url == "https://linear.app/acme/inbox")
        check("inbox URL uses the workspace key", inbox.inboxURL == "https://linear.app/acme/inbox")

        check("assigned issues skip malformed rows", inbox.assigned.count == 2)
        check("assigned sorted by last update", inbox.assigned.map(\.key) == ["ENG-2", "ENG-1"])
        check("state name and color", inbox.assigned.first?.stateName == "In Progress"
                                     && inbox.assigned.first?.stateColor == "#f2c94c")

        print("LinearInbox.parse errors")
        check("GraphQL errors give nil", LinearInbox.parse(errorJSON, now: now) == nil)
        check("garbage gives nil", LinearInbox.parse(Data("nope".utf8), now: now) == nil)

        print("LinearInbox.fresh")
        check("first poll alerts nothing", LinearInbox.fresh(inbox.unread, seen: nil).isEmpty)
        check("only unseen entries alert",
              LinearInbox.fresh(inbox.unread, seen: ["n1", "n4", "n5"]).map(\.id) == ["n6"])

        print("LinearInbox.query")
        check("query avoids internal fields",
              !LinearInbox.query.contains("inboxUrl") && !LinearInbox.query.contains(" title\n          url"))
        check("request body is JSON with the query",
              (try? JSONSerialization.jsonObject(with: LinearInbox.requestBody() ?? Data()) as? [String: String])?["query"] == LinearInbox.query)

        print("linearTimeAgo")
        check("minutes", linearTimeAgo(now.addingTimeInterval(-300), now: now) == "5m")
        check("days", linearTimeAgo(now.addingTimeInterval(-86400 * 3), now: now) == "3d")

        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nAll Linear inbox tests passed")
    }
}
