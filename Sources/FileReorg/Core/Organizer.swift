import Foundation

// MARK: - 计划器

public enum OrganizerPlanner {
    /// 新文件夹以所属年份的 4 位数字命名（如 2023）；无日期时回退修改日期，再无则归入"未知年份"
    public static func yearFolder(for file: FileInfo, calendar: Calendar = .current) -> String {
        guard let date = file.creationDate ?? file.modificationDate else { return "未知年份" }
        let year = calendar.component(.year, from: date)
        return year > 0 ? String(format: "%04d", year) : "未知年份"
    }

    public static func makePlan(
        root: URL,
        scan: ScanOutcome,
        uniqueFiles: [FileInfo],
        deletions: [FileInfo]
    ) -> OrganizerPlan {
        let rootURL = root.standardizedFileURL
        var destinationDirectories = Set<String>()
        var moves: [MoveOperation] = []
        moves.reserveCapacity(uniqueFiles.count)

        for file in uniqueFiles {
            let year = yearFolder(for: file)
            // 已位于对应年份目录内（重复执行场景）→ 原地保留，避免嵌套 2023/2023/
            let inPlace = file.relativePath.hasPrefix(year + "/")
            let destinationRelative = inPlace ? file.relativePath : year + "/" + file.relativePath
            let directoryRelative = (destinationRelative as NSString).deletingLastPathComponent
            if !directoryRelative.isEmpty {
                destinationDirectories.insert(directoryRelative)
                // 计入全部祖先目录（处理后会实际存在）
                var components = directoryRelative.split(separator: "/").map(String.init)
                while !components.isEmpty {
                    destinationDirectories.insert(components.joined(separator: "/"))
                    components.removeLast()
                }
            }
            moves.append(MoveOperation(
                file: file,
                source: URL(fileURLWithPath: file.path),
                destination: rootURL.appendingPathComponent(destinationRelative),
                inPlace: inPlace
            ))
        }

        // 预测移动后会幸存的原始目录：原地保留文件所在目录链、以及移动文件将落入的目录链，
        // 这些目录（及其原始祖先）处理后非空，不能清理
        let originalDirs = scan.directories
        var survived = Set<String>()
        func retainChain(_ relative: String) {
            var current = relative
            while !current.isEmpty {
                if originalDirs.contains(current) { survived.insert(current) }
                let parent = (current as NSString).deletingLastPathComponent
                if parent == current { break }
                current = parent
            }
        }
        for dir in destinationDirectories {
            retainChain(dir)
        }
        for op in moves where op.inPlace {
            let dir = (op.file.relativePath as NSString).deletingLastPathComponent
            if !dir.isEmpty { retainChain(dir) }
        }

        // 其余原始目录自底向上清理（先删深层，父目录随后才能变空）
        let removedDirs = originalDirs.subtracting(survived)
        let emptyDirectoryCleanup = removedDirs.sorted {
            let c0 = $0.split(separator: "/").count
            let c1 = $1.split(separator: "/").count
            return c0 != c1 ? c0 > c1 : $0 > $1
        }

        let finalDirectories = destinationDirectories.union(originalDirs).subtracting(removedDirs)
        return OrganizerPlan(
            root: rootURL,
            moves: moves,
            deletions: deletions.sorted { $0.relativePath < $1.relativePath },
            destinationDirectories: destinationDirectories,
            finalDirectories: finalDirectories,
            emptyDirectoryCleanup: emptyDirectoryCleanup
        )
    }
}

// MARK: - 执行器

enum MoveOutcome: Sendable {
    case moved, renamed, dedupeDeleted, inPlace, skipped, failed
}

public struct Organizer {
    public init() {}

    public func execute(
        plan: OrganizerPlan,
        digests: [String: String],
        maxConcurrent: Int = ProcessInfo.processInfo.activeProcessorCount * 2,
        progress: ProgressCounter? = nil,
        log: LogSink? = nil,
        cancel: CancelToken? = nil
    ) async throws -> OrganizeResult {
        if cancel?.isCancelled == true { throw OrganizerError.cancelled }
        var result = OrganizeResult()
        progress?.set(ProgressKeys.processTotal, to: Int64(plan.totalOperations))

        // 0) 预检：目标目录不可写时立即失败，避免海量移动逐个报错
        let fm = FileManager.default
        if !fm.isWritableFile(atPath: plan.root.path) {
            throw OrganizerError.notWritable(plan.root.path)
        }

        // 1) 并发创建全部目标目录（含祖先），失败不再静默——那会导致后续移动全部报错
        let directories = plan.destinationDirectories.sorted()
        if !directories.isEmpty {
            let dirErrors: [String] = try await runBounded(
                count: directories.count,
                maxConcurrent: maxConcurrent,
                cancel: cancel
            ) { index -> String? in
                // FileManager.default 线程安全，闭包内直接取用避免跨闭包捕获
                do {
                    try FileManager.default.createDirectory(
                        at: plan.root.appendingPathComponent(directories[index]),
                        withIntermediateDirectories: true
                    )
                    return nil
                } catch {
                    return "创建目标目录失败：\(directories[index])（\(error.localizedDescription)，错误码 \((error as NSError).code)）"
                }
            }
            .compactMap { $0 }
            for message in dirErrors.prefix(5) {
                log?(.error, message)
            }
            if dirErrors.count > 5 {
                log?(.error, "…另有 \(dirErrors.count - 5) 个目录创建失败")
            }
            if dirErrors.isEmpty {
                log?(.info, "已就绪目标目录 \(directories.count) 个")
            } else {
                log?(.warning, "目标目录就绪 \(directories.count - dirErrors.count)/\(directories.count) 个，部分文件可能无法移动")
            }
        }

        // 2) 并发删除重复文件
        if !plan.deletions.isEmpty {
            let deletionResults: [(Bool, String?)] = try await runBounded(
                count: plan.deletions.count,
                maxConcurrent: maxConcurrent,
                cancel: cancel
            ) { index in
                if let cancel, cancel.isCancelled { throw OrganizerError.cancelled }
                let file = plan.deletions[index]
                do {
                    try FileManager.default.removeItem(atPath: file.path)
                    progress?.increment(ProgressKeys.deleted)
                    progress?.increment(ProgressKeys.processDone)
                    log?(.warning, "删除重复文件：\(file.relativePath)（\(ByteFmt.format(file.size))）")
                    return (true, nil)
                } catch {
                    progress?.increment(ProgressKeys.processDone)
                    progress?.increment(ProgressKeys.errors)
                    return (false, "删除重复文件失败：\(file.relativePath)（\(error.localizedDescription)）")
                }
            }
            for (ok, error) in deletionResults {
                if ok {
                    result.deletedCount += 1
                } else if let error {
                    result.errors.append(error)
                }
            }
        }

        // 3) 并发移动文件到 年份/原结构 目录
        guard !plan.moves.isEmpty else { return result }
        let moveResults: [(MoveOutcome, String?)] = try await runBounded(
            count: plan.moves.count,
            maxConcurrent: maxConcurrent,
            cancel: cancel
        ) { index in
            if let cancel, cancel.isCancelled { throw OrganizerError.cancelled }
            let op = plan.moves[index]
            if op.inPlace {
                progress?.increment(ProgressKeys.inPlace)
                progress?.increment(ProgressKeys.processDone)
                log?(.info, "已在目标位置，无需移动：\(op.file.relativePath)")
                return (.inPlace, nil)
            }
            guard FileManager.default.fileExists(atPath: op.file.path) else {
                progress?.increment(ProgressKeys.skipped)
                progress?.increment(ProgressKeys.processDone)
                log?(.warning, "源文件不存在，跳过：\(op.file.relativePath)")
                return (.skipped, nil)
            }

            var destination = op.destination
            var renamed = false
            if FileManager.default.fileExists(atPath: destination.path) {
                if Self.contentsEqual(at: op.file.path, and: destination.path, knownDigest: digests[op.file.path]) {
                    do {
                        try FileManager.default.removeItem(atPath: op.file.path)
                        progress?.increment(ProgressKeys.deleted)
                        progress?.increment(ProgressKeys.processDone)
                        log?(.warning, "目标已存在相同文件，移除重复源：\(op.file.relativePath)")
                        return (.dedupeDeleted, nil)
                    } catch {
                        progress?.increment(ProgressKeys.processDone)
                        return (.failed, "移除重复源失败：\(op.file.relativePath)（\(error.localizedDescription)）")
                    }
                }
                destination = Self.alternateURL(for: destination)
                renamed = true
            }

            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                // 同卷移动即 rename，元数据（含创建日期）保留
                try FileManager.default.moveItem(atPath: op.file.path, toPath: destination.path)
                progress?.increment(renamed ? ProgressKeys.renamed : ProgressKeys.moved)
                progress?.increment(ProgressKeys.processDone)
                log?(.success, "\(renamed ? "改名迁移" : "已移动")：\(op.file.relativePath) → \(Self.relativePath(of: destination, in: plan.root))")
                return (renamed ? .renamed : .moved, nil)
            } catch {
                progress?.increment(ProgressKeys.processDone)
                progress?.increment(ProgressKeys.errors)
                let nsError = error as NSError
                return (.failed, "移动失败：\(op.file.relativePath) → \(Self.relativePath(of: destination, in: plan.root))（\(error.localizedDescription)，错误码 \(nsError.domain)#\(nsError.code)）")
            }
        }

        for (outcome, error) in moveResults {
            switch outcome {
            case .moved: result.movedCount += 1
            case .renamed: result.renamedCount += 1
            case .dedupeDeleted: result.deletedCount += 1
            case .inPlace: result.inPlaceCount += 1
            case .skipped: result.skippedCount += 1
            case .failed: break
            }
            if let error { result.errors.append(error) }
        }

        // 4) 自底向上清理移动后变空的原始目录。
        // 用 POSIX rmdir：只删除真空目录，非空（含失败/跳过残留）自动失败跳过，绝不递归误删。
        if !plan.emptyDirectoryCleanup.isEmpty {
            var removedDirs = 0
            for relative in plan.emptyDirectoryCleanup {
                let path = plan.root.appendingPathComponent(relative).path
                if rmdir(path) == 0 {
                    removedDirs += 1
                }
                progress?.increment(ProgressKeys.processDone)
            }
            result.removedDirectoriesCount = removedDirs
            let kept = plan.emptyDirectoryCleanup.count - removedDirs
            var line = "已清理空目录 \(removedDirs)/\(plan.emptyDirectoryCleanup.count) 个"
            if kept > 0 { line += "（其余非空已保留）" }
            log?(removedDirs > 0 ? .success : .info, line)
        }
        return result
    }

    // MARK: 私有工具

    static func relativePath(of url: URL, in root: URL) -> String {
        let prefix = root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }

    /// 内容比较：先比大小，再比 SHA-256（利用已知哈希避免重算）
    static func contentsEqual(at pathA: String, and pathB: String, knownDigest: String?) -> Bool {
        let fm = FileManager.default
        guard
            let attrsA = try? fm.attributesOfItem(atPath: pathA),
            let attrsB = try? fm.attributesOfItem(atPath: pathB),
            let sizeA = attrsA[.size] as? Int64,
            let sizeB = attrsB[.size] as? Int64,
            sizeA == sizeB
        else { return false }
        guard
            let digestA = knownDigest ?? (try? FileDeduplicator.hashFile(at: pathA)),
            let digestB = try? FileDeduplicator.hashFile(at: pathB)
        else { return false }
        return digestA == digestB
    }

    /// 目标名冲突时寻找 "name (1).ext" 形式的可用名称
    static func alternateURL(for url: URL) -> URL {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let nameWithoutExtension = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let directory = url.deletingLastPathComponent()
        var index = 1
        while index < 1000 {
            let newName = ext.isEmpty
                ? "\(nameWithoutExtension) (\(index))"
                : "\(nameWithoutExtension) (\(index)).\(ext)"
            let candidate = directory.appendingPathComponent(newName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
        return directory.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(name)")
    }
}
