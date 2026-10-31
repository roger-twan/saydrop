import Foundation
import Security
import XCTest
import SaydropCore
@testable import SaydropUI

@MainActor
private final class HistoryKeyFake: KeychainCredentialBacking {
    var data: Data?
    var fails = false
    func read(service: String, account: String) -> KeychainCredentialReadResult {
        if fails { return .failure(errSecAuthFailed) }
        return data.map { .value($0) } ?? .itemNotFound
    }
    func add(data: Data, service: String, account: String) -> OSStatus {
        guard !fails else { return errSecAuthFailed }
        self.data = data; return errSecSuccess
    }
    func update(data: Data, service: String, account: String) -> OSStatus { XCTFail("Unexpected key update"); return errSecAuthFailed }
}

@MainActor
final class HistoryStoreTests: XCTestCase {
    private func fixture() -> HistoryArchive {
        let record = SavePolicy(audioEnabled: true, textEnabled: true).record(
            result: SessionResult(rawText: "private history", outputText: "private output", targetName: "Editor"),
            at: Date(), duration: 2, mode: .raw, outcome: .confirmed, audioAvailable: true)!
        return HistoryArchive(records: [record], audio: [record.id: Data("private audio".utf8)])
    }
    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.enc")
    }
    func testEncryptedRoundTripAndDeletion() throws {
        let path = url(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let backing = HistoryKeyFake(), archive = fixture()
        let store = EncryptedHistoryStore(url: path, backing: backing)
        XCTAssertTrue(try store.load().records.isEmpty)
        try store.save(archive)
        let bytes = try Data(contentsOf: path)
        XCTAssertNil(bytes.range(of: Data("private".utf8)))
        XCTAssertEqual(backing.data?.count, 32)
        let reopened = EncryptedHistoryStore(url: path, backing: backing)
        XCTAssertEqual(try reopened.load().records, archive.records)
        XCTAssertEqual(try reopened.load().audio, archive.audio)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try reopened.save(HistoryArchive())
        XCTAssertTrue(try reopened.load().records.isEmpty)
        XCTAssertTrue(try reopened.load().audio.isEmpty)
    }
    func testTamperOrMissingKeyDoesNotOverwriteArchive() throws {
        let path = url(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let backing = HistoryKeyFake(), store = EncryptedHistoryStore(url: path, backing: HistoryKeyFake())
        try store.save(fixture())
        let original = try Data(contentsOf: path)
        let noKey = EncryptedHistoryStore(url: path, backing: backing)
        XCTAssertThrowsError(try noKey.load())
        XCTAssertThrowsError(try noKey.save(HistoryArchive()))
        XCTAssertNil(backing.data); XCTAssertEqual(try Data(contentsOf: path), original)
        var corrupted = original; corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: path)
        XCTAssertThrowsError(try store.load())
    }
    func testKeychainFailureCreatesNoHistoryFile() {
        let path = url(); let backing = HistoryKeyFake(); backing.fails = true
        let store = EncryptedHistoryStore(url: path, backing: backing)
        XCTAssertThrowsError(try store.save(fixture()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
}
