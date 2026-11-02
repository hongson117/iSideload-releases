import Foundation
import SwiftUI

/// AltStore/SideStore-compatible source JSON (clean-room reader of the public format).
struct SourceApp: Identifiable, Hashable {
    var id: String { bundleIdentifier }
    let name: String, bundleIdentifier: String, developer: String, subtitle: String, icon: URL?
    let versions: [SourceVersion]
    var latest: SourceVersion? { versions.first }
}
struct SourceVersion: Hashable { let version: String, date: String, notes: String, url: URL, size: Int }
struct AppSource: Identifiable, Hashable { var id: String { url }; let url: String; var name: String; var apps: [SourceApp]; var error: String? }

@MainActor final class SourceStore: ObservableObject {
    static let shared = SourceStore()
    @Published var sources: [AppSource] = []
    @AppStorage("sourceURLs") private var stored = "[]"
    var urls: [String] { (try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? [] }

    func add(_ raw: String) async {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard URL(string: s) != nil, !urls.contains(s) else { return }
        stored = String(data: try! JSONEncoder().encode(urls + [s]), encoding: .utf8)!
        await reload()
    }
    func remove(_ url: String) {
        stored = String(data: try! JSONEncoder().encode(urls.filter { $0 != url }), encoding: .utf8)!
        sources.removeAll { $0.url == url }
    }
    func reload() async {
        var out: [AppSource] = []
        for u in urls { out.append(await Self.fetch(u)) }
        sources = out
    }
    /// Installed app with an older version than the source's latest.
    func update(for app: SideloadedApp) -> (SourceApp, SourceVersion)? {
        for s in sources { if let a = s.apps.first(where: { $0.bundleIdentifier == app.bundleID || app.bundleID.hasPrefix($0.bundleIdentifier + ".") }),
                              let v = a.latest, Self.newer(v.version, than: app.version) { return (a, v) } }
        return nil
    }
    static func newer(_ a: String, than b: String) -> Bool {
        guard !b.isEmpty else { return false }
        return a.compare(b, options: .numeric) == .orderedDescending
    }

    static func fetch(_ u: String) async -> AppSource {
        do {
            let (d, _) = try await URLSession.shared.data(from: URL(string: u)!)
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw CoreError(message: "JSON không hợp lệ") }
            let apps = (j["apps"] as? [[String: Any]] ?? []).compactMap(parseApp)
            return AppSource(url: u, name: j["name"] as? String ?? u, apps: apps)
        } catch { return AppSource(url: u, name: u, apps: [], error: error.localizedDescription) }
    }
    static func parseApp(_ a: [String: Any]) -> SourceApp? {
        guard let name = a["name"] as? String, let bid = a["bundleIdentifier"] as? String else { return nil }
        var vs: [SourceVersion] = (a["versions"] as? [[String: Any]] ?? []).compactMap { v in
            guard let s = v["downloadURL"] as? String, let u = URL(string: s) else { return nil }
            return SourceVersion(version: v["version"] as? String ?? "", date: v["date"] as? String ?? "",
                                 notes: v["localizedDescription"] as? String ?? "", url: u, size: v["size"] as? Int ?? 0)
        }
        if vs.isEmpty, let s = a["downloadURL"] as? String, let u = URL(string: s) {   // legacy flat format
            vs = [SourceVersion(version: a["version"] as? String ?? "", date: a["versionDate"] as? String ?? "",
                                notes: a["versionDescription"] as? String ?? "", url: u, size: a["size"] as? Int ?? 0)]
        }
        return SourceApp(name: name, bundleIdentifier: bid, developer: a["developerName"] as? String ?? "",
                         subtitle: a["subtitle"] as? String ?? "", icon: (a["iconURL"] as? String).flatMap(URL.init(string:)), versions: vs)
    }

    static func download(_ v: SourceVersion, name: String) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: v.url)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw CoreError(message: "Tải lỗi HTTP \(h.statusCode)") }
        let safe = name.filter { $0.isLetter || $0.isNumber }
        let dest = Engine.ipaDir.appendingPathComponent("\(safe)-\(v.version)-\(UUID().uuidString.prefix(6)).ipa")
        try? FileManager.default.createDirectory(at: Engine.ipaDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
