# MacDirStat — Native macOS App Requirements & Evals (Swift)

**Version:** 2.0 (supersedes the stack assumption in `MacDirStat-Requirements.md`)
**Status:** Implementation-ready
**Platform:** macOS 14+ · **Stack:** Swift, SwiftUI (UI), AppKit interop where needed (treemap `NSView`/Metal, table performance)
**License:** MIT
**Depends on:** `dirstat-core` (Rust engine, MIT/Apache) via its C-ABI. This app owns **all UI and OS integration**; it owns **no scanning/sizing/treemap-geometry logic** — those come from the engine.

This is one of three documents:
- `dirstat-core-Spec.md` — the engine (scan, sizing, synthetic-node math, treemap geometry, type aggregation, save/reload, FFI).
- `MacDirStat-App-Spec.md` (this file) — the native app.
- `MacDirStat-Requirements.md` / `-Evals.md` — original product-level parity reference.

---

## 0. Architecture boundary (read first)

MacDirStat is the **host**. It links the `dirstat-core` static library and talks to it across the documented C-ABI (§9 of the engine spec). The rule of thumb for "which side owns this":

- **Engine owns:** anything that's a *fact about the data* — sizes, counts, percentages, sort order, type aggregation, the 12-slot color assignment, treemap rectangles + cushion coefficients, save/reload, scan progress numbers.
- **App owns:** anything that's *macOS* — windows, split views, outline/table rendering, the treemap pixels (shading, palette RGB, grid, selection frame), Finder/Trash/Launch Services/Terminal, Settings UI, accessibility, menus/toolbar/shortcuts, permissions/entitlements/notarization, localization.

Requirement IDs: `APP-<AREA>-<n>`. RFC-2119 applies. Evals in §13.

---

## 1. FFI integration layer (NEW — the Swift side of the seam)

- **APP-FFI-1** A Swift wrapper module **MUST** encapsulate the entire C-ABI so the rest of the app never touches raw pointers. It exposes idiomatic Swift types (`EngineModel`, `Node`, `TypeStat`, `TreemapRect`) backed by engine handles.
- **APP-FFI-2** The wrapper **MUST** implement the recommended boundary design: the engine owns the tree, Swift holds `NodeId` handles and fetches `NodeInfo` lazily for *visible* rows only; the treemap layout is fetched as one bulk buffer per (re)layout.
- **APP-FFI-3** Engine progress callbacks arrive on engine threads; the wrapper **MUST** marshal them to the main actor before touching UI state.
- **APP-FFI-4** The wrapper **MUST** own model lifetime (call `model_free` deterministically) and **MUST** invalidate cached `NodeId`s when a model is freed/replaced.
- **APP-FFI-5** Every engine error code **MUST** be surfaced as a Swift `Error` with the engine's `last_error` detail; no silent failures.
- **APP-FFI-6** The pinned C header version the app builds against **MUST** match the linked library; a mismatch **MUST** fail the build (cross-check engine CORE-FFI-SAFE-3).
- **APP-FFI-7** The universal (arm64 + x86_64) static lib **MUST** link cleanly; the build documents how the Rust artifact is produced/fetched.

---

## 2. Scan target selection (owns original FR-TARGET-*)

- **APP-TARGET-1** On first launch (no saved session) present a native target-selection screen (the Mac equivalent of the Select Drives Dialog).
- **APP-TARGET-2** Three mutually-exclusive modes: All local volumes / Individual volumes / A specific folder (via `NSOpenPanel`).
- **APP-TARGET-3** Volume rows show name, mount path, total, free, used, used% — figures obtained from macOS (`URLResourceValues`/`statfs`) and **passed to the engine** as the volume figures it needs for `<Free Space>`/`<Unknown>`.
- **APP-TARGET-4** Exclude network volumes from "All local volumes"; keep them selectable in the other two modes.
- **APP-TARGET-5** Persist and pre-select the last-used selection.
- **APP-TARGET-6** Accept path(s) via CLI args and Finder "open folder"; begin scan without the picker.
- **APP-TARGET-7** Support multiple roots; each is a top-level node (engine supports this; app renders it).

## 3. Permissions / sandbox (owns original FR-PERM-* on the OS side)

- **APP-PERM-1** Request access through the standard macOS mechanism (security-scoped resources / Full Disk Access prompt); show a clear, actionable message on denial.
- **APP-PERM-2** Persist security-scoped bookmarks so re-scans don't re-prompt.
- **APP-PERM-3** When the OS denies a path, the app passes that fact to the engine so the bytes feed `<Unknown>` (engine CORE-SCAN-13); the app surfaces unreadable areas in the scan-report UI.

## 4. Scan UX / lifecycle (owns the UX around original FR-SCAN-10..16)

- **APP-SCAN-1** Display live progress (items found, bytes counted, current path) driven by engine progress callbacks; determinate when the engine provides an estimate, else a clear indeterminate indicator.
- **APP-SCAN-2** Update the Directory List progressively during the scan (partial results).
- **APP-SCAN-3** Provide Cancel (engine cancellation); offer "keep partial" vs "back to picker". Pause/resume SHOULD; cancel/restart MUST.
- **APP-SCAN-4** Provide Refresh Selected and Refresh All in the UI, wired to the engine's refresh calls; update all three views afterward.
- **APP-SCAN-5** Provide Save Scan / Open Scan UI wired to engine save/load; mark reloaded scans as a dated snapshot and disable destructive on-disk actions (engine flags it; app enforces it in the UI).
- **APP-SCAN-6** Show a viewable scan report (errors, denied paths, `<Unknown>` clamp notes from the engine).

## 5. Three coupled views — layout & coupling (owns original FR-VIEW-*, FR-COUPLE-*)

- **APP-VIEW-1** Present Directory List, Type List, Treemap in the recognizable WinDirStat three-pane arrangement using native `NSSplitView`/SwiftUI split views with draggable, persisted dividers.
- **APP-VIEW-2** Each pane independently resizable; layout, divider positions, column widths/order persist.
- **APP-VIEW-3** Light/dark mode; correct Retina/HiDPI rendering.
- **APP-VIEW-4** Standard window behaviors: full screen; multiple windows each holding an independent `EngineModel`.
- **APP-COUPLE-1** Directory List selection → frame in Treemap + select type in Type List.
- **APP-COUPLE-2** Treemap click → engine hit-test → select file → expand+scroll Directory List → select its type.
- **APP-COUPLE-3** Type List selection → highlight all files of that type in Treemap (engine supplies which nodes are that type/slot).
- **APP-COUPLE-4** Single shared selection model: Directory List and Treemap selection always identical.
- **APP-COUPLE-5** Coupling reflects within one frame (~50 ms).

## 6. Directory List (owns original FR-DIR-* rendering)

- **APP-DIR-1** Expandable outline (`NSOutlineView` or SwiftUI equivalent) of dirs+files with Finder icons, sized largest-first by default.
- **APP-DIR-2** Default sort size-desc at every level; expanding re-sorts children via the engine's sorted enumeration.
- **APP-DIR-3** Header-click sorting with asc/desc toggle and a native sort indicator; sort performed by the engine (within-parent, stable secondary key).
- **APP-DIR-4** Expand all / collapse all for a subtree (triangle, keyboard, menu).
- **APP-DIR-COL** Columns, all toggle-able/reorderable/persisted: Name(+icon), Size (honors logical/physical setting), Subtree % bar, Percent, Files, Subdirs, Items, Last Change, Attributes. Optional hidden-by-default: Created, Owner, Physical size, per-level count.
- **APP-DIR-ATTR** The app **MUST** interpret the engine's raw attribute bits into macOS labels: Hidden, Locked/Read-only, Restricted/SIP, Symbolic link, Package/Bundle, Compressed (HFS/APFS), Encrypted — documented in-app.
- **APP-DIR-NAV** Click selects; arrow keys navigate; treemap frame follows; selecting a file auto-selects+scrolls its type in the Type List.
- **APP-DIR-CTX** Right/Control-click shows the item context menu (§10 actions).

## 7. Type / Extension List (owns original FR-EXT-* rendering)

- **APP-EXT-1** List every type from the engine's aggregation, sorted by bytes-desc by default.
- **APP-EXT-2** Columns: Extension(+icon), Color swatch, Description (macOS UTI/Launch-Services description), Bytes, % Bytes, Files.
- **APP-EXT-3** Map the engine's 12 distinct palette **slots** + "other" to actual **RGB colors** the app owns (themeable, dark-mode-aware, with a color-blind-friendly option). Legend swatches and treemap colors **MUST** use the identical RGB mapping.
- **APP-EXT-4** Clicking a type highlights all its files in the treemap (via engine slot membership).
- **APP-EXT-5** Show synthetic pseudo-types (`<Free Space>` grey, `<Unknown>` yellow) in the legend with fixed colors when those nodes are present.

## 8. Treemap rendering (owns original FR-TM-* pixels)

- **APP-TM-1** Render the engine's computed rectangles: each file a colored rect, directories nested, area ∝ size. The app does **not** compute geometry; it requests `treemap_layout` from the engine for the current view rect/zoom.
- **APP-TM-2** Apply cushion shading using the engine's per-rect cushion coefficients, producing the 3D-relief look; render efficiently (Core Graphics or Metal) and crisply at 2×.
- **APP-TM-3** Expose the layout-style choice (KDirStat default / Squarified) and pass it to the engine per layout.
- **APP-TM-4** Cushion shading parameters (brightness, height/relief, ambient, scale) are app settings passed into the engine layout call; the app renders the returned coefficients.
- **APP-TM-5** Grid lines on/off + grid color; selection-frame color — all app-rendered, configurable.
- **APP-TM-6** Click → engine hit-test → selection (APP-COUPLE-2). Hover tooltip with name/size/path (SHOULD).
- **APP-TM-7** Selection frame drawn around the selected file/dir's rect.
- **APP-TM-8** Zoom in (selected subtree fills view; Directory List marks subtree root with a frame) / Zoom out; Select Parent / Re-select Child commands; macOS-appropriate keyboard shortcuts, documented in Help.
- **APP-TM-9** Type-selection highlight: dim non-matching rects (engine tells the app which nodes match).
- **APP-TM-10** Re-request layout on pane resize; keep the UI responsive (offload layout to engine on a background queue, render on main).

## 9. Settings (owns original FR-CFG-* UI)

Native Settings window; all persisted. UI for: scan options (cross-FS, follow symlinks, follow firmlinks, opaque bundles — app supplies the bundle-extension list to the engine, include hidden, primary metric logical/physical, show free space, show unknown); list style (grid/stripes/alt rows); columns; scan-time % display + bar colors; treemap style + cushion params + grid + selection color + custom palette (the RGB override for the 12 slots); units (binary default / decimal); localization; **and the up-to-10 custom commands** (enabled, title, command line, `%p %n %sp %sn` placeholders documented in-editor, item-type restriction, recursive flag). Plus Restore Defaults.

- **APP-CFG-CMD** Custom commands execute via the user's shell with **safely quoted** placeholders; a warning is shown before running; output + exit status surfaced; never vulnerable to injection. (This is OS execution → app-side, not engine.)

## 10. Item actions (owns original FR-ACT-* — all OS integration)

All reachable from main menu, toolbar, and context menu; each has a ⌘-shortcut. **None of these live in the engine.**

- **APP-ACT-1** Refresh Selected (calls engine refresh, then re-renders).
- **APP-ACT-2** Copy Path.
- **APP-ACT-3** Open (Launch Services; confirm before launching executables/apps).
- **APP-ACT-4** Reveal in Finder.
- **APP-ACT-5** Open Terminal Here (Terminal or configured terminal at the item's dir).
- **APP-ACT-6** Move to Trash (OS API), then call engine refresh and update all views/totals.
- **APP-ACT-7** Delete Permanently (explicit confirmation), then engine refresh.
- **APP-ACT-8** Get Info (size/dates/owner/permissions/attributes, or Finder Get Info).
- **APP-ACT-9** Generate Report: reproduce the Directory List lines beneath the selection in current expansion+sort order (data from engine, formatting app-side); offer copy/email.
- **APP-ACT-10** Custom commands appear by title, enabled only for targeted item types.
- **APP-ACT-11** Destructive actions require confirmation, are disabled on synthetic nodes and on reloaded snapshots.
- **APP-ACT-12** After any FS mutation, the app calls engine refresh so aggregates/type totals/synthetic nodes/treemap stay consistent.
- **APP-ACT-13** Multi-selection for safe actions (Copy Path, Move to Trash with one combined confirmation) — SHOULD.

## 11. Menus / toolbar / shortcuts (owns original FR-UI-*)

- **APP-UI-1** Standard macOS menu bar: App / File (open target, open recent, save scan, open scan, refresh, close) / Edit / View (toggle panes, columns, treemap style, zoom, expand/collapse) / Actions / Window / Help.
- **APP-UI-2** Customizable toolbar (open/new scan, refresh, reveal, trash, zoom) via "Customize Toolbar".
- **APP-UI-3** Every action + nav/zoom command has a documented ⌘-shortcut; Help → Keyboard Shortcuts lists all.
- **APP-UI-4** About window + Help explaining views, synthetic nodes, columns, treemap.
- **APP-UI-5** Status/summary area: root(s), total size, item count, free space, last-scan timestamp.

## 12. Non-functional (app side) (owns original NFR on the UI/OS side)

- **APP-PERF-1** UI responsive (no main-thread stall >100 ms) during scan/sort/render; engine work is off-main, rendering on-main.
- **APP-PERF-2** Selection coupling median <50 ms over 100 selections.
- **APP-PERF-3** Treemap render+resize on a 1M-item tree feels interactive (engine layout within budget; app render within budget).
- **APP-A11Y-1** VoiceOver: lists/columns/actions labeled; treemap exposes an accessible alternative (the Directory List is the accessible representation).
- **APP-A11Y-2** Honor system text size/contrast; color-blind-friendly palette option.
- **APP-SEC-1** Ship notarized, hardened-runtime, minimal entitlements; graceful Full-Disk-Access flow.
- **APP-I18N-1** All strings externalized (String Catalog); English built-in default; dates/numbers respect locale.

---

## 13. App evals (XCUITest / snapshot / integration)

Engine correctness (sizes, sort order, treemap geometry, synthetic math, type aggregation, save/reload round-trip) is proven in `dirstat-core` evals and **not re-proven here**; app evals assume a correct engine (use a stub/recorded model where helpful) and verify *integration, rendering, OS behavior, and UX*.

| Eval ID | Requirement | Type | Pass criteria |
|---|---|---|---|
| EVA-FFI-1 | APP-FFI-1..7 | integration | Swift wrapper drives a real engine end-to-end; raw pointers never escape the wrapper (API audit); header/lib version match enforced. |
| EVA-FFI-3 | APP-FFI-3 | integration | Progress callbacks update UI only on main actor (thread-assertion). |
| EVA-FFI-5 | APP-FFI-5 | unit | Forced engine error surfaces as Swift Error with detail. |
| EVA-TARGET-1..7 | APP-TARGET-* | UI | Picker modes, volume figures match OS, network exclusion, persistence, CLI/Finder open, multi-root. |
| EVA-PERM-1..3 | APP-PERM-* | integration | Permission prompt + denial message; bookmark persistence; denied path feeds `<Unknown>` and shows in report. |
| EVA-SCAN-1..6 | APP-SCAN-* | UI | Live progress; progressive list; cancel + keep-partial/back; refresh; save/open + snapshot lock; scan report. |
| EVA-VIEW-1..4 | APP-VIEW-* | UI/snapshot | Three-pane native layout; persistence; dark mode + 2×; full screen + multi-window. |
| EVA-COUPLE-1..5 | APP-COUPLE-* | UI/perf | All four coupling directions correct; selection identical across views; <50 ms. |
| EVA-DIR-* | APP-DIR-* | UI | Outline, default+header sort indicators, expand/collapse, all columns render correct engine values, attribute labels correct, arrow-key nav, context menu. |
| EVA-EXT-* | APP-EXT-* | UI/snapshot | Type list columns; 12-slot→RGB mapping identical in legend & treemap; type-click highlight; synthetic legend colors. |
| EVA-TM-1..10 | APP-TM-* | snapshot/UI | Rects rendered from engine; cushion relief from coefficients; style switch; param sliders change shading; grid/selection color; click hit-test selects; zoom in/out + subtree-root frame; type dimming; resize re-layouts; crisp at 2×. |
| EVA-CFG-* | APP-CFG-*, APP-CFG-CMD | UI/integration | Every setting persists & takes effect; custom-command editor caps at 10, documents placeholders, restricts by type, runs recursive depth-first, safely quotes (injection test with spaces/quotes), shows warning + output; Restore Defaults. |
| EVA-ACT-1..13 | APP-ACT-* | integration | Each action's OS effect verified (clipboard, Finder reveal, Terminal opens, file in Trash, permanent delete after confirm, Get Info, report content, custom-command menu gating, destructive-disabled on synthetic/snapshot, post-action consistency, multi-select). |
| EVA-UI-1..5 | APP-UI-* | UI | Menus, toolbar+customize, every shortcut works + listed in Help, About/Help content, status summary fields. |
| EVA-PERF-1..3 | APP-PERF-* | perf | No >100 ms main-thread stall; coupling <50 ms; 1M-item treemap interactive. |
| EVA-A11Y-1..2 | APP-A11Y-* | UI | VoiceOver audit passes; treemap has accessible alternative; high-contrast/color-blind palette honored; text-size respected. |
| EVA-SEC-1 | APP-SEC-1 | integration | Built artifact is notarized, hardened-runtime, minimal entitlements; FDA flow graceful. |
| EVA-I18N-1 | APP-I18N-1 | unit | Pseudo-loc finds no hard-coded strings; locale-aware dates/numbers. |

### Coverage gate (app)
Releasable only when every `APP-*` ID appears in ≥1 eval, all MUST pass, SHOULD pass or are deferred with sign-off, and the FFI integration + security evals pass (no deferral). The engine's own gate (in `dirstat-core-Spec.md`) must also be green.

---

## 14. Combined traceability (product → two repos)

Every original `FR-*`/`NFR-*` is now owned by exactly one side:
- **Engine (`CORE-*`):** all scanning, sizing, counts, percentages, sort logic, synthetic-node math, type aggregation + 12-slot assignment, treemap geometry + cushion coefficients, units math, save/reload.
- **App (`APP-*`):** target/permissions UX, scan UX, three-view layout + coupling UX, all rendering (lists, treemap pixels, RGB palette), Finder/Trash/Launch Services/Terminal, settings UI + custom-command execution, menus/toolbar/shortcuts, accessibility, localization, notarization, and the FFI wrapper.

A CI script greps all three documents and fails if any original product requirement is unaccounted for on either side, or if any `CORE-*`/`APP-*` ID lacks an eval.
