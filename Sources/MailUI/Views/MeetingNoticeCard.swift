import MailCore
import SwiftUI

/// A calendar's automatic notice as one line: who answered what, and a button to the meeting
/// on the web when the notice has one. The original text is a click away.
struct MeetingNoticeCard: View {
    let notice: MeetingNotice
    let who: String
    let showText: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: notice.title).font(TypeScale.rowStrong).foregroundStyle(Ink.primary).lineLimit(2)
                    Text(verbatim: line).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                }
                Spacer(minLength: Space.s)
                if let link = notice.link {
                    Button(isOutlook(link) ? "Open in Outlook" : "Open event") { openURL(link) }
                        .buttonStyle(PillButtonStyle())
                }
            }
            Button("Show message", action: showText)
                .buttonStyle(.plain)
                .font(TypeScale.label)
                .foregroundStyle(Ink.tertiary)
        }
        .padding(Space.m)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    private var line: String {
        switch notice.kind {
        case .accepted: String(localized: "\(who) accepted")
        case .tentative: String(localized: "\(who) might come")
        case .declined: String(localized: "\(who) declined")
        case .cancelled: String(localized: "Cancelled by \(who)")
        }
    }

    private var symbol: String {
        switch notice.kind {
        case .accepted: "checkmark"
        case .tentative: "questionmark"
        case .declined: "xmark"
        case .cancelled: "calendar.badge.minus"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .accepted: Status.done
        case .tentative: Status.star
        case .declined, .cancelled: Status.danger
        }
    }

    private func isOutlook(_ url: URL) -> Bool { url.host()?.lowercased().contains("outlook") == true }
}
