import Foundation

// Same cases as the tests in windows/src-tauri/src/open_webui.rs.

@main
enum OpenWebUITests {

    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    static func main() {
        print("OpenWebUI key")
        let stored = OpenWebUI.boundKey("sk-x", url: "http://127.0.0.1:8080")
        checkTrue("key for its own address", OpenWebUI.key(stored: stored, url: "http://127.0.0.1:8080") == "sk-x")
        checkTrue("no key for another address", OpenWebUI.key(stored: stored, url: "https://elsewhere.example") == nil)
        checkTrue("no key stored", OpenWebUI.key(stored: nil, url: "http://127.0.0.1:8080") == nil)
        checkTrue("https carries a key", OpenWebUI.mayCarryKey("https://chat.example.com"))
        checkTrue("loopback http carries a key", OpenWebUI.mayCarryKey("http://localhost:8080"))
        checkTrue("plain http elsewhere does not", !OpenWebUI.mayCarryKey("http://192.168.1.5:8080"))
        checkTrue("127.x and ::1 are loopback", OpenWebUI.mayCarryKey("http://127.0.0.2:3000")
                  && OpenWebUI.mayCarryKey("http://[::1]:8080"))
        checkTrue("a name starting with 127. is not", !OpenWebUI.mayCarryKey("http://127.attacker.example:8080")
                  && !OpenWebUI.mayCarryKey("http://127.0.0.1.attacker.example"))
        checkTrue("only localhost itself is", !OpenWebUI.mayCarryKey("http://localhost.attacker.example"))

        print("OpenWebUI models")
        let models = OpenWebUI.parseModels(json(#"{"data":[{"id":"llama3","name":"Llama 3"},{"id":"bare"}]}"#)) ?? []
        checkTrue("named by name, else id", models.map(\.label) == ["Llama 3", "bare"])
        let body = json(#"""
        {"data": [
          {"id": "zeta", "name": "Zeta"},
          {"id": "reviewer", "name": "Code Reviewer", "info": {"base_model_id": "gpt"}},
          {"id": "gpt", "name": "GPT"},
          {"id": "alpha", "name": "alpha"},
          {"id": "summarizer", "name": "Summarizer", "info": {"base_model_id": "gpt"}},
          {"id": "plain", "name": "Plain", "info": {"base_model_id": null}}
        ]}
        """#)
        let usage = OpenWebUI.parseUsage(json(#"""
        {"models": [{"model_id": "summarizer", "count": 42}, {"model_id": "gpt", "count": 17},
                    {"model_id": "gone", "count": 9}, {"model_id": "zeta", "count": 0}]}
        """#))
        let ranked = OpenWebUI.rank(OpenWebUI.parseModels(body) ?? [], usage: usage)
        checkTrue("most used, then workspace, then by name",
                  ranked.map(\.id) == ["summarizer", "gpt", "reviewer", "alpha", "plain", "zeta"])
        checkTrue("groups follow", ranked.map(\.group) == [.used, .used, .custom, nil, nil, nil])
        let unranked = OpenWebUI.rank(OpenWebUI.parseModels(body) ?? [], usage: [:])
        checkTrue("without analytics nothing is used", unranked.first?.id == "reviewer" && !unranked.contains { $0.group == .used })

        print("OpenWebUI chat")
        let id = OpenWebUI.newID()
        checkTrue("ids look like uuids", id.count == 36 && Array(id)[14] == "4")
        let (empty, none) = OpenWebUI.newChat(history: [], model: "m", at: 10)
        checkTrue("an empty chat has no current message",
                  none == nil && (((empty["chat"] as? [String: Any])?["history"] as? [String: Any])?["currentId"] is NSNull))
        let (chat, last) = OpenWebUI.newChat(history: [("user", "hi"), ("assistant", "hello")], model: "m", at: 10)
        let messages = (((chat["chat"] as? [String: Any])?["history"] as? [String: Any])?["messages"] as? [String: [String: Any]]) ?? [:]
        let answer = messages[last ?? ""] ?? [:]
        let question = messages[answer["parentId"] as? String ?? ""] ?? [:]
        checkTrue("earlier turns are a linked history",
                  messages.count == 2 && answer["done"] as? Bool == true && question["content"] as? String == "hi"
                  && question["childrenIds"] as? [String] == [last ?? ""])

        let first = OpenWebUI.completion(model: "m", system: "sys", thread: .init(id: "c", last: nil), userID: "u",
                                         answerID: "a", text: "q", at: 5, webSearch: true, variables: [:])
        checkTrue("searching asks for legacy function calling",
                  (first["features"] as? [String: Bool])?["web_search"] == true
                  && (first["params"] as? [String: String])?["function_calling"] == "legacy")
        checkTrue("a first turn names the chat",
                  (first["background_tasks"] as? [String: Bool])?["title_generation"] == true && first["parent_id"] is NSNull)
        let later = OpenWebUI.completion(model: "m", system: "sys", thread: .init(id: "c", last: "a0"), userID: "u",
                                         answerID: "a", text: "q", at: 5, webSearch: false, variables: [:])
        checkTrue("a later turn hangs under the last answer",
                  later["parent_id"] as? String == "a0" && later["params"] == nil
                  && (later["user_message"] as? [String: Any])?["parentId"] as? String == "a0")

        print("OpenWebUI answers")
        checkTrue("answer from the reply",
                  OpenWebUI.answerInReply(json(#"{"choices":[{"message":{"role":"assistant","content":"Hi!"}}]}"#)) == "Hi!")
        let streaming = json(#"{"chat":{"history":{"messages":{"a":{"content":"Hal","done":false}}}}}"#)
        checkTrue("answer from the stored chat", OpenWebUI.answerInChat(streaming, "a").map { $0.text == "Hal" && !$0.done } == true)
        let failed = json(#"{"chat":{"history":{"messages":{"a":{"content":"","done":true,"error":{"content":"Filter failed "}}}}}}"#)
        checkTrue("a failed filter's message", OpenWebUI.errorInChat(failed, "a") == "Filter failed")

        print("OpenWebUI variables")
        let kept = OpenWebUI.templateVariables([
            "{{CURRENT_TIMEZONE}}": "Europe/Paris", "token": "x", "{{lower}}": "x",
            "{{LONG}}": String(repeating: "x", count: 101),
        ])
        checkTrue("only template variables go to the server", Array(kept.keys) == ["{{CURRENT_TIMEZONE}}"])
        let date = Date(timeIntervalSince1970: 1_791_655_500)   // 10.10.2026 18:05 UTC
        // Not UTC: macOS Foundation reports its identifier as "GMT"
        let vars = OpenWebUI.promptVariables(now: date, timeZone: TimeZone(identifier: "Europe/Helsinki")!, language: "fi-FI")
        checkTrue("date, time and timezone", vars["{{CURRENT_DATETIME}}"] == "2026-10-10 21:05:00"
                  && vars["{{CURRENT_WEEKDAY}}"] == "Saturday" && vars["{{CURRENT_TIMEZONE}}"] == "Europe/Helsinki")

        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nAll Open WebUI tests passed")
    }
}
