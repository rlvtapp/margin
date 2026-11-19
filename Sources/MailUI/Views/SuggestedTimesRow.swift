import MailCore
import SwiftUI

/// "Suggested times" for an event with people (docs/calendar.md): up to five chips with times
/// that suit everyone; picking one moves the event there, keeping its length. Under it, anyone
/// busy at the time now chosen. The row keeps its height while it looks, so the form doesn't jump.
struct SuggestedTimesRow: View {
    let model: MailModel
    let people: [EmailAddress]
    let destination: EventDestination?
    @Binding var start: Date
    @Binding var end: Date
    /// Off where the form already says who's busy (New Meeting).
    var showsBusy = true
    /// Only your busy time in these calendars counts; nil for every one shown.
    var counting: Set<String>? = nil
    /// Off where the form gives the row its own heading.
    var showsTitle = true

    /// Nil while looking.
    @State private var times: [SuggestedTime]?
    @State private var busy: [EmailAddress] = []

    #if os(iOS)
    private static let rowHeight: CGFloat = 36
    #else
    private static let rowHeight: CGFloat = 26
    #endif

    private var length: TimeInterval { max(end.timeIntervalSince(start), 15 * 60) }
    private var lookupKey: String {
        people.map { $0.address.lowercased() }.joined(separator: ",") + "|\(Int(length))|\(destination?.id ?? "")|"
            + (counting.map { $0.sorted().joined(separator: ",") } ?? "all")
    }
    private var busyKey: String { lookupKey + "|\(start.timeIntervalSinceReferenceDate)|\(end.timeIntervalSinceReferenceDate)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text("Suggested times")
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.secondary)
            }
            chips
                .frame(height: Self.rowHeight, alignment: .leading)
            ForEach(showsBusy ? busy : [], id: \.address) { person in
                Label(String(localized: "\(person.displayName) is busy then"), systemImage: "exclamationmark.circle")
                    .foregroundStyle(Status.danger)
            }
        }
        .task(id: lookupKey) {
            times = nil
            // Waits for typing to settle before asking anyone's calendar.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await model.suggestTimes(with: people, length: length, in: destination, counting: counting)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { times = found }
        }
        .task(id: busyKey) {
            guard showsBusy else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.busyPeople(people, from: start, to: end, in: destination)
            guard !Task.isCancelled else { return }
            busy = found
        }
    }

    @ViewBuilder private var chips: some View {
        if let times {
            if times.isEmpty {
                Text("No time when everyone's free in the next two weeks")
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassChipRow {
                        ForEach(times) { time in
                            Button { pick(time) } label: {
                                GlassChip(Text(verbatim: Self.label(time.start)), isOn: time.start == start)
                            }
                            .buttonStyle(.plain)
                            .help(Text(Self.detail(time)))
                            .accessibilityHint(Text(Self.detail(time)))
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollClipDisabled()
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for times…")
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }

    private func pick(_ time: SuggestedTime) {
        let keep = length
        start = time.start
        end = time.start.addingTimeInterval(keep)
    }

    /// "Tomorrow, 10:00" for today and tomorrow, "Fri 14:30" within the week, "28 Nov, 9:00" after.
    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) || calendar.isDateInTomorrow(date) {
            let formatter = DateFormatter()
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// Who's free then and whose calendar couldn't be seen, for the pointer and VoiceOver.
    static func detail(_ time: SuggestedTime) -> String {
        var parts: [String] = []
        if !time.busy.isEmpty {
            parts.append(String(localized: "Busy: \(time.busy.map(\.displayName).formatted(.list(type: .and)))"))
        }
        if !time.unknown.isEmpty {
            parts.append(String(localized: "Calendar not visible: \(time.unknown.map(\.displayName).formatted(.list(type: .and)))"))
        }
        if parts.isEmpty { parts.append(String(localized: "Everyone's free")) }
        return parts.joined(separator: "\n")
    }
}
