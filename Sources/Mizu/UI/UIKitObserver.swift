#if canImport(UIKit)
import ObjectiveC
import SwiftUI
import UIKit

/// Feeds screens, taps, keyboard, text focus and app lifecycle into the timeline.
/// Never records what anyone types.
@MainActor
final class UIKitObserver {
    private let timeline: Timeline
    private var tokens: [NSObjectProtocol] = []
    private(set) var currentScreen: String?

    nonisolated(unsafe) static var current: UIKitObserver?
    nonisolated(unsafe) private static var hooksInstalled = false

    init(timeline: Timeline) {
        self.timeline = timeline
    }

    func install() {
        UIKitObserver.current = self
        installHooksOnce()
        observeNotifications()
    }

    // MARK: Screens

    /// Called from `.mizuScreen("Name")` in SwiftUI, and for every UIKit view controller that appears.
    func screenAppeared(_ name: String, source: String) {
        guard name != currentScreen else { return }
        currentScreen = name
        timeline.record("screen", ["name": .string(name), "via": .string(source)])
    }

    fileprivate func viewControllerAppeared(_ controller: UIViewController) {
        guard !(controller is ReportSheetController) else { return }
        let typeName = String(describing: type(of: controller))
        let name = ScreenName.from(typeName: typeName)
        // Containers, system plumbing, and SwiftUI hosts without a useful name (`.mizuScreen` covers those).
        let isSystem = typeName.hasPrefix("_") || (typeName.hasPrefix("UI") && !typeName.contains("<"))
        if isSystem || UIKitObserver.ignoredControllers.contains(name) || name.hasSuffix("HostingController") {
            return
        }
        screenAppeared(name, source: "uikit")
    }

    private static let ignoredControllers: Set<String> = [
        "UINavigationController", "UITabBarController", "UIPageViewController", "UISplitViewController",
        "UIInputWindowController", "UICompatibilityInputViewController", "UIEditingOverlayViewController",
        "UISystemKeyboardDockController", "UIPredictionViewController", "UIAlertController",
    ]

    // MARK: Taps

    fileprivate func observe(_ event: UIEvent) {
        guard event.type == .touches, let touches = event.allTouches else { return }
        for touch in touches where touch.phase == .ended {
            guard let window = touch.window else { continue }
            // Key positions on the keyboard would spell out what was typed, passwords included. Never record them.
            if UIKitObserver.isSystemInputWindow(window) || touch.view.map(UIKitObserver.isKeyboardView) == true { continue }
            let point = touch.location(in: window)
            var data: [String: TimelineValue] = [
                "x": .int(Int(point.x)),
                "y": .int(Int(point.y)),
            ]
            if let view = touch.view {
                data["view"] = .string(ScreenName.from(typeName: String(describing: type(of: view))))
                if let label = Self.nearestLabel(view) { data["label"] = .string(label) }
            }
            if touch.tapCount > 1 { data["taps"] = .int(touch.tapCount) }
            timeline.record("tap", data)
        }
    }

    static func isSystemInputWindow(_ window: UIWindow) -> Bool {
        let name = NSStringFromClass(type(of: window))
        return name.contains("Keyboard") || name.contains("TextEffects") || name.contains("InputWindow")
    }

    private static func isKeyboardView(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let v = current {
            if NSStringFromClass(type(of: v)).contains("Keyboard") { return true }
            current = v.superview
        }
        return false
    }

    /// The accessibility label or identifier of the view or a close ancestor, e.g. "Send" for a button.
    private static func nearestLabel(_ view: UIView) -> String? {
        var current: UIView? = view
        for _ in 0..<4 {
            guard let v = current else { break }
            if let id = v.accessibilityIdentifier, !id.isEmpty { return id }
            if let label = v.accessibilityLabel, !label.isEmpty, !(v is UITextField), !(v is UITextView) {
                return String(label.prefix(60))
            }
            current = v.superview
        }
        return nil
    }

    // MARK: Notifications

    private func observeNotifications() {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handler(note) }
            })
        }

        on(UIResponder.keyboardWillShowNotification) { [timeline] in timeline.record("keyboard.will_show", Self.keyboardInfo($0)) }
        on(UIResponder.keyboardDidShowNotification) { [timeline] in timeline.record("keyboard.did_show", Self.keyboardInfo($0)) }
        on(UIResponder.keyboardWillHideNotification) { [timeline] in timeline.record("keyboard.will_hide", Self.keyboardInfo($0)) }
        on(UIResponder.keyboardDidHideNotification) { [timeline] _ in timeline.record("keyboard.did_hide") }

        on(UITextField.textDidBeginEditingNotification) { [timeline] in timeline.record("text.focus", Self.fieldInfo($0.object)) }
        on(UITextField.textDidEndEditingNotification) { [timeline] in timeline.record("text.blur", Self.fieldInfo($0.object)) }
        on(UITextView.textDidBeginEditingNotification) { [timeline] in timeline.record("text.focus", Self.fieldInfo($0.object)) }
        on(UITextView.textDidEndEditingNotification) { [timeline] in timeline.record("text.blur", Self.fieldInfo($0.object)) }

        on(UIApplication.didBecomeActiveNotification) { [timeline] _ in timeline.record("app.active") }
        on(UIApplication.willResignActiveNotification) { [timeline] _ in timeline.record("app.inactive") }
        on(UIApplication.didEnterBackgroundNotification) { [timeline] _ in
            timeline.record("app.background")
            Mizu.persistAll()
        }
        on(UIApplication.willEnterForegroundNotification) { [timeline] _ in timeline.record("app.foreground") }
        on(UIApplication.willTerminateNotification) { [timeline] _ in
            timeline.record("app.terminate")
            Mizu.persistAll()
        }
        on(UIApplication.didReceiveMemoryWarningNotification) { [timeline] _ in timeline.record("memory.warning") }
        on(ProcessInfo.thermalStateDidChangeNotification) { [timeline] _ in
            timeline.record("thermal", ["state": .string(DeviceInfo.thermalName(ProcessInfo.processInfo.thermalState))])
        }
        on(UIDevice.orientationDidChangeNotification) { [timeline] _ in
            let o = UIDevice.current.orientation
            guard o.isValidInterfaceOrientation else { return }
            timeline.record("orientation", ["value": .string(o.isLandscape ? "landscape" : "portrait")])
        }
    }

    private static func keyboardInfo(_ note: Notification) -> [String: TimelineValue] {
        var data: [String: TimelineValue] = [:]
        if let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            data["height"] = .int(Int(frame.height))
            data["y"] = .int(Int(frame.minY))
        }
        if let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
            data["anim_ms"] = .int(Int(duration * 1000))
        }
        return data
    }

    private static func fieldInfo(_ object: Any?) -> [String: TimelineValue] {
        var data: [String: TimelineValue] = [:]
        if let field = object as? UITextField {
            data["field"] = "UITextField"
            if let placeholder = field.placeholder, !placeholder.isEmpty { data["placeholder"] = .string(String(placeholder.prefix(60))) }
            if field.isSecureTextEntry { data["secure"] = true }
        } else if object is UITextView {
            data["field"] = "UITextView"
        }
        if let view = object as? UIView, let id = view.accessibilityIdentifier, !id.isEmpty { data["id"] = .string(id) }
        return data
    }

    // MARK: Hooks

    private func installHooksOnce() {
        guard !UIKitObserver.hooksInstalled else { return }
        UIKitObserver.hooksInstalled = true

        hook(UIViewController.self, #selector(UIViewController.viewDidAppear(_:))) { (original: @convention(c) (AnyObject, Selector, Bool) -> Void, selector) in
            let block: @convention(block) (AnyObject, Bool) -> Void = { object, animated in
                original(object, selector, animated)
                if let controller = object as? UIViewController {
                    MainActor.assumeIsolated { UIKitObserver.current?.viewControllerAppeared(controller) }
                }
            }
            return imp_implementationWithBlock(block)
        }

        hook(UIApplication.self, #selector(UIApplication.sendEvent(_:))) { (original: @convention(c) (AnyObject, Selector, UIEvent) -> Void, selector) in
            let block: @convention(block) (AnyObject, UIEvent) -> Void = { object, event in
                MainActor.assumeIsolated { UIKitObserver.current?.observe(event) }
                original(object, selector, event)
            }
            return imp_implementationWithBlock(block)
        }
    }

    private func hook<F>(_ cls: AnyClass, _ selector: Selector, _ make: (F, Selector) -> IMP) {
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: F.self)
        method_setImplementation(method, make(original, selector))
    }
}

public extension View {
    /// Names this screen in Mizu reports and timelines. Useful for SwiftUI, where the type name is often generic.
    ///
    ///     ChatView().mizuScreen("Chat")
    func mizuScreen(_ name: String) -> some View {
        onAppear { Mizu.screen(name) }
    }
}
#endif
