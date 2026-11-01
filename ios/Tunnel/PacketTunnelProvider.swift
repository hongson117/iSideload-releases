import NetworkExtension

/// Loopback tunnel (OPTIONAL, paid developer accounts only — free Apple IDs cannot
/// get the Network Extension entitlement). Routes 10.7.0.1 into utun and writes every
/// IPv4 packet back with source/destination swapped, so a TCP connect from the app to
/// 10.7.0.1 arrives at the device's own services as if from a remote host.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        let v4 = NEIPv4Settings(addresses: ["10.7.0.0"], subnetMasks: ["255.255.255.0"])
        v4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
        s.ipv4Settings = v4
        s.mtu = 1500
        setTunnelNetworkSettings(s) { [weak self] err in
            completionHandler(err)
            if err == nil { self?.pump() }
        }
    }

    private func pump() {
        packetFlow.readPackets { [weak self] packets, protos in
            guard let self else { return }
            let out = packets.map(Self.reflect)
            self.packetFlow.writePackets(out, withProtocols: protos)
            self.pump()
        }
    }

    /// Swaps IPv4 src (bytes 12..15) and dst (16..19). The IP and TCP/UDP checksums
    /// are sums over both addresses, so a swap leaves them valid.
    static func reflect(_ p: Data) -> Data {
        guard p.count >= 20, p[p.startIndex] >> 4 == 4 else { return p }
        var b = [UInt8](p)
        for i in 0..<4 { b.swapAt(12 + i, 16 + i) }
        return Data(b)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) { completionHandler() }
}
