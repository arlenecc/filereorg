import Foundation
import SwiftUI
import Combine

// MARK: - 显示快照

struct SummaryStats: Equatable {
    var scannedFiles = 0
    var scannedBytes: Int64 = 0
    var uniqueFiles = 0
    var duplicateFiles = 0
    var wastedBytes: Int64 = 0
    var estDirCount = 0
    var estFileCount = 0
    var estBytes: Int64 = 0
    var processedDone = 0
    var processedTotal = 0
}

struct LogEntry: Identifiable, Equatable {
    let id: Int
    let date: Date
    let severity: LogSeverity
    let text: String
}

/// 线程安全日志缓冲：后台任务随时写入，UI 定时批量拉取，
/// 避免海量文件时逐条刷新界面。容量有上限，防止极端情况下无界增长。
final class LogBuffer: @unchecked Sendable {
    private static let capacity = 4096
    private let lock = NSLock()
    private var pending: [LogEntry] = []
    private var nextID = 0

    func append(_ severity: LogSeverity, _ text: String) {
        lock.lock()
        nextID += 1
        pending.append(LogEntry(id: nextID, date: Date(), severity: severity, text: text))
        if pending.count > Self.capacity {
            pending.removeFirst(pending.count - Self.capacity)
        }
        lock.unlock()
    }

    func drain() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        return out
    }
}

// MARK: - 视图模型

@MainActor
final class OrganizerModel: ObservableObject {
    enum Phase: Equatable {
        case idle, scanning, hashing, ready, organizing, done, cancelled, failed(String)
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { updateTimer() }
    }
    @Published var rootPathText = ""
    @Published private(set) var summary = SummaryStats()
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var overallProgress: Double = 0
    @Published private(set) var progressIndeterminate = false
    @Published private(set) var statusText = "请选择目标目录并点击开始分析"
    // CLT 工具链缺少 SwiftUI 宏插件，@State 不可用，目录选择状态放在模型中
    @Published var showDirectoryPicker = false

    // 非发布内部状态：计数器/日志由后台任务高频写入，UI 仅按 0.3s 节流拉取
    private let counter = ProgressCounter()
    private let logBuffer = LogBuffer()
    private var pendingPlan: OrganizerPlan?
    private var pendingDigests: [String: String] = [:]
    private var resolvedRoot: URL?
    private var workTask: Task<Void, Never>?
    private let cancelToken = CancelToken()
    private var timerCancellable: AnyCancellable?

    var isBusy: Bool { phase == .scanning || phase == .hashing || phase == .organizing }
    var canStartAnalysis: Bool { resolvedRoot != nil && !isBusy }
    var canStartProcessing: Bool { phase == .ready && pendingPlan != nil }

    init() {}

    /// 定时器仅在忙碌阶段运行，空闲时停止以减少无谓唤醒；离开忙碌时最后排空一次日志
    private func updateTimer() {
        if isBusy {
            if timerCancellable == nil {
                timerCancellable = Timer.publish(every: 0.3, on: .main, in: .common)
                    .autoconnect()
                    .sink { [weak self] _ in self?.refreshDisplay() }
            }
        } else if timerCancellable != nil {
            timerCancellable = nil
            refreshDisplay()
        }
    }

    // MARK: 取消

    func cancelWork() {
        guard isBusy else { return }
        cancelToken.cancel()
        workTask?.cancel()
        logBuffer.append(.warning, "正在取消…")
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? OrganizerError) == .cancelled
    }

    private func handleCancelled() {
        logBuffer.append(.warning, "操作已取消（已完成的部分保留，可重新分析）")
        pendingPlan = nil
        pendingDigests = [:]
        progressIndeterminate = false
        phase = .cancelled
        statusText = "已取消"
    }

    // MARK: 目录选择

    func setRoot(_ url: URL) {
        resolvedRoot = url
        rootPathText = url.path
        guard !isBusy else { return }
        phase = .idle
        logs = []
        _ = logBuffer.drain()
        resetSummary()
        overallProgress = 0
        progressIndeterminate = false
        statusText = "已选择目录，点击开始分析"
    }

    private func resolveTypedPath() -> URL? {
        var text = rootPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("~") {
            text = NSString(string: text).expandingTildeInPath
        }
        let url = URL(fileURLWithPath: text, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url.standardizedFileURL
    }

    // MARK: 开始分析

    func startAnalysis() {
        guard !isBusy else { return }
        guard let root = resolveTypedPath() else {
            statusText = "目录无效：请选择或输入正确的目录路径"
            return
        }
        resolvedRoot = root
        rootPathText = root.path

        cancelToken.reset()
        counter.reset()
        logs = []
        _ = logBuffer.drain()
        pendingPlan = nil
        pendingDigests = [:]
        resetSummary()
        overallProgress = 0
        progressIndeterminate = true
        phase = .scanning
        statusText = "正在扫描目录…"
        logBuffer.append(.info, "开始扫描：\(root.path)")

        let counter = self.counter
        let logBuffer = self.logBuffer
        let cancel = self.cancelToken
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 扫描在后台线程执行，不阻塞主线程；cancel 令牌用于协作式中止
                let scan = try await Task.detached(priority: .userInitiated) {
                    try FileScanner().scan(root: root, progress: counter, cancel: cancel)
                }.value
                try Task.checkCancellation()

                self.phase = .hashing
                // 扫描已完成，直接用最终值，避免最后一次节流刷新漏掉尾巴
                self.summary.scannedFiles = scan.files.count
                self.summary.scannedBytes = scan.totalBytes
                self.statusText = "正在计算哈希、全局排重…"
                logBuffer.append(.info, "扫描完成：共 \(scan.files.count) 个文件（\(ByteFmt.format(scan.totalBytes))），\(scan.directories.count) 个子目录，\(scan.emptyDirectories.count) 个空目录")
                let scanErrors = counter.value(ProgressKeys.scanErrors)
                if scanErrors > 0 {
                    logBuffer.append(.warning, "扫描时 \(scanErrors) 项无法读取，已跳过")
                }
                if !FileManager.default.isWritableFile(atPath: root.path) {
                    logBuffer.append(.warning, "警告：目标目录当前不可写（可能只读或无写权限），开始处理预计会失败")
                }
                if scan.files.count > 1 {
                    logBuffer.append(.info, "开始全局排重（按大小分桶 + SHA-256 哈希比对）…")
                }

                let dedup = try await FileDeduplicator().deduplicate(files: scan.files, progress: counter, cancel: cancel)
                try Task.checkCancellation()

                let plan = await Task.detached(priority: .userInitiated) {
                    OrganizerPlanner.makePlan(
                        root: root, scan: scan,
                        uniqueFiles: dedup.uniqueFiles,
                        deletions: dedup.allDuplicates
                    )
                }.value
                try Task.checkCancellation()

                self.pendingPlan = plan
                // 仅保留执行阶段会用到的哈希（唯一文件的），重复文件的哈希立即释放
                let uniquePaths = Set(dedup.uniqueFiles.map(\.path))
                self.pendingDigests = dedup.digests.filter { uniquePaths.contains($0.key) }
                self.summary = SummaryStats(
                    scannedFiles: scan.files.count,
                    scannedBytes: scan.totalBytes,
                    uniqueFiles: dedup.uniqueFiles.count,
                    duplicateFiles: dedup.duplicateCount,
                    wastedBytes: dedup.wastedBytes,
                    estDirCount: plan.estimatedFinalDirectoryCount,
                    estFileCount: dedup.uniqueFiles.count,
                    estBytes: scan.totalBytes - dedup.wastedBytes,
                    processedDone: 0,
                    processedTotal: plan.totalOperations
                )
                self.overallProgress = 0
                self.progressIndeterminate = false

                logBuffer.append(.success, "分析完成：排重后保留 \(dedup.uniqueFiles.count) 个文件，发现重复 \(dedup.duplicateCount) 个，可释放 \(ByteFmt.format(dedup.wastedBytes))；预计处理后 \(plan.estimatedFinalDirectoryCount) 个目录 / \(dedup.uniqueFiles.count) 个文件 / \(ByteFmt.format(scan.totalBytes - dedup.wastedBytes))")
                self.phase = .ready
                self.statusText = "分析完成，确认结果后点击开始处理"
            } catch {
                if Self.isCancellation(error) {
                    self.handleCancelled()
                } else {
                    logBuffer.append(.error, "分析失败：\(error.localizedDescription)")
                    self.phase = .failed(error.localizedDescription)
                    self.statusText = "分析失败：\(error.localizedDescription)"
                    self.progressIndeterminate = false
                }
            }
        }
    }

    // MARK: 开始处理

    func startProcessing() {
        guard canStartProcessing, let plan = pendingPlan else { return }
        cancelToken.reset()
        counter.reset()
        overallProgress = 0
        progressIndeterminate = false
        phase = .organizing
        statusText = "正在处理…"
        logBuffer.append(.info, "开始处理：移动 \(plan.moves.count) 个文件到年份目录，删除 \(plan.deletions.count) 个重复文件")

        let counter = self.counter
        let logBuffer = self.logBuffer
        let digests = self.pendingDigests
        let cancel = self.cancelToken
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Organizer().execute(
                    plan: plan,
                    digests: digests,
                    progress: counter,
                    log: { severity, message in
                        logBuffer.append(severity, message)
                    },
                    cancel: cancel
                )

                self.summary.processedDone = self.summary.processedTotal
                self.overallProgress = 1.0
                self.progressIndeterminate = false

                var line = "处理完成：移动 \(result.movedCount) 个，原地保留 \(result.inPlaceCount) 个，删除重复 \(result.deletedCount) 个"
                if result.renamedCount > 0 { line += "，改名迁移 \(result.renamedCount) 个" }
                if result.skippedCount > 0 { line += "，跳过 \(result.skippedCount) 个" }
                if result.removedDirectoriesCount > 0 { line += "，清理空目录 \(result.removedDirectoriesCount) 个" }
                if !result.errors.isEmpty { line += "，失败 \(result.errors.count) 个" }
                logBuffer.append(result.errors.isEmpty ? .success : .warning, line)
                // 计划已执行完毕，释放大对象
                self.pendingPlan = nil
                self.pendingDigests = [:]
                self.phase = .done
                self.statusText = line
            } catch {
                // 取消或失败后计划可能已部分执行，不可复用，需重新分析
                self.pendingPlan = nil
                self.pendingDigests = [:]
                if Self.isCancellation(error) {
                    self.handleCancelled()
                } else {
                    logBuffer.append(.error, "处理失败：\(error.localizedDescription)")
                    self.phase = .failed(error.localizedDescription)
                    self.statusText = "处理失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: 定时刷新（节流）

    func refreshDisplay() {
        let snapshot = counter.snapshot()
        switch phase {
        case .scanning:
            summary.scannedFiles = Int(snapshot[ProgressKeys.scanFiles] ?? 0)
            summary.scannedBytes = snapshot[ProgressKeys.scanBytes] ?? 0
        case .hashing:
            let done = snapshot[ProgressKeys.hashDone] ?? 0
            let total = snapshot[ProgressKeys.hashTotal] ?? 0
            overallProgress = total > 0 ? Double(done) / Double(total) : 0
        case .organizing:
            let done = snapshot[ProgressKeys.processDone] ?? 0
            let total = snapshot[ProgressKeys.processTotal] ?? 0
            summary.processedDone = Int(done)
            summary.processedTotal = Int(total)
            overallProgress = total > 0 ? Double(done) / Double(total) : 0
        default:
            break
        }
        let drained = logBuffer.drain()
        if !drained.isEmpty {
            logs.append(contentsOf: drained)
            if logs.count > 400 {
                logs.removeFirst(logs.count - 400)
            }
        }
    }

    private func resetSummary() {
        summary = SummaryStats()
    }
}
