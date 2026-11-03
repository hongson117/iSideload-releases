import Foundation
import UIKit

struct ContainerGuest: Identifiable, Decodable {
    let id: String
    let bundleID: String
    let name: String
    let version: String
    let prepared: Bool
    let signer: String?
    let embeddedComponents: [String]?
    enum CodingKeys: String, CodingKey { case id, name, version, prepared, signer; case bundleID = "bundle_id", embeddedComponents = "embedded_components" }
}

@MainActor
final class ContainerStore: ObservableObject {
    static let shared = ContainerStore()
    @Published var guests: [ContainerGuest] = []
    @Published var working = false
    @Published var message: String?
    @Published var failure: String?
    @Published var readyToReopen = false
    static var root: URL { URL(fileURLWithPath: ICContainerRoot(), isDirectory: true) }

    init() { reload(); failure = ICLastLaunchError() }

    func reload() {
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
            message = "Đã nhập app vào Container. Chọn Chuẩn bị và dùng đúng chứng chỉ đã ký iContainer để chạy. Mỗi lần nhập tạo một bản dữ liệu riêng."
            if let guest = result["guest"] as? [String: Any], guest["main_app_only"] as? Bool == true {
                message = (message ?? "") + "\nGói có extension hoặc Apple Watch: bản gốc được giữ nguyên, Container chỉ chuẩn bị và chạy app chính trên iPhone. Extension/Watch không được kích hoạt."
            }
        } catch { failure = error.localizedDescription }
    }

    func prepare(_ guest: ContainerGuest, signer: String, engine: Engine) async {
        guard !working && !engine.busy && !engine.peerBusy else { return }
        working = true; defer { working = false }
        do {
            try await engine.prepareContainerGuest(request("container_prepare", id: guest.id), signer: signer)
            reload()
            message = "Đã chuẩn bị \(guest.name). Chọn Chạy để mở app."
        } catch { failure = error.localizedDescription }
    }

    func launch(_ guest: ContainerGuest) {
        guard !working else { return }
        do {
            var error: NSError?
            guard ICQueueGuest(guest.id, &error) else {
                throw CoreError(message: error?.localizedDescription ?? "Không tạo được yêu cầu mở app.")
            }
            readyToReopen = true
        } catch { failure = error.localizedDescription }
    }

    func remove(_ guest: ContainerGuest, engine: Engine) async {
        guard !working && !engine.busy && !engine.peerBusy else { return }
        working = true; defer { working = false }
        do {
            _ = try await engine.containerOperation(request("container_remove", id: guest.id))
            reload()
        } catch { failure = error.localizedDescription }
    }
}
