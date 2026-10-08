import Foundation

// MARK: - 日志与错误

public enum LogSeverity: String, Sendable {
    case info, success, warning, error
}

public typealias LogSink = @Sendable (_ severity: LogSeverity, _ message: String) -> Void

public enum OrganizerError: LocalizedError, Equatable {
    case invalidRoot(String)
    case scanFailed(String)
    case cancelled
    case notWritable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot(let path): return "目标不是有效目录：\(path)"
        case .scanFailed(let path): return "无法遍历目录：\(path)"
        case .cancelled: return "操作已取消"
        case .notWritable(let path): return "目标目录不可写（可能只读或无写权限）：\(path)"
        }
    }
}

/// 协作式取消令牌：后台引擎（含 Task.detached 中的同步遍历）通过轮询它及时中止。
/// Task.cancel 无法传播进 detached 任务，因此同步扫描需要显式令牌。
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    public func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        _isCancelled = false
        lock.unlock()
    }
}

// MARK: - 数据模型

public struct FileInfo: Sendable, Equatable, Hashable {
    public let path: String
    public let relativePath: String
    public let size: Int64
    public let creationDate: Date?
    public let modificationDate: Date?

    public init(path: String, relativePath: String, size: Int64,
                creationDate: Date?, modificationDate: Date?) {
        self.path = path
        self.relativePath = relativePath
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}

/// 扫描结果
public struct ScanOutcome: Sendable {
    public let root: URL
    public let files: [FileInfo]
    /// 所有子目录（相对路径）
    public let directories: Set<String>
    /// 空目录（相对路径）
    public let emptyDirectories: Set<String>

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// 排重结果
public struct DedupResult: Sendable {
    public let uniqueFiles: [FileInfo]
    /// 每组重复（组内已按相对路径排序，首个为保留文件）
    public let duplicateGroups: [[FileInfo]]
    /// 所有待删除的重复文件（已排序）
    public let allDuplicates: [FileInfo]
    /// 已计算哈希的文件：路径 -> SHA-256
    public let digests: [String: String]

    public var duplicateCount: Int {
        duplicateGroups.reduce(0) { $0 + $1.count - 1 }
    }

    public var wastedBytes: Int64 {
        duplicateGroups.reduce(0) { sum, group in
            sum + group.dropFirst().reduce(0) { $0 + $1.size }
        }
    }
}

// MARK: - 计划

public struct MoveOperation: Sendable {
    public let file: FileInfo
    public let source: URL
    public let destination: URL
    /// 源路径已等于目标路径（重复执行场景）
    public let inPlace: Bool
}

public struct OrganizerPlan: Sendable {
    public let root: URL
    public let moves: [MoveOperation]
    public let deletions: [FileInfo]
    /// 需要创建的目标目录（相对路径，含全部祖先）
    public let destinationDirectories: Set<String>
    /// 处理后实际存在的目录 = (目标目录 ∪ 原有目录) − 移动后变空的原始目录
    public let finalDirectories: Set<String>
    /// 移动完成后预计变空、需自底向上清理的原始目录（已按深层在前排序）
    public let emptyDirectoryCleanup: [String]

    public init(
        root: URL,
        moves: [MoveOperation],
        deletions: [FileInfo],
        destinationDirectories: Set<String>,
        finalDirectories: Set<String>,
        emptyDirectoryCleanup: [String] = []
    ) {
        self.root = root
        self.moves = moves
        self.deletions = deletions
        self.destinationDirectories = destinationDirectories
        self.finalDirectories = finalDirectories
        self.emptyDirectoryCleanup = emptyDirectoryCleanup
    }

    public var estimatedFinalDirectoryCount: Int { finalDirectories.count }

    public var totalOperations: Int { moves.count + deletions.count + emptyDirectoryCleanup.count }
}

// MARK: - 执行结果

public struct OrganizeResult: Sendable {
    public var movedCount = 0
    public var renamedCount = 0
    public var deletedCount = 0
    public var inPlaceCount = 0
    public var skippedCount = 0
    public var removedDirectoriesCount = 0
    public var errors: [String] = []

    public init() {}
}

// MARK: - 进度计数器（线程安全，供后台任务累计、UI 定时拉取）

public enum ProgressKeys {
    public static let scanFiles = "scanFiles"
    public static let scanBytes = "scanBytes"
    public static let scanErrors = "scanErrors"
    public static let hashDone = "hashDone"
    public static let hashTotal = "hashTotal"
    public static let processDone = "processDone"
    public static let processTotal = "processTotal"
    public static let moved = "moved"
    public static let renamed = "renamed"
    public static let deleted = "deleted"
    public static let inPlace = "inPlace"
    public static let skipped = "skipped"
    public static let errors = "errors"
}

public final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int64] = [:]

    public init() {}

    public func increment(_ key: String, by amount: Int64 = 1) {
        lock.lock()
        values[key, default: 0] += amount
        lock.unlock()
    }

    /// 扫描专用：文件数与字节数一次加锁同时累计，海量文件时省一半锁开销
    public func incrementScan(files: Int64, bytes: Int64) {
        lock.lock()
        values[ProgressKeys.scanFiles, default: 0] += files
        values[ProgressKeys.scanBytes, default: 0] += bytes
        lock.unlock()
    }

    public func set(_ key: String, to value: Int64) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    public func value(_ key: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return values[key] ?? 0
    }

    public func snapshot() -> [String: Int64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    public func reset() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
}

// MARK: - 字节格式化（确定性与线程安全，供核心日志与 UI 共用）

public enum ByteFmt {
    public static func format(_ bytes: Int64) -> String {
        let units: [(threshold: Double, symbol: String)] = [
            (1, "B"), (1024, "KB"), (1_048_576, "MB"),
            (1_073_741_824, "GB"), (1_099_511_627_776, "TB"),
        ]
        var chosen = units[0]
        for unit in units where Double(bytes) >= unit.threshold {
            chosen = unit
        }
        guard chosen.threshold > 1 else { return "\(bytes) B" }
        let scaled = Double(bytes) / chosen.threshold
        let text: String
        if scaled >= 100 {
            text = String(format: "%.0f", scaled)
        } else if scaled >= 10 {
            text = String(format: "%.1f", scaled)
        } else {
            text = String(format: "%.2f", scaled)
        }
        return "\(text) \(chosen.symbol)"
    }
}
