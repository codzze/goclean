import Foundation

/// Central safety classifier that flags system/OS/high-risk paths as `.danger`
/// and no-impact regenerable/disposable files as `.high` ("Safe").
public struct FileSafetyClassifier: Sendable {
    private let homePath: String

    private static let systemRootPrefixes: [String] = [
        "/System/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/private/etc/",
        "/private/var/db/",
        "/private/var/vm/",
        "/private/var/root/",
        "/private/var/protected/",
        "/private/var/log/",
        "/private/var/select/",
        "/var/db/",
        "/var/vm/",
        "/var/root/",
        "/dev/",
        "/etc/",
        "/opt/",
        "/Library/Apple/",
        "/Library/System/",
        "/Library/Frameworks/",
        "/Library/Extensions/",
        "/Library/CoreMediaIO/",
        "/Library/Updates/",
        "/Library/Developer/",
        "/Library/Application Support/Apple/",
        "/Applications/"
    ]

    private static let systemExactPaths: Set<String> = [
        "/", "/System", "/usr", "/bin", "/sbin", "/private", "/Library", "/Applications", "/opt", "/var"
    ]

    private static let dangerousExtensions: Set<String> = [
        "kext", "dylib", "framework", "xpc", "appex", "plugin", "qlgenerator",
        "prefpane", "driver", "sys", "car", "metallib", "bom", "db", "sqlite"
    ]

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homePath = homeDirectory.standardizedFileURL.path
    }

    /// Returns `true` if `url` resides inside macOS system, root `/Library`, `/Applications`, or sensitive `~/Library` directories.
    public func isSystemOrProtectedPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if Self.systemExactPaths.contains(path) {
            return true
        }
        // Only apply OS root prefixes if the path isn't inside the configured user home directory
        let insideHome = path == homePath || path.hasPrefix("\(homePath)/")
        if !insideHome {
            for prefix in Self.systemRootPrefixes {
                if path.hasPrefix(prefix) {
                    return true
                }
            }
        }
        // Sensitive user Library locations (Keychains, Mail, Messages, Safari, Group Containers, System containers)
        let sensitiveUserLibraryPrefixes = [
            "\(homePath)/Library/Keychains/",
            "\(homePath)/Library/Mail/",
            "\(homePath)/Library/Messages/",
            "\(homePath)/Library/Safari/",
            "\(homePath)/Library/Accounts/",
            "\(homePath)/Library/Biome/",
            "\(homePath)/Library/Metadata/",
            "\(homePath)/Library/Mobile Documents/",
            "\(homePath)/Library/Group Containers/com.apple",
            "\(homePath)/Library/Containers/com.apple",
            "\(homePath)/Library/Application Support/Apple",
            "\(homePath)/Library/Application Support/CloudDocs",
            "\(homePath)/Library/Application Support/MobileSync",
            "\(homePath)/.ssh/",
            "\(homePath)/.gnupg/"
        ]
        for prefix in sensitiveUserLibraryPrefixes {
            if path.hasPrefix(prefix) {
                return true
            }
        }
        // Files inside .app, .framework, .kext, .xpc, .photoslibrary bundles
        let lower = path.lowercased()
        if lower.contains(".app/") || lower.contains(".framework/") ||
            lower.contains(".kext/") || lower.contains(".xpc/") ||
            lower.contains(".bundle/") || lower.contains(".photoslibrary/") {
            return true
        }
        return false
    }

    /// Returns `true` if the path is inside `~/Library/` (often hidden app/system support data rather than user media).
    public func isInsideUserLibrary(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix("\(homePath)/Library/")
    }

    /// Classifies a file's safety level and provides a concise explanation.
    public func classify(
        url: URL,
        defaultConfidence: ConfidenceLevel,
        defaultRationale: String
    ) -> (confidence: ConfidenceLevel, rationale: String) {
        if isSystemOrProtectedPath(url) {
            return (
                .danger,
                "System or protected OS file — deleting may destabilize macOS or installed apps."
            )
        }

        let ext = url.pathExtension.lowercased()
        if Self.dangerousExtensions.contains(ext) {
            return (
                .danger,
                "System library, executable, or database file (.\(ext)) — avoid removing unless certain."
            )
        }

        // Top-level root /Library items outside /Library/Caches are system-wide
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/Library/") && !path.hasPrefix("/Library/Caches/") {
            return (
                .danger,
                "System-wide /Library asset shared across macOS — removing may affect apps."
            )
        }

        return (defaultConfidence, defaultRationale)
    }
}
