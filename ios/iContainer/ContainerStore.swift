#if !SICONTAINER_RUNNER
import Foundation
import Network
import UIKit

@MainActor
final class ContainerStore: ObservableObject {
    static let shared = ContainerStore()
    @Published var guests: [ContainerGuest] = []
    @Published var working = false
    @Published var message: String?
    @Published var failure: String?
    @Published var readyToReopen = false
    @Published var probeSummary: [String: Any] = [:]
    private var shortcutListener: NWListener?
    private var shortcutPayloads: [String: (mime: String, data: Data)] = [:]

    static var root: URL { URL(fileURLWithPath: ICContainerRoot(), isDirectory: true) }

    init() {
        reload()
        failure = ICLastLaunchError()
    }

    var sharedGroupAvailable: Bool {
        (probeSummary["shared_group_available"] as? Bool) == true
    }

    var sharedGroupID: String {
        (probeSummary["shared_group_id"] as? String) ?? ""
    }

    var runner1BundleID: String? {
        let probe = probeSummary["runner1_probe"] as? [String: Any]
        if let bid = probe?["bundle_id"] as? String, !bid.isEmpty { return bid }
        return nil
    }

    var runner1AliveInRAM: Bool {
        (probeSummary["runner1_alive_in_ram"] as? Bool) == true
    }

    var runner1ActiveGuestName: String? {
        guard runner1AliveInRAM,
              let reg = probeSummary["slot_registry"] as? [String: Any],
              let slots = reg["slots"] as? [String: Any],
              let r1 = slots["runner1"] as? [String: Any],
              let name = r1["guest_name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    func reload() {
        probeSummary = ICReadProbeSummary() as? [String: Any] ?? [:]
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        guests = dirs.compactMap { dir in
            guard UUID(uuidString: dir.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let guest = try? JSONDecoder().decode(ContainerGuest.self, from: data),
                  guest.id == dir.lastPathComponent else { return nil }
            return guest
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func request(_ op: String, id: String) -> [String: Any] {
        ["op": op, "guest_id": id, "container_root": Self.root.path]
    }

    func importIPA(_ url: URL, engine: Engine) async {
        guard !working && !engine.busy && !engine.peerBusy else { return }
        working = true; defer { working = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            var r = request("container_import", id: UUID().uuidString)
            r["ipa_path"] = url.path
            let result = try await engine.containerOperation(r)
            reload()
            message = "Đã nhập app vào SIContainer (dữ liệu chung trong App Group). Chọn Chuẩn bị để ký bản chạy cho cả Con Chính và Con Phụ 1."
            if let guest = result["guest"] as? [String: Any], guest["main_app_only"] as? Bool == true {
                message = (message ?? "") + "\nGói có extension hoặc Apple Watch: bản gốc được giữ nguyên, Container chỉ chuẩn bị và chạy app chính trên iPhone."
            }
        } catch { failure = error.localizedDescription }
    }

    func prepare(_ guest: ContainerGuest, signer: String, engine: Engine) async {
        guard !working && !engine.busy && !engine.peerBusy else { return }
        working = true; defer { working = false }
        do {
            var req = request("container_prepare", id: guest.id)
            if let r1 = runner1BundleID, let own = Bundle.main.bundleIdentifier {
                req["target_bundle_ids"] = [own, r1]
            }
            try await engine.prepareContainerGuest(req, signer: signer)
            reload()
            message = "Đã chuẩn bị \(guest.name) cho cả SIContainer Chính và Phụ 1. Bạn có thể bấm Chạy trên Phụ 1 để mở ngay không cần đóng app!"
        } catch { failure = error.localizedDescription }
    }

    func launchInRunner1(_ guest: ContainerGuest) {
        guard !working else { return }
        guard guest.readyToLaunch else {
            failure = "Chọn Chuẩn bị lại để tạo bản chạy cho SIContainer Phụ 1. App gốc và dữ liệu được giữ nguyên."
            return
        }
        var error: NSError?
        guard let plan = ICPrepareRunnerLaunch(guest.id, "runner1", &error) as? [String: Any],
              let urlStr = plan["url"] as? String,
              let url = URL(string: urlStr) else {
            failure = error?.localizedDescription ?? "Không tạo được lệnh điều phối sang SIContainer Phụ 1."
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] ok in
            if !ok {
                Task { @MainActor in
                    self?.failure = "Không mở được SIContainer Phụ 1. Hãy kiểm tra đã cài SIContainer Phụ 1 trên máy chưa."
                }
            }
        }
    }

    func launchLocalFallback(_ guest: ContainerGuest) {
        guard !working else { return }
        guard guest.readyToLaunch else {
            failure = "Chọn Chuẩn bị lại để sửa bản chạy cũ. App gốc và dữ liệu của bạn được giữ nguyên."
            return
        }
        do {
            var error: NSError?
            guard ICQueueGuest(guest.id, &error) else {
                throw CoreError(message: error?.localizedDescription ?? "Không tạo được yêu cầu mở app.")
            }
            readyToReopen = true
        } catch { failure = error.localizedDescription }
    }

    func launchFromShortcut(guestID: String) {
        reload()
        guard let guest = guests.first(where: { $0.id.caseInsensitiveCompare(guestID) == .orderedSame }) else {
            failure = "Không tìm thấy app của Shortcut này trong SIContainer."
            return
        }
        if sharedGroupAvailable {
            launchInRunner1(guest)
        } else {
            launchLocalFallback(guest)
        }
    }

    func completeRunnerSwitch(slot: String, requestID: String) {
        guard let url = ICCompleteRunnerSwitchURL(slot, requestID) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    func probeRunner1() {
        ICRecordRoleProbe()
        reload()
        guard let url = URL(string: "sicontainer-runner1://probe?return=1") else { return }
        UIApplication.shared.open(url, options: [:]) { [weak self] ok in
            if !ok {
                Task { @MainActor in
                    self?.failure = "Chưa mở được SIContainer Phụ 1 (sicontainer-runner1://). Hãy cài SIContainer Phụ 1 trước."
                }
            }
        }
    }

    func remove(_ guest: ContainerGuest, engine: Engine) async {
        guard !working && !engine.busy && !engine.peerBusy else { return }
        working = true; defer { working = false }
        do {
            _ = try await engine.containerOperation(request("container_remove", id: guest.id))
            reload()
        } catch { failure = error.localizedDescription }
    }

    // MARK: - Home Screen Shortcut Generator (WebClip .mobileconfig & Safari Page)

    private func extractGuestIconPNG(for guest: ContainerGuest) -> Data? {
        let appDir = Self.root.appendingPathComponent(guest.id).appendingPathComponent("Original.app")
        guard let files = try? FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let candidates = files.filter {
            let name = $0.lastPathComponent.lowercased()
            return name.hasSuffix(".png") && (name.contains("appicon") || name.contains("icon"))
        }
        var best: URL?
        var bestSize = 0
        for file in candidates {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > bestSize { bestSize = size; best = file }
        }
        guard let chosen = best, let raw = try? Data(contentsOf: chosen), let img = UIImage(data: raw) else { return nil }
        return img.pngData()
    }

    private func buildWebClipMobileConfig(for guest: ContainerGuest) -> Data? {
        let launchURL = "sicontainer://launch?guest=\(guest.id)"
        var clip: [String: Any] = [
            "PayloadType": "com.apple.webclip.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.hongson117.sicontainer.webclip.\(guest.id)",
            "PayloadUUID": guest.id,
            "PayloadDisplayName": guest.name.isEmpty ? guest.bundleID : guest.name,
            "Label": guest.name.isEmpty ? guest.bundleID : guest.name,
            "URL": launchURL,
            "FullScreen": true,
            "Precomposed": true,
            "IsRemovable": true
        ]
        if let iconData = extractGuestIconPNG(for: guest) {
            clip["Icon"] = iconData
        }
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.hongson117.sicontainer.shortcut.\(guest.id)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Shortcut: \(guest.name.isEmpty ? guest.bundleID : guest.name)",
            "PayloadDescription": "Tạo biểu tượng mở nhanh \(guest.name) qua SIContainer trên màn hình chính.",
            "PayloadOrganization": "SIContainer",
            "PayloadContent": [clip]
        ]
        return try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    private func buildSafariShortcutHTML(for guest: ContainerGuest) -> Data {
        let title = (guest.name.isEmpty ? guest.bundleID : guest.name)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let launchURL = "sicontainer://launch?guest=\(guest.id)"
        let iconB64 = extractGuestIconPNG(for: guest)?.base64EncodedString() ?? ""
        let iconLink = iconB64.isEmpty ? "" : "<link rel=\"apple-touch-icon\" href=\"data:image/png;base64,\(iconB64)\">"
        let html = """
        <!doctype html>
        <html lang="vi"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-title" content="\(title)">
        \(iconLink)
        <title>\(title)</title>
        <style>body{font-family:-apple-system,sans-serif;padding:28px;text-align:center;background:#111;color:#fff}
        .card{background:#1c1c1e;border-radius:18px;padding:24px;margin-top:20px}
        a.btn{display:inline-block;background:#0a84ff;color:#fff;text-decoration:none;padding:12px 20px;border-radius:12px;font-weight:600;margin-top:14px}</style>
        </head><body>
        <h2>\(title)</h2>
        <div class="card">
        <p>1. Nếu đang mở từ Màn hình chính, đang chuyển sang <b>\(title)</b>…</p>
        <p>2. Để thêm ra Màn hình chính: bấm nút <b>Chia sẻ</b> ở thanh dưới Safari → chọn <b>Thêm vào MH chính</b>.</p>
        <a class="btn" href="\(launchURL)">Mở \(title) ngay</a>
        </div>
        <script>
        if (window.navigator.standalone || location.hash === '#launch') {
            window.location.replace('\(launchURL)');
        }
        </script>
        </body></html>
        """
        return Data(html.utf8)
    }

    func openShortcutInstaller(for guest: ContainerGuest, mode: String) {
        guard let configData = buildWebClipMobileConfig(for: guest) else {
            failure = "Không tạo được cấu hình Shortcut."
            return
        }
        let htmlData = buildSafariShortcutHTML(for: guest)
        shortcutPayloads["/webclip.mobileconfig"] = ("application/x-apple-aspen-config", configData)
        shortcutPayloads["/safari"] = ("text/html; charset=utf-8", htmlData)

        if shortcutListener == nil {
            guard let listener = try? NWListener(using: .tcp, on: .any) else {
                failure = "Không mở được cổng máy chủ nội bộ cho Shortcut."
                return
            }
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    Task { @MainActor in
                        guard let self else { conn.cancel(); return }
                        let req = String(data: data ?? Data(), encoding: .utf8) ?? ""
                        let firstLine = req.split(separator: "\r\n").first ?? ""
                        let rawPath = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/safari"
                        let path = rawPath.components(separatedBy: "?").first ?? "/safari"
                        let payload = self.shortcutPayloads[path] ?? self.shortcutPayloads["/safari"]!
                        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(payload.mime)\r\nContent-Length: \(payload.data.count)\r\nConnection: close\r\n\r\n"
                        var response = Data(header.utf8)
                        response.append(payload.data)
                        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
                    }
                }
            }
            listener.start(queue: .main)
            shortcutListener = listener
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let port = self.shortcutListener?.port?.rawValue else { return }
            let path = (mode == "webclip") ? "/webclip.mobileconfig" : "/safari"
            if let url = URL(string: "http://127.0.0.1:\(port)\(path)") {
                UIApplication.shared.open(url)
            }
        }
    }
}
#endif
