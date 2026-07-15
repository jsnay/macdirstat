import SwiftUI

/// Color channels for the treemap (design 1g): kind is the proposed
/// default, age is the "big AND untouched" delete-me signal, extension is
/// the WinDirStat-parity channel. Same geometry all three times — the
/// engine supplies the keys, the app owns every RGB value.
enum ColorMode: String, CaseIterable, Identifiable {
    case kind, age, extension_
    var id: String { rawValue }

    var label: String {
        switch self {
        case .kind: "Kind"
        case .age: "Age"
        case .extension_: "Extension"
        }
    }
}

enum Palette {
    /// 8 stable, learnable kind colors (design CATC values).
    static let kind: [KindCategory: Color] = [
        .developer: Color(hex: 0x6C8FD4),
        .media: Color(hex: 0xC96F9A),
        .photos: Color(hex: 0xD9A05A),
        .documents: Color(hex: 0x74A97A),
        .archives: Color(hex: 0x9A83D1),
        .system: Color(hex: 0x7E8894),
        .apps: Color(hex: 0x58B3A4),
        .other: Color(hex: 0x667080),
    ]

    /// Age buckets, bright = recent, dark = untouched (design AGEC values).
    static let age: [Color] = [
        Color(hex: 0xE9D9A6),  // this week
        Color(hex: 0xC7AD76),  // this month
        Color(hex: 0x98815C),  // this year
        Color(hex: 0x6A5F4D),  // 1–2 years
        Color(hex: 0x42403C),  // older
    ]

    static let ageLabels = ["This week", "This month", "This year", "1–2 years", "Older"]

    /// Top-12 extension slots + "everything else" grey (design EXTC values).
    static let extensionSlots: [Color] = [
        Color(hex: 0xC94F43), Color(hex: 0xD2813B), Color(hex: 0xD9B13F),
        Color(hex: 0xA9C04A), Color(hex: 0x5FAE57), Color(hex: 0x4FB0A0),
        Color(hex: 0x4F96C9), Color(hex: 0x5F78C9), Color(hex: 0x8B6CC9),
        Color(hex: 0xB45FC0), Color(hex: 0xC9548B), Color(hex: 0x948E55),
        Color(hex: 0x6B7078),  // slot 12: everything else
    ]

    static func color(for rect: TreemapRect, mode: ColorMode) -> Color {
        switch mode {
        case .kind:
            kind[rect.category] ?? kind[.other]!
        case .age:
            age[min(rect.ageBucket, age.count - 1)]
        case .extension_:
            extensionSlots[min(rect.extSlot, extensionSlots.count - 1)]
        }
    }

    static func color(for category: KindCategory) -> Color {
        kind[category] ?? kind[.other]!
    }

    /// Staged-for-cleanup amber (design 1e marks).
    static let staged = Color(hex: 0xFFB340)
    /// The "unreadable — grant Full Disk Access" amber.
    static let warning = Color(hex: 0xD9A05A)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// Byte formatting for UI labels; the engine hands us raw counts.
enum ByteFormat {
    static func compact(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1000 { return String(format: "%.2f TB", gb / 1000) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1000)
    }
}
