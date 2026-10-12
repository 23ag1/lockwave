// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// The moving wave as Core Animation. The song is drawn once into two
/// bitmaps, the cover's colour and white, each in a clip on its side of the
/// playhead; while the song plays a single linear animation carries both to
/// the song's end, and the window server moves them. The app only touches
/// the layers again on a pause, a seek, a new song or a real drift from the
/// player. What a click asks shows at the click, whatever the player: a pause
/// folds the bars down to their line, a skip folds them away and the new
/// song grows out of it when it comes.
struct NotchLockScreenWaveLayer: NSViewRepresentable {
    let key: String
    let heights: [Double]
    let tint: NSColor
    /// Bar under the playhead, and how many bars a second pass it.
    let head: Double
    let speed: Double
    let timed: Bool
    let playing: Bool
    /// A skip was asked and the next song is on its way: the wave folds now.
    var skipping = false
    var reduceMotion = false

    func makeNSView(context: Context) -> NotchLockScreenWaveLayerView { NotchLockScreenWaveLayerView() }

    func updateNSView(_ view: NotchLockScreenWaveLayerView, context: Context) {
        view.update(.init(key: key, heights: heights, tint: tint, head: head, speed: speed,
                          timed: timed, playing: playing, skipping: skipping, reduceMotion: reduceMotion))
    }
}

final class NotchLockScreenWaveLayerView: NSView {
    struct Inputs {
        let key: String
        let heights: [Double]
        let tint: NSColor
        let head: Double
        let speed: Double
        let timed: Bool
        let playing: Bool
        let skipping: Bool
        let reduceMotion: Bool
    }

    /// One song's wave: both strips in their clips, under a layer that folds
    /// them toward the line they stand on.
    private final class Wave {
        let root = CALayer(), left = CALayer(), right = CALayer()
        let played = CALayer(), coming = CALayer()
        let key: String
        var count: Int
        var tint = ""

        init(key: String, count: Int) {
            self.key = key
            self.count = count
            for clip in [left, right] {
                clip.masksToBounds = true
                root.addSublayer(clip)
            }
            left.addSublayer(played)
            right.addSublayer(coming)
            for strip in [played, coming] {
                strip.anchorPoint = .zero
                strip.contentsGravity = .resize
                strip.magnificationFilter = .linear
            }
        }
        var strips: [CALayer] { [played, coming] }
    }

    private static let folded: CGFloat = 0.12
    private static let gone: CGFloat = 0.02
    private let fade = CAGradientLayer()
    private var wave: Wave?
    private var last: Inputs?
    private var size: CGSize = .zero
    /// Where the running motion started, to tell drift from a new place.
    private var anchor: (head: Double, time: CFTimeInterval, speed: Double)?
    private var timed = true
    private var shape: CGFloat?
    /// A new song not yet whole: when it was first seen, and when it last changed.
    private var pending: (identity: String, first: CFTimeInterval, changed: CFTimeInterval)?
    private var settle: DispatchWorkItem?
    private static let stillFor: CFTimeInterval = 0.3
    private static let waitAtMost: CFTimeInterval = 1.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        layer?.mask = fade
    }

    required init?(coder: NSCoder) { nil }

    /// Clicks belong to the SwiftUI band around it, which seeks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != size, let last else { return }
        size = bounds.size
        wave = nil
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        anchor = nil
        update(last)
    }

    func update(_ input: Inputs) {
        last = input
        guard bounds.width > 0, bounds.height > 0, let host = layer else { return }
        size = bounds.size
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let now = CACurrentMediaTime()
        let animate = !input.reduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameFade()

        // A new song: the old wave folds into its line and goes, the new one
        // grows out of the same line. A player names a new song in pieces,
        // the title first and its length a moment later, so the new wave
        // waits, folded, until the song has stood still for a moment; it
        // grows once, already in its place.
        var arrived = false
        let identity = "\(input.key)|\(input.timed)|\(input.heights.count)"
        if wave?.key != identity {
            if wave != nil, !settled(identity, timed: input.timed, now: now) {
                if let wave, shape != Self.gone {
                    fold(wave, to: Self.gone, animate: animate, growing: false)
                    shape = Self.gone
                }
                CATransaction.commit()
                return
            }
            pending = nil
            settle?.cancel()
            timed = input.timed
            let next = Wave(key: identity, count: input.heights.count)
            next.coming.contents = Self.strip(input.heights, colour: .white, alpha: 0.42,
                                              height: bounds.height, scale: scale)
            frame(next)
            host.addSublayer(next.root)
            if let old = wave { retire(old, animate: animate) }
            wave = next
            anchor = nil
            arrived = true
        }
        guard let wave else { CATransaction.commit(); return }

        // The cover's colour often lands a moment after the song; it fades in
        // over the bars rather than swapping them.
        let rgb = input.tint.usingColorSpace(.sRGB) ?? input.tint
        let tint = "\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent)|\(bounds.height)|\(scale)"
        if wave.tint != tint {
            if !wave.tint.isEmpty, animate {
                let swap = CABasicAnimation(keyPath: "contents")
                swap.duration = 0.4
                wave.played.add(swap, forKey: "tint")
            }
            wave.tint = tint
            wave.played.contents = Self.strip(input.heights, colour: rgb, alpha: 1, height: bounds.height, scale: scale)
        }

        // A running motion already shows where the song is. A slow player
        // answers a click late, so up to a second and a half off is its
        // delay, not a new place, and is left alone; anything more is set at
        // once, never eased.
        let slack = max(0.35, input.speed * 1.5)
        let drifted = anchor.map { abs($0.head + (now - $0.time) * $0.speed - input.head) > slack } ?? true
        if anchor?.speed != input.speed || drifted {
            anchor = (input.head, now, input.speed)
            move(wave, head: input.head, speed: input.speed)
        }

        let target: CGFloat = input.skipping && !arrived ? Self.gone
            : input.playing || !input.timed ? 1 : Self.folded
        if shape != target || arrived {
            fold(wave, to: target, animate: animate, growing: arrived)
            shape = target
        }
        CATransaction.commit()
    }

    /// Whether a new song has stopped changing long enough to draw; if not,
    /// asks again when it might have.
    private func settled(_ identity: String, timed: Bool, now: CFTimeInterval) -> Bool {
        if pending?.identity != identity {
            pending = (identity, pending?.first ?? now, now)
        }
        guard let pending else { return true }
        // A song with no length may still get one; wait longer for it.
        let still = now - pending.changed >= (timed ? Self.stillFor : Self.waitAtMost)
        if still || now - pending.first >= Self.waitAtMost * 2 { return true }
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let last = self.last else { return }
            self.update(last)
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        return false
    }

    private func frameFade() {
        fade.frame = bounds
        let edge = Double(min(0.45, NotchLockScreenWave.fade / max(1, bounds.width)))
        fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
    }

    /// Layer space runs up from the bottom unless the host flips it.
    private var baselineAnchor: CGFloat {
        let base = NotchLockScreenWaveBand.baseline(bounds.height) / bounds.height
        return layer?.isGeometryFlipped == true ? base : 1 - base
    }

    private func frame(_ wave: Wave) {
        let width = bounds.width, height = bounds.height, mid = (width / 2).rounded()
        wave.root.anchorPoint = CGPoint(x: 0.5, y: baselineAnchor)
        wave.root.bounds = bounds
        wave.root.position = CGPoint(x: width / 2, y: height * baselineAnchor)
        wave.left.frame = CGRect(x: 0, y: 0, width: timed ? mid : 0, height: height)
        wave.right.frame = timed ? CGRect(x: mid, y: 0, width: width - mid, height: height) : bounds
        let song = CGRect(x: 0, y: 0, width: CGFloat(wave.count) * NotchLockScreenWave.step, height: height)
        wave.played.bounds = song
        wave.coming.bounds = song
    }

    /// Puts the playhead on `head` and, while playing, runs the strips to
    /// the song's end.
    private func move(_ wave: Wave, head: Double, speed: Double) {
        let mid = (bounds.width / 2).rounded(), step = NotchLockScreenWave.step
        let start = mid - CGFloat(head) * step
        let targets = [start, timed ? start - mid : start]
        let remaining = Double(wave.count) - head
        for (strip, target) in zip(wave.strips, targets) {
            strip.removeAnimation(forKey: "run")
            strip.position = CGPoint(x: target, y: 0)
            guard speed > 0, remaining > 0 else { continue }
            let travel = CGFloat(remaining) * step
            strip.position.x = target - travel
            let run = CABasicAnimation(keyPath: "position.x")
            run.fromValue = target
            run.toValue = target - travel
            run.duration = remaining / speed
            run.timingFunction = CAMediaTimingFunction(name: .linear)
            strip.add(run, forKey: "run")
        }
    }

    /// Paused, the bars fold down toward their line, as SoundCloud's do;
    /// playing, they stand up again.
    private func fold(_ wave: Wave, to target: CGFloat, animate: Bool, growing: Bool) {
        let open = target > Self.folded
        let shown = growing ? Self.gone : (wave.root.presentation()?.transform.m22 ?? wave.root.transform.m22)
        wave.root.transform = CATransform3DMakeScale(1, target, 1)
        guard animate, abs(shown - target) > 0.001 else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale.y")
        spring.fromValue = shown
        spring.toValue = target
        spring.mass = 1
        spring.stiffness = open ? 170 : 260
        spring.damping = open ? 19 : 30
        spring.duration = spring.settlingDuration
        wave.root.add(spring, forKey: "fold")
        if target == Self.gone {
            spring.stiffness = 300
            spring.damping = 34
            spring.duration = spring.settlingDuration
        }
        if growing {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.25
            wave.root.add(appear, forKey: "appear")
        }
    }

    private func retire(_ old: Wave, animate: Bool) {
        guard animate else { old.root.removeFromSuperlayer(); return }
        let shown = old.root.presentation()?.transform.m22 ?? old.root.transform.m22
        old.root.removeAnimation(forKey: "fold")
        let fold = CABasicAnimation(keyPath: "transform.scale.y")
        fold.fromValue = shown
        fold.toValue = 0.02
        let dim = CABasicAnimation(keyPath: "opacity")
        dim.fromValue = 1
        dim.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fold, dim]
        group.duration = 0.28
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        old.root.transform = CATransform3DMakeScale(1, 0.02, 1)
        old.root.opacity = 0
        CATransaction.setCompletionBlock { old.root.removeFromSuperlayer() }
        old.root.add(group, forKey: "retire")
    }

    /// Every bar of the song standing on a line over its reflection, half as
    /// tall and fainter, a hairline of air between the two.
    private static func strip(_ heights: [Double], colour: NSColor, alpha: CGFloat,
                              height: CGFloat, scale: CGFloat) -> CGImage? {
        let step = NotchLockScreenWave.step, bar = NotchLockScreenWave.barWidth
        let width = CGFloat(heights.count) * step
        guard height > 0, width > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int((width * scale).rounded(.up)),
                                      height: Int((height * scale).rounded(.up)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-down, as the band is laid out.
        context.translateBy(x: 0, y: height * scale)
        context.scaleBy(x: scale, y: -scale)
        let base = NotchLockScreenWaveBand.baseline(height), tall = base - 1
        let top = CGMutablePath(), low = CGMutablePath()
        for (index, value) in heights.enumerated() {
            let x = CGFloat(index) * step, length = max(bar, CGFloat(value) * tall)
            top.addRoundedRect(in: CGRect(x: x, y: base - length, width: bar, height: length),
                               cornerWidth: bar / 2, cornerHeight: bar / 2)
            low.addRoundedRect(in: CGRect(x: x, y: base + NotchLockScreenWaveBand.gap, width: bar,
                                          height: max(bar, length * NotchLockScreenWaveBand.echo)),
                               cornerWidth: bar / 2, cornerHeight: bar / 2)
        }
        let rgb = colour.usingColorSpace(.sRGB) ?? colour
        context.setFillColor(rgb.withAlphaComponent(alpha).cgColor)
        context.addPath(top); context.fillPath()
        context.setFillColor(rgb.withAlphaComponent(alpha * 0.4).cgColor)
        context.addPath(low); context.fillPath()
        return context.makeImage()
    }
}
