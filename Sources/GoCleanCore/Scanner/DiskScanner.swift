import Darwin
import Foundation
import os

/// Live progress snapshot streamed from `ConcurrentScanEngine` to the UI.
public struct ScanProgress: Sendable {
    public let scannedFiles: Int
    public let scannedDirectories: Int
    public let scannedBytes: UInt64
    public let currentPath: String
    public let isComplete: Bool
    public let rootNode: FileNode?
    public let elapsedSeconds: TimeInterval

    public init(
        scannedFiles: Int,
        scannedDirectories: Int,
        scannedBytes: UInt64,
        currentPath: String,
        isComplete: Bool,
        rootNode: FileNode?,
        elapsedSeconds: TimeInterval
    ) {
        self.scannedFiles = scannedFiles
        self.scannedDirectories = scannedDirectories
        self.scannedBytes = scannedBytes
        self.currentPath = currentPath
        self.isComplete = isComplete
        self.rootNode = rootNode
        self.elapsedSeconds = elapsedSeconds
    }
}

/// High-performance, APFS-aware concurrent disk scanner built on POSIX `opendir` + `fstatat`.
///
/// Key properties:
/// - Measures actual physical disk allocation (`st_blocks * 512`).
/// - Detects macOS `SF_DATALESS` cloud-only placeholders (iCloud Drive, OneDrive, Dropbox) and counts them as 0 local bytes.
/// - Deduplicates hard links via `(st_dev, st_ino)` for files with `st_nlink > 1`.
/// - Avoids macOS APFS firmlink double-counting (`/System/Volumes`, `/Volumes`, `/dev`, `/net`).
public final class ConcurrentScanEngine: Sendable {
    /// Darwin `SF_DATALESS` flag (`0x40000000`) indicating a cloud placeholder with no local blocks.
    private static let sfDatalessFlag: UInt32 = 0x4000_0000

    /// Paths skipped when scanning macOS root `/` to prevent virtual mounts and firmlink recursion loops.
    private static let rootExcludedPaths: Set<String> = [
        "/dev",
        "/net",
        "/home",
        "/Volumes",
        "/System/Volumes"
    ]

    public init() {}

    /// Enumerates mounted local and external volumes with APFS capacity telemetry.
    public static func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRootFileSystemKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var volumes: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard (values.volumeIsLocal ?? true) else { continue }
            let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
            guard total > 0 else { continue }
            let available = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            let importantAvailable = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? Int64(available)))
            let isRoot = values.volumeIsRootFileSystem ?? (url.path == "/")
            let isRemovable = values.volumeIsRemovable ?? false
            let name = values.volumeName ?? (isRoot ? "Macintosh HD" : url.lastPathComponent)

            volumes.append(VolumeInfo(
                id: url.standardizedFileURL.path,
                name: name,
                url: url.standardizedFileURL,
                totalCapacity: total,
                availableCapacity: available,
                importantAvailableCapacity: importantAvailable,
                isRootVolume: isRoot,
                isRemovable: isRemovable
            ))
        }

        return volumes.sorted { lhs, rhs in
            if lhs.isRootVolume != rhs.isRootVolume {
                return lhs.isRootVolume
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Fast synchronous physical size calculation for a single file or directory (used by analyzers & app discovery).
    public static func calculatePhysicalSize(at url: URL) -> (physical: UInt64, logical: UInt64, fileCount: Int, latestModDate: Date?) {
        let path = url.standardizedFileURL.path
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return (0, 0, 0, nil)
        }
        let modDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        let mode = st.st_mode & S_IFMT
        if mode != S_IFDIR {
            let isDataless = (st.st_flags & sfDatalessFlag) != 0
            let phys: UInt64 = isDataless ? 0 : UInt64(max(0, st.st_blocks)) * 512
            let log: UInt64 = UInt64(max(0, st.st_size))
            return (phys, log, 1, modDate)
        }

        var seenInodes = Set<InodeKey>()
        var totalPhys: UInt64 = 0
        var totalLog: UInt64 = 0
        var totalFiles = 0
        var newestMod = modDate

        var stack: [String] = [path]
        while let currentDir = stack.popLast() {
            guard let dir = opendir(currentDir) else { continue }
            defer { closedir(dir) }
            let fd = dirfd(dir)

            while let entryPtr = readdir(dir) {
                let name = withUnsafePointer(to: entryPtr.pointee.d_name) { ptr -> String in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }

                var childStat = stat()
                guard fstatat(fd, name, &childStat, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let childMode = childStat.st_mode & S_IFMT

                if childMode == S_IFDIR {
                    let childPath = currentDir == "/" ? "/\(name)" : "\(currentDir)/\(name)"
                    stack.append(childPath)
                } else if childMode == S_IFREG {
                    let isDataless = (childStat.st_flags & sfDatalessFlag) != 0
                    if childStat.st_nlink > 1 {
                        let key = InodeKey(dev: childStat.st_dev, ino: childStat.st_ino)
                        if !seenInodes.insert(key).inserted {
                            continue
                        }
                    }
                    let phys: UInt64 = isDataless ? 0 : UInt64(max(0, childStat.st_blocks)) * 512
                    totalPhys &+= phys
                    totalLog &+= UInt64(max(0, childStat.st_size))
                    totalFiles += 1
                    let childMod = Date(timeIntervalSince1970: TimeInterval(childStat.st_mtimespec.tv_sec))
                    if childMod > newestMod {
                        newestMod = childMod
                    }
                }
            }
        }

        return (totalPhys, totalLog, totalFiles, newestMod)
    }

    /// Streams live scan progress and finishes with a finalized `FileNode` tree rooted at `targetURL`.
    public func scan(
        url targetURL: URL,
        maxConcurrency: Int = max(4, ProcessInfo.processInfo.activeProcessorCount)
    ) -> AsyncThrowingStream<ScanProgress, Error> {
        let standardized = targetURL.standardizedFileURL
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startTime = Date()
                let state = ScanSharedState()
                let isSystemRoot = standardized.path == "/"

                let rootName = isSystemRoot ? "Macintosh HD" : standardized.lastPathComponent
                let rootNode = FileNode(
                    name: rootName,
                    isDirectory: true,
                    rootBaseURL: standardized
                )

                // Read immediate top-level entries to fan out across worker tasks
                guard let topEntries = Self.readDirectoryEntries(
                    atPath: standardized.path,
                    isSystemRoot: isSystemRoot
                ) else {
                    continuation.yield(ScanProgress(
                        scannedFiles: 0,
                        scannedDirectories: 1,
                        scannedBytes: 0,
                        currentPath: standardized.path,
                        isComplete: true,
                        rootNode: rootNode,
                        elapsedSeconds: Date().timeIntervalSince(startTime)
                    ))
                    continuation.finish()
                    return
                }

                var directChildNodes: [FileNode] = []
                var subdirsToScan: [(path: String, node: FileNode)] = []

                for entry in topEntries {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let modDate = Date(timeIntervalSince1970: TimeInterval(entry.stat.st_mtimespec.tv_sec))
                    if entry.isDirectory {
                        let dirNode = FileNode(
                            name: entry.name,
                            isDirectory: true,
                            modificationDate: modDate,
                            parent: rootNode
                        )
                        directChildNodes.append(dirNode)
                        subdirsToScan.append((entry.fullPath, dirNode))
                    } else if entry.isRegularFile {
                        let isDataless = (entry.stat.st_flags & Self.sfDatalessFlag) != 0
                        var phys: UInt64 = isDataless ? 0 : UInt64(max(0, entry.stat.st_blocks)) * 512
                        let log: UInt64 = UInt64(max(0, entry.stat.st_size))
                        if entry.stat.st_nlink > 1 {
                            let key = InodeKey(dev: entry.stat.st_dev, ino: entry.stat.st_ino)
                            if !state.markInodeSeen(key) {
                                phys = 0
                            }
                        }
                        let fileNode = FileNode(
                            name: entry.name,
                            isDirectory: false,
                            physicalSize: phys,
                            logicalSize: log,
                            fileCount: 1,
                            modificationDate: modDate,
                            isCloudPlaceholder: isDataless,
                            parent: rootNode
                        )
                        directChildNodes.append(fileNode)
                        state.addFileStats(bytes: phys, path: entry.fullPath)
                    }
                }

                rootNode.children = directChildNodes

                // Periodic progress emitter while workers run
                let progressTask = Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(90))
                        if Task.isCancelled { break }
                        let snap = state.snapshot()
                        // Build lightweight top-level snapshot for live Orbital Map rendering
                        let liveRoot = FileNode(
                            name: rootNode.name,
                            isDirectory: true,
                            physicalSize: snap.bytes,
                            logicalSize: snap.bytes,
                            fileCount: snap.files,
                            rootBaseURL: standardized
                        )
                        liveRoot.children = directChildNodes
                            .map { child in
                                FileNode(
                                    id: child.id,
                                    name: child.name,
                                    isDirectory: child.isDirectory,
                                    physicalSize: child.physicalSize,
                                    logicalSize: child.logicalSize,
                                    fileCount: child.fileCount,
                                    modificationDate: child.modificationDate,
                                    category: child.category,
                                    isCloudPlaceholder: child.isCloudPlaceholder,
                                    parent: liveRoot
                                )
                            }
                            .sorted { $0.physicalSize > $1.physicalSize }

                        continuation.yield(ScanProgress(
                            scannedFiles: snap.files,
                            scannedDirectories: snap.dirs,
                            scannedBytes: snap.bytes,
                            currentPath: snap.currentPath,
                            isComplete: false,
                            rootNode: liveRoot,
                            elapsedSeconds: Date().timeIntervalSince(startTime)
                        ))
                    }
                }

                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        var index = 0
                        let limit = max(1, min(maxConcurrency, subdirsToScan.count))

                        for _ in 0..<limit {
                            let item = subdirsToScan[index]
                            index += 1
                            group.addTask {
                                try Self.scanSubtree(
                                    path: item.path,
                                    node: item.node,
                                    isSystemRoot: isSystemRoot,
                                    state: state
                                )
                            }
                        }

                        while try await group.next() != nil {
                            try Task.checkCancellation()
                            if index < subdirsToScan.count {
                                let item = subdirsToScan[index]
                                index += 1
                                group.addTask {
                                    try Self.scanSubtree(
                                        path: item.path,
                                        node: item.node,
                                        isSystemRoot: isSystemRoot,
                                        state: state
                                    )
                                }
                            }
                        }
                    }
                } catch {
                    progressTask.cancel()
                    continuation.finish(throwing: error)
                    return
                }

                progressTask.cancel()
                rootNode.finalizeTree()
                let finalSnap = state.snapshot()

                continuation.yield(ScanProgress(
                    scannedFiles: rootNode.fileCount,
                    scannedDirectories: finalSnap.dirs + 1,
                    scannedBytes: rootNode.physicalSize,
                    currentPath: standardized.path,
                    isComplete: true,
                    rootNode: rootNode,
                    elapsedSeconds: Date().timeIntervalSince(startTime)
                ))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private POSIX Helpers

    private struct DirectoryEntry {
        let name: String
        let fullPath: String
        let stat: stat
        let isDirectory: Bool
        let isRegularFile: Bool
    }

    private struct InodeKey: Hashable, Sendable {
        let dev: dev_t
        let ino: ino_t
    }

    private final class ScanSharedState: @unchecked Sendable {
        struct Counters {
            var files: Int = 0
            var dirs: Int = 0
            var bytes: UInt64 = 0
            var currentPath: String = ""
        }

        private let counterLock = OSAllocatedUnfairLock(initialState: Counters())
        private let inodeLock = OSAllocatedUnfairLock(initialState: Set<InodeKey>())

        func markInodeSeen(_ key: InodeKey) -> Bool {
            inodeLock.withLock { set in
                set.insert(key).inserted
            }
        }

        func addFileStats(bytes: UInt64, path: String) {
            counterLock.withLock { c in
                c.files += 1
                c.bytes &+= bytes
                c.currentPath = path
            }
        }

        func addBatchStats(files: Int, dirs: Int, bytes: UInt64, path: String) {
            counterLock.withLock { c in
                c.files += files
                c.dirs += dirs
                c.bytes &+= bytes
                c.currentPath = path
            }
        }

        func snapshot() -> Counters {
            counterLock.withLock { $0 }
        }
    }

    private static func readDirectoryEntries(atPath path: String, isSystemRoot: Bool) -> [DirectoryEntry]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        let fd = dirfd(dir)

        var entries: [DirectoryEntry] = []
        while let entryPtr = readdir(dir) {
            let name = withUnsafePointer(to: entryPtr.pointee.d_name) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }

            let fullPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            if isSystemRoot && rootExcludedPaths.contains(fullPath) {
                continue
            }

            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            // Skip symbolic links to avoid loops and double-counting
            if mode == S_IFLNK { continue }

            entries.append(DirectoryEntry(
                name: name,
                fullPath: fullPath,
                stat: st,
                isDirectory: mode == S_IFDIR,
                isRegularFile: mode == S_IFREG
            ))
        }
        return entries
    }

    private static func scanSubtree(
        path: String,
        node: FileNode,
        isSystemRoot: Bool,
        state: ScanSharedState
    ) throws {
        try Task.checkCancellation()

        // Explicit stack for deep directories to avoid stack overflow on deeply nested node_modules
        var stack: [(path: String, node: FileNode)] = [(path, node)]
        var visitedNodes: [FileNode] = []

        var batchFiles = 0
        var batchDirs = 0
        var batchBytes: UInt64 = 0

        while let current = stack.popLast() {
            if batchDirs % 64 == 0 {
                try Task.checkCancellation()
            }

            guard let dir = opendir(current.path) else { continue }
            let fd = dirfd(dir)
            var children: [FileNode] = []
            var localBytes: UInt64 = 0
            var localFiles = 0

            while let entryPtr = readdir(dir) {
                let name = withUnsafePointer(to: entryPtr.pointee.d_name) { ptr -> String in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }

                let childPath = current.path == "/" ? "/\(name)" : "\(current.path)/\(name)"
                if isSystemRoot && rootExcludedPaths.contains(childPath) {
                    continue
                }

                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let mode = st.st_mode & S_IFMT
                if mode == S_IFLNK { continue }

                let modDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))

                if mode == S_IFDIR {
                    let childDir = FileNode(
                        name: name,
                        isDirectory: true,
                        modificationDate: modDate,
                        parent: current.node
                    )
                    children.append(childDir)
                    stack.append((childPath, childDir))
                } else if mode == S_IFREG {
                    let isDataless = (st.st_flags & sfDatalessFlag) != 0
                    var phys: UInt64 = isDataless ? 0 : UInt64(max(0, st.st_blocks)) * 512
                    let log: UInt64 = UInt64(max(0, st.st_size))

                    if st.st_nlink > 1 {
                        let key = InodeKey(dev: st.st_dev, ino: st.st_ino)
                        if !state.markInodeSeen(key) {
                            phys = 0
                        }
                    }

                    let fileNode = FileNode(
                        name: name,
                        isDirectory: false,
                        physicalSize: phys,
                        logicalSize: log,
                        fileCount: 1,
                        modificationDate: modDate,
                        isCloudPlaceholder: isDataless,
                        parent: current.node
                    )
                    children.append(fileNode)
                    localBytes &+= phys
                    localFiles += 1
                }
            }

            closedir(dir)
            current.node.children = children
            visitedNodes.append(current.node)

            // Propagate live approximate size to top-level subtree node for smooth live Orbital Map growth
            if current.node !== node {
                node.physicalSize &+= localBytes
                node.fileCount += localFiles
            } else {
                node.physicalSize &+= localBytes
                node.fileCount += localFiles
            }

            batchFiles += localFiles
            batchDirs += 1
            batchBytes &+= localBytes

            if batchDirs >= 32 || batchFiles >= 500 {
                state.addBatchStats(files: batchFiles, dirs: batchDirs, bytes: batchBytes, path: current.path)
                batchFiles = 0
                batchDirs = 0
                batchBytes = 0
            }
        }

        if batchFiles > 0 || batchDirs > 0 {
            state.addBatchStats(files: batchFiles, dirs: batchDirs, bytes: batchBytes, path: path)
        }

        // Bottom-up size aggregation & sorting
        for dirNode in visitedNodes.reversed() {
            var phys: UInt64 = 0
            var log: UInt64 = 0
            var count = 0
            for child in dirNode.children {
                phys &+= child.physicalSize
                log &+= child.logicalSize
                count += child.isDirectory ? child.fileCount : 1
            }
            dirNode.children.sort { lhs, rhs in
                if lhs.physicalSize != rhs.physicalSize {
                    return lhs.physicalSize > rhs.physicalSize
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            dirNode.physicalSize = phys
            dirNode.logicalSize = log
            dirNode.fileCount = count
        }
    }
}
