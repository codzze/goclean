import CryptoKit
import Darwin
import Foundation

/// Live progress reported during the 3-stage duplicate scan.
public struct DuplicateScanProgress: Sendable {
    public let stage: String
    public let filesInspected: Int
    public let candidateGroups: Int
    public let verifiedGroups: Int

    public init(stage: String, filesInspected: Int, candidateGroups: Int, verifiedGroups: Int) {
        self.stage = stage
        self.filesInspected = filesInspected
        self.candidateGroups = candidateGroups
        self.verifiedGroups = verifiedGroups
    }
}

/// High-speed 3-stage duplicate file finder:
/// 1. Group regular non-cloud files by exact logical byte size (skipping hardlinks with identical device+inode).
/// 2. Compute fast 16KB partial hash (first 8KB + last 8KB) for size-colliding files.
/// 3. Verify partial-hash collisions using streaming full-file `CryptoKit.SHA256`.
public struct DuplicateFinder: Sendable {
    private static let sfDatalessFlag: UInt32 = 0x4000_0000
    private static let partialWindowSize = 8_192
    private static let streamChunkSize = 262_144

    private static let skippedDirectoryNames: Set<String> = [
        ".git", ".Trash", "node_modules", ".build", "DerivedData", "Library"
    ]

    public init() {}

    public func findDuplicates(
        in rootURL: URL,
        minimumBytes: UInt64 = 1_048_576,
        skipLibrary: Bool = true,
        onProgress: (@Sendable (DuplicateScanProgress) -> Void)? = nil
    ) async throws -> [DuplicateGroup] {
        try await Task.detached(priority: .userInitiated) {
            // Stage 1: Exact byte size grouping
            var sizeBuckets: [UInt64: [CandidateFile]] = [:]
            var seenInodes = Set<InodeKey>()
            var inspectedCount = 0

            var stack: [String] = [rootURL.standardizedFileURL.path]
            let rootPath = rootURL.standardizedFileURL.path

            while let currentPath = stack.popLast() {
                try Task.checkCancellation()
                guard let dir = opendir(currentPath) else { continue }
                let fd = dirfd(dir)

                while let entryPtr = readdir(dir) {
                    let name = withUnsafePointer(to: entryPtr.pointee.d_name) { ptr -> String in
                        ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                            String(cString: $0)
                        }
                    }
                    if name == "." || name == ".." { continue }
                    if name.hasSuffix(".app") || name.hasSuffix(".framework") || name.hasSuffix(".photoslibrary") || name.hasSuffix(".bundle") {
                        continue
                    }

                    var st = stat()
                    guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                    let mode = st.st_mode & S_IFMT
                    let fullPath = currentPath == "/" ? "/\(name)" : "\(currentPath)/\(name)"

                    if mode == S_IFDIR {
                        if Self.skippedDirectoryNames.contains(name) {
                            if name == "Library" && (!skipLibrary || currentPath != rootPath) {
                                // allow if skipLibrary == false or nested
                            } else {
                                continue
                            }
                        }
                        stack.append(fullPath)
                    } else if mode == S_IFREG {
                        inspectedCount += 1
                        if inspectedCount % 2000 == 0 {
                            onProgress?(DuplicateScanProgress(
                                stage: "Indexing file sizes…",
                                filesInspected: inspectedCount,
                                candidateGroups: 0,
                                verifiedGroups: 0
                            ))
                        }
                        let isDataless = (st.st_flags & Self.sfDatalessFlag) != 0
                        if isDataless { continue }

                        let size = UInt64(max(0, st.st_size))
                        guard size >= minimumBytes else { continue }

                        // Skip hard links pointing to the same physical inode
                        if st.st_nlink > 1 {
                            let key = InodeKey(dev: st.st_dev, ino: st.st_ino)
                            if !seenInodes.insert(key).inserted {
                                continue
                            }
                        }

                        let modDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                        let createDate = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec))
                        sizeBuckets[size, default: []].append(CandidateFile(
                            url: URL(fileURLWithPath: fullPath),
                            size: size,
                            modificationDate: modDate,
                            creationDate: createDate
                        ))
                    }
                }
                closedir(dir)
            }

            let collidingSizeBuckets = sizeBuckets.values.filter { $0.count >= 2 }
            onProgress?(DuplicateScanProgress(
                stage: "Computing fast partial hashes…",
                filesInspected: inspectedCount,
                candidateGroups: collidingSizeBuckets.count,
                verifiedGroups: 0
            ))

            // Stage 2: Partial 8KB head + 8KB tail fingerprint
            var partialBuckets: [String: [CandidateFile]] = [:]
            for group in collidingSizeBuckets {
                try Task.checkCancellation()
                for file in group {
                    if let partial = Self.partialHash(url: file.url, size: file.size) {
                        let key = "\(file.size):\(partial)"
                        partialBuckets[key, default: []].append(file)
                    }
                }
            }

            let partialCollisions = partialBuckets.values.filter { $0.count >= 2 }
            onProgress?(DuplicateScanProgress(
                stage: "Verifying full SHA-256 checksums…",
                filesInspected: inspectedCount,
                candidateGroups: partialCollisions.count,
                verifiedGroups: 0
            ))

            // Stage 3: Full streaming SHA-256 verification
            var finalGroups: [DuplicateGroup] = []
            for group in partialCollisions {
                try Task.checkCancellation()
                var byFullHash: [String: [CandidateFile]] = [:]
                for file in group {
                    if let sha = Self.fullSHA256(url: file.url) {
                        byFullHash[sha, default: []].append(file)
                    }
                }
                for (sha, matched) in byFullHash where matched.count >= 2 {
                    let entries = matched
                        .map {
                            DuplicateFileEntry(
                                url: $0.url,
                                size: $0.size,
                                modificationDate: $0.modificationDate,
                                creationDate: $0.creationDate
                            )
                        }
                        .sorted { $0.url.path < $1.url.path }

                    finalGroups.append(DuplicateGroup(
                        sha256: sha,
                        fileSize: matched[0].size,
                        files: entries
                    ))
                }
            }

            let sorted = finalGroups.sorted { $0.wastedSize > $1.wastedSize }
            onProgress?(DuplicateScanProgress(
                stage: "Complete",
                filesInspected: inspectedCount,
                candidateGroups: partialCollisions.count,
                verifiedGroups: sorted.count
            ))
            return sorted
        }.value
    }

    /// Selects duplicate copies to remove while guaranteeing at least one copy in every group is kept.
    public static func selectDuplicates(
        in groups: [DuplicateGroup],
        strategy: DuplicateSelectionStrategy
    ) -> [CleanupItem] {
        var toRemove: [CleanupItem] = []

        for group in groups where group.files.count >= 2 {
            let sorted: [DuplicateFileEntry]
            switch strategy {
            case .keepOldest:
                sorted = group.files.sorted { lhs, rhs in
                    let lDate = lhs.creationDate ?? lhs.modificationDate ?? .distantFuture
                    let rDate = rhs.creationDate ?? rhs.modificationDate ?? .distantFuture
                    if lDate != rDate { return lDate < rDate }
                    return lhs.url.path.count < rhs.url.path.count
                }
            case .keepNewest:
                sorted = group.files.sorted { lhs, rhs in
                    let lDate = lhs.modificationDate ?? lhs.creationDate ?? .distantPast
                    let rDate = rhs.modificationDate ?? rhs.creationDate ?? .distantPast
                    if lDate != rDate { return lDate > rDate }
                    return lhs.url.path.count < rhs.url.path.count
                }
            case .keepShortestPath:
                sorted = group.files.sorted { lhs, rhs in
                    if lhs.url.path.count != rhs.url.path.count {
                        return lhs.url.path.count < rhs.url.path.count
                    }
                    return lhs.url.path < rhs.url.path
                }
            }

            // Keep index 0, mark all remaining copies for cleanup
            for copy in sorted.dropFirst() {
                toRemove.append(copy.asCleanupItem())
            }
        }

        return toRemove
    }

    // MARK: - Private Hashing Helpers

    private struct InodeKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    private struct CandidateFile {
        let url: URL
        let size: UInt64
        let modificationDate: Date?
        let creationDate: Date?
    }

    private static func partialHash(url: URL, size: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: partialWindowSize), !head.isEmpty else {
            return nil
        }
        hasher.update(data: head)

        if size > UInt64(partialWindowSize) {
            let tailOffset = size > UInt64(partialWindowSize) ? size - UInt64(partialWindowSize) : 0
            try? handle.seek(toOffset: tailOffset)
            if let tail = try? handle.read(upToCount: partialWindowSize) {
                hasher.update(data: tail)
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fullSHA256(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: streamChunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
