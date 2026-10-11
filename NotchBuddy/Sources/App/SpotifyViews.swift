#if !APPSTORE
import SwiftUI
import AppKit

// MARK: - Spotify Pill (overview right card, GitHub build only)

struct SpotifyPill: View {
    let task: AgentTask
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    @ObservedObject private var controller = SpotifyController.shared

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
        .onHover { onHover($0) }
    }
}

// MARK: - Spotify Card (overview left card, GitHub build only)

struct SpotifyCardView: View {
    @ObservedObject private var controller = SpotifyController.shared

    private let green = Color(hex: SpotifyController.green)

    var body: some View {
        Group {
            if controller.automationDenied {
                deniedView
            } else if let track = controller.track {
                nowPlaying(track)
            } else {
                idleView
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        // Spotify doesn't announce seeks made in its own window: re-read when the card shows
        .onAppear { controller.refresh() }
    }

    // MARK: Now playing

    // The card is 98 pt tall: artwork row, progress row, controls row.
    private func nowPlaying(_ track: SpotifyTrack) -> some View {
        let subtitle = [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                NowPlayingArtwork(image: controller.artwork, accent: green)
                    .frame(width: 36, height: 36)
                    .onTapGesture { controller.openSpotify() }
                    .help(track.album.isEmpty ? String(localized: "Open Spotify") : String(localized: "\(track.album) — open Spotify"))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(green).frame(width: 6, height: 6)
                        Text(track.isAd ? String(localized: "Advertisement") : track.title)
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
                    accent: green,
                    canSeek: !track.isAd && track.duration > 0,
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

    private var controls: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                NowPlayingIconButton(icon: "shuffle", size: 10,
                                  tint: controller.shuffling ? green : Color(hex: "#6B7079"),
                                  help: controller.shuffling ? "Shuffle on" : "Shuffle off") {
                    controller.setShuffling(!controller.shuffling)
                }
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
                NowPlayingIconButton(icon: "repeat", size: 10,
                                  tint: controller.repeating ? green : Color(hex: "#6B7079"),
                                  help: controller.repeating ? "Repeat on" : "Repeat off") {
                    controller.setRepeating(!controller.repeating)
                }
            }
            Spacer(minLength: 8)
            NowPlayingVolume(volume: controller.volume, accent: green) { controller.setVolume($0) }
        }
    }

    // MARK: Idle / not installed / denied (same layout as the other idle cards)

    private var idleView: some View {
        let installed = controller.isInstalled
        return VStack(alignment: .leading, spacing: 6) {
            header(dot: green)
            HStack(spacing: 5) {
                Circle()
                    .fill(installed ? Color(hex: "#22C55E") : Color(hex: "#F4505E"))
                    .frame(width: 5, height: 5)
                Text(installed ? String(localized: "Not playing") : String(localized: "Spotify not installed"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
            }
            .padding(.leading, 108)
            .padding(.top, 2)

            Button(installed ? String(localized: "Open Spotify") : String(localized: "Get Spotify")) {
                installed ? controller.openSpotify() : controller.openDownloadPage()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(green.opacity(0.85))
            .buttonStyle(.plain)
            .padding(.leading, 108)
            .padding(.top, 2)
        }
    }

    private var deniedView: some View {
        VStack(alignment: .leading, spacing: 4) {
            header(dot: Color(hex: "#F4505E"))
            Text("Allow Coucou to control Spotify")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .padding(.leading, 108)
                .padding(.trailing, 12)
            Button("Open Settings…") { controller.openAutomationSettings() }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(green.opacity(0.85))
                .buttonStyle(.plain)
                .padding(.leading, 108)
                .padding(.top, 2)
        }
    }

    private func header(dot: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text("Spotify")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            Text(PillCatalog.definition(for: SpotifyController.pillId)?.subtitle ?? "Integration")
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
