import AxoCore
import SwiftUI

/// The colors a Space can have. Stored by name, so the names must not change.
nonisolated public enum SpaceColor: String, CaseIterable, Identifiable, Sendable {
    case pink, red, orange, yellow, green, mint, teal, blue, indigo, purple, brown, gray

    public var id: Self { self }

    /// The color's name, for VoiceOver and tooltips.
    public var title: String { rawValue.capitalized }

    /// The color. Pink is Axo's Axolotl Pink; the others are system colors, which adapt to light
    /// and dark mode.
    public var color: Color {
        switch self {
        case .pink: Color(red: 1, green: 0.62, blue: 0.76)
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .brown: .brown
        case .gray: .gray
        }
    }
}

/// The icons a Space can have: SF Symbols, with names for VoiceOver.
nonisolated public enum SpaceIcon {
    /// The SF Symbol names offered, with their spoken names.
    public static let all: [(symbol: String, title: String)] = [
        ("house", "House"), ("briefcase", "Briefcase"), ("book", "Book"), ("graduationcap", "School"),
        ("cart", "Shopping"), ("gamecontroller", "Games"), ("music.note", "Music"), ("film", "Film"),
        ("heart", "Heart"), ("star", "Star"), ("leaf", "Leaf"), ("airplane", "Travel"),
        ("hammer", "Tools"), ("paintbrush", "Art"), ("chevron.left.forwardslash.chevron.right", "Code"), ("globe", "Globe"),
    ]

    /// The spoken name for an icon, or the symbol name for one not in the list.
    public static func title(for symbol: String) -> String {
        all.first { $0.symbol == symbol }?.title ?? symbol
    }
}

extension Space {
    /// The Space's color, if it has one from the palette.
    var spaceColor: SpaceColor? { color.flatMap(SpaceColor.init(rawValue:)) }
}
