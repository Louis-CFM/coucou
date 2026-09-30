import AppKit
import SwiftUI

// MARK: - NSView drag destination
// Wired at the AppKit level in IslandWindowController (not via SwiftUI NSViewRepresentable)
// so it never interferes with SwiftUI hit-testing.

final class FileDropNSView: NSView {
    var onDragEntered: ((CGPoint) -> Void)?
    var onDragUpdated: ((CGPoint) -> Void)?
    var onDragExited:  (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?

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
        onFilesDropped?(urls)
        return true
    }
}

// MARK: - Inbox
// Dropped files are copied into Application Support/NotchBuddy/inbox so the original is never
// touched and the copy survives the drag source going away. Copies are kept for a week, then
// swept — same policy as windows/src-tauri/src/files.rs.

enum FileInbox {
    static let keepFor: TimeInterval = 7 * 24 * 60 * 60

    /// Copies `source` into `dir` and returns the copy, or nil if nothing was copied.
    /// Folders are not copied (a recursive copy of a dropped folder could be huge and
    /// would sit on disk for a week); a same-named earlier copy is never overwritten.
    static func ingest(_ source: URL, into dir: URL) -> URL? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let name = source.lastPathComponent
        var dest = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) {
            let stem = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
            for i in 2..<1000 {
                let candidate = dir.appendingPathComponent("\(stem) (\(i))\(ext)")
                if !fm.fileExists(atPath: candidate.path) { dest = candidate; break }
            }
        }
        guard (try? fm.copyItem(at: source, to: dest)) != nil else { return nil }
        // copyItem keeps the source's dates, so a file last edited long ago would arrive
        // already older than the sweep window. The inbox ages from when we copied it.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
        sweep(dir)
        return dest
    }

    /// Removes anything copied here more than `keepFor` ago.
    static func sweep(_ dir: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        for entry in entries {
            guard let copied = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                continue
            }
            if now.timeIntervalSince(copied) > keepFor {
                try? fm.removeItem(at: entry)
            }
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
            if let dest = FileInbox.ingest(url, into: inbox) {
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
