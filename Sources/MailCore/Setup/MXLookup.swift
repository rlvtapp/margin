import Foundation
import dnssd

/// Where a domain's mail goes (its MX records), asked of the device's own DNS resolver, so a
/// custom domain on iCloud, Google Workspace, Microsoft 365 or Fastmail is recognised. Only the
/// domain is looked up; nothing goes to anyone else.
enum MXLookup {
    static func hosts(for domain: String, timeout: TimeInterval = 3) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: query(domain, timeout: timeout))
            }
        }
    }

    private final class Answers {
        var hosts: [(preference: Int, host: String)] = []
        var moreComing = true
    }

    private static func query(_ domain: String, timeout: TimeInterval) -> [String] {
        let answers = Answers()
        var reference: DNSServiceRef?
        let context = Unmanaged.passUnretained(answers).toOpaque()
        let reply: DNSServiceQueryRecordReply = { _, flags, _, error, _, _, _, length, data, _, context in
            guard let context else { return }
            let answers = Unmanaged<Answers>.fromOpaque(context).takeUnretainedValue()
            answers.moreComing = flags & kDNSServiceFlagsMoreComing != 0
            guard error == kDNSServiceErr_NoError, let data, length > 3 else { return }
            if let record = MXLookup.parse(UnsafeRawBufferPointer(start: data, count: Int(length))) {
                answers.hosts.append(record)
            }
        }
        guard DNSServiceQueryRecord(&reference, 0, 0, domain, UInt16(kDNSServiceType_MX), UInt16(kDNSServiceClass_IN),
                                    reply, context) == kDNSServiceErr_NoError, let reference else { return [] }
        defer { DNSServiceRefDeallocate(reference) }
        let socket = DNSServiceRefSockFD(reference)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var waiting = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard poll(&waiting, 1, milliseconds) > 0, DNSServiceProcessResult(reference) == kDNSServiceErr_NoError else { break }
        } while answers.moreComing && Date() < deadline
        return answers.hosts.sorted { $0.preference < $1.preference }.map(\.host)
    }

    /// An MX record's data: two bytes of preference, then the host as length-prefixed labels.
    static func parse(_ bytes: UnsafeRawBufferPointer) -> (preference: Int, host: String)? {
        guard bytes.count > 3 else { return nil }
        let preference = Int(bytes[0]) << 8 | Int(bytes[1])
        var labels: [String] = []
        var index = 2
        while index < bytes.count {
            let length = Int(bytes[index])
            if length == 0 { break }
            index += 1
            guard index + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[index..<index + length], as: UTF8.self))
            index += length
        }
        return labels.isEmpty ? nil : (preference, labels.joined(separator: ".").lowercased())
    }
}

extension ProviderCatalog {
    /// The provider whose servers a domain's mail goes to, by its MX hosts.
    public static func preset(forMXHosts hosts: [String]) -> ProviderPreset? {
        let rules: [(suffix: String, id: String)] = [
            ("mail.icloud.com", "icloud"),
            ("google.com", "google"), ("googlemail.com", "google"),
            ("mail.protection.outlook.com", "microsoft"), ("outlook.com", "microsoft"),
            ("messagingengine.com", "fastmail"),
            ("zoho.com", "zoho"), ("zoho.eu", "zoho"),
            ("protonmail.ch", "proton"),
        ]
        for host in hosts {
            if let rule = rules.first(where: { host == $0.suffix || host.hasSuffix("." + $0.suffix) }) {
                return preset(id: rule.id)
            }
        }
        return nil
    }
}
