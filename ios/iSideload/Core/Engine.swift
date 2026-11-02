import Foundation
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()
    @AppStorage("appleID") var appleID = ""
    @AppStorage("anisetteURL") var anisetteURL = ""
    @AppStorage("vpnTarget") var vpnTarget = ""
    @Published var signedIn = false
    @Published var teamName = ""
    @Published var apps: [SideloadedApp] = []
    @Published var deviceLine = ""
    @Published var busy = false
    @Published var stage = ""
    @Published var progress: Double = 0
    @Published var prompt: CorePrompt?
    @Published var errorText: String?
    @Published var infoText: String?
    @Published var pendingIPA: URL?

    nonisolated(unsafe) private var answer: String?
    private let answered = DispatchSemaphore(value: 0)

    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let storage = docs.appendingPathComponent("Storage", isDirectory: true)
    static let ipaDir = docs.appendingPathComponent("IPAs", isDirectory: true)
    static let pairingURL = storage.appendingPathComponent("pairing.plist")
    private static let appsURL = storage.appendingPathComponent("apps.json")

    init() {
        for d in [Self.storage, Self.ipaDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        if let d = try? Data(contentsOf: Self.appsURL), let a = try? JSONDecoder().decode([SideloadedApp].self, from: d) { apps = a }
        signedIn = !appleID.isEmpty && Keychain.load(appleID) != nil
    }

    var hasPairing: Bool { FileManager.default.fileExists(atPath: Self.pairingURL.path) }
    var vpnActive: Bool { LoopbackVPN.isActive(target: vpnTarget.isEmpty ? LoopbackVPN.defaultTarget : vpnTarget) }

    private func save() { if let d = try? JSONEncoder().encode(apps) { try? d.write(to: Self.appsURL) }; AutoRefresh.scheduleExpiryReminders(apps) }

    private func base(_ op: String) -> [String: Any] {
        ["op": op, "apple_id": appleID, "password": Keychain.load(appleID) ?? "", "anisette_url": anisetteURL,
         "storage_dir": Self.storage.path, "pairing_path": Self.pairingURL.path, "target": vpnTarget,
         "license": LicenseManager.shared.license ?? "",
         "device_id": LicenseManager.deviceID,
         "build_sha": Bundle.main.infoDictionary?["ISLGitSHA"] as? String ?? ""]
    }

    // Prompt plumbing: the core thread blocks until the sheet answers.
    nonisolated private func ask(_ p: CorePrompt) -> String? {
        DispatchQueue.main.async { self.prompt = p }
        answered.wait()
        return answer
    }
    func answerPrompt(_ a: String?) { answer = a; prompt = nil; answered.signal() }

    private func run(_ req: [String: Any]) async throws -> [String: Any] {
        busy = true; stage = ""; progress = 0
        defer { busy = false }
        let r = await CoreCall.runAsync(req, onEvent: { s, p in
            DispatchQueue.main.async { self.stage = s; self.progress = p }
        }, onPrompt: { [weak self] p in self?.ask(p) })
        return try r.checked()
    }

    private func guarded(_ work: () async throws -> Void) async {
        do { try await work() } catch { errorText = error.localizedDescription }
    }

    // MARK: Account
    func signIn(email: String, password: String) async {
        appleID = email.trimmingCharacters(in: .whitespaces)
        Keychain.save(password, for: appleID)
        await guarded {
            do {
                let r = try await run(base("sign_in"))
                teamName = r["team_name"] as? String ?? (r["team"] as? String ?? "")
                signedIn = true
            } catch { Keychain.delete(appleID); signedIn = false; throw error }
        }
    }
    func signOut() { Keychain.delete(appleID); signedIn = false; teamName = "" }

    // MARK: Pairing / device
    func importPairing(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  obj["HostPrivateKey"] != nil || obj["DeviceCertificate"] != nil else {
                throw CoreError(message: "Đây không phải file ghép nối hợp lệ (thiếu HostPrivateKey/DeviceCertificate).")
            }
            try? FileManager.default.removeItem(at: Self.pairingURL)
            try data.write(to: Self.pairingURL)
            infoText = "Đã nhập file ghép nối."
            objectWillChange.send()
        } catch { errorText = error.localizedDescription }
    }

    func checkDevice() async {
        await guarded {
            let r = try await run(base("device"))
            deviceLine = "\(r["name"] as? String ?? "") · iOS \(r["ios"] as? String ?? "?")"
        }
    }

    func refreshList() async {
        await guarded {
            let r = try await run(base("apps"))
            let live = (r["apps"] as? [[String: Any]]) ?? []
            let ids = Set(live.compactMap { $0["bundle_id"] as? String })
            apps.removeAll { !ids.contains($0.bundleID) }
            for a in live {
                let bid = a["bundle_id"] as? String ?? ""
                if !apps.contains(where: { $0.bundleID == bid }) {
                    apps.append(SideloadedApp(bundleID: bid, name: a["name"] as? String ?? bid, version: a["version"] as? String ?? "", expires: nil, ipaFile: nil))
                }
            }
            save()
        }
    }

    // MARK: Install / refresh
    func importIPA(from url: URL) {
        if ["plist", "mobiledevicepairing"].contains(url.pathExtension.lowercased()) { importPairing(from: url); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = Self.ipaDir.appendingPathComponent(UUID().uuidString + ".ipa")
        do { try FileManager.default.copyItem(at: url, to: dest); pendingIPA = dest } catch { errorText = "Không chép được IPA: \(error.localizedDescription)" }
    }

    func install(ipa: URL, upgrade: Bool = false) async {
        guard signedIn else { errorText = "Hãy đăng nhập Apple ID trước (tab Tài khoản)."; return }
        guard hasPairing else { errorText = "Hãy nhập file ghép nối trước (tab Thiết bị)."; return }
        await guarded {
            let info = try await run(["op": "inspect", "ipa_path": ipa.path])
            if info["is_tvos"] as? Bool == true { throw CoreError(message: "Đây là app Apple TV, không cài được lên iPhone/iPad.") }
            var req = base("install"); req["ipa_path"] = ipa.path; req["upgrade"] = upgrade
            let r = try await run(req)
            let bid = r["bundle_id"] as? String ?? ""
            let exp = (r["expires"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let rec = SideloadedApp(bundleID: bid, name: r["name"] as? String ?? bid, version: r["version"] as? String ?? "",
                                    expires: exp, ipaFile: ipa.lastPathComponent)
            if let c = r["lc_cert"] as? [String: Any] { lastLCCert = c }
            apps.removeAll { $0.bundleID == bid }
            apps.append(rec); save()
            infoText = "Đã cài \(rec.name)" + (exp.map { ", hết hạn \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
        }
    }

    func refresh(_ app: SideloadedApp) async {
        guard let f = app.ipaFile, FileManager.default.fileExists(atPath: Self.ipaDir.appendingPathComponent(f).path) else {
            errorText = "Không còn file IPA gốc của \(app.name). Hãy chọn lại IPA để cài đè."; return
        }
        errorText = nil
        await install(ipa: Self.ipaDir.appendingPathComponent(f), upgrade: true)
        if errorText == nil { markLCCertPending() }
    }

    /// Manual "Làm mới" button: re-sign one app, then push the certificate to LiveContainer.
    func refreshAndPush(_ app: SideloadedApp) async {
        await refresh(app)
        await pushPendingLCCert()
    }

    /// Re-sign and re-install iSideload itself from its own running bundle (no PC needed).
    /// iOS terminates the app while installation_proxy replaces it; reopen afterwards.
    func refreshSelf() async {
        let out = Self.ipaDir.appendingPathComponent("iSideload-self.ipa")
        try? FileManager.default.createDirectory(at: Self.ipaDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        do {
            _ = try await run(["op": "pack_self", "app_path": Bundle.main.bundleURL.path, "out_path": out.path])
        } catch { errorText = "Không đóng gói được iSideload: \(error)"; return }
        infoText = "Đang ký lại iSideload — app sẽ tự đóng khi cài xong, mở lại là xong."
        // iOS usually kills the app when the install finishes: the push happens on next launch.
        markLCCertPending()
        await install(ipa: out, upgrade: true)
    }

    // MARK: In-app pairing (iOS 27)
    @Published var pairingPIN: String = ""
    @Published var pairingActive = false
    private var bonjour: NetService?

    func pairOnDevice() async {
        pairingPIN = ""; pairingActive = true
        // Settings is in front while pairing, so keep running in the background and
        // deliver the PIN as a notification the user can read from Settings.
        let bg = UIApplication.shared.beginBackgroundTask(withName: "pairing") {}
        defer { UIApplication.shared.endBackgroundTask(bg) }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        CoreCall.structured = { [weak self] obj in
            DispatchQueue.main.async {
                guard let self else { return }
                if let ad = obj["advertise"] as? [String: Any] { self.publish(ad) }
                if let pin = obj["pin"] as? String {
                    self.pairingPIN = pin
                    let c = UNMutableNotificationContent()
                    c.title = "Mã ghép nối iSideload"; c.body = pin; c.sound = .default
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "isl-pin", content: c, trigger: nil))
                }
            }
        }
        defer { CoreCall.structured = nil; bonjour?.stop(); bonjour = nil; pairingActive = false; pairingPIN = "" }
        let tmp = Self.storage.appendingPathComponent("pairing-new.plist")
        await guarded {
            var req = base("pair_host"); req["pairing_path"] = tmp.path
            _ = try await run(req)
            try? FileManager.default.removeItem(at: Self.pairingURL)
            try FileManager.default.moveItem(at: tmp, to: Self.pairingURL)
            infoText = "Ghép nối thành công. Bật LocalDevVPN rồi bấm Kiểm tra kết nối."
        }
    }

    private func publish(_ ad: [String: Any]) {
        guard let port = ad["port"] as? Int, let name = ad["name"] as? String else { return }
        let svc = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: name, port: Int32(port))
        var txt: [String: Data] = [:]
        for (k, v) in ad["txt"] as? [String: String] ?? [:] { txt[k] = Data(v.utf8) }
        svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        svc.publish()
        bonjour = svc
    }

    // MARK: Auto refresh
    @Published var lcLatest: String = ""

    var isideloadBundleID: String { Bundle.main.bundleIdentifier ?? "" }

    /// Re-signs due apps from stored IPAs (others first, iSideload itself last). Returns success.
    @discardableResult
    func refreshAll(includeSelf: Bool, onlyDue: Bool, background: Bool, onlySelf: Bool = false) async -> Bool {
        guard !busy else { return false }
        guard vpnActive else {
            if !background { pendingVPNAction = .refreshAll(includeSelf: includeSelf && !onlySelf); LoopbackVPN.turnOn(); return false }
            AutoRefresh.notify("iSideload chưa ký lại", "LocalDevVPN chưa bật. Bật VPN rồi chạy lại.")
            return false
        }
        let due: (SideloadedApp) -> Bool = { !onlyDue || ($0.daysLeft ?? 0) < AutoRefresh.thresholdDays }
        var ok: [String] = [], failed: [String] = []
        if !onlySelf {
            for app in apps where app.bundleID != isideloadBundleID && !app.bundleID.hasPrefix(isideloadBundleID + ".") && due(app) {
                errorText = nil
                await refresh(app)
                if errorText == nil { ok.append(app.name) } else { failed.append("\(app.name): \(errorText ?? "")") }
            }
        }
        UserDefaults.standard.set(Date(), forKey: "lastRefresh")
        let selfDue = apps.first(where: { $0.bundleID.hasPrefix(isideloadBundleID) }).map(due) ?? true
        let summary = (ok.isEmpty ? "" : "Đã ký lại: " + ok.joined(separator: ", ") + ". ")
            + (failed.isEmpty ? "" : "Lỗi: " + failed.joined(separator: "; "))
        if includeSelf && selfDue {
            AutoRefresh.notify("iSideload đang tự ký lại", summary + " iSideload sẽ tự thoát khi cài xong.")
            await refreshSelf()   // process is usually terminated here on success
            if let e = errorText { AutoRefresh.notify("iSideload ký lại thất bại", e); return false }
        } else {
            AutoRefresh.notify(failed.isEmpty ? "Ký lại xong" : "Ký lại có lỗi", summary.isEmpty ? "Không có app nào cần ký lại." : summary)
        }
        if !ok.isEmpty { markLCCertPending() }
        if !background { await pushPendingLCCert() }
        return failed.isEmpty
    }

    func installFromSource(_ a: SourceApp, _ v: SourceVersion) async {
        guard signedIn else { errorText = "Hãy đăng nhập Apple ID trước (tab Tài khoản)."; return }
        busy = true; stage = "Đang tải \(a.name) \(v.version)…"
        let ipa: URL
        do { ipa = try await SourceStore.download(v, name: a.name) } catch { busy = false; errorText = "Tải thất bại: \(error.localizedDescription)"; return }
        busy = false
        if !vpnActive { pendingVPNAction = .install(ipa); LoopbackVPN.turnOn(); return }
        await install(ipa: ipa, upgrade: apps.contains { $0.bundleID.hasPrefix(a.bundleIdentifier) })
    }

    // MARK: LocalDevVPN hand-off: remember the action, open LocalDevVPN, resume when it bounces back.
    enum VPNAction { case refreshAll(includeSelf: Bool), install(URL) }
    var pendingVPNAction: VPNAction?
    func resumeAfterVPN() async {
        guard let a = pendingVPNAction else { return }
        for _ in 0..<16 where !vpnActive { try? await Task.sleep(nanoseconds: 500_000_000) }
        guard vpnActive else { return }
        pendingVPNAction = nil
        switch a {
        case .refreshAll(let s): await refreshAll(includeSelf: s, onlyDue: false, background: false)
        case .install(let u): await install(ipa: u, upgrade: true)
        }
    }

    /// On open/foreground: re-sign anything expiring within 2 days (VPN needed).
    func foregroundCheck() async {
        await resumeAfterVPN()
        guard UserDefaults.standard.object(forKey: "fgRefresh") as? Bool ?? true, !busy, signedIn else { return }
        let urgent = apps.contains { ($0.daysLeft ?? 99) < 2 }
        if urgent { if vpnActive { await refreshAll(includeSelf: true, onlyDue: true, background: false) }
                    else { pendingVPNAction = .refreshAll(includeSelf: true); LoopbackVPN.turnOn() } }
    }

    func installLiveContainer() async {
        await guarded {
            stage = "Đang tải LiveContainer…"
            let r = try await LiveContainer.latest()
            let ipa = try await LiveContainer.download(r, into: Self.ipaDir)
            let existing = apps.contains { $0.bundleID.hasPrefix(LiveContainer.bundlePrefix) }
            lastLCCert = nil
            await install(ipa: ipa, upgrade: existing)
            // Right after installing, hand LiveContainer the signing certificate automatically.
            if let c = lastLCCert, errorText == nil {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                try sendCertToLiveContainer(c)
            }
        }
    }

    // MARK: LiveContainer certificate
    var lastLCCert: [String: Any]?
    private static let lcPendingKey = "lcCertPending"

    /// After a successful re-sign: remember to push the current certificate to LiveContainer.
    func markLCCertPending() {
        if liveContainerInstalled != nil { UserDefaults.standard.set(true, forKey: Self.lcPendingKey) }
    }

    /// Pushes the certificate if a re-sign left it pending. Only works in the foreground
    /// (URLs can't be opened from a background task); otherwise it waits for the next launch/foreground.
    func pushPendingLCCert() async {
        guard UserDefaults.standard.bool(forKey: Self.lcPendingKey) else { return }
        guard liveContainerInstalled != nil else { UserDefaults.standard.set(false, forKey: Self.lcPendingKey); return }
        guard UIApplication.shared.applicationState == .active, !busy, signedIn else { return }
        do {
            let r = try await run(base("export_cert"))
            try sendCertToLiveContainer(r)
            UserDefaults.standard.set(false, forKey: Self.lcPendingKey)
        } catch { errorText = "Chưa gửi được chứng chỉ sang LiveContainer: \(error.localizedDescription)" }
    }

    /// Exports the certificate this Apple ID signs with (.p12 + password) and opens
    /// livecontainer://certificate so LiveContainer stores it for JIT-less mode.
    func exportCertToLiveContainer() async {
        guard signedIn else { errorText = "Hãy đăng nhập Apple ID trước (tab Tài khoản)."; return }
        guard liveContainerInstalled != nil || UIApplication.shared.canOpenURL(URL(string: "livecontainer://")!) else {
            errorText = "Chưa cài LiveContainer. Hãy bấm Cài LiveContainer trước."; return
        }
        await guarded {
            let r = try await run(base("export_cert"))
            try sendCertToLiveContainer(r)
        }
    }

    private func sendCertToLiveContainer(_ c: [String: Any]) throws {
        guard let b64 = c["p12_base64"] as? String, let pw = c["password"] as? String else {
            throw CoreError(message: "Không có dữ liệu chứng chỉ.")
        }
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        let enc = { (x: String) in x.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        guard let url = URL(string: "livecontainer://certificate?cert=\(enc(b64))&password=\(enc(pw))") else {
            throw CoreError(message: "Không tạo được liên kết cho LiveContainer.")
        }
        // Keep a copy so the user can also import it by hand in LiveContainer › Settings.
        if let d = Data(base64Encoded: b64) {
            try? d.write(to: Self.docs.appendingPathComponent("LiveContainer-cert.p12"), options: .completeFileProtection)
        }
        UIApplication.shared.open(url) { ok in
            Task { @MainActor in
                if ok { self.infoText = "Đã gửi chứng chỉ (team \(c["team_id"] as? String ?? "")) sang LiveContainer. Trong LiveContainer hãy bấm đồng ý nhập." }
                else { self.errorText = "Không mở được LiveContainer. Mở LiveContainer một lần rồi thử lại." }
            }
        }
    }

    func checkLiveContainer() async {
        if let r = try? await LiveContainer.latest() { lcLatest = r.version }
    }

    var liveContainerInstalled: SideloadedApp? { apps.first { $0.bundleID.hasPrefix(LiveContainer.bundlePrefix) } }

    func handleURL(_ url: URL) {
        if url.scheme == "isideload" {
            if url.host == "vpn-ready" || url.host == nil || url.host == "" { Task { await resumeAfterVPN() }; return }
            if url.host == "refresh" { Task { await refreshAll(includeSelf: true, onlyDue: false, background: false) } }
            else if url.host == "refresh-apps" { Task { await refreshAll(includeSelf: false, onlyDue: false, background: false) } }
            return
        }
        importIPA(from: url)
    }

    // MARK: Certificates
    @Published var certs: [[String: Any]] = []
    func loadCerts() async { await guarded { certs = (try await run(base("certs"))["certs"] as? [[String: Any]]) ?? [] } }
    func revoke(_ serial: String) async {
        await guarded { var r = base("revoke_cert"); r["serial"] = serial; _ = try await run(r); certs.removeAll { $0["serial"] as? String == serial } }
    }
}
