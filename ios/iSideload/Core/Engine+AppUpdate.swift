import Foundation
import UIKit

@MainActor
extension Engine {
    var installedVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var installedBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }

    func confirmVersionUpdate() {
        guard let data = UserDefaults.standard.data(forKey: "pendingVersionUpdate"),
              let release = try? JSONDecoder().decode(AppUpdateRelease.self, from: data) else { return }
        UserDefaults.standard.removeObject(forKey: "pendingVersionUpdate")
        if installedVersion == release.version, installedBuild == release.build {
            infoText = "Đã cập nhật phiên bản " + release.label + " ✓"
        } else {
            updateStatus = "Chưa xác nhận cài phiên bản " + release.label + ". Bản hiện tại: " + installedVersion + " · build " + installedBuild
        }
    }

    func checkAppVersion(manual: Bool = false) async {
        guard !checkingAppUpdate else { return }
        let defaults = UserDefaults.standard
        if !manual {
            guard defaults.object(forKey: "checkAppVersions") as? Bool ?? true else { return }
            let last = defaults.double(forKey: "lastAppVersionCheck")
            guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        }
        checkingAppUpdate = true
        defer { checkingAppUpdate = false }
        do {
            guard let product = AppUpdates.product(bundleID: isideloadBundleID) else { return }
            let release = try await AppUpdates.latest(product: product)
            defaults.set(Date().timeIntervalSince1970, forKey: "lastAppVersionCheck")
            if let release, release.isNewer(than: installedVersion, build: installedBuild) {
                appUpdate = release
                updateStatus = "Có bản mới: " + release.label
            } else {
                appUpdate = nil
                updateStatus = "Đang dùng bản mới nhất được phát hành cho ứng dụng này."
            }
        } catch {
            updateStatus = "Chưa kiểm tra được: " + error.localizedDescription
            if manual { appUpdate = nil }
        }
    }

    func updateApplication() async {
        guard !busy, !peerBusy, !updatingApp, pendingVPNAction == nil, let release = appUpdate else { return }
        guard release.isNewer(than: installedVersion, build: installedBuild) else { return }
        let who = selfApp.map(signerOf) ?? "self"
        guard signers.contains(who) else {
            errorText = "Chọn tài khoản gia hạn của bản đang cài trong tab Ứng dụng trước khi cập nhật."; return
        }
        if let problem = selfSignerProblem(who) { errorText = problem; return }
        guard who == "cert" || hasPairing else {
            errorText = "Nhập file ghép đôi và kiểm tra kết nối trong tab Thiết bị trước khi cập nhật."; return
        }
        updatingApp = true; busy = true; errorText = nil; stage = "Đang tải bản cập nhật " + release.label
        let folder = Self.ipaDir.appendingPathComponent("AppUpdate", isDirectory: true)
        let input = folder.appendingPathComponent("download.ipa")
        let prepared = Self.ipaDir.appendingPathComponent("app-update-\(UUID().uuidString).ipa")
        do {
            try release.validate()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (temporary, response) = try await session.download(for: URLRequest(url: release.url, timeoutInterval: 180))
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(release.bytes) else {
                throw AppUpdateError.invalid("Tải IPA chưa hoàn tất hoặc kích thước không khớp.")
            }
            try? FileManager.default.removeItem(at: input)
            try FileManager.default.moveItem(at: temporary, to: input)
            defer { try? FileManager.default.removeItem(at: input) }
            _ = try await run(["op": "prepare_self_update", "ipa_path": input.path,
                              "host_path": Bundle.main.bundleURL.path, "out_path": prepared.path,
                              "installed_bundle_id": isideloadBundleID, "sha256": release.sha256,
                              "version": release.version, "build": release.build])
            busy = false; updatingApp = false
            await completeVersionUpdate(ipa: prepared, signer: who, release: release)
        } catch {
            busy = false; updatingApp = false; errorText = error.localizedDescription
            try? FileManager.default.removeItem(at: prepared)
        }
    }

    func completeVersionUpdate(ipa: URL, signer: String, release: AppUpdateRelease) async {
        guard !busy, !peerBusy else { return }
        guard signers.contains(signer) else { errorText = "Tài khoản ký chưa sẵn sàng."; return }
        if let problem = selfSignerProblem(signer) { errorText = problem; return }
        if signer != "cert", !vpnActive {
            pendingVPNAction = .versionUpdate(ipa, signer, release)
            LoopbackVPN.turnOn(); return
        }
        if let data = try? JSONEncoder().encode(release) { UserDefaults.standard.set(data, forKey: "pendingVersionUpdate") }
        infoText = nil; errorText = nil
        await install(ipa: ipa, upgrade: true, signer: signer, selfRefresh: true, versionUpdate: release)
        if pendingVPNAction != nil { return }
        if progress >= 0.7, let text = errorText?.lowercased(),
           ["socket", "io failed", "broken pipe", "connection", "reset", "eof"].contains(where: { text.contains($0) }) {
            errorText = nil
        }
        if errorText == nil {
            infoText = "Đã gửi bản cập nhật " + release.label + ". Mở lại app sau khi iOS cài xong để xác nhận."
        } else { UserDefaults.standard.removeObject(forKey: "pendingVersionUpdate") }
        vpnJobDone()
    }

    func automaticVersionUpdateIfReady() async -> Bool {
        guard UserDefaults.standard.bool(forKey: "autoInstallAppUpdates"),
              let release = appUpdate, !busy, !peerBusy, pendingVPNAction == nil,
              UIApplication.shared.applicationState == .active else { return false }
        let who = selfApp.map(signerOf) ?? "self"
        guard signers.contains(who), selfSignerProblem(who) == nil, who == "cert" || hasPairing else { return false }
        let key = release.key + "/" + Date().formatted(.iso8601.year().month().day())
        guard UserDefaults.standard.string(forKey: "appVersionAutoAttempt") != key else { return false }
        UserDefaults.standard.set(key, forKey: "appVersionAutoAttempt")
        await updateApplication()
        return true
    }
}
