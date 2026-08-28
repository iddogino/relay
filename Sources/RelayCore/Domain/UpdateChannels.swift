import Foundation

/// Which Sparkle update channels this install should see. Stable items in
/// the appcast carry no channel and are visible to everyone; prerelease
/// items are tagged with `rc` and shown only to installs that ride that
/// channel.
public enum UpdateChannels {
    public static let earlyChannel = "rc"

    /// A prerelease install (its version carries a `-channel.N` suffix)
    /// stays on the early channel automatically — whoever installed an rc
    /// keeps getting rcs, and graduates to stable when one ships (stable
    /// builds always carry a higher build number). Stable installs join
    /// only by explicit opt-in.
    public static func allowed(currentVersion: String, earlyBuildsOptIn: Bool) -> Set<String> {
        if earlyBuildsOptIn || currentVersion.contains("-") {
            return [earlyChannel]
        }
        return []
    }
}
