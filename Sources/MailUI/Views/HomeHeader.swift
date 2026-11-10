import MailCore
import SwiftUI

extension Place {
    var isHome: Bool {
        if case .home = self { return true }
        return false
    }
}

/// The top of Home: today's date and how many conversations need you (the notes in the margin
/// below say why), then a tab per group. No greeting: Home is a page of notes, not a welcome.
struct HomeDateLine: View {
    let model: MailModel
    var size: CGFloat = 22

    var body: some View {
        let count = model.needYouCount
        (Text(verbatim: model.homeDate).foregroundStyle(Ink.primary)
            + Text(verbatim: "  ·  ").foregroundStyle(Ink.quaternary)
            + Text(count == 0 ? String(localized: "nothing needs you")
                : count == 1 ? String(localized: "1 needs you") : String(localized: "\(count) need you"))
                .foregroundStyle(Ink.tertiary))
            .font(.system(size: size, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// The top of Home: the date line, what not to forget today, and a tab per group.
struct HomeHeader: View {
    let model: MailModel
    /// Off where the date already titles the band above (the Mac's list).
    var showsDate = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The day as the page's heading, with room to breathe, and one quiet sentence
            // about what needs you: a page, not a dashboard.
            if showsDate {
                Text(verbatim: model.homeDate)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(verbatim: summary)
                .font(.system(size: 15))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, Space.l)
            // The groups as plain words, the one you're in a little darker.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.l) {
                    textTab(String(localized: "Everything"), count: nil, isOn: model.place == .home(group: nil)) {
                        model.go(to: .home(group: nil))
                    }
                    ForEach(model.homeGroups, id: \.group.id) { item in
                        textTab(item.group.name, count: item.count, isOn: model.place == .home(group: item.group.name)) {
                            model.go(to: .home(group: item.group.name))
                        }
                    }
                    if model.isSorting, let progress = model.sortingProgress {
                        Button { model.stopSorting() } label: { Text("Sorting \(progress.done) of \(progress.total) · Stop") }
                            .buttonStyle(.plain)
                            .font(TypeScale.label)
                            .foregroundStyle(Ink.tertiary)
                    } else {
                        Button { model.sortNow() } label: { Label("Sort now", systemImage: "wand.and.stars") }
                            .buttonStyle(.plain)
                            .font(TypeScale.label)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, model.layout.isCalm ? Space.xs : Space.l)
        .padding(.top, Space.l)
        .padding(.bottom, Space.xs)
    }

    private func textTab(_ title: String, count: Int?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(verbatim: title)
                if let count, count > 0 { Text(verbatim: "\(count)").foregroundStyle(Ink.tertiary) }
            }
            .font(isOn ? TypeScale.rowStrong : TypeScale.row)
            .foregroundStyle(isOn ? Ink.primary : Ink.tertiary)
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Ink.primary).frame(height: 1.5).opacity(isOn ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Two replies to write and a bill to open. Quarterly planning at 10:00." Or, with
    /// nothing waiting, "Nothing needs you right now."
    private var summary: String {
        let now = Date()
        var parts: [String] = []
        let owed = model.allInboxesThreads(nil).filter { !model.isSnoozed($0) && model.owesReply($0, now: now) }.count
        if owed > 0 { parts.append(owed == 1 ? String(localized: "a reply to write") : String(localized: "\(owed) replies to write")) }
        let bills = model.unopenedBills.count
        if bills > 0 { parts.append(bills == 1 ? String(localized: "a bill to open") : String(localized: "\(bills) bills to open")) }
        var sentence = parts.isEmpty ? "" : parts.formatted(.list(type: .and))
        if !sentence.isEmpty { sentence = sentence.prefix(1).uppercased() + sentence.dropFirst() + "." }
        if let next = model.todaysEvents.first(where: { !$0.isAllDay && $0.finish > now }) {
            let time = next.start.formatted(date: .omitted, time: .shortened)
            let line = next.start <= now ? String(localized: "\(next.title) is on now.") : String(localized: "\(next.title) at \(time).")
            sentence = sentence.isEmpty ? line : sentence + " " + line
        }
        return sentence.isEmpty ? String(localized: "Nothing needs you right now.") : sentence
    }

    private func tab(_ title: String, count: Int?, group: String?) -> some View {
        let selected = model.place == .home(group: group)
        return Button {
            // In Minimal, Home shows every group as a section: a tab jumps to it.
            if model.layout == .minimal, let group, model.place == .home(group: nil) {
                model.homeScrollTarget = "group-\(group)"
            } else {
                model.go(to: .home(group: group))
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: title)
                if let count { Text(verbatim: "\(count)").foregroundStyle(selected ? Ink.inverse.opacity(0.7) : Ink.tertiary) }
            }
        }
        .buttonStyle(PillButtonStyle(prominent: selected))
    }
}

