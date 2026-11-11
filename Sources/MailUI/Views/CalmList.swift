import MailCore
import SwiftUI

/// A titled run of conversations in the Spark and Minimal layouts.
struct ListSection: Identifiable {
    var id: String
    var title: String
    var threads: [MailThread]
}

extension MailModel {
    /// Spark: one list grouped by day, Today first.
    func daySections(_ threads: [MailThread]) -> [ListSection] {
        let calendar = Calendar.current
        let now = Date()
        func bucket(_ date: Date) -> (Int, String) {
            if calendar.isDateInToday(date) { return (0, String(localized: "Today")) }
            if calendar.isDateInYesterday(date) { return (1, String(localized: "Yesterday")) }
            if let week = calendar.dateInterval(of: .weekOfYear, for: now), week.contains(date) { return (2, String(localized: "This week")) }
            return (3, String(localized: "Earlier"))
        }
        var sections: [Int: ListSection] = [:]
        for thread in threads {
            let (order, title) = bucket(thread.date)
            sections[order, default: ListSection(id: "day-\(order)", title: title, threads: [])].threads.append(thread)
        }
        return sections.keys.sorted().compactMap { sections[$0] }
    }

    /// Home: what needs you first (the conversations with a note: a reply owed, a meeting, a
    /// bill, a code), then everything else by day.
    func homeSections(_ threads: [MailThread]) -> [ListSection] {
        let now = Date()
        let needs = threads.filter { marginNote(for: $0, now: now) != nil }
        let ids = Set(needs.map(\.id))
        var sections: [ListSection] = []
        if !needs.isEmpty {
            sections.append(ListSection(id: "home-needs", title: String(localized: "Needs you"), threads: needs))
        }
        sections += daySections(threads.filter { !ids.contains($0.id) })
        return sections
    }

    /// Minimal's Home: a section per group, in the order of the groups (what needs you first),
    /// then everything not sorted yet as "More that can wait".
    func groupSections(_ threads: [MailThread]) -> [ListSection] {
        var remaining = threads
        var sections: [ListSection] = []
        for group in emailGroups {
            let inGroup = remaining.filter { thread in labels(for: thread).contains { $0.caseInsensitiveCompare(group.name) == .orderedSame } }
            guard !inGroup.isEmpty else { continue }
            let ids = Set(inGroup.map(\.id))
            remaining.removeAll { ids.contains($0.id) }
            sections.append(ListSection(id: "group-\(group.name)", title: group.name, threads: inGroup))
        }
        if !remaining.isEmpty {
            sections.append(ListSection(id: "group-more", title: String(localized: "More that can wait"), threads: remaining))
        }
        return sections
    }

    /// The sections the list shows, or nil for one plain list.
    func listSections(_ threads: [MailThread]) -> [ListSection]? {
        switch layout {
        case .spark: return daySections(threads)
        // On iPhone and iPad Home keeps its own header (not Minimal's), so it leads with what
        // needs you there too.
        #if os(macOS)
        case .minimal where place.isHome: return groupSections(threads)
        #else
        case .minimal where place.isHome: return homeSections(threads)
        #endif
        case .panels where place.isHome, .wide where place.isHome: return homeSections(threads)
        default: return nil
        }
    }
}

/// The top of the Tabs layout: the date line, today's events, and tabs with unread counts.
struct SparkHeader: View {
    let model: MailModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HomeDateLine(model: model)
            if !model.todaysEvents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.todaysEvents.prefix(3)) { event in
                        HStack(spacing: Space.s) {
                            Circle().fill(Status.done).frame(width: 6, height: 6)
                            Text(verbatim: event.isAllDay ? String(localized: "All day") : event.start.formatted(date: .omitted, time: .shortened))
                                .font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary)
                            Text(verbatim: event.title).font(TypeScale.row).foregroundStyle(Ink.secondary).lineLimit(1)
                        }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                GlassChipRow {
                    GroupTab(title: String(localized: "Inbox"), symbol: "tray", count: model.unreadCount(account: nil),
                             isOn: isInbox && !model.quickFilters.contains(.unread)) {
                        model.quickFilters.remove(.unread)
                        model.go(to: .allInboxes)
                    }
                    GroupTab(title: String(localized: "Unread"), symbol: "circle.inset.filled", color: Palette.accent, count: nil,
                             isOn: isInbox && model.quickFilters.contains(.unread)) {
                        model.go(to: .allInboxes)
                        model.quickFilters.insert(.unread)
                    }
                    ForEach(model.allLabels.prefix(10), id: \.self) { label in
                        let unread = model.inboxThreads(nil).filter { thread in
                            thread.isUnread && model.labels(for: thread).contains(label)
                        }.count
                        GroupTab.group(label, count: unread, isOn: model.place == .home(group: label)) {
                            model.quickFilters.remove(.unread)
                            model.go(to: .home(group: label))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(.bottom, Space.s)
        }
        .padding(.top, Space.s)
    }

    private var isInbox: Bool {
        if case .inbox(nil, nil) = model.place { return true }
        return false
    }

    private func tab(_ title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(verbatim: title)
                if let count, count > 0 { Text(verbatim: "\(count)").foregroundStyle(selected ? Ink.inverse.opacity(0.7) : Ink.tertiary) }
            }
        }
        .buttonStyle(PillButtonStyle(prominent: selected))
    }
}

/// A section title in the Spark and Minimal lists.
struct ListSectionHeader: View {
    let section: ListSection

    var body: some View {
        // Soft headings: they divide the page without shouting.
        HStack(spacing: Space.xs) {
            Text(verbatim: section.title).font(TypeScale.label.weight(.semibold)).foregroundStyle(Ink.secondary)
            Text(verbatim: "\(section.threads.count)").font(TypeScale.label).foregroundStyle(Ink.tertiary)
            Spacer()
        }
        .padding(.horizontal, Space.s)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.xs)
    }
}

extension View {
    /// In Spark and Minimal the list sits in a readable column in the middle.
    @ViewBuilder
    func calmColumn(_ on: Bool) -> some View {
        if on { frame(maxWidth: 820).frame(maxWidth: .infinity) } else { self }
    }
}

/// Each group's icon and colour, for its tab and its label.
enum GroupStyle {
    static func symbol(_ name: String) -> String {
        let starters = EmailGroup.starters.map(\.name)
        let symbols = ["person.2", "person.3", "briefcase", "creditcard", "receipt", "shippingbox", "airplane",
                       "calendar", "doc.text", "gearshape", "newspaper", "tag"]
        if let index = starters.firstIndex(of: name) { return symbols[index] }
        return "tag"
    }

    static func color(_ name: String) -> Color {
        Palette.account(LabelColors.index(for: name))
    }

    /// The label's colour for its name written on its tint, readable at AA.
    static func textColor(_ name: String) -> Color {
        Palette.accountText(LabelColors.index(for: name))
    }
}

/// Each label's colour: the one you picked (right-click a label → Color), else the starter
/// group's own, else one worked out from the name that stays the same on every launch and device.
enum LabelColors {
    /// Picked colours by lowercased label name, set from the model before drawing.
    nonisolated(unsafe) static var chosen: [String: Int] = [:]

    /// The palette's colours in order, for the Color menu.
    static var names: [String] {
        [String(localized: "Blue"), String(localized: "Green"), String(localized: "Violet"), String(localized: "Amber"),
         String(localized: "Pink"), String(localized: "Cyan"), String(localized: "Red"), String(localized: "Lime")]
    }

    static func index(for name: String) -> Int {
        let key = name.lowercased()
        if let picked = chosen[key] { return picked }
        if let starter = EmailGroup.starters.firstIndex(where: { $0.name.lowercased() == key }) { return starter % names.count }
        // A stable hash (Swift's own changes every launch, which shuffled colours).
        var hash: UInt32 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return Int(hash % UInt32(names.count))
    }

    /// Changes whenever a colour is picked, so the window redraws.
    static var signature: String { chosen.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") }
}

/// A tab in Home, Spark and Minimal: a Liquid Glass chip with the group's icon and colour.
struct GroupTab: View {
    let title: String
    var symbol: String?
    var color: Color?
    var count: Int?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassChip(Text(verbatim: title), symbol: symbol, color: color, tint: color ?? Palette.pickedGlass, count: count, isOn: isOn)
        }
        .buttonStyle(.plain)
    }

    /// A tab for a group or label, styled by its name.
    static func group(_ name: String, count: Int?, isOn: Bool, action: @escaping () -> Void) -> GroupTab {
        GroupTab(title: name, symbol: GroupStyle.symbol(name), color: GroupStyle.color(name), count: count, isOn: isOn, action: action)
    }
}
