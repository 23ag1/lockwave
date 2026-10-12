// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// The song across the lock screen, as Vorssaint draws it.
struct NotchLockScreenPlayer: View {
    let size: CGSize
    @ObservedObject private var music = NotchMusicService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// What a tap on play or pause asked for, shown at once as the island's
    /// own player shows it, until the player says so.
    @State private var requestedPlaying: Bool?
    /// A skip asked here, until the next song or the start of this one comes.
    @State private var skipping = false
    /// Back restarts a song that is past its start rather than going back.
    @State private var skippingBack = false
    private var accent: Color { music.artworkTint?.color ?? .white }

    var body: some View {
        let shown = music.playback.map { $0.track.title != nil || $0.track.artist != nil } == true
        ZStack {
            if shown, let playback = music.playback {
                horizon(playback)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: shown)
        // A second tap before the player answers asks for the state after it,
        // so only the player reaching what was asked ends the early word.
        .onChange(of: music.playback?.isPlaying) {
            if music.playback?.isPlaying == requestedPlaying { requestedPlaying = nil }
        }
        .onChange(of: music.playback?.track) { requestedPlaying = nil; skipping = false }
        // Back may only restart the song: its start ends the skip as well.
        .onChange(of: music.playback?.sampledAt) {
            if skipping, skippingBack, let playback = music.playback, playback.position(at: Date()) < 2 { skipping = false }
        }
        .task(id: skipping) {
            guard skipping else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { skipping = false }
        }
        // A player that never answers leaves the button as it was.
        .task(id: requestedPlaying) {
            guard requestedPlaying != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { requestedPlaying = nil }
        }
    }

    /// The song across the lock screen: the cover and its tags centred
    /// under the clock, the wave from edge to edge with the playhead on the
    /// same axis as the clock and the login picture, the buttons under it.
    /// No pane: a soft shade behind keeps white type readable on any photo.
    private func horizon(_ playback: NotchPlayback) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                NotchArtwork(image: music.artwork, size: 104)
                    .shadow(color: .black.opacity(0.5), radius: 22, y: 12)
                    .scaleEffect(playback.isPlaying || reduceMotion ? 1 : 0.94)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: playback.isPlaying)
                let title = playback.track.title ?? Strings.nowPlaying
                let artist = playback.track.artist ?? playback.track.album
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 34, weight: .bold))
                    if let artist {
                        Text(artist)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                // As wide as the longer line, so the cover and the song stay
                // centred together, and no wider than the room under the clock.
                .frame(width: Self.textWidth(title: title, artist: artist, limit: min(620, size.width - 360)),
                       alignment: .leading)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 1)
            }
            .padding(.bottom, 34)
            NotchLockScreenWaveBand(playback: playback, service: music, tint: accent,
                                    playing: requestedPlaying ?? playback.isPlaying, skipping: skipping)
            transport(playback, large: true)
                .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .frame(width: size.width)
        .background {
            EllipticalGradient(colors: [.black.opacity(0.5), .clear], center: .center,
                               startRadiusFraction: 0, endRadiusFraction: 0.5)
                .frame(width: size.width * 0.9)
                .allowsHitTesting(false)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func textWidth(title: String, artist: String?, limit: CGFloat) -> CGFloat {
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .bold)]).width
        let artistWidth = artist.map {
            ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold)]).width
        } ?? 0
        return min(max(1, limit), ceil(max(titleWidth, artistWidth)) + 2)
    }

    private func cover(size: CGFloat, playback: NotchPlayback) -> some View {
        NotchArtwork(image: music.artwork, size: size)
            .shadow(color: (music.artworkTint?.color ?? .black).opacity(0.5), radius: size * 0.28, y: size * 0.1)
            .scaleEffect(playback.isPlaying || reduceMotion ? 1 : 0.92)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: playback.isPlaying)
    }

    /// The player's own buttons, never a permission prompt: a request made
    /// here would open behind the lock screen, where no one can answer it.
    private func transport(_ playback: NotchPlayback, large: Bool = false) -> some View {
        let playing = requestedPlaying ?? playback.isPlaying
        return glassGroup(large) {
            HStack(spacing: large ? 26 : 46) {
                if !music.lacksTrackSkipping(.previous) {
                    button("backward.fill", size: large ? 18 : 22, title: Strings.previous, command: .previous,
                           playback: playback, large: large)
                }
                button(playing ? "pause.fill" : "play.fill", size: large ? 19 : 30, title: Strings.playPause,
                       command: .toggle, playback: playback, large: large, disc: large)
                if !music.lacksTrackSkipping(.next) {
                    button("forward.fill", size: large ? 18 : 22, title: Strings.next, command: .next,
                           playback: playback, large: large)
                }
            }
        }
        .frame(height: large ? 64 : 46)
    }

    /// One container, so the three glass circles sample the wallpaper as
    /// one surface; they sit far enough apart never to melt together.
    @ViewBuilder private func glassGroup<Content: View>(_ large: Bool, @ViewBuilder _ content: () -> Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26, *), large, !reduceTransparency {
            GlassEffectContainer(spacing: 6) { content() }
        } else {
            content()
        }
#else
        content()
#endif
    }

    /// Liquid Glass circles: play a size up and tinted with the cover, the
    /// skips clear. Interactive glass answers the press itself.
    @ViewBuilder private func glassButton(_ symbol: String, size: CGFloat, disc: Bool) -> some View {
        let side: CGFloat = disc ? 64 : 50
        let glyph = Image(systemName: symbol)
            .font(.system(size: disc ? 22 : size, weight: .bold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: symbol)
            .frame(width: side, height: side)
            .contentShape(Circle())
#if compiler(>=6.2)
        if #available(macOS 26, *) {
            glyph
                .glassEffect(disc ? .regular.tint(accent.opacity(0.42)).interactive() : .clear.interactive(),
                             in: Circle())
                .environment(\.appearsActive, true)
                .materialActiveAppearance(.active)
        } else {
            glyph
        }
#else
        glyph
#endif
    }

    private var usesGlass: Bool {
#if compiler(>=6.2)
        if #available(macOS 26, *) { return !reduceTransparency }
#endif
        return false
    }

    private func button(_ symbol: String, size: CGFloat, title: String, command: NotchMusicService.Command,
                        playback: NotchPlayback, large: Bool = false, disc: Bool = false) -> some View {
        Button {
            let playing = requestedPlaying ?? playback.isPlaying
            // The button turns at the click. A player reached by Apple Event
            // (a browser tab) answers a beat later; until then, or until the
            // early word times out, the screen shows what was asked.
            guard music.send(command, context: playback.commandContext) else { return }
            switch command {
            case .toggle: requestedPlaying = !playing
            case .next, .previous: skipping = true; skippingBack = command == .previous
            default: break
            }
        } label: {
            if large && usesGlass {
                glassButton(symbol, size: size, disc: disc)
            } else {
                flatLabel(symbol, size: size, large: large, disc: disc)
            }
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 14, lifts: !(large && usesGlass), highlights: !large))
        // While a command is on its way the buttons stay lit: dimming them for
        // that beat reads as lag. A click in it is simply not sent.
        .disabled(!music.canPerform(command) && !music.commandPending)
        .accessibilityLabel(title)
    }

    /// Without glass the large skips are bare glyphs and play sits on a
    /// white disc; nothing else draws a shape, so no ring shows around them.
    private func flatLabel(_ symbol: String, size: CGFloat, large: Bool, disc: Bool) -> some View {
        let side: CGFloat = disc ? 52 : large ? 44 : max(48, size * 1.6)
        return Image(systemName: symbol)
                .font(.system(size: size, weight: large ? .bold : .semibold))
                .foregroundStyle(disc ? Color.black.opacity(0.85) : Color.white.opacity(large ? 0.92 : 1))
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: symbol)
                .frame(width: side, height: large ? side : max(44, size * 1.4))
                .background {
                    // A bare glyph would let clicks through the clear pixels
                    // around it; a wash no one can see takes the whole circle.
                    if disc { Circle().fill(.white).shadow(color: .black.opacity(0.28), radius: 12, y: 4) }
                    else if large { Circle().fill(Color.black.opacity(0.01)) }
                }
                .shadow(color: disc ? .clear : .black.opacity(0.4), radius: 6)
                .contentShape(large ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 14)))
    }
}
