import Foundation
import MailCore

/// How far a question has got, shown in place of the answer until it's done.
public enum AskProgress: Equatable, Sendable {
    case searching
    case reading(Int)
    /// The answer as written so far.
    case writing(String)
}

/// One Ask conversation: questions, answers and the mail each answer came from.
public struct AskChat: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var turns: [AskTurn] = []
    public var date = Date()
    /// The first question, as the chat's name.
    public var title: String { turns.first?.question ?? "" }
}

public struct AskTurn: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var question: String
    public var answer: String
    public var isError = false
    /// The conversations the answer cites, kept so they can be opened later.
    public var sources: [AskSource] = []
}

public struct AskSource: Codable, Hashable, Sendable {
    public var threadID: String
    public var accountID: UUID?
    public var messages: [MailMessage]

    public var thread: MailThread { MailThread(id: threadID, messages: messages, accountID: accountID) }
}

/// What can be typed after a slash in Ask.
public enum AskCommand: String, CaseIterable, Sendable {
    case catchup, waiting, summarize, reply, cleanup, help

    public var title: String {
        switch self {
        case .catchup: String(localized: "Catch up on unread mail from people")
        case .waiting: String(localized: "Mail waiting for an answer")
        case .summarize: String(localized: "Summarize the open conversation")
        case .reply: String(localized: "Draft a reply to the open conversation")
        case .cleanup: String(localized: "Newsletters you rarely open")
        case .help: String(localized: "What Ask can do")
        }
    }

    /// Commands matching what's been typed after the slash.
    public static func matching(_ text: String) -> [AskCommand] {
        guard text.hasPrefix("/") else { return [] }
        let typed = text.dropFirst().lowercased()
        return allCases.filter { $0.rawValue.hasPrefix(typed) }
    }
}

extension MailModel {
    public var currentAskChat: AskChat? {
        askChats.first { $0.id == currentAskChatID }
    }

    /// Runs a question or a slash command in the current chat.
    public func send(askInput text: String) {
        loadAskChatsIfNeeded()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("/"), let command = AskCommand(rawValue: String(trimmed.dropFirst()).split(separator: " ").first.map(String.init) ?? "") {
            run(command)
        } else {
            ask(trimmed)
        }
    }

    /// A question typed into search: a new Ask chat answers it, with the conversations it used.
    public func askFromSearch(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        newAskChat()
        isAsking = true
        send(askInput: question)
    }

    /// Whether search should offer to ask this instead: an assistant is on and it reads as a question.
    public func offersAsk(for text: String) -> Bool {
        isAssistantOn && SearchQuery.looksLikeQuestion(text)
    }

    public func newAskChat() {
        currentAskChatID = nil
        askAnswer = nil
        askSources = []
    }

    public func openAskChat(_ chat: AskChat) {
        currentAskChatID = chat.id
    }

    public func deleteAskChat(_ chat: AskChat) {
        askChats.removeAll { $0.id == chat.id }
        if currentAskChatID == chat.id { currentAskChatID = nil }
        saveAskChats()
    }

    /// Archives the conversations an answer came from, after the person tapped to approve.
    public func archive(_ sources: [AskSource]) {
        let threads = sources.map(\.thread).compactMap { source in inboxThreads(nil).first { $0.id == source.id } }
        guard !threads.isEmpty else {
            notice = Notice(text: String(localized: "Those are already out of your inbox."))
            return
        }
        Task { await apply(.done, to: threads, announce: true) }
    }

    public func markRead(_ sources: [AskSource]) {
        let threads = sources.map(\.thread).compactMap { source in inboxThreads(nil).first { $0.id == source.id } }
        guard !threads.isEmpty else { return }
        Task { await apply(.markRead, to: threads, announce: false) }
    }

    func recordAsk(_ question: String, answer: String, sources: [MailThread], isError: Bool = false) {
        loadAskChatsIfNeeded()
        let turn = AskTurn(question: question, answer: answer, isError: isError,
                           sources: sources.map { AskSource(threadID: $0.id, accountID: $0.accountID,
                                                            messages: $0.messages.map { var m = $0; m.body = nil; return m }) })
        if let index = askChats.firstIndex(where: { $0.id == currentAskChatID }) {
            askChats[index].turns.append(turn)
            askChats[index].date = Date()
            let chat = askChats.remove(at: index)
            askChats.insert(chat, at: 0)
        } else {
            let chat = AskChat(turns: [turn])
            currentAskChatID = chat.id
            askChats.insert(chat, at: 0)
        }
        if askChats.count > 50 { askChats.removeLast(askChats.count - 50) }
        saveAskChats()
    }

    private func run(_ command: AskCommand) {
        let label = "/" + command.rawValue
        switch command {
        case .help:
            recordAsk(label, answer: AskCommand.allCases.filter { $0 != .help }.map { "/\($0.rawValue): \($0.title)" }.joined(separator: "\n"), sources: [])
        case .waiting:
            Task {
                let waiting = await waitingThreads(nil)
                let text = waiting.isEmpty
                    ? String(localized: "Nothing is waiting for an answer.")
                    : String(localized: "\(waiting.count) sent emails haven't been answered yet.")
                recordAsk(label, answer: text, sources: Array(waiting.prefix(8)))
            }
        case .cleanup:
            let rarely = newsletterSuggestions
            let text = rarely.isEmpty
                ? String(localized: "You open the newsletters you get. Nothing to clean up.")
                : rarely.map { String(localized: "\($0.name): you opened \($0.opened) of \($0.received)") }.joined(separator: "\n")
            recordAsk(label, answer: text, sources: rarely.map(\.latest))
        case .catchup:
            let unread = inboxThreads(nil).filter { $0.isUnread && $0.split == .people }
            guard !unread.isEmpty else {
                recordAsk(label, answer: String(localized: "No unread mail from people."), sources: [])
                return
            }
            ask(String(localized: "Catch me up: what do these unread emails from people say, and what do they ask of me? One line each."),
                restrictedTo: Array(unread.prefix(8)), shownAs: label)
        case .summarize:
            guard let thread = selectedThread else {
                recordAsk(label, answer: String(localized: "Open a conversation first."), sources: [], isError: true)
                return
            }
            ask(String(localized: "Summarize this conversation in a few lines, and say what I'm asked to do."), restrictedTo: [thread], shownAs: label)
        case .reply:
            guard selectedThread != nil else {
                recordAsk(label, answer: String(localized: "Open a conversation first."), sources: [], isError: true)
                return
            }
            isAsking = false
            writeReply(.draft(note: nil))
        }
    }

    /// Asks about specific conversations instead of searching for them.
    func ask(_ question: String, restrictedTo threads: [MailThread], shownAs label: String) {
        guard let intelligence else { return }
        assistantWork.insert("ask")
        askProgress = .reading(threads.count)
        Task {
            defer { assistantWork.remove("ask"); askProgress = nil }
            let context = await askContext(threads)
            let me = accounts.first?.address ?? EmailAddress(address: "me@example.com")
            do {
                let answer = try await intelligence.ask(question, about: context, me: me) { [weak self] text in
                    await MainActor.run { self?.askProgress = .writing(text) }
                }
                recordAsk(label, answer: answer.text, sources: threads)
            } catch {
                recordAsk(label, answer: error.localizedDescription, sources: [], isError: true)
            }
        }
    }

    private var askFile: JSONFile<[AskChat]> {
        JSONFile(url: environment.folder.appending(path: "ask-chats.json"))
    }

    func loadAskChatsIfNeeded() {
        guard !askChatsLoaded else { return }
        askChatsLoaded = true
        if let saved = askFile.load() { askChats = saved }
    }

    private func saveAskChats() {
        askFile.save(askChats)
    }
}
