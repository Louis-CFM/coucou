#if !APPSTORE
import AppKit
import SwiftUI

/// Whether Spotify or Music plays, for the Mochis that dance (read each frame, no observer).
/// The players only know it while their pill is on or a Music view shows.
@MainActor
enum HubNowPlaying {
    static var isPlaying: Bool {
        AppState.shared.musicPlaying || SpotifyController.shared.isPlaying
    }
}

/// The Music page: what Spotify or Music plays, its controls, and the Mochis dancing to it.
/// It follows both players while it shows, pill on or not.
struct HubMusicPage: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var music = MusicController.shared

    private enum Source { case spotify, music }

    /// The player shown: the one playing, else the one with a track, Spotify first.
    private var source: Source? {
        let spotifyTrack = spotify.track != nil
        let musicTrack = music.trackTitle != nil
        if spotifyTrack && spotify.isPlaying { return .spotify }
        if musicTrack && state.musicPlaying { return .music }
        if spotifyTrack { return .spotify }
        if musicTrack { return .music }
        return nil
    }

    private var playing: Bool {
        switch source {
        case .spotify: return spotify.isPlaying
        case .music:   return state.musicPlaying
        case nil:      return false
        }
    }

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.page.music"),
                        subtitle: String(localized: "hub.music.subtitle")) {
            if let source {
                player(source)
            } else {
                HubCard {
                    HubEmptyState(text: String(localized: "hub.music.nothing"), state: .sleeping, color: "#1DB954")
                    HStack(spacing: 10) {
                        if spotify.isInstalled { openButton("Spotify", bundleId: SpotifyController.bundleId) }
                        openButton(String(localized: "hub.music.apple-music"), bundleId: "com.apple.Music")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HubLabel(String(localized: "hub.music.dancefloor"))
            HubDanceFloor(playing: playing)
            if spotify.automationDenied {
                Text("hub.music.automation-denied")
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            spotify.watch(true)
            music.watch(true)
        }
        .onDisappear {
            spotify.watch(false)
            music.watch(false)
        }
    }

    private func openButton(_ name: String, bundleId: String) -> some View {
        Button(String(format: String(localized: "hub.music.open %@"), name)) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        .buttonStyle(HubButtonStyle())
    }

    // MARK: Player

    private func player(_ source: Source) -> some View {
        let isSpotify = source == .spotify
        let accent = isSpotify ? Color(hex: SpotifyController.green) : Color(hex: "#FA2D48")
        return HStack(alignment: .center, spacing: 24) {
            HubAlbumArt(image: isSpotify ? spotify.artwork : nil, accent: accent, playing: playing)
                .frame(width: 168, height: 168)
            VStack(alignment: .leading, spacing: 6) {
                Text(isSpotify ? "Spotify" : String(localized: "hub.music.apple-music"))
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundColor(accent)
                Text((isSpotify ? spotify.track?.title : music.trackTitle) ?? "")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.4)
                    .lineLimit(2)
                Text((isSpotify ? spotify.track?.artist : music.artist) ?? "")
                    .font(.system(size: 15))
                    .foregroundColor(HubTheme.body)
                    .lineLimit(1)
                if let album = isSpotify ? spotify.track?.album : music.album, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 13))
                        .foregroundColor(HubTheme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isSpotify, let track = spotify.track {
                    // Spotify only posts on play, pause and track change: the bar runs on from
                    // its last position, redrawn once a second while it plays.
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        NowPlayingProgress(position: spotify.position(at: timeline.date), duration: track.duration,
                                           accent: accent, canSeek: !track.isAd) { spotify.seek(to: $0) }
                    }
                    .frame(maxWidth: 420)
                }
                controls(isSpotify: isSpotify, accent: accent)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubTheme.card)
                // The cover's colour, faint, behind the card.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [accent.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
    }

    private func controls(isSpotify: Bool, accent: Color) -> some View {
        HStack(spacing: 18) {
            if isSpotify {
                HubPlayerButton(symbol: "shuffle", size: 13, tint: spotify.shuffling ? accent : HubTheme.secondary,
                                help: String(localized: "hub.music.shuffle")) { spotify.setShuffling(!spotify.shuffling) }
            }
            HubPlayerButton(symbol: "backward.fill", size: 16, tint: HubTheme.text,
                            help: String(localized: "hub.music.previous")) {
                isSpotify ? spotify.previousTrack() : music.previousTrack()
            }
            Button {
                isSpotify ? spotify.playPause() : music.playPause()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.white))
                    .contentShape(Circle())
            }
            .buttonStyle(NowPlayingPressStyle())
            .help(playing ? String(localized: "hub.music.pause") : String(localized: "hub.music.play"))
            HubPlayerButton(symbol: "forward.fill", size: 16, tint: HubTheme.text,
                            help: String(localized: "hub.music.next")) {
                isSpotify ? spotify.nextTrack() : music.nextTrack()
            }
            if isSpotify {
                HubPlayerButton(symbol: "repeat", size: 13, tint: spotify.repeating ? accent : HubTheme.secondary,
                                help: String(localized: "hub.music.repeat")) { spotify.setRepeating(!spotify.repeating) }
                NowPlayingVolume(volume: spotify.volume, accent: accent) { spotify.setVolume($0) }
                    .padding(.leading, 6)
            }
        }
    }
}

/// A transport button of the Music page.
private struct HubPlayerButton: View {
    let symbol: String
    let size: CGFloat
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(tint.opacity(hover ? 1 : 0.85))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(NowPlayingPressStyle())
        .help(help)
        .accessibilityLabel(help)
        .onHover { hover = $0 }
    }
}

/// The cover, breathing a little to the beat while the music plays. Music gives no cover:
/// a note on the player's colour instead.
private struct HubAlbumArt: View {
    let image: NSImage?
    let accent: Color
    let playing: Bool
    @Environment(\.hubVisible) private var visible

    var body: some View {
        TimelineView(.animation(paused: !visible || !playing)) { timeline in
            let beat = timeline.date.timeIntervalSinceReferenceDate * 112 / 60
            let pulse = playing ? 1 + 0.018 * pow(abs(sin(.pi * beat)), 4) : 1
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [accent, accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: accent.opacity(playing ? 0.45 : 0.15), radius: playing ? 22 : 10, y: 6)
            .scaleEffect(pulse)
        }
        .animation(.easeInOut(duration: 0.3), value: image)
    }
}

/// The dance floor: an equalizer to the beat and a troupe of Mochis that dance while it plays
/// and wander when it stops. Click one to say hello.
private struct HubDanceFloor: View {
    let playing: Bool
    @Environment(\.hubVisible) private var visible

    private static let cast: [HubMochiSpec] = [
        HubMochiSpec(color: "#1DB954", size: 74, outfit: .sunglasses, start: 0.08, dances: true),
        HubMochiSpec(color: "#F5F6F8", size: 62, outfit: .partyHat, start: 0.3, dances: true),
        HubMochiSpec(color: "#FB923C", size: 84, outfit: .crown, start: 0.52, dances: true),
        HubMochiSpec(color: "#A78BFA", size: 58, outfit: .beanie, start: 0.74, dances: true),
        HubMochiSpec(color: "#F472B6", size: 66, outfit: .bow, start: 0.95, dances: true),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            TimelineView(.animation(paused: !visible || !playing)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    Self.drawEqualizer(&context, size: size, time: t, playing: playing)
                }
            }
            HubMochiScene(cast: Self.cast, range: 0.04...0.96)
                .frame(height: 112)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        .frame(height: 190)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: "#020203")))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
    }

    /// Bars bouncing at the Mochis' 112 BPM, each at its own rhythm; low and still when paused.
    private static func drawEqualizer(_ context: inout GraphicsContext, size: CGSize, time: Double, playing: Bool) {
        let count = 36
        let gap: CGFloat = 4
        let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let beat = time * 112 / 60
        let colors = [Color(hex: "#1DB954"), Color(hex: "#22D3EE"), Color(hex: "#A78BFA"), Color(hex: "#F472B6"), Color(hex: "#FB923C")]
        for i in 0..<count {
            let k = Double(i)
            let level: Double
            if playing {
                let a = abs(sin(.pi * beat * (0.5 + Double(i % 4) * 0.25) + k * 0.7))
                let b = abs(sin(.pi * beat * 0.25 + k * 1.3))
                level = 0.12 + 0.6 * a * (0.5 + 0.5 * b)
            } else {
                level = 0.05
            }
            let h = size.height * 0.62 * CGFloat(level)
            let x = CGFloat(i) * (width + gap)
            let rect = CGRect(x: x, y: size.height - h, width: width, height: h)
            let color = colors[i * colors.count / count]
            context.fill(Path(roundedRect: rect, cornerRadius: width / 2),
                         with: .linearGradient(Gradient(colors: [color.opacity(0.55), color.opacity(0.05)]),
                                               startPoint: CGPoint(x: x, y: rect.minY), endPoint: CGPoint(x: x, y: size.height)))
        }
    }
}
#endif
