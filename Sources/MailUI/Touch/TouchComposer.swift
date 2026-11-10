#if os(iOS)
import MailCore
import SwiftUI

/// Writing on iPhone and iPad: a full screen of its own for new messages, replies and
/// forwards, with Send at the top and the tools above the keyboard. A reply shows the
/// message it answers underneath, folded, instead of squeezing a box under the thread.
struct TouchComposer: View {
    let model: MailModel
    @Binding var state: ComposeState
    let isReply: Bool
    @FocusState private var field: Field?
    @State private var richText = RichTextController()
    @State private var picksFiles = false
    @State private var picksDate = false
    @State private var warnsAboutAttachment = false
    @State private var showsQuoted = false

    enum Field { case to, cc, subject, body }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Who it's from comes first, as on the Mac.
                    if model.accounts.flatMap(\.sendAddresses).count > 1 {
                        // The picker carries its own "From" label.
                        VStack(spacing: 0) {
                            HStack { FromPicker(model: model, state: $state); Spacer() }
                                .padding(.horizontal, Space.l)
                                .frame(minHeight: 46)
                            Rectangle().fill(Line.hairline).frame(height: 1)
                        }
                    }
                    line("To") {
                        TextField("", text: $state.to)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($field, equals: .to)
                        if !state.showsCc {
                            Button("Cc") { state.showsCc = true; field = .cc }
                                .font(TypeScale.label).foregroundStyle(Ink.tertiary)
                        }
                    }
                    if field == .to {
                        RecipientSuggestions(model: model, field: $state.to).padding(.horizontal, Space.l).padding(.vertical, 4)
                    }
                    if state.showsCc {
                        line("Cc") {
                            TextField("", text: $state.cc)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($field, equals: .cc)
                        }
                        if field == .cc {
                            RecipientSuggestions(model: model, field: $state.cc).padding(.horizontal, Space.l).padding(.vertical, 4)
                        }
                    }
                    line("Subject") { TextField("", text: $state.draft.subject).focused($field, equals: .subject) }
                    if model.usesBlockComposer {
                        BlockComposer(state: $state)
                            .frame(minHeight: 320)
                    } else {
                        RichTextEditor(text: $state.draft.text, html: $state.draft.html, controller: richText)
                            .focused($field, equals: .body)
                            .frame(minHeight: 220)
                            .padding(.horizontal, Space.l)
                            .padding(.vertical, Space.m)
                    }
                    if isReply {
                        ReplyAssistantBar(model: model, hasText: !state.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .padding(.horizontal, Space.l)
                            .padding(.bottom, Space.s)
                    }
                    ComposeAttachments(state: $state)
                        .padding(.horizontal, Space.l)
                        .padding(.bottom, Space.s)
                    if isReply, let message = answered { quoted(message) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Paper.panel)
            .navigationTitle(isReply ? "Reply" : (state.draft.subject.hasPrefix("Fwd:") ? "Forward" : "New message"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Closing keeps what was written in Drafts.
                    Button { model.closeComposer(state, isReply: isReply) } label: { Label("Close", systemImage: "xmark") }
                }
                // Down out of the way to search or read other mail; a chip at the top brings it back.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if isReply { model.isReplyPutAway = true } else { model.isComposePutAway = true }
                    } label: { Label("Put Away", systemImage: "chevron.down") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { send() } label: { Label("Send", systemImage: "arrow.up") }
                        .disabled(state.to.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                // The block editor has its own bar above the keyboard; Margin's tools stay at the foot.
                if !model.usesBlockComposer {
                    ToolbarItemGroup(placement: .keyboard) { tools }
                }
                ToolbarItemGroup(placement: .bottomBar) { tools }
            }
        }
        .tint(Ink.primary)
        .onAppear { field = state.to.isEmpty ? .to : .body }
        .fileImporter(isPresented: $picksFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { _ = ComposeAttachments.add(urls, to: &state) }
        }
        .sheet(isPresented: $picksDate) {
            DateChoiceSheet(title: "Send at", action: "Schedule") { date in model.schedule(state, at: date, isReply: isReply) }
        }
        .alert("Did you mean to attach a file?", isPresented: $warnsAboutAttachment) {
            Button("Attach a file") { picksFiles = true }
            Button("Send anyway") { model.queueSend(state, isReply: isReply) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The message mentions an attachment, but nothing is attached.")
        }
    }

    /// Attach, send later, templates and formatting: one row, above the keyboard or at the foot.
    @ViewBuilder
    private var tools: some View {
        Button { picksFiles = true } label: { Label("Attach", systemImage: "paperclip") }
        Menu {
            Button("Tomorrow · \(SnoozePreset.tomorrow.date().formatted(.dateTime.weekday(.abbreviated).hour().minute()))") {
                model.schedule(state, at: SnoozePreset.tomorrow.date(), isReply: isReply)
            }
            Button("Monday · \(SnoozePreset.nextWeek.date().formatted(.dateTime.weekday(.abbreviated).hour().minute()))") {
                model.schedule(state, at: SnoozePreset.nextWeek.date(), isReply: isReply)
            }
            Button("Pick a date…") { picksDate = true }
        } label: { Label("Send later", systemImage: "clock") }
        Spacer()
        SignatureMenu(model: model, state: $state)
        ReplyReminderMenu(state: $state)
        TemplatesMenu(model: model, state: $state)
    }

    /// The newest message of the conversation being answered.
    private var answered: MailMessage? {
        model.selectedThread?.latest
    }

    /// "On Tue 16:28, Noor Haddad wrote:", folded until tapped; it isn't added to what you send.
    private func quoted(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button { withAnimation(Motion.quick) { showsQuoted.toggle() } } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: showsQuoted ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(message.from.displayName) wrote \(RowDate.long(message.date))")
                    Spacer()
                }
                .font(TypeScale.label)
                .foregroundStyle(Ink.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsQuoted, let thread = model.selectedThread {
                Text(model.body(of: message, in: thread)?.text ?? message.snippet)
                    .font(TypeScale.row)
                    .foregroundStyle(Ink.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, Space.m)
                    .overlay(alignment: .leading) { Rectangle().fill(Line.edge).frame(width: 2) }
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.m)
        .padding(.bottom, Space.xl)
        .overlay(alignment: .top) { Rectangle().fill(Line.hairline).frame(height: 1) }
    }

    private func line<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Text(label).font(TypeScale.label).foregroundStyle(Ink.tertiary).frame(width: 60, alignment: .leading)
                content().font(TypeScale.row)
            }
            .padding(.horizontal, Space.l)
            .frame(minHeight: 46)
            Rectangle().fill(Line.hairline).frame(height: 1)
        }
    }

    private func send() {
        if state.forgotAttachment { warnsAboutAttachment = true } else { model.queueSend(state, isReply: isReply) }
    }
}
#endif
