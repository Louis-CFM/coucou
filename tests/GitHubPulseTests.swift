import Foundation

@main
enum GitHubPulseTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    // MARK: - Fixture JSON

    // Valid response: PR #42 SUCCESS/APPROVED, PR #43 null CI (unknown)/null review,
    // repo "testuser/myrepo" PENDING, archived repo filtered out,
    // one to-review PR from another repo.
    static let validJSON: Data = """
    {
      "data": {
        "viewer": {
          "login": "testuser",
          "pullRequests": {
            "nodes": [
              {
                "number": 42,
                "title": "Add feature",
                "url": "https://github.com/testuser/myrepo/pull/42",
                "isDraft": false,
                "reviewDecision": "APPROVED",
                "repository": {"nameWithOwner": "testuser/myrepo", "url": "https://github.com/testuser/myrepo"},
                "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}
              },
              {
                "number": 43,
                "title": "Fix bug",
                "url": "https://github.com/testuser/myrepo/pull/43",
                "isDraft": true,
                "reviewDecision": null,
                "repository": {"nameWithOwner": "testuser/myrepo", "url": "https://github.com/testuser/myrepo"},
                "commits": {"nodes": [{"commit": {"statusCheckRollup": null}}]}
              }
            ]
          },
          "repositories": {
            "nodes": [
              {
                "nameWithOwner": "testuser/myrepo",
                "url": "https://github.com/testuser/myrepo",
                "isArchived": false,
                "defaultBranchRef": {
                  "name": "main",
                  "target": {"statusCheckRollup": {"state": "PENDING"}}
                }
              },
              {
                "nameWithOwner": "testuser/archived",
                "url": "https://github.com/testuser/archived",
                "isArchived": true,
                "defaultBranchRef": {
                  "name": "main",
                  "target": {"statusCheckRollup": {"state": "SUCCESS"}}
                }
              }
            ]
          }
        },
        "reviewRequested": {
          "issueCount": 1,
          "nodes": [
            {
              "number": 7,
              "title": "Review this",
              "url": "https://github.com/other/repo/pull/7",
              "isDraft": false,
              "author": {"login": "otheruser"},
              "repository": {"nameWithOwner": "other/repo", "url": "https://github.com/other/repo"}
            }
          ]
        }
      }
    }
    """.data(using: .utf8)!

    static let emptyJSON: Data = """
    {
      "data": {
        "viewer": {
          "login": "testuser",
          "pullRequests": {"nodes": []},
          "repositories": {"nodes": []}
        },
        "reviewRequested": {"issueCount": 0, "nodes": []}
      }
    }
    """.data(using: .utf8)!

    // MARK: - Main

    static func main() {

        // ── GitHubPulse.parse ─────────────────────────────────────────────────
        print("GitHubPulse.parse")
        do {
            let pulse = GitHubPulse.parse(validJSON)
            check("parse returns non-nil",       pulse != nil)
            check("login",                        pulse?.login == "testuser")
            check("2 myPRs",                      pulse?.myPRs.count == 2)
            check("PR#42 id",                     pulse?.myPRs[0].id == "testuser/myrepo#42")
            check("PR#42 ci success",             pulse?.myPRs[0].ci == .success)
            check("PR#42 review approved",        pulse?.myPRs[0].review == .approved)
            check("PR#43 ci unknown (null rollup)",pulse?.myPRs[1].ci == .unknown)
            check("PR#43 review unknown (null)",  pulse?.myPRs[1].review == .unknown)
            check("PR#43 isDraft",                pulse?.myPRs[1].isDraft == true)
            check("1 mainCI (archived filtered)", pulse?.mainCI.count == 1)
            check("mainCI repo",                  pulse?.mainCI[0].repo == "testuser/myrepo")
            check("mainCI ci pending",            pulse?.mainCI[0].ci == .pending)
            check("mainCI branch main",           pulse?.mainCI[0].branch == "main")
            check("1 toReview",                   pulse?.toReview.count == 1)
            check("toReview id",                  pulse?.toReview[0].id == "other/repo#7")
            check("hasPending (mainCI pending)",  pulse?.hasPending == true)
        }

        // ── GitHubPulse.parse — empty ─────────────────────────────────────────
        print("GitHubPulse.parse — empty")
        do {
            let pulse = GitHubPulse.parse(emptyJSON)
            check("empty parses ok",     pulse != nil)
            check("no myPRs",            pulse?.myPRs.isEmpty == true)
            check("no mainCI",           pulse?.mainCI.isEmpty == true)
            check("no toReview",         pulse?.toReview.isEmpty == true)
            check("!hasPending",         pulse?.hasPending == false)
        }

        // ── GitHubPulse.parse — bad data ──────────────────────────────────────
        print("GitHubPulse.parse — bad data")
        do {
            check("garbage → nil",    GitHubPulse.parse("garbage".data(using: .utf8)!) == nil)
            check("empty obj → nil",  GitHubPulse.parse("{}".data(using: .utf8)!) == nil)
        }

        // ── CIState init ──────────────────────────────────────────────────────
        print("CIState init")
        do {
            check("nil → unknown",      CIState(rawGitHub: nil)        == .unknown)
            check("PENDING → pending",  CIState(rawGitHub: "PENDING")  == .pending)
            check("EXPECTED → pending", CIState(rawGitHub: "EXPECTED") == .pending)
            check("SUCCESS → success",  CIState(rawGitHub: "SUCCESS")  == .success)
            check("FAILURE → failure",  CIState(rawGitHub: "FAILURE")  == .failure)
            check("ERROR → failure",    CIState(rawGitHub: "ERROR")    == .failure)
            check("other → unknown",    CIState(rawGitHub: "WAITING")  == .unknown)
        }

        // ── GitHubPulse.events — first poll silent ────────────────────────────
        print("GitHubPulse.events — first poll silent")
        do {
            let pulse = GitHubPulse.parse(validJSON)!
            let events = GitHubPulse.events(old: nil, new: pulse)
            check("first poll → no events", events.isEmpty)
        }

        // ── GitHubPulse.events — pending → success ────────────────────────────
        print("GitHubPulse.events — pending → success")
        do {
            var oldPulse = GitHubPulse.parse(emptyJSON)!
            oldPulse.myPRs = [GitHubPR(id: "r/p#1", title: "T", url: "", repo: "r/p",
                                        number: 1, isDraft: false, ci: .pending, review: .unknown)]
            var newPulse = oldPulse
            newPulse.myPRs[0].ci = .success
            let events = GitHubPulse.events(old: oldPulse, new: newPulse)
            check("pending→success → ciPassed", events == [.ciPassed(prId: "r/p#1")])
        }

        // ── GitHubPulse.events — success → failure ────────────────────────────
        print("GitHubPulse.events — success → failure")
        do {
            var oldPulse = GitHubPulse.parse(emptyJSON)!
            oldPulse.myPRs = [GitHubPR(id: "r/p#2", title: "T", url: "", repo: "r/p",
                                        number: 2, isDraft: false, ci: .success, review: .unknown)]
            var newPulse = oldPulse
            newPulse.myPRs[0].ci = .failure
            let events = GitHubPulse.events(old: oldPulse, new: newPulse)
            check("success→failure → ciFailed", events == [.ciFailed(prId: "r/p#2")])
        }

        // ── GitHubPulse.events — main CI failure ──────────────────────────────
        print("GitHubPulse.events — main CI failure")
        do {
            var oldPulse = GitHubPulse.parse(emptyJSON)!
            oldPulse.mainCI = [GitHubRepoCI(repo: "a/b", url: "", branch: "main", ci: .success)]
            var newPulse = oldPulse
            newPulse.mainCI[0].ci = .failure
            let events = GitHubPulse.events(old: oldPulse, new: newPulse)
            check("main success→failure → mainFailed", events == [.mainFailed(repo: "a/b")])
        }

        // ── GitHubPulse.events — new review request ───────────────────────────
        print("GitHubPulse.events — new review request")
        do {
            let pr = GitHubPR(id: "o/r#7", title: "R", url: "", repo: "o/r",
                              number: 7, isDraft: false, ci: .unknown, review: .pending)
            var oldPulse = GitHubPulse.parse(emptyJSON)!
            var newPulse = oldPulse
            newPulse.toReview = [pr]
            let events = GitHubPulse.events(old: oldPulse, new: newPulse)
            check("new review → reviewRequested", events == [.reviewRequested(prId: "o/r#7")])

            // Already-known review: no new event
            oldPulse.toReview = [pr]
            newPulse.toReview = [pr]
            let noEvents = GitHubPulse.events(old: oldPulse, new: newPulse)
            check("known review → no event", noEvents.isEmpty)
        }

        // ── GitHubPulse.parse — duplicate ids ────────────────────────────────────
        print("GitHubPulse.parse — duplicate ids")
        do {
            // JSON with PR #42 duplicated: should keep only first occurrence
            let dupJSON: Data = """
            {
              "data": {
                "viewer": {
                  "login": "testuser",
                  "pullRequests": {
                    "nodes": [
                      {
                        "number": 42, "title": "Add feature",
                        "url": "https://github.com/testuser/myrepo/pull/42",
                        "isDraft": false, "reviewDecision": "APPROVED",
                        "repository": {"nameWithOwner": "testuser/myrepo", "url": "https://github.com/testuser/myrepo"},
                        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}
                      },
                      {
                        "number": 42, "title": "Duplicate entry",
                        "url": "https://github.com/testuser/myrepo/pull/42",
                        "isDraft": true, "reviewDecision": null,
                        "repository": {"nameWithOwner": "testuser/myrepo", "url": "https://github.com/testuser/myrepo"},
                        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE"}}}]}
                      }
                    ]
                  },
                  "repositories": {"nodes": []}
                },
                "reviewRequested": {"issueCount": 0, "nodes": []}
              }
            }
            """.data(using: .utf8)!
            let pulse = GitHubPulse.parse(dupJSON)
            check("dup PR → 1 myPR",           pulse?.myPRs.count == 1)
            check("dup PR → keeps first title", pulse?.myPRs[0].title == "Add feature")
            check("dup PR → keeps first ci",    pulse?.myPRs[0].ci == .success)
        }

        // ── GitHubPulse.events — duplicate ids in old pulse ───────────────────
        print("GitHubPulse.events — duplicate-safe Dictionary")
        do {
            // OLD has duplicate ids (uniquingKeysWith keeps first); NEW has one entry → fires once
            var oldPulse = GitHubPulse.parse(emptyJSON)!
            let pr1 = GitHubPR(id: "r/p#1", title: "T", url: "", repo: "r/p",
                               number: 1, isDraft: false, ci: .pending, review: .unknown)
            oldPulse.myPRs = [pr1, pr1]  // intentional duplicate in old
            var newPulse = GitHubPulse.parse(emptyJSON)!
            var pr1Passed = pr1; pr1Passed.ci = .success
            newPulse.myPRs = [pr1Passed]  // single entry in new
            let events = GitHubPulse.events(old: oldPulse, new: newPulse)
            check("dup old ids → no crash", true)
            check("dup old ids → ciPassed fires once",
                  events.filter { if case .ciPassed = $0 { return true }; return false }.count == 1)
        }

        // ── GitHubPulse.events — headSha: new PR already green ───────────────
        print("GitHubPulse.events — headSha: new PR already green")
        do {
            let old = GitHubPulse.parse(emptyJSON)!
            var newPulse = old
            newPulse.myPRs = [GitHubPR(id: "r/p#10", title: "T", url: "", repo: "r/p",
                                        number: 10, isDraft: false, ci: .success, review: .unknown,
                                        headSha: "abc111")]
            let events = GitHubPulse.events(old: old, new: newPulse)
            check("new PR green → ciPassed", events == [.ciPassed(prId: "r/p#10")])
        }

        // ── GitHubPulse.events — headSha: new PR pending → nothing ───────────
        print("GitHubPulse.events — headSha: new PR pending → nothing")
        do {
            let old = GitHubPulse.parse(emptyJSON)!
            var newPulse = old
            newPulse.myPRs = [GitHubPR(id: "r/p#11", title: "T", url: "", repo: "r/p",
                                        number: 11, isDraft: false, ci: .pending, review: .unknown,
                                        headSha: "abc222")]
            let events = GitHubPulse.events(old: old, new: newPulse)
            check("new PR pending → no events", events.isEmpty)
        }

        // ── GitHubPulse.events — headSha: new commit already red ─────────────
        print("GitHubPulse.events — headSha: new commit already red → ciFailed")
        do {
            var oldPulse = GitHubPulse.parse(emptyJSON)!
            oldPulse.myPRs = [GitHubPR(id: "r/p#12", title: "T", url: "", repo: "r/p",
                                        number: 12, isDraft: false, ci: .success, review: .unknown,
                                        headSha: "sha-old")]
            var newPulse = oldPulse
            newPulse.myPRs[0].ci = .failure
            newPulse.myPRs[0].headSha = "sha-new"
            let events = GitHubPulse.events(old: oldPulse, new: newPulse)
            check("new commit red → ciFailed", events == [.ciFailed(prId: "r/p#12")])
        }

        // ── GitHubPulse.events — headSha: same sha success→success → nothing ─
        print("GitHubPulse.events — headSha: same sha success→success → nothing")
        do {
            var oldPulse = GitHubPulse.parse(emptyJSON)!
            oldPulse.myPRs = [GitHubPR(id: "r/p#13", title: "T", url: "", repo: "r/p",
                                        number: 13, isDraft: false, ci: .success, review: .unknown,
                                        headSha: "same")]
            let newPulse = oldPulse  // identical SHA and CI
            let events = GitHubPulse.events(old: oldPulse, new: newPulse)
            check("same sha success→success → no event", events.isEmpty)
        }

        // ── GitHubPulse.events — headSha: new commit on main red → mainFailed ─
        print("GitHubPulse.events — headSha: new commit on main red → mainFailed")
        do {
            var oldPulse = GitHubPulse.parse(emptyJSON)!
            oldPulse.mainCI = [GitHubRepoCI(repo: "a/b", url: "", branch: "main",
                                             ci: .success, headSha: "sha-old")]
            var newPulse = oldPulse
            newPulse.mainCI[0].ci = .failure
            newPulse.mainCI[0].headSha = "sha-new"
            let events = GitHubPulse.events(old: oldPulse, new: newPulse)
            check("new commit on main red → mainFailed", events == [.mainFailed(repo: "a/b")])
        }

        // ── GitHubPulse.isStale ───────────────────────────────────────────────
        print("GitHubPulse.isStale")
        do {
            let now = Date()
            check("nil fetchedAt → stale",
                  GitHubPulse.isStale(fetchedAt: nil, now: now, maxAge: 60))
            check("fresh (same instant) → not stale",
                  !GitHubPulse.isStale(fetchedAt: now, now: now, maxAge: 60))
            check("61 s ago → stale",
                  GitHubPulse.isStale(fetchedAt: now.addingTimeInterval(-61), now: now, maxAge: 60))
        }

        // ── GitHubPulse.parse — watched repos as aliases r0, r1… ─────────────
        print("GitHubPulse.parse — watched repo aliases")
        do {
            let json = """
            {
              "data": {
                "viewer": { "login": "u", "pullRequests": { "nodes": [] } },
                "reviewRequested": { "issueCount": 0, "nodes": [] },
                "r1": { "nameWithOwner": "org/second", "url": "u2", "isArchived": false,
                        "defaultBranchRef": { "name": "main",
                          "target": { "oid": "b", "statusCheckRollup": { "state": "FAILURE" } } } },
                "r0": { "nameWithOwner": "org/first", "url": "u1", "isArchived": false,
                        "defaultBranchRef": { "name": "dev",
                          "target": { "oid": "a", "statusCheckRollup": { "state": "SUCCESS" } } } },
                "r2": null
              }
            }
            """.data(using: .utf8)!
            let pulse = GitHubPulse.parse(json)
            check("parses with aliases", pulse != nil)
            check("aliases in r0, r1 order", pulse?.mainCI.map(\.repo) == ["org/first", "org/second"])
            check("alias CI parsed", pulse?.mainCI.map(\.ci) == [.success, .failure])
            check("null alias (no access) skipped", pulse?.mainCI.count == 2)
        }

        // ── GitHubPulse.filtered ──────────────────────────────────────────────
        print("GitHubPulse.filtered")
        do {
            var pulse = GitHubPulse.parse(emptyJSON)!
            pulse.myPRs = [GitHubPR(id: "a/x#1", title: "", url: "", repo: "a/x", number: 1,
                                    isDraft: false, ci: .success, review: .unknown),
                           GitHubPR(id: "b/y#2", title: "", url: "", repo: "b/y", number: 2,
                                    isDraft: false, ci: .failure, review: .unknown)]
            pulse.toReview = [GitHubPR(id: "b/y#3", title: "", url: "", repo: "b/y", number: 3,
                                       isDraft: false, ci: .unknown, review: .pending)]
            pulse.mainCI = [GitHubRepoCI(repo: "a/x", url: "", branch: "main", ci: .success),
                            GitHubRepoCI(repo: "b/y", url: "", branch: "main", ci: .failure)]
            check("empty set → unchanged", pulse.filtered(toRepos: []) == pulse)
            let only = pulse.filtered(toRepos: ["b/y"])
            check("PRs narrowed", only.myPRs.map(\.repo) == ["b/y"])
            check("to-review narrowed", only.toReview.count == 1)
            check("main CI narrowed", only.mainCI.map(\.repo) == ["b/y"])
            check("login kept", only.login == pulse.login)
        }

        // ── finish ─────────────────────────────────────────────────────────────
        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
