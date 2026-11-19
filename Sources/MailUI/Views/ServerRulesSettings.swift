import MailCore
import SwiftUI

/// For `-snapshot-settings server-rule`: the rule editor changing a rule kept on the sample
/// mailbox's server.
public struct ServerRuleEditorSnapshot: View {
    let model: MailModel
    @State private var book = ServerRuleBook()
    @State private var form: RuleForm

    public init(model: MailModel) {
        self.model = model
        let accountID = model.accounts.first?.id ?? UUID()
        _form = State(initialValue: RuleForm(server: ServerRule(id: "1", name: String(localized: "Receipts"), from: "billing@",
                                                                subject: String(localized: "receipt"), hasAttachment: true,
                                                                moveTo: "receipts", markRead: true, flag: true),
                                             accountID: accountID))
    }

    public var body: some View {
        Form {
            Section {
                RuleEditor(model: model, book: book, form: $form)
            } header: {
                Text("Change rule")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 900)
        .task { await book.loadAll(model) }
    }
}
