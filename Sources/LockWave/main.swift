// SPDX-License-Identifier: GPL-3.0-or-later
// LockWave — the lock screen music player from Vorssaint, on its own.

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let enabledKey = "showOnLockScreen"

    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(locked), name: .init("com.apple.screenIsLocked"), object: nil)
        center.addObserver(self, selector: #selector(unlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
        // The first launch registers itself, so the player is there after a restart.
        if UserDefaults.standard.object(forKey: "askedLogin") == nil {
            UserDefaults.standard.set(true, forKey: "askedLogin")
            try? SMAppService.mainApp.register()
        }
        buildMenu()
    }

    @objc private func locked() {
        guard enabled else { return }
        LockScreenController.shared.show()
    }

    @objc private func unlocked() {
        LockScreenController.shared.hide()
    }

    // MARK: Menu

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "LockWave")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleEnabled() { enabled.toggle() }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
    }

    @objc private func preview() { LockScreenController.shared.preview() }

    @objc private func about() {
        NSWorkspace.shared.open(URL(string: "https://github.com/23ag1/lockwave")!)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Built as it opens, so the checkmarks are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "LockWave", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let show = NSMenuItem(title: Strings.enabled, action: #selector(toggleEnabled), keyEquivalent: "")
        show.state = enabled ? .on : .off
        show.target = self
        menu.addItem(show)
        let login = NSMenuItem(title: Strings.atLogin, action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)
        let preview = NSMenuItem(title: Strings.preview, action: #selector(preview), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)
        menu.addItem(.separator())
        let about = NSMenuItem(title: Strings.about, action: #selector(about), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: Strings.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
