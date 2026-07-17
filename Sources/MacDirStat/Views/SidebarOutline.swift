import SwiftUI

// =============================================================================
// FILE: Sources/MacDirStat/Views/SidebarOutline.swift
// =============================================================================
//
// PURPOSE
//   The left pane of the 1b layout: the directory outline as a Mac sidebar
//   with ONE smart column — name plus size, with a %-of-root bar drawn
//   BEHIND the row instead of a separate percent column. Always sorted
//   largest-first by the engine; fully clickable mid-scan as "Largest so
//   far" (1d). Adds Finder-style horizontal arrow-key navigation on top of
//   List's native vertical selection.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - Model/AppState.swift: OutlineStore (rows/expansion/tail summary),
//     selection, searchText, isScanning, select/zoomInto/rescan/
//     revealInFinder/copyPath/toggleCleanup, cleanup.stagedNodes for the
//     context-menu label.
//   - Engine/Engine.swift: NodeID (row identity/selection tags).
//   - Model/Palette.swift: category swatch colors, ByteFormat sizes.
//   - SwiftUI: List(selection:), ScrollViewReader, onKeyPress.
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - Views/MainView.swift embeds SidebarOutline as the left split pane.
//
// STRUCTURE
//   - SidebarOutline: thin wrapper handing the store to SidebarContent
//   - SidebarContent: header, List + selection binding + arrow keys,
//     tail-summary footer, mid-scan reassurance footer, row context menu
//   - OutlineRowView: one row — disclosure triangle, swatch, name, size,
//     and the %-bar background
//
// BEHAVIOR & INVARIANTS
//   - Observation: OutlineStore is observed via @ObservedObject in
//     SidebarContent (nested ObservableObjects don't republish through
//     @EnvironmentObject — same topology note as AppState/MainView).
//   - Selection coupling direction: a row tap calls state.select with
//     revealInOutline FALSE — the sidebar is the source here, and the
//     treemap ring follows from the shared `selection`. Only map-side
//     selections reveal/expand sidebar rows (APP-COUPLE-1 vs -2).
//   - The auto-scroll follows selection changes from ANY source, so a
//     treemap click scrolls its (just-revealed) row into view.
//   - Search filters the FLATTENED visible rows by substring; it narrows
//     what is listed but never changes expansion state.
// =============================================================================

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

/// The real sidebar body; separate from SidebarOutline solely so the
/// OutlineStore can be observed explicitly (see file header).
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
                        if row.tailCount > 0 {
                            // Inner-level truncation indicator (app#22):
                            // count-only, click to un-truncate that level.
                            Button {
                                outline.uncap(row.node)
                            } label: {
                                Text("…and \(row.tailCount) more")
                                    .font(.system(size: 11))
                                    .italic()
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, CGFloat(6 + row.depth * 13))
                            }
                            .buttonStyle(.plain)
                            .id(row.id)
                            .listRowInsets(
                                EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
                            )
                            .listRowSeparator(.hidden)
                        } else {
                            OutlineRowView(row: row)
                                .tag(row.node)
                                .id(row.node.raw)
                                .listRowInsets(
                                    EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
                                )
                                .listRowSeparator(.hidden)
                                .contextMenu { rowMenu(row) }
                        }
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

    /// Substring filter over the already-flattened visible rows (cheap,
    /// case-insensitive). Expansion state is untouched — clearing the
    /// search restores exactly the outline the user had.
    private var filteredRows: [OutlineStore.Row] {
        guard !state.searchText.isEmpty else { return outline.rows }
        let needle = state.searchText.lowercased()
        return outline.rows.filter { $0.name.lowercased().contains(needle) }
    }

    /// Bridges List's native selection into the shared AppState selection.
    /// The set side establishes the coupling DIRECTION: a sidebar row tap
    /// selects with revealInOutline false (the row is already on screen),
    /// and the treemap draws its ring from the same shared `selection` —
    /// sidebar → map (APP-COUPLE-1). nil sets are ignored so stray List
    /// deselection can't clear a selection the treemap still shows.
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

    /// → arrow, a two-state machine keyed on the selected row:
    ///   collapsed dir → expand it (stay put);
    ///   already expanded → step INTO the largest child;
    ///   leaf/no selection → .ignored so the event falls through.
    /// So pressing → repeatedly walks the "largest" spine downward,
    /// expanding as it goes — the fastest route to the space hog.
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

    /// ← arrow, the mirror image:
    ///   expanded dir → collapse it (stay put);
    ///   collapsed/leaf → jump to the PARENT;
    /// so repeated ← walks the path upward, folding it behind you.
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

    /// Per-row context menu; the same actions the treemap offers, plus
    /// Zoom for directories. All funnel through AppState.
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

// MARK: - Row view

/// One sidebar row: disclosure triangle, kind swatch, name, size — and
/// the trick that replaces a whole percent column: the row's BACKGROUND
/// is a rounded bar whose width is percentOfRoot, so relative weight is
/// visible at a glance behind every row. When selected, the same bar
/// grows to full width in the accent color and doubles as the selection
/// highlight.
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
            // Unselected: width = percentOfRoot of the row width (2pt
            // floor so tiny items stay visible). Selected: full-width
            // accent fill — the bar IS the selection highlight.
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
        // Double-tap registered first so it wins over the single tap;
        // sidebar taps never reveal (the row is already visible).
        .onTapGesture(count: 2) {
            if row.isDirectory { state.zoomInto(row.node) }
        }
        .onTapGesture {
            state.select(node: row.node, revealInOutline: false)
        }
    }
}
