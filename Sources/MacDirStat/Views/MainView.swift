import AppKit
import SwiftUI

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
/// must re-render when items are staged.
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

    private var cleanupBinding: Binding<Bool> {
        Binding(
            get: { cleanup.reviewPresented },
            set: { cleanup.reviewPresented = $0 })
    }
}

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

    private var rootBytes: UInt64? {
        guard let model = state.model, model.root.isValid else { return nil }
        return (try? model.info(model.root))?.logical
    }
}

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

    private var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = state.progressPath
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

/// The type list demoted to a legend strip (1b): same click-to-isolate
/// power, 30 px instead of a pane; the full table is one keystroke away.
struct LegendChips: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            ForEach(state.categories.filter { $0.logical > 0 }) { stat in
                CategoryChip(
                    stat: stat,
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

private struct CategoryChip: View {
    let stat: CategoryStat
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
                Text(ByteFormat.compact(stat.logical))
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

/// The capacity footer (1b): free space as a segmented bar (kills the
/// `<Free Space>` pseudo-node), the amber unreadable call-to-action (kills
/// `<Unknown>`), the selection readout, and the Cleanup pill (1e).
struct FooterRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        FooterContent(cleanup: state.cleanup)
    }
}

/// Observes the CleanupStore directly so pill/count updates render.
private struct FooterContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var cleanup: CleanupStore

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
                        if rec.unknown > 1_000_000 {
                            Button {
                                let pane = URL(
                                    string:
                                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                                )!
                                NSWorkspace.shared.open(pane)
                            } label: {
                                Text(
                                    "\(ByteFormat.compact(rec.unknown)) unreadable — Grant Full Disk Access…"
                                )
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.warning)
                            }
                            .buttonStyle(.plain)
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
                    if let selection = state.selection, let model = state.model {
                        (Text("selected: ")
                            + Text(
                                "\(model.name(of: selection)) · \(ByteFormat.compact((try? model.info(selection))?.logical ?? 0))"
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
                    ForEach(state.categories.filter { $0.logical > 0 }) { stat in
                        Rectangle()
                            .fill(Palette.color(for: stat.category))
                            .frame(
                                width: geo.size.width * CGFloat(stat.logical)
                                    / CGFloat(rec.total))
                    }
                    if rec.unknown > 0 {
                        HatchedRectangle()
                            .frame(width: geo.size.width * CGFloat(rec.unknown) / CGFloat(rec.total))
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
