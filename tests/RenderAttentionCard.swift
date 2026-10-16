import AppKit
import SwiftUI

@main
enum RenderAttentionCard {
    @MainActor static func main() throws {
        let request = MainSessionAttention(source: "opencode", requestId: "per_demo", sessionId: "ses_demo",
                                           title: "主要聊天：整理專案檔案", reason: "需要你核准執行測試：npm test",
                                           kind: "permission", expiresAt: Date().timeIntervalSince1970 + 25)
        let card = MainSessionAttentionCard(request: request, count: 1, onOpen: {}, onDismiss: {})
            .frame(width: 608, height: 152)
            .background(.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:])
        else { fatalError("Card rendering failed") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
