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
func appendAppLog(_ fileName: String, _ message: String,
                  timestampFormat: String = "yyyy-MM-dd HH:mm:ss") {
    let fm = FileManager.default
    let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NotchBuddy")
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: logsDir.path)
    let logFile = logsDir.appendingPathComponent(fileName)
    let f = DateFormatter(); f.dateFormat = timestampFormat
    let line = "\(f.string(from: Date())) \(escapedForLog(message))\n"
    guard let data = line.data(using: .utf8) else { return }
    let maxLogBytes = 1_048_576 // 1 MB
    if fm.fileExists(atPath: logFile.path) {
        // Rotate when the file reaches the limit
        let size = (try? fm.attributesOfItem(atPath: logFile.path)[.size] as? Int) ?? 0
        if size >= maxLogBytes {
            try? fm.removeItem(at: logFile)
            try? data.write(to: logFile, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600 as NSNumber], ofItemAtPath: logFile.path)
            return
        }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
        // Ensure permissions even on existing files (idempotent)
        try? fm.setAttributes([.posixPermissions: 0o600 as NSNumber], ofItemAtPath: logFile.path)
    } else {
        try? data.write(to: logFile, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600 as NSNumber], ofItemAtPath: logFile.path)
    }
}
