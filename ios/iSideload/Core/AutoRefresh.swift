import AppIntents
import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// Daily re-sign. iOS gives no guaranteed background installs, so three triggers share one
/// routine: a BGAppRefreshTask (best effort), the URL isideload://refresh, and App Intents
/// for a Shortcuts personal automation. Other apps are refreshed first, iSideload last,
/// because replacing itself terminates the process.
enum AutoRefresh {
    static let taskID = "com.hongson117.isideload.refresh"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "autoRefresh") }
    static var thresholdDays: Int { max(0, UserDefaults.standard.object(forKey: "refreshDays") as? Int ?? 6) }
    static var lastRun: Date? { UserDefaults.standard.object(forKey: "lastRefresh") as? Date }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            schedule()
            let work = Task { @MainActor in
                let ok = await Engine.shared.refreshAll(includeSelf: false, onlyDue: true, background: true)
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        guard enabled else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID); return }
        let r = BGAppRefreshTaskRequest(identifier: taskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        try? BGTaskScheduler.shared.submit(r)
    }

    static func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

struct RefreshSelfIntent: AppIntent {
    static var title: LocalizedStringResource = "Ký lại iSideload"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        _ = await Engine.shared.refreshAll(includeSelf: true, onlyDue: false, background: false, onlySelf: true)
        return .result()
    }
}

struct RefreshAllIntent: AppIntent {
    static var title: LocalizedStringResource = "Ký lại tất cả app"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        _ = await Engine.shared.refreshAll(includeSelf: true, onlyDue: false, background: false)
        return .result()
    }
}

struct ISLShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RefreshAllIntent(), phrases: ["Ký lại tất cả app bằng \(.applicationName)"],
                    shortTitle: "Ký lại tất cả app", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: RefreshSelfIntent(), phrases: ["Ký lại \(.applicationName)"],
                    shortTitle: "Ký lại iSideload", systemImageName: "iphone.and.arrow.forward")
    }
}

/// LiveContainer: download the official release IPA, sign and install it like any other app.
enum LiveContainer {
    static let bundlePrefix = "com.kdt.livecontainer"
    static let api = URL(string: "https://api.github.com/repos/LiveContainer/LiveContainer/releases/latest")!

    struct Release { let version: String; let url: URL }

    static func latest() async throws -> Release {
        var req = URLRequest(url: api); req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (d, _) = try await URLSession.shared.data(for: req)
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
        let tag = (j["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let assets = j["assets"] as? [[String: Any]] ?? []
        guard let a = assets.first(where: { ($0["name"] as? String) == "LiveContainer.ipa" })
                ?? assets.first(where: { ($0["name"] as? String ?? "").hasSuffix(".ipa") }),
              let s = a["browser_download_url"] as? String, let u = URL(string: s) else {
            throw CoreError(message: "Không tìm thấy LiveContainer.ipa trong bản phát hành mới nhất.")
        }
        return Release(version: tag, url: u)
    }

    static func download(_ r: Release, into dir: URL) async throws -> URL {
        let (tmp, _) = try await URLSession.shared.download(from: r.url)
        let dest = dir.appendingPathComponent("LiveContainer-\(r.version).ipa")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Hands a remote IPA link to LiveContainer instead of using a free-account app slot.
    static func openInLiveContainer(_ ipaURL: URL) {
        var c = URLComponents(); c.scheme = "livecontainer"; c.host = "install"
        c.queryItems = [URLQueryItem(name: "url", value: ipaURL.absoluteString)]
        if let u = c.url { UIApplication.shared.open(u) }
    }
}
