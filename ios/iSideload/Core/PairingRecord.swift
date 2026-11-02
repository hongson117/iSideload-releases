import Foundation
import CryptoKit

/// Recognizes a file's format; only a device handshake can verify its trust.
struct PairingRecord {
    enum Kind: String {
        case remote = "Remote Pairing"
        case lockdown = "Lockdown"
    }

    enum Invalid: LocalizedError {
        case file, remoteKeys, identifier, irk
        var errorDescription: String? {
            switch self {
            case .file: return "Không nhận diện được file ghép nối. Hãy xuất lại bằng idevice_pair hoặc iLoader."
            case .remoteKeys: return "Khóa Remote Pairing thiếu, bị hỏng hoặc không khớp nhau. Hãy xuất lại file ghép nối."
            case .identifier: return "File Remote Pairing thiếu identifier. Hãy xuất bản ghi đầy đủ từ idevice_pair."
            case .irk: return "File Remote Pairing có alt_irk không hợp lệ. Hãy xuất lại file ghép nối."
            }
        }
    }

    let kind: Kind
    let data: Data

    static func parse(_ data: Data) throws -> PairingRecord {
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            throw Invalid.file
        }
        // A composite file can contain both formats. Extract RP so the core
        // selects the RP tunnel instead of the older lockdown transport.
        if dict["public_key"] != nil || dict["private_key"] != nil {
            guard let secret = dict["private_key"] as? Data, secret.count == 32,
                  let publicKey = dict["public_key"] as? Data, publicKey.count == 32,
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret),
                  key.publicKey.rawRepresentation == publicKey else { throw Invalid.remoteKeys }
            guard let identifier = dict["identifier"] as? String,
                  !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid.identifier }
            var normalized: [String: Any] = ["public_key": publicKey, "private_key": secret, "identifier": identifier]
            if let raw = dict["alt_irk"] {
                guard let irk = raw as? Data, irk.count == 16 else { throw Invalid.irk }
                normalized["alt_irk"] = irk
            }
            return PairingRecord(kind: .remote, data: try PropertyListSerialization.data(
                fromPropertyList: normalized, format: .xml, options: 0))
        }
        // Keep compatibility with existing classic exports. This is format
        // recognition, not a claim that the record belongs to this iPhone.
        if nonempty(dict["HostPrivateKey"]) || nonempty(dict["DeviceCertificate"]) {
            return PairingRecord(kind: .lockdown, data: data)
        }
        throw Invalid.file
    }

    private static func nonempty(_ value: Any?) -> Bool {
        if let bytes = value as? Data { return !bytes.isEmpty }
        if let text = value as? String { return !text.isEmpty }
        return false
    }
}
