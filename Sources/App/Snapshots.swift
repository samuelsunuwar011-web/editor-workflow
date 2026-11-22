import SwiftUI
import AppKit

/// `EditorWorkflow --snapshot <folder>`: draws every main screen into PNG files and quits.
/// For design review without driving the real window. Reads the library; never copies, imports or writes app data.
@MainActor
enum Snapshots {
    static func run(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let model = AppModel.shared
        model.reload()
        Task { @MainActor in
            let main = NSSize(width: 1120, height: 760)
            for (i, item) in SidebarItem.allCases.enumerated() {
                model.selection = item
                await shot(ContentView().environmentObject(model), main, dir, String(format: "%02d-%@", i + 1, item.rawValue.lowercased()))
            }
            if let t = model.templateList.first(where: { $0.cover != nil }) ?? model.templateList.first {
                for (tab, name) in [(0, "bins"), (1, "assets"), (2, "settings"), (5, "test-run")] {
                    await shot(TemplateDetailView(templateID: t.id, initialTab: tab).environmentObject(model), NSSize(width: 860, height: 640), dir, "10-template-\(name)")
                }
                await shot(PhotoPicker(templateID: t.id, initialQuery: t.name).environmentObject(model), NSSize(width: 700, height: 540), dir, "11-photo-picker", wait: 7)
            }
            await shot(WelcomeView {}.environmentObject(model), NSSize(width: 520, height: 520), dir, "30-welcome")
            let dropping = PanelState(); dropping.dropMode = true
            await shot(CompanionPanel(panel: dropping).environmentObject(model), nil, dir, "21-panel-drop")
            for (tab, name) in [(CompanionTab.transfer, "copy"), (.favorites, "favorites"), (.create, "create")] {
                model.companion.tab = tab
                await shot(CompanionPanel(panel: PanelState()).environmentObject(model), nil, dir, "20-panel-\(name)")
            }
            exit(0)
        }
    }

    /// size nil: the view's own fitting size (the panel sizes to its content).
    static func shot<V: View>(_ view: V, _ size: NSSize?, _ dir: URL, _ name: String, wait: Double = 1.5) async {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size ?? NSSize(width: 720, height: 600))
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))   // off-screen: never shown to the user
        w.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        if size == nil { host.setFrameSize(host.fittingSize); w.setContentSize(host.fittingSize) }
        host.layoutSubtreeIfNeeded()
        host.display()
        // 1x pixels: small files that are quick to review.
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        }
        w.orderOut(nil)
        w.contentView = nil
    }
}
