import SwiftUI
import UIKit

/// Per-bundle icon cache: PNGs pulled from IPAs (may be CgBI — UIImage decodes those) + remembered source icon URLs.
enum IconCache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var tried = Set<String>()
    private static var mem = [String: UIImage]()

    static func file(_ bid: String) -> URL { dir.appendingPathComponent(bid + ".png") }

    static func image(_ bid: String) -> UIImage? {
        if let i = mem[bid] { return i }
        guard let d = try? Data(contentsOf: file(bid)), let i = UIImage(data: d) else { return nil }
        mem[bid] = i; return i
    }

    static func adopt(_ tmp: URL, for bid: String) {
        guard !bid.isEmpty, let d = try? Data(contentsOf: tmp), let img = UIImage(data: d) else { try? FileManager.default.removeItem(at: tmp); return }
        // Re-encode so the cached file is a standard PNG (un-crushes CgBI).
        try? (img.pngData() ?? d).write(to: file(bid))
        try? FileManager.default.removeItem(at: tmp)
        mem[bid] = img
    }

    static func remember(_ url: URL, for bid: String) {
        var m = UserDefaults.standard.dictionary(forKey: "iconURLs") as? [String: String] ?? [:]
        m[bid] = url.absoluteString; UserDefaults.standard.set(m, forKey: "iconURLs")
    }

    /// Remote fallback: remembered URL, or any loaded source app whose bundle ID prefixes this one.
    @MainActor static func remote(_ bid: String) -> URL? {
        let m = UserDefaults.standard.dictionary(forKey: "iconURLs") as? [String: String] ?? [:]
        if let s = m.first(where: { bid == $0.key || bid.hasPrefix($0.key + ".") })?.value { return URL(string: s) }
        for src in SourceStore.shared.sources {
            if let a = src.apps.first(where: { bid == $0.bundleIdentifier || bid.hasPrefix($0.bundleIdentifier + ".") }), let u = a.icon { return u }
        }
        return nil
    }
}

struct AppIconView: View {
    var bundleID: String
    var name: String
    var remote: URL? = nil
    var size: CGFloat = 46

    var body: some View {
        Group {
            if let img = IconCache.image(bundleID) {
                Image(uiImage: img).resizable()
            } else if let u = remote ?? IconCache.remote(bundleID) {
                AsyncImage(url: u) { ph in
                    if let i = ph.image { i.resizable() } else { letter }
                }
            } else { letter }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }

    var letter: some View {
        let c = Theme.color(for: bundleID)
        return Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [c, c.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }
}
