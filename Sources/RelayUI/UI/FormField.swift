import SwiftUI

/// A labeled text field in a form: the label in the Mac's label column; on
/// iOS beside the field in its row (iOS forms show no TextField labels).
struct FormField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var secure = false
    #if os(iOS)
    var keyboard: UIKeyboardType = .default
    #endif

    var body: some View {
        #if os(macOS)
        if secure {
            SecureField(label, text: $text, prompt: Text(prompt))
        } else {
            TextField(label, text: $text, prompt: Text(prompt))
        }
        #else
        LabeledContent(label) {
            Group {
                if secure {
                    SecureField(label, text: $text, prompt: Text(prompt))
                } else {
                    TextField(label, text: $text, prompt: Text(prompt))
                        .keyboardType(keyboard)
                }
            }
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        #endif
    }
}
