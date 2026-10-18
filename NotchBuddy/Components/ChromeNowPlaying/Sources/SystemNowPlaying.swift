import AppKit
import Combine
import Darwin
import Foundation
import ImageIO

/// Own optional system now-playing backend. No AppState, Spotify or Music dependency.
@MainActor
final class SystemNowPlaying: ObservableObject {
    @Published private(set) var snapshot: PlaybackSnapshot?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var connected = false
    @Published private(set) var running = false
    @Published private(set) var status = "Desconectado. Pulsa Conectar para escuchar Ahora suena."
    @Published private(set) var controlsBusy = false
    @Published private(set) var commandNotice: String?
    private struct PendingCommand {
        let id: String
        let name: String
        let baseline: PlaybackSnapshot
        var isNavigation: Bool { name == "next" || name == "previous" }
    }
    private var pendingCommand: PendingCommand?
    private var commandDeadline: Task<Void, Never>?
    private var noticeDeadline: Task<Void, Never>?
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var artworkRevision: UInt64?

    var isPlaying: Bool { snapshot?.playing == true }
    var duration: Double { snapshot?.duration ?? 0 }
    func position(at date: Date) -> Double {
        guard let snapshot else { return 0 }
        let elapsed = isPlaying ? max(0, date.timeIntervalSince1970 - snapshot.timestamp) * snapshot.rate : 0
        let result = max(0, snapshot.position + elapsed)
        return duration > 0 ? min(duration, result) : result
    }

    private static var libraryURL: URL? {
        if let directory = Bundle.main.privateFrameworksURL {
            let candidate = directory.appendingPathComponent("NowPlayingBridge.dylib")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return Bundle.main.url(forResource: "NowPlayingBridge", withExtension: "dylib")
    }

    func start() {
        guard process == nil else { return }
        guard let launcher = Bundle.main.url(forResource: "bridge", withExtension: "pl"),
            let library = Self.libraryURL
        else {
            status = "No se encontró el componente de Ahora suena."
            return
        }
        let token = UUID()
        generation = token
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [launcher.path, library.path]
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        // At most 8 MiB queued, sufficient for the largest permitted artwork event.
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(256))
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // A single POSIX read returns currently available bytes; Foundation's
            // read(upToCount:) can wait to fill the requested count on a pipe.
            var bytes = [UInt8](repeating: 0, count: 32 * 1024)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { return }
                handle.readabilityHandler = nil
                continuation.finish()
                Task { @MainActor [weak self] in
                    guard self?.generation == token else { return }
                    self?.stop(message: "Se interrumpió la lectura del receptor.")
                }
                return
            }
            if count == 0 {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            let data = Data(bytes.prefix(count))
            if case .dropped = continuation.yield(data) {
                continuation.finish()
                handle.readabilityHandler = nil
                // Reject overflow; never silently lose state changes.
                Task { @MainActor [weak self] in
                    guard self?.generation == token else { return }
                    self?.stop(message: "Demasiadas actualizaciones. Se cerró el receptor.")
                }
            }
        }
        continuation.onTermination = { _ in stdout.fileHandleForReading.readabilityHandler = nil }
        child.terminationHandler = { [weak self] child in
            continuation.finish()
            let code = child.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.stop(
                    message: code == 0
                        ? "Receptor cerrado." : "No se pudo mantener el receptor de esta versión de macOS.")
            }
        }
        process = child
        input = stdin.fileHandleForWriting
        running = true
        reader = Task { [weak self] in
            let parser = BridgeParser()
            do {
                for await data in stream {
                    guard !Task.isCancelled, let self, self.generation == token else { return }
                    for event in try await parser.append(data) {
                        guard self.generation == token else { return }
                        self.receive(event)
                    }
                }
                try await parser.finish()
            } catch {
                guard let self, self.generation == token else { return }
                self.stop(message: "Respuesta no válida. Receptor detenido.")
            }
        }
        status = "Conectando…"
        do { try child.run() } catch {
            stop(message: "No se pudo iniciar el auxiliar local.")
            return
        }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.generation == token,
                self.snapshot == nil, !self.connected
            else { return }
            self.stop(message: "macOS no respondió. No se harán reintentos automáticos.")
        }
    }

    func stop(message: String = "Desconectado.") {
        generation = UUID()
        commandDeadline?.cancel()
        commandDeadline = nil
        noticeDeadline?.cancel()
        noticeDeadline = nil
        pendingCommand = nil
        controlsBusy = false
        commandNotice = nil
        reader?.cancel()
        reader = nil
        watchdog?.cancel()
        watchdog = nil
        try? input?.close()
        input = nil
        // EOF is the normal shutdown path; terminate also handles hung private calls.
        if let process, process.isRunning { process.terminate() }
        process = nil
        snapshot = nil
        artwork = nil
        artworkRevision = nil
        connected = false
        running = false
        status = message
    }

    private func receive(_ event: BridgeEvent) {
        switch event.type {
        case "ready": status = "Esperando respuesta del sistema…"
        case "snapshot":
            connected = true
            watchdog?.cancel()
            guard event.active == true else {
                finishCommand(notice: pendingCommand == nil ? nil : "El reproductor activo cambió.")
                snapshot = nil
                artwork = nil
                artworkRevision = nil
                status = "Conectado. Sin reproducción compatible. Spotify y Apple Music tienen sus propias tarjetas."
                return
            }
            if event.artworkRevision != artworkRevision {
                artwork = Self.thumbnail(event.artwork)
                artworkRevision = event.artworkRevision
            }
            snapshot = PlaybackSnapshot(event)
            if let pending = pendingCommand, pending.isNavigation, let snapshot,
                snapshot.confirmsNavigation(from: pending.baseline, command: pending.name)
            {
                finishCommand(notice: nil)
            }
            status =
                (event.source ?? "Ahora suena") + " · " + (event.playing == true ? "Reproduciendo" : "En pausa")
                + (event.controlsKnown == true ? "" : " · Disponibilidad de controles no confirmada")
        case "command":
            guard let pending = pendingCommand, pending.id == event.requestID else { return }
            if event.accepted != true {
                finishCommand(notice: event.message ?? "El reproductor rechazó la orden.")
            } else if !pending.isNavigation {
                finishCommand(notice: nil)
            }
        // Navigation waits for a changed track/restart, not just a transport receipt.
        case "error": stop(message: event.message ?? "Receptor no disponible.")
        default: break
        }
    }

    private static func thumbnail(_ base64: String?) -> NSImage? {
        guard let base64, let data = Data(base64Encoded: base64), data.count <= 4 * 1024 * 1024,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func playPause() { send(isPlaying ? "pause" : "play") }
    func previous() { send("previous") }
    func next() { send("next") }
    func seek(_ seconds: Double) {
        guard duration > 0, seconds.isFinite else { return }
        send("seek", seconds: min(duration, max(0, seconds)))
    }
    private func send(_ command: String, seconds: Double? = nil) {
        guard connected, !controlsBusy, let snapshot, let input else { return }
        if (command == "previous" && !snapshot.canPrevious) || (command == "next" && !snapshot.canNext)
            || (command == "seek" && !snapshot.canSeek)
        {
            return
        }
        let id = UUID().uuidString
        var request: [String: Any] = [
            "command": command, "pid": snapshot.pid, "bundleIdentifier": snapshot.bundleIdentifier, "requestID": id,
        ]
        if let seconds { request["seconds"] = seconds }
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return }
        data.append(10)
        pendingCommand = PendingCommand(id: id, name: command, baseline: snapshot)
        controlsBusy = true
        commandNotice = nil
        noticeDeadline?.cancel()
        commandDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.pendingCommand?.id == id else { return }
            self.finishCommand(
                notice: "El reproductor no ha confirmado el cambio. Puede que este contenido no lo permita.")
        }
        do { try input.write(contentsOf: data) } catch { stop(message: "Se cerró la conexión con el reproductor.") }
    }
    private func finishCommand(notice: String?) {
        commandDeadline?.cancel()
        commandDeadline = nil
        pendingCommand = nil
        controlsBusy = false
        noticeDeadline?.cancel()
        commandNotice = notice
        if notice != nil {
            noticeDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.commandNotice = nil
            }
        }
    }

}
