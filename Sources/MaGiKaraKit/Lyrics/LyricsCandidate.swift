import Foundation

public enum LyricsTextSource: String, Codable, Sendable, Equatable {
    case synchronized
    case plain
}

/// Provenance for the text transcript. Alignment timestamps always come from local audio.
public struct LyricsSourceInfo: Codable, Sendable, Equatable {
    public var provider: String
    public var recordID: Int
    public var trackName: String
    public var artistName: String
    public var albumName: String?
    public var sourceDurationSec: Double?
    public var textSource: LyricsTextSource
    public var importedAt: Date

    public init(provider: String = "LRCLIB",
                recordID: Int,
                trackName: String,
                artistName: String,
                albumName: String?,
                sourceDurationSec: Double?,
                textSource: LyricsTextSource,
                importedAt: Date = Date()) {
        self.provider = provider
        self.recordID = recordID
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.sourceDurationSec = sourceDurationSec
        self.textSource = textSource
        self.importedAt = importedAt
    }
}

/// A text-only candidate. Synchronized source timestamps are deliberately not exposed here.
public struct LyricsCandidate: Sendable, Equatable, Identifiable {
    public var id: Int
    public var trackName: String
    public var artistName: String
    public var albumName: String?
    public var durationSec: Double?
    public var durationDeltaSec: Double?
    public var lyricsText: String
    public var textSource: LyricsTextSource
    /// 是否是按用户填的歌手名匹配到的。LRCLIB 里歌手多是英文写法，填中文/日文名常常搜不到；
    /// 此时会自动改为只按歌曲名搜索，这种结果为 false，界面会提示用户核对歌手。
    public var matchesRequestedArtist: Bool

    public init(id: Int,
                trackName: String,
                artistName: String,
                albumName: String?,
                durationSec: Double?,
                durationDeltaSec: Double?,
                lyricsText: String,
                textSource: LyricsTextSource,
                matchesRequestedArtist: Bool = true) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.durationSec = durationSec
        self.durationDeltaSec = durationDeltaSec
        self.lyricsText = lyricsText
        self.textSource = textSource
        self.matchesRequestedArtist = matchesRequestedArtist
    }

    public func sourceInfo(importedAt: Date = Date()) -> LyricsSourceInfo {
        LyricsSourceInfo(recordID: id,
                         trackName: trackName,
                         artistName: artistName,
                         albumName: albumName,
                         sourceDurationSec: durationSec,
                         textSource: textSource,
                         importedAt: importedAt)
    }
}
