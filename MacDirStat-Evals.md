# MacDirStat — Evaluation & Test Specification

**Version:** 1.0
**Companion to:** `MacDirStat-Requirements.md` (every `FR-*` / `NFR-*` ID below traces to that document)
**Purpose:** This is the acceptance-test contract for MacDirStat. Each eval is independently verifiable. When handed to Claude Code, this document defines "done": every MUST-level eval must pass; every SHOULD-level eval must pass or carry a documented, accepted deferral.

---

## 0. Test strategy & conventions

### 0.1 Test layers

| Layer | Framework | What it covers |
|---|---|---|
| **Unit** | XCTest / Swift Testing | Pure logic: size accumulation, sorting, percentage math, color assignment, placeholder substitution, unit conversion, treemap layout geometry. |
| **Integration** | XCTest against a real temp file tree | Scan engine on a controlled fixture; refresh; save/reload; permission handling; action side-effects on disk. |
| **UI** | XCUITest | Coupling between views, selection, menus/toolbar/shortcuts, context menus, settings persistence, zoom. |
| **Snapshot** | Image-diff (e.g., point-by-point pixel comparison of rendered treemap) | Treemap rendering, cushion shading, color legend, dark mode, Retina. |
| **Performance** | XCTest `measure` / signposts | Scan throughput, render latency, coupling latency, memory. |
| **Fuzz / stress** | Generated pathological trees | Stability under adversarial inputs. |

### 0.2 Canonical fixtures (build these once; reused by many evals)

- **FIX-TINY** — a hand-built tree with known exact sizes:
  ```
  root/
    a.txt            (1000 B)
    b.txt            (3000 B)
    sub/
      c.jpg          (5000 B)
      d.jpg          (1000 B)
      deep/
        e.bin        (10000 B)
    empty/           (no children)
  ```
  Totals (logical): root = 20000 B; sub = 16000 B; deep = 10000 B. Files=5, Subdirs=3, Items=8.
- **FIX-TYPES** — files spanning ≥15 distinct extensions with controlled per-type byte totals, to test the 12-color + grey rule and Type List math.
- **FIX-EDGE** — zero-byte files, no-extension files, mixed-case extensions (`.JPG`/`.jpg`), Unicode/emoji names, a very long path (deep nesting), a hard-link pair, a symlink, a symlink cycle, an `.app` bundle, a permission-denied subdirectory.
- **FIX-LARGE** — generated tree of ≥1,000,000 small files for performance/memory (created in CI scratch space, not committed).
- **FIX-VOLUME** — a small disk image (`.dmg`/sparse) mounted as a volume, with known capacity and free space, for `<Free Space>` / `<Unknown>` and volume-level evals.

Each fixture has a manifest (JSON) of expected values so evals assert against ground truth, not against the app's own output.

### 0.3 Pass/Fail rule

An eval **passes** only when its stated assertions hold. "Visual" evals pass when the snapshot matches an approved reference within the stated tolerance. Performance evals state explicit budgets; budgets are CI-machine-relative and recorded in `perf-baseline.json`.

---

## 1. Target selection evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-TARGET-1 | FR-TARGET-1 | UI | Launch fresh (no saved session) | Target picker appears before any scan. |
| EV-TARGET-2 | FR-TARGET-2 | UI | Inspect picker | Exactly three mutually-exclusive modes present: All local volumes / Individual volumes / A specific folder. |
| EV-TARGET-3 | FR-TARGET-3 | Integration | Mount FIX-VOLUME; read picker rows | Name, mount path, total, free, used bytes, used% shown; total & free match `statfs`/`URLResourceValues` for that volume within 1 block. |
| EV-TARGET-4 | FR-TARGET-4 | Integration | Attach a network mount + local volume | Network volume excluded from "All local volumes"; present/selectable under "Individual" and "A specific folder". |
| EV-TARGET-5 | FR-TARGET-5 | UI | Choose a target, quit, relaunch | Previous selection pre-selected. |
| EV-TARGET-6 | FR-TARGET-6 | Integration | Launch with a path arg / Finder "open folder" | Scan of that path starts; picker not shown. |
| EV-TARGET-7 | FR-TARGET-7 | Integration | Provide two folder roots | Both appear as top-level nodes; totals independent and correct. |

## 2. Permissions evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-PERM-1 | FR-PERM-1 | Integration | Target a protected location without access | Standard permission request triggered; on denial a clear, actionable message shown; no crash. |
| EV-PERM-2 | FR-PERM-2 | Integration | Grant a folder, quit, relaunch, re-scan | No re-prompt; security-scoped bookmark resolves. |
| EV-PERM-3 | FR-PERM-3 | Integration | Scan FIX-EDGE with a 0700 root-owned subdir | Scan completes; denied dir counted toward `<Unknown>`; item flagged unreadable; no abort. |

## 3. Scan engine evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-SCAN-1 | FR-SCAN-1 | Integration | Scan FIX-TINY | Every file records name, full path, logical size, physical size, mtime, ctime, attributes; values match manifest. |
| EV-SCAN-2 | FR-SCAN-2 | Integration | Scan FIX-TINY | root=20000, sub=16000, deep=10000 B; per-dir Files/Subdirs/Items match manifest exactly. |
| EV-SCAN-3 | FR-SCAN-3 | Unit | Build node tree from manifest | Directory size == sum of descendants; directory's own entry size contributes 0. |
| EV-SCAN-4 | FR-SCAN-4 | Integration | Scan a sparse file + an APFS clone in FIX-EDGE | Logical ≠ physical and both recorded; toggling the metric changes displayed sizes and treemap area source. |
| EV-SCAN-5 | FR-SCAN-5 | Integration | Scan FIX-EDGE hard-link pair | Shared inode counted once toward totals; both paths recorded as sharing the inode. |
| EV-SCAN-6 | FR-SCAN-6 | Integration | Scan FIX-EDGE symlink (follow OFF) | Symlink's own size counted; target not traversed/double-counted. |
| EV-SCAN-7 | FR-SCAN-7 | Integration | Scan across a mount point in FIX-VOLUME (cross OFF) | Traversal stops at the other file system by default. |
| EV-SCAN-8 | FR-SCAN-8 | Integration | Scan FIX-EDGE `.app` bundle (opaque OFF) | Bundle traversed as a directory; (opaque ON) bundle is one leaf item. |
| EV-SCAN-9 | FR-SCAN-9 / NFR-PERF-2 | Performance | Scan FIX-LARGE; sample CPU & main-thread | >1 core utilized; no main-thread stall > 100 ms. |
| EV-SCAN-10 | FR-SCAN-10 | UI | Start scan of FIX-LARGE | Live items-found and bytes-counted update; progress indicator present. |
| EV-SCAN-11 | FR-SCAN-11 | UI | During FIX-LARGE scan | Directory List shows partial results before completion. |
| EV-SCAN-12 | FR-SCAN-12 | UI | Cancel mid-scan | Work stops promptly (< 1 s); app offers "keep partial" vs "back to picker"; state consistent. |
| EV-SCAN-13 | FR-SCAN-13 | UI | Cancel then restart (and pause/resume if implemented) | Cancel/restart works; pause/resume works or is documented as deferred (SHOULD). |
| EV-SCAN-14 | FR-SCAN-14 | Integration | Delete a file mid-scan (race) | No crash; event logged to scan report; totals remain consistent. |
| EV-SCAN-15 | FR-SCAN-15 | Integration | Modify a subtree on disk, "Refresh Selected" | That subtree re-read; all three views updated to match disk. |
| EV-SCAN-16 | FR-SCAN-16 | Integration | "Refresh All" after external changes | All roots re-scanned; totals match new disk state. |
| EV-SCAN-17 | FR-SCAN-17 | Integration | Save scan of FIX-TINY, relaunch, reload | Reloaded tree byte-identical (sizes, counts, dates, attrs, synthetic values) without re-scanning. |
| EV-SCAN-18 | FR-SCAN-18 | UI | Open a reloaded scan | Marked as snapshot with timestamp; destructive on-disk actions disabled or warned. |
| EV-LIMIT-1 | NFR-LIMIT-1 | Unit | Accumulate sizes near 2^63−1 | No overflow; arithmetic exact. |
| EV-LIMIT-2 | NFR-LIMIT-2 | Unit | Synthesize a node with 2^31 children counts | Counts stored/summed without overflow or logic error. |
| EV-LIMIT-3 | NFR-LIMIT-3 | Integration | Scan FIX-EDGE long/deep path & 255-byte name | No truncation/corruption; sizes and names correct. |

## 4. View layout & coupling evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-VIEW-1 | FR-VIEW-1 | UI | Inspect main window | Three regions present in the WinDirStat-style arrangement using native split views. |
| EV-VIEW-2 | FR-VIEW-2 | UI | Drag dividers, reorder/resize columns, quit, relaunch | Layout, divider positions, column widths/order persist. |
| EV-VIEW-3 | FR-VIEW-3 | Snapshot | Toggle dark mode; run on 2× display | Renders correctly in both appearances; crisp at 2×. |
| EV-VIEW-4 | FR-VIEW-4 | UI | Enter full screen; open second window with second scan | Both work; windows independent. |
| EV-COUPLE-1 | FR-COUPLE-1 | UI | Select item in Directory List | Treemap frames it; Type List selects its type. |
| EV-COUPLE-2 | FR-COUPLE-2 | UI | Click a rectangle in treemap | Correct file selected; Directory List expands+scrolls to it; Type List selects its type. |
| EV-COUPLE-3 | FR-COUPLE-3 | UI | Select a type in Type List | All files of that type highlighted in treemap; others de-emphasized. |
| EV-COUPLE-4 | FR-COUPLE-4 | UI | Change selection in either view repeatedly | Directory List and Treemap selection always identical (single shared model). |
| EV-COUPLE-5 | FR-COUPLE-5 / NFR-PERF-4 | Performance | Measure selection→reflection latency | < 50 ms (one frame) median over 100 selections. |

## 5. Directory List evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-DIR-1 | FR-DIR-1 | UI | Inspect list on FIX-TINY | Expandable outline of dirs+files with icons. |
| EV-DIR-2 | FR-DIR-2 | Unit+UI | Default sort on FIX-TINY | Sorted size-desc at every level; expanding keeps size-desc recursively. |
| EV-DIR-3 | FR-DIR-3 | UI | Click a header, click again | Sorts by that column; toggles asc/desc; indicator shows direction. |
| EV-DIR-4 | FR-DIR-4 | Unit | Sort with nested tree | Sort applied only within each parent's children; tree never flattened. |
| EV-DIR-5 | FR-DIR-5 | Unit | Two items equal on primary key | Previous sort column breaks the tie (stable secondary sort). |
| EV-DIR-6 | FR-DIR-6 | UI | Expand all / collapse all on a subtree | Works via triangle, keyboard, and menu. |
| EV-DIR-COL-1..9 | FR-DIR-COL-1..9 | Integration | Read each column on FIX-TINY/FIX-EDGE | Name+icon; Size; Subtree% bar; Percent; Files; Subdirs; Items; Last Change; Attributes — each equals manifest. Attributes map Hidden/Locked/Restricted/Symlink/Package/Compressed/Encrypted correctly. |
| EV-DIR-COL-10 | FR-DIR-COL-10 | UI | Enable optional columns | Created/Owner/Physical-size/per-level count appear and are correct; hidden by default. |
| EV-DIR-7 | FR-DIR-7 | UI | Select a name, use arrow keys | Navigation works; treemap frame follows. |
| EV-DIR-8 | FR-DIR-8 | UI | Select a file | Its type auto-selected and scrolled into view in Type List. |
| EV-DIR-9 | FR-DIR-9 | UI | Drag to reorder/resize columns, relaunch | Persisted. |
| EV-DIR-10 | FR-DIR-10 | UI | Control-click an item | Context menu appears with §10 actions. |

## 6. Extension / Type List evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-EXT-1 | FR-EXT-1 | Integration | Scan FIX-TYPES | Every extension present is listed, aggregated tree-wide. |
| EV-EXT-2 | FR-EXT-2 | Unit | Default sort | Sorted by total bytes desc. |
| EV-EXT-3 | FR-EXT-3 | Unit+Snapshot | FIX-TYPES (≥15 types) | Exactly the top-12-by-bytes get distinct colors; all others share one grey; legend colors == treemap colors. |
| EV-EXT-4 | FR-EXT-4 | Integration | Inspect columns | Extension(+icon), Color swatch, Description (UTI/LS description), Bytes, %Bytes, Files — all correct vs manifest. |
| EV-EXT-5 | FR-EXT-5 | UI | Click a type | Treemap highlights all files of that type (cross-check FR-COUPLE-3). |
| EV-EXT-6 | FR-EXT-6 | Unit | FIX-EDGE no-ext + `.JPG`/`.jpg` | No-extension grouped under "(no extension)"; case-insensitive merge. |
| EV-EXT-7 | FR-EXT-7 | UI | Volume scan with synthetic nodes shown | `<Free Space>` grey & `<Unknown>` yellow appear in legend. |
| EV-EXT-8 | FR-EXT-8 | Integration | Save+reload; re-scan same tree | Type→color mapping deterministic and stable; legend/treemap/saved scan agree. |

## 7. Treemap evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-TM-1 | FR-TM-1 | Unit | Layout FIX-TINY into a known rect | Each file's area ∝ size; ratio of any two file areas == ratio of sizes (within min-pixel tolerance). |
| EV-TM-2 | FR-TM-2 | Unit | Layout nested tree | Each directory's rect fully contains its children; dir area ∝ subtree size. |
| EV-TM-3 | FR-TM-3 | Snapshot | Render FIX-TYPES | Each rectangle's color == its type's legend color. |
| EV-TM-4 | FR-TM-4 | Snapshot | Render with cushion shading on | Per-rectangle relief gradient present; reference image match within tolerance; structure visually conveyed. |
| EV-TM-5 | FR-TM-5 | Unit+Snapshot | Switch KDirStat vs Squarified | Both produce valid, area-correct layouts; KDirStat is default; squarified minimizes aspect ratio (assert max aspect ratio lower than naive slice-and-dice). |
| EV-TM-6 | FR-TM-6 | Snapshot | Vary brightness/height/scale | Each parameter visibly and monotonically changes shading per reference set. |
| EV-TM-7 | FR-TM-7 | Snapshot | Toggle grid lines; change grid color | Grid drawn/removed; color honored. |
| EV-TM-8 | FR-TM-8 | UI | Change selection-frame color | New color used for selection frame. |
| EV-TM-9 | FR-TM-9 | Snapshot | Render at 1× and 2×; resize pane | Crisp at 2×; layout recomputed on resize; no stretching artifacts. |
| EV-TM-10 | FR-TM-10 | UI | Click points inside known rectangles | Hit-testing returns the file whose rect contains the point. |
| EV-TM-11 | FR-TM-11 | Snapshot | Select a file, then a directory | Selection frame drawn; directory's enclosing rect framed. |
| EV-TM-12 | FR-TM-12 | UI | Hover a rectangle | Tooltip shows name, size, path (SHOULD). |
| EV-TM-13 | FR-TM-13 | UI | Zoom in on a subtree, then out | Subtree fills view; Directory List marks subtree root (blue frame); zoom out restores parent. |
| EV-TM-14 | FR-TM-14 | UI | "Select Parent" / "Re-select Child" | Selection moves to parent/child correctly. |
| EV-TM-15 | FR-TM-15 | UI | Use treemap nav shortcuts | macOS-equivalent shortcuts move selection/region; documented in Help. |
| EV-TM-16 | FR-TM-16 | Snapshot | Select a type | All same-type rectangles highlighted, others dimmed. |

## 8. Synthetic node evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-SYN-1 | FR-SYN-1 | Unit | FIX-TINY `sub/` (files + subdir) | `<Files>` node aggregates only immediate files of the dir. |
| EV-SYN-2 | FR-SYN-2 | Unit | Dir with 1 file / dir with no subdirs | `<Files>` omitted in both cases. |
| EV-SYN-3 | FR-SYN-3 | Integration | Volume scan, Show Free Space ON | `<Free Space>` size == volume free space; treemap color fixed dark grey. |
| EV-SYN-4 | FR-SYN-4 | Integration | Compare to OS | Free-space value matches `URLResourceValues.volumeAvailableCapacity`. |
| EV-SYN-5 | FR-SYN-5 | Integration | Volume scan, Show Unknown ON, with denied dir | `<Unknown>` == total − free − measured-sum; treemap color vivid yellow. |
| EV-SYN-6 | FR-SYN-6 | Unit | Force would-be-negative unknown | Clamped to 0; condition noted in scan report. |
| EV-SYN-7 | FR-SYN-7 | UI | Select each synthetic node | Distinct label/color; Open/Delete/Trash/custom actions disabled. |
| EV-SYN-8 | FR-SYN-8 | Integration | Scan a sub-folder (not a volume) | No `<Free Space>` / `<Unknown>` shown. |

## 9. Configuration / Settings evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-CFG-1 | FR-CFG-1 | Integration | Toggle cross-FS, re-scan FIX-VOLUME | Crossing happens only when ON; default OFF. |
| EV-CFG-2 | FR-CFG-2 | Integration | Toggle follow-symlinks, re-scan FIX-EDGE | Target traversed only when ON; default OFF; cycle does not hang. |
| EV-CFG-3 | FR-CFG-3 | Integration | Toggle follow-firmlinks | Honored; default OFF. |
| EV-CFG-4 | FR-CFG-4 | Integration | Toggle bundle-opaque | `.app` treated opaque vs traversed accordingly; default traverse. |
| EV-CFG-5 | FR-CFG-5 | Integration | Toggle physical vs logical primary metric | Sizes and treemap area source switch; default logical. |
| EV-CFG-6 | FR-CFG-6 | Integration | Toggle include-hidden | Hidden files counted only when ON; default ON. |
| EV-CFG-7/8 | FR-CFG-7, FR-CFG-8 | UI | Toggle Show Free Space / Show Unknown | Synthetic nodes appear/disappear accordingly. |
| EV-CFG-9 | FR-CFG-9 | Snapshot | Toggle grid/stripes list style | Applies to all lists. |
| EV-CFG-10 | FR-CFG-10 | UI | Hide/show/reorder/resize columns, relaunch | Persisted across launch. |
| EV-CFG-11 | FR-CFG-11 | UI | Configure scan-time % display + bar colors | Honored during a scan. |
| EV-CFG-12 | FR-CFG-12 | Snapshot | Switch treemap layout style | Cross-check EV-TM-5. |
| EV-CFG-13 | FR-CFG-13 | Snapshot | Adjust cushion params | Cross-check EV-TM-6. |
| EV-CFG-14/15 | FR-CFG-14, FR-CFG-15 | Snapshot | Grid + selection-frame color | Cross-check EV-TM-7/8. |
| EV-CFG-16 | FR-CFG-16 | Snapshot | Override the 12 default colors | Custom palette used in legend + treemap. |
| EV-CFG-17 | FR-CFG-17 | Unit | Switch binary/decimal units | 1 KiB=1024 vs 1 KB=1000; labels unambiguous; default binary. |
| EV-CFG-18 | FR-CFG-18 / NFR-I18N-1 | Unit | Pseudo-localize; change system locale | No hard-coded strings; dates/numbers respect locale; English is built-in default. |
| EV-CFG-19 | FR-CFG-19 | UI | Define 11 custom commands | Capped at 10; each has enabled/title/command-line. |
| EV-CFG-20 | FR-CFG-20 | Unit | Substitute `%p %n %sp %sn` (path/name/parent-path/parent-name) for a selected item | Each placeholder resolves correctly; meanings documented in editor. |
| EV-CFG-21 | FR-CFG-21 | UI+Integration | Restrict a command to dirs; mark recursive | Command enabled only for dirs; recursion runs depth-first. |
| EV-CFG-22 | FR-CFG-22 | Integration | Run a custom command with a path containing spaces/quotes | Placeholders safely quoted; warning shown pre-run; output + exit status surfaced; no shell injection. |
| EV-CFG-23 | FR-CFG-23 | UI | Restore Defaults | All settings reset to documented defaults. |

## 10. Item action evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-ACT-1 | FR-ACT-1 | Integration | Modify item, Refresh Selected | Item re-read; views update (cross-check EV-SCAN-15). |
| EV-ACT-2 | FR-ACT-2 | UI | Copy Path | Clipboard contains exact full path. |
| EV-ACT-3 | FR-ACT-3 | Integration | Open a `.txt`; attempt Open on an executable/app | Doc opens in default app; executable launch requires confirmation. |
| EV-ACT-4 | FR-ACT-4 | Integration | Reveal in Finder | Finder activates with the item selected. |
| EV-ACT-5 | FR-ACT-5 | Integration | Open Terminal Here on a dir | Terminal (or configured terminal) opens at that directory. |
| EV-ACT-6 | FR-ACT-6 | Integration | Move to Trash a fixture file | File in Trash (recoverable); item + ancestor totals + Type List + synthetic nodes + treemap updated. |
| EV-ACT-7 | FR-ACT-7 | Integration | Delete Permanently after confirm | File gone irrecoverably; explicit confirmation required; views refreshed. |
| EV-ACT-8 | FR-ACT-8 | UI | Get Info | Shows size, dates, owner/permissions, attributes (or invokes Finder Get Info). |
| EV-ACT-9 | FR-ACT-9 | Integration | Generate Report on a dir | Report reproduces the Directory List lines beneath it, in current expansion + sort order; copy/email offered. |
| EV-ACT-10 | FR-ACT-10 | UI | Custom commands in menus | Appear by title in main/context menu; enabled only for targeted item types. |
| EV-ACT-11 | FR-ACT-11 | UI | Attempt destructive action on synthetic node and on reloaded snapshot | Disabled/blocked; confirmation required for real destructive actions. |
| EV-ACT-12 | FR-ACT-12 | Integration | After Move to Trash | All aggregates, Type List totals, synthetic nodes, treemap consistent with new state. |
| EV-ACT-13 | FR-ACT-13 | UI | Multi-select then Copy Path / Move to Trash | Multi-select actions work with a single combined confirmation (SHOULD). |

## 11. Menus / toolbar / shortcuts evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-UI-1 | FR-UI-1 | UI | Walk the menu bar | App/File/Edit/View/Actions/Window/Help present with the listed commands. |
| EV-UI-2 | FR-UI-2 | UI | Inspect + customize toolbar | Key actions present; "Customize Toolbar" works. |
| EV-UI-3 | FR-UI-3 | UI | Trigger every action/zoom via keyboard | Each has a working shortcut (⌘-based); Help → Keyboard Shortcuts lists them all. |
| EV-UI-4 | FR-UI-4 | UI | Open About + Help | About present; Help explains views, synthetic nodes, columns, treemap. |
| EV-UI-5 | FR-UI-5 | UI | Inspect status/summary area | Shows root(s), total size, item count, free space, last-scan timestamp. |

## 12. Data-correctness evals (high priority)

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-DATA-1 | FR-DATA-1 | Unit | Sum children vs parent on FIX-TINY (logical+physical) | Equal within display-unit rounding for both metrics, at every node. |
| EV-DATA-2 | FR-DATA-2 | Unit | Sum Type List bytes on FIX-TYPES | Equals total of all real files (synthetic excluded). |
| EV-DATA-3 | FR-DATA-3 | Unit | Compare two file areas within a dir | Area ratio == size ratio (within min-pixel tolerance, applied consistently). |
| EV-DATA-4 | FR-DATA-4 | Unit | Subtree% and Percent on FIX-TINY | Subtree% relative to expanded parent; Percent relative to root; values match manifest. |
| EV-DATA-5 | FR-DATA-5 | Unit | Counts at every node | Items == Files + Subdirs everywhere. |
| EV-DATA-6 | FR-DATA-6 | Unit | Convert known byte values | 1 KiB=1024, 1 MiB=1024 KiB, 1 GiB=1024 MiB exactly when binary selected. |

## 13. Non-functional evals

| Eval ID | Requirement | Type | Procedure | Pass criteria |
|---|---|---|---|---|
| EV-PERF-1 | NFR-PERF-1 | Performance | Scan FIX-LARGE (≥100k items) on CI SSD | Completes within recorded budget (target ≤ ~10 s, machine-relative); regression > 20% fails. |
| EV-PERF-2 | NFR-PERF-2 | Performance | Sample main thread during scan/sort/render | No stall > 100 ms. |
| EV-PERF-3 | NFR-PERF-3 | Performance | Treemap render+resize on 1,000,000-item tree | Within recorded interactive budget; uses incremental/observed-region rendering if needed. |
| EV-PERF-4 | NFR-PERF-4 | Performance | 100 selection changes | Median coupling latency < 50 ms. |
| EV-MEM-1 | NFR-MEM-1 | Performance | Scan FIX-LARGE on a 16 GB machine | No crash/OOM; memory scales ~linearly; per-item footprint recorded. |
| EV-STAB-1 | NFR-STAB-1 | Fuzz | Run FIX-EDGE + generated pathological trees (symlink cycle, 0-byte, Unicode, very deep) | No crash, hang, or data corruption. |
| EV-A11Y-1 | NFR-A11Y-1 | UI | VoiceOver audit | Lists/columns/actions have accessibility labels; treemap has an accessible alternative (Directory List). |
| EV-A11Y-2 | NFR-A11Y-2 | UI/Snapshot | Enable high-contrast / color-blind palette; change text size | Honored; legend palette has accessible option. |
| EV-SEC-1 | NFR-SEC-1 | Integration | Inspect signed build + entitlements | Notarized, hardened runtime, minimal entitlements; Full-Disk-Access flow graceful. |

## 14. Optional / future parity evals (SHOULD)

These correspond to §14 non-goals / FR-EXT-FUTURE. Failing these does **not** block v1, but each must be either passing or explicitly deferred with sign-off.

| Eval ID | Feature | Pass criteria |
|---|---|---|
| EV-OPT-1 | Duplicate detection by content hash | Identical files grouped; counted once in a "duplicates" report; design does not require reworking the scan model. |
| EV-OPT-2 | Large-file finder | A view/filter lists the N largest files across the tree, correctly ordered. |
| EV-OPT-3 | Cloud placeholder awareness | iCloud "dataless"/offline files detected and flagged; logical vs on-disk reported. |
| EV-OPT-4 | Filter / search within results | Filtering the Directory List/Type List by name/extension/size works and re-couples views. |

---

## 15. Traceability matrix (coverage gate)

The build is releasable only when this gate passes:

1. **Every** `FR-*` and `NFR-*` ID in `MacDirStat-Requirements.md` appears in at least one eval row above. (CI script greps both documents and fails the build if any requirement ID has zero matching eval IDs.)
2. **Every MUST-level** requirement's evals pass.
3. **Every SHOULD-level** requirement's evals pass *or* carry a recorded deferral in `deferrals.md`.
4. Data-correctness evals (§12) and stability eval EV-STAB-1 are **mandatory blockers** — no deferral permitted.

### Quick coverage checklist (areas → eval sections)
- Target selection → §1 · Permissions → §2 · Scan engine → §3 · Layout/coupling → §4 · Directory List → §5 · Type List → §6 · Treemap → §7 · Synthetic nodes → §8 · Settings → §9 · Actions → §10 · Menus/shortcuts → §11 · Data correctness → §12 · Non-functional → §13 · Optional → §14.
