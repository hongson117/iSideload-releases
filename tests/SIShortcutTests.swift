import Foundation

@main
struct SIShortcutTests {
    static func main() throws {
        let guest = "5BCC9837-1C4A-498F-91DF-F9DE42DE68B1"
        let name = "Lịch Âm & Dương #1 + 2?"
        let icon = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aT9sAAAAASUVORK5CYII=")!
        let data = SIShortcut.mobileConfig(guestID: guest.lowercased(), name: name, icon: icon)!
        let profile = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let clip = (profile["PayloadContent"] as! [[String: Any]])[0]
        precondition(clip["PayloadType"] as? String == "com.apple.webClip.managed")
        precondition(profile["PayloadType"] as? String == "Configuration")
        precondition(clip["Label"] as? String == name)
        precondition(clip["Icon"] as? Data == icon)
        precondition(clip["TargetApplicationBundleIdentifier"] == nil, "Manual profiles cannot rely on an MDM-only key")
        for payload in [profile, clip] {
            precondition(UUID(uuidString: payload["PayloadUUID"] as! String) != nil)
        }
        precondition(profile["PayloadUUID"] as! String != clip["PayloadUUID"] as! String)
        precondition(profile["PayloadIdentifier"] as? String == "com.hongson117.sicontainer.shortcut.\(guest)")
        let url = URLComponents(string: clip["URL"] as! String)!
        let query = Dictionary(uniqueKeysWithValues: url.queryItems!.map { ($0.name, $0.value!) })
        precondition(query == ["guest": guest, "name": name, "slot": "runner1"])
        precondition(SIShortcut.launchURL(guestID: guest)?.absoluteString == "sicontainer-runner1://launch?guest=\(guest)")
        precondition(SIShortcut.launchURL(guestID: guest, slot: "main")?.scheme == "sicontainer")
        precondition(SIShortcut.webURL(guestID: guest, name: name, slot: "main")?.absoluteString.contains("slot=main") == true)
        precondition(SIShortcut.mobileConfig(guestID: "../invalid", name: name, icon: nil) == nil)
        precondition(SIShortcut.launchURL(guestID: guest, slot: "other-app") == nil)
        print("SIContainer shortcut/profile regression tests passed")
    }
}
