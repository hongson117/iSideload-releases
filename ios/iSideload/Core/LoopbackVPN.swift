import Darwin
import Foundation
import UIKit

/// The device reaches its own lockdownd at 10.7.0.1 through a loopback VPN whose
/// provider reflects packets back into the device (swap src/dst IPv4). Free Apple IDs
/// cannot sign Network Extensions, so by default iSideload uses the App Store app
/// "LocalDevVPN"; the bundled Tunnel/ provider is for paid developer accounts.
enum LoopbackVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id6755608044")!
    static let enableURL = URL(string: "localdevvpn://enable?scheme=isideload")!
    static let defaultTarget = "10.7.0.1"

    @MainActor static var helperInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }

    /// A utun interface with an IPv4 address in 10.7.x.x means the loopback VPN is up.
    static func isActive(target: String = defaultTarget) -> Bool {
        let prefix = target.split(separator: ".").prefix(2).joined(separator: ".") + "."
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let e = cur {
            defer { cur = e.pointee.ifa_next }
            guard String(cString: e.pointee.ifa_name).hasPrefix("utun"), let a = e.pointee.ifa_addr,
                  a.pointee.sa_family == sa_family_t(AF_INET), (e.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
               String(cString: host).hasPrefix(prefix) { return true }
        }
        return false
    }

    @MainActor static func turnOn() { UIApplication.shared.open(helperInstalled ? enableURL : appStoreURL) }
}
