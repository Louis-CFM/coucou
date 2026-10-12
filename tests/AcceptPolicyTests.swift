import Darwin

@main
enum AcceptPolicyTests {
    static func main() {
        // A signal or a client that hung up first: just accept again.
        precondition(AcceptPolicy.next(afterErrno: EINTR) == .retry)
        precondition(AcceptPolicy.next(afterErrno: ECONNABORTED) == .retry)
        precondition(AcceptPolicy.next(afterErrno: EAGAIN) == .retry)
        // Out of descriptors or memory: give the machine a moment, then go on.
        precondition(AcceptPolicy.next(afterErrno: EMFILE) == .retryAfterPause)
        precondition(AcceptPolicy.next(afterErrno: ENFILE) == .retryAfterPause)
        precondition(AcceptPolicy.next(afterErrno: ENOBUFS) == .retryAfterPause)
        // The listening socket itself is gone: nothing left to serve.
        precondition(AcceptPolicy.next(afterErrno: EBADF) == .stop)
        precondition(AcceptPolicy.next(afterErrno: EINVAL) == .stop)
        print("AcceptPolicy tests passed")
    }
}
