import Foundation

/// How a newsletter can be left, from its List-Unsubscribe headers (RFC 2369, RFC 8058).
public enum Unsubscribe: Hashable, Sendable {
    /// One POST and it's done, no page to visit (RFC 8058 one-click).
    case oneClick(URL)
    /// An email to a list address.
    case mail(EmailAddress, subject: String)
    /// A page to open in the browser.
    case web(URL)

    public static func method(from headers: [String: String]) -> Unsubscribe? {
        guard let raw = headers["list-unsubscribe"] else { return nil }
        // Some servers (Microsoft's among them) rewrite a long header as encoded words
        // (`=?us-ascii?Q?=3Chttps=3A…?=`): read it back first, or the links aren't found.
        let value = raw.contains("=?") ? MIMEWords.decode(raw) : raw
        // `<https://…>, <mailto:…>`: the targets are the bracketed parts. A long link folded
        // over several lines comes with spaces where the lines met; a link has none.
        let targets = MessageIDs.parse(value).map { $0.filter { !$0.isWhitespace } }
        let https = targets.compactMap(URL.init(string:)).first { $0.scheme?.lowercased() == "https" }
        let oneClick = headers["list-unsubscribe-post"]?.lowercased().replacingOccurrences(of: " ", with: "") == "list-unsubscribe=one-click"
        if let https, oneClick { return .oneClick(https) }
        if let mailto = targets.compactMap(URL.init(string:)).first(where: { $0.scheme?.lowercased() == "mailto" }),
           let components = URLComponents(url: mailto, resolvingAgainstBaseURL: false),
           EmailAddress.isValid(components.path) {
            let subject = components.queryItems?.first { $0.name.lowercased() == "subject" }?.value ?? "unsubscribe"
            return .mail(EmailAddress(address: components.path), subject: subject)
        }
        if let https { return .web(https) }
        // A plain http page is still a way out; it opens in the browser.
        return targets.compactMap(URL.init(string:)).first { $0.scheme?.lowercased() == "http" }.map(Unsubscribe.web)
    }

    /// Words an unsubscribe link is labelled with, or that the sentence around it uses, in
    /// the languages mail commonly comes in.
    static let linkWords = ["unsubscribe", "opt out", "opt-out", "stop receiving", "stop getting", "no longer wish", "no longer want",
                            "uitschrijven", "uitschrijf", "schrijf je uit", "afmelden", "afmeld", "meld je af", "niet meer ontvangen",
                            "geen e-mails meer", "geen mails meer", "abmelden", "abbestellen", "austragen",
                            "désabonner", "desabonner", "désinscri", "desinscri", "darse de baja", "cancelar suscripción",
                            "cancelar la suscripción", "cancelar inscrição", "annulla iscrizione", "disiscri", "avregistrera",
                            "avprenumerera", "wypisz", "abonelikten", "отписаться", "退订", "取消订阅", "取消訂閱", "配信停止", "수신거부"]
    static let linkAddressWords = ["unsubscribe", "unsub", "optout", "opt-out", "opt_out", "afmelden", "uitschrijven", "abmelden"]
    /// Where a sender that offers no unsubscribe link lets you turn its mail off instead.
    static let settingsWords = ["preferences", "email settings", "notification settings", "manage notifications",
                                "manage your notifications", "manage emails", "manage your email", "email notifications",
                                "communication settings", "update your settings", "change your settings", "voorkeuren",
                                "meldingen beheren", "e-mailinstellingen", "meldingsinstellingen", "instellingen voor meldingen",
                                "einstellungen", "préférences", "preferencias", "preferenze"]
    static let settingsAddressWords = ["preferences", "notification", "email-settings", "emailsettings", "subscriptions"]
    private static let anchor = try? NSRegularExpression(
        pattern: #"<a\b[^>]*?href\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))[^>]*>(.*?)</a>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let plainLink = try? NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#, options: [.caseInsensitive])

    /// For lists that send no List-Unsubscribe header: the way out in the mail's own text, as
    /// a page to open. Tried in this order, the last match of each winning (it's the footer):
    /// 1. a link whose label or address says unsubscribe;
    /// 2. with `loose`, the link next to a sentence that says so ("To unsubscribe, click here");
    /// 3. with `loose`, the sender's page for its mail settings.
    /// `loose` is for mail no person wrote; a friend's signature may link to "settings" too.
    public static func link(inHTML html: String, text: String = "", loose: Bool = false) -> Unsubscribe? {
        let lowered = html.lowercased()
        let everyWord = linkWords + linkAddressWords + (loose ? settingsWords + settingsAddressWords : [])
        if !html.isEmpty, everyWord.contains(where: lowered.contains), let anchor {
            let source = html as NSString
            var links: [(url: URL, address: String, label: String, range: NSRange)] = []
            for match in anchor.matches(in: html, range: NSRange(location: 0, length: source.length)) {
                let group = (1...3).first { match.range(at: $0).location != NSNotFound } ?? 1
                let address = source.substring(with: match.range(at: group)).replacingOccurrences(of: "&amp;", with: "&")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let loweredAddress = address.lowercased()
                guard loweredAddress.hasPrefix("https://") || loweredAddress.hasPrefix("http://"), let url = URL(string: address) else { continue }
                let label = source.substring(with: match.range(at: 4))
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression).lowercased()
                links.append((url, loweredAddress, label, match.range))
            }
            if let direct = links.last(where: { link in
                linkWords.contains(where: link.label.contains) || linkAddressWords.contains(where: link.address.contains)
            }) { return .web(direct.url) }
            if loose {
                // The sentence says it, the link beside it is "here": the first link after the
                // last such word, or failing that the last one shortly before it.
                let whole = lowered as NSString
                var lastWord: Int?
                for word in linkWords {
                    let found = whole.range(of: word, options: .backwards)
                    if found.location != NSNotFound { lastWord = max(lastWord ?? 0, found.location) }
                }
                if let lastWord {
                    if let after = links.first(where: { $0.range.location >= lastWord && $0.range.location - lastWord < 600 }) { return .web(after.url) }
                    if let before = links.last(where: { $0.range.location < lastWord && lastWord - NSMaxRange($0.range) < 300 }) { return .web(before.url) }
                }
                if let settings = links.last(where: { link in
                    settingsWords.contains(where: link.label.contains) || settingsAddressWords.contains(where: link.address.contains)
                }) { return .web(settings.url) }
            }
        }
        // Mail with no formatting: the address written out after the word.
        guard html.isEmpty, loose, let plainLink else { return nil }
        let plain = text as NSString, loweredText = text.lowercased() as NSString
        for word in linkWords {
            let found = loweredText.range(of: word, options: .backwards)
            guard found.location != NSNotFound else { continue }
            let window = NSRange(location: found.location, length: min(400, plain.length - found.location))
            if let match = plainLink.firstMatch(in: text, range: window), let url = URL(string: plain.substring(with: match.range)) {
                return .web(url)
            }
        }
        return nil
    }

    /// The RFC 8058 request: a form POST with exactly this body, no cookies.
    public static func oneClickRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        return request
    }
}

extension Unsubscribe {
    /// Refuses to follow a redirect: a one-click request that's sent on to some page hasn't
    /// unsubscribed anyone, and following it would turn the POST into a page visit that
    /// answers 200.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Sends the one-click request and says whether the sender's server confirmed it: only a
    /// 2xx answer to the POST itself counts. `send` is replaced in tests.
    public static func confirmOneClick(_ url: URL, send: ((URLRequest) async throws -> Int)? = nil) async -> Bool {
        let request = oneClickRequest(url)
        if let send { return ((try? await send(request)) ?? 0) / 100 == 2 }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
    }
}

/// One-time sign-in codes in alerts ("Your code is 482 913"), so they can be copied in one click.
public enum SignInCode {
    private static let cues = ["code", "verification", "verify", "sign-in", "sign in", "login", "log in", "one-time",
                               "passcode", "otp", "2fa", "security", "confirm", "bevestig", "inlogcode"]
    /// Words that have to come shortly before the number itself ("Your code is 482 913").
    /// Not "sign in" or "login" on their own: "a sign-in from a new device, reference 482913" is
    /// a notice, not a code. Real ones say code (or verification, one-time…).
    private static let nearCues = ["code", "verif", "passcode", "otp", "one-time", "token", "2fa", "código", "codice"]
    /// How far before the number those words may be.
    private static let reach = 80

    /// 4–8 digits, optionally split once by a space or dash ("482 913", "482-913"). Built once.
    private static let codePattern = try? NSRegularExpression(pattern: #"(?<![\d\w€$£.,:/=?&#+])(\d{3,4}[ -]\d{3,4}|\d{4,8})(?![\d\w%.,/:])"#)
    private static let linkPattern = try? NSRegularExpression(pattern: #"(https?://|www\.)\S+"#)

    public static func detect(subject: String, text: String) -> String? {
        let start = text.prefix(2_000)
        // No three digits in a row anywhere: no code. Most mail stops here, before any of the
        // work below (this is asked for every recent conversation).
        guard hasDigitRun(subject.utf8) || hasDigitRun(start.utf8) else { return nil }
        // Links carry ids that look like codes ("LinkId=521839"), so they go first.
        var words = String(start)
        if let linkPattern, words.contains("://") || words.contains("www.") {
            words = linkPattern.stringByReplacingMatches(in: words, range: NSRange(words.startIndex..., in: words), withTemplate: " ")
        }
        let haystack = subject + "\n" + words
        let lower = haystack.lowercased()
        guard cues.contains(where: lower.contains) else { return nil }
        guard let regex = codePattern else { return nil }
        let range = NSRange(haystack.startIndex..., in: haystack)
        for match in regex.matches(in: haystack, range: range) {
            guard let found = Range(match.range(at: 1), in: haystack) else { continue }
            let digits = haystack[found].filter(\.isNumber)
            // Years and amounts are the usual false friends.
            if digits.count == 4, let year = Int(digits), (1900...2100).contains(year) { continue }
            let before = haystack[..<found.lowerBound].suffix(reach).lowercased()
            guard nearCues.contains(where: before.contains) else { continue }
            return String(digits)
        }
        return nil
    }
}

extension SignInCode {
    /// Whether three digits stand together somewhere in the text.
    static func hasDigitRun<Bytes: Sequence>(_ bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
        var run = 0
        for byte in bytes {
            if byte >= 48, byte <= 57 {
                run += 1
                if run >= 3 { return true }
            } else {
                run = 0
            }
        }
        return false
    }
}

/// Links that sign you in or confirm an address ("Sign in to Kettle", "Confirm your email"), so
/// they can be opened in one click.
public enum SignInLink {
    public enum Kind: Sendable { case signIn, confirm }

    private static let signInCues = ["sign in", "sign-in", "log in", "login", "magic link", "inloggen", "anmelden", "se connecter"]
    private static let confirmCues = ["confirm your", "verify your", "activate your", "bevestig je", "bestätige", "confirmez"]
    private static let linkWords = ["signin", "sign-in", "sign_in", "login", "log-in", "magic", "verify", "confirm", "activate",
                                    "auth", "token", "session", "validate"]

    /// The sign-in or confirmation link in a message, or nil when there isn't a clear one.
    public static func detect(subject: String, text: String, html: String?) -> (url: URL, kind: Kind)? {
        let lower = (subject + "\n" + String(text.prefix(3_000))).lowercased()
        let kind: Kind
        if confirmCues.contains(where: lower.contains) { kind = .confirm }
        else if signInCues.contains(where: lower.contains) { kind = .signIn }
        else { return nil }
        // Links with their words: an anchor whose text or address says what it does.
        var candidates: [(url: URL, words: String)] = []
        if let html {
            let pattern = #"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                    guard let href = Range(match.range(at: 1), in: html), let label = Range(match.range(at: 2), in: html),
                          let url = URL(string: String(html[href]).replacingOccurrences(of: "&amp;", with: "&")),
                          url.scheme == "https" else { continue }
                    let words = String(html[label]).replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    candidates.append((url, words.lowercased()))
                }
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, url.scheme == "https" { candidates.append((url, "")) }
            }
        }
        let best = candidates.first { candidate in
            let address = candidate.url.absoluteString.lowercased()
            let unsubscribe = address.contains("unsubscribe") || candidate.words.contains("unsubscribe")
            return !unsubscribe && (linkWords.contains(where: address.contains)
                || (signInCues + confirmCues + ["verify", "confirm"]).contains(where: candidate.words.contains))
        }
        return best.map { ($0.url, kind) }
    }
}

/// Snooze times people actually pick.
public enum SnoozePreset: String, CaseIterable, Sendable {
    case laterToday, tomorrow, weekend, nextWeek

    public var title: String {
        switch self {
        case .laterToday: String(localized: "Later today")
        case .tomorrow: String(localized: "Tomorrow")
        case .weekend: String(localized: "This weekend")
        case .nextWeek: String(localized: "Next week")
        }
    }

    public func date(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        func at(_ hour: Int, daysFromNow days: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }
        switch self {
        case .laterToday:
            let later = now.addingTimeInterval(3 * 3600)
            return calendar.dateInterval(of: .hour, for: later)?.start ?? later
        case .tomorrow:
            return at(8, daysFromNow: 1)
        case .weekend:
            let weekday = calendar.component(.weekday, from: now) // 1 = Sunday, 7 = Saturday
            let days = weekday == 7 ? 7 : (7 - weekday)
            return at(9, daysFromNow: days == 0 ? 6 : days)
        case .nextWeek:
            let weekday = calendar.component(.weekday, from: now)
            let days = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7 // next Monday
            return at(8, daysFromNow: days)
        }
    }
}

/// Conversations where you wrote last and nobody has answered for a while.
public enum FollowUp {
    /// `sent`: threads from Sent folders. `inbox`: threads from inboxes, where replies arrive.
    public static func waiting(sent: [MailThread], inbox: [MailThread], me: Set<String>, olderThan: TimeInterval, now: Date = Date()) -> [MailThread] {
        let incoming = inbox.flatMap(\.messages).filter { !me.contains($0.from.address.lowercased()) }
        return sent.filter { thread in
            let mine = thread.latest
            guard me.contains(mine.from.address.lowercased()), !MeetingNotice.isNotice(subject: mine.subject),
                  now.timeIntervalSince(mine.date) >= olderThan,
                  now.timeIntervalSince(mine.date) < 60 * 86_400 else { return false }
            let subject = Subject.normalized(mine.subject)
            let recipients = Set((mine.to + mine.cc).map { $0.address.lowercased() })
            let answered = incoming.contains { reply in
                guard reply.date > mine.date else { return false }
                if let id = mine.messageID, reply.inReplyTo == id || reply.references.contains(id) { return true }
                return Subject.normalized(reply.subject) == subject && recipients.contains(reply.from.address.lowercased())
            }
            return !answered
        }.sorted { $0.date > $1.date }
    }
}

/// A small JSON file in Application Support: snoozes, the outbox, settings that aren't secrets.
public struct JSONFile<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func standard(appName: String, name: String) -> JSONFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return JSONFile(url: base.appending(path: appName, directoryHint: .isDirectory).appending(path: name))
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(value).write(to: url, options: .atomic)
    }
}

/// A message waiting in the outbox to be sent later.
public struct ScheduledMessage: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var accountID: UUID
    public var draft: Draft
    public var sendAt: Date
    /// Sent while there was no connection: it goes out by itself once there is one.
    public var waitsForConnection: Bool

    public init(accountID: UUID, draft: Draft, sendAt: Date, waitsForConnection: Bool = false) {
        self.accountID = accountID
        self.draft = draft
        self.sendAt = sendAt
        self.waitsForConnection = waitsForConnection
    }
}

extension MailError {
    /// Whether this failure is about the connection (offline, a timeout), so trying again later
    /// can work, rather than something the server refused.
    public static func isConnectionProblem(_ error: Error) -> Bool {
        if let mail = error as? MailError {
            switch mail {
            case .connectionFailed, .connectionClosed, .timedOut: return true
            default: return false
            }
        }
        if let url = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff].contains(url.code)
        }
        return (error as NSError).domain == NSPOSIXErrorDomain
    }
}

/// A key for a long string (a mail's HTML) that's cheap to work out: its bytes are hashed as
/// they are. Swift's own string hashing first puts text in a normal form so that differently
/// built equal strings match, which for a 100 KB mail with any non-ASCII letter in it takes
/// around a millisecond, and the views ask for these keys several times per redraw.
public enum TextKey {
    public static func of(_ text: String) -> Int {
        var hasher = Hasher()
        var text = text
        text.withUTF8 { bytes in
            hasher.combine(bytes.count)
            hasher.combine(bytes: UnsafeRawBufferPointer(bytes))
        }
        return hasher.finalize()
    }
}

extension Array where Element == UInt8 {
    /// Where `needle` first occurs at or after `start`, by bytes.
    public func firstIndex(of needle: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, count >= needle.count, start <= count - needle.count else { return nil }
        let first = needle[0], last = count - needle.count
        return withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { want in
                var index = start
                while index <= last {
                    if hay[index] == first, memcmp(hay.baseAddress! + index, want.baseAddress!, want.count) == 0 { return index }
                    index += 1
                }
                return nil
            }
        }
    }
}
