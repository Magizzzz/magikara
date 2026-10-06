import Foundation

// MARK: - 解析后的 Ruby 绑定

/// 一个 token 内某段汉字最终使用的 Ruby 绑定。
///
/// 与 `JapaneseReadingService.RubyRun` 的区别：
/// - `isConfirmed == true` 表示来自用户人工覆盖；
/// - `readingStart < 0` 表示无法定位到整词读音里的偏移（时间窗退化为按位置）。
public struct ResolvedRubyBinding: Sendable, Equatable {
    public var surfaceStart: Int
    public var surfaceLength: Int
    public var reading: String
    /// 在整词 reading 里的字符偏移；-1 表示未知。
    public var readingStart: Int
    /// 是否人工确认（覆盖）过。
    public var isConfirmed: Bool

    public init(surfaceStart: Int,
                surfaceLength: Int,
                reading: String,
                readingStart: Int,
                isConfirmed: Bool) {
        self.surfaceStart = surfaceStart
        self.surfaceLength = surfaceLength
        self.reading = reading
        self.readingStart = readingStart
        self.isConfirmed = isConfirmed
    }
}

/// 一个 token 的 Ruby 解析结果。
public struct ResolvedRuby: Sendable, Equatable {
    public var bindings: [ResolvedRubyBinding]
    /// 自动对齐不可靠，需要人工确认（不会把整词读音盖到混合 token 上）。
    public var needsConfirmation: Bool

    public init(bindings: [ResolvedRubyBinding], needsConfirmation: Bool) {
        self.bindings = bindings
        self.needsConfirmation = needsConfirmation
    }

    public static let empty = ResolvedRuby(bindings: [], needsConfirmation: false)
}

/// 把「人工覆盖」与「自动对齐」合并成最终 Ruby 绑定。
///
/// 规则：
/// 1. 有实际读音的人工覆盖段优先，并标记为已确认；
/// 2. `reading` 为空的人工覆盖表示「显式删除」：该段不再显示自动注音；
/// 3. 其余未被覆盖/删除的段继续使用严格自动对齐；
/// 4. 自动对齐不可靠时，没有被人工覆盖的部分不生成，并标记待确认。
public enum RubyBindingResolver {

    public static func resolve(for token: LyricToken) -> ResolvedRuby {
        let overrides = token.sanitizedRubyOverrides()
        let auto = JapaneseReadingService.alignRuby(surface: token.surface, reading: token.reading ?? "")
        var bindings: [ResolvedRubyBinding] = []

        if !overrides.isEmpty {
            // 人工有读音的段：直接生效。
            for override in overrides where !override.reading.isEmpty {
                let autoStart = auto.runs
                    .first { $0.surfaceStart == override.surfaceStart }?
                    .readingStart ?? -1
                bindings.append(ResolvedRubyBinding(surfaceStart: override.surfaceStart,
                                                    surfaceLength: override.surfaceLength,
                                                    reading: override.reading,
                                                    readingStart: autoStart,
                                                    isConfirmed: true))
            }
            // 自动对齐里没有被人工覆盖/抑制区间压到的段继续保留。
            for run in auto.runs where !overlapsAny(run, overrides) {
                bindings.append(ResolvedRubyBinding(surfaceStart: run.surfaceStart,
                                                    surfaceLength: run.surfaceLength,
                                                    reading: run.reading,
                                                    readingStart: run.readingStart,
                                                    isConfirmed: false))
            }
        } else {
            bindings = auto.runs.map {
                ResolvedRubyBinding(surfaceStart: $0.surfaceStart,
                                    surfaceLength: $0.surfaceLength,
                                    reading: $0.reading,
                                    readingStart: $0.readingStart,
                                    isConfirmed: false)
            }
        }

        bindings.sort { $0.surfaceStart < $1.surfaceStart }
        return ResolvedRuby(bindings: bindings,
                            needsConfirmation: auto.needsConfirmation && overrides.isEmpty)
    }

    private static func overlapsAny(_ run: JapaneseReadingService.RubyRun,
                                    _ overrides: [RubyOverride]) -> Bool {
        overrides.contains { o in
            o.surfaceStart < run.surfaceStart + run.surfaceLength
                && run.surfaceStart < o.surfaceStart + o.surfaceLength
        }
    }
}

// MARK: - 字幕 Tab / 原位编辑用的槽位

/// 一个可人工编辑的 Ruby 槽位：对应 token 内一段连续汉字。
public struct RubyEditSlot: Identifiable, Equatable, Sendable {
    public var id: String
    public var tokenID: UUID
    public var tokenSurface: String
    /// 在 token.surface 里的字符起点与长度。
    public var surfaceStart: Int
    public var surfaceLength: Int
    /// 该槽位覆盖的汉字（通常 1 个字，熟字訓可能多字）。
    public var characters: String
    /// 当前生效的读音（人工覆盖优先，其次自动对齐）。
    public var reading: String
    public var isOverride: Bool
    public var isUnconfirmed: Bool

    public init(id: String,
                tokenID: UUID,
                tokenSurface: String,
                surfaceStart: Int,
                surfaceLength: Int,
                characters: String,
                reading: String,
                isOverride: Bool,
                isUnconfirmed: Bool) {
        self.id = id
        self.tokenID = tokenID
        self.tokenSurface = tokenSurface
        self.surfaceStart = surfaceStart
        self.surfaceLength = surfaceLength
        self.characters = characters
        self.reading = reading
        self.isOverride = isOverride
        self.isUnconfirmed = isUnconfirmed
    }
}

/// 把一句歌词拆成「逐汉字段」的可编辑 Ruby 槽位。
///
/// - 已有绑定时按绑定段生成槽位（熟字訓保持为一个槽位，如「素晴」→「すば」）；
/// - 自动对齐不可靠时按每个汉字段生成空读音槽位并标 `isUnconfirmed`，
///   让用户可以直接补，而不是让界面把整词读音悄悄盖上去。
public enum RubySlotBuilder {

    public static func slots(for line: LyricLine) -> [RubyEditSlot] {
        var slots: [RubyEditSlot] = []
        for token in line.tokens {
            let chars = Array(token.surface)
            guard chars.contains(where: { JapaneseText.isKanji($0) }) else { continue }
            let resolved = RubyBindingResolver.resolve(for: token)
            let overrides = token.sanitizedRubyOverrides()

            var ranges: [(start: Int, length: Int, reading: String,
                          isOverride: Bool, unconfirmed: Bool)] = []
            for binding in resolved.bindings {
                ranges.append((binding.surfaceStart, binding.surfaceLength, binding.reading,
                               binding.isConfirmed,
                               resolved.needsConfirmation && !binding.isConfirmed))
            }
            // 被显式删除的段：保留一个空槽位，用户可重新填写恢复。
            for override in overrides where override.reading.isEmpty {
                ranges.append((override.surfaceStart, override.surfaceLength, "", true, false))
            }
            // 自动对齐不可靠时：每个汉字段生成空槽位，允许直接人工补。
            for run in JapaneseReadingService.kanjiRuns(in: token.surface) {
                let covered = ranges.contains {
                    overlaps($0.start, $0.length, run.surfaceStart, run.surfaceLength)
                }
                if !covered {
                    ranges.append((run.surfaceStart, run.surfaceLength, "", false,
                                   resolved.needsConfirmation))
                }
            }
            ranges.sort { $0.start < $1.start }

            for range in ranges {
                let start = max(0, min(chars.count, range.start))
                let end = max(start, min(chars.count, start + max(1, range.length)))
                guard start < end else { continue }
                slots.append(RubyEditSlot(id: "\(token.id.uuidString):\(range.start)",
                                          tokenID: token.id,
                                          tokenSurface: token.surface,
                                          surfaceStart: range.start,
                                          surfaceLength: range.length,
                                          characters: String(chars[start..<end]),
                                          reading: range.reading,
                                          isOverride: range.isOverride,
                                          isUnconfirmed: range.unconfirmed))
            }
        }
        return slots
    }

    private static func overlaps(_ aStart: Int, _ aLength: Int,
                                 _ bStart: Int, _ bLength: Int) -> Bool {
        aStart < bStart + bLength && bStart < aStart + aLength
    }
}
