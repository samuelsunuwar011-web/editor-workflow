#!/usr/bin/env python3
"""Editor Workflow -> DaVinci Resolve bridge.

Reads one JSON command on stdin and writes one JSON result on stdout.
Uses only API calls proven in docs/capability-matrix.md. Never edits Resolve databases directly.

Commands:
  {"cmd": "probe"}
  {"cmd": "current", "exportPath": "/x.drp"}   export the open project + read its bins/settings
  {"cmd": "open", "name": "Project"}            open an existing project by name
  {"cmd": "inspect", "drp": "/x.drp"}          import a temporary copy, list media/fonts/LUTs/OFX/Fusion, delete it
  {"cmd": "selftest", "clip": "/c.mp4", "tmp": "/dir"}  prove each capability on this Resolve version
  {"cmd": "run", "plan": {...}}  plan keys: drp, projectName, bins[], imports[{bin, paths[], optional}],
                                 settings{width,height,frameRate}, inputColorSpace, timelineName
"""
import json
import os
import sys

# Extensions Resolve can import from a folder. Sidecars and metadata stay out of ImportMedia.
MEDIA_EXT = {
    "mov", "mp4", "m4v", "mxf", "avi", "mts", "m2ts", "mkv", "insv", "lrv",
    "braw", "r3d", "ari", "crm", "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf",
    "wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "bwf",
    "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "psd", "webp",
}


def receipt(step, capability, status, detail="", error=None):
    return {"step": step, "capability": capability, "status": status, "detail": str(detail)[:300], "errorCode": error}


def is_studio(resolve):
    return "studio" in (resolve.GetProductName() or "").lower()


def probe(resolve):
    pm = resolve.GetProjectManager()
    return {
        "reachable": True,
        "product": resolve.GetProductName(),
        "version": resolve.GetVersionString(),
        "studio": is_studio(resolve),
        "projects": pm.GetProjectListInCurrentFolder() or [],
    }


def unique_name(name, taken):
    lowered = {t.lower() for t in taken}
    if name.lower() not in lowered:
        return name
    n = 2
    while f"{name} ({n})".lower() in lowered:
        n += 1
    return f"{name} ({n})"


def ensure_bin(media_pool, path):
    """Walk/create nested bins. Returns (folder, created_names)."""
    folder = media_pool.GetRootFolder()
    created = []
    for part in [p for p in path.split("/") if p.strip()]:
        existing = {f.GetName(): f for f in (folder.GetSubFolderList() or [])}
        if part in existing:
            folder = existing[part]
        else:
            new = media_pool.AddSubFolder(folder, part)
            if not new:
                return None, created
            created.append(part)
            folder = new
    return folder, created


def project_is_empty(project):
    """A fresh Resolve session shows an untitled project with no media. Saving that project is noise,
    and it is what made the app say "save this project" on a clean start."""
    try:
        name = (project.GetName() or "").strip().lower()
        if name.startswith("untitled"):
            return True
        if (project.GetTimelineCount() or 0) > 0:
            return False
        return not clips(project.GetMediaPool().GetRootFolder())
    except Exception:
        return False


def run_plan(resolve, plan):
    out = []
    allowed = set(plan.get("allowed") or [])

    def ok(cap, step):
        """Only capabilities proven on this Resolve version run; others become manual steps."""
        if cap in allowed:
            return True
        out.append(receipt(step, cap, "manual", "Not proven on this Resolve version. Do this step by hand (see checklist).", "capability_unproven"))
        return False

    if not is_studio(resolve):
        out.append(receipt("Edition check", "edition", "manual",
                           "Resolve Free: automation not offered. Follow the import checklist.", "free_edition"))
        return {"projectName": None, "receipts": out}

    pm = resolve.GetProjectManager()
    existing = plan.get("existingProject")
    if existing and existing in (pm.GetProjectListInCurrentFolder() or []):
        # Retry: continue in the project created earlier instead of importing a second copy.
        name = existing
        out.append(receipt("Reuse project from earlier run", "local", "ok", name))
    else:
        name = unique_name(plan["projectName"], pm.GetProjectListInCurrentFolder() or [])
        if name != plan["projectName"]:
            out.append(receipt("Unique project name", "local", "ok", f"'{plan['projectName']}' exists in Resolve; using '{name}'"))
        if not ok("canImportProject", "Import project"):
            return {"projectName": None, "receipts": out}
        if not pm.ImportProject(plan["drp"], name):
            out.append(receipt("Import project", "canImportProject", "failed", plan["drp"], "import_project_failed"))
            return {"projectName": None, "receipts": out}
        out.append(receipt("Import project", "canImportProject", "ok", name))

    # A project already open in Resolve is saved first, then Resolve switches to the new one.
    # A blank/untitled project has nothing to save: open the new project directly.
    current = pm.GetCurrentProject()
    if current and current.GetName() != name:
        prev = current.GetName()
        if project_is_empty(current):
            out.append(receipt("Open project", "local", "ok", f"Nothing open; opening '{name}'"))
        else:
            saved = pm.SaveProject()
            out.append(receipt("Save open project", "local", "ok" if saved else "failed", f"{prev} saved" if saved else f"{prev} could not be saved; left open", None if saved else "save_failed"))
            if not saved:
                return {"projectName": name, "receipts": out}
    project = pm.LoadProject(name)
    if not project and current:
        pm.CloseProject(current)
        project = pm.LoadProject(name)
    if project:
        try:
            resolve.OpenPage("edit")
        except Exception:
            pass
    if not project:
        out.append(receipt("Open project", "canOpenProject", "failed", name, "load_failed"))
        return {"projectName": name, "receipts": out}
    out.append(receipt("Open project", "canOpenProject", "ok", name))

    mp = project.GetMediaPool()
    imported = []
    for b in plan.get("bins", []) if ok("canCreateBin", "Create bins") else []:
        folder, created = ensure_bin(mp, b)
        if folder is None:
            out.append(receipt(f"Bin {b}", "canCreateBin", "failed", b, "add_subfolder_failed"))
        else:
            out.append(receipt(f"Bin {b}", "canCreateBin", "ok", "created" if created else "existing"))

    for imp in plan.get("imports", []) if ok("canImportMedia", "Import media") else []:
        folder, _ = ensure_bin(mp, imp["bin"])
        label = f"Import into {imp['bin'] or 'Master bin'}: {os.path.basename(imp['paths'][0].rstrip('/'))}"
        optional = bool(imp.get("optional"))
        if folder is None or not mp.SetCurrentFolder(folder):
            out.append(receipt(label, "canImportMedia", "failed", "target bin unavailable", "bin_unavailable"))
            continue
        # A folder brings only its own media files: its subfolders have their own bins (Resolve would flatten them otherwise).
        paths = []
        for p in imp["paths"]:
            if os.path.isdir(p):
                paths += sorted(os.path.join(p, n) for n in os.listdir(p)
                                if not n.startswith(".") and os.path.splitext(n)[1].lower().lstrip(".") in MEDIA_EXT
                                and os.path.isfile(os.path.join(p, n)))
            elif os.path.exists(p):
                paths.append(p)
        if not paths:
            out.append(receipt(label, "canImportMedia", "skipped",
                               f"No importable media directly inside {', '.join(imp['paths'])}",
                               "optional_missing" if optional else "no_media"))
            continue
        items = mp.ImportMedia(paths) or []
        imported += items
        if items:
            out.append(receipt(label, "canImportMedia", "ok", f"{len(items)} clip(s) from {', '.join(imp['paths'])}"))
        else:
            out.append(receipt(label, "canImportMedia", "skipped" if optional else "failed",
                               f"0 clips imported from {', '.join(imp['paths'])}",
                               "optional_missing" if optional else "import_media_empty"))

    # Input color space → Rec.709. Setting Clip Attributes alone changes nothing visible: Resolve needs
    # Color Management to read the camera space and convert it. With this, every clip dragged to the
    # timeline shows as Rec.709, including clips added later.
    color_space = (plan.get("inputColorSpace") or "").strip()
    if color_space and "canSetSetting" not in allowed:
        out.append(receipt("Color management", "canSetSetting", "manual",
                           "Not proven on this Resolve version. Set the input color space by hand.", "capability_unproven"))
        color_space = ""
    if color_space:
        managed = [
            ("Color science", "colorScienceMode", "davinciYRGBColorManagedv2"),
            ("Separate color space and gamma", "separateColorSpaceAndGamma", "0"),
            ("Input color space", "colorSpaceInput", color_space),
            ("Timeline color space", "colorSpaceTimeline", "DaVinci WG/Intermediate"),
            ("Output color space", "colorSpaceOutput", "Rec.709 Gamma 2.4"),
        ]
        for label, key, value in managed:
            before = str(project.GetSetting(key))
            if before == value:
                out.append(receipt(label, "canSetSetting", "ok", f"already {value}"))
            elif project.SetSetting(key, str(value)):
                out.append(receipt(label, "canSetSetting", "ok", f"{before} -> {value}"))
            else:
                out.append(receipt(label, "canSetSetting", "failed",
                                   f"still {before}; Resolve did not accept {value}", "set_setting_failed"))
        # Also record the camera space on each imported clip, so Clip Attributes shows the same value.
        if imported:
            changed = rejected = 0
            for item in imported:
                try:
                    kind = str(item.GetClipProperty("Type") or "").lower()
                    ext = os.path.splitext(str(item.GetClipProperty("File Path") or ""))[1].lower().lstrip(".")
                    if "audio" in kind and "video" not in kind:
                        continue
                    if ext in {"jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "psd", "webp"}:
                        continue
                    if item.SetClipProperty("Input Color Space", color_space):
                        changed += 1
                    else:
                        rejected += 1
                except Exception:
                    rejected += 1
            if changed:
                out.append(receipt("Clip input color space", "canSetClipColorSpace", "ok",
                                   f"{color_space} on {changed} clip(s)"))
            elif rejected:
                out.append(receipt("Clip input color space", "canSetClipColorSpace", "manual",
                                   f"Clip Attributes kept its own value. Project color management still converts to Rec.709.",
                                   "set_clip_property_unsupported"))

    s = (plan.get("settings") or {}) if ("canSetSetting" in allowed or not plan.get("settings")) else {}
    if plan.get("settings") and "canSetSetting" not in allowed:
        ok("canSetSetting", "Project settings")
    if s.get("width") and s.get("height"):
        cur = (str(project.GetSetting("timelineResolutionWidth")), str(project.GetSetting("timelineResolutionHeight")))
        want = (str(s["width"]), str(s["height"]))
        if cur == want:
            out.append(receipt("Resolution", "canSetSetting", "ok", f"already {want[0]}x{want[1]}"))
        elif project.SetSetting("timelineResolutionWidth", want[0]) and project.SetSetting("timelineResolutionHeight", want[1]):
            out.append(receipt("Resolution", "canSetSetting", "ok", f"{cur[0]}x{cur[1]} -> {want[0]}x{want[1]}"))
        else:
            out.append(receipt("Resolution", "canSetSetting", "failed", f"still {cur[0]}x{cur[1]}", "set_setting_failed"))
    if s.get("frameRate"):
        cur = str(project.GetSetting("timelineFrameRate"))
        try:
            same = abs(float(cur) - float(s["frameRate"])) < 0.001
        except ValueError:
            same = cur == str(s["frameRate"])
        if same:
            out.append(receipt("Frame rate", "canSetSetting", "ok", f"{cur} fps"))
        elif project.GetTimelineCount() > 0:
            out.append(receipt("Frame rate", "canSetSetting", "skipped",
                               f"Template is {cur} fps and already has timelines; not changed. Needs a new project/timeline.",
                               "framerate_locked"))
        elif project.SetSetting("timelineFrameRate", str(s["frameRate"])):
            out.append(receipt("Frame rate", "canSetSetting", "ok", f"{cur} -> {s['frameRate']} fps"))
        else:
            out.append(receipt("Frame rate", "canSetSetting", "failed", f"still {cur} fps", "set_setting_failed"))

    # Color science must be set before the color spaces it enables.
    first = {"colorScienceMode": 0, "separateColorSpaceAndGamma": 1}
    for key, value in sorted((s.get("extra") or {}).items(), key=lambda kv: (first.get(kv[0], 2), kv[0])):
        before = str(project.GetSetting(key))
        if before == str(value):
            out.append(receipt(f"Setting {key}", "canSetSetting", "ok", f"already {value}"))
        elif project.SetSetting(key, str(value)):
            out.append(receipt(f"Setting {key}", "canSetSetting", "ok", f"{before} -> {value}"))
        else:
            out.append(receipt(f"Setting {key}", "canSetSetting", "failed", f"still {before}; not supported here", "set_setting_failed"))

    if project.GetTimelineCount() > 0:
        wanted = plan.get("timelineName") or ""
        timelines = [project.GetTimelineByIndex(i) for i in range(1, project.GetTimelineCount() + 1)]
        tl = next((t for t in timelines if t.GetName() == wanted), timelines[0])
        ok = project.SetCurrentTimeline(tl)
        out.append(receipt("Open timeline", "canOpenProject", "ok" if ok else "failed", tl.GetName(), None if ok else "set_timeline_failed"))

    saved = pm.SaveProject()
    out.append(receipt("Save project", "canOpenProject", "ok" if saved else "failed", name, None if saved else "save_failed"))
    # Keep the folder's .drp equal to the saved Resolve project. The master stays read-only.
    export_path = plan.get("exportDrp") or ""
    if export_path:
        tmp = export_path + ".ewtmp"
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
            if pm.ExportProject(name, tmp, False) and os.path.exists(tmp):
                os.replace(tmp, export_path)
                out.append(receipt("Sync project copy", "canExportProject", "ok", export_path))
            else:
                if os.path.exists(tmp):
                    os.remove(tmp)
                out.append(receipt("Sync project copy", "canExportProject", "failed",
                                   "Resolve saved the project but could not export the folder copy.", "export_failed"))
        except Exception as e:
            out.append(receipt("Sync project copy", "canExportProject", "failed", repr(e), "export_exception"))
    resolve.OpenPage("edit")
    return {"projectName": name, "receipts": out}


def open_project(resolve, name):
    """Open an existing Resolve project by name. Never imports a second copy."""
    pm = resolve.GetProjectManager()
    if name not in (pm.GetProjectListInCurrentFolder() or []):
        return {"opened": False, "detail": f"Project '{name}' is not in the current Resolve folder."}
    project = pm.LoadProject(name)
    if not project:
        return {"opened": False, "detail": f"Resolve could not open '{name}'."}
    try:
        resolve.OpenPage("edit")
    except Exception:
        pass
    return {"opened": True, "name": name}


def bin_tree(folder, prefix=""):
    out = []
    for f in folder.GetSubFolderList() or []:
        path = f"{prefix}/{f.GetName()}" if prefix else f.GetName()
        out.append(path)
        out += bin_tree(f, path)
    return out


def current(resolve, export_path):
    pm = resolve.GetProjectManager()
    p = pm.GetCurrentProject()
    if not p:
        return {"error": "no_project", "detail": "No project is open in Resolve."}
    pm.SaveProject()
    name = p.GetName()
    ok = pm.ExportProject(name, export_path, False)
    return {"name": name, "exported": bool(ok),
            "bins": bin_tree(p.GetMediaPool().GetRootFolder()),
            "width": str(p.GetSetting("timelineResolutionWidth")), "height": str(p.GetSetting("timelineResolutionHeight")),
            "frameRate": str(p.GetSetting("timelineFrameRate")), "timelines": p.GetTimelineCount()}


def clips(folder):
    out = []
    for c in folder.GetClipList() or []:
        out.append({"name": c.GetName(), "path": c.GetClipProperty("File Path") or "", "type": c.GetClipProperty("Type") or ""})
    for f in folder.GetSubFolderList() or []:
        out += clips(f)
    return out


def inspect(resolve, drp):
    """Imports a throwaway copy, lists media references, then deletes it and reopens the previous project."""
    import os, uuid
    pm = resolve.GetProjectManager()
    prev = pm.GetCurrentProject()
    prev_name = prev.GetName() if prev else None
    if prev:
        pm.SaveProject()
    temp = "EW_INSPECT_" + uuid.uuid4().hex[:8]
    try:
        if not pm.ImportProject(drp, temp):
            return {"error": "import_failed", "detail": "Resolve could not import this .drp (damaged or from a newer version)."}
        p = pm.LoadProject(temp)
        found = clips(p.GetMediaPool().GetRootFolder()) if p else []
        timelines = p.GetTimelineCount() if p else 0
        extras = timeline_dependencies(p) if p else {}
        for c in found:
            c["exists"] = bool(c["path"]) and os.path.exists(c["path"])
        result = {"clips": found, "timelines": timelines, "opened": bool(p)}
        result.update(extras)
        return result
    finally:
        # Always remove the temporary project, even when a Resolve call raises.
        if prev_name:
            pm.LoadProject(prev_name)
        pm.DeleteProject(temp)


def timeline_dependencies(project):
    """Fonts (Text+), OFX tools and Fusion comps on timeline items, LUTs on grade nodes. Best effort, never raises."""
    fonts, ofx, luts, titles, comps = set(), set(), set(), set(), 0
    for ti in range(1, project.GetTimelineCount() + 1):
        tl = project.GetTimelineByIndex(ti)
        try:
            tracks = tl.GetTrackCount("video")
        except Exception:
            continue
        for tr in range(1, tracks + 1):
            for item in tl.GetItemListInTrack("video", tr) or []:
                try:
                    n = item.GetFusionCompCount() or 0
                    comps += n
                    if n and item.GetMediaPoolItem() is None:
                        titles.add(item.GetName())
                    for ci in range(1, n + 1):
                        comp = item.GetFusionCompByIndex(ci)
                        for tool in (comp.GetToolList(False) or {}).values():
                            reg = (tool.GetAttrs() or {}).get("TOOLS_RegID", "")
                            if reg == "TextPlus":
                                f = tool.GetInput("Font")
                                if f:
                                    fonts.add(str(f))
                            elif reg.lower().startswith("ofx."):
                                ofx.add(reg)
                except Exception:
                    pass
                try:
                    g = item.GetNodeGraph()
                    for ni in range(1, (g.GetNumNodes() or 0) + 1):
                        lut = g.GetLUT(ni)
                        if lut:
                            luts.add(lut)
                except Exception:
                    pass
    return {"fonts": sorted(fonts), "ofx": sorted(ofx), "luts": sorted(luts), "titles": sorted(titles), "fusionComps": comps}


def selftest(resolve, clip, tmp):
    """Runs every automated capability on throwaway projects and reports pass/fail per capability."""
    import os, uuid
    pm = resolve.GetProjectManager()
    prev = pm.GetCurrentProject()
    prev_name = prev.GetName() if prev else None
    if prev:
        pm.SaveProject()
    tag = uuid.uuid4().hex[:6]
    a, b = "EW_SELFTEST_A_" + tag, "EW_SELFTEST_B_" + tag
    drp = os.path.join(tmp, f"selftest-{tag}.drp")
    res = {k: False for k in ["canCreateBin", "canImportMedia", "canSetSetting", "canImportProject", "canOpenProject"]}
    notes = []
    try:
        pa = pm.CreateProject(a)
        if not pa:
            return {"error": "create_failed", "detail": "Could not create a test project."}
        mp = pa.GetMediaPool()
        f1 = mp.AddSubFolder(mp.GetRootFolder(), "Test")
        f2 = mp.AddSubFolder(f1, "Nested") if f1 else None
        res["canCreateBin"] = bool(f1 and f2)
        if f2 and mp.SetCurrentFolder(f2):
            res["canImportMedia"] = bool(mp.ImportMedia([clip]))
        res["canSetSetting"] = bool(pa.SetSetting("timelineResolutionWidth", "1080") and pa.SetSetting("timelineResolutionHeight", "1920"))
        mp.CreateEmptyTimeline("Probe")
        pm.SaveProject()
        if pm.ExportProject(a, drp, False) and pm.ImportProject(drp, b):
            res["canImportProject"] = True
            pb = pm.LoadProject(b)
            res["canOpenProject"] = bool(pb and pb.GetTimelineCount() > 0 and pb.SetCurrentTimeline(pb.GetTimelineByIndex(1)))
    except Exception as e:
        notes.append(repr(e))
    finally:
        if prev_name:
            pm.LoadProject(prev_name)
        for n in (a, b):
            if n in (pm.GetProjectListInCurrentFolder() or []):
                pm.DeleteProject(n)
        if os.path.exists(drp):
            os.remove(drp)
    return {"results": res, "version": resolve.GetVersionString(), "notes": notes}


def main():
    cmd = json.loads(sys.stdin.read() or "{}")
    try:
        import DaVinciResolveScript as dvr
    except Exception as e:  # module path missing
        print(json.dumps({"reachable": False, "error": "module_missing", "detail": repr(e)}))
        return
    resolve = dvr.scriptapp("Resolve")
    if resolve is None:
        print(json.dumps({"reachable": False, "error": "not_reachable",
                          "detail": "Resolve is not running, or Preferences > System > General > "
                                    "External scripting using is not set to Local (Studio only)."}))
        return
    try:
        c = cmd.get("cmd")
        if c == "probe":
            result = probe(resolve)
        elif c == "open":
            result = open_project(resolve, cmd["name"])
        elif c == "current":
            result = current(resolve, cmd["exportPath"])
        elif c == "inspect":
            result = inspect(resolve, cmd["drp"])
        elif c == "selftest":
            result = selftest(resolve, cmd["clip"], cmd["tmp"])
        else:
            result = run_plan(resolve, cmd["plan"])
        result["reachable"] = True
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"reachable": True, "error": "exception", "detail": repr(e)}))


if __name__ == "__main__":
    main()
