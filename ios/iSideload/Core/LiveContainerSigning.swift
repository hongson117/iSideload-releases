import Foundation

/// A user-selected signing identity travels with the downloaded IPA across VPN hand-off.
struct LiveContainerInstallPlan: Equatable {
    let ipa: URL
    let upgrade: Bool
    let signer: String

    enum Invalid: LocalizedError {
        case missingChoice, unavailable
        var errorDescription: String? {
            switch self {
            case .missingChoice: return "Hãy chọn Apple ID hoặc chứng chỉ đã nhập để ký LiveContainer."
            case .unavailable: return "Nguồn ký đã chọn chưa sẵn sàng. Đăng nhập Apple ID hoặc nhập lại chứng chỉ ở tab Tài khoản."
            }
        }
    }

    init(ipa: URL, upgrade: Bool, selectedSigner: String?, availableSigners: [String]) throws {
        guard let signer = selectedSigner, !signer.isEmpty else { throw Invalid.missingChoice }
        guard availableSigners.contains(signer) else { throw Invalid.unavailable }
        self.ipa = ipa; self.upgrade = upgrade; self.signer = signer
    }
}

enum LiveContainerSigning {
    static let prefix = "com.kdt.livecontainer"
    static func isContainer(_ id: String) -> Bool { id == prefix || id.hasPrefix(prefix + ".") }
    /// Engine appends successful installs. Never pick an older certificate-signed copy first.
    static func latestInstalled(in apps: [SideloadedApp], activeBundleID: String? = nil) -> SideloadedApp? {
        if let activeBundleID, let active = apps.first(where: { $0.bundleID == activeBundleID && isContainer($0.bundleID) }) {
            return active
        }
        return apps.last { isContainer($0.bundleID) }
    }
    /// The shared livecontainer:// scheme cannot identify one of several app copies.
    static func needsManualCertificateImport(apps: [SideloadedApp]) -> Bool {
        Set(apps.filter { isContainer($0.bundleID) }.map(\.bundleID)).count != 1
    }
}

struct LiveContainerCertificateFile: Identifiable {
    let id = UUID()
    let url: URL
    let password: String
    let sourceLabel: String
}
