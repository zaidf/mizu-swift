#if canImport(UIKit)
import SwiftUI

/// The sheet that appears on shake. Typewriter-plain, like the website.
struct ReportSheet: View {
    let screenshot: UIImage?
    let screen: String
    /// Set when this report answers Claude's repro request.
    let reproNote: String?
    let send: (_ note: String, _ attachScreenshot: Bool, _ audio: Data?) -> Void
    let dismiss: () -> Void

    @State private var note = ""
    @State private var attachScreenshot = true
    @State private var sent = false
    @StateObject private var recorder = VoiceRecorder()
    @FocusState private var noteFocused: Bool

    private let mono = Font.system(.body, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MIZU").font(.system(.headline, design: .monospaced)).tracking(4)
                Spacer()
                Button("cancel") {
                    recorder.discard()
                    dismiss()
                }
                .font(mono)
                .foregroundStyle(.secondary)
            }

            if sent {
                Spacer()
                Text("sent. now tell claude.").font(mono).frame(maxWidth: .infinity)
                Spacer()
            } else {
                if let reproNote {
                    Text("claude asked: \(reproNote)")
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(Rectangle().stroke(.secondary.opacity(0.4)))
                }
                Text("what happened on \(screen)?").font(mono).foregroundStyle(.secondary)

                TextField("the bottom nav jumps when…", text: $note, axis: .vertical)
                    .font(mono)
                    .lineLimit(3...8)
                    .focused($noteFocused)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.5)))

                if VoiceRecorder.isAvailable {
                    HoldToTalkButton(recorder: recorder)
                }

                if let screenshot {
                    HStack(alignment: .top, spacing: 12) {
                        Image(uiImage: screenshot)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 120)
                            .overlay(Rectangle().stroke(.secondary.opacity(0.4)))
                            .opacity(attachScreenshot ? 1 : 0.3)
                        Toggle("attach\nscreenshot", isOn: $attachScreenshot)
                            .font(.system(.footnote, design: .monospaced))
                            .toggleStyle(.switch)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    recorder.stop()
                    send(note.trimmingCharacters(in: .whitespacesAndNewlines), attachScreenshot, recorder.audio)
                    withAnimation { sent = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: dismiss)
                } label: {
                    Text("send to claude →")
                        .font(.system(.body, design: .monospaced).bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .foregroundStyle(Color(uiColor: .systemBackground))
            }
        }
        .padding(20)
        .onAppear { noteFocused = true }
    }
}
#endif
