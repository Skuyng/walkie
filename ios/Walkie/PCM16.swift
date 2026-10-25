import Foundation

/// Wire audio shared with `public/index.html`.
///
/// Each WebSocket binary frame is raw PCM: signed 16-bit little-endian,
/// mono, 16 kHz, no header. The browser writes `sample * 32767` into an
/// `Int16Array` and plays received samples divided by 32768.
enum PCM16 {
    static let sampleRate: Double = 16_000

    static func encode(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return Data() }
            return encode(base, count: pointer.count, limit: false)
        }
    }

    /// Writes PCM16 straight from the converter buffer. The knee matches the old limiter.
    static func encodeLimited(_ samples: UnsafeMutablePointer<Float>, count: Int) -> Data {
        encode(samples, count: count, limit: true)
    }

    private static func encode(_ samples: UnsafePointer<Float>, count: Int, limit: Bool) -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            guard let ints = raw.bindMemory(to: Int16.self).baseAddress else { return }
            let knee: Float = 0.7
            let ceiling: Float = 0.98
            let span: Float = 1 - knee
            for index in 0..<count {
                var unit = samples[index]
                if !unit.isFinite {
                    unit = 0
                } else if limit {
                    let sign: Float = unit < 0 ? -1 : 1
                    let magnitude = abs(unit)
                    if magnitude > knee {
                        let compressed = knee + span * (1 - exp(-(magnitude - knee) / span))
                        unit = sign * min(ceiling, compressed)
                    }
                }
                if unit > 1 { unit = 1 }
                if unit < -1 { unit = -1 }
                ints[index] = Int16(unit * 32_767)
            }
        }
        return data
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
