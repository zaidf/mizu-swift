#if canImport(UIKit)
import SwiftUI
import UIKit

extension UIWindow {
    // Shake anywhere in the app opens the report sheet.
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake, Mizu.isRunning, Mizu.options.shakeToReport {
            Mizu.showReporter()
            return
        }
        super.motionEnded(motion, with: event)
    }
}

@MainActor
enum ReporterPresenter {
    static func present() {
        guard let scene = activeScene(), let window = scene.keyWindow ?? scene.windows.first else { return }
        guard let top = topViewController(window.rootViewController) else { return }
        if top is ReportSheetController { return }

        // Capture before the sheet covers anything, and before typing the note adds its own taps.
        let shot = Screenshot.capture(scene)
        let context = Mizu.contextParts(trigger: "shake")
        let screen = Mizu.currentScreen() ?? ScreenName.from(typeName: String(describing: type(of: top)))

        let controller = ReportSheetController(screenshot: shot?.image, screen: screen,
                                               reproNote: Mizu.configClient?.activeRepro?.note) { note, attach, audio in
            var parts = context
            if attach, let jpeg = shot?.jpeg { parts.append(OutboxPart(name: "screenshot", contentType: "image/jpeg", data: jpeg)) }
            if let audio { parts.append(OutboxPart(name: "audio", contentType: VoiceRecorder.audioType, data: audio)) }
            parts += Mizu.attachmentParts()
            Mizu.report(note: note, screen: screen, parts: parts)
        }
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        top.present(controller, animated: true)
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func topViewController(_ root: UIViewController?) -> UIViewController? {
        var current = root
        while true {
            if let presented = current?.presentedViewController, !presented.isBeingDismissed {
                current = presented
            } else if let nav = current as? UINavigationController, let visible = nav.visibleViewController {
                current = visible
            } else if let tabs = current as? UITabBarController, let selected = tabs.selectedViewController {
                current = selected
            } else {
                return current
            }
        }
    }
}

final class ReportSheetController: UIHostingController<ReportSheet> {
    init(screenshot: UIImage?, screen: String, reproNote: String?, send: @escaping (String, Bool, Data?) -> Void) {
        var dismiss: () -> Void = {}
        super.init(rootView: ReportSheet(screenshot: screenshot, screen: screen, reproNote: reproNote, send: send, dismiss: { dismiss() }))
        dismiss = { [weak self] in self?.dismiss(animated: true) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

enum Screenshot {
    /// JPEG of whatever is on screen in the active scene, for `Mizu.shareDebug`.
    @MainActor
    static func captureActiveScene() -> Data? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return nil }
        return capture(scene)?.jpeg
    }

    @MainActor
    static func capture(_ scene: UIWindowScene) -> (image: UIImage, jpeg: Data)? {
        let bounds = scene.screen.bounds
        // Mizu's own banner isn't part of the app.
        let banners = scene.windows.compactMap { $0.viewWithTag(MizuBanner.viewTag) }.filter { !$0.isHidden }
        banners.forEach { $0.isHidden = true }
        defer { banners.forEach { $0.isHidden = false } }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(scene.screen.scale, 2) // keeps uploads ~200 KB
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            // The keyboard lives in system windows that render as solid black here, so draw only the app's own.
            let windows = scene.windows
                .filter { !$0.isHidden && $0.alpha > 0 && !UIKitObserver.isSystemInputWindow($0) }
                .sorted { $0.windowLevel < $1.windowLevel }
            for window in windows where !window.drawHierarchy(in: window.frame, afterScreenUpdates: false) {
                if let context = UIGraphicsGetCurrentContext() {
                    context.saveGState()
                    context.translateBy(x: window.frame.minX, y: window.frame.minY)
                    window.layer.render(in: context)
                    context.restoreGState()
                }
            }
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else { return nil }
        return (image, jpeg)
    }
}
#endif
