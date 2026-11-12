import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

#if !APPSTORE

// MARK: - Settings → Android phone
//
// One box, styled like the iPhone one (same controls, same spacing). Off by default: turning the
// switch on starts the listener, turning it off stops everything. The pairing code (a QR code and
// the link) is shown only after a click, as on Windows/Linux, because whoever holds it can pair.

enum AndroidLinkQR {
    /// The link as a QR code, black on white with a quiet zone, scaled up without smoothing.
    static func image(for text: String, side: CGFloat = 180) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, floor(side / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let padded = scaled.composited(over: CIImage(color: .white).cropped(to: scaled.extent.insetBy(dx: -12, dy: -12)))
        let rep = NSCIImageRep(ciImage: padded)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct AndroidLinkSettingsBox: View {
    @ObservedObject private var link = AndroidLinkService.shared
    @AppStorage(AndroidLinkService.enabledKey) private var enabled = false
    @AppStorage(AndroidLinkDefaultsFeatures.detailsKey) private var details = false
    @AppStorage(AndroidLinkDefaultsFeatures.answersKey) private var answers = false
    @AppStorage(AndroidLinkDefaultsFeatures.usageKey) private var usage = false
    @State private var showCode = false
    @State private var pairing: String?

    var body: some View {
        GroupBox("Android phone") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(String(localized: "android.link.toggle"), isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        showCode = false
                        pairing = nil
                        link.setEnabled(on)
                    }
                note(String(localized: "android.link.description"))
                if enabled {
                    status
                    if link.running {
                        Button(String(localized: showCode ? "android.link.hide" : "android.link.show")) {
                            showCode.toggle()
                            pairing = showCode ? link.pairingLink() : nil
                        }
                        if showCode { pairingCode }
                    }
                }
                Toggle(String(localized: "android.link.details"), isOn: $details)
                    .disabled(!enabled)
                    .onChange(of: details) { _, _ in link.switchesChanged() }
                note(String(localized: "android.link.details.description"))
                Toggle(String(localized: "android.link.answers"), isOn: $answers)
                    .disabled(!enabled)
                    .onChange(of: answers) { _, _ in link.switchesChanged() }
                note(String(localized: "android.link.answers.description"))
                Toggle(String(localized: "android.link.usage"), isOn: $usage)
                    .disabled(!enabled)
                    .onChange(of: usage) { _, _ in link.switchesChanged() }
                note(String(localized: "android.link.usage.description"))
            }
            .padding(6)
        }
    }

    @ViewBuilder private var status: some View {
        if let error = link.error {
            note(String(format: String(localized: "android.link.error %@"), error))
        } else if link.running {
            note(String(format: String(localized: "android.link.listening %lld"), Int64(link.port)))
        }
    }

    @ViewBuilder private var pairingCode: some View {
        if let text = pairing {
            note(String(localized: "android.link.scan"))
            if let image = AndroidLinkQR.image(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .accessibilityLabel(Text("android.link.show"))
            }
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(String(localized: "android.link.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button(String(localized: "android.link.repair")) {
                    link.pairAgain()
                    pairing = link.pairingLink()
                }
            }
            note(String(localized: "android.link.repair.description"))
        } else {
            note(String(localized: "android.link.nolocal"))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#endif
