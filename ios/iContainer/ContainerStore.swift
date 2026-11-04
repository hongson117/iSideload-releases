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
    private var shortcutPayloads: [String: (mime: String, filename: String?, data: Data)] = [:]
    private var shortcutBgTask: UIBackgroundTaskIdentifier = .invalid
    private var iconCache: [String: UIImage] = [:]

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

    private func openExternalURLWhenActive(_ url: URL, failureMessage: String? = nil, retriesLeft: Int = 16) {
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "SIContainerURLJump") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        func attempt(_ remaining: Int) {
            let state = UIApplication.shared.applicationState
            if state != .active && remaining > 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    attempt(remaining - 1)
                }
                return
            }
            UIApplication.shared.open(url, options: [:]) { [weak self] ok in
                Task { @MainActor in
                    if ok {
                        if bgTask != .invalid {
                            UIApplication.shared.endBackgroundTask(bgTask)
                            bgTask = .invalid
                        }
                    } else if remaining > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                            attempt(remaining - 1)
                        }
                    } else {
                        if bgTask != .invalid {
                            UIApplication.shared.endBackgroundTask(bgTask)
                            bgTask = .invalid
                        }
                        if let msg = failureMessage {
                            self?.failure = msg
                        }
                    }
                }
            }
        }
        attempt(retriesLeft)
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
        openExternalURLWhenActive(
            url,
            failureMessage: "Không mở được SIContainer Phụ 1. Hãy kiểm tra đã cài SIContainer Phụ 1 trên máy chưa."
        )
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
        openExternalURLWhenActive(url)
    }

    func probeRunner1() {
        ICRecordRoleProbe()
        reload()
        guard let url = URL(string: "sicontainer-runner1://probe?return=1") else { return }
        openExternalURLWhenActive(
            url,
            failureMessage: "Chưa mở được SIContainer Phụ 1 (sicontainer-runner1://). Hãy cài SIContainer Phụ 1 trước."
        )
    }

    func remove(_ guest: ContainerGuest, engine: Engine) async {
        guard !working && !engine.busy && !engine.peerBusy else { return }
        working = true; defer { working = false }
        do {
            _ = try await engine.containerOperation(request("container_remove", id: guest.id))
            reload()
        } catch { failure = error.localizedDescription }
    }

    // MARK: - Home Screen Shortcut Generator (WebClip .mobileconfig & Direct Safari Launcher)

    func guestIconImage(for guest: ContainerGuest) -> UIImage? {
        if let cached = iconCache[guest.id] { return cached }
        let appDir = Self.root.appendingPathComponent(guest.id).appendingPathComponent("Original.app")
        var found: UIImage?

        if let bundle = Bundle(url: appDir) {
            let info = bundle.infoDictionary ?? [:]
            var iconNames: [String] = []
            if let icons = info["CFBundleIcons"] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                if let files = primary["CFBundleIconFiles"] as? [String] {
                    iconNames.append(contentsOf: files.reversed())
                }
                if let name = primary["CFBundleIconName"] as? String {
                    iconNames.append(name)
                }
            }
            if let iconsPad = info["CFBundleIcons~ipad"] as? [String: Any],
               let primary = iconsPad["CFBundlePrimaryIcon"] as? [String: Any],
               let files = primary["CFBundleIconFiles"] as? [String] {
                iconNames.append(contentsOf: files.reversed())
            }
            if let legacyFiles = info["CFBundleIconFiles"] as? [String] {
                iconNames.append(contentsOf: legacyFiles.reversed())
            }
            iconNames.append(contentsOf: ["AppIcon60x60", "AppIcon76x76", "AppIcon", "Icon-60", "Icon"])
            for name in iconNames {
                if let img = UIImage(named: name, in: bundle, compatibleWith: nil), img.size.width >= 40 {
                    found = img
                    break
                }
            }
        }

        if found == nil,
           let files = try? FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: [.fileSizeKey]) {
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
            if let chosen = best, let raw = try? Data(contentsOf: chosen), let img = UIImage(data: raw) {
                found = img
            }
        }

        let size = CGSize(width: 180, height: 180)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            if let img = found {
                UIColor.black.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                img.draw(in: CGRect(origin: .zero, size: size))
            } else {
                let colors = [UIColor(red: 0.35, green: 0.24, blue: 0.92, alpha: 1.0).cgColor,
                              UIColor(red: 0.14, green: 0.09, blue: 0.45, alpha: 1.0).cgColor] as CFArray
                if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    ctx.cgContext.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 180, y: 180), options: [])
                }
                let title = (guest.name.isEmpty ? guest.bundleID : guest.name).trimmingCharacters(in: .whitespacesAndNewlines)
                let letter = String(title.prefix(1)).uppercased()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 92, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let strSize = letter.size(withAttributes: attrs)
                let rect = CGRect(
                    x: (180 - strSize.width) / 2.0,
                    y: (180 - strSize.height) / 2.0,
                    width: strSize.width,
                    height: strSize.height
                )
                letter.draw(in: rect, withAttributes: attrs)
            }
        }
        iconCache[guest.id] = rendered
        return rendered
    }

    private func extractGuestIconPNG(for guest: ContainerGuest) -> Data? {
        guestIconImage(for: guest)?.pngData()
    }

    private func buildWebClipMobileConfig(for guest: ContainerGuest) -> Data? {
        let launchURL = "sicontainer://launch?guest=\(guest.id)"
        let cleanUUID = (UUID(uuidString: guest.id) ?? UUID()).uuidString.uppercased()
        let displayTitle = guest.name.isEmpty ? guest.bundleID : guest.name
        var clip: [String: Any] = [
            "PayloadType": "com.apple.webclip.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.hongson117.sicontainer.webclip.\(cleanUUID)",
            "PayloadUUID": cleanUUID,
            "PayloadDisplayName": displayTitle,
            "Label": displayTitle,
            "URL": launchURL,
            "FullScreen": false,
            "IgnoreManifestScope": true,
            "Precomposed": true,
            "IsRemovable": true
        ]
        if let iconData = extractGuestIconPNG(for: guest) {
            clip["Icon"] = iconData
        }
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.hongson117.sicontainer.shortcut.\(cleanUUID)",
            "PayloadUUID": UUID().uuidString.uppercased(),
            "PayloadDisplayName": "Biểu tượng: \(displayTitle)",
            "PayloadDescription": "Tạo icon mở trực tiếp \(displayTitle) (1 chạm vào thẳng app qua SIContainer).",
            "PayloadOrganization": "SIContainer",
            "PayloadRemovalDisallowed": false,
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
        let iconLink = iconB64.isEmpty ? "" : "<link rel=\"apple-touch-icon\" sizes=\"180x180\" href=\"data:image/png;base64,\(iconB64)\">"
        let imgTag = iconB64.isEmpty ? "" : "<img src=\"data:image/png;base64,\(iconB64)\" style=\"width:76px;height:76px;border-radius:18px;box-shadow:0 6px 20px rgba(0,0,0,.45);margin-bottom:10px\">"
        let html = """
        <!doctype html>
        <html lang="vi"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta name="apple-mobile-web-app-title" content="\(title)">
        \(iconLink)
        <title>\(title)</title>
        <script>
        if ('serviceWorker' in navigator) {
            navigator.serviceWorker.register('/sw.js').catch(function(){});
        }
        if (location.hash !== '#setup') {
            window.location.replace('\(launchURL)');
            setTimeout(function(){ window.location.href = '\(launchURL)'; }, 60);
        } else {
            setTimeout(function(){
                try { history.replaceState(null, '', '/safari/\(guest.id)#launch'); } catch(e) {}
            }, 120);
        }
        </script>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:22px 18px;text-align:center;background:#0d0d11;color:#fff;margin:0}
        .card{background:#1c1c22;border:1px solid rgba(255,255,255,.08);border-radius:18px;padding:20px;margin:14px auto;max-width:420px;text-align:left}
        .title{font-size:21px;font-weight:700;margin:4px 0 2px;text-align:center}
        .sub{font-size:13px;color:#98989f;margin-bottom:14px;text-align:center}
        .step{font-size:15px;line-height:1.55;margin:8px 0;color:#e5e5ea}
        a.btn{display:block;text-align:center;background:#5e5ce6;color:#fff;text-decoration:none;padding:13px 18px;border-radius:13px;font-weight:600;margin-top:12px;font-size:15px}
        a.btn-secondary{background:#2c2c34;color:#fff}
        </style>
        </head><body>
        \(imgTag)
        <div class="title">\(title)</div>
        <div class="sub">Shortcut 1-Chạm mở trực tiếp</div>
        <div class="card">
        <div class="step"><b>Cách 1 (Khuyên dùng · Mở thẳng 1 chạm không qua Safari):</b></div>
        <div class="step">Bấm nút dưới đây → chọn <b>Cho phép</b> → vào <b>Cài đặt → Đã tải về hồ sơ → Cài đặt</b>.</div>
        <a class="btn" href="/webclip/\(guest.id).mobileconfig">Cài Hồ sơ Icon 1-Chạm (.mobileconfig)</a>
        </div>
        <div class="card">
        <div class="step"><b>Cách 2 (Thêm trực tiếp từ trang Safari này):</b></div>
        <div class="step">Trang này đã gắn sẵn lệnh nhảy trực tiếp. Bấm nút <b>Chia sẻ</b> ở thanh dưới Safari → chọn <b>Thêm vào MH chính</b>. Khi chạm icon ngoài màn hình chính sẽ tự nhảy thẳng vào <b>\(title)</b>.</div>
        <a class="btn btn-secondary" href="\(launchURL)">Thử mở \(title) ngay</a>
        </div>
        </body></html>
        """
        return Data(html.utf8)
    }

    private func buildServiceWorkerJS() -> Data {
        let js = """
        const CACHE = 'sicontainer-shortcuts-v2';
        self.addEventListener('install', e => { self.skipWaiting(); });
        self.addEventListener('activate', e => { e.waitUntil(self.clients.claim()); });
        self.addEventListener('fetch', e => {
            if (e.request.method !== 'GET') return;
            e.respondWith(
                fetch(e.request).then(res => {
                    const copy = res.clone();
                    caches.open(CACHE).then(c => c.put(e.request, copy));
                    return res;
                }).catch(() => caches.match(e.request, {ignoreSearch: true}))
            );
        });
        """
        return Data(js.utf8)
    }

    private func beginShortcutServerBackgroundTask() {
        if shortcutBgTask != .invalid {
            UIApplication.shared.endBackgroundTask(shortcutBgTask)
            shortcutBgTask = .invalid
        }
        shortcutBgTask = UIApplication.shared.beginBackgroundTask(withName: "SIContainerShortcutServer") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.shortcutBgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.shortcutBgTask)
                    self.shortcutBgTask = .invalid
                }
            }
        }
    }

    func openShortcutInstaller(for guest: ContainerGuest, mode: String) {
        guard let configData = buildWebClipMobileConfig(for: guest) else {
            failure = "Không tạo được cấu hình Shortcut."
            return
        }
        beginShortcutServerBackgroundTask()
        let htmlData = buildSafariShortcutHTML(for: guest)
        let swData = buildServiceWorkerJS()
        let safeFile = "\(guest.id).mobileconfig"
        shortcutPayloads["/webclip.mobileconfig"] = ("application/x-apple-aspen-config", safeFile, configData)
        shortcutPayloads["/webclip/\(safeFile)"] = ("application/x-apple-aspen-config", safeFile, configData)
        shortcutPayloads["/safari"] = ("text/html; charset=utf-8", nil, htmlData)
        shortcutPayloads["/safari/\(guest.id)"] = ("text/html; charset=utf-8", nil, htmlData)
        shortcutPayloads["/sw.js"] = ("application/javascript; charset=utf-8", nil, swData)

        shortcutListener?.cancel()
        shortcutListener = nil

        let preferredPort = NWEndpoint.Port(rawValue: 18989)
        let listener = (preferredPort.flatMap { try? NWListener(using: .tcp, on: $0) })
            ?? (try? NWListener(using: .tcp, on: .any))
        guard let listener else {
            failure = "Không mở được cổng máy chủ nội bộ cho Shortcut."
            return
        }

        let targetPath = (mode == "webclip")
            ? "/webclip/\(safeFile)"
            : "/safari/\(guest.id)#setup"
        var didOpenBrowser = false

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                Task { @MainActor in
                    guard let self else { conn.cancel(); return }
                    let req = String(data: data ?? Data(), encoding: .utf8) ?? ""
                    let firstLine = req.split(separator: "\r\n").first ?? ""
                    let parts = firstLine.split(separator: " ")
                    let method = parts.first.map(String.init) ?? "GET"
                    let rawPath = parts.dropFirst().first.map(String.init) ?? "/safari/\(guest.id)"
                    let cleanPath = (rawPath.components(separatedBy: "?").first ?? "/safari/\(guest.id)")
                        .components(separatedBy: "#").first ?? "/safari/\(guest.id)"
                    let defaultPayload = self.shortcutPayloads["/safari/\(guest.id)"] ?? ("text/html; charset=utf-8", nil, htmlData)
                    let payload = self.shortcutPayloads[cleanPath] ?? defaultPayload

                    var headers = [
                        "HTTP/1.1 200 OK",
                        "Content-Type: \(payload.mime)",
                        "Content-Length: \(payload.data.count)",
                        "Cache-Control: public, max-age=31536000",
                        "Connection: close"
                    ]
                    if let filename = payload.filename {
                        headers.append("Content-Disposition: attachment; filename=\"\(filename)\"")
                    }
                    let headerBlock = headers.joined(separator: "\r\n") + "\r\n\r\n"
                    var response = Data(headerBlock.utf8)
                    if method.uppercased() != "HEAD" {
                        response.append(payload.data)
                    }
                    conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener else { return }
                if case .ready = state, !didOpenBrowser {
                    didOpenBrowser = true
                    let port = listener.port?.rawValue ?? 18989
                    if let url = URL(string: "http://127.0.0.1:\(port)\(targetPath)") {
                        self.openExternalURLWhenActive(url)
                    }
                }
            }
        }

        listener.start(queue: .main)
        shortcutListener = listener
    }
}
#endif
