# Menu bar companion: spec v2.0 traceability

Source: *Editor_Workflow_Menu_Bar_FINAL_Specification.pdf* (23 pages). Built 2026-11-09. The PDF's visuals were treated as concepts, not copied: the layout is the app's own native design.

Check legend:
- **T**: self-test (`scripts/test.sh`, 172 checks)
- **U**: clicked through in the running app
- **L**: live against Resolve Studio 21.1
- **B**: built, not clicked
- **H**: needs hardware

| Spec | Requirement | Implementation | Check |
|---|---|---|---|
| p2 | Menu bar companion, not a command list; never loses context; copy/verify/report; works without the main window | `MenuBar.swift` (AppKit status item + popover), `CompanionPanel.swift`, shared `AppModel` services | U |
| p3 | Three icon pages (Transfer / Favorites / Create Template), labels + tooltips + accessible names; switching never cancels; status area; command menu for Settings/Help/Quit | Panel header tabs; `StatusStrip`; "…" menu and right-click status item menu | U |
| p3 | Calm first screen, complexity revealed step by step; compact and expandable | 1-2-3 steps; expand toggle; "Open Panel in Window" (detached) and popover drag-to-detach | U |
| p4 | Drive mount: detect, check access, auto-open / notify / never, trusted drives, don't steal focus, latest drive suggested, stable IDs, never auto-copy | `DrivePolicy.decide` (T), `AppModel.driveMounted`, Settings → Menu bar companion | T, B (H for a real drive) |
| p5–6 | Built-in browser: drives / favorites / recents with free space and read-only; Back/Forward/Up; breadcrumbs; single-click select vs double-click open; Select This Folder; search as you type with scope and parent paths; multi-select with tray (Remove/Clear/size); create and rename a new folder; writable state; background counts with cancel; incremental loading; keyboard | `Browser.swift` (`BrowserModel`, `BrowserView`) | U (navigation, select vs open, Select This Folder, size, writable); B (multi-select, search scope, rename) |
| p6 | Parent+child selected: copied once; symlinks/loops/nested destinations blocked or warned | `normalizeSources`, overlap preflight, symlink skip | T |
| p7 | Copy From → Copy To advances automatically; Change Source; suggested recent/paired destinations; proposed folder named after source; no silent merge; source breadcrumb while choosing destination | `TransferPage`, `draftDestination`, merge confirmation in `PreflightView` | U |
| p7, p10 | Review: from/to with drive IDs, formats, selected vs scanned, size, free space, conflicts (per-file), verification, explicit approval of skipped checksums | `PreflightView` | U, T |
| p8 | Phases Preparing → Copying → Verifying → Completed; current file, speed, time left; pause/resume/cancel; closing the panel never stops a job; sleep, space, read-only, permission, disconnect, partial files | `LiveProgress`, `JobProgressCard`, runner `activity`, disconnect stop, `.ewpart` temp files | T, U (completion); B (live phases on a large copy) |
| p8 | Camera Card Backup vs Selective (warns it is not a full backup); Completed & Verified only when the policy succeeds | modes; `TransferReport.isVerified` | T, U |
| p9 | Queue: fixed job IDs, add while running, at most one job per destination drive (limit in Settings), Waiting / Paused / Needs Attention…, reorder, Start Next, retry failed, remove history without deleting media, resume compares before retrying, overlapping jobs blocked | `AppModel.pump/start/enqueue`, `QueueRows`, `deleteRecord`, `overlaps` | T, B |
| p10 | Completion report: scanned/selected, copied/skipped/failed, verified/not, bytes, time, paths, exceptions; Retry Failed / Open Destination / Export Report | `TransferReport`, `CompletionCard`, `exportReport` | T, U |
| p10 | Handoff only when verified; partial needs "Continue with partial files" | `HandoffSection` | B |
| p11 | After copy: verified folder card + favorites; template opens setup with the copied folder preselected; Copy Only / Done | `HandoffSection` → `ProjectSetupView` | U |
| p12 | Favorites page: pin, manual order, search, recent first; last verified copy suggested with Change; browse if no copy; full app for details | `FavoritesPage` | U |
| p12 | Compact setup: name from folder, media source, project library (editable), saved mapping + Keep/Replace/Optional, advanced collapsed, Create & Open (Studio) or guided | `ProjectSetupView` | U, L (Ready with real imports) |
| p13 | Route B (template first): Use In Place (labelled "no backup or transfer") or Copy New; copy-only exit | `ProjectSetupView` source choices, "Done (Copy Only)" | U (Done), B (Use In Place) |
| p14 | Create Template: drop or Browse; validated without editing .drp internals; name/thumbnail/category/tags/description; Keep/Replace/Optional; master protected; corrupt file explained, original unchanged; duplicate name → rename / new version / cancel; missing assets listed; version mismatch warned; Continue in Full App | `CreateTemplatePage`, `DrpInfo`, `TemplateStore` | U (page), T (validation), B (duplicate dialog) |
| p15 | Resolve: Free/Studio by tested capability; missing Resolve → Choose App / Get Resolve; frame rate treated as checked; results Ready / Manual Step / Partial / Failed, never faked | `StatusStrip`, `chooseResolveApp`, capability gating | L, U |
| p16 | Status icon states (idle / copying / verifying / attention / failed / complete); outside click closes UI not transfer; quit warns with active transfers; permissions re-authorize; completion notification with Open Destination / Create Project; drag a folder onto the panel; near-full warning | `MenuBarController.updateIcon`, `.transient` popover, `applicationShouldTerminate`, notification categories, `onDrop`, preflight warning | T (near-full), B |
| p17 | State transitions: mount → Folder tab with drive; select → advance; review → durable job; reopen restores progress; verified → report + favorites; Favorites without copy offers Browse / Copy New; switching or closing keeps state; disconnect → Needs Attention | `CompanionState` persisted (tab, draft, browser paths, handoff, favorites order, last verified) | U (state restored after a crash and after a relaunch, pending handoff restored) |
| p18 | Edge cases: disconnect, overlap, source changed mid-copy, full/read-only, conflicts, same-name drives, 100k-file folders, crash/restart, missing template asset, panel closed mid-copy | engine checks + `BrowserModel` batched loading | T (source change, overlap, IDs), H (real unplug) |
| p19 | Architecture: menu UI, shared browser, volume observer, transfer service, template service, Resolve adapter, state storage; stored TransferJob / ProjectHandoff / preferences | as listed | T |
| p21–22 | Acceptance 1–22 | 2, 3, 4, 8, 9, 11, 13, 14, 15, 17, 18, 19, 20, 21, 22: U/T/L. 1 and 12: H (real drives). 5, 6, 7, 10, 16: T + B | — |

## Fixed during the live check
- **Crash on Review:** the Copy button read view state that only exists inside the window; it is now a plain function.
- **Hidden popover:** the panel could not appear while the app was in the background; it now brings the app forward first. The drive policy still sends a notification instead while Resolve is in front.
- **Missing icon:** the Create Template tab icon used a symbol name that doesn't exist.
- **Blocked Create:** "Create & Open" stayed disabled until a project library was chosen; it now defaults to the folder holding the footage.

## Still open
- **Real drive:** auto-open on mount, trusted drives, and unplug mid-copy need a physical card or SSD.
- **Not clicked:** multi-select with Cmd/Shift, search scope, folder rename, Use In Place, the partial-copy decision, the duplicate-template dialog, and the queue with several jobs.
- **Notarization and VoiceOver:** as in the main traceability doc.

## Update 2026-11-09: background app, card auto-fill, icon-first redesign
- **Background app:** runs as a menu bar app with no Dock icon (`LSUIElement`). The main window doesn't open at launch and gets a Dock icon only while open. On first run, "Open at login" is turned on through system login items, with a toggle in Settings.
- **Card insert:** inserting a card opens the panel by default. A card already inserted when the app starts counts as an insert.
- **Route fills itself:** the card becomes the source, the last-used destination is reused, and the folder gets a dated name like "GoPro 2026-11-09". You only press "Copy & verify". It never copies on its own.
- **Card brands:** `CameraCard.detect` recognises GoPro, Sony, Canon, Nikon, Panasonic, Fujifilm, DJI, RED, Blackmagic and AVCHD. A recognised brand wins over a generic DCIM drive.
- **Built-in SD slot:** a card in the Mac's own slot (reported as "internal" but removable) now counts as external.
- **Redesign:**
  - Icon tabs, one card → drive route, and automatic preflight with a summary row.
  - Options behind a gear, details behind an info button.
  - A progress ring with the phase.
  - A result card with icon actions, template tiles, an icon queue, and an icon browser tray.
  - Every icon has a tooltip and a spoken label.
- **Live test:** a real GoPro card in the slot (NO NAME, 163 files, 696.3 MB) copied and verified in 9 s, and a spot-check hash matched the card.
