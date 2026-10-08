import Foundation

/// 文件扫描器：单次遍历收集文件元数据与目录信息。
/// 使用 FileManager.enumerator，流式遍历，适合海量文件。
public struct FileScanner {
    public init() {}

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey,
    ]

    public func scan(
        root: URL,
        progress: ProgressCounter? = nil,
        cancel: CancelToken? = nil
    ) throws -> ScanOutcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw OrganizerError.invalidRoot(root.path)
        }
        if cancel?.isCancelled == true { throw OrganizerError.cancelled }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [],
            errorHandler: { _, _ in
                progress?.increment(ProgressKeys.scanErrors)
                return true  // 单项失败继续遍历
            }
        ) else {
            throw OrganizerError.scanFailed(root.path)
        }

        let rootPath = root.standardizedFileURL.path
        var files: [FileInfo] = []
        files.reserveCapacity(256)
        var directories = Set<String>()
        var parents = Set<String>()

        for case let url as URL in enumerator {
            if let cancel, cancel.isCancelled { throw OrganizerError.cancelled }
            guard let values = try? url.resourceValues(forKeys: Self.resourceKeys) else {
                progress?.increment(ProgressKeys.scanErrors)
                continue
            }
            // 符号链接一律跳过（既不当作文件，也不深入）
            if values.isSymbolicLink == true { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }

            if values.isRegularFile == true {
                let relative = String(path.dropFirst(rootPath.count + 1))
                guard !relative.isEmpty else { continue }
                let size = Int64(values.fileSize ?? 0)
                files.append(FileInfo(
                    path: path,
                    relativePath: relative,
                    size: size,
                    creationDate: values.creationDate,
                    modificationDate: values.contentModificationDate
                ))
                parents.insert((relative as NSString).deletingLastPathComponent)
                progress?.incrementScan(files: 1, bytes: size)
            } else if values.isDirectory == true && path != rootPath {
                let relative = String(path.dropFirst(rootPath.count + 1))
                directories.insert(relative)
                parents.insert((relative as NSString).deletingLastPathComponent)
            }
        }

        files.sort { $0.relativePath < $1.relativePath }
        let emptyDirectories = directories.subtracting(parents)
        return ScanOutcome(
            root: root.standardizedFileURL,
            files: files,
            directories: directories,
            emptyDirectories: emptyDirectories
        )
    }
}
