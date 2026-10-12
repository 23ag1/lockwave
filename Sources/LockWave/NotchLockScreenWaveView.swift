// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The song's wave from one edge of the display to the other, the playhead
/// fixed under the clock and the wave moving through it: what has played in
/// the cover's colour on the left, what is coming in quiet white on the
/// right, each bar over its fainter reflection. Toward the edges the wave
/// fades out; the wallpaper under it is never touched. A click or a drag on it seeks, where allowed.
struct NotchLockScreenWaveBand: View {
    let playback: NotchPlayback
    @ObservedObject var service: NotchMusicService
    let tint: Color
    /// Play or pause as last asked, a beat before the player says so.
    let playing: Bool
    var skipping = false
    @State private var scrubPosition: Double?
    @State private var scrubStart: Double?
    /// Where a pause asked here stopped the wave, until the player stops too.
    @State private var held: Double?
    /// Where a play asked here set the wave going, until the player plays too.
    @State private var resumed: (position: Double, at: Date)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let waveHeight = NotchLockScreenWave.amplitude * 2 + 20
    static let height: CGFloat = waveHeight + 30

    var body: some View {
        let heights = Self.heights(for: playback.track)
        let timed = playback.duration > 0
        // The wave moves on its own in Core Animation; this only ticks the
        // clock under it, twice a second, and not at all when it stands.
        return TimelineView(.animation(minimumInterval: 0.5,
                                       paused: !moving || !timed)) { context in
            let position = scrubPosition ?? held ?? resumedPosition(at: context.date) ?? playback.position(at: context.date)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack {
                    wave(position: position, heights: heights)
                        .frame(width: width, height: Self.waveHeight)
                        .position(x: width / 2, y: Self.waveHeight / 2)
                    if timed {
                        Capsule().fill(.white)
                            .frame(width: 2, height: Self.waveHeight)
                            .shadow(color: .black.opacity(0.35), radius: 3)
                            .position(x: width / 2, y: Self.waveHeight / 2)
                        times(position).position(x: width / 2, y: Self.waveHeight + 18)
                    }
                }
                // The window lets clicks through clear pixels, which between
                // bars would miss the wave; a wash no one can see takes them.
                .background(Color.black.opacity(0.01))
                .contentShape(Rectangle())
                .gesture(seek(width: width))
            }
        }
        .frame(height: Self.height)
        .onChange(of: playback.track) { scrubPosition = nil; held = nil; resumed = nil }
        // A pause stops the wave at the click, where it is on screen.
        // A play sets it going at once, from where it stands; the player's
        // own word, when it comes late, changes nothing on screen.
        .onChange(of: playing) {
            let now = Date()
            let shown = held ?? resumedPosition(at: now) ?? playback.position(at: now)
            held = playing ? nil : shown
            resumed = playing && !playback.isPlaying ? (shown, now) : nil
        }
        .onChange(of: playback.isPlaying) { if playback.isPlaying { resumed = nil } }
        // Released once the player reports the new place, or after a moment
        // if it never does, so the wave neither jumps back nor sticks.
        .onChange(of: playback.sampledAt) {
            // Paused elsewhere at another place: that place wins.
            if let held, !playback.isPlaying, abs(playback.position(at: Date()) - held) > 1.5 { self.held = nil }
            if let scrubPosition, scrubStart == nil, abs(playback.position(at: Date()) - scrubPosition) <= 2 {
                self.scrubPosition = nil
            }
        }
        .task(id: scrubPosition) {
            guard scrubPosition != nil, scrubStart == nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, scrubStart == nil { scrubPosition = nil }
        }
        .accessibilityHidden(true)
    }

    private var secondsPerPoint: Double {
        playback.duration / Double(NotchLockScreenWave.barCount) / Double(NotchLockScreenWave.step)
    }

    /// A click jumps to the bar under it; a drag moves the wave under the
    /// playhead, left to go ahead, as the wave itself moves while playing.
    private func seek(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard canSeek else { return }
                let start = scrubStart ?? playback.position(at: Date())
                scrubStart = start
                guard abs(drag.translation.width) > 3 else { return }
                scrubPosition = clamp(start - Double(drag.translation.width) * secondsPerPoint)
            }
            .onEnded { drag in
                guard canSeek, let start = scrubStart else { scrubStart = nil; return }
                let target = abs(drag.translation.width) > 3
                    ? clamp(start - Double(drag.translation.width) * secondsPerPoint)
                    : clamp(start + Double(drag.location.x - width / 2) * secondsPerPoint)
                scrubPosition = target
                scrubStart = nil
                service.seek(to: target, in: playback.track, context: playback.commandContext)
            }
    }

    private var canSeek: Bool { service.canSeek && playback.duration > 0 && !service.commandPending }
    private func clamp(_ position: Double) -> Double { min(playback.duration, max(0, position)) }

    /// Drawn once per song; the band redraws thirty times a second.
    @MainActor private static var cache: (key: String, heights: [Double])?
    @MainActor private static func heights(for track: RadialNowPlayingSnapshot) -> [Double] {
        let key = "\(track.artist ?? "")\u{1}\(track.title ?? "")"
        if let cache, cache.key == key { return cache.heights }
        let heights = NotchLockScreenWave.heights(title: track.title, artist: track.artist)
        cache = (key, heights)
        return heights
    }

    private func wave(position: Double, heights: [Double]) -> some View {
        let timed = playback.duration > 0
        return NotchLockScreenWaveLayer(
            key: "\(playback.track.artist ?? "")\u{1}\(playback.track.title ?? "")",
            heights: heights, tint: NSColor(tint),
            head: timed ? NotchLockScreenWave.playhead(position: position, duration: playback.duration)
                : Double(heights.count) / 2,
            speed: moving ? Double(NotchLockScreenWave.barCount) / playback.duration * pace : 0,
            timed: timed, playing: playing, skipping: skipping, reduceMotion: reduceMotion)
    }

    private var moving: Bool {
        playback.duration > 0 && playing && (playback.isPlaying || resumed != nil) && scrubPosition == nil
    }

    /// A paused player may report no rate; a play asked here runs at normal speed.
    private var pace: Double { playback.rate > 0 ? playback.rate : 1 }

    private func resumedPosition(at date: Date) -> Double? {
        guard let resumed else { return nil }
        return min(playback.duration, resumed.position + max(0, date.timeIntervalSince(resumed.at)) * pace)
    }

    static let gap: CGFloat = 2
    static let echo: CGFloat = 0.5
    /// Where the bars stand, so the bars and their reflection fill the band.
    static func baseline(_ height: CGFloat) -> CGFloat { (height - gap) / (1 + echo) }

    /// Elapsed on the played side, remaining on the side to come, as quiet
    /// type either side of the playhead.
    private func times(_ position: Double) -> some View {
        HStack(spacing: 18) {
            Text(Self.timestamp(position))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("−" + Self.timestamp(playback.duration - position))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.5), radius: 6)
        .frame(width: 240)
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let seconds = Int(min(604_800, max(0, interval)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

