import MailCore
import SwiftUI

/// Making and changing events from the Calendar: the editor sheet, and the question a repeating
/// event asks (only this one, or all of them). Shared by the agenda, Day, Week and Month, which
/// find it in the environment.
@MainActor @Observable
final class CalendarEditor {
    struct Sheet: Identifiable {
        let id = UUID()
        /// Nil for a new event.
        var item: AgendaItem?
        var draft: EventDraft
        var destination: EventDestination?
    }

    struct ScopeQuestion: Identifiable {
        let id = UUID()
        let title: String
        let isDelete: Bool
        let perform: (EventScope) -> Void
    }

    let model: MailModel
    var sheet: Sheet?
    var scopeQuestion: ScopeQuestion?

    init(model: MailModel) { self.model = model }

    /// Whether there's anywhere to put a new event.
    var canAdd: Bool { !model.eventDestinations.isEmpty }

    /// A new event; with invitees, in a connected mailbox's calendar, which can invite them.
    func newEvent(start: Date, end: Date? = nil, allDay: Bool = false, invitees: [EmailAddress] = []) {
        let canInvite = model.eventDestinations.filter { if case .account = $0 { true } else { false } }
        guard let destination = invitees.isEmpty ? model.defaultEventDestination : (canInvite.first ?? model.defaultEventDestination) else { return }
        let finish = end ?? start.addingTimeInterval(allDay ? 86_400 : 3600)
        // A meeting with people gets a video call by default; the editor turns it off when the
        // calendar can't make one.
        sheet = Sheet(item: nil, draft: EventDraft(title: "", start: start, end: finish, isAllDay: allDay, location: "", notes: "",
                                                   invitees: invitees, videoCall: !invitees.isEmpty),
                      destination: destination)
    }

    func edit(_ item: AgendaItem) {
        guard model.canChange(item) else { return }
        sheet = Sheet(item: item, draft: model.draft(of: item), destination: model.destination(of: item))
    }

    /// Saves a change; a repeating event asks first whether it's for this one or all.
    func change(_ item: AgendaItem, to draft: EventDraft) {
        let model = model
        guard item.repeats else {
            Task { await model.updateEvent(item, with: draft) }
            return
        }
        scopeQuestion = ScopeQuestion(title: item.title, isDelete: false) { scope in
            Task { await model.updateEvent(item, with: draft, scope: scope) }
        }
    }

    func delete(_ item: AgendaItem) {
        let model = model
        guard item.repeats else {
            Task { await model.deleteEvent(item) }
            return
        }
        scopeQuestion = ScopeQuestion(title: item.title, isDelete: true) { scope in
            Task { await model.deleteEvent(item, scope: scope) }
        }
    }

    /// A time snapped to the quarter hour, the steps events are made and moved in.
    static func snapped(_ date: Date, minutes step: Int = 15) -> Date {
        let seconds = Double(step * 60)
        return Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / seconds).rounded() * seconds)
    }
}

extension View {
    /// The editor sheet and the repeating-event question, for a view holding a `CalendarEditor`.
    func calendarEditing(_ editor: CalendarEditor) -> some View {
        modifier(CalendarEditingModifier(editor: editor))
    }
}

private struct CalendarEditingModifier: ViewModifier {
    @Bindable var editor: CalendarEditor

    func body(content: Content) -> some View {
        content
            .environment(editor)
            .sheet(item: $editor.sheet) { sheet in
                EventEditorView(editor: editor, sheet: sheet)
            }
            .confirmationDialog(
                Text(editor.scopeQuestion?.isDelete == true ? "Delete a repeating event" : "Change a repeating event"),
                isPresented: Binding(get: { editor.scopeQuestion != nil }, set: { if !$0 { editor.scopeQuestion = nil } }),
                presenting: editor.scopeQuestion
            ) { question in
                Button(question.isDelete ? "Delete Only This Event" : "Only This Event", role: question.isDelete ? .destructive : nil) {
                    question.perform(.thisEvent)
                }
                Button(question.isDelete ? "Delete All Events" : "All Events", role: question.isDelete ? .destructive : nil) {
                    question.perform(.allEvents)
                }
                Button("Cancel", role: .cancel) {}
            } message: { question in
                Text("“\(question.title)” repeats. Change only this one, or every one?")
            }
    }
}

/// The event window: a big title, then one row per part, each with its symbol on the left, the
/// way Calendar and Daybook lay an event out. Calendar is a menu of every calendar grouped by
/// where it lives; people are chips, with suggestions floating over the form; suggested times
/// stay folded until asked for, with a choice of which of your calendars count. ⌘↩ saves.
private struct EventEditorView: View {
    let editor: CalendarEditor
    let sheet: CalendarEditor.Sheet
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EventDraft
    @State private var destination: EventDestination?
    @State private var invitees: [EmailAddress]
    @State private var typing = ""
    @State private var directory: [EmailAddress] = []
    @State private var isSaving = false
    /// The video call service the chosen calendar offers; nil while unknown or when it has none.
    @State private var videoService: String?
    @State private var showsTimes = false
    @State private var showsCounting = false
    @State private var skips: Set<String>
    @FocusState private var focus: Field?

    enum Field: Hashable { case title, people }

    init(editor: CalendarEditor, sheet: CalendarEditor.Sheet) {
        self.editor = editor
        self.sheet = sheet
        _draft = State(initialValue: sheet.draft)
        _destination = State(initialValue: sheet.destination)
        _invitees = State(initialValue: sheet.draft.invitees)
        _skips = State(initialValue: editor.model.suggestionSkips)
    }

    private var model: MailModel { editor.model }
    private var isNew: Bool { sheet.item == nil }
    private var isAccount: Bool { if case .account = destination { true } else { false } }
    /// A connected mailbox's calendar, which can invite people and make calls.
    private var mailboxCalendar: EventDestination? {
        model.eventDestinations.first { if case .account = $0 { true } else { false } }
    }
    private var counting: Set<String> { Set(model.busyCalendarChoices.map(\.id)).subtracting(skips) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Event" : "Edit Event").font(TypeScale.heading).foregroundStyle(Ink.primary)
                Spacer()
                CloseKeyCap { dismiss() }
            }
            .padding(.horizontal, 20)
            .frame(height: 46)
            Rectangle().fill(Line.hairline).frame(height: 1)
            HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Title", text: $draft.title, prompt: Text("Title"))
                        .textFieldStyle(.plain)
                        .font(.system(size: Look.size(20), weight: .semibold))
                        .focused($focus, equals: .title)
                        .padding(.bottom, 2)
                    row("calendar") { calendarMenu }
                    row("clock") { timeFields }
                    if isNew {
                        row("person.2") { peopleField }
                            .zIndex(2)
                    }
                    if isNew, isAccount, !invitees.isEmpty, !draft.isAllDay {
                        row("sparkles") { suggestedTimes }
                    }
                    row("video") { videoRow }
                    row("mappin") {
                        TextField("Location", text: Binding(get: { draft.location ?? "" }, set: { draft.location = $0 }),
                                  prompt: Text("Add a place"))
                            .textFieldStyle(.plain)
                            .font(TypeScale.row)
                    }
                    row("text.alignleft") {
                        TextField("Notes", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0 }),
                                  prompt: Text("Add notes"), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(TypeScale.row)
                            .lineLimit(3...10)
                    }
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity)
            #if os(macOS)
            Rectangle().fill(Line.hairline).frame(width: 1)
            // The day beside the form, as calendars show it while you pick a time.
            DayPeek(model: model, start: Binding(get: { draft.start }, set: { draft.start = $0 }), end: $draft.end,
                    isAllDay: draft.isAllDay, title: draft.title, people: isAccount ? invitees : [],
                    destination: destination, editing: sheet.item)
                .frame(width: 280)
            #endif
            }
            Rectangle().fill(Line.hairline).frame(height: 1)
            HStack(spacing: 8) {
                if let item = sheet.item {
                    Button("Delete Event", role: .destructive) {
                        dismiss()
                        editor.delete(item)
                    }
                    .buttonStyle(.plain)
                    .font(TypeScale.rowStrong)
                    .foregroundStyle(Status.danger)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { save() } label: {
                    HStack(spacing: 6) {
                        Text(isNew ? (invitees.isEmpty ? "Add Event" : "Send Invitations") : "Save")
                        Text(verbatim: "⌘↩").opacity(0.55)
                    }
                }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSaving || draft.title.trimmingCharacters(in: .whitespaces).isEmpty || destination == nil)
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
        }
        .background(Paper.popover)
        #if os(macOS)
        .frame(width: 820, height: 640)
        #endif
        .onAppear { focus = isNew && draft.title.isEmpty ? .title : nil }
        .task(id: destination) {
            videoService = nil
            guard let destination else { return }
            let service = await model.videoCallService(for: destination)
            videoService = service ?? sheet.item?.joinURL.flatMap(AgendaRow.service)
        }
        .task(id: showsTimes) { if showsTimes { await model.refreshCalendarSharers() } }
    }

    private func row<Content: View>(_ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: Look.size(13)))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 18)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Calendar

    /// Every calendar new events can go in, grouped: each mailbox, then this Mac's.
    private var calendarMenu: some View {
        let accounts = model.eventDestinations.filter { if case .account = $0 { true } else { false } }
        let device = model.eventDestinations.filter { if case .device = $0 { true } else { false } }
        return Menu {
            if !accounts.isEmpty {
                Section("Mailboxes") { ForEach(accounts) { option($0) } }
            }
            if !device.isEmpty {
                Section("On this Mac") { ForEach(device) { option($0) } }
            }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(Palette.account(destination.map(model.colorIndex(of:)) ?? 0)).frame(width: 9, height: 9)
                Text(verbatim: destination.map(model.title(of:)) ?? "")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.tertiary)
            }
            .font(TypeScale.row)
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isNew)
    }

    private func option(_ destination: EventDestination) -> some View {
        Button {
            self.destination = destination
        } label: {
            Label {
                Text(verbatim: model.title(of: destination))
            } icon: {
                Image(systemName: self.destination == destination ? "checkmark.circle.fill" : "circle.fill")
                    .foregroundStyle(Palette.account(model.colorIndex(of: destination)))
            }
        }
    }

    // MARK: When

    private var timeFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DatePicker("Starts", selection: startBinding, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
                Text("to").font(TypeScale.row).foregroundStyle(Ink.tertiary)
                DatePicker("Ends", selection: endBinding, in: draft.start..., displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
            }
            HStack(spacing: 12) {
                Toggle("All day", isOn: $draft.isAllDay)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                    .font(TypeScale.row)
                if !draft.isAllDay {
                    Text(verbatim: Duration.seconds(draft.end.timeIntervalSince(draft.start)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        .font(TypeScale.label)
                        .foregroundStyle(Ink.tertiary)
                }
            }
        }
    }

    /// Moving the start keeps the length, as calendars do.
    private var startBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { newStart in
            let length = draft.end.timeIntervalSince(draft.start)
            draft.start = newStart
            draft.end = newStart.addingTimeInterval(max(length, 0))
        })
    }

    /// An all-day event's end is shown as its last day.
    private var endBinding: Binding<Date> {
        Binding(get: { draft.isAllDay ? max(draft.start, draft.end.addingTimeInterval(-1)) : draft.end },
                set: { draft.end = draft.isAllDay ? Calendar.current.startOfDay(for: $0).addingTimeInterval(86_400) : $0 })
    }

    // MARK: People

    /// Chips for everyone invited and a field to add more. Suggestions float over the form, so
    /// it doesn't grow, and only offer people you know: written to, sharing a calendar, or in
    /// your organization's directory.
    private var peopleField: some View {
        let suggestions = model.inviteeSuggestions(for: typing, excluding: Set(invitees.map { $0.address.lowercased() }),
                                                   directory: directory)
        return VStack(alignment: .leading, spacing: 4) {
            FlowRow(spacing: 6) {
                ForEach(invitees, id: \.address) { person in
                    InviteeChip(person: person, seesCalendar: model.calendarSharers.contains { $0.address.lowercased() == person.address.lowercased() }
                                    || model.workDomains.contains(MailModel.domain(of: person))) {
                        invitees.removeAll { $0.address == person.address }
                    }
                }
                TextField("People", text: $typing, prompt: Text(invitees.isEmpty ? "Invite people" : "Add"))
                    .textFieldStyle(.plain)
                    .font(TypeScale.row)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .people)
                    .frame(minWidth: 120)
                    .onSubmit { addTyped(suggestions.first?.person) }
                    .onChange(of: typing) { _, value in if value.hasSuffix(",") || value.hasSuffix(";") { addTyped(nil) } }
                    .onKeyPress(.delete) {
                        guard typing.isEmpty, !invitees.isEmpty else { return .ignored }
                        invitees.removeLast()
                        return .handled
                    }
            }
            if !isAccount, !invitees.isEmpty, let mailboxCalendar {
                Text("Invitations go out from \(model.title(of: mailboxCalendar)).")
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .overlay(alignment: .topLeading) {
            if focus == .people, !suggestions.isEmpty {
                InviteeSuggestions(suggestions: suggestions) { addTyped($0) }
                    .offset(y: 30)
            }
        }
        .task(id: typing) {
            let text = typing.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { directory = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.searchDirectories(text)
            if !Task.isCancelled { directory = found }
        }
    }

    /// Adds the picked person, or what was typed when it's an address. Inviting people moves a
    /// new event to a mailbox's calendar, since only those send invitations.
    private func addTyped(_ person: EmailAddress?) {
        let typed = typing.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        let adding = person.map { [$0] } ?? (EmailAddress.parseList(typed) ?? [])
        for address in adding where !invitees.contains(where: { $0.address.lowercased() == address.address.lowercased() }) {
            invitees.append(address)
        }
        if !adding.isEmpty {
            typing = ""
            if !isAccount, let mailboxCalendar {
                destination = mailboxCalendar
                draft.videoCall = true
            }
        }
    }

    // MARK: Suggested times

    private var suggestedTimes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(Motion.quick) { showsTimes.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text("Suggest a time").font(TypeScale.row).foregroundStyle(Ink.primary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Ink.quaternary)
                            .rotationEffect(.degrees(showsTimes ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if showsTimes {
                    Button {
                        showsCounting.toggle()
                    } label: {
                        Text(skips.isEmpty ? "All your calendars" : "\(counting.count) of your calendars")
                            .font(TypeScale.label)
                            .foregroundStyle(Ink.tertiary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsCounting, arrowEdge: .bottom) { countingList }
                }
            }
            if showsTimes {
                SuggestedTimesRow(model: model, people: invitees, destination: destination,
                                  start: $draft.start, end: $draft.end, counting: counting, showsTitle: false)
                    .transition(.opacity)
            }
        }
    }

    /// Which of your calendars count as busy when suggesting times; remembered for next time.
    private var countingList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Count me busy in").font(TypeScale.label.weight(.semibold)).foregroundStyle(Ink.secondary)
            ForEach(model.busyCalendarChoices) { choice in
                Toggle(isOn: Binding(get: { !skips.contains(choice.id) }, set: { on in
                    if on { skips.remove(choice.id) } else { skips.insert(choice.id) }
                    model.suggestionSkips = skips
                })) {
                    HStack(spacing: 7) {
                        Circle().fill(Palette.account(choice.colorIndex)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: choice.title).font(TypeScale.label)
                            if let detail = choice.detail {
                                Text(verbatim: detail).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                            }
                        }
                    }
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
            }
        }
        .padding(14)
        .frame(minWidth: 240, alignment: .leading)
    }

    // MARK: Video call

    @ViewBuilder
    private var videoRow: some View {
        if let url = sheet.item?.joinURL {
            Link(destination: url) { Text("Join \(videoService ?? AgendaRow.service(url) ?? "")") }
                .font(TypeScale.row)
        } else if let videoService {
            Toggle(isOn: $draft.videoCall) { Text("Add a \(videoService) call").font(TypeScale.row) }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
        } else if isNew, let mailboxCalendar {
            // This calendar can't make calls; a mailbox's can. Asking for one moves it there.
            Button {
                destination = mailboxCalendar
                draft.videoCall = true
            } label: {
                Text("Add a video call").font(TypeScale.row)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .help(Text("Moves the event to \(model.title(of: mailboxCalendar))"))
        } else {
            Text("No video calls in this calendar").font(TypeScale.row).foregroundStyle(Ink.quaternary)
        }
    }

    // MARK: Saving

    private func save() {
        addTyped(nil)
        var final = draft
        final.title = final.title.trimmingCharacters(in: .whitespaces)
        if videoService == nil && sheet.item?.joinURL == nil { final.videoCall = false }
        if let item = sheet.item {
            dismiss()
            editor.change(item, to: final)
            return
        }
        guard let destination else { return }
        final.invitees = isAccount ? invitees : []
        isSaving = true
        Task {
            let made = await model.createEvent(final, in: destination)
            isSaving = false
            if made { dismiss() }
        }
    }
}

/// Someone invited: their face, name, a dot when their calendar can be seen, and ✕ on hover.
private struct InviteeChip: View {
    let person: EmailAddress
    let seesCalendar: Bool
    let remove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Avatar(person, size: 18)
            Text(verbatim: person.name ?? person.address).font(TypeScale.label).foregroundStyle(Ink.primary).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.45)
            .accessibilityLabel(Text("Remove \(person.displayName)"))
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(Fill.one, in: Capsule())
        .overlay(alignment: .topTrailing) {
            if seesCalendar {
                Circle().fill(Status.done).frame(width: 6, height: 6).offset(x: -2, y: 1)
                    .help(Text("Their busy times can be seen"))
            }
        }
        .onHover { isHovered = $0 }
        .help(Text(verbatim: person.address))
    }
}

/// The people matching what's typed, floating under the field: those whose calendar can be
/// seen first, marked.
private struct InviteeSuggestions: View {
    let suggestions: [(person: EmailAddress, seesCalendar: Bool)]
    let pick: (EmailAddress) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.person.address) { suggestion in
                Button { pick(suggestion.person) } label: {
                    HStack(spacing: 9) {
                        Avatar(suggestion.person, size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: suggestion.person.displayName).font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                            Text(verbatim: suggestion.person.address).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 8)
                        if suggestion.seesCalendar {
                            Label("Calendar", systemImage: "calendar")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 11))
                                .foregroundStyle(Status.done)
                                .help(Text("Their busy times can be seen"))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(width: 340, alignment: .leading)
        .background(Paper.popover, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Line.edge))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }
}

/// The editor for a new event with people in it, on its own, for snapshots
/// (`-snapshot-event-editor`): the sheet can't be pictured with the window behind it.
public struct EventEditorSnapshot: View {
    @State private var editor: CalendarEditor

    public init(model: MailModel, start: Date, invitees: [EmailAddress]) {
        let editor = CalendarEditor(model: model)
        editor.newEvent(start: start, end: start.addingTimeInterval(1800), invitees: invitees)
        _editor = State(initialValue: editor)
    }

    public var body: some View {
        if let sheet = editor.sheet { EventEditorView(editor: editor, sheet: sheet) }
    }
}

/// Beside the event window: the event's day, with what else is on, when the people invited are
/// busy, and the event itself, which can be dragged to another time (in quarter hours, keeping
/// its length). Above it, one line: free then, or what it clashes with.
private struct DayPeek: View {
    let model: MailModel
    @Binding var start: Date
    @Binding var end: Date
    let isAllDay: Bool
    let title: String
    let people: [EmailAddress]
    let destination: EventDestination?
    /// The event being edited, left out of what else is on.
    let editing: AgendaItem?
    @State private var busy: [String: [BusyTime]] = [:]
    @State private var drag: CGFloat = 0
    /// While its bottom edge is dragged: how much longer (or shorter) the event is, in points.
    @State private var stretch: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)

    private let hour: CGFloat = 40
    private let gutter: CGFloat = 38
    private var day: Date { Calendar.current.startOfDay(for: start) }

    var body: some View {
        let others = model.agenda(from: day, to: day.addingTimeInterval(86_400))
            .filter { item in !item.isAllDay && item.id != editing?.id }
        let clashes = isAllDay ? [] : others.filter { $0.response != .declined && $0.start < end && $0.end > start }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { shift(days: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Ink.tertiary).frame(width: 20, height: 20)
                Text(verbatim: day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(TypeScale.rowStrong)
                    .foregroundStyle(Ink.primary)
                Button { shift(days: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).foregroundStyle(Ink.tertiary).frame(width: 20, height: 20)
                Spacer()
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 40)
            status(clashes)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Rectangle().fill(Line.hairline).frame(height: 1)
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { h in
                            HStack(alignment: .top, spacing: 4) {
                                Text(verbatim: h == 0 ? "" : CalendarTimeline.hourLabel(h))
                                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Ink.quaternary)
                                    .frame(width: gutter - 6, alignment: .trailing)
                                    .offset(y: -5)
                                Rectangle().fill(Line.hairline).frame(height: 1)
                            }
                            .frame(height: hour, alignment: .top)
                        }
                    }
                    GeometryReader { geometry in
                        let width = geometry.size.width - gutter - 6
                        ForEach(others) { item in
                            block(item.title, from: item.start, to: item.end, tint: Palette.account(item.colorIndex), strong: false)
                                .frame(width: width * 0.62, height: height(item.start, item.end))
                                .offset(x: gutter, y: y(item.start))
                        }
                        // The people invited: a bar each down the right where they're busy.
                        ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                            ForEach(Array((busy[person.address.lowercased()] ?? []).enumerated()), id: \.offset) { _, time in
                                Capsule()
                                    .fill(Palette.account(index + 3).opacity(time.kind == .tentative ? 0.35 : 0.7))
                                    .frame(width: 4, height: max(height(time.start, time.end), 4))
                                    .offset(x: gutter + width - CGFloat(index) * 6, y: y(time.start))
                                    .help(Text("\(person.displayName) is busy \(time.start.formatted(date: .omitted, time: .shortened)) – \(time.end.formatted(date: .omitted, time: .shortened))"))
                            }
                        }
                        if !isAllDay {
                            let shownEnd = end.addingTimeInterval(Double(snapped(stretch)) * 60)
                            block(title.isEmpty ? String(localized: "New Event") : title, from: start, to: shownEnd,
                                  tint: Palette.account(destination.map(model.colorIndex(of:)) ?? 0), strong: true)
                                .frame(width: width * 0.62, height: max(height(start, end) + stretch, hour / 4 - 1))
                                // The bottom edge: drag it to make the event longer or shorter.
                                .overlay(alignment: .bottom) {
                                    Capsule()
                                        .fill(.white.opacity(0.7))
                                        .frame(width: 18, height: 3)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 10)
                                        .contentShape(Rectangle())
                                        .padding(.bottom, -3)
                                        #if os(macOS)
                                        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                                        #endif
                                        .highPriorityGesture(DragGesture(minimumDistance: 1)
                                            .onChanged { stretch = $0.translation.height }
                                            .onEnded { value in
                                                let minutes = snapped(value.translation.height)
                                                stretch = 0
                                                end = max(end.addingTimeInterval(Double(minutes) * 60), start.addingTimeInterval(15 * 60))
                                            })
                                        .help(Text("Drag to change how long it is"))
                                }
                                .offset(x: gutter + width * 0.3, y: y(start) + drag)
                                .gesture(DragGesture(minimumDistance: 2)
                                    .onChanged { drag = $0.translation.height }
                                    .onEnded { value in
                                        let minutes = Int((value.translation.height / hour * 60 / 15).rounded()) * 15
                                        drag = 0
                                        move(minutes: minutes)
                                    })
                                .help(Text("Drag to change the time"))
                        }
                    }
                }
                .frame(height: hour * 24)
                .padding(.trailing, 6)
            }
            .scrollPosition($position)
            .onAppear { position.scrollTo(y: max(y(start) - hour * 2, 0)) }
            .onChange(of: day) { _, _ in position.scrollTo(y: max(y(start) - hour * 2, 0)) }
        }
        .background(Paper.sidebar)
        .task(id: "\(day.timeIntervalSince1970)|" + people.map(\.address).joined(separator: ",")) {
            guard !people.isEmpty else { busy = [:]; return }
            busy = await model.busyTimes(of: people, from: day, to: day.addingTimeInterval(86_400), in: destination)
        }
    }

    @ViewBuilder
    private func status(_ clashes: [AgendaItem]) -> some View {
        let peopleBusy = people.filter { person in
            (busy[person.address.lowercased()] ?? []).contains { $0.kind != .workingElsewhere && $0.start < end && $0.end > start }
        }
        if isAllDay {
            Text("All day").font(TypeScale.label).foregroundStyle(Ink.tertiary)
        } else if let first = clashes.first {
            Label(String(localized: "Clashes with \(first.title)"), systemImage: "exclamationmark.triangle.fill")
                .font(TypeScale.label).foregroundStyle(Status.star).lineLimit(1)
        } else if let person = peopleBusy.first {
            Label(String(localized: "\(person.displayName) is busy then"), systemImage: "exclamationmark.circle")
                .font(TypeScale.label).foregroundStyle(Status.star).lineLimit(1)
        } else {
            Label(people.isEmpty ? "You're free then" : "Everyone's free then", systemImage: "checkmark.circle.fill")
                .font(TypeScale.label).foregroundStyle(Status.done).lineLimit(1)
        }
    }

    private func block(_ title: String, from: Date, to: Date, tint: Color, strong: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(verbatim: strong ? from.formatted(date: .omitted, time: .shortened) + " – " + to.formatted(date: .omitted, time: .shortened)
                                  : from.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10).monospacedDigit()).opacity(0.75)
        }
        .foregroundStyle(strong ? Color.white : Ink.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(strong ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.16)), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .leading) { if !strong { Rectangle().fill(tint).frame(width: 2.5) } }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(strong ? 0.15 : 0), radius: 4, y: 2)
    }

    /// Points dragged, as whole quarter hours.
    private func snapped(_ points: CGFloat) -> Int { Int((points / hour * 60 / 15).rounded()) * 15 }

    private func y(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(day) / 3600) * hour }
    private func height(_ from: Date, _ to: Date) -> CGFloat { max(CGFloat(to.timeIntervalSince(from) / 3600) * hour - 1, 16) }

    private func move(minutes: Int) {
        guard minutes != 0 else { return }
        start = start.addingTimeInterval(Double(minutes) * 60)
        end = end.addingTimeInterval(Double(minutes) * 60)
    }

    private func shift(days: Int) {
        let calendar = Calendar.current
        start = calendar.date(byAdding: .day, value: days, to: start) ?? start
        end = calendar.date(byAdding: .day, value: days, to: end) ?? end
    }
}
