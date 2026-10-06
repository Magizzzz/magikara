import Foundation

/// 面向普通播放器/剪辑软件的轻量歌词导出。
///
/// ASS 仍然承载完整的逐字扫色、假名与双行布局；LRC/SRT 只输出句级时间，
/// 用于手机播放器、剪辑软件导入和快速分享，不把高级格式的复杂度带进主流程。
public enum LyricTextExporter {

    public static func lrc(project: KaraProject) -> String {
        project.sortedLines
            .filter { $0.singEnd > $0.singStart }
            .map { "[\(lrcTime($0.singStart))]\($0.displayText)" }
            .joined(separator: "\n") + "\n"
    }

    public static func srt(project: KaraProject) -> String {
        var blocks: [String] = []
        for (index, line) in project.sortedLines.enumerated() where line.singEnd > line.singStart {
            let start = min(max(0, line.displayStart), line.singStart)
            let end = max(line.singEnd, line.displayEnd)
            blocks.append("\(index + 1)\n\(srtTime(start)) --> \(srtTime(end))\n\(line.displayText)\n")
        }
        return blocks.joined(separator: "\n")
    }

    public static func lrcTime(_ seconds: Double) -> String {
        let safe = max(0, seconds)
        let minutes = Int(safe / 60)
        let remaining = safe - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remaining)
    }

    public static func srtTime(_ seconds: Double) -> String {
        let totalMillis = Int((max(0, seconds) * 1000).rounded())
        let hours = totalMillis / 3_600_000
        let minutes = (totalMillis / 60_000) % 60
        let secs = (totalMillis / 1000) % 60
        let millis = totalMillis % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}
