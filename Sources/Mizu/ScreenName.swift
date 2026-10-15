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
}
