import Foundation
import Testing
@testable import RelayCore

@Suite("terminal key defaults")
struct TerminalKeyDefaultsTests {
    @Test func findsTheUsersOwnShiftEnterBinding() {
        #expect(TerminalKeyDefaults.bindsShiftEnter(#"keybind = shift+enter=text:\n"#))
        #expect(TerminalKeyDefaults.bindsShiftEnter("font-size = 13\n  keybind=Enter+Shift=text:\\x1b\\r\n"))
        #expect(TerminalKeyDefaults.bindsShiftEnter("keybind = global:shift+enter=unbind"))
        #expect(TerminalKeyDefaults.bindsShiftEnter("keybind = ctrl+a>shift+enter=new_split:right"))
    }

    @Test func otherBindingsAndCommentsDontCount() {
        #expect(!TerminalKeyDefaults.bindsShiftEnter(""))
        #expect(!TerminalKeyDefaults.bindsShiftEnter("keybind = enter=text:\\n"))
        #expect(!TerminalKeyDefaults.bindsShiftEnter("keybind = ctrl+shift+enter=toggle_fullscreen"))
        #expect(!TerminalKeyDefaults.bindsShiftEnter("# keybind = shift+enter=text:\\n"))
        #expect(!TerminalKeyDefaults.bindsShiftEnter("keybind = shift+enter>a=text:x"))
    }

    @Test func looksWhereGhosttyReadsItsConfig() {
        let home = URL(fileURLWithPath: "/Users/u")
        #expect(TerminalKeyDefaults.userConfigFiles(home: home, environment: [:]).map(\.path) == [
            "/Users/u/.config/ghostty/config",
            "/Users/u/.config/ghostty/config.ghostty",
            "/Users/u/Library/Application Support/com.mitchellh.ghostty/config",
            "/Users/u/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
        #expect(TerminalKeyDefaults.userConfigFiles(home: home, environment: ["XDG_CONFIG_HOME": "/x"]).first?.path
                == "/x/ghostty/config")
    }
}
