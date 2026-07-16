import Foundation

/// A mounted volume with real capacity figures (design 1f: the picker rows
/// are "already useful before any scan"). Figures come from macOS and are
/// passed to the engine for `<Unknown>` reconciliation (APP-TARGET-3).
struct VolumeInfo: Identifiable, Equatable {
    let url: URL
    let name: String
    let total: UInt64
    let free: UInt64
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

    var used: UInt64 { total > free ? total - free : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 0 }
    /// The design flags the volume that's the reason you opened the app.
    var isLowOnSpace: Bool { total > 0 && freeFraction < 0.10 }

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
    /// scan target is a dropped folder, not a whole volume).
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

/// Recent scans for the 1f welcome chips.
enum RecentScans {
    private static let key = "recentScanPaths"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ path: String) {
        var recents = load().filter { $0 != path }
        recents.insert(path, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(5)), forKey: key)
    }
}
