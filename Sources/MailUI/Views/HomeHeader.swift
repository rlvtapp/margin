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
            // The groups as glass tabs; the one you're in is filled.
            ScrollView(.horizontal, showsIndicators: false) {
                GlassChipRow {
                    GroupTab(title: String(localized: "Everything"), symbol: "tray.full", isOn: model.place == .home(group: nil)) {
                        model.go(to: .home(group: nil))
                    }
                    ForEach(model.homeGroups, id: \.group.id) { item in
                        GroupTab.group(item.group.name, count: item.count, isOn: model.place == .home(group: item.group.name)) {
                            model.go(to: .home(group: item.group.name))
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
        .padding(.horizontal, model.layout.isCalm ? Space.xs : Space.l)
        .padding(.top, Space.l)
        .padding(.bottom, Space.xs)
    }

    /// The one quiet sentence about what needs you (`MailModel.homeSummary`).
    private var summary: String { model.homeSummary() }

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
