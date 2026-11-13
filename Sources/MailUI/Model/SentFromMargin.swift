import Foundation
import MailCore
import SwiftUI

/// "Sent from Margin" at the end of a new message, reply or forward, under the signature: in
/// the text as you write, with "Margin" linking to Margin's site right there in the editor, so
/// what you see is what's sent. Delete or change it like any text; nothing is added or changed
/// when you send. On by default, with its words yours to change, or off (Settings → Writing).
/// Never on reactions, invitation answers or mail sent by a rule, which don't start in the composer.
extension MailModel {
    nonisolated static let marginSite = "https://margin.relevate.app"

    public var addsSentFromMargin: Bool {
        get { _ = writingRevision; return environment.defaults.object(forKey: "sentFromMargin") as? Bool ?? true }
        set { environment.defaults.set(newValue, forKey: "sentFromMargin"); writingRevision += 1 }
    }

    /// The line's words; empty means the standard "Sent from Margin".
    public var sentFromMarginText: String {
        get { _ = writingRevision; return environment.defaults.string(forKey: "sentFromMarginText") ?? "" }
        set { environment.defaults.set(newValue, forKey: "sentFromMarginText"); writingRevision += 1 }
    }

    static var standardSentFromMargin: String { String(localized: "Sent from Margin") }

    /// The line as it's set now; nil when it's off.
    var sentFromLine: String? {
        guard addsSentFromMargin else { return nil }
        let typed = sentFromMarginText.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? Self.standardSentFromMargin : typed
    }

    /// A message just started, with the line under its signature when it's on.
    func withSentFrom(_ state: ComposeState) -> ComposeState {
        guard let line = sentFromLine else { return state }
        var state = state
        state.addSentFrom(line)
        return state
    }

    /// The words in the line that link to Margin's site: "Margin", or the whole line when the
    /// words don't say it.
    nonisolated static func linkRange(in line: String) -> Range<String.Index> {
        line.range(of: "Margin", options: .backwards) ?? line.startIndex..<line.endIndex
    }
}

/// Settings → Writing: the line under mail you send.
struct SentFromMarginSection: View {
    @Bindable var model: MailModel
    @State private var text = ""

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.addsSentFromMargin }, set: { model.addsSentFromMargin = $0 })) {
                SettingLabel("Sent from Margin", detail: "A small line under mail you send, linking to margin.relevate.app. It goes after your signature.")
            }
            if model.addsSentFromMargin {
                TextField(text: $text, prompt: Text(verbatim: MailModel.standardSentFromMargin)) { Text("Words") }
                    .onChange(of: text) { _, value in model.sentFromMarginText = value }
            }
        }
        .onAppear { text = model.sentFromMarginText }
    }
}
