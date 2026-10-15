import Foundation

/// Loudness of a 16-bit PCM WAV, so a voice note recorded with a muted or silent mic is caught on the phone
/// instead of uploading a minute of nothing.
enum AudioLevel {
    /// Below this peak there is no speech worth sending. Normal speech peaks around -20 to -6 dBFS.
    static let silenceThresholdDB: Double = -40

    /// Peak level in dBFS (0 is the loudest possible), or nil if this isn't 16-bit PCM WAV.
    static func peakDB(wav: Data) -> Double? {
        guard let samples = pcmSamples(wav), !samples.isEmpty else { return nil }
        let peak = samples.reduce(0) { max($0, abs(Int($1))) }
        guard peak > 0 else { return -.infinity }
        return 20 * log10(Double(peak) / Double(Int16.max))
    }

    static func isSilent(wav: Data) -> Bool {
        guard let peak = peakDB(wav: wav) else { return false } // unknown format: let the server decide
        return peak < silenceThresholdDB
    }

    /// Walks the RIFF chunks to the `data` chunk; AVAudioRecorder adds extra chunks, so the header isn't always 44 bytes.
    private static func pcmSamples(_ wav: Data) -> [Int16]? {
        let bytes = [UInt8](wav)
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { return nil }

        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }

        var offset = 12
        var bitsPerSample = 0
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " && body + 16 <= bytes.count {
                guard u16(body) == 1 else { return nil } // PCM only
                bitsPerSample = u16(body + 14)
            } else if id == "data" {
                guard bitsPerSample == 16 else { return nil }
                let end = min(body + size, bytes.count)
                var samples = [Int16]()
                samples.reserveCapacity((end - body) / 2)
                var i = body
                while i + 1 < end {
                    samples.append(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))
                    i += 2
                }
                return samples
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}
