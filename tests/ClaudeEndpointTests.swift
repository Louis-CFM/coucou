import Foundation

@main
enum ClaudeEndpointTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func url(_ raw: String) -> String? {
        (try? ClaudeEndpoint.messagesURL(from: raw))?.absoluteString
    }

    static func failure(_ raw: String) -> ClaudeEndpoint.Failure? {
        do { _ = try ClaudeEndpoint.messagesURL(from: raw); return nil }
        catch { return error as? ClaudeEndpoint.Failure }
    }

    static func main() {
        print("ClaudeEndpoint.messagesURL")
        check("base URL gets /v1/messages",
              url("https://api.minimax.io/anthropic") == "https://api.minimax.io/anthropic/v1/messages")
        check("trailing slashes trimmed",
              url("https://api.minimax.io/anthropic//") == "https://api.minimax.io/anthropic/v1/messages")
        check("…/v1 gets /messages", url("https://gw.example.com/v1") == "https://gw.example.com/v1/messages")
        check("…/v1/messages kept", url("https://gw.example.com/v1/messages") == "https://gw.example.com/v1/messages")
        check("bare host", url("https://gw.example.com") == "https://gw.example.com/v1/messages")
        check("spaces trimmed", url("  https://gw.example.com  ") == "https://gw.example.com/v1/messages")
        check("fragment dropped", url("https://gw.example.com/x#frag") == "https://gw.example.com/x/v1/messages")
        check("port kept", url("https://gw.example.com:8443/") == "https://gw.example.com:8443/v1/messages")
        check("http to localhost", url("http://localhost:4000") == "http://localhost:4000/v1/messages")
        check("http to 127.0.0.1", url("http://127.0.0.1:20128") == "http://127.0.0.1:20128/v1/messages")
        check("http to [::1]", url("http://[::1]:4000") != nil)
        check("http to a public host refused", failure("http://gw.example.com") == .insecure)
        check("http to the local network refused", failure("http://192.168.1.10:4000") == .insecure)
        check("user and password refused", failure("https://me:secret@gw.example.com") == .credentials)
        check("user name alone refused", failure("https://me@gw.example.com") == .credentials)
        check("other scheme refused", failure("ftp://gw.example.com") == .invalid)
        check("no scheme refused", failure("gw.example.com") == .invalid)
        check("garbage refused", failure("not a url") == .invalid)

        print("ClaudeEndpoint.isLoopback")
        check("localhost", ClaudeEndpoint.isLoopback("localhost"))
        check("LOCALHOST", ClaudeEndpoint.isLoopback("LOCALHOST"))
        check("*.localhost", ClaudeEndpoint.isLoopback("gateway.localhost"))
        check("127.0.0.1", ClaudeEndpoint.isLoopback("127.0.0.1"))
        check("127.8.9.10", ClaudeEndpoint.isLoopback("127.8.9.10"))
        check("::1", ClaudeEndpoint.isLoopback("::1"))
        check("[::1]", ClaudeEndpoint.isLoopback("[::1]"))
        check("::ffff:127.0.0.1", ClaudeEndpoint.isLoopback("::ffff:127.0.0.1"))
        check("0.0.0.0", ClaudeEndpoint.isLoopback("0.0.0.0"))
        check("not 128.0.0.1", !ClaudeEndpoint.isLoopback("128.0.0.1"))
        check("not 127.0.0.1.example.com", !ClaudeEndpoint.isLoopback("127.0.0.1.example.com"))
        check("not localhost.example.com", !ClaudeEndpoint.isLoopback("localhost.example.com"))
        check("not 127.0.0.256", !ClaudeEndpoint.isLoopback("127.0.0.256"))

        print("ClaudeEndpoint.current")
        let env = [ClaudeEndpoint.environmentVariable: "https://api.minimax.io/anthropic"]
        check("nothing set → Anthropic", (try? ClaudeEndpoint.current(environment: [:]))?.isGateway == false)
        check("nothing set → api.anthropic.com",
              (try? ClaudeEndpoint.current(environment: [:]))?.messages == ClaudeEndpoint.anthropic)
        check("Claude Code's ANTHROPIC_BASE_URL ignored",
              (try? ClaudeEndpoint.current(environment: ["ANTHROPIC_BASE_URL": "https://proxy.example.com"]))?.isGateway == false)
        check("COUCOU_ANTHROPIC_BASE_URL used",
              (try? ClaudeEndpoint.current(environment: env))?.messages.host == "api.minimax.io")
        check("blank variable → Anthropic",
              (try? ClaudeEndpoint.current(environment: [ClaudeEndpoint.environmentVariable: "  "]))?.isGateway == false)
        var threw = false
        do { _ = try ClaudeEndpoint.current(environment: [ClaudeEndpoint.environmentVariable: "http://gw.example.com"]) } catch { threw = true }
        check("invalid URL throws, never falls back to Anthropic", threw)

        print("ClaudeEndpoint.current with Settings")
        let suite = "coucou-claude-endpoint-tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let other = [ClaudeEndpoint.environmentVariable: "https://env.example.com"]
        check("empty Settings → environment",
              (try? ClaudeEndpoint.current(defaults: defaults, environment: other))?.messages.host == "env.example.com")
        defaults.set("https://api.minimax.io/anthropic", forKey: ClaudeEndpoint.settingsKey)
        check("Settings wins over the environment",
              (try? ClaudeEndpoint.current(defaults: defaults, environment: other))?.messages.host == "api.minimax.io")
        defaults.set("   ", forKey: ClaudeEndpoint.settingsKey)
        check("blank Settings → environment",
              (try? ClaudeEndpoint.current(defaults: defaults, environment: other))?.messages.host == "env.example.com")
        defaults.set("http://gw.example.com", forKey: ClaudeEndpoint.settingsKey)
        threw = false
        do { _ = try ClaudeEndpoint.current(defaults: defaults, environment: [:]) } catch { threw = true }
        check("invalid Settings throws, never falls back to Anthropic", threw)
        defaults.removePersistentDomain(forName: suite)

        print("ClaudeEndpoint requests")
        let anthropic = ClaudeEndpoint(messages: ClaudeEndpoint.anthropic)
        let gateway = ClaudeEndpoint(messages: try! ClaudeEndpoint.messagesURL(from: "https://api.minimax.io/anthropic"))
        check("Anthropic is not a gateway", !anthropic.isGateway)
        check("MiniMax is a gateway", gateway.isGateway)
        check("Anthropic models URL", anthropic.models.absoluteString == "https://api.anthropic.com/v1/models?limit=100")
        check("gateway models URL", gateway.models.absoluteString == "https://api.minimax.io/anthropic/v1/models?limit=100")
        let a = anthropic.request(key: "sk-test", timeout: 4)
        check("Anthropic: POST", a.httpMethod == "POST")
        check("Anthropic: x-api-key", a.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        check("Anthropic: version", a.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        check("Anthropic: no bearer", a.value(forHTTPHeaderField: "Authorization") == nil)
        check("Anthropic: timeout", a.timeoutInterval == 4)
        let g = gateway.request(key: "sk-test", timeout: 30)
        check("gateway: sent to the gateway", g.url == gateway.messages)
        check("gateway: x-api-key", g.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        check("gateway: bearer", g.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        check("Anthropic: fast model", anthropic.model(fast: "claude-haiku-4-5", chat: "claude-sonnet-4-6") == "claude-haiku-4-5")
        check("gateway: chat model", gateway.model(fast: "claude-haiku-4-5", chat: "MiniMax-M3") == "MiniMax-M3")
        check("Anthropic: shared session", anthropic.session === URLSession.shared)
        check("gateway: own session", gateway.session !== URLSession.shared)

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll ClaudeEndpoint tests passed.")
    }
}
