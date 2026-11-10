import Foundation
import MailCore

/// Messages being written are kept on the device as you type (`unsent.json`), so a crash or a
/// quit never loses them: the next launch puts them in Drafts.
struct UnsentMessage: Codable, Equatable {
    var accountID: UUID
    var draft: Draft
}

extension MailModel {
    private var unsentFile: JSONFile<[UnsentMessage]> { JSONFile(url: environment.folder.appending(path: "unsent.json")) }

    /// What's open in the composer and the reply bar, written a moment after the last change.
    func keepUnsent() {
        guard !environment.isPreview else { return }
        unsentSave?.cancel()
        // A message in its Undo Send moment counts too, until it has gone.
        let open = [compose, reply, pendingSend?.state].compactMap { state -> UnsentMessage? in
            guard let state, state.hasContent else { return nil }
            var draft = state.draft
            draft.to = EmailAddress.parseList(state.to) ?? draft.to
            draft.cc = EmailAddress.parseList(state.cc) ?? draft.cc
            return UnsentMessage(accountID: state.accountID, draft: draft)
        }
        unsentSave = Task { [weak self] in
            // Sending or closing clears it at once; typing saves after a short pause.
            if !open.isEmpty { try? await Task.sleep(for: .seconds(1.5)) }
            guard !Task.isCancelled, let self else { return }
            self.unsentFile.save(open)
        }
    }

    /// Messages left unsent when Margin last stopped go to Drafts.
    func recoverUnsent() async {
        let left = unsentFile.load() ?? []
        guard !left.isEmpty else { return }
        var saved = 0
        var kept: [UnsentMessage] = []
        for item in left {
            guard let account = account(item.accountID), let provider = try? provider(for: account) else { continue }
            do {
                try await provider.saveDraft(item.draft)
                saved += 1
            } catch {
                kept.append(item)
            }
        }
        unsentFile.save(kept)
        if saved > 0 {
            notice = Notice(text: saved == 1 ? String(localized: "A message you hadn't sent is in Drafts")
                                             : String(localized: "\(saved) messages you hadn't sent are in Drafts"))
        }
    }
}
