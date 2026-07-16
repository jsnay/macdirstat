import SwiftUI

// =============================================================================
// FILE: Sources/MacDirStat/Views/TypeTableSheet.swift
// =============================================================================
//
// PURPOSE
//   The full per-extension table, one keystroke away (⌘T). The design
//   review demoted WinDirStat's always-on type pane to the legend chip
//   strip ("a legend pretending to be a pane"); this sheet is the promised
//   escape hatch that keeps the per-extension habit available on demand.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - Model/AppState.swift: state.model (typeList + root info for the
//     percent denominator), typeTablePresented toggled by the ⌘T command.
//   - Engine/Engine.swift: TypeStat rows (ext, logical bytes, files, slot).
//   - Model/Palette.swift: extensionSlots swatch colors, ByteFormat.
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - Views/MainView.swift presents this as the ⌘T sheet.
//
// STRUCTURE
//   - TypeTableSheet: title + Done, then a Table of TypeStat rows
//     (swatch, .ext, size, % of tree, file count)
//
// BEHAVIOR & INVARIANTS
//   - Data is fetched on each body evaluation (typeList is a cheap
//     engine aggregation); the sheet is transient, so no caching layer.
//   - Sizes here are LOGICAL bytes — the engine's extension aggregation
//     tracks logical only (physical-per-extension is an explicit
//     deferral); the swatch colors match the treemap's extension channel
//     exactly because both index Palette.extensionSlots by slot.
// =============================================================================

/// The full per-extension table, one keystroke away (⌘T). The always-on
/// pane is gone (design 1b); this is the escape hatch that keeps the
/// WinDirStat habit available.
struct TypeTableSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var stats: [TypeStat] {
        state.model?.typeList() ?? []
    }

    private var totalBytes: UInt64 {
        guard let model = state.model, model.root.isValid else { return 0 }
        return (try? model.info(model.root))?.logical ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Types")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Table(stats) {
                TableColumn("") { stat in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Palette.extensionSlots[min(stat.slot, 12)])
                        .frame(width: 11, height: 11)
                }
                .width(20)
                TableColumn("Extension") { stat in
                    Text("." + stat.ext).monospacedDigit()
                }
                TableColumn("Size") { stat in
                    Text(ByteFormat.compact(stat.logical)).monospacedDigit()
                }
                .width(90)
                TableColumn("%") { stat in
                    Text(percent(stat)).foregroundStyle(.secondary)
                }
                .width(60)
                TableColumn("Files") { stat in
                    Text(stat.files.formatted()).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(80)
            }
            .frame(minHeight: 360)
        }
        .padding(20)
        .frame(width: 480, height: 470)
    }

    private func percent(_ stat: TypeStat) -> String {
        guard totalBytes > 0 else { return "—" }
        return String(format: "%.1f%%", Double(stat.logical) / Double(totalBytes) * 100)
    }
}
