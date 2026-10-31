import Foundation

public struct WAVMetadata: Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let dataBytes: Int
    public var duration: TimeInterval { Double(dataBytes) / Double(sampleRate * channels * bitsPerSample / 8) }
    public enum ValidationError: Error { case invalidWAV, tooLarge, tooLong, empty }
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= SaydropDefaults.maximumAudioBytes else { throw ValidationError.tooLarge }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24 }
        func tag(_ offset: Int) -> String { String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? "" }
        guard bytes.count >= 44, tag(0) == "RIFF", tag(8) == "WAVE", u32(4) == bytes.count - 8 else { throw ValidationError.invalidWAV }
        var offset = 12, formatFound = false, dataBytes: Int?
        while offset + 8 <= bytes.count {
            let type = tag(offset), length = u32(offset + 4), start = offset + 8
            guard length <= bytes.count - start else { throw ValidationError.invalidWAV }
            if type == "fmt " {
                guard !formatFound, length >= 16, u16(start) == 1, u16(start + 2) == 1,
                      u32(start + 4) == 16000, u32(start + 8) == 32000,
                      u16(start + 12) == 2, u16(start + 14) == 16 else { throw ValidationError.invalidWAV }
                formatFound = true
            } else if type == "data" {
                guard dataBytes == nil, length % 2 == 0 else { throw ValidationError.invalidWAV }
                dataBytes = length
            }
            offset = start + length + length % 2
        }
        guard offset == bytes.count, formatFound, let size = dataBytes else { throw ValidationError.invalidWAV }
        guard size > 0 else { throw ValidationError.empty }
        let value = Self(sampleRate: 16000, channels: 1, bitsPerSample: 16, dataBytes: size)
        guard value.duration <= SaydropDefaults.captureLimit else { throw ValidationError.tooLong }
        return value
    }
}
