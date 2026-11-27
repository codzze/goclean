import Darwin
import Foundation

/// Identifies cleanable application caches, package manager caches, and project-local developer build artifacts
/// (`node_modules`, Rust `target/`, Swift `.build`, Xcode `DerivedData`, CocoaPods, Gradle, Python venvs, etc.).
public struct DevCacheAnalyzer: Sendable {
    private let homeDirectory: URL
    private let customProjectRoots: [URL]?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        customProjectRoots: [URL]? = nil
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.customProjectRoots = customProjectRoots?.map { $0.standardizedFileURL }
    }

    public func analyze(existingTree: FileNode? = nil) async -> [CleanupItem] {
        await Task.detached(priority: .userInitiated) {
            var resultsByPath: [String: CleanupItem] = [:]

            // 1. Global package manager, Xcode, and app caches
            for item in Self.scanGlobalCaches(home: homeDirectory) {
                resultsByPath[item.id] = item
            }

            // 2. Project-local build artifacts (reuse existing scan tree if available and rooted at home/root)
            let projectArtifacts: [CleanupItem]
            if let existingTree, customProjectRoots == nil {
                projectArtifacts = Self.extractProjectArtifacts(from: existingTree, home: homeDirectory)
            } else {
                let roots = customProjectRoots ?? Self.defaultProjectRoots(home: homeDirectory)
                projectArtifacts = Self.scanProjectArtifacts(in: roots, home: homeDirectory)
            }

            for item in projectArtifacts {
                resultsByPath[item.id] = item
            }

            return resultsByPath.values
                .filter { $0.size >= 4_096 }
                .sorted { $0.size > $1.size }
        }.value
    }

    // MARK: - Global Caches

    private static func scanGlobalCaches(home: URL) -> [CleanupItem] {
        let fm = FileManager.default
        var items: [CleanupItem] = []

        let knownCaches: [(relPath: String, name: String, category: DevCacheCategory, confidence: ConfidenceLevel, rationale: String)] = [
            ("Library/Caches/Homebrew", "Homebrew Download Cache", .packageManagers, .high, "Cached formula & cask downloads; safely recreated on next brew install."),
            (".npm/_cacache", "npm Cache", .packageManagers, .high, "Global npm package cache."),
            (".pnpm-store", "pnpm Content Store", .packageManagers, .medium, "Global pnpm content-addressable package store."),
            ("Library/Caches/Yarn", "Yarn Cache", .packageManagers, .high, "Global Yarn package cache."),
            (".bun/install/cache", "Bun Package Cache", .packageManagers, .high, "Global Bun install cache."),
            ("Library/Caches/pip", "pip Cache", .packageManagers, .high, "Python pip wheel & HTTP download cache."),
            (".cache/pip", "pip Cache (.cache)", .packageManagers, .high, "Python pip download cache."),
            (".cache/uv", "uv Python Cache", .packageManagers, .high, "uv Python package & wheel cache."),
            (".cargo/registry/cache", "Cargo Registry Cache", .packageManagers, .high, "Downloaded Rust crate tarballs; re-fetched on demand."),
            ("go/pkg/mod/cache", "Go Module Download Cache", .packageManagers, .high, "Cached Go module zip downloads."),
            (".gradle/caches", "Gradle Build Caches", .packageManagers, .high, "Global Gradle dependency and transform caches."),
            (".m2/repository", "Maven Local Repository", .packageManagers, .medium, "Cached Maven JAR dependencies; re-downloaded on build."),
            ("Library/Caches/CocoaPods", "CocoaPods Cache", .xcodeAndSwift, .high, "Cached CocoaPods specs and pods."),
            ("Library/Developer/Xcode/DerivedData", "Xcode DerivedData", .xcodeAndSwift, .high, "Intermediate Xcode build products and indexes; fully regenerable."),
            ("Library/Developer/CoreSimulator/Caches", "CoreSimulator Caches", .xcodeAndSwift, .high, "iOS/watchOS Simulator runtime caches."),
            ("Library/Caches/org.swift.swiftpm", "SwiftPM Cache", .xcodeAndSwift, .high, "Swift Package Manager downloaded repository cache."),
            ("Library/Caches/com.apple.dt.Xcode", "Xcode Internal Cache", .xcodeAndSwift, .high, "Xcode temporary cache data.")
        ]

        for spec in knownCaches {
            let url = home.appendingPathComponent(spec.relPath)
            guard fm.fileExists(atPath: url.path) else { continue }
            let stats = ConcurrentScanEngine.calculatePhysicalSize(at: url)
            guard stats.physical >= 16_384 else { continue }
            items.append(CleanupItem(
                url: url,
                displayName: spec.name,
                subtitle: "~/\(spec.relPath)",
                size: stats.physical,
                bucket: .devAndAppCaches,
                confidence: spec.confidence,
                rationale: spec.rationale,
                lastModified: stats.latestModDate,
                tag: spec.category.rawValue,
                isDirectory: true
            ))
        }

        // Scan individual app caches inside ~/Library/Caches (excluding already-listed specific ones)
        let libraryCaches = home.appendingPathComponent("Library/Caches")
        let alreadyHandled: Set<String> = ["Homebrew", "Yarn", "pip", "CocoaPods", "org.swift.swiftpm", "com.apple.dt.Xcode"]
        if let entries = try? fm.contentsOfDirectory(
            at: libraryCaches,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                let name = entry.lastPathComponent
                if alreadyHandled.contains(name) { continue }
                if name.lowercased().hasPrefix("com.apple.nsurlsessiond") || name.lowercased() == "cloudkit" {
                    continue
                }
                let stats = ConcurrentScanEngine.calculatePhysicalSize(at: entry)
                // Surface meaningful app caches (>= 5 MB)
                guard stats.physical >= 5 * 1024 * 1024 else { continue }
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                items.append(CleanupItem(
                    url: entry,
                    displayName: name,
                    subtitle: "~/Library/Caches",
                    size: stats.physical,
                    bucket: .devAndAppCaches,
                    confidence: .high,
                    rationale: "Application cache folder; apps automatically recreate needed cache data.",
                    lastModified: stats.latestModDate,
                    tag: DevCacheCategory.appCaches.rawValue,
                    isDirectory: isDir
                ))
            }
        }

        return items
    }

    // MARK: - Project-Local Build Artifacts

    private static func defaultProjectRoots(home: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [home]
        }

        let skippedTopLevel: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures", "Public"]
        return entries.filter { url in
            guard !skippedTopLevel.contains(url.lastPathComponent) else { return false }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir
        }
    }

    private static func extractProjectArtifacts(from rootNode: FileNode, home: URL) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let fm = FileManager.default
        let classifier = FileSafetyClassifier(homeDirectory: home)

        rootNode.walk { node in
            guard node.isDirectory else { return false }
            let name = node.name
            let nodeURL = node.url
            if name == ".git" || name == ".Trash" || name == "Library" ||
                classifier.isSystemOrProtectedPath(nodeURL) {
                return false
            }
            if let match = classifyArtifactDirectory(name: name, url: nodeURL, fileManager: fm) {
                if node.physicalSize >= 16_384 {
                    let projectName = node.parent?.name ?? nodeURL.deletingLastPathComponent().lastPathComponent
                    let evaluated = classifier.classify(
                        url: nodeURL,
                        defaultConfidence: match.confidence,
                        defaultRationale: match.rationale
                    )
                    items.append(CleanupItem(
                        url: nodeURL,
                        displayName: "\(projectName) / \(name)",
                        subtitle: nodeURL.deletingLastPathComponent().path,
                        size: node.physicalSize,
                        bucket: .devAndAppCaches,
                        confidence: evaluated.confidence,
                        rationale: evaluated.rationale,
                        lastModified: node.modificationDate,
                        tag: match.category.rawValue,
                        isDirectory: true
                    ))
                }
                // Do not recurse inside node_modules / target / .build
                return false
            }
            return true
        }

        return items
    }

    private static func scanProjectArtifacts(in roots: [URL], home: URL) -> [CleanupItem] {
        let fm = FileManager.default
        let classifier = FileSafetyClassifier(homeDirectory: home)
        var items: [CleanupItem] = []

        for root in roots {
            var stack: [(path: String, depth: Int)] = [(root.path, 0)]
            while let (currentPath, depth) = stack.popLast() {
                if Task.isCancelled { break }
                if depth > 7 { continue }
                guard let dir = opendir(currentPath) else { continue }
                let fd = dirfd(dir)

                var subdirs: [(name: String, path: String)] = []
                while let entryPtr = readdir(dir) {
                    let name = withUnsafePointer(to: entryPtr.pointee.d_name) { ptr -> String in
                        ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                            String(cString: $0)
                        }
                    }
                    if name == "." || name == ".." || name == ".git" || name == ".Trash" { continue }
                    if name.hasSuffix(".app") || name.hasSuffix(".photoslibrary") { continue }

                    var st = stat()
                    guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                    if (st.st_mode & S_IFMT) == S_IFDIR {
                        let full = currentPath == "/" ? "/\(name)" : "\(currentPath)/\(name)"
                        subdirs.append((name, full))
                    }
                }
                closedir(dir)

                for sub in subdirs {
                    let subURL = URL(fileURLWithPath: sub.path)
                    if let match = classifyArtifactDirectory(name: sub.name, url: subURL, fileManager: fm) {
                        let stats = ConcurrentScanEngine.calculatePhysicalSize(at: subURL)
                        if stats.physical >= 16_384 {
                            let projectName = subURL.deletingLastPathComponent().lastPathComponent
                            let evaluated = classifier.classify(
                                url: subURL,
                                defaultConfidence: match.confidence,
                                defaultRationale: match.rationale
                            )
                            items.append(CleanupItem(
                                url: subURL,
                                displayName: "\(projectName) / \(sub.name)",
                                subtitle: subURL.deletingLastPathComponent().path,
                                size: stats.physical,
                                bucket: .devAndAppCaches,
                                confidence: evaluated.confidence,
                                rationale: evaluated.rationale,
                                lastModified: stats.latestModDate,
                                tag: match.category.rawValue,
                                isDirectory: true
                            ))
                        }
                        // Stop descending into matched artifact folder
                    } else {
                        stack.append((sub.path, depth + 1))
                    }
                }
            }
        }

        return items
    }

    private struct ArtifactMatch {
        let category: DevCacheCategory
        let confidence: ConfidenceLevel
        let rationale: String
    }

    private static func classifyArtifactDirectory(name: String, url: URL, fileManager fm: FileManager) -> ArtifactMatch? {
        let parent = url.deletingLastPathComponent()
        switch name {
        case "node_modules":
            return ArtifactMatch(
                category: .nodeModules,
                confidence: .high,
                rationale: "JavaScript dependencies; reinstallable via npm/pnpm/yarn/bun install."
            )
        case ".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache":
            return ArtifactMatch(
                category: .nodeModules,
                confidence: .high,
                rationale: "Frontend framework build cache; regenerated automatically on next dev/build."
            )
        case "target":
            if fm.fileExists(atPath: parent.appendingPathComponent("Cargo.toml").path) {
                return ArtifactMatch(
                    category: .rustGoJvmPython,
                    confidence: .high,
                    rationale: "Rust Cargo build artifacts (Cargo.toml detected); regenerated by cargo build."
                )
            }
            if fm.fileExists(atPath: parent.appendingPathComponent("pom.xml").path) {
                return ArtifactMatch(
                    category: .rustGoJvmPython,
                    confidence: .high,
                    rationale: "Maven build output (pom.xml detected); regenerated by mvn package."
                )
            }
            return nil
        case ".build":
            if fm.fileExists(atPath: parent.appendingPathComponent("Package.swift").path) {
                return ArtifactMatch(
                    category: .xcodeAndSwift,
                    confidence: .high,
                    rationale: "Swift Package Manager build folder (Package.swift detected)."
                )
            }
            return nil
        case "Pods":
            if fm.fileExists(atPath: parent.appendingPathComponent("Podfile").path) {
                return ArtifactMatch(
                    category: .xcodeAndSwift,
                    confidence: .high,
                    rationale: "CocoaPods dependencies (Podfile detected); restored via pod install."
                )
            }
            return nil
        case ".gradle":
            if fm.fileExists(atPath: parent.appendingPathComponent("build.gradle").path) ||
                fm.fileExists(atPath: parent.appendingPathComponent("build.gradle.kts").path) {
                return ArtifactMatch(
                    category: .rustGoJvmPython,
                    confidence: .high,
                    rationale: "Local Gradle project cache."
                )
            }
            return nil
        case ".venv", "venv":
            if fm.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path) {
                return ArtifactMatch(
                    category: .rustGoJvmPython,
                    confidence: .medium,
                    rationale: "Python virtual environment; recreate from requirements.txt / pyproject.toml."
                )
            }
            return nil
        case "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache":
            return ArtifactMatch(
                category: .rustGoJvmPython,
                confidence: .high,
                rationale: "Python bytecode / linter cache; automatically recreated."
            )
        default:
            return nil
        }
    }
}
