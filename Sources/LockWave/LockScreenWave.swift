// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The lock screen's wave. macOS shares a song's title and position, never
/// its sound, so the wave is drawn from the song itself: the same song
/// always has the same wave and two songs never share one. It is a picture
/// of the song's place in time, not its loudness.
enum NotchLockScreenWave {
    /// Bars in a whole song; the visible stretch scrolls through them.
    static let barCount = 1000
    /// Points from one bar to the next, and a bar's width.
    static let step: CGFloat = 3
    static let barWidth: CGFloat = 2
    /// Half the tallest bar: the wave is drawn both ways from its centre line.
    static let amplitude: CGFloat = 40
    /// Toward the display's edges the bars shrink to dots and fade over this much.
    static let fade: CGFloat = 260

    /// How much of a bar shows at `x` across a display `width` wide: whole
    /// in the middle, easing to nothing at the edges.
    static func edge(x: CGFloat, width: CGFloat) -> CGFloat {
        let e = min(1, max(0, min(x, width - x) / fade))
        return e * e * (3 - 2 * e)
    }

    /// Heights from 0 to 1, stable for a title and artist across launches:
    /// FNV-1a, since Swift's own hash changes with every run.
    static func heights(title: String?, artist: String?) -> [Double] {
        var seed: UInt64 = 0xcbf29ce484222325
        for byte in "\(artist ?? "")\u{1}\(title ?? "")".utf8 {
            seed = (seed ^ UInt64(byte)) &* 0x100000001b3
        }
        var state = seed | 1
        func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 10_000) / 10_000
        }
        // Verses and choruses: a slow swell under the bar-to-bar grain,
        // the grain skewed low so loud bars stand out, then each bar eased
        // toward its neighbours so the wave reads as music, not noise.
        let phase = next() * .pi * 2, sections = 6 + next() * 5
        let raw = (0..<barCount).map { index -> Double in
            let u = Double(index) / Double(barCount)
            let swell = 0.25 + 0.75 * pow(abs(sin(u * sections + phase)), 0.8)
            // A song starts and ends quieter than its middle.
            let ends = min(1, min(u, 1 - u) * 14 + 0.25)
            return swell * pow(next(), 1.4) * ends
        }
        return raw.indices.map { index in
            let before = raw[max(0, index - 1)], after = raw[min(raw.count - 1, index + 1)]
            return min(1, max(0.06, (before + raw[index] * 2 + after) / 4 * 1.7))
        }
    }

    /// Where the bar under the playhead is, as a fractional index.
    static func playhead(position: Double, duration: Double) -> Double {
        guard duration > 0, position.isFinite else { return 0 }
        return min(1, max(0, position / duration)) * Double(barCount)
    }
}
