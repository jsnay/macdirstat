# MacDirStat — Functional Requirements Specification

**Version:** 1.0
**Status:** Implementation-ready
**Target platform:** macOS 14 (Sonoma) and later
**Tech stack:** Swift, SwiftUI (UI layer), AppKit interop where required (custom treemap rendering, table performance)
**Document purpose:** This is a *functional and test specification*. It defines **what** MacDirStat must do, not **how** to architect it. It is written to be handed directly to Claude Code as the authoritative scope of work. A companion document, `MacDirStat-Evals.md`, defines the acceptance tests for every requirement here.

---

## 0. How to read this document

- Every requirement has a stable ID of the form `FR-<AREA>-<n>` (functional requirement) or `NFR-<AREA>-<n>` (non-functional requirement).
- Each requirement uses RFC-2119 keywords: **MUST**, **MUST NOT**, **SHOULD**, **MAY**.
- Each functional requirement maps to one or more evals in `MacDirStat-Evals.md` via the same ID.
- "Parity" means *behavioral equivalence with WinDirStat*, adapted to macOS conventions. Where WinDirStat behavior is Windows-specific (shell commands, drive letters, recycle bin), the macOS-native equivalent is specified explicitly.
- Terminology: an **item** is any node in the scanned tree (a file, a directory, or a synthetic node). A **synthetic node** is `<Files>`, `<Free Space>`, or `<Unknown>` (see §8).

---

## 1. Product overview

MacDirStat is a native macOS disk-usage statistics viewer and cleanup tool. It scans a volume, folder, or set of folders, computes the size of every file and the aggregate size of every directory subtree, and presents the result in three coupled views:

1. **Directory List** — a sortable, expandable outline of the tree, sized largest-first.
2. **Extension/Type List** — a breakdown of disk usage by file type, which also acts as the color legend.
3. **Treemap** — a cushion-shaded treemap where each file is a rectangle whose area is proportional to its size.

The three views are **coupled**: a selection in any one view is reflected in the other two. The user can act on any selected item (reveal, open, move to Trash, delete, get info, copy path, run a custom command).

The product goal is exhaustive feature parity with WinDirStat, with the user experience modernized to macOS conventions (Finder integration, Trash, APFS awareness, Retina rendering, dark mode, sandbox/permissions model).

---

## 2. Scan target selection

### 2.1 Target picker

- **FR-TARGET-1** On launch with no prior session, the app **MUST** present a target-selection screen (the macOS equivalent of WinDirStat's "Select Drives Dialog").
- **FR-TARGET-2** The picker **MUST** offer three mutually exclusive modes:
  - **All local volumes** — every mounted local (non-network) volume.
  - **Individual volumes** — a multi-select list of mounted volumes.
  - **A specific folder** — a single folder chosen via the standard macOS open panel (`NSOpenPanel`), including network/SMB/AFP mounts and external drives.
- **FR-TARGET-3** The volume list **MUST** display, per volume: name, mount path, total capacity, free space, used space (bytes), and used/total as a percentage. Capacity figures **MUST** match what Finder/Disk Utility report for the same volume.
- **FR-TARGET-4** The app **MUST** distinguish local volumes from network volumes and **MUST NOT** include network volumes in "All local volumes" mode. Network volumes remain selectable in "Individual volumes" or "A specific folder" mode.
- **FR-TARGET-5** The last-used selection **MUST** persist across launches and be pre-selected the next time the picker opens.
- **FR-TARGET-6** The app **MUST** accept one or more paths as command-line arguments and/or via "open folder" from Finder, and begin scanning that target without showing the picker.
- **FR-TARGET-7** Multiple paths **MAY** be scanned in a single session; when more than one root is scanned, each appears as a top-level node.

### 2.2 Permissions

- **FR-PERM-1** When a scan target requires permission the app does not yet hold (e.g., a protected folder, Full Disk Access, or a security-scoped folder), the app **MUST** request access through the standard macOS mechanism and **MUST** surface a clear, actionable message if access is denied.
- **FR-PERM-2** The app **MUST** retain security-scoped bookmarks for user-granted folders so a re-scan does not re-prompt unnecessarily.
- **FR-PERM-3** Directories that cannot be read due to permissions **MUST NOT** abort the scan; they **MUST** be counted toward `<Unknown>` (see §8.3) and flagged in the item's state.

---

## 3. Scanning engine

### 3.1 Traversal and sizing

- **FR-SCAN-1** The engine **MUST** recursively traverse the chosen target(s) and record, for every file: name, full path, logical size (bytes), physical/allocated size (bytes on disk), modification date, creation date, and file-system attributes (see §5.2).
- **FR-SCAN-2** For every directory the engine **MUST** compute the aggregate subtree size as the sum of the sizes of all descendant files (logical and physical tracked separately), plus counts of files, subdirectories, and total items in the subtree.
- **FR-SCAN-3** Directory entries themselves contribute negligible size; the size of a directory **MUST** be defined solely as the sum of its descendants (matching WinDirStat semantics).
- **FR-SCAN-4** The engine **MUST** support both **logical size** (file length) and **physical size** (allocated blocks on disk), and the UI **MUST** let the user choose which is displayed and used for treemap area (default: logical). APFS clones/sparse files mean these can differ substantially; both **MUST** be tracked.
- **FR-SCAN-5** Hard links **MUST** be detected (by device + inode) and counted once toward total usage to avoid double-counting; the app **MUST** record which paths share an inode.
- **FR-SCAN-6** Symbolic links **MUST NOT** be followed by default (the link's own small size is counted, not its target). Following symlinks **MAY** be offered as an option (see §9).
- **FR-SCAN-7** The engine **MUST** treat APFS firmlinks and volume mount points the way WinDirStat treats mount points: by default it **MUST NOT** cross into a different file system, and crossing **MUST** be a configurable option (see §9).
- **FR-SCAN-8** Package/bundle directories (`.app`, `.bundle`, `.framework`, etc.) **MUST** be traversed as normal directories by default, with an option to treat bundles as opaque single items (see §9).
- **FR-SCAN-9** The engine **MUST** be multi-threaded / concurrent to fully use available cores (a deliberate, modern departure from WinDirStat's single-threaded `OnIdle` model), while keeping the UI responsive.

### 3.2 Progress and lifecycle

- **FR-SCAN-10** During scanning the app **MUST** display live progress: items discovered, bytes counted, and either a determinate progress indicator (when total is estimable) or a clear indeterminate indicator.
- **FR-SCAN-11** The directory list **MUST** update progressively during the scan (partial results visible before completion), mirroring WinDirStat's pacman/percentage-during-scan behavior with a modern progress affordance.
- **FR-SCAN-12** The user **MUST** be able to cancel an in-progress scan; cancellation **MUST** stop work promptly and leave the app in a consistent state (either partial results or back to the picker — the choice **MUST** be offered).
- **FR-SCAN-13** The user **MUST** be able to pause and resume a scan, or, at minimum, cancel and restart. (Pause/resume is SHOULD; cancel/restart is MUST.)
- **FR-SCAN-14** Scan errors (unreadable entries, vanished files, races where a file is deleted mid-scan) **MUST** be handled gracefully and logged to a viewable scan report; they **MUST NOT** crash or abort the whole scan.

### 3.3 Refresh and persistence

- **FR-SCAN-15** "Refresh Selected" **MUST** re-read the selected item (and its subtree) from disk and update all three views, so the display matches the current on-disk state (parity with WinDirStat "Refresh").
- **FR-SCAN-16** "Refresh All" **MUST** re-scan all current roots.
- **FR-SCAN-17** The app **MUST** be able to save a completed scan to a file and reload it later without re-scanning (modern WinDirStat-2.x parity). The saved file **MUST** capture the full tree, sizes, counts, dates, attributes, and the synthetic nodes' values at save time.
- **FR-SCAN-18** Reloaded scans **MUST** be clearly marked as a snapshot (with the scan timestamp) and **MUST** disable destructive on-disk actions that no longer make sense, or warn that the data is historical.

### 3.4 Limits (parity targets)

- **NFR-LIMIT-1** The engine **MUST** correctly handle file and subtree sizes up to 2^63 − 1 bytes (no overflow in size accumulation).
- **NFR-LIMIT-2** The engine **MUST** handle directories with at least 2^31 direct children and total item counts into the billions without logic errors (memory permitting).
- **NFR-LIMIT-3** Path lengths up to and beyond the classic limits **MUST** be handled; macOS path components up to 255 bytes and deep nesting **MUST NOT** truncate or corrupt.

---

## 4. The three coupled views — general

- **FR-VIEW-1** The main window **MUST** present three regions: Directory List, Extension/Type List, and Treemap, in a layout that is recognizably the WinDirStat three-pane arrangement (list top-left, type list top-right, treemap bottom) but **MUST** use native macOS split views with user-draggable, persisted dividers.
- **FR-VIEW-2** Each pane **MUST** be independently resizable, and the layout (sizes, divider positions, column widths and order) **MUST** persist across launches.
- **FR-VIEW-3** The app **MUST** support light and dark mode and **MUST** render correctly on Retina/HiDPI displays.
- **FR-VIEW-4** The app **MUST** support standard macOS window behaviors: full screen, multiple windows (each window **MAY** hold an independent scan), and tab support is OPTIONAL.

### 4.1 Coupling rules (parity with WinDirStat "Coupling of the Views")

- **FR-COUPLE-1** Selecting an item in the **Directory List MUST** highlight that item in the **Treemap** with a selection frame, and **MUST** select that item's type in the **Type List**.
- **FR-COUPLE-2** Clicking a rectangle in the **Treemap MUST** select the corresponding file, expand and scroll the **Directory List** to reveal it, and select its type in the **Type List**.
- **FR-COUPLE-3** Selecting a type in the **Type List MUST** highlight *all* files of that type in the **Treemap** (parity: "Extension List → Treemap highlights all files of this type").
- **FR-COUPLE-4** At all times the Directory List selection and the Treemap selection **MUST** be identical (a single shared selection model).
- **FR-COUPLE-5** Coupling updates **MUST** feel instantaneous (see performance NFRs in §13).

---

## 5. Directory List view

### 5.1 Structure and sorting

- **FR-DIR-1** The Directory List **MUST** be an expandable outline (tree) of directories and files, resembling Finder's list/column view but sized largest-first.
- **FR-DIR-2** By default it **MUST** be sorted by size descending, so the largest items appear at the top; expanding a directory **MUST** show its children, again sorted by size descending, recursively.
- **FR-DIR-3** Clicking any column header **MUST** sort by that column; clicking again **MUST** toggle ascending/descending. The current sort column and direction **MUST** be visually indicated (parity with WinDirStat's `<` / `>` markers, rendered as native sort indicators).
- **FR-DIR-4** Sorting **MUST** respect the tree structure: sorting happens only **within** each parent's children, never flattening the tree (explicit WinDirStat requirement).
- **FR-DIR-5** Sorting **MUST** use a stable secondary key: the previously-sorted column breaks ties (parity: "two columns are drawn on the sorting").
- **FR-DIR-6** Expand/collapse **MUST** be available via disclosure triangles, keyboard, and a menu command; "Expand all" and "Collapse all" for a subtree **MUST** be available.

### 5.2 Columns

The Directory List **MUST** provide the following columns (all toggle-able and reorderable; widths and order persist):

- **FR-DIR-COL-1 Name** — name plus tree-structure indentation and a type icon (Finder icon for the item).
- **FR-DIR-COL-2 Size** — for files, the file size; for directories, the subtree total. Honors the logical/physical setting (§3.1).
- **FR-DIR-COL-3 Subtree %** — graphical/percentage breakdown of how a subtree's size is composed of its children, comparable only within one expanded parent (parity with WinDirStat "Subtree Percentage" bar). During scan this column **MAY** show progress (read-jobs-remaining or a spinner).
- **FR-DIR-COL-4 Percent** — the same proportion expressed as a percentage number.
- **FR-DIR-COL-5 Files** — number of files in the subtree.
- **FR-DIR-COL-6 Subdirs** — number of subdirectories in the subtree.
- **FR-DIR-COL-7 Items** — total items in the subtree (Files + Subdirs).
- **FR-DIR-COL-8 Last Change** — date of the most recent modification within the subtree.
- **FR-DIR-COL-9 Attributes** — file/folder attributes, mapped to macOS equivalents: Hidden, Read-only/locked, System (SIP/restricted), Symbolic link, Package/bundle, Compressed (HFS/APFS compression), and Encrypted. The legacy Windows R/H/S/A/C/E set **MUST** be mapped to the closest macOS concept and documented in-app.
- **FR-DIR-COL-10** Additional modern columns **SHOULD** be available: Created date, Owner, Physical (allocated) size shown alongside logical, and file count per directory level. These are optional/hidden by default.

### 5.3 Operation

- **FR-DIR-7** Clicking a name **MUST** select the item; arrow keys **MUST** then navigate the tree (up/down to move, right/left to expand/collapse), with the treemap frame following the selection.
- **FR-DIR-8** Selecting a file **MUST** auto-select its type in the Type List and scroll it into view (parity).
- **FR-DIR-9** Column widths and order **MUST** be adjustable by drag and **MUST** persist (parity annotation).
- **FR-DIR-10** Right-click (or Control-click) on an item **MUST** show the item context menu (see §10).

---

## 6. Extension / Type List view

- **FR-EXT-1** The Type List **MUST** contain every file extension (type) present in the scanned tree, aggregated across the whole tree.
- **FR-EXT-2** By default it **MUST** be sorted by total bytes descending, so the types using the most space appear first.
- **FR-EXT-3** The app **MUST** assign distinct colors to the **12** types that occupy the most space; all remaining types **MUST** share a single "other/grey" color. These are the exact colors used by the treemap (parity: "12 colors are assigned to the 12 file types … The rest is grey").
- **FR-EXT-4** Columns **MUST** include: **Extension** (icon + extension text), **Color** (the treemap swatch for this type), **Description** (human-readable type description, the macOS UTI/Launch-Services description analogous to Explorer's description), **Bytes** (total size of all files of this type), **% Bytes** (that total as a percentage of overall tree size), and **Files** (count of files of this type).
- **FR-EXT-5** Clicking a type **MUST** highlight all files of that type in the treemap (see FR-COUPLE-3).
- **FR-EXT-6** Files with no extension **MUST** be grouped under a clearly labeled "(no extension)" type. Comparison **MUST** be case-insensitive (`.JPG` == `.jpg`).
- **FR-EXT-7** The synthetic nodes' pseudo-types (`<Free Space>`, `<Unknown>`) **MUST** appear in the legend with their fixed colors when those nodes are shown (see §8).
- **FR-EXT-8** The color-to-type mapping **MUST** be deterministic for a given scan, so the legend, treemap, and any saved scan agree.

---

## 7. Treemap view

### 7.1 Core rendering

- **FR-TM-1** The treemap **MUST** display the entire scanned tree at once: each file is a rectangle whose **area is proportional to the file's size**.
- **FR-TM-2** Directories **MUST** be laid out as rectangles that fully contain the rectangles of all their files and subdirectories, so a directory's area is proportional to its subtree size (nested treemap).
- **FR-TM-3** Each file rectangle's **color MUST** indicate its type, matching the Type List legend exactly (FR-EXT-3).
- **FR-TM-4** The treemap **MUST** apply **cushion shading**: a per-rectangle gradient/relief that conveys the tree structure with a 3D-surface appearance (the Bruls/Huizing/van Wijk/van de Wetering cushion-treemap technique that WinDirStat/KDirStat use).
- **FR-TM-5** The treemap **MUST** support both layout algorithms WinDirStat offers, selectable in settings: **KDirStat style** (children laid out in rows) and **SequoiaView / squarified style** (classic squarification minimizing aspect ratio). KDirStat **MUST** be the default.
- **FR-TM-6** Cushion shading parameters **MUST** be configurable: brightness, ambient light/height (relief intensity), and scale factor (parity with WinDirStat treemap options).
- **FR-TM-7** Optional grid lines between rectangles **MUST** be supported and toggle-able, and the grid line color **MUST** be configurable.
- **FR-TM-8** The selection-frame color **MUST** be configurable.
- **FR-TM-9** Rendering **MUST** be correct and crisp on Retina displays and **MUST** recompute layout on pane resize.

### 7.2 Interaction

- **FR-TM-10** Clicking anywhere in the treemap **MUST** hit the file whose rectangle contains the point and select it (coupling per FR-COUPLE-2).
- **FR-TM-11** The currently selected item **MUST** be drawn with a selection frame; when a directory is selected, its enclosing rectangle **MUST** be framed.
- **FR-TM-12** Hovering a rectangle **SHOULD** show a tooltip with the file's name, size, and path.
- **FR-TM-13 Zoom in** **MUST** enlarge the treemap so the selected subtree fills the view, and the Directory List **MUST** mark that subtree's root (parity: WinDirStat draws it with a blue frame). **Zoom out** **MUST** step back to the parent.
- **FR-TM-14** "Select Parent" and "Re-select Child" navigation commands **MUST** exist (parity with WinDirStat treemap context menu), along with their keyboard equivalents.
- **FR-TM-15** Treemap navigation keyboard shortcuts **MUST** be provided (WinDirStat uses `+`, `-`, `*`, `/` to move around / change the viewed region; MacDirStat **MUST** provide equivalent shortcuts, documented in-app, adapted to macOS conventions).
- **FR-TM-16** When a type is selected in the Type List, all rectangles of that type **MUST** be visually highlighted (e.g., others dimmed), per FR-COUPLE-3.

---

## 8. Synthetic nodes (Legend parity)

### 8.1 `<Files>`

- **FR-SYN-1** Each directory in the Directory List **MUST** contain a synthetic `<Files>` child that aggregates all *immediate* (non-recursive) file children of that directory, so the user can see how much space the directory's own files use versus its subdirectories.
- **FR-SYN-2** The `<Files>` node **MUST** be omitted when the directory has only one file, or has no subdirectories (parity exactly).

### 8.2 `<Free Space>`

- **FR-SYN-3** When "Show Free Space" is enabled, each scanned **volume root MUST** show a `<Free Space>` node whose size equals the volume's free space, giving a used-vs-free impression. Its treemap color **MUST** be a fixed dark grey.
- **FR-SYN-4** The free-space value **MUST** match what the OS reports for that volume.

### 8.3 `<Unknown>`

- **FR-SYN-5** When "Show Unknown" is enabled, each scanned volume root **MUST** show an `<Unknown>` node equal to: total capacity − free space − (sum of file sizes MacDirStat could read). This accounts for unreadable/permission-denied areas. Its treemap color **MUST** be a fixed vivid yellow.
- **FR-SYN-6** `<Unknown>` **MUST** never be negative; if rounding/timing would make it negative it **MUST** be clamped to zero and the condition noted in the scan report.

### 8.4 Synthetic node behavior

- **FR-SYN-7** Synthetic nodes **MUST** be visually distinguishable (angle-bracket labels, fixed colors) and **MUST NOT** be deletable, openable, or otherwise treated as real files. Destructive actions **MUST** be disabled on them.
- **FR-SYN-8** `<Free Space>` and `<Unknown>` **MUST** only appear when the corresponding scan root is a whole volume, never for a sub-folder scan.

---

## 9. Configuration / Settings

The app **MUST** provide a native macOS Settings window. All settings **MUST** persist. The following groups and options are required (parity with WinDirStat "Configuration", modernized):

### 9.1 General / Scanning
- **FR-CFG-1** Cross file-system boundaries (cross mount points) — on/off, default off.
- **FR-CFG-2** Follow symbolic links — on/off, default off.
- **FR-CFG-3** Follow firmlinks/junction-equivalents — on/off, default off.
- **FR-CFG-4** Treat bundles/packages as opaque items — on/off, default off (traverse).
- **FR-CFG-5** Count physical (allocated) size vs logical size as the primary metric — selectable, default logical.
- **FR-CFG-6** Include hidden files — on/off, default on (count them).
- **FR-CFG-7** Show Free Space node — on/off (parity).
- **FR-CFG-8** Show Unknown node — on/off (parity).

### 9.2 Lists
- **FR-CFG-9** List style options analogous to WinDirStat's grid/stripes (e.g., show grid lines, alternating row backgrounds) — apply to all lists.
- **FR-CFG-10** Which columns are visible, their order, and widths (persisted).
- **FR-CFG-11** What the Subtree % / Percent columns display during a scan, and the colors used for the subtree-percentage bars (parity).

### 9.3 Treemap
- **FR-CFG-12** Layout style: KDirStat vs SequoiaView/squarified.
- **FR-CFG-13** Cushion shading: brightness, height/relief, scale factor, ambient light.
- **FR-CFG-14** Grid lines on/off and grid color.
- **FR-CFG-15** Selection-frame color.
- **FR-CFG-16** Custom color palette for the type legend (override the 12 default colors).

### 9.4 Units & locale
- **FR-CFG-17** Byte units **MUST** be selectable between binary (KiB/MiB/GiB, 1 KiB = 1024 B — WinDirStat's default convention) and decimal (KB/MB/GB, 1 KB = 1000 B). Default **MUST** be binary to match WinDirStat. The displayed unit labels **MUST** be unambiguous.
- **FR-CFG-18** All user-facing strings **MUST** be localizable (Localizable strings catalog). English **MUST** be the built-in default. Date and number formatting **MUST** respect the system locale.

### 9.5 Custom commands (User Defined Cleanups parity)
- **FR-CFG-19** The user **MUST** be able to define up to **10** custom commands, each with: enabled flag, title (shown in menus), and a command line.
- **FR-CFG-20** Each custom command **MUST** support placeholders for the selected item, mapped from WinDirStat's `%p`, `%n`, `%sp`, `%sn`: full path, name, parent path, parent name. The placeholder meanings **MUST** be documented in the editor UI.
- **FR-CFG-21** Each custom command **MUST** let the user restrict which item types it applies to (file / directory / volume) and whether it runs recursively over subdirectories (depth-first), matching WinDirStat's "More Options".
- **FR-CFG-22** Commands **MUST** be executed via the user's shell, with placeholders safely quoted; the app **MUST** warn before running any custom command and surface its output/exit status.

### 9.6 Reset
- **FR-CFG-23** A "Restore Defaults" action **MUST** reset all settings to documented defaults.

---

## 10. Item actions (Cleanups parity)

All actions operate on the currently selected item and **MUST** be reachable from the main menu, the toolbar, and a right-click context menu (parity: "accessible through the main menu, the tool bar and through keyboard shortcuts"). Each action **MUST** have a keyboard shortcut.

- **FR-ACT-1 Refresh Selected** — re-read the item from disk (see FR-SCAN-15).
- **FR-ACT-2 Copy Path** — copy the item's full path to the clipboard.
- **FR-ACT-3 Open** — open the item with its default app (Launch Services). For an app bundle this launches the app; the app **MUST** confirm before launching executables to avoid accidental execution.
- **FR-ACT-4 Reveal in Finder** — the macOS equivalent of "Explorer here": reveal and select the item in Finder.
- **FR-ACT-5 Open Terminal Here** — the macOS equivalent of "Command Prompt here": open Terminal (or the user's configured terminal) at the item's directory.
- **FR-ACT-6 Move to Trash** — the macOS equivalent of "Delete (to Recycle Bin)": move the item to Trash via the OS API, then refresh the item and affected totals.
- **FR-ACT-7 Delete Permanently** — the equivalent of "Delete (no way to undelete)": irreversibly delete after an explicit, clearly-worded confirmation, then refresh.
- **FR-ACT-8 Get Info** — the equivalent of "Properties": show the item's macOS info (size, dates, owner/permissions, attributes), or invoke Finder's Get Info.
- **FR-ACT-9 Generate Report** — the equivalent of "Send Mail to Owner": produce a textual report of the lines shown in the Directory List beneath the selected item, in the current expansion state and sort order, and offer to copy it or open a pre-filled email (to the directory's owner where determinable).
- **FR-ACT-10** Custom commands defined in §9.5 **MUST** appear in the same menus as built-in actions, by their titles, enabled only for the item types they target.
- **FR-ACT-11** All destructive actions (Move to Trash, Delete Permanently, custom commands flagged destructive) **MUST** require confirmation and **MUST** be disabled for synthetic nodes (§8.4) and for snapshot/reloaded scans where the on-disk item may not exist (§3.3).
- **FR-ACT-12** After any action that changes the file system, the affected subtree and all ancestor aggregate sizes, the Type List totals, the synthetic nodes, and the treemap **MUST** be updated consistently.
- **FR-ACT-13** Multi-selection **SHOULD** be supported for actions where it is safe (Copy Path, Move to Trash with a single combined confirmation).

---

## 11. Menus, toolbar, shortcuts

- **FR-UI-1** The app **MUST** provide a standard macOS menu bar: app menu, File (open target, open recent, save scan, reload scan, refresh, close), Edit (copy path, select all), View (toggle panes, columns, treemap style, zoom in/out, expand/collapse), Actions (all of §10), Window, Help.
- **FR-UI-2** The app **MUST** provide a toolbar exposing the most-used actions (open/new scan, refresh, reveal in Finder, move to Trash, zoom in/out), customizable via the standard macOS "Customize Toolbar".
- **FR-UI-3** Every action in §10 and every navigation/zoom command in §7.2 **MUST** have a documented keyboard shortcut, listed in a Help → Keyboard Shortcuts reference and following macOS conventions (⌘ rather than Ctrl).
- **FR-UI-4** The app **MUST** provide an About window and Help that explains the views, the synthetic nodes, the columns, and the treemap (parity with WinDirStat's bundled documentation).
- **FR-UI-5** A status bar / summary area **MUST** show, for the current scan: root path(s), total size, total item count, free space, and the last-scanned timestamp.

---

## 12. Data correctness rules

- **FR-DATA-1** The sum of a directory's children's sizes **MUST** equal the directory's reported subtree size (within the rounding of the chosen display unit), for both logical and physical metrics.
- **FR-DATA-2** The Type List's per-type byte totals **MUST** sum to the total size of all real files in the tree (excluding synthetic nodes).
- **FR-DATA-3** Each file's treemap rectangle area **MUST** be proportional to its size such that, within a directory, the ratio of two files' areas equals the ratio of their sizes (subject to minimum-pixel rendering limits, which **MUST** be applied consistently and noted).
- **FR-DATA-4** Percentages in the Directory List **MUST** be computed relative to the expanded parent (Subtree %) and relative to the appropriate root (Percent), exactly as WinDirStat defines them.
- **FR-DATA-5** Counts (Files, Subdirs, Items) **MUST** be internally consistent: Items = Files + Subdirs for every node.
- **FR-DATA-6** Binary unit math **MUST** be exact: 1 KiB = 1024 B, 1 MiB = 1024 KiB, 1 GiB = 1024 MiB (parity with WinDirStat's stated convention) when binary units are selected.

---

## 13. Non-functional requirements

- **NFR-PERF-1** Scanning **MUST** make full use of available CPU and I/O concurrency; on a typical SSD the engine **SHOULD** scan at least 100,000 items in under ~10 seconds (hardware-dependent target; the eval defines the measured budget).
- **NFR-PERF-2** The UI **MUST** remain responsive (no main-thread stalls > 100 ms) during scanning, sorting, and treemap rendering.
- **NFR-PERF-3** Treemap layout + render for a tree of 1,000,000 items **MUST** complete fast enough to feel interactive on resize (target budget defined in evals) and **MUST** use incremental/observed-region techniques if needed.
- **NFR-PERF-4** Selection coupling between views **MUST** reflect within one display frame / under ~50 ms.
- **NFR-MEM-1** Memory use **MUST** scale roughly linearly with item count and **MUST** handle multi-million-item trees on a machine with 16 GB RAM without crashing; the per-item footprint **SHOULD** be documented.
- **NFR-STAB-1** The app **MUST NOT** crash on permission errors, vanished files, deeply nested trees, symlink cycles, or pathological inputs (zero-byte files, files with no extension, names with unusual Unicode).
- **NFR-A11Y-1** The app **MUST** be VoiceOver-accessible: lists, columns, and actions **MUST** have accessibility labels; the treemap **MUST** expose an accessible alternative (e.g., the Directory List remains a fully accessible representation of the same data).
- **NFR-A11Y-2** The app **MUST** support Dynamic Type / honor system text-size and contrast settings where applicable, and the treemap palette **SHOULD** offer a high-contrast / color-blind-friendly option.
- **NFR-SEC-1** The app **MUST** operate within macOS security: it **MUST** function as a notarized, hardened-runtime app, request only the entitlements it needs, and handle the sandbox/Full-Disk-Access model gracefully.
- **NFR-I18N-1** All UI strings **MUST** be externalized for localization; no user-facing string is hard-coded.

---

## 14. Explicit non-goals (for this version)

- The app **MUST NOT** modify files except through the explicit actions in §10.
- Cloud-storage online/offline placeholder awareness (e.g., iCloud "dataless" files) **SHOULD** be detected and reported but full cloud integration is out of scope.
- Duplicate-file detection by hash and a dedicated large-file finder are desirable parity features with WinDirStat 2.x; they are **SHOULD** (nice-to-have) for v1 and **MUST** be designed so they can be added without reworking the scan model. (Tracked as FR-EXT-FUTURE; see evals "optional" section.)

---

## 15. Requirement index

Every `FR-*` / `NFR-*` ID in this document has a corresponding entry in `MacDirStat-Evals.md`. Implementation is complete when every MUST-level requirement passes its eval and every SHOULD-level requirement is either passing or has a documented, accepted deferral.
