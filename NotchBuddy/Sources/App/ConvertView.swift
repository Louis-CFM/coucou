import SwiftUI
import AppKit

/// The island after "Convert": the formats the dropped file can become, then where the new
/// file was saved. The GitHub build saves next to the original (or in Downloads if that
/// folder can't be written); the App Store build asks for a folder, as its sandbox requires.
struct ConvertView: View {
    @ObservedObject var state: AppState
    @State private var phase: Phase = .picking

    private enum Phase: Equatable {
        case picking
        case converting(String)        // format label
        case done(URL)                 // the new file (or folder of pages)
        case failed(ConvertError)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text(verbatim: title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if phase == .picking {
                        Button("convert.back") { state.view = .choose }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                            .underline()
                    }
                }
                content
            }
            .padding(.leading, 98)
            .padding(.trailing, 18)
        }
        // Every island view stays mounted: start fresh each time this one opens.
        .onChange(of: state.view) { _, view in
            if view == .convert { phase = .picking }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .picking:
            ChipFlowLayout(spacing: 6) {
                ForEach(formats) { format in
                    SecondaryButton(verbatim: format.label) { convert(to: format) }
                }
            }
        case .converting:
            Text("convert.wait")
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#9398A1"))
        case .done(let output):
            Text(String(format: String(localized: "convert.in %@"), folderName(of: output)))
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#9398A1"))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                PrimaryButton("convert.show") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                SecondaryButton("convert.again") { phase = .picking }
                SecondaryButton("convert.done") { NotificationCenter.default.post(name: .islandCollapse, object: nil) }
            }
        case .failed(let error):
            Text(message(for: error))
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#FF8D97"))
            HStack(spacing: 8) {
                SecondaryButton("convert.again") { phase = .picking }
                SecondaryButton("convert.back") { state.view = .choose }
            }
        }
    }

    // MARK: - Text

    private var fileName: String { state.droppedFile?.name ?? "file" }

    private var formats: [ConvertFormat] {
        state.droppedFile.map { FileConverter.formats(for: $0.url) } ?? []
    }

    private var title: String {
        switch phase {
        case .picking:
            return String(format: String(localized: "convert.title %@"), fileName)
        case .converting(let label):
            return String(format: String(localized: "convert.working %@"), label)
        case .done(let output):
            return String(format: String(localized: "convert.saved %@"), output.lastPathComponent)
        case .failed:
            return String(format: String(localized: "convert.failed %@"), fileName)
        }
    }

    private func message(for error: ConvertError) -> LocalizedStringKey {
        switch error {
        case .unsupported: return "convert.error.unsupported"
        case .unreadable:  return "convert.error.unreadable"
        case .locked:      return "convert.error.locked"
        case .writeFailed: return "convert.error.write"
        }
    }

    private func folderName(of output: URL) -> String {
        FileManager.default.displayName(atPath: output.deletingLastPathComponent().path)
    }

    // MARK: - Converting

    private func convert(to format: ConvertFormat) {
        guard let file = state.droppedFile else { return }
        // Read the original: Convert needs no copy. The inbox copy only if the original is gone.
        let input = file.originalURL.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil } ?? file.url
        phase = .converting(format.label)
        Task { @MainActor in
            do {
                guard let folder = chooseFolder(for: file) else {
                    phase = .picking   // the user closed the folder panel
                    return
                }
                let output: URL
                do {
                    output = try await FileConverter.convert(input, to: format, in: folder)
                } catch ConvertError.writeFailed where folder != downloads {
                    // The original's folder can't be written (a read-only disk…): try Downloads.
                    output = try await FileConverter.convert(input, to: format, in: downloads)
                }
                phase = .done(output)
                SoundEngine.shared.play("finish")
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
            } catch {
                phase = .failed(error as? ConvertError ?? .writeFailed)
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)
            }
        }
    }

    private var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Where the new file goes. nil when the user cancels the App Store folder panel.
    private func chooseFolder(for file: DroppedFile) -> URL? {
        let original = file.originalURL?.deletingLastPathComponent()
        #if APPSTORE
        // The sandbox only lets Coucou write where the user points: ask, starting at the original's folder.
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = original ?? downloads
        panel.prompt = String(localized: "convert.save-here")
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return original ?? downloads
        #endif
    }
}
