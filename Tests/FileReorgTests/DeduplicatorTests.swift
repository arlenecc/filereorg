import Foundation
import Testing
import FileReorg

/// 排重模块测试：TC5-TC8
@Suite("排重模块")
struct DeduplicatorTests {

    /// TC5: 相同内容不同路径 -> 识别为一组重复，仅保留一个
    @Test("TC5: 相同内容归为一组重复")
    func dedupGroupsSameContentAcrossPaths() async throws {
        let t = TempTree()
        try t.writeFile("a/one.txt", content: "SAMECONTENT", year: 2023)
        try t.writeFile("b/two.txt", content: "SAMECONTENT", year: 2024)
        try t.writeFile("c/three.txt", content: "DIFFERENT!!", year: 2024)

        let scan = try FileScanner().scan(root: t.root)
        let dedup = try await FileDeduplicator().deduplicate(files: scan.files)

        #expect(scan.files.count == 3)
        #expect(dedup.duplicateGroups.count == 1)
        #expect(dedup.duplicateGroups[0].count == 2)
        #expect(dedup.duplicateCount == 1)
        #expect(dedup.uniqueFiles.count == 2)
        #expect(dedup.uniqueFiles.contains { $0.relativePath == "c/three.txt" })
    }

    /// TC6: 大小相同但内容不同 -> 不误判为重复
    @Test("TC6: 同大小不同内容不误判")
    func dedupSameSizeDifferentContentNotDuplicates() async throws {
        let t = TempTree()
        try t.writeFile("x/one.dat", content: "AAA1", year: 2023)
        try t.writeFile("y/two.dat", content: "AAA2", year: 2023)

        let scan = try FileScanner().scan(root: t.root)
        let dedup = try await FileDeduplicator().deduplicate(files: scan.files)

        #expect(dedup.duplicateGroups.count == 0)
        #expect(dedup.uniqueFiles.count == 2)
        #expect(dedup.wastedBytes == 0)
    }

    /// TC7: 重复组中保留相对路径排序第一个的文件
    @Test("TC7: 保留排序第一个副本")
    func dedupKeepsFirstSortedCopy() async throws {
        let t = TempTree()
        try t.writeFile("m/copy.txt", content: "X", year: 2025)
        try t.writeFile("a/orig.txt", content: "X", year: 2021)
        try t.writeFile("z/other.txt", content: "Y", year: 2023)

        let scan = try FileScanner().scan(root: t.root)
        let dedup = try await FileDeduplicator().deduplicate(files: scan.files)

        #expect(dedup.duplicateGroups.count == 1)
        #expect(dedup.duplicateGroups[0].map(\.relativePath) == ["a/orig.txt", "m/copy.txt"])
        #expect(dedup.allDuplicates.map(\.relativePath) == ["m/copy.txt"])
        #expect(dedup.uniqueFiles.map(\.relativePath) == ["a/orig.txt", "z/other.txt"])
    }

    /// TC8: 浪费空间统计 = 重复文件大小之和
    @Test("TC8: 浪费空间统计正确")
    func dedupWastedBytes() async throws {
        let t = TempTree()
        try t.writeFile("d1.bin", content: "DDDD", year: 2023)             // 4 bytes
        try t.writeFile("sub/d2.bin", content: "DDDD", year: 2023)         // 4 bytes
        try t.writeFile("sub/deep/d3.bin", content: "DDDD", year: 2023)    // 4 bytes
        try t.writeFile("unique.txt", content: "UNIQUE-12345", year: 2024) // 12 bytes

        let scan = try FileScanner().scan(root: t.root)
        let dedup = try await FileDeduplicator().deduplicate(files: scan.files)

        #expect(dedup.duplicateCount == 2)
        #expect(dedup.wastedBytes == 8)
        #expect(scan.totalBytes == 24)
        #expect(dedup.uniqueFiles.count == 2)
    }

    /// TC19: 已取消的令牌使排重立即中止并抛出取消错误
    @Test("TC19: 排重可取消")
    func dedupSupportsCancellation() async throws {
        let t = TempTree()
        try t.writeFile("a.bin", content: "DUP", year: 2023)
        try t.writeFile("b.bin", content: "DUP", year: 2024)

        let scan = try FileScanner().scan(root: t.root)
        let token = CancelToken()
        token.cancel()

        do {
            _ = try await FileDeduplicator().deduplicate(files: scan.files, cancel: token)
            Issue.record("应当抛出取消错误")
        } catch {
            #expect((error as? OrganizerError) == .cancelled)
        }
    }
}
