import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct TemplatesView: View {
    @EnvironmentObject var model: AppModel
    @Local private var search = ""
    @Local private var category = ""
    @Local private var asList = false
    @Local private var byRecent = false
    @Local private var editing: Template?

    var categories: [String] { Array(Set(model.templateList.map(\.category).filter { !$0.isEmpty })).sorted() }
    var filtered: [Template] {
        let f = model.templateList.filter { $0.matches(search) && (category.isEmpty || $0.category == category) }
        return byRecent ? f.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) } : f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).frame(width: 240, height: 28)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                if !categories.isEmpty {
                    Picker("Category", selection: $category) {
                        Text("All").tag("")
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().fixedSize().help("Category")
                }
                Picker(selection: $byRecent) {
                    Text("Name").tag(false)
                    Text("Recently used").tag(true)
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .pickerStyle(.menu).fixedSize().help("Sort").accessibilityLabel("Sort templates")
                IconButton(symbol: asList ? "square.grid.2x2" : "list.bullet", label: asList ? "Show as grid" : "Show as list", tint: .secondary, size: 13) { asList.toggle() }
                Spacer()
                Menu {
                    Button { model.showImporter = true } label: { Label("Import .drp…", systemImage: "square.and.arrow.down") }
                    Button { model.templateFromOpenResolveProject { editing = $0 } } label: { Label("From the project open in Resolve", systemImage: "bolt") }
                        .disabled(model.resolveStatus?.canAutomate != true)
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Add a template").accessibilityLabel("Add a template")
            }
            if model.templateList.isEmpty { DrpDropZone() }
            ScrollView {
                if filtered.isEmpty {
                    if !model.templateList.isEmpty { Label("No match", systemImage: "magnifyingglass").foregroundStyle(.secondary).padding() }
                } else if asList {
                    LazyVStack(alignment: .leading) {
                        ForEach(filtered) { t in TemplateListRow(template: t).onTapGesture { editing = t }.accessibilityAction { editing = t }.contextMenu { TemplateMenu(template: t, editing: $editing) } }
                    }
                } else {
                    TemplateGrid(templates: filtered, editing: $editing)
                }
            }
        }
        .padding(20)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "drp" else { return }
                Task { @MainActor in importDrp(url, model: model) { editing = $0 } }
            }
            return true
        }
        .navigationTitle("Templates")
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [UTType(filenameExtension: "drp") ?? .data]) { r in
            if case .success(let url) = r { importDrp(url, model: model) { editing = $0 } }
        }
        .sheet(item: $editing) { t in TemplateDetailView(templateID: t.id).environmentObject(model) }
        .onReceive(model.$openTemplateDetail) { id in
            if let id, let t = model.templateList.first(where: { $0.id == id }) { editing = t; model.openTemplateDetail = nil }
        }
    }
}

@MainActor func importDrp(_ url: URL, model: AppModel, then: (Template) -> Void = { _ in }) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
        // Two templates with one name are impossible to tell apart in pickers: number the new one.
        let name = ProjectStore.uniqueName(url.deletingPathExtension().lastPathComponent, taken: model.templateList.map(\.name))
        let t = try model.templates.importTemplate(from: url, name: name, resolveVersion: model.resolveStatus?.liveVersion ?? model.resolveStatus?.installedVersion)
        model.reloadTemplates()
        model.autoCover(t.id)
        then(t)
    } catch { model.report(error) }
}

struct DrpDropZone: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    @Local private var targeted = false
    @Local private var editing: Template?

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5))
            .frame(height: compact ? 56 : 110)
            .overlay {
                VStack(spacing: 4) {
                    Label("Drop a .drp here to import a template", systemImage: "tray.and.arrow.down")
                    if !compact { Text("Your original file is never changed").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.showImporter = true }
            .accessibilityAction { model.showImporter = true }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in
                            if url.pathExtension.lowercased() != "drp" { model.errorMessage = "\(url.lastPathComponent) is not a .drp file."; return }
                            importDrp(url, model: model) { editing = $0 }
                        }
                    }
                }
                return true
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Import template drop zone")
            .accessibilityHint("Drop a DaVinci Resolve .drp file, or activate to choose one")
            .accessibilityAddTraits(.isButton)
            .sheet(item: $editing) { t in TemplateDetailView(templateID: t.id).environmentObject(model) }
    }
}

struct TemplateGrid: View {
    @EnvironmentObject var model: AppModel
    let templates: [Template]
    var editing: Binding<Template?>? = nil
    @Local private var localEditing: Template?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 14)], spacing: 14) {
            ForEach(templates) { t in
                TemplateCard(template: t)
                    .onTapGesture { if let editing { editing.wrappedValue = t } else { localEditing = t } }
                    .accessibilityAction { if let editing { editing.wrappedValue = t } else { localEditing = t } }
                    .contextMenu { TemplateMenu(template: t, editing: editing ?? $localEditing) }
            }
        }
        .sheet(item: $localEditing) { t in TemplateDetailView(templateID: t.id).environmentObject(model) }
    }
}

struct TemplateCard: View {
    @EnvironmentObject var model: AppModel
    let template: Template

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(template: template, corner: 10)
                .frame(height: 112)
                .overlay(alignment: .topTrailing) {
                    Button { var t = template; t.favorite.toggle(); try? model.templates.updateMetadata(t); model.reloadTemplates() } label: {
                        Image(systemName: template.favorite ? "heart.fill" : "heart").font(.caption).padding(6).background(.thinMaterial, in: Circle())
                            .foregroundStyle(template.favorite ? Theme.favorite : .primary)
                    }
                    .buttonStyle(.plain).padding(6)
                    .help(template.favorite ? "Remove from favorites" : "Add to favorites")
                    .accessibilityLabel(template.favorite ? "Remove from favorites" : "Add to favorites")
                }
            Text(template.name).font(.callout.weight(.semibold)).lineLimit(1)
            Text(template.category.isEmpty ? " " : template.category).font(.caption).foregroundStyle(.secondary).lineLimit(1)  // keeps cards the same height
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .help(template.lastUsed.map { "v\(template.current.number) · used \($0.formatted(.relative(presentation: .named)))" } ?? "v\(template.current.number) · not used yet")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct TemplateListRow: View {
    let template: Template
    var body: some View {
        HStack {
            Image(systemName: template.favorite ? "heart.fill" : "doc").foregroundStyle(template.favorite ? Theme.favorite : .secondary)
            Text(template.name).bold()
            Text(template.category).foregroundStyle(.secondary)
            Text(template.tags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("v\(template.current.number) · \(template.current.bins.count) bins")
        }
        .padding(.vertical, 6).contentShape(Rectangle())
    }
}

struct TemplateMenu: View {
    @EnvironmentObject var model: AppModel
    let template: Template
    @Binding var editing: Template?

    var body: some View {
        Button("Edit…") { editing = template }
        Button("New Project from Template…") { model.wizardTemplateID = template.id; model.showWizard = true }
        Button(template.favorite ? "Remove from Favorites" : "Add to Favorites") { var t = template; t.favorite.toggle(); try? model.templates.updateMetadata(t); model.reloadTemplates() }
        Button("Duplicate") { do { _ = try model.templates.duplicate(template.id); model.reload() } catch { model.report(error) } }
        Button("Export .drp…") {
            if let dir = AppModel.chooseFolder(prompt: "Export Here") {
                do { let u = try model.templates.export(template.id, to: dir); NSWorkspace.shared.activateFileViewerSelecting([u]) } catch { model.report(error) }
            }
        }
        Divider()
        Button("Remove from Library…", role: .destructive) {
            let a = NSAlert()
            a.messageText = "Remove \"\(template.name)\" from the library?"
            a.informativeText = "Its stored master copies are deleted from the app library. Projects already created keep their own .drp copies. Your original .drp file is not touched."
            a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { try? model.templates.remove(template.id); model.reload() }
        }
    }
}

// MARK: - Detail

/// Tabs with an icon and a word: icons alone were too hard to read.
struct TabStrip: View {
    let tabs: [(icon: String, title: String)]
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs.indices, id: \.self) { i in
                let on = selection == i
                Button { selection = i } label: {
                    Label(tabs[i].title, systemImage: tabs[i].icon)
                        .font(.callout.weight(on ? .semibold : .regular))
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(on ? Theme.accent.opacity(0.18) : .clear, in: Capsule())
                        .foregroundStyle(on ? Theme.accent : .secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
    }
}

/// Small status pill; the long explanation lives in the tooltip.
func StatusPill(_ text: String, _ icon: String, _ color: Color, help: String) -> some View {
    Label(text, systemImage: icon)
        .font(.caption.weight(.medium)).foregroundStyle(color)
        .padding(.horizontal, 8).frame(height: 22)
        .background(color.opacity(0.12), in: Capsule())
        .help(help)
        .accessibilityLabel("\(text). \(help)")
}

struct TemplateDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let templateID: UUID
    @Local private var t: Template?
    @Local private var draft = TemplateVersion(number: 0, masterPath: "", masterHash: "", originalFilename: "")
    @Local private var tagsText = ""
    @Local private var tab: Int
    @Local private var masterOK: Bool?
    @Local private var scanning = false

    init(templateID: UUID, initialTab: Int = 0) {
        self.templateID = templateID
        _tab = Local(wrappedValue: initialTab)
    }

    var dirty: Bool { t.map { draft.bins != $0.current.bins || draft.assets != $0.current.assets || draft.settings != $0.current.settings || draft.folderScheme != $0.current.folderScheme } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if t != nil {
                header.padding(20)
                TabStrip(tabs: [("rectangle.stack", "Bins"), ("photo.stack", "Assets"), ("slider.horizontal.3", "Settings"),
                                ("folder", "Folders"), ("clock.arrow.circlepath", "Versions"), ("checklist", "Test run")], selection: $tab)
                    .padding(.horizontal, 16).padding(.bottom, 10)
                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case 0: BinPlanEditor(bins: $draft.bins)
                        case 1:
                            VStack(alignment: .leading, spacing: 12) {
                                Button {
                                    scanning = true
                                    model.scanDependencies(draft) { found in draft.assets = TemplateStore.merge(found, into: draft.assets); scanning = false }
                                } label: { Label(scanning ? "Scanning…" : "Scan in Resolve", systemImage: "wand.and.stars") }
                                .disabled(model.resolveStatus?.canAutomate != true || scanning)
                                .help("Resolve Studio opens a temporary copy and lists clips, fonts, LUTs, Fusion titles and OFX tools, then deletes the copy.")
                                AssetRulesEditor(assets: $draft.assets, templateID: templateID)
                            }
                        case 2: SettingsProfileEditor(settings: $draft.settings)
                        case 3: StringListEditor(title: "Folders created on disk for each project", items: $draft.folderScheme, placeholder: "06 Proxies")
                        case 4: versions
                        default: testRun
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    if dirty {
                        Label("Saving makes version \(t!.current.number + 1)", systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.secondary).help("Projects already made keep their version.")
                    }
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }.padding(16)
            }
        }
        .frame(width: 860, height: 640)
        .tint(Theme.accent)
        .onAppear(perform: load)
    }

    func load() {
        t = model.templates.get(templateID)
        if let t { draft = t.current; tagsText = t.tags.joined(separator: ", ") }
        let store = model.templates, v = draft
        Task.detached { let ok = store.verifyMaster(v); await MainActor.run { masterOK = ok } }
    }

    func save() {
        guard var cur = t else { return }
        cur.cover = model.templates.get(cur.id)?.cover   // the cover box saves itself; don't overwrite it with this sheet's copy
        cur.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            try model.templates.updateMetadata(cur)
            if dirty {
                let d = draft
                _ = try model.templates.newVersion(of: cur.id, note: "Edited bins/assets/settings") { v in
                    v.bins = d.bins; v.assets = d.assets; v.settings = d.settings; v.folderScheme = d.folderScheme
                }
            }
            model.reloadTemplates(); load()
            dismiss()   // saving is the end of the edit: the sheet closes, the library shows the new version
        } catch { model.report(error) }
    }

    @ViewBuilder var header: some View {
        HStack(alignment: .top, spacing: 20) {
            if let live = model.templateList.first(where: { $0.id == templateID }) {
                CoverBox(template: live, height: 132).frame(width: 230)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Template name", text: Binding(get: { t!.name }, set: { t!.name = $0 }))
                        .font(.title2.weight(.semibold)).textFieldStyle(.plain)
                    Button { t!.favorite.toggle() } label: {
                        Image(systemName: t!.favorite ? "heart.fill" : "heart").font(.title3)
                            .foregroundStyle(t!.favorite ? Theme.favorite : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(t!.favorite ? "Remove from favorites" : "Add to favorites")
                    .accessibilityLabel(t!.favorite ? "Remove from favorites" : "Add to favorites")
                }
                HStack(spacing: 8) {
                    TextField("Category", text: Binding(get: { t!.category }, set: { t!.category = $0 })).frame(width: 150)
                    TextField("Tags", text: $tagsText).help("Comma separated, e.g. wedding, outdoor")
                    TextField("Project types", text: Binding(get: { t!.projectTypes.joined(separator: ", ") }, set: { t!.projectTypes = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                        .help("Comma separated, e.g. long-form, teaser")
                }.textFieldStyle(.roundedBorder)
                TextField("Description", text: Binding(get: { t!.summary }, set: { t!.summary = $0 }), axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...3)
                statusLine
            }
        }
    }

    var statusLine: some View {
        let v = t!.current
        let diags = v.diagnostics ?? []
        let warn = diags.contains { $0.contains("newer") }
        return HStack(spacing: 6) {
            StatusPill("v\(v.number)", "doc", .secondary, help: "Version \(v.number) from \(v.originalFilename)")
            StatusPill(masterOK == nil ? "Checking" : (masterOK! ? "Intact" : "Changed"), masterOK == false ? "exclamationmark.triangle.fill" : "lock.fill",
                       masterOK == false ? Theme.failed : Theme.verified,
                       help: masterOK == false ? "The stored master changed on disk. Do not use it." : "Stored master, never modified. SHA-256 \(v.masterHash.prefix(16))…")
            if model.resolveStatus?.canAutomate != true {
                StatusPill("Manual import", "hand.point.up.left", .secondary, help: "Resolve Free or an untested version: you enter bins and assets, and import by hand with the checklist. The app never edits the .drp.")
            }
            if !diags.isEmpty {
                StatusPill(diags.count == 1 ? "1 note" : "\(diags.count) notes", warn ? "exclamationmark.triangle.fill" : "info.circle",
                           warn ? Theme.attention : .secondary, help: diags.joined(separator: "\n"))
            }
        }
    }

    var versions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(t!.versions.sorted { $0.number > $1.number }) { v in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("v\(v.number)").font(Theme.number(15)).frame(width: 36, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.note.isEmpty ? v.originalFilename : v.note)
                        Text("\(v.importedAt.formatted(date: .abbreviated, time: .shortened)), \(v.bins.count) bins, \(v.assets.count) assets")
                            .font(.caption).foregroundStyle(.secondary)
                            .help(v.resolveVersion.map { "Resolve \($0), \(v.originalFilename)" } ?? v.originalFilename)
                    }
                }
            }
            Button {
                let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "drp") ?? .data]
                if p.runModal() == .OK, let u = p.url {
                    do { _ = try model.templates.replaceMaster(of: templateID, with: u); model.reloadTemplates(); load() } catch { model.report(error) }
                }
            } label: { Label("Replace master .drp…", systemImage: "arrow.triangle.2.circlepath") }
                .help("Makes a new version. Projects already made keep theirs.")
        }
    }

    var testRun: some View {
        let s = ProjectSession(name: "Example Client - Example Event", templateID: templateID, templateVersion: draft.number, templateName: t!.name,
                               projectFolder: "~/Projects/Example", instanceDrpPath: "~/Projects/Example/Resolve/Example.drp",
                               mappings: draft.bins.map { BinMapping(sourcePath: "<\($0.defaultSourceRule.isEmpty ? "folder" : $0.defaultSourceRule)>", targetBin: $0.binPath) },
                               settings: draft.settings)
        return VStack(alignment: .leading, spacing: 10) {
            Text("What a manual run does").font(.headline)
                .help("Nothing is created. Studio automation runs only steps proven on your Resolve version.")
            Text(ProjectStore.checklist(for: s, version: draft)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            let essentialMissing = draft.assets.filter { $0.essential && $0.status == .knownMissing }
            if !essentialMissing.isEmpty { Label("\(essentialMissing.count) essential asset(s) missing", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.attention) }
        }
    }
}

struct BinPlanEditor: View {
    @Binding var bins: [BinPlanEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !bins.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Bin").help("Use / for nested bins, e.g. 01 Footage/Camera A")
                        Text("Footage folder contains").help("Folders whose name contains this text go into the bin, e.g. cam a")
                        Text("Required").gridColumnAlignment(.center)
                        Color.clear.frame(width: 20, height: 1)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach($bins) { $b in
                        GridRow {
                            TextField("01 Footage/Camera A", text: $b.binPath)
                            TextField("cam a", text: $b.defaultSourceRule).frame(width: 180)
                            Toggle("Required", isOn: $b.required).labelsHidden().accessibilityLabel("Required")
                            Button { bins.removeAll { $0.id == b.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove bin").accessibilityLabel("Remove bin")
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button { bins.append(BinPlanEntry(binPath: "")) } label: { Label("Add bin", systemImage: "plus") }
                if bins.isEmpty {
                    Button("Use a common structure") {
                        bins = [("01 Footage/Camera A", "cam a"), ("01 Footage/Camera B", "cam b"), ("01 Footage/Drone", "drone"),
                                ("02 Audio/Voice", "audio"), ("03 Audio/Music", "music"), ("04 Graphics/Logos", "logo")]
                            .map { BinPlanEntry(binPath: $0.0, defaultSourceRule: $0.1) }
                    }
                    .help("Camera A/B, Drone, Voice, Music, Logos")
                }
            }
        }
    }
}

struct AssetRulesEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var assets: [AssetRuleEntry]
    var templateID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($assets) { $a in
                HStack {
                    TextField("Asset name", text: $a.name)
                    Picker("", selection: $a.kind) { ForEach(AssetKind.allCases, id: \.self) { Text($0.rawValue.capitalized) } }.frame(width: 100)
                    Picker("", selection: $a.rule) { ForEach(AssetRule.allCases, id: \.self) { Text($0.rawValue.capitalized) } }.pickerStyle(.segmented).frame(width: 200)
                        .help("Keep: reusable titles and placeholders. Replace: client footage, names, branding. Optional: music, LUTs, overlays chosen per job.")
                    Picker("", selection: $a.status) { ForEach(DependencyStatus.allCases, id: \.self) { Text($0.label) } }.frame(width: 150)
                    Toggle("Essential", isOn: $a.essential)
                    Button { assets.removeAll { $0.id == a.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel("Remove asset")
                }.textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Location (optional)", text: $a.location).textFieldStyle(.roundedBorder)
                    Button("Locate…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true
                        if p.runModal() == .OK, let u = p.url { a.location = u.path; a.status = .available }
                    }
                    if let templateID {
                        Button(a.packagedPath == nil ? "Package…" : "Packaged ✓") { package($a, templateID) }
                            .help("Store a copy of this asset with the template")
                    }
                }.padding(.leading, 12).padding(.bottom, 6)
            }
            Button { assets.append(AssetRuleEntry(name: "")) } label: { Label("Add asset", systemImage: "plus") }
        }
    }

    func package(_ a: Binding<AssetRuleEntry>, _ templateID: UUID) {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false
        if !a.wrappedValue.location.isEmpty { p.directoryURL = URL(fileURLWithPath: a.wrappedValue.location).deletingLastPathComponent() }
        guard p.runModal() == .OK, let u = p.url else { return }
        let alert = NSAlert()
        alert.messageText = "Do you have the right to reuse \(u.lastPathComponent) in other projects?"
        alert.informativeText = "Only package your own or properly licensed assets. Commercial fonts, LUTs, plugins, music and client logos often may not be copied between projects."
        alert.addButton(withTitle: "I Have the Rights — Package"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { a.wrappedValue.packagedPath = try model.templates.packageFile(u, templateID: templateID); a.wrappedValue.location = u.path; a.wrappedValue.status = .available }
        catch { model.report(error) }
    }
}

struct SettingsProfileEditor: View {
    @Binding var settings: SettingsProfile
    /// Keys read from Resolve 21.1 Project.GetSetting(); values as Resolve reports them.
    static let extraKeys: [(String, String, String)] = [
        ("colorScienceMode", "Color science", "davinciYRGB / davinciYRGBColorManagedv2 / acescct"),
        ("colorSpaceInput", "Input color space", "S-Gamut3.Cine/S-Log3"),
        ("colorSpaceTimeline", "Timeline color space", "Rec.709 (Scene)"),
        ("colorSpaceOutput", "Output color space", "Rec.709 (Scene)"),
        ("perfProxyMediaMode", "Proxy mode", "0 off · 1 prefer proxies · 2 prefer camera originals"),
        ("perfProxyResolutionRatio", "Proxy resolution", "original / half / quarter"),
        ("perfOptimizedResolutionRatio", "Optimized media resolution", "auto / original / half"),
        ("perfRenderCacheMode", "Render cache", "none / smart / user"),
        ("timelinePlaybackFrameRate", "Playback frame rate", "24"),
        ("videoMonitorFormat", "Monitoring format", "HD 1080p 24"),
        ("audioPlayoutNumChannels", "Audio playout channels", "2"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Apply these settings to new projects", isOn: Binding(get: { settings.apply == true }, set: { settings.apply = $0 }))
                .help("Off: the master's own settings are kept.")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Preset")
                    Picker("Preset", selection: Binding(get: { settings.apply == true ? "custom" : "" }, set: { name in
                        if name.isEmpty { settings.apply = false; return }      // Default: Resolve's standard project, nothing changed
                        if let p = SettingsProfile.presets.first(where: { $0.0 == name }) { let tl = settings.timelineName; settings = p.1; settings.timelineName = tl; settings.apply = true }
                    })) {
                        Text("Default (no changes)").tag("")
                        Text("Custom").tag("custom")
                        Divider()
                        ForEach(SettingsProfile.presets, id: \.0) { Text($0.0).tag($0.0) }
                    }.labelsHidden().frame(width: 240)
                }
                GridRow {
                    label("Resolution")
                    HStack(spacing: 6) {
                        TextField("Width", value: $settings.width, format: .number.grouping(.never)).frame(width: 80)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", value: $settings.height, format: .number.grouping(.never)).frame(width: 80)
                        Text(settings.orientation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    label("Frame rate")
                    HStack(spacing: 6) {
                        Picker("Frame rate", selection: $settings.frameRate) { ForEach(SettingsProfile.frameRates, id: \.self) { Text("\($0) fps") } }
                            .labelsHidden().frame(width: 120)
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.attention)
                            .help("Frame rate can't change once a Resolve project has timelines. If the master's timelines use another rate, the app reports it and leaves it.")
                            .accessibilityLabel("Frame rate needs a new project or timeline")
                    }
                }
                GridRow {
                    label("Timeline to open")
                    TextField("First timeline", text: $settings.timelineName).frame(width: 260)
                }
                GridRow {
                    label("Clip input color space")
                    Picker("Clip input color space", selection: Binding(
                        get: { settings.inputColorSpace ?? "" },
                        set: { settings.inputColorSpace = $0.isEmpty ? nil : $0 })) {
                        ForEach(SettingsProfile.inputColorSpaces, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden().frame(width: 280)
                    .help("Applied to every video clip the project imports, e.g. S-Log3 or HLG. Auto keeps Resolve's own reading of the file.")
                }
            }
            DisclosureGroup("Advanced Resolve settings") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(Self.extraKeys, id: \.0) { key, title, hint in
                        GridRow {
                            label(title)
                            TextField(hint, text: Binding(get: { settings.extra?[key] ?? "" }, set: { v in
                                var e = settings.extra ?? [:]; e[key] = v.isEmpty ? nil : v; settings.extra = e.isEmpty ? nil : e
                                if !v.isEmpty { settings.apply = true }
                            })).frame(width: 360)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .help("Applied after import, one result per setting. Keys your Resolve version doesn't support are reported, not faked.")
        }
        .textFieldStyle(.roundedBorder)
    }

    func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

struct StringListEditor: View {
    let title: String
    @Binding var items: [String]
    let placeholder: String
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            ForEach(items.indices, id: \.self) { i in
                HStack {
                    TextField(placeholder, text: Binding(get: { i < items.count ? items[i] : "" }, set: { if i < items.count { items[i] = $0 } })).textFieldStyle(.roundedBorder)
                    Button { items.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Remove folder").accessibilityLabel("Remove folder")
                }
            }
            Button { items.append("") } label: { Label("Add folder", systemImage: "plus") }
        }
    }
}
