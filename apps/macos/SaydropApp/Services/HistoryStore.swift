import Foundation
import CryptoKit
import Security
import SaydropCore

struct HistoryArchive: Codable {
    var version = 1
    var records: [HistoryRecord] = []
    var audio: [UUID: Data] = [:]
}

@MainActor
protocol HistoryStoring: AnyObject {
    func load() throws -> HistoryArchive
    func save(_ archive: HistoryArchive) throws
}

enum HistoryStorageError: Error { case unavailable, invalid }

/// Encrypted atomic archive; the 256-bit key stays in Keychain, never preferences.
@MainActor
final class EncryptedHistoryStore: HistoryStoring {
    private let url: URL
    private let backing: any KeychainCredentialBacking
    private let service = "com.saydrop.local-history-key.v1"
    private let account = "archive-aes-gcm-v1"
    private let context = Data("Saydrop local history v1".utf8)
    init(url: URL, backing: any KeychainCredentialBacking) { self.url = url; self.backing = backing }
    static func application() -> EncryptedHistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = Bundle.main.bundleIdentifier ?? "local.saydrop.dev"
        return EncryptedHistoryStore(url: base.appendingPathComponent(folder).appendingPathComponent("history-v1.enc"),
                                     backing: SecurityKeychainCredentialBacking())
    }
    private func key(create: Bool) throws -> SymmetricKey {
        switch backing.read(service: service, account: account) {
        case .value(let data):
            guard data.count == 32 else { throw HistoryStorageError.invalid }
            return SymmetricKey(data: data)
        case .itemNotFound:
            guard create else { throw HistoryStorageError.unavailable }
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            switch backing.add(data: data, service: service, account: account) {
            case errSecSuccess: return key
            case errSecDuplicateItem: return try self.key(create: false)
            default: throw HistoryStorageError.unavailable
            }
        case .failure: throw HistoryStorageError.unavailable
        }
    }
    func load() throws -> HistoryArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return HistoryArchive() }
        let data = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: key(create: false), authenticating: context)
        let archive = try JSONDecoder().decode(HistoryArchive.self, from: plain)
        guard archive.version == 1, Set(archive.records.map(\.id)).count == archive.records.count else { throw HistoryStorageError.invalid }
        return archive
    }
    func save(_ archive: HistoryArchive) throws {
        // An existing unreadable archive must never cause silent key replacement.
        let key = try key(create: !FileManager.default.fileExists(atPath: url.path))
        let plain = try JSONEncoder().encode(archive)
        guard let encrypted = try AES.GCM.seal(plain, using: key, authenticating: context).combined else { throw HistoryStorageError.invalid }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try encrypted.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
