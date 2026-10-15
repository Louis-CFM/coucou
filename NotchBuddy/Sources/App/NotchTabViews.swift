#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - The notch's Music and Calendar tabs (GitHub build)
//
// Every tab stays mounted behind the active one (for the cross-fade): these views follow the
// players and Calendar only while their tab is the one shown.

/// Runs `start` when the view is on screen and its tab is the active one, `stop` when it no
/// longer is: always in pairs.
private struct WhileTabActive: ViewModifier {
    let start: () -> Void
    let stop: () -> Void
    @Environment(\.islandViewActive) private var active
    @State private var appeared = false
    @State private var running = false

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true; sync() }
            .onDisappear { appeared = false; sync() }
            .onChange(of: active) { _, _ in sync() }
    }

    private func sync() {
        let on = appeared && active
        guard on != running else { return }
        running = on
        on ? start() : stop()
    }
}

extension View {
    func whileTabActive(start: @escaping () -> Void, stop: @escaping () -> Void) -> some View {
        modifier(WhileTabActive(start: start, stop: stop))
    }
}

// MARK: - Music

/// What Spotify or Music plays, with its controls. Mochi dances on the left while it plays.
struct NotchMusicView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var music = MusicController.shared
    @Environment(\.islandViewActive) private var active

    private enum Source { case spotify, music }

    /// The one playing, else the one with a track, Spotify first.
    private var source: Source? {
        if spotify.track != nil && spotify.isPlaying { return .spotify }
        if music.trackTitle != nil && state.musicPlaying { return .music }
        if spotify.track != nil { return .spotify }
        if music.trackTitle != nil { return .music }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            Group {
                if let source { player(source) } else { idle }
            }
            .padding(.leading, 108)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .whileTabActive(start: { spotify.watch(true); music.watch(true) },
                        stop: { spotify.watch(false); music.watch(false) })
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("hub.music.nothing")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#8E939C"))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if spotify.isInstalled {
                    Button(String(format: String(localized: "hub.music.open %@"), "Spotify")) { spotify.openSpotify() }
                        .foregroundColor(Color(hex: SpotifyController.green))
                }
                Button(String(format: String(localized: "hub.music.open %@"), String(localized: "hub.music.apple-music"))) {
                    music.openMusic()
                }
                .foregroundColor(Color(hex: "#FA2D48"))
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
        }
    }

    private func player(_ source: Source) -> some View {
        let isSpotify = source == .spotify
        let accent = isSpotify ? Color(hex: SpotifyController.green) : Color(hex: "#FA2D48")
        let playing = isSpotify ? spotify.isPlaying : state.musicPlaying
        return HStack(alignment: .center, spacing: 12) {
            NowPlayingArtwork(image: isSpotify ? spotify.artwork : nil, accent: accent)
                .frame(width: 66, height: 66)
                .onTapGesture { isSpotify ? spotify.openSpotify() : music.openMusic() }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    NotchEqualizer(playing: playing && active, color: accent)
                        .frame(width: 14, height: 10)
                    Text((isSpotify ? spotify.track?.title : music.trackTitle) ?? "")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1).truncationMode(.tail)
                }
                Text((isSpotify ? spotify.track?.artist : music.artist) ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1).truncationMode(.tail)
                if isSpotify, let track = spotify.track {
                    TimelineView(.animation(minimumInterval: 0.5, paused: !playing || !active)) { context in
                        NowPlayingProgress(position: spotify.position(at: context.date), duration: track.duration,
                                           accent: accent, canSeek: !track.isAd && track.duration > 0) { spotify.seek(to: $0) }
                    }
                }
                HStack(spacing: 16) {
                    if isSpotify {
                        NowPlayingIconButton(icon: "shuffle", size: 10, tint: spotify.shuffling ? accent : Color(hex: "#8E939C"),
                                             help: "Shuffle") { spotify.setShuffling(!spotify.shuffling) }
                    }
                    NowPlayingIconButton(icon: "backward.fill", size: 11, tint: Color(hex: "#C5C8CD"), help: "Previous") {
                        isSpotify ? spotify.previousTrack() : music.previousTrack()
                    }
                    NowPlayingIconButton(icon: playing ? "pause.fill" : "play.fill", size: 14, tint: Color(hex: "#F5F6F8"),
                                         help: playing ? "Pause" : "Play") {
                        isSpotify ? spotify.playPause() : music.playPause()
                    }
                    NowPlayingIconButton(icon: "forward.fill", size: 11, tint: Color(hex: "#C5C8CD"), help: "Next") {
                        isSpotify ? spotify.nextTrack() : music.nextTrack()
                    }
                    if isSpotify {
                        NowPlayingIconButton(icon: "repeat", size: 10, tint: spotify.repeating ? accent : Color(hex: "#8E939C"),
                                             help: "Repeat") { spotify.setRepeating(!spotify.repeating) }
                        Spacer(minLength: 0)
                        NowPlayingVolume(volume: spotify.volume, accent: accent) { spotify.setVolume($0) }
                    }
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Three little bars bouncing to Mochi's 112 BPM while the music plays.
private struct NotchEqualizer: View {
    let playing: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(paused: !playing)) { timeline in
            let beat = timeline.date.timeIntervalSinceReferenceDate * 112 / 60
            Canvas { context, size in
                let w = size.width / 5
                for i in 0..<3 {
                    let level = playing ? 0.3 + 0.7 * abs(sin(.pi * beat * (0.5 + 0.25 * Double(i)) + Double(i))) : 0.3
                    let h = size.height * level
                    let rect = CGRect(x: CGFloat(i) * w * 2, y: size.height - h, width: w, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(color))
                }
            }
        }
    }
}

// MARK: - Calendar

/// The next events of the Mac's Calendar and of Cal.com, as in the Calendar pill's card.
struct NotchCalendarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            CalendarCardView()
        }
    }
}
#endif
