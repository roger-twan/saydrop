import XCTest
@testable import SaydropUI

final class CloudConfigurationTests: XCTestCase {
    func testProductionRejectsAllHTTPAndDevelopmentRejectsNonLoopback() {
        for value in ["http://127.0.0.1:8000", "http://example.test", "http://192.168.1.2:8000"] {
            XCTAssertThrowsError(try CloudConfiguration(baseURL: URL(string: value)!))
        }
        XCTAssertThrowsError(try CloudConfiguration(baseURL: URL(string: "http://192.168.1.2:8000")!, permitsLoopbackHTTP: true))
        XCTAssertNoThrow(try CloudConfiguration(baseURL: URL(string: "http://127.0.0.1:8000")!, permitsLoopbackHTTP: true))
        XCTAssertNoThrow(try CloudConfiguration(baseURL: URL(string: "http://[::1]:8000")!, permitsLoopbackHTTP: true))
    }
    func testRejectsURLCredentialsQueryFragmentAndNonRootPath() {
        for value in ["https://user:pass@example.test", "https://example.test?q=token", "https://example.test/#token", "https://example.test/api", "https://example.test:0"] {
            XCTAssertThrowsError(try CloudConfiguration(baseURL: URL(string: value)!))
        }
    }
    func testDefaultPortAndTrailingSlashHaveCanonicalOrigin() throws {
        let a = try CloudConfiguration(baseURL: URL(string: "https://example.test:443/")!)
        let b = try CloudConfiguration(baseURL: URL(string: "https://example.test")!)
        XCTAssertEqual(a.origin, b.origin)
    }
    func testCredentialsAreValidatedAndRedacted() {
        let credential = InstallationCredential(installationID: UUID(), accessToken: String(repeating: "A", count: 43))
        XCTAssertTrue(credential.isValid); XCTAssertFalse(credential.description.contains(credential.accessToken))
        XCTAssertFalse(InstallationCredential(installationID: UUID(), accessToken: "Bearer short").isValid)
    }
    func testDisclosureIdentityCannotAliasFieldSeparators() {
        let a = CloudDisclosure(version: "v1", receiver: "a\u{001f}b", purpose: "c", retention: "d")
        let b = CloudDisclosure(version: "v1", receiver: "a", purpose: "b\u{001f}c", retention: "d")
        XCTAssertNotEqual(a.identity, b.identity)
        XCTAssertFalse(CloudDisclosure(version: "v1", receiver: "", purpose: "p", retention: "r").isConfigured)
    }
}
