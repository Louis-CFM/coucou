import Foundation

// MARK: - ClaudeEndpoint
//
// Where Claude requests go: Anthropic's API, or an Anthropic-compatible gateway
// (MiniMax, LiteLLM, a company proxy…) set in Settings → Chat, or in
// COUCOU_ANTHROPIC_BASE_URL, the variable the Windows and Linux app reads.
// Claude Code's own ANTHROPIC_BASE_URL is never read: it may name a proxy the
// user never meant to hand this key to. Same rules as net::anthropic_endpoint
// on Windows: https only (plain http only to this Mac), no user name or
// password in the URL, and a base URL gets /v1/messages appended.

struct ClaudeEndpoint: Equatable, Sendable {
    /// The Messages endpoint requests are sent to.
    let messages: URL

    static let anthropic = URL(string: "https://api.anthropic.com/v1/messages")!
    static let settingsKey = "anthropicBaseURL"
    static let environmentVariable = "COUCOU_ANTHROPIC_BASE_URL"
    static let anthropicVersion = "2023-06-01"

    /// Anything but Anthropic's own API. A gateway gets no web search (an Anthropic
    /// server tool) and no beta header, the key also as a bearer token (most gateways
    /// read that one), and the chat model instead of the fixed fast one.
    var isGateway: Bool { messages != Self.anthropic }

    enum Failure: LocalizedError, Equatable {
        case invalid, insecure, credentials

        var errorDescription: String? {
            switch self {
            case .invalid:     return "The Claude base URL is not a valid URL."
            case .insecure:    return "The Claude base URL must use https:// (plain http only to this Mac)."
            case .credentials: return "The Claude base URL must not carry a user name or password."
            }
        }
    }

    /// Settings first, then the environment, then Anthropic. A URL that breaks the
    /// rules throws rather than falling back: the key was meant for that gateway,
    /// and is not sent anywhere else.
    static func current(defaults: UserDefaults = .standard,
                        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ClaudeEndpoint {
        let saved = (defaults.string(forKey: settingsKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = saved.isEmpty
            ? (environment[environmentVariable] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : saved
        guard !raw.isEmpty else { return ClaudeEndpoint(messages: anthropic) }
        return ClaudeEndpoint(messages: try messagesURL(from: raw))
    }

    /// The Messages endpoint for a base URL as typed: `https://host/anthropic`,
    /// `…/v1` and `…/v1/messages` all give `…/v1/messages`.
    static func messagesURL(from raw: String) throws -> URL {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host, !host.isEmpty else { throw Failure.invalid }
        switch scheme {
        case "https": break
        case "http" where isLoopback(host): break
        case "http": throw Failure.insecure
        default: throw Failure.invalid
        }
        guard parts.user == nil, parts.password == nil else { throw Failure.credentials }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/v1/messages") {
            path += path.hasSuffix("/v1") ? "/messages" : "/v1/messages"
        }
        parts.path = path
        parts.fragment = nil
        guard let url = parts.url else { throw Failure.invalid }
        return url
    }

    /// This Mac: localhost, *.localhost, 127.0.0.0/8, ::1 (and its IPv4-mapped form), 0.0.0.0.
    static func isLoopback(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h == "::1" || h == "::" || h == "0:0:0:0:0:0:0:1" { return true }
        if h.hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
        let octets = h.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return false }
        return octets[0] == "127" || h == "0.0.0.0"
    }

    /// The model list next to the Messages endpoint.
    var models: URL {
        var parts = URLComponents(url: messages, resolvingAgainstBaseURL: false)!
        if parts.path.hasSuffix("/messages") { parts.path.removeLast("/messages".count) }
        parts.path += "/models"
        parts.query = "limit=100"
        return parts.url!
    }

    /// The fixed fast model on Anthropic; on a gateway, which rarely has it, the chat model.
    func model(fast: String, chat: String) -> String {
        isGateway ? chat : fast
    }

    /// A POST to the Messages endpoint, key and API version set.
    func request(key: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: messages, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        authorize(&request, key: key)
        return request
    }

    func authorize(_ request: inout URLRequest, key: String) {
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        if isGateway { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    }

    /// Gateways never get a redirect followed: the key only reaches the host typed.
    var session: URLSession { isGateway ? Self.gatewaySession : .shared }

    private static let gatewaySession = URLSession(configuration: .ephemeral,
                                                   delegate: RefuseRedirects(), delegateQueue: nil)
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
