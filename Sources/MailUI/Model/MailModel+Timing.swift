import Foundation
import MailCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Quick filter buttons over the list.
public enum QuickFilter: String, CaseIterable, Sendable {
    case unread, starred, attachments

    public var title: String {
        switch self {
        case .unread: String(localized: "Unread")
        case .starred: String(localized: "Starred")
        case .attachments: String(localized: "Attachments")
        }
    }

    /// The toggle's symbol; ".fill" is added while it's on.
    public var symbol: String {
        switch self {
        case .unread: "envelope.badge"
        case .starred: "star"
        case .attachments: "paperclip.circle"
        }
    }
}

/// Which new mail gets a notification.
public enum NewMailAlerts: String, CaseIterable, Sendable {
    /// Only mail from people you know (contacts, VIPs, people you've written to), and sign-in codes.
    case people
    case all
    /// Only VIPs (and sign-in codes).
    case vips
    case none

    public var title: String {
        switch self {
        case .people: String(localized: "Smart: people you know and sign-in codes")
        case .all: String(localized: "All new mail")
        case .vips: String(localized: "Only VIPs and sign-in codes")
        case .none: String(localized: "None")
        }
    }
}

/// A message on its way out, still inside its undo window.
struct PendingSend {
    var state: ComposeState
    var isReply: Bool
    var threadID: MailThread.ID?
    var task: Task<Void, Never>
}

extension MailModel {
    // MARK: Undo send and send later

    /// Closes the composer at once and sends after the undo window, so Undo can bring the
    /// message back. A failed send reopens it with the error.
    public func queueSend(_ state: ComposeState, isReply: Bool) {
        do { _ = try state.validated() } catch { show(error); return }
        if isReply { reply = nil } else { compose = nil }
        focusRequest += 1
        if let previous = pendingSend {
            pendingSend = nil
            previous.task.cancel()
            Task { _ = await send(previous.state) }
        }
        let delay = max(undoSendDelay, 0)
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let pending = self.pendingSend
            self.pendingSend = nil
            if self.notice?.undo == .send { self.notice = nil }
            if let error = await self.attemptSend(state) {
                if MailError.isConnectionProblem(error), let draft = try? state.validated() {
                    // Offline: it waits in the outbox and goes out once there's a connection.
                    self.outbox.append(ScheduledMessage(accountID: state.accountID, draft: draft, sendAt: Date(), waitsForConnection: true))
                    self.saveOutbox()
                    if let old = state.editedDraft { await self.apply(.trash, to: [old], announce: false) }
                    self.notice = Notice(text: String(localized: "No connection. It'll send as soon as you're back online."))
                } else {
                    self.show(error)
                    if let pending { self.reopen(pending) }
                }
            } else if let old = state.editedDraft {
                await self.apply(.trash, to: [old], announce: false)
            }
        }
        pendingSend = PendingSend(state: state, isReply: isReply, threadID: selectedThreadID, task: task)
        notice = Notice(text: delay > 0 ? String(localized: "Sending…") : String(localized: "Sent"), undo: delay > 0 ? .send : nil)
    }

    func undoSend() {
        guard let pending = pendingSend else { return }
        pending.task.cancel()
        pendingSend = nil
        notice = nil
        reopen(pending)
    }

    private func reopen(_ pending: PendingSend) {
        if pending.isReply, pending.threadID == selectedThreadID {
            reply = pending.state
        } else {
            compose = pending.state
        }
    }

    /// Keeps the message on this Mac and sends it at `date` (while Margin is running).
    public func schedule(_ state: ComposeState, at date: Date, isReply: Bool) {
        let draft: Draft
        do { draft = try state.validated() } catch { show(error); return }
        outbox.append(ScheduledMessage(accountID: state.accountID, draft: draft, sendAt: date))
        outbox.sort { $0.sendAt < $1.sendAt }
        saveOutbox()
        if isReply { reply = nil } else { compose = nil }
        notice = Notice(text: String(localized: "Scheduled for \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))"))
        focusRequest += 1
    }

    public func cancelScheduled(_ id: ScheduledMessage.ID) {
        outbox.removeAll { $0.id == id }
        saveOutbox()
    }

    /// Takes a scheduled message back into the composer.
    public func editScheduled(_ id: ScheduledMessage.ID) {
        guard let item = outbox.first(where: { $0.id == id }), let account = account(item.accountID) else { return }
        cancelScheduled(id)
        var state = ComposeState(account: account, draft: item.draft)
        state.to = item.draft.to.map(\.headerValue).joined(separator: ", ")
        compose = state
    }

    public func sendScheduledNow(_ id: ScheduledMessage.ID) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        outbox[index].sendAt = Date()
        saveOutbox()
        Task { await tick() }
    }

    func saveOutbox() {
        JSONFile<[ScheduledMessage]>(url: environment.folder.appending(path: "outbox.json")).save(outbox)
    }

    // MARK: Snooze

    public func isSnoozed(_ thread: MailThread) -> Bool {
        guard let until = snoozes[LabelStore.key(for: thread)] else { return false }
        return until > Date()
    }

    /// "Checking for mail…", "Offline · showing saved mail", or "Updated 20 minutes ago" once
    /// it's been a while. Blank while everything is fresh.
    public func statusLine(now: Date) -> String {
        if isLoading { return String(localized: "Checking for mail…") }
        if isOffline { return String(localized: "Offline · showing saved mail") }
        guard let updated = lastUpdated else { return " " }
        // Fresh mail needs no note; it only says something once it's been a while.
        if now.timeIntervalSince(updated) < 10 * 60 { return " " }
        return String(localized: "Updated \(updated.formatted(.relative(presentation: .named)))")
    }

    public func snoozedUntil(_ thread: MailThread) -> Date? {
        snoozes[LabelStore.key(for: thread)].flatMap { $0 > Date() ? $0 : nil }
    }

    /// Hides the conversations until `date`; they come back to the inbox then.
    public func snooze(until date: Date) {
        snooze(actionTargets, until: date)
    }

    /// Snoozes one conversation without opening it: a swipe or a long press on a row.
    public func snooze(_ thread: MailThread, until date: Date) {
        snooze([thread], until: date)
    }

    private func snooze(_ targets: [MailThread], until date: Date) {
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        let visible = visibleThreads
        if ids.contains(selectedThreadID ?? ""), let index = visible.firstIndex(where: { ids.contains($0.id) }) {
            let remaining = visible.filter { !ids.contains($0.id) }
            selectedThreadID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        lastSnoozed = targets.map(LabelStore.key(for:))
        for key in lastSnoozed { snoozes[key] = date }
        saveSnoozes()
        selection = []
        let until = date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let text = targets.count == 1
            ? String(localized: "Snoozed until \(until)")
            : String(localized: "\(targets.count) conversations snoozed until \(until)")
        notice = Notice(text: text, undo: .snooze)
        Task { await loadBodies() }
    }

    public func unsnooze(_ thread: MailThread) {
        snoozes[LabelStore.key(for: thread)] = nil
        saveSnoozes()
    }

    func undoSnooze() {
        for key in lastSnoozed { snoozes[key] = nil }
        lastSnoozed = []
        saveSnoozes()
        notice = nil
    }

    func saveSnoozes() {
        JSONFile<[String: Date]>(url: environment.folder.appending(path: "snoozes.json")).save(snoozes)
    }

    // MARK: Waiting for reply

    /// Sent conversations taken off the waiting list.
    var dismissedWaitingKeys: Set<String> {
        get {
            if let dismissedWaiting { return dismissedWaiting }
            let loaded = JSONFile<Set<String>>(url: environment.folder.appending(path: "waiting-dismissed.json")).load() ?? []
            dismissedWaiting = loaded
            return loaded
        }
        set {
            dismissedWaiting = newValue
            JSONFile<Set<String>>(url: environment.folder.appending(path: "waiting-dismissed.json")).save(newValue)
        }
    }

    /// Sent mail older than the follow-up setting that nobody has answered.
    func waitingThreads(_ accountID: UUID?) async -> [MailThread] {
        var sent: [MailThread] = []
        for account in accounts where accountID == nil || account.id == accountID {
            guard let mailbox = combinedMailbox(.sent, of: account.id), let provider = try? provider(for: account) else { continue }
            let threads = (try? await provider.threads(in: mailbox, limit: 100)) ?? []
            sent += threads.map { Self.tag($0, account: account.id) }
        }
        let me = Set(accounts.map { $0.address.address.lowercased() })
        let dismissed = dismissedWaitingKeys
        let waiting = FollowUp.waiting(sent: sent, inbox: inboxThreads(nil), me: me, olderThan: TimeInterval(followUpDays) * 86_400)
            .filter { !dismissed.contains(LabelStore.key(for: $0)) }
        if accountID == nil { waitingCount = waiting.count }
        return waiting
    }

    /// A short nudge on the open conversation: drafted by the assistant when it's on.
    public func followUp() {
        guard selectedThread != nil else { return }
        if isAssistantOn {
            writeReply(.draft(note: "A short, friendly follow-up asking whether they had a chance to look at my last message."))
        } else {
            startReply()
            reply?.draft.text = String(localized: "Hi,\n\nJust following up on this. Did you have a chance to take a look?\n\n") + (reply?.draft.text ?? "")
        }
    }

    // MARK: Selection

    /// Selected conversations, or the open one when nothing is selected.
    public var actionTargets: [MailThread] {
        if !selection.isEmpty { return visibleThreads.filter { selection.contains($0.id) } }
        return selectedThread.map { [$0] } ?? []
    }

    /// ⌘-click: add or remove one conversation.
    public func toggleSelection(_ id: MailThread.ID) {
        if selection.isEmpty, let current = selectedThreadID, current != id { selection.insert(current) }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// ⇧-click: everything between the open conversation and this one.
    public func extendSelection(to id: MailThread.ID) {
        let threads = visibleThreads
        guard let anchor = threads.firstIndex(where: { $0.id == selectedThreadID }),
              let end = threads.firstIndex(where: { $0.id == id }) else { toggleSelection(id); return }
        for index in min(anchor, end)...max(anchor, end) { selection.insert(threads[index].id) }
    }

    public func selectAll() {
        selection = Set(visibleThreads.map(\.id))
    }

    // MARK: Clock

    /// Wakes snoozes, sends due scheduled mail, and checks for new mail every few minutes.
    public func startClock() {
        startWatching()
        guard clock == nil else { return }
        clock = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                await self.tick()
                ticks += 1
                if ticks % 9 == 0, !self.isLoading { await self.reload() } // about every 3 minutes
                if ticks % 180 == 0 { await self.refreshContacts() } // about every hour
                if ticks % 3 == 0 { await self.syncNow() } // about every minute, when Sync with iCloud is on
            }
        }
    }

    func tick() async {
        let now = Date()
        clockTick += 1
        checkReplyReminders(now: now)
        // Now and then, look for invitations in new mail so the calendar knows about them.
        if clockTick % 9 == 1 { await findInvites() }
        if clockTick % 3 == 0 { await sortNewMail(inboxThreads(nil).filter { now.timeIntervalSince($0.date) < 3 * 3600 }) }
        runAutomaticBackupIfDue(now: now)
        let woken = snoozes.filter { $0.value <= now }.map(\.key)
        if !woken.isEmpty {
            for key in woken { snoozes[key] = nil }
            saveSnoozes()
        }
        for item in outbox where item.sendAt <= now {
            guard let account = account(item.accountID) else { continue }
            do {
                try await provider(for: account).send(item.draft)
                outbox.removeAll { $0.id == item.id }
                saveOutbox()
                notice = Notice(text: item.waitsForConnection ? String(localized: "Back online: your message was sent")
                                                              : String(localized: "Scheduled message sent"))
            } catch where MailError.isConnectionProblem(error) {
                // Still offline: keep it and try again on the next tick, quietly.
                if let index = outbox.firstIndex(where: { $0.id == item.id }), !outbox[index].waitsForConnection {
                    outbox[index].waitsForConnection = true
                    saveOutbox()
                }
            } catch {
                if let index = outbox.firstIndex(where: { $0.id == item.id }) {
                    outbox[index].waitsForConnection = false
                    // Moved a day ahead, so it isn't retried every few seconds; Send now tries again.
                    outbox[index].sendAt = now.addingTimeInterval(86_400)
                    saveOutbox()
                }
                notice = Notice(text: String(localized: "A message couldn't be sent: \(error.localizedDescription)"), isError: true)
            }
        }
    }

    // MARK: Notifications

    /// Posts a notification for unread conversations that weren't there before. The first
    /// load only remembers what's there.
    // MARK: Push

    /// Keeps a connection open to each mailbox's server and reloads the moment it reports
    /// new mail. Servers that can't push are left to the timer above. No server of ours is
    /// involved: this works while Margin is running.
    public func startWatching() {
        guard !environment.isPreview else { return }
        for account in accounts where watchers[account.id] == nil {
            watchers[account.id] = Task { [weak self] in await self?.watch(account) }
        }
        for id in watchers.keys where !accounts.contains(where: { $0.id == id }) {
            watchers.removeValue(forKey: id)?.cancel()
        }
    }

    public func stopWatching() {
        for task in watchers.values { task.cancel() }
        watchers = [:]
        pushingAccounts = []
    }

    private func watch(_ account: MailAccount) async {
        var failures = 0
        while !Task.isCancelled {
            guard let provider = try? provider(for: account) else { return }
            do {
                // Servers end an IDLE after 30 minutes; start a new one before that.
                let changed = try await provider.waitForInboxChange(timeout: .seconds(25 * 60))
                pushingAccounts.insert(account.id)
                failures = 0
                if changed, !isLoading { await reload() }
            } catch MailError.notSupported {
                pushingAccounts.remove(account.id)
                return
            } catch {
                // Offline or dropped: wait a little longer each time, up to five minutes.
                pushingAccounts.remove(account.id)
                failures += 1
                try? await Task.sleep(for: .seconds(min(300, 10 * failures * failures)))
            }
        }
    }

    // MARK: Notifications

    private var seenFile: JSONFile<Set<MailThread.ID>> {
        JSONFile(url: environment.folder.appending(path: "seen-unread.json"))
    }

    /// Fetches new mail and alerts about it; for background refresh on iPhone and iPad, where
    /// the system wakes Margin now and then. Returns whether anything new arrived.
    @discardableResult
    public func checkForNewMail() async -> Bool {
        let before = Set(inboxThreads(nil).map(\.id))
        await reload()
        return !Set(inboxThreads(nil).map(\.id)).subtracting(before).isEmpty
    }

    /// Whether a conversation comes from someone you know: in your contacts or VIPs, someone
    /// you've written to, or a reply in a conversation you're part of. Smart alerts are only for
    /// these, so promotions that look personal stay quiet.
    func isFromSomeoneYouKnow(_ thread: MailThread) -> Bool {
        if thread.messages.contains(where: isMine) { return true }
        let senders = Set(thread.messages.filter { !isMine($0) }.map { $0.from.address.lowercased() })
        if senders.contains(where: correspondents.contains) { return true }
        if thread.messages.contains(where: { isVIP($0.from) }) { return true }
        let known = Set(contacts.flatMap(\.addresses).map { $0.address.lowercased() })
        return senders.contains(where: known.contains)
    }

    func notifyAboutNewMail() {
        let unread = inboxThreads(nil).filter(\.isUnread)
        let ids = Set(unread.map(\.id))
        // Remembered across launches, so a background check doesn't alert about old mail.
        if seenUnread == nil, !environment.isPreview { seenUnread = seenFile.load() }
        defer {
            seenUnread = (seenUnread ?? []).union(ids).intersection(Set(inboxThreads(nil).map(\.id)))
            if !environment.isPreview { seenFile.save(seenUnread ?? []) }
        }
        guard let seen = seenUnread, !environment.isPreview else { return }
        // Each mailbox can have its own setting. Sign-in codes come through unless a mailbox's
        // alerts are off entirely: they're needed now.
        let fresh = unread.filter { thread in
            let setting = alertSetting(for: thread)
            // Workspaces not in view stay quiet, except for sign-in codes.
            if isInOtherWorkspace(thread) { return !seen.contains(thread.id) && signInCode(in: thread) != nil }
            return !seen.contains(thread.id) && !isSnoozed(thread) && setting != .none
                && (setting == .all || (setting == .people && thread.split == .people && isFromSomeoneYouKnow(thread))
                    || (setting == .vips && thread.messages.contains { isVIP($0.from) }) || signInCode(in: thread) != nil)
        }
        guard !fresh.isEmpty else { return }
        // A code that just arrived goes straight to the clipboard, ready to paste.
        if copiesSignInCodes, let newest = fresh.first(where: { signInCode(in: $0) != nil && Date().timeIntervalSince($0.date) < 15 * 60 }),
           let code = signInCode(in: newest) {
            Self.putOnPasteboard(code)
            notice = Notice(text: String(localized: "Code \(ReaderSuggestion.spaced(code)) copied"))
            typeIntoFocusedField(code)
        }
        // The sound is played here, so the Mac can use any of its alert sounds.
        playAlertSound()
        #if os(macOS)
        // While Margin runs on the Mac, the newest slides down from the top of the screen instead.
        if showsDropDownAlerts, let newest = fresh.first {
            dropDownAlert = newest
            return
        }
        #endif
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let sound = alertSound
        let alerts = fresh.prefix(3).map { thread in
            let content = UNMutableNotificationContent()
            content.title = thread.latest.from.displayName
            content.subtitle = thread.subject
            content.body = thread.latest.snippet
            content.userInfo = ["threadID": thread.id]
            if let code = signInCode(in: thread) {
                // The code in the title, and a Copy button on the notification itself.
                content.title = String(localized: "Sign-in code \(ReaderSuggestion.spaced(code))")
                content.subtitle = thread.latest.from.displayName
                content.body = thread.subject
                content.userInfo["code"] = code
                content.categoryIdentifier = MailNotifications.codeCategory
                content.interruptionLevel = .timeSensitive
            }
            content.threadIdentifier = account(thread.accountID)?.label ?? "mail"
            #if os(iOS)
            content.sound = sound == .none ? nil : .default
            #endif
            return UNNotificationRequest(identifier: thread.id, content: content, trigger: nil)
        }
        MailNotifications.registerCategories()
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
            for request in alerts { try? await center.add(request) }
        }
        #endif
    }

    /// Opens a conversation from a notification.
    public func reveal(_ threadID: MailThread.ID) {
        // Meetings made here have no message to open.
        guard !threadID.isEmpty else { return }
        if !visibleThreads.contains(where: { $0.id == threadID }) { go(to: .allInboxes) }
        select(threadID)
    }
}

/// What a swipe on a conversation does, on iPhone and iPad.
public enum SwipeAction: String, CaseIterable, Identifiable, Sendable {
    case done, star, read, snooze, trash, none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .done: String(localized: "Done")
        case .star: String(localized: "Star")
        case .read: String(localized: "Read or unread")
        case .snooze: String(localized: "Snooze")
        case .trash: String(localized: "Trash")
        case .none: String(localized: "Nothing")
        }
    }
}

extension MailModel {
    /// The two actions behind a swipe right (leading) and a swipe left (trailing); the first
    /// of each runs on a full swipe.
    public var leadingSwipes: [SwipeAction] {
        get { swipes("swipeLeading", default: [.done, .star]) }
        set { environment.defaults.set(newValue.map(\.rawValue), forKey: "swipeLeading"); swipeRevision += 1 }
    }

    public var trailingSwipes: [SwipeAction] {
        get { swipes("swipeTrailing", default: [.trash, .snooze]) }
        set { environment.defaults.set(newValue.map(\.rawValue), forKey: "swipeTrailing"); swipeRevision += 1 }
    }

    private func swipes(_ key: String, default fallback: [SwipeAction]) -> [SwipeAction] {
        _ = swipeRevision
        let saved = environment.defaults.stringArray(forKey: key)?.compactMap(SwipeAction.init(rawValue:))
        return (saved?.count == 2 ? saved : nil) ?? fallback
    }
}
