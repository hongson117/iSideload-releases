import Foundation

/// Metadata from the app that is actually running, not from a downloaded IPA or
/// an estimated free-account signing window. Reading this never needs a pairing.
struct InstalledAppState {
    let bundleID: String
    let name: String
    let version: String
    let expires: Date?
    let createdAt: Date?
    let teamID: String?
    let udid: String?

    static func read(bundleURL: URL) -> InstalledAppState? {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let bundleID = nonempty(info["CFBundleIdentifier"] as? String) else { return nil }

        let profile = (try? Data(contentsOf: bundleURL.appendingPathComponent("embedded.mobileprovision")))
            .flatMap(parseProfile)
        let entitlements = profile?["Entitlements"] as? [String: Any]
        let teams = profile?["TeamIdentifier"] as? [String] ?? []
        let devices = profile?["ProvisionedDevices"] as? [String] ?? []
        return InstalledAppState(
            bundleID: bundleID,
            name: nonempty(info["CFBundleDisplayName"] as? String)
                ?? nonempty(info["CFBundleName"] as? String) ?? bundleID,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            expires: profile?["ExpirationDate"] as? Date,
            createdAt: profile?["CreationDate"] as? Date,
            teamID: teams.first.flatMap { nonempty($0) }
                ?? nonempty(entitlements?["com.apple.developer.team-identifier"] as? String),
            udid: devices.count == 1 ? nonempty(devices[0]) : nil
        )
    }

    /// Provisioning profiles are CMS containers whose content is an XML plist.
    /// This extracts metadata only; it is not a cryptographic signature check.
    static func parseProfile(_ data: Data) -> [String: Any]? {
        if let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            return plist
        }
        guard let start = data.range(of: Data("<?xml".utf8))
                ?? data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: [], in: start.lowerBound..<data.endIndex) else { return nil }
        let content = data.subdata(in: start.lowerBound..<end.upperBound)
        return (try? PropertyListSerialization.propertyList(from: content, options: [], format: nil)) as? [String: Any]
    }

    /// Upsert only the exact running bundle. Other iSideload identities and other
    /// apps are retained. Existing IPA/account/history values survive a launch.
    func reconcile(_ apps: [SideloadedApp], signer: String? = nil) -> [SideloadedApp] {
        let matches = apps.filter { $0.bundleID == bundleID }
        let chosenSigner = Self.nonempty(signer)
        var own = matches.first ?? SideloadedApp(
            bundleID: bundleID, name: name, version: version, expires: expires,
            ipaFile: nil, installedAt: createdAt ?? Date(), signer: chosenSigner
        )
        // Recover useful fields if an older build saved duplicate records.
        for duplicate in matches.dropFirst() {
            if own.ipaFile == nil { own.ipaFile = duplicate.ipaFile }
            if own.signer == nil { own.signer = duplicate.signer }
            if own.expires == nil { own.expires = duplicate.expires }
        }
        own.name = name
        if !version.isEmpty { own.version = version }
        if let expires { own.expires = expires }
        if let chosenSigner { own.signer = chosenSigner }

        var result: [SideloadedApp] = []
        var inserted = false
        for app in apps {
            if app.bundleID == bundleID {
                if !inserted { result.append(own); inserted = true }
            } else {
                result.append(app)
            }
        }
        if !inserted { result.insert(own, at: 0) }
        return result
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
