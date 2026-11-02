import Foundation
import Network
import UIKit

/// Certificate (dev/distribution) installs without any VPN, the way on-device signers do it:
/// the signed IPA is served from a tiny HTTP server on 127.0.0.1 inside this app, an HTTPS
/// relay returns the manifest.plist pointing at it, and iOS installs via itms-services.
/// (itms-services needs the manifest over trusted HTTPS; the IPA itself may come from localhost.)
@MainActor
final class OTAInstaller {
    static let shared = OTAInstaller()
    /// Any HTTPS endpoint that turns query params into a manifest. Self-host: see /relay in the repo.
    static var relay: String {
        let v = UserDefaults.standard.string(forKey: "otaRelay") ?? ""
        return v.isEmpty ? "https://api.palera.in/genPlist" : v
    }

    private var listener: NWListener?
    private var file: URL?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var sentBytes: Int64 = 0
    private var total: Int64 = 0
    private var served = false

    /// Serve `ipa`, open the install prompt, and wait until iOS has pulled the whole file (or timeout).
    func install(ipa: URL, bundleID: String, name: String, version: String,
                 progress: @escaping (String, Double?) -> Void) async throws {
        stop()
        file = ipa; served = false; sentBytes = 0
        total = ((try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let port = try await start()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "ota") { [weak self] in self?.stop() }
        defer { stop() }

        var c = URLComponents(string: Self.relay)!
        c.queryItems = [URLQueryItem(name: "bundleid", value: bundleID), URLQueryItem(name: "name", value: name),
                        URLQueryItem(name: "version", value: version.isEmpty ? "1.0" : version),
                        URLQueryItem(name: "fetchurl", value: "http://127.0.0.1:\(port)/app.ipa")]
        let manifest = c.url!.absoluteString
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let itms = URL(string: "itms-services://?action=download-manifest&url=" + (manifest.addingPercentEncoding(withAllowedCharacters: allowed) ?? manifest))!
        progress("Bấm \"Cài đặt\" trên hộp thoại của iOS…", nil)
        let opened = await UIApplication.shared.open(itms)
        guard opened else { throw CoreError(message: "iOS không mở được itms-services (kiểm tra mạng / relay \(Self.relay)).") }

        // Wait up to 10 min for iOS to fetch the IPA.
        let deadline = Date().addingTimeInterval(600)
        var lastMove = Date(), last: Int64 = -1
        while !served && Date() < deadline {
            if sentBytes != last { last = sentBytes; lastMove = Date() }
            if sentBytes > 0 { progress("iOS đang tải app…", total > 0 ? Double(sentBytes) / Double(total) : nil) }
            if sentBytes > 0 && Date().timeIntervalSince(lastMove) > 60 { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard served else {
            throw CoreError(message: sentBytes == 0
                ? "iOS chưa tải app (đã bấm Huỷ, hoặc relay manifest không tới được). Thử lại."
                : "iOS dừng tải giữa chừng. Thử lại.")
        }
        progress("iOS đang cài app…", 1)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }

    private func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] conn in Task { @MainActor in self?.handle(conn) } }
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            l.stateUpdateHandler = { st in
                guard !done else { return }
                switch st {
                case .ready: done = true; cont.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let e): done = true; cont.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: .main)
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                let head = String(decoding: data ?? Data(), as: UTF8.self)
                let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
                let isHead = line.hasPrefix("HEAD ")
                guard line.contains(" /app.ipa"), let f = self.file, let fh = try? FileHandle(forReadingFrom: f) else {
                    conn.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                              completion: .contentProcessed { _ in conn.cancel() }); return
                }
                let hdr = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(self.total)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(hdr.utf8), completion: .contentProcessed { _ in })
                if isHead { try? fh.close(); conn.cancel(); return }
                self.pump(conn, fh, sent: 0)
            }
        }
    }

    private func pump(_ conn: NWConnection, _ fh: FileHandle, sent: Int64) {
        let chunk = (try? fh.read(upToCount: 512 * 1024)) ?? Data()
        if chunk.isEmpty {
            try? fh.close()
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            if sent >= total { served = true }
            return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                if err != nil { try? fh.close(); conn.cancel(); return }
                let n = sent + Int64(chunk.count)
                self.sentBytes = max(self.sentBytes, n)
                self.pump(conn, fh, sent: n)
            }
        })
    }
}
