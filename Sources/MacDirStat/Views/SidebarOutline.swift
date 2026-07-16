import SwiftUI

/// The 1b sidebar: the outline as a Mac sidebar with one smart column —
/// name + size with a %-of-root bar behind the row. Largest first, always
/// (never an unsorted default). During a scan it is "Largest so far" and
/// fully clickable (1d).
struct SidebarOutline: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SidebarContent(outline: state.outline)
    }
}

private struct SidebarContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var outline: OutlineStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.isScanning ? "Largest so far" : "Largest first")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ScrollViewReader { proxy in
                List(selection: selectionBinding) {
                    ForEach(filteredRows) { row in
                        OutlineRowView(row: row)
                            .tag(row.node)
                            .id(row.node.raw)
                            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                            .listRowSeparator(.hidden)
                            .contextMenu { rowMenu(row) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: state.selection) { _, newValue in
                    if let node = newValue {
                        withAnimation { proxy.scrollTo(node.raw) }
                    }
                }
                // Finder-style horizontal navigation: → expands (then steps
                // into the largest child), ← collapses (then jumps to the
                // parent, so repeated ← walks and folds the path upward).
                // ↑/↓ come from List selection itself.
                .onKeyPress(.rightArrow) { handleRightArrow() }
                .onKeyPress(.leftArrow) { handleLeftArrow() }
            }

            if let tail = outline.rootTail, state.searchText.isEmpty {
                Divider().opacity(0.4)
                Text("…and \(tail.count) more, \(ByteFormat.compact(tail.bytes))")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }

            if state.isScanning {
                Divider().opacity(0.4)
                Text("Sizes only grow — safe to explore now")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .background(Color(hex: 0x232429))
    }

    private var filteredRows: [OutlineStore.Row] {
        guard !state.searchText.isEmpty else { return outline.rows }
        let needle = state.searchText.lowercased()
        return outline.rows.filter { $0.name.lowercased().contains(needle) }
    }

    private var selectionBinding: Binding<NodeID?> {
        Binding(
            get: { state.selection },
            set: { node in
                if let node {
                    // Sidebar click → treemap frames it (APP-COUPLE-1).
                    state.select(node: node, revealInOutline: false)
                }
            })
    }

    private func handleRightArrow() -> KeyPress.Result {
        guard let selection = state.selection,
            let row = outline.rows.first(where: { $0.node == selection })
        else { return .ignored }
        if row.hasChildren, !row.isExpanded {
            outline.setExpanded(selection, true)
            return .handled
        }
        if row.isExpanded, let child = outline.firstChild(of: selection) {
            state.select(node: child, revealInOutline: false)
            return .handled
        }
        return .ignored
    }

    private func handleLeftArrow() -> KeyPress.Result {
        guard let selection = state.selection,
            let row = outline.rows.first(where: { $0.node == selection })
        else { return .ignored }
        if row.isExpanded, row.hasChildren {
            outline.setExpanded(selection, false)
            return .handled
        }
        if let parent = outline.parent(of: selection) {
            state.select(node: parent, revealInOutline: false)
            return .handled
        }
        return .ignored
    }

    @ViewBuilder
    private func rowMenu(_ row: OutlineStore.Row) -> some View {
        Button("Reveal in Finder") { state.revealInFinder(row.node) }
        Button("Copy Path") { state.copyPath(row.node) }
        Divider()
        if row.isDirectory {
            Button("Zoom Into Subtree") { state.zoomInto(row.node) }
        }
        Button("Re-scan From Here") { state.rescan(row.node) }
            .disabled(state.isScanning || state.isRefreshing)
        Button(
            state.cleanup.stagedNodes.contains(row.node)
                ? "Remove from Cleanup" : "Add to Cleanup"
        ) {
            state.toggleCleanup(row.node)
        }
    }
}

private struct OutlineRowView: View {
    @EnvironmentObject private var state: AppState
    let row: OutlineStore.Row

    var body: some View {
        let isSelected = state.selection == row.node
        HStack(spacing: 6) {
            // Disclosure triangle.
            Group {
                if row.hasChildren {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            .contentShape(Rectangle())
            .onTapGesture { state.outline.toggle(row.node) }

            RoundedRectangle(cornerRadius: 2.5)
                .fill(Palette.color(for: row.category))
                .frame(width: 9, height: 9)

            Text(row.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.92))

            Spacer(minLength: 8)

            Text(ByteFormat.compact(row.size))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.white.opacity(0.45))
        }
        .padding(.leading, CGFloat(6 + row.depth * 13))
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(
            // The one smart column: a %-of-root bar behind the row (1b).
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(Color(hex: 0x788CB4).opacity(0.15)))
                    .frame(
                        width: isSelected
                            ? geo.size.width
                            : max(2, geo.size.width * row.percentOfRoot / 100))
            }
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if row.isDirectory { state.zoomInto(row.node) }
        }
        .onTapGesture {
            state.select(node: row.node, revealInOutline: false)
        }
    }
}
