import Foundation

/// A child process that ends with Coucou, even when Coucou is killed outright.
/// A shell runs the command and watches its stdin, a pipe only Coucou holds: the
/// kernel closes it when Coucou dies, and the shell then ends the command.
enum TiedProcess {
    static let shell = #"""
    exec 3<&0
    "$@" </dev/null & child=$!
    (read -r _ <&3; kill $child 2>/dev/null) & watch=$!
    trap 'kill $child 2>/dev/null' TERM
    wait $child; status=$?
    kill $watch 2>/dev/null
    exit $status
    """#

    /// `executable` run with `arguments`. Keep the pipe for as long as it runs.
    static func make(_ executable: String, _ arguments: [String]) -> (Process, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", shell, "sh", executable] + arguments
        let tie = Pipe()
        p.standardInput = tie
        return (p, tie)
    }
}
