import Foundation

/// The user's home folder — the real one. In the App Sandbox,
/// `NSHomeDirectory()` and `~` expansion give the app's container instead,
/// which holds no `.ssh`; paths a user typed or a config names (`~/.ssh/…`)
/// mean the real one, which the app reads once the user grants it access.
public enum UserHome {
    public static let path: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return path }
        }
        return NSHomeDirectory()
    }()

    /// Whether this process runs in the App Sandbox (where the real home
    /// folder is readable only once the user grants access).
    public static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// `path` with a leading `~` or `~/` replaced by the real home folder.
    /// (`~user` forms are left alone.)
    public static func expand(_ path: String) -> String {
        if path == "~" { return Self.path }
        if path.hasPrefix("~/") { return Self.path + path.dropFirst(1) }
        return path
    }

    /// `path` with the home folder shortened back to `~`, for display.
    public static func abbreviate(_ path: String) -> String {
        if path == Self.path { return "~" }
        if path.hasPrefix(Self.path + "/") { return "~" + path.dropFirst(Self.path.count) }
        return path
    }
}
