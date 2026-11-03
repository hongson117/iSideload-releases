import Foundation
import UIKit

struct PeerReceiver: Codable {
    let sessionID: String
    let name: String
    let model: String
    let udid: String
    let ip: String
    let pairedAt: Date
    var installedAt: Date?
    var installAccount: String?
    var installedBundleID: String?
    var installedTeamID: String?
    var installedBootstrap: Bool?

    var recordURL: URL { Engine.storage.appendingPathComponent("peer-pairings/\(sessionID).plist") }
    var metadataURL: URL { Engine.storage.appendingPathComponent("peer-pairings/\(sessionID).json") }
}

@MainActor
final class PeerInstaller: NSObject, ObservableObject, NetServiceDelegate {
    enum Phase { case idle, pairing, paired, installing, installed }
    @Published var phase: Phase = .idle
    @Published var pin = ""
    @Published var hostName = ""
    @Published var stage = ""
    @Published var progress = 0.0
    @Published var error: String?
    @Published var receiver: PeerReceiver?
    @Published var receiverSetupVerified = false
    @Published var receiverNeedsPersonalSetup = false
    private var sessionID = ""
    private var advertisement: NetService?
    private var cancelRequested = false
    private var publishError: String?
    var active: Bool { phase == .pairing || phase == .installing }

    override init() {
        super.init()
        let dir = Engine.storage.appendingPathComponent("peer-pairings")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        receiver = files.filter { $0.pathExtension == "json" }.compactMap { url -> PeerReceiver? in
            guard let data = try? Data(contentsOf: url), let peer = try? JSONDecoder().decode(PeerReceiver.self, from: data),
                  FileManager.default.fileExists(atPath: peer.recordURL.path) else { return nil }
            return peer
        }.max { $0.pairedAt < $1.pairedAt }
        if receiver != nil { phase = .paired }
    }

    private func saveReceiver() throws {
        guard let peer = receiver else { return }
        try JSONEncoder().encode(peer).write(to: peer.metadataURL, options: [.atomic, .completeFileProtection])
    }

    private func event(_ stage: String, _ progress: Double) {
        self.stage = stage; self.progress = progress
    }

    private func publish(_ data: [String: Any]) {
        guard let port = data["port"] as? Int, let name = data["name"] as? String else { return }
        hostName = data["host_name"] as? String ?? "iContainer - Cai may khac"
        let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: name, port: Int32(port))
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord:
            (data["txt"] as? [String: String] ?? [:]).mapValues { Data($0.utf8) }))
        advertisement = service
        service.publish()
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Task { @MainActor in
            self.publishError = "Không phát được tên ghép nối (Bonjour \(errorDict)). Kiểm tra quyền Mạng cục bộ và Wi-Fi rồi thử lại."
            self.cancelPairing()
        }
    }

    func cancelPairing() {
        guard phase == .pairing else { return }
        cancelRequested = true
        advertisement?.stop(); advertisement = nil
        let id = sessionID
        Task { _ = await CoreCall.runAsync(["op": "peer_cancel", "session_id": id]) }
    }

    func pair() async {
        let engine = Engine.shared
        guard !engine.busy, !active else { return }
        let previous = receiver
        sessionID = UUID().uuidString
        phase = .pairing; pin = ""; hostName = ""; error = nil; progress = 0
        cancelRequested = false; publishError = nil
        stage = "Đang phát tên ghép nối…"
        engine.peerBusy = true; engine.busy = true
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            advertisement?.stop(); advertisement = nil; pin = ""
            UIApplication.shared.isIdleTimerDisabled = idle
            engine.peerBusy = false; engine.busy = false
        }
        do {
            var req = engine.peerRequest("peer_pair"); req["session_id"] = sessionID
            let result = try await engine.callForPeer(req, onEvent: { [weak self] st, p in
                DispatchQueue.main.async { self?.event(st, p) }
            }, onStructured: { [weak self] obj in
                DispatchQueue.main.async {
                    guard let self, self.phase == .pairing, !self.cancelRequested else { return }
                    if let ad = obj["advertise"] as? [String: Any] { self.publish(ad) }
                    if let pin = obj["pin"] as? String { self.pin = pin }
                }
            })
            let sourceUDID = UserDefaults.standard.string(forKey: "deviceUDID") ?? ""
            if !sourceUDID.isEmpty, (result["udid"] as? String)?.caseInsensitiveCompare(sourceUDID) == .orderedSame {
                throw CoreError(message: "Bạn đã ghép nối chính máy hỗ trợ. Hãy thực hiện bước chọn tên và nhập mã trên iPhone nhận.")
            }
            receiver = PeerReceiver(sessionID: sessionID, name: result["name"] as? String ?? "iPhone",
                                    model: result["model"] as? String ?? "", udid: result["udid"] as? String ?? "",
                                    ip: result["ip"] as? String ?? "", pairedAt: Date())
            try saveReceiver()
            phase = .paired; stage = "Đã ghép nối. Kiểm tra đúng máy nhận rồi bấm Cài iContainer."
        } catch {
            receiver = previous; phase = previous == nil ? .idle : .paired
            self.error = publishError ?? (cancelRequested ? nil : error.localizedDescription)
            stage = cancelRequested ? "Đã hủy ghép nối." : "Ghép nối chưa hoàn tất."
        }
    }

    func install(account: String, bootstrap: Bool = false) async {
        let engine = Engine.shared
        guard !engine.busy, !active, let peer = receiver, engine.signedAccounts.contains(account) else { return }
        phase = .installing; error = nil; progress = 0; receiverSetupVerified = false; receiverNeedsPersonalSetup = bootstrap
        engine.peerBusy = true; engine.busy = true
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("peer-\(UUID().uuidString).ipa")
        defer {
            try? FileManager.default.removeItem(at: out)
            UIApplication.shared.isIdleTimerDisabled = idle
            engine.peerBusy = false; engine.busy = false
        }
        let events: CoreCall.Event = { [weak self] st, p in DispatchQueue.main.async { self?.event(st, p) } }
        do {
            stage = "Đang chuẩn bị iContainer cho máy nhận…"
            _ = try await engine.callForPeer(["op": "pack_self", "app_path": Bundle.main.bundleURL.path,
                                             "out_path": out.path, "peer_bootstrap": true], onEvent: events)
            var req = engine.peerRequest("peer_install", account: account)
            req["session_id"] = peer.sessionID; req["target"] = peer.ip
            req["expected_udid"] = peer.udid; req["ipa_path"] = out.path
            req["recipient_bootstrap"] = bootstrap
            req["upgrade"] = peer.installedAt != nil && peer.installAccount == account
            if peer.installAccount == account, let team = peer.installedTeamID { req["preferred_team_id"] = team }
            let result = try await engine.callForPeer(req, onEvent: events)
            receiver?.installedAt = Date()
            receiver?.installAccount = account
            receiver?.installedBundleID = result["bundle_id"] as? String
            receiver?.installedTeamID = result["team_id"] as? String
            receiver?.installedBootstrap = bootstrap
            receiverSetupVerified = result["recipient_setup_verified"] as? Bool == true
            // Installation succeeded even if writing local history fails.
            try? saveReceiver()
            phase = .installed; progress = 1
            stage = "Đã cài iContainer lên \(peer.name)."
            if receiverSetupVerified { stage += bootstrap ? " Bản khởi tạo đã có ghép nối; người nhận đăng nhập tài khoản riêng để thiết lập bản cá nhân." : " Đã thiết lập khóa ký và ghép nối cho tài khoản người nhận." }
            else { error = "App đã cài, nhưng thiết lập tự gia hạn chưa hoàn tất: \(result["recipient_setup_error"] as? String ?? "chưa xác minh dữ liệu thiết lập"). Giữ máy nhận mở khóa rồi cài lại bằng cùng tài khoản để thử lại." }
        } catch {
            phase = .paired; self.error = error.localizedDescription
            stage = "Chưa cài xong. Giữ máy nhận mở khóa và kiểm tra Wi-Fi rồi thử lại."
        }
    }
}
