import Foundation
import MailCore
#if canImport(Contacts)
import Contacts
#endif

/// A CardDAV address book someone added. The password is in the Keychain.
public struct CardDAVBook: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var server: String
    public var username: String

    public init(id: UUID = UUID(), server: String, username: String) {
        self.id = id
        self.server = server
        self.username = username
    }

    var keychainKey: String { "carddav.\(id.uuidString)" }
}

/// Contacts from the Contacts app, from Microsoft and Google accounts, and from CardDAV, kept on
/// the device (`contacts.json`) and used for address suggestions.
extension MailModel {
    private var contactsFile: JSONFile<[Contact]> { JSONFile(url: environment.folder.appending(path: "contacts.json")) }

    /// Everyone from every address book that's turned on.
    public var contacts: [Contact] {
        if let contactStore { return contactStore }
        let loaded = environment.isPreview ? [] : (contactsFile.load() ?? [])
        contactStore = loaded
        return loaded
    }

    /// Use the Contacts app on this device. Asks for permission when turned on.
    public var usesSystemContacts: Bool {
        get { _ = contactSettingsRevision; return environment.defaults.bool(forKey: "usesSystemContacts") }
        set {
            environment.defaults.set(newValue, forKey: "usesSystemContacts")
            contactSettingsRevision += 1
            Task { await refreshContacts() }
        }
    }

    public var cardDAVBooks: [CardDAVBook] {
        get {
            _ = contactSettingsRevision
            return environment.defaults.data(forKey: "cardDAVBooks").flatMap { try? JSONDecoder().decode([CardDAVBook].self, from: $0) } ?? []
        }
        set {
            environment.defaults.set(try? JSONEncoder().encode(newValue), forKey: "cardDAVBooks")
            contactSettingsRevision += 1
        }
    }

    /// How many contacts came from each source, for Settings.
    public func contactCount(_ source: ContactSource) -> Int { contacts.filter { $0.source == source }.count }

    /// Adds a CardDAV address book after checking it can be read.
    public func addCardDAVBook(server: String, username: String, password: String) async throws {
        let client = CardDAVClient(server: server, username: username, password: password)
        _ = try await client.addressBooks()
        let book = CardDAVBook(server: server, username: username)
        try environment.keychain.save(password, key: book.keychainKey)
        cardDAVBooks.append(book)
        await refreshContacts()
    }

    public func removeCardDAVBook(_ id: CardDAVBook.ID) {
        guard let book = cardDAVBooks.first(where: { $0.id == id }) else { return }
        environment.keychain.delete(key: book.keychainKey)
        cardDAVBooks.removeAll { $0.id == id }
        contactProblems["carddav.\(id.uuidString)"] = nil
        Task { await refreshContacts() }
    }

    // MARK: Access beyond mail

    /// Reads what each OAuth account's extra tokens allow.
    func loadAPIAccess() async {
        var found: [UUID: Set<APIAccess>] = [:]
        for account in accounts {
            let access = await credentials.apiAccess(for: account)
            if !access.isEmpty { found[account.id] = access }
        }
        apiAccess = found
    }

    /// The OAuth provider of an account, when it has one.
    public func oauthProvider(of account: MailAccount) -> OAuthProviderID? {
        if case .oauth(let provider, _) = account.auth { return provider }
        return nil
    }

    /// Whether this build can ask the account's provider for more (it has a client id).
    public func canAskForAccess(_ account: MailAccount) -> Bool {
        oauthProvider(of: account).flatMap { environment.oauth.client(for: $0) } != nil
    }

    /// Asks the provider for more access in the sign-in sheet, keeping what was granted before.
    /// `authenticate` opens the sheet (the view's web authentication session) and returns the
    /// callback URL.
    public func requestAccess(_ wanted: Set<APIAccess>, for account: MailAccount,
                              authenticate: (URL, String) async throws -> URL) async throws {
        guard let provider = oauthProvider(of: account) else { return }
        let access = (apiAccess[account.id] ?? []).union(wanted)
        guard let client = environment.oauth.client(for: provider, access: access) else { throw MailError.missingCredentials }
        let request = client.authorizationRequest(loginHint: account.address.address)
        let callback = try await authenticate(request.url, client.callbackScheme)
        let tokens = try await client.exchange(callback: callback, verifier: request.verifier, state: request.state)
        // Another account said yes (one already signed in, picked by mistake): keep nothing.
        let mine = Set(([account.address] + (account.aliases ?? [])).map { $0.address.lowercased() })
        if let who = tokens.signedInAs, !mine.contains(who) {
            throw MailError.authenticationFailed(String(localized: "You signed in as \(who). Connect again and choose \(account.address.address)."))
        }
        try await credentials.saveAPITokens(APITokens(tokens: tokens, access: access), for: account)
        apiAccess[account.id] = access
        if wanted.contains(.contacts) { await refreshContacts() }
    }

    /// Stops using the account's contacts, calendar and rooms, and forgets the tokens.
    public func removeAccess(for account: MailAccount) {
        Task {
            await credentials.removeAPITokens(for: account)
            apiAccess[account.id] = nil
            contactProblems["account.\(account.id.uuidString)"] = nil
            await refreshContacts()
        }
    }

    // MARK: Refreshing

    /// Reads every address book that's turned on and keeps the result. Sources that fail keep
    /// their last contacts and note the problem.
    public func refreshContacts() async {
        guard !isRefreshingContacts, !environment.isPreview else { return }
        isRefreshingContacts = true
        defer { isRefreshingContacts = false }
        var previous = Dictionary(grouping: contacts, by: \.source)
        var gathered: [Contact] = []
        var problems: [String: String] = [:]

        for (key, source, adapter) in contactAdapters() {
            do {
                gathered += try await adapter().contacts()
            } catch {
                problems[key] = error.localizedDescription
                gathered += previous[source] ?? []
                previous[source] = nil
            }
        }
        var seen = Set<String>()
        // Pictures that came with the contacts go into the picture store; the list keeps a note.
        let unique = await savingPictures(of: gathered.filter { seen.insert($0.id).inserted })
        contactStore = unique
        contactProblems = problems
        contactsFile.save(unique)
        ContactPictures.shared.refresh()
    }

    /// People for what's typed in an address field beyond what's loaded: everyone on saved mail
    /// in every folder and mailbox (Sent included), then the work directories of mailboxes whose
    /// contacts are on (Microsoft 365). Empty when nothing matches.
    public func searchDirectories(_ text: String) async -> [EmailAddress] {
        await searchDirectories(text, in: accounts).map(\.person)
    }

    /// The same search, limited to some mailboxes' saved mail and directories, with where each
    /// person was found.
    func searchDirectories(_ text: String, in scope: [MailAccount]) async -> [(person: EmailAddress, source: PersonSource)] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2, !environment.isPreview else { return [] }
        let mine = Set(accounts.flatMap(\.sendAddresses).map { $0.address.lowercased() })
        let only = scope.count == accounts.count ? nil : Set(scope.map(\.id))
        var found: [(person: EmailAddress, source: PersonSource)] = await environment.cache.people(matching: typed, accounts: only)
            .filter { !mine.contains($0.address.lowercased()) }.map { ($0, .savedMail) }
        for account in scope where apiAccess[account.id]?.contains(.contacts) == true && oauthProvider(of: account) == .microsoft {
            guard let token = try? await credentials.apiToken(for: account) else { continue }
            let graph = MicrosoftGraphClient(accessToken: token)
            // People you deal with first, then anyone else in the organization.
            async let people = try? graph.searchPeople(typed)
            async let users = try? graph.searchUsers(typed)
            found += ((await people ?? []) + (await users ?? [])).map { ($0, .directory) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.person.address.lowercased()).inserted }
    }

    /// Every address book that's turned on, as adapters made when they're read (account tokens are
    /// fetched then): the Contacts app, connected accounts, and CardDAV servers.
    func contactAdapters() -> [(key: String, source: ContactSource, adapter: () async throws -> any ContactsAdapter)] {
        var list: [(key: String, source: ContactSource, adapter: () async throws -> any ContactsAdapter)] = []
        if usesSystemContacts { list.append(("system", .system, { SystemContacts() })) }
        for account in accounts where apiAccess[account.id]?.contains(.contacts) == true {
            guard let provider = oauthProvider(of: account) else { continue }
            list.append(("account.\(account.id.uuidString)", provider == .google ? .google : .microsoft, { [credentials] in
                let token = try await credentials.apiToken(for: account)
                return provider == .google ? GooglePeopleClient(accessToken: token) as any ContactsAdapter : MicrosoftGraphClient(accessToken: token)
            }))
        }
        for book in cardDAVBooks {
            let password = environment.keychain.read(key: book.keychainKey)
            list.append(("carddav.\(book.id.uuidString)", .carddav, {
                guard let password else { throw MailError.missingCredentials }
                return CardDAVClient(server: book.server, username: book.username, password: password)
            }))
        }
        return list
    }

    /// The Contacts app's people with an email address. Asks for permission the first time.
    nonisolated static func systemContacts() async throws -> [Contact] {
        #if canImport(Contacts)
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            guard try await store.requestAccess(for: .contacts) else { throw ContactsDenied() }
        } else if status != .authorized {
            throw ContactsDenied()
        }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey,
                    CNContactNicknameKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        return try await Task.detached {
            var found: [Contact] = []
            try store.enumerateContacts(with: request) { contact, _ in
                let emails = contact.emailAddresses.map { $0.value as String }
                guard !emails.isEmpty else { return }
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                found.append(Contact(id: "system:\(contact.identifier)", name: name.isEmpty ? contact.nickname : name,
                                     emails: emails, organization: contact.organizationName, source: .system,
                                     pictureData: contact.thumbnailImageData))
            }
            return found
        }.value
        #else
        return []
        #endif
    }
}

/// The Contacts app on this device, as an address book.
struct SystemContacts: ContactsAdapter {
    func contacts() async throws -> [Contact] { try await MailModel.systemContacts() }
}

struct ContactsDenied: LocalizedError {
    var errorDescription: String? {
        #if os(macOS)
        String(localized: "Margin isn't allowed to read Contacts. Turn it on in System Settings → Privacy & Security → Contacts.")
        #else
        String(localized: "Margin isn't allowed to read Contacts. Turn it on in Settings → Apps → Margin.")
        #endif
    }
}
