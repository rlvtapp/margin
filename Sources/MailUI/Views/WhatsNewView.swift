import SwiftUI

/// What's New: the notes for this version on top, earlier versions folded below. Opens once after
/// Margin updates, and from Settings → About. The app icon and plain rows, like Apple's own
/// "What's New" sheets.
struct WhatsNewView: View {
    let model: MailModel
    /// The version to lead with; the running one unless a snapshot picks another.
    var version: String = Changelog.currentVersion
    @Environment(\.dismiss) private var dismiss

    private var latest: ChangelogRelease? {
        Changelog.release(version) ?? Changelog.releases.first
    }

    private var earlier: [ChangelogRelease] {
        Changelog.releases.filter { $0.version != latest?.version }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    AppIconPreview(choice: model.appIcon, dark: model.appIconDark, size: 64)
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
                    Text("What's New in Margin")
                        .font(.system(size: Look.size(24), weight: .bold))
                        .foregroundStyle(Ink.primary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                    if let latest {
                        Text("Version \(latest.version)")
                            .font(TypeScale.label.monospacedDigit())
                            .foregroundStyle(Ink.tertiary)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(latest.changes) { ChangeRow(change: $0) }
                        }
                        .padding(.top, 28)
                    }
                    if !earlier.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(earlier) { release in
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 14) {
                                        ForEach(release.changes) { ChangeRow(change: $0, compact: true) }
                                    }
                                    .padding(.top, 10)
                                } label: {
                                    Text("Version \(release.version)")
                                        .font(TypeScale.rowStrong)
                                        .foregroundStyle(Ink.secondary)
                                }
                            }
                        }
                        .padding(.top, 32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 36)
                .padding(.bottom, 20)
            }
            Button {
                dismiss()
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Ink.primary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 36)
            .padding(.bottom, 28)
            .padding(.top, 8)
        }
        .background(Paper.sheet)
        #if os(macOS)
        .frame(width: 460, height: 600)
        #endif
    }
}

/// One change: a coloured symbol tile, what it is, and a sentence on what it does for you.
struct ChangeRow: View {
    let change: ChangelogRelease.Change
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: change.symbol)
                .font(.system(size: compact ? 13 : 16, weight: .semibold))
                .foregroundStyle(Palette.account(change.hue))
                .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
                .background(Palette.account(change.hue).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: change.title)
                    .font(compact ? TypeScale.rowStrong : .system(size: Look.size(15), weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text(verbatim: change.detail)
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#if os(macOS)
/// What's New on its own, for snapshots (`-snapshot-whats-new`).
public struct WhatsNewSnapshot: View {
    let model: MailModel
    public init(model: MailModel) { self.model = model }
    public var body: some View { WhatsNewView(model: model, version: Changelog.releases.first?.version ?? "") }
}
#endif

/// Settings → What's New: every version, newest first, each under its date.
struct ChangelogSettings: View {
    var body: some View {
        Form {
            SettingsHeader(.changelog)
            ForEach(Changelog.releases) { release in
                Section {
                    ForEach(release.changes) { change in
                        ChangeRow(change: change, compact: true).padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        Text("Version \(release.version)")
                        Spacer()
                        if release.version == Changelog.release(Changelog.currentVersion)?.version {
                            Text("This version").foregroundStyle(Ink.tertiary)
                        } else if let date = Changelog.date(of: release.version) {
                            Text(verbatim: date).foregroundStyle(Ink.tertiary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
