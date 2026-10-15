#if canImport(UIKit)
import SwiftUI
import UIKit

/// A card across the top of the app: "Claude asks: …" (a repro request) or "Fixed: …" (something this install
/// reported). An overlay on the app's own window, sized to the card, so it never moves the app's layout and every
/// touch outside it still reaches the app. One at a time; stays until tapped.
@MainActor
enum MizuBanner {
    /// Screenshots hide views with this tag.
    static let viewTag = 0x4D495A55 // "MIZU"
    private static var host: UIHostingController<BannerView>?

    /// Returns false if it can't show right now (app not on screen yet, or another banner is up), so the caller
    /// can try again on the next check-in.
    @discardableResult
    static func show(title: String, message: String, detail: String? = nil, action: (title: String, run: () -> Void)? = nil,
                     onClose: @escaping () -> Void) -> Bool {
        if host != nil { return false }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return false }

        let close = {
            host?.view.removeFromSuperview()
            host = nil
            onClose()
        }
        let controller = UIHostingController(rootView: BannerView(
            title: title, message: message, detail: detail,
            actionTitle: action?.title,
            action: { close(); action?.run() },
            dismiss: close
        ))
        controller.view.backgroundColor = .clear
        controller.view.tag = viewTag
        let width = window.bounds.width
        let height = controller.sizeThatFits(in: CGSize(width: width, height: 400)).height
        controller.view.frame = CGRect(x: 0, y: window.safeAreaInsets.top + 4, width: width, height: height)
        controller.view.autoresizingMask = [.flexibleWidth]
        window.addSubview(controller.view)
        host = controller
        return true
    }
}

/// "Claude asks: …" when Claude has asked for a repro (MCP `request_repro`).
@MainActor
enum ReproBanner {
    @discardableResult
    static func show(_ repro: RemoteConfig.Repro) -> Bool {
        let shown = MizuBanner.show(
            title: "CLAUDE ASKS", message: repro.note,
            action: (title: "report now →", run: { Mizu.showReporter(trigger: "repro_request") }),
            onClose: { Mizu.configClient?.markSeen(repro) }
        )
        if shown { Mizu.timeline?.record("mizu.repro_shown", ["id": .string(repro.id)]) }
        return shown
    }
}

/// "Fixed: …" when something this install reported was fixed (MCP `resolve_report` / `update_request`).
@MainActor
enum FixedBanner {
    @discardableResult
    static func show(_ notice: FixedNotice) -> Bool {
        let shipped = notice.kind == "request"
        let shown = MizuBanner.show(
            title: shipped ? "SHIPPED" : "FIXED",
            message: notice.note ?? (shipped ? "Something you asked for is in the app now." : "Something you reported is fixed."),
            detail: "you \(shipped ? "asked" : "reported"): \"\(notice.what)\"",
            onClose: { Mizu.configClient?.acknowledge(notice) }
        )
        if shown { Mizu.timeline?.record("mizu.fixed_shown", ["id": .string(notice.id)]) }
        return shown
    }
}

struct BannerView: View {
    let title: String
    let message: String
    let detail: String?
    let actionTitle: String?
    let action: () -> Void
    let dismiss: () -> Void

    private let mono = Font.system(.callout, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(.caption, design: .monospaced).bold()).tracking(2)
            Text(message).font(mono).fixedSize(horizontal: false, vertical: true).lineLimit(4)
            if let detail {
                Text(detail).font(.system(.caption, design: .monospaced)).opacity(0.75).lineLimit(2)
            }
            HStack(spacing: 20) {
                Button("ok", action: dismiss)
                if let actionTitle { Button(actionTitle, action: action).bold() }
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
