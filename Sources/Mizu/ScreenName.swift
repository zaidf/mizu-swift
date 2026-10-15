import Foundation

enum ScreenName {
    private static let wrappers: Set<String> = [
        "UIHostingController", "ModifiedContent", "AnyView", "Optional", "TupleView", "Group",
        "NavigationStack", "NavigationView", "NavigationSplitView", "TabView", "ZStack", "VStack", "HStack",
        "UINavigationController", "UITabBarController", "SwiftUI", "Never", "some",
    ]

    /// Turns a view controller type name into something a person would call the screen.
    /// `UIHostingController<ModifiedContent<ChatView, _EnvironmentKeyWritingModifier<…>>>` → `ChatView`.
    static func from(typeName: String) -> String {
        let tokens = typeName
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
            .filter { !$0.isEmpty }
        // SwiftUI's own plumbing (RootModifier, _EnvironmentKeyWritingModifier…) isn't a screen.
        if let meaningful = tokens.first(where: { !wrappers.contains($0) && !$0.hasPrefix("_") && !$0.hasSuffix("Modifier") }) {
            return meaningful
        }
        return tokens.first ?? typeName
    }

    /// How a person would say it: `PrewarmingViewController` → "prewarming", `HotelDetailView` → "hotel detail".
    static func spoken(_ name: String) -> String {
        var base = name
        for suffix in ["ViewController", "Controller", "View", "Screen", "Page"] where base.count > suffix.count && base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
            break
        }
        var words: [String] = []
        var current = ""
        for ch in base {
            if ch.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                words.append(current)
                current = ""
            }
            if ch == "_" || ch == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        let spoken = words.joined(separator: " ").lowercased()
        return spoken.isEmpty ? name : spoken
    }
}
