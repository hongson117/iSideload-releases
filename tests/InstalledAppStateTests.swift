import Foundation

@main
struct InstalledAppStateTests {
    enum Failure: Error { case assertion(String) }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    static let originalExpiry = Date(timeIntervalSince1970: 2_000_000_000)
    static let originalCreation = Date(timeIntervalSince1970: 1_999_395_200)
    static let bundleID = "com.hongson117.isideload.TESTTEAM01"

    static func fixture(_ root: URL, profile: [String: Any]?) throws -> URL {
        let app = root.appendingPathComponent(UUID().uuidString + ".app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleDisplayName": "iSideload",
            "CFBundleShortVersionString": "1.2.1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        if let profile { try writeProfile(profile, to: app) }
        return app
    }

    static func writeProfile(_ profile: [String: Any], to app: URL) throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        // Exercise XML extraction without treating the CMS envelope as UTF-8.
        var cms = Data([0x30, 0x82, 0xFF, 0x00, 0x04])
        cms.append(xml)
        cms.append(contentsOf: [0x00, 0x80, 0xFE])
        try cms.write(to: app.appendingPathComponent("embedded.mobileprovision"))
    }

    static var profile: [String: Any] {
        ["ExpirationDate": originalExpiry, "CreationDate": originalCreation,
         "TeamIdentifier": ["TESTTEAM01"], "ProvisionedDevices": ["TEST-DEVICE-1"]]
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("installed-app-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try fixture(root, profile: profile)
        guard let state = InstalledAppState.read(bundleURL: app) else { throw Failure.assertion("Cannot read fixture") }
        try expect(state.expires == originalExpiry, "Must read actual profile expiration")
        try expect(state.createdAt == originalCreation, "Must read profile creation date")
        try expect(state.teamID == "TESTTEAM01", "Must read signing team")
        try expect(state.udid == "TEST-DEVICE-1", "Single-device profile identifies this device")

        let fresh = state.reconcile([])
        try expect(fresh.count == 1 && fresh[0].bundleID == bundleID, "Fresh install must list itself")
        try expect(fresh[0].expires == originalExpiry, "Fresh self record uses actual expiry")
        try expect(fresh[0].installedAt == originalCreation, "Fresh self record uses known creation date")
        try expect(state.reconcile(fresh) == fresh, "Repeated launches must be idempotent")

        let installationDate = Date(timeIntervalSince1970: 1_900_000_000)
        var existing = fresh[0]
        existing.ipaFile = "cached-original.ipa"
        existing.signer = "apple:existing@example.test"
        existing.installedAt = installationDate
        let preserved = state.reconcile([existing])[0]
        try expect(preserved.ipaFile == existing.ipaFile, "Keep cached original IPA")
        try expect(preserved.signer == existing.signer, "Keep known signing account")
        try expect(preserved.installedAt == installationDate, "Keep installation history")
        try expect(state.reconcile([existing], signer: "apple:new@example.test")[0].signer == "apple:new@example.test", "Explicit signer wins")

        let unknownApp = try fixture(root, profile: nil)
        guard let unknown = InstalledAppState.read(bundleURL: unknownApp) else { throw Failure.assertion("Missing profile should not hide app") }
        try expect(unknown.expires == nil, "Missing profile must not invent seven days")
        try expect(unknown.reconcile([])[0].expires == nil, "Unknown expiration remains unknown")
        try expect(unknown.reconcile([existing])[0].expires == existing.expires, "Unreadable metadata must not erase previously known expiry")
        try Data([0x01, 0xFF, 0x80]).write(to: unknownApp.appendingPathComponent("embedded.mobileprovision"))
        try expect(InstalledAppState.read(bundleURL: unknownApp)?.expires == nil, "Corrupt profile must remain unknown")

        var renewedProfile = profile
        let renewedExpiry = originalExpiry.addingTimeInterval(86_400)
        renewedProfile["ExpirationDate"] = renewedExpiry
        renewedProfile["ProvisionedDevices"] = ["TEST-DEVICE-1", "TEST-DEVICE-2"]
        try writeProfile(renewedProfile, to: app)
        guard let renewed = InstalledAppState.read(bundleURL: app) else { throw Failure.assertion("Cannot read renewed fixture") }
        try expect(renewed.reconcile([existing])[0].expires == renewedExpiry, "Renewed profile refreshes the expiry")
        try expect(renewed.udid == nil, "Multi-device profiles cannot identify the running UDID")

        let other = SideloadedApp(bundleID: bundleID + ".another-copy", name: "Another copy", version: "1", expires: nil, ipaFile: nil)
        let ordinary = SideloadedApp(bundleID: "com.example.reader", name: "Reader", version: "2", expires: nil, ipaFile: "reader.ipa")
        let reconciled = state.reconcile([ordinary, existing, other, existing])
        try expect(reconciled.count == 3, "Duplicate exact self records are coalesced")
        try expect(reconciled.filter { $0.bundleID == bundleID }.count == 1, "Only one exact self record")
        try expect(reconciled.contains(other) && reconciled.contains(ordinary), "Prefix-related and unrelated apps survive unchanged")
        try expect(state.reconcile(reconciled) == reconciled, "Reconciliation is stable after duplicates are removed")

        try expect(InstalledAppState.parseProfile(Data("<plist>broken".utf8)) == nil, "Malformed profile rejected")
        try expect(InstalledAppState.read(bundleURL: root) == nil, "Missing Info.plist cannot fabricate identity")
        print("InstalledAppState tests passed: fresh install, identity, expiration, signer/cache/history, renewal, invalid profiles, deduplication")
    }
}
