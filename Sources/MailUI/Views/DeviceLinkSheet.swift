import MailCore
import SwiftUI

/// Shown when a device-link file from another device is opened: type the code shown there.
struct DeviceLinkSheet: View {
    let model: MailModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Link this device").font(TypeScale.heading).foregroundStyle(Ink.primary)
            Text("Type the code shown on your other device. Its mailboxes, passwords, settings, labels and templates are added here. Nothing already here is removed.")
                .font(TypeScale.row).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Code", text: $code, prompt: Text(verbatim: "ABCD-2345"))
                .fieldStyle()
                .font(TypeScale.row.monospaced())
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                #endif
                .onSubmit(accept)
            // Always there, so the sheet doesn't jump when a problem appears.
            Text(verbatim: problem ?? " ").font(TypeScale.label).foregroundStyle(Status.danger)
            HStack {
                Spacer()
                Button("Cancel") { model.pendingDeviceLink = nil; dismiss() }.buttonStyle(QuietButtonStyle())
                Button("Link", action: accept).buttonStyle(InkButtonStyle()).disabled(BackupBox.normalized(code).count < 8)
            }
        }
        .padding(Space.xl)
        #if os(macOS)
        .frame(width: 420)
        #endif
    }

    private func accept() {
        do {
            model.notice = Notice(text: try model.acceptDeviceLink(code: code))
            dismiss()
        } catch BackupBox.Failure.wrongPassword {
            problem = String(localized: "That code doesn't match. Check it on the other device.")
        } catch {
            problem = error.localizedDescription
        }
    }
}
