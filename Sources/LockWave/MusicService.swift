// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// LockWave: the music half of Vorssaint's NotchMusicService, without its
// lyrics, queue, source picker and Apple Event automation.

import AppKit
import Combine

/// What is playing, read through the Now Playing adapter: perl, a platform
/// binary, loads the adapter library, and MediaRemote answers it where it no
/// longer answers an app (macOS 15.4 and later). Commands go back to the
/// player through the same process.
final class NotchMusicService: ObservableObject {
    static let shared = NotchMusicService()
    typealias Command = NotchPlaybackCommand

    @Published private(set) var playback: NotchPlayback?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkTint: NotchArtworkTint?
    /// Kept for the views written against Vorssaint's service; commands here
    /// always go straight to the player, so none waits.
    @Published private(set) var commandPending = false

    private var process: Process?
    private var input: Pipe?
    private var generation = UUID()
    private var wanted = false
    private var restarts = 0
    private var gapWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "lockwave.music", qos: .utility)
    private lazy var writer = NotchMusicCommandWriter { [queue = self.queue] action in queue.async(execute: action) }

    private init() {}

    private static var adapter: [String]? {
        guard let script = Bundle.main.url(forResource: "now-playing", withExtension: "pl"),
              let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("libLockWaveNowPlaying.dylib"),
              FileManager.default.fileExists(atPath: library.path) else { return nil }
        return [script.path, library.path]
    }

    func start() {
        guard !wanted else { return }
        wanted = true
        restarts = 0
        launch()
    }

    func stop() {
        wanted = false
        generation = UUID()
        writer.stop()
        gapWork?.cancel()
        gapWork = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
    }

    private func launch() {
        guard wanted, process == nil, let arguments = Self.adapter else { return }
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        // A child can exit between a check and a write; keep that an error.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { return }
        let requested = UUID()
        generation = requested
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // Every player, browsers included: on the lock screen any song counts.
        process.arguments = arguments + ["watch_all"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        var cachedArtwork: Data?
        var cachedImage: NSImage?
        var cachedTint: NotchArtworkTint?
        let reader = LineReader { [weak self] line in
            let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            // Command receipts and the adapter's own requests carry no song.
            if reply?["sent"] != nil || reply?["validationRequest"] != nil
                || reply?["queueRequest"] != nil || reply?["queueAction"] != nil { return }
            let next = NotchPlayback.decode(line, previousArtwork: cachedArtwork,
                                           commandContext: reply.flatMap(NotchPlaybackContext.init(reply:)),
                                           canSendCommandsDirectly: reply?["canSendCommandsDirectly"] as? Bool == true)
            if cachedArtwork != next?.track.artworkData {
                cachedArtwork = next?.track.artworkData
                cachedImage = cachedArtwork.flatMap(NSImage.init(data:))
                cachedTint = cachedImage.flatMap(Self.tint(of:))
            }
            let image = cachedImage, tint = cachedTint
            DispatchQueue.main.async {
                guard let self, self.generation == requested else { return }
                self.receive(next, artwork: image, tint: tint)
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.append(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == requested else { return }
                self.process = nil
                self.input = nil
                self.writer.stop()
                // A crashed adapter comes back, but not in a tight loop.
                guard self.wanted, self.restarts < 5 else { return }
                self.restarts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(self.restarts)) { self.launch() }
            }
        }
        do {
            try process.run()
            writer.start()
            self.process = process
            self.input = input
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
        }
    }

    /// A player between songs reports nothing for a moment; the last song
    /// stays for that moment instead of the screen emptying and refilling.
    private func receive(_ next: NotchPlayback?, artwork: NSImage?, tint: NotchArtworkTint?) {
        gapWork?.cancel()
        gapWork = nil
        guard let next else {
            guard playback != nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.playback = nil
                self?.artwork = nil
                self?.artworkTint = nil
            }
            gapWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchPlayback.gapGracePeriod, execute: work)
            return
        }
        playback = next
        // A song whose cover has not arrived yet keeps the last one a moment.
        if artwork != nil || self.artwork == nil || next.track.artworkData != nil {
            self.artwork = artwork
            artworkTint = tint
        }
    }

    // MARK: Commands

    func seek(to position: Double, in track: RadialNowPlayingSnapshot, context: NotchPlaybackContext?) {
        guard let playback, playback.track == track, let context, context == playback.commandContext,
              let position = playback.seekPosition(position, allowed: canSeek) else { return }
        send(.seek(position), context: context)
    }

    @discardableResult
    func send(_ command: Command, context: NotchPlaybackContext?) -> Bool {
        guard let playback, playback.canSendCommandsDirectly, process?.isRunning == true, let input else { return false }
        if command.requiresPlaybackContext {
            guard gapWork == nil, let context, context == playback.commandContext else { return false }
        }
        return writer.submit(command, context: context, write: { data in
            try input.fileHandleForWriting.write(contentsOf: data)
        }, failed: {})
    }

    var canSeek: Bool {
        guard let playback, playback.hasPosition, playback.duration > 0 else { return false }
        return playback.canSendCommandsDirectly && playback.canSeek
    }

    func canPerform(_ command: Command) -> Bool {
        guard let playback, playback.commandContext != nil, playback.canSendCommandsDirectly else { return false }
        if case .seek = command { return canSeek }
        return !lacksTrackSkipping(command)
    }

    /// The player itself says it cannot skip this way, so the button is hidden.
    func lacksTrackSkipping(_ command: Command) -> Bool {
        guard let playback, playback.canSendCommandsDirectly else { return false }
        switch command {
        case .next: return playback.canSkipNext == false
        case .previous: return playback.canSkipPrevious == false
        default: return false
        }
    }

    /// The cover's colour from one averaged pixel.
    private static func tint(of image: NSImage) -> NotchArtworkTint? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return NotchArtworkTint.from(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}

/// Splits the adapter's output into lines off the main thread, dropping a
/// runaway line rather than growing without bound.
private final class LineReader {
    private let queue = DispatchQueue(label: "lockwave.music.reader", qos: .utility)
    private var buffer = Data()
    private let receive: (Data) -> Void
    init(receive: @escaping (Data) -> Void) { self.receive = receive }

    func append(_ data: Data) {
        queue.sync {
            buffer.append(data)
            if buffer.count > RadialNowPlayingSupport.maximumAdapterReplyBytes {
                buffer.removeAll(keepingCapacity: false)
                return
            }
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                receive(line)
            }
        }
    }
}
