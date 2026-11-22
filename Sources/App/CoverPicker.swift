import SwiftUI
import AppKit
import ImageIO
import WebKit
import UniformTypeIdentifiers

// Template covers (Folder Photo Feature Guide). Photos come from Unsplash (with the user's key) or Openverse (openly licensed).
// Pinterest opens in the user's own browser, where they are signed in; a photo is dragged or its link pasted back here.

/// Decoded, downsized covers kept in memory. Cover files are named by content, so an entry never goes stale.
enum CoverCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(_ url: URL) -> NSImage? {
        let key = url.path as NSString
        if let img = cache.object(forKey: key) { return img }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1200,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }
}

/// Templates whose photo is being looked up right now (their card shows a spinner instead of a bare letter).
@MainActor final class CoverActivity: ObservableObject {
    static let shared = CoverActivity()
    @Published var finding: Set<UUID> = []
}

extension AppModel {
    var coverStore: CoverStore { templates.covers }

    /// Templates imported before covers existed, or whose search failed last time, get another try at launch.
    func fillMissingCovers() {
        for t in templateList where t.cover == nil && t.thumbnailPath == nil { autoCover(t.id) }
    }

    /// Finds and stores a cover for a template that has none: Unsplash with the user's key, else Openverse.
    func autoCover(_ id: UUID) {
        guard let t = templates.get(id), t.cover == nil, t.thumbnailPath == nil, !CoverActivity.shared.finding.contains(id) else { return }
        let key = settings.unsplashKey ?? ""
        CoverActivity.shared.finding.insert(id)
        Task { @MainActor in
            defer { CoverActivity.shared.finding.remove(id) }
            var url: URL? = key.isEmpty ? nil : await CoverFinder.unsplash(t.name, key: key)
            if url == nil { url = await CoverFinder.openverse(t.name) }
            guard let url else { Log.info("no cover found", ["template": t.name]); return }
            let saved: String
            do { saved = try coverStore.save(try await CoverStore.download(url)) }
            catch { Log.info("cover download failed", ["url": url.absoluteString, "error": "\(error)"]); return }
            // The user may have chosen one meanwhile: only fill an empty cover.
            if templates.get(id)?.cover == nil { try? templates.setCover(id, value: CoverStore.value(saved)); reloadTemplates() }
        }
    }

    func setCover(_ id: UUID, from url: URL) async {
        do {
            let data = url.isFileURL ? try Data(contentsOf: url) : try await CoverStore.downloadImageOrPage(url)
            try templates.setCover(id, value: CoverStore.value(try coverStore.save(data)))
            reloadTemplates()
        } catch { report(error) }
    }

    /// A drop from Finder or a browser: a file or web address, else raw image data.
    func setCover(_ id: UUID, providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in await self.setCover(id, from: url) } } }
            return true
        }
        p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                do { try self.templates.setCover(id, value: CoverStore.value(try self.coverStore.save(data))); self.reloadTemplates() }
                catch { self.report(error) }
            }
        }
        return true
    }

    func openPinterest(_ query: String) {
        var c = URLComponents(string: "https://www.pinterest.com/search/pins/")!
        c.queryItems = [.init(name: "q", value: query)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }
}

/// A template's cover with its framing (falls back to an initial on a tinted card).
struct CoverImage: View {
    @EnvironmentObject var model: AppModel
    let template: Template
    var corner: CGFloat = 10
    var framingOverride: (Double, Double)? = nil
    @ObservedObject private var activity = CoverActivity.shared

    var body: some View {
        GeometryReader { geo in
            if let c = model.coverStore.parse(template.cover), let img = CoverCache.image(c.url) {
                framed(img, geo.size, framingOverride ?? (c.x, c.y))
            } else if let p = template.thumbnailPath, let img = CoverCache.image(URL(fileURLWithPath: p)) {
                framed(img, geo.size, (50, 50))
            } else {
                Theme.accent.opacity(0.18).overlay {
                    if activity.finding.contains(template.id) { ProgressView().controlSize(.small).help("Finding a photo…") }
                    else { Text(String(template.name.prefix(1)).uppercased()).font(Theme.number(min(geo.size.height * 0.45, 40))).foregroundStyle(Theme.accent) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .accessibilityHidden(true)
    }

    /// Fill the box; x,y (0–100) choose which part of the overflow is visible, like CSS object-position.
    func framed(_ img: NSImage, _ box: CGSize, _ f: (Double, Double)) -> some View {
        let s = img.size.width > 0 && img.size.height > 0 ? max(box.width / img.size.width, box.height / img.size.height) : 1
        let w = img.size.width * s, h = img.size.height * s
        return Image(nsImage: img).resizable().frame(width: w, height: h)
            .offset(x: (box.width - w) * (f.0 / 100) + (w - box.width) / 2, y: (box.height - h) * (f.1 / 100) + (h - box.height) / 2)
            .frame(width: box.width, height: box.height)
    }
}

/// Editable cover: click to choose a photo, drag to frame it, drop an image on it.
struct CoverBox: View {
    @EnvironmentObject var model: AppModel
    let template: Template
    var height: CGFloat = 150
    @Local private var drag: (Double, Double)?
    @Local private var start: (Double, Double)?
    @Local private var targeted = false
    @Local private var picking = false

    var body: some View {
        let current = model.coverStore.parse(template.cover)
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(template: template, corner: 12, framingOverride: drag)
                .frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Theme.accent : .clear, lineWidth: 2))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        guard let c = current else { return }
                        let s = start ?? (c.x, c.y); start = s
                        // Moving the photo right shows more of its left side.
                        drag = (min(100, max(0, s.0 - Double(g.translation.width) / 3)), min(100, max(0, s.1 - Double(g.translation.height) / 3)))
                    }
                    .onEnded { _ in
                        if let d = drag, let c = current { try? model.templates.setCover(template.id, value: CoverStore.value(c.url.lastPathComponent, x: d.0, y: d.1)); model.reloadTemplates() }
                        drag = nil; start = nil
                    })
                .onTapGesture { picking = true }
                .onDrop(of: [.fileURL, .url, .image], isTargeted: $targeted) { model.setCover(template.id, providers: $0) }
                .help(current == nil ? "Click to choose a photo" : "Click to change · drag to reframe")
                .accessibilityElement()
                .accessibilityLabel("Cover photo")
                .accessibilityAction(named: "Choose a photo") { picking = true }
            HStack(spacing: 6) {
                Button { picking = true } label: { Label(template.cover == nil ? "Add photo" : "Change photo", systemImage: "photo.on.rectangle.angled") }
                    .controlSize(.small)
                if template.cover != nil {
                    IconButton(symbol: "trash", label: "Remove photo", tint: .secondary, size: 12) { try? model.templates.setCover(template.id, value: nil); model.reloadTemplates() }
                }
            }
        }
        .sheet(isPresented: $picking) { PhotoPicker(templateID: template.id, initialQuery: template.name).environmentObject(model) }
    }
}

/// Photo grid for a cover: Pinterest is the default (real event photos), Photos searches openly licensed images.
/// Also: a file, a pasted link, or a photo dragged in.
struct PhotoPicker: View {
    enum Source: String, CaseIterable { case pinterest = "Pinterest", photos = "Photos" }

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let templateID: UUID
    let initialQuery: String
    @Local private var query = ""
    @Local private var photos: [CoverFinder.Photo] = []
    @Local private var searching = false
    @Local private var searched = false
    @Local private var choosing: String?
    @Local private var link = ""
    @Local private var targeted = false
    @Local private var source: Source = .pinterest
    @Local private var pinterestLoading = true
    @Local private var pinterestFailure: String?
    /// The term Pinterest is actually showing. Typing does not reload it; Enter or the search icon does.
    @Local private var applied = ""
    @Local private var attempt = 0

    /// The word sent to Pinterest and to the photo search: the event, not the template's working title.
    var term: String {
        let t = CoverFinder.searchTerm(query)
        return t.isEmpty ? query.trimmingCharacters(in: .whitespaces) : t
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Button(action: submit) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Search")
                    .accessibilityLabel("Search")
                    TextField("Search photos", text: $query).textFieldStyle(.plain).onSubmit { submit() }
                    if searching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 168)
                .help("Pinterest: real photos, sign in once. Photos: openly licensed images.")
                .onChange(of: source) { _, s in if s == .photos { Task { await run() } } }
                Button(action: chooseFile) { Label("File…", systemImage: "folder") }
            }
            .padding(14)
            Divider()
            if source == .pinterest {
                ZStack(alignment: .top) {
                    PinterestBrowser(query: applied, loading: $pinterestLoading,
                                     onPick: { url in Task { await model.setCover(templateID, from: url); dismiss() } },
                                     onClose: { dismiss() },
                                     onFail: { pinterestFailure = $0 })
                        .id("\(applied)#\(attempt)")
                    if let failure = pinterestFailure {
                        VStack(spacing: 8) {
                            Label("Pinterest did not load", systemImage: "wifi.exclamationmark").font(.headline)
                            Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Button("Try Again") { pinterestFailure = nil; pinterestLoading = true; attempt += 1 }
                                Button("Open in Browser") {
                                    var c = URLComponents(string: "https://www.pinterest.com/search/pins/")!
                                    c.queryItems = [.init(name: "q", value: term)]
                                    if let u = c.url { NSWorkspace.shared.open(u) }
                                }
                            }
                        }
                        .padding(18).frame(maxWidth: 420)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 60)
                    }
                    if pinterestLoading && pinterestFailure == nil {
                        ProgressView("Loading Pinterest…").controlSize(.small).padding(.top, 14)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Hold or double-click a photo to use it. Search is “\(applied)”.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
            } else {
                ScrollView {
                    if photos.isEmpty && searched && !searching {
                        Text("No photos found for “\(term)”. Try another word, or switch to Pinterest.").foregroundStyle(.secondary).padding(40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(photos) { p in
                            Button { choose(p) } label: {
                                VStack(spacing: 4) {
                                    Color.secondary.opacity(0.1)
                                        .frame(height: 104)
                                        .overlay {
                                            AsyncImage(url: p.thumb) { $0.resizable().scaledToFill() } placeholder: { ProgressView().controlSize(.small) }
                                        }
                                        .overlay { if choosing == p.id { Color.black.opacity(0.4); ProgressView() } }
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .contentShape(RoundedRectangle(cornerRadius: 8))
                                    // Unsplash and Openverse ask for visible attribution, not only a tooltip.
                                    Text(p.credit).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(choosing != nil)
                            .help("Photo by \(p.credit)")
                            .accessibilityLabel("Photo by \(p.credit)")
                        }
                    }
                    .padding(14)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Paste an image or Pinterest link", text: $link).textFieldStyle(.roundedBorder).onSubmit(useLink)
                Button("Use", action: useLink).disabled(URL(string: link.trimmingCharacters(in: .whitespaces))?.scheme != "https")
                Spacer(minLength: 20)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 760, height: 660)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? Theme.accent : .clear, lineWidth: 3))
        .onDrop(of: [.fileURL, .url, .image], isTargeted: $targeted) { providers in
            let ok = model.setCover(templateID, providers: providers)
            if ok { dismiss() }
            return ok
        }
        .task {
            query = initialQuery
            applied = term
            if source == .photos { await run() }
        }
    }

    func submit() {
        applied = term
        pinterestFailure = nil
        pinterestLoading = true
        if source == .photos { Task { await run() } }
    }

    func run() async {
        searching = true
        photos = await CoverFinder.search(term, unsplashKey: model.settings.unsplashKey)
        searching = false; searched = true
    }

    func choose(_ p: CoverFinder.Photo) {
        choosing = p.id
        Task { await model.setCover(templateID, from: p.full); choosing = nil; dismiss() }
    }

    func useLink() {
        guard let u = URL(string: link.trimmingCharacters(in: .whitespaces)), u.scheme == "https" else { return }
        Task { await model.setCover(templateID, from: u); dismiss() }
    }

    func chooseFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url { Task { await model.setCover(templateID, from: u); dismiss() } }
    }
}


/// Pinterest inside the cover picker (Folder Photo Feature Guide): press and hold a photo for half a second,
/// or double-click it, to use it. Uses the app's persistent web storage, so you sign in to Pinterest once.
/// Personal use: reading Pinterest may break its terms.
struct PinterestBrowser: NSViewRepresentable {
    let query: String
    @Binding var loading: Bool
    let onPick: (URL) -> Void
    let onClose: () -> Void
    let onFail: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        // A plain Safari identity: Pinterest shows a blank page to browsers it does not recognise.
        cfg.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "photoChosen")
        ucc.addUserScript(WKUserScript(source: Self.pickScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController = ucc
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        context.coordinator.loadedQuery = query
        web.load(URLRequest(url: Self.searchURL(query)))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedQuery != query else { return }
        context.coordinator.loadedQuery = query
        web.load(URLRequest(url: Self.searchURL(query)))
    }

    static func searchURL(_ q: String) -> URL {
        var c = URLComponents(string: "https://www.pinterest.com/search/pins/")!
        c.queryItems = [.init(name: "q", value: q)]
        return c.url!
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let parent: PinterestBrowser
        var loadedQuery: String = ""
        init(parent: PinterestBrowser) { self.parent = parent }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let s = message.body as? String else { return }
            if s == "close" { parent.onClose(); return }
            if let u = URL(string: s), u.scheme == "https" { parent.onPick(u) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.info("pinterest load failed", ["error": error.localizedDescription])
            parent.loading = false
            parent.onFail(error.localizedDescription)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Log.info("pinterest load failed", ["error": error.localizedDescription])
            parent.loading = false
            parent.onFail(error.localizedDescription)
        }

        /// Google and Apple sign-in refuse embedded web views: those open in the real browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let host = action.request.url?.host, host.contains("accounts.google.") || host.contains("appleid.apple.") {
                if let u = action.request.url { NSWorkspace.shared.open(u) }
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
    }

    /// Hold 450 ms (8 px move tolerance) or double-click on any photo; the sharpest size in its srcset is sent back.
    static let pickScript = """
    (() => {
      const HOLD = 450;
      let timer = null, start = null, img = null;
      const photoAt = (x, y) => document.elementsFromPoint(x, y).find(n => n.tagName === 'IMG' && n.getBoundingClientRect().width >= 80);
      const best = (n) => {
        const s = (n.srcset || '').split(',').map(x => x.trim().split(/\\s+/)[0]).filter(Boolean);
        return s.find(u => /\\/originals\\//.test(u)) || s.find(u => /\\/736x\\//.test(u)) || s[s.length - 1] || n.currentSrc || n.src;
      };
      const send = (n) => { window.webkit.messageHandlers.photoChosen.postMessage(best(n)); };
      const reset = () => { clearTimeout(timer); timer = null; if (img) img.style.transform = ''; img = null; start = null; };
      addEventListener('pointerdown', (e) => {
        const n = photoAt(e.clientX, e.clientY); if (!n) return;
        img = n; start = [e.clientX, e.clientY];
        n.style.transition = 'transform ' + HOLD + 'ms ease-out'; n.style.transform = 'scale(.95)';
        timer = setTimeout(() => { const t = img; reset(); if (t) send(t); }, HOLD);
      }, true);
      addEventListener('pointermove', (e) => { if (start && Math.hypot(e.clientX - start[0], e.clientY - start[1]) > 8) reset(); }, true);
      addEventListener('pointerup', () => { if (timer) reset(); }, true);
      addEventListener('scroll', reset, true);
      addEventListener('dblclick', (e) => { const n = photoAt(e.clientX, e.clientY); if (n) { e.preventDefault(); e.stopPropagation(); send(n); } }, true);
      // A hold opens the pin otherwise: swallow the click that ends a hold.
      addEventListener('click', (e) => { if (photoAt(e.clientX, e.clientY) && e.detail > 1) { e.preventDefault(); e.stopPropagation(); } }, true);
      addEventListener('contextmenu', (e) => { if (photoAt(e.clientX, e.clientY)) e.preventDefault(); }, true);
      addEventListener('keydown', (e) => { if (e.key === 'Escape') window.webkit.messageHandlers.photoChosen.postMessage('close'); });
      const tip = document.createElement('div');
      tip.textContent = 'Hold or double-click a photo to use it. Esc closes.';
      tip.style.cssText = 'position:fixed;bottom:16px;left:50%;transform:translateX(-50%);z-index:2147483647;background:rgba(20,20,20,.85);color:#f2f2f2;font:13px -apple-system;padding:8px 14px;border-radius:18px;pointer-events:none';
      document.documentElement.appendChild(tip);
    })();
    """
}
