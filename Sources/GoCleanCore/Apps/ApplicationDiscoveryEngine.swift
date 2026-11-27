import Foundation

/// Discovers installed applications across Mac App Store, Homebrew (Casks & Formulae),
/// Direct / DMG `.app` bundles, and Direct `curl` / user CLI installations, along with their
/// associated Library/config leftovers.
public struct ApplicationDiscoveryEngine: Sendable {
    private let homeDirectory: URL
    private let applicationDirectories: [URL]
    private let brewExecutablePath: String?
    private let cliBinaryDirectories: [URL]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        brewExecutablePath: String? = CleanupExecutor.resolveBrewExecutable(),
        cliBinaryDirectories: [URL]? = nil
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications"),
            homeDirectory.appendingPathComponent("Applications")
        ]
        self.brewExecutablePath = brewExecutablePath
        self.cliBinaryDirectories = cliBinaryDirectories ?? [
            homeDirectory.appendingPathComponent(".local/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            homeDirectory.appendingPathComponent("go/bin"),
            homeDirectory.appendingPathComponent(".cargo/bin")
        ]
    }

    /// Runs full discovery across all installation sources.
    public func discoverAll() async -> [InstalledApplication] {
        // Fetch Homebrew metadata concurrently if brew is installed
        async let brewDataTask: HomebrewParsedResult = fetchHomebrewInstalled()

        let brewResult = await brewDataTask

        return await Task.detached(priority: .userInitiated) {
            var discovered: [InstalledApplication] = []
            let caskAppNameMap = brewResult.caskAppBundleNames // lowercased "foo.app" -> cask info

            // 1. Scan .app bundles (App Store, Homebrew Cask, Direct Download)
            var matchedCaskTokens = Set<String>()
            let appBundles = Self.discoverAppBundles(in: applicationDirectories)

            for appURL in appBundles {
                let info = Self.readAppBundleInfo(at: appURL)
                let bundleFileNameLower = appURL.lastPathComponent.lowercased()
                let isAppStore = FileManager.default.fileExists(
                    atPath: appURL.appendingPathComponent("Contents/_MASReceipt/receipt").path
                )

                let source: AppInstallSource
                var caskToken: String?
                var descText: String?

                if let cask = caskAppNameMap[bundleFileNameLower] {
                    source = .homebrewCask
                    caskToken = cask.token
                    descText = cask.desc
                    matchedCaskTokens.insert(cask.token)
                } else if isAppStore {
                    source = .appStore
                } else {
                    source = .directDownload
                }

                let sizeStats = ConcurrentScanEngine.calculatePhysicalSize(at: appURL)
                let associated = Self.findAssociatedLibraryFiles(
                    appName: info.displayName,
                    bundleID: info.bundleID,
                    home: homeDirectory
                )

                discovered.append(InstalledApplication(
                    id: "app:\(appURL.standardizedFileURL.path)",
                    name: info.displayName,
                    bundleIdentifier: info.bundleID,
                    version: info.version,
                    source: source,
                    installPath: appURL,
                    appSize: max(sizeStats.physical, sizeStats.logical),
                    associatedFiles: associated,
                    lastModified: sizeStats.latestModDate,
                    homebrewToken: caskToken,
                    descriptionText: descText
                ))
            }

            // 2. Add Homebrew Casks whose artifacts weren't standard .app bundles (e.g. fonts, pkg casks, CLI casks)
            for cask in brewResult.casks where !matchedCaskTokens.contains(cask.token) {
                let sizeStats = ConcurrentScanEngine.calculatePhysicalSize(at: cask.caskroomPath)
                let associated = Self.findAssociatedLibraryFiles(
                    appName: cask.displayName,
                    bundleID: nil,
                    home: homeDirectory
                )
                discovered.append(InstalledApplication(
                    id: "cask:\(cask.token)",
                    name: cask.displayName,
                    bundleIdentifier: nil,
                    version: cask.version,
                    source: .homebrewCask,
                    installPath: cask.caskroomPath,
                    appSize: max(sizeStats.physical, sizeStats.logical),
                    associatedFiles: associated,
                    lastModified: sizeStats.latestModDate,
                    homebrewToken: cask.token,
                    descriptionText: cask.desc
                ))
            }

            // 3. Add Homebrew Formulae
            discovered.append(contentsOf: brewResult.formulae)

            // 4. Discover Direct Curl / Standalone User CLI Tools & Toolchains
            let curlTools = Self.discoverCurlAndCLITools(
                home: homeDirectory,
                cliDirs: cliBinaryDirectories,
                homebrewFormulaNames: Set(brewResult.formulae.map { $0.name.lowercased() })
            )
            discovered.append(contentsOf: curlTools)

            return discovered.sorted { lhs, rhs in
                if lhs.totalFootprint != rhs.totalFootprint {
                    return lhs.totalFootprint > rhs.totalFootprint
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }.value
    }

    // MARK: - Homebrew JSON Parsing

    public struct HomebrewCaskRecord: Sendable {
        public let token: String
        public let displayName: String
        public let version: String?
        public let desc: String?
        public let appArtifacts: [String]
        public let caskroomPath: URL
    }

    public struct HomebrewParsedResult: Sendable {
        public let formulae: [InstalledApplication]
        public let casks: [HomebrewCaskRecord]
        public let caskAppBundleNames: [String: HomebrewCaskRecord]

        public static let empty = HomebrewParsedResult(formulae: [], casks: [], caskAppBundleNames: [:])
    }

    private func fetchHomebrewInstalled() async -> HomebrewParsedResult {
        guard let brew = brewExecutablePath else { return .empty }
        let (status, output) = await CleanupExecutor.runProcess(
            executable: brew,
            arguments: ["info", "--json=v2", "--installed"]
        )
        guard status == 0, let data = output.data(using: .utf8) else {
            return .empty
        }
        let prefix = brew.hasPrefix("/opt/homebrew") ? "/opt/homebrew" : "/usr/local"
        return Self.parseHomebrewJSON(
            data,
            cellarPrefix: URL(fileURLWithPath: "\(prefix)/Cellar"),
            caskroomPrefix: URL(fileURLWithPath: "\(prefix)/Caskroom")
        )
    }

    /// Parses `brew info --json=v2 --installed` payload into formulae (with reverse-dependency graph) and casks.
    public static func parseHomebrewJSON(
        _ data: Data,
        cellarPrefix: URL,
        caskroomPrefix: URL
    ) -> HomebrewParsedResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }

        // Parse formulae
        let rawFormulae = json["formulae"] as? [[String: Any]] ?? []
        var dependenciesByFormula: [String: [String]] = [:]
        var reverseDeps: [String: [String]] = [:]

        for entry in rawFormulae {
            guard let name = entry["name"] as? String else { continue }
            let deps = entry["dependencies"] as? [String] ?? []
            dependenciesByFormula[name] = deps
            for dep in deps {
                reverseDeps[dep, default: []].append(name)
            }
        }

        var formulae: [InstalledApplication] = []
        for entry in rawFormulae {
            guard let name = entry["name"] as? String else { continue }
            let desc = entry["desc"] as? String
            let installedList = entry["installed"] as? [[String: Any]] ?? []
            let firstInstalled = installedList.first
            let version = firstInstalled?["version"] as? String
                ?? (entry["versions"] as? [String: Any])?["stable"] as? String
            let installedOnRequest = firstInstalled?["installed_on_request"] as? Bool ?? true
            let installedAsDep = firstInstalled?["installed_as_dependency"] as? Bool ?? !installedOnRequest

            let cellarPath = cellarPrefix.appendingPathComponent(name)
            let stats = ConcurrentScanEngine.calculatePhysicalSize(at: cellarPath)

            formulae.append(InstalledApplication(
                id: "formula:\(name)",
                name: name,
                bundleIdentifier: nil,
                version: version,
                source: .homebrewFormula,
                installPath: cellarPath,
                appSize: max(stats.physical, stats.logical),
                associatedFiles: [],
                lastModified: stats.latestModDate,
                reverseDependencies: (reverseDeps[name] ?? []).sorted(),
                isDependencyOnly: installedAsDep && !installedOnRequest,
                homebrewToken: name,
                descriptionText: desc
            ))
        }

        // Parse casks
        let rawCasks = json["casks"] as? [[String: Any]] ?? []
        var casks: [HomebrewCaskRecord] = []
        var appBundleMap: [String: HomebrewCaskRecord] = [:]

        for entry in rawCasks {
            guard let token = entry["token"] as? String else { continue }
            let names = entry["name"] as? [String] ?? []
            let displayName = names.first ?? token
            let version = entry["installed"] as? String ?? entry["version"] as? String
            let desc = entry["desc"] as? String

            var appArtifacts: [String] = []
            if let artifacts = entry["artifacts"] as? [[String: Any]] {
                for artifact in artifacts {
                    if let apps = artifact["app"] as? [Any] {
                        for appItem in apps {
                            if let appName = appItem as? String {
                                appArtifacts.append(appName)
                            } else if let arr = appItem as? [Any], let appName = arr.first as? String {
                                appArtifacts.append(appName)
                            }
                        }
                    }
                }
            }

            let caskPath = caskroomPrefix.appendingPathComponent(token)
            let record = HomebrewCaskRecord(
                token: token,
                displayName: displayName,
                version: version,
                desc: desc,
                appArtifacts: appArtifacts,
                caskroomPath: caskPath
            )
            casks.append(record)
            for appArtifact in appArtifacts {
                let fileName = URL(fileURLWithPath: appArtifact).lastPathComponent.lowercased()
                appBundleMap[fileName] = record
            }
        }

        return HomebrewParsedResult(
            formulae: formulae,
            casks: casks,
            caskAppBundleNames: appBundleMap
        )
    }

    // MARK: - App Bundle Discovery & Leftover Matching

    private struct AppBundleInfo {
        let displayName: String
        let bundleID: String?
        let version: String?
    }

    private static func discoverAppBundles(in directories: [URL]) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        var seenPaths = Set<String>()

        for dir in directories {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in items {
                if item.pathExtension.lowercased() == "app" {
                    let std = item.standardizedFileURL.path
                    if seenPaths.insert(std).inserted {
                        results.append(item.standardizedFileURL)
                    }
                }
            }
        }
        return results
    }

    private static func readAppBundleInfo(at appURL: URL) -> AppBundleInfo {
        let fallbackName = appURL.deletingPathExtension().lastPathComponent
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            return AppBundleInfo(displayName: fallbackName, bundleID: nil, version: nil)
        }

        let displayName = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String)
            ?? fallbackName
        let bundleID = dict["CFBundleIdentifier"] as? String
        let version = (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String)

        return AppBundleInfo(displayName: displayName, bundleID: bundleID, version: version)
    }

    /// Finds associated `~/Library` data, caches, containers, preferences, and launch agents for an app.
    public static func findAssociatedLibraryFiles(
        appName: String,
        bundleID: String?,
        home: URL
    ) -> [CleanupItem] {
        let fm = FileManager.default
        let libraryURL = home.appendingPathComponent("Library")
        let lowerBundleID = bundleID?.lowercased()
        let normAppName = appName.lowercased().filter { $0.isLetter || $0.isNumber }

        guard (lowerBundleID != nil && !(lowerBundleID!.isEmpty)) || normAppName.count >= 4 else {
            return []
        }

        let locations: [(subdir: String, tag: String)] = [
            ("Application Support", "Application Support"),
            ("Caches", "Cache"),
            ("Containers", "Container"),
            ("Group Containers", "Group Container"),
            ("Preferences", "Preferences"),
            ("Saved Application State", "Saved State"),
            ("HTTPStorages", "HTTP Storage"),
            ("WebKit", "WebKit Data"),
            ("Logs", "Logs"),
            ("LaunchAgents", "Launch Agent")
        ]

        var matched: [CleanupItem] = []

        for loc in locations {
            let folder = libraryURL.appendingPathComponent(loc.subdir)
            guard let entries = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let raw = entry.lastPathComponent
                let lower = raw.lowercased()
                if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") {
                    continue
                }

                var isMatch = false
                if let lowerBundleID {
                    if lower == lowerBundleID ||
                        lower.hasPrefix(lowerBundleID + ".") ||
                        lower.contains(lowerBundleID) {
                        isMatch = true
                    }
                }
                if !isMatch && normAppName.count >= 4 {
                    let stripped = lower
                        .replacingOccurrences(of: ".plist", with: "")
                        .replacingOccurrences(of: ".savedstate", with: "")
                    let normEntry = stripped.filter { $0.isLetter || $0.isNumber }
                    if normEntry == normAppName {
                        isMatch = true
                    }
                }

                if isMatch {
                    let stats = ConcurrentScanEngine.calculatePhysicalSize(at: entry)
                    let size = max(stats.physical, stats.logical)
                    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    matched.append(CleanupItem(
                        url: entry,
                        displayName: raw,
                        subtitle: "~/Library/\(loc.subdir)",
                        size: size,
                        bucket: .applications,
                        confidence: .medium,
                        rationale: "Associated \(loc.tag) data for \(appName).",
                        lastModified: stats.latestModDate,
                        tag: loc.tag,
                        isDirectory: isDir
                    ))
                }
            }
        }

        return matched.sorted { $0.size > $1.size }
    }

    // MARK: - Direct Curl / Standalone CLI Tool Discovery

    private static func discoverCurlAndCLITools(
        home: URL,
        cliDirs: [URL],
        homebrewFormulaNames: Set<String>
    ) -> [InstalledApplication] {
        let fm = FileManager.default
        var results: [InstalledApplication] = []
        var seenNames = Set<String>()

        // 1. Known curl-scripted toolchains installed into home dot-directories
        let knownToolchains: [(relPath: String, name: String, desc: String, extraPaths: [String])] = [
            (".bun", "Bun", "JavaScript runtime installed via curl script (~/.bun)", []),
            (".deno", "Deno", "JavaScript/TypeScript runtime installed via curl (~/.deno)", []),
            (".nvm", "nvm", "Node Version Manager installed via curl (~/.nvm)", []),
            (".pyenv", "pyenv", "Python version manager (~/.pyenv)", []),
            (".volta", "Volta", "JavaScript tool manager installed via curl (~/.volta)", []),
            (".fnm", "fnm", "Fast Node Manager (~/.fnm)", []),
            (".sdkman", "SDKMAN!", "SDK version manager installed via curl (~/.sdkman)", []),
            (".rye", "Rye", "Python toolchain manager (~/.rye)", []),
            (".rustup", "Rustup Toolchain", "Rust toolchain manager installed via curl (~/.rustup)", [".cargo"]),
            (".ollama", "Ollama Data & Models", "Local LLM runtime models & config (~/.ollama)", []),
            (".oh-my-zsh", "Oh My Zsh", "Zsh configuration framework installed via curl (~/.oh-my-zsh)", [])
        ]

        for tc in knownToolchains {
            let url = home.appendingPathComponent(tc.relPath)
            guard fm.fileExists(atPath: url.path) else { continue }
            let stats = ConcurrentScanEngine.calculatePhysicalSize(at: url)
            guard stats.physical > 0 || stats.logical > 0 else { continue }

            var associated: [CleanupItem] = []
            for extra in tc.extraPaths {
                let extraURL = home.appendingPathComponent(extra)
                if fm.fileExists(atPath: extraURL.path) {
                    let eStats = ConcurrentScanEngine.calculatePhysicalSize(at: extraURL)
                    associated.append(CleanupItem(
                        url: extraURL,
                        displayName: extra,
                        subtitle: "~/\(extra)",
                        size: max(eStats.physical, eStats.logical),
                        bucket: .applications,
                        confidence: .review,
                        rationale: "Associated toolchain directory for \(tc.name).",
                        lastModified: eStats.latestModDate,
                        tag: "Toolchain Data",
                        isDirectory: true
                    ))
                }
            }

            seenNames.insert(tc.name.lowercased())
            results.append(InstalledApplication(
                id: "curl-tc:\(url.path)",
                name: tc.name,
                source: .curlCLI,
                installPath: url,
                appSize: max(stats.physical, stats.logical),
                associatedFiles: associated,
                lastModified: stats.latestModDate,
                descriptionText: tc.desc
            ))
        }

        // 2. Standalone user CLI binaries in ~/.local/bin, /usr/local/bin, ~/go/bin, ~/.cargo/bin
        for dir in cliDirs {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isExecutableKey, .isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let name = entry.lastPathComponent
                let lowerName = name.lowercased()
                if seenNames.contains(lowerName) { continue }

                // Skip directories inside bin folders
                let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isExecutableKey])
                if vals?.isDirectory == true { continue }
                guard fm.isExecutableFile(atPath: entry.path) else { continue }

                // Exclude Homebrew-managed symlinks and Apple system binaries
                let resolvedPath = entry.resolvingSymlinksInPath().standardizedFileURL.path
                if resolvedPath.hasPrefix("/opt/homebrew/") ||
                    resolvedPath.hasPrefix("/usr/local/Cellar/") ||
                    resolvedPath.hasPrefix("/usr/local/Caskroom/") ||
                    resolvedPath.hasPrefix("/System/") ||
                    resolvedPath.hasPrefix("/usr/bin/") ||
                    resolvedPath.hasPrefix("/Applications/") {
                    continue
                }
                if homebrewFormulaNames.contains(lowerName) && dir.path == "/usr/local/bin" {
                    continue
                }

                let stats = ConcurrentScanEngine.calculatePhysicalSize(at: entry)
                let size = max(stats.physical, stats.logical)

                // Check for matching ~/.config/<name> or ~/.<name>
                var associated: [CleanupItem] = []
                let candidateConfigs = [
                    home.appendingPathComponent(".config/\(name)"),
                    home.appendingPathComponent(".\(name)"),
                    home.appendingPathComponent("Library/Caches/\(name)")
                ]
                for cfg in candidateConfigs where fm.fileExists(atPath: cfg.path) {
                    let cStats = ConcurrentScanEngine.calculatePhysicalSize(at: cfg)
                    associated.append(CleanupItem(
                        url: cfg,
                        displayName: cfg.lastPathComponent,
                        subtitle: cfg.deletingLastPathComponent().path,
                        size: max(cStats.physical, cStats.logical),
                        bucket: .applications,
                        confidence: .review,
                        rationale: "Configuration or cache directory for CLI tool '\(name)'.",
                        lastModified: cStats.latestModDate,
                        tag: "CLI Config",
                        isDirectory: true
                    ))
                }

                seenNames.insert(lowerName)
                results.append(InstalledApplication(
                    id: "curl-bin:\(entry.standardizedFileURL.path)",
                    name: name,
                    source: .curlCLI,
                    installPath: entry,
                    appSize: size,
                    associatedFiles: associated,
                    lastModified: stats.latestModDate,
                    descriptionText: "Standalone CLI binary in \(dir.path)"
                ))
            }
        }

        return results
    }
}
