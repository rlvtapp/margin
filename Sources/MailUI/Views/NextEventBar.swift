import MailCore
import SwiftUI

/// The next meeting from an invitation, above the list: what, when, and Join once it's close.
struct NextEventBar: View {
    let model: MailModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let event = model.nextEvent {
            let now = Date()
            let happening = event.start <= now
            let close = event.start.timeIntervalSince(now) < 10 * 60
            HStack(spacing: Space.s) {
                Image(systemName: "calendar").foregroundStyle(happening ? Status.done : Ink.tertiary)
                Text(verbatim: event.title).font(TypeScale.rowStrong).foregroundStyle(Ink.primary).lineLimit(1)
                Text(happening ? String(localized: "Now", table: "Calendar") : event.start.formatted(date: .omitted, time: .shortened))
                    .font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary)
                Spacer(minLength: 0)
                if let join = event.joinURL, happening || close {
                    Button(String(localized: "Join", table: "Calendar")) { openURL(join) }.buttonStyle(QuietButtonStyle())
                } else {
                    Button(String(localized: "Open", table: "Calendar")) { model.open(event) }.buttonStyle(QuietButtonStyle())
                }
            }
            .padding(.horizontal, Space.m)
            .frame(height: Look.gap(36))
            .background(Fill.one, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.s)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The next meeting as a small chip at the top right of the Mac window: what, when, and Join.
struct NextEventChip: View {
    let model: MailModel
    @Environment(\.mailAccent) private var accent
    @Environment(\.mailAccentInk) private var accentInk
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let event = model.nextEvent {
            let now = Date()
            let happening = event.start <= now
            let close = event.start.timeIntervalSince(now) < 10 * 60
            HStack(spacing: 6) {
                Button { model.open(event) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: Look.size(11), weight: .semibold))
                            .foregroundStyle(happening ? Status.done : Ink.tertiary)
                        Text(verbatim: event.title).font(TypeScale.label.weight(.medium)).foregroundStyle(Ink.primary).lineLimit(1)
                        Text(happening ? String(localized: "now", table: "Calendar") : event.start.formatted(date: .omitted, time: .shortened))
                            .font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if let join = event.joinURL, happening || close {
                    Button(String(localized: "Join", table: "Calendar")) { openURL(join) }
                        .buttonStyle(.plain)
                        .font(TypeScale.label.weight(.semibold))
                        .foregroundStyle(accentInk)
                        .padding(.horizontal, 10)
                        .frame(height: Look.gap(22))
                        .background(accent, in: Capsule())
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, event.joinURL != nil && (happening || close) ? 3 : 10)
            .frame(height: Look.gap(28))
            .glassCapsule(tint: nil)
            // Any spare width goes on the left, so the chip sits right beside the icons after it.
            .frame(maxWidth: 320, alignment: .trailing)
            .tip(event.location ?? event.title)
        }
    }
}
