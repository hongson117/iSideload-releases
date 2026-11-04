import Foundation

enum SIShortcut {
    static func launchURL(guestID: String, slot: String = "runner1") -> URL? {
        guard let id = UUID(uuidString: guestID), ["runner1", "main"].contains(slot) else { return nil }
        var url = URLComponents()
        url.scheme = slot == "main" ? "sicontainer" : "sicontainer-runner1"
        url.host = "launch"
        url.queryItems = [URLQueryItem(name: "guest", value: id.uuidString)]
        return url.url
    }

    static func webURL(guestID: String, name: String, slot: String = "runner1") -> URL? {
        guard let id = UUID(uuidString: guestID), launchURL(guestID: guestID, slot: slot) != nil else { return nil }
        var url = URLComponents(string: "https://hongson117.github.io/iSideload-releases/go.html")!
        url.queryItems = [
            URLQueryItem(name: "guest", value: id.uuidString),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "slot", value: slot)
        ]
        return url.url
    }

    static func mobileConfig(guestID: String, name: String, icon: Data?, slot: String = "runner1") -> Data? {
        guard let id = UUID(uuidString: guestID), let url = webURL(guestID: guestID, name: name, slot: slot) else { return nil }
        var clip: [String: Any] = [
            "PayloadType": "com.apple.webClip.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.hongson117.sicontainer.webclip.v2.\(id.uuidString)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": name,
            "Label": name,
            "URL": url.absoluteString,
            "FullScreen": false,
            "Precomposed": true,
            "IsRemovable": true
        ]
        if let icon { clip["Icon"] = icon }
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.hongson117.sicontainer.shortcut.v2.\(id.uuidString)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Shortcut \(name)",
            "PayloadDescription": "Thêm biểu tượng mở \(name) vào Màn hình chính.",
            "PayloadOrganization": "SIContainer",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [clip]
        ]
        return try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}
