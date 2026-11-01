import Foundation
import SwiftUI

@MainActor
final class Engine: ObservableObject {
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

    private func save() { if let d = try? JSONEncoder().encode(apps) { try? d.write(to: Self.appsURL) } }

    private func base(_ op: String) -> [String: Any] {
        ["op": op, "apple_id": appleID, "password": Keychain.load(appleID) ?? "", "anisette_url": anisetteURL,
         "storage_dir": Self.storage.path, "pairing_path": Self.pairingURL.path, "target": vpnTarget]
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
            apps.removeAll { $0.bundleID == bid }
            apps.append(rec); save()
            infoText = "Đã cài \(rec.name)" + (exp.map { ", hết hạn \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
        }
    }

    func refresh(_ app: SideloadedApp) async {
        guard let f = app.ipaFile, FileManager.default.fileExists(atPath: Self.ipaDir.appendingPathComponent(f).path) else {
            errorText = "Không còn file IPA gốc của \(app.name). Hãy chọn lại IPA để cài đè."; return
        }
        await install(ipa: Self.ipaDir.appendingPathComponent(f), upgrade: true)
    }

    // MARK: Certificates
    @Published var certs: [[String: Any]] = []
    func loadCerts() async { await guarded { certs = (try await run(base("certs"))["certs"] as? [[String: Any]]) ?? [] } }
    func revoke(_ serial: String) async {
        await guarded { var r = base("revoke_cert"); r["serial"] = serial; _ = try await run(r); certs.removeAll { $0["serial"] as? String == serial } }
    }
}
