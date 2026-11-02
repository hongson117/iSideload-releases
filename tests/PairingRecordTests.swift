import Foundation
import CryptoKit

@main
struct PairingRecordTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }
    static func plist(_ dict: [String: Any], _ format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
    }
    static func rejects(_ dict: [String: Any]) throws {
        do { _ = try PairingRecord.parse(plist(dict)) }
        catch is PairingRecord.Invalid { return }
        throw Failure.assertion("Malformed pairing record accepted")
    }
    static func main() throws {
        let key = Curve25519.Signing.PrivateKey()
        let rp: [String: Any] = ["public_key": key.publicKey.rawRepresentation,
                                 "private_key": key.rawRepresentation,
                                 "identifier": "test-controller",
                                 "alt_irk": Data(repeating: 7, count: 16)]
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let record = try PairingRecord.parse(plist(rp, format))
            try expect(record.kind == .remote, "Pure RP XML and binary exports must be accepted")
            let reread = try PairingRecord.parse(record.data)
            try expect(reread.kind == .remote, "Normalized record must round-trip")
        }
        let classic: [String: Any] = ["HostPrivateKey": Data([1]), "DeviceCertificate": Data([2])]
        let legacy = try PairingRecord.parse(plist(classic))
        try expect(legacy.kind == .lockdown, "Keep classic record compatibility")
        var composite = rp
        composite.merge(classic) { old, _ in old }
        let normalized = try PairingRecord.parse(plist(composite))
        let clean = try PropertyListSerialization.propertyList(from: normalized.data, format: nil) as! [String: Any]
        try expect(normalized.kind == .remote && clean["HostPrivateKey"] == nil && clean["DeviceCertificate"] == nil,
                   "Composite exports must select RP in the existing core")
        var bad = rp; bad["private_key"] = Data([1]); try rejects(bad)
        bad = rp; bad["public_key"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation; try rejects(bad)
        bad = rp; bad.removeValue(forKey: "identifier"); try rejects(bad)
        bad = rp; bad["identifier"] = "  "; try rejects(bad)
        bad = rp; bad["alt_irk"] = Data([1]); try rejects(bad)
        try rejects([:]); try rejects(["HostPrivateKey": Data()])
        print("PairingRecord tests passed: pure RP XML/binary, matching keys, identifier, IRK, composite extraction, classic compatibility, malformed records")
    }
}
