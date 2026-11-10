#if os(iOS)
import Observation
import UIKit

/// Whether the software keyboard is on screen (a hardware keyboard's
/// accessory bar alone doesn't count).
@MainActor
@Observable
final class KeyboardObserver {
    static let shared = KeyboardObserver()

    private(set) var softwareKeyboardShown = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated { KeyboardObserver.shared.update(frame: frame) }
        }
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { KeyboardObserver.shared.softwareKeyboardShown = false }
        }
    }

    private func update(frame: CGRect) {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let visible = screen.map { frame.intersection($0.bounds).height } ?? frame.height
        // Taller than any accessory bar: keys.
        softwareKeyboardShown = visible > 120
    }
}
#endif
