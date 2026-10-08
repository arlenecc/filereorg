import Foundation
import Testing
import FileReorg

/// 扫描模块测试：TC1-TC4
@Suite("扫描模块")
struct FileScannerTests {

    /// TC1: 递归扫描统计文件数量与总大小正确
    @Test("TC1: 扫描文件数量与总大小")
    func scanCountsFilesAndSizes() throws {
        let t = TempTree()
        try t.writeFile("a.txt", content: "12345", year: 2023)          // 5 bytes
        try t.writeFile("sub/b.txt", content: "12345678", year: 2024)   // 8 bytes
        try t.writeFile("sub/deep/c.txt", content: "1", year: 2024)     // 1 byte

        let outcome = try FileScanner().scan(root: t.root)

        #expect(outcome.files.count == 3)
        #expect(outcome.totalBytes == 14)
        #expect(outcome.files.contains { $0.relativePath == "sub/deep/c.txt" })
    }

    /// TC2: 符号链接不计入文件
    @Test("TC2: 跳过符号链接")
    func scanSkipsSymlinks() throws {
        let t = TempTree()
        try t.writeFile("real.txt", content: "abc", year: 2023)
        try FileManager.default.createSymbolicLink(
            atPath: t.root.appendingPathComponent("link.txt").path,
            withDestinationPath: "real.txt"
        )
        try t.makeDir("subdir")
        try FileManager.default.createSymbolicLink(
            atPath: t.root.appendingPathComponent("dirlink").path,
            withDestinationPath: "subdir"
        )

        let outcome = try FileScanner().scan(root: t.root)

        #expect(outcome.files.map(\.relativePath) == ["real.txt"])
    }

    /// TC3: 结果按相对路径排序（确定性，保证排重保留策略可预测）
    @Test("TC3: 结果按相对路径排序")
    func scanSortsByRelativePath() throws {
        let t = TempTree()
        try t.writeFile("z.txt", content: "1", year: 2023)
        try t.writeFile("a/x.txt", content: "1", year: 2023)
        try t.writeFile("a/b/y.txt", content: "1", year: 2023)

        let outcome = try FileScanner().scan(root: t.root)

        #expect(outcome.files.map(\.relativePath) == ["a/b/y.txt", "a/x.txt", "z.txt"])
    }

    /// TC4: 空目录被识别
    @Test("TC4: 识别空目录")
    func scanDetectsEmptyDirectories() throws {
        let t = TempTree()
        try t.writeFile("f.txt", content: "1", year: 2023)
        try t.makeDir("empty1")
        try t.makeDir("e2/sub")   // e2 含子目录，不算空；e2/sub 为空

        let outcome = try FileScanner().scan(root: t.root)

        #expect(outcome.emptyDirectories == Set(["e2/sub", "empty1"]))
        #expect(outcome.directories == Set(["empty1", "e2", "e2/sub"]))
    }

    /// TC18: 已取消的令牌使扫描立即中止并抛出取消错误
    @Test("TC18: 扫描可取消")
    func scanSupportsCancellation() throws {
        let t = TempTree()
        try t.writeFile("a.txt", content: "1", year: 2023)
        let token = CancelToken()
        token.cancel()

        do {
            _ = try FileScanner().scan(root: t.root, cancel: token)
            Issue.record("应当抛出取消错误")
        } catch {
            #expect((error as? OrganizerError) == .cancelled)
        }
    }

    /// TC18b: 扫描期间统计无法读取的项
    @Test("TC18b: 扫描错误计数")
    func scanCountsErrors() throws {
        let t = TempTree()
        try t.writeFile("ok.txt", content: "1", year: 2023)

        let outcome = try FileScanner().scan(root: t.root, progress: ProgressCounter())

        #expect(outcome.files.count == 1)
    }
}
