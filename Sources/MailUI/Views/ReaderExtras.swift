import MailCore
import SwiftUI
import UniformTypeIdentifiers
#if canImport(Translation)
import Translation
#endif

/// Situational actions under the subject: follow up, unsnooze, unsubscribe, clear out a
/// sender, copy a sign-in code, translate.
struct ReaderExtras: View {
    let model: MailModel
    let thread: MailThread
    @State private var showsTranslation = false

    var body: some View {
        let unsubscribe = model.unsubscribeMethod(for: thread)
        let fromSender = thread.split == .newsletters || unsubscribe != nil ? model.threadsFromSameSender(as: thread).count : 0
        let code = model.signInCode(in: thread)
        HStack(spacing: Space.l) {
            if thread.messages.contains(where: { $0.flags.contains(.draft) }) || model.place.isDraftsFolder {
                TextAction(title: "Edit draft", symbol: "pencil", key: nil) { model.editDraft(thread) }
            }
            if case .waiting = model.place {
                TextAction(title: "Follow up", symbol: "arrowshape.turn.up.right", key: "W") { model.followUp() }
            }
            if model.snoozedUntil(thread) != nil {
                TextAction(title: "Unsnooze", symbol: "clock.arrow.circlepath", key: nil) { model.unsnooze(thread) }
            }
            if let code {
                TextAction(title: "Copy code \(code)", symbol: "number", key: nil) { model.copy(code, announce: "Code copied") }
            }
            if unsubscribe != nil {
                TextAction(title: "Unsubscribe", symbol: "minus.circle", key: nil) { model.unsubscribe(thread) }
            }
            if fromSender > 1 {
                TextAction(title: "Archive all \(fromSender) from sender", symbol: "archivebox", key: nil) { model.archiveAll(from: thread) }
            }
            TextAction(title: "Translate", symbol: "character.bubble", key: nil) { showsTranslation = true }
        }
        #if canImport(Translation)
        .translationPresentation(isPresented: $showsTranslation, text: translatableText)
        #endif
    }

    private var translatableText: String {
        let latest = thread.latest
        return thread.subject + "\n\n" + (model.body(of: latest, in: thread)?.text ?? latest.snippet)
    }
}

/// Snooze presets and "Pick a date…" in the toolbar.
struct SnoozeMenu: View {
    @Bindable var model: MailModel

    var body: some View {
        Menu {
            ForEach(SnoozePreset.allCases, id: \.self) { preset in
                let date = preset.date()
                Button {
                    model.snooze(until: date)
                } label: {
                    Text(verbatim: "\(preset.title) · \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                }
            }
            Divider()
            Button("Pick a date…") { model.isPickingSnoozeDate = true }
        } label: {
            ToolbarLabel(symbol: "clock", title: "Snooze")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Snooze  H")
        .sheet(isPresented: $model.isPickingSnoozeDate) {
            DateChoiceSheet(title: "Snooze until", action: "Snooze") { date in model.snooze(until: date) }
        }
    }
}

/// A date and time, for snoozing or sending later.
struct DateChoiceSheet: View {
    let title: LocalizedStringKey
    let action: LocalizedStringKey
    let onChoose: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(title).font(TypeScale.heading)
            DatePicker("", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(action) { onChoose(date); dismiss() }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 360)
        .background(Paper.popover)
    }
}

/// Several conversations selected: act on all of them at once.
struct BulkActionsView: View {
    let model: MailModel

    var body: some View {
        VStack(spacing: Space.l) {
            Text("\(model.selection.count) conversations selected").font(TypeScale.heading).foregroundStyle(Ink.primary)
            HStack(spacing: Space.s) {
                Button("Done") { model.perform(.done) }.buttonStyle(InkButtonStyle())
                Button("Mark read") { model.perform(.markRead) }.buttonStyle(QuietButtonStyle())
                Button("Star") { model.perform(.star) }.buttonStyle(QuietButtonStyle())
                Menu("Snooze") {
                    ForEach(SnoozePreset.allCases, id: \.self) { preset in
                        Button(preset.title) { model.snooze(until: preset.date()) }
                    }
                }
                .fixedSize()
                Button("Trash") { model.perform(.trash) }.buttonStyle(QuietButtonStyle())
            }
            Text("E, U, S, H and # work on the selection too. Esc clears it.").font(TypeScale.label).foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What a message's attachment chips can do; the model fetches and writes the files.
struct AttachmentActions: Sendable {
    var open: @MainActor @Sendable (AttachmentInfo) -> Void
    var save: @MainActor @Sendable (AttachmentInfo) -> Void
    var file: @MainActor @Sendable (AttachmentInfo) async throws -> URL
}

/// One file: click opens it, drag it out, or Save As from the menu.
struct AttachmentChip: View {
    let file: AttachmentInfo
    let actions: AttachmentActions?
    @State private var isHovered = false

    var body: some View {
        Button { actions?.open(file) } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(file.mimeType)).font(.system(size: 11)).foregroundStyle(Ink.tertiary)
                Text(file.filename).font(TypeScale.label).foregroundStyle(Ink.secondary).lineLimit(1)
                if let size = file.size {
                    Text(size.formatted(.byteCount(style: .file))).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(isHovered ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Line.edge))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .tip("Open \(file.filename)")
        .contextMenu {
            Button("Open") { actions?.open(file) }
            Button("Save As…") { actions?.save(file) }
        }
        .onDrag { dragItem() }
    }

    /// Hands the file over lazily, so dragging doesn't wait for a download that may not be needed.
    private func dragItem() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.filename
        let type = UTType(mimeType: file.mimeType) ?? .data
        let actions = actions
        let file = file
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    guard let url = try await actions?.file(file) else { completion(nil, false, MailError.connectionClosed); return }
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    static func symbol(_ mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType.contains("zip") { return "doc.zipper" }
        return "doc"
    }
}

/// A meeting invitation: when, where, join, add to calendar, and an answer for the organizer.
struct InviteCard: View {
    let model: MailModel
    let thread: MailThread
    let invite: CalendarInvite

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: Space.m) {
                VStack(spacing: 0) {
                    Text(invite.start.map { $0.formatted(.dateTime.month(.abbreviated)) }?.uppercased() ?? "")
                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 15).background(Status.danger)
                    Text(invite.start.map { $0.formatted(.dateTime.day()) } ?? "–")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(Ink.primary).frame(maxHeight: .infinity)
                }
                .frame(width: 42, height: 46)
                .background(Paper.sheet)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Line.edge))
                VStack(alignment: .leading, spacing: 3) {
                    Text(invite.isCancelled ? String(localized: "Canceled: \(invite.summary)") : invite.summary)
                        .font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                    Text(when).font(TypeScale.row).foregroundStyle(Ink.secondary)
                    if let location = invite.location, !location.isEmpty {
                        Text(location).font(TypeScale.label).foregroundStyle(Ink.tertiary).lineLimit(1)
                    }
                    if let organizer = invite.organizer {
                        Text("From \(organizer.displayName)").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                    }
                }
                Spacer()
            }
            MeetingGuests(attendees: guests)
            if !invite.isCancelled && invite.method != "REPLY" {
                // One row when it fits; on a narrow screen, the answers move to a row of their own.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s) {
                        actions
                        Spacer()
                        answers
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(spacing: Space.s) { actions }
                        HStack(spacing: Space.s) { answers }
                    }
                }
            }
        }
        .padding(14)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: invite.uid) { await model.refreshAnswers(invite.uid) }
    }

    @ViewBuilder
    private var actions: some View {
        if let join = invite.joinURL {
            Button("Join") { HTMLWebCoordinator.openInBrowser(join) }.buttonStyle(PillButtonStyle(prominent: true))
        }
        if model.hasDaybook {
            Button("Open in Daybook") { model.openInDaybook(invite) }.buttonStyle(PillButtonStyle())
        } else {
            Button("Add to Calendar") { model.addToCalendar(invite) }.buttonStyle(PillButtonStyle())
        }
    }

    @ViewBuilder
    private var answers: some View {
        if invite.organizer != nil && invite.method == "REQUEST" {
            ForEach(CalendarInvite.Response.allCases, id: \.self) { response in
                let chosen = model.rsvps[invite.uid] == response
                Button(chosen ? "✓ " + Self.label(response) : Self.label(response)) { model.respond(to: invite, in: thread, with: response) }
                    .buttonStyle(PillButtonStyle(prominent: chosen))
            }
        }
    }

    /// The meeting's guests with the latest answers known: the calendar's copy when there is
    /// one (updated by replies), else the invitation's own list.
    private var guests: [MeetingAttendee] {
        model.calendarEntries.first { $0.id == invite.uid }?.attendees ?? invite.attendees
    }

    private var when: String {
        guard let start = invite.start else { return String(localized: "Time not given") }
        if invite.isAllDay { return String(localized: "\(start.formatted(.dateTime.weekday(.wide).day().month(.wide))) · all day") }
        let day = start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end = invite.end else { return "\(day) · \(from)" }
        return "\(day) · \(from) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    static func label(_ response: CalendarInvite.Response) -> String {
        switch response {
        case .accepted: String(localized: "Accept")
        case .tentative: String(localized: "Maybe")
        case .declined: String(localized: "Decline")
        }
    }
}
