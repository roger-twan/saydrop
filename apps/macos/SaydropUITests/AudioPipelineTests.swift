import XCTest
import SaydropCore
@testable import SaydropUI

@MainActor
final class AudioPipelineTests: XCTestCase {
    func testAllNativeChannelsContributeToMeanDownmix() throws {
        let channels = [Array(repeating: Float(0.6), count: 1600), Array(repeating: Float(0.2), count: 1600), Array(repeating: Float(-0.2), count: 1600)]
        let captured = try AudioPipeline.convertPlanarFloat32ForTesting(channels, sampleRate: 16_000)
        XCTAssertEqual(captured.rms, 0.2, accuracy: 0.002)
    }
    func testMultipleInputChunksDoNotReplayOrDropFramesAtFortyFourK() throws {
        let captured = try AudioPipeline.convertPlanarFloat32ForTesting([Array(repeating: Float(0.25), count: 44_100 * 3)], sampleRate: 44_100)
        XCTAssertEqual(captured.duration, 3, accuracy: 0.003)
        XCTAssertLessThanOrEqual(abs(captured.frameCount - 48_000), 48)
    }
    func testEightKInputIsUpsampledToCanonicalWAV() throws {
        let captured = try AudioPipeline.convertPlanarFloat32ForTesting([Array(repeating: Float(0.25), count: 800)], sampleRate: 8_000)
        XCTAssertEqual(captured.duration, 0.1, accuracy: 0.003)
        XCTAssertEqual(try WAVMetadata.parse(captured.wav).sampleRate, 16_000)
    }
    func testNonFiniteSourceSamplesAreRejected() {
        XCTAssertThrowsError(try AudioPipeline.convertPlanarFloat32ForTesting([[Float.nan]], sampleRate: 16_000))
    }
    func testSyntheticPlanarMultichannelPCMConvertsToValidatedMonoWAV() throws {
        let sourceFrames = 4_800 // 100 ms at 48 kHz
        let left = Array(repeating: Float(0.60), count: sourceFrames)
        let center = Array(repeating: Float(0.20), count: sourceFrames)
        let right = Array(repeating: Float(-0.20), count: sourceFrames)

        let captured = try AudioPipeline.convertPlanarFloat32ForTesting(
            [left, center, right],
            sampleRate: 48_000
        )
        let metadata = try WAVMetadata.parse(captured.wav)

        XCTAssertEqual(metadata.sampleRate, 16_000)
        XCTAssertEqual(metadata.channels, 1)
        XCTAssertEqual(metadata.bitsPerSample, 16)
        XCTAssertEqual(captured.frameCount, metadata.dataBytes / 2)
        XCTAssertEqual(captured.duration, metadata.duration, accuracy: 0.000_001)
        XCTAssertEqual(captured.duration, 0.1, accuracy: 0.003)
        XCTAssertGreaterThan(captured.rms, 0.05)
    }

    func testSyntheticPCMIsAccuratelyClampedToOneHundredTwentySeconds() throws {
        let permittedFrames = Int(SaydropDefaults.captureLimit * 16_000)
        let samples = Array(repeating: Float(0.25), count: permittedFrames + 257)

        let captured = try AudioPipeline.convertPlanarFloat32ForTesting([samples], sampleRate: 16_000)
        let metadata = try WAVMetadata.parse(captured.wav)

        XCTAssertEqual(captured.frameCount, permittedFrames)
        XCTAssertEqual(metadata.dataBytes, permittedFrames * 2)
        XCTAssertEqual(captured.duration, SaydropDefaults.captureLimit, accuracy: 0.000_001)
    }

    func testSyntheticNearSilentPCMReturnsExplicitErrorWhenPolicyIsEnabled() throws {
        let silence = Array(repeating: Float.zero, count: 1_600)

        XCTAssertThrowsError(
            try AudioPipeline.convertPlanarFloat32ForTesting(
                [silence],
                sampleRate: 16_000,
                silenceRMSFloor: 0.01
            )
        ) { error in
            guard case AudioPipelineError.nearSilent = error else {
                return XCTFail("Expected nearSilent error, got \(error)")
            }
        }
    }
}
