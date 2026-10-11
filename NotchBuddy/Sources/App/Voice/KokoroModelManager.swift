#if !APPSTORE
import Foundation

// MARK: - KokoroModelManager
//
// Manages the two on-disk Kokoro-82M MLX model files:
//   • kokoro-v1_0.safetensors (~312 MB) — weights (HuggingFace prince-canuma/Kokoro-82M)
//   • voices.npz (~14 MB)               — voice embeddings (GitHub mlalma/KokoroTestApp)
// Both stored in ~/Library/Application Support/Coucou/kokoro/.
// The download is triggered only by the user pressing the button in Settings → Voice.
// Progress is weighted: voices 5 %, model 95 %.

@MainActor
final class KokoroModelManager: ObservableObject {
    static let shared = KokoroModelManager()

    @Published var isDownloaded:     Bool   = false
    @Published var isDownloading:    Bool   = false
    @Published var downloadProgress: Double = 0   // 0..1
    @Published var downloadError:    String?

    private static let modelFile  = "kokoro-v1_0.safetensors"
    private static let voicesFile = "voices.npz"

    var modelDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coucou/kokoro", isDirectory: true)
    }
    var modelURL:  URL { modelDir.appendingPathComponent(Self.modelFile)  }
    var voicesURL: URL { modelDir.appendingPathComponent(Self.voicesFile) }

    private static let modelDownloadURL = URL(
        string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors")!
    private static let voicesDownloadURL = URL(
        string: "https://github.com/mlalma/KokoroTestApp/raw/refs/heads/main/Resources/voices.npz")!

    private var activeTask: Task<Void, Never>?

    private init() { checkInstalled() }

    func checkInstalled() {
        let fm = FileManager.default
        isDownloaded = fm.fileExists(atPath: modelURL.path)
                    && fm.fileExists(atPath: voicesURL.path)
    }

    func startDownload() {
        guard !isDownloading, !isDownloaded else { return }
        isDownloading    = true
        downloadProgress = 0
        downloadError    = nil
        activeTask = Task { await _runDownload() }
    }

    private func _runDownload() async {
        do {
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            // voices.npz first (small, 14 MB → 5% of total weight)
            try await _downloadFile(from: Self.voicesDownloadURL, to: voicesURL,
                                    progressOffset: 0.00, progressWeight: 0.05)
            // Model weights (312 MB → 95% of total weight)
            try await _downloadFile(from: Self.modelDownloadURL, to: modelURL,
                                    progressOffset: 0.05, progressWeight: 0.95)
            isDownloading = false
            isDownloaded  = true
            appendAppLog("nb.log", "[Kokoro] downloaded successfully")
        } catch is CancellationError {
            isDownloading = false
        } catch {
            isDownloading = false
            downloadError = error.localizedDescription
            try? FileManager.default.removeItem(at: voicesURL)
            try? FileManager.default.removeItem(at: modelURL)
            appendAppLog("nb.log", "[Kokoro] download failed: \(error)")
        }
    }

    func cancelDownload() {
        activeTask?.cancel()
        activeTask       = nil
        isDownloading    = false
        downloadProgress = 0
        try? FileManager.default.removeItem(at: voicesURL)
        try? FileManager.default.removeItem(at: modelURL)
    }

    func deleteModel() {
        cancelDownload()
        try? FileManager.default.removeItem(at: modelDir)
        isDownloaded = false
        KokoroSpeaker.shared.unload()
    }

    // MARK: - Download helper

    private func _downloadFile(from url: URL, to dest: URL,
                                progressOffset: Double, progressWeight: Double) async throws {
        let box = _ProgressBox { [weak self] p in
            guard let self else { return }
            self.downloadProgress = progressOffset + progressWeight * p
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = _DownloadDelegate(continuation: cont, destination: dest, progressBox: box)
            let session  = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            var req = URLRequest(url: url, timeoutInterval: 600)
            req.setValue("Coucou/1.0", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: req).resume()
        }
    }
}

// MARK: - Progress bridge  (URLSession delegate thread → @MainActor)

/// Wraps a @MainActor progress callback so URLSessionDownloadDelegate (background thread)
/// can call it. Throttled to 1 % granularity — at most 100 main-actor hops per file.
private final class _ProgressBox: @unchecked Sendable {
    private let handler: @MainActor (Double) -> Void
    private var last: Double = -1

    init(_ handler: @MainActor @escaping (Double) -> Void) { self.handler = handler }

    func report(_ p: Double) {
        let pct = floor(p * 100) / 100
        guard pct != last else { return }
        last = pct
        let h = handler
        Task { @MainActor in h(p) }
    }
}

private final class _DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let continuation: CheckedContinuation<Void, Error>
    let destination:  URL
    let progressBox:  _ProgressBox
    var session:      URLSession?
    private var done = false

    init(continuation: CheckedContinuation<Void, Error>,
         destination: URL, progressBox: _ProgressBox) {
        self.continuation = continuation
        self.destination  = destination
        self.progressBox  = progressBox
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error { finish(.failure(e)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressBox.report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !done else { return }
        done = true
        session?.finishTasksAndInvalidate()
        session = nil
        switch result {
        case .success:        continuation.resume()
        case .failure(let e): continuation.resume(throwing: e)
        }
    }
}
#endif
