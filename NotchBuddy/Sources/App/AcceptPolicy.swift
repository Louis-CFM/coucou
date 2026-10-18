import Darwin

// What the hook server does after accept() failed. Leaving its loop means no
// hook event reaches Coucou again until it restarts, so it only does that when
// the listening socket itself is unusable.
enum AcceptPolicy {
    enum Next: Equatable {
        case retry
        case retryAfterPause
        case stop
    }

    static func next(afterErrno e: Int32) -> Next {
        switch e {
        case EINTR, ECONNABORTED, EAGAIN:
            return .retry
        case EMFILE, ENFILE, ENOBUFS, ENOMEM:
            return .retryAfterPause
        default:
            return .stop   // EBADF, EINVAL, ENOTSOCK…: the server socket is gone
        }
    }
}
