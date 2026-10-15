#if canImport(UIKit)
import SwiftUI
import UIKit

/// "Claude asks: …" across the top of the app when Claude has asked for a repro (MCP `request_repro`).
/// An overlay on the app's own window, sized to the card, so it never moves the app's layout and every touch
/// outside it still reaches the app. Stays until tapped.
@MainActor
enum ReproBanner {
    /// Screenshots hide views with this tag.
    static let viewTag = 0x4D495A55 // "MIZU"
    private static var host: UIHostingController<BannerView>?

    /// Returns false if the app isn't on screen yet (e.g., mid-launch), so the caller can try again later.
    @discardableResult
    static func show(_ repro: RemoteConfig.Repro) -> Bool {
        if host != nil { return true }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return false }

        let controller = UIHostingController(rootView: BannerView(note: repro.note, report: {
            hide(repro)
            Mizu.showReporter()
        }, dismiss: {
            hide(repro)
        }))
        controller.view.backgroundColor = .clear
        controller.view.tag = viewTag
        let width = window.bounds.width
        let height = controller.sizeThatFits(in: CGSize(width: width, height: 400)).height
        controller.view.frame = CGRect(x: 0, y: window.safeAreaInsets.top + 4, width: width, height: height)
        controller.view.autoresizingMask = [.flexibleWidth]
        window.addSubview(controller.view)
        host = controller
        Mizu.timeline?.record("mizu.repro_shown", ["id": .string(repro.id)])
        return true
    }

    private static func hide(_ repro: RemoteConfig.Repro) {
        Mizu.configClient?.markSeen(repro)
        host?.view.removeFromSuperview()
        host = nil
    }
}

struct BannerView: View {
    let note: String
    let report: () -> Void
    let dismiss: () -> Void

    private let mono = Font.system(.callout, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLAUDE ASKS").font(.system(.caption, design: .monospaced).bold()).tracking(2)
            Text(note).font(mono).fixedSize(horizontal: false, vertical: true).lineLimit(3)
            HStack(spacing: 20) {
                Button("ok", action: dismiss)
                Button("report now →", action: report).bold()
                Spacer()
            }
            .font(mono)
        }
        .foregroundStyle(Color(uiColor: .systemBackground))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10)
    }
}
#endif
