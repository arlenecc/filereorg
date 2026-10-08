import Foundation
import Testing
import FileReorg

/// 计划与执行模块测试：TC9-TC17
@Suite("计划与执行")
struct OrganizerTests {

    // MARK: - 计划

    /// TC9: 目标路径 = 根目录/创建年份(4位)/原相对路径，保留原目录结构
    @Test("TC9: 目标路径按年份保留结构")
    func planDestPreservesStructureUnderYearFolder() throws {
        let t = TempTree()
        try t.writeFile("old/project/src/main.swift", content: "x", year: 2019)

        let scan = try FileScanner().scan(root: t.root)
        let plan = OrganizerPlanner.makePlan(root: t.root, scan: scan, uniqueFiles: scan.files, deletions: [])

        #expect(plan.moves.count == 1)
        let move = plan.moves[0]
        #expect(!move.inPlace)
        #expect(move.destination.path == t.root.appendingPathComponent("2019/old/project/src/main.swift").path)
        #expect(OrganizerPlanner.yearFolder(for: scan.files[0]) == "2019")
    }

    /// TC9b: 新文件夹以所属年份的 4 位数字命名；无日期回退修改日期，两者皆无归入"未知年份"
    @Test("TC9b: 年份文件夹 4 位数字命名")
    func yearFolderNaming() {
        func file(creation: Date?, modification: Date?) -> FileInfo {
            FileInfo(path: "/x", relativePath: "x", size: 1,
                     creationDate: creation, modificationDate: modification)
        }
        func date(_ year: Int) -> Date {
            var comps = DateComponents()
            comps.year = year; comps.month = 1; comps.day = 1
            return Calendar(identifier: .gregorian).date(from: comps)!
        }
        // 正常年份：4 位数字
        #expect(OrganizerPlanner.yearFolder(for: file(creation: date(2023), modification: nil)) == "2023")
        // 异常小年份：补零至 4 位
        #expect(OrganizerPlanner.yearFolder(for: file(creation: date(999), modification: nil)) == "0999")
        // 无创建日期：回退修改日期
        #expect(OrganizerPlanner.yearFolder(for: file(creation: nil, modification: date(2015))) == "2015")
        // 两者皆无：归入"未知年份"
        #expect(OrganizerPlanner.yearFolder(for: file(creation: nil, modification: nil)) == "未知年份")
    }

    /// TC10: 预计最终目录数 = (目标目录(含祖先) ∪ 原有目录) − 移动后清理的空目录
    @Test("TC10: 预计最终目录数")
    func planFinalDirectoryCount() throws {
        let t = TempTree()
        try t.writeFile("sub1/only/a.txt", content: "x", year: 2023)
        try t.makeDir("e1")
        try t.makeDir("e2/sub")

        let scan = try FileScanner().scan(root: t.root)
        let plan = OrganizerPlanner.makePlan(root: t.root, scan: scan, uniqueFiles: scan.files, deletions: [])

        #expect(plan.destinationDirectories == Set(["2023", "2023/sub1", "2023/sub1/only"]))
        // 原有 5 个目录全部变空被清理，只剩 3 个年份目标目录
        #expect(Set(plan.emptyDirectoryCleanup) == Set(["e1", "e2", "e2/sub", "sub1", "sub1/only"]))
        #expect(plan.estimatedFinalDirectoryCount == 3)
    }

    /// TC11: 已在目标位置的文件（重复执行场景）标记 inPlace，不重复移动
    @Test("TC11: 已在目标位置不移动")
    func inPlaceFilesAreNotMoved() async throws {
        let t = TempTree()
        try t.writeFile("2023/a.txt", content: "x", year: 2023)

        let (scan, dedup, plan) = try await buildPlan(root: t.root)
        #expect(scan.files.count == 1)
        #expect(plan.moves[0].inPlace)
        // 原地文件所在目录必须幸存，不参与清理
        #expect(plan.emptyDirectoryCleanup.isEmpty)
        #expect(plan.estimatedFinalDirectoryCount == 1)

        let result = try await Organizer().execute(plan: plan, digests: dedup.digests, maxConcurrent: 4)
        #expect(result.errors.isEmpty)
        #expect(result.inPlaceCount == 1)
        #expect(result.movedCount == 0)
        #expect(result.removedDirectoriesCount == 0)
        #expect(try t.fileTree() == ["2023/a.txt": "x"])
        #expect(t.exists("2023"))
    }

    // MARK: - 执行

    /// TC12: 按计划移动文件、删除重复文件，原位置清空
    @Test("TC12: 移动与删除按计划完成")
    func organizeMovesAndDeletes() async throws {
        let t = TempTree()
        try t.writeFile("f1.txt", content: "one", year: 2024)
        try t.writeFile("sub/f2.txt", content: "two", year: 2023)
        try t.writeFile("sub/f2dup.txt", content: "two", year: 2024)

        let (scan, dedup, plan) = try await buildPlan(root: t.root)
        #expect(dedup.duplicateCount == 1)

        let result = try await Organizer().execute(plan: plan, digests: dedup.digests, maxConcurrent: 4)

        #expect(result.errors.isEmpty)
        #expect(result.movedCount == 2)
        #expect(result.deletedCount == 1)

        let tree = try t.fileTree()
        #expect(tree == [
            "2024/f1.txt": "one",
            "2023/sub/f2.txt": "two",
        ])
        #expect(!t.exists("f1.txt"))
        #expect(!t.exists("sub/f2.txt"))
        #expect(!t.exists("sub/f2dup.txt"))
        // 原目录 sub 已变空并被清理
        #expect(!t.exists("sub"))
    }

    /// TC13: 移动后文件创建日期保留
    @Test("TC13: 创建日期保留")
    func organizePreservesCreationDate() async throws {
        let t = TempTree()
        try t.writeFile("x.txt", content: "hello", year: 2020)

        let (scan, dedup, plan) = try await buildPlan(root: t.root)
        _ = try await Organizer().execute(plan: plan, digests: dedup.digests, maxConcurrent: 4)

        #expect(try t.creationYear("2020/x.txt") == 2020)
    }

    /// TC14: 目标冲突 - 内容相同则仅保留一份；内容不同则改名 (1) 迁移
    @Test("TC14: 目标冲突处理")
    func organizeHandlesDestinationCollision() async throws {
        let t = TempTree()
        // 场景 1：已归档位置存在同名同内容文件 → 源被排重删除，已归档文件原地保留
        try t.writeFile("b.txt", content: "SAME", year: 2024)
        try t.writeFile("2024/b.txt", content: "SAME", year: 2024)
        // 场景 2：目标已存在但内容不同（同大小，强制走哈希比较）→ 改名迁移
        try t.writeFile("g.txt", content: "OTHR", year: 2024)
        try t.writeFile("2024/g.txt", content: "PREX", year: 2024)

        let (scan, dedup, plan) = try await buildPlan(root: t.root)
        let result = try await Organizer().execute(plan: plan, digests: dedup.digests, maxConcurrent: 4)

        #expect(result.errors.isEmpty)
        #expect(result.deletedCount == 1)   // b.txt 源被排重删除
        #expect(result.inPlaceCount == 2)   // 2024/b.txt 与 2024/g.txt 均原地保留
        #expect(result.renamedCount == 1)   // g.txt 改名迁移
        #expect(result.movedCount == 0)

        #expect(try t.content("2024/b.txt") == "SAME")
        #expect(!t.exists("b.txt"))
        #expect(try t.content("2024/g.txt") == "PREX")
        #expect(try t.content("2024/g (1).txt") == "OTHR")
    }

    /// TC15: 源文件缺失时跳过并继续，不中断整体流程
    @Test("TC15: 源缺失跳过不中断")
    func organizeSkipsMissingSource() async throws {
        let t = TempTree()
        try t.writeFile("keep.txt", content: "K", year: 2023)
        try t.writeFile("gone.txt", content: "G", year: 2023)

        let (scan, dedup, plan) = try await buildPlan(root: t.root)
        try t.remove("gone.txt")   // 计划生成后、执行前文件消失

        let result = try await Organizer().execute(plan: plan, digests: dedup.digests, maxConcurrent: 4)

        #expect(result.errors.isEmpty)
        #expect(result.skippedCount == 1)
        #expect(result.movedCount == 1)
        #expect(t.exists("2023/keep.txt"))
    }

    /// TC16: 大规模文件（300 个）并发执行正确性
    @Test("TC16: 300 文件并发正确性")
    func organizeLargeScaleConcurrency() async throws {
        let t = TempTree()
        for i in 0..<300 {
            let isDup = i % 10 < 3   // 30 组重复，每组 3 份
            let content = isDup ? "DUP\(i % 10)" : "UNIQUE-\(i)-\(String(repeating: "x", count: i % 7))"
            try t.writeFile("dir\(i % 50)/f\(i).txt", content: content, year: 2000 + i % 25)
        }

        let (scan, dedup, plan) = try await buildPlan(root: t.root)
        #expect(scan.files.count == 300)
        #expect(dedup.duplicateCount == 87)   // 3 组 x 29 份

        let result = try await Organizer().execute(plan: plan, digests: dedup.digests, maxConcurrent: 8)

        #expect(result.errors.isEmpty)
        #expect(result.movedCount == 213)
        #expect(result.deletedCount == 87)

        let tree = try t.fileTree()
        #expect(tree.count == 213)

        // 所有非重复文件都应位于 根/年份/原子目录/ 文件名
        var expected = Set<String>()
        for i in 0..<300 where i % 10 >= 3 {
            expected.insert("\(2000 + i % 25)/dir\(i % 50)/f\(i).txt")
        }
        #expect(expected.isSubset(of: Set(tree.keys)))
        // 每组重复内容在最终结果中恰好只剩 1 份
        for k in 0..<3 {
            #expect(tree.values.filter { $0 == "DUP\(k)" }.count == 1)
        }
    }

    /// TC17: 端到端 - 全链路执行后目录树与预计完全一致
    @Test("TC17: 端到端全链路")
    func endToEndPipeline() async throws {
        let t = TempTree()
        try t.writeFile("a.txt", content: "AAAA", year: 2023)
        try t.writeFile("notes/b.txt", content: "BBBB", year: 2024)
        try t.writeFile("notes/copy-b.txt", content: "BBBB", year: 2021)   // b 的重复
        try t.writeFile("deep/x/y/c.bin", content: "CCCC", year: 2022)
        try t.writeFile("deep/x/y/c-dup.bin", content: "CCCC", year: 2025) // c 的重复（排序在前，保留）
        try t.writeFile("deep/x/d.txt", content: "D", year: 2024)
        try t.writeFile("same/x1.dat", content: "E11E", year: 2024)
        try t.writeFile("same/x2.dat", content: "E22E", year: 2024)
        try t.makeDir("empty")

        let (scan, dedup, plan) = try await buildPlan(root: t.root)

        // 分析统计
        #expect(scan.files.count == 8)
        #expect(scan.totalBytes == 29)
        #expect(dedup.uniqueFiles.count == 6)
        #expect(dedup.duplicateCount == 2)
        #expect(dedup.wastedBytes == 8)
        // 最终目录数 = (原有 6 + 目标 10) − 清理空目录 6 = 10（全部为年份目标目录）
        #expect(plan.estimatedFinalDirectoryCount == 10)

        let result = try await Organizer().execute(plan: plan, digests: dedup.digests, maxConcurrent: 4)

        #expect(result.errors.isEmpty)
        #expect(result.movedCount == 6)
        #expect(result.deletedCount == 2)
        #expect(result.removedDirectoriesCount == 6)

        // 最终文件树
        let tree = try t.fileTree()
        #expect(tree == [
            "2023/a.txt": "AAAA",
            "2024/notes/b.txt": "BBBB",
            "2025/deep/x/y/c-dup.bin": "CCCC",
            "2024/deep/x/d.txt": "D",
            "2024/same/x1.dat": "E11E",
            "2024/same/x2.dat": "E22E",
        ])

        // 实际目录数与预估一致
        #expect(try t.allDirectories().count == plan.estimatedFinalDirectoryCount)
    }

    /// TC20: 已取消的令牌使处理立即中止，文件系统不被改动
    @Test("TC20: 处理可取消")
    func organizeSupportsCancellation() async throws {
        let t = TempTree()
        try t.writeFile("f1.txt", content: "one", year: 2024)
        try t.writeFile("f1dup.txt", content: "one", year: 2023)

        let (scan, dedup, plan) = try await buildPlan(root: t.root)
        let token = CancelToken()
        token.cancel()

        do {
            _ = try await Organizer().execute(plan: plan, digests: dedup.digests, cancel: token)
            Issue.record("应当抛出取消错误")
        } catch {
            #expect((error as? OrganizerError) == .cancelled)
        }

        // 未执行任何删除或移动
        #expect(t.exists("f1.txt"))
        #expect(t.exists("f1dup.txt"))
    }

    /// TC21: 处理后自底向上清理变空的原始目录；原地保留文件所在目录不清理
    @Test("TC21: 空目录清理")
    func cleanupEmptyOriginalDirectories() async throws {
        let t = TempTree()
        try t.writeFile("notes/a.txt", content: "A", year: 2023)
        try t.writeFile("notes/b.txt", content: "B", year: 2024)
        try t.makeDir("notes/archive/old")                                  // 纯空目录链
        try t.writeFile("2025/keep.txt", content: "K", year: 2025)          // 原地保留

        let (scan, dedup, plan) = try await buildPlan(root: t.root)

        // 仅 notes 链变空需清理；2025 含原地保留文件必须幸存
        #expect(plan.emptyDirectoryCleanup == ["notes/archive/old", "notes/archive", "notes"])
        // 清理后 = 5 个目标目录（2023、2023/notes、2024、2024/notes、2025）
        #expect(plan.estimatedFinalDirectoryCount == 5)

        let result = try await Organizer().execute(plan: plan, digests: dedup.digests, maxConcurrent: 4)

        #expect(result.errors.isEmpty)
        #expect(result.removedDirectoriesCount == 3)
        // 预估与实际目录严格一致
        #expect(try t.allDirectories() == Set(["2023", "2023/notes", "2024", "2024/notes", "2025"]))
        #expect(try t.allDirectories().count == plan.estimatedFinalDirectoryCount)
        #expect(t.exists("2025/keep.txt"))
        #expect(!t.exists("notes"))
    }
}
