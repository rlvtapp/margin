import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Margin's language. On the Mac, picked right here (or left to follow the Mac), used from the
/// next start; on iPhone and iPad, changed where the system keeps each app's language.
struct LanguageSetting: View {
    @Environment(\.openURL) private var openURL

    /// "English (Canada)", "Nederlands"…: the language Margin is showing now, in that language.
    static var current: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    #if os(macOS)
    /// The language chosen in Margin, or nil to follow the Mac. Kept as the app's own
    /// `AppleLanguages`, which macOS reads when Margin starts.
    @State private var chosen: String? = LanguageSetting.override
    @State private var needsRestart = false

    static var override: String? {
        guard UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil else { return nil }
        return (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first
    }

    /// The languages Margin is translated into, each named in itself, sorted by that name.
    static var available: [(code: String, name: String)] {
        Bundle.main.localizations.filter { $0 != "Base" }.map { code in
            let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
            return (code, name.prefix(1).uppercased() + name.dropFirst())
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: Space.s) {
            if needsRestart {
                Button("Restart Margin") { Self.relaunch() }
            }
            Picker("Language", selection: Binding(get: { chosen ?? "" }, set: { choose($0.isEmpty ? nil : $0) })) {
                Text("Same as Mac").tag("")
                Divider()
                ForEach(Self.available, id: \.code) { language in
                    Text(verbatim: language.name).tag(language.code)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func choose(_ code: String?) {
        chosen = code
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        needsRestart = true
    }

    /// Opens a fresh Margin and quits this one, so the new language is used everywhere.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    #else
    var body: some View {
        HStack(spacing: Space.s) {
            Text(verbatim: Self.current).foregroundStyle(.secondary)
            Button("Change…") { openSettings() }
        }
    }
    #endif

    private func openSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { openURL(url) }
        #endif
    }
}
