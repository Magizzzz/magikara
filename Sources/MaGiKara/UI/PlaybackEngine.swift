import Foundation
import AVFoundation
import Combine
import MaGiKaraKit

/// 播放与播放头同步（RD §2：视频预览、播放/暂停、时间码、播放头同步）。
final class PlaybackEngine: ObservableObject {

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var duration: Double = 0
    @Published var volume: Double = 1.0 {
        didSet { applyMasterVolume() }
    }

    let player = AVPlayer()

    /// 是否正在 seek。seek 完成前不接受时间观察者的回调 ——
    /// 否则「前往开头」会先跳回 0，随后被 AVPlayer 尚未完成的旧时间覆盖回结尾，
    /// 界面看起来就像「点开头跳到了结尾」。
    private var isSeeking = false
    /// 连续 seek 时只认最后一次完成回调
    private var seekGeneration = 0

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var audioTrackMuted = false
    private var vocalTrackMuted = false
    /// 分离后的素材；非 nil 表示正在用「画面 + 伴奏 + 人声」的合成播放。
    private var separatedSources: SeparatedSources?
    private var isUsingSeparatedStems: Bool { separatedSources != nil }

    private struct SeparatedSources {
        var mediaURL: URL
        var vocalURL: URL
        var instrumentalURL: URL
    }

    init() {
        player.actionAtItemEnd = .pause
        installTimeObserver()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let t = CMTimeGetSeconds(time)
            // seek 未完成前忽略观察者回调，避免时间回跳
            if t.isFinite, !self.isSeeking {
                self.currentTime = t
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            self?.isPlaying = false
        }
    }

    func load(url: URL, audioMuted: Bool = false) {
        separatedSources = nil
        audioTrackMuted = audioMuted
        vocalTrackMuted = false
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        applyMasterVolume()
        observe(item: item)
        currentTime = 0
        isPlaying = false
    }

    /// 用同一条 AVPlayer 时间轴合成画面与分离出的双音轨，保证预览播放完全同步。
    func loadSeparated(url: URL,
                       vocalURL: URL,
                       instrumentalURL: URL,
                       audioMuted: Bool,
                       vocalMuted: Bool) throws {
        let sources = SeparatedSources(mediaURL: url, vocalURL: vocalURL, instrumentalURL: instrumentalURL)
        let item = try Self.makeSeparatedItem(sources, audioMuted: audioMuted, vocalMuted: vocalMuted)
        separatedSources = sources
        audioTrackMuted = audioMuted
        vocalTrackMuted = vocalMuted
        player.replaceCurrentItem(with: item)
        applyMasterVolume()
        observe(item: item)
        currentTime = 0
        isPlaying = false
    }

    /// 合成只包含**未静音**音轨的播放项。
    ///
    /// 不用 AVAudioMix 调音量来静音：播放中途替换 audioMix 时，AVPlayer 已经缓冲好的音频
    /// 不会按新音量重新处理，用户点了「人声静音」仍然能听到人声。被静音的轨直接不放进合成，
    /// 就不可能再出声。
    private static func makeSeparatedItem(_ sources: SeparatedSources,
                                          audioMuted: Bool,
                                          vocalMuted: Bool) throws -> AVPlayerItem {
        let source = AVURLAsset(url: sources.mediaURL)
        let composition = AVMutableComposition()

        if let sourceVideo = source.tracks(withMediaType: .video).first,
           let destination = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
            try destination.insertTimeRange(sourceVideo.timeRange, of: sourceVideo, at: .zero)
            destination.preferredTransform = sourceVideo.preferredTransform
        }

        var stems: [URL] = []
        if !audioMuted { stems.append(sources.instrumentalURL) }
        if !vocalMuted { stems.append(sources.vocalURL) }
        // 两条都静音且没有画面时，仍需一条音轨撑起时间轴；此时由 player.volume = 0 保证无声。
        if stems.isEmpty, composition.tracks(withMediaType: .video).isEmpty {
            stems.append(sources.instrumentalURL)
        }
        for url in stems {
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = asset.tracks(withMediaType: .audio).first,
                  let destination = composition.addMutableTrack(withMediaType: .audio,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw PlaybackCompositionError.missingAudio(url.lastPathComponent)
            }
            try destination.insertTimeRange(sourceTrack.timeRange, of: sourceTrack, at: .zero)
        }
        guard !composition.tracks.isEmpty else { throw PlaybackCompositionError.noSeparatedAudio }
        DebugLog.write("playback: 分离合成 伴奏\(audioMuted ? "静音" : "播放") 人声\(vocalMuted ? "静音" : "播放") 音轨数=\(composition.tracks(withMediaType: .audio).count)")
        return AVPlayerItem(asset: composition)
    }

    private func observe(item: AVPlayerItem) {
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            let d = CMTimeGetSeconds(item.duration)
            if d.isFinite, d > 0 {
                DispatchQueue.main.async { self?.duration = d }
            }
        }
    }

    func setTrackMutes(audioMuted: Bool, vocalMuted: Bool) {
        let changed = audioMuted != audioTrackMuted || vocalMuted != vocalTrackMuted
        audioTrackMuted = audioMuted
        vocalTrackMuted = vocalMuted
        if changed, let sources = separatedSources {
            // 换成只含未静音音轨的新播放项，回到原来的时间点，原来在播就接着播。
            let time = player.currentTime()
            let wasPlaying = isPlaying
            do {
                let item = try Self.makeSeparatedItem(sources, audioMuted: audioMuted, vocalMuted: vocalMuted)
                player.replaceCurrentItem(with: item)
                observe(item: item)
                let seconds = CMTimeGetSeconds(time)
                seek(to: seconds.isFinite ? seconds : currentTime)
                if wasPlaying { player.play() }
            } catch {
                DebugLog.write("playback: 重建分离合成失败 \(error.localizedDescription)")
            }
        }
        applyMasterVolume()
    }

    private func applyMasterVolume() {
        let muteFactor: Double
        if isUsingSeparatedStems {
            muteFactor = (audioTrackMuted && vocalTrackMuted) ? 0 : 1
        } else {
            muteFactor = audioTrackMuted ? 0 : 1
        }
        player.volume = Float(max(0, min(1, volume)) * muteFactor)
    }

    func clear() {
        player.replaceCurrentItem(with: nil)
        separatedSources = nil
        audioTrackMuted = false
        vocalTrackMuted = false
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    func play() {
        guard player.currentItem != nil else { return }
        // 播放到结尾后再按播放，从头开始
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(to t: Double) {
        let clamped = max(0, duration > 0 ? min(t, duration) : t)
        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            // 只处理最后一次 seek 的完成回调
            guard generation == self.seekGeneration else { return }
            self.isSeeking = false
            self.currentTime = clamped
        }
    }

    /// 精确 seek 并等待完成（供回归测试使用）
    func seekAndWait(to t: Double) async -> Double {
        let clamped = max(0, duration > 0 ? min(t, duration) : t)
        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        currentTime = clamped
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                cont.resume()
            }
        }
        if generation == seekGeneration {
            isSeeking = false
            currentTime = clamped
        }
        return currentTime
    }

    /// 按小步长移动播放头（←/→）
    func step(by delta: Double) {
        pause()
        seek(to: currentTime + delta)
    }

    func setDuration(_ d: Double) {
        if d > 0 { duration = d }
    }
}

private enum PlaybackCompositionError: LocalizedError {
    case noSeparatedAudio
    case missingAudio(String)

    var errorDescription: String? {
        switch self {
        case .noSeparatedAudio: return "分离音轨未能载入"
        case .missingAudio(let name): return "找不到音轨音频：\(name)"
        }
    }
}
