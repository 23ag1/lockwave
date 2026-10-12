// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// LockWave: the player half of Vorssaint's NotchLockScreenService.

import AppKit
import SwiftUI

/// macOS draws the lock screen's date, clock and login controls in one window
/// over the whole display, so their room is kept by measure. On macOS 26 and
/// 27 the date and clock end 236 points from the top of a 956-point display,
/// and the name, picture, password field and hint take the lowest 218.
enum LockScreenLayout {
    /// A taller display draws a larger clock.
    static func clockBottom(screenHeight: CGFloat) -> CGFloat { max(236, screenHeight * 0.247) }
    static let rowGap: CGFloat = 18
    static let rowHeight: CGFloat = 30
    /// From the bottom of the display to the player.
    static let loginClearance: CGFloat = 250
    static let minimumPlayerHeight: CGFloat = 190
    /// The level of the system's lock screen notifications, over the lock screen.
    static let spaceLevel: Int32 = 400

    /// Between the clock and the login controls, from edge to edge.
    static func playerFrame(in screen: CGRect) -> CGRect? {
        guard [screen.minX, screen.minY, screen.width, screen.height].allSatisfy(\.isFinite),
              screen.width >= 492, screen.height > 0 else { return nil }
        let top = screen.maxY - clockBottom(screenHeight: screen.height) - rowGap - rowHeight - 10
        let bottom = screen.minY + loginClearance
        guard top - bottom >= minimumPlayerHeight else { return nil }
        return CGRect(x: screen.minX, y: bottom, width: screen.width, height: top - bottom)
    }

    /// macOS draws the clock and the password field on the main display.
    static func mainScreen() -> NSScreen? {
        let main = CGMainDisplayID()
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == main
        } ?? NSScreen.screens.first
    }
}

/// Shows the player over the lock screen while the Mac is locked and
/// something is playing, and takes it away as the Mac unlocks.
final class LockScreenController {
    static let shared = LockScreenController()

    private var space: NotchOverlaySpace?
    private var panel: LockScreenPanel?
    private var shownFrame: CGRect?
    private var screenObserver: NSObjectProtocol?
    private var previewWork: DispatchWorkItem?

    private init() {}

    var isShowing: Bool { space != nil }

    func show() {
        guard space == nil, let screen = LockScreenLayout.mainScreen()?.frame,
              let frame = LockScreenLayout.playerFrame(in: screen),
              let space = NotchOverlaySpace(absoluteLevel: LockScreenLayout.spaceLevel) else { return }
        NotchMusicService.shared.start()
        let panel = Self.makePanel(frame: frame, content: NotchLockScreenPlayer(size: frame.size))
        // Joined before it is first shown, the window belongs to this Space
        // alone and is drawn over the lock screen with it.
        space.add(panel)
        self.space = space
        self.panel = panel
        shownFrame = frame
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 1
        }
        // A display attached or rearranged while locked moves the clock and
        // the login controls; the player follows.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.space != nil,
                      let screen = LockScreenLayout.mainScreen()?.frame,
                      LockScreenLayout.playerFrame(in: screen) != self.shownFrame else { return }
                self.hide(fading: false)
                self.show()
            }
    }

    func hide(fading: Bool = true) {
        previewWork?.cancel()
        previewWork = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        guard let space, let panel else { return }
        self.space = nil
        self.panel = nil
        NotchMusicService.shared.stop()
        guard fading else {
            panel.orderOut(nil)
            space.close()
            return
        }
        // The lock screen is gone about 0.3 s after the unlock is announced;
        // the player leaves with it rather than lingering over the desktop.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            space.close()
        })
    }

    /// The player over the desktop for a few seconds, to see it without locking.
    func preview() {
        guard !isShowing else { return }
        show()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private static func makePanel<Content: View>(frame: CGRect, content: Content) -> LockScreenPanel {
        let panel = LockScreenPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = LockScreenHostingView(rootView: AnyView(content))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(frame, display: false)
        return panel
    }
}

/// Never key and never main: while the Mac is locked every keystroke belongs
/// to the password field, and a click on the player must not take it away.
final class LockScreenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // A window that never holds key focus would otherwise draw its glass as
    // an inactive window does, flat and dull.
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .unknown }
}

private final class LockScreenHostingView: NSHostingView<AnyView> {
    // The panel is never key, so a button has to answer the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
