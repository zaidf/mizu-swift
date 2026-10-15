import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum DeviceInfo {
    /// App version, build, git sha and device details sent with every report.
    static func appMeta(bundle: Bundle = .main) -> [String: Any] {
        var meta: [String: Any] = ["device": device()]
        if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { meta["app_version"] = version }
        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String { meta["build"] = build }
        // Set by a build phase: see the README.
        if let sha = bundle.object(forInfoDictionaryKey: "MizuGitSHA") as? String, !sha.isEmpty { meta["git_sha"] = sha }
        return meta
    }

    static func device() -> [String: Any] {
        let process = ProcessInfo.processInfo
        var info: [String: Any] = [
            "model": modelIdentifier(),
            "os": process.operatingSystemVersionString,
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "low_power": process.isLowPowerModeEnabled,
            "thermal": thermalName(process.thermalState),
        ]
        #if targetEnvironment(simulator)
        info["simulator"] = true
        #endif
        #if canImport(UIKit)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                let screen = UIScreen.main
                info["screen"] = "\(Int(screen.bounds.width))x\(Int(screen.bounds.height))@\(Int(screen.scale))x"
                info["appearance"] = UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light"
                info["text_size"] = UIApplication.shared.preferredContentSizeCategory.rawValue
            }
        }
        #endif
        return info
    }

    static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
