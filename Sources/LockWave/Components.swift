// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct NotchButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    var lifts = true
    /// A light wash under the pointer.
    var highlights = true
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let active = enabled && hovered
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.white.opacity(active && highlights ? 0.09 : 0))
                    .allowsHitTesting(false)
            }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(reduceMotion || !lifts ? 1
                         : configuration.isPressed ? 0.965 : (active ? 1.022 : 1))
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7),
                       value: configuration.isPressed)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.75), value: hovered)
            .onHover { hovered = $0 }
    }
}

extension NotchArtworkTint {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

struct NotchArtwork: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.black.overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.3, weight: .light))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.19, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.19, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

/// The few words LockWave shows, in Russian or English by the system language.
enum Strings {
    static let russian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
    static var nowPlaying: String { russian ? "Сейчас играет" : "Now Playing" }
    static var previous: String { russian ? "Предыдущий трек" : "Previous" }
    static var playPause: String { russian ? "Воспроизвести или пауза" : "Play or pause" }
    static var next: String { russian ? "Следующий трек" : "Next" }
    static var enabled: String { russian ? "Показывать на экране блокировки" : "Show on the lock screen" }
    static var atLogin: String { russian ? "Открывать при входе" : "Open at login" }
    static var preview: String { russian ? "Показать сейчас (5 с)" : "Preview now (5 s)" }
    static var about: String { russian ? "О LockWave" : "About LockWave" }
    static var quit: String { russian ? "Выйти" : "Quit" }
}
