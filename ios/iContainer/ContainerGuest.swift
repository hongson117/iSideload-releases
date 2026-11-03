import Foundation

struct ContainerGuest: Identifiable, Decodable {
    let id: String
    let bundleID: String
    let name: String
    let version: String
    let prepared: Bool
    let preparationRevision: Int?
    var readyToLaunch: Bool { prepared && (preparationRevision ?? 0) >= 3 }
    let signer: String?
    let embeddedComponents: [String]?
    enum CodingKeys: String, CodingKey { case id, name, version, prepared, signer; case bundleID = "bundle_id", embeddedComponents = "embedded_components"; case preparationRevision = "preparation_revision" }
}

