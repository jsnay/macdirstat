# Deferrals

Spec'd but intentionally not built yet, with reasons. The shipped scope is
the accepted design direction (Claude Design review options 1b, 1d, 1e, 1f,
1g), which supersedes the original UX requirements; several original
requirements were **cut by that review**, not deferred — those are listed
second.

## Deferred (still planned)

| Spec ID | What | Why deferred |
|---|---|---|
| APP-VIEW-3 (partial) | Light mode | The accepted 1b design ships dark; the review calls for a "light-mode pass on 1b" as a follow-up mock first. |
| APP-TM-2/4 | Classic cushion shading | Design default is flat fills + hairlines + subtle gradient; "Classic cushions" returns as a view option with engine CORE-TM-3. |
| APP-SCAN-5 | Save/open scans | Phase 5; engine save/reload is deferred too. |
| APP-SCAN-6 | Scan report window | Errors are counted and retrievable via the wrapper (`scanReport`); a dedicated viewer UI is pending. The unreadable total already surfaces in the footer CTA. |
| APP-PERM-2 | Security-scoped bookmarks | Needs sandboxed-build testing on real hardware; current build is unsandboxed dev-style. |
| APP-TARGET-2/7 | "All local volumes" mode, multi-root models | 1f scans one volume/folder per window; engine multi-root is deferred. |
| APP-DIR-3/COL | Column table view with header sorting | 1b's sidebar is the one-smart-column outline; the design puts full columns "behind a list-view toggle" — that toggle is the pending piece. |
| APP-ACT-3/5/8 | Open, Open Terminal Here, Get Info | Reveal in Finder, Copy Path, Move to Trash (via staging) shipped first; these are small additions to the same context menu. |
| APP-ACT-7 | Delete Permanently | Deliberately absent from the staging flow per design 1e ("exists in the menu, never as the default button") — will land in the menu bar with its own confirmation. |
| APP-TM-6 (partial) | Hover tooltip | SHOULD-level; selection readout in the footer covers the need meanwhile. |
| APP-A11Y-1 | VoiceOver audit | The outline sidebar is the accessible twin by design; the formal audit + treemap accessible elements are pending. |
| APP-I18N-1 | String catalog | Strings are inline English for now. |
| APP-SEC-1 | Notarization/hardened runtime | Phase 6. |
| EVA-* UI tests | XCUITest suite | Logic-level tests ship (cleanup guard/hints/palette); UI automation needs a Mac CI runner. |

## Cut by the accepted design review (not deferred)

| Original requirement | Verdict in review |
|---|---|
| Always-on Type/Extension list pane | Demoted to legend chip strip + ⌘T table ("a legend pretending to be a pane"). |
| `<Files>` / `<Free Space>` / `<Unknown>` as tree citizens | Concepts survive as the capacity footer, the unreadable CTA, and (pending) the italic loose-files row; angle-bracket pseudo-nodes are gone. |
| Attributes column; separate Files/Subdirs columns | Column diet: Name · Size · % bar (Items/Modified behind the pending list-view toggle). |
| Top-12-colors-else-grey as the default channel | Replaced by 8 stable kind categories; extension channel kept as an option (1g). |
| "Select drives" modal front door | The window is the picker (1f). |
| 10 user-defined shell commands | Cut: "niche, a quoting/injection liability; Shortcuts/Services are the Mac-native answer." |
