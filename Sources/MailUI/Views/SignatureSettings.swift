import MailCore
import SwiftUI

/// A signature open in its editor, and the name it had (nil for a new one).
struct SignatureEditing: Identifiable {
    let id = UUID()
    let original: String?
    let signature: NamedSignature
}

extension SignatureSet {
    /// An empty signature with the next free name ("Signature 2"…).
    func newSignature() -> NamedSignature {
        let taken = Set(allSignatures.map(\.name))
        let name = (2...).lazy.map { String(localized: "Signature \($0)", table: "Settings") }.first { !taken.contains($0) } ?? ""
        return NamedSignature(name: name, text: "")
    }
}

/// Where signatures are kept: shared by every inbox, shared by a workspace's, or one inbox's.
enum SignatureOwner: Hashable {
    case all, workspace(UUID), account(UUID)

    /// The key its shared signatures are saved under.
    var sharedKey: String? {
        switch self {
        case .all: "all"
        case .workspace(let id): id.uuidString
        case .account: nil
        }
    }
}

extension MailModel {
    /// Signatures shared by every inbox ("all") and by workspaces (by id). Saved with the other
    /// settings, so they sync and are backed up.
    var sharedSignatureSets: [String: SharedSignatures] {
        get {
            _ = contactSettingsRevision
            guard let data = environment.defaults.data(forKey: "sharedSignatures") else { return [:] }
            return (try? JSONDecoder().decode([String: SharedSignatures].self, from: data)) ?? [:]
        }
        set {
            let kept = newValue.filter { !$0.value.isEmpty }
            if kept.isEmpty {
                environment.defaults.removeObject(forKey: "sharedSignatures")
            } else {
                environment.defaults.set(try? JSONEncoder().encode(kept), forKey: "sharedSignatures")
            }
            contactSettingsRevision += 1
            applySharedSignatures()
        }
    }

    /// The shared signatures a mailbox falls back on: those of a workspace it's in, else every
    /// inbox's.
    func sharedSignatures(for accountID: UUID, in sets: [String: SharedSignatures]) -> SharedSignatures? {
        for workspace in workspaces where workspace.accounts.contains(accountID) {
            if var shared = sets[workspace.id.uuidString], !shared.isEmpty {
                shared.title = workspace.name
                return shared
            }
        }
        guard var shared = sets["all"], !shared.isEmpty else { return nil }
        shared.title = String(localized: "All inboxes", table: "Settings")
        return shared
    }

    /// Hands each mailbox the shared signatures it falls back on. Only changes what's
    /// different, so setting the mailboxes here doesn't start it again.
    func applySharedSignatures() {
        let sets = sharedSignatureSets
        let wanted = accounts.map { sharedSignatures(for: $0.id, in: sets) }
        guard zip(accounts, wanted).contains(where: { $0.sharedSignatures.value != $1 }) else { return }
        var updated = accounts
        for index in updated.indices { updated[index].sharedSignatures = Unsaved(wanted[index]) }
        accounts = updated
    }

    /// What a place's signatures are called: "All Inboxes", the workspace's name, the inbox's.
    func signatureOwnerName(_ owner: SignatureOwner) -> String {
        switch owner {
        case .all: String(localized: "All inboxes", table: "Settings")
        case .workspace(let id): workspaces.first { $0.id == id }?.name ?? ""
        case .account(let id): account(id)?.label ?? ""
        }
    }

    /// One place's signatures.
    func signatureSet(of owner: SignatureOwner) -> any SignatureSet {
        switch owner {
        case .account(let id): account(id) ?? SharedSignatures()
        default: sharedSignatureSets[owner.sharedKey ?? ""] ?? SharedSignatures()
        }
    }

    /// Changes one place's signatures and saves them; a mailbox isn't reconnected.
    func changeSignatures(of owner: SignatureOwner, _ change: (inout any SignatureSet) -> Void) {
        switch owner {
        case .account(let id):
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            var set: any SignatureSet = accounts[index]
            change(&set)
            guard let changed = set as? MailAccount else { return }
            accounts[index] = changed
            try? environment.accounts.save(accounts)
        case .all, .workspace:
            guard let key = owner.sharedKey else { return }
            var sets = sharedSignatureSets
            var set: any SignatureSet = sets[key] ?? SharedSignatures()
            change(&set)
            sets[key] = set as? SharedSignatures
            sharedSignatureSets = sets
        }
    }

    /// Copies a signature to another place, as its default or next to its others.
    func copySignature(_ signature: NamedSignature, from source: SignatureOwner, to target: SignatureOwner, asDefault: Bool) {
        let sourceName = signatureOwnerName(source)
        changeSignatures(of: target) { $0.copySignature(signature, from: sourceName, asDefault: asDefault) }
        notice = Notice(text: String(localized: "Copied to \(signatureOwnerName(target))", table: "Settings"))
    }
}

/// Settings → Signatures: signatures shared by every inbox and by each workspace, then every
/// inbox's own, to write, change, remove, or copy somewhere else. Changes are saved as they're
/// made.
struct SignaturesSettings: View {
    @Bindable var model: MailModel
    @State private var editing: (owner: SignatureOwner, item: SignatureEditing)?

    /// Every place signatures can be kept, in the page's order.
    private var owners: [SignatureOwner] {
        [.all] + model.workspaces.map { .workspace($0.id) } + model.accounts.map { .account($0.id) }
    }

    var body: some View {
        Form {
            SettingsHeader(.signatures)
            // The line that goes under every signature: one switch, so it comes first.
            SentFromMarginSection(model: model)
            ForEach(owners, id: \.self) { owner in
                section(owner)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing {
                let set = model.signatureSet(of: editing.owner)
                SignatureSheet(original: editing.item.signature, isDefault: editing.item.original == NamedSignature.defaultName,
                               takenNames: Set(set.allSignatures.map(\.name)).subtracting([editing.item.original ?? ""])) { saved in
                    model.changeSignatures(of: editing.owner) { $0.saveSignature(saved, replacing: editing.item.original) }
                }
            }
        }
    }

    private func section(_ owner: SignatureOwner) -> some View {
        SignatureOwnerSection(model: model, owner: owner, others: owners.filter { $0 != owner }) { item in
            editing = (owner, item)
        }
    }
}

/// One place's signatures on the Signatures page: its rows, Add, what replies use, and for an
/// inbox whether it falls back on shared ones.
private struct SignatureOwnerSection: View {
    @Bindable var model: MailModel
    let owner: SignatureOwner
    /// Everywhere else a signature can be copied to.
    let others: [SignatureOwner]
    let edit: (SignatureEditing) -> Void

    private var set: any SignatureSet { model.signatureSet(of: owner) }

    var body: some View {
        Section {
            ForEach([set.defaultSignature ?? NamedSignature(name: NamedSignature.defaultName, text: "")] + (set.moreSignatures ?? [])) { signature in
                SignatureRow(signature: signature, copyTargets: others.map { ($0, model.signatureOwnerName($0)) }) {
                    edit(SignatureEditing(original: signature.name, signature: signature))
                } remove: {
                    model.changeSignatures(of: owner) { $0.removeSignature(named: signature.name) }
                } copy: { target, asDefault in
                    model.copySignature(signature, from: owner, to: target, asDefault: asDefault)
                }
            }
            Button(String(localized: "Add a Signature…", table: "Settings")) {
                edit(SignatureEditing(original: nil, signature: set.newSignature()))
            }
            Picker(String(localized: "For replies and forwards", table: "Settings"), selection: Binding(
                get: { set.replySignature ?? NamedSignature.defaultName },
                set: { value in model.changeSignatures(of: owner) { $0.replySignature = value == NamedSignature.defaultName ? nil : value } }
            )) {
                Text("Default", tableName: "Settings").tag(NamedSignature.defaultName)
                ForEach(set.moreSignatures ?? []) { Text(verbatim: $0.name).tag($0.name) }
                Text("None", tableName: "Settings").tag("")
            }
            if case .account(let id) = owner, let account = model.account(id) {
                sharedRow(account)
            } else {
                Text(verbatim: footer).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            header
        }
    }

    private var footer: String {
        switch owner {
        case .all: String(localized: "Inboxes without signatures of their own use these.", table: "Settings")
        case .workspace: String(localized: "Inboxes in this workspace without signatures of their own use these in place of the ones for all inboxes.", table: "Settings")
        case .account: ""
        }
    }

    /// Whether an inbox falls back on shared signatures, and which ones it's using now.
    @ViewBuilder
    private func sharedRow(_ account: MailAccount) -> some View {
        Toggle(isOn: Binding(
            get: { account.usesSharedSignatures != false },
            set: { value in model.changeSignatures(of: .account(account.id)) { set in
                guard var mailbox = set as? MailAccount else { return }
                mailbox.usesSharedSignatures = value ? nil : false
                set = mailbox
            } }
        )) {
            Text("Use shared signatures when it has none", tableName: "Settings")
            if let inherited = account.inheritedSignatures {
                Text("Now using the signatures from \(inherited.title).", tableName: "Settings").font(TypeScale.label).foregroundStyle(Ink.tertiary)
            } else if account.usesSharedSignatures != false, let shared = account.sharedSignatures.value {
                Text("Its own come first. Those from \(shared.title) are in the signature menu while writing.", tableName: "Settings")
                    .font(TypeScale.label).foregroundStyle(Ink.tertiary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            switch owner {
            case .all:
                Image(systemName: "tray.2.fill").font(.system(size: Look.scaled(11), weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(SettingsPage.mailboxes.tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            case .workspace(let id):
                Image(systemName: "square.stack.fill").font(.system(size: Look.scaled(11), weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Palette.account(model.workspaces.first { $0.id == id }?.colorIndex ?? 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            case .account(let id):
                if let account = model.account(id) { AccountMark(account, size: 20) }
            }
            Text(verbatim: model.signatureOwnerName(owner)).font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
            switch owner {
            case .all: Text("Shared", tableName: "Settings").font(TypeScale.row).foregroundStyle(Ink.tertiary)
            case .workspace: Text("Workspace", tableName: "Settings").font(TypeScale.row).foregroundStyle(Ink.tertiary)
            case .account(let id):
                Text(verbatim: model.account(id)?.address.address ?? "").font(TypeScale.row).foregroundStyle(Ink.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .textCase(nil)
        .padding(.top, owner == .all ? Space.m : 0)
    }
}

/// One signature in Settings: its name, how it starts, Edit, copying it to another inbox, and
/// removing it.
struct SignatureRow: View {
    let signature: NamedSignature
    /// Where it can be copied to, with their names.
    var copyTargets: [(owner: SignatureOwner, name: String)] = []
    let edit: () -> Void
    let remove: () -> Void
    var copy: (SignatureOwner, Bool) -> Void = { _, _ in }

    private var isDefault: Bool { signature.name == NamedSignature.defaultName }
    private var isEmpty: Bool { signature.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var pictures: Int { signature.text.filter { $0 == NamedSignature.pictureCharacter }.count }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isDefault ? String(localized: "Default", table: "Settings") : signature.name).font(TypeScale.rowStrong)
                if isEmpty {
                    Text("None", tableName: "Settings").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                } else {
                    Text(verbatim: signature.plainText).font(TypeScale.label).foregroundStyle(Ink.secondary).lineLimit(3)
                    if signature.isFormatted {
                        Label(pictures == 0 ? String(localized: "Formatted", table: "Settings")
                                : pictures == 1 ? String(localized: "Formatted, with a picture", table: "Settings")
                                : String(localized: "Formatted, with \(pictures) pictures", table: "Settings"),
                              systemImage: pictures == 0 ? "textformat" : "photo")
                            .font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                    }
                }
            }
            Spacer()
            Button(isEmpty ? String(localized: "Write…", table: "Settings") : String(localized: "Edit…", table: "Settings"), action: edit)
            if !isEmpty, !copyTargets.isEmpty {
                Menu {
                    ForEach(copyTargets, id: \.owner) { target in
                        Menu(target.name) {
                            Button(String(localized: "As Its Default", table: "Settings")) { copy(target.owner, true) }
                            Button(String(localized: "As Another Signature", table: "Settings")) { copy(target.owner, false) }
                        }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuIndicatorHidden()
                .fixedSize()
                .help(Text("Copy to…", tableName: "Settings"))
                .accessibilityLabel(Text("Copy to…", tableName: "Settings"))
            }
            if !isDefault || !isEmpty {
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove", tableName: "Settings"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }
}

/// Writing a signature. On the Mac it's the message editor with all its formatting, links and
/// pictures; on iPhone and iPad the words, with a formatted one shown as it's sent.
struct SignatureSheet: View {
    let original: NamedSignature
    let isDefault: Bool
    /// Names the other signatures have.
    let takenNames: Set<String>
    let save: (NamedSignature) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var html: String?
    @State private var madePlain = false
    #if canImport(AppKit)
    @State private var controller: RichTextController = {
        let controller = RichTextController()
        controller.widestPicture = SignatureText.widestPicture
        controller.keepsPicturesSmall = true
        return controller
    }()
    @State private var initial: NSAttributedString?
    @State private var importing = false
    @State private var htmlSource = ""
    #endif

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameIsFree: Bool { isDefault || (!trimmedName.isEmpty && !takenNames.contains(trimmedName)) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(isDefault ? Text("Default Signature", tableName: "Settings") : Text("Signature", tableName: "Settings"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", table: "Settings")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Save", table: "Settings")) {
                            save(finished())
                            dismiss()
                        }
                        .disabled(!nameIsFree)
                    }
                }
        }
        .tint(Ink.primary)
        .onAppear {
            name = original.name
            #if canImport(AppKit)
            if initial == nil {
                let shown = SignatureText.attributed(original)
                text = shown.string
                initial = shown
            }
            #else
            text = original.plainText
            #endif
        }
    }

    private var nameField: some View {
        TextField(String(localized: "Name", table: "Settings"), text: $name, prompt: Text("Casual, Formal, Short…", tableName: "Settings"))
    }

    #if canImport(AppKit)
    private var content: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if !isDefault {
                nameField.textFieldStyle(.roundedBorder)
                if !nameIsFree, !trimmedName.isEmpty {
                    Text("Another signature has this name.", tableName: "Settings").font(TypeScale.label).foregroundStyle(Status.danger)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                FormattingBar(controller: controller)
            }
            if let initial {
                RichTextEditor(text: $text, html: $html, controller: controller, initial: initial)
                    .frame(minHeight: 180)
                    .padding(Space.s)
                    .background(Fill.one, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack {
                Text("Add a logo or photo with the picture button. Pictures go along with the mail, so nobody has to load them.", tableName: "Settings")
                    .font(TypeScale.label).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Menu(String(localized: "Picture Size", table: "Settings")) {
                    Button(String(localized: "Small", table: "Settings")) { controller.resizePictures(to: 80) }
                    Button(String(localized: "Medium", table: "Settings")) { controller.resizePictures(to: 160) }
                    Button(String(localized: "Large", table: "Settings")) { controller.resizePictures(to: SignatureText.widestPicture) }
                }
                .fixedSize()
                .help(Text("Picture size (the selected pictures, or all of them)", tableName: "Settings"))
                Button(String(localized: "Import HTML…", table: "Settings")) { importing = true }
            }
        }
        .padding(Space.l)
        .frame(width: 640, height: 460)
        .sheet(isPresented: $importing) { importSheet }
    }

    /// HTML from somewhere else, read into the editor to change from there.
    private var importSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Paste a signature's HTML. It replaces what's in the editor.", tableName: "Settings")
                    .font(TypeScale.label).foregroundStyle(Ink.secondary)
                TextEditor(text: $htmlSource)
                    .font(TypeScale.label.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Fill.one, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(Space.l)
            .navigationTitle(String(localized: "Import HTML", table: "Settings"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", table: "Settings")) { importing = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Import", table: "Settings")) {
                        if let read = SignatureText.fromHTML(htmlSource), let view = controller.textView, let storage = view.textStorage {
                            storage.setAttributedString(read)
                            view.didChangeText()
                        }
                        htmlSource = ""
                        importing = false
                    }
                    .disabled(htmlSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 480, height: 360)
    }

    private func finished() -> NamedSignature {
        let finalName = isDefault ? NamedSignature.defaultName : trimmedName
        guard let written = controller.textView?.attributedString() else { return NamedSignature(name: finalName, text: text) }
        return SignatureText.signature(named: finalName, from: written)
    }
    #else
    private var content: some View {
        Form {
            if !isDefault {
                Section { nameField } footer: {
                    if !nameIsFree, !trimmedName.isEmpty { Text("Another signature has this name.", tableName: "Settings") }
                }
            }
            if original.isFormatted, !madePlain, let preview = original.previewHTML {
                Section {
                    HTMLMessageView(html: HTMLSanitizer.sanitize(preview), allowsRemote: true).frame(minHeight: 80)
                    Button(String(localized: "Make It Plain to Edit Here", table: "Settings")) { madePlain = true }
                } footer: {
                    Text("This signature has formatting or pictures. Change it in Margin on a Mac, or make it plain to change the words here.", tableName: "Settings")
                }
            } else {
                Section {
                    TextEditor(text: $text).frame(minHeight: 140)
                }
            }
        }
    }

    private func finished() -> NamedSignature {
        let finalName = isDefault ? NamedSignature.defaultName : trimmedName
        if original.isFormatted, !madePlain {
            var kept = original
            kept.name = finalName
            return kept
        }
        return NamedSignature(name: finalName, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    #endif
}

/// A send-as address's signature, in a popover from its row: the mailbox's, one of its
/// signatures, none, or words of its own.
struct AliasSignatureButton: View {
    /// Its own words; empty when it has none.
    @Binding var signature: String
    /// The mailbox signature it uses by name, "" for none, nil when it doesn't pick one.
    @Binding var choice: String?
    let names: [String]
    let address: String
    @State private var isOpen = false
    @State private var writesOwn = false

    private enum Pick: Hashable { case mailbox, named(String), none, own }

    private var pick: Binding<Pick> {
        Binding(
            get: {
                if let choice { return choice.isEmpty ? .none : .named(choice) }
                return writesOwn || !signature.isEmpty ? .own : .mailbox
            },
            set: { value in
                writesOwn = value == .own
                switch value {
                case .mailbox: choice = nil; signature = ""
                case .named(let name): choice = name
                case .none: choice = ""
                case .own: choice = nil
                }
            }
        )
    }

    private var isSet: Bool { choice != nil || !signature.isEmpty }

    var body: some View {
        Button { isOpen = true } label: {
            Image(systemName: isSet ? "signature.fill" : "signature")
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSet ? Ink.primary : Ink.tertiary)
        .help(Text("Signature for \(address)", tableName: "Settings"))
        .popover(isPresented: $isOpen) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Signature for \(address)", tableName: "Settings").font(TypeScale.rowStrong)
                Picker(String(localized: "Signature", table: "Settings"), selection: pick) {
                    Text("The mailbox's", tableName: "Settings").tag(Pick.mailbox)
                    ForEach(names, id: \.self) { name in
                        Text(name == NamedSignature.defaultName ? String(localized: "Default", table: "Settings") : name).tag(Pick.named(name))
                    }
                    Text("None", tableName: "Settings").tag(Pick.none)
                    Text("Its own words", tableName: "Settings").tag(Pick.own)
                }
                .labelsHidden()
                if pick.wrappedValue == .own {
                    TextEditor(text: $signature)
                        .font(.system(size: Look.scaled(13)))
                        .frame(width: 320, height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Line.edge))
                }
                Text("Mail sent as this address uses it. The mailbox's follows what new mail and replies use.", tableName: "Settings")
                    .font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.m)
            .frame(width: 352)
        }
    }
}

#if canImport(AppKit)
import AppKit

/// A formatted signature with a picture, open in its editor, for screenshots.
public struct SignatureSheetSnapshot: View {
    public init() {}

    public var body: some View {
        SignatureSheet(original: Self.sample, isDefault: false, takenNames: []) { _ in }
    }

    /// A formatted signature for all inboxes, for a picture of the Signatures page.
    public static func fillSharedSignatures(_ model: MailModel) {
        var shared = sample
        shared.name = NamedSignature.defaultName
        model.changeSignatures(of: .all) { $0.setSignature(shared) }
    }

    static var sample: NamedSignature {
        let logo = NSImage(size: NSSize(width: 240, height: 64), flipped: false) { rect in
            NSColor(srgbRed: 0.10, green: 0.35, blue: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            let words = NSAttributedString(string: "Northwind", attributes: [
                .font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.white])
            words.draw(at: NSPoint(x: 28, y: 14))
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = logo
        attachment.bounds = CGRect(x: 0, y: 0, width: 120, height: 32)
        let text = NSMutableAttributedString(attachment: attachment)
        let normal = SignatureText.normal()
        text.append(NSAttributedString(string: "\n", attributes: normal))
        text.append(NSAttributedString(string: "Alex Rivera", attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: "\nDesign lead · Northwind\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: FormattingBar.colors[0].value]))
        text.append(NSAttributedString(string: "northwind.example", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .link: URL(string: "https://northwind.example")!]))
        return SignatureText.signature(named: "Work", from: text)
    }
}
#endif
