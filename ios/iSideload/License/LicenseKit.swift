// LicenseKit — activation-code licensing for HongSon's apps (TVSideload, iSideload).
// Server: https://tvsideload-license.hongson1812.workers.dev  (POST /activate, POST /check)
// License = base64url(JSON payload) + "." + base64url(Ed25519 signature)
// payload = {code, app, device_id, exp (ms, 0 = never), issued_at (ms)}
// Defense in depth only; a determined reverse engineer can still patch the binary.
import Foundation
import CryptoKit
import Security
import SwiftUI
import UIKit

public struct LicenseConfig {
    public var appID: String                // "tvsideload" | "isideload"
    public var serverURL: URL
    public var keyShares: [[UInt8]]         // public key = XOR of all shares (32 bytes each)
    public var watermark: [UInt8]           // bytes shifted +1
    public var watermarkSHA256: String
    public var graceDays: Double = 7
    public var appName: String
    public init(appID: String, appName: String, serverURL: URL, keyShares: [[UInt8]], watermark: [UInt8], watermarkSHA256: String) {
        self.appID = appID; self.appName = appName; self.serverURL = serverURL
        self.keyShares = keyShares; self.watermark = watermark; self.watermarkSHA256 = watermarkSHA256
    }
}

enum LKKeychain {
    static let service = "com.hongson117.licensekit"
    static func get(_ k: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: k, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ k: String, _ v: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: k]
        SecItemDelete(base as CFDictionary)
        guard let v else { return }
        var q = base
        q[kSecValueData as String] = Data(v.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

public enum LKSecurity {
    /// True when a debugger is attached (P_TRACED). Fail closed.
    public static func debuggerAttached() -> Bool {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
    /// Soft signal only (not enforced): common jailbreak artifacts.
    public static func looksJailbroken() -> Bool {
        ["/Applications/Cydia.app", "/var/jb", "/usr/sbin/sshd", "/bin/bash"].contains { FileManager.default.fileExists(atPath: $0) }
    }
}

@MainActor
public final class LicenseManager: ObservableObject {
    public enum State: Equatable { case checking, locked(String?), unlocked }
    nonisolated(unsafe) public static private(set) var shared: LicenseManager!
    @Published public private(set) var state: State = .checking
    @Published public private(set) var busy = false
    public let config: LicenseConfig

    public static func configure(_ c: LicenseConfig) { shared = LicenseManager(c) }
    private init(_ c: LicenseConfig) { config = c; state = localValid() ? .unlocked : .locked(nil) }

    private var kLicense: String { "license.\(config.appID)" }
    private var kCode: String { "code.\(config.appID)" }

    /// identifierForVendor persisted in Keychain so it survives reinstall.
    public nonisolated static var deviceID: String {
        if let d = LKKeychain.get("device_id") { return d }
        let d = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        LKKeychain.set("device_id", d); return d
    }
    /// Stored signed license (pass to native core for its own verification).
    public nonisolated var license: String? { LKKeychain.get("license.\(config.appID)") }
    public var code: String? { LKKeychain.get(kCode) }
    public var isUnlocked: Bool { state == .unlocked }

    private nonisolated func publicKey() -> Data {
        var k = [UInt8](repeating: 0, count: 32)
        for s in config.keyShares { for i in 0..<32 { k[i] ^= s[i] } }
        return Data(k)
    }
    public nonisolated func integrityOK() -> Bool {
        let wm = Data(config.watermark.map { $0 &- 1 })
        return SHA256.hash(data: wm).map { String(format: "%02x", $0) }.joined() == config.watermarkSHA256
    }

    /// Full local check: integrity, no debugger, signature, device, app, expiry, offline grace.
    public nonisolated func verify(_ lic: String?) -> (ok: Bool, reason: String?) {
        guard integrityOK() else { return (false, "Ứng dụng đã bị chỉnh sửa.") }
        guard !LKSecurity.debuggerAttached() else { return (false, "Phát hiện trình gỡ lỗi.") }
        guard let lic, let dot = lic.firstIndex(of: ".") else { return (false, nil) }
        guard let p = b64u(String(lic[..<dot])), let s = b64u(String(lic[lic.index(after: dot)...])),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey()),
              key.isValidSignature(s, for: p),
              let o = try? JSONSerialization.jsonObject(with: p) as? [String: Any] else { return (false, "Giấy phép không hợp lệ.") }
        guard o["device_id"] as? String == Self.deviceID, o["app"] as? String == config.appID else { return (false, "Giấy phép không thuộc thiết bị này.") }
        let now = Date().timeIntervalSince1970 * 1000
        let exp = (o["exp"] as? NSNumber)?.doubleValue ?? 0
        if exp > 0 && now > exp { return (false, "Mã kích hoạt đã hết hạn.") }
        let issued = (o["issued_at"] as? NSNumber)?.doubleValue ?? 0
        if now - issued > config.graceDays * 86_400_000 { return (false, "Cần kết nối mạng để xác minh lại giấy phép.") }
        return (true, nil)
    }
    private func localValid() -> Bool { verify(license).ok }

    private nonisolated func b64u(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func message(_ e: String) -> String {
        switch e {
        case "invalid": return "Mã kích hoạt không đúng."
        case "revoked": return "Mã kích hoạt đã bị thu hồi."
        case "expired": return "Mã kích hoạt đã hết hạn."
        case "wrong_app": return "Mã này không dùng cho ứng dụng này."
        case "device_limit": return "Mã đã được dùng trên số thiết bị tối đa."
        case "not_activated": return "Thiết bị chưa được kích hoạt."
        case "rate_limited": return "Thử quá nhiều lần, vui lòng đợi rồi thử lại."
        default: return "Lỗi: \(e)"
        }
    }

    private func post(_ path: String, _ code: String) async -> (license: String?, error: String?, network: Bool) {
        var r = URLRequest(url: config.serverURL.appendingPathComponent(path), timeoutInterval: 15)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "content-type")
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code, "device_id": Self.deviceID, "app": config.appID, "version": ver])
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (nil, nil, true) }
        if let l = o["license"] as? String { return (l, nil, false) }
        return (nil, o["error"] as? String ?? "unknown", false)
    }

    /// Activate with a code typed by the user.
    public func activate(_ raw: String) async {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return }
        busy = true; defer { busy = false }
        let r = await post("activate", code)
        if r.network { state = .locked("Không kết nối được máy chủ. Kiểm tra mạng rồi thử lại."); return }
        if let e = r.error { state = .locked(Self.message(e)); return }
        let v = verify(r.license)
        guard v.ok else { state = .locked(v.reason ?? "Giấy phép không hợp lệ."); return }
        LKKeychain.set(kLicense, r.license); LKKeychain.set(kCode, code)
        state = .unlocked
    }

    /// Re-check online (call on launch / foreground). Offline keeps the local license within grace.
    public func revalidate() async {
        guard let code else { state = localValid() ? .unlocked : .locked(nil); return }
        let r = await post("check", code)
        if r.network { let v = verify(license); state = v.ok ? .unlocked : .locked(v.reason); return }
        if let e = r.error { LKKeychain.set(kLicense, nil); state = .locked(Self.message(e)); return }
        let v = verify(r.license)
        if v.ok { LKKeychain.set(kLicense, r.license); state = .unlocked } else { state = .locked(v.reason) }
    }

    /// Re-verify locally right before a sensitive operation.
    @discardableResult public func requireValid() -> Bool {
        let v = verify(license)
        if !v.ok { state = .locked(v.reason) }
        return v.ok
    }

    public func deactivateLocally() { LKKeychain.set(kLicense, nil); LKKeychain.set(kCode, nil); state = .locked(nil) }
}

/// Wrap the root view: shows the Vietnamese activation screen until unlocked.
public struct LicenseGate<Content: View>: View {
    @ObservedObject var lm: LicenseManager
    @Environment(\.scenePhase) private var phase
    let content: () -> Content
    public init(_ lm: LicenseManager, @ViewBuilder content: @escaping () -> Content) { self.lm = lm; self.content = content }
    public var body: some View {
        Group {
            if lm.isUnlocked { content() } else { ActivationView(lm: lm) }
        }
        .task { await lm.revalidate() }
        .onChange(of: phase) { _, p in if p == .active { Task { await lm.revalidate() } } }
    }
}

public struct ActivationView: View {
    @ObservedObject var lm: LicenseManager
    @State private var code = ""
    public var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Kích hoạt \(lm.config.appName)").font(.title2.bold())
            Text("Ứng dụng cần mã kích hoạt để sử dụng. Liên hệ người cung cấp để nhận mã.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            TextField("Mã kích hoạt (VD: TVS-XXXX-XXXX)", text: $code)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .font(.system(.body, design: .monospaced)).padding(12)
                .background(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.4)))
            if case .locked(let m?) = lm.state { Text(m).foregroundStyle(.red).multilineTextAlignment(.center) }
            Button { Task { await lm.activate(code) } } label: {
                if lm.busy { ProgressView() } else { Text("Kích hoạt").frame(maxWidth: .infinity) }
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(lm.busy || code.isEmpty)
            Text("Mã thiết bị: \(String(LicenseManager.deviceID.prefix(8)))")
                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(28).frame(maxWidth: 480)
    }
}
