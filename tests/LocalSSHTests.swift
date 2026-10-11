import Foundation

@main
struct LocalSSHTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if cond { print("  ✓ \(msg)") } else { print("  ✗ \(msg)"); failures += 1 }
        }
        func dest(_ user: String?, _ host: String, _ port: Int?) -> LocalSSH.Destination {
            LocalSSH.Destination(user: user, host: host, port: port)
        }
        func call(_ line: String) -> (LocalSSH.Destination, String)? {
            LocalSSH.call(line.split(separator: " ").map(String.init))
        }

        check(LocalSSH.destination("devbox") == dest(nil, "devbox", nil), "a plain host")
        check(LocalSSH.destination("me@Build.Example.org") == dest("me", "build.example.org", nil), "user@host, host lower-cased")
        check(LocalSSH.destination("ssh://mastodon@localhost:23456") == dest("mastodon", "localhost", 23456), "an ssh:// URL")
        check(LocalSSH.destination("ssh://[::1]:2222") == dest(nil, "::1", 2222), "IPv6 in an ssh:// URL")
        check(LocalSSH.destination("a@b@host") == dest("a@b", "host", nil), "the last @ splits the user")
        check(LocalSSH.destination("ssh://host:x") == nil, "a port that is no number")
        check(LocalSSH.destination("me@") == nil, "no host")
        check(LocalSSH.destination("-oProxyCommand=x") == nil, "an option is never a host")

        check(call("ssh devbox")?.0 == dest(nil, "devbox", nil), "ssh host")
        check(call("ssh -p 2222 -i key me@h")?.0 == dest("me", "h", 2222), "values apart")
        check(call("ssh -tp2222 -l me h")?.0 == dest("me", "h", 2222), "flags clustered with a value glued")
        check(call("ssh -oPort=2200 -o User=you h")?.0 == dest("you", "h", 2200), "-o Port and User")
        check(call("ssh -J jump -F cfg -L 8080:x:80 -E log -b 0.0.0.0 h")?.0 == dest(nil, "h", nil), "a value is never the destination")
        check(call("ssh me@h -p 2222 -l other")?.0 == dest("me", "h", 2222), "options after the destination, first value wins")
        check(call("ssh -l me -p 1 ssh://you@h:2")?.0 == dest("me", "h", 1), "-l and -p before an ssh:// URL win")
        check(call("ssh -t h tmux attach -t main")?.1 == "tmux attach -t main", "the rest is the remote command")
        check(call("ssh -- h -p 1").map { $0.0 == dest(nil, "h", nil) && $0.1 == "-p 1" } == true, "after --, no options")
        for line in ["ssh -N -R x:y h", "ssh -fN h", "ssh -W h:22 jump", "ssh -O check h", "ssh -NT -o BatchMode=yes -- h", "ssh", "ssh -p", "ssh -v"] {
            check(call(line) == nil, "no session: \(line)")
        }

        let host = LocalSSH.destination("ssh://mastodon@localhost:23456")!
        func same(_ line: String, _ want: LocalSSH.Destination) -> Bool { LocalSSH.same(call(line)!.0, want) }
        check(same("ssh -p 23456 mastodon@localhost", host), "the host as typed")
        check(same("ssh -p 23456 LOCALHOST", host), "no user named: any")
        check(!same("ssh mastodon@localhost", host), "another port")
        check(!same("ssh -p 23456 root@localhost", host), "another user")
        check(same("ssh -A me@devbox", LocalSSH.destination("devbox")!), "an alias with a user")
        check(!same("ssh -p 2222 devbox", LocalSSH.destination("devbox")!), "an alias on another port")

        func proc(_ pid: Int32, age: Int) -> LocalSSH.Proc {
            LocalSSH.Proc(pid: pid, ppid: 1, tty: "/dev/ttys001", age: age, name: "ssh")
        }
        let found = [(proc(10, age: 50), ""), (proc(11, age: 5), "htop"),
                     (proc(12, age: 400), "tmux attach -t 'work-2'"), (proc(13, age: 900), "tmux attach -t work-22")]
        check(LocalSSH.pick(found, tmux: "work-2")?.pid == 12, "the ssh on the session's tmux wins")
        check(LocalSSH.pick(found, tmux: "")?.pid == 11, "else the newest")
        check(LocalSSH.pick([], tmux: "x") == nil, "none")

        let ps = """
              812     1 ??        3-01:02:03 launchd
              900   812 ttys004      01:05 zsh
              901   900 ttys004   02:10:00 ssh
              902   812 ttys005      00:07 Google Chrome H
            """
        let procs = LocalSSH.processes(ps: ps)
        check(procs.map(\.pid) == [900, 901, 902], "processes without a terminal are left out")
        check(procs.first?.tty == "/dev/ttys004" && procs.last?.name == "Google Chrome H", "tty path and names with spaces")
        check(procs[1].age == 7800, "elapsed time in seconds")
        check(LocalSSH.seconds(etime: "3-01:02:03") == 3 * 86_400 + 3723, "days")
        check(LocalSSH.seconds(etime: "x") == nil && LocalSSH.seconds(etime: "1:2:3:4") == nil, "not a time")
        check(LocalSSH.ancestors(of: 901, in: procs + [LocalSSH.Proc(pid: 812, ppid: 1, tty: "", age: 0, name: "launchd")])
              == [900, 812], "parents up to launchd")

        var args: [UInt8] = [3, 0, 0, 0]
        args += Array("/usr/bin/ssh".utf8) + [0, 0, 0]
        args += Array("ssh".utf8) + [0] + Array("-t".utf8) + [0] + Array("host".utf8) + [0] + Array("HOME=/x".utf8) + [0]
        check(LocalSSH.argv(procArgs: args) == ["ssh", "-t", "host"], "argv from a KERN_PROCARGS2 buffer")
        check(LocalSSH.argv(procArgs: [1, 0]) == [], "a short buffer")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All local ssh tests passed")
    }
}
