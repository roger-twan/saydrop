import Foundation
import SaydropCore

/// Data-only persistence boundary for the non-sensitive, restart-recovery
/// marker. Tests use an in-memory implementation and never touch UserDefaults.
@MainActor
protocol PendingTranscriptionBacking: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

@MainActor
private final class UserDefaultsPendingTranscriptionBacking: PendingTranscriptionBacking {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        defaults.set(data, forKey: key)
    }
}

private enum PendingStoreRecordDecodingError: Error {
    case invalid
}

private struct PendingStoreCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct StoredPendingTranscription: Codable {
    let id: UUID
    let mode: OutputMode
    let locallyCancelled: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case mode
        case locallyCancelled
    }

    init(_ pending: PendingTranscription) {
        id = pending.id
        mode = pending.mode
        locallyCancelled = pending.locallyCancelled
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: PendingStoreCodingKey.self)
        guard Set(rawContainer.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw PendingStoreRecordDecodingError.invalid
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mode = try container.decode(OutputMode.self, forKey: .mode)
        locallyCancelled = try container.decode(Bool.self, forKey: .locallyCancelled)
    }

    var pending: PendingTranscription {
        PendingTranscription(id: id, mode: mode, locallyCancelled: locallyCancelled)
    }
}

/// Persists only a recovery marker for one request per configured origin. It
/// intentionally contains no audio, transcription body, installation token or
/// other credential material. Corrupt records are retained and reported rather
/// than silently deleted, so the caller fails closed and can avoid a re-upload.
@MainActor
final class UserDefaultsPendingTranscriptionStore: PendingTranscriptionStoring {
    private let backing: any PendingTranscriptionBacking
    private let keyPrefix = "com.saydrop.pending-transcription.v1."

    init() {
        backing = UserDefaultsPendingTranscriptionBacking(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        backing = UserDefaultsPendingTranscriptionBacking(defaults: defaults)
    }

    init(backing: any PendingTranscriptionBacking) {
        self.backing = backing
    }

    func read(origin: String) throws -> PendingTranscription? {
        guard let key = key(for: origin) else { throw CloudClientError.credentialStorage }
        guard let data = backing.data(forKey: key) else { return nil }

        do {
            return try JSONDecoder().decode(StoredPendingTranscription.self, from: data).pending
        } catch {
            // Do not remove malformed metadata: deletion would make an unknown
            // request look absent and could lead a future caller to re-upload.
            throw CloudClientError.credentialStorage
        }
    }

    func save(_ pending: PendingTranscription?, origin: String) throws {
        guard let key = key(for: origin) else { throw CloudClientError.credentialStorage }
        guard let pending else {
            backing.set(nil, forKey: key)
            return
        }

        do {
            let data = try JSONEncoder().encode(StoredPendingTranscription(pending))
            backing.set(data, forKey: key)
        } catch {
            throw CloudClientError.credentialStorage
        }
    }

    private func key(for origin: String) -> String? {
        guard let origin = CloudStoreOrigin.canonical(origin),
              let data = origin.data(using: .utf8)
        else { return nil }
        let partition = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return keyPrefix + partition
    }
}
