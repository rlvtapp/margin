import Foundation
import MailCore

/// The writing profile: learned from sent mail, used so drafts sound like the person.
extension MailModel {
    /// People in the mail on this device, for suggestions while addressing a message.
    public var addressBook: AddressBook {
        AddressBook(threads: inboxThreads(nil) + folder + newsletterHistory,
                    me: Set(accounts.flatMap(\.sendAddresses).map { $0.address.lowercased() }),
                    contacts: contacts.flatMap(\.addresses))
    }

    /// How many sent emails a fresh profile learns from.
    static let sentMailToLearn = 200

    /// Instructions for the assistant to write like this person to `recipient`, when learning is on
    /// and enough is known. `language` is the conversation's; `languageOf` works it out from one.
    func writingStyle(for recipient: EmailAddress?, account: MailAccount, language: String? = nil) -> String? {
        loadWritingProfileIfNeeded()
        let learned = learnsWriting
            ? writingProfile.styleGuide(for: recipient, myName: EmailAddress.firstName(of: account.address), language: language)
            : nil
        // The person's own rules come last, so they win over what was learned.
        let rules = writingInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = rules.isEmpty ? nil : "Always follow these instructions from the person:\n" + rules
        let parts = [learned, own].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Rules for everything the assistant writes, in the person's words ("No exclamation marks.
    /// Sign off with just my first name.").
    public var writingInstructions: String {
        get { _ = writingRevision; return environment.defaults.string(forKey: "writingInstructions") ?? "" }
        set { environment.defaults.set(newValue, forKey: "writingInstructions"); writingRevision += 1 }
    }

    /// Learns from a message just sent.
    func learnWriting(from draft: Draft, account: MailAccount) {
        loadWritingProfileIfNeeded()
        guard learnsWriting else { return }
        if writingProfile.learn(draft.text, to: draft.to, signature: account.signature) { saveWritingProfile() }
    }

    /// On first start: learns from recent sent mail so drafts sound right from day one.
    func learnFromSentMailIfNew() async {
        loadWritingProfileIfNeeded()
        guard learnsWriting, writingProfile.isEmpty else { return }
        await learnFromSentMail()
    }

    /// Reads up to `sentMailToLearn` sent emails from every mailbox and learns from them.
    /// Emails already learned from are skipped, so running it again only adds new ones.
    public func learnFromSentMail() async {
        loadWritingProfileIfNeeded()
        guard !isLearningWriting else { return }
        isLearningWriting = true
        defer { isLearningWriting = false }
        for account in accounts {
            guard let sent = mailboxes[account.id]?.first(where: { $0.role == .sent }),
                  let provider = try? provider(for: account),
                  let threads = try? await provider.threads(in: sent, limit: Self.sentMailToLearn) else { continue }
            let mine = threads.flatMap(\.messages).filter { $0.from.address.caseInsensitiveCompare(account.address.address) == .orderedSame }
            for message in mine.prefix(Self.sentMailToLearn) {
                let id = message.messageID ?? message.id
                guard !writingProfile.learned.contains(id) else { continue }
                let text: String = if let body = message.body?.text { body } else { (try? await provider.body(of: message).text) ?? "" }
                writingProfile.learn(text, to: message.to, signature: account.signature, id: id, date: message.date)
            }
        }
        saveWritingProfile()
    }

    /// A draft as the person would write it: without dashes when they never use them, since
    /// models add them even when asked not to.
    func inYourStyle(_ text: String, language: String?) -> String {
        loadWritingProfileIfNeeded()
        guard learnsWriting, writingProfile.avoidsDashes(language: language) else { return text }
        return WritingProfile.withoutDashes(text)
    }

    /// The language a conversation is in, from its newest message's words.
    func languageOf(_ thread: MailThread) -> String? {
        let latest = thread.latest
        let text = body(of: latest, in: thread)?.text ?? latest.snippet
        return WritingProfile.language(of: WritingProfile.ownWriting(text, signature: nil).prefix(1_000) + "")
            ?? WritingProfile.language(of: latest.subject + " " + latest.snippet)
    }

    /// Three short replies for mail from a person that's waiting on an answer, written again
    /// whenever a new message arrives; none when the latest message is your own.
    public func suggestReplies(for thread: MailThread) async {
        // Answers to what people wrote, not to their reactions.
        let thread = withoutReactions(thread)
        guard replySuggestionsFor[thread.id] != thread.latest.id else { return }
        replySuggestionsFor[thread.id] = thread.latest.id
        replySuggestions[thread.id] = []
        let mine = Set(accounts.flatMap { [$0.address] + ($0.aliases ?? []) }.map { $0.address.lowercased() })
        guard suggestsReplies, let intelligence, thread.split == .people, let account = account(thread.accountID),
              !mine.contains(thread.latest.from.address.lowercased()) else { return }
        let style = writingStyle(for: thread.latest.from, account: account, language: languageOf(thread))
        let suggestions = (try? await intelligence.suggestReplies(thread, bodies: bodies(of: thread), me: account.address, style: style)) ?? []
        replySuggestions[thread.id] = suggestions.map { inYourStyle($0, language: languageOf(thread)) }
    }

    /// Opens the reply and drafts it from one of the suggestions.
    public func reply(with suggestion: String) {
        startReply()
        writeReply(.draft(note: suggestion))
    }

    public func forgetWriting(to address: String) {
        loadWritingProfileIfNeeded()
        writingProfile.forget(address)
        saveWritingProfile()
    }

    public func resetWritingProfile() {
        writingProfile = WritingProfile()
        saveWritingProfile()
    }

    private var writingFile: JSONFile<WritingProfile> {
        JSONFile(url: environment.folder.appending(path: "writing-profile.json"))
    }

    func loadWritingProfileIfNeeded() {
        // Loaded once at start; reading the property later doesn't change state mid-draw.
        guard !writingProfileLoaded else { return }
        writingProfileLoaded = true
        if let saved = writingFile.load() { writingProfile = saved }
    }

    private func saveWritingProfile() {
        writingFile.save(writingProfile)
    }
}

extension MailModel {
    /// A reply to a pasted email, written the way the person would: for trying out what Margin
    /// learned. Nothing is sent or saved. Also says which language and whose habits it used.
    public func tryReply(to text: String, from sender: String, note: String) async throws -> (reply: String, about: String, instructions: String) {
        guard let intelligence else { throw MailError.notSupported(String(localized: "Turn on the assistant to try this.")) }
        let account = currentAccount
        // Without a sender, the name the email is signed with; without that, no name at all.
        let typedSender = sender.trimmingCharacters(in: .whitespaces)
        let from: EmailAddress? = typedSender.isEmpty
            ? Self.signedName(in: text).map { EmailAddress(name: $0, address: "sender@invalid") }
            : EmailAddress.parseList(typedSender)?.first ?? EmailAddress(name: typedSender, address: "sender@invalid")
        let message = MailMessage(id: "try", mailboxID: "INBOX", messageID: "try@margin",
                                  from: from ?? EmailAddress(name: nil, address: "sender@invalid"), to: [account.address],
                                  subject: "", date: Date(), snippet: String(text.prefix(160)))
        let thread = MailThread(id: "try", messages: [message], accountID: account.id)
        let language = WritingProfile.language(of: text)
        let style = writingStyle(for: from, account: account, language: language)
        var trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if from == nil { trimmedNote += (trimmedNote.isEmpty ? "" : " ") + "The sender's name isn't known: don't address them by name." }
        let written = try await intelligence.write(.draft(note: trimmedNote.isEmpty ? nil : trimmedNote), thread: thread,
                                                   bodies: ["try": MessageBody(text: text)], me: account.address, draft: "", style: style)
        let reply = inYourStyle(written, language: language)
        loadWritingProfileIfNeeded()
        let languageName = language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        let known = language.flatMap { writingProfile.languages[$0]?.messages } ?? 0
        let about: String = if style == nil {
            String(localized: "Not enough learned yet, so this is a plain reply.")
        } else if let languageName, known >= 3 {
            String(localized: "In \(languageName), the way you write in it.")
        } else if let languageName {
            String(localized: "In \(languageName). Margin hasn't seen enough of your \(languageName) yet, so only your general style is used.")
        } else {
            String(localized: "Using your general style.")
        }
        return (reply, about, style ?? String(localized: "Nothing learned yet."))
    }

    /// The name an email is signed with: a short last line that looks like a name ("Sam", "Noor Haddad").
    static func signedName(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last, last.count <= 30 else { return nil }
        let words = last.split(separator: " ")
        guard (1...3).contains(words.count), words.allSatisfy({ $0.first?.isUppercase == true && $0.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" } }) else { return nil }
        return last
    }
}
