import MailCore
import SwiftUI

extension SwipeAction {
    /// Its colour behind a swiped row and in Settings.
    var color: Color {
        switch self {
        case .done: Status.done
        case .trash: Status.danger
        case .star: Status.star
        case .read: Palette.accent
        case .snooze: Palette.account(2)
        case .none: Ink.quaternary
        }
    }
}

/// Settings → Swipes: for each direction, a small conversation swiped open to show what it does,
/// the main action to pick as buttons, and an optional second one.
struct SwipeSettings: View {
    @Bindable var model: MailModel

    var body: some View {
        Section {
            SwipeSide(model: model, leading: true)
            SwipeSide(model: model, leading: false)
        } header: {
            Text("Swipes")
        } footer: {
            #if os(macOS)
            Text("Two fingers sideways on a trackpad. A full swipe does the first action.")
            #else
            Text("A full swipe does the first action.")
            #endif
        }
        #if os(macOS)
        Section {
            Toggle(isOn: Binding(get: { model.showsHoverActions }, set: { model.showsHoverActions = $0 })) {
                SettingLabel("Buttons on hover", detail: "Done, Mark read and Move to Trash at the end of a conversation while the pointer is over it.")
            }
        }
        #endif
    }
}

private struct SwipeSide: View {
    @Bindable var model: MailModel
    let leading: Bool

    private var actions: [SwipeAction] { leading ? model.leadingSwipes : model.trailingSwipes }

    private func set(_ index: Int, _ value: SwipeAction) {
        var list = actions
        list[index] = value
        // Nothing first and something second: move it up, so a full swipe does it.
        if list[0] == .none, list[1] != .none { list = [list[1], .none] }
        if list[0] == list[1], list[0] != .none { list[1] = .none }
        withAnimation(Motion.quick) {
            if leading { model.leadingSwipes = list } else { model.trailingSwipes = list }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(leading ? "Swipe right" : "Swipe left").font(.headline)
            SwipePreview(actions: actions.filter { $0 != .none }, leading: leading)
            HStack(spacing: 6) {
                ForEach(SwipeAction.allCases) { action in
                    ActionChoice(action: action, isOn: actions[0] == action) { set(0, action) }
                }
            }
            if actions[0] != .none {
                HStack {
                    Text("Second action").foregroundStyle(.secondary)
                    Spacer()
                    Picker(selection: Binding(get: { actions[1] }, set: { set(1, $0) })) {
                        ForEach(SwipeAction.allCases.filter { $0 != actions[0] }) { Text($0.title).tag($0) }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// One action to pick: its coloured capsule when chosen, a quiet one when not, its name under it.
private struct ActionChoice: View {
    let action: SwipeAction
    let isOn: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 5) {
                Image(systemName: action.symbol)
                    .font(.system(size: Look.size(13), weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Ink.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Look.gap(30))
                    .background(isOn ? action.color : Fill.one, in: Capsule())
                Text(verbatim: action == .read ? String(localized: "Read") : action.title)
                    .font(.system(size: Look.size(11), weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? Ink.primary : Ink.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A conversation swiped open: its actions as capsules where the row has moved away.
private struct SwipePreview: View {
    let actions: [SwipeAction]
    let leading: Bool

    var body: some View {
        let open = CGFloat(actions.count) * 76
        HStack(spacing: 0) {
            if leading { capsules.frame(width: open) }
            row
            if !leading { capsules.frame(width: open) }
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Line.hairline))
        .animation(Motion.quick, value: actions)
    }

    private var capsules: some View {
        HStack(spacing: 0) {
            ForEach(leading ? actions : actions.reversed()) { action in
                VStack(spacing: 4) {
                    Image(systemName: action.symbol)
                        .font(.system(size: Look.size(12), weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 26)
                        .background(action.color, in: Capsule())
                    Text(verbatim: action == .read ? String(localized: "Read") : action.title)
                        .font(.system(size: Look.size(10), weight: .medium))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// A pretend conversation: a face and two lines.
    private var row: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.account(4).opacity(0.7)).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Ink.secondary.opacity(0.5)).frame(width: 90, height: 7)
                RoundedRectangle(cornerRadius: 3).fill(Ink.tertiary.opacity(0.35)).frame(height: 6)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.panel)
        .overlay(alignment: leading ? .leading : .trailing) {
            Rectangle().fill(Line.hairline).frame(width: 1)
        }
    }
}
