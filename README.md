# Editor Workflow

A native macOS app that copies and verifies footage, keeps reusable DaVinci Resolve `.drp` templates, and prepares projects. Resolve Studio projects are automated, but only for steps proven to work. Resolve Free gets an honest guided checklist.
The spec is `Editor_Workflow_App_Product_Specification.pdf` (v1.0).

## Build and run (Xcode not needed)
```bash
scripts/test.sh                 # self-tests (EW_BIG=1 adds the >4 GiB test)
scripts/build.sh                # -> build/Editor Workflow.app
open "build/Editor Workflow.app"
```
Requires macOS 15+ (Sequoia) on Apple Silicon and the Xcode Command Line Tools. The build uses plain `swiftc`:
- No SwiftPM. It needs a nested sandbox, which some environments block.
- No `@State`. In current SDKs it is a macro whose plugin ships only with Xcode, so `Sources/App/Local.swift` provides `@Local` instead.

For Studio automation, set Resolve > Preferences > System > General > **External scripting using: Local**.

## Layout
| Path | What it does |
|---|---|
| `Sources/Core/TransferEngine.swift` | Plan and preflight, then streams each file into a hidden `.ewpart` temp file. Computes SHA-256 of source and destination, then renames atomically (never overwrites unless Replace is confirmed). Keeps a per-file journal, supports resume after volume revalidation, and writes JSON/CSV manifests |
| `Sources/Core/Templates.swift` | Stores immutable masters (read-only, checksummed) with versioning, metadata, export and duplicate |
| `Sources/Core/Projects.swift` | Project folders, `.drp` instance copy, bin-mapping suggestions, Free checklist, truthful state rules, wizard drafts |
| `Sources/Core/Resolve.swift` + `Resources/resolve_bridge.py` | Detects edition through `GetProductName()`, runs proven Studio steps, and returns one receipt per step |
| `Sources/Core/Database.swift` | SQLite document store in `~/Library/Application Support/EditorWorkflow/` |
| `Sources/App/*` | SwiftUI shell, menu bar extra, dual-panel transfers, template library, five-step wizard, projects, history, settings |
| `docs/capability-matrix.md` | Resolve calls tested live (Gate 0) |
| `docs/acceptance.md` | Spec acceptance cases and how each is verified |

## Safety rules the code enforces
- Copy only: nothing is moved or deleted. Source files are opened read-only.
- "Verified" requires matching SHA-256 hashes. A mismatch is reported as a failure and the bad file is never finalized.
- A drive is matched by volume UUID, never by name.
- Template masters are never written. Each project gets its own `.drp` copy, and Studio imports into Resolve's database.
- Project state comes only from real receipts.

## Transfers (0.10)
- **Compare with destination** (Options menu on the Copy page): *Copy everything*, *Continue — skip files already copied*, or *Only files missing at the destination*. The review screen then shows how many files already exist with the same size, how many differ, and how many bytes will actually move.
- **Continue** on an interrupted or failed job resumes where it stopped; finished files are never recopied.
- **Several transfers run at once** (default 4, Settings → "Transfers at once", up to 6), including jobs writing to the same destination drive — only jobs whose output folders overlap are refused. Inside each job, **up to 4 files copy in parallel** (each with its own read-ahead, hash and write stream), so one big folder no longer trickles file by file. The menu bar shows `2× 45%` while several run; the queue badge counts them.
- The panel closes when you click outside it even mid-copy — the copy keeps going (Finder-like).
- Big-file hardening: per-file autorelease pools, throttled UI updates, content hashing skipped when file sizes already differ, `F_FULLFSYNC` only for files ≥128 MB (plain `fsync` otherwise, several seconds faster per small file on external drives).
- **Video preview in the browser**: play button on the selected row, right-click → Preview, or Enter — inline player for video/audio, image viewer for photos.
- The expand button in the popover opens the panel as a centered window instead of a half-clipped popover.
- **Keyboard cleaning mode** (⋯ menu): one event tap swallows keyboard, scroll and gestures; mouse still works. Unlock with the button or Esc ×5. Requires Accessibility permission (the app asks and links to Settings).
- **Scratchpad**: multiple named notes with a dropdown, rename/close/clear/save-as-`.txt`, autosaved; files and photos dragged in show up as a thumbnail shelf.
- **Background activity monitor**: running processes with memory and CPU, sortable, with force quit (⚠ asks first).

## Panel tabs (0.11)
- **Shelf** is photos-only: dropping images (Finder, Photos app, screenshots — file or raw image data) stores them as thumbnails on the shelf. Double-click a photo to reveal it in Finder; right-click for Open / Reveal / Start Project / Remove. Dropping a `.drp` still routes to Add Template, footage still routes to New Project.
- **Activity** tab: the process monitor inside the panel, grouped by app — one row per app with its icon, aggregated CPU and memory, and a "Using most:" line naming the top CPU consumers. Expand a row to see its individual processes; tick rows (or all) and use **Quit Selected** or **Quit All** (both ask first; this app and system processes are skipped by Quit All). Built for smooth live refresh: icons are cached for the app's lifetime, the filtered/sorted list is computed once per refresh instead of per frame, and the toolbar is a single compact row (RAM pressure moved into the summary line).
- **Clean** tab: Keyboard Cleaning Mode from inside the panel — start/stop, live Esc ×5 unlock progress, and the permission notes. While active the full-screen shield still covers every display.
- Panel widened to 800 (960 expanded) so the new tabs have room.

## Bug fixes (0.12.2)
- Drops that are not photos, `.drp` or footage (a `.txt`, `.zip`, …) are refused with an explanation instead of being opened as a bogus "New Project".
- Image drags now work everywhere: the full-panel drop screen accepts image data (Photos, browser, screenshots), the drag toward the menu bar opens the drop screen for image-only drags, and a photo dropped straight on the menu bar icon is saved into the shelf folder first.
- Shelf file names from providers are sanitized (`:` and `/` can no longer break the path).
- The live transfer row counts files truthfully ("Copying — 12 of 40 files done") and shows "4 files at once" instead of flickering between file names while parallel streams run.
- Activity: app-group names strip the `.app` suffix once (bundles like `App.app.app` keep their name).
- New regression test: two jobs copying into the same drive at the same time, both verified, both outputs intact.

## Uninstall
1. Double-click `Uninstall Editor Workflow.command` (it is installed in `/Applications` and also sits beside the package). Answer `y` to remove the app, login item, preferences and caches; answer `y` to the second question to delete the library too. Add `--purge` for a silent full removal: `./Uninstall\ Editor\ Workflow.command --yes --purge`.
2. Or by hand: quit the app, delete `Editor Workflow.app` and `~/Library/LaunchAgents/app.editorworkflow.mac.plist`, then delete `~/Library/Application Support/EditorWorkflow/` (library, history, logs). Settings → "Delete App Records…" does the same from inside the app.

Every copy is removed (any version, any place it was unzipped). Footage, project folders, original `.drp` files and Resolve projects are never stored there, so uninstalling leaves them untouched.

## Templates that ship with the package
`scripts/seed.sh` exports this Mac's template library into `Resources/templates/` (`.drp` + cover + `seeds.json`); `scripts/build.sh` puts it in the app bundle. On first launch the app imports each seed once and remembers the keys, so nothing is imported twice and a template you delete stays deleted. Your own library already has those names, so nothing duplicates here.

Traceability of every spec requirement: `docs/spec-traceability.md`.
