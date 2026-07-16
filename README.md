# MacDirStat

A native macOS disk-usage visualizer: a size-sorted outline coupled to a
dominant treemap, a progressive scan you can explore while it runs, and a
staged, Trash-first cleanup flow. Swift/SwiftUI host over the
[dirstat-core](https://github.com/jsnay/dirstat-core) Rust engine (C ABI).

The UX follows the accepted Claude Design review (options **1b, 1d, 1e, 1f,
1g**), which supersedes the original WinDirStat-parity chrome:

- **1f — the window is the picker.** No modal front door: volumes with real
  capacity bars, a drop-anything target, recent scans, and the Full Disk
  Access ask on one calm surface.
- **1b — evolved two-pane layout.** The outline is a Mac sidebar with one
  smart column (name + size + a %-of-root bar behind the row, largest
  first); the treemap gets ~75% of the window; the type list is a legend
  chip strip with click-to-isolate (full table on ⌘T); free space is the
  capacity footer; `<Unknown>` is an amber "N GB unreadable — Grant Full
  Disk Access" call-to-action.
- **1d — the scan is the show.** Determinate progress (bytes vs used-bytes,
  denominator known up front), counters that only go up, a map that
  subdivides on a ~2 s settle cadence with a hatched "still scanning"
  region, everything clickable mid-scan, and Stop keeps what was found.
- **1e — delete via staging, not sniping.** Items collect in a Cleanup list
  (striped amber in the map) with a running reclaim total; one review, one
  commit — to Trash, always. Path-aware hints ("Xcode rebuilds this",
  "may be the only backup of this device"); system-critical paths can't be
  staged; after commit the engine refreshes so every pane reconciles.
- **1g — color = meaning.** Three channels over the same geometry: **Kind**
  (8 stable UTI-style categories, default), **Age** (bright = recent, dark =
  untouched — "big and dark" is the delete-me signal), **Extension**
  (top-12 slots, the parity channel). The app owns every RGB value; the
  engine owns which key each node gets.

## Building (macOS 14+, Xcode 15+ / Swift 5.9+, Rust toolchain)

```sh
git clone https://github.com/jsnay/dirstat-core ../dirstat-core   # sibling checkout
make run        # builds the Rust engine, stages .lib/, swift run
make test       # engine + swift test
make app        # release build bundled as MacDirStat.app
make install    # make app + copy to /Applications
```

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
some caches) are skipped and surface as the amber "N GB unreadable" figure
in the footer — the math still reconciles, you just can't see inside them.

`Scripts/build-engine.sh` builds `libdirstat_core.a` and **fails the build
if the checked-in header** (`Sources/CDirstatCore/include/dirstat_core.h`)
**differs from the engine's** — the header pin. The wrapper additionally
verifies `ds_abi_version()` at startup.

## Architecture

- `Sources/MacDirStat/Engine/` — the FFI wrapper: the only file that sees
  raw pointers. The engine owns the tree; Swift holds opaque `NodeID`s,
  fetches visible rows lazily, and gets treemap layouts as one bulk buffer.
  Progress callbacks are marshalled to the main actor here.
- `Sources/MacDirStat/Model/` — app state: scan lifecycle + 2 s settle
  cadence, selection/zoom, color channels + palettes (the app owns RGB),
  cleanup staging with the system-path guard and path hints, volumes.
- `Sources/MacDirStat/Views/` — SwiftUI: welcome/picker, toolbar, sidebar
  outline, treemap canvas, legend chips, capacity footer, cleanup pill +
  review sheet, type table.

Boundary rule: the engine owns *facts about the data*; the app owns
*macOS*. See `MacDirStat-App-Spec.md` §0 and `deferrals.md` for what is
deferred vs cut-by-design.

## License

MIT. Clean-room: built from the spec documents and public Apple/Rust docs;
no WinDirStat (GPL) source was read or used.
