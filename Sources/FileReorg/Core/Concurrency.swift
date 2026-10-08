import Foundation

/// 有界并发执行：同时最多 maxConcurrent 个任务，按序收集结果。
/// 用于哈希计算与文件移动/删除，避免海量文件时打满线程或内存。
/// cancel 令牌在每次派发新任务前检查，取消后立即停止排队并抛出。
public func runBounded<R: Sendable>(
    count: Int,
    maxConcurrent: Int,
    priority: TaskPriority? = nil,
    cancel: CancelToken? = nil,
    _ body: @escaping @Sendable (Int) async throws -> R
) async throws -> [R] {
    guard count > 0 else { return [] }
    let limit = max(1, min(maxConcurrent, count))
    var results = [R?](repeating: nil, count: count)
    var nextIndex = 0

    return try await withThrowingTaskGroup(of: (Int, R).self) { group in
        func spawnNext() throws {
            if let cancel, cancel.isCancelled { throw OrganizerError.cancelled }
            guard nextIndex < count else { return }
            let index = nextIndex
            nextIndex += 1
            group.addTask(priority: priority) {
                (index, try await body(index))
            }
        }
        for _ in 0..<limit { try spawnNext() }
        for try await (index, value) in group {
            results[index] = value
            try spawnNext()
        }
        return results.map { $0! }
    }
}
