import Foundation

@main
enum GithubPullRequestsTests {

    static var failures = 0

    static func check(_ label: String, _ got: String, _ expected: String) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got.debugDescription)")
            print("    expected: \(expected.debugDescription)")
            failures += 1
        }
    }

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func item(number: Int, repo: String = "acme/widgets", title: String = "Fix things",
                     updated: String = "2026-10-01T10:00:00Z", draft: Bool = false,
                     isPR: Bool = true) -> [String: Any] {
        var d: [String: Any] = [
            "id": 123_456 + number,
            "number": number,
            "title": title,
            "html_url": "https://github.com/\(repo)/pull/\(number)",
            "repository_url": "https://api.github.com/repos/\(repo)",
            "user": ["login": "octocat"],
            "updated_at": updated,
            "draft": draft,
        ]
        if isPR { d["pull_request"] = ["url": "https://api.github.com/repos/\(repo)/pulls/\(number)"] }
        return d
    }

    static func main() {
        // ── parse ──────────────────────────────────────────────────────────────
        print("GithubPullRequests.parse")

        let pr = GithubPullRequests.parse(item: item(number: 42), reason: .reviewRequested)
        checkTrue("parse PR item → non-nil",             pr != nil)
        check("id is owner/repo#number",                 pr?.id ?? "", "acme/widgets#42")
        check("reference is repo#number",                pr?.reference ?? "", "widgets#42")
        check("author from user.login",                  pr?.author ?? "", "octocat")
        check("url",                                     pr?.url ?? "", "https://github.com/acme/widgets/pull/42")
        checkTrue("reason recorded",                     pr?.reasons == [.reviewRequested])
        checkTrue("needsReview true for review request", pr?.needsReview == true)
        checkTrue("not draft by default",                pr?.isDraft == false)
        checkTrue("updatedAt parsed",
                  abs((pr?.updatedAt.timeIntervalSince1970 ?? 0) - 1_790_848_800) < 1)

        let draft = GithubPullRequests.parse(item: item(number: 7, draft: true), reason: .assigned)
        checkTrue("draft flag parsed",                   draft?.isDraft == true)
        checkTrue("assigned PR does not need review",    draft?.needsReview == false)

        checkTrue("issue (no pull_request key) → nil",
                  GithubPullRequests.parse(item: item(number: 1, isPR: false), reason: .assigned) == nil)
        checkTrue("missing number → nil",
                  GithubPullRequests.parse(item: ["title": "x", "html_url": "u", "repository_url": "r",
                                                  "pull_request": [:]], reason: .assigned) == nil)
        checkTrue("bad repository_url → nil",
                  GithubPullRequests.parse(item: ["number": 1, "title": "x", "html_url": "u",
                                                  "repository_url": "https://api.github.com/nope",
                                                  "pull_request": [:]], reason: .assigned) == nil)

        let fractional = GithubPullRequests.parse(item: item(number: 3, updated: "2026-10-01T10:00:00.123Z"),
                                                  reason: .assigned)
        checkTrue("fractional-second date parsed",       fractional != nil)

        // ── parse(payload:) ────────────────────────────────────────────────────
        print("GithubPullRequests.parse(payload:)")
        let payload: [String: Any] = ["total_count": 3, "items": [
            item(number: 1), item(number: 2, isPR: false), item(number: 3),
        ]]
        let list = GithubPullRequests.parse(payload: payload, reason: .reviewRequested)
        check("keeps only pull requests", "\(list.map(\.number))", "[1, 3]")
        checkTrue("empty payload → empty list",
                  GithubPullRequests.parse(payload: [:], reason: .assigned).isEmpty)

        // ── merge ──────────────────────────────────────────────────────────────
        print("GithubPullRequests.merge")
        let review = [
            GithubPullRequests.parse(item: item(number: 10, updated: "2026-10-01T08:00:00Z"), reason: .reviewRequested)!,
            GithubPullRequests.parse(item: item(number: 11, updated: "2026-10-01T09:00:00Z"), reason: .reviewRequested)!,
        ]
        let assigned = [
            GithubPullRequests.parse(item: item(number: 11, updated: "2026-10-01T09:00:00Z"), reason: .assigned)!,
            GithubPullRequests.parse(item: item(number: 12, updated: "2026-10-01T12:00:00Z"), reason: .assigned)!,
        ]
        let merged = GithubPullRequests.merge([review, assigned])
        check("deduped count",                           "\(merged.count)", "3")
        check("review requests first, newest first, then assigned",
              "\(merged.map(\.number))", "[11, 10, 12]")
        let both = merged.first { $0.number == 11 }
        checkTrue("PR in both lists keeps both reasons",  both?.reasons == [.reviewRequested, .assigned])
        checkTrue("merge of nothing → empty",             GithubPullRequests.merge([]).isEmpty)

        // ── summary ────────────────────────────────────────────────────────────
        print("GithubPullRequests.summary")
        check("summary with both shows reviews",         GithubPullRequests.summary(merged) ?? "nil", "2 to review")
        check("summary review only",                     GithubPullRequests.summary(review) ?? "nil", "2 to review")
        check("summary assigned only",
              GithubPullRequests.summary([assigned[1]]) ?? "nil", "1 assigned")
        checkTrue("summary empty → nil",                 GithubPullRequests.summary([]) == nil)
        check("detailed summary with both",              GithubPullRequests.detailedSummary(merged) ?? "nil", "2 to review · 1 assigned")
        check("detailed summary review only",            GithubPullRequests.detailedSummary(review) ?? "nil", "2 to review")
        checkTrue("detailed summary empty → nil",        GithubPullRequests.detailedSummary([]) == nil)

        // ── searchURL ──────────────────────────────────────────────────────────
        print("GithubPullRequests.searchURL")
        let url = GithubPullRequests.searchURL(for: .reviewRequested)
        checkTrue("search URL built",                    url != nil)
        checkTrue("search URL hits api.github.com/search/issues",
                  url?.absoluteString.hasPrefix("https://api.github.com/search/issues?") == true)
        let q = URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value ?? ""
        check("review query",   q, "is:pr is:open archived:false review-requested:@me")
        let q2 = URLComponents(url: GithubPullRequests.searchURL(for: .assigned)!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value ?? ""
        check("assigned query", q2, "is:pr is:open archived:false assignee:@me")

        // ── errorMessage ───────────────────────────────────────────────────────
        print("GithubPullRequests.errorMessage")
        check("401",  GithubPullRequests.errorMessage(status: 401, transport: nil), "Invalid token (401)")
        check("403",  GithubPullRequests.errorMessage(status: 403, transport: nil), "Rate limited or missing scope (403)")
        check("0 with transport error", GithubPullRequests.errorMessage(status: 0, transport: "Offline"), "Offline")
        check("0 without transport error", GithubPullRequests.errorMessage(status: 0, transport: nil), "No connection")
        check("other", GithubPullRequests.errorMessage(status: 500, transport: nil), "API error 500")

        // ── result ─────────────────────────────────────────────────────────────
        if failures == 0 {
            print("\nAll GithubPullRequests tests passed.")
        } else {
            print("\n\(failures) failure(s).")
            exit(1)
        }
    }
}
