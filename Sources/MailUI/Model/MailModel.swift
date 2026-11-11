import Foundation
import MailCore
import Observation
import SwiftUI

/// Where the list is pointed. A nil account means every account together.
public enum Place: Hashable, Sendable {
    case inbox(account: UUID?, split: InboxSplit?)
    case starred(account: UUID?)
    case mailbox(account: UUID, Mailbox)
    /// One kind of folder from every mailbox at once: all Sent, all Drafts, all Trash.
    case combined(MailboxRole)
    /// Conversations snoozed until later (kept on this device).
    case snoozed(account: UUID?)
    /// Mail you sent that nobody has answered yet.
    case waiting(account: UUID?)
    /// Messages scheduled to send later.
    case scheduled
    /// Every newsletter from every mailbox, with how much of each was opened.
    case subscriptions
    /// Results from saved mail and every server.
    case search(String)
    /// A greeting, what not to forget today, and the inbox by group (nil: everything).
    case home(group: String?)
    /// Mail from the people marked as VIPs.
    case vips(account: UUID?)
    /// Meetings from invitations in the mail, and from calendars Margin may read.
    case calendar

    public static let allInboxes = Place.inbox(account: nil, split: nil)

    /// The folders "All" combines, in sidebar order.
    public static let combinedRoles: [MailboxRole] = [.drafts, .sent, .archive, .junk, .trash]

    public var accountID: UUID? {
        switch self {
        case .inbox(let account, _), .starred(let account): account
        case .mailbox(let account, _): account
        case .snoozed(let account), .waiting(let account), .vips(let account): account
        case .combined, .scheduled, .subscriptions, .search, .home, .calendar: nil
        }
    }

    /// Sent and Drafts: lists of mail you wrote, so rows name who it went to.
    public var isOutgoing: Bool {
        let role: MailboxRole? = switch self {
        case .combined(let role): role
        case .mailbox(_, let mailbox): mailbox.role
        default: nil
        }
        return role == .sent || role == .drafts
    }

    /// Lists that live in folders and are fetched when opened, not kept like inboxes.
    var isFolder: Bool {
        switch self {
        case .mailbox, .combined, .waiting: true
        default: false
        }
    }

    var isDraftsFolder: Bool {
        switch self {
        case .combined(.drafts): true
        case .mailbox(_, let mailbox): mailbox.role == .drafts
        default: false
        }
    }

    /// Inbox views, where snoozed conversations are hidden until they're due.
    var isInbox: Bool {
        switch self {
        case .inbox, .starred, .home, .vips: true
        default: false
        }
    }

    /// Combined views show which account each conversation belongs to.
    public var isCombined: Bool { accountID == nil }
}

/// Settings the app target supplies: where accounts and secrets are kept, OAuth ids.
/// `@unchecked` only for `UserDefaults`, which is documented as thread-safe.
public struct MailEnvironment: @unchecked Sendable {
    public var appName: String
    public var accounts: AccountStore
    public var keychain: Keychain
    public var oauth: OAuthClientRegistry
    public var labels: LabelStore
    /// Where assistant and connection settings are kept.
    public var defaults: UserDefaults
    /// Where snoozes and the outbox are kept.
    public var folder: URL
    /// Previews and snapshots don't post notifications.
    public var isPreview: Bool
    /// Mail kept on this device.
    public var cache: MailCache

    public init(appName: String, accounts: AccountStore, keychain: Keychain, oauth: OAuthClientRegistry,
                labels: LabelStore? = nil, defaults: UserDefaults = .standard, folder: URL? = nil, isPreview: Bool = false) {
        self.appName = appName
        self.accounts = accounts
        self.keychain = keychain
        self.oauth = oauth
        self.labels = labels ?? .standard(appName: appName)
        self.defaults = defaults
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: appName, directoryHint: .isDirectory)
        self.isPreview = isPreview
        cache = MailCache(url: isPreview ? nil : self.folder.appending(path: "mail.sqlite"))
    }

    /// The app's own: mailboxes and settings on this device, secrets in the Keychain.
    public static var standard: MailEnvironment {
        MailEnvironment(
            appName: "Margin",
            accounts: .standard(appName: "Margin"),
            keychain: Keychain(service: Bundle.main.bundleIdentifier ?? "app.relevate.margin"),
            oauth: .fromInfoPlist()
        )
    }

    /// In memory only: the sample accounts, no saved files.
    public static func preview() -> MailEnvironment {
        MailEnvironment(
            appName: "Margin",
            accounts: AccountStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "margin-preview-\(UUID()).json")),
            keychain: Keychain(service: "margin.preview"),
            oauth: .fromInfoPlist(),
            labels: LabelStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "margin-preview-labels-\(UUID()).json")),
            defaults: UserDefaults(suiteName: "margin.preview.\(UUID().uuidString)") ?? .standard,
            folder: FileManager.default.temporaryDirectory.appending(path: "margin-preview-\(UUID().uuidString)", directoryHint: .isDirectory),
            isPreview: true
        )
    }
}

/// A short message at the bottom of the window, optionally with Undo.
public struct Notice: Identifiable, Equatable {
    public let id = UUID()
    public var text: String
    /// What Undo (Z) would take back, if anything.
    public var undo: UndoKind?
    public var isError = false
    /// While a message waits to go out: from now until it sends, drawn as a ring that fills.
    public var countdown: ClosedRange<Date>?
    public var canUndo: Bool { undo != nil }

    public init(text: String, undo: UndoKind? = nil, isError: Bool = false, countdown: ClosedRange<Date>? = nil) {
        self.text = text
        self.undo = undo
        self.isError = isError
        self.countdown = countdown
    }
}

public enum UndoKind: Equatable, Sendable {
    case change, send, snooze
}



/// All accounts' mail, side by side. Each account talks to its own server directly.
@MainActor @Observable
public final class MailModel {
    public let environment: MailEnvironment
    public internal(set) var accounts: [MailAccount]
    public internal(set) var mailboxes: [UUID: [Mailbox]] = [:]
    public internal(set) var inboxes: [UUID: [MailThread]] = [:]
    /// The open folder when the place is a mailbox.
    public internal(set) var folder: [MailThread] = [] {
        // Archiving or deleting in a folder updates what's remembered for it too.
        didSet { if place.isFolder, !folder.isEmpty || oldValue.count == 1 { folderMemory[place] = folder } }
    }
    /// Message bodies by `BodyKey`.
    public internal(set) var bodies: [String: MessageBody] = [:]
    public internal(set) var loadErrors: [UUID: String] = [:]
    public internal(set) var isLoading = false
    /// A folder (Sent, Archive, a label…) is being fetched for the list.
    public internal(set) var isLoadingFolder = false
    /// Something the list is showing is still downloading, so empty means "not yet", not "none".
    public var isListLoading: Bool {
        isLoading || (isLoadingFolder && !place.isInbox)
    }
    public internal(set) var lastUpdated: Date?

    public var place: Place = .allInboxes
    public var selectedThreadID: MailThread.ID?
    public var searchText = ""
    public var notice: Notice?
    public var collapsedAccounts: Set<UUID> = []
    /// Show HTML mail as plain text instead of its own layout. Each message can still switch.
    public var prefersPlainText: Bool {
        didSet { environment.defaults.set(prefersPlainText, forKey: "prefersPlainText") }
    }
    /// Hides the sidebar for more reading room; the rail stays.
    public var isSidebarHidden = false
    /// Senders whose pictures load without asking (kept on this device only).
    public internal(set) var trustedPictureSenders: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "trustedPictureSenders") ?? [])

    // Overlays
    public var isPaletteOpen = false
    /// Text the palette opens with ("Snooze" when H is pressed).
    public var paletteSeed = ""
    public var isShowingShortcuts = false
    public var isAddingAccount = false
    public var isNewMeetingOpen = false
    public var isShowingOnboarding = false
    /// The meeting shown on its own (one sent from here, with no message to open).
    public var shownMeetingID: String?
    public var compose: ComposeState? {
        didSet {
            if compose != oldValue { keepUnsent() }
            // Starting another message while one is put away keeps the first in Drafts.
            if isComposePutAway, let old = oldValue, compose != nil {
                isComposePutAway = false
                saveToDrafts(old)
            }
            // A new message, or one that's closed, is never put away.
            if compose == nil || oldValue == nil { isComposePutAway = false }
        }
    }
    public var reply: ComposeState? {
        didSet {
            if reply != oldValue { keepUnsent() }
            if isReplyPutAway, let old = oldValue, reply != nil {
                isReplyPutAway = false
                saveToDrafts(old)
            }
            if reply == nil || oldValue == nil { isReplyPutAway = false }
        }
    }
    /// The message being written is tucked into the top bar while you search and read other
    /// mail; it comes back down with everything as it was.
    public var isComposePutAway = false
    public var isReplyPutAway = false
    var unsentSave: Task<Void, Never>?
    /// Bumped to ask the list to take keyboard focus back.
    public var focusRequest = 0
    /// Bumped to ask the search field to take focus.
    public var searchRequest = 0

    // Assistant
    public internal(set) var assistantSettings: AssistantSettings
    public internal(set) var summaries: [MailThread.ID: ThreadSummary] = [:]
    public internal(set) var labelSuggestions: [MailThread.ID: [String]] = [:]
    /// Work in progress: "summary|<thread>", "labels|<thread>", "reply".
    public internal(set) var assistantWork: Set<String> = []
    public internal(set) var labelStore: LabelStore
    var intelligence: MailIntelligence?
    /// The Ask box: open, and its latest answer.
    public var isAsking = false
    public internal(set) var askAnswer: MailAnswer?
    /// Where the question being asked is: searching, reading, or the answer so far.
    public internal(set) var askProgress: AskProgress?
    public internal(set) var askSources: [MailThread] = []
    /// Past Ask conversations, newest first, kept on this device.
    public internal(set) var askChats: [AskChat] = []
    public var currentAskChatID: UUID?
    var askChatsLoaded = false

    // Timing: snoozes, the outbox, undo send, follow-ups
    public internal(set) var snoozes: [String: Date]
    public internal(set) var outbox: [ScheduledMessage]
    public internal(set) var templates: [MailTemplate]
    /// Invitations answered in this session, by event id.
    public internal(set) var rsvps: [String: CalendarInvite.Response] = [:]
    /// Events read from accounts' own calendars (with Calendar access on), by account.
    public internal(set) var calendarEvents: [UUID: [CalendarEvent]] = [:]
    /// The days `calendarEvents` covers.
    @ObservationIgnored var calendarEventsRange: ClosedRange<Date>?
    public internal(set) var waitingCount = 0
    var pendingSend: PendingSend? { didSet { keepUnsent() } }
    var lastSnoozed: [String] = []

    // Newsletters: which issues were opened, and which lists to stop suggesting
    var newsletterState = NewsletterState()
    var newsletterStateLoaded = false
    /// Older issues from the archive, loaded when the clean-up is shown.
    public internal(set) var newsletterHistory: [MailThread] = []
    /// The newsletter whose emails are open in a sheet, by list id.
    public var openSubscriptionID: String?
    /// Bumped when folder order or hiding changes, so views read it again.
    var folderRevision = 0
    var swipeRevision = 0
    var backupRevision = 0

    // How the person writes, learned from what they send (kept on this device)
    public internal(set) var writingProfile = WritingProfile()
    var writingProfileLoaded = false
    public internal(set) var isLearningWriting = false
    /// Short replies offered for an open conversation, by thread id.
    public internal(set) var replySuggestions: [MailThread.ID: [String]] = [:]
    /// The message each conversation's suggestions answer, so a new message gets new ones.
    @ObservationIgnored var replySuggestionsFor: [MailThread.ID: String] = [:]
    /// Offer short replies when mail from a person opens.
    public var suggestsReplies: Bool {
        get { environment.defaults.object(forKey: "suggestsReplies") as? Bool ?? true }
        set { environment.defaults.set(newValue, forKey: "suggestsReplies") }
    }
    /// Learning on or off; drafts follow the profile only while it's on.
    public var learnsWriting: Bool {
        get { environment.defaults.object(forKey: "learnsWriting") as? Bool ?? true }
        set { environment.defaults.set(newValue, forKey: "learnsWriting") }
    }
    var clock: Task<Void, Never>?
    /// One task per mailbox that waits for the server to say new mail arrived (IMAP IDLE).
    var watchers: [UUID: Task<Void, Never>] = [:]
    /// Mailboxes whose server pushes new mail, so the timer can relax for them.
    public internal(set) var pushingAccounts: Set<UUID> = []
    var seenUnread: Set<MailThread.ID>?
    /// Everyone you've written to, from saved mail; refreshed before each round of alerts.
    var correspondents: Set<String> = []
    /// Folders opened this session, so going back shows them at once while they refresh.
    @ObservationIgnored var folderMemory: [Place: [MailThread]] = [:]
    /// Each account's recent Sent mail, so a conversation shows both sides (`conversation(_:)`).
    var sentMail: [UUID: [MailMessage]] = [:] { didSet { sentIndexCache = nil } }
    /// What's been sent, indexed once per change of `sentMail` (see `sentIndex`).
    @ObservationIgnored var sentIndexCache: SentIndex?
    @ObservationIgnored var emailGroupsCache: (revision: Int, groups: [EmailGroup])?
    /// Home's notes per conversation, valid while `key` holds (see `marginNote(for:)`).
    @ObservationIgnored var marginNoteCache: (key: Int, notes: [String: MarginNote?])?
    @ObservationIgnored var sentMailLoaded: [UUID: Date] = [:]
    /// Sign-in codes and links already looked for, by message and whether its body was there.
    @ObservationIgnored var signInCodes: [String: String?] = [:]
    @ObservationIgnored var signInLinks: [String: FoundLink?] = [:]
    struct FoundLink { var url: URL; var kind: SignInLink.Kind }

    // Selection and filters
    public var selection: Set<MailThread.ID> = []
    /// Servers are still being searched for the current search.
    public internal(set) var isSearchingServers = false
    /// The snooze date picker is open.
    public var isPickingSnoozeDate = false
    public var quickFilters: Set<QuickFilter> = []

    // Look and keys
    public var appearance: AppAppearance { didSet { environment.defaults.set(appearance.rawValue, forKey: "appearance") } }
    public var accentIndex: Int { didSet { environment.defaults.set(accentIndex, forKey: "accentIndex") } }
    public var appIcon: AppIconChoice {
        didSet {
            environment.defaults.set(appIcon.rawValue, forKey: "appIcon")
            if appIcon != oldValue { applyAppIcon() }
        }
    }
    public var appIconDark: Bool {
        didSet {
            environment.defaults.set(appIconDark, forKey: "appIconDark")
            if appIconDark != oldValue { applyAppIcon() }
        }
    }
    public var compactRows: Bool { didSet { environment.defaults.set(compactRows, forKey: "compactRows") } }
    /// On the Mac: names beside the icons above a conversation (Done, Reply…), or icons only.
    public var buttonNames: Bool { didSet { environment.defaults.set(buttonNames, forKey: "buttonNames") } }
    /// On the Mac: the list and reader edge to edge on the window, or in a rounded inset panel.
    public var insetPanel: Bool { didSet { environment.defaults.set(insetPanel, forKey: "insetPanel") } }
    /// On the Mac: the Next up column right of the reader, when the window is wide enough.
    public var showsNextUp: Bool { didSet { environment.defaults.set(showsNextUp, forKey: "showsNextUp") } }
    /// Next up (the column, the badge in the top bar and its button) is set aside for now while
    /// it's reworked; the code and the saved preference stay, so turning this back on restores it.
    public static let nextUpAvailable = true
    /// Whether the Next up column is on screen now (it needs the setting, the layout and the room).
    public var isNextUpOnScreen = false
    public var layout: ListLayout {
        didSet {
            environment.defaults.set(layout.rawValue, forKey: "layout")
            // Minimal starts from Home, without the sidebar.
            if layout == .minimal, oldValue != .minimal { place = .home(group: nil) }
        }
    }
    /// In the wide list, a conversation is open over the list.
    public var isReaderOpen = false
    /// The Mac and iPad open the top conversation of a list straight away; an iPhone shows the
    /// list first, since opening one there covers the whole screen.
    public var opensFirstConversation = true
    var firstConversation: MailThread.ID? { opensFirstConversation ? visibleThreads.first?.id : nil }
    // Accessibility
    public var colorBlindSafe: Bool { didSet { environment.defaults.set(colorBlindSafe, forKey: "colorBlindSafe") } }
    public var increaseContrast: Bool { didSet { environment.defaults.set(increaseContrast, forKey: "increaseContrast") } }
    public var underlineLinks: Bool { didSet { environment.defaults.set(underlineLinks, forKey: "underlineLinks") } }
    /// In dark mode, light emails are shown dark (colours turned around, pictures kept).
    public var darkensMail: Bool { didSet { environment.defaults.set(darkensMail, forKey: "darkensMail") } }
    /// Mail in a language the reader doesn't read gets a Translate line above it.
    public var offersTranslation: Bool { didSet { environment.defaults.set(offersTranslation, forKey: "offersTranslation") } }
    /// Messages shown translated, in place.
    public let translations = MessageTranslations()
    public var reduceMotion: Bool { didSet { environment.defaults.set(reduceMotion, forKey: "reduceMotion") } }
    public var singleKeyShortcuts: Bool { didSet { environment.defaults.set(singleKeyShortcuts, forKey: "singleKeyShortcuts") } }
    /// Changed keys: command id → key.
    public var keyOverrides: [String: String] { didSet { environment.defaults.set(keyOverrides, forKey: "keyOverrides") } }

    // Reading and alerts
    public var textScale: Double { didSet { environment.defaults.set(textScale, forKey: "textScale") } }
    public var newMailAlerts: NewMailAlerts { didSet { environment.defaults.set(newMailAlerts.rawValue, forKey: "newMailAlerts") } }
    /// Seconds a sent message waits so it can still be undone.
    public var undoSendDelay: Int { didSet { environment.defaults.set(undoSendDelay, forKey: "undoSendDelay") } }
    public var followUpDays: Int { didSet { environment.defaults.set(followUpDays, forKey: "followUpDays") } }

    // Connections (MCP)
    public internal(set) var connectionSettings: ConnectionSettings
    public internal(set) var connectionActivity: [MCPActivity] = []
    public internal(set) var connectionError: String?
    var mcpServer: MCPHTTPServer?
    /// A device-link file opened from another device, waiting for its password.
    public var pendingDeviceLink: URL?
    /// Bumped when Margin becomes the default mail app, so Settings looks again.
    public var defaultAppRevision = 0
    /// Pinned conversations, loaded on first use.
    var pinStore: Set<String>?
    /// Bumped when pins or VIPs change.
    public var priorityRevision = 0
    /// Junk listed for an AI app by `list_spam`, so `not_spam` can find it.
    var agentJunk: [MailThread] = []
    /// The Home section a group tab asked to scroll to.
    public var homeScrollTarget: String?
    /// Files added to the next Ask question.
    public var askAttachments: [AskAttachment] = []
    /// Bumped when workspaces change.
    public var workspaceRevision = 0
    /// Bumped when sorting groups change.
    public var sortingRevision = 0
    var sortingTask: Task<Void, Never>?
    /// Conversations sorting has looked at, by label key, with the newest message it saw: those
    /// aren't asked about again until something new arrives. Loaded once (see `sortingChecked`).
    @ObservationIgnored var sortingCheckedCache: [String: String]?
    /// How far "Sort now" has come: done, of how many.
    public var sortingProgress: (done: Int, total: Int)?
    /// Counts clock ticks (every 20 seconds), so time-based views refresh.
    public var clockTick = 0
    /// Bumped when the writing instructions change.
    public var writingRevision = 0
    /// Sent messages to check for replies, loaded on first use.
    var replyReminderStore: [ReplyReminder]?
    /// Events from invitations, loaded on first use.
    var calendarStore: [CalendarEntry]?
    var contactStore: [Contact]?
    /// What went wrong with each contact source, keyed like `ContactSourceKey`.
    public internal(set) var contactProblems: [String: String] = [:]
    public internal(set) var isRefreshingContacts = false
    /// What each account's extra API tokens allow (contacts, calendar, rooms).
    public internal(set) var apiAccess: [UUID: Set<APIAccess>] = [:]
    /// Outlook's own reactions read through Graph (opt-in), by `bodyKey`, and when each was read.
    var outlookReactions: [String: [MailReaction]] = [:]
    var outlookReactionsRead: [String: Date] = [:]
    var contactSettingsRevision = 0
    /// Sync with iCloud: why it can't run, when it last ran, and whether it's running.
    public internal(set) var syncProblem: String?
    public internal(set) var lastSync: Date?
    var isSyncing = false
    /// Bumped when alert settings change, so views read them again.
    public var alertRevision = 0
    /// New mail waiting to slide down from the top of the screen (Mac).
    public var dropDownAlert: MailThread?
    /// What was here before the last restore, so it can be undone.
    var restoreUndo: RestoreUndo?
    /// What AI apps changed, newest last, so `undo_last` can put it back. Kept for this run only.
    var agentChanges: [AgentChange] = []
    /// Margin's own assistant taking actions ("Sort my mail"): the latest run, shown with its
    /// steps until dismissed, and the task doing it.
    public internal(set) var agentRun: AgentRun?
    var agentTask: Task<Void, Never>?
    /// The "Ask Margin to…" sheet on iPhone and iPad.
    public var isAgentPromptOpen = false
    /// Bumped when the provider for actions, saved providers or what they support change.
    public var actionSettingsRevision = 0
    /// Sent conversations no longer tracked as waiting for a reply (by LabelStore key).
    var dismissedWaiting: Set<String>?

    var providers: [UUID: any MailProvider] = [:]
    var pendingChange: PendingChange?
    let credentials: KeychainCredentials

    public init(environment: MailEnvironment) {
        self.environment = environment
        // The sample mailboxes only stand in until there's a real one; leftovers go.
        var loaded = environment.accounts.load()
        if loaded.contains(where: { $0.connection != .sample }) && loaded.contains(where: { $0.connection == .sample }) {
            loaded.removeAll { $0.connection == .sample }
            try? environment.accounts.save(loaded)
        }
        accounts = loaded
        credentials = KeychainCredentials(keychain: environment.keychain, oauth: environment.oauth)
        labelStore = environment.labels
        prefersPlainText = environment.defaults.bool(forKey: "prefersPlainText")
        appearance = AppAppearance(rawValue: environment.defaults.string(forKey: "appearance") ?? "") ?? .system
        accentIndex = environment.defaults.object(forKey: "accentIndex") as? Int ?? 0
        appIcon = AppIconChoice(rawValue: environment.defaults.string(forKey: "appIcon") ?? "") ?? .blue
        appIconDark = environment.defaults.bool(forKey: "appIconDark")
        compactRows = environment.defaults.bool(forKey: "compactRows")
        buttonNames = environment.defaults.object(forKey: "buttonNames") as? Bool ?? true
        layout = ListLayout(rawValue: environment.defaults.string(forKey: "layout") ?? "") ?? .panels
        insetPanel = environment.defaults.bool(forKey: "insetPanel")
        showsNextUp = environment.defaults.object(forKey: "showsNextUp") as? Bool ?? true
        singleKeyShortcuts = environment.defaults.object(forKey: "singleKeyShortcuts") as? Bool ?? true
        colorBlindSafe = environment.defaults.bool(forKey: "colorBlindSafe")
        increaseContrast = environment.defaults.bool(forKey: "increaseContrast")
        underlineLinks = environment.defaults.bool(forKey: "underlineLinks")
        darkensMail = environment.defaults.object(forKey: "darkensMail") as? Bool ?? true
        offersTranslation = environment.defaults.object(forKey: "offersTranslation") as? Bool ?? true
        reduceMotion = environment.defaults.bool(forKey: "reduceMotion")
        keyOverrides = environment.defaults.dictionary(forKey: "keyOverrides") as? [String: String] ?? [:]
        let scale = environment.defaults.double(forKey: "textScale")
        textScale = scale == 0 ? 1 : scale
        newMailAlerts = NewMailAlerts(rawValue: environment.defaults.string(forKey: "newMailAlerts") ?? "") ?? .people
        let delay = environment.defaults.object(forKey: "undoSendDelay") as? Int
        undoSendDelay = delay ?? 5
        let days = environment.defaults.object(forKey: "followUpDays") as? Int
        followUpDays = days ?? 3
        snoozes = JSONFile<[String: Date]>(url: environment.folder.appending(path: "snoozes.json")).load() ?? [:]
        outbox = JSONFile<[ScheduledMessage]>(url: environment.folder.appending(path: "outbox.json")).load() ?? []
        templates = JSONFile<[MailTemplate]>(url: environment.folder.appending(path: "templates.json")).load() ?? MailTemplate.examples
        let saved = environment.defaults.data(forKey: "assistantSettings")
            .flatMap { try? JSONDecoder().decode(AssistantSettings.self, from: $0) }
        assistantSettings = saved ?? .initial
        connectionSettings = environment.defaults.data(forKey: "connectionSettings")
            .flatMap { try? JSONDecoder().decode(ConnectionSettings.self, from: $0) } ?? ConnectionSettings()
        rebuildIntelligence()
        SafeHTMLCache.blocksTrackers = environment.defaults.object(forKey: "blocksTrackers") as? Bool ?? true
        if layout == .minimal { place = .home(group: nil) }
    }

    // MARK: Reading

    public func account(_ id: UUID?) -> MailAccount? {
        accounts.first { $0.id == id }
    }

    /// The account new mail is written from: the one in view, or the first.
    public var currentAccount: MailAccount {
        account(place.accountID) ?? account(selectedThread?.accountID) ?? accounts[0]
    }

    public var title: String {
        switch place {
        case .inbox: String(localized: "Inbox")
        case .starred: String(localized: "Starred")
        case .mailbox(_, let mailbox): mailbox.name
        case .combined(let role): role.title
        case .snoozed: String(localized: "Snoozed")
        case .waiting: String(localized: "Waiting for reply")
        case .scheduled: String(localized: "Scheduled")
        case .subscriptions: String(localized: "Subscriptions")
        case .calendar: String(localized: "Calendar")
        case .home(let group): group ?? String(localized: "Home")
        case .vips: String(localized: "VIPs")
        case .search(let text): String(localized: "“\(text)”")
        }
    }

    /// The inbox part shown by the list's tabs, when the place is an inbox.
    public var split: InboxSplit?? {
        if case .inbox(_, let split) = place { return .some(split) }
        return nil
    }

    public func inboxThreads(_ accountID: UUID?) -> [MailThread] {
        if let accountID { return inboxes[accountID] ?? [] }
        return accounts.flatMap { inboxes[$0.id] ?? [] }.sorted { $0.date > $1.date }
    }

    public var visibleThreads: [MailThread] {
        var source: [MailThread] = switch place {
        case .inbox(let account, let split): allInboxesThreads(account).filter { split == nil || $0.split == split }
        case .starred(let account): allInboxesThreads(account).filter(\.isStarred)
        case .snoozed(let account): allInboxesThreads(account).filter { isSnoozed($0) }
        case .mailbox, .combined, .waiting, .search: folder
        case .scheduled, .subscriptions, .calendar: []
        case .vips(let account): vipThreads(account)
        case .home(let group):
            allInboxesThreads(nil).filter { thread in
                group.map { name in labels(for: thread).contains { $0.caseInsensitiveCompare(name) == .orderedSame } } ?? true
            }
        }
        if place.isInbox { source.removeAll { isSnoozed($0) } }
        if quickFilters.contains(.unread) { source.removeAll { !$0.isUnread } }
        if quickFilters.contains(.starred) { source.removeAll { !$0.isStarred } }
        if quickFilters.contains(.attachments) { source.removeAll { !$0.hasAttachments } }
        // Search results were already matched, operators included; filtering again by the
        // words would drop server results whose bodies aren't downloaded yet.
        if case .search = place { return source }
        let query = SearchQuery(searchText)
        let found = query.isEmpty ? source : source.filter(query.matches)
        return place.isInbox ? pinnedFirst(found) : found
    }

    public var selectedThread: MailThread? {
        guard let selectedThreadID else { return nil }
        return visibleThreads.first { $0.id == selectedThreadID }
            ?? (folder + inboxThreads(nil) + newsletterHistory).first { $0.id == selectedThreadID }
    }

    public func unreadCount(account: UUID?, split: InboxSplit? = nil) -> Int {
        allInboxesThreads(account).filter { $0.isUnread && (split == nil || $0.split == split) }.count
    }

    /// One mailbox's inbox, or All Inboxes: every mailbox not left out of it.
    func allInboxesThreads(_ accountID: UUID?) -> [MailThread] {
        guard accountID == nil else { return inboxThreads(accountID) }
        // Only the workspace in view, and not the mailboxes left out of All Inboxes.
        let shown = Set(workspaceAccounts.filter { $0.inAllInboxes != false }.map(\.id))
        guard shown.count != accounts.count else { return inboxThreads(nil) }
        return inboxThreads(nil).filter { shown.contains($0.accountID ?? UUID()) }
    }

    /// An account's folders other than its inbox, in a familiar order.
    public func folders(of accountID: UUID) -> [Mailbox] {
        let order: [MailboxRole] = [.drafts, .sent, .archive, .all, .junk, .trash, .other]
        return (mailboxes[accountID] ?? []).filter { $0.role != .inbox && $0.role != .flagged }
            .sorted { (order.firstIndex(of: $0.role) ?? 9, $0.name) < (order.firstIndex(of: $1.role) ?? 9, $1.name) }
    }

    public func body(of message: MailMessage, in thread: MailThread) -> MessageBody? {
        bodies[Self.bodyKey(thread.accountID, message.id)]
    }

    static func bodyKey(_ accountID: UUID?, _ messageID: String) -> String {
        "\(accountID?.uuidString ?? "-")|\(messageID)"
    }

    public func start() async {
        // Avatars everywhere ask this model for people's pictures.
        ContactPictures.shared.load = { [weak self] address in await self?.pictureData(for: address) }
        if !hasOnboarded && !environment.isPreview { isShowingOnboarding = true }
        await forgetRemovedAccounts()
        pruneLearnedAliases()
        await loadSavedMail()
        // Your Sent mail, so Home knows what you've already answered (from any app).
        for account in accounts { await loadSavedSentMail(for: account) }
        fillPlaceholderNames()
        await loadAPIAccess()
        if !environment.isPreview { prepareSync(); await recoverUnsent() }
        await syncNow()
        await reload()
        // Meetings from invitations anywhere in saved mail, without holding up the rest.
        Task { await findInvites() }
        await refreshCalendar()
        await refreshContacts()
        await learnProviderAliases()
        await refreshNewsletterHistory()
        await learnFromSentMailIfNew()
    }

    /// Fetches every account's folders and inbox at once.
    public func reload() async {
        isLoading = true
        defer { isLoading = false }
        struct Loaded: Sendable {
            var id: UUID
            var mailboxes: [Mailbox] = []
            var threads: [MailThread] = []
            var error: String?
        }
        var jobs: [(UUID, any MailProvider)] = []
        for account in accounts {
            do { jobs.append((account.id, try provider(for: account))) } catch { loadErrors[account.id] = error.localizedDescription }
        }
        let results = await withTaskGroup(of: Loaded.self) { group in
            for (id, provider) in jobs {
                group.addTask {
                    do {
                        let boxes = try await provider.mailboxes()
                        guard let inbox = boxes.first(where: { $0.role == .inbox }) else {
                            return Loaded(id: id, mailboxes: boxes, error: String(localized: "This account has no inbox."))
                        }
                        return Loaded(id: id, mailboxes: boxes, threads: try await provider.threads(in: inbox, limit: 200))
                    } catch {
                        return Loaded(id: id, error: error.localizedDescription)
                    }
                }
            }
            var all: [Loaded] = []
            for await result in group { all.append(result) }
            return all
        }
        for result in results {
            loadErrors[result.id] = result.error
            // Offline or failing: keep showing saved mail instead of an empty inbox.
            guard result.error == nil else { continue }
            mailboxes[result.id] = result.mailboxes
            inboxes[result.id] = result.threads.map { Self.tag($0, account: result.id) }
            await environment.cache.saveMailboxes(result.mailboxes, account: result.id)
            if let inbox = result.mailboxes.first(where: { $0.role == .inbox }) {
                await environment.cache.saveThreads(result.threads, account: result.id, mailbox: inbox.id)
            }
        }
        lastUpdated = Date()
        applyInboxRules()
        correspondents = await environment.cache.correspondents(of: Set(accounts.flatMap(\.sendAddresses).map { $0.address.lowercased() }))
        notifyAboutNewMail()
        // The top of the list is read ahead, so those conversations open instantly.
        Task { await readAhead() }
        #if os(iOS) && canImport(WatchConnectivity)
        WatchBridge.shared.push()
        #endif
        if #available(iOS 18.0, macOS 15.0, *) {
            SiriBridge.model = self
            Task { await SiriBridge.index(self) }
        }
        if place.isFolder { await loadFolder(for: place) }
        if selectedThread == nil { selectedThreadID = firstConversation }
        await loadBodies()
    }

    /// Thread ids are only unique within one account, so they carry the account's id.
    nonisolated static func tag(_ thread: MailThread, account: UUID) -> MailThread {
        var copy = thread
        copy.accountID = account
        copy.id = "\(account.uuidString)|\(thread.id)"
        return copy
    }

    public func go(to place: Place) {
        self.place = place
        // A folder still loading for the place left behind doesn't count here.
        isLoadingFolder = false
        searchText = ""
        reply = nil
        if place.isFolder {
            folder = folderMemory[place] ?? []
            selectedThreadID = nil
            Task {
                await loadFolder(for: place)
                selectedThreadID = firstConversation
                await loadBodies()
            }
        } else {
            selectedThreadID = firstConversation
            Task { await loadBodies() }
        }
        focusRequest += 1
    }

    /// Fetches one account's folder, or the same kind of folder from every account at once.
    private func loadFolder(for place: Place) async {
        isLoadingFolder = true
        defer { if self.place == place { isLoadingFolder = false } }
        if case .waiting(let account) = place {
            let waiting = await waitingThreads(account)
            if self.place == place { folder = waiting }
            return
        }
        var jobs: [(UUID, any MailProvider, Mailbox)] = []
        switch place {
        case .mailbox(let accountID, let mailbox):
            if let account = account(accountID), let provider = try? provider(for: account) {
                jobs.append((accountID, provider, mailbox))
            }
        case .combined(let role):
            for account in accounts {
                guard let mailbox = combinedMailbox(role, of: account.id), let provider = try? provider(for: account) else { continue }
                jobs.append((account.id, provider, mailbox))
            }
        default:
            return
        }
        // What was downloaded last time shows at once; the server's answer replaces it.
        var saved: [MailThread] = []
        for (accountID, _, mailbox) in jobs {
            saved += await environment.cache.threads(account: accountID, mailbox: mailbox.id).map { Self.tag($0, account: accountID) }
        }
        if !saved.isEmpty, self.place == place, folder.isEmpty {
            folder = saved.sorted { $0.date > $1.date }
            folderMemory[place] = folder
        }
        let answers = await withTaskGroup(of: (UUID, Result<[MailThread], Error>).self) { group in
            for (accountID, provider, mailbox) in jobs {
                group.addTask {
                    do {
                        return (accountID, .success(try await provider.threads(in: mailbox, limit: 200).map { Self.tag($0, account: accountID) }))
                    } catch {
                        return (accountID, .failure(error))
                    }
                }
            }
            var all: [(UUID, Result<[MailThread], Error>)] = []
            for await answer in group { all.append(answer) }
            return all
        }
        let results = answers.map(\.1)
        guard self.place == place else { return } // the person moved on while this loaded
        // A mailbox that couldn't be reached keeps what was saved for it.
        let unreachable = Set(answers.compactMap { answer -> UUID? in if case .failure = answer.1 { answer.0 } else { nil } })
        let fresh = (results.flatMap { (try? $0.get()) ?? [] } + saved.filter { unreachable.contains($0.accountID ?? UUID()) })
            .sorted { $0.date > $1.date }
        // New conversations slide in at the top; the rest stay where they are.
        if fresh.map(\.id) != folder.map(\.id) || fresh != folder {
            withAnimation(reduceMotion || folder.isEmpty ? nil : .easeOut(duration: 0.25)) { folder = fresh }
        }
        folderMemory[place] = fresh
        for (accountID, _, mailbox) in jobs {
            let fetched = folder.filter { $0.accountID == accountID && $0.messages.first?.mailboxID == mailbox.id }
            if !fetched.isEmpty {
                await environment.cache.saveThreads(fetched.map { Self.untagged($0) }, account: accountID, mailbox: mailbox.id)
            }
        }
        if case .failure(let error) = results.first(where: { if case .failure = $0 { true } else { false } }) {
            show(error)
        }
    }

    /// The account's folder of that kind. Archive falls back to all mail, which is how
    /// some providers archive.
    func combinedMailbox(_ role: MailboxRole, of accountID: UUID) -> Mailbox? {
        let boxes = mailboxes[accountID] ?? []
        return boxes.first { $0.role == role } ?? (role == .archive ? boxes.first { $0.role == .all } : nil)
    }

    /// Kinds of folder at least one mailbox has, for the combined sidebar.
    public var combinedRoles: [MailboxRole] {
        Place.combinedRoles.filter { role in accounts.contains { combinedMailbox(role, of: $0.id) != nil } }
    }

    public func select(_ id: MailThread.ID?) {
        guard id != selectedThreadID else { return }
        selectedThreadID = id
        reply = nil
        Task { await loadBodies() }
    }

    /// Moves the selection by one row (j/k).
    public func moveSelection(_ delta: Int) {
        // In the order on screen: sectioned lists (Home, Tabs) differ from the plain order.
        let threads = listSections(visibleThreads)?.flatMap(\.threads) ?? visibleThreads
        guard !threads.isEmpty else { return }
        let index = threads.firstIndex { $0.id == selectedThreadID } ?? -1
        select(threads[min(max(index + delta, 0), threads.count - 1)].id)
    }

    /// Fetches bodies for the selected thread and marks it read once it's on screen.
    /// One message's text from the server, tried a second time after a moment: a dropped
    /// connection shouldn't leave the message blank until you open it again.
    private func fetchBody(of message: MailMessage, from provider: any MailProvider) async -> MessageBody? {
        if let body = try? await provider.body(of: message) { return body }
        try? await Task.sleep(for: .milliseconds(800))
        return try? await provider.body(of: message)
    }

    func loadBodies() async {
        guard let thread = selectedThread, let account = account(thread.accountID),
              let provider = try? provider(for: account) else { return }
        noteNewsletterOpened(thread)
        // Your replies from Sent are stitched in from saved mail at once; the refresh from the
        // server runs alongside instead of holding up the message.
        if sentMail[account.id] == nil {
            await loadSavedSentMail(for: account)
        }
        let shown = conversation(thread).messages.count
        Task {
            await loadSentMail(for: account)
            // Replies that just came in from Sent need their text too.
            if selectedThreadID == thread.id, conversation(thread).messages.count != shown { await loadBodies() }
        }
        // The newest message first: it's the one open on screen.
        for message in conversation(thread).messages.reversed() {
            let key = Self.bodyKey(thread.accountID, message.id)
            guard bodies[key] == nil else { continue }
            if let body = message.body {
                bodies[key] = body
            } else if let saved = await environment.cache.body(of: message.id, account: account.id) {
                bodies[key] = saved
            } else if let body = await fetchBody(of: message, from: provider) {
                bodies[key] = body
                await environment.cache.saveBody(body, of: message, account: account.id)
            }
        }
        noteInvites(in: thread)
        if thread.isUnread, selectedThreadID == thread.id {
            await apply(.markRead, to: [thread], announce: false)
        }
    }

    // MARK: Accounts

    /// Saves the secret, proves the connection works, then keeps the account.
    public func add(_ account: MailAccount, secret: String?) async throws {
        var account = account
        let used = Set(accounts.map(\.colorIndex))
        account.colorIndex = (0..<12).first { !used.contains($0) } ?? accounts.count
        if let secret {
            let kind: String = switch account.auth {
            case .password: "password"
            case .oauth: "oauth"
            case .token: "token"
            }
            try environment.keychain.save(secret, account: account.id, kind: kind)
        }
        do {
            let provider = try ProviderFactory.make(for: account, credentials: credentials)
            _ = try await provider.mailboxes()
            providers[account.id] = provider
        } catch {
            environment.keychain.deleteAll(account: account.id)
            throw error
        }
        // Your first real mailbox replaces the sample ones, mail and all.
        if account.connection != .sample {
            for sample in accounts where sample.connection == .sample {
                providers[sample.id] = nil
                mailboxes[sample.id] = nil
                inboxes[sample.id] = nil
                loadErrors[sample.id] = nil
            }
            accounts.removeAll { $0.connection == .sample }
        }
        accounts.append(account)
        try? environment.accounts.save(accounts)
        if clock != nil { startWatching() }
        go(to: .inbox(account: account.id, split: nil))
        // Access is confirmed; the mail itself comes in the background, so adding is quick.
        Task {
            await forgetRemovedAccounts()
            await reload()
            await loadSavedSentMail(for: account)
        }
    }

    public func remove(_ id: UUID) {
        if let provider = providers.removeValue(forKey: id) {
            Task { await provider.disconnect() }
        }
        environment.keychain.deleteAll(account: id)
        watchers.removeValue(forKey: id)?.cancel()
        pushingAccounts.remove(id)
        accounts.removeAll { $0.id == id }
        mailboxes[id] = nil
        inboxes[id] = nil
        loadErrors[id] = nil
        if accounts.isEmpty {
            accounts = [.sample, .samplePersonal]
            Task { await reload() }
        }
        try? environment.accounts.save(accounts)
        if place.accountID == id { go(to: .allInboxes) }
    }

    public func trustsPictures(from sender: EmailAddress) -> Bool {
        trustedPictureSenders.contains(sender.address.lowercased())
    }

    public func trustPictures(from sender: EmailAddress) {
        trustedPictureSenders.insert(sender.address.lowercased())
        UserDefaults.standard.set(Array(trustedPictureSenders).sorted(), forKey: "trustedPictureSenders")
    }

    public func toggleCollapsed(_ id: UUID) {
        if collapsedAccounts.contains(id) { collapsedAccounts.remove(id) } else { collapsedAccounts.insert(id) }
    }

    // MARK: Helpers

    func provider(for account: MailAccount) throws -> any MailProvider {
        if let provider = providers[account.id] { return provider }
        let provider = try ProviderFactory.make(for: account, credentials: credentials)
        providers[account.id] = provider
        return provider
    }

    public func show(_ error: Error) {
        notice = Notice(text: error.localizedDescription, isError: true)
    }
}

extension MailboxRole {
    public var title: String {
        switch self {
        case .inbox: String(localized: "Inbox")
        case .sent: String(localized: "Sent")
        case .drafts: String(localized: "Drafts")
        case .archive: String(localized: "Archive")
        case .trash: String(localized: "Trash")
        case .junk: String(localized: "Junk")
        case .all: String(localized: "All mail")
        case .flagged: String(localized: "Starred")
        case .other: String(localized: "Folder")
        }
    }
}

public enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark, deepDark, white, developer
    public var title: String {
        switch self {
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        case .deepDark: return String(localized: "Deep dark")
        case .white: return String(localized: "White")
        case .developer: return String(localized: "Developer")
        case .system:
            #if os(macOS)
            return String(localized: "Match the Mac")
            #else
            return String(localized: "Match the system")
            #endif
        }
    }

    /// The light or dark mode this look needs; nil follows the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .white: .light
        case .dark, .deepDark, .developer: .dark
        }
    }
}

public enum ListLayout: String, CaseIterable, Sendable {
    /// List and reader side by side.
    case panels
    /// The list takes the whole width; a conversation opens over it.
    case wide
    /// Side by side, with tabs above the list for the inbox, unread mail and each label,
    /// and today's meetings.
    case spark
    /// Home first, without the sidebar; a conversation opens over the list.
    case minimal

    public var title: String {
        switch self {
        case .panels: String(localized: "Side by side")
        case .wide: String(localized: "Wide list")
        case .spark: String(localized: "Tabs")
        case .minimal: String(localized: "Minimal")
        }
    }

    /// Whether a conversation opens over the list instead of beside it.
    public var opensOverList: Bool { self != .panels }

    /// Spark and Minimal keep the list in a calm, centred column.
    public var isCalm: Bool { self == .spark || self == .minimal }
}
