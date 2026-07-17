import SwiftUI

// =============================================================================
// FILE: Sources/MacDirStat/Model/Palette.swift
// =============================================================================
//
// PURPOSE
//   The app-owned RGB side of the color story (design 1g / APP-EXT-3):
//   the ENGINE assigns keys (kind category, age bucket, extension slot),
//   this file maps every key to an actual color, identically wherever it
//   appears — treemap rects, legend chips, sidebar swatches, review-sheet
//   rows. Also hosts the small byte-formatting helper the same UI labels
//   share. One file so the mapping cannot drift between views.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - SwiftUI: Color.
//   - Engine/Engine.swift: KindCategory + TreemapRect (the color keys).
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - Views/TreemapPane.swift: Palette.color(for:mode:) per rect, staged
//     amber striping color.
//   - Views/MainView.swift: chip/capacity-bar colors, warning amber.
//   - Views/SidebarOutline.swift: category swatches; ByteFormat sizes.
//   - Views/CleanupReviewSheet.swift / TypeTableSheet.swift / WelcomeView:
//     swatches, staged/warning colors, ByteFormat.
//   - Model/AppState.swift: ColorMode (the published channel selection).
//   - Tests/MacDirStatTests/CleanupTests.swift: completeness checks.
//
// STRUCTURE
//   - ColorMode: the three 1g channels (kind / age / extension)
//   - Palette: kind map, age ramp, extension slots, staged/warning ambers
//   - Color(hex:): 0xRRGGBB convenience init
//   - ByteFormat: compact decimal-unit byte strings for labels
//
// BEHAVIOR & INVARIANTS
//   - Same geometry all three channels: switching ColorMode recolors, it
//     never relayouts.
//   - Array channels (age, extensionSlots) are indexed with min()-clamps
//     at the call sites so an engine value beyond the table cannot crash.
//   - ByteFormat uses decimal units (1 GB = 10^9), matching what Finder
//     and disk vendors report.
// =============================================================================

/// Color channels for the treemap (design 1g): kind is the proposed
/// default, age is the "big AND untouched" delete-me signal, extension is
/// the WinDirStat-parity channel. Same geometry all three times — the
/// engine supplies the keys, the app owns every RGB value.
enum ColorMode: String, CaseIterable, Identifiable {
    // `extension` is a Swift keyword, hence the trailing underscore.
    case kind, age, extension_
    var id: String { rawValue }

    /// Segmented-control label in the toolbar.
    var label: String {
        switch self {
        case .kind: "Kind"
        case .age: "Age"
        case .extension_: "Extension"
        }
    }
}

// MARK: - Palette tables

/// The single source of truth for every color in the app. Views must not
/// invent category/age/extension colors — they ask here, so the treemap,
/// chips, swatches, and capacity bar always agree (APP-EXT-3).
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

    /// Legend labels matching `age` index-for-index (tests pin the counts).
    static let ageLabels = ["This week", "This month", "This year", "1–2 years", "Older"]

    /// Top-12 extension slots + "everything else" grey (design EXTC values).
    static let extensionSlots: [Color] = [
        Color(hex: 0xC94F43), Color(hex: 0xD2813B), Color(hex: 0xD9B13F),
        Color(hex: 0xA9C04A), Color(hex: 0x5FAE57), Color(hex: 0x4FB0A0),
        Color(hex: 0x4F96C9), Color(hex: 0x5F78C9), Color(hex: 0x8B6CC9),
        Color(hex: 0xB45FC0), Color(hex: 0xC9548B), Color(hex: 0x948E55),
        Color(hex: 0x6B7078),  // slot 12: everything else
    ]

    /// The one treemap color decision: pick the channel's table and index
    /// it with the rect's engine-assigned key. min()-clamps make unknown
    /// future engine values fall into the last ("other"/"older") bucket
    /// instead of trapping.
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

    /// Kind color for non-rect UI (chips, swatches, capacity bar).
    static func color(for category: KindCategory) -> Color {
        kind[category] ?? kind[.other]!
    }

    /// Staged-for-cleanup amber (design 1e marks).
    static let staged = Color(hex: 0xFFB340)
    /// The "unreadable — grant Full Disk Access" amber.
    static let warning = Color(hex: 0xD9A05A)
}

// MARK: - Helpers

extension Color {
    /// Design-doc 0xRRGGBB literal, decoded as sRGB.
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
    /// Human-compact decimal-unit string: TB two decimals, GB one, MB/KB
    /// none — precision scaled to how much users care at each magnitude.
    static func compact(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1000 { return String(format: "%.2f TB", gb / 1000) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1000)
    }
}

/// Pure decision logic for the capacity footer's two indicators (issue
/// app#13). The two signals are deliberately independent, because they
/// answer different questions:
///
/// - The **Full Disk Access CTA** answers "did the scan hit permission
///   walls?" — and the only honest evidence for that is the engine's scan
///   report (paths that actually failed to read). Bytes behind an
///   unreadable directory are unknowable by definition, so this indicator
///   speaks in location counts, never bytes.
/// - The **capacity gap** answers "why doesn't measured + free equal the
///   disk?" — and on an APFS boot disk the honest answer is snapshots,
///   sibling volumes in the container (System/VM/Preboot/…), and purgeable
///   space, which no permission grant can surface. It is informational,
///   never a call to action, and only meaningful when a whole volume was
///   scanned (for a folder scan the "gap" is just the rest of the disk).
enum FooterIndicators {
    /// Amber CTA text, or nil when the scan hit no read failures.
    static func fdaMessage(errorCount: UInt64) -> String? {
        guard errorCount > 0 else { return nil }
        let noun = errorCount == 1 ? "location" : "locations"
        return "\(errorCount) \(noun) couldn't be read — Grant Full Disk Access…"
    }

    /// Neutral gap attribution, or nil for folder scans / negligible gaps.
    static func gapMessage(unknown: UInt64, isFullVolumeScan: Bool) -> String? {
        guard isFullVolumeScan, unknown > 1_000_000_000 else { return nil }
        return "\(ByteFormat.compact(unknown)) in snapshots, system volumes & purgeable space"
    }
}
