import MailCore
import SwiftUI

/// The workspace switcher at the top of the sidebar: All, then each workspace with a dot when
/// it has unread mail, and Edit Workspaces….
struct WorkspaceMenu<Label: View>: View {
    let model: MailModel
    @Binding var editing: Bool
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            Button { model.switchWorkspace(to: nil) } label: {
                if model.currentWorkspaceID == nil { SwiftUI.Label("All mailboxes", systemImage: "checkmark") } else { Text("All mailboxes") }
            }
            if !model.workspaces.isEmpty { Divider() }
            ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, workspace in
                let unread = model.unreadCount(in: workspace)
                Button { model.switchWorkspace(to: workspace.id) } label: {
                    let title = unread > 0 && workspace.id != model.currentWorkspaceID ? "\(workspace.name) ●" : workspace.name
                    if workspace.id == model.currentWorkspaceID { SwiftUI.Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
                }
                .workspaceShortcut(index)
            }
            Divider()
            Button("Edit Workspaces…") { editing = true }
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
    }
}

extension View {
    /// ⌥⌘1…⌥⌘9 for the first nine workspaces.
    @ViewBuilder
    func workspaceShortcut(_ index: Int) -> some View {
        if index < 9 { keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.option, .command]) } else { self }
    }
}

/// The sidebar's top line when no single mailbox is open: the workspace in view (or All
/// inboxes) with what it holds, opening the workspace menu.
struct WorkspaceHeader: View {
    let model: MailModel
    @State private var editing = false

    var body: some View {
        WorkspaceMenu(model: model, editing: $editing) {
            HStack(spacing: 10) {
                if let workspace = model.currentWorkspace {
                    WorkspaceBadge(workspace: workspace, size: 28)
                } else {
                    Image(systemName: "tray.2")
                        .font(.system(size: Look.size(13)))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 28, height: 28)
                        .background(Fill.two, in: Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(verbatim: model.currentWorkspace?.name ?? String(localized: "All inboxes"))
                            .font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: Look.size(8), weight: .semibold)).foregroundStyle(Ink.tertiary)
                    }
                    Text(verbatim: model.workspaceAccounts.map(\.label).formatted(.list(type: .and)))
                        .font(TypeScale.caption).foregroundStyle(Ink.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                // Mail waiting in the other workspaces.
                if model.workspaces.contains(where: { $0.id != model.currentWorkspaceID && model.unreadCount(in: $0) > 0 }) && model.currentWorkspaceID != nil {
                    Circle().fill(Palette.accent).frame(width: 6, height: 6).accessibilityLabel("Unread mail in other workspaces")
                }
            }
            .contentShape(Rectangle())
        }
        .tip("Switch workspace")
        .sheet(isPresented: $editing) { WorkspaceEditor(model: model) }
    }
}

/// A workspace's badge: its first letter on a rounded square in its colour.
struct WorkspaceBadge: View {
    let workspace: Workspace
    var size: CGFloat = 28

    var body: some View {
        Text(workspace.name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.account(workspace.colorIndex), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

extension Binding {
    /// One item of a list being edited, found by its id each time instead of by its place.
    /// A field that still reads or writes an item after it was deleted gets the last copy and
    /// changes nothing. A binding by place, as `ForEach($list)` makes, reaches past the end of
    /// the list there and stops the app.
    @MainActor
    func item<Element: Identifiable & Sendable>(_ item: Element) -> Binding<Element>
    where Value == [Element], Element.ID: Sendable {
        Binding<Element>(
            get: { wrappedValue.first { $0.id == item.id } ?? item },
            set: { changed in
                guard let index = wrappedValue.firstIndex(where: { $0.id == item.id }) else { return }
                wrappedValue[index] = changed
            }
        )
    }
}

/// Making and changing workspaces: name, colour, and which mailboxes are in each.
struct WorkspaceEditor: View {
    let model: MailModel
    @Environment(\.dismiss) private var dismiss
    @State private var workspaces: [Workspace] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Group your mailboxes, like Work and Personal. Pick one at the top of the sidebar, or with ⌥⌘1, ⌥⌘2…, to see only its mail. The others keep checking quietly: no alerts except sign-in codes.")
                        .font(TypeScale.label).foregroundStyle(Ink.secondary)
                    Text("A mailbox that's in no workspace shows in all of them.")
                        .font(TypeScale.label).foregroundStyle(Ink.secondary)
                }
                // By id, not by place: a name field that is still writing when its workspace is
                // deleted must not reach into the list at a place that is gone.
                ForEach(workspaces) { item in
                    let draft = $workspaces.item(item)
                    let workspace = draft.wrappedValue
                    Section {
                        HStack {
                            WorkspaceBadge(workspace: workspace, size: 24)
                            TextField("Name", text: draft.name)
                        }
                        Picker("Color", selection: draft.colorIndex) {
                            ForEach(0..<12, id: \.self) { index in
                                Text(verbatim: "●").foregroundStyle(Palette.account(index)).tag(index)
                            }
                        }
                        ForEach(model.accounts) { account in
                            Toggle(isOn: Binding(
                                get: { draft.wrappedValue.accounts.contains(account.id) },
                                set: { on in
                                    var accounts = draft.wrappedValue.accounts.filter { $0 != account.id }
                                    if on { accounts.append(account.id) }
                                    draft.wrappedValue.accounts = accounts
                                }
                            )) {
                                HStack { AccountMark(account, size: 16); Text(verbatim: account.label) }
                            }
                        }
                        Button("Delete Workspace", role: .destructive) { workspaces.removeAll { $0.id == workspace.id } }
                    }
                }
                Section {
                    Button("Add a Workspace") {
                        workspaces.append(Workspace(name: String(localized: "New workspace"), colorIndex: (workspaces.count * 3 + 1) % 12, accounts: []))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Workspaces")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.workspaces = workspaces.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 560)
        #endif
        .onAppear { workspaces = model.workspaces }
    }
}
