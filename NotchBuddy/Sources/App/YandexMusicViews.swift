#if !APPSTORE
import SwiftUI
import AppKit

// MARK: - Yandex Music Pill (overview right card, GitHub build only)

struct YandexMusicPill: View {
    let task: AgentTask
    @Binding var swapping: Bool
    let onTap: () -> Void
    @ObservedObject private var controller = YandexMusicController.shared
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
                        MusicControlButton(icon: controller.isPlaying ? "pause.fill" : "play.fill", color: task.color) {
                            controller.playPause()
                        }
                        MusicControlButton(icon: "forward.fill", color: task.color) {
                            controller.nextTrack()
                        }
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

// MARK: - Yandex Music Card (overview left card, GitHub build only)

struct YandexMusicCardView: View {
    @ObservedObject private var controller = YandexMusicController.shared

    private let yellow = Color(hex: YandexMusicController.yellow)

    var body: some View {
        Group {
            if controller.nowPlayingUnavailable {
                unavailableView
            } else if let track = controller.track {
                nowPlaying(track)
            } else {
                idleView
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        // Seeks made in Yandex Music's own window aren't announced: re-read when the card shows
        .onAppear { controller.refresh() }
    }

    // MARK: Now playing

    // The card is 98 pt tall: artwork row, progress row, controls row.
    private func nowPlaying(_ track: YandexMusicTrack) -> some View {
        let subtitle = [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                NowPlayingArtwork(image: controller.artwork, accent: yellow)
                    .frame(width: 36, height: 36)
                    .onTapGesture { controller.openYandexMusic() }
                    .help(track.album.isEmpty ? String(localized: "Open Yandex Music") : String(localized: "\(track.album) — open Yandex Music"))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(yellow).frame(width: 6, height: 6)
                        Text(track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 24)   // the ↗ button sits top-right
            .padding(.top, 6)

            // Position runs on its own clock only while playing and on screen
            TimelineView(.animation(minimumInterval: 0.5, paused: !controller.isPlaying)) { context in
                NowPlayingProgress(
                    position: controller.position(at: context.date),
                    duration: track.duration,
                    accent: yellow,
                    canSeek: track.duration > 0,
                    onSeek: { controller.seek(to: $0) }
                )
            }
            .padding(.top, 7)

            controls
                .padding(.top, 4)
        }
        .padding(.leading, 108)
        .padding(.trailing, 12)
    }

    // No shuffle, repeat or volume: Yandex Music only exposes play/pause, skip and seek.
    private var controls: some View {
        HStack(spacing: 10) {
            NowPlayingIconButton(icon: "backward.fill", size: 11, tint: Color(hex: "#C5C8CD"), help: "Previous") {
                controller.previousTrack()
            }
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
            .help(controller.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
            NowPlayingIconButton(icon: "forward.fill", size: 11, tint: Color(hex: "#C5C8CD"), help: "Next") {
                controller.nextTrack()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Idle / not installed / Now Playing unavailable (same layout as the other idle cards)

    private var idleView: some View {
        let installed = controller.isInstalled
        return VStack(alignment: .leading, spacing: 6) {
            header(dot: yellow)
            HStack(spacing: 5) {
                Circle()
                    .fill(installed ? Color(hex: "#22C55E") : Color(hex: "#F4505E"))
                    .frame(width: 5, height: 5)
                Text(installed ? String(localized: "Not playing") : String(localized: "Yandex Music not installed"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
            }
            .padding(.leading, 108)
            .padding(.top, 2)

            Button(installed ? String(localized: "Open Yandex Music") : String(localized: "Get Yandex Music")) {
                installed ? controller.openYandexMusic() : controller.openDownloadPage()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(yellow.opacity(0.85))
            .buttonStyle(.plain)
            .padding(.leading, 108)
            .padding(.top, 2)
        }
    }

    private var unavailableView: some View {
        VStack(alignment: .leading, spacing: 4) {
            header(dot: Color(hex: "#F4505E"))
            Text("Coucou can't read Now Playing on this Mac")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .padding(.leading, 108)
                .padding(.trailing, 12)
            Button("Open Yandex Music") { controller.openYandexMusic() }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(yellow.opacity(0.85))
                .buttonStyle(.plain)
                .padding(.leading, 108)
                .padding(.top, 2)
        }
    }

    private func header(dot: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text("Yandex Music")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            Text(PillCatalog.definition(for: YandexMusicController.pillId)?.subtitle ?? "Integration")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
            Spacer(minLength: 2)
        }
        .padding(.top, 6)
        .padding(.leading, 108)
        .padding(.trailing, 36)
    }
}
#endif
