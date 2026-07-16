import SwiftUI

// =============================================================================
// FILE: Sources/MacDirStat/Views/TreemapPane.swift
// =============================================================================
//
// PURPOSE
//   The dominant treemap pane (design 1b: ~75% of the window). The strict
//   division of labor from APP-TM-1 rules this file: the ENGINE computes
//   every rectangle; this view only turns rects into pixels — fills with a
//   subtle per-rect gradient, hairline nesting, group labels, the selection
//   ring, staged-cleanup striping (1e), and the mid-scan hatched "still
//   scanning" region that grows on the 2s settle cadence (1d).
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - Model/AppState.swift: layoutGeneration (the ONLY relayout trigger
//     besides pane resize), treemapRoot, selection, colorMode,
//     isolatedCategory, isScanning/progressFraction, select/zoomInto/
//     rescan/revealInFinder/copyPath/toggleCleanup.
//   - Engine/Engine.swift: EngineModel.treemapLayout (bulk geometry),
//     TreemapRect, NodeID, node names for labels.
//   - Model/CleanupStore.swift: stagedNodes for the amber striping.
//   - Model/Palette.swift: all colors (channel fills, staged amber).
//   - SwiftUI: Canvas (async renderer), gestures, context menu.
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - Views/MainView.swift embeds TreemapPane in the right split pane.
//
// STRUCTURE
//   - TreemapPane: owns the rect buffer; relayout policy (resize +
//     generation bumps + mid-scan width scaling)
//   - TreemapContent: drawing (canvas / stripe / groupLabels /
//     scanningOverlay) + interaction (taps, context menu, hitTest)
//
// BEHAVIOR & INVARIANTS
//   - Relayout happens ONLY on: appear, pane resize, layoutGeneration
//     bump. Never on selection/staging/color changes — those recolor or
//     re-stroke the SAME geometry, which is what keeps the map stable.
//   - The Canvas closure must not touch main-actor state: it renders
//     asynchronously (possibly off-main), so everything it reads is
//     snapshotted into locals before the closure is built.
//   - Hit-testing prefers the DEEPEST LEAF under the cursor; directory
//     rects are a fallback only (files always win over their ancestors).
//   - Mid-scan, geometry is laid out into progressFraction of the width
//     (floor 25%), and the remaining strip is the hatched overlay (1d).
// =============================================================================

/// The treemap (1b: dominant, ~75% of the window). Geometry comes from the
/// engine as one bulk buffer; this view only draws pixels: flat fills with
/// a subtle per-rect gradient, hairline nesting, group labels, selection
/// ring, staged-for-cleanup striping (1e), and the mid-scan hatched region
/// with the 2 s settle cadence (1d).
struct TreemapPane: View {
    @EnvironmentObject private var state: AppState

    /// The current engine geometry. Plain @State: replaced wholesale on
    /// each relayout, never mutated in place.
    @State private var rects: [TreemapRect] = []

    var body: some View {
        GeometryReader { geo in
            // The three relayout triggers, and ONLY these (the contract
            // documented on AppState.layoutGeneration): first appearance,
            // pane resize, generation bump. cleanup is passed through so
            // TreemapContent observes staging changes directly — those
            // restripe but never relayout.
            TreemapContent(cleanup: state.cleanup, rects: rects, mapSize: geo.size)
                .onAppear { relayout(size: geo.size) }
                .onChange(of: geo.size) { _, newSize in relayout(size: newSize) }
                .onChange(of: state.layoutGeneration) { _, _ in relayout(size: geo.size) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x0E0F12))
        )
    }

    /// Fetch fresh geometry from the engine for the current zoom root,
    /// pane size, and metric (one bulk buffer per call, APP-FFI-2).
    private func relayout(size: CGSize) {
        guard let model = state.model, size.width > 10, size.height > 10 else { return }
        // During a scan the map fills the scanned fraction of the pane and
        // grows on the settle cadence; the remainder is the hatched
        // "still scanning" region (1d). The 0.25 floor keeps early-scan
        // rects large enough to be readable and clickable.
        let fraction = state.isScanning ? max(0.25, state.progressFraction) : 1.0
        let width = size.width * fraction
        rects = model.treemapLayout(
            root: state.treemapRoot, width: width, height: size.height,
            algorithm: .squarified, minPixel: 2, metric: state.sizeMetric)
    }
}

// MARK: - Content: drawing + interaction

/// The drawing and interaction layer over an already-computed rect buffer.
/// Layered as canvas (all rect pixels) → groupLabels (top-level pill
/// labels) → scanningOverlay (the 1d hatched region), with tap gestures
/// and the item context menu on top.
private struct TreemapContent: View {
    @EnvironmentObject private var state: AppState
    /// Observed directly: staging must restripe the map immediately (1e).
    /// (CleanupStore updates do not flow through AppState's environment
    /// object — see the observation-topology note in AppState/MainView.)
    @ObservedObject var cleanup: CleanupStore
    let rects: [TreemapRect]
    /// Full pane size — the scanning overlay needs it to size the
    /// not-yet-scanned strip beyond the laid-out width.
    let mapSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            canvas
            groupLabels
            scanningOverlay
        }
        .contentShape(Rectangle())
        .gesture(doubleTap)
        .gesture(singleTap)
        .contextMenu {
            if let selection = state.selection {
                Button("Reveal in Finder") { state.revealInFinder(selection) }
                Button("Copy Path") { state.copyPath(selection) }
                Divider()
                Button("Re-scan From Here") { state.rescan(selection) }
                    .disabled(state.isScanning || state.isRefreshing)
                Button(
                    cleanup.stagedNodes.contains(selection)
                        ? "Remove from Cleanup" : "Add to Cleanup"
                ) {
                    state.toggleCleanup(selection)
                }
            }
        }
    }

    /// The main rect renderer. Draw order inside the Canvas closure:
    /// leaf fills + gradient + hairline + striping + labels, then
    /// directory boundary hairlines, then the selection ring on top.
    private var canvas: some View {
        // Snapshot main-actor state before the closure: with
        // rendersAsynchronously the renderer may run off-main, and a
        // closure that captured `state`/`cleanup` would read main-actor
        // ObservableObjects from a background thread (a data race, and a
        // torn frame if staging changes mid-render). Everything below is
        // copied into immutable locals; the closure captures ONLY values.
        let rects = self.rects
        let staged = cleanup.stagedNodes
        let isolated = state.isolatedCategory
        let mode = state.colorMode
        // Resolve the selection to its frame now — the closure must not
        // search state at draw time.
        let selectedFrame = state.selection.flatMap { sel in
            rects.first(where: { $0.node == sel })?.frame
        }
        // Pre-fetch names for label-worthy rects: engine calls are not
        // allowed inside the render closure either (model is Sendable,
        // but per-frame FFI chatter is exactly what APP-FFI-2 avoids).
        var labels: [UInt64: String] = [:]
        if let model = state.model {
            for rect in rects where !rect.isDir && rect.w > 92 && rect.h > 24 {
                labels[rect.node.raw] = model.name(of: rect.node)
            }
        }

        return Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
            for rect in rects where !rect.isDir {
                let frame = rect.frame
                guard frame.width >= 0.5, frame.height >= 0.5 else { continue }
                var color = Palette.color(for: rect, mode: mode)
                // Chip click-to-isolate (1b): dim everything else.
                if let isolated, rect.category != isolated {
                    color = color.opacity(0.13)
                }
                let path = Path(frame)
                context.fill(path, with: .color(color))

                // Subtle per-rect gradient (design: "flat fills + hairline
                // nesting + a subtle per-rect gradient", not 2003 cushions).
                if isolated == nil || rect.category == isolated {
                    let gradient = Gradient(colors: [
                        Color.white.opacity(0.10), Color.black.opacity(0.12),
                    ])
                    context.fill(
                        path,
                        with: .linearGradient(
                            gradient,
                            startPoint: frame.origin,
                            endPoint: CGPoint(x: frame.maxX, y: frame.maxY)))
                }

                // Hairline.
                context.stroke(path, with: .color(Color.black.opacity(0.45)), lineWidth: 0.5)

                // Staged-for-cleanup striping (1e).
                if staged.contains(rect.node) {
                    stripe(context: context, frame: frame)
                }

                // Leaf labels for big rects.
                if let name = labels[rect.node.raw] {
                    context.draw(
                        Text(name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.95)),
                        in: CGRect(
                            x: frame.minX + 4, y: frame.minY + 2,
                            width: frame.width - 8, height: 14))
                }
            }

            // Directory hairlines: subtree boundaries without borders-war.
            for rect in rects where rect.isDir && rect.depth > 0 {
                context.stroke(
                    Path(rect.frame), with: .color(Color(hex: 0x0A0B0E).opacity(0.62)),
                    lineWidth: 1)
            }

            // Selection ring (1b: the clicked file is ringed in the map).
            if let frame = selectedFrame {
                context.stroke(Path(frame.insetBy(dx: 1, dy: 1)), with: .color(.white), lineWidth: 2)
                context.stroke(Path(frame), with: .color(Color.accentColor), lineWidth: 2)
            }
        }
    }

    /// Staged-for-cleanup marking (1e): 45° amber stripes clipped to the
    /// rect, plus a solid amber border. GraphicsContext is a value type,
    /// so `var stripes = context` copies it and the clip applies only to
    /// this rect's stripes, not to subsequent drawing. Diagonals run from
    /// bottom-left to top-right, starting one rect-height early so the
    /// first band already crosses the rect; 12pt spacing of 4pt lines.
    private func stripe(context: GraphicsContext, frame: CGRect) {
        var stripes = context
        stripes.clip(to: Path(frame))
        var x = frame.minX - frame.height
        while x < frame.maxX {
            var line = Path()
            line.move(to: CGPoint(x: x, y: frame.maxY))
            line.addLine(to: CGPoint(x: x + frame.height, y: frame.minY))
            stripes.stroke(line, with: .color(Palette.staged.opacity(0.55)), lineWidth: 4)
            x += 12
        }
        stripes.stroke(Path(frame), with: .color(Palette.staged), lineWidth: 2)
    }

    /// Labels for the largest top-level groups, pill-style (design 1b).
    /// Only depth-1 directories, only comfortably large rects, only the
    /// four biggest by area — enough orientation without clutter.
    private var groupLabels: some View {
        let groups =
            rects
            .filter { $0.isDir && $0.depth == 1 && $0.w > 120 && $0.h > 60 }
            .sorted { $0.w * $0.h > $1.w * $1.h }
            .prefix(4)
        return ForEach(Array(groups), id: \.node.raw) { rect in
            Text(state.model?.name(of: rect.node) ?? "")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0x0A0B0E).opacity(0.82))
                )
                .offset(x: rect.x + 5, y: rect.y + 5)
        }
    }

    /// The 1d "still scanning" region: hatched, with the cadence note.
    /// Sized as the complement of the laid-out width (same fraction + 25%
    /// floor formula as relayout, so overlay and geometry always meet at
    /// the same x). Skipped entirely once the remainder is under 20pt —
    /// a sliver-wide hatch would just flicker at the edge.
    @ViewBuilder
    private var scanningOverlay: some View {
        if state.isScanning {
            let scannedWidth = mapSize.width * max(0.25, state.progressFraction)
            if scannedWidth < mapSize.width - 20 {
                ZStack {
                    Canvas { context, size in
                        var x: CGFloat = -size.height
                        while x < size.width {
                            var band = Path()
                            band.move(to: CGPoint(x: x, y: size.height))
                            band.addLine(to: CGPoint(x: x + size.height, y: 0))
                            context.stroke(
                                band, with: .color(Color(hex: 0x1C1D23)), lineWidth: 14)
                            x += 28
                        }
                    }
                    .background(Color(hex: 0x17181D))
                    VStack(spacing: 2) {
                        Text("still scanning")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: 0x6F707A))
                        Text("map settles every 2 s")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: 0x54555E))
                    }
                }
                .frame(width: mapSize.width - scannedWidth)
                .offset(x: scannedWidth)
                .animation(.easeOut(duration: 0.5), value: scannedWidth)
            }
        }
    }

    // Click → engine-shaped hit test over the returned buffer → select →
    // outline expands and scrolls to it (APP-COUPLE-2). Everything is
    // clickable mid-scan (1d).
    private var singleTap: some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { event in
                if let node = hitTest(at: event.location) {
                    state.select(node: node, revealInOutline: true)
                }
            }
    }

    /// Double-click a folder rect to descend (zoom/re-root).
    /// The hit is almost always a LEAF, so zoom targets its PARENT — the
    /// folder the user visually double-clicked inside. Guarded against
    /// zooming into the current root (a no-op that would push junk onto
    /// the back stack).
    private var doubleTap: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { event in
                guard let node = hitTest(at: event.location), let model = state.model else {
                    return
                }
                let parent = (try? model.info(node))?.parent ?? .invalid
                if parent.isValid, parent != state.treemapRoot {
                    state.zoomInto(parent)
                }
            }
    }

    /// Point → node over the rect buffer (the app-side half of
    /// APP-COUPLE-2's hit test; geometry is engine data, so scanning the
    /// buffer IS testing the engine's answer).
    ///
    /// Precedence, two passes: (1) the DEEPEST LEAF containing the point —
    /// files always beat every enclosing directory, and deeper beats
    /// shallower where small leaves overlay group areas; (2) only if no
    /// leaf contains the point (padding/culled slivers inside a group),
    /// fall back to the deepest DIRECTORY, so clicks in the gaps still
    /// select the enclosing folder.
    private func hitTest(at point: CGPoint) -> NodeID? {
        var best: TreemapRect?
        for rect in rects where !rect.isDir && rect.frame.contains(point) {
            if best == nil || rect.depth > best!.depth { best = rect }
        }
        if best == nil {
            for rect in rects where rect.isDir && rect.frame.contains(point) {
                if best == nil || rect.depth > best!.depth { best = rect }
            }
        }
        return best?.node
    }
}
