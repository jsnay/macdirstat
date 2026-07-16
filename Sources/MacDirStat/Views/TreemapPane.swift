import SwiftUI

/// The treemap (1b: dominant, ~75% of the window). Geometry comes from the
/// engine as one bulk buffer; this view only draws pixels: flat fills with
/// a subtle per-rect gradient, hairline nesting, group labels, selection
/// ring, staged-for-cleanup striping (1e), and the mid-scan hatched region
/// with the 2 s settle cadence (1d).
struct TreemapPane: View {
    @EnvironmentObject private var state: AppState

    @State private var rects: [TreemapRect] = []

    var body: some View {
        GeometryReader { geo in
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

    private func relayout(size: CGSize) {
        guard let model = state.model, size.width > 10, size.height > 10 else { return }
        // During a scan the map fills the scanned fraction of the pane and
        // grows on the settle cadence; the remainder is the hatched
        // "still scanning" region (1d).
        let fraction = state.isScanning ? max(0.25, state.progressFraction) : 1.0
        let width = size.width * fraction
        rects = model.treemapLayout(
            root: state.treemapRoot, width: width, height: size.height,
            algorithm: .squarified, minPixel: 2)
    }
}

private struct TreemapContent: View {
    @EnvironmentObject private var state: AppState
    /// Observed directly: staging must restripe the map immediately (1e).
    @ObservedObject var cleanup: CleanupStore
    let rects: [TreemapRect]
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

    private var canvas: some View {
        // Snapshot main-actor state before the closure: with
        // rendersAsynchronously the renderer may run off-main.
        let rects = self.rects
        let staged = cleanup.stagedNodes
        let isolated = state.isolatedCategory
        let mode = state.colorMode
        let selectedFrame = state.selection.flatMap { sel in
            rects.first(where: { $0.node == sel })?.frame
        }
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
