import Foundation
import Testing
import FileReorg

/// 测试辅助：临时目录树构建与断言工具
final class TempTree {
    let root: URL
    private let fm = FileManager.default

    init(name: String = "tree") {
        let base = fm.temporaryDirectory
            .appendingPathComponent("FileReorgTests-\(UUID().uuidString)")
        root = base.appendingPathComponent(name)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// 写入相对路径文件，可指定创建年份（用于验证按年份归档）
    @discardableResult
    func writeFile(_ rel: String, content: String, year: Int? = nil) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        if let year {
            var comps = DateComponents()
            comps.year = year
            comps.month = 6
            comps.day = 15
            comps.hour = 12
            let date = Calendar(identifier: .gregorian).date(from: comps)!
            try fm.setAttributes([.creationDate: date], ofItemAtPath: url.path)
        }
        return url
    }

    func makeDir(_ rel: String) throws {
        try fm.createDirectory(at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
    }

    func remove(_ rel: String) throws {
        try fm.removeItem(at: root.appendingPathComponent(rel))
    }

    func exists(_ rel: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(rel).path)
    }

    func content(_ rel: String) throws -> String {
        String(decoding: try Data(contentsOf: root.appendingPathComponent(rel)), as: UTF8.self)
    }

    /// 递归收集所有普通文件：相对路径 -> 内容
    func fileTree() throws -> [String: String] {
        var result: [String: String] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            return result
        }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let rel = String(path.dropFirst(rootPath.count + 1))
            result[rel] = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        return result
    }

    /// 收集所有子目录相对路径
    func allDirectories() throws -> Set<String> {
        var dirs: Set<String> = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return dirs
        }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey]), v.isDirectory == true else { continue }
            let path = url.standardizedFileURL.path
            if path != rootPath {
                dirs.insert(String(path.dropFirst(rootPath.count + 1)))
            }
        }
        return dirs
    }

    /// 读取文件创建年份
    func creationYear(_ rel: String) throws -> Int? {
        let v = try root.appendingPathComponent(rel).resourceValues(forKeys: [.creationDateKey])
        guard let d = v.creationDate else { return nil }
        return Calendar.current.component(.year, from: d)
    }
}

/// 全链路管线辅助：扫描 -> 排重 -> 计划
func buildPlan(root: URL) async throws -> (ScanOutcome, DedupResult, OrganizerPlan) {
    let scan = try FileScanner().scan(root: root)
    let dedup = try await FileDeduplicator().deduplicate(files: scan.files, maxConcurrent: 4)
    let plan = OrganizerPlanner.makePlan(
        root: root,
        scan: scan,
        uniqueFiles: dedup.uniqueFiles,
        deletions: dedup.allDuplicates
    )
    return (scan, dedup, plan)
}
