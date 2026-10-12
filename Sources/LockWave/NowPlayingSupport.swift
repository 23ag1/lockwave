// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct RadialNowPlayingSnapshot: Equatable {
    let title: String?
    let artist: String?
    let album: String?
    let artworkData: Data?
    let appBundleIdentifier: String?
    let appPID: Int32?

    var radialLabel: String? {
        let parts = [title, artist].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

enum RadialNowPlayingState: Equatable {
    case loading
    case nothingPlaying
    case playing(RadialNowPlayingSnapshot)
}

enum RadialNowPlayingSupport {
    static let titleKey = "kMRMediaRemoteNowPlayingInfoTitle"
    static let artistKey = "kMRMediaRemoteNowPlayingInfoArtist"
    static let albumKey = "kMRMediaRemoteNowPlayingInfoAlbum"
    static let artworkDataKey = "kMRMediaRemoteNowPlayingInfoArtworkData"
    static let playbackRateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"

    private static let forbiddenScalars = CharacterSet.controlCharacters.union(.newlines)
    /// The one artwork cap. The adapter (`Sources/NowPlayingAdapter`) drops
    /// artwork above it before encoding, and the bridge's pipe cap is
    /// `maximumAdapterReplyBytes`, sized so the base64 line (4/3 of the bytes,
    /// so 16 MB) plus the other keys fits.
    static let maximumArtworkBytes = 12 * 1_024 * 1_024
    static let maximumAdapterReplyBytes = maximumArtworkBytes / 3 * 4 + 1_024 * 1_024

    static func playbackIsActive(remoteIsPlaying: Bool?, info: [String: Any]) -> Bool {
        if let remoteIsPlaying { return remoteIsPlaying }
        return (info[playbackRateKey] as? NSNumber)?.doubleValue ?? 0 > 0
    }

    /// One reply from the Now Playing adapter (`Resources/now-playing.pl`):
    /// the MediaRemote metadata keys it forwards, plus the owning app and the
    /// remote's own playing flag, in the shape `snapshot(info:...)` reads.
    struct AdapterReply {
        let info: [String: Any]
        let pid: Int32
        let displayID: String?
        let isPlaying: Bool?
    }

    /// Parses the adapter's JSON line, the last non-blank line of the run's
    /// output: stderr shares the pipe, so a perl warning (a locale it cannot
    /// set, say) can precede it. Artwork arrives base64-encoded under
    /// `artworkBase64` and is handed on as `artworkDataKey` bytes. An `error`
    /// key, a non-object or unreadable bytes read as no reply.
    static func adapterReply(from data: Data) -> AdapterReply? {
        let blank: Set<UInt8> = [0x20, 0x09, 0x0D]
        guard let line = data.split(separator: 0x0A).last(where: { $0.contains { !blank.contains($0) } }),
              let object = try? JSONSerialization.jsonObject(with: line),
              let fields = object as? [String: Any],
              fields["error"] == nil else { return nil }
        var info: [String: Any] = [:]
        for key in [titleKey, artistKey, albumKey] {
            if let value = fields[key] as? String { info[key] = value }
        }
        for key in [playbackRateKey, "kMRMediaRemoteNowPlayingInfoDuration",
                    "kMRMediaRemoteNowPlayingInfoElapsedTime"] {
            if let value = fields[key] as? NSNumber { info[key] = value }
        }
        if fields["artworkUnchanged"] as? Bool == true { info["artworkUnchanged"] = true }
        for key in ["canSeek", "canSkipNext", "canSkipPrevious"] {
            if let value = fields[key] as? Bool { info[key] = value }
        }
        if let identifier = fields["itemIdentifier"] as? String, !identifier.isEmpty,
           identifier.utf8.count <= 512, !identifier.contains("\0") { info["itemIdentifier"] = identifier }
        if let artwork = fields["artworkBase64"] as? String,
           let bytes = Data(base64Encoded: artwork), !bytes.isEmpty {
            info[artworkDataKey] = bytes
        }
        return AdapterReply(info: info,
                            pid: (fields["pid"] as? NSNumber)?.int32Value ?? 0,
                            displayID: fields["displayID"] as? String,
                            isPlaying: fields["isPlaying"] as? Bool)
    }

    static func snapshot(info: [String: Any],
                         isPlaying: Bool,
                         appBundleIdentifier: String?,
                         appPID: Int32) -> RadialNowPlayingSnapshot? {
        guard isPlaying else { return nil }
        let title = sanitizedText(info[titleKey])
        let artist = sanitizedText(info[artistKey])
        let album = sanitizedText(info[albumKey])
        let bundleIdentifier = sanitizedBundleIdentifier(appBundleIdentifier)
        let pid = appPID > 0 ? appPID : nil
        let artworkData = sanitizedArtworkData(info[artworkDataKey])
        guard title != nil || bundleIdentifier != nil || pid != nil else { return nil }
        return RadialNowPlayingSnapshot(title: title,
                                        artist: artist,
                                        album: album,
                                        artworkData: artworkData,
                                        appBundleIdentifier: bundleIdentifier,
                                        appPID: pid)
    }

    private static func sanitizedText(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clean = String(String.UnicodeScalarView(
            trimmed.unicodeScalars.filter { !forbiddenScalars.contains($0) }))
        return clean.isEmpty ? nil : String(clean.prefix(300))
    }

    private static func sanitizedBundleIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255,
              !trimmed.unicodeScalars.contains(where: { forbiddenScalars.contains($0) })
        else { return nil }
        return trimmed
    }

    private static func sanitizedArtworkData(_ value: Any?) -> Data? {
        guard let data = value as? Data, !data.isEmpty, data.count <= maximumArtworkBytes else {
            return nil
        }
        return data
    }
}
