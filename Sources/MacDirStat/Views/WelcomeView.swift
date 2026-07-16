import AppKit
import SwiftUI
import UniformTypeIdentifiers

// =============================================================================
// FILE: Sources/MacDirStat/Views/WelcomeView.swift
// =============================================================================
//
// PURPOSE
//   The first-run / empty-window surface (design 1f): "the window is the
//   picker." Instead of a modal drive-selection dialog in front of an empty
//   window, the empty state itself shows mounted volumes with real capacity
//   bars (useful before any scan), a drop-anything target, recent scans,
//   and the Full Disk Access ask — calmly, in context, before the first
//   scan produces an embarrassing "unreadable" number.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - Model/AppState.swift: startScan(path:volume:) — the only action this
//     screen performs.
//   - Model/Volumes.swift: VolumeInfo.mounted() for the volume rows (with
//     capacity/free/low-space), RecentScans for the recents chips.
//   - Model/Palette.swift: warning amber for the FDA banner, ByteFormat.
//   - SwiftUI onDrop + UniformTypeIdentifiers (.fileURL) for the drop
//     target; AppKit NSWorkspace to open the Full Disk Access pane.
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - MacDirStatApp.swift (RootView) shows WelcomeView for the .welcome
//     phase; nothing else references it.
//
// STRUCTURE
//   - WelcomeView: headline, volume rows, drop target, recents, FDA banner
//   - dropTarget: dashed onDrop zone (loads a file URL, starts a scan)
//   - fullDiskAccessBanner: the in-context permissions ask
//   - abbreviate: home-relative path shortening for recents chips
//   - VolumeRow: one volume card — icon, name, low-space badge, used bar,
//     free-of-total line, Scan button
//
// BEHAVIOR & INVARIANTS
//   - Volumes/recents load in onAppear, not init: cheap, and re-fetched
//     each time the user returns to the picker.
//   - The dropped-URL callback arrives off the main actor; the Task
//     { @MainActor } hop before startScan keeps AppState main-isolated.
//   - The low-space badge threshold lives in VolumeInfo.isLowOnSpace
//     (<10% free) — the view only renders the fact.
// =============================================================================

/// First run: the window IS the picker (design 1f). No modal front door —
/// volumes with real capacity bars, a drop-anything target, recents, and
/// the Full Disk Access ask, all on one calm surface.
struct WelcomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var volumes: [VolumeInfo] = []
    @State private var recents: [String] = []
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Where did your space go?")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.top, 34)
                    Text("Pick a volume or drop any folder. Scanning changes nothing on disk.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    VStack(spacing: 10) {
                        ForEach(volumes) { volume in
                            VolumeRow(volume: volume) {
                                state.startScan(path: volume.url.path, volume: volume)
                            }
                        }
                    }
                    .padding(.top, 22)

                    dropTarget
                        .padding(.top, 14)

                    if !recents.isEmpty {
                        HStack(spacing: 8) {
                            Text("Recent:")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(recents.prefix(3), id: \.self) { path in
                                Button {
                                    state.startScan(path: path, volume: nil)
                                } label: {
                                    Text(abbreviate(path))
                                        .font(.system(size: 11.5))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 16)
                    }
                }
                .frame(maxWidth: 660)
                .padding(.horizontal, 36)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity)
            }

            fullDiskAccessBanner
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            volumes = VolumeInfo.mounted()
            recents = RecentScans.load()
        }
    }

    private var dropTarget: some View {
        HStack(spacing: 8) {
            Text("…or drop any folder here")
            Text("— ⌘O to browse").foregroundStyle(.tertiary)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.primary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    state.startScan(path: url.path, volume: nil)
                }
            }
            return true
        }
    }

    /// The permissions ask happens here, in context, before the first scan
    /// produces an embarrassing "unreadable" number (1f).
    private var fullDiskAccessBanner: some View {
        HStack(spacing: 10) {
            Text("**Full Disk Access** lets MacDirStat see Mail, Messages and system caches — otherwise they show up as “unreadable.”")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Grant…") {
                let pane = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                NSWorkspace.shared.open(pane)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 12)
        .background(Palette.warning.opacity(0.12))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo
    let onScan: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.15))
                .overlay(
                    Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                        .foregroundStyle(.secondary))
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(volume.name)
                        .font(.system(size: 13.5, weight: .semibold))
                    if volume.isLowOnSpace {
                        Text("\(Int((volume.freeFraction * 100).rounded()))% FREE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(hex: 0xA33D30))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(hex: 0xF6E3E0).opacity(0.9)))
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(volume.isLowOnSpace ? Color(hex: 0xA33D30).opacity(0.75) : Color.accentColor.opacity(0.65))
                            .frame(width: geo.size.width * volume.usedFraction)
                    }
                }
                .frame(height: 6)
                Text(
                    "\(ByteFormat.compact(volume.free)) free of \(ByteFormat.compact(volume.total))"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Button("Scan", action: onScan)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.08)))
        )
    }
}
