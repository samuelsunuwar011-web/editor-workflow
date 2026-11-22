# Spec traceability: every PDF requirement, where it is implemented, how it was checked

Source: *Editor Workflow App — Product Specification v1.0* (20 pages). Checked 2026-11-08.

Check legend:
- **T**: self-test in `scripts/test.sh`
- **L**: live run against DaVinci Resolve Studio 21.1.0.14
- **U**: clicked through in the running app
- **B**: built and compiles, not yet clicked
- **H**: needs hardware or an account (see the end)

## p2 Non-negotiable rules
| Rule | Implementation | Check |
|---|---|---|
| Never damage originals; copy by default; no move/delete | `TransferEngine.swift`: copy only, source opened read-only, `RENAME_EXCL` | T |
| Never modify a master template | `Templates.swift`: master stored 0444 and hashed; Resolve imports a copy | T (20 projects), L (hash unchanged) |
| Never fake success | `ProjectStore.state` from receipts; empty job never "verified"; size-only marked "not verified" | T, L |
| Never promise identical Free/Studio | Edition from `GetProductName`; per-version capabilities; Free gets the checklist | T, L |
| Quick path not buried | Wizard remembers mappings, settings and draft; naming preset; menu-bar favorites | U (wizard), B (preset) |

## p3–4 Strategy and information architecture
| Requirement | Implementation | Check |
|---|---|---|
| Home: resume, search, favorites, New Project/Transfer, active jobs | `App.swift` HomeView | U |
| Home: template collection, continue unfinished setup, recent pairs | HomeView sections | U (collection, recent pair + Use Again); B (continue draft) |
| Templates: search/filter by name, category, tag, recent use | `TemplatesView` (search, category, sort by recent) | U |
| Templates: import .drp; create from a tested Studio project | Import + "From Open Resolve Project" (`bridge current`) | U (both, in app), L |
| Transfers / Projects / History / Settings areas | Sidebar | U |
| History: results, checksums, warnings, durations, paths | JobDetail (duration, hashes, warnings, both volumes) | U |
| Settings: bookmarks, default folders, policy, naming presets, Resolve status, accessibility | `SettingsView` | U |
| Drop-zone with validation and next steps | `DrpDropZone` → detail sheet | U |
| Menu bar: status, open, transfer, favorites, recent, progress, pause/resume | `MenuBarContent` | B |

## p5–6 Media transfer
| Requirement | Implementation | Check |
|---|---|---|
| Source/destination panels, volumes, breadcrumbs, search, recent locations, free space, device identity | `FolderPanel` | U |
| Remount under a different path | `Volumes.remap` by UUID | T |
| Create folders, favorite destinations | New Folder…, Save as Favorite | U (favorite) |
| Warn overlap, write access, capacity | `TransferPlanner.plan` preflight | T |
| Camera Card Backup: everything, never filtered, all verified | mode `.cameraCardBackup`, always SHA-256 | T, U |
| Selective copy with preview and companion warning | `SelectiveFilter`, `CameraPackages.warnings` | T |
| Review: volumes, paths, counts, bytes, filter rules, output tree | `TransferReviewSheet` | U |
| Conflict decisions (skip identical, rename, replace after confirm, keep both), per file | `ConflictPolicy`, `TransferItem.policy` | T |
| Capacity headroom, read-only, filesystem limits | preflight (5% + 50 MB, read-only, FAT32 4 GB) | T |
| Choose verification policy; report unverified | `VerificationPolicy` (camera backup forced to SHA-256) | T |
| Queue, bytes and files progress, cancel, durable history | AppModel queue, JobRow, SQLite | T, U |
| TR-01 any authorized pair | plan works on any folders | T, U |
| TR-02 journal, resume after identity check | `titem` per-file journal, `revalidate` | T |
| TR-03 temp names then atomic finalize | `.ewpart` + `rename`/`renamex_np` | T |
| TR-04 SHA-256 source and destination | `streamCopy` + re-hash | T, U (shasum) |
| TR-05 case/Unicode collisions, hidden files, symlinks | `collisionKey`, hidden included, links skipped with warning | T |
| TR-06 timestamps/names kept, unpreserved reported | `preserveMetadata`, `metadataNotPreserved` | T, U (mtime) |
| TR-07 manifest + error log, export | JSON/CSV manifest, `Log` with error IDs, Export Summary | T |
| TR-08 copy default, no move/delete | no move/delete code | T |
| TR-09 confirm by location, not name | full path + volume shown everywhere | U |
| TR-10 measured throughput, no promises | throughput from real timing | U |
| Edge: card ejected, same-name card inserted | live unmount stop + UUID refusal | T (UUID), **H** (real eject) |
| Edge: exFAT/APFS/network/read-only/full/limit | preflight + mid-job "destination full" → Continue Elsewhere | T |
| Edge: RAW/XAVC/BRAW/RED/spanned | full-card backup copies everything; selective warns | T |
| Edge: incomplete earlier job, Unicode/case at destination | leftover `.ewpart` cleaned, collision keys | T |
| Edge: sleep, quit, power loss, permission revoked | idle-sleep assertion; stale "running" → Interrupted on launch; per-file failure | T (logic), **H** |
| Edge: source as its own destination | overlap block | T |

## p7–8 Templates
| Requirement | Implementation | Check |
|---|---|---|
| Master: immutable, checksum, import time, Resolve version, category | `TemplateVersion` + `DrpInfo` (reads `DbAppVer`) | T, U |
| Metadata: ID, name, description, tags, image, favorite, project types, last used | Template detail header | U |
| Bin plan, discovered or verified by Studio | bins read from .drp archive; from open Resolve project | T, L |
| Asset manifest + optional packaged reusable assets + missing warnings | `AssetRuleEntry`, `packageFile` with license confirmation | T, B (UI) |
| Settings profile: resolution, frame rate, orientation, timeline, color, audio | `SettingsProfile` + extra keys | L (extra key), U |
| Version history; sessions keep their version | `newVersion`, `templateVersion` | T, U |
| Keep / Replace / Optional | asset editor | U |
| .drp is not a media archive; no byte rewriting | read-only `unzip -Z1`/`-p` only | T |
| Import: drop, name/brand, rules, plan, test & save | drop zone → detail tabs → Test simulation | U |

## p8–9 Project launch
| Requirement | Implementation | Check |
|---|---|---|
| Five steps with advanced settings collapsed | `ProjectWizard` | U |
| Template from favorites / menu bar; version + edition shown | step 1 + `EditionLine` | U |
| Name, destination, folder structure | step 2 | U |
| Existing folder or verified transfer; several sources | step 3 (Add Existing / Transfer First) | B (with media) |
| Map to bins: new, existing, omit, later, replace branding | step 4, `MappingAction` | T |
| Review: summary, capabilities, missing deps, automated vs guided | step 5 | U |
| Quick presets; custom res/fps; safe vs new-project labels | `SettingsProfileEditor` labels | B |
| Never silently change frame rates | applied only when chosen; locked rate reported | T, L |
| Name conflicts → safe new names | `uniqueName`, Resolve `(2)` | T, L |

## p9–10 Resolve compatibility
| Requirement | Implementation | Check |
|---|---|---|
| Free: dashboard, transfers, template store, guided import | all app-owned; checklist | T |
| Studio automation only for proven calls, per version | `Capabilities` + self-test + bridge `allowed` gating | T, L |
| Hard technical gate | Gate 0 spike, `docs/capability-matrix.md` | L |
| Free fallback: prepare, structure, instance, guided import, honest status | `ProjectStore.create`, checklist, "Manual Step Required" | T, U |

## p11 Settings and dependencies
| Requirement | Implementation | Check |
|---|---|---|
| Default / quick / advanced tiers | template defaults, wizard quick presets, collapsed Advanced | U |
| Editable presets (YouTube, vertical, interview, …, music video) and fps list | `SettingsProfile.presets/frameRates` | U |
| Dependency report: fonts, LUTs, logos, Fusion, OFX, titles | `bridge inspect` + `assets(fromScan:)` | U (scan of a real project in app), L (font, LUT, title, clip fixture), T |
| Known missing / available / not checked / incompatible | `DependencyStatus` | T |
| Locate / replace / omit; master untouched | asset editor | U |
| No packaging of licensed assets without permission | license confirmation before packaging | B |

## p12 Journeys
| Journey | Check |
|---|---|
| A Mehndi long-form | U (wizard + Resolve run), L |
| B talking head, no transfer | covered by "Add Existing Folder" path, B |
| C vertical with frame-rate warning | T (warning logic), B |
| D several cameras, partially verified state | T |

## p13 Screens and interaction details
| Requirement | Check |
|---|---|
| All listed screens | U |
| Scoped search, full paths, category preview, persisted wizard | T, U |
| Drag/drop (.drp, folders into panels), shortcuts, context menus | U (.drp via picker), B (folder drag) |
| VoiceOver, reduced motion, light/dark, focus | accessibility actions added (U through AX), **H** (VoiceOver pass by a person) |
| Custom icons/images and names | U |

## p14–15 Architecture, contract, recovery, security
| Requirement | Implementation | Check |
|---|---|---|
| SwiftUI + AppKit, menu bar, notifications | built with `swiftc` | U |
| Transfer engine / Resolve adapter separated | `Sources/Core/*` vs bridge | T |
| Persistence SQLite; immutable masters and manifests | `Database.swift` | T |
| Diagnostics: local structured logs, error IDs, opt-in export | `Log.swift`, Settings → Export Diagnostics | T, U (log with IDs written; export button rendered) |
| Data model entities | `Models.swift` | T |
| Capability probes canImportProject/CreateBin/ImportMedia/SetSetting/OpenProject | `Capabilities.all`, self-test | L, U (self-test run from Settings: 5/5 stored for 21.1) |
| Studio reports real results; Free "requires manual step" | receipts | L |
| Recovery: disconnect, mismatch (controlled retry), full, duplicates, missing deps, Free, partial Resolve, corrupt .drp | engine + Retry Failed + Continue Elsewhere + retry-in-same-project + `DrpInfo` | T, L |
| Local-first, minimal access, revocable | bookmarks, Remove | U |
| Signed + notarized | `scripts/notarize.sh` | **H** (Developer ID) |
| Export/backup and delete own records | Settings | B |

## p16–18 Priorities, gates, acceptance, metrics
| Item | Check |
|---|---|
| Gates 0–6 | done; Gate 6 hardware items **H** |
| Huge files / many small files | T (4.06 GiB, 2,000 files) |
| Acceptance table (13 cases) | `docs/acceptance.md` |
| Local metrics (times, effort, failure rates, manual share, reuse) | `Metrics.swift`, History → Local Metrics: T, U |
| Migration/upgrade | new fields are optional, so older records decode (checked on real data after each upgrade today); U |
| Clean uninstall | README "Uninstall" + Delete App Records | B |

## Still open
- **Hardware:** pull a real card or SSD mid-copy, Mac sleep, power loss. Logic is tested; hardware is not.
- **VoiceOver:** a full pass by a person.
- **Resolve Free 21.1:** not installed here. The guided path is used by design.
- **Notarization:** needs your Apple Developer ID.
- **Not clicked in the app:** these need a system file panel or a pop-up menu, which can't be driven in the background: Export Diagnostics, Package…, Continue Elsewhere, the size-only verification choice, dragging a folder from Finder, and the template right-click menu. The logic behind each is covered by self-tests.
- **Continue unfinished setup** card on Home: shows only when a wizard draft exists; not seen in this pass.
- **Bugs found and fixed in the final pass:**
  - A size-only warning stopped the folder scan, and an empty job then counted as "verified".
  - Video clips were labelled "Music".
  - A layout loop made Transfers blank.
  - The Transfers bar and Templates header were cramped.
  - Test folders were never deleted after test runs.
