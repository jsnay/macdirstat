# MacDirStat

A native macOS disk-usage visualizer: a size-sorted outline coupled to a
dominant treemap, a progressive scan you can explore while it runs, and a
staged, Trash-first cleanup flow. Swift/SwiftUI host over the
[dirstat-core](https://github.com/jsnay/dirstat-core) Rust engine (C ABI).

**The boundary rule**: the engine owns *facts about the data* (sizes,
counts, sort order, aggregation, layout rectangles); this app owns *macOS*
(pixels, RGB, Finder/Trash, permissions, menus). If you're unsure where
something lives, that sentence decides it.

## What it does

The UX follows a deliberate design direction that supersedes the original
WinDirStat-parity chrome:

- **The window is the picker.** No modal front door: volumes with real
  capacity bars and a low-space badge, a drop-anything target, recent scans,
  and the Full Disk Access ask on one calm surface.
- **Evolved two-pane layout.** The outline is a Mac sidebar with one
  smart column (name + size + a %-of-root bar behind the row, largest
  first); the treemap gets ~75% of the window; the type list is a legend
  chip strip with click-to-isolate (full table on ⌘T); free space is the
  capacity footer; `<Unknown>` splits into two honest footer signals — a
  read-failure line driven by actual scan errors (an amber "Grant Full
  Disk Access" call-to-action only when the grant is really absent;
  neutral "system-protected" wording once it's granted, since FDA lifts
  TCC but never POSIX permissions), and a clickable capacity-gap note
  ("N GB in snapshots, system volumes & purgeable space") that opens a
  per-bucket breakdown popover.
- **The scan is the show.** Determinate progress (bytes vs used-bytes,
  denominator known up front), counters that only go up, a map that
  subdivides on a ~2 s settle cadence with a hatched "still scanning"
  region, everything clickable mid-scan, and Stop keeps what was found.
- **Delete via staging, not sniping.** Items collect in a Cleanup list
  (striped amber in the map) with a running reclaim total; one review, one
  commit — to Trash, always. Path-aware hints ("Xcode rebuilds this", "may
  be the only backup of this device"); system-critical paths can't be
  staged; after commit the engine refreshes so every pane reconciles.
- **Color = meaning.** Three channels over the same geometry: **Kind**
  (8 stable categories, default), **Age** (bright = recent, dark = untouched
  — "big and dark" is the delete-me signal), **Extension** (top-12 slots,
  the parity channel). The app owns every RGB value.

Plus, from field use: **on-disk (allocated) sizes by default** with a
View-menu Apparent toggle, **Re-scan From Here** (context menus) / **⌘R**
re-scan selection / **⇧⌘R** re-scan all, Finder-style **arrow-key tree
navigation** (→ expands/steps in, ← collapses/jumps to parent), and correct
APFS volume-group accounting (see "macOS storage truths" below).

## Repository map

| Path | What it is |
|---|---|
| `Sources/MacDirStat/Engine/Engine.swift` | The FFI wrapper — the only file with raw pointers. Opaque `NodeID`s, lazy row fetches, one bulk buffer per treemap layout, progress marshalled to the main actor. |
| `Sources/MacDirStat/Model/AppState.swift` | The state machine: scan lifecycle + 2 s settle cadence, selection/zoom stacks, size metric, `OutlineStore` sidebar rows. |
| `Sources/MacDirStat/Model/CleanupStore.swift` | Staging vs committing, the system-path guard + `/System/Volumes/Data` canonicalization, path-aware hints. |
| `Sources/MacDirStat/Model/Palette.swift` | Every RGB in the app (kind/age/extension channels, ambers) + byte formatting. |
| `Sources/MacDirStat/Model/Volumes.swift` | Mounted volumes with capacity figures; the boot-volume → Data-volume scan-path rule; recents. |
| `Sources/MacDirStat/Views/` | Welcome picker, main two-pane surface, sidebar outline, treemap canvas, cleanup review sheet, ⌘T type table. |
| `Sources/CDirstatCore/include/dirstat_core.h` | The **pinned** engine header (generated upstream — never edit here; the build fails if it drifts from the engine's). |
| `Tests/MacDirStatTests/` | Unit tests for the pure app-side logic (cleanup guard, hints, palette completeness). |
| `Scripts/build-engine.sh`, `Makefile` | Engine staging + header-pin gate + app bundling. |
| `deferrals.md` | What's deferred vs what the design review deliberately cut. |

Every Swift file opens with a structured header (purpose, upstream
dependencies, downstream consumers, structure, behavior & invariants) —
start there when reviewing.

## Building (macOS 14+, Xcode 15+ / Swift 5.9+, Rust toolchain)

```sh
git clone https://github.com/jsnay/dirstat-core ../dirstat-core   # sibling checkout
make run        # builds the Rust engine, stages .lib/, swift run
make test       # engine + swift test
make app        # release build bundled (ad-hoc signed) as MacDirStat.app
make install    # make app + copy to /Applications
```

Two safety gates connect the repos: `Scripts/build-engine.sh` **fails the
build if the pinned header differs from the engine's** (so Swift and Rust
can't silently disagree), and the wrapper verifies `ds_abi_version()` at
launch (so a stale staticlib dies loudly, never mid-scan).

## Full Disk Access

macOS grants disk access per *responsible app*, so how you launch matters:

- **`make run` / `swift run` from a terminal** — the scan runs with your
  terminal's permissions. Grant **Terminal** (or iTerm) Full Disk Access in
  System Settings → Privacy & Security → Full Disk Access, quit and reopen
  it, and re-run. The MacDirStat binary itself will never appear in that
  list when run this way.
- **`make install` → launch `/Applications/MacDirStat.app`** — add the app
  itself to the Full Disk Access list (＋ button → select MacDirStat.app).
  The bundle is ad-hoc signed; after a rebuild/reinstall the grant may need
  to be toggled off/on once since the binary identity changed.

Without the grant, protected areas (Mail, Messages, Time Machine locals,
some caches) fail to read and surface as the amber "N locations couldn't
be read — Grant Full Disk Access" call-to-action in the footer. With the
grant, a couple hundred root-owned OS directories still fail — FDA lifts
TCC protections, not POSIX permissions — so the footer switches to
neutral "N system-protected locations couldn't be read" wording instead
of pointing you at a pane that can't help. Either way the math
reconciles; you just can't see inside them.

## macOS storage truths (why the numbers are the way they are)

These bit us in field testing and are now handled deliberately:

- **The boot "volume" is an APFS volume group.** The Data volume is mounted
  at `/System/Volumes/Data`, and your directories are *also* visible at `/`
  through firmlinks. Scanning naively counts everything twice. MacDirStat
  scans the Data volume directly (still labeled "Macintosh HD"), and the
  engine additionally dedupes aliased directory inodes as defense in depth.
- **Apparent sizes lie on modern filesystems.** Cloud-only placeholder
  files (OneDrive/iCloud "dataless" files) report full size while occupying
  ~0 bytes; APFS clones double-report; sparse files (Docker.raw) inflate.
  That's why **on-disk (allocated) size is the default metric** — it's the
  number that matches your actual disk. View → Sizes toggles Apparent back
  on when you want it.
- **"Free space" means three things on macOS.** Strictly free blocks (what
  our footer shows); Finder's "available" (free + purgeable: snapshots,
  caches, evictable cloud files); and the installer check
  (`…ForImportantUsage`, which assumes purgeables get purged). If macOS says
  an update won't fit even though Finder shows space, hunting big
  *allocated* files here is what actually helps.
- **Used-bytes will never equal the sum of your files.** The volume
  figures macOS reports are container-wide, but a scan measures one
  volume's files — the difference legitimately holds APFS local Time
  Machine snapshots (often tens of GB), the sealed System volume, VM swap,
  Preboot/Recovery/Update, and purgeable space. No permission grant can
  surface any of it, which is why the footer labels this gap neutrally
  ("in snapshots, system volumes & purgeable space") and reserves the
  Full Disk Access call-to-action for paths the scan actually failed to
  read.

## Logging & diagnostics

The app keeps a local trace log so field issues are diagnosable after the
fact: `~/Library/Logs/MacDirStat/macdirstat-YYYY-MM-DD.log`, one file per
day, mirrored to the unified log (subsystem `com.macdirstat.app`) for live
Console.app debugging. Logged: scan lifecycle summaries (target, totals,
durations, error counts), the capacity reconciliation and its breakdown,
the Full Disk Access probe result, cleanup decisions (refusals, TOCTOU
trips, per-item commit outcomes), and engine events routed through
`ds_set_log_callback` (ABI v5). Volume is bounded — summaries and
decisions, never per-file lines.

**Retention**: files older than 90 days are deleted at launch, and the
directory is capped at 50 MB (oldest first). **Privacy**: log lines
contain scanned paths; they never leave the machine (the app has no
network access) and expire on the schedule above. When filing an issue,
attaching the latest log file is the single most useful thing you can do.

## Testing & CI

- Engine correctness (sizes, sorting, dedup, layout geometry) is proven in
  dirstat-core's own suite and **not re-proven here**.
- `EngineIntegrationTests` drives the **real engine through the Swift
  wrapper** — scan → navigate → treemap layout + hit-test → refresh →
  cancel → cleanup commit, plus AppState zoom/metric and the outline's
  reveal-past-the-cap behavior — with no mocks. The
  wrapper is the highest-risk file in the app and both field bugs lived at
  this seam, so this is the real integration proof (EVA-FFI-1).
- `CleanupTests` covers the safety-critical pure logic: the system-path
  refusal rules (including the Data-volume canonicalization), the
  **TOCTOU-safe `FileIdentity`** (a replaced file / symlink swap is
  detected before deletion), the **root-refusal** check, deletion hints,
  byte formatting, the footer's FDA-CTA/capacity-gap split (including the
  granted-FDA "system-protected" wording), the capacity-gap partition
  math, the log-retention pruning rules, volume routing, and palette
  completeness.
- CI builds the real engine from a sibling checkout (matching branch, else
  `main`) and runs `swift build` + `swift test` on a macOS runner. All
  third-party GitHub Actions are SHA-pinned.

## Security posture

Read/scan-only except for one guarded operation (Move to Trash). No network
access, no shell execution, no third-party runtime dependencies. Deletion is
staged, reviewed, Trash-only, and gated by: a system-path guard, refusal of
non-UTF-8 names (whose lossy path could denote a different file), and a
TOCTOU re-check of `(device, inode)` immediately before each trash. The app
refuses to run as root. Diagnostic logs are local-only with bounded
retention (see "Logging & diagnostics"). See the repo issues for the full
threat model.

## License

MIT. Clean-room: built from the spec documents and public Apple/Rust docs;
no WinDirStat (GPL) source was read or used.
