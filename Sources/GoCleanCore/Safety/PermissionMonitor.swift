import Darwin
import Foundation

/// Detects whether macOS Full Disk Access has been granted to the current process.
public struct PermissionMonitor: Sendable {
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    public init() {}

    /// Performs real POSIX read/opendir probes on TCC-protected macOS locations
    /// (since `FileManager.isReadableFile` only checks POSIX bits and ignores TCC).
    public func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let protectedFiles = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
            "\(home)/Library/Messages/chat.db"
        ]

        var probedAnyExistingTarget = false
        for path in protectedFiles {
            var st = stat()
            if stat(path, &st) == 0 {
                probedAnyExistingTarget = true
                let fd = open(path, O_RDONLY)
                if fd >= 0 {
                    close(fd)
                    return true
                }
            }
        }

        let protectedDirs = [
            "\(home)/Library/Safari",
            "\(home)/Library/Mail",
            "\(home)/Library/Messages"
        ]

        for dirPath in protectedDirs {
            var st = stat()
            if stat(dirPath, &st) == 0 {
                probedAnyExistingTarget = true
                if let dir = opendir(dirPath) {
                    closedir(dir)
                    return true
                }
            }
        }

        return !probedAnyExistingTarget
    }
}
