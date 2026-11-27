import Foundation

/// Validation result from `SafetyGuard`.
public enum SafetyValidation: Equatable, Sendable {
    case allowed
    case blocked(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Non-bypassable safety guardrail preventing deletion of critical macOS system directories
/// or top-level user home folders.
public struct SafetyGuard: Sendable {
    private let homePath: String
    private let exactBlockedPaths: Set<String>
    private let blockedPrefixes: [String]

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let home = homeDirectory.standardizedFileURL.path
        self.homePath = home

        self.exactBlockedPaths = [
            "/",
            "/System",
            "/usr",
            "/usr/bin",
            "/usr/sbin",
            "/usr/lib",
            "/usr/local",
            "/usr/local/bin",
            "/bin",
            "/sbin",
            "/dev",
            "/etc",
            "/private",
            "/private/etc",
            "/private/var",
            "/private/var/db",
            "/private/var/vm",
            "/Library",
            "/Library/Apple",
            "/Library/System",
            "/Applications",
            "/Applications/Utilities",
            "/Users",
            "/Volumes",
            "/opt",
            "/opt/homebrew",
            home,
            "\(home)/Library",
            "\(home)/Library/Application Support",
            "\(home)/Library/Caches",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Preferences",
            "\(home)/Library/Logs",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/LaunchAgents",
            "\(home)/Library/Keychains",
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Pictures",
            "\(home)/Movies",
            "\(home)/Music",
            "\(home)/Public",
            "\(home)/.ssh",
            "\(home)/.gnupg"
        ]

        self.blockedPrefixes = [
            "/System/",
            "/usr/bin/",
            "/usr/sbin/",
            "/usr/lib/",
            "/usr/libexec/",
            "/usr/share/",
            "/bin/",
            "/sbin/",
            "/dev/",
            "/private/var/db/",
            "/Library/Apple/",
            "\(home)/Library/Keychains/",
            "\(home)/.ssh/",
            "\(home)/.gnupg/"
        ]
    }

    /// Validates whether `url` is safe to stage or delete.
    public func validate(url: URL) -> SafetyValidation {
        let standardized = url.standardizedFileURL.path
        let trimmed = standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast())
            : standardized

        if trimmed.isEmpty {
            return .blocked(reason: "Empty path is not permitted.")
        }

        if exactBlockedPaths.contains(trimmed) {
            return .blocked(reason: "'\(trimmed)' is a protected macOS or top-level user directory.")
        }

        for prefix in blockedPrefixes {
            if trimmed.hasPrefix(prefix) {
                return .blocked(reason: "'\(trimmed)' resides inside a SIP or security-protected directory.")
            }
        }

        // Also check symlink destination so symlinks cannot escape into protected paths.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        if resolved != trimmed {
            if exactBlockedPaths.contains(resolved) {
                return .blocked(reason: "Symlink resolves to protected path '\(resolved)'.")
            }
            for prefix in blockedPrefixes where resolved.hasPrefix(prefix) {
                return .blocked(reason: "Symlink resolves inside protected path '\(resolved)'.")
            }
        }

        return .allowed
    }
}

/// Executes safe deletions (Move to Trash / Permanent Erase) and Homebrew uninstalls.
public struct CleanupExecutor: Sendable {
    public let safetyGuard: SafetyGuard

    public init(safetyGuard: SafetyGuard = SafetyGuard()) {
        self.safetyGuard = safetyGuard
    }

    /// Executes deletion for a batch of staged `CleanupItem`s.
    public func execute(items: [CleanupItem], mode: DeletionMode) async -> CleanupExecutionResult {
        var succeeded: [URL] = []
        var freed: UInt64 = 0
        var failures: [CleanupExecutionResult.Failure] = []
        let fm = FileManager.default

        for item in items {
            let validation = safetyGuard.validate(url: item.url)
            if case .blocked(let reason) = validation {
                failures.append(.init(url: item.url, reason: reason))
                continue
            }

            guard fm.fileExists(atPath: item.url.path) else {
                // Already removed (e.g. parent folder was also staged)
                succeeded.append(item.url)
                continue
            }

            do {
                switch mode {
                case .moveToTrash:
                    var resultingURL: NSURL?
                    try fm.trashItem(at: item.url, resultingItemURL: &resultingURL)
                case .permanentErase:
                    try fm.removeItem(at: item.url)
                }
                succeeded.append(item.url)
                freed &+= item.size
            } catch {
                failures.append(.init(url: item.url, reason: error.localizedDescription))
            }
        }

        return CleanupExecutionResult(
            succeededURLs: succeeded,
            freedBytes: freed,
            failures: failures,
            mode: mode
        )
    }

    /// Uninstalls an `InstalledApplication` using its native strategy (Homebrew or Trash) plus selected leftovers.
    public func uninstall(
        application: InstalledApplication,
        includeAssociatedFiles: Bool,
        mode: DeletionMode = .moveToTrash,
        brewPath: String? = nil
    ) async -> CleanupExecutionResult {
        var succeeded: [URL] = []
        var freed: UInt64 = 0
        var failures: [CleanupExecutionResult.Failure] = []
        var commandOutput: String?

        switch application.uninstallStrategy {
        case .homebrewCask(let token, let zap):
            if let brew = brewPath ?? Self.resolveBrewExecutable() {
                var args = ["uninstall", "--cask"]
                if zap { args.append("--zap") }
                args.append(token)
                let (status, output) = await Self.runProcess(executable: brew, arguments: args)
                commandOutput = output
                if status == 0 {
                    succeeded.append(application.installPath)
                    freed &+= application.appSize
                } else {
                    failures.append(.init(
                        url: application.installPath,
                        reason: "brew uninstall failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                    ))
                }
            } else {
                failures.append(.init(url: application.installPath, reason: "Homebrew executable not found."))
            }

        case .homebrewFormula(let name):
            if let brew = brewPath ?? Self.resolveBrewExecutable() {
                let (status, output) = await Self.runProcess(executable: brew, arguments: ["uninstall", name])
                commandOutput = output
                if status == 0 {
                    succeeded.append(application.installPath)
                    freed &+= application.appSize
                } else {
                    failures.append(.init(
                        url: application.installPath,
                        reason: "brew uninstall failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                    ))
                }
            } else {
                failures.append(.init(url: application.installPath, reason: "Homebrew executable not found."))
            }

        case .trashFiles:
            let appItem = CleanupItem(
                url: application.installPath,
                displayName: application.name,
                size: application.appSize,
                bucket: .applications,
                confidence: .review,
                isDirectory: true
            )
            let appResult = await execute(items: [appItem], mode: mode)
            succeeded.append(contentsOf: appResult.succeededURLs)
            freed &+= appResult.freedBytes
            failures.append(contentsOf: appResult.failures)
        }

        if includeAssociatedFiles && !application.associatedFiles.isEmpty {
            let extraResult = await execute(items: application.associatedFiles, mode: mode)
            succeeded.append(contentsOf: extraResult.succeededURLs)
            freed &+= extraResult.freedBytes
            failures.append(contentsOf: extraResult.failures)
        }

        return CleanupExecutionResult(
            succeededURLs: succeeded,
            freedBytes: freed,
            failures: failures,
            mode: mode,
            commandOutput: commandOutput
        )
    }

    public static func resolveBrewExecutable() -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func runProcess(executable: String, arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            // Ensure Homebrew finds git/curl/etc. in PATH
            var env = ProcessInfo.processInfo.environment
            let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = env["PATH"].map { "\($0):\(defaultPath)" } ?? defaultPath
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, output))
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}
