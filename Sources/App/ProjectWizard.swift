import SwiftUI
import AppKit

struct ProjectWizard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let initialTemplate: UUID?
    @Local private var d = WizardDraft()
    @Local private var search = ""
    @Local private var showAdvanced = false
    @Local private var showTransfer = false
    @Local private var creating = false
    @Local private var loaded = false

    let steps = ["Template", "Name", "Media", "Bins", "Review"]
    var template: Template? { d.templateID.flatMap { id in model.templateList.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(steps.indices, id: \.self) { i in
                    Button { if canEnter(i) { d.step = i } } label: {
                        Label(steps[i], systemImage: ["square.grid.2x2", "character.cursor.ibeam", "sdcard", "rectangle.stack", "checkmark.circle"][i])
                            .font(.callout.weight(i == d.step ? .semibold : .regular))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(i == d.step ? Theme.accent.opacity(0.2) : .clear, in: Capsule())
                            .foregroundStyle(i == d.step ? Theme.accent : (i < d.step ? .primary : .secondary))
                    }.buttonStyle(.plain).disabled(!canEnter(i))
                    .accessibilityLabel("Step \(i + 1) of 5, \(steps[i])\(i == d.step ? ", current" : "")")
                    if i < steps.count - 1 { Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption) }
                }
                Spacer()
            }.padding(16)
            Divider()
            ScrollView {
                Group {
                    switch d.step {
                    case 0: chooseTemplate
                    case 1: nameStep
                    case 2: mediaStep
                    case 3: binsStep
                    default: reviewStep
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Discard Draft") { model.projects.clearDraft(); d = WizardDraft() }.disabled(d == WizardDraft())
                Spacer()
                if d.step > 0 { Button("Back") { d.step -= 1 } }
                if d.step < 4 {
                    Button("Next") { advance() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canEnter(d.step + 1))
                } else {
                    let auto = model.resolveStatus?.canAutomate == true
                    if auto { Button("Create (guided only)") { create(automate: false) }.disabled(creating) }
                    Button(auto ? "Create & Run in Resolve" : "Create Project") { create(automate: auto) }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(creating)
                }
            }.padding(16)
        }
        .frame(width: 900, height: 580)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let saved = model.projects.draft, initialTemplate == nil || saved.templateID == initialTemplate { d = saved }
            if let initialTemplate, d.templateID != initialTemplate { d = WizardDraft(); d.templateID = initialTemplate; d.step = 1 }
            if d.destinationRoot.isEmpty { d.destinationRoot = model.settings.defaultProjectsFolder }
            if d.startedAt == nil { d.startedAt = Date() }
            model.refreshResolve()
        }
        .onChange(of: d) { old, new in
            // Count editor-made changes (not step moves) for the local "fields changed per run" metric.
            var a = old, b = new; a.step = 0; b.step = 0; a.edits = nil; b.edits = nil
            if a != b && old.startedAt != nil { d.edits = (d.edits ?? 0) + 1 }
            model.projects.saveDraft(d)
        }
        .sheet(isPresented: $showTransfer) {
            VStack(spacing: 0) {
                TransfersView { job in
                    d.sources.append(MediaSource(path: job.outputPath, label: URL(fileURLWithPath: job.outputPath).lastPathComponent, volume: job.destinationVolume, transferJobID: job.id))
                    showTransfer = false
                }
                HStack { Spacer(); Button("Close") { showTransfer = false } }.padding(10)
            }
            .environmentObject(model).frame(width: 980, height: 600)
        }
    }

    func canEnter(_ step: Int) -> Bool {
        switch step {
        case 0: return true
        case 1: return template != nil
        case 2: return template != nil && !d.projectName.trimmingCharacters(in: .whitespaces).isEmpty && !d.destinationRoot.isEmpty
        case 3, 4: return canEnter(2)
        default: return false
        }
    }

    /// A source covers a file or a folder, never a sibling whose name only starts the same way
    /// ("/a/cam" must not cover "/a/cam2").
    static func covers(_ path: String, _ source: String) -> Bool {
        path == source || path.hasPrefix(source + "/")
    }

    func advance() {
        if d.step == 0, d.projectName.isEmpty, let pattern = model.settings.namePattern, !pattern.isEmpty {
            d.projectName = ProjectStore.applyPattern(pattern, template: template)
        }
        if d.step == 1, d.settings == nil { d.settings = template?.current.settings }
        // Suggest when nothing is mapped yet, or when a source was added that no row covers.
        // Suggest rows only for sources no row covers yet, so earlier edits survive.
        if d.step == 2 {
            let uncovered = d.sources.filter { s in !d.mappings.contains { Self.covers($0.sourcePath, s.path) } }
            d.mappings += model.projects.suggestMappings(sources: uncovered, bins: template?.current.bins ?? [], templateID: d.templateID)
        }
        d.step += 1
    }

    // MARK: Steps

    var chooseTemplate: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search templates", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            if model.templateList.isEmpty { Text("No templates yet. Import a .drp in Templates first.").foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(model.templateList.filter { $0.matches(search) }) { t in
                    TemplateCard(template: t)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(d.templateID == t.id ? Color.accentColor : .clear, lineWidth: 3))
                        .onTapGesture { d.templateID = t.id; d.settings = t.current.settings; d.mappings = [] }
                        .onTapGesture(count: 2) { d.templateID = t.id; d.settings = t.current.settings; d.step = 1 }
                        .accessibilityAction { d.templateID = t.id; d.settings = t.current.settings; d.mappings = [] }
                        .accessibilityAddTraits(d.templateID == t.id ? .isSelected : [])
                }
            }
            if let t = template {
                Text("v\(t.current.number), \(t.current.bins.count) bins, \(t.current.assets.count) assets").font(.caption).foregroundStyle(.secondary)
                    .help("Made with Resolve \(t.current.resolveVersion ?? "unknown")")
                EditionLine()
            }
        }
    }

    var nameStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Project name, e.g. Mohan & Anbika - Mehndi", text: $d.projectName)
                .textFieldStyle(.plain).font(.title3.weight(.semibold))
                .padding(.horizontal, 10).frame(height: 36)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1))
                .accessibilityLabel("Project name")
            HStack {
                Text(d.destinationRoot.isEmpty ? "No destination chosen" : d.destinationRoot).foregroundStyle(d.destinationRoot.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Destination…") { if let u = AppModel.chooseFolder(prompt: "Use", start: d.destinationRoot.isEmpty ? nil : d.destinationRoot) { d.destinationRoot = u.path } }
            }
            if !d.destinationRoot.isEmpty, !d.projectName.isEmpty {
                let existing = (try? FileManager.default.contentsOfDirectory(atPath: d.destinationRoot)) ?? []
                let final = ProjectStore.uniqueName(d.projectName, taken: existing)
                if final != d.projectName { Label("A folder with this name exists. The project will be created as \"\(final)\"; nothing is overwritten.", systemImage: "info.circle").foregroundStyle(.orange) }
                if let rs = model.resolveStatus, rs.projects.contains(where: { $0.collisionKey == d.projectName.collisionKey }) {
                    Label("Name taken in Resolve: a unique one will be used", systemImage: "info.circle").foregroundStyle(.orange)
                }
            }
            Toggle("Create project folder structure (\(template?.current.folderScheme.joined(separator: ", ") ?? ""))", isOn: $d.createFolders)
            GroupBox("Quick settings") {
                HStack {
                    ForEach(SettingsProfile.presets.prefix(3), id: \.0) { p in
                        Button(p.0) { let tl = d.settings?.timelineName ?? ""; d.settings = p.1; d.settings?.timelineName = tl; d.settings?.apply = true }
                    }
                    Spacer()
                    Text(d.settings?.apply == true ? "\(d.settings?.width ?? 0)×\(d.settings?.height ?? 0) · \(d.settings?.frameRate ?? "") fps" : "Keep master's settings").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Input color space").foregroundStyle(.secondary)
                Picker("Input color space", selection: Binding(
                    get: { d.settings?.inputColorSpace ?? template?.current.settings.inputColorSpace ?? "" },
                    set: { v in
                        var s = d.settings ?? template?.current.settings ?? SettingsProfile()
                        s.inputColorSpace = v
                        d.settings = s
                    })) {
                    ForEach(SettingsProfile.inputColorSpaces, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().frame(width: 280)
                .help("Resolve Color Management converts every imported clip from this space to Rec.709 on the timeline.")
                Spacer()
            }
            DisclosureGroup("Advanced settings", isExpanded: $showAdvanced) {
                SettingsProfileEditor(settings: Binding(get: { d.settings ?? SettingsProfile() }, set: { d.settings = $0 }))
                if let t = template, let s = d.settings, s.frameRate != t.current.settings.frameRate {
                    Label("Template uses \(t.current.settings.frameRate) fps", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .help("If the master already has timelines, Resolve keeps its rate and the app reports it instead of converting.")
                }
            }
        }
    }

    var mediaStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add footage folders. They are linked, not copied again.").foregroundStyle(.secondary)
            HStack {
                Button { if let u = AppModel.chooseFolder(prompt: "Add") { d.sources.append(MediaSource(path: u.path, label: u.lastPathComponent, volume: Volumes.identity(of: u))) } } label: { Label("Add Existing Folder…", systemImage: "folder.badge.plus") }
                Button { showTransfer = true } label: { Label("Transfer First…", systemImage: "arrow.left.arrow.right") }
            }
            ForEach(d.sources) { s in
                HStack {
                    Image(systemName: s.transferJobID == nil ? "folder" : "arrow.down.doc")
                    VStack(alignment: .leading) {
                        Text(s.label).bold()
                        Text("\(s.volume?.name ?? "?") [\(s.volume?.shortID ?? "?")] · \(s.path)").font(.caption).foregroundStyle(.secondary)
                        if let jid = s.transferJobID, let j = model.jobs.first(where: { $0.id == jid }) {
                            Text("Transfer: \(j.status.label)").font(.caption).foregroundStyle(j.status == .verified ? .green : .orange)
                        }
                    }
                    Spacer()
                    Button { d.sources.removeAll { $0.id == s.id }; d.mappings.removeAll { Self.covers($0.sourcePath, s.path) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel("Remove source")
                }
            }
            if d.sources.isEmpty { Text("No media yet. You can also continue and add media in Resolve later.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    var binsStep: some View {
        let binNames = (template?.current.bins.map(\.binPath) ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose a bin for each folder").foregroundStyle(.secondary).help("New bin paths are created. Use / for nested bins.")
                Spacer()
                Button("Re-suggest") { d.mappings = model.projects.suggestMappings(sources: d.sources, bins: template?.current.bins ?? [], templateID: d.templateID) }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text("Source").bold(); Text("Target bin").bold(); Text("Action").bold() }
                ForEach($d.mappings) { $m in
                    GridRow {
                        Text(URL(fileURLWithPath: m.sourcePath).pathComponents.suffix(2).joined(separator: " / ")).help(m.sourcePath).lineLimit(1)
                        HStack {
                            TextField("Bin", text: $m.targetBin).textFieldStyle(.roundedBorder).frame(width: 240)
                            Menu("") { ForEach(binNames, id: \.self) { b in Button(b) { m.targetBin = b; if m.action == .createBinAndImport { m.action = .importMedia } } } }
                                .menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Choose existing template bin")
                        }
                        Picker("", selection: $m.action) { ForEach(MappingAction.allCases, id: \.self) { Text($0.label) } }.frame(width: 190)
                    }
                }
            }
            let missingRequired = (template?.current.bins ?? []).filter { b in b.required && !d.mappings.contains { $0.targetBin == b.binPath && $0.action != .omit } }
            ForEach(missingRequired) { b in Label("Required bin \(b.binPath) has no media mapped.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Button { d.mappings.append(BinMapping(sourcePath: AppModel.chooseFolder(prompt: "Add")?.path ?? "", targetBin: binNames.first ?? "")) } label: { Label("Add mapping", systemImage: "plus") }
        }
    }

    @ViewBuilder
    var reviewStep: some View {
        if let t = template {
            reviewBody(t)
        } else {
            Text("This template is no longer available. Go back and choose one again.").foregroundStyle(.secondary)
        }
    }

    func reviewBody(_ t: Template) -> some View {
        let s = d.settings ?? t.current.settings
        let status = model.resolveStatus
        return VStack(alignment: .leading, spacing: 10) {
            Text("Review").font(.title2.bold())
            Text("Template: \(t.name) v\(t.current.number)").help("The master stays untouched; the project gets its own copy.")
            Text("Project: \(d.projectName) in \(d.destinationRoot)")
            Text(d.createFolders ? "Folders: \(t.current.folderScheme.joined(separator: ", "))" : "Folders: only Resolve/ (for the project copy and checklist)")
            Text(s.apply == true ? "Settings: \(s.width)×\(s.height) \(s.orientation) · \(s.frameRate) fps\(s.timelineName.isEmpty ? "" : " · open \(s.timelineName)")" : "Settings: keep the master's resolution and frame rate (no preset chosen)")
            Divider()
            Text("Media → bins").bold()
            ForEach(d.mappings) { m in Text("• \(URL(fileURLWithPath: m.sourcePath).lastPathComponent) → \(m.targetBin): \(m.action.label)").font(.callout) }
            if d.mappings.isEmpty { Text("No media mapped.").foregroundStyle(.secondary) }
            let unverified = d.sources.compactMap { s in s.transferJobID.flatMap { id in model.jobs.first { $0.id == id } } }.filter { $0.status != .verified }
            ForEach(unverified) { j in Label("Transfer \"\(j.name)\" is \(j.status.label.lowercased()). Media from it may be incomplete.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            let deps = t.current.assets.filter { $0.status != .available }
            if !deps.isEmpty {
                Text("Dependencies").bold()
                ForEach(deps) { a in Text("• \(a.name) (\(a.kind.rawValue), \(a.rule.rawValue)): \(a.status.label)\(a.essential ? ", essential" : "")").font(.callout).foregroundStyle(a.status == .knownMissing ? .orange : .secondary) }
            }
            Divider()
            EditionLine()
            if status?.canAutomate == true {
                Label("Resolve Studio does the import for you", systemImage: "bolt.fill").font(.callout)
                    .help("Imports the project copy, creates bins, imports media, sets resolution, opens the timeline and saves. Each step reports its own result. Frame rate is never changed on a project that has timelines.")
            } else {
                Label("You import into Resolve with a checklist", systemImage: "hand.point.up.left").font(.callout)
                    .help("The app creates the folders, a project .drp copy and an import checklist, then opens Resolve. The status stays \"Manual Step Required\" until you confirm the import.")
            }
        }
    }

    func create(automate: Bool) {
        guard let t = template else { return }
        let root = URL(fileURLWithPath: d.destinationRoot)
        creating = true
        do {
            let s = try model.projects.create(name: d.projectName.trimmingCharacters(in: .whitespaces), template: t, destinationRoot: root, createFolders: d.createFolders,
                                              sources: d.sources, mappings: d.mappings, settings: d.settings ?? t.current.settings,
                                              wizardSeconds: d.startedAt.map { Date().timeIntervalSince($0) }, wizardEdits: d.edits)
            model.projects.clearDraft()
            model.reload()
            if automate { model.runResolveAutomation(for: s) } else { openResolveGuided(s) }
            model.selection = .projects
            dismiss()
        } catch { model.report(error) }
        creating = false
    }

    func openResolveGuided(_ s: ProjectSession) {
        model.openInResolve(s)
    }
}

struct EditionLine: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack {
            if let s = model.resolveStatus {
                Image(systemName: s.canAutomate ? "bolt.fill" : "hand.point.up.left").foregroundStyle(s.canAutomate ? .green : .orange)
                Text("Resolve \(s.liveVersion ?? s.installedVersion ?? ""), \(s.canAutomate ? "automatic import" : "manual import")").font(.caption)
                    .help("\(s.edition.label). \(s.message)")
            } else {
                ProgressView().controlSize(.small); Text("Checking Resolve…").font(.caption)
            }
            Spacer()
            Button("Recheck") { model.refreshResolve() }.controlSize(.small)
        }
    }
}

// MARK: - Projects

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @Local private var selected: ProjectSession.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.sessions, selection: $selected) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(s.name).bold(); Spacer(); StateBadge(state: s.state) }
                        Text("\(s.templateName) v\(s.templateVersion) · \(s.created.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }.tag(s.id)
                }
                .overlay {
                    if model.sessions.isEmpty {
                        EmptyState(icon: "film.stack", title: "No projects yet", action: "New project") { model.wizardTemplateID = nil; model.showWizard = true }
                    }
                }
                HStack { Button { model.wizardTemplateID = nil; model.showWizard = true } label: { Label("New Project", systemImage: "plus") }; Spacer() }.padding(8)
            }.frame(minWidth: 320)
            if let id = selected, let s = model.sessions.first(where: { $0.id == id }) {
                ProjectDetail(session: s).frame(minWidth: 460)
            } else {
                EmptyState(icon: "film", title: "Pick a project to see its status")
            }
        }
        .navigationTitle("Projects")
        .onAppear { if selected == nil { selected = model.sessions.first?.id } }
    }
}

struct ProjectDetail: View {
    @EnvironmentObject var model: AppModel
    let session: ProjectSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(session.name).font(.title2.bold()); StateBadge(state: session.state) }
                Label("\(session.templateName) v\(session.templateVersion)", systemImage: "square.grid.2x2").font(.caption).foregroundStyle(.secondary)
                    .help("Resolve edition: \(session.resolveEdition)\(session.resolveProjectName.map { " · Resolve project \($0)" } ?? "") · \(session.projectFolder)")
                HStack(spacing: 2) {
                    IconButton(symbol: "folder", label: "Open project folder") { NSWorkspace.shared.open(URL(fileURLWithPath: session.projectFolder)) }
                    if let c = session.checklistPath { IconButton(symbol: "checklist", label: "Open import checklist") { NSWorkspace.shared.open(URL(fileURLWithPath: c)) } }
                    IconButton(symbol: "play.rectangle", label: "Open in DaVinci Resolve") { model.openInResolve(session) }
                    if session.state != .ready {
                        Divider().frame(height: 18)
                        IconButton(symbol: "bolt.fill", label: model.resolveStatus?.canAutomate == true ? "Run in Resolve" : "Run in Resolve (needs Resolve Studio): \(model.resolveStatus?.message ?? "")", tint: Theme.accent) {
                            model.runResolveAutomation(for: session)
                        }.disabled(model.resolveStatus?.canAutomate != true)
                        IconButton(symbol: "checkmark.circle", label: "I imported it by hand") { model.markImportedManually(session) }
                    }
                }
                GroupBox("Sources") {
                    ForEach(session.sources) { s in
                        VStack(alignment: .leading) {
                            Text(s.label).bold()
                            Text("\(s.volume?.name ?? "?") [\(s.volume?.shortID ?? "?")] · \(s.path)").font(.caption).foregroundStyle(.secondary)
                            if let v = s.volume, Volumes.find(v) == nil { Text("Drive not connected: media will be offline in Resolve.").font(.caption).foregroundStyle(.orange) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if session.sources.isEmpty { Text("No media sources.").foregroundStyle(.secondary) }
                }
                GroupBox("Bin mapping") {
                    ForEach(session.mappings) { m in
                        HStack { Text(URL(fileURLWithPath: m.sourcePath).lastPathComponent); Image(systemName: "arrow.right"); Text(m.targetBin); Spacer(); Text(m.action.label).foregroundStyle(.secondary) }.font(.callout)
                    }
                }
                GroupBox("Action results") {
                    ForEach(session.receipts) { r in
                        HStack(alignment: .top) {
                            Image(systemName: icon(r.status)).foregroundStyle(color(r.status))
                            VStack(alignment: .leading) {
                                Text(r.step).bold()
                                Text([r.status, r.errorCode, r.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Text(r.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                }
                HStack {
                    Spacer()
                    Button("Remove Record…", role: .destructive) {
                        let a = NSAlert()
                        a.messageText = "Remove this project record from the app?"
                        a.informativeText = "Only the app's record is removed. The project folder, footage and any Resolve project stay as they are."
                        a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
                        if a.runModal() == .alertFirstButtonReturn { try? model.projects.delete(session.id); model.reload() }
                    }
                }
            }.padding(16)
        }
    }

    func icon(_ s: String) -> String { ["ok": "checkmark.circle.fill", "failed": "xmark.octagon.fill", "manual": "hand.raised.fill"][s] ?? "minus.circle" }
    func color(_ s: String) -> Color { ["ok": Color.green, "failed": .red, "manual": .orange][s] ?? .yellow }
}
