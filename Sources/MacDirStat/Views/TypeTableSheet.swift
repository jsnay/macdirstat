import SwiftUI

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
