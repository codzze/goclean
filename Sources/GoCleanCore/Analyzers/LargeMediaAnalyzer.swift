import Darwin
import Foundation

/// Finds large videos, audio, raw photos, archives, and oversized files above a configurable byte threshold.
public struct LargeMediaAnalyzer: Sendable {
    public static let videoExtensions: Set<String> = [
        "mov", "mp4", "mkv", "avi", "m4v", "webm", "flv", "wmv", "mts", "m2ts", "mpg", "mpeg", "ts", "r3d", "braw", "prores"
    ]
    public static let audioExtensions: Set<String> = [
        "wav", "flac", "aiff", "aif", "mp3", "m4a", "aac", "ogg", "alac"
    ]
    public static let imageExtensions: Set<String> = [
        "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "psb", "tiff", "tif", "heic", "png", "jpg", "jpeg", "exr"
    ]
    public static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "7z", "rar", "dmg", "iso", "img", "sparsebundle", "sparseimage", "qcow2", "vmdk"
    ]

    private let rootDirectory: URL
    private let homeDirectory: URL

    public init(
        rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public static func classifyMediaKind(fileName: String) -> LargeMediaKind {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if imageExtensions.contains(ext) { return .image }
        if archiveExtensions.contains(ext) { return .archive }
        return .other
    }

    public func analyze(
        existingTree: FileNode? = nil,
        minimumBytes: UInt64 = 50 * 1024 * 1024,
        videosOnly: Bool = false,
        includeSystemFiles: Bool = false
    ) async -> [CleanupItem] {
        await Task.detached(priority: .userInitiated) {
            let classifier = FileSafetyClassifier(homeDirectory: homeDirectory)
            var items: [CleanupItem] = []

            if let existingTree {
                existingTree.walk { node in
                    let nodeURL = node.url
                    if node.isDirectory {
                        if node.name == ".Trash" || node.name == ".git" || node.name == "node_modules" {
                            return false
                        }
                        if !includeSystemFiles {
                            if node.name.hasSuffix(".app") || node.name.hasSuffix(".framework") ||
                                node.name.hasSuffix(".bundle") || node.name.hasSuffix(".photoslibrary") ||
                                node.name.hasSuffix(".kext") || node.name == "CoreSimulator" ||
                                classifier.isSystemOrProtectedPath(nodeURL) ||
                                classifier.isInsideUserLibrary(nodeURL) ||
                                nodeURL.standardizedFileURL.path == "\(homeDirectory.path)/Library" ||
                                nodeURL.standardizedFileURL.path == "/Library" {
                                return false
                            }
                        }
                        // Prune entire subtrees smaller than threshold
                        return node.physicalSize >= minimumBytes
                    }
                    guard !node.isCloudPlaceholder, node.physicalSize >= minimumBytes else { return false }

                    let isSystem = classifier.isSystemOrProtectedPath(nodeURL) || classifier.isInsideUserLibrary(nodeURL)
                    if !includeSystemFiles && isSystem {
                        return false
                    }

                    let kind = Self.classifyMediaKind(fileName: node.name)
                    if videosOnly && kind != .video { return false }

                    let defaultConf: ConfidenceLevel
                    let defaultReason: String
                    if isSystem {
                        defaultConf = .danger
                        defaultReason = "System or Library file — do not remove unless you know its purpose."
                    } else if kind == .archive && nodeURL.path.contains("/Downloads/") {
                        defaultConf = .high
                        defaultReason = "Safe to clean: downloaded archive/installer in Downloads."
                    } else if kind == .video {
                        defaultConf = .high
                        defaultReason = "User video file (no system impact). Preview before moving to Trash."
                    } else {
                        defaultConf = .review
                        defaultReason = "Large user \(kind.rawValue.lowercased()) occupying significant local storage."
                    }

                    let evaluated = classifier.classify(
                        url: nodeURL,
                        defaultConfidence: defaultConf,
                        defaultRationale: defaultReason
                    )

                    items.append(CleanupItem(
                        url: nodeURL,
                        displayName: node.name,
                        subtitle: nodeURL.deletingLastPathComponent().path,
                        size: node.physicalSize,
                        bucket: .largeMedia,
                        confidence: evaluated.confidence,
                        rationale: evaluated.rationale,
                        lastModified: node.modificationDate,
                        tag: kind.rawValue,
                        isDirectory: false
                    ))
                    return false
                }
            } else {
                items = Self.scanDirectly(
                    root: rootDirectory,
                    home: homeDirectory,
                    minimumBytes: minimumBytes,
                    videosOnly: videosOnly,
                    includeSystemFiles: includeSystemFiles
                )
            }

            return items.sorted { $0.size > $1.size }
        }.value
    }

    private static func scanDirectly(
        root: URL,
        home: URL,
        minimumBytes: UInt64,
        videosOnly: Bool,
        includeSystemFiles: Bool
    ) -> [CleanupItem] {
        let sfDatalessFlag: UInt32 = 0x4000_0000
        let classifier = FileSafetyClassifier(homeDirectory: home)
        var items: [CleanupItem] = []
        var stack: [String] = [root.path]

        while let currentPath = stack.popLast() {
            if Task.isCancelled { break }
            guard let dir = opendir(currentPath) else { continue }
            let fd = dirfd(dir)

            while let entryPtr = readdir(dir) {
                let name = withUnsafePointer(to: entryPtr.pointee.d_name) { ptr -> String in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." || name == ".Trash" || name == ".git" || name == "node_modules" {
                    continue
                }
                if !includeSystemFiles && (name.hasSuffix(".app") || name.hasSuffix(".framework") || name.hasSuffix(".photoslibrary") || name.hasSuffix(".bundle")) {
                    continue
                }

                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let mode = st.st_mode & S_IFMT

                let fullPath = currentPath == "/" ? "/\(name)" : "\(currentPath)/\(name)"
                let fullURL = URL(fileURLWithPath: fullPath)

                if mode == S_IFDIR {
                    if !includeSystemFiles {
                        if classifier.isSystemOrProtectedPath(fullURL) ||
                            fullPath == "\(home.path)/Library" ||
                            fullPath == "/Library" ||
                            fullPath == "/Volumes" ||
                            fullPath == "/dev" {
                            continue
                        }
                    }
                    stack.append(fullPath)
                } else if mode == S_IFREG {
                    let isDataless = (st.st_flags & sfDatalessFlag) != 0
                    if isDataless { continue }
                    let phys = UInt64(max(0, st.st_blocks)) * 512
                    guard phys >= minimumBytes else { continue }

                    let isSystem = classifier.isSystemOrProtectedPath(fullURL) || classifier.isInsideUserLibrary(fullURL)
                    if !includeSystemFiles && isSystem { continue }

                    let kind = classifyMediaKind(fileName: name)
                    if videosOnly && kind != .video { continue }

                    let defaultConf: ConfidenceLevel
                    let defaultReason: String
                    if isSystem {
                        defaultConf = .danger
                        defaultReason = "System or Library file — do not remove unless you know its purpose."
                    } else if kind == .archive && fullPath.contains("/Downloads/") {
                        defaultConf = .high
                        defaultReason = "Safe to clean: downloaded archive/installer in Downloads."
                    } else if kind == .video {
                        defaultConf = .high
                        defaultReason = "User video file (no system impact). Preview before moving to Trash."
                    } else {
                        defaultConf = .review
                        defaultReason = "Large user \(kind.rawValue.lowercased()) occupying significant local storage."
                    }

                    let evaluated = classifier.classify(
                        url: fullURL,
                        defaultConfidence: defaultConf,
                        defaultRationale: defaultReason
                    )

                    let modDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                    items.append(CleanupItem(
                        url: fullURL,
                        displayName: name,
                        subtitle: fullURL.deletingLastPathComponent().path,
                        size: phys,
                        bucket: .largeMedia,
                        confidence: evaluated.confidence,
                        rationale: evaluated.rationale,
                        lastModified: modDate,
                        tag: kind.rawValue,
                        isDirectory: false
                    ))
                }
            }
            closedir(dir)
        }

        return items
    }
}
