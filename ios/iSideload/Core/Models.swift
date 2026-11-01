import Foundation

struct SideloadedApp: Codable, Identifiable, Hashable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var version: String
    var expires: Date?
    var ipaFile: String?          // cached original IPA (Documents/IPAs), used by Refresh
    var installedAt: Date = Date()

    var daysLeft: Int? {
        guard let e = expires else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: e).day
    }
}
