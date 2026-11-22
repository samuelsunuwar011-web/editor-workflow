import Foundation

/// Local-only metrics from the spec (p.18). Computed from the app's own records; nothing leaves the Mac.
struct LocalMetrics {
    struct Row: Hashable { var label: String; var value: String }

    var transfers: [Row] = []
    var projects: [Row] = []
    var templates: [Row] = []

    static func compute(jobs: [TransferJob], items: [TransferItem], sessions: [ProjectSession], templates: [Template]) -> LocalMetrics {
        var m = LocalMetrics()
        let finished = jobs.filter { $0.finished != nil && $0.started != nil }
        let verified = jobs.filter { $0.status == .verified }
        let mismatches = items.filter { $0.message?.hasPrefix("Checksum mismatch") == true }.count
        let failedItems = items.filter { $0.state == .failed }.count
        let resumed = jobs.filter { j in j.warnings.contains { $0.contains("closed while copying") || $0.contains("disconnected") } }
        m.transfers = [
            Row(label: "Transfers", value: "\(jobs.count) (\(verified.count) verified, \(jobs.filter { $0.status == .partiallyVerified }.count) partial, \(jobs.filter { $0.status == .failed }.count) failed)"),
            Row(label: "Median time from start to verified", value: median(verified.compactMap { j in j.finished.map { $0.timeIntervalSince(j.started ?? j.created) } }).map(duration) ?? "—"),
            Row(label: "Average measured throughput", value: average(finished.compactMap { j -> Double? in
                let t = j.finished!.timeIntervalSince(j.started!); return t > 0 ? Double(j.copiedBytes) / t : nil
            }).map { Int64($0).bytesText + "/s" } ?? "—"),
            Row(label: "Checksum mismatches", value: "\(mismatches) of \(items.count) files"),
            Row(label: "Failed files", value: "\(failedItems)"),
            Row(label: "Interrupted jobs (disconnect or app closed)", value: "\(resumed.count), \(resumed.filter { $0.status == .verified }.count) recovered to verified"),
        ]

        func manualShare(_ s: [ProjectSession]) -> String {
            guard !s.isEmpty else { return "—" }
            let manual = s.filter { $0.receipts.contains { $0.status == "manual" } || $0.state == .manualStepRequired }.count
            return "\(manual) of \(s.count) (\(Int(Double(manual) / Double(s.count) * 100))%)"
        }
        let studio = sessions.filter { $0.resolveEdition == ResolveEdition.studio.rawValue }
        let other = sessions.filter { $0.resolveEdition != ResolveEdition.studio.rawValue }
        let receipts = sessions.flatMap(\.receipts)
        let importOK = receipts.filter { $0.capability == "canImportMedia" && $0.status == "ok" }.count
        let importBad = receipts.filter { $0.capability == "canImportMedia" && $0.status == "failed" }.count
        m.projects = [
            Row(label: "Projects created", value: "\(sessions.count)"),
            Row(label: "States", value: Dictionary(grouping: sessions, by: \.state).map { "\($0.key.label): \($0.value.count)" }.sorted().joined(separator: " · ").ifEmpty("—")),
            Row(label: "Median time in wizard (template to project)", value: median(sessions.compactMap(\.wizardSeconds)).map(duration) ?? "—"),
            Row(label: "Median fields changed per run", value: median(sessions.compactMap { $0.wizardEdits.map(Double.init) }).map { String(Int($0)) } ?? "—"),
            Row(label: "Needed a manual Resolve step: Studio", value: manualShare(studio)),
            Row(label: "Needed a manual Resolve step: Free / unknown", value: manualShare(other)),
            Row(label: "Bin imports", value: "\(importOK) succeeded, \(importBad) failed"),
        ]

        let uses = Dictionary(grouping: sessions, by: \.templateID).mapValues(\.count)
        let top = templates.sorted { (uses[$0.id] ?? 0) > (uses[$1.id] ?? 0) }.prefix(3).map { "\($0.name) ×\(uses[$0.id] ?? 0)" }
        let missing = templates.flatMap { $0.current.assets }.filter { $0.status == .knownMissing }.count
        m.templates = [
            Row(label: "Templates", value: "\(templates.count), reused in \(sessions.count) project(s)"),
            Row(label: "Most used", value: top.joined(separator: " · ").ifEmpty("—")),
            Row(label: "Known missing dependencies", value: "\(missing)"),
        ]
        return m
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
    static func average(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    static func duration(_ t: Double) -> String {
        let f = DateComponentsFormatter(); f.allowedUnits = t >= 3600 ? [.hour, .minute] : [.minute, .second]; f.unitsStyle = .abbreviated
        return f.string(from: t) ?? "\(Int(t)) s"
    }
}

extension String { func ifEmpty(_ s: String) -> String { isEmpty ? s : self } }
