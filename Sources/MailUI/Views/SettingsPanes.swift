import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// Every Settings page is a grouped form, the same on the Mac, iPhone and iPad: rows with the
// label on the left and the control on the right, explanations under each group, system buttons.

/// Mailboxes: each account, with Edit… and Remove, and Add Mailbox….
struct MailboxesSettings: View {
    @Bindable var model: MailModel
    @Binding var editing: UUID?
    @State private var removing: MailAccount?
    @State private var signingIn: MailAccount?

    var body: some View {
        Form {
            SettingsHeader(.mailboxes)
            Section {
                if model.accounts.isEmpty {
                    SettingsEmptyRow("No mailboxes yet.")
                }
                ForEach(model.accounts) { account in
                    HStack(spacing: Space.m) {
                        AccountMark(account, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.label)
                            Text(account.serverDescription).font(TypeScale.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editing = account.id }
                        Menu {
                            Button("Move Up") { withAnimation(Motion.quick) { model.moveAccount(account.id, by: -1) } }
                                .disabled(!model.canMoveAccount(account.id, by: -1))
                            Button("Move Down") { withAnimation(Motion.quick) { model.moveAccount(account.id, by: 1) } }
                                .disabled(!model.canMoveAccount(account.id, by: 1))
                            if model.canSignInAgain(account) {
                                Divider()
                                Button("Sign In Again…") { signingIn = account }
                            }
                            Divider()
                            Button("Remove", role: .destructive) { removing = account }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuIndicatorHidden()
                        .fixedSize()
                    }
                }
                .onMove { model.moveAccounts(from: $0, to: $1) }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if model.accounts.count > 1 {
                        Text("Drag to change the order, here or in the account column.")
                    }
                    if model.accounts.contains(where: model.canSignInAgain) {
                        Text("If a mailbox stops signing in, choose Sign In Again from its menu. Your mail and settings stay as they are.")
                    }
                }
            }
            Section {
                Button("Add Mailbox…") { model.isAddingAccount = true }
            }
        }
        .formStyle(.grouped)
        .signsInAgain(model: model, account: $signingIn, confirms: true)
        .confirmationDialog(Text("Remove this mailbox from Margin?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { account in
            Button("Remove", role: .destructive) { model.remove(account.id) }
        } message: { _ in
            Text("Mail stays on the server. You can add the mailbox again later.")
        }
    }
}

/// How much older mail this device keeps, what that takes, and a way to take it out again.
struct SavedMailSection: View {
    @Bindable var model: MailModel
    @State private var isClearing = false

    var body: some View {
        Section {
            Picker("Keep on this device", selection: $model.keepMail) {
                ForEach(KeepMail.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            Picker(selection: $model.keepText) {
                ForEach(KeepText.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                SettingLabel("Open recent mail instantly", detail: "Saves the text of mail from this stretch ahead of time.")
            }
            HStack {
                // Room kept for both lines, so nothing moves when downloading starts or stops.
                ZStack(alignment: .leading) {
                    Text("Downloading older mail…").hidden()
                    if let usage = model.savedMailUsage {
                        let size = ByteCountFormatter.string(fromByteCount: Int64(usage.bytes), countStyle: .file)
                        Text(model.isDownloadingOlder ? String(localized: "Downloading older mail…")
                                                      : String(localized: "\(usage.messages) messages, \(size) on disk"))
                    }
                }
                .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Downloaded Mail") {
                    isClearing = true
                    Task {
                        await model.clearDownloadedMail()
                        isClearing = false
                    }
                }
                .disabled(isClearing)
            }
        } header: {
            Text("On this device")
        } footer: {
            Text("Older mail's senders, subjects and previews are downloaded in the background, so it can be searched and scrolled without a connection. The text of recent mail is saved too, without its files, so opening it doesn't wait; older texts and all files come when a mail is opened. On iPhone and iPad only on Wi-Fi, and while charging or above 20% battery.")
        }
        .task {
            while !Task.isCancelled {
                await model.refreshSavedMailUsage()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// Appearance: theme, accent, size, the app icon, colours and accessibility.
struct AppearanceSettings: View {
    @Bindable var model: MailModel

    static func caption(_ appearance: AppAppearance) -> String? {
        switch appearance {
        #if os(macOS)
        case .system: String(localized: "Light or dark, like the Mac.")
        #else
        case .system: String(localized: "Light or dark, like the system.")
        #endif
        case .light: String(localized: "Soft gray sidebar, white mail.")
        case .dark: String(localized: "Dark gray, easy at night.")
        case .deepDark: String(localized: "True black, for dark rooms.")
        case .white: String(localized: "All white, no gray.")
        case .developer: String(localized: "Dark blue-black with green.")
        }
    }

    static func caption(_ layout: ListLayout) -> String? {
        switch layout {
        case .panels: String(localized: "The list and the open mail next to each other.")
        case .wide: String(localized: "A full-width list; mail opens over it.")
        case .spark: String(localized: "Inbox, unread and labels as tabs on top.")
        case .minimal: String(localized: "A calm page of sections, no sidebar.")
        }
    }

    var body: some View {
        Form {
            SettingsHeader(.appearance)
            Section {
                ChoiceTiles(options: AppAppearance.allCases, selection: $model.appearance,
                            title: \.title, caption: Self.caption) { ThemePreview(appearance: $0) }
                LabeledContent {
                    HStack(spacing: 10) {
                        ForEach(0..<8, id: \.self) { index in
                            Button { model.accentIndex = index } label: {
                                Circle().fill(Palette.account(index)).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Ink.primary, lineWidth: 2).padding(-3).opacity(model.accentIndex == index ? 1 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Accent \(index + 1)")
                        }
                    }
                } label: { SettingLabel("Accent", detail: "Unread dots, selections and badges.") }
            } header: {
                Text("Theme")
            }
            Section {
                ChoiceTiles(options: Density.allCases, selection: $model.density,
                            title: { $0 == .roomy ? String(localized: "Roomy") : String(localized: "Compact") },
                            caption: { $0 == .roomy ? String(localized: "Bigger text and more room.") : String(localized: "Fits more on screen.") }) {
                    DensityPreview(density: $0)
                }
            } header: {
                Text("Size")
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: Space.s)], spacing: Space.m) {
                    ForEach(AppIconChoice.allCases) { choice in
                        Button { model.appIcon = choice } label: {
                            VStack(spacing: 6) {
                                AppIconPreview(choice: choice, dark: model.appIconDark, size: 48)
                                    .padding(3)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Ink.primary, lineWidth: 2)
                                            .opacity(model.appIcon == choice ? 1 : 0)
                                    )
                                Text(verbatim: choice.title)
                                    .font(TypeScale.caption)
                                    .foregroundStyle(model.appIcon == choice ? Ink.primary : Ink.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: choice.title))
                        .accessibilityAddTraits(model.appIcon == choice ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
                Toggle("Dark", isOn: $model.appIconDark)
                    .disabled(!model.appIcon.hasDarkVersion)
            } header: {
                Text("App icon")
            } footer: {
                #if os(macOS)
                Text("The Dock shows the new icon while Margin is open.")
                #endif
            }
            Section {
                ChoiceTiles(options: [false, true], selection: $model.colorBlindSafe,
                            title: { $0 ? String(localized: "Color-blind safe") : String(localized: "Standard") }) {
                    PalettePreview(colorBlindSafe: $0)
                }
            } header: {
                Text("Colors")
            } footer: {
                Text("A palette that stays clear with red–green and blue–yellow color blindness. Mailboxes also always show their letter, and unread mail is bold as well as marked.")
            }
            Section {
                Toggle(isOn: $model.increaseContrast) { SettingLabel("Increase contrast", detail: "Darker text and clearer lines.") }
                Toggle(isOn: $model.underlineLinks) { SettingLabel("Underline links in mail", detail: "So links stand out without relying on color.") }
                Toggle(isOn: $model.reduceMotion) { SettingLabel("Reduce motion", detail: "Things appear at once instead of sliding.") }
            } header: {
                Text("Accessibility")
            } footer: {
                #if os(macOS)
                Text("Margin also follows these settings from the Mac's Accessibility settings.")
                #else
                Text("Margin also follows these settings from the system's Accessibility settings.")
                #endif
            }
        }
        .formStyle(.grouped)
    }
}

/// Layout: how the window is arranged, how much a row shows, and the window's own parts on the Mac.
struct LayoutSettings: View {
    @Bindable var model: MailModel

    private var layouts: [ListLayout] {
        #if os(macOS)
        ListLayout.allCases
        #else
        // On iPhone a conversation always opens over the list, so Wide is the same as Side by side.
        [.panels, .spark, .minimal]
        #endif
    }

    var body: some View {
        Form {
            SettingsHeader(.layout)
            Section {
                ChoiceTiles(options: layouts, selection: $model.layout, title: \.title, caption: AppearanceSettings.caption) { LayoutPreview(layout: $0) }
            } header: {
                Text("Layout")
            }
            Section {
                ChoiceTiles(options: [false, true], selection: $model.compactRows,
                            title: { $0 ? String(localized: "One line") : String(localized: "Three lines") },
                            caption: { $0 ? String(localized: "Fits the most mail on screen.") : String(localized: "Sender, subject and a preview.") }) {
                    RowsPreview(compact: $0)
                }
            } header: {
                Text("Rows")
            }
            #if os(macOS)
            Section {
                ChoiceTiles(options: [false, true], selection: $model.insetPanel,
                            title: { $0 ? String(localized: "Inset panel") : String(localized: "Edge to edge") },
                            caption: { $0 ? String(localized: "Mail sits in a rounded panel.") : String(localized: "Mail runs to the window's edges.") }) {
                    WindowStylePreview(inset: $0)
                }
                Toggle(isOn: Binding(get: { model.showsAccountRail }, set: { model.showsAccountRail = $0 })) {
                    SettingLabel("Account column",
                                 detail: "The column of mailboxes at the far left. Off, All inboxes, Home, the Calendar and your mailboxes move to the top of the sidebar.")
                }
                Toggle(isOn: $model.buttonNames) {
                    SettingLabel("Show button names",
                                 detail: "Names beside the icons above a conversation, when they fit. Off shows icons only; pointing at one shows its name and shortcut.")
                }
            } header: {
                Text("Window")
            }
            #endif
        }
        .formStyle(.grouped)
    }
}

/// Shortcuts and Swipes: change any single key or turn single keys off (on the Mac), and what a
/// swipe on a conversation does.
struct ShortcutSettings: View {
    @Bindable var model: MailModel

    var body: some View {
        Form {
            SettingsHeader(.shortcuts)
            #if os(macOS)
            keyboard
            #endif
            SwipeSettings(model: model)
            #if os(macOS)
            keyList
            #endif
        }
        .formStyle(.grouped)
    }

    #if os(macOS)
    private var commands: [MailCommand] {
        MailCommand.all(for: model).filter { $0.keys.count == 1 || model.keyOverrides[$0.id] != nil }
    }

    @ViewBuilder
    private var keyboard: some View {
        Section {
            Toggle(isOn: $model.singleKeyShortcuts) { SettingLabel("Single-key shortcuts (E, R, J, K…)") }
            LabeledContent {
                Menu("Choose…") {
                    ForEach(ShortcutPreset.allCases) { preset in
                        Button(preset.title) {
                            model.keyOverrides = preset.overrides
                            model.singleKeyShortcuts = preset.usesSingleKeys
                        }
                    }
                }
                .fixedSize()
            } label: { SettingLabel("Start from the keys of") }
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Turn this off if you'd rather nothing happens when you type outside a text field. ⌘ shortcuts and ⌘K keep working.")
        }
    }

    @ViewBuilder
    private var keyList: some View {
        let commands = commands
        Section {
            ForEach(commands) { command in
                ShortcutRow(model: model, command: command, clashes: clashes(command, in: commands))
            }
        } header: {
            Text("Single keys")
        }
        .disabled(!model.singleKeyShortcuts)
        Section {
            Button("Restore the original keys") { model.keyOverrides = [:] }
        }
    }

    private func clashes(_ command: MailCommand, in commands: [MailCommand]) -> Bool {
        guard let key = command.key(in: model)?.lowercased() else { return false }
        return commands.contains { $0.id != command.id && $0.key(in: model)?.lowercased() == key }
    }
    #endif
}

#if os(macOS)
private struct ShortcutRow: View {
    @Bindable var model: MailModel
    let command: MailCommand
    let clashes: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.s) {
                if clashes { Text("Used twice").font(TypeScale.caption).foregroundStyle(Status.danger) }
                TextField("", text: Binding(
                    get: { command.key(in: model) ?? "" },
                    set: { value in
                        let key = String(value.suffix(1)).uppercased()
                        var overrides = model.keyOverrides
                        overrides[command.id] = key == (command.keys.first ?? "") ? nil : key
                        model.keyOverrides = overrides
                    }
                ))
                .labelsHidden()
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 36)
            }
        } label: {
            Text(command.title)
        }
    }
}

#endif

/// Templates: reusable text with fill-ins.
struct TemplateSettings: View {
    @Bindable var model: MailModel
    @State private var editing: MailTemplate?

    var body: some View {
        Form {
            SettingsHeader(.templates)
            Section {
                if model.templates.isEmpty {
                    SettingsEmptyRow("No templates yet.")
                }
                ForEach(model.templates) { template in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                            Text(template.body.replacingOccurrences(of: "\n", with: " ")).font(TypeScale.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editing = template }
                        Menu {
                            Button("Delete", role: .destructive) { model.deleteTemplate(template.id) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuIndicatorHidden()
                        .fixedSize()
                    }
                }
            } footer: {
                Text("Fill-ins: {first_name}, {name}, {my_name}, {my_first_name}, {date}")
            }
            Section {
                Button("New template") { editing = MailTemplate(name: "", body: "") }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { template in
            TemplateEditor(template: template) { model.updateTemplate($0) }
        }
    }
}

private struct TemplateEditor: View {
    @State var template: MailTemplate
    let onSave: (MailTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $template.name)
                    TextField("Subject (optional)", text: $template.subject)
                }
                Section {
                    TextEditor(text: $template.body)
                        .font(TypeScale.body)
                        .frame(minHeight: 160)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(template); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], Space.l)
        }
        .frame(minWidth: 460, minHeight: 380)
    }
}

/// Sorting: the groups mail goes into, and when it's sorted.
struct SortingSettings: View {
    let model: MailModel
    @State private var groups: [EmailGroup] = []

    var body: some View {
        Form {
            SettingsHeader(.sorting)
            Section {
                Toggle(isOn: Binding(get: { model.sortsNewMail }, set: { model.sortsNewMail = $0 })) {
                    SettingLabel("Sort new mail as it arrives")
                }
                LabeledContent {
                    if model.isSorting, let progress = model.sortingProgress {
                        Button("Stop (\(progress.done) of \(progress.total))") { model.stopSorting() }
                    } else {
                        Button("Sort Now") { model.sortNow() }
                    }
                } label: {
                    SettingLabel("Sort the inbox", detail: "Goes through the mail that's already there.")
                }
                LabeledContent {
                    Button("Open") { model.settingsPageRequest = SettingsPage.assistant.rawValue }
                } label: {
                    SettingLabel(verbatim: String(localized: "Sorting with AI"),
                                 detail: !model.usesAI ? String(localized: "Off, because AI is off. Clear cases are still sorted.")
                                    : model.sortAssistant.map { String(localized: "On, by \(AssistantRow.label($0)).") }
                                        ?? String(localized: "Off, because no assistant is set up. Clear cases are still sorted."))
                }
            } footer: {
                Text("Margin sorts the inbox into these groups, each a label, and Home shows a tab per group. With the assistant on it reads each conversation; without it, only clear cases are sorted (bills, receipts, orders, travel, newsletters).")
            }
            Section {
                ForEach($groups) { $group in
                    HStack(alignment: .top, spacing: Space.s) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name", text: $group.name).textFieldStyle(.plain)
                            TextField("What belongs here", text: $group.detail, axis: .vertical)
                                .textFieldStyle(.plain).font(TypeScale.caption).foregroundStyle(.secondary).lineLimit(1...3)
                        }
                        .labelsHidden()
                        Spacer()
                        Button { move(group.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .accessibilityLabel("Move up").disabled(groups.first?.id == group.id)
                        Button { move(group.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel("Move down").disabled(groups.last?.id == group.id)
                        Button { groups.removeAll { $0.id == group.id } } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove")
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Groups")
            }
            Section {
                Button("Add Group") { groups.append(EmailGroup(name: String(localized: "New group"), detail: "")) }
                Button("Start Over") { groups = EmailGroup.starters }
            }
        }
        .formStyle(.grouped)
        .onAppear { groups = model.emailGroups }
        .onChange(of: groups) { _, new in
            model.emailGroups = new.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    private func move(_ id: EmailGroup.ID, by offset: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups.indices.contains(index + offset) else { return }
        groups.swapAt(index, index + offset)
    }
}

/// Backup and Devices, as three pages: syncing and moving to another device; a file now,
/// automatic backups and the recovery key; restoring.
struct BackupSettings: View {
    /// The three pages this is shown as: syncing and other devices, making backups, restoring.
    enum Part { case devices, backups, restore }

    let model: MailModel
    var part: Part = .devices
    @State private var password = ""
    @State private var includeSecrets = false
    @State private var status: String?
    @State private var pendingRestore: Data?
    @State private var restorePassword = ""
    @State private var parts: RestoreParts = .all
    @State private var autoPassword = ""
    @State private var link: (file: URL, code: String)?
    @State private var shownRecoveryKey: String?
    @State private var exported: URL?
    @State private var choosingRestore = false

    var body: some View {
        Form {
            switch part {
            case .devices:
                SettingsHeader(.backup)
            Section {
                Toggle(isOn: Binding(get: { model.syncsWithICloud }, set: { model.syncsWithICloud = $0 })) {
                    SettingLabel("Sync with iCloud",
                                 detail: "Mailboxes, passwords, settings, templates and workspaces on every Mac, iPhone and iPad signed in to your Apple Account.")
                }
                if model.syncsWithICloud {
                    if let problem = model.syncProblem {
                        Text(verbatim: problem).font(TypeScale.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent {
                            Button("Sync Now") { Task { await model.syncNow() } }
                        } label: {
                            if let last = model.lastSync {
                                Text("Synced \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                            } else {
                                Text("Not synced yet").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Passwords go through iCloud Keychain, encrypted end to end by Apple. The rest is kept in Margin's folder in your iCloud Drive. No server of ours is involved.")
            }
                linkDevice
                statusLine
            case .backups:
                SettingsHeader(.backupFiles)
            Section {
                LabeledContent {
                    RevealableField(title: "Password", text: $password, prompt: Text("Optional")).frame(maxWidth: 220)
                } label: { SettingLabel("Password") }
                Toggle(isOn: $includeSecrets) { SettingLabel("Include mail passwords and API keys") }
                    .disabled(password.isEmpty)
                HStack {
                    Button("Export Backup…") { export() }
                    if let exported {
                        // iPhone and iPad: save it to Files, AirDrop it, or send it anywhere.
                        ShareLink(item: exported) { Label("Save or Send…", systemImage: "square.and.arrow.up") }
                    }
                }
            } header: {
                Text("Make a backup")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(password.isEmpty
                         ? "Without a password the file isn't encrypted, so passwords and keys are left out."
                         : "The file is encrypted with this password. Without it, the backup can't be opened.")
                    Text("A backup holds your mailboxes, settings, labels, snoozes, scheduled mail, templates and signatures. Mail itself stays on your mail servers.")
                }
            }

                automatic
                recovery
                statusLine
            case .restore:
                SettingsHeader(.restore)
            Section {
                part("Mailboxes and signatures", .mailboxes)
                part("Settings", .settings)
                part("Labels and snoozes", .labelsAndSnoozes)
                part("Templates", .templates)
                part("Scheduled mail", .scheduled)
                part("Writing style and Ask chats", .writingAndChats)
                HStack {
                    Button("Restore from Backup…") { choosingRestore = true }
                    if model.canUndoRestore {
                        Button("Undo Restore") { model.undoRestore(); status = nil }
                    }
                }
            } header: {
                Text("When restoring, bring back")
            } footer: {
                // Kept in place, so the page doesn't jump when a message appears.
                Text(verbatim: status ?? " ")
            }

            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingRestore, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { status = String(localized: "Couldn't read that file."); return }
            if BackupBox.isEncrypted(data) { pendingRestore = data } else { restore(data, password: nil) }
        }
        .alert("This backup has a password", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            SecureField("Password", text: $restorePassword)
            Button("Cancel", role: .cancel) { pendingRestore = nil }
            Button("Restore") {
                if let data = pendingRestore { restore(data, password: restorePassword) }
                pendingRestore = nil
                restorePassword = ""
            }
        }
    }

    /// What the last action said, in room that's always there so nothing moves when it appears.
    private var statusLine: some View {
        Section {
        } footer: {
            Text(verbatim: status ?? " ")
        }
    }

    /// Margin saves a backup by itself, daily or weekly, keeping the newest 30.
    private var automatic: some View {
        Section {
            if let problem = model.automaticBackupProblem {
                Label(String(localized: "The last automatic backup failed: \(problem)"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Status.danger)
            }
            Picker(selection: Binding(get: { model.backupSchedule }, set: { model.backupSchedule = $0 })) {
                ForEach(BackupSchedule.allCases) { Text($0.title).tag($0) }
            } label: { SettingLabel("Back up") }
            if model.backupSchedule != .off {
                #if canImport(AppKit)
                LabeledContent {
                    HStack {
                        Button("Choose Folder…") { chooseFolder() }
                        if MailModel.iCloudDriveFolder != nil {
                            Button("Use iCloud Drive…") { chooseFolder(in: MailModel.iCloudDriveFolder) }
                        }
                    }
                } label: {
                    Text(verbatim: model.backupFolder.path(percentEncoded: false)).lineLimit(1).truncationMode(.head)
                }
                #endif
                LabeledContent {
                    RevealableField(title: "Password", text: $autoPassword, prompt: Text(model.hasAutomaticBackupPassword ? "Saved in Keychain" : "Optional"))
                        .frame(maxWidth: 200)
                    Button("Save Password") {
                        model.setAutomaticBackupPassword(autoPassword)
                        autoPassword = ""
                    }
                    .disabled(autoPassword.isEmpty)
                } label: { SettingLabel("Password") }
                LabeledContent {
                    Button("Back Up Now") {
                        do { try model.writeAutomaticBackup(); status = String(localized: "Backed up.") } catch { status = error.localizedDescription }
                    }
                } label: {
                    if let last = model.lastAutomaticBackup {
                        Text("Last backup \(last.formatted(.relative(presentation: .named)))")
                    }
                }
            }
        } header: {
            Text("Automatic backups")
        } footer: {
            if model.backupSchedule != .off {
                Text(model.hasAutomaticBackupPassword
                     ? "Backups are encrypted and include mail passwords, so a restore needs no signing in."
                     : "Without a password, passwords and keys are left out of automatic backups.")
            }
        }
    }

    /// A second way into password-protected backups, for when the password is forgotten.
    private var recovery: some View {
        Section {
            if let key = shownRecoveryKey {
                LabeledContent {
                    Button("Copy") { MailModel.putOnPasteboard(key) }
                } label: {
                    Text(verbatim: key).monospaced().textSelection(.enabled)
                }
            }
            if model.backupRecoveryKey == nil {
                Button("Make a Recovery Key") { shownRecoveryKey = model.makeBackupRecoveryKey() }
            } else {
                HStack {
                    Button(shownRecoveryKey == nil ? "Show Recovery Key" : "Hide") {
                        shownRecoveryKey = shownRecoveryKey == nil ? model.backupRecoveryKey : nil
                    }
                    Button("Remove", role: .destructive) { model.removeBackupRecoveryKey(); shownRecoveryKey = nil }
                }
            }
        } header: {
            Text("Recovery key")
        } footer: {
            Text("A recovery key also opens backups that have a password. Write it down or keep it in a password manager.")
        }
    }

    /// Everything, passwords included, to another Mac, iPhone or iPad in one file and a code.
    private var linkDevice: some View {
        Section {
            if let link {
                LabeledContent {
                    ShareLink(item: link.file) { Label("Send File…", systemImage: "square.and.arrow.up") }
                } label: {
                    HStack(spacing: Space.s) {
                        Text("Code")
                        Text(verbatim: link.code).monospaced().bold().textSelection(.enabled)
                    }
                }
            } else {
                Button("Link Another Device…") {
                    do { link = try model.makeDeviceLink() } catch { status = error.localizedDescription }
                }
            }
        } header: {
            Text("Link another device")
        } footer: {
            Text("Moves your mailboxes, passwords, settings, labels and templates to another Mac, iPhone or iPad. Send the file there (AirDrop works), open it, and type the code.")
        }
    }

    private func export() {
        do {
            let data = try model.makeBackup(password: password.isEmpty ? nil : password, includeSecrets: includeSecrets)
            let name = String(localized: "Margin Backup \(Date().formatted(.iso8601.year().month().day()))", comment: "Default backup file name, without extension") + ".marginbackup"
            #if canImport(AppKit)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            status = String(localized: "Saved \(url.lastPathComponent)")
            #else
            let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: name)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exported = url
            #endif
        } catch {
            status = error.localizedDescription
        }
    }

    private func part(_ title: LocalizedStringKey, _ part: RestoreParts) -> some View {
        Toggle(title, isOn: Binding(get: { parts.contains(part) }, set: { if $0 { parts.insert(part) } else { parts.remove(part) } }))
    }

    #if canImport(AppKit)
    private func chooseFolder(in start: URL? = nil) {
        let panel = NSOpenPanel()
        panel.directoryURL = start
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { model.setBackupFolder(url) }
    }
    #endif

    private func restore(_ data: Data, password: String?) {
        do {
            status = try model.restore(data, password: password, parts: parts)
        } catch {
            status = error.localizedDescription
        }
    }
}

/// About: Margin's icon, name and version; where to tell us when something breaks; who makes it.
struct AboutSettings: View {
    let model: MailModel
    @State private var showingWelcome = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AppIconPreview(choice: model.appIcon, dark: model.appIconDark, size: 84)
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                Text(verbatim: model.environment.appName)
                    .font(.system(size: Look.size(26), weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .padding(.top, 16)
                Text("Version \(Self.version)")
                    .font(TypeScale.label.monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
                #if os(macOS)
                if let updates = model.updates {
                    UpdateSettings(updates: updates)
                        .padding(.top, 20)
                }
                #endif
                TellUsCard()
                    .padding(.top, 36)
                Link(destination: URL(string: "https://relevate.app")!) {
                    HStack(spacing: 8) {
                        Text("Made by").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                        RelevateLogo()
                            .fill(Ink.secondary)
                            .aspectRatio(RelevateLogo.aspect, contentMode: .fit)
                            .frame(height: Look.gap(22))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Made by Relevate"))
                .padding(.top, 32)
                Button("Show Welcome") { showingWelcome = true }
                    .buttonStyle(.borderless)
                    .font(TypeScale.label)
                    .padding(.top, 10)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, 44)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingWelcome) { OnboardingView(model: model) }
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }
}

#if os(macOS)
/// On the Mac app downloaded from the website: check now, and whether Margin looks and installs
/// by itself. Sparkle keeps these settings; this copies them in when the page opens.
private struct UpdateSettings: View {
    let updates: any AppUpdates
    @State private var checks = true
    @State private var installs = false

    var body: some View {
        VStack(spacing: 12) {
            Button("Check for Updates…") { updates.checkForUpdates() }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Check for updates automatically", isOn: $checks)
                    .onChange(of: checks) { _, on in updates.checksAutomatically = on }
                Toggle("Download and install updates", isOn: $installs)
                    .onChange(of: installs) { _, on in updates.installsAutomatically = on }
                    .disabled(!checks)
            }
            .font(TypeScale.label)
        }
        .onAppear {
            checks = updates.checksAutomatically
            installs = updates.installsAutomatically
        }
    }
}
#endif

/// Nothing is tracked, so a problem is only known once someone says so: an ink card with the
/// X mark, that sentence, and the two accounts to tell, each a row you can click.
private struct TellUsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Text(verbatim: "𝕏")
                    .font(.system(size: Look.size(22), weight: .heavy))
                    .foregroundStyle(Ink.inverse)
                    .frame(width: 40, height: 40)
                    .background(Ink.inverse.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Something broken?")
                        .font(.system(size: Look.size(16), weight: .semibold))
                        .foregroundStyle(Ink.inverse)
                    Text("Because nothing is tracked, we won't know when something breaks until you tell us.")
                        .font(TypeScale.label)
                        .foregroundStyle(Ink.inverse.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            Rectangle().fill(Ink.inverse.opacity(0.1)).frame(height: 1)
            HandleRow(handle: "@kaanmol_", who: "Kaan, who makes Margin", url: "https://x.com/kaanmol_")
            Rectangle().fill(Ink.inverse.opacity(0.1)).frame(height: 1).padding(.leading, 18)
            HandleRow(handle: "@rlvtapp", who: "Relevate", url: "https://x.com/rlvtapp")
        }
        .background(Ink.primary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
    }
}

/// One account to write to: the handle, who it is, and an arrow that moves on hover.
private struct HandleRow: View {
    let handle: String
    let who: LocalizedStringKey
    let url: String
    @State private var isHovered = false

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: handle).font(.system(size: Look.size(14), weight: .semibold)).foregroundStyle(Ink.inverse)
                    Text(who).font(TypeScale.caption).foregroundStyle(Ink.inverse.opacity(0.6))
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: Look.size(12), weight: .bold))
                    .foregroundStyle(Ink.inverse.opacity(isHovered ? 1 : 0.6))
                    .offset(x: isHovered ? 2 : 0, y: isHovered ? -2 : 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(Ink.inverse.opacity(isHovered ? 0.06 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Motion.quick) { isHovered = hovering } }
        .tip(Text(verbatim: url))
    }
}

extension View {
    /// Hides the menu arrow on the Mac, where an icon-only menu would otherwise get one.
    @ViewBuilder
    func menuIndicatorHidden() -> some View {
        #if os(macOS)
        self.menuIndicator(.hidden).menuStyle(.borderlessButton)
        #else
        self
        #endif
    }
}
