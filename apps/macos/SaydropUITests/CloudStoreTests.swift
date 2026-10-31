import Foundation
import Security
import XCTest
import SaydropCore
@testable import SaydropUI

@MainActor
private final class MemoryKeychainCredentialBacking: KeychainCredentialBacking {
    private(set) var records: [String: Data] = [:]
    var forcedReadStatus: OSStatus?
    var forcedAddStatus: OSStatus?
    var forcedUpdateStatus: OSStatus?
    private(set) var updatedAccounts: [String] = []

    func read(service: String, account: String) -> KeychainCredentialReadResult {
        if let forcedReadStatus { return .failure(forcedReadStatus) }
        guard let data = records[recordKey(service: service, account: account)] else { return .itemNotFound }
        return .value(data)
    }

    func add(data: Data, service: String, account: String) -> OSStatus {
        if let forcedAddStatus { return forcedAddStatus }
        let key = recordKey(service: service, account: account)
        guard records[key] == nil else { return errSecDuplicateItem }
        records[key] = data
        return errSecSuccess
    }

    func update(data: Data, service: String, account: String) -> OSStatus {
        updatedAccounts.append(account)
        if let forcedUpdateStatus { return forcedUpdateStatus }
        let key = recordKey(service: service, account: account)
        guard records[key] != nil else { return errSecItemNotFound }
        records[key] = data
        return errSecSuccess
    }

    func record(forAccount account: String) -> Data? {
        records.first { $0.key.hasSuffix("\u{001f}" + account) }?.value
    }

    func replaceRecord(forAccount account: String, with data: Data) {
        guard let key = records.keys.first(where: { $0.hasSuffix("\u{001f}" + account) }) else { return }
        records[key] = data
    }

    private func recordKey(service: String, account: String) -> String {
        service + "\u{001f}" + account
    }
}

@MainActor
private final class MemoryPendingTranscriptionBacking: PendingTranscriptionBacking {
    private(set) var records: [String: Data] = [:]
    private(set) var readCalls = 0

    func data(forKey key: String) -> Data? {
        readCalls += 1
        return records[key]
    }

    func set(_ data: Data?, forKey key: String) {
        records[key] = data
    }

    var onlyRecord: Data? { records.values.first ?? nil }

    func replaceOnlyRecord(with data: Data) {
        guard let key = records.keys.first else { return }
        records[key] = data
    }
}

@MainActor
final class CloudStoreTests: XCTestCase {
    private let firstOrigin = "https://one.example.test"
    private let secondOrigin = "https://two.example.test"

    private func credential(_ tokenCharacter: Character = "a", id: UUID = UUID()) -> InstallationCredential {
        InstallationCredential(installationID: id, accessToken: String(repeating: String(tokenCharacter), count: 43))
    }

    private func assertCredentialStorageError<T>(_ expression: @autoclosure () throws -> T,
                                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? CloudClientError, .credentialStorage, file: file, line: line)
        }
    }

    func testCredentialStorePartitionsOriginsAndStrictlyValidatesStoredOrigin() throws {
        let backing = MemoryKeychainCredentialBacking()
        let store = KeychainInstallationCredentialStore(backing: backing)
        let one = credential("a")
        let two = credential("b")

        try store.save(one, origin: firstOrigin)
        try store.save(two, origin: secondOrigin)

        XCTAssertEqual(backing.records.count, 2)
        XCTAssertEqual(try store.read(origin: firstOrigin), one)
        XCTAssertEqual(try store.read(origin: secondOrigin), two)

        let original = try XCTUnwrap(backing.record(forAccount: firstOrigin))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["version", "origin", "installationID", "accessToken"]))
        object["origin"] = secondOrigin
        backing.replaceRecord(forAccount: firstOrigin, with: try JSONSerialization.data(withJSONObject: object))

        assertCredentialStorageError(try store.read(origin: firstOrigin))
    }

    func testCredentialStoreRejectsInvalidInputsAndAllSecurityFailures() throws {
        let invalid = InstallationCredential(installationID: UUID(), accessToken: "not-a-valid-token")
        let backing = MemoryKeychainCredentialBacking()
        let store = KeychainInstallationCredentialStore(backing: backing)

        assertCredentialStorageError(try store.save(invalid, origin: firstOrigin))
        assertCredentialStorageError(try store.save(credential(), origin: "https://one.example.test/path"))
        XCTAssertEqual(backing.records.count, 0)

        backing.forcedAddStatus = errSecAuthFailed
        assertCredentialStorageError(try store.save(credential(), origin: firstOrigin))
        backing.forcedAddStatus = nil

        try store.save(credential("a"), origin: firstOrigin)
        backing.forcedReadStatus = errSecAuthFailed
        assertCredentialStorageError(try store.read(origin: firstOrigin))
        backing.forcedReadStatus = nil

        backing.forcedUpdateStatus = errSecAuthFailed
        assertCredentialStorageError(try store.save(credential("c"), origin: firstOrigin))
    }

    func testCredentialStoreUpdatesOnlySameOriginItem() throws {
        let backing = MemoryKeychainCredentialBacking()
        let store = KeychainInstallationCredentialStore(backing: backing)
        let one = credential("a")
        let two = credential("b")
        let replacement = credential("c")

        try store.save(one, origin: firstOrigin)
        try store.save(two, origin: secondOrigin)
        try store.save(replacement, origin: firstOrigin)

        XCTAssertEqual(try store.read(origin: firstOrigin), replacement)
        XCTAssertEqual(try store.read(origin: secondOrigin), two)
        XCTAssertEqual(backing.updatedAccounts, [firstOrigin])
    }

    func testPendingStoreRoundTripsOnlyPermittedMetadataAndPartitionsOrigins() throws {
        let backing = MemoryPendingTranscriptionBacking()
        let store = UserDefaultsPendingTranscriptionStore(backing: backing)
        let pending = PendingTranscription(id: UUID(), mode: .lightPolish, locallyCancelled: true)
        let other = PendingTranscription(id: UUID(), mode: .raw)

        try store.save(pending, origin: firstOrigin)
        let encoded = try XCTUnwrap(backing.onlyRecord)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "mode", "locallyCancelled"]))
        let encodedID = try XCTUnwrap(object["id"] as? String)
        XCTAssertEqual(UUID(uuidString: encodedID), pending.id)
        XCTAssertEqual(object["mode"] as? String, OutputMode.lightPolish.rawValue)
        XCTAssertEqual(object["locallyCancelled"] as? Bool, true)
        XCTAssertEqual(try store.read(origin: firstOrigin), pending)

        try store.save(other, origin: secondOrigin)
        XCTAssertEqual(backing.records.count, 2)
        XCTAssertEqual(try UserDefaultsPendingTranscriptionStore(backing: backing).read(origin: firstOrigin), pending)
        XCTAssertEqual(try store.read(origin: secondOrigin), other)
    }

    func testPendingStoreRejectsUnknownAndDamagedMetadataWithoutDeletingIt() throws {
        let backing = MemoryPendingTranscriptionBacking()
        let store = UserDefaultsPendingTranscriptionStore(backing: backing)
        let pending = PendingTranscription(id: UUID(), mode: .raw, locallyCancelled: false)
        try store.save(pending, origin: firstOrigin)

        let original = try XCTUnwrap(backing.onlyRecord)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["audio"] = "must-not-be-accepted"
        let unknownFieldRecord = try JSONSerialization.data(withJSONObject: object)
        backing.replaceOnlyRecord(with: unknownFieldRecord)
        assertCredentialStorageError(try store.read(origin: firstOrigin))
        XCTAssertEqual(backing.onlyRecord, unknownFieldRecord)

        let damagedRecord = Data("not-json".utf8)
        backing.replaceOnlyRecord(with: damagedRecord)
        assertCredentialStorageError(try store.read(origin: firstOrigin))
        XCTAssertEqual(backing.onlyRecord, damagedRecord)
    }

    func testPendingStoreRejectsInvalidOriginBeforeReadingBacking() throws {
        let backing = MemoryPendingTranscriptionBacking()
        let store = UserDefaultsPendingTranscriptionStore(backing: backing)

        assertCredentialStorageError(try store.read(origin: "http://example.test"))
        XCTAssertEqual(backing.readCalls, 0)
    }
}
