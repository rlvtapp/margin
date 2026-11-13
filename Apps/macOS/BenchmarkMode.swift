import AppKit
import MailCore
import MailUI
import SwiftUI

/// `-benchmark <file.txt>` fills the app with a made-up load (`-benchmark-accounts 6`,
/// `-benchmark-threads 200`), steps through mail the way a person does, and writes how long each
/// step took: from the key press to the mail being on screen, and how long the main thread was
/// busy meanwhile (which is what makes the app feel stuck). Nothing is fetched.
///
/// By default every conversation is in memory, as if each had been scrolled to: the hardest case
/// for the lists. With `-benchmark-saved <folder>` the mailboxes are held the way the app really
/// holds them: all of it in a saved-mail database in that folder (made on the first run, used
/// again after), on a made-up server, and only the newest page in memory until the list is
/// scrolled.
struct BenchmarkMode {
    let output: URL
    let accounts: Int
    let threads: Int
    let steps: Int
    /// Where the saved-mail database of a `-benchmark-saved` run is kept.
    let store: URL?

    static func fromArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> BenchmarkMode? {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let path = value(after: "-benchmark") else { return nil }
        return BenchmarkMode(output: URL(fileURLWithPath: path), accounts: value(after: "-benchmark-accounts").flatMap(Int.init) ?? 6,
                             threads: value(after: "-benchmark-threads").flatMap(Int.init) ?? 200,
                             steps: value(after: "-benchmark-steps").flatMap(Int.init) ?? 40,
                             store: value(after: "-benchmark-saved").map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    /// The saved-mail file for this size, and whether it has to be filled first.
    var storeFile: URL? {
        // The made-up mail is dated from today, so a file is good for the day it was made.
        let day = Date().formatted(.iso8601.year().month().day())
        return store?.appending(path: "mail-\(accounts)x\(threads)-\(day).sqlite")
    }

    /// The app's surroundings for the run: nothing of the real app's, and for a saved run the
    /// database file in the folder given.
    var environment: MailEnvironment {
        var environment = MailEnvironment.preview()
        if let storeFile { environment.cache = MailCache(url: storeFile) }
        return environment
    }

    /// How long the main thread keeps others waiting: a second thread asks it for a moment of
    /// its time every millisecond and notes how long each ask took to be answered. (Watching
    /// the run loop rest, as this did before, saw nothing while the main thread never rested.)
    final class Busy: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var asked: CFAbsoluteTime?
        nonisolated(unsafe) private var sum: Double = 0
        nonisolated(unsafe) private var worst: Double = 0
        nonisolated(unsafe) private var timer: DispatchSourceTimer?

        nonisolated var total: Double { lock.withLock { sum + pending() } }
        nonisolated var longest: Double { lock.withLock { max(worst, pending()) } }

        /// The ask that's still unanswered, when it has waited a while (call with the lock held).
        nonisolated private func pending() -> Double {
            guard let asked else { return 0 }
            let waited = CFAbsoluteTimeGetCurrent() - asked
            return waited > 0.002 ? waited : 0
        }

        nonisolated func start() {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "benchmark.busy", qos: .userInteractive))
            timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(100))
            timer.setEventHandler { @Sendable [self] in
                let sent = CFAbsoluteTimeGetCurrent()
                let free = lock.withLock { () -> Bool in
                    guard asked == nil else { return false }
                    asked = sent
                    return true
                }
                guard free else { return }
                DispatchQueue.main.async { @Sendable [self] in
                    let waited = CFAbsoluteTimeGetCurrent() - sent
                    lock.withLock {
                        asked = nil
                        // Under half a millisecond is the ask itself, not work.
                        if waited > 0.0005 { sum += waited; worst = max(worst, waited) }
                    }
                }
            }
            timer.resume()
            self.timer = timer
        }

        nonisolated func reset() { lock.withLock { sum = 0; worst = 0 } }
    }

    /// Memory the app holds, as Activity Monitor counts it, in MB.
    static func memory() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    struct Step { var shown: Double; var busy: Double; var longest: Double; var formatted: Bool }

    func run(model: MailModel) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                let screen = main.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1728, height: 1084)
                main.setFrame(NSRect(x: screen.minX + 20, y: screen.maxY - 900 - 20, width: 1400, height: 900), display: true)
            }
            let busy = Busy()
            busy.start()
            var lines: [String] = ["Margin benchmark: \(accounts) mailboxes x \(threads) conversations"]
            @MainActor func note(_ line: String) { lines.append(line); try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8) }

            let before = Self.memory()
            if let storeFile {
                lines[0] += ", saved on this Mac, newest page in memory"
                // A file from an earlier run of this size is used as it is.
                let times = await model.loadBenchmarkStore(accounts: accounts, threads: threads)
                if let fill = times.fill { note("save \(accounts * threads) conversations for the first time: \(Self.ms(fill)) ms") }
                let size = (try? FileManager.default.attributesOfItem(atPath: storeFile.path)[.size] as? Int) ?? 0
                note("saved mail: \(await model.environment.cache.messageCount()) messages, \(size / 1_048_576) MB on disk")
                note("fill the window from saved mail (what launch waits for): \(Self.ms(times.open)) ms")
                // The first refresh comes with the window's first drawing; the one timed is
                // the next, as every three minutes afterwards.
                await model.reload()
                try? await Task.sleep(for: .seconds(2))
                let written = await model.environment.cache.rowsWritten
                busy.reset()
                let refresh = await ContinuousClock().measure { await model.reload() }
                note(String(format: "refresh every mailbox with nothing new: \(Self.ms(refresh)) ms, main thread busy %.0f ms, rows written \(await model.environment.cache.rowsWritten - written)", busy.total * 1000))
            } else {
                lines[0] += ", all in memory"
                let filled = ContinuousClock().measure { model.loadBenchmarkMail(accounts: accounts, threads: threads) }
                note("load the made-up mail: \(Self.ms(filled)) ms")
            }
            try? await Task.sleep(for: .seconds(2))
            let loaded = model.accounts.reduce(0) { $0 + model.inboxThreads($1.id).count }
            note(String(format: "memory: %.0f MB with %d conversations in memory (%.0f MB before the mail)", Self.memory(), loaded, before))

            var pages = 0
            MailBenchmark.onPageMeasured = { pages += 1 }

            /// One action, timed until its mail is on screen and the main thread rests again.
            @MainActor func step(_ action: @MainActor () -> Void) async -> Step {
                let before = pages
                busy.reset()
                let start = CFAbsoluteTimeGetCurrent()
                action()
                // Whether the mail is formatted is known once its text is there (in memory
                // already, or a moment later from saved mail or the server).
                @MainActor func text() -> MessageBody? { model.selectedThread.flatMap { model.body(of: $0.latest, in: $0) } }
                var formatted = text()?.html != nil && !model.prefersPlainText
                var shown = start
                // Up to three seconds for the page; then until the main thread has done next to
                // nothing for 60 ms (these checks themselves are a few microseconds each).
                var marks: [(at: CFAbsoluteTime, busy: Double)] = []
                var lastWork = start
                while CFAbsoluteTimeGetCurrent() - start < 3 {
                    try? await Task.sleep(for: .milliseconds(4))
                    let now = CFAbsoluteTimeGetCurrent()
                    if let last = marks.last, busy.total - last.busy > 0.0008 { lastWork = now }
                    marks.append((now, busy.total))
                    if !formatted, text()?.html != nil, !model.prefersPlainText { formatted = true }
                    if model.selectedThread != nil, text() == nil { continue }
                    if formatted ? pages > before : true {
                        if formatted, shown == start { shown = now }
                        if now - lastWork > 0.06 { break }
                    }
                }
                // Plain mail has no page to wait for: it's on screen when the main thread is
                // done with it.
                if !formatted { shown = max(lastWork, start + busy.total) }
                return Step(shown: (shown - start) * 1000, busy: busy.total * 1000, longest: busy.longest * 1000, formatted: formatted)
            }

            @MainActor func report(_ title: String, _ steps: [Step]) {
                func stats(_ values: [Double]) -> String {
                    let sorted = values.sorted()
                    guard !sorted.isEmpty else { return "-" }
                    let median = sorted[sorted.count / 2], p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
                    return String(format: "median %4.0f  p90 %4.0f  max %4.0f", median, p90, sorted.last!)
                }
                note("\(title) (\(steps.count) steps, ms)")
                note("  on screen after      " + stats(steps.map(\.shown)))
                note("  main thread busy     " + stats(steps.map(\.busy)))
                note("  longest single block " + stats(steps.map(\.longest)))
                let formatted = steps.filter(\.formatted), plain = steps.filter { !$0.formatted }
                if !formatted.isEmpty { note("  formatted mail only  " + stats(formatted.map(\.shown))) }
                if !plain.isEmpty { note("  plain mail only      " + stats(plain.map(\.shown))) }
            }

            // `-benchmark-only pages` or `typing`: just that part, repeated, for profiling it.
            let arguments = ProcessInfo.processInfo.arguments
            let only = arguments.firstIndex(of: "-benchmark-only").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            if only == "pages" {
                var pages: [Step] = []
                for round in 0..<6 {
                    for account in model.accounts.prefix(4) { pages.append(await step { model.go(to: .inbox(account: account.id, split: nil)) }) }
                    pages.append(await step { model.go(to: .home(group: nil)) })
                    pages.append(await step { model.go(to: .allInboxes) })
                    pages.append(await step { model.go(to: .starred(account: nil)) })
                    pages.append(await step { model.go(to: .snoozed(account: nil)) })
                    if round % 2 == 0 { pages.append(await step { model.go(to: .calendar) }) }
                }
                report("Switching pages", pages)
                note("done")
                exit(0)
            }
            if only == "tabs" {
                // All, Important and Other, in All inboxes and in one mailbox.
                var tabs: [Step] = []
                for place in [nil, model.accounts.first?.id] {
                    for _ in 0..<5 {
                        for split in [InboxSplit.people, .updates, nil] {
                            tabs.append(await step { model.go(to: .inbox(account: place, split: split)) })
                        }
                    }
                }
                report("Switching inbox tabs", tabs)
                note("done")
                exit(0)
            }
            if only == "typing", let long = model.visibleThreads.first(where: { $0.messages.count >= 5 }) {
                model.select(long.id)
                try? await Task.sleep(for: .seconds(1))
                model.startReply()
                try? await Task.sleep(for: .seconds(1))
                var typing: [Step] = []
                for letter in String(repeating: "A reply typed one letter at a time. ", count: 8) {
                    typing.append(await step { model.reply?.draft.text.append(letter) })
                }
                report("Typing in a reply", typing)
                note("done")
                exit(0)
            }

            // 1. Stepping down All inboxes, one mail at a time, waiting for each.
            var all: [Step] = []
            for _ in 0..<steps { all.append(await step { model.moveSelection(1) }) }
            report("All inboxes, next mail", all)

            // 2. The same inside one mailbox.
            model.go(to: .inbox(account: model.accounts[0].id, split: nil))
            try? await Task.sleep(for: .seconds(1))
            var one: [Step] = []
            for _ in 0..<steps { one.append(await step { model.moveSelection(1) }) }
            report("One mailbox, next mail", one)

            // 3. Switching mailboxes.
            var switching: [Step] = []
            for account in model.accounts + model.accounts {
                switching.append(await step { model.go(to: .inbox(account: account.id, split: nil)) })
            }
            report("Switching mailbox", switching)

            // 4. Home and back to All inboxes.
            var places: [Step] = []
            for _ in 0..<4 {
                places.append(await step { model.go(to: .home(group: nil)) })
                places.append(await step { model.go(to: .allInboxes) })
            }
            report("Home and All inboxes", places)

            // 5. Holding the key: a new mail every 70 ms, whether the last one is ready or not.
            model.go(to: .allInboxes)
            try? await Task.sleep(for: .seconds(1))
            busy.reset()
            let heldStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<30 {
                model.moveSelection(1)
                try? await Task.sleep(for: .milliseconds(70))
            }
            let asked = CFAbsoluteTimeGetCurrent() - heldStart
            var heldBusy = busy.total, heldWork = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - heldWork < 0.15, CFAbsoluteTimeGetCurrent() - heldStart < 20 {
                try? await Task.sleep(for: .milliseconds(10))
                if busy.total - heldBusy > 0.001 { heldWork = CFAbsoluteTimeGetCurrent() }
                heldBusy = busy.total
            }
            note(String(format: "Holding the key, 30 mails at 70 ms each: asked for in %.0f ms, settled after %.0f ms, main thread busy %.0f ms, longest block %.0f ms",
                        asked * 1000, (CFAbsoluteTimeGetCurrent() - heldStart) * 1000, busy.total * 1000, busy.longest * 1000))

            // 6. Typing a reply in a long conversation.
            if let long = model.visibleThreads.first(where: { $0.messages.count >= 5 }) {
                model.select(long.id)
                try? await Task.sleep(for: .seconds(1))
                model.startReply()
                try? await Task.sleep(for: .seconds(1))
                var typing: [Step] = []
                for letter in "A reply typed one letter at a time." {
                    typing.append(await step { model.reply?.draft.text.append(letter) })
                }
                report("Typing in a reply", typing)
                model.reply = nil
            }

            // 7. Scrolling down: each time the end of the list comes on screen, the next rows
            // are shown, and older mail is fetched once everything loaded is on screen.
            model.go(to: .allInboxes)
            try? await Task.sleep(for: .seconds(1))
            var scrolling: [Step] = []
            for _ in 0..<12 where model.canShowMore {
                let rows = model.visibleThreads.count
                busy.reset()
                let start = CFAbsoluteTimeGetCurrent()
                model.listReachedEnd()
                while CFAbsoluteTimeGetCurrent() - start < 5, model.visibleThreads.count == rows || model.isLoadingOlder {
                    try? await Task.sleep(for: .milliseconds(2))
                }
                let shown = (CFAbsoluteTimeGetCurrent() - start) * 1000
                try? await Task.sleep(for: .milliseconds(150))
                scrolling.append(Step(shown: shown, busy: busy.total * 1000, longest: busy.longest * 1000, formatted: false))
            }
            report("Scrolling to the end of the list: the next \(MailModel.listPage) rows", scrolling)
            note("rows in the list after scrolling: \(model.visibleThreads.count) of \(model.listCount)")

            // 8. Next mail again, this far down.
            // From a row where the next mails are formatted ones, like the newest are (the
            // made-up mailboxes hold the same kind of mail at the same place).
            let rows = model.visibleThreads
            var from = rows.count - steps - 5
            while from > 0, rows[from..<min(from + steps + 1, rows.count)].contains(where: { $0.subject.contains("Plans for week") }) { from -= 1 }
            if from > 0 {
                model.select(rows[from].id)
                try? await Task.sleep(for: .seconds(1))
                var deep: [Step] = []
                for _ in 0..<steps { deep.append(await step { model.moveSelection(1) }) }
                report("All inboxes, next mail, scrolled down", deep)
            }

            if store != nil {
                // 9. Saved mail: finding words, and people as they're typed in To.
                let cache = model.environment.cache
                var search: [Double] = [], people: [Double] = []
                for words in ["statement ready", "plans week 4821", "order", "lisbon"] {
                    search.append(Double(Self.ms(await ContinuousClock().measure { _ = await cache.search(words) })) ?? 0)
                }
                for typed in ["no", "sam", "person1", "maya ch"] {
                    people.append(Double(Self.ms(await ContinuousClock().measure { _ = await cache.people(matching: typed) })) ?? 0)
                }
                note("search saved mail, 4 searches (ms): " + search.map { String(format: "%.0f", $0) }.joined(separator: ", "))
                note("people for the To field, 4 lookups (ms): " + people.map { String(format: "%.0f", $0) }.joined(separator: ", "))
            }
            let held = model.accounts.reduce(0) { $0 + model.inboxThreads($1.id).count }
            note(String(format: "memory at the end: %.0f MB with %d conversations in memory", Self.memory(), held))
            note("done")
            exit(0)
        }
    }

    static func ms(_ duration: Duration) -> String {
        String(format: "%.0f", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }
}
