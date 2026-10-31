import XCTest
@testable import SaydropRealtime

final class SaydropRealtimeTests: XCTestCase {
    func testPlanarMultichannelFramesAreInterleavedWithoutDroppingChannels() {
        let ring = sdrt_spsc_ring_create(8, 3)
        XCTAssertNotNil(ring)
        defer { sdrt_spsc_ring_destroy(ring) }

        var left: [Float] = [0.1, 0.2, 0.3]
        var center: [Float] = [1.1, 1.2, 1.3]
        var right: [Float] = [-0.1, -0.2, -0.3]
        let wrote = left.withUnsafeMutableBufferPointer { l in
            center.withUnsafeMutableBufferPointer { c in
                right.withUnsafeMutableBufferPointer { r in
                    var planes: [UnsafeMutablePointer<Float>?] = [l.baseAddress, c.baseAddress, r.baseAddress]
                    return planes.withUnsafeMutableBufferPointer { pointers in
                        sdrt_spsc_ring_write_planar_f32(ring, pointers.baseAddress, 3)
                    }
                }
            }
        }
        XCTAssertTrue(wrote)
        XCTAssertTrue(sdrt_spsc_ring_has_first_buffer(ring))
        XCTAssertEqual(sdrt_spsc_ring_available_frames(ring), 3)

        var output = Array(repeating: Float.zero, count: 9)
        let read = output.withUnsafeMutableBufferPointer {
            sdrt_spsc_ring_read_interleaved_f32(ring, $0.baseAddress, 3)
        }
        XCTAssertEqual(read, 3)
        XCTAssertEqual(output, [0.1, 1.1, -0.1, 0.2, 1.2, -0.2, 0.3, 1.3, -0.3])
    }

    func testFullRingRejectsWholeWriteAndNeverOverwritesUnreadFrames() {
        let ring = sdrt_spsc_ring_create(4, 1)
        XCTAssertNotNil(ring)
        defer { sdrt_spsc_ring_destroy(ring) }

        var initial: [Float] = [1, 2, 3, 4]
        XCTAssertTrue(initial.withUnsafeMutableBufferPointer {
            sdrt_spsc_ring_write_interleaved_f32(ring, $0.baseAddress, 4)
        })
        var rejected: [Float] = [9]
        XCTAssertFalse(rejected.withUnsafeMutableBufferPointer {
            sdrt_spsc_ring_write_interleaved_f32(ring, $0.baseAddress, 1)
        })
        XCTAssertTrue(sdrt_spsc_ring_take_overflow(ring))
        XCTAssertFalse(sdrt_spsc_ring_take_overflow(ring))

        var output = Array(repeating: Float.zero, count: 4)
        let read = output.withUnsafeMutableBufferPointer {
            sdrt_spsc_ring_read_interleaved_f32(ring, $0.baseAddress, 4)
        }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(output, initial)
    }

    func testRingWrapsInOrderAndResetsFirstBufferAcknowledgement() {
        let ring = sdrt_spsc_ring_create(4, 1)
        XCTAssertNotNil(ring)
        defer { sdrt_spsc_ring_destroy(ring) }

        var first: [Float] = [1, 2, 3]
        XCTAssertTrue(first.withUnsafeMutableBufferPointer {
            sdrt_spsc_ring_write_interleaved_f32(ring, $0.baseAddress, 3)
        })
        var prefix = Array(repeating: Float.zero, count: 2)
        XCTAssertEqual(prefix.withUnsafeMutableBufferPointer {
            sdrt_spsc_ring_read_interleaved_f32(ring, $0.baseAddress, 2)
        }, 2)
        XCTAssertEqual(prefix, [1, 2])

        sdrt_spsc_ring_reset_first_buffer(ring)
        XCTAssertFalse(sdrt_spsc_ring_has_first_buffer(ring))
        var tail: [Float] = [4, 5, 6]
        XCTAssertTrue(tail.withUnsafeMutableBufferPointer {
            sdrt_spsc_ring_write_interleaved_f32(ring, $0.baseAddress, 3)
        })
        XCTAssertTrue(sdrt_spsc_ring_has_first_buffer(ring))

        var output = Array(repeating: Float.zero, count: 4)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer {
            sdrt_spsc_ring_read_interleaved_f32(ring, $0.baseAddress, 4)
        }, 4)
        XCTAssertEqual(output, [3, 4, 5, 6])
    }
}
