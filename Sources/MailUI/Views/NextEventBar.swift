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
                Text(happening ? String(localized: "Now") : event.start.formatted(date: .omitted, time: .shortened))
                    .font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary)
                Spacer(minLength: 0)
                if let join = event.joinURL, happening || close {
                    Button("Join") { openURL(join) }.buttonStyle(QuietButtonStyle())
                } else {
                    Button("Open") { model.open(event) }.buttonStyle(QuietButtonStyle())
                }
            }
            .padding(.horizontal, Space.m)
            .frame(height: 36)
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
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let event = model.nextEvent {
            let now = Date()
            let happening = event.start <= now
            let close = event.start.timeIntervalSince(now) < 10 * 60
            HStack(spacing: 6) {
                Button { model.open(event) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(happening ? Status.done : Ink.tertiary)
                        Text(verbatim: event.title).font(TypeScale.label.weight(.medium)).foregroundStyle(Ink.primary).lineLimit(1)
                        Text(happening ? String(localized: "now") : event.start.formatted(date: .omitted, time: .shortened))
                            .font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if let join = event.joinURL, happening || close {
                    Button("Join") { openURL(join) }
                        .buttonStyle(.plain)
                        .font(TypeScale.label.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Palette.accent, in: Capsule())
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, event.joinURL != nil && (happening || close) ? 3 : 10)
            .frame(height: 28)
            .glassCapsule(tint: nil)
            .frame(maxWidth: 320)
            .help(event.location ?? event.title)
        }
    }
}
