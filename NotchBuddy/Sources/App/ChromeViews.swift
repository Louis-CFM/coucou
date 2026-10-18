#if !APPSTORE
import SwiftUI
import AppKit

struct ChromePill: View {
    let task: AgentTask
    @Binding var swapping: Bool
    let onTap: () -> Void
    @ObservedObject private var controller = ChromeController.shared
    @State private var isHovered = false

    private var showControls: Bool { isHovered && controller.track != nil }

    var body: some View {
        ZStack {
            // Selection target — full pill area, receives taps where controls don't
            Capsule()
                .fill(Color.clear)
                .contentShape(Capsule())
                .onTapGesture { onTap() }

            // Visual fills
            Capsule()
                .fill(isHovered ? Color(hex: task.color).opacity(0.18) : Color(hex: "#0E0F11"))
                .allowsHitTesting(false)
            Capsule()
                .stroke(Color(hex: task.color).opacity(isHovered ? 0.55 : 0.14), lineWidth: 1)
                .allowsHitTesting(false)

            // Mini Mochi at leading edge
            HStack(spacing: 0) {
                MiniBotCanvasView(task: task, isDancing: controller.isPlaying)
                    .frame(width: 22 / 0.6, height: 22 / 0.6)
                    .frame(width: 22, height: 22, alignment: .center)
                    .padding(.leading, 8)
                Spacer()
            }
            .allowsHitTesting(false)

            // Title — trailing padding grows on hover to make room for buttons
            Text(task.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHovered ? Color(hex: task.color).lighter(by: 0.3) : Color(hex: "#6B7079"))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 34)
                .padding(.trailing, showControls ? 52 : 10)
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: showControls)
                .allowsHitTesting(false)

            // Playback controls — appear on hover when a track is loaded
            if showControls {
                HStack(spacing: 0) {
                    Spacer()
                    HStack(spacing: 2) {
                        MusicControlButton(
                            icon: controller.isPlaying ? "pause.fill" : "play.fill", color: task.color
                        ) {
                            controller.playPause()
                        }
                        .disabled(controller.controlsBusy)
                        MusicControlButton(icon: "forward.fill", color: task.color) {
                            controller.nextTrack()
                        }
                        .disabled(controller.track?.canNext != true || controller.controlsBusy)
                    }
                    .padding(.trailing, 4)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .shadow(color: Color(hex: task.color).opacity(isHovered ? 0.35 : 0), radius: 10, x: 0, y: 2)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .brightness(isHovered ? 0.06 : 0)
        .onHover { newHover in
            guard !swapping else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = newHover }
        }
    }
}

struct ChromeCardView: View {
    @Environment(\.musicCardExpansion) private var expansion
    @ObservedObject private var controller = ChromeController.shared
    private let accent = Color(hex: ChromeController.accentHex)

    var body: some View {
        Group {
            if let track = controller.track { nowPlaying(track) } else { idleView }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private func nowPlaying(_ track: PlaybackSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                NowPlayingArtwork(image: controller.artwork, accent: accent)
                    .modifier(MusicArtworkExpansion(fraction: expansion))
                    .onTapGesture { controller.openPlayer() }
                    .help("Abrir reproductor")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(accent).frame(width: 6, height: 6)
                        Text(track.title.isEmpty ? "Sin título" : track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Text(controller.commandNotice ?? (track.artist.isEmpty ? "Ahora suena" : track.artist))
                        .font(.system(size: 11)).foregroundColor(
                            Color(hex: controller.commandNotice == nil ? "#8E939C" : "#E8B86D")
                        )
                        .lineLimit(1)
                        .help(controller.commandNotice ?? "").truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 24 + 67 * expansion).padding(.top, 6)
            TimelineView(.animation(minimumInterval: 1, paused: !controller.isPlaying)) { context in
                NowPlayingProgress(
                    position: controller.position(at: context.date), duration: track.duration,
                    accent: accent, canSeek: track.duration > 0 && track.canSeek && !controller.controlsBusy,
                    onSeek: { controller.seek(to: $0) })
            }
            .padding(.top, 7)
            .padding(.trailing, 67 * expansion)
            MusicTransportLayout(fraction: expansion) {
                HStack(spacing: 10) {
                    NowPlayingIconButton(
                        icon: "backward.fill", size: 11, tint: accent,
                        help: track.canPrevious ? "Anterior" : "El reproductor no ofrece Anterior para este contenido"
                    ) { controller.previousTrack() }
                    .disabled(!track.canPrevious || controller.controlsBusy)
                    .opacity(track.canPrevious && !controller.controlsBusy ? 1 : 0.35)
                    Button(action: { controller.playPause() }) {
                        ZStack {
                            Circle().fill(Color(hex: "#F5F6F8"))
                            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(Color(hex: "#0E0F11"))
                                .offset(x: controller.isPlaying ? 0 : 1)
                        }
                        .frame(width: 20, height: 20)
                    }
                    .buttonStyle(NowPlayingPressStyle())
                    .disabled(controller.controlsBusy)
                    .help(controller.isPlaying ? "Pausar" : "Reproducir")
                    NowPlayingIconButton(
                        icon: "forward.fill", size: 11, tint: accent,
                        help: track.canNext ? "Siguiente" : "El reproductor no ofrece Siguiente para este contenido"
                    ) { controller.nextTrack() }
                    .disabled(!track.canNext || controller.controlsBusy)
                    .opacity(track.canNext && !controller.controlsBusy ? 1 : 0.35)
                }
                NowPlayingIconButton(
                    icon: "power", size: 10, tint: Color(hex: "#6B7079"),
                    help: "Desconectar Ahora suena"
                ) { controller.disconnect() }
            }
            .padding(.top, 4)
            .padding(.trailing, 67 * expansion)
        }
        .padding(.leading, 108).padding(.trailing, 12)
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text("Ahora suena").font(.system(size: 12, weight: .semibold)).foregroundColor(
                    Color(hex: "#F5F6F8"))
            }
            Text(controller.connectionMessage).font(.system(size: 10))
                .foregroundColor(Color(hex: "#8E939C")).lineLimit(2)
            Button(controller.running ? "Desconectar" : "Conectar Ahora suena") {
                if controller.running { controller.disconnect() } else { controller.connect() }
            }
            .font(.system(size: 11, weight: .medium)).foregroundColor(accent).buttonStyle(.plain)
            .help(
                "Muestra la reproducción publicada en macOS, excepto Spotify y Apple Music. Sin extensiones ni permiso de Automatización."
            )
        }
        .padding(.leading, 108).padding(.trailing, 12).padding(.top, 6)
    }
}
#endif
