#if canImport(UIKit)
import AVFoundation
import Combine
import SwiftUI

/// Hold-to-talk voice notes for the report sheet. Records 16 kHz mono WAV, which Whisper takes as-is
/// (about 1.9 MB a minute), capped at a minute.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case recorded(duration: TimeInterval)
        /// Recorded, but nothing louder than room noise: mic muted, covered, or nobody spoke.
        case silent
        case denied
    }

    static let maxDuration: TimeInterval = 60
    static let audioType = "audio/wav"

    @Published private(set) var state: State = .idle
    private var recorder: AVAudioRecorder?
    /// The finger is down. Permission is asynchronous, so a quick tap can lift before recording would begin.
    private var holding = false
    private(set) var audio: Data?
    private let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("mizu-voice-\(UUID().uuidString).wav")

    /// Asking for the mic without a usage description crashes the app, so the button only shows when the app has one.
    static var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    func start() {
        guard Self.isAvailable, recorder == nil else { return }
        holding = true
        audio = nil
        Task {
            guard await Self.requestPermission() else {
                state = .denied
                return
            }
            guard holding, recorder == nil else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
                try session.setActive(true)
                let recorder = try AVAudioRecorder(url: fileURL, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ])
                recorder.delegate = self
                recorder.record(forDuration: Self.maxDuration)
                self.recorder = recorder
                Mizu.timeline?.record("voice.start")
                state = .recording(since: Date())
            } catch {
                MizuLog.warn("Could not start recording: \(error)")
                state = .idle
            }
        }
    }

    func stop() {
        holding = false
        guard let recorder else { return }
        let duration = recorder.isRecording ? recorder.currentTime : Self.maxDuration
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Mizu.timeline?.record("voice.stop", ["ms": .int(Int(duration * 1000))])

        // A blip from a mis-tap isn't a voice note (and Whisper invents words for silence).
        guard duration >= 0.6, let data = try? Data(contentsOf: fileURL) else {
            discard()
            return
        }
        if AudioLevel.isSilent(wav: data) {
            discard()
            state = .silent
            return
        }
        audio = data
        state = .recorded(duration: duration)
    }

    func discard() {
        holding = false
        recorder?.stop()
        recorder = nil
        audio = nil
        try? FileManager.default.removeItem(at: fileURL)
        if state != .denied && state != .silent { state = .idle }
    }

    /// Hit the one-minute cap while still holding: keep what was recorded.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if case .recording = self.state { self.stop() }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17, *) {
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }
}

/// "hold to talk" — press and hold to record, let go to stop.
///
/// The view's structure never changes between states (only its text and colors do). If it did, SwiftUI would swap
/// in a new view mid-press and the finger's release would go to a view that no longer exists.
/// The square mic next to "send". Hold it to talk; let go to stop.
struct HoldToTalkButton: View {
    @ObservedObject var recorder: VoiceRecorder

    var body: some View {
        let recording = recorder.isRecording
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(recording ? Color.red : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(recording ? Color.red : Color.primary.opacity(0.25), lineWidth: 1))
            .overlay(
                Image(systemName: recording ? "waveform" : "mic")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(recording ? Color.white : Color.primary)
            )
            .frame(width: 54, height: 54)
            .scaleEffect(recording ? 1.06 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: recording)
            // SwiftUI gestures get cancelled by the sheet's own pan handling; a plain UIKit control doesn't.
            .overlay(PressTracker(onPress: { recorder.start() }, onRelease: { recorder.stop() }))
            .accessibilityLabel("Hold to record a voice note")
    }
}

/// One quiet line above the buttons: how to talk, the running clock, or what went wrong.
struct VoiceHint: View {
    @ObservedObject var recorder: VoiceRecorder
    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(recorder.isRecording ? Color.red : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onReceive(ticker) { now = $0 }
    }

    private var text: String {
        switch recorder.state {
        case .idle, .recorded: return "hold the mic to say it instead"
        case .recording(let since): return "● \(Self.clock(max(0, now.timeIntervalSince(since)))) · let go to stop"
        case .silent: return "didn't hear anything. hold and talk"
        case .denied: return "mic access is off (Settings)"
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension VoiceRecorder {
    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var recordedDuration: TimeInterval? {
        if case .recorded(let duration) = state { return duration }
        return nil
    }
}

/// Reports finger down and finger up (or cancel) — nothing else.
private struct PressTracker: UIViewRepresentable {
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeUIView(context: Context) -> Control {
        let control = Control()
        control.addTarget(context.coordinator, action: #selector(Coordinator.down), for: .touchDown)
        control.addTarget(context.coordinator, action: #selector(Coordinator.up), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return control
    }

    func updateUIView(_ uiView: Control, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Control: UIControl {
        // Stay pressed even if the finger wanders a bit while talking.
        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { true }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PressTracker
        init(parent: PressTracker) { self.parent = parent }
        @objc func down() { parent.onPress() }
        @objc func up() { parent.onRelease() }
    }
}
#endif
