import MailCore
import SwiftUI

extension MailModel {
    /// Minimal's Home is showing: every group, in sections.
    var showsMinimalHome: Bool { layout == .minimal && place.isHome }

}

/// The top of Minimal's Home: the date and how many conversations need you, what not to
/// forget, and a round tab per group.
struct MinimalHomeHeader: View {
    let model: MailModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HomeDateLine(model: model, size: 24)
            if !reminders.isEmpty { dontForget }
            tabs
        }
        .padding(.top, Space.xl)
        .padding(.bottom, Space.s)
    }

    // MARK: Don't forget

    private struct Reminder: Identifiable {
        var id: String
        var symbol: String
        var color: Color
        var text: String
        var threadID: String?
    }

    private var reminders: [Reminder] {
        var list: [Reminder] = []
        for event in model.todaysEvents.prefix(4) {
            let when = event.isAllDay ? String(localized: "Today") : event.start.formatted(date: .omitted, time: .shortened)
            list.append(Reminder(id: event.id, symbol: "calendar", color: Status.danger, text: "\(when): \(event.title)", threadID: event.threadID))
        }
        let waiting = model.waitingCount
        if waiting > 0 {
            list.append(Reminder(id: "waiting", symbol: "hourglass", color: Palette.accent,
                                 text: waiting == 1 ? String(localized: "1 email you sent is still waiting for a reply")
                                     : String(localized: "\(waiting) emails you sent are still waiting for a reply"), threadID: nil))
        }
        let bills = model.unopenedBills
        if !bills.isEmpty {
            list.append(Reminder(id: "bills", symbol: "doc.text", color: Status.star,
                                 text: bills.count == 1 ? String(localized: "1 bill you haven't opened")
                                     : String(localized: "\(bills.count) bills you haven't opened"), threadID: bills.first?.id))
        }
        return list
    }

    private var dontForget: some View {
        HStack(alignment: .top, spacing: Space.m) {
            RoundedRectangle(cornerRadius: 1.5).fill(Status.star).frame(width: 3)
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Don't forget").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                ForEach(reminders) { item in
                    Button {
                        if let event = model.calendarEntries.first(where: { $0.id == item.id }) {
                            model.open(event)
                        } else if let id = item.threadID {
                            model.reveal(id)
                        } else {
                            model.go(to: .waiting(account: nil))
                        }
                    } label: {
                        HStack(spacing: Space.s) {
                            Image(systemName: item.symbol).font(.system(size: 12)).foregroundStyle(item.color).frame(width: 16)
                            Text(verbatim: item.text).font(TypeScale.row).foregroundStyle(Ink.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Tabs

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassChipRow {
                GroupTab(title: String(localized: "All"), symbol: "tray.full", count: model.visibleThreads.count, isOn: true) {
                    model.homeScrollTarget = "home-top"
                }
                ForEach(model.homeGroups, id: \.group.id) { item in
                    GroupTab.group(item.group.name, count: item.count, isOn: false) {
                        model.homeScrollTarget = "group-\(item.group.name)"
                    }
                }
                if model.isSorting, let progress = model.sortingProgress {
                    Button { model.stopSorting() } label: { Text("Sorting \(progress.done) of \(progress.total) · Stop") }
                        .buttonStyle(PillButtonStyle())
                } else {
                    GroupTab(title: String(localized: "Sort now"), symbol: "wand.and.stars", isOn: false) { model.sortNow() }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func tab(_ title: String, count: Int, target: String?) -> some View {
        Button {
            if let target { model.homeScrollTarget = target } else { model.homeScrollTarget = "home-top" }
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: title)
                Text(verbatim: "\(count)").foregroundStyle(target == nil ? Ink.inverse.opacity(0.7) : Ink.tertiary)
            }
        }
        .buttonStyle(PillButtonStyle(prominent: target == nil))
    }
}

/// A conversation on Minimal's Home: who, when, and one line of what they wrote.
struct MinimalRow: View {
    let thread: MailThread
    let isSelected: Bool
    /// Why it matters now, in the margin.
    var note: MarginNote?

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            MarginNoteLabel(note: note).padding(.top, 8)
            Avatar(thread.latest.from, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(verbatim: thread.latest.from.displayName)
                        .font(thread.isUnread ? TypeScale.rowStrong : TypeScale.row)
                        .foregroundStyle(Ink.primary).lineLimit(1)
                    Spacer()
                    Text(RowDate.string(thread.date)).font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary)
                }
                Text(verbatim: thread.latest.snippet.isEmpty ? thread.subject : thread.latest.snippet)
                    .font(TypeScale.row).foregroundStyle(thread.isUnread ? Ink.primary : Ink.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 10)
        .background(isSelected ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A quiet section title on Minimal's Home: "People 9".
struct MinimalSectionHeader: View {
    let section: ListSection

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: section.title)
            Text(verbatim: "\(section.threads.count)")
        }
        .font(TypeScale.row)
        .foregroundStyle(Ink.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.s)
        .padding(.top, Space.l)
        .padding(.bottom, Space.xs)
    }
}
