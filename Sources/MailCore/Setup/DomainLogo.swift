import Foundation
import ImageIO

/// A mailbox's company logo: the icon its own domain publishes for phones and browsers
/// (`apple-touch-icon` and friends). Asked of that domain only, never of a third-party service,
/// and kept on the device. Free-mail domains (gmail.com, outlook.com…) have no logo of their own.
public actor DomainLogos {
    /// Smaller icons look blurry on an avatar.
    static let minimumSide = 48
    /// A logo is a small picture; anything bigger isn't one.
    static let maximumBytes = 1_000_000
    /// How long a domain without a usable icon is left alone.
    static let retryAfter: TimeInterval = 7 * 24 * 3600

    private let folder: URL?
    private let fetch: @Sendable (URL) async throws -> (Data, URLResponse)
    private var misses: [String: Date] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    /// `folder` nil keeps nothing on disk (previews and tests).
    public init(folder: URL?, fetch: @escaping @Sendable (URL) async throws -> (Data, URLResponse) = DomainLogos.fetchQuietly) {
        self.folder = folder
        self.fetch = fetch
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        if let data = folder.flatMap({ try? Data(contentsOf: $0.appending(path: "misses.json")) }),
           let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            misses = saved
        }
    }

    /// Whether a domain could have a logo of its own.
    public static func isCompanyDomain(_ domain: String) -> Bool {
        let lower = domain.lowercased()
        guard lower.contains("."), !lower.hasSuffix("privaterelay.appleid.com"),
              ![".example", ".test", ".invalid", ".local", ".localhost"].contains(where: lower.hasSuffix) else { return false }
        return !ProviderCatalog.all.contains { $0.domains.contains(lower) } && !freeMail.contains(lower)
    }

    /// Free-mail domains beyond the providers Margin lists.
    private static let freeMail: Set<String> = [
        "hotmail.nl", "hotmail.fr", "hotmail.de", "live.nl", "outlook.fr", "yahoo.nl", "ziggo.nl", "kpnmail.nl",
        "planet.nl", "home.nl", "xs4all.nl", "t-online.de", "web.de", "gmx.com", "mail.com", "yandex.com", "qq.com",
        "163.com", "icloud.com", "proton.me", "tutanota.com", "hey.com",
    ]

    /// The saved logo, if one was found before.
    public func saved(for domain: String) -> Data? {
        guard folder != nil else { return nil }
        return try? Data(contentsOf: file(for: domain.lowercased()))
    }

    /// The logo for a company domain: saved, or looked up once (and again after a week if none
    /// was found). Nil for free-mail domains and sites without a usable icon.
    public func logo(for domain: String) async -> Data? {
        let domain = domain.lowercased()
        guard Self.isCompanyDomain(domain) else { return nil }
        if let saved = saved(for: domain) { return saved }
        if let missed = misses[domain], Date().timeIntervalSince(missed) < Self.retryAfter { return nil }
        if let running = inFlight[domain] { return await running.value }
        let task = Task { await self.lookUp(domain) }
        inFlight[domain] = task
        let found = await task.value
        inFlight[domain] = nil
        if let found {
            if let folder { try? found.write(to: file(for: domain, in: folder)) }
        } else {
            misses[domain] = Date()
            if let folder, let data = try? JSONEncoder().encode(misses) { try? data.write(to: folder.appending(path: "misses.json")) }
        }
        return found
    }

    private func lookUp(_ domain: String) async -> Data? {
        for host in [domain, "www.\(domain)"] {
            guard let home = URL(string: "https://\(host)/") else { continue }
            var candidates: [URL] = []
            if let (data, response) = try? await fetch(home), let page = String(data: data.prefix(200_000), encoding: .utf8) {
                // Redirects (to www, or a language path) set the base for relative links.
                candidates = Self.iconLinks(in: page, base: response.url ?? home)
            }
            candidates += ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"].compactMap { URL(string: $0, relativeTo: home)?.absoluteURL }
            for url in candidates where url.scheme == "https" {
                guard let (data, response) = try? await fetch(url), (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count <= Self.maximumBytes, Self.isUsableImage(data) else { continue }
                return data
            }
        }
        return nil
    }

    /// Icons a page names, best first: apple-touch-icon, then other icons by declared size.
    /// SVG is left out (iOS can't draw it as an image).
    static func iconLinks(in html: String, base: URL) -> [URL] {
        let pattern = #"<link\b[^>]*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var found: [(url: URL, score: Int)] = []
        for match in expression.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: tag), !href.lowercased().hasSuffix(".svg"),
                  attribute("type", in: tag)?.lowercased() != "image/svg+xml",
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let side = attribute("sizes", in: tag)?.lowercased().split(separator: "x").first.flatMap { Int($0) } ?? 0
            let score = (rel.contains("apple-touch-icon") ? 10_000 : 0) + side
            found.append((url, score))
        }
        return found.sorted { $0.score > $1.score }.map(\.url)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 2...4 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    /// A bitmap at least `minimumSide` pixels on its shorter side.
    static func isUsableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return min(width, height) >= minimumSide
    }

    private func file(for domain: String, in folder: URL? = nil) -> URL {
        (folder ?? self.folder ?? FileManager.default.temporaryDirectory).appending(path: "\(domain).logo")
    }

    /// A plain fetch with a short timeout, no cookies.
    public static let fetchQuietly: @Sendable (URL) async throws -> (Data, URLResponse) = { url in
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        return try await URLSession.shared.data(for: request)
    }
}

extension ProviderCatalog {
    /// The provider an account belongs to: the one chosen when it was added, or the one whose
    /// servers it uses (a Microsoft 365 address on its own domain still reads as Microsoft).
    public static func preset(for account: MailAccount) -> ProviderPreset? {
        if let id = account.providerID, let found = preset(id: id) { return found }
        if let byDomain = preset(forDomain: account.address.domain) { return byDomain }
        guard case .imap(let incoming, _) = account.connection else {
            if case .jmap(let url) = account.connection { return all.first { $0.connection == .jmap(sessionURL: url) } }
            return nil
        }
        return all.first { preset in
            if case .imap(let known, _) = preset.connection { return known.host.lowercased() == incoming.host.lowercased() }
            return false
        }
    }
}
