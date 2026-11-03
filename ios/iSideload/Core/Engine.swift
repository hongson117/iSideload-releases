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
    @AppStorage("liveContainerActiveBundleID") private var liveContainerActiveBundleID = ""
    @Published var importedCert: [String: Any]?
    @Published var signedIn = false
    @Published var teamName = ""
    @Published var apps: [SideloadedApp] = []
    @Published var deviceLine = ""
    @Published var pairingVerified = false
    @Published var pairingCheckError: String?
    @Published var liveContainerCertificateFile: LiveContainerCertificateFile?
    @Published var busy = false
    @Published var peerBusy = false
    @Published var selectedTab = 0
    @Published var stage = ""
    @Published var progress: Double = 0
    @Published var prompt: CorePrompt?
    @Published var errorText: String?
    @Published var infoText: String?
    @Published var pendingIPA: URL?
    @Published var preparedOwnerInstallation: [String: Any]?
    @Published var appUpdate: AppUpdateRelease?
    @Published var checkingAppUpdate = false
    @Published var updatingApp = false
    @Published var updateStatus = "Chưa kiểm tra phiên bản mới."

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
        syncSelfRecord()
        if (UserDefaults.standard.string(forKey: "deviceUDID") ?? "").isEmpty,
           let udid = selfSigningIdentity?.deviceUDID { UserDefaults.standard.set(udid, forKey: "deviceUDID") }
        if let data = try? Data(contentsOf: Self.storage.appendingPathComponent("owner-installation.json")),
           let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           value["source_bundle_id"] as? String == Bundle.main.bundleIdentifier {
            preparedOwnerInstallation = value
        }
        checkSelfUpdate()
        confirmVersionUpdate()
        if hasImportedCert { Task { await loadImportedCert() } }
    }

    // MARK: Signers (multiple Apple IDs + imported certificate)
    @Published var hasImportedCert = false
    var accounts: [String] { accountsRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
    var signedAccounts: [String] { accounts.filter { Keychain.load($0) != nil } }
    /// All usable signers: "apple:<email>" for each signed-in Apple ID, plus "cert".
    var signers: [String] { signedAccounts.map { "apple:" + $0 } + (hasImportedCert ? ["cert"] : []) }
    var canSign: Bool { !signers.isEmpty }
    func signerLabel(_ s: String) -> String {
        if s == "self" { return "Chưa chọn tài khoản ký" }
        return s == "cert" ? "Chứng chỉ đã nhập (.p12)" : String(s.dropFirst(6))
    }
    func signerOf(_ app: SideloadedApp) -> String {
        if let signer = app.signer { return signer }
        if isSelf(app) { return "self" }
        return "apple:" + appleID
    }
    func isSelf(_ app: SideloadedApp) -> Bool { app.bundleID == isideloadBundleID }
    var selfApp: SideloadedApp? { apps.first(where: isSelf) }

    var selfSigningIdentity: SelfSigningIdentity? {
        guard let state = InstalledAppState.read(bundleURL: Bundle.main.bundleURL), let teamID = state.teamID else { return nil }
        return SelfSigningIdentity(bundleID: state.bundleID, teamID: teamID,
            installerData: try? Data(contentsOf: Self.storage.appendingPathComponent("installation-identity.json")))
    }

    private func knownTeamIDs(for account: String) -> [String]? {
        (UserDefaults.standard.dictionary(forKey: "accountTeamIDs") as? [String: [String]])?[account.lowercased()]
    }

    func selfSignerProblem(_ signer: String) -> String? {
        guard let identity = selfSigningIdentity else { return "Chưa đọc được Team ký bản đang cài." }
        let teams: [String]?
        if signer == "cert" {
            let team = (importedCert?["certificate"] as? [String: Any])?["team_id"] as? String
            teams = team.map { [$0] }
        }
        else if signer.hasPrefix("apple:") { teams = knownTeamIDs(for: String(signer.dropFirst(6))) }
        else { return nil }
        guard let teams, !identity.accepts(teamIDs: teams) else { return nil }
        return "Tài khoản đã chọn chưa gắn với bản cài này. Vào Tài khoản → Thiết lập iContainer bằng tài khoản này. " + identity.description
    }

    /// Register a fresh installation without needing VPN or a device browse first.
    func syncSelfRecord(signer: String? = nil) {
        guard let state = InstalledAppState.read(bundleURL: Bundle.main.bundleURL) else { return }
        apps = state.reconcile(apps, signer: signer)
        if let udid = state.udid { UserDefaults.standard.set(udid, forKey: "deviceUDID") }
        save()
    }
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
        for a in apps where !isSelf(a) && !g.contains(signerOf(a)) { g.append(signerOf(a)) }
        return g
    }
    /// Re-sign every app in one identity's group.
    func refreshGroup(_ s: String) async {
        await refreshAll(includeSelf: true, onlyDue: false, background: false, signerFilter: s)
    }
    /// Move an app to another identity: re-sign with it (frees a slot on the old Apple ID).
    func move(_ app: SideloadedApp, to s: String) async {
        if isSelf(app) { await refreshSelf(signer: s); return }
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
        return "\(e) · \(slotsUsed(s)) app đã ghi nhận · App ID \(appIDsUsed(e))/10 trong 7 ngày"
    }

    var pairingKind: PairingRecord.Kind? {
        guard let data = try? Data(contentsOf: Self.pairingURL) else { return nil }
        return (try? PairingRecord.parse(data))?.kind
    }
    var hasPairing: Bool { pairingKind != nil }
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
         "build_sha": Bundle.main.infoDictionary?["ISLGitSHA"] as? String ?? "",
         "host_path": Bundle.main.bundleURL.path,
         "allow_certificate_prompt": UIApplication.shared.applicationState == .active]
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

    func run(_ req: [String: Any]) async throws -> [String: Any] {
        guard !peerBusy else { throw CoreError(message: "Đang hỗ trợ iPhone khác. Hãy hoàn tất thao tác đó trước.") }
        busy = true; stage = ""; progress = 0
        defer { busy = false }
        let r = await CoreCall.runAsync(req, onEvent: { s, p in
            DispatchQueue.main.async { self.stage = s; self.progress = p }
        }, onPrompt: { [weak self] p in self?.ask(p) })
        return try r.checked()
    }

    // Peer jobs share only the signing account and prompt UI, never this phone's app list or pairing file.
    #if ICONTAINER
    func containerOperation(_ request: [String: Any]) async throws -> [String: Any] {
        try await run(request)
    }

    func prepareContainerGuest(_ request: [String: Any], signer: String) async throws {
        guard signers.contains(signer) else { throw CoreError(message: "Chọn nguồn ký hợp lệ trong tab Tài khoản.") }
        var export = base("export_cert", signer: signer)
        if let identity = selfSigningIdentity { export["expected_team_id"] = identity.teamID }
        let certificate = try await run(export)
        var r = request
        r["p12_base64"] = certificate["p12_base64"]
        r["password"] = certificate["password"]
        r["signer"] = signer
        r["host_path"] = Bundle.main.bundleURL.path
        _ = try await run(r)
    }
    #endif

    func peerRequest(_ op: String, account: String = "") -> [String: Any] {
        base(op, signer: account.isEmpty ? nil : "apple:" + account)
    }

    func callForPeer(_ req: [String: Any], onEvent: @escaping CoreCall.Event,
                     onStructured: (([String: Any]) -> Void)? = nil) async throws -> [String: Any] {
        try await CoreCall.runAsync(req, onEvent: onEvent,
                                   onPrompt: { [weak self] p in self?.ask(p) },
                                   onStructured: onStructured).checked()
    }

    private func guarded(_ work: () async throws -> Void) async {
        do { try await work() } catch { errorText = error.localizedDescription }
    }

    // MARK: Account
    /// Signs in an Apple ID and adds it to the account list (the first one becomes the main account).
    func signIn(email: String, password: String) async {
        let id = email.trimmingCharacters(in: .whitespaces)
        errorText = nil
        let previousPassword = Keychain.load(id)
        Keychain.save(password, for: id)
        await guarded {
            do {
                let r = try await run(base("sign_in", signer: "apple:" + id))
                let teamIDs = (r["teams"] as? [[String: Any]] ?? []).compactMap { $0["team_id"] as? String }
                var memberships = UserDefaults.standard.dictionary(forKey: "accountTeamIDs") as? [String: [String]] ?? [:]
                memberships[id.lowercased()] = teamIDs
                UserDefaults.standard.set(memberships, forKey: "accountTeamIDs")
                if appleID.isEmpty || Keychain.load(appleID) == nil { appleID = id }
                if !accounts.contains(id) { accountsRaw = (accounts + [id]).joined(separator: "\n") }
                var t = UserDefaults.standard.dictionary(forKey: "teams") as? [String: String] ?? [:]
                t[id] = r["team_name"] as? String ?? (r["team"] as? String ?? ""); UserDefaults.standard.set(t, forKey: "teams")
                if id == appleID { teamName = r["team_name"] as? String ?? (r["team"] as? String ?? "") }
                signedIn = true
                if selfApp?.signer == nil, selfSigningIdentity?.accepts(teamIDs: teamIDs) == true {
                    syncSelfRecord(signer: "apple:" + id)
                }
                infoText = "Đã thêm tài khoản \(id)."
            } catch {
                if let previousPassword { Keychain.save(previousPassword, for: id) }
                else { Keychain.delete(id) }
                throw error
            }
        }
    }
    func signOut() { signOut(appleID) }
    func signOut(_ id: String) {
        Keychain.delete(id)
        accountsRaw = accounts.filter { $0 != id }.joined(separator: "\n")
        var teams = UserDefaults.standard.dictionary(forKey: "teams") as? [String: String] ?? [:]
        teams.removeValue(forKey: id); UserDefaults.standard.set(teams, forKey: "teams")
        var memberships = UserDefaults.standard.dictionary(forKey: "accountTeamIDs") as? [String: [String]] ?? [:]
        memberships.removeValue(forKey: id.lowercased()); UserDefaults.standard.set(memberships, forKey: "accountTeamIDs")
        if installSigner == "apple:" + id { installSigner = "" }
        if id == appleID { appleID = signedAccounts.first ?? ""; teamName = "" }
        signedIn = !appleID.isEmpty && Keychain.load(appleID) != nil
        objectWillChange.send()
    }
    func makeMain(_ id: String) { appleID = id; teamName = ""; signedIn = Keychain.load(id) != nil }

    // MARK: Imported certificate (.p12 + .mobileprovision)
    func prepareOwnerInstallation(account: String) async {
        guard !busy && !peerBusy, signedAccounts.contains(account) else { return }
        errorText = nil
        let udid = UserDefaults.standard.string(forKey: "deviceUDID") ?? selfSigningIdentity?.deviceUDID ?? ""
        guard !udid.isEmpty else {
            errorText = "Vào Thiết bị, bật LocalDevVPN rồi Kiểm tra kết nối một lần để xác định iPhone trước khi thiết lập tài khoản của bạn."; return
        }
        let relative = "OwnerSetup/\(UUID().uuidString)/iContainer-personal.ipa"
        let out = Self.docs.appendingPathComponent(relative)
        let input = out.deletingLastPathComponent().appendingPathComponent("iContainer-bootstrap.ipa")
        do {
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await run(["op": "pack_self", "app_path": Bundle.main.bundleURL.path,
                              "out_path": input.path, "peer_bootstrap": true, "personal_setup": true])
            defer { try? FileManager.default.removeItem(at: input) }
            var request = base("prepare_owner_install", signer: "apple:" + account)
            request["ipa_path"] = input.path; request["ipa_out"] = out.path
            request["ipa_relative_path"] = relative
            request["source_bundle_id"] = Bundle.main.bundleIdentifier ?? ""
            request["udid"] = udid
            let result = try await run(request)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.storage.appendingPathComponent("owner-installation.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            preparedOwnerInstallation = result
            infoText = "Đã chuẩn bị bản iContainer ký bằng \(account). Bản đang dùng và dữ liệu hiện tại vẫn được giữ. Bản cài sẵn sàng để cài bằng máy hỗ trợ."
        } catch { errorText = error.localizedDescription }
    }

    var preparedOwnerIPA: URL? {
        guard let relative = preparedOwnerInstallation?["ipa_relative_path"] as? String,
              relative.hasPrefix("OwnerSetup/"), !relative.split(separator: "/").contains("..") else { return nil }
        return Self.docs.appendingPathComponent(relative)
    }

    func installPreparedOwner() async {
        guard !busy && !peerBusy, let file = preparedOwnerIPA,
              let account = preparedOwnerInstallation?["apple_id"] as? String,
              signedAccounts.contains(account) else { return }
        await installNow(file, signer: "apple:" + account)

    }

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
            let record = try PairingRecord.parse(Data(contentsOf: url))
            try record.data.write(to: Self.pairingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            pairingVerified = false; pairingCheckError = nil; deviceLine = ""; errorText = nil
            infoText = "Đã nhập file \(record.kind.rawValue). Bật LocalDevVPN rồi bấm Kiểm tra kết nối thiết bị."
            objectWillChange.send()
        } catch { errorText = error.localizedDescription }
    }

    func checkDevice() async {
        guard !busy else { return }
        pairingVerified = false; pairingCheckError = nil; deviceLine = ""; errorText = nil
        await guarded {
            let r = try await run(base("device"))
            deviceLine = "\(r["name"] as? String ?? "") · iOS \(r["ios"] as? String ?? "?")"
            if let u = r["udid"] as? String, !u.isEmpty { UserDefaults.standard.set(u, forKey: "deviceUDID") }
            pairingVerified = true
        }
        pairingCheckError = errorText
    }

    func refreshList() async {
        await guarded {
            let r = try await run(base("apps"))
            let live = (r["apps"] as? [[String: Any]]) ?? []
            let ids = Set(live.compactMap { $0["bundle_id"] as? String })
            apps.removeAll { !isSelf($0) && !ids.contains($0.bundleID) }
            for a in live {
                let bid = a["bundle_id"] as? String ?? ""
                if !apps.contains(where: { $0.bundleID == bid }) {
                    apps.append(SideloadedApp(bundleID: bid, name: a["name"] as? String ?? bid, version: a["version"] as? String ?? "", expires: nil, ipaFile: nil))
                }
            }
            syncSelfRecord()
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

    func install(ipa: URL, upgrade: Bool = false, signer: String? = nil, selfRefresh: Bool = false, versionUpdate: AppUpdateRelease? = nil) async {
        guard canSign else { errorText = "Hãy đăng nhập Apple ID hoặc nhập chứng chỉ trước (tab Tài khoản)."; return }
        // Imported certificate = KSign-style OTA install, never VPN. Only Apple ID signing needs pairing + LocalDevVPN.
        let early = signer ?? apps.first { $0.ipaFile == ipa.lastPathComponent }.map(signerOf) ?? defaultSigner
        if early != "cert" {
            guard hasPairing else { errorText = "Hãy nhập file ghép nối trước (tab Thiết bị)."; return }
            // Real reachability first (62078 connect/refused ≈ 1 s). Only hand off to LocalDevVPN when it's really down.
            if !vpnActive {
                if UIApplication.shared.applicationState == .active && (UserDefaults.standard.object(forKey: "vpnAutoOff") as? Bool ?? true) {
                    if let release = versionUpdate { pendingVPNAction = .versionUpdate(ipa, early, release) }
                    else if selfRefresh { pendingVPNAction = .refreshSelf(signer) }
                    else { pendingVPNAction = .install(ipa, upgrade, signer) }
                    LoopbackVPN.turnOn(); return
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
            if selfRefresh { req["self_refresh"] = true; req["installed_bundle_id"] = isideloadBundleID }
            req["udid"] = UserDefaults.standard.string(forKey: "deviceUDID") ?? ""
            let otaIPA = FileManager.default.temporaryDirectory.appendingPathComponent("ota-\(UUID().uuidString).ipa")
            if who != "cert" && !vpnActive { throw CoreError(message: "Không thấy thiết bị qua LocalDevVPN (10.7.0.1). Hãy bật LocalDevVPN.") }
            if who == "cert" && UIApplication.shared.applicationState != .active {
                throw CoreError(message: "App ký bằng chứng chỉ cần mở iContainer để cài lại (iOS hiện hộp thoại Cài đặt).")
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
            if let c = r["lc_cert"] as? [String: Any] { lastLCCert = c; lastLCCertSigner = who }
            // A different team may produce a second app, not an in-place replacement.
            // Keep the old identity in the list until it is actually uninstalled.
            apps.removeAll { $0.bundleID == bid }
            apps.append(rec); save()
            if info["icon_path"] != nil { IconCache.adopt(tmpIcon, for: bid) }
            infoText = Self.doneLine(rec.name, exp) + (notes.isEmpty ? "" : "\n" + notes.joined(separator: " "))
            if r["recipient_setup_verified"] as? Bool == false {
                infoText = (infoText ?? "Đã cài app.") + "\nThiết lập tự gia hạn chưa hoàn tất: " + (r["recipient_setup_error"] as? String ?? "chưa xác minh khóa ký và ghép nối")
            }
        }
    }

    func refresh(_ app: SideloadedApp) async {
        if isSelf(app) { await refreshSelf(); return }
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

    /// Re-sign and re-install iContainer itself from its own running bundle (no PC needed).
    /// iOS terminates the app while installation_proxy replaces it; reopen afterwards.
    func refreshSelf(signer: String? = nil) async {
        guard !busy else { return }
        errorText = nil
        let who = signer ?? selfApp.map(signerOf) ?? defaultSigner
        guard signers.contains(who) else {
            errorText = "Chọn tài khoản ký cho iContainer: đăng nhập Apple ID trong tab Tài khoản, hoặc nhập chứng chỉ của bạn."; return
        }
        if let problem = selfSignerProblem(who) { errorText = problem; return }
        if who != "cert" {
            guard hasPairing else { errorText = "Máy này chưa tự ghép nối. Vào Thiết bị › Ghép nối ngay trên máy, rồi thử Làm mới iContainer."; return }
            if !vpnActive { pendingVPNAction = .refreshSelf(who); LoopbackVPN.turnOn(); return }
        }
        syncSelfRecord(signer: who)
        let out = Self.ipaDir.appendingPathComponent("iContainer-self.ipa")
        try? FileManager.default.createDirectory(at: Self.ipaDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        do {
            _ = try await run(["op": "pack_self", "app_path": Bundle.main.bundleURL.path, "out_path": out.path])
        } catch { errorText = "Không đóng gói được iContainer: \(error)"; return }
        infoText = nil
        // iOS usually kills the app when the install finishes: the push happens on next launch.
        markLCCertPending()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "selfUpdatePending")
        UserDefaults.standard.set(selfApp?.expires?.timeIntervalSince1970 ?? 0, forKey: "selfPreviousExpiry")
        await install(ipa: out, upgrade: true, signer: who, selfRefresh: true)
        // iOS replaces (and kills) the running app; the connection often drops right after the upload.
        if progress >= 0.7, let e = errorText?.lowercased(), ["socket", "io failed", "broken pipe", "connection", "reset", "eof"].contains(where: { e.contains($0) }) {
            errorText = nil
            infoText = "Đã gửi bản ký lại. iOS đang thay iContainer — mở lại app để xác nhận."
        } else if errorText != nil {
            UserDefaults.standard.removeObject(forKey: "selfUpdatePending")
        }
    }

    /// On launch after a self re-sign: confirm via the new embedded.mobileprovision (written by the install).
    func checkSelfUpdate() {
        let t = UserDefaults.standard.double(forKey: "selfUpdatePending")
        guard t > 0 else { return }
        UserDefaults.standard.removeObject(forKey: "selfUpdatePending")
        let previousExpiry = UserDefaults.standard.double(forKey: "selfPreviousExpiry")
        UserDefaults.standard.removeObject(forKey: "selfPreviousExpiry")
        guard let state = InstalledAppState.read(bundleURL: Bundle.main.bundleURL), let expiry = state.expires,
              expiry > Date(), let created = state.createdAt,
              created.timeIntervalSince1970 >= t - 120,
              previousExpiry == 0 || expiry.timeIntervalSince1970 > previousExpiry else {
            infoText = "Chưa xác nhận được hạn ký mới của iContainer. Hãy kiểm tra ngày hết hạn trong tab Ứng dụng và thử lại nếu cần."
            return
        }
        syncSelfRecord()
        infoText = "Đã ký lại iContainer ✓ · hết hạn " + expiry.formatted(date: .abbreviated, time: .omitted)
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
                    c.title = "Mã ghép nối iContainer"; c.body = pin; c.sound = .default
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
            pairingVerified = false; pairingCheckError = nil; deviceLine = ""
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

    /// Re-signs due apps from stored IPAs (others first, iContainer itself last). Returns success.
    @discardableResult
    func refreshAll(includeSelf: Bool, onlyDue: Bool, background: Bool, onlySelf: Bool = false, signerFilter: String? = nil) async -> Bool {
        guard !busy else { return false }
        errorText = nil
        syncSelfRecord()
        let dueAny: (SideloadedApp) -> Bool = { !onlyDue || ($0.daysLeft ?? 0) < AutoRefresh.thresholdDays }
        let requested = apps.filter { dueAny($0) && (isSelf($0) ? includeSelf : !onlySelf)
            && (signerFilter == nil || signerOf($0) == signerFilter) }
        let needVPN = requested.contains { signerOf($0) != "cert" }
        if needVPN && !vpnActive {
            if !background { pendingVPNAction = .refreshAll(includeSelf: includeSelf, onlyDue: onlyDue, onlySelf: onlySelf, signer: signerFilter); LoopbackVPN.turnOn(); return false }
            AutoRefresh.notify("iContainer chưa ký lại", "LocalDevVPN chưa bật. Bật VPN rồi chạy lại.")
            return false
        }
        var ok: [String] = [], failed: [String] = []
        if !onlySelf {
            for app in requested where !isSelf(app) {
                errorText = nil
                await refresh(app)
                if errorText == nil { ok.append(Self.doneLine(app.name, apps.first { $0.name == app.name }?.expires).replacingOccurrences(of: "Đã ký ", with: "")) } else { failed.append("\(app.name): \(errorText ?? "")") }
            }
        }
        UserDefaults.standard.set(Date(), forKey: "lastRefresh")
        let selfDue = requested.contains(where: isSelf)
        let summary = (ok.isEmpty ? "" : "Đã ký " + ok.joined(separator: "; ") + ". ")
            + (failed.isEmpty ? "" : "Lỗi: " + failed.joined(separator: "; "))
        if includeSelf && selfDue {
            AutoRefresh.notify("iContainer đang tự ký lại", summary + " iContainer sẽ tự thoát khi cài xong.")
            await refreshSelf()   // process is usually terminated here on success
            if let e = errorText { AutoRefresh.notify("iContainer ký lại thất bại", e); return false }
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
    /// Remove from iContainer's list: stops re-signing it and frees its slot (slots are counted from this list).
    func removeFromList(_ app: SideloadedApp) {
        guard !isSelf(app) else { return }
        apps.removeAll { $0.bundleID == app.bundleID }; save()
        if let f = app.ipaFile { try? FileManager.default.removeItem(at: Self.ipaDir.appendingPathComponent(f)) }
        try? FileManager.default.removeItem(at: IconCache.file(app.bundleID))
    }
    /// Uninstall from the device via installation_proxy (needs LocalDevVPN like install), then drop from the list.
    func uninstall(_ app: SideloadedApp) async {
        guard !isSelf(app) else { errorText = "iContainer quản lý việc gia hạn cho chính nó. Muốn gỡ hoàn toàn, hãy gỡ từ màn hình chính của iOS."; return }
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
    enum VPNAction {
        case refreshAll(includeSelf: Bool, onlyDue: Bool = false, onlySelf: Bool = false, signer: String? = nil)
        case refreshSelf(String?)
        case versionUpdate(URL, String, AppUpdateRelease)
        case install(URL, Bool, String?)
        case liveContainerInstall(LiveContainerInstallPlan)
        case uninstall(SideloadedApp)
    }
    var pendingVPNAction: VPNAction?
    func resumeAfterVPN() async {
        guard let a = pendingVPNAction else { return }
        var ok = false
        for _ in 0..<8 { if vpnActive { ok = true; break }; try? await Task.sleep(nanoseconds: 600_000_000) }   // retry 62078 ~5 s
        guard ok else { pendingVPNAction = nil; errorText = "Không kết nối được tới thiết bị qua LocalDevVPN (10.7.0.1) sau ~5 giây. Mở LocalDevVPN, bấm Connect rồi thử lại."; return }
        pendingVPNAction = nil
        switch a {
        case .refreshAll(let s, let due, let own, let signer):
            await refreshAll(includeSelf: s, onlyDue: due, background: false, onlySelf: own, signerFilter: signer)
        case .refreshSelf(let signer): await refreshSelf(signer: signer)
        case .versionUpdate(let url, let signer, let release): await completeVersionUpdate(ipa: url, signer: signer, release: release)
        case .install(let u, let up, let sg): await install(ipa: u, upgrade: up, signer: sg)
        case .liveContainerInstall(let plan): await completeLiveContainerInstall(plan)
        case .uninstall(let app): await uninstall(app)
        }
        vpnJobDone()
    }

    /// On open/foreground: re-sign anything expiring within 2 days (VPN needed).
    func foregroundCheck() async {
        guard !peerBusy, !busy, !updatingApp else { return }
        let resuming = pendingVPNAction != nil
        await resumeAfterVPN()
        if resuming { return }
        await checkAppVersion()
        if await automaticVersionUpdateIfReady() { return }
        guard UserDefaults.standard.object(forKey: "fgRefresh") as? Bool ?? true, !busy, canSign,
              hasPairing || defaultSigner == "cert" else { return }
        let urgent = apps.contains { ($0.daysLeft ?? 99) < 2 }
        if urgent { if vpnActive { await refreshAll(includeSelf: true, onlyDue: true, background: false) }
                    else if apps.contains(where: { ($0.daysLeft ?? 99) < 2 && signerOf($0) != "cert" }) { pendingVPNAction = .refreshAll(includeSelf: true); LoopbackVPN.turnOn() }
                    else { await refreshAll(includeSelf: true, onlyDue: true, background: false) } }
    }

    func installLiveContainer(signer: String?) async {
        guard !busy, !liveContainerInstallActive else { return }
        errorText = nil; infoText = nil
        do {
            // Validate before downloading; there is no fallback to the old/default source.
            _ = try LiveContainerInstallPlan(ipa: Self.ipaDir, upgrade: false, selectedSigner: signer, availableSigners: signers)
            busy = true
            stage = "Đang tải LiveContainer…"
            let r = try await LiveContainer.latest()
            let ipa = try await LiveContainer.download(r, into: Self.ipaDir)
            let plan = try LiveContainerInstallPlan(ipa: ipa, upgrade: liveContainerInstalled != nil,
                selectedSigner: signer, availableSigners: signers)
            busy = false
            await completeLiveContainerInstall(plan)
        } catch { busy = false; errorText = error.localizedDescription }
        vpnJobDone()
    }

    private var liveContainerInstallActive = false
    private func completeLiveContainerInstall(_ plan: LiveContainerInstallPlan) async {
        guard !busy, !liveContainerInstallActive else { return }
        guard signers.contains(plan.signer) else { errorText = LiveContainerInstallPlan.Invalid.unavailable.localizedDescription; return }
        if plan.signer != "cert" {
            guard hasPairing else { errorText = "Cần file ghép đôi để ký bằng Apple ID. Vào Thiết bị để thiết lập và kiểm tra kết nối."; return }
            if !vpnActive {
                pendingVPNAction = .liveContainerInstall(plan)
                LoopbackVPN.turnOn(); return
            }
        }
        liveContainerInstallActive = true
        defer { liveContainerInstallActive = false }
        lastLCCert = nil; lastLCCertSigner = nil; errorText = nil
        await install(ipa: plan.ipa, upgrade: plan.upgrade, signer: plan.signer)
        if case .install(let url, _, let signer) = pendingVPNAction,
           url == plan.ipa, signer == plan.signer {
            pendingVPNAction = .liveContainerInstall(plan)
        }
        guard errorText == nil, pendingVPNAction == nil else { return }
        guard let installed = apps.last(where: {
            LiveContainerSigning.isContainer($0.bundleID) && $0.ipaFile == plan.ipa.lastPathComponent && $0.signer == plan.signer
        }) else {
            errorText = "Chưa xác định được bản LiveContainer đã cài bằng nguồn vừa chọn; chưa tự gửi chứng chỉ."; return
        }
        liveContainerActiveBundleID = installed.bundleID
        UserDefaults.standard.set(false, forKey: Self.lcPendingKey)
        do {
            let certificate: [String: Any]
            if let c = lastLCCert, lastLCCertSigner == plan.signer { certificate = c }
            else { certificate = try await run(base("export_cert", signer: plan.signer)) }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try sendCertToLiveContainer(certificate, sourceSigner: plan.signer)
        } catch { errorText = "LiveContainer đã được cài, nhưng chưa chuyển được chứng chỉ đã chọn: \(error.localizedDescription)" }
    }

    // MARK: LiveContainer certificate
    var lastLCCert: [String: Any]?
    private var lastLCCertSigner: String?
    private static let lcPendingKey = "lcCertPending"

    /// After a successful re-sign: remember to push the current certificate to LiveContainer.
    func markLCCertPending() {
        #if ICONTAINER
        return
        #else
        if liveContainerInstalled != nil { UserDefaults.standard.set(true, forKey: Self.lcPendingKey) }
        #endif
    }

    /// Pushes the certificate if a re-sign left it pending. Only works in the foreground
    /// (URLs can't be opened from a background task); otherwise it waits for the next launch/foreground.
    func pushPendingLCCert() async {
        #if ICONTAINER
        return
        #else
        guard UserDefaults.standard.bool(forKey: Self.lcPendingKey) else { return }
        guard liveContainerInstalled != nil else { UserDefaults.standard.set(false, forKey: Self.lcPendingKey); return }
        guard UIApplication.shared.applicationState == .active, !busy, !liveContainerInstallActive,
              pendingVPNAction == nil, liveContainerCertificateFile == nil, canSign else { return }
        guard let signer = lcSigner, signers.contains(signer) else {
            UserDefaults.standard.set(false, forKey: Self.lcPendingKey); return
        }
        do {
            let r = try await run(base("export_cert", signer: signer))
            try sendCertToLiveContainer(r, sourceSigner: signer)
            UserDefaults.standard.set(false, forKey: Self.lcPendingKey)
        } catch { errorText = "Chưa gửi được chứng chỉ sang LiveContainer: \(error.localizedDescription)" }
        #endif
    }

    /// Exports the certificate this Apple ID signs with (.p12 + password) and opens
    /// livecontainer://certificate so LiveContainer stores it for JIT-less mode.
    func exportCertToLiveContainer() async {
        guard !busy, !liveContainerInstallActive else { return }
        guard let signer = lcSigner, signers.contains(signer) else {
            errorText = "Chưa xác định được nguồn ký của LiveContainer, hoặc nguồn đó chưa sẵn sàng. Chọn Cài lại LiveContainer để chọn rõ Apple ID/chứng chỉ, hoặc đăng nhập lại tài khoản đã ký."; return
        }
        guard liveContainerInstalled != nil || UIApplication.shared.canOpenURL(URL(string: "livecontainer://")!) else {
            errorText = "Chưa cài LiveContainer. Hãy bấm Cài LiveContainer trước."; return
        }
        await guarded {
            let r = try await run(base("export_cert", signer: signer))
            try sendCertToLiveContainer(r, sourceSigner: signer)
        }
    }

    private func sendCertToLiveContainer(_ c: [String: Any], sourceSigner: String) throws {
        guard let b64 = c["p12_base64"] as? String, let pw = c["password"] as? String else {
            throw CoreError(message: "Không có dữ liệu chứng chỉ.")
        }
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        let enc = { (x: String) in x.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        guard let url = URL(string: "livecontainer://certificate?cert=\(enc(b64))&password=\(enc(pw))") else {
            throw CoreError(message: "Không tạo được liên kết cho LiveContainer.")
        }
        guard let data = Data(base64Encoded: b64) else { throw CoreError(message: "Dữ liệu chứng chỉ không hợp lệ.") }
        let manual = LiveContainerSigning.needsManualCertificateImport(apps: apps)
        let file = Self.docs.appendingPathComponent(manual ? "LiveContainer-cert-\(UUID().uuidString).p12" : "LiveContainer-cert.p12")
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        if manual {
            infoText = nil
            liveContainerCertificateFile = LiveContainerCertificateFile(url: file, password: pw, sourceLabel: signerLabel(sourceSigner))
            return
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
    var lcSigner: String? { liveContainerInstalled?.signer }
    var liveContainerInstalled: SideloadedApp? { LiveContainerSigning.latestInstalled(in: apps, activeBundleID: liveContainerActiveBundleID) }

    func handleURL(_ url: URL) {
        if url.scheme == "icontainer" {
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
