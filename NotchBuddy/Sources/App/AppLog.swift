import Foundation

// MARK: - Shared diagnostic log helpers

/// Escapes ASCII control characters so log lines can't inject terminal sequences.
func escapedForLog(_ s: String) -> String {
    s.unicodeScalars.map { sc -> String in
        let v = sc.value
        return (v < 0x20 || v == 0x7F) ? "\\u\(String(format: "%04X", v))" : String(sc)
    }.joined()
}

/// Appends one timestamped line to `~/Library/Logs/NotchBuddy/<fileName>`.
/// - Log directory is created at mode 0700.
/// - Log file is set to mode 0600 on first creation and after each rotation.
/// - File is rotated (truncated) when it reaches 1 MB.
/// The time is taken now; the write happens on a background serial queue, in order, so a
/// log line never blocks the main thread (it used to cost ~8 file operations per line).
func appendAppLog(_ fileName: String, _ message: String,
                  timestampFormat: String = "yyyy-MM-dd HH:mm:ss") {
    let date = Date()
    AppLogWriter.queue.async {
        AppLogWriter.write(fileName, message, date: date, format: timestampFormat)
    }
}

private enum AppLogWriter {
    static let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.applog", qos: .utility)
    static let maxLogBytes = 1_048_576 // 1 MB

    // Touched only on `queue`.
    nonisolated(unsafe) static var dirReady = false
    nonisolated(unsafe) static var sizes: [String: Int] = [:]
    nonisolated(unsafe) static var formatters: [String: DateFormatter] = [:]

    static let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NotchBuddy")

    static func write(_ fileName: String, _ message: String, date: Date, format: String) {
        let fm = FileManager.default
        if !dirReady {
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: logsDir.path)
            dirReady = true
        }
        let logFile = logsDir.appendingPathComponent(fileName)
        let f: DateFormatter
        if let cached = formatters[format] { f = cached } else {
            f = DateFormatter(); f.dateFormat = format; formatters[format] = f
        }
        let line = "\(f.string(from: date)) \(escapedForLog(message))\n"
        guard let data = line.data(using: .utf8) else { return }

        // Size known from our own writes; read from disk once per file (or if it vanished).
        var size = sizes[fileName]
        if size == nil || !fm.fileExists(atPath: logFile.path) {
            size = fm.fileExists(atPath: logFile.path)
                ? ((try? fm.attributesOfItem(atPath: logFile.path)[.size] as? Int) ?? 0) : nil
        }
        guard let current = size else {
            // New file
            try? data.write(to: logFile, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600 as NSNumber], ofItemAtPath: logFile.path)
            sizes[fileName] = data.count
            return
        }
        if current >= maxLogBytes {
            // Rotate when the file reaches the limit
            try? fm.removeItem(at: logFile)
            try? data.write(to: logFile, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600 as NSNumber], ofItemAtPath: logFile.path)
            sizes[fileName] = data.count
            return
        }
        if sizes[fileName] == nil {
            // First write to an existing file this run: make sure of its permissions.
            try? fm.setAttributes([.posixPermissions: 0o600 as NSNumber], ofItemAtPath: logFile.path)
        }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
        sizes[fileName] = current + data.count
    }
}
