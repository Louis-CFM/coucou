import Foundation

@main
struct SSHDestinationTests {
    static func main() {
        var failures = 0
        func check(_ got: String?, _ want: String?, _ name: String) {
            if got == want { print("  ✓ \(name)") } else { print("  ✗ \(name): \(got ?? "nil")"); failures += 1 }
        }

        check(SSHDestination.parse("devbox"), "devbox", "a plain host stays as typed")
        check(SSHDestination.parse(" alice@203.0.113.7 "), "alice@203.0.113.7", "spaces around are dropped")
        check(SSHDestination.parse("alice@203.0.113.7 -p 2222"), "ssh://alice@203.0.113.7:2222", "-p after the host")
        check(SSHDestination.parse("-p 2222 alice@203.0.113.7"), "ssh://alice@203.0.113.7:2222", "-p before the host")
        check(SSHDestination.parse("alice@203.0.113.7 -p2222"), "ssh://alice@203.0.113.7:2222", "-p glued to the port")
        check(SSHDestination.parse("alice@203.0.113.7:2222"), "ssh://alice@203.0.113.7:2222", "host:port")
        check(SSHDestination.parse("ssh://alice@devbox:2222"), "ssh://alice@devbox:2222", "an ssh:// URL stays")
        check(SSHDestination.parse("[fe80::1]:2222"), "ssh://[fe80::1]:2222", "IPv6 in brackets with a port")
        check(SSHDestination.parse("fe80::1"), "fe80::1", "bare IPv6 is not read as a port")
        check(SSHDestination.parse("devbox -p 0"), nil, "port 0 is refused")
        check(SSHDestination.parse("devbox -p 70000"), nil, "port above 65535 is refused")
        check(SSHDestination.parse("-oProxyCommand=x"), nil, "an option is never a host")
        check(SSHDestination.parse("devbox -i key"), nil, "other ssh options are refused")
        check(SSHDestination.parse(""), nil, "empty is refused")

        check(SSHDestination.label("ssh://alice@203.0.113.7:2222"), "alice@203.0.113.7", "label drops the scheme and port")
        check(SSHDestination.label("ssh://[2001:db8::7]:2222"), "[2001:db8::7]", "label of IPv6 with a port")
        check(SSHDestination.label("devbox"), "devbox", "label of a plain host")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All SSH destination tests passed")
    }
}
