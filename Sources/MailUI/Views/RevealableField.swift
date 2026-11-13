import SwiftUI

/// A password field with an eye to show what's typed, for passwords the person sets themselves
/// (backups), where a typo would lock them out.
struct RevealableField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var prompt: Text?
    @State private var shows = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if shows {
                    TextField(title, text: $text, prompt: prompt)
                } else {
                    SecureField(title, text: $text, prompt: prompt)
                }
            }
            .labelsHidden()
            Button { shows.toggle() } label: {
                Image(systemName: shows ? "eye.slash" : "eye").foregroundStyle(Ink.tertiary)
            }
            .buttonStyle(.plain)
            .help(shows ? Text("Hide password") : Text("Show password"))
        }
    }
}
