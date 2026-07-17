import AppKit
import SwiftUI

// =============================================================================
// FILE: Sources/MacDirStat/Views/MainView.swift
// =============================================================================
//
// PURPOSE
//   The active window surface (design 1b): the evolved TWO-pane layout that
//   replaces WinDirStat's three panes. Sidebar outline on the left; on the
//   right a vertical stack of legend chips (the demoted type list), the
//   dominant treemap, and the capacity footer with the Cleanup pill (1e).
//   The toolbar doubles as the 1d scan surface: while scanning it shows the
//   live progress cluster, afterwards the 1g color-channel control + search.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - Model/AppState.swift: phase-independent state — rootName, isScanning,
//     progress trio, canGoBack/Forward, colorMode, searchText, categories,
//     isolatedCategory, reconciliation, selection, sizeMetric.
//   - Model/CleanupStore.swift: items/total/lastReclaimed/reviewPresented
//     for the pill, footer toast, and sheet presentation.
//   - Views/SidebarOutline.swift, TreemapPane.swift, CleanupReviewSheet.swift,
//     TypeTableSheet.swift: the embedded panes and sheets.
//   - Model/Palette.swift: chip/bar colors, staged & warning ambers,
//     ByteFormat.
//   - AppKit: NSWorkspace to open the Full Disk Access settings pane.
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - MacDirStatApp.swift (RootView) shows MainView for the .active phase.
//
// STRUCTURE
//   - MainView → MainContent: whole-surface layout + both sheets
//   - ToolbarRow (+ NavChevron): zoom chevrons, title, scan cluster OR
//     color-mode picker + search
//   - ScanProgressCluster: the 1d determinate progress display
//   - LegendChips (+ CategoryChip): click-to-isolate kind strip
//   - FooterRow → FooterContent: capacity bar, free/unreadable line,
//     reclaimed toast, selection readout, CleanupPill
//   - CapacityBar + HatchedRectangle: per-kind capacity segments
//   - CleanupPill: staged count + reclaim total + Review button
//
// BEHAVIOR & INVARIANTS
//   - Observation topology: CleanupStore is a SEPARATE ObservableObject
//     owned by AppState, and nested ObservableObjects do NOT republish
//     through @EnvironmentObject — @EnvironmentObject only re-renders on
//     AppState's own objectWillChange. So every view that must react to
//     staging (MainContent's sheet, FooterContent's toast, CleanupPill's
//     numbers) takes the store as an explicit @ObservedObject; the
//     MainView/FooterRow wrappers exist only to perform that handoff.
//   - The capacity bar is PHYSICAL-bytes only, whatever the sizeMetric:
//     it reconciles against real disk capacity, and logical (apparent)
//     sizes can exceed the disk (clones, cloud placeholders).
//   - Free space and unknown are footer elements, not treemap nodes — the
//     footer is what kills the <Free Space>/<Unknown> pseudo-nodes (1b).
// =============================================================================

/// The evolved layout (design 1b): two panes, not three. The outline is a
/// Mac sidebar with one smart column; the treemap gets ~75% of the window;
/// the type list is a 30 px chip strip; free space lives in the capacity
/// footer; staged deletions accumulate in the Cleanup pill.
struct MainView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        MainContent(cleanup: state.cleanup)
    }
}

/// Observes the CleanupStore directly: sheet presentation and map striping
/// must re-render when items are staged. This is the @ObservedObject
/// handoff described in the file header — without it, staging an item
/// would not re-evaluate this body and the review sheet could never
/// present from the store's own flag.
private struct MainContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var cleanup: CleanupStore

    var body: some View {
        VStack(spacing: 0) {
            ToolbarRow()
            Divider().opacity(0.6)
            HSplitView {
                SidebarOutline()
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                VStack(spacing: 0) {
                    LegendChips()
                    TreemapPane()
                        .padding(.horizontal, 14)
                    FooterRow()
                }
                .frame(minWidth: 500, maxWidth: .infinity)
            }
        }
        .background(Color(hex: 0x1D1E23))
        .sheet(isPresented: cleanupBinding) {
            CleanupReviewSheet()
        }
        .sheet(isPresented: $state.typeTablePresented) {
            TypeTableSheet()
        }
    }

    /// Explicit Binding into the store's published presentation flag
    /// (equivalent to the projected binding, spelled out for clarity).
    private var cleanupBinding: Binding<Bool> {
        Binding(
            get: { cleanup.reviewPresented },
            set: { cleanup.reviewPresented = $0 })
    }
}

// MARK: - Toolbar

/// The 1b toolbar: back/forward, title + used bytes, then either the 1d
/// scan progress cluster (path, counters, determinate bar, Stop) or the
/// color-channel segmented control (1g) and search.
struct ToolbarRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                NavChevron(symbol: "chevron.left", enabled: state.canGoBack) { state.goBack() }
                NavChevron(symbol: "chevron.right", enabled: state.canGoForward) {
                    state.goForward()
                }
            }

            Text(state.rootName)
                .font(.system(size: 13, weight: .semibold))
            if let bytes = rootBytes {
                Text("\(ByteFormat.compact(bytes)) used")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if state.isScanning {
                ScanProgressCluster()
                Spacer()
                Button("Stop") { state.stopScan() }
                    .controlSize(.small)
                    .help("Stop keeps everything found so far")
            } else {
                if state.isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Re-scanning…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 8)
                }
                Spacer()
                Picker("", selection: $state.colorMode) {
                    ForEach(ColorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .help("Color the map by kind, age, or extension (same geometry all three)")

                TextField("Search", text: $state.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color(hex: 0x26272C))
    }

    /// Root total in the current metric for the "N used" toolbar label.
    private var rootBytes: UInt64? {
        guard let model = state.model, model.root.isValid,
            let info = try? model.info(model.root)
        else { return nil }
        return state.sizeMetric == .physical ? info.physical : info.logical
    }
}

/// One zoom-history chevron button (back/forward), dimmed when its stack
/// is empty.
private struct NavChevron: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Scan progress cluster (1d)

/// 1d: determinate progress — the denominator (used bytes) is known before
/// the scan starts; counters only go up.
struct ScanProgressCluster: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Scanning \(shortPath)…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(
                    "\(state.progressItems.formatted()) items · \(ByteFormat.compact(state.progressBytes))"
                )
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.8))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * state.progressFraction))
                        .animation(.linear(duration: 0.3), value: state.progressFraction)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: 420)
    }

    /// Home-relative abbreviation of the currently-scanned path.
    private var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = state.progressPath
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

// MARK: - Legend chips (1b)

/// The type list demoted to a legend strip (1b): same click-to-isolate
/// power, 30 px instead of a pane; the full table is one keystroke away.
/// Clicking a chip toggles isolation (click again to clear); the treemap
/// dims all other kinds while one is isolated.
struct LegendChips: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            ForEach(state.categories.filter { $0.bytes(state.sizeMetric) > 0 }) { stat in
                CategoryChip(
                    stat: stat,
                    bytes: stat.bytes(state.sizeMetric),
                    isIsolated: state.isolatedCategory == stat.category
                ) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        state.isolatedCategory =
                            state.isolatedCategory == stat.category ? nil : stat.category
                    }
                }
            }
            Text("click a kind to isolate · full table ⌘T")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// One legend chip: color dot, kind label, byte total; accent-ringed
/// while its kind is isolated.
private struct CategoryChip: View {
    let stat: CategoryStat
    /// Pre-selected for the current metric by the caller.
    let bytes: UInt64
    let isIsolated: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Palette.color(for: stat.category))
                    .frame(width: 8, height: 8)
                Text(stat.category.label)
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(ByteFormat.compact(bytes))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isIsolated ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.05))
                    .overlay(
                        Capsule().strokeBorder(
                            isIsolated ? Color.accentColor : Color.white.opacity(0.10)))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Capacity footer + Cleanup pill

/// The capacity footer (1b): free space as a segmented bar (kills the
/// `<Free Space>` pseudo-node), the read-failure FDA call-to-action plus
/// the neutral capacity-gap note (kills `<Unknown>` — see FooterIndicators
/// for why they are two separate signals), the selection readout, and the
/// Cleanup pill (1e). Thin wrapper for the @ObservedObject handoff below.
struct FooterRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        FooterContent(cleanup: state.cleanup)
    }
}

/// Observes the CleanupStore directly so pill/count updates render.
/// (Same topology reason as MainContent: store changes do not propagate
/// through the AppState environment object.)
private struct FooterContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var cleanup: CleanupStore
    /// The #17 capacity-gap breakdown popover.
    @State private var breakdownPresented = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                CapacityBar()
                HStack(spacing: 14) {
                    if let rec = state.reconciliation {
                        (Text(ByteFormat.compact(rec.free)).bold().foregroundColor(
                            Color.white.opacity(0.8))
                            + Text(" free of \(ByteFormat.compact(rec.total))"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        // Two independent indicators (app#13/#19): read
                        // failures become a Grant-FDA CTA only when the
                        // grant is actually absent — with FDA in place the
                        // remaining failures are POSIX-denied OS internals
                        // and get neutral wording. The capacity gap
                        // (snapshots, sibling container volumes, purgeable)
                        // is informational; clicking it opens the #17
                        // breakdown popover.
                        if let indicator = FooterIndicators.readFailures(
                            errorCount: state.scanErrorCount, fdaGranted: state.fdaGranted)
                        {
                            if indicator.isCTA {
                                Button {
                                    let pane = URL(
                                        string:
                                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                                    )!
                                    NSWorkspace.shared.open(pane)
                                } label: {
                                    Text(indicator.text)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.warning)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text(indicator.text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let gap = FooterIndicators.gapMessage(
                            unknown: rec.unknown, isFullVolumeScan: state.isFullVolumeScan)
                        {
                            Button {
                                breakdownPresented.toggle()
                            } label: {
                                Text(gap)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .underline(breakdownPresented)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $breakdownPresented, arrowEdge: .top) {
                                CapacityBreakdownPopover(
                                    reconciliation: rec, breakdown: state.capacityBreakdown)
                            }
                        }
                    } else {
                        Text("\(state.progressItems.formatted()) items")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let reclaimed = cleanup.lastReclaimed {
                        Text("Reclaimed \(ByteFormat.compact(reclaimed)) ✓")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x30D158))
                            .transition(.opacity)
                    }
                    if let selection = state.selection, let model = state.model,
                        let info = try? model.info(selection)
                    {
                        let bytes = state.sizeMetric == .physical ? info.physical : info.logical
                        (Text("selected: ")
                            + Text(
                                "\(model.name(of: selection)) · \(ByteFormat.compact(bytes))"
                            ).bold().foregroundColor(Color.white.opacity(0.8)))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            CleanupPill(cleanup: cleanup)
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 11)
    }
}

/// Per-category capacity segments + hatched unknown + free remainder.
struct CapacityBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if let rec = state.reconciliation, rec.total > 0 {
                    // Physical bytes always: this bar reconciles against the
                    // real disk capacity, so apparent sizes would overflow it.
                    ForEach(state.categories.filter { $0.physical > 0 }) { stat in
                        Rectangle()
                            .fill(Palette.color(for: stat.category))
                            .frame(
                                width: geo.size.width * CGFloat(stat.physical)
                                    / CGFloat(rec.total))
                    }
                    // The gap segments only mean something for a
                    // whole-volume scan; for a folder scan they would fill
                    // with the entire rest of the disk (app#13). Decomposed
                    // per app#17: system volumes and purgeable as muted
                    // fills, snapshots/metadata keep the hatch.
                    if rec.unknown > 0 && state.isFullVolumeScan {
                        if let b = state.capacityBreakdown {
                            Rectangle()
                                .fill(Palette.systemVolumes)
                                .frame(
                                    width: geo.size.width * CGFloat(b.systemVolumes)
                                        / CGFloat(rec.total))
                            Rectangle()
                                .fill(Palette.purgeable)
                                .frame(
                                    width: geo.size.width * CGFloat(b.purgeable)
                                        / CGFloat(rec.total))
                            HatchedRectangle()
                                .frame(
                                    width: geo.size.width * CGFloat(b.snapshotsAndMetadata)
                                        / CGFloat(rec.total))
                        } else {
                            HatchedRectangle()
                                .frame(
                                    width: geo.size.width * CGFloat(rec.unknown)
                                        / CGFloat(rec.total))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

/// The #17 breakdown popover: where every byte of the disk is, including
/// the ones no scan can reach, each with one line of what it means. Reads
/// the breakdown from AppState; pure presentation.
struct CapacityBreakdownPopover: View {
    let reconciliation: VolumeReconciliation
    /// Passed explicitly (not via environment) — NSPopover-backed content
    /// has not always inherited environment objects reliably on macOS.
    let breakdown: CapacityBreakdown?

    var body: some View {
        let rec = reconciliation
        let b = breakdown
        let measured = rec.total &- min(rec.total, rec.free &+ rec.unknown)
        VStack(alignment: .leading, spacing: 10) {
            Text("Where the disk went")
                .font(.system(size: 12, weight: .semibold))
            row(
                swatch: nil, label: "Your files (scanned)", bytes: measured,
                note: "What the map and outline show.")
            if let b {
                row(
                    swatch: Palette.systemVolumes, label: "System volumes", bytes: b.systemVolumes,
                    note: "macOS itself: the sealed System volume, VM swap, Preboot/Update.")
                row(
                    swatch: Palette.purgeable, label: "Purgeable", bytes: b.purgeable,
                    note: "Space macOS frees automatically under pressure: thinnable "
                        + "Time Machine snapshots, evictable cloud files, disposable caches.")
                row(
                    swatch: nil, label: "Snapshots & metadata", bytes: b.snapshotsAndMetadata,
                    note: "Local snapshot blocks beyond the purgeable estimate, plus "
                        + "filesystem bookkeeping. Thinned automatically within ~24h.")
            }
            row(
                swatch: nil, label: "Free", bytes: rec.free,
                note: "Strictly free blocks (Finder's “available” adds purgeable).")
            Text("No permission grant can surface system volumes, snapshots or purgeable space — they aren't files this user can read.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func row(swatch: Color?, label: String, bytes: UInt64, note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8)
                }
                Text(label).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(ByteFormat.compact(bytes))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HatchedRectangle: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.clear))
            var x: CGFloat = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(Color(hex: 0x6D6F78)), lineWidth: 2)
                x += 5
            }
        }
    }
}

/// The Cleanup pill (1b/1e): running count + reclaim total + Review.
struct CleanupPill: View {
    @ObservedObject var cleanup: CleanupStore

    var body: some View {
        let count = cleanup.items.count
        HStack(spacing: 8) {
            Text("Cleanup")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
            Text("\(count) item\(count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(ByteFormat.compact(cleanup.total))
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Palette.staged)
            Button("Review…") {
                cleanup.reviewPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(count == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.10)))
        )
        .opacity(count == 0 ? 0.55 : 1)
    }
}
