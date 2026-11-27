import Foundation

/// Detects orphaned application leftovers in `~/Library` whose owning macOS app is no longer installed.
public struct OrphanAppAnalyzer: Sendable {
    public struct InstalledAppSignature: Sendable {
        public let bundleID: String?
        public let normalizedTokens: Set<String>
        public let appGroups: Set<String>
    }

    private let homeDirectory: URL
    private let applicationDirectories: [URL]
    private let includeCLIToolNames: Bool

    /// Critical Apple / macOS / standard runtime identifiers that must never be flagged as orphaned.
    private static let protectedIdentifiers: Set<String> = [
        "apple", "com.apple", "clouddocs", "mobilesync", "addressbook", "callhistorydb",
        "callhistorytransactions", "knowledge", "crashreporter", "icdd", "syncservices",
        "dock", "finder", "spotlight", "webkit", "safari", "mail", "messages", "notes",
        "photos", "music", "podcasts", "tv", "books", "calendar", "contacts", "reminders",
        "facetime", "keychain", "keychains", "accounts", "assistant", "biome", "corespotlight",
        "differentialprivacy", "fileprovider", "geoservices", "homekit", "identityservices",
        "intelligenceplatform", "metadata", "passkit", "proactiveeventtracker", "quicklook",
        "screensharing", "security", "siri", "suggestions", "systempreferences", "tcc",
        "trial", "ubiquity", "usernotifications", "voiceservices", "weather", "widgets",
        "homebrew", "pip", "yarn", "npm", "pnpm", "bun", "cargo", "go", "node", "python",
        "ruby", "java", "docker", "colima", "git", "ssh", "gnupg", "zsh", "bash", "vim",
        "nvim", "neovim", "tmux", "aws", "gcloud", "kubectl", "terraform", "xcode",
        "coresimulator", "developer", "swift", "clang", "lldb", "cocoapods", "jetbrains",
        "mozilla", "cef", "electron", "gpu", "shader", "metal", "opengl", "nvidia",
        "globalpreferences", "pbs", "loginwindow", "windowserver", "universalaccess",
        "sharedfilelist", "recentitems", "fontcollections", "fonts", "services", "audio",
        "colorsync", "printers", "spelling", "keyboard", "inputmethods", "automator",
        "workflows", "scripts", "contextualmenu", "preferencepanes", "screensavers",
        "animoji", "avfoundation", "bird", "caches", "cloudkit", "com.goclean.app", "goclean"
    ]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        includeCLIToolNames: Bool = true
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications"),
            homeDirectory.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]
        self.includeCLIToolNames = includeCLIToolNames
    }

    public func analyze() async -> [OrphanAppGroup] {
        await Task.detached(priority: .userInitiated) {
            let installedIndex = Self.buildInstalledIndex(
                appDirectories: applicationDirectories,
                includeCLITools: includeCLIToolNames
            )
            let libraryURL = homeDirectory.appendingPathComponent("Library")
            let fm = FileManager.default

            let scanLocations: [(subdir: String, label: String, isPlistOnly: Bool)] = [
                ("Application Support", "Application Support", false),
                ("Caches", "App Cache", false),
                ("Containers", "Sandbox Container", false),
                ("Saved Application State", "Saved State", false),
                ("HTTPStorages", "HTTP Storage", false),
                ("WebKit", "WebKit Data", false),
                ("Logs", "App Logs", false),
                ("Preferences", "Preferences", true),
                ("LaunchAgents", "Launch Agent", true)
            ]

            var groupedItems: [String: (name: String, bundleHint: String?, confidence: ConfidenceLevel, rationale: String, items: [CleanupItem])] = [:]

            for loc in scanLocations {
                if Task.isCancelled { break }
                let folderURL = libraryURL.appendingPathComponent(loc.subdir)
                guard let entries = try? fm.contentsOfDirectory(
                    at: folderURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                for entryURL in entries {
                    let rawName = entryURL.lastPathComponent
                    if loc.isPlistOnly && !rawName.hasSuffix(".plist") {
                        continue
                    }

                    guard let candidate = Self.evaluateCandidate(
                        name: rawName,
                        locationLabel: loc.label,
                        installedIndex: installedIndex
                    ) else {
                        continue
                    }

                    let sizeInfo = ConcurrentScanEngine.calculatePhysicalSize(at: entryURL)
                    // Skip tiny/empty 0-byte placeholders unless it's a plist/LaunchAgent
                    if sizeInfo.physical == 0 && sizeInfo.logical < 1024 {
                        continue
                    }

                    let effectiveSize = max(sizeInfo.physical, sizeInfo.logical)
                    let isDir = (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                    let item = CleanupItem(
                        url: entryURL,
                        displayName: rawName,
                        subtitle: "~/Library/\(loc.subdir)",
                        size: effectiveSize,
                        bucket: .orphanedAppData,
                        confidence: candidate.confidence,
                        rationale: candidate.rationale,
                        lastModified: sizeInfo.latestModDate,
                        tag: loc.label,
                        isDirectory: isDir
                    )

                    if var existing = groupedItems[candidate.groupKey] {
                        existing.items.append(item)
                        if candidate.confidence > existing.confidence {
                            existing.confidence = candidate.confidence
                        }
                        groupedItems[candidate.groupKey] = existing
                    } else {
                        groupedItems[candidate.groupKey] = (
                            name: candidate.displayName,
                            bundleHint: candidate.bundleHint,
                            confidence: candidate.confidence,
                            rationale: candidate.rationale,
                            items: [item]
                        )
                    }
                }
            }

            return groupedItems.map { key, value in
                OrphanAppGroup(
                    id: key,
                    appName: value.name,
                    bundleHint: value.bundleHint,
                    confidence: value.confidence,
                    rationale: value.rationale,
                    items: value.items
                )
            }
            .filter { $0.totalSize >= 4_096 }
            .sorted { $0.totalSize > $1.totalSize }
        }.value
    }

    // MARK: - Indexing & Matching

    private struct InstalledIndex {
        var bundleIDs: Set<String> = []
        var appTokens: Set<String> = []
        var vendorTokens: Set<String> = []
    }

    private struct CandidateMatch {
        let groupKey: String
        let displayName: String
        let bundleHint: String?
        let confidence: ConfidenceLevel
        let rationale: String
    }

    private static func buildInstalledIndex(appDirectories: [URL], includeCLITools: Bool) -> InstalledIndex {
        var index = InstalledIndex()
        let fm = FileManager.default

        for dir in appDirectories {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in items {
                if item.pathExtension.lowercased() == "app" {
                    indexAppBundle(at: item, into: &index)
                } else {
                    // Check one level deeper (e.g. /Applications/Utilities/Foo.app or /Applications/Setapp/Bar.app)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                        if let nested = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                            for sub in nested where sub.pathExtension.lowercased() == "app" {
                                indexAppBundle(at: sub, into: &index)
                            }
                        }
                    }
                }
            }
        }

        if includeCLITools {
            let cliDirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
            for path in cliDirs {
                if let entries = try? fm.contentsOfDirectory(atPath: path) {
                    for entry in entries {
                        let token = normalizeToken(entry)
                        if token.count >= 3 {
                            index.appTokens.insert(token)
                        }
                    }
                }
            }
        }

        return index
    }

    private static func indexAppBundle(at appURL: URL, into index: inout InstalledIndex) {
        let baseName = appURL.deletingPathExtension().lastPathComponent
        insertTokenVariants(baseName, into: &index.appTokens)

        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else { return }

        if let bundleID = dict["CFBundleIdentifier"] as? String {
            let lowerID = bundleID.lowercased()
            index.bundleIDs.insert(lowerID)
            let parts = lowerID.split(separator: ".").map(String.init)
            if parts.count >= 2 {
                // Record vendor + product tokens
                let vendor = normalizeToken(parts[1])
                if vendor.count >= 3 {
                    index.vendorTokens.insert(vendor)
                }
                if let last = parts.last {
                    insertTokenVariants(last, into: &index.appTokens)
                }
                if parts.count >= 3 {
                    insertTokenVariants(parts.dropFirst(2).joined(separator: ""), into: &index.appTokens)
                }
            }
        }
        if let name = dict["CFBundleName"] as? String {
            insertTokenVariants(name, into: &index.appTokens)
        }
        if let displayName = dict["CFBundleDisplayName"] as? String {
            insertTokenVariants(displayName, into: &index.appTokens)
        }
        if let exec = dict["CFBundleExecutable"] as? String {
            insertTokenVariants(exec, into: &index.appTokens)
        }
    }

    private static func insertTokenVariants(_ raw: String, into set: inout Set<String>) {
        let norm = normalizeToken(raw)
        if norm.count >= 2 {
            set.insert(norm)
        }
        for part in raw.components(separatedBy: CharacterSet.alphanumerics.inverted) where part.count >= 3 {
            set.insert(part.lowercased())
        }
    }

    private static func normalizeToken(_ string: String) -> String {
        string.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func evaluateCandidate(
        name: String,
        locationLabel: String,
        installedIndex: InstalledIndex
    ) -> CandidateMatch? {
        // Strip known suffixes like .plist, .savedState, .LSSharedFileList.plist
        var cleaned = name
        for suffix in [".savedState", ".plist", ".LSSharedFileList.plist", ".binarycookies"] {
            if cleaned.lowercased().hasSuffix(suffix.lowercased()) {
                cleaned = String(cleaned.dropLast(suffix.count))
            }
        }

        let lower = cleaned.lowercased()
        let norm = normalizeToken(cleaned)

        // Never flag Apple or protected system entries
        if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") || lower.hasPrefix("apple.") {
            return nil
        }
        if protectedIdentifiers.contains(lower) || protectedIdentifiers.contains(norm) {
            return nil
        }
        if lower.hasPrefix("org.macos") || lower.hasPrefix("system.") || lower.hasPrefix("com.openssh") {
            return nil
        }

        // Check if this matches any installed bundle ID directly or as prefix/helper
        if installedIndex.bundleIDs.contains(lower) {
            return nil
        }
        for installedID in installedIndex.bundleIDs {
            if lower.hasPrefix(installedID + ".") || installedID.hasPrefix(lower + ".") {
                return nil
            }
        }

        let looksLikeBundleID = lower.contains(".") && (
            lower.hasPrefix("com.") || lower.hasPrefix("org.") ||
            lower.hasPrefix("net.") || lower.hasPrefix("io.") ||
            lower.hasPrefix("app.") || lower.hasPrefix("dev.") ||
            lower.hasPrefix("co.") || lower.hasPrefix("me.") ||
            lower.hasPrefix("ch.") || lower.hasPrefix("de.") ||
            lower.hasPrefix("uk.") || lower.hasPrefix("jp.")
        )

        if looksLikeBundleID {
            let parts = lower.split(separator: ".").map(String.init)
            let meaningfulParts = parts.dropFirst() // drop TLD (com/org/io)
            for part in meaningfulParts {
                let pNorm = normalizeToken(part)
                if protectedIdentifiers.contains(pNorm) {
                    return nil
                }
                if pNorm.count >= 4 && installedIndex.appTokens.contains(pNorm) {
                    return nil
                }
            }
            // If vendor + product didn't match any installed app, it's a high-confidence orphan
            let productPart = parts.last ?? cleaned
            let prettyName = productPart
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            let groupKey = parts.prefix(3).joined(separator: ".")
            return CandidateMatch(
                groupKey: groupKey,
                displayName: prettyName.isEmpty ? cleaned : prettyName,
                bundleHint: cleaned,
                confidence: .high,
                rationale: "Bundle identifier '\(cleaned)' does not match any installed app (\(locationLabel))."
            )
        }

        // Non-bundle-ID folder name: require stricter checks to avoid false positives
        if installedIndex.appTokens.contains(norm) || installedIndex.vendorTokens.contains(norm) {
            return nil
        }
        for token in installedIndex.appTokens where token.count >= 4 {
            if norm.contains(token) || token.contains(norm) {
                return nil
            }
        }
        for part in cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted) where part.count >= 3 {
            let pLower = part.lowercased()
            if protectedIdentifiers.contains(pLower) || installedIndex.appTokens.contains(pLower) {
                return nil
            }
        }

        return CandidateMatch(
            groupKey: norm.isEmpty ? lower : norm,
            displayName: cleaned,
            bundleHint: nil,
            confidence: .review,
            rationale: "No installed app matches '\(cleaned)' in \(locationLabel). Review before removing."
        )
    }
}
