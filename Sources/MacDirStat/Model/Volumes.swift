import Foundation

// =============================================================================
// FILE: Sources/MacDirStat/Model/Volumes.swift
// =============================================================================
//
// PURPOSE
//   Everything the app knows about mounted volumes, straight from macOS:
//   discovery of pickable volumes with real capacity figures (design 1f —
//   the picker rows are useful before any scan), the used/free math, the
//   low-space flag, and — critically — the `scanPath` decision that
//   redirects a boot-volume scan to the APFS Data volume. Also holds the
//   tiny UserDefaults-backed recent-scans list for the welcome chips.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - Foundation only: FileManager mounted-volume enumeration,
//     URLResourceValues capacity keys, UserDefaults. Deliberately no
//     engine dependency — this is pure macOS knowledge (APP-TARGET-3).
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - Views/WelcomeView.swift: VolumeInfo.mounted() for picker rows,
//     RecentScans.load() for the chips.
//   - Model/AppState.swift: VolumeInfo.containing(path:) for dropped
//     folders, volume.total/free passed to the engine, volume.used as the
//     determinate-progress denominator, scanPath for the "/" redirect,
//     RecentScans.record on scan start.
//
// STRUCTURE
//   - VolumeInfo: one mounted volume + derived fractions + scanPath
//   - RecentScans: 5-entry MRU of scanned paths in UserDefaults
//
// BEHAVIOR & INVARIANTS
//   - Capacity figures come from macOS and flow TO the engine (which owns
//     the free/unknown reconciliation math) — never the other way.
//   - APFS volume-group service volumes are never listed as picker rows;
//     the boot-volume row represents the whole group.
// =============================================================================

/// A mounted volume with real capacity figures (design 1f: the picker rows
/// are "already useful before any scan"). Figures come from macOS and are
/// passed to the engine for `<Unknown>` reconciliation (APP-TARGET-3).
struct VolumeInfo: Identifiable, Equatable {
    /// Mount point (e.g. "/" or /Volumes/Backup).
    let url: URL
    /// User-visible volume name ("Macintosh HD").
    let name: String
    /// Capacity in bytes, from URLResourceValues.
    let total: UInt64
    /// Available bytes; `used` is derived from these two.
    let free: UInt64
    /// Internal vs external drive — picker row icon only.
    let isInternal: Bool

    var id: String { url.path }

    /// The path the engine should actually walk. For the boot volume this
    /// is the APFS **Data** volume (`/System/Volumes/Data`): it holds all
    /// user data on one device, and scanning it directly avoids traversing
    /// the firmlinked directories (`/Users`, `/Applications`, …) twice —
    /// the double-count that made a 256 GB disk read as a terabyte. The
    /// sealed System volume's few GB are accounted via the capacity
    /// reconciliation instead.
    var scanPath: String {
        if url.path == "/" {
            // Existence check keeps this correct on pre-Catalina layouts
            // (no volume group): fall through and scan "/" itself.
            var isDirectory: ObjCBool = false
            let data = "/System/Volumes/Data"
            if FileManager.default.fileExists(atPath: data, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return data
            }
        }
        return url.path
    }

    /// Bytes in use; clamped at 0 (macOS can transiently report free >
    /// total on APFS due to purgeable space).
    var used: UInt64 { total > free ? total - free : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 0 }
    /// The design flags the volume that's the reason you opened the app.
    var isLowOnSpace: Bool { total > 0 && freeFraction < 0.10 }

    /// Enumerate the volumes worth showing in the picker: browsable, with
    /// a real capacity, excluding hidden volumes and the APFS service
    /// mounts. Snapshot semantics — call again to refresh.
    static func mounted() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey,
        ]
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            // The APFS volume-group service volumes (Data/VM/Preboot/…)
            // are surfaced through the boot volume row, never separately.
            if url.path.hasPrefix("/System/Volumes/") { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.volumeIsBrowsable ?? false,
                let total = values.volumeTotalCapacity, total > 0
            else { return nil }
            return VolumeInfo(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                total: UInt64(total),
                free: UInt64(values.volumeAvailableCapacity ?? 0),
                isInternal: values.volumeIsInternal ?? false)
        }
    }

    /// Figures for the volume containing an arbitrary folder (used when the
    /// scan target is a dropped folder, not a whole volume). The engine
    /// still needs the CONTAINING volume's total/free for reconciliation
    /// and the progress denominator. `url` is the folder itself, not the
    /// mount point — sufficient for the resource-value queries used here.
    static func containing(path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            ]), let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        return VolumeInfo(
            url: url,
            name: values.volumeName ?? "",
            total: UInt64(total),
            free: UInt64(values.volumeAvailableCapacity ?? 0),
            isInternal: true)
    }
}

// MARK: - Recent scans (welcome chips)

/// Recent scans for the 1f welcome chips. A 5-entry most-recent-first
/// list in UserDefaults; recording an existing path moves it to the front.
enum RecentScans {
    private static let key = "recentScanPaths"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Record a scan target: dedupe, prepend, trim to 5.
    static func record(_ path: String) {
        var recents = load().filter { $0 != path }
        recents.insert(path, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(5)), forKey: key)
    }
}

// MARK: - Capacity-gap decomposition (app#17)

/// The honest breakdown of the capacity gap (`total − free − measured`).
/// On an APFS boot disk that gap is real data the scan can never see:
/// sibling volumes in the container (sealed System, VM swap, Preboot,
/// Update), purgeable space, and local Time Machine snapshots. `partition`
/// is pure math (unit-tested); `gather` is the impure collector.
struct CapacityBreakdown: Equatable {
    /// Used bytes on the container's other volumes (boot-group scans only).
    let systemVolumes: UInt64
    /// macOS's own estimate of space it would free under pressure
    /// (`…ForImportantUsage` minus strictly-free) — includes thinnable
    /// snapshot space, evictable cloud files, disposable caches.
    let purgeable: UInt64
    /// Whatever the first two don't explain: snapshot blocks beyond the
    /// purgeable estimate plus filesystem metadata. Deliberately a
    /// remainder — per-snapshot "size" is ill-defined on APFS (shared
    /// blocks), so we never pretend to a precision we don't have.
    let snapshotsAndMetadata: UInt64

    /// Clamp-partition `unknown` so the segments can never exceed it (the
    /// inputs are estimates from different subsystems and may overlap).
    static func partition(
        unknown: UInt64, systemVolumesUsed: UInt64, purgeableEstimate: UInt64
    ) -> CapacityBreakdown {
        let sys = min(systemVolumesUsed, unknown)
        let purge = min(purgeableEstimate, unknown - sys)
        return CapacityBreakdown(
            systemVolumes: sys,
            purgeable: purge,
            snapshotsAndMetadata: unknown - sys - purge)
    }

    /// Collect the inputs and partition. Sibling-volume figures only make
    /// sense when the scan target is the boot volume group's Data volume;
    /// for any other target the gap is purgeable + remainder.
    static func gather(unknown: UInt64, scanTarget: String) -> CapacityBreakdown {
        var sys: UInt64 = 0
        if scanTarget == "/System/Volumes/Data" || scanTarget == "/" {
            // statfs Used (f_blocks − f_bfree, in f_bsize units) matches
            // df's per-volume Used column on APFS.
            for mount in [
                "/", "/System/Volumes/VM", "/System/Volumes/Preboot",
                "/System/Volumes/Update", "/System/Volumes/Hardware",
            ] {
                var st = statfs()
                if statfs(mount, &st) == 0, st.f_blocks >= st.f_bfree {
                    sys += (st.f_blocks - st.f_bfree) &* UInt64(st.f_bsize)
                }
            }
        }
        var purge: UInt64 = 0
        let vals = try? URL(fileURLWithPath: scanTarget).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = vals?.volumeAvailableCapacityForImportantUsage,
            let avail = vals?.volumeAvailableCapacity, important > Int64(avail)
        {
            purge = UInt64(important - Int64(avail))
        }
        return partition(unknown: unknown, systemVolumesUsed: sys, purgeableEstimate: purge)
    }
}
