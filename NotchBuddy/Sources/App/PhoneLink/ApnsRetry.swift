// After Apple refused a Live Activity token as BadDeviceToken: the other push
// server to try, once. A token only works on one of the two (sandbox for builds
// run from Xcode, production for TestFlight and the App Store); refused by both,
// it is no good anywhere and nothing more is sent for it.
enum ApnsRetry {
    static func otherEnvironment(after env: String, alreadyRetried: Bool) -> String? {
        guard !alreadyRetried else { return nil }
        return env == "production" ? "development" : "production"
    }
}
