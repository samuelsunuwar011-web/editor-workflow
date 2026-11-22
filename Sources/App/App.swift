import SwiftUI
import AppKit

@main
struct EditorWorkflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // Runs in the background from the menu bar. The main window is an AppKit window (AppModel.openMainWindow)
        // so it can be opened any time; a SwiftUI Window scene that never appeared could not be reopened.
        Settings {
            SettingsView().environmentObject(model).frame(width: 640, height: 720)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Project…") { model.wizardTemplateID = nil; model.showWizard = true }.keyboardShortcut("n")
                Button("New Transfer") { model.selection = .transfers }.keyboardShortcut("t")
                Button("Import Template…") { model.selection = .templates; model.showImporter = true }.keyboardShortcut("i")
                Divider()
                Button("Show Menu Bar Panel") { model.showPanel(model.companion.tab) }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Open Panel in Window") { model.showPanelWindow() }
            }
            // Keyboard route to every page (the sidebar is otherwise mouse-only).
            CommandMenu("Go") {
                ForEach(Array(SidebarItem.allCases.filter { $0 != .settings }.enumerated()), id: \.element) { i, item in
                    Button(item.rawValue) { model.selection = item; model.openMainWindow() }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
            }
        }
        // The menu bar companion is an AppKit status item + popover (MenuBar.swift), not a SwiftUI MenuBarExtra.
    }
}

func percent(_ j: TransferJob) -> Int { j.totalBytes == 0 ? 0 : Int(Double(j.copiedBytes) / Double(j.totalBytes) * 100) }

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.selection) { item in
                // tag must be the outermost modifier, or the row can't be selected
                Label(item.rawValue, systemImage: item.icon)
                    .badge(item == .transfers ? model.activeJobs.count + model.queue.count : 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            if let j = model.activeJob {
                VStack(alignment: .leading, spacing: 4) {
                    Text(j.name).font(.caption).lineLimit(1)
                    ProgressView(value: Double(j.copiedBytes), total: Double(max(j.totalBytes, 1)))
                }
                .padding(10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Active transfer \(j.name), \(percent(j)) percent")
            }
        } detail: {
            switch model.selection ?? .home {
            case .home: HomeView()
            case .templates: TemplatesView()
            case .transfers: TransfersView()
            case .projects: ProjectsView()
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
        .sheet(isPresented: $model.showWizard) { ProjectWizard(initialTemplate: model.wizardTemplateID).environmentObject(model) }
        .alert("Something needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @Local private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Search templates", text: $search).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8).frame(width: 260, height: 30)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Button { model.selection = .transfers } label: { Label("Copy footage", systemImage: "sdcard") }.controlSize(.large)
                    Button { model.wizardTemplateID = nil; model.showWizard = true } label: { Label("New project", systemImage: "film.stack") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                ForEach(model.activeJobs) { JobProgressCard(job: $0) }
                if let draft = model.projects.draft, draft.templateID != nil {
                    Button { model.wizardTemplateID = nil; model.showWizard = true } label: {
                        Label("Continue \(draft.projectName.isEmpty ? "project setup" : draft.projectName) · step \(draft.step + 1)/5", systemImage: "arrow.uturn.forward.circle")
                    }.buttonStyle(.link)
                }
                let shown = search.isEmpty ? (model.orderedFavorites.isEmpty ? model.templateList : model.orderedFavorites) : model.templateList.filter { $0.matches(search) }
                header(search.isEmpty ? (model.orderedFavorites.isEmpty ? "Templates" : "Favorites") : "Results", search.isEmpty && !model.orderedFavorites.isEmpty ? "heart.fill" : "square.grid.2x2")
                if model.templateList.isEmpty { DrpDropZone() } else { TemplateGrid(templates: shown) }
                if !model.sessions.isEmpty || !model.recentPairs.isEmpty {
                    header("Recent", "clock")
                    VStack(spacing: 2) {
                        ForEach(model.recentPairs.prefix(3), id: \.self) { r in
                            row("arrow.left.arrow.right", "\(URL(fileURLWithPath: r.source).lastPathComponent) → \(URL(fileURLWithPath: r.destination).lastPathComponent)", r.used, help: "\(r.source) → \(r.destination)") {
                                IconButton(symbol: "arrow.clockwise", label: "Copy this way again", size: 12) { model.transferPreset = (r.source, r.destination); model.selection = .transfers }
                            }
                        }
                        ForEach(model.sessions.prefix(5)) { s in
                            row("film", s.name, s.created) {
                                StateBadge(state: s.state)
                                IconButton(symbol: "folder", label: "Open project folder", size: 12) { NSWorkspace.shared.open(URL(fileURLWithPath: s.projectFolder)) }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Home")
    }

    func header(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
    }

    func row<Trailing: View>(_ icon: String, _ text: String, _ date: Date, help: String? = nil, @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            Text(text).lineLimit(1)
            Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .help(help ?? text)
    }
}

/// An empty list says what is missing and offers the one action that fills it.
struct EmptyState: View {
    let icon: String
    let title: String
    var action: String? = nil
    var perform: () -> Void = {}
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
            if let action { Button(action, action: perform).buttonStyle(.borderedProminent).tint(Theme.accent) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Template {
    func matches(_ q: String) -> Bool {
        let k = q.collisionKey
        return k.isEmpty || name.collisionKey.contains(k) || category.collisionKey.contains(k) || tags.contains { $0.collisionKey.contains(k) }
    }
}

struct StateBadge: View {
    let state: SessionState
    var body: some View {
        Text(state.label)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
    var color: Color {
        switch state {
        case .ready: return .green
        case .manualStepRequired: return .orange
        case .partiallyCompleted: return .yellow
        case .failed: return .red
        case .draft: return .secondary
        }
    }
}
