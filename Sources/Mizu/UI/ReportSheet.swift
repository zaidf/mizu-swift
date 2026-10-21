#if canImport(UIKit)
import SwiftUI

/// The sheet that appears on shake. Typewriter-plain, like the website: the question is the field itself, and one row
/// on the keyboard holds everything else: voice first, then what's attached, then send.
struct ReportSheet: View {
    let screenshot: UIImage?
    let screen: String
    /// Set when this report answers Claude's repro request.
    let reproNote: String?
    let send: (_ note: String, _ attachScreenshot: Bool, _ audio: Data?, _ photos: [Data]) -> Void
    let dismiss: () -> Void
    /// Tells the controller there's something to lose, so a swipe down asks first.
    let setDirty: (Bool) -> Void

    @State private var note = ""
    @State private var attachScreenshot = true
    @State private var sent = false
    @State private var photos: [PickedPhoto] = []
    @State private var loadingPhotos = 0
    @StateObject private var recorder = VoiceRecorder()
    @FocusState private var noteFocused: Bool

    private let margin: CGFloat = 24
    private static let sendSize: CGFloat = 76

    var body: some View {
        Group {
            if sent {
                Text("sent. now tell claude.")
                    .font(.system(.title3, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.keyboard) // stays put while the keyboard drops away
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let reproNote { claudeAsked(reproNote) }
                            noteField
                        }
                        .padding(.horizontal, margin)
                        .padding(.top, 50) // where the sheet's top corners finish curving
                        .padding(.bottom, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    attachmentHub
                }
            }
        }
        .onAppear { noteFocused = true }
        .onDisappear { recorder.discard() }
        .onChange(of: isDirty) { setDirty($0) }
        .background(AmbientGlow().ignoresSafeArea())
    }

    private var isDirty: Bool {
        !sent && (!note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty
            || recorder.isRecording || recorder.recordedDuration != nil)
    }

    // MARK: parts

    private var sendButton: some View {
        Button {
            recorder.stop()
            send(note.trimmingCharacters(in: .whitespacesAndNewlines), attachScreenshot, recorder.audio, photos.map(\.jpeg))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            noteFocused = false
            withAnimation(.easeOut(duration: 0.2)) { sent = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: dismiss)
        } label: {
            Group {
                if loadingPhotos > 0 {
                    ProgressView().tint(Color(uiColor: .systemBlue))
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 40))
                        // Light at the tail, bright at the tip: it brightens the way it flies.
                        .foregroundStyle(LinearGradient(
                            colors: [Color(red: 0.50, green: 0.76, blue: 1.00), Color(red: 0.00, green: 0.42, blue: 1.00)],
                            startPoint: .bottomLeading, endPoint: .topTrailing))
                        .offset(x: 5) // the symbol's own side bearing, so the tip meets the margin
                }
            }
            // The plane's edge lines up with the row's margin; the touch area reaches past it.
            .frame(width: 64, height: Self.sendSize, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loadingPhotos > 0)
        .accessibilityLabel(loadingPhotos > 0 ? "Adding photos" : "Send to Claude")
    }

    private func claudeAsked(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("claude asked").font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
            Text(text).font(.system(.callout, design: .monospaced)).fixedSize(horizontal: false, vertical: true).lineLimit(4)
        }
    }

    /// The question is the placeholder: it asks (three ways, in turn), then gets out of the way.
    private var noteField: some View {
        TextField("", text: $note, axis: .vertical)
            .font(.system(.title3, design: .monospaced))
            .lineLimit(3...12)
            .tint(.primary)
            .focused($noteFocused)
            .overlay(alignment: .topLeading) {
                if note.isEmpty { RotatingPrompt() }
            }
            .accessibilityLabel(RotatingPrompt.prompts[0])
    }

    /// Voice first, then the screenshot, a voice note, photos and "+", then send: everything that goes with the note,
    /// resting on the keyboard. Mic and send stay put while the middle scrolls, so a hold never turns into a scroll.
    private var attachmentHub: some View {
        VStack(alignment: .leading, spacing: 10) {
            if VoiceRecorder.isAvailable, VoiceHint.text(for: recorder.state) != nil {
                VoiceHint(recorder: recorder).transition(.opacity)
            }
            HStack(alignment: .top, spacing: 12) {
                if VoiceRecorder.isAvailable {
                    HoldToTalkButton(recorder: recorder).padding(.top, TileBadge.overhang)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        if let screenshot { screenshotTile(screenshot) }
                        if let duration = recorder.recordedDuration { voiceTile(duration) }
                        PhotoAttachments(photos: $photos, loading: $loadingPhotos)
                    }
                    .padding(.top, TileBadge.overhang)
                    .padding(.trailing, TileBadge.overhang)
                }
                sendButton
                    .padding(.top, TileBadge.overhang + (MizuTile.height - Self.sendSize) / 2)
            }
        }
        .animation(.easeOut(duration: 0.2), value: VoiceHint.text(for: recorder.state) == nil)
        .padding(.horizontal, margin)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    /// The screen as it was, at its real proportions. ✕ leaves it out; tap again to put it back.
    private func screenshotTile(_ image: UIImage) -> some View {
        let width = (MizuTile.height * image.size.width / max(image.size.height, 1)).rounded()
        let toggle = { withAnimation(.easeOut(duration: 0.15)) { attachScreenshot.toggle() } }
        return Button(action: toggle) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .mizuTile(width: width)
                .opacity(attachScreenshot ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            TileBadge(symbol: attachScreenshot ? "xmark" : "plus", action: toggle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attachScreenshot ? "Screenshot attached" : "Screenshot left out")
        .accessibilityHint(attachScreenshot ? "Double-tap to leave it out." : "Double-tap to attach it.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
    }

    private func voiceTile(_ duration: TimeInterval) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform").font(.system(size: 17, weight: .regular))
            Text(VoiceHint.clock(duration)).font(.system(.caption, design: .monospaced))
        }
        .foregroundStyle(.primary)
        .mizuTile(filled: true)
        .overlay(alignment: .topTrailing) {
            TileBadge(symbol: "xmark") { recorder.discard() }
                .accessibilityLabel("Delete voice note")
        }
    }
}

/// The app Mizu is running in, by the name on the home screen.
enum HostApp {
    static let name: String = {
        let info = Bundle.main.localizedInfoDictionary ?? [:]
        return (info["CFBundleDisplayName"] ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName")) as? String ?? "this app"
    }()
}

/// The empty field's placeholder: three questions, three seconds each, fading out and in. It only exists while the
/// note is empty, so typing stops it and clearing the note starts it again.
private struct RotatingPrompt: View {
    static let prompts: [String] = {
        let app = HostApp.name
        return [
            "what's not working?",
            "what do you wish \(app) could do?",
            "what pisses you off about \(app)?",
        ]
    }()

    @State private var index = 0
    @State private var visible = true

    var body: some View {
        Text(Self.prompts[index])
            .font(.system(.title3, design: .monospaced))
            .foregroundStyle(.secondary)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true) // the field carries the question
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation(.easeIn(duration: 0.35)) { visible = false }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    index = (index + 1) % Self.prompts.count
                    withAnimation(.easeOut(duration: 0.45)) { visible = true }
                }
            }
    }
}
#endif
