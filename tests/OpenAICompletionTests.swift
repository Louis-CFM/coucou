import Foundation

@main
enum OpenAICompletionTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    static func reply(_ content: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    static func main() {
        print("OpenAICompletion.url")
        check("cloud base keeps its version",
              OpenAICompletion.url(base: "https://api.openai.com/v1", local: false)?.absoluteString
                == "https://api.openai.com/v1/chat/completions")
        check("Gemini's base",
              OpenAICompletion.url(base: "https://generativelanguage.googleapis.com/v1beta/openai", local: false)?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        check("local server gets /v1",
              OpenAICompletion.url(base: "http://127.0.0.1:11434", local: true)?.absoluteString
                == "http://127.0.0.1:11434/v1/chat/completions")
        check("trailing slash trimmed",
              OpenAICompletion.url(base: "http://127.0.0.1:1234/", local: true)?.absoluteString
                == "http://127.0.0.1:1234/v1/chat/completions")
        check("empty base → nil", OpenAICompletion.url(base: "  ", local: true) == nil)

        print("OpenAICompletion.request")
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        let r = OpenAICompletion.request(url: url, key: "sk-test", model: "gpt-x", system: "sys", user: "hello",
                                         timeout: 4, temperature: 0)
        let b = body(r)
        check("POST", r.httpMethod == "POST")
        check("bearer key", r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        check("JSON", r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        check("timeout", r.timeoutInterval == 4)
        check("model", b["model"] as? String == "gpt-x")
        check("temperature", b["temperature"] as? Double == 0)
        let messages = b["messages"] as? [[String: String]] ?? []
        check("system then user", messages.map { $0["role"] ?? "" } == ["system", "user"])
        check("contents", messages.map { $0["content"] ?? "" } == ["sys", "hello"])
        check("not streamed", b["stream"] == nil)
        let local = OpenAICompletion.request(url: url, key: nil, model: "llama", system: "s", user: "u", timeout: 120)
        check("no key → no Authorization", local.value(forHTTPHeaderField: "Authorization") == nil)
        check("empty key → no Authorization",
              OpenAICompletion.request(url: url, key: "", model: "m", system: "s", user: "u", timeout: 1)
                .value(forHTTPHeaderField: "Authorization") == nil)
        check("no temperature unless asked", body(local)["temperature"] == nil)

        print("OpenAICompletion.text")
        check("plain answer", OpenAICompletion.text(from: reply("  Hello.  ")) == "Hello.")
        check("reasoning left out", OpenAICompletion.text(from: reply("<think>hmm</think>\nThe summary")) == "The summary")
        check("only reasoning → nil", OpenAICompletion.text(from: reply("<think>hmm</think>")) == nil)
        check("empty → nil", OpenAICompletion.text(from: reply("")) == nil)
        check("null content → nil", OpenAICompletion.text(from: reply(NSNull())) == nil)
        check("error body → nil",
              OpenAICompletion.text(from: try! JSONSerialization.data(withJSONObject: ["error": ["message": "bad key"]])) == nil)
        check("not JSON → nil", OpenAICompletion.text(from: Data("<html>".utf8)) == nil)

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll OpenAICompletion tests passed.")
    }
}
