import XCTest
@testable import Mizu

final class AudioLevelTests: XCTestCase {
    /// A 16 kHz mono 16-bit WAV, optionally with an extra chunk before `data` like AVAudioRecorder writes.
    private func wav(_ samples: [Int16], extraChunk: Bool = false) -> Data {
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataSize = samples.count * 2
        str("RIFF"); u32(0); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        if extraChunk { str("FLLR"); u32(6); d.append(Data(count: 6)) }
        str("data"); u32(dataSize)
        for s in samples { u16(Int(UInt16(bitPattern: s))) }
        return d
    }

    func testSilenceAndRoomNoiseAreSilent() {
        XCTAssertTrue(AudioLevel.isSilent(wav: wav(Array(repeating: 0, count: 16000))))
        XCTAssertTrue(AudioLevel.isSilent(wav: wav((0..<16000).map { _ in Int16.random(in: -30...30) })))
    }

    func testSpeechLevelIsNotSilent() {
        let speech = (0..<16000).map { i in Int16(8000 * sin(Double(i) / 10)) } // about -12 dBFS
        XCTAssertFalse(AudioLevel.isSilent(wav: wav(speech)))
        XCTAssertEqual(AudioLevel.peakDB(wav: wav(speech))!, -12.3, accuracy: 0.5)
    }

    func testFindsDataPastExtraChunks() {
        let speech = (0..<1600).map { i in Int16(8000 * sin(Double(i) / 10)) }
        XCTAssertFalse(AudioLevel.isSilent(wav: wav(speech, extraChunk: true)))
    }

    func testUnknownFormatsAreLeftToTheServer() {
        XCTAssertNil(AudioLevel.peakDB(wav: Data("not a wav".utf8)))
        XCTAssertFalse(AudioLevel.isSilent(wav: Data("not a wav".utf8)))
    }
}
