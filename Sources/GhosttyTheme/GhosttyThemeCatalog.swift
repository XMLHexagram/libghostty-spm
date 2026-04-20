//
//  GhosttyThemeCatalog.swift
//  libghostty-spm
//

public enum GhosttyThemeCatalog {
    /// Lazy-built name → theme index for O(1) lookup.
    /// Built on first access instead of loading all themes into a separate structure.
    private static let themeIndex: [String: Int] = {
        var index = [String: Int](minimumCapacity: allThemes.count)
        for (i, theme) in allThemes.enumerated() {
            index[theme.name] = i
        }
        return index
    }()

    /// All theme names (lightweight — just strings, no full definitions loaded).
    public static let themeNames: [String] = allThemes.map(\.name)

    public static func theme(named name: String) -> GhosttyThemeDefinition? {
        guard let idx = themeIndex[name] else { return nil }
        return allThemes[idx]
    }

    public static func search(_ query: String) -> [GhosttyThemeDefinition] {
        let lowered = query.lowercased()
        return allThemes.filter { $0.name.lowercased().contains(lowered) }
    }
}
