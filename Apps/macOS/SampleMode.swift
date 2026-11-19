import Foundation
import MailCore
import MailUI

/// `-sample-mail`: Margin with the sample mailboxes, meetings, Calendar app events and reminders
/// instead of yours, as on iPhone and iPad. Its MCP connection has its own settings, token and
/// port (47911), with changes and sending allowed, so `Margin --mcp -sample-mail` talks to it and
/// never to the real app: a way to try every MCP tool end to end without touching real mail.
enum SampleMode {
    static let isOn = CommandLine.arguments.contains("-sample-mail")
    /// The settings suite and Keychain service the sample app and its bridge share.
    static let service = "app.relevate.margin.sample"
    static let port: UInt16 = 47_911

    static var defaults: UserDefaults { UserDefaults(suiteName: service) ?? .standard }

    static func environment() -> MailEnvironment {
        let folder = FileManager.default.temporaryDirectory.appending(path: "margin-sample-\(UUID().uuidString)", directoryHint: .isDirectory)
        return MailEnvironment(
            appName: "Margin",
            accounts: AccountStore(fileURL: folder.appending(path: "accounts.json")),
            keychain: Keychain(service: service),
            oauth: .fromInfoPlist(),
            labels: LabelStore(fileURL: folder.appending(path: "labels.json")),
            defaults: defaults,
            folder: folder,
            isPreview: true
        )
    }

    /// Fills in the sample calendar and opens the connection.
    @MainActor static func start(_ model: MailModel) {
        Task { @MainActor in
            await model.reload()
            await model.findInvites()
            model.addSampleCalendar()
            var settings = ConnectionSettings()
            settings.enabled = true
            settings.allowChanges = true
            settings.allowSending = true
            settings.port = port
            model.applyConnections(settings)
        }
    }
}
