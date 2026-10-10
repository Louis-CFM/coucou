import Foundation

@main struct ChatAPIErrorTests {
    static func main() {
        let cases = [
            (#"{"error":{"message":"Model unavailable"}}"#, "Model unavailable"),
            (#"[{"error":{"code":404,"message":"No access"}}]"#, "No access"),
            (#"{"error":"Route missing"}"#, "Route missing"),
            (#"{"message":"Not found"}"#, "Not found")
        ]
        for (body, expected) in cases {
            let error = ChatAPIError(status: 404, provider: "Google", model: "gemini-2.5-flash", data: Data(body.utf8))
            precondition(error.detail == expected)
            precondition(error.localizedDescription.contains("Google · gemini-2.5-flash (HTTP 404)"))
            precondition(error.localizedDescription.contains("refreshed model menu"))
        }
        let html = ChatAPIError(status: 502, provider: "OpenAI", model: "model", data: Data("<html>proxy error</html>".utf8))
        precondition(html.detail == nil)
        precondition(html.localizedDescription.contains("temporarily unavailable"))
        for code in [401, 403, 429] {
            let error = ChatAPIError(status: code, provider: "Provider", model: "model", data: Data())
            precondition(error.localizedDescription.contains(code == 429 ? "quota" : "permissions"))
        }
        print("Chat API error envelope and recovery-message tests passed")
    }
}
