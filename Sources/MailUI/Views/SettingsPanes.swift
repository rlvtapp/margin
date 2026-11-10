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
                            Text(account.serverDescription).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editing = account.id }
                        Menu {
                            Button("Remove", role: .destructive) { removing = account }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuIndicatorHidden()
                        .fixedSize()
                    }
                }
            }
            Section {
                Button("Add Mailbox…") { model.isAddingAccount = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(Text("Remove this mailbox from Margin?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { account in
            Button("Remove", role: .destructive) { model.remove(account.id) }
        } message: { _ in
            Text("Mail stays on the server. You can add the mailbox again later.")
        }
    }
}

/// Appearance: theme, accent, layout, rows, colours, accessibility; swipes on iPhone and iPad.
struct AppearanceSettings: View {
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
            SettingsHeader(.appearance)
            Section {
                Picker(selection: $model.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { SettingLabel("Appearance") }
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
                } label: { SettingLabel("Accent") }
                Picker(selection: $model.layout) {
                    ForEach(layouts, id: \.self) { Text($0.title).tag($0) }
                } label: { SettingLabel("Layout") }
                Picker(selection: $model.compactRows) {
                    Text("Three lines").tag(false)
                    Text("One line").tag(true)
                } label: { SettingLabel("Rows") }
                #if os(macOS)
                Picker(selection: $model.insetPanel) {
                    Text("Edge to edge").tag(false)
                    Text("Inset panel").tag(true)
                } label: { SettingLabel("Window") }
                #endif
                LabeledContent { LanguageSetting() } label: { SettingLabel("Language") }
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
                                    .font(.caption)
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
                Picker(selection: $model.colorBlindSafe) {
                    Text("Standard").tag(false)
                    Text("Color-blind safe").tag(true)
                } label: { SettingLabel("Colors") }
            } footer: {
                Text("A palette that stays clear with red–green and blue–yellow color blindness. Mailboxes also always show their letter, and unread mail is bold as well as marked.")
            }
            Section {
                Toggle(isOn: $model.increaseContrast) { SettingLabel("Increase contrast") }
                Toggle(isOn: $model.underlineLinks) { SettingLabel("Underline links in mail") }
                Toggle(isOn: $model.reduceMotion) { SettingLabel("Reduce motion") }
            } header: {
                Text("Accessibility")
            } footer: {
                #if os(macOS)
                Text("Margin also follows these settings from the Mac's Accessibility settings.")
                #else
                Text("Margin also follows these settings from the system's Accessibility settings.")
                #endif
            }
            #if os(iOS)
            swipes
            #endif
        }
        .formStyle(.grouped)
    }

    #if os(iOS)
    /// What swiping a conversation does: two actions each way, the first on a full swipe.
    private var swipes: some View {
        Section {
            swipePicker("Swipe right", index: 0, leading: true)
            swipePicker("Swipe right, second", index: 1, leading: true)
            swipePicker("Swipe left", index: 0, leading: false)
            swipePicker("Swipe left, second", index: 1, leading: false)
        } header: {
            Text("Swipes")
        } footer: {
            Text("A full swipe does the first action.")
        }
    }

    private func swipePicker(_ title: LocalizedStringKey, index: Int, leading: Bool) -> some View {
        Picker(selection: Binding(
            get: { (leading ? model.leadingSwipes : model.trailingSwipes)[index] },
            set: { value in
                var list = leading ? model.leadingSwipes : model.trailingSwipes
                list[index] = value
                if leading { model.leadingSwipes = list } else { model.trailingSwipes = list }
            }
        )) {
            ForEach(SwipeAction.allCases) { Text($0.title).tag($0) }
        } label: {
            Text(title)
        }
    }
    #endif
}

/// Shortcuts: change any single key, or turn single keys off.
struct ShortcutSettings: View {
    @Bindable var model: MailModel

    var body: some View {
        let commands = MailCommand.all(for: model).filter { $0.keys.count == 1 || model.keyOverrides[$0.id] != nil }
        Form {
            SettingsHeader(.shortcuts)
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
            } footer: {
                Text("Turn this off if you'd rather nothing happens when you type outside a text field. ⌘ shortcuts and ⌘K keep working.")
            }
            Section {
                ForEach(commands) { command in
                    ShortcutRow(model: model, command: command, clashes: clashes(command, in: commands))
                }
            }
            .disabled(!model.singleKeyShortcuts)
            Section {
                Button("Restore the original keys") { model.keyOverrides = [:] }
            }
        }
        .formStyle(.grouped)
    }

    private func clashes(_ command: MailCommand, in commands: [MailCommand]) -> Bool {
        guard let key = command.key(in: model)?.lowercased() else { return false }
        return commands.contains { $0.id != command.id && $0.key(in: model)?.lowercased() == key }
    }
}

private struct ShortcutRow: View {
    @Bindable var model: MailModel
    let command: MailCommand
    let clashes: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.s) {
                if clashes { Text("Used twice").font(.caption).foregroundStyle(Status.danger) }
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
                            Text(template.body.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                if model.isSorting, let progress = model.sortingProgress {
                    Button("Stop (\(progress.done) of \(progress.total))") { model.stopSorting() }
                } else {
                    Button("Sort Now") { model.sortNow() }
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
                                .textFieldStyle(.plain).font(.caption).foregroundStyle(.secondary).lineLimit(1...3)
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

/// Backup and Devices: a file now, automatic backups, a recovery key, and moving to another device.
struct BackupSettings: View {
    let model: MailModel
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
            SettingsHeader(.backup)
            Section {
                Toggle(isOn: Binding(get: { model.syncsWithICloud }, set: { model.syncsWithICloud = $0 })) {
                    SettingLabel("Sync with iCloud",
                                 detail: "Mailboxes, passwords, settings, templates and workspaces on every Mac, iPhone and iPad signed in to your Apple Account.")
                }
                if model.syncsWithICloud {
                    if let problem = model.syncProblem {
                        Text(verbatim: problem).font(.caption).foregroundStyle(.secondary)
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
            Section {
                LabeledContent {
                    SecureField("Password", text: $password, prompt: Text("Optional")).labelsHidden().frame(maxWidth: 220)
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

            automatic
            recovery
            linkDevice
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
                    SecureField("Password", text: $autoPassword, prompt: Text(model.hasAutomaticBackupPassword ? "Saved in Keychain" : "Optional"))
                        .labelsHidden()
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

/// About: what Margin is, its version, and who makes it.
struct AboutSettings: View {
    let model: MailModel
    @State private var showingWelcome = false

    var body: some View {
        Form {
            SettingsHeader(.about)
            Section {
                Text("\(model.environment.appName) is a free, open-source mail client (Apache-2.0). It connects directly to your mail provider over IMAP, SMTP and JMAP. There is no server of ours in between, no account to make, and nothing is tracked.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } footer: {
                Link(destination: URL(string: "https://relevate.app")!) {
                    VStack(spacing: Space.s) {
                        Text("Made by").font(.caption).foregroundStyle(.secondary)
                        RelevateLogo()
                            .fill(Ink.primary)
                            .aspectRatio(RelevateLogo.aspect, contentMode: .fit)
                            .frame(height: 30)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.xl)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Made by Relevate"))
                .padding(.bottom, Space.l)
                Button("Show Welcome") { showingWelcome = true }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingWelcome) { OnboardingView(model: model) }
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
