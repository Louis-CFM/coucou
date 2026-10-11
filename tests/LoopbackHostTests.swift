import Foundation

// Same cases as is_loopback_host in windows/src-tauri/src/net.rs.

@main
enum LoopbackHostTests {
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { print("  ✓ \(name)") } else { print("  ✗ \(name)"); failures += 1 }
        }
        for host in ["localhost", "LOCALHOST", "app.localhost", "127.0.0.1", "127.0.0.2", "0.0.0.0",
                     "::1", "[::1]", "::", "::ffff:127.0.0.1"] {
            check(LoopbackHost.matches(host), "\(host) is this Mac")
        }
        for host in ["127.attacker.example", "127.0.0.1.attacker.example", "localhost.attacker.example",
                     "192.168.1.5", "10.0.0.1", "::ffff:10.0.0.1", "127.1", "example.com", ""] {
            check(!LoopbackHost.matches(host), "\(host) is not")
        }
        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("LoopbackHost: all passed")
    }
}
