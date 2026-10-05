import Foundation

@main
enum GitLabPulseTests {

    static var failures = 0

    static func check(_ label: String, _ got: String?, _ expected: String?) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got.debugDescription)")
            print("    expected: \(expected.debugDescription)")
            failures += 1
        }
    }

    static func response(pipeline: String) -> Data {
        Data("""
        {"data":{"currentUser":{"username":"jdoe",
          "authoredMergeRequests":{"nodes":[
            {"iid":"12","title":"Fix login redirect","webUrl":"https://git.example.com/acme/web/-/merge_requests/12",
             "draft":false,"approved":true,"diffHeadSha":"abc","project":{"fullPath":"acme/web"},
             "headPipeline":{"status":"\(pipeline)"}},
            {"iid":"12","title":"duplicate","webUrl":"https://git.example.com/acme/web/-/merge_requests/12",
             "draft":false,"approved":false,"diffHeadSha":"abc","project":{"fullPath":"acme/web"},
             "headPipeline":null},
            {"iid":"7","title":"Draft: new billing page","webUrl":"https://git.example.com/acme/docs/-/merge_requests/7",
             "draft":true,"approved":false,"diffHeadSha":"def","project":{"fullPath":"acme/docs"},
             "headPipeline":null},
            {"iid":"not-a-number","title":"broken","webUrl":"x","project":{"fullPath":"acme/x"}}
          ]},
          "reviewRequestedMergeRequests":{"nodes":[
            {"iid":"31","title":"Add search filters","webUrl":"https://git.example.com/acme/api/-/merge_requests/31",
             "draft":false,"project":{"fullPath":"acme/api"}}
          ]}}}}
        """.utf8)
    }

    static func main() {
        // ── parse ──────────────────────────────────────────────────────────────
        print("GitLabPulse.parse")
        let pulse = GitLabPulse.parse(response(pipeline: "FAILED"))
        check("username", pulse?.login, "jdoe")
        check("duplicates and broken nodes are skipped", "\(pulse?.myPRs.count ?? -1)", "2")
        check("id uses ! like GitLab", pulse?.myPRs.first?.id, "acme/web!12")
        check("iid becomes the number", "\(pulse?.myPRs.first?.number ?? -1)", "12")
        check("failed pipeline", pulse?.myPRs.first?.ci.rawValue, "failure")
        check("approved MR", pulse?.myPRs.first?.review.rawValue, "approved")
        check("head sha kept for CI alerts", pulse?.myPRs.first?.headSha, "abc")
        check("no pipeline is unknown", pulse?.myPRs.last?.ci.rawValue, "unknown")
        check("draft", "\(pulse?.myPRs.last?.isDraft ?? false)", "true")
        check("review requested", pulse?.toReview.first?.id, "acme/api!31")
        check("no default-branch CI on GitLab", "\(pulse?.mainCI.count ?? -1)", "0")
        check("not GitLab JSON", GitLabPulse.parse(Data("{\"data\":{}}".utf8)) == nil ? "nil" : "parsed", "nil")

        print("CIState(rawGitLab:)")
        check("running", CIState(rawGitLab: "RUNNING").rawValue, "pending")
        check("waiting for resource", CIState(rawGitLab: "WAITING_FOR_RESOURCE").rawValue, "pending")
        check("success", CIState(rawGitLab: "SUCCESS").rawValue, "success")
        check("canceled", CIState(rawGitLab: "CANCELED").rawValue, "unknown")
        check("manual", CIState(rawGitLab: "MANUAL").rawValue, "unknown")

        // ── alerts reuse the GitHub rules ──────────────────────────────────────
        print("GitHubPulse.events on GitLab data")
        let running = GitLabPulse.parse(response(pipeline: "RUNNING"))!
        let failed = GitLabPulse.parse(response(pipeline: "FAILED"))!
        let passed = GitLabPulse.parse(response(pipeline: "SUCCESS"))!
        check("running → failed alerts", "\(GitHubPulse.events(old: running, new: failed))",
              "\([GitHubEvent.ciFailed(prId: "acme/web!12")])")
        check("running → success alerts", "\(GitHubPulse.events(old: running, new: passed))",
              "\([GitHubEvent.ciPassed(prId: "acme/web!12")])")
        check("first load never alerts", "\(GitHubPulse.events(old: nil, new: failed).count)", "0")

        // ── instance URL ───────────────────────────────────────────────────────
        print("GitLabPulse.baseURL")
        check("empty → gitlab.com", GitLabPulse.baseURL(from: "")?.absoluteString, "https://gitlab.com")
        check("bare host gets https", GitLabPulse.baseURL(from: " git.example.com/ ")?.absoluteString, "https://git.example.com")
        check("http is refused (the token would travel in clear)", GitLabPulse.baseURL(from: "http://git.example.com")?.absoluteString, nil)

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
