import Foundation
import CryptoKit

/// 全局排重引擎。
/// 策略：先按文件大小分桶（大小唯一则必然唯一，无需哈希），
/// 仅对大小冲突的文件流式计算 SHA-256，再按哈希分组。
public struct FileDeduplicator {
    public init() {}

    public func deduplicate(
        files: [FileInfo],
        maxConcurrent: Int = ProcessInfo.processInfo.activeProcessorCount * 2,
        progress: ProgressCounter? = nil,
        cancel: CancelToken? = nil
    ) async throws -> DedupResult {
        if cancel?.isCancelled == true { throw OrganizerError.cancelled }
        let bySize = Dictionary(grouping: files, by: \.size)
        let candidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        progress?.set(ProgressKeys.hashTotal, to: Int64(candidates.count))

        var digests: [String: String] = [:]
        if !candidates.isEmpty {
            let pairs: [(FileInfo, String)] = try await runBounded(
                count: candidates.count,
                maxConcurrent: maxConcurrent,
                cancel: cancel
            ) { index in
                if let cancel, cancel.isCancelled { throw OrganizerError.cancelled }
                let file = candidates[index]
                let digest: String
                do {
                    digest = try Self.hashFile(at: file.path)
                } catch {
                    // 无法读取的文件视为唯一，避免中断整体流程
                    digest = "unhashable:\(file.path)"
                    progress?.increment(ProgressKeys.errors)
                }
                progress?.increment(ProgressKeys.hashDone)
                return (file, digest)
            }
            digests = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.path, $0.1) })
        }

        var duplicateGroups: [[FileInfo]] = []
        for (_, group) in bySize where group.count > 1 {
            var byDigest: [String: [FileInfo]] = [:]
            for file in group {
                let key = digests[file.path] ?? "unhashable:\(file.path)"
                byDigest[key, default: []].append(file)
            }
            for sub in byDigest.values where sub.count > 1 {
                duplicateGroups.append(sub.sorted { $0.relativePath < $1.relativePath })
            }
        }

        let allDuplicates = duplicateGroups
            .flatMap { $0.dropFirst() }
            .sorted { $0.relativePath < $1.relativePath }
        let duplicatePaths = Set(allDuplicates.map(\.path))
        let uniqueFiles = files.filter { !duplicatePaths.contains($0.path) }

        return DedupResult(
            uniqueFiles: uniqueFiles,
            duplicateGroups: duplicateGroups,
            allDuplicates: allDuplicates,
            digests: digests
        )
    }

    /// 流式哈希：固定缓冲区逐块读取，避免大文件占用内存
    static func hashFile(at path: String, bufferSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
