import Foundation

/// Identifies crash dumps, core dumps, heap dumps, old DMG/PKG installers, Xcode Archives/DeviceSupport, and log bloat.
public struct DumpAndJunkAnalyzer: Sendable {
    private let homeDirectory: URL
    private let extraDumpScanRoots: [URL]

    private static let dumpExtensions: Set<String> = [
        "ips", "crash", "diag", "dmp", "mdmp", "core", "hprof", "heapsnapshot", "panic", "spin"
    ]

    private static let installerExtensions: Set<String> = [
        "dmg", "pkg", "mpkg", "iso"
    ]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        extraDumpScanRoots: [URL] = []
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.extraDumpScanRoots = extraDumpScanRoots.map { $0.standardizedFileURL }
    }

    public func analyze(existingTree: FileNode? = nil) async -> [CleanupItem] {
        await Task.detached(priority: .userInitiated) {
            var results: [String: CleanupItem] = [:]
            let fm = FileManager.default

            // 1. User DiagnosticReports (Crash dumps)
            let userDiag = homeDirectory.appendingPathComponent("Library/Logs/DiagnosticReports")
            for item in Self.scanDirectoryFiles(
                at: userDiag,
                subtitle: "~/Library/Logs/DiagnosticReports",
                tag: DumpJunkCategory.crashDumps.rawValue,
                confidence: .high,
                rationale: "macOS crash / diagnostic report dump file.",
                extensions: nil
            ) {
                results[item.id] = item
            }

            // 2. Old Installers in ~/Downloads and ~/Desktop
            for folderName in ["Downloads", "Desktop"] {
                let folder = homeDirectory.appendingPathComponent(folderName)
                for item in Self.scanDirectoryFiles(
                    at: folder,
                    subtitle: "~/\(folderName)",
                    tag: DumpJunkCategory.installers.rawValue,
                    confidence: .medium,
                    rationale: "Disk image or installer package; usually unneeded after installation.",
                    extensions: Self.installerExtensions
                ) {
                    results[item.id] = item
                }
            }

            // 3. Xcode DeviceSupport & Archives
            let xcodeDirs: [(relPath: String, label: String, confidence: ConfidenceLevel, rationale: String)] = [
                ("Library/Developer/Xcode/iOS DeviceSupport", "iOS DeviceSupport", .high, "Debug symbols for older iOS devices; Xcode re-extracts when needed."),
                ("Library/Developer/Xcode/watchOS DeviceSupport", "watchOS DeviceSupport", .high, "Debug symbols for watchOS devices."),
                ("Library/Developer/Xcode/tvOS DeviceSupport", "tvOS DeviceSupport", .high, "Debug symbols for tvOS devices."),
                ("Library/Developer/Xcode/Archives", "Xcode Archives", .review, "Archived app builds & dSYMs. Keep if you need crash symbolication for shipped releases.")
            ]

            for spec in xcodeDirs {
                let dirURL = homeDirectory.appendingPathComponent(spec.relPath)
                guard let entries = try? fm.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for entry in entries {
                    let stats = ConcurrentScanEngine.calculatePhysicalSize(at: entry)
                    guard stats.physical >= 1_048_576 else { continue }
                    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let item = CleanupItem(
                        url: entry,
                        displayName: "\(spec.label): \(entry.lastPathComponent)",
                        subtitle: "~/\(spec.relPath)",
                        size: stats.physical,
                        bucket: .dumpAndJunk,
                        confidence: spec.confidence,
                        rationale: spec.rationale,
                        lastModified: stats.latestModDate,
                        tag: DumpJunkCategory.xcodeArchives.rawValue,
                        isDirectory: isDir
                    )
                    results[item.id] = item
                }
            }

            // 4. User App Logs in ~/Library/Logs
            let userLogs = homeDirectory.appendingPathComponent("Library/Logs")
            if let logEntries = try? fm.contentsOfDirectory(
                at: userLogs,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for entry in logEntries where entry.lastPathComponent != "DiagnosticReports" {
                    let stats = ConcurrentScanEngine.calculatePhysicalSize(at: entry)
                    guard stats.physical >= 512_000 else { continue }
                    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let item = CleanupItem(
                        url: entry,
                        displayName: entry.lastPathComponent,
                        subtitle: "~/Library/Logs",
                        size: stats.physical,
                        bucket: .dumpAndJunk,
                        confidence: .high,
                        rationale: "Application diagnostic log folder/file.",
                        lastModified: stats.latestModDate,
                        tag: DumpJunkCategory.logsAndTemp.rawValue,
                        isDirectory: isDir
                    )
                    results[item.id] = item
                }
            }

            // 5. Dump files anywhere inside an existing scan tree or custom roots
            let classifier = FileSafetyClassifier(homeDirectory: homeDirectory)
            if let existingTree {
                existingTree.walk { node in
                    if node.isDirectory {
                        let name = node.name
                        if name == ".git" || name == "node_modules" || name.hasSuffix(".app") {
                            return false
                        }
                        return true
                    }
                    let ext = (node.name as NSString).pathExtension.lowercased()
                    if Self.dumpExtensions.contains(ext) && node.physicalSize >= 1_024 {
                        let nodeURL = node.url
                        let evaluated = classifier.classify(
                            url: nodeURL,
                            defaultConfidence: .high,
                            defaultRationale: "Crash, heap, or core dump file (.\(ext)). Safe to remove."
                        )
                        let item = CleanupItem(
                            url: nodeURL,
                            displayName: node.name,
                            subtitle: nodeURL.deletingLastPathComponent().path,
                            size: node.physicalSize,
                            bucket: .dumpAndJunk,
                            confidence: evaluated.confidence,
                            rationale: evaluated.rationale,
                            lastModified: node.modificationDate,
                            tag: DumpJunkCategory.crashDumps.rawValue,
                            isDirectory: false
                        )
                        results[item.id] = item
                    }
                    return false
                }
            }

            for root in extraDumpScanRoots {
                for item in Self.scanDirectoryFiles(
                    at: root,
                    subtitle: root.path,
                    tag: DumpJunkCategory.crashDumps.rawValue,
                    confidence: .high,
                    rationale: "Crash, heap, or core dump file.",
                    extensions: Self.dumpExtensions
                ) {
                    results[item.id] = item
                }
            }

            return results.values.sorted { $0.size > $1.size }
        }.value
    }

    private static func scanDirectoryFiles(
        at directory: URL,
        subtitle: String,
        tag: String,
        confidence: ConfidenceLevel,
        rationale: String,
        extensions: Set<String>?
    ) -> [CleanupItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [CleanupItem] = []
        for entry in entries {
            let ext = entry.pathExtension.lowercased()
            if let extensions, !extensions.contains(ext) {
                continue
            }
            let stats = ConcurrentScanEngine.calculatePhysicalSize(at: entry)
            let effectiveSize = max(stats.physical, stats.logical)
            guard effectiveSize >= 1_024 else { continue }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            items.append(CleanupItem(
                url: entry,
                displayName: entry.lastPathComponent,
                subtitle: subtitle,
                size: effectiveSize,
                bucket: .dumpAndJunk,
                confidence: confidence,
                rationale: rationale,
                lastModified: stats.latestModDate,
                tag: tag,
                isDirectory: isDir
            ))
        }
        return items
    }
}
