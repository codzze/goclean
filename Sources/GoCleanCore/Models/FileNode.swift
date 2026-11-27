import Foundation

/// Semantic file category used for visual coloring in the Luminous Orbital Map and analytics.
public enum FileCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case applications = "Applications"
    case media = "Media"
    case developer = "Developer"
    case caches = "Caches"
    case documents = "Documents"
    case archives = "Archives"
    case system = "System"
    case other = "Other"

    public static func classify(name: String, isDirectory: Bool, parentName: String? = nil) -> FileCategory {
        let lower = name.lowercased()

        if isDirectory {
            if lower.hasSuffix(".app") || lower == "applications" {
                return .applications
            }
            if lower == "node_modules" || lower == "deriveddata" || lower == "target" ||
                lower == ".build" || lower == "pods" || lower == ".gradle" ||
                lower == ".next" || lower == ".nuxt" || lower == ".venv" || lower == "venv" ||
                lower == "__pycache__" || lower == ".git" || lower == "developer" {
                return .developer
            }
            if lower == "caches" || lower.contains("cache") || lower == "logs" || lower == "tmp" {
                return .caches
            }
            if lower == "movies" || lower == "music" || lower == "pictures" || lower == "photos" {
                return .media
            }
            if lower == "documents" || lower == "desktop" {
                return .documents
            }
            if lower == "system" || lower == "library" || lower == "private" {
                return .system
            }
            return .other
        }

        let ext = (lower as NSString).pathExtension
        switch ext {
        case "app", "pkg", "mpkg", "prefpane", "plugin", "kext", "framework", "dylib":
            return .applications
        case "mov", "mp4", "mkv", "avi", "m4v", "webm", "flv", "wmv", "mts", "m2ts",
             "mp3", "wav", "flac", "aac", "m4a", "ogg", "aiff",
             "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "raw", "cr2", "nef", "arw", "dng", "tiff", "psd", "svg":
            return .media
        case "swift", "rs", "ts", "tsx", "js", "jsx", "py", "go", "c", "cpp", "h", "hpp", "m", "mm",
             "java", "kt", "rb", "php", "cs", "sh", "zsh", "bash", "json", "yaml", "yml", "toml",
             "xml", "html", "css", "scss", "sql", "o", "a", "pyc", "class", "jar", "wasm", "dSYM", "map":
            return .developer
        case "cache", "log", "ips", "crash", "diag", "dmp", "core", "tmp", "temp", "swp", "ds_store":
            return .caches
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
             "txt", "md", "rtf", "csv", "epub", "sketch", "fig":
            return .documents
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "img", "sparseimage", "sparsebundle":
            return .archives
        default:
            if let parent = parentName?.lowercased(), parent.contains("cache") {
                return .caches
            }
            return .other
        }
    }
}

/// Memory-compact tree node representing a scanned file or directory.
/// Stores only the single path component `name` and reconstructs the full URL via parent links.
public final class FileNode: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let name: String
    public let isDirectory: Bool
    public var physicalSize: UInt64
    public var logicalSize: UInt64
    public var fileCount: Int
    public let modificationDate: Date?
    public let category: FileCategory
    public let isCloudPlaceholder: Bool
    public weak var parent: FileNode?
    public var children: [FileNode]

    /// Set only on the root node of a scan tree.
    private let rootBaseURL: URL?

    public init(
        id: UUID = UUID(),
        name: String,
        isDirectory: Bool,
        physicalSize: UInt64 = 0,
        logicalSize: UInt64 = 0,
        fileCount: Int = 0,
        modificationDate: Date? = nil,
        category: FileCategory? = nil,
        isCloudPlaceholder: Bool = false,
        parent: FileNode? = nil,
        children: [FileNode] = [],
        rootBaseURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.physicalSize = physicalSize
        self.logicalSize = logicalSize
        self.fileCount = fileCount
        self.modificationDate = modificationDate
        self.category = category ?? FileCategory.classify(name: name, isDirectory: isDirectory, parentName: parent?.name)
        self.isCloudPlaceholder = isCloudPlaceholder
        self.parent = parent
        self.children = children
        self.rootBaseURL = rootBaseURL
    }

    /// Reconstructs the full file URL by walking up the parent chain.
    public var url: URL {
        if let rootBaseURL {
            return rootBaseURL
        }
        var components: [String] = []
        var cursor: FileNode? = self
        var base: URL?
        while let node = cursor {
            if let r = node.rootBaseURL {
                base = r
                break
            }
            components.append(node.name)
            cursor = node.parent
        }
        var built = base ?? URL(fileURLWithPath: "/")
        for component in components.reversed() {
            built.appendPathComponent(component, isDirectory: false)
        }
        return built
    }

    /// Ancestor chain from root down to `self` (inclusive) for breadcrumb navigation.
    public var breadcrumbChain: [FileNode] {
        var chain: [FileNode] = []
        var cursor: FileNode? = self
        while let node = cursor {
            chain.append(node)
            cursor = node.parent
        }
        return chain.reversed()
    }

    /// Dominant category for directories based on the largest children, or own category for files.
    public var dominantCategory: FileCategory {
        guard isDirectory, !children.isEmpty else { return category }
        if category != .other { return category }
        var totals: [FileCategory: UInt64] = [:]
        for child in children.prefix(24) {
            totals[child.category, default: 0] += child.physicalSize
        }
        return totals.max(by: { $0.value < $1.value })?.key ?? .other
    }

    /// Recomputes sizes recursively and sorts children descending by physical size.
    public func finalizeTree() {
        guard isDirectory else { return }
        var totalPhys: UInt64 = 0
        var totalLog: UInt64 = 0
        var totalFiles = 0
        for child in children {
            if child.isDirectory {
                child.finalizeTree()
            }
            totalPhys &+= child.physicalSize
            totalLog &+= child.logicalSize
            totalFiles += child.isDirectory ? child.fileCount : 1
        }
        children.sort { lhs, rhs in
            if lhs.physicalSize != rhs.physicalSize {
                return lhs.physicalSize > rhs.physicalSize
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        self.physicalSize = totalPhys
        self.logicalSize = totalLog
        self.fileCount = totalFiles
    }

    /// Removes a deleted child node by URL and propagates the byte delta up to the root.
    @discardableResult
    public func removeNode(at targetURL: URL) -> Bool {
        let standardized = targetURL.standardizedFileURL.path
        return removeNode(standardizedPath: standardized)
    }

    private func removeNode(standardizedPath: String) -> Bool {
        if let idx = children.firstIndex(where: { $0.url.standardizedFileURL.path == standardizedPath }) {
            let removed = children.remove(at: idx)
            let deltaPhys = removed.physicalSize
            let deltaLog = removed.logicalSize
            let deltaFiles = removed.isDirectory ? removed.fileCount : 1
            propagateSubtraction(physical: deltaPhys, logical: deltaLog, files: deltaFiles)
            return true
        }
        for child in children where child.isDirectory {
            let childPath = child.url.standardizedFileURL.path
            if standardizedPath.hasPrefix(childPath + "/") {
                if child.removeNode(standardizedPath: standardizedPath) {
                    return true
                }
            }
        }
        return false
    }

    private func propagateSubtraction(physical: UInt64, logical: UInt64, files: Int) {
        var cursor: FileNode? = self
        while let node = cursor {
            node.physicalSize = node.physicalSize > physical ? node.physicalSize - physical : 0
            node.logicalSize = node.logicalSize > logical ? node.logicalSize - logical : 0
            node.fileCount = max(0, node.fileCount - files)
            node.children.sort { $0.physicalSize > $1.physicalSize }
            cursor = node.parent
        }
    }

    /// Depth-first traversal yielding every node in this subtree.
    public func walk(_ visitor: (FileNode) -> Bool) {
        guard visitor(self) else { return }
        for child in children {
            child.walk(visitor)
        }
    }
}

/// Information about a mounted local or external macOS volume.
public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let totalCapacity: UInt64
    public let availableCapacity: UInt64
    public let importantAvailableCapacity: UInt64
    public let isRootVolume: Bool
    public let isRemovable: Bool

    public var usedCapacity: UInt64 {
        totalCapacity > importantAvailableCapacity ? totalCapacity - importantAvailableCapacity : 0
    }

    public var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedCapacity) / Double(totalCapacity)))
    }

    public init(
        id: String,
        name: String,
        url: URL,
        totalCapacity: UInt64,
        availableCapacity: UInt64,
        importantAvailableCapacity: UInt64,
        isRootVolume: Bool,
        isRemovable: Bool
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.importantAvailableCapacity = importantAvailableCapacity
        self.isRootVolume = isRootVolume
        self.isRemovable = isRemovable
    }
}
