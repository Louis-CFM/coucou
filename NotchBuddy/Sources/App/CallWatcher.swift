import AppKit

/// Keeps `AppState.callSensors` current from Control Center's sensor-indicators log,
/// the source of the menu bar dots. `log stream` sleeps between changes. Not sandboxed.
@MainActor
final class CallWatcher {
    static let shared = CallWatcher()
    private static let predicate = "subsystem == \"com.apple.controlcenter\" AND category == \"sensor-indicators\""
    private static let own = Bundle.main.bundleIdentifier ?? ""

    private var process: Process?
    private var buffer = Data()
    private var streamed = false

    private init() {}

    func start() {
        guard process == nil else { return }
        seed()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate", Self.predicate]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor in self?.consume(data) }
        }
        do { try p.run() } catch { return }
        process = p
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            p.terminate()
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let held = CallSensors.parse(line, own: Self.own) {
                streamed = true
                AppState.shared.callSensors = held
            }
        }
    }

    /// A call already running at launch, unless the stream already said.
    private func seed() {
        let own = Self.own, predicate = Self.predicate
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show", "--last", "1h", "--style", "compact", "--predicate", predicate]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard let last = text.split(separator: "\n").last(where: { $0.contains(CallSensors.marker) }),
                  let held = CallSensors.parse(String(last), own: own) else { return }
            await MainActor.run {
                guard !CallWatcher.shared.streamed else { return }
                AppState.shared.callSensors = held
            }
        }
    }
}
