import MailCore
import SwiftUI

/// Who's coming: a one-line tally that opens into everyone invited with their answer.
struct MeetingGuests: View {
    let attendees: [MeetingAttendee]
    var startsOpen = false
    @State private var open: Bool?

    private var isOpen: Bool { open ?? startsOpen }

    var body: some View {
        let people = attendees.filter { $0.kind != .room }
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button { open = !isOpen } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2").foregroundStyle(Ink.tertiary)
                        Text(verbatim: Self.summary(attendees)).foregroundStyle(Ink.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Ink.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .font(TypeScale.label)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: Self.summary(attendees)))
                if isOpen {
                    ForEach(attendees) { guest in
                        HStack(spacing: Space.s) {
                            if guest.kind == .room {
                                Image(systemName: "door.left.hand.open").frame(width: 20).foregroundStyle(Ink.tertiary)
                            } else {
                                Avatar(guest.address, size: 20)
                            }
                            Text(verbatim: guest.address.displayName).font(TypeScale.row).foregroundStyle(Ink.primary).lineLimit(1)
                            if guest.kind == .optional {
                                Text("Optional").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                            }
                            Spacer(minLength: Space.s)
                            Self.answer(guest.response)
                        }
                    }
                }
            }
        }
    }

    /// "3 yes · 1 maybe · 2 no answer"
    static func summary(_ attendees: [MeetingAttendee]) -> String {
        let tally = attendees.tally
        var parts: [String] = []
        if tally.yes > 0 { parts.append(String(localized: "\(tally.yes) yes")) }
        if tally.maybe > 0 { parts.append(String(localized: "\(tally.maybe) maybe")) }
        if tally.no > 0 { parts.append(String(localized: "\(tally.no) no")) }
        if tally.waiting > 0 { parts.append(String(localized: "\(tally.waiting) no answer")) }
        return parts.joined(separator: " · ")
    }

    static func answer(_ response: CalendarInvite.Response?) -> some View {
        let (text, symbol, color): (String, String, Color) = switch response {
        case .accepted: (String(localized: "Going"), "checkmark.circle.fill", Status.done)
        case .tentative: (String(localized: "Maybe"), "questionmark.circle.fill", Ink.secondary)
        case .declined: (String(localized: "Not going"), "xmark.circle.fill", Status.danger)
        case nil: (String(localized: "No answer"), "circle.dotted", Ink.tertiary)
        }
        return Label(text, systemImage: symbol).font(TypeScale.label).foregroundStyle(color).labelStyle(.titleAndIcon)
    }
}

/// A meeting with no message to open (one sent from here): when, where, and who's coming.
struct MeetingDetail: View {
    let model: MailModel
    let id: CalendarEntry.ID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let entry = model.calendarEntries.first(where: { $0.id == id }) {
                    Section {
                        LabeledContent("When") {
                            Text(verbatim: entry.start.formatted(date: .abbreviated, time: .shortened) + " – "
                                 + entry.finish.formatted(date: .omitted, time: .shortened))
                        }
                        if let place = entry.location, !place.isEmpty { LabeledContent("Where") { Text(verbatim: place) } }
                        if let join = entry.joinURL {
                            Button("Join") { HTMLWebCoordinator.openInBrowser(join) }
                        }
                        if model.hasDaybook {
                            Button("Open in Daybook") { model.openInDaybook(entry) }
                        }
                    }
                    Section {
                        MeetingGuests(attendees: entry.attendees, startsOpen: true)
                    } header: {
                        Text("Guests")
                    } footer: {
                        Text("Answers come in as people reply, and straight from Microsoft 365 or Google when the account's calendar is connected.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: model.calendarEntries.first { $0.id == id }?.title ?? ""))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.refreshAnswers(id) }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}

struct ShownMeeting: Identifiable { let id: String }
