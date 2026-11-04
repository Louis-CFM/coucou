#if !APPSTORE
import SwiftUI

/// The island after ⌘⇧S: Mochi on the left (he just swallowed the capture), the image, and what
/// to do with it. With Flow on, holding its key sends the image and your words together.
struct CaptureCardView: View {
    @ObservedObject private var capture = ScreenCapture.shared
    @ObservedObject private var flow = FlowDictation.shared

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            HStack(alignment: .center, spacing: 14) {
                thumbnail
                VStack(alignment: .leading, spacing: 7) {
                    Text("capture.ready")
                        .font(.system(size: 14, weight: .semibold))
                    Text(verbatim: hint)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#9398A1"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 7) {
                        PrimaryButton(verbatim: String(localized: "capture.paste")) { capture.pasteIntoPrompt() }
                        SecondaryButton(verbatim: String(localized: "capture.copy")) { capture.copy() }
                        SecondaryButton(verbatim: String(localized: "capture.annotate")) { capture.annotate() }
                        SecondaryButton(verbatim: String(localized: "capture.ask")) { capture.askClaude() }
                    }
                }
            }
            .padding(.leading, 98)
            .padding(.trailing, 16)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = capture.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 104, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
    }

    /// "Hold fn and talk: the image and your words go in together." when Flow is on.
    private var hint: String {
        flow.isEnabled
            ? String(format: String(localized: "capture.flow-hint %@"), flow.key.label)
            : String(localized: "capture.hint")
    }
}
#endif
