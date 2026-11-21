import Foundation
import MailCore

/// When Margin quit unexpectedly (docs/crash-reports.md): macOS writes a crash report, and at the
/// next launch Margin asks whether to send it. Yes opens the normal composer to Margin's inbox,
/// from your own mailbox, with the report attached for you to look at or remove. Nothing is sent
/// or collected otherwise; Margin tracks nothing.
extension MailModel {
    static let crashCheckedKey = "crash.checkedAt"

    /// Looks for a report newer than the last look; the first launch only notes the time.
    func checkForCrash(in folder: URL = MailModel.crashReportFolder, bundleID: String? = Bundle.main.bundleIdentifier, now: Date = Date()) {
        let defaults = environment.defaults
        let last = defaults.object(forKey: Self.crashCheckedKey) as? Date
        defaults.set(now, forKey: Self.crashCheckedKey)
        guard let last, let bundleID else { return }
        pendingCrashReport = Self.crashReports(in: folder, bundleID: bundleID, after: last).first
    }

    /// Margin's own crash reports in `folder` written after `date`, newest first: the report's
    /// first line names the app it's from, so other apps and other builds of Margin (the
    /// screenshot tool) are left out.
    static func crashReports(in folder: URL, bundleID: String, after date: Date) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified > date, Self.crashReport(url, isFrom: bundleID) else { return nil }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func crashReport(_ url: URL, isFrom bundleID: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        guard let line = String(decoding: head, as: UTF8.self).split(separator: "\n").first,
              let header = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
        return header["bundleID"] as? String == bundleID
    }

    /// Where macOS keeps the crash reports of your own apps.
    static var crashReportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
    }

    /// The composer to Margin's inbox with the report attached and a line to say what happened.
    public func sendCrashReport() {
        guard let url = pendingCrashReport else { return }
        pendingCrashReport = nil
        startFeedback(String(localized: "Margin quit unexpectedly. What were you doing just before?"), problem: true)
        if let data = try? Data(contentsOf: url) {
            compose?.draft.attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: "application/json", data: data))
        }
    }
}
