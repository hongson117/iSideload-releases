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

    /// Real reachability: a TCP connect to lockdownd (62078) or RSD (49152) on the loopback target,
    /// ~1 s timeout. ECONNREFUSED still means packets went through the VPN, so it counts as reachable.
    /// (A stale utun with 10.7.x can survive after LocalDevVPN is switched off, so the interface check alone lies.)
    static func reachable(target: String = defaultTarget, timeout: Double = 1.0) -> Bool {
        guard isActive(target: target) else { return false }
        for port in [UInt16(62078), 49152] where probe(target, port, timeout) { return true }
        return false
    }
    private static func probe(_ host: String, _ port: UInt16, _ timeout: Double) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian; inet_pton(AF_INET, host, &a.sin_addr)
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r == 0 { return true }
        if errno == ECONNREFUSED { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
        var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0 || err == ECONNREFUSED
    }

    static let disableURL = URL(string: "localdevvpn://disable?scheme=isideload")!
    /// Turn LocalDevVPN off again (foreground only — iOS can't open URLs from a background task).
    @MainActor static func turnOff() { if helperInstalled { UIApplication.shared.open(disableURL) } }
    @MainActor static func turnOn() { UIApplication.shared.open(helperInstalled ? enableURL : appStoreURL) }
}
