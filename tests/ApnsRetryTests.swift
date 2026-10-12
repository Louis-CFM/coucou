@main
enum ApnsRetryTests {
    static func main() {
        precondition(ApnsRetry.otherEnvironment(after: "production", alreadyRetried: false) == "development")
        precondition(ApnsRetry.otherEnvironment(after: "development", alreadyRetried: false) == "production")
        // A second refusal means the token is no good anywhere: nothing more is sent.
        precondition(ApnsRetry.otherEnvironment(after: "production", alreadyRetried: true) == nil)
        precondition(ApnsRetry.otherEnvironment(after: "development", alreadyRetried: true) == nil)
        print("ApnsRetry tests passed")
    }
}
