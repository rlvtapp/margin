import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Margin's language: shown here, changed where the system keeps each app's language
/// (iPhone and iPad: Settings → Margin; Mac: System Settings → Language & Region → Applications).
struct LanguageSetting: View {
    @Environment(\.openURL) private var openURL

    /// "English (Canada)", "Nederlands"…: the language Margin is showing now, in that language.
    static var current: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Text(verbatim: Self.current).foregroundStyle(.secondary)
            Button("Change…") { openSettings() }
        }
    }

    private func openSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { openURL(url) }
        #endif
    }
}
