# Acceptance checklist (spec p.18)

How each acceptance case is covered. "Self-test" means `scripts/test.sh`. "Live" means it was run against DaVinci Resolve Studio 21.1.0.14 on 2026-11-08. "Manual" means a person needs to check it in the running app.

| Case | Pass condition | Coverage |
|---|---|---|
| Master safety | 20 projects from one template leave the master checksum unchanged | Self-test (20 runs, master stays read-only at 0444). Live: hash unchanged after two `ImportProject` runs |
| Folder search | Two "Mohan & Anbika" folders on separate disks show distinct paths and volumes | Self-test. The UI lists the volume name, short UUID and full path for each result |
| Backup integrity | Every Camera Card Backup file is in the manifest and validates | Self-test: hidden files, sidecars and empty folders are included, every SHA-256 is checked, and the CSV has one row per file |
| Media filtering | Selective copy shows exact included/excluded files and warns on camera packages | Self-test: Sony `PRIVATE/M4ROOT` warning and companion `C0001M01.XML` warning. The review sheet has Included and Excluded tabs |
| Unplug mid-transfer | A partial job is not complete, and reconnecting needs the correct volume | Self-test: a paused job is not complete, and resume finishes. A volume with a different UUID or no UUID is refused. On a real card, check manually by ejecting mid-copy |
| Duplicate handling | Existing names never overwrite silently, and decisions are recorded | Self-test: the user file is untouched, the new copy is saved as `(2)` with a message, and identical files are skipped. Without Replace, `renamex_np(RENAME_EXCL)` enforces this at the filesystem level |
| Low free space | Preflight blocks unsafe transfers | Self-test (needs size + 5% + 50 MB). The UI allows another destination |
| Edition support | Free never claims Studio operations, and Studio runs only verified calls | Bridge returns `manual` for non-Studio. Studio steps match `docs/capability-matrix.md`. Live run passed |
| Bin mapping | A folder can target an existing bin or a new nested bin, and its status shows | Self-test (suggestions). Live: one existing bin and one created bin, with a receipt for each step |
| Missing assets | Missing LUT/logo/music is labeled and offers locate/omit/manual steps | Self-test (checklist). Template asset editor has a Locate button. Status values: Known missing / Available / Not checked / Incompatible |
| Settings guard | Frame-rate changes with consequences warn and never damage timelines | Live: frame rate locked once timelines exist, reported as `skipped / framerate_locked`. The wizard warns before creating |
| Project launch | Unique name, truthful Ready / Manual Step Required / Partially Completed / Failed | Self-test (state rules, unique names). Live: duplicate Resolve name became `(2)` |
| Accessibility | Keyboard, focus order, VoiceOver labels, dark mode | Manual: system controls, ⌘N / ⌘T / ⌘I shortcuts, labels on icon-only buttons, system colors. Needs a VoiceOver pass by a person |

## Added after the first review (2026-11-08)
| Feature | Coverage |
|---|---|
| Retry continues in the same Resolve project, imports only what failed, latest result per step decides state | Self-test, plus a live bridge run ("Reuse project from earlier run") |
| Template from the project open in Resolve (export + real bins/settings) | Live bridge run (`current` export) |
| Dependency scan: temporary copy in Resolve lists clip paths as available/missing, then is deleted | Live bridge run. The scan opens a copy, so Resolve switches projects briefly and comes back |
| `.drp` diagnostics: writing Resolve version, bins from the archive, corrupt archive rejected, newer-version warning | Self-test |
| Extra project settings (proxy, color, monitoring, audio), with one result per key and unsupported keys reported | Live: `perfProxyMediaMode` set, a fake key reported as failed |
| Per-file conflict decisions in Review | Self-test |
| Continue unfinished files on another destination | Self-test |
| Live unplug detection (stops the job at once, marked Interrupted with the reason) | Code path only. Needs a real drive pulled during a copy |
| Recent locations and source → destination pairs, project naming preset | Built, not clicked through |
| Local metrics (History → Local Metrics) | Self-test of the calculations |

The new screens could not be clicked through: the Mac was locked or on another desktop during this pass.

## Not yet verified
- A real SD card or SSD unplugged mid-copy, Mac sleep, or power loss. Logic is tested; hardware is not.
- Files over 4 GiB: passed 2026-11-08 (`EW_BIG=1 .build/selftest`, a 4.06 GiB file copied and verified).
- Resolve Free 21.1 (not installed here). Free is treated as guided-only by design.
- In-app UI check (2026-11-08): every screen renders. A Camera Card Backup run through the UI finished Verified, with hashes matching on disk. A template was imported, edited and saved as v3 with 6 bins. The wizard ran Create & Run in Resolve against Studio 21.1: 10 bins and the timeline opened, confirmed in Resolve. The state was Partially Completed because the frame rate was skipped. Master hash unchanged. Not yet tested: a wizard run with media sources attached.
- Notarization needs your Developer ID (`scripts/notarize.sh`).
