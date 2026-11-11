import CryptoKit
import Foundation
import ImageIO
import MailCore
import SwiftUI
import UniformTypeIdentifiers

/// People's pictures, kept on this device as small files: one per address, named by a hash of
/// the address so the folder doesn't spell out who you know. A picture comes from the person's
/// entry in one of your own address books and nowhere else.
struct ContactPictureStore: Sendable {
    let folder: URL
    /// How long "no picture" is believed before the address book is asked again.
    static let missingFor: TimeInterval = 7 * 24 * 3600

    private func file(_ address: String, _ suffix: String) -> URL {
        let digest = SHA256.hash(data: Data(address.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: "\(digest).\(suffix)")
    }

    func data(for address: String) -> Data? {
        try? Data(contentsOf: file(address, "jpg"))
    }

    /// Saves the picture for each address, made small. False when the data isn't a picture.
    @discardableResult
    func save(_ data: Data, for addresses: [String]) -> Bool {
        guard let small = Self.thumbnail(data) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for address in addresses {
            try? small.write(to: file(address, "jpg"), options: .atomic)
            try? FileManager.default.removeItem(at: file(address, "none"))
        }
        return true
    }

    func markMissing(_ address: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data().write(to: file(address, "none"))
    }

    func isMarkedMissing(_ address: String, now: Date = Date()) -> Bool {
        guard let made = (try? file(address, "none").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
        return now.timeIntervalSince(made) < Self.missingFor
    }

    /// The picture as a JPEG no larger than `side` pixels either way, or nil when it isn't one.
    static func thumbnail(_ data: Data, side: Int = 192) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// The pictures now in memory, for every avatar in the app to draw from. An avatar asks for its
/// person once; when the picture arrives the avatar redraws with it.
@MainActor @Observable
public final class ContactPictures {
    public static let shared = ContactPictures()

    private var images: [String: Image] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    /// Finds a person's picture (the mail model sets this when it starts).
    @ObservationIgnored var load: (@MainActor (String) async -> Data?)?

    public func image(for address: String) -> Image? { images[address.lowercased()] }

    public func want(_ address: String) {
        let key = address.lowercased()
        guard let load, !key.isEmpty, images[key] == nil, asked.insert(key).inserted else { return }
        Task {
            guard let data = await load(key), let image = Self.image(from: data) else { return }
            images[key] = image
        }
    }

    /// The address books were read again: people without a picture get another look.
    public func refresh() {
        asked = []
    }

    static func image(from data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}

extension MailModel {
    var pictureStore: ContactPictureStore { ContactPictureStore(folder: environment.folder.appending(path: "pictures")) }

    /// Pictures that came with the contacts themselves (the Contacts app, vCards) are written to
    /// the picture store, and the contact keeps only a note that it has one.
    func savingPictures(of contacts: [Contact]) async -> [Contact] {
        let store = pictureStore
        return await Task.detached {
            contacts.map { contact in
                guard let data = contact.pictureData else { return contact }
                var kept = contact
                kept.pictureData = nil
                if store.save(data, for: contact.emails) { kept.picture = .saved }
                return kept
            }
        }.value
    }

    /// The picture for an address: your own mailbox's picture, one already saved, or one fetched
    /// from the address book the person is in (Google's or Microsoft's). Nil when they have none.
    func pictureData(for address: String) async -> Data? {
        let key = address.lowercased()
        if let mine = accounts.first(where: { $0.sendAddresses.contains { $0.address.lowercased() == key } })?.picture { return mine }
        guard !environment.isPreview else { return nil }
        let store = pictureStore
        if let saved = store.data(for: key) { return saved }
        guard !store.isMarkedMissing(key),
              let picture = contacts.first(where: { $0.picture != nil && $0.emails.contains { $0.lowercased() == key } })?.picture
        else { return nil }

        var found: Data?
        switch picture {
        case .saved:
            break
        case .url(let address):
            // Straight from the address the provider gave, with no cookies or account attached.
            if let url = URL(string: address), url.scheme == "https" {
                found = try? await URLSession(configuration: .ephemeral).data(from: url).0
            }
        case .microsoftContact, .microsoftUser:
            for account in accounts where apiAccess[account.id]?.contains(.contacts) == true && oauthProvider(of: account) == .microsoft {
                guard let token = try? await credentials.apiToken(for: account) else { continue }
                if let data = try? await MicrosoftGraphClient(accessToken: token).picture(picture) {
                    found = data
                    break
                }
            }
        }
        if let found, store.save(found, for: [key]) { return store.data(for: key) }
        store.markMissing(key)
        return nil
    }
}
