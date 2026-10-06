import Foundation

/// `.magikara` 工程的读写、自动保存、媒体重定位与撤销栈（RD §11.1）。
public enum ProjectStore {

    public enum StoreError: LocalizedError {
        case unsupportedVersion(Int)
        case mediaMissing(URL)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "工程版本 \(v) 高于当前 App 支持的版本 \(KaraProject.currentVersion)"
            case .mediaMissing(let u):
                return "媒体文件找不到：\(u.lastPathComponent)"
            }
        }
    }

    // MARK: 编码 / 解码

    public static func encode(_ project: KaraProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(project)
    }

    public static func decode(_ data: Data) throws -> KaraProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var project = try decoder.decode(KaraProject.self, from: data)
        project = migrate(project)
        return project
    }

    /// 最低限度的版本迁移（RD §11.1）。
    static func migrate(_ project: KaraProject) -> KaraProject {
        var p = project
        if p.version < KaraProject.currentVersion {
            // v0 → v1：补上缺失的显示策略与词典，并修正四段时间约束
            p.version = KaraProject.currentVersion
        }
        p.enforceAllInvariants()
        // 旧工程的预览里本来就隐含一个开头倒计时，现在它是时间线上的显式色块；
        // 载入时补上（用户删除或改过的不会被补回），这样 App、命令行导出等任何入口行为一致。
        p.syncOpeningCountdown()
        return p
    }

    // MARK: 文件读写

    public static func save(_ project: KaraProject, to url: URL) throws {
        var p = project
        p.version = KaraProject.currentVersion
        let data = try encode(p)
        try data.write(to: url, options: .atomic)
    }

    /// 读取工程。媒体丢失时不抛错：工程仍要能打开，由界面提示重新定位（RD §11.1）。
    public static func load(from url: URL) throws -> KaraProject {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    // MARK: 媒体重定位

    /// 用户重新指定媒体文件后，把路径与书签写回工程。
    public static func relocateMedia(_ project: KaraProject, to newURL: URL, duration: Double) -> KaraProject {
        var p = project
        p.mediaURL = newURL
        p.duration = duration
        p.mediaBookmark = try? newURL.bookmarkData(options: [.withSecurityScope],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
        return p
    }

    /// 尝试用安全书签找回媒体。
    public static func resolveBookmark(_ project: KaraProject) -> URL? {
        guard let data = project.mediaBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return url
    }
}

// MARK: - 撤销 / 重做

/// 快照式撤销栈。
///
/// 工程结构（歌词 + token + 音拍 + 样式）整体不大，直接存快照最简单也最不容易出错；
/// 规格要求「可撤销/重做关键时间线操作」，快照法能覆盖全部编辑路径。
public final class UndoStack {

    private var undoStack: [KaraProject] = []
    private var redoStack: [KaraProject] = []
    private let limit: Int

    public init(limit: Int = 60) {
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoCount: Int { undoStack.count }
    public var redoCount: Int { redoStack.count }

    /// 在执行一次编辑之前调用，记录当前状态。
    public func record(_ current: KaraProject, label: String) {
        undoStack.append(current)
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public func undo(current: KaraProject) -> KaraProject? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public func redo(current: KaraProject) -> KaraProject? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

// MARK: - 自动保存

/// 用户停止操作后防抖 1 秒自动保存（RD §11.1）。
public final class Autosaver {
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.magi.magikara.autosave")

    public private(set) var lastSavedAt: Date?
    public private(set) var lastError: String?

    public init(delay: TimeInterval = 1.0) {
        self.delay = delay
    }

    /// 安排一次自动保存。`provider` 在真正落盘时才取工程，避免频繁拷贝。
    public func schedule(url: URL, provider: @escaping () -> KaraProject) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let project = provider()
            do {
                try ProjectStore.save(project, to: url)
                self.lastSavedAt = Date()
                self.lastError = nil
            } catch {
                self.lastError = error.localizedDescription
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// 立即保存（退出前调用）。
    public func flush(url: URL, project: KaraProject) throws {
        pending?.cancel()
        pending = nil
        try ProjectStore.save(project, to: url)
        lastSavedAt = Date()
    }
}
