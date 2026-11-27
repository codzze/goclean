import Foundation

/// High-level feature buckets in the GoClean sidebar.
public enum CleanupBucketKind: String, CaseIterable, Codable, Sendable, Hashable {
    case diskMap = "Disk Map"
    case orphanedAppData = "Orphaned App Data"
    case devAndAppCaches = "Dev & App Caches"
    case dumpAndJunk = "Dump & System Junk"
    case largeMedia = "Large Videos & Media"
    case duplicates = "Duplicate Files"
    case applications = "Applications"
}

/// Safety / confidence score attached to heuristically detected cleanup items.
public enum ConfidenceLevel: String, CaseIterable, Codable, Sendable, Hashable, Comparable {
    case high = "Safe"
    case medium = "Likely Safe"
    case review = "Review"
    case danger = "Danger"

    private var rank: Int {
        switch self {
        case .high: return 3
        case .medium: return 2
        case .review: return 1
        case .danger: return 0
        }
    }

    public static func < (lhs: ConfidenceLevel, rhs: ConfidenceLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Sub-category for Developer & App Caches.
public enum DevCacheCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case nodeModules = "node_modules"
    case xcodeAndSwift = "Xcode & Swift"
    case packageManagers = "Package Caches"
    case appCaches = "App & Browser Caches"
    case rustGoJvmPython = "Build Artifacts"
}

/// Sub-category for Dump & System Junk.
public enum DumpJunkCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case crashDumps = "Crash & Core Dumps"
    case installers = "Old Installers"
    case xcodeArchives = "Xcode Support & Archives"
    case logsAndTemp = "Logs & Clutter"
}

/// Sub-category for Large Media & Files.
public enum LargeMediaKind: String, CaseIterable, Codable, Sendable, Hashable {
    case video = "Video"
    case audio = "Audio"
    case image = "Image"
    case archive = "Archive"
    case other = "Other Large File"
}

/// Unified cleanable item that can be staged in the Collector from any view.
public struct CleanupItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let displayName: String
    public let subtitle: String
    public let size: UInt64
    public let bucket: CleanupBucketKind
    public let confidence: ConfidenceLevel
    public let rationale: String
    public let lastModified: Date?
    public let tag: String?
    public let isDirectory: Bool

    public init(
        url: URL,
        displayName: String? = nil,
        subtitle: String = "",
        size: UInt64,
        bucket: CleanupBucketKind,
        confidence: ConfidenceLevel = .high,
        rationale: String = "",
        lastModified: Date? = nil,
        tag: String? = nil,
        isDirectory: Bool = false
    ) {
        let standardized = url.standardizedFileURL
        self.id = standardized.path
        self.url = standardized
        self.displayName = displayName ?? standardized.lastPathComponent
        self.subtitle = subtitle.isEmpty ? standardized.deletingLastPathComponent().path : subtitle
        self.size = size
        self.bucket = bucket
        self.confidence = confidence
        self.rationale = rationale
        self.lastModified = lastModified
        self.tag = tag
        self.isDirectory = isDirectory
    }

    /// Number of days since last modification, if known.
    public var dormantDays: Int? {
        guard let lastModified else { return nil }
        return Calendar.current.dateComponents([.day], from: lastModified, to: Date()).day
    }
}

/// Grouped orphaned app leftovers belonging to one inferred deleted application.
public struct OrphanAppGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let appName: String
    public let bundleHint: String?
    public let confidence: ConfidenceLevel
    public let rationale: String
    public let items: [CleanupItem]

    public var totalSize: UInt64 {
        items.reduce(0) { $0 &+ $1.size }
    }

    public init(
        id: String,
        appName: String,
        bundleHint: String?,
        confidence: ConfidenceLevel,
        rationale: String,
        items: [CleanupItem]
    ) {
        self.id = id
        self.appName = appName
        self.bundleHint = bundleHint
        self.confidence = confidence
        self.rationale = rationale
        self.items = items.sorted { $0.size > $1.size }
    }
}

/// A single file entry inside a verified SHA-256 duplicate group.
public struct DuplicateFileEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let fileName: String
    public let parentPath: String
    public let size: UInt64
    public let modificationDate: Date?
    public let creationDate: Date?

    public init(
        url: URL,
        size: UInt64,
        modificationDate: Date?,
        creationDate: Date?
    ) {
        let standardized = url.standardizedFileURL
        self.id = standardized.path
        self.url = standardized
        self.fileName = standardized.lastPathComponent
        self.parentPath = standardized.deletingLastPathComponent().path
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
    }

    public func asCleanupItem() -> CleanupItem {
        CleanupItem(
            url: url,
            displayName: fileName,
            subtitle: parentPath,
            size: size,
            bucket: .duplicates,
            confidence: .high,
            rationale: "Exact SHA-256 duplicate copy",
            lastModified: modificationDate,
            tag: "Duplicate",
            isDirectory: false
        )
    }
}

/// Group of 2 or more byte-identical files sharing the same SHA-256 hash.
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let sha256: String
    public let fileSize: UInt64
    public let files: [DuplicateFileEntry]

    public var wastedSize: UInt64 {
        guard files.count > 1 else { return 0 }
        return fileSize * UInt64(files.count - 1)
    }

    public init(sha256: String, fileSize: UInt64, files: [DuplicateFileEntry]) {
        self.id = sha256
        self.sha256 = sha256
        self.fileSize = fileSize
        self.files = files
    }
}

/// Strategy for smartly selecting duplicates while preserving at least one copy.
public enum DuplicateSelectionStrategy: String, CaseIterable, Sendable {
    case keepOldest = "Keep Oldest"
    case keepNewest = "Keep Newest"
    case keepShortestPath = "Keep Shortest Path"
}

/// Source from which an application or CLI tool was installed.
public enum AppInstallSource: String, CaseIterable, Codable, Sendable, Hashable {
    case appStore = "App Store"
    case homebrewCask = "Homebrew Cask"
    case homebrewFormula = "Homebrew Formula"
    case directDownload = "Direct / DMG"
    case curlCLI = "Direct Curl / CLI"
}

/// Strategy for uninstalling an application or CLI tool cleanly.
public enum UninstallStrategy: Hashable, Sendable {
    case trashFiles
    case homebrewCask(token: String, zap: Bool)
    case homebrewFormula(name: String)
}

/// Unified model representing an installed macOS application, Homebrew package, or direct-curl CLI tool.
public struct InstalledApplication: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    public let source: AppInstallSource
    public let installPath: URL
    public let appSize: UInt64
    public let associatedFiles: [CleanupItem]
    public let lastModified: Date?
    public let reverseDependencies: [String]
    public let isDependencyOnly: Bool
    public let homebrewToken: String?
    public let descriptionText: String?

    public var associatedSize: UInt64 {
        associatedFiles.reduce(0) { $0 &+ $1.size }
    }

    public var totalFootprint: UInt64 {
        appSize &+ associatedSize
    }

    public var uninstallStrategy: UninstallStrategy {
        switch source {
        case .homebrewCask:
            return .homebrewCask(token: homebrewToken ?? name, zap: true)
        case .homebrewFormula:
            return .homebrewFormula(name: homebrewToken ?? name)
        case .appStore, .directDownload, .curlCLI:
            return .trashFiles
        }
    }

    public init(
        id: String,
        name: String,
        bundleIdentifier: String? = nil,
        version: String? = nil,
        source: AppInstallSource,
        installPath: URL,
        appSize: UInt64,
        associatedFiles: [CleanupItem] = [],
        lastModified: Date? = nil,
        reverseDependencies: [String] = [],
        isDependencyOnly: Bool = false,
        homebrewToken: String? = nil,
        descriptionText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.source = source
        self.installPath = installPath.standardizedFileURL
        self.appSize = appSize
        self.associatedFiles = associatedFiles.sorted { $0.size > $1.size }
        self.lastModified = lastModified
        self.reverseDependencies = reverseDependencies
        self.isDependencyOnly = isDependencyOnly
        self.homebrewToken = homebrewToken
        self.descriptionText = descriptionText
    }
}

/// Mode of executing cleanup operations.
public enum DeletionMode: String, Sendable {
    case moveToTrash = "Move to Trash"
    case permanentErase = "Permanent Erase"
}

/// Outcome summary after executing a cleanup batch or app uninstall.
public struct CleanupExecutionResult: Sendable {
    public struct Failure: Identifiable, Sendable {
        public let id = UUID()
        public let url: URL
        public let reason: String

        public init(url: URL, reason: String) {
            self.url = url
            self.reason = reason
        }
    }

    public let succeededURLs: [URL]
    public let freedBytes: UInt64
    public let failures: [Failure]
    public let mode: DeletionMode
    public let commandOutput: String?

    public init(
        succeededURLs: [URL],
        freedBytes: UInt64,
        failures: [Failure],
        mode: DeletionMode,
        commandOutput: String? = nil
    ) {
        self.succeededURLs = succeededURLs
        self.freedBytes = freedBytes
        self.failures = failures
        self.mode = mode
        self.commandOutput = commandOutput
    }
}
