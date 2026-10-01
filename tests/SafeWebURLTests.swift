import Foundation

@main
enum SafeWebURLTests {
    static func main() {
        // Accepted: plain http/https URLs
        precondition(safeWebURL("https://example.com") != nil)
        precondition(safeWebURL("http://example.com/a?b=1") != nil)
        precondition(safeWebURL("HTTPS://EXAMPLE.COM") != nil)
        precondition(safeWebURL(" https://example.com \n") != nil)
        precondition(safeWebURL("http://localhost:5678") != nil)

        // Rejected: nil, empty, non-web schemes, malformed
        precondition(safeWebURL(nil) == nil)
        precondition(safeWebURL("") == nil)
        precondition(safeWebURL("file:///etc/hosts") == nil)
        precondition(safeWebURL("javascript:alert(1)") == nil)
        precondition(safeWebURL("vscode://file/etc/hosts") == nil)
        precondition(safeWebURL("smb://server/share") == nil)
        precondition(safeWebURL("mailto:a@b.c") == nil)
        precondition(safeWebURL("https://") == nil)
        precondition(safeWebURL("https:example.com") == nil)
        precondition(safeWebURL("//example.com") == nil)

        print("Safe web links: 15 cases passed")
    }
}
