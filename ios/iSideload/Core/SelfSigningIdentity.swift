import Foundation

/// Per-install metadata stays in Documents/Storage, outside the distributable IPA.
/// The provisioning profile decides the team; metadata only supplies a login hint.
struct SelfSigningIdentity {
    let bundleID: String
    let teamID: String
    let installerAppleID: String?
    let deviceUDID: String?

    private struct Installer: Decodable {
        let bundleID: String
        let teamID: String
        let appleID: String
        let udid: String?
        enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id", teamID = "team_id", appleID = "apple_id", udid
        }
    }

    init(bundleID: String, teamID: String, installerData: Data?) {
        self.bundleID = bundleID
        self.teamID = teamID
        if let data = installerData, let owner = try? JSONDecoder().decode(Installer.self, from: data),
           owner.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame,
           owner.teamID.caseInsensitiveCompare(teamID) == .orderedSame,
           !owner.appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            installerAppleID = owner.appleID
            deviceUDID = owner.udid
        } else { installerAppleID = nil; deviceUDID = nil }
    }

    func accepts(teamIDs: [String]) -> Bool {
        teamIDs.contains { $0.caseInsensitiveCompare(teamID) == .orderedSame }
    }

    var description: String {
        var text = "Team đang ký bản này: \(teamID)."
        if let installerAppleID { text += " Tài khoản cài đặt: \(installerAppleID)." }
        return text + " Nếu dùng Apple ID riêng khác tài khoản cài ban đầu, chọn Thiết lập iContainer bằng tài khoản của bạn trước lần gia hạn đầu tiên."
    }
}
