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
    @AppStorage("accounts") private var accountsRaw = ""          // extra Apple IDs, newline-separated
    @AppStorage("installSigner") var installSigner = ""           // default signer for new installs
    @Published var importedCert: [String: Any]?
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
        // Migration: older builds never wrote vpnAutoOff; make the auto-VPN default explicit ON.
        if !UserDefaults.standard.bool(forKey: "migVPN2") { UserDefaults.standard.set(true, forKey: "vpnAutoOff"); UserDefaults.standard.set(true, forKey: "migVPN2") }
        for d in [Self.storage, Self.ipaDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        if let d = try? Data(contentsOf: Self.appsURL), let a = try? JSONDecoder().decode([SideloadedApp].self, from: d) { apps = a }
        signedIn = !appleID.isEmpty && Keychain.load(appleID) != nil
        if !appleID.isEmpty && !accounts.contains(appleID) { accountsRaw = ([appleID] + accounts).joined(separator: "\n") }
        hasImportedCert = FileManager.default.fileExists(atPath: Self.storage.appendingPathComponent("imported_cert/cert.p12").path)
        checkSelfUpdate()
    }

    // MARK: Signers (multiple Apple IDs + imported certificate)
    @Published var hasImportedCert = false
    var accounts: [String] { accountsRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
    var signedAccounts: [String] { accounts.filter { Keychain.load($0) != nil } }
    /// All usable signers: "apple:<email>" for each signed-in Apple ID, plus "cert".
    var signers: [String] { signedAccounts.map { "apple:" + $0 } + (hasImportedCert ? ["cert"] : []) }
    var canSign: Bool { !signers.isEmpty }
    func signerLabel(_ s: String) -> String { s == "cert" ? "Chứng chỉ có sẵn" : String(s.dropFirst(6)) }
    func signerOf(_ app: SideloadedApp) -> String { app.signer ?? "apple:" + appleID }
    var defaultSigner: String { signers.contains(installSigner) ? installSigner : (signers.first ?? "") }
    /// Apps signed by this signer that occupy a free-account slot (3 per Apple ID per device).
    func slotsUsed(_ s: String) -> Int { apps.filter { signerOf($0) == s }.count }
    /// App IDs created in the last 7 days by this Apple ID (counted locally, approximate).
    func appIDsUsed(_ email: String) -> Int {
        let log = UserDefaults.standard.dictionary(forKey: "appIDLog") as? [String: [Double]] ?? [:]
        let cut = Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        return (log[email] ?? []).filter { $0 > cut }.count
    }
    private func logAppIDs(_ email: String, count: Int) {
        var log = UserDefaults.standard.dictionary(forKey: "appIDLog") as? [String: [Double]] ?? [:]
        let cut = Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        log[email] = (log[email] ?? []).filter { $0 > cut } + Array(repeating: Date().timeIntervalSince1970, count: count)
        UserDefaults.standard.set(log, forKey: "appIDLog")
    }
    func team(of s: String) -> String {
        if s == "cert" { return ((importedCert?["certificate"] as? [String: Any])?["team_id"] as? String) ?? "" }
        return (UserDefaults.standard.dictionary(forKey: "teams") as? [String: String])?[String(s.dropFirst(6))] ?? ""
    }
    /// Groups for the Apps list: every signer (even empty) plus signers of apps no longer signed in.
    var signerGroups: [String] {
        var g = signers
        for a in apps where !g.contains(signerOf(a)) { g.append(signerOf(a)) }
        return g
    }
    /// Re-sign every app in one identity's group.
    func refreshGroup(_ s: String) async {
        if s != "cert" && !vpnActive { pendingVPNAction = .refreshAll(includeSelf: false); LoopbackVPN.turnOn(); return }
        var failed: [String] = []
        for app in apps where signerOf(app) == s && !app.bundleID.hasPrefix(isideloadBundleID) {
            errorText = nil; await refresh(app)
            if let e = errorText { failed.append("\(app.name): \(e)") }
        }
        if let me = apps.first(where: { $0.bundleID.hasPrefix(isideloadBundleID) && signerOf($0) == s }) { _ = me; await refreshSelf() }
        errorText = failed.isEmpty ? nil : failed.joined(separator: "\n")
        if failed.isEmpty { infoText = "Đã ký lại nhóm \(signerLabel(s))." }
        await pushPendingLCCert()
        vpnJobDone()
    }
    /// Move an app to another identity: re-sign with it (frees a slot on the old Apple ID).
    func move(_ app: SideloadedApp, to s: String) async {
        guard let f = app.ipaFile, FileManager.default.fileExists(atPath: Self.ipaDir.appendingPathComponent(f).path) else {
            errorText = "Không còn file IPA gốc của \(app.name)."; return
        }
        await install(ipa: Self.ipaDir.appendingPathComponent(f), upgrade: true, signer: s)
        if errorText == nil { markLCCertPending(); await pushPendingLCCert() }
        vpnJobDone()
    }
    /// min(cert notAfter, earliest profile ExpirationDate) of the imported certificate.
    var importedExpiry: Date? {
        let c = (importedCert?["certificate"] as? [String: Any])?["expires"] as? Double
        let p = (importedCert?["profiles"] as? [[String: Any]] ?? []).compactMap { $0["expires"] as? Double }.min()
        return [c, p].compactMap { $0 }.min().map { Date(timeIntervalSince1970: $0) }
    }
    /// One short line: "Đã ký <App> · còn N ngày".
    static func doneLine(_ name: String, _ exp: Date?) -> String {
        let n = name.count > 24 ? String(name.prefix(23)) + "…" : name
        guard let e = exp else { return "Đã ký \(n)" }
        let d = Int(floor(e.timeIntervalSinceNow / 86400))
        return "Đã ký \(n) · còn \(max(0, d)) ngày"
    }
    func signerSummary(_ s: String) -> String {
        if s == "cert" {
            switch importedWildcard {
            case .some(true): return "Chứng chỉ có sẵn · \(slotsUsed(s)) app · không giới hạn (profile wildcard)"
            case .some(false): return "Chứng chỉ có sẵn · \(slotsUsed(s)) app · không giới hạn (giữ bundle ID gốc)"
            case .none: return "Chứng chỉ có sẵn · \(slotsUsed(s)) app"
            }
        }
        let e = String(s.dropFirst(6))
        return "\(e) · \(slotsUsed(s))/3 app · App ID \(appIDsUsed(e))/10 trong 7 ngày"
    }

    var hasPairing: Bool { FileManager.default.fileExists(atPath: Self.pairingURL.path) }
    var vpnInterfaceUp: Bool { LoopbackVPN.isActive(target: vpnTarget.isEmpty ? LoopbackVPN.defaultTarget : vpnTarget) }
    /// Real check (TCP probe, ~1 s) used before every job.
    var vpnActive: Bool { LoopbackVPN.reachable(target: vpnTarget.isEmpty ? LoopbackVPN.defaultTarget : vpnTarget) }

    private func save() { if let d = try? JSONEncoder().encode(apps) { try? d.write(to: Self.appsURL) }; AutoRefresh.scheduleExpiryReminders(apps) }

    private func base(_ op: String, signer: String? = nil) -> [String: Any] {
        let id = signer.flatMap { $0.hasPrefix("apple:") ? String($0.dropFirst(6)) : nil } ?? appleID
        var r: [String: Any] = ["op": op, "apple_id": id, "password": Keychain.load(id) ?? "", "anisette_url": anisetteURL,
         "storage_dir": Self.storage.path, "pairing_path": Self.pairingURL.path, "target": vpnTarget,
         "license": LicenseManager.shared.license ?? "",
         "device_id": LicenseManager.deviceID,
         "build_sha": Bundle.main.infoDictionary?["ISLGitSHA"] as? String ?? ""]
        if signer == "cert" { r["use_imported_cert"] = true }
        return r
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
    /// Signs in an Apple ID and adds it to the account list (the first one becomes the main account).
    func signIn(email: String, password: String) async {
        let id = email.trimmingCharacters(in: .whitespaces)
        Keychain.save(password, for: id)
        await guarded {
            do {
                let r = try await run(base("sign_in", signer: "apple:" + id))
                if appleID.isEmpty || Keychain.load(appleID) == nil { appleID = id }
                if !accounts.contains(id) { accountsRaw = (accounts + [id]).joined(separator: "\n") }
                var t = UserDefaults.standard.dictionary(forKey: "teams") as? [String: String] ?? [:]
                t[id] = r["team_name"] as? String ?? (r["team"] as? String ?? ""); UserDefaults.standard.set(t, forKey: "teams")
                if id == appleID { teamName = r["team_name"] as? String ?? (r["team"] as? String ?? "") }
                signedIn = true
                infoText = "Đã thêm tài khoản \(id)."
            } catch { Keychain.delete(id); throw error }
        }
    }
    func signOut() { signOut(appleID) }
    func signOut(_ id: String) {
        Keychain.delete(id)
        accountsRaw = accounts.filter { $0 != id }.joined(separator: "\n")
        if id == appleID { appleID = signedAccounts.first ?? ""; teamName = "" }
        signedIn = !appleID.isEmpty && Keychain.load(appleID) != nil
        objectWillChange.send()
    }
    func makeMain(_ id: String) { appleID = id; teamName = ""; signedIn = Keychain.load(id) != nil }

    // MARK: Imported certificate (.p12 + .mobileprovision)
    func importCert(p12: URL?, password: String, profiles: [URL], replaceProfiles: Bool = false) async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        func copy(_ u: URL) -> String {
            let sc = u.startAccessingSecurityScopedResource(); defer { if sc { u.stopAccessingSecurityScopedResource() } }
            let d = tmp.appendingPathComponent(u.lastPathComponent); try? FileManager.default.copyItem(at: u, to: d); return d.path
        }
        await guarded {
            var r = base("import_cert")
            if let p12 { r["p12_path"] = copy(p12); r["password"] = password }
            r["profile_paths"] = profiles.map(copy); r["replace_profiles"] = replaceProfiles
            r["udid"] = UserDefaults.standard.string(forKey: "deviceUDID") ?? ""
            importedCert = try await run(r)
            hasImportedCert = true
            infoText = "Đã nhập chứng chỉ."
        }
    }
    func loadImportedCert() async {
        var r = base("imported_cert"); r["udid"] = UserDefaults.standard.string(forKey: "deviceUDID") ?? ""
        if let v = try? await CoreCall.runAsync(r, onEvent: { _, _ in }, onPrompt: { _ in nil }).checked() {
            importedCert = (v["imported"] as? Bool == true) ? v : nil; hasImportedCert = importedCert != nil
            if let e = importedExpiry, apps.contains(where: { signerOf($0) == "cert" && $0.expires != e }) {
                for i in apps.indices where signerOf(apps[i]) == "cert" { apps[i].expires = e }; save()
            }
        }
    }
    func clearImportedCert() async {
        await guarded { _ = try await run(base("clear_imported_cert")); importedCert = nil; hasImportedCert = false }
    }

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
            if let u = r["udid"] as? String, !u.isEmpty { UserDefaults.standard.set(u, forKey: "deviceUDID") }
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

    /// Installs/re-signs with a signer: explicit, else the one that signed this app before, else the default.
    /// nil = unknown; true = some usable profile has a wildcard App ID (unlimited apps); false = explicit only (1 app).
    var importedWildcard: Bool? {
        guard let ps = importedCert?["profiles"] as? [[String: Any]], !ps.isEmpty else { return nil }
        let live = ps.filter { ($0["expired"] as? Bool) != true }
        return (live.isEmpty ? ps : live).contains { $0["wildcard"] as? Bool == true }
    }
    var importedSingleAppID: String? {
        guard importedWildcard == false else { return nil }
        return (importedCert?["profiles"] as? [[String: Any]])?.first?["app_id"] as? String
    }
    @Published var explicitWarn: (URL, Bool, String?)?
    var explicitReplaces = ""
    private var explicitOK = false
    func confirmExplicit() async {
        guard let (u, up, sg) = explicitWarn else { return }
        explicitWarn = nil; explicitOK = true
        await install(ipa: u, upgrade: up, signer: sg); explicitOK = false; vpnJobDone()
    }

    func install(ipa: URL, upgrade: Bool = false, signer: String? = nil) async {
        guard canSign else { errorText = "Hãy đăng nhập Apple ID hoặc nhập chứng chỉ trước (tab Tài khoản)."; return }
        // Imported certificate = KSign-style OTA install, never VPN. Only Apple ID signing needs pairing + LocalDevVPN.
        let early = signer ?? apps.first { $0.ipaFile == ipa.lastPathComponent }.map(signerOf) ?? defaultSigner
        if early != "cert" {
            guard hasPairing else { errorText = "Hãy nhập file ghép nối trước (tab Thiết bị)."; return }
            // Real reachability first (62078 connect/refused ≈ 1 s). Only hand off to LocalDevVPN when it's really down.
            if !vpnActive {
                if UIApplication.shared.applicationState == .active && (UserDefaults.standard.object(forKey: "vpnAutoOff") as? Bool ?? true) {
                    pendingVPNAction = .install(ipa, upgrade, signer); LoopbackVPN.turnOn(); return
                }
                errorText = "Không thấy thiết bị qua LocalDevVPN (10.7.0.1). Hãy bật LocalDevVPN."; return
            }
        }
        await guarded {
            let tmpIcon = IconCache.dir.appendingPathComponent("_pending.png")
            let info = try await run(["op": "inspect", "ipa_path": ipa.path, "icon_out": tmpIcon.path])
            if info["is_tvos"] as? Bool == true { throw CoreError(message: "Đây là app Apple TV, không cài được lên iPhone/iPad.") }
            let bundle = info["bundle_id"] as? String ?? ""
            let prev = apps.first { $0.bundleID == bundle || $0.ipaFile == ipa.lastPathComponent }
            let who = signer ?? prev.map(signerOf) ?? defaultSigner
            guard signers.contains(who) else { throw CoreError(message: "Tài khoản ký \(signerLabel(who)) chưa đăng nhập. Hãy đăng nhập lại ở tab Tài khoản.") }
            if who == "cert", prev == nil, !explicitOK, false,
               let old = apps.first(where: { signerOf($0) == "cert" && $0.bundleID != bundle }) {
                explicitReplaces = old.name; explicitWarn = (ipa, upgrade, signer ?? who); return
            }
            if who.hasPrefix("apple:"), prev == nil || signerOf(prev!) != who, slotsUsed(who) >= 3 {
                throw CoreError(message: "\(signerLabel(who)) đã dùng 3/3 app trên máy này. Chọn tài khoản khác hoặc gỡ bớt app.")
            }
            var req = base("install", signer: who); req["ipa_path"] = ipa.path; req["upgrade"] = upgrade
            req["udid"] = UserDefaults.standard.string(forKey: "deviceUDID") ?? ""
            let otaIPA = FileManager.default.temporaryDirectory.appendingPathComponent("ota-\(UUID().uuidString).ipa")
            if who != "cert" && !vpnActive { throw CoreError(message: "Không thấy thiết bị qua LocalDevVPN (10.7.0.1). Hãy bật LocalDevVPN.") }
            if who == "cert" && UIApplication.shared.applicationState != .active {
                throw CoreError(message: "App ký bằng chứng chỉ cần mở iSideload để cài lại (iOS hiện hộp thoại Cài đặt).")
            }
            if who == "cert" { req["ota"] = true; req["ipa_out"] = otaIPA.path }
            defer { try? FileManager.default.removeItem(at: otaIPA) }
            let r = try await run(req)
            if who == "cert" {
                busy = true; defer { busy = false }
                try await OTAInstaller.shared.install(ipa: otaIPA, bundleID: r["bundle_id"] as? String ?? "", name: r["name"] as? String ?? "App",
                                                     version: r["version"] as? String ?? "1.0") { [weak self] st, p in self?.stage = st; self?.progress = p ?? 0 }
            }
            let bid = r["bundle_id"] as? String ?? ""
            if let u = r["udid"] as? String, !u.isEmpty { UserDefaults.standard.set(u, forKey: "deviceUDID") }
            if who.hasPrefix("apple:") && prev.map(signerOf) != who { logAppIDs(String(who.dropFirst(6)), count: 1 + ((info["extensions"] as? [Any])?.count ?? 0)) }
            let notes = (r["notes"] as? [String]) ?? []
            var exp = (r["expires"] as? Double).map { Date(timeIntervalSince1970: $0) }
            // Imported cert: real expiry = min(cert notAfter, profile ExpirationDate) — never the 7-day free-account window.
            if who == "cert" { exp = [exp, importedExpiry].compactMap { $0 }.min() }
            let rec = SideloadedApp(bundleID: bid, name: r["name"] as? String ?? bid, version: r["version"] as? String ?? "",
                                    expires: exp, ipaFile: ipa.lastPathComponent, signer: who)
            if let c = r["lc_cert"] as? [String: Any] { lastLCCert = c }
            apps.removeAll { $0.bundleID == bid || ($0.bundleID == bundle && prev != nil) }
            apps.append(rec); save()
            if info["icon_path"] != nil { IconCache.adopt(tmpIcon, for: bid) }
            infoText = Self.doneLine(rec.name, exp) + (notes.isEmpty ? "" : "\n" + notes.joined(separator: " "))
        }
    }

    func refresh(_ app: SideloadedApp) async {
        guard let f = app.ipaFile, FileManager.default.fileExists(atPath: Self.ipaDir.appendingPathComponent(f).path) else {
            errorText = "Không còn file IPA gốc của \(app.name). Hãy chọn lại IPA để cài đè."; return
        }
        errorText = nil
        await install(ipa: Self.ipaDir.appendingPathComponent(f), upgrade: true, signer: signerOf(app))
        if errorText == nil { markLCCertPending() }
    }

    /// Manual "Làm mới" button: re-sign one app, then push the certificate to LiveContainer.
    func refreshAndPush(_ app: SideloadedApp) async {
        await refresh(app)
        await pushPendingLCCert()
        vpnJobDone()
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
        let me = apps.first { $0.bundleID.hasPrefix(isideloadBundleID) }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "selfUpdatePending")
        await install(ipa: out, upgrade: true, signer: me.map(signerOf))
        // iOS replaces (and kills) the running app; the connection often drops right after the upload.
        if let e = errorText?.lowercased(), ["socket", "io failed", "broken pipe", "connection", "reset", "eof"].contains(where: { e.contains($0) }) {
            errorText = nil
            infoText = "Đã gửi bản ký lại. iOS đang thay iSideload — mở lại app để xác nhận."
        } else if errorText != nil {
            UserDefaults.standard.removeObject(forKey: "selfUpdatePending")
        }
    }

    /// On launch after a self re-sign: confirm via the new embedded.mobileprovision (written by the install).
    func checkSelfUpdate() {
        let t = UserDefaults.standard.double(forKey: "selfUpdatePending")
        guard t > 0 else { return }
        UserDefaults.standard.removeObject(forKey: "selfUpdatePending")
        let prov = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let m = (try? FileManager.default.attributesOfItem(atPath: prov.path))?[.modificationDate] as? Date,
              m.timeIntervalSince1970 >= t - 120 else { return }
        var exp: Date?
        if let d = try? Data(contentsOf: prov), let s = String(data: d, encoding: .isoLatin1),
           let r = s.range(of: "<key>ExpirationDate</key>"), let a = s.range(of: "<date>", range: r.upperBound..<s.endIndex),
           let b = s.range(of: "</date>", range: a.upperBound..<s.endIndex) {
            exp = ISO8601DateFormatter().date(from: String(s[a.upperBound..<b.lowerBound]))
        }
        if let i = apps.firstIndex(where: { $0.bundleID.hasPrefix(isideloadBundleID) }) {
            if let exp { apps[i].expires = exp }
            apps[i].installedAt = Date()
            save()
        }
        infoText = "Đã ký lại iSideload ✓" + (exp.map { " · hết hạn " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
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
        let dueAny: (SideloadedApp) -> Bool = { !onlyDue || ($0.daysLeft ?? 0) < AutoRefresh.thresholdDays }
        let needVPN = apps.contains { dueAny($0) && signerOf($0) != "cert" && (!onlySelf || $0.bundleID.hasPrefix(isideloadBundleID)) }
        if needVPN && !vpnActive {
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
                if errorText == nil { ok.append(Self.doneLine(app.name, apps.first { $0.name == app.name }?.expires).replacingOccurrences(of: "Đã ký ", with: "")) } else { failed.append("\(app.name): \(errorText ?? "")") }
            }
        }
        UserDefaults.standard.set(Date(), forKey: "lastRefresh")
        let selfDue = apps.first(where: { $0.bundleID.hasPrefix(isideloadBundleID) }).map(due) ?? true
        let summary = (ok.isEmpty ? "" : "Đã ký " + ok.joined(separator: "; ") + ". ")
            + (failed.isEmpty ? "" : "Lỗi: " + failed.joined(separator: "; "))
        if includeSelf && selfDue {
            AutoRefresh.notify("iSideload đang tự ký lại", summary + " iSideload sẽ tự thoát khi cài xong.")
            await refreshSelf()   // process is usually terminated here on success
            if let e = errorText { AutoRefresh.notify("iSideload ký lại thất bại", e); return false }
        } else {
            AutoRefresh.notify(failed.isEmpty ? "Ký lại xong" : "Ký lại có lỗi", summary.isEmpty ? "Không có app nào cần ký lại." : summary)
        }
        if !ok.isEmpty { markLCCertPending() }
        if !background { await pushPendingLCCert(); vpnJobDone() }
        return failed.isEmpty
    }

    /// Lazily pull the icon out of a stored IPA for apps installed before icons existed.
    func ensureIcon(_ app: SideloadedApp) async {
        guard IconCache.image(app.bundleID) == nil, let f = app.ipaFile, !IconCache.tried.contains(app.bundleID) else { return }
        IconCache.tried.insert(app.bundleID)
        let ipa = Self.ipaDir.appendingPathComponent(f)
        guard FileManager.default.fileExists(atPath: ipa.path) else { return }
        let out = IconCache.dir.appendingPathComponent("_lazy-\(app.bundleID).png")
        let r = await CoreCall.runAsync(["op": "inspect", "ipa_path": ipa.path, "icon_out": out.path], onEvent: { _, _ in })
        if r["icon_path"] != nil { IconCache.adopt(out, for: app.bundleID); objectWillChange.send() }
    }

    func installFromSource(_ a: SourceApp, _ v: SourceVersion, signer: String? = nil) async {
        guard canSign else { errorText = "Hãy đăng nhập Apple ID trước (tab Tài khoản)."; return }
        busy = true; stage = "Đang tải \(a.name) \(v.version)…"
        let ipa: URL
        do { ipa = try await SourceStore.download(v, name: a.name) } catch { busy = false; errorText = "Tải thất bại: \(error.localizedDescription)"; return }
        busy = false
        if let u = a.icon { IconCache.remember(u, for: a.bundleIdentifier) }
        let who = signer ?? apps.first { $0.bundleID.hasPrefix(a.bundleIdentifier) }.map(signerOf) ?? defaultSigner
        if who != "cert" && !vpnActive { pendingVPNAction = .install(ipa, apps.contains { $0.bundleID.hasPrefix(a.bundleIdentifier) }, signer); LoopbackVPN.turnOn(); return }
        await install(ipa: ipa, upgrade: apps.contains { $0.bundleID.hasPrefix(a.bundleIdentifier) }, signer: signer)
        vpnJobDone()
    }

    // MARK: VPN only during jobs: turn LocalDevVPN off as soon as an install/refresh finishes (ok or failed).
    private var vpnOffScheduled = false
    func vpnJobDone() {
        guard UserDefaults.standard.object(forKey: "vpnAutoOff") as? Bool ?? true, !vpnOffScheduled,
              pendingVPNAction == nil, UIApplication.shared.applicationState == .active else { return }
        vpnOffScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)   // let a LiveContainer cert hand-off open first
            vpnOffScheduled = false
            if !busy && vpnActive { LoopbackVPN.turnOff() }
        }
    }
    // MARK: Uninstall
    @Published var uninstallFailed: SideloadedApp?
    /// Remove from iSideload's list: stops re-signing it and frees its slot (slots are counted from this list).
    func removeFromList(_ app: SideloadedApp) {
        apps.removeAll { $0.bundleID == app.bundleID }; save()
        if let f = app.ipaFile { try? FileManager.default.removeItem(at: Self.ipaDir.appendingPathComponent(f)) }
        try? FileManager.default.removeItem(at: IconCache.file(app.bundleID))
    }
    /// Uninstall from the device via installation_proxy (needs LocalDevVPN like install), then drop from the list.
    func uninstall(_ app: SideloadedApp) async {
        guard hasPairing else { uninstallFailed = app; return }
        if !vpnActive {
            if UIApplication.shared.applicationState == .active { pendingVPNAction = .uninstall(app); LoopbackVPN.turnOn(); return }
            uninstallFailed = app; return
        }
        var req = base("uninstall"); req["bundle_id"] = app.bundleID
        let r = await CoreCall.runAsync(req)
        if r["ok"] as? Bool == true {
            removeFromList(app); infoText = "Đã gỡ \(app.name)"
        } else { uninstallFailed = app }
        vpnJobDone()
    }

    func installNow(_ ipa: URL, signer: String) async { await install(ipa: ipa, signer: signer); vpnJobDone() }

    // MARK: LocalDevVPN hand-off: remember the action, open LocalDevVPN, resume when it bounces back.
    enum VPNAction { case refreshAll(includeSelf: Bool), install(URL, Bool, String?), uninstall(SideloadedApp) }
    var pendingVPNAction: VPNAction?
    func resumeAfterVPN() async {
        guard let a = pendingVPNAction else { return }
        var ok = false
        for _ in 0..<8 { if vpnActive { ok = true; break }; try? await Task.sleep(nanoseconds: 600_000_000) }   // retry 62078 ~5 s
        guard ok else { pendingVPNAction = nil; errorText = "Không kết nối được tới thiết bị qua LocalDevVPN (10.7.0.1) sau ~5 giây. Mở LocalDevVPN, bấm Connect rồi thử lại."; return }
        pendingVPNAction = nil
        switch a {
        case .refreshAll(let s): await refreshAll(includeSelf: s, onlyDue: false, background: false)
        case .install(let u, let up, let sg): await install(ipa: u, upgrade: up, signer: sg)
        case .uninstall(let app): await uninstall(app)
        }
        vpnJobDone()
    }

    /// On open/foreground: re-sign anything expiring within 2 days (VPN needed).
    func foregroundCheck() async {
        await resumeAfterVPN()
        guard UserDefaults.standard.object(forKey: "fgRefresh") as? Bool ?? true, !busy, canSign else { return }
        let urgent = apps.contains { ($0.daysLeft ?? 99) < 2 }
        if urgent { if vpnActive { await refreshAll(includeSelf: true, onlyDue: true, background: false) }
                    else if apps.contains(where: { ($0.daysLeft ?? 99) < 2 && signerOf($0) != "cert" }) { pendingVPNAction = .refreshAll(includeSelf: true); LoopbackVPN.turnOn() }
                    else { await refreshAll(includeSelf: true, onlyDue: true, background: false) } }
    }

    func installLiveContainer() async {
        await guarded {
            stage = "Đang tải LiveContainer…"
            let r = try await LiveContainer.latest()
            let ipa = try await LiveContainer.download(r, into: Self.ipaDir)
            let existing = liveContainerInstalled
            lastLCCert = nil
            await install(ipa: ipa, upgrade: existing != nil, signer: existing.map(signerOf))
            // Right after installing, hand LiveContainer the signing certificate automatically.
            if let c = lastLCCert, errorText == nil {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                try sendCertToLiveContainer(c)
            }
        }
        vpnJobDone()
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
        guard UIApplication.shared.applicationState == .active, !busy, canSign else { return }
        do {
            let r = try await run(base("export_cert", signer: lcSigner))
            try sendCertToLiveContainer(r)
            UserDefaults.standard.set(false, forKey: Self.lcPendingKey)
        } catch { errorText = "Chưa gửi được chứng chỉ sang LiveContainer: \(error.localizedDescription)" }
    }

    /// Exports the certificate this Apple ID signs with (.p12 + password) and opens
    /// livecontainer://certificate so LiveContainer stores it for JIT-less mode.
    func exportCertToLiveContainer() async {
        guard canSign else { errorText = "Hãy đăng nhập Apple ID trước (tab Tài khoản)."; return }
        guard liveContainerInstalled != nil || UIApplication.shared.canOpenURL(URL(string: "livecontainer://")!) else {
            errorText = "Chưa cài LiveContainer. Hãy bấm Cài LiveContainer trước."; return
        }
        await guarded {
            let r = try await run(base("export_cert", signer: lcSigner))
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

    /// LiveContainer must get the certificate of the account that signed it.
    var lcSigner: String { liveContainerInstalled.map(signerOf) ?? defaultSigner }
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
