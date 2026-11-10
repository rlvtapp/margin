import CommonCrypto
import CryptoKit
import Foundation

/// Seals a backup. The contents are encrypted with AES-GCM under a random key, and that key is
/// locked separately by each secret that may open the backup: the password, and optionally a
/// recovery key. PBKDF2-HMAC-SHA256 turns each secret into the key that locks it. Without any
/// secret the contents are stored as they are (and the app leaves secrets out).
public enum BackupBox {
    static let format = "margin-backup"
    static let rounds: UInt32 = 310_000

    public struct File: Codable, Sendable {
        var format: String
        var version: Int
        var encrypted: Bool
        /// One per secret that opens the backup.
        var slots: [Slot]?
        var contents: Data
    }

    struct Slot: Codable, Sendable {
        /// "password" or "recovery".
        var kind: String
        var salt: Data
        var rounds: UInt32
        /// The contents key, sealed with the key this secret makes.
        var key: Data
    }

    public enum Failure: LocalizedError, Equatable {
        case notABackup, needsPassword, wrongPassword
        public var errorDescription: String? {
            switch self {
            case .notABackup: String(localized: "This file isn't a Margin backup.")
            case .needsPassword: String(localized: "This backup is protected with a password.")
            case .wrongPassword: String(localized: "That password doesn't open this backup.")
            }
        }
    }

    /// Seals `contents` so the password, or the recovery key when given, opens it.
    public static func seal(_ contents: Data, password: String?, recoveryKey: String? = nil) throws -> Data {
        var file = File(format: format, version: 1, encrypted: false, contents: contents)
        let secrets = [("password", password), ("recovery", recoveryKey.map(normalized))]
            .compactMap { kind, secret in secret.flatMap { $0.isEmpty ? nil : (kind, $0) } }
        if !secrets.isEmpty {
            let contentsKey = SymmetricKey(size: .bits256)
            file.contents = try AES.GCM.seal(contents, using: contentsKey).combined ?? Data()
            file.slots = try secrets.map { kind, secret in
                let salt = randomBytes(16)
                let lock = try deriveKey(secret, salt: salt, rounds: rounds)
                let raw = contentsKey.withUnsafeBytes { Data($0) }
                return Slot(kind: kind, salt: salt, rounds: rounds, key: try AES.GCM.seal(raw, using: lock).combined ?? Data())
            }
            file.encrypted = true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    public static func isEncrypted(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(File.self, from: data))?.encrypted ?? false
    }

    /// Opens a backup with its password or its recovery key.
    public static func open(_ data: Data, password: String?) throws -> Data {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == format else { throw Failure.notABackup }
        guard file.encrypted else { return file.contents }
        guard let password, !password.isEmpty else { throw Failure.needsPassword }
        guard let slots = file.slots, !slots.isEmpty else { throw Failure.notABackup }
        for slot in slots {
            let secret = slot.kind == "recovery" ? normalized(password) : password
            guard let lock = try? deriveKey(secret, salt: slot.salt, rounds: slot.rounds),
                  let box = try? AES.GCM.SealedBox(combined: slot.key),
                  let raw = try? AES.GCM.open(box, using: lock) else { continue }
            do {
                return try AES.GCM.open(AES.GCM.SealedBox(combined: file.contents), using: SymmetricKey(data: raw))
            } catch {
                throw Failure.notABackup
            }
        }
        throw Failure.wrongPassword
    }

    /// A new recovery key: 24 letters and digits in groups of four, easy to write down.
    /// Characters that look alike (0/O, 1/I/L) are left out.
    public static func makeRecoveryKey() -> String {
        let characters = randomCharacters(24)
        return stride(from: 0, to: 24, by: 4).map { String(characters[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// A short code for moving settings to another device, like "K7QM-3XHP".
    public static func makeLinkCode() -> String {
        let characters = randomCharacters(8)
        return String(characters[0..<4]) + "-" + String(characters[4..<8])
    }

    /// Recovery keys and link codes match however they're typed: case, spaces and dashes don't matter.
    public static func normalized(_ key: String) -> String {
        key.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func randomCharacters(_ count: Int) -> [Character] {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        // 248 is the largest multiple of 31 below 256, so every character is equally likely.
        var result: [Character] = []
        while result.count < count {
            for byte in randomBytes(count * 2) where byte < 248 && result.count < count {
                result.append(alphabet[Int(byte) % alphabet.count])
            }
        }
        return result
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    static func deriveKey(_ password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        var key = Data(count: 32)
        let passwordBytes = Array(password.utf8)
        let status = key.withUnsafeMutableBytes { keyBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                    keyBuffer.bindMemory(to: UInt8.self).baseAddress, 32
                )
            }
        }
        guard status == kCCSuccess else { throw Failure.notABackup }
        return SymmetricKey(data: key)
    }
}
