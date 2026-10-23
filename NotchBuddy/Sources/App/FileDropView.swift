import AppKit
import SwiftUI

// MARK: - NSView drag destination
// Wired at the AppKit level in IslandWindowController (not via SwiftUI NSViewRepresentable)
// so it never interferes with SwiftUI hit-testing.

final class FileDropNSView: NSView {
    var onDragEntered: ((CGPoint) -> Void)?
    var onDragUpdated: ((CGPoint) -> Void)?
    var onDragExited:  (() -> Void)?
    var onFilesDropped: (([URL], CGPoint) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    // Pass all mouse events through — drag-drop uses NSDraggingDestination, not hitTest
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?(sender.draggingLocation)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragUpdated?(sender.draggingLocation)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExited?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }
        onFilesDropped?(urls, sender.draggingLocation)
        return true
    }
}

enum FileDropDestination: Equatable {
    case stash
    case ask
    case airDrop

    static func at(x: CGFloat, hasAirDrop: Bool = true) -> FileDropDestination {
        let fraction = min(1, max(0, (x - CGFloat(USC.CARD_X)) / CGFloat(USC.CARD_W)))
        if hasAirDrop {
            if fraction < 1.0 / 3.0 { return .ask }
            if fraction < 2.0 / 3.0 { return .stash }
            return .airDrop
        }
        return fraction < 0.5 ? .ask : .stash
    }
}

enum FileStashStore {
    private static let manifestKey = "notchStashedFiles"
    private static var directory: URL {
        HookServer.supportDir.appendingPathComponent("notch-files", isDirectory: true)
    }

    static func list() -> [StashedFile] {
        guard let data = UserDefaults.standard.data(forKey: manifestKey),
              let files = try? JSONDecoder().decode([StashedFile].self, from: data) else { return [] }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { file in
                let fileURL = file.url.standardizedFileURL
                let root = directory.standardizedFileURL
                var isDirectory: ObjCBool = false
                let isStoredAppBundle = fileURL.pathExtension.lowercased() == "app"
                    && fileURL.path.hasPrefix(root.path + "/")
                    && fileURL.deletingLastPathComponent().deletingLastPathComponent().path == root.path
                    && FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
                if isStoredAppBundle {
                    // Repair bundle roots made non-traversable by older versions.
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.path)
                }
                return file
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    static func add(urls: [URL]) throws -> [StashedFile] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var added: [StashedFile] = []
        do {
            for source in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    let values = try source.resourceValues(forKeys: [.isPackageKey])
                    let isAppBundle = source.pathExtension.lowercased() == "app"
                    guard values.isPackage == true || isAppBundle else {
                        throw NSError(domain: "CoucouFileStash", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: String(localized: "Folders can't be dropped yet.")])
                    }
                }
                let accessing = source.startAccessingSecurityScopedResource()
                defer { if accessing { source.stopAccessingSecurityScopedResource() } }
                let name = source.lastPathComponent.isEmpty ? "file" : source.lastPathComponent
                let id = UUID().uuidString
                let destination = directory.appendingPathComponent(id, isDirectory: true)
                    .appendingPathComponent(name)
                let entryDirectory = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entryDirectory.path)
                try FileManager.default.copyItem(at: source, to: destination)
                // A .app is a directory bundle. Forcing 0600 on its root removes
                // execute/traverse permission and breaks the app's own executable bit.
                if !isDirectory.boolValue {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                }
                added.append(StashedFile(id: id, name: name, path: destination.path, addedAt: Date()))
            }
            let all = list() + added
            let data = try JSONEncoder().encode(all)
            UserDefaults.standard.set(data, forKey: manifestKey)
            return added
        } catch {
            for file in added { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
            throw error
        }
    }

    static func remove(_ file: StashedFile) throws {
        let fileURL = file.url.standardizedFileURL
        let root = directory.standardizedFileURL
        guard fileURL.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
        let entryDirectory = fileURL.deletingLastPathComponent().standardizedFileURL
        guard entryDirectory.deletingLastPathComponent().path == root.path else { throw CocoaError(.fileWriteNoPermission) }
        if FileManager.default.fileExists(atPath: entryDirectory.path) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                // Earlier versions chmod'ed the bundle root to 0600. Restore
                // write/traverse access on its directories before removing it.
                repairBundleDirectories(at: fileURL)
            }
            try FileManager.default.removeItem(at: entryDirectory)
        }
        let remaining = list().filter { $0.id != file.id }
        UserDefaults.standard.set(try JSONEncoder().encode(remaining), forKey: manifestKey)
    }

    private static func repairBundleDirectories(at bundle: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundle.path)
        guard let entries = FileManager.default.enumerator(
            at: bundle,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else { return }
        for case let url as URL in entries {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
}

// MARK: - File drop handler

enum FileDropHandler {
    @MainActor
    static func handle(urls: [URL], state: AppState) async {
        guard let url = urls.first else { return }
        let name = url.lastPathComponent

        // Start animation immediately — do NOT block on file copy.
        // Use original URL first; swap to inbox copy once background copy finishes.
        state.droppedFile = DroppedFile(url: url, name: name)
        state.uploadProgress = 0
        state.fileDragOver = false
        state.promptContext = .file(name: name, fileURL: url)

        let dur = 2.4
        UploadSequenceEngine.shared.performDrop(uploadDuration: dur)

        // Copy to inbox in background — update state when done
        let inbox = HookServer.supportDir.appendingPathComponent("inbox")
        Task.detached {
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let dest = inbox.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                await MainActor.run {
                    state.droppedFile = DroppedFile(url: dest, name: name)
                    state.promptContext = .file(name: name, fileURL: dest)
                }
            }
        }

        // Drop feedback
        NotificationCenter.default.post(name: .botGulp, object: nil)
        SoundEngine.shared.play("approve")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        NotificationCenter.default.post(name: .botMorphTo, object: CGFloat(0))

        state.uploadDuration = dur
        state.uploadStartTime = Date()
        state.view = .uploading  // canvas stays active: uploadActive covers .uploading

        // Canvas timeline from drop:
        //   T_DROP → T_PROG_START : ≈1.30s  gulp + shrink + bar reveal
        //   T_PROG_START → progEnd: dur      progress bar fills
        //   progEnd → growEnd     : 0.70s    Mochi grows back to choose position
        let preProgress = USC.T_PROG_START - USC.T_DROP  // ≈1.30s

        // Tick sounds — delayed to sync with canvas progress start
        Task { @MainActor in
            var lastTens = 0
            let progStart = Date().addingTimeInterval(preProgress)
            while lastTens < 9 {
                try? await Task.sleep(nanoseconds: 80_000_000)
                let approxP = min(1.0, max(0, Date().timeIntervalSince(progStart) / dur))
                let tens = Int(approxP * 10)
                if tens > lastTens {
                    SoundEngine.shared.play("tick")
                    lastTens = tens
                }
            }
        }

        // Wait for canvas progress to complete (gulp/shrink phase + upload duration)
        try? await Task.sleep(nanoseconds: UInt64((preProgress + dur) * 1_000_000_000))

        // Canvas shows checkmark at this point
        SoundEngine.shared.play("approve")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)

        // Wait for grow-back animation + choose overlay settle
        try? await Task.sleep(nanoseconds: UInt64(1_000_000_000))

        // Clean up upload state
        state.uploadProgress = 0
        state.uploadStartTime = nil

        // Switch to choose — canvas stays active (uploadActive covers .choose).
        // Engine deactivates when user clicks a canvas choose button or navigates away.
        state.view = .choose
    }
}
