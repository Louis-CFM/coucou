import Foundation

@main
enum SlackParsingTests {
    static func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    static func main() {
        // Errors: ok:false with a code, missing scopes named
        precondition(SlackParsing.error(json(#"{"ok":true}"#)) == nil)
        precondition(SlackParsing.error(json(#"{"ok":false,"error":"invalid_auth"}"#)) == "Invalid token")
        precondition(SlackParsing.error(json(#"{"ok":false,"error":"not_allowed_token_type"}"#)) == "Use a user token (xoxp-…)")
        precondition(SlackParsing.error(json(#"{"ok":false,"error":"missing_scope","needed":"search:read"}"#))
                     == "Missing scope: search:read")
        precondition(SlackParsing.error(json(#"{"ok":false,"error":"ratelimited"}"#)) == "Slack error: ratelimited")

        // One conversation or person Slack no longer finds is skipped, not an error
        precondition(SlackParsing.isMissing(json(#"{"ok":false,"error":"channel_not_found"}"#)))
        precondition(SlackParsing.isMissing(json(#"{"ok":false,"error":"user_not_found"}"#)))
        precondition(!SlackParsing.isMissing(json(#"{"ok":false,"error":"invalid_auth"}"#)))
        precondition(!SlackParsing.isMissing(json(#"{"ok":true}"#)))

        // auth.test
        let me = SlackParsing.identity(json(#"""
        {"ok":true,"url":"https://subarachnoid.slack.com/","team":"Subarachnoid Workspace",
         "user":"grace","team_id":"T12345678","user_id":"W12345678"}
        """#))
        precondition(me == SlackIdentity(userId: "W12345678", teamId: "T12345678",
                                         url: "https://subarachnoid.slack.com/"))
        precondition(SlackParsing.identity(json(#"{"ok":false,"error":"invalid_auth"}"#)) == nil)

        // conversations.list: deactivated people dropped, priority kept
        let ims = SlackParsing.ims(json(#"""
        {"ok":true,"channels":[
          {"id":"D0C0F7S8Y","created":1498500348,"is_im":true,"user":"U0BS9U4SV","is_user_deleted":false,"priority":0},
          {"id":"D0BSHH4AD","is_im":true,"user":"U0C0NS9HN","is_user_deleted":true,"priority":0.9},
          {"id":"D0BSHH4AE","is_im":true,"user":"U0C0NS9HP","priority":0.5}]}
        """#))
        precondition(ims.map(\.channelId) == ["D0C0F7S8Y", "D0BSHH4AE"])
        precondition(ims[1].priority == 0.5)

        // Which conversations a poll looks at: the closest, plus any still unread
        let pool = (0..<5).map { SlackIM(channelId: "D\($0)", userId: "U\($0)", priority: Double($0)) }
        let picked = SlackParsing.imsToCheck(pool, unread: ["D0"], limit: 2).map(\.channelId)
        precondition(picked == ["D4", "D3", "D0"])

        // conversations.info: unread DM from the other person
        let dm = SlackParsing.unreadDM(json(#"""
        {"ok":true,"channel":{"id":"D0BSHH4AD","is_im":true,"user":"U27FFLNF4",
          "last_read":"1513718191.000038",
          "latest":{"type":"message","user":"U27FFLNF4","text":"Psssst!","ts":"1513718191.000038"},
          "unread_count":2,"unread_count_display":2}}
        """#), me: "W1")
        precondition(dm?.kind == .dm && dm?.unread == 2 && dm?.text == "Psssst!")
        precondition(dm?.userId == "U27FFLNF4" && dm?.ts == "1513718191.000038")
        // Read, or my own last word: nothing to show
        precondition(SlackParsing.unreadDM(json(#"""
        {"ok":true,"channel":{"id":"D1","is_im":true,"user":"U2","unread_count_display":0}}
        """#), me: "W1") == nil)
        precondition(SlackParsing.unreadDM(json(#"""
        {"ok":true,"channel":{"id":"D1","is_im":true,"user":"U2","unread_count_display":1,
          "latest":{"user":"W1","text":"done","ts":"1.0"}}}
        """#), me: "W1") == nil)

        // search.messages: recent mentions by others only
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let mentions = SlackParsing.mentions(json(#"""
        {"ok":true,"query":"<@W1>","messages":{"matches":[
          {"type":"message","user":"U2","username":"egon","ts":"1699999000.000100","text":"<@W1> look",
           "channel":{"id":"C12345678","name":"general"},
           "permalink":"https://hitchhikers.slack.com/archives/C12345678/p1699999000000100"},
          {"type":"message","user":"W1","username":"me","ts":"1699999500.000000","text":"<@W1> note to self",
           "channel":{"id":"C12345678","name":"general"}},
          {"type":"message","user":"U3","username":"ray","ts":"1600000000.000000","text":"old",
           "channel":{"id":"C2","name":"random"}}]}}
        """#), me: "W1", now: now)
        precondition(mentions.count == 1)
        precondition(mentions[0].author == "egon" && mentions[0].channelName == "general")
        precondition(mentions[0].permalink?.hasPrefix("https://hitchhikers.slack.com/") == true)

        // conversations.info last_read: only mentions newer than it stay
        precondition(SlackParsing.lastRead(json(#"{"ok":true,"channel":{"id":"C1","last_read":"1699999000.000100"}}"#)) == "1699999000.000100")
        precondition(SlackParsing.lastRead(json(#"{"ok":false,"error":"missing_scope"}"#)) == nil)
        precondition(SlackParsing.unreadMentions(mentions, lastRead: ["C12345678": "1699999000.000100"]).isEmpty)
        precondition(SlackParsing.unreadMentions(mentions, lastRead: ["C12345678": "1699999000.000099"]).count == 1)
        precondition(SlackParsing.unreadMentions(mentions, lastRead: [:]).count == 1)

        // users.info: display name, falling back to the real name
        precondition(SlackParsing.userName(json(#"""
        {"ok":true,"user":{"id":"W1","name":"spengler","real_name":"Egon Spengler",
          "profile":{"display_name":"","real_name":"Egon Spengler"}}}
        """#)) == "Egon Spengler")
        precondition(SlackParsing.userName(json(#"""
        {"ok":true,"user":{"id":"W1","name":"spengler","profile":{"display_name":"egon"}}}
        """#)) == "egon")

        // Timestamps: compared exactly, beyond what a Double keeps
        precondition(SlackParsing.tsLess("1513718191.000038", "1513718191.000039"))
        precondition(!SlackParsing.tsLess("1513718191.000039", "1513718191.000038"))
        precondition(SlackParsing.tsLess("999999999.9", "1000000000.0"))
        let a = SlackMessage(kind: .dm, channelId: "D1", channelName: nil, userId: "U1", author: "a",
                             text: "", ts: "100.000001", unread: 1, permalink: nil)
        let b = SlackMessage(kind: .mention, channelId: "C1", channelName: "g", userId: "U2", author: "b",
                             text: "", ts: "100.000002", unread: 0, permalink: nil)
        precondition(SlackParsing.newest([a, b])?.id == b.id)
        precondition(SlackParsing.merged(dms: [a], mentions: [b]).map(\.kind) == [.dm, .mention])

        // Snippets: Slack markup made readable
        let names = ["U2": "egon"]
        precondition(SlackParsing.snippet("<@U2> see <#C1|general>\n<https://x.dev|the doc> &amp; <https://y.dev>",
                                          names: names) == "@egon see #general the doc & https://y.dev")
        precondition(SlackParsing.snippet("<!here> 3 &lt; 4", names: [:]) == "@here 3 < 4")
        precondition(SlackParsing.snippet("<@U9>", names: [:]) == "@U9")
        precondition(SlackParsing.snippet("unclosed < bracket", names: [:]) == "unclosed < bracket")

        // Links: the app first, the permalink or a redirect in the browser
        precondition(SlackLinks.app(team: "T1", channel: "D1")?.absoluteString == "slack://channel?team=T1&id=D1")
        precondition(SlackLinks.app(team: "T1", channel: "C1", permalink: "https://a.slack.com/archives/C1/p1699999000000100")?
            .absoluteString == "slack://channel?team=T1&id=C1&message=1699999000.000100")
        precondition(SlackLinks.app(team: "T1", channel: "C1",
                                    permalink: "https://a.slack.com/archives/C1/p1699999000000100?thread_ts=1699998000.000200&cid=C1")?
            .absoluteString == "slack://channel?team=T1&id=C1&message=1699999000.000100&thread_ts=1699998000.000200")
        precondition(SlackLinks.app(team: "T1", channel: "C1", permalink: "https://a.slack.com/archives/C1/p1x&evil=1")?
            .absoluteString == "slack://channel?team=T1&id=C1")
        precondition(SlackLinks.web(team: "T1", channel: "C1", permalink: "https://a.slack.com/archives/C1/p1")?
                        .absoluteString == "https://a.slack.com/archives/C1/p1")
        precondition(SlackLinks.web(team: "T1", channel: "D1", permalink: nil)?.absoluteString
                     == "https://slack.com/app_redirect?channel=D1&team=T1")
        precondition(SlackLinks.web(team: "T1", channel: "D1", permalink: "javascript:alert(1)")?.absoluteString
                     == "https://slack.com/app_redirect?channel=D1&team=T1")

        // Retry-After: a wait, never forever
        precondition(SlackParsing.retryAfter("30") == 30)
        precondition(SlackParsing.retryAfter(nil) == 60)
        precondition(SlackParsing.retryAfter("soon") == 60)
        precondition(SlackParsing.retryAfter("1e300") == 3600)
        precondition(SlackParsing.retryAfter("inf") == 60)
        precondition(SlackParsing.retryAfter("nan") == 60)
        precondition(SlackParsing.retryAfter("-5") == 0)

        print("Slack parsing: 38 cases passed")
    }
}
