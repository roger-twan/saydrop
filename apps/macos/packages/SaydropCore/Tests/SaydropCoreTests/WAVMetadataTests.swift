import Foundation
import XCTest
@testable import SaydropCore

final class WAVMetadataTests: XCTestCase {
    func wav(samples: Int, rate: Int = 16000) -> Data {
        var data = Data()
        func tag(_ string: String) { data.append(contentsOf: string.utf8) }
        func short(_ value: UInt16) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func long(_ value: UInt32) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        tag("RIFF"); long(UInt32(36 + samples * 2)); tag("WAVE"); tag("fmt "); long(16)
        short(1); short(1); long(UInt32(rate)); long(UInt32(rate * 2)); short(2); short(16)
        tag("data"); long(UInt32(samples * 2)); data.append(Data(repeating: 1, count: samples * 2)); return data
    }
    func testCanonicalPCMMetadata() throws { let info = try WAVMetadata.parse(wav(samples: 16000)); XCTAssertEqual(info.duration, 1); XCTAssertEqual(info.channels, 1); XCTAssertEqual(info.bitsPerSample, 16) }
    func testExactly120SecondsAllowed() throws { XCTAssertEqual(try WAVMetadata.parse(wav(samples: 16000 * 120)).duration, 120) }
    func testOver120SecondsRejected() { XCTAssertThrowsError(try WAVMetadata.parse(wav(samples: 16000 * 120 + 1))) }
    func testWrongSampleRateRejected() { XCTAssertThrowsError(try WAVMetadata.parse(wav(samples: 10, rate: 48000))) }
    func testTruncatedAndEmptyRejected() { var data = wav(samples: 10); data.removeLast(); XCTAssertThrowsError(try WAVMetadata.parse(data)); XCTAssertThrowsError(try WAVMetadata.parse(wav(samples: 0))) }
    func testOverEightMiBRejected() { XCTAssertThrowsError(try WAVMetadata.parse(Data(repeating: 0, count: SaydropDefaults.maximumAudioBytes + 1))) }
}
