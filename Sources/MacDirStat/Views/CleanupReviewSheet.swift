import SwiftUI

/// The destructive moment (design 1e): review once, commit once — to
/// Trash, always. Staging separated deciding from doing; this sheet is the
/// single confirmation. Path-aware hints say what regenerates; the amber
/// warning is for the one case that matters (only backup of a device).
/// "Delete Permanently" is deliberately not offered here.
struct CleanupReviewSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CleanupReviewContent(cleanup: state.cleanup)
    }
}

private struct CleanupReviewContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var cleanup: CleanupStore
    @State private var committing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Move \(cleanup.items.count) item\(cleanup.items.count == 1 ? "" : "s") to Trash?")
                .font(.system(size: 16, weight: .bold))
            (Text("Frees ")
                + Text(ByteFormat.compact(cleanup.total)).bold().foregroundColor(Palette.staged)
                + Text(
                    ". Nothing is deleted permanently — restore from the Trash any time."
                ))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.top, 3)

            VStack(spacing: 2) {
                ForEach(cleanup.items) { item in
                    StagedRow(item: item) { cleanup.remove(item) }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.25)))
            .padding(.vertical, 16)

            HStack(spacing: 10) {
                Text("System-critical paths can’t be staged.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { cleanup.reviewPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    committing = true
                    Task {
                        await state.commitCleanup()
                        committing = false
                    }
                } label: {
                    Text("Move to Trash").bold()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(committing || cleanup.items.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 520)
    }
}

private struct StagedRow: View {
    let item: CleanupStore.StagedItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Palette.color(for: item.category))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 3) {
                    Text(shortPath)
                        .foregroundStyle(.tertiary)
                    if !item.hint.text.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text((item.hint.isWarning ? "⚠ " : "") + item.hint.text)
                            .foregroundStyle(
                                item.hint.isWarning ? Palette.staged : Color.secondary)
                    }
                }
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer()

            Text(ByteFormat.compact(item.size))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.8))

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Keep this item")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let parent = (item.path as NSString).deletingLastPathComponent
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }
}
