import Foundation

// The one network call of the media rows: `GET <agent base>/api/files/download?path=<path>` on a sign in agent, with the
// bearer the app already holds for that agent. Nothing else is ever requested for a directive.
//
// - Redirects are not followed: the bearer never leaves the agent host.
// - The size is capped while the bytes arrive, whatever the headers said.
// - The type is decided from the first bytes (`ChatMediaSniff`), never from the name or the header.
// - The token goes in the `Authorization` header only: never in a query, never in a log.
// - Nothing is logged: no path, no name, no byte, no status.
// Foundation only, in both builds, no flag.

enum ChatMediaFetch {
    /// What the app fetches by itself, when the row is on screen: images up to 5 MB, voice and audio up to 10 MB.
    static let autoImageCap = 5 << 20
    static let autoAudioCap = 10 << 20
    /// What a click may fetch. Above it: "too large", no request.
    static let manualCap = 50 << 20

    enum Failure: Error, Equatable, Sendable {
        case network
        case notFound
        case refused
        /// Larger than the cap of this request; the size is known when the server declared it.
        case tooLarge(Int?)
        case signIn
        case notAvailable
        case unreadable
        /// The file arrived and checks out as audio, but the sound would not start (no output, the engine refused).
        case cannotPlay
    }

    struct Downloaded: Equatable, Sendable {
        let url: URL
        let format: ChatMediaSniff.Format
        let bytes: Int
    }

    /// The cap of an automatic fetch for a kind, nil when the kind is never fetched by itself.
    static func autoCap(for kind: ChatAttachmentKind) -> Int? {
        switch kind {
        case .image: return autoImageCap
        case .voice, .audio: return autoAudioCap
        case .video, .document: return nil
        }
    }

    /// `path` is the claim of the agent, checked by `ChatMediaDirectives`; it travels as one percent encoded query value.
    static func requestURL(agent: HermesAgent, path: String) -> URL? {
        guard let base = HermesSignIn.endpoint(agent.baseURL, "/api/files/download"),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let value = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        parts.percentEncodedQuery = "path=" + value
        return parts.url
    }

    static func download(agent: HermesAgent, path: String, cap: Int, sessions: HermesSessions, files: ChatMediaFiles,
                         conversation: String, progress: @escaping @Sendable (Int, Int?) -> Void) async -> Result<Downloaded, Failure> {
        guard agent.connection == .signIn, let url = requestURL(agent: agent, path: path) else { return .failure(.notAvailable) }
        // The conversation may be cleared while the bytes arrive: the write below then finds another epoch and writes nothing.
        let epoch = files.epoch(of: conversation)
        var token: String
        do { token = try await sessions.validToken(for: agent) } catch { return .failure(failure(of: error)) }
        for attempt in 0..<2 {
            let answer = await get(url, bearer: token, cap: cap, progress: progress)
            if Task.isCancelled { return .failure(.network) }
            switch answer {
            case .failed(let f): return .failure(f)
            case .answered(let status, let data):
                switch status {
                case 200:
                    return store(data, files: files, conversation: conversation, epoch: epoch)
                case 401:
                    // One refresh for a token the server refused, as the ticket does; a second refusal ends here.
                    guard attempt == 0 else { return .failure(.signIn) }
                    do { token = try await sessions.validToken(for: agent, forceRefresh: true) } catch { return .failure(failure(of: error)) }
                case 403, 415: return .failure(.refused)
                case 404: return .failure(.notFound)
                case 413: return .failure(.tooLarge(nil))
                default: return .failure(.network)
                }
            }
        }
        return .failure(.signIn)
    }

    private static func failure(of error: Error) -> Failure {
        if let e = error as? HermesChatError, case .signInNeeded = e { return .signIn }
        return .network
    }

    private static func store(_ data: Data, files: ChatMediaFiles, conversation: String, epoch: ChatMediaFiles.Epoch) -> Result<Downloaded, Failure> {
        guard !data.isEmpty, !Task.isCancelled else { return .failure(.unreadable) }
        let format = ChatMediaSniff.format(of: [UInt8](data.prefix(ChatMediaSniff.headBytes)))
        guard let url = files.write(data, conversation: conversation, extensionName: format.fileExtension, epoch: epoch) else { return .failure(.unreadable) }
        // Cancelled after the write (the chat folded): the file goes with the request.
        if Task.isCancelled { files.remove(url); return .failure(.network) }
        return .success(Downloaded(url: url, format: format, bytes: data.count))
    }

    // MARK: One request

    private enum Answer: Sendable {
        case answered(Int, Data)
        case failed(Failure)
    }

    private static func get(_ url: URL, bearer: String, cap: Int,
                            progress: @escaping @Sendable (Int, Int?) -> Void) async -> Answer {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        // The cap counts the bytes of the file, not of a compressed copy of it.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let collector = Collector(cap: cap, progress: progress)
        let session = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
                collector.start(task, continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let cap: Int
        private let progress: @Sendable (Int, Int?) -> Void
        private let lock = NSLock()
        private var data = Data()
        private var status = 0
        private var declared: Int?
        private var tooLarge = false
        private var overflow = false
        /// Every byte that reached the app, even the ones dropped when the cap was passed.
        private var received = 0
        private var lastTick = Date.distantPast
        private var continuation: CheckedContinuation<Answer, Never>?

        init(cap: Int, progress: @escaping @Sendable (Int, Int?) -> Void) {
            self.cap = cap
            self.progress = progress
        }

        func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Answer, Never>) {
            lock.lock(); self.continuation = continuation; lock.unlock()
            task.resume()
        }

        // Not followed: the answer of the redirect itself is what the caller sees (a status that is not 200).
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let length = response.expectedContentLength
            declared = length >= 0 ? Int(clamping: length) : nil
            let over = status == 200 && (declared ?? 0) > cap
            if over { tooLarge = true }
            lock.unlock()
            // A declared size over the cap ends the request at once; so does any answer that is not a file.
            completionHandler(over || status != 200 ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            lock.lock()
            guard status == 200, !overflow else { lock.unlock(); return }
            data.append(chunk)
            let count = data.count
            received = count
            let total = declared
            let over = count > cap
            if over { overflow = true; data = Data() }
            let tick = Date().timeIntervalSince(lastTick) >= 0.08
            if tick { lastTick = Date() }
            lock.unlock()
            if over { dataTask.cancel(); return }
            if tick { progress(count, total) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let answer: Answer
            if tooLarge { answer = .failed(.tooLarge(declared)) }
            else if overflow { answer = .failed(.tooLarge(nil)) }
            else if status != 200 && status != 0 { answer = .answered(status, Data()) }
            else if error != nil || status == 0 { answer = .failed(.network) }
            else {
                // Fewer bytes than declared: the connection broke, the file is not whole.
                if let declared, data.count != declared { answer = .failed(.network) } else { answer = .answered(status, data) }
            }
            let c = continuation
            continuation = nil
            let total = received, expected = declared
            lock.unlock()
            // The last count, whatever the outcome (done, cut for size, failed, cancelled): the budget of the store
            // counts the bytes that came. Not throttled.
            if total > 0 { progress(total, expected) }
            c?.resume(returning: answer)
        }
    }
}
