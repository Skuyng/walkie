import Foundation

/// Wire audio shared with `public/index.html`.
///
/// Each WebSocket binary frame is raw PCM: signed 16-bit little-endian,
/// mono, 16 kHz, no header. The browser writes `sample * 32767` into an
/// `Int16Array` and plays received samples divided by 32768.
enum PCM16 {
    static let sampleRate: Double = 16_000

    static func encode(_ samples: [Float]) -> Data {
        var ints = [Int16](repeating: 0, count: samples.count)
        for index in samples.indices {
            var unit = samples[index]
            if !unit.isFinite { unit = 0 }
            if unit > 1 { unit = 1 }
            if unit < -1 { unit = -1 }
            ints[index] = Int16(unit * 32_767)
        }
        return ints.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return [] }
        var ints = [Int16](repeating: 0, count: count)
        let byteCount = count * MemoryLayout<Int16>.size
        _ = ints.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination, count: byteCount)
        }
        return ints.map { Float($0) / 32_768 }
    }
}
