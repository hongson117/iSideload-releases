import Foundation
import SwiftUI

/// AltStore/SideStore-compatible source JSON (clean-room reader of the public format).
struct SourceApp: Identifiable, Hashable {
    var id: String { bundleIdentifier }
    let name: String, bundleIdentifier: String, developer: String, subtitle: String, icon: URL?
    let versions: [SourceVersion]
    var description: String = ""
    var latest: SourceVersion? { versions.first }
}
struct SourceVersion: Hashable { let version: String, date: String, notes: String, url: URL, size: Int }
struct AppSource: Identifiable, Hashable {
    var id: String { url }
    let url: String; var name: String; var apps: [SourceApp]; var error: String?
    var icon: URL? = nil
}
/// What the user added: the URL they typed (kept for display), the URL that actually served JSON, and an optional custom name.
struct SourceEntry: Codable, Hashable { var url: String; var resolved: String?; var customName: String? }

@MainActor final class SourceStore: ObservableObject {
    static let shared = SourceStore()
    @Published var sources: [AppSource] = []
    @Published var loading = false
    @AppStorage("sourceEntries") private var storedEntries = ""
    @AppStorage("sourceURLs") private var legacy = "[]"

    var entries: [SourceEntry] {
        get {
            if let e = try? JSONDecoder().decode([SourceEntry].self, from: Data(storedEntries.utf8)) { return e }
            let old = (try? JSONDecoder().decode([String].self, from: Data(legacy.utf8))) ?? []
            return old.map { SourceEntry(url: $0, resolved: $0) }
        }
        set { storedEntries = String(data: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
    }
    var urls: [String] { entries.map(\.url) }

    private var lastReload = Date.distantPast
    init() {
        // Show cached copies quickly (parsed off the main thread); network refresh happens on reload().
        let es = entries
        Task {
            let cached = await Task.detached { es.compactMap { e -> AppSource? in
                guard let d = try? Data(contentsOf: SourceStore.cacheFile(e.resolved ?? e.url)) else { return nil }
                return SourceStore.parse(d, url: e.url, customName: e.customName)
            } }.value
            if self.sources.isEmpty { self.sources = cached }
        }
    }
    func reloadIfStale() async {
        if Date().timeIntervalSince(lastReload) > 1800 || sources.isEmpty { await reload() }
    }

    /// Adds a source. Accepts a direct JSON URL or a website URL; returns the resolved JSON URL.
    @discardableResult
    func add(_ raw: String) async throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { throw CoreError(message: "Hãy nhập địa chỉ nguồn.") }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard URL(string: s)?.host != nil else { throw CoreError(message: "Địa chỉ không hợp lệ.") }
        if entries.contains(where: { $0.url == s || $0.resolved == s }) { throw CoreError(message: "Nguồn này đã có trong danh sách.") }
        let (resolved, data) = try await Self.resolve(s)
        if entries.contains(where: { $0.resolved == resolved }) { throw CoreError(message: "Nguồn này đã có (\(resolved)).") }
        try? data.write(to: Self.cacheFile(resolved))
        entries.append(SourceEntry(url: s, resolved: resolved))
        if let src = Self.parse(data, url: s, customName: nil) { sources.append(src) }
        return resolved
    }
    func remove(_ url: String) {
        if let e = entries.first(where: { $0.url == url }) { try? FileManager.default.removeItem(at: Self.cacheFile(e.resolved ?? e.url)) }
        entries.removeAll { $0.url == url }
        sources.removeAll { $0.url == url }
    }
    func rename(_ url: String, to name: String) {
        var e = entries
        guard let i = e.firstIndex(where: { $0.url == url }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        e[i].customName = n.isEmpty ? nil : n; entries = e
        if let j = sources.firstIndex(where: { $0.url == url }), !n.isEmpty { sources[j].name = n }
    }
    func move(from: IndexSet, to: Int) {
        var e = entries; e.move(fromOffsets: from, toOffset: to); entries = e
        let order = e.map(\.url)
        sources.sort { (order.firstIndex(of: $0.url) ?? 0) < (order.firstIndex(of: $1.url) ?? 0) }
    }
    func reload(only url: String? = nil) async {
        loading = true; defer { loading = false }
        if url == nil { lastReload = Date() }
        for e in entries where url == nil || e.url == url {
            let src = await Self.fetch(e)
            if let i = sources.firstIndex(where: { $0.url == e.url }) {
                if src.error == nil || sources[i].apps.isEmpty { sources[i] = src } else { sources[i].error = src.error }
            } else { sources.append(src) }
        }
        let order = entries.map(\.url)
        sources.removeAll { !order.contains($0.url) }
        sources.sort { (order.firstIndex(of: $0.url) ?? 0) < (order.firstIndex(of: $1.url) ?? 0) }
    }
    /// Installed app with an older version than the source's latest.
    func update(for app: SideloadedApp) -> (SourceApp, SourceVersion)? {
        for s in sources { if let a = s.apps.first(where: { $0.bundleIdentifier == app.bundleID || app.bundleID.hasPrefix($0.bundleIdentifier + ".") }),
                              let v = a.latest, Self.newer(v.version, than: app.version) { return (a, v) } }
        return nil
    }
    nonisolated static func newer(_ a: String, than b: String) -> Bool {
        guard !b.isEmpty else { return false }
        return a.compare(b, options: .numeric) == .orderedDescending
    }

    nonisolated static func cacheFile(_ url: String) -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let safe = String(url.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }).suffix(120)
        return d.appendingPathComponent(safe + ".json")
    }

    nonisolated static func get(_ u: URL) async throws -> Data {
        var r = URLRequest(url: u, timeoutInterval: 60)
        r.setValue("iSideload/1.0 (AltStore-compatible)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/json, text/html;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw CoreError(message: "HTTP \(h.statusCode)") }
        return d
    }
    nonisolated static func isSource(_ d: Data) -> Bool {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return j["apps"] is [Any]
    }

    /// Try the URL as-is, common source file names, then links found in an HTML page.
    nonisolated static func resolve(_ s: String) async throws -> (String, Data) {
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        var tried = [String](), firstHTML: (URL, String)?
        var candidates = [s]
        if !s.lowercased().hasSuffix(".json") {
            candidates += ["/source.json", "/apps.json", "/repo.json", "/altstore.json", "/altstore-source.json", "/sidestore.json"].map { base + $0 }
            candidates.append(s + (s.contains("?") ? "&" : "?") + "format=altstore")
        }
        for c in candidates {
            guard let u = URL(string: c), !tried.contains(c) else { continue }
            tried.append(c)
            guard let d = try? await get(u) else { continue }
            if isSource(d) { return (c, d) }
            if firstHTML == nil, let html = String(data: d, encoding: .utf8), html.lowercased().contains("<html") { firstHTML = (u, html) }
        }
        if let (pageURL, html) = firstHTML {
            for link in jsonLinks(in: html, base: pageURL) where !tried.contains(link.absoluteString) {
                tried.append(link.absoluteString)
                if let d = try? await get(link), isSource(d) { return (link.absoluteString, d) }
            }
        }
        throw CoreError(message: "Không tìm thấy nguồn AltStore/SideStore (JSON có \"apps\") ở địa chỉ này. Hãy dán đúng link nguồn mà trang web cung cấp (thường kết thúc bằng .json).")
    }
    nonisolated static func jsonLinks(in html: String, base: URL) -> [URL] {
        var out: [URL] = []
        let ns = html as NSString
        // href/src/data-url values plus altstore://source?url=… / sidestore deep links
        let re = try! NSRegularExpression(pattern: #"(?:href|src|data-url|value)\s*=\s*["']([^"']+)["']|(?:url|source)=(https?(?:%3A|:)[^"'&\s<]+)"#, options: .caseInsensitive)
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            for g in 1...2 where m.range(at: g).location != NSNotFound {
                var v = ns.substring(with: m.range(at: g)).replacingOccurrences(of: "&amp;", with: "&")
                if let dec = v.removingPercentEncoding, dec.hasPrefix("http") { v = dec }
                if v.lowercased().hasPrefix("altstore://") || v.lowercased().hasPrefix("sidestore://") || v.lowercased().hasPrefix("feather://"),
                   let q = URLComponents(string: v)?.queryItems?.first(where: { $0.name == "url" })?.value { v = q }
                let low = v.lowercased()
                guard low.contains(".json") || low.contains("source") || low.contains("altstore") || low.contains("repo") else { continue }
                if low.hasSuffix(".css") || low.hasSuffix(".js") || low.hasSuffix(".png") { continue }
                if let u = URL(string: v, relativeTo: base)?.absoluteURL, u.scheme?.hasPrefix("http") == true, !out.contains(u) { out.append(u) }
            }
        }
        return out.sorted { ($0.absoluteString.lowercased().contains(".json") ? 0 : 1) < ($1.absoluteString.lowercased().contains(".json") ? 0 : 1) }
    }

    nonisolated static func fetch(_ e: SourceEntry) async -> AppSource {
        let target = e.resolved ?? e.url
        do {
            let d: Data
            if let u = URL(string: target), let x = try? await get(u), isSource(x) { d = x }
            else { d = try await resolve(e.url).1 }
            try? d.write(to: cacheFile(target))
            return parse(d, url: e.url, customName: e.customName) ?? AppSource(url: e.url, name: e.customName ?? e.url, apps: [], error: "JSON không hợp lệ")
        } catch { return AppSource(url: e.url, name: e.customName ?? e.url, apps: [], error: error.localizedDescription) }
    }
    nonisolated static func parse(_ d: Data, url: String, customName: String?) -> AppSource? {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var seen = Set<String>()
        let apps = (j["apps"] as? [[String: Any]] ?? []).compactMap(parseApp).filter { seen.insert($0.bundleIdentifier + "|" + ($0.latest?.version ?? "") + "|" + $0.name).inserted }
        return AppSource(url: url, name: customName ?? (j["name"] as? String) ?? URL(string: url)?.host ?? url, apps: apps,
                         icon: (j["iconURL"] as? String).flatMap(URL.init(string:)))
    }
    nonisolated static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? Int(v as? String ?? "") ?? 0 }
    nonisolated static func parseApp(_ a: [String: Any]) -> SourceApp? {
        guard let bid = (a["bundleIdentifier"] as? String) ?? (a["bundleID"] as? String), !bid.isEmpty else { return nil }
        let name = (a["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bid
        var vs: [SourceVersion] = (a["versions"] as? [[String: Any]] ?? []).compactMap { v in
            guard let s = v["downloadURL"] as? String, let u = URL(string: s) else { return nil }
            return SourceVersion(version: v["version"] as? String ?? "", date: v["date"] as? String ?? "",
                                 notes: v["localizedDescription"] as? String ?? "", url: u, size: int(v["size"]))
        }
        if vs.isEmpty, let s = a["downloadURL"] as? String, let u = URL(string: s) {   // legacy flat format
            vs = [SourceVersion(version: a["version"] as? String ?? "", date: a["versionDate"] as? String ?? "",
                                notes: a["versionDescription"] as? String ?? "", url: u, size: int(a["size"]))]
        }
        guard !vs.isEmpty else { return nil }
        let icon = ((a["iconURL"] as? String) ?? (a["icon"] as? String)).flatMap(URL.init(string:))
        return SourceApp(name: name, bundleIdentifier: bid, developer: a["developerName"] as? String ?? "",
                         subtitle: a["subtitle"] as? String ?? "", icon: icon, versions: vs,
                         description: a["localizedDescription"] as? String ?? "")
    }

    nonisolated static func download(_ v: SourceVersion, name: String) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: v.url)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw CoreError(message: "Tải lỗi HTTP \(h.statusCode)") }
        let safe = name.filter { $0.isLetter || $0.isNumber }
        let dest = Engine.ipaDir.appendingPathComponent("\(safe)-\(v.version)-\(UUID().uuidString.prefix(6)).ipa")
        try? FileManager.default.createDirectory(at: Engine.ipaDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
