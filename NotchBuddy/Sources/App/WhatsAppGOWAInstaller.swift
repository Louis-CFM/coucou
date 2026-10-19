#if !APPSTORE
import Foundation
import CryptoKit

// "Install WhatsApp": one click instead of GitHub, a zip, xattr, chmod and a Terminal command.
// Downloads GOWA's own latest macOS build for this Mac from its GitHub releases, checks its
// SHA-256 against the checksums GOWA publishes, puts the binary in Coucou's GOWA folder (next
// to the WhatsApp session it keeps) and turns on "Start GOWA automatically". GitHub build only.
// The only network call is to GitHub, once, after the click; no message ever goes there.

@MainActor
final class WhatsAppGOWAInstaller: ObservableObject {
    static let shared = WhatsAppGOWAInstaller()

    enum Step: Equatable {
        case idle
        case checking
        case downloading(megabytes: Int)
        case verifying
        case installing
        case done(version: String)
        case failed(String)
    }

    @Published private(set) var step: Step = .idle

    var busy: Bool {
        switch step {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    /// GOWA's version once installed by Coucou (not a secret: UserDefaults).
    static var installedVersion: String? {
        get { UserDefaults.standard.string(forKey: "whatsappGOWAVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "whatsappGOWAVersion") }
    }

    /// Where Coucou keeps the binary it installed.
    static var binaryURL: URL { WhatsAppGOWAProcess.workingDirectory.appendingPathComponent("gowa") }

    /// A gateway Coucou can start: the one it installed, or one the user picked.
    static var isInstalled: Bool {
        let path = (WhatsAppGOWAProcess.binaryPath as NSString).expandingTildeInPath
        return !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)
    }

    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: GitHubOnly(), delegateQueue: nil)
    }()

    func install() {
        guard !busy else { return }
        step = .checking
        Task { await run() }
    }

    private func run() async {
        do {
            // 1. Which build: GOWA's latest release, the zip for this Mac.
            var req = URLRequest(url: WAGOWARelease.latestURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (meta, metaResponse) = try await session.data(for: req)
            guard (metaResponse as? HTTPURLResponse)?.statusCode == 200,
                  let release = WAGOWARelease.parse(meta),
                  let picked = WAGOWARelease.pick(release.assets, arch: Self.arch) else {
                throw Failure(String(localized: "whatsapp.install.no-build"))
            }
            var checksums: String? = nil
            if let sums = picked.checksums {
                let (data, _) = try await session.data(from: sums.url)
                checksums = String(data: data, encoding: .utf8)
            }
            guard let expected = WAGOWARelease.expectedSHA256(for: picked.zip, checksums: checksums) else {
                throw Failure(String(localized: "whatsapp.install.no-checksum"))
            }

            // 2. Download.
            step = .downloading(megabytes: max(1, picked.zip.size / 1_000_000))
            let (tmp, zipResponse) = try await session.download(from: picked.zip.url)
            guard (zipResponse as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(String(localized: "whatsapp.install.download-failed")) }

            // 3. Verify: exactly the file GOWA published.
            step = .verifying
            let digest = try await Task.detached { () throws -> String in
                let data = try Data(contentsOf: tmp)
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }.value
            guard digest == expected else {
                try? FileManager.default.removeItem(at: tmp)
                throw Failure(String(localized: "whatsapp.install.bad-checksum"))
            }

            // 4. Unzip with macOS's own ditto, put the binary in place, make it runnable.
            step = .installing
            let version = release.version
            let binary = WAGOWARelease.binaryName(arch: Self.arch)
            try await Task.detached {
                try Self.unpack(zip: tmp, binaryName: binary)
            }.value
            Self.installedVersion = version
            WhatsAppSettings.gateway = .gowa
            KeychainStore.shared.remove(WhatsAppSettings.urlKey)   // back to http://127.0.0.1:3000
            WhatsAppGOWAProcess.binaryPath = Self.binaryURL.path
            WhatsAppGOWAProcess.autoStart = true
            WhatsAppGOWAProcess.shared.stopNow()                     // an older one gives way
            WhatsAppController.shared.settingsChanged()              // starts it; the QR follows
            step = .done(version: version)
            appendAppLog("nb.log", "[WhatsApp] GOWA \(version) installed (\(Self.arch))")
        } catch let failure as Failure {
            step = .failed(failure.message)
            appendAppLog("nb.log", "[WhatsApp] GOWA install failed: \(failure.message)")
        } catch {
            step = .failed(String(localized: "whatsapp.install.download-failed"))
            appendAppLog("nb.log", "[WhatsApp] GOWA install failed: \(error.localizedDescription)")
        }
    }

    private struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    /// Unzips into a temporary folder, then moves `binaryName` to the GOWA folder as `gowa`.
    nonisolated private static func unpack(zip: URL, binaryName: String) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("coucou-gowa-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work); try? fm.removeItem(at: zip) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, work.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Failure(String(localized: "whatsapp.install.unzip-failed")) }

        guard let found = fm.enumerator(at: work, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == binaryName }) else {
            throw Failure(String(localized: "whatsapp.install.no-build"))
        }
        try fm.createDirectory(at: WhatsAppGOWAProcess.workingDirectory, withIntermediateDirectories: true)
        let dest = WhatsAppGOWAProcess.workingDirectory.appendingPathComponent("gowa")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: found, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        // Downloaded by Coucou itself, it carries no quarantine; cleared anyway so macOS never
        // asks the user to allow it in System Settings.
        removexattr(dest.path, "com.apple.quarantine", 0)
    }
}

/// The download follows GitHub's redirect to its asset storage, and nothing else.
private final class GitHubOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(WAGOWARelease.allowedHost(request.url?.host) ? request : nil)
    }
}
#endif
