# Resolve capability matrix (Gate 0)

Tested 2026-11-08 on DaVinci Resolve Studio 21.1.0.14, macOS, local database.
The calls ran inside Resolve's scripting host through the Resolve MCP `run_script` tool.
Fixtures: `spike/fixtures/master.drp` (exported by Resolve) and `spike/fixtures/footage/CAM A|CAM B`.

| Capability | API call | Studio 21.1 | Free 21.1 |
|---|---|---|---|
| Detect edition | `Resolve.GetProductName()` → "DaVinci Resolve Studio" | PASS | not tested (external scripting restricted in Free 21.1) |
| Detect version | `Resolve.GetVersionString()` → "21.1.0.14" | PASS | not tested |
| canImportProject | `ProjectManager.ImportProject(drp, newName)` | PASS | manual |
| Name conflict | `ImportProject` with an existing name | returns False (no overwrite) | manual |
| canOpenProject | `ProjectManager.LoadProject(name)` | PASS | manual |
| Template bins survive | `Folder.GetSubFolderList()` after import | PASS (`01 Footage`, `03 Audio`) | manual |
| canCreateBin | `MediaPool.AddSubFolder(parent, name)` (nested) | PASS | manual |
| Target bin | `MediaPool.SetCurrentFolder(folder)` | PASS | manual |
| canImportMedia | `MediaPool.ImportMedia([paths])` | PASS (1 item per file) | manual |
| Missing media | `ImportMedia` with a bad path | returns `[]` → report failure | manual |
| canSetSetting (resolution) | `Project.SetSetting("timelineResolutionWidth"/"Height")` | PASS | manual |
| canSetSetting (frame rate) | `Project.SetSetting("timelineFrameRate")` when a timeline exists | **FAIL** (False, unchanged) | manual |
| Open timeline | `Project.SetCurrentTimeline(tl)` | PASS | manual |
| Save | `ProjectManager.SaveProject()` | PASS | manual |
| Clip input color space | `Project.SetSetting("colorScienceMode"/"colorSpaceInput"/"colorSpaceOutput")` + `SetClipProperty` | built, not live-tested yet | manual |
| Show edit page | `Resolve.OpenPage("edit")` | PASS | manual |
| Master untouched | SHA-256 of `master.drp` before and after import | identical | n/a (app only copies the file) |
| External bridge | `python3` + `DaVinciResolveScript.scriptapp("Resolve")` from the app | PASS (Settings shows Studio 21.1.0.14). Returns `None` inside a sandboxed shell | restricted |

## Decisions for Gates 3–5
- Studio automation is **enabled** for: import as new project, load, create nested bins, import media into a target bin, set resolution, set the current timeline, save.
- Frame rate is locked once a timeline exists. The app never changes it on a template instance. A template's frame rate shows as "requires new project/timeline".
- Project name conflicts: `ImportProject` refuses existing names. The app checks `GetProjectListInCurrentFolder()` first and suggests `Name (2)`.
- Clip input color space: the bridge turns on Resolve Color Management (`davinciYRGBColorManagedv2`), sets the chosen camera space as the input and Rec.709 Gamma 2.4 as the output, so imported clips look converted as soon as they reach the timeline. Clip Attributes is also set, but it does nothing on its own.
- `ImportMedia` returns `[]` for each file that fails. The app records each source as its own `resolve_action` receipt.
- External bridge: works from the app on this Mac. If `scriptapp` returns `None` (Resolve closed, or **Preferences → System → General → External scripting using** set to None), the app shows that instruction and falls back to the guided (Free) path.
- The edition comes from `GetProductName()`. Studio installs as `DaVinci Resolve.app`, so the bundle name cannot be used. With no bridge, the edition is "unknown" and the app uses the guided path.
