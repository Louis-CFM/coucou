#if !APPSTORE
import Foundation

enum CodexDesktopPlugin {
    static func export(to parent: URL, bundle: Bundle = .main) throws -> URL {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard let source = bundle.url(forResource: "CodexDesktopPlugin", withExtension: nil),
              fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "CoucouCodexPlugin", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "codex.desktop-plugin.missing", defaultValue: "Desktop plugin resources are missing. Reinstall Coucou and try again.")])
        }
        let destination = parent.appendingPathComponent("Coucou-Codex-Plugin", isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else {
            throw NSError(domain: "CoucouCodexPlugin", code: 2, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "codex.desktop-plugin.exists", defaultValue: "Coucou-Codex-Plugin already exists in that folder. Choose another folder.")])
        }
        try fm.copyItem(at: source, to: destination)
        return destination
    }
}
#endif
