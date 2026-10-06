import Foundation

/// 轨道标识（RD §3.3 的固定层级：视频 / 音频 / 假名 / 歌词）。
public enum TrackID: String, Codable, Sendable, CaseIterable {
    case video
    case audio
    case vocal
    /// 倒计时轨道：放倒计时色块，位于音频轨与歌词轨之间。
    case countdown
    case rubyUpper
    case lyricUpper
    case rubyLower
    case lyricLower

    public var displayName: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        case .vocal: return "人声"
        case .countdown: return "倒计时"
        case .rubyUpper: return "假名 · 上行"
        case .lyricUpper: return "歌词 · 上行"
        case .rubyLower: return "假名 · 下行"
        case .lyricLower: return "歌词 · 下行"
        }
    }

    /// 是不是可编辑歌词的轨道（视频/音频轨只做显隐与静音）
    public var isEditableContent: Bool {
        self == .lyricUpper || self == .lyricLower
    }
}

/// 单条轨道的状态（只保留显隐 / 锁定 / 静音，不做嵌套 —— 用户明确要求）。
public struct TrackState: Codable, Sendable, Equatable, Hashable {
    public var isVisible: Bool = true
    /// 锁定后该轨道不可编辑（不能移动 / 修剪 / 分割 / 删除）
    public var isLocked: Bool = false
    public var isMuted: Bool = false

    public init(isVisible: Bool = true, isLocked: Bool = false, isMuted: Bool = false) {
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.isMuted = isMuted
    }
}

/// 所有轨道状态的集合，随工程保存。
public struct TrackStateStore: Codable, Sendable, Equatable {
    public var states: [String: TrackState] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        states = try c.decodeIfPresent([String: TrackState].self, forKey: .states) ?? [:]
    }

    public subscript(track: TrackID) -> TrackState {
        get { states[track.rawValue] ?? TrackState() }
        set { states[track.rawValue] = newValue }
    }

    public func isLocked(_ track: TrackID) -> Bool { self[track].isLocked }
    public func isVisible(_ track: TrackID) -> Bool { self[track].isVisible }
    public func isMuted(_ track: TrackID) -> Bool { self[track].isMuted }

    /// 某条歌词句所在轨道是否被锁定。**锁定是编辑的唯一闸门**，
    /// UI 与命令层都走这一个判断，避免有的入口漏判。
    public func isLocked(line: LyricLine) -> Bool {
        isLocked(line.lane == .upper ? TrackID.lyricUpper : TrackID.lyricLower)
    }

    public mutating func toggleVisible(_ track: TrackID) { self[track].isVisible.toggle() }
    public mutating func toggleLocked(_ track: TrackID) { self[track].isLocked.toggle() }
    public mutating func toggleMuted(_ track: TrackID) { self[track].isMuted.toggle() }
}
