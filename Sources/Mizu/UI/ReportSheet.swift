#if canImport(UIKit)
import SwiftUI

/// The sheet that appears on shake. Typewriter-plain, like the website: a question, a note, a row of attachments,
/// and the mic next to "send".
struct ReportSheet: View {
    let screenshot: UIImage?
    let screen: String
    /// Set when this report answers Claude's repro request.
    let reproNote: String?
    let send: (_ note: String, _ attachScreenshot: Bool, _ audio: Data?, _ photos: [Data]) -> Void
    let dismiss: () -> Void

    @State private var note = ""
    @State private var attachScreenshot = true
    @State private var sent = false
    @State private var photos: [PickedPhoto] = []
    @State private var loadingPhotos = 0
    @StateObject private var recorder = VoiceRecorder()
    @FocusState private var noteFocused: Bool

    private let mono = Font.system(.body, design: .monospaced)
    private let small = Font.system(.footnote, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if sent {
                Spacer()
                Text("sent. now tell claude.").font(mono).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        question
                        noteField
                        attachments
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                bottomBar
            }
        }
        .onAppear { noteFocused = true }
    }

    // MARK: parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MIZU").font(.system(.caption, design: .monospaced).bold()).tracking(4)
            Spacer()
            Button("cancel") {
                recorder.discard()
                dismiss()
            }
            .font(small)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reproNote {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CLAUDE ASKED").font(.system(.caption2, design: .monospaced).bold()).tracking(2).foregroundStyle(.secondary)
                    Text(reproNote).font(small).fixedSize(horizontal: false, vertical: true).lineLimit(4)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 2) }
                .padding(.bottom, 10)
            }
            Text("what's off?").font(.system(.title3, design: .monospaced).weight(.semibold))
            Text("on \(ScreenName.spoken(screen))").font(small).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("the bottom nav jumps when…", text: $note, axis: .vertical)
                .font(mono)
                .lineLimit(3...10)
                .focused($noteFocused)
            Rectangle().fill(Color.primary.opacity(noteFocused ? 0.5 : 0.2)).frame(height: 1)
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if let screenshot { screenshotTile(screenshot) }
                    if let duration = recorder.recordedDuration { voiceTile(duration) }
                    PhotoAttachments(photos: $photos, loading: $loadingPhotos)
                }
                .padding(.top, 8)     // room for the corner badges
                .padding(.trailing, 8)
            }
            Text(attachmentsCaption)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .transaction { $0.animation = nil } // swap the words, don't cross-fade them
        }
    }

    private func screenshotTile(_ image: UIImage) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { attachScreenshot.toggle() } } label: {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64, alignment: .top)
                .mizuTile()
                .opacity(attachScreenshot ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            TileBadge(symbol: attachScreenshot ? "checkmark" : nil, filled: attachScreenshot) {
                withAnimation(.easeOut(duration: 0.15)) { attachScreenshot.toggle() }
            }
        }
        .accessibilityLabel(attachScreenshot ? "Screenshot attached. Tap to leave it out." : "Screenshot left out. Tap to attach it.")
    }

    private func voiceTile(_ duration: TimeInterval) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "waveform").font(.system(size: 18))
            Text(VoiceHint.clock(duration)).font(.system(.caption2, design: .monospaced))
        }
        .foregroundStyle(.primary)
        .mizuTile()
        .overlay(alignment: .topTrailing) {
            TileBadge(symbol: "xmark", filled: true) { recorder.discard() }
                .accessibilityLabel("Delete voice note")
        }
    }

    private var attachmentsCaption: String {
        if screenshot == nil { return "add photos, e.g. a mockup or a screenshot from another app" }
        return attachScreenshot ? "tap the screenshot to leave it out" : "screenshot left out"
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if VoiceRecorder.isAvailable { VoiceHint(recorder: recorder) }
            HStack(spacing: 10) {
                if VoiceRecorder.isAvailable { HoldToTalkButton(recorder: recorder) }
                Button {
                    recorder.stop()
                    send(note.trimmingCharacters(in: .whitespacesAndNewlines), attachScreenshot, recorder.audio, photos.map(\.jpeg))
                    withAnimation { sent = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: dismiss)
                } label: {
                    Text(loadingPhotos > 0 ? "adding photos…" : "send to claude →")
                        .font(.system(.body, design: .monospaced).bold())
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.primary.opacity(loadingPhotos > 0 ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(loadingPhotos > 0)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}
#endif
