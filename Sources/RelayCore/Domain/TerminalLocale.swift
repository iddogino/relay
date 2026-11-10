import Foundation

/// The locale remote programs get on iOS, which has no LANG of its own: the
/// one a Mac set to the same language and region forwards (`SendEnv LANG`).
/// tmux needs a UTF-8 one — without, it draws `_` for anything non-ASCII
/// and garbles the session list.
public enum TerminalLocale {
    /// `ll_RR.UTF-8` for the locale's language and region; en_US when
    /// either is missing.
    public static func lang(for locale: Locale) -> String {
        guard let language = locale.language.languageCode?.identifier, language.count == 2 || language.count == 3,
              let region = locale.region?.identifier, region.count == 2,
              language.allSatisfy(\.isLetter), region.allSatisfy(\.isLetter)
        else { return "en_US.UTF-8" }
        return "\(language.lowercased())_\(region.uppercased()).UTF-8"
    }
}
