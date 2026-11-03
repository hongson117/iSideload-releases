import Foundation

/// The feed contains public unsigned code only. Credentials and owner identity stay on device.
struct AppUpdateManifest: Decodable {
    let schema: Int
    let apps: [String: AppUpdateRelease]
}

struct AppUpdateRelease: Codable, Equatable {
    let version: String
    let build: String
    let url: URL
    let sha256: String
    let bytes: Int64

    var key: String { version + "/" + build }
    var label: String { version + " · build " + build }

    func validate() throws {
        let parts = url.path.split(separator: "/")
        guard url.scheme == "https", url.host == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              parts.count == 6, parts[0] == "hongson117", parts[1] == "iSideload-releases",
              parts[2] == "releases", parts[3] == "download",
              ["iSideload.ipa", "iContainer.ipa"].contains(String(parts[5])) else {
            throw AppUpdateError.invalid("Địa chỉ bản cập nhật không thuộc kho phát hành chính thức.")
        }
        try validateMetadata()
    }

    private func validateMetadata() throws {
        guard Self.numbers(version) != nil, Int(build).map({ $0 > 0 }) == true,
              bytes > 0, bytes <= 200 * 1024 * 1024, sha256.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AppUpdateError.invalid("Thông tin phiên bản hoặc checksum không hợp lệ.")
        }
    }

    static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        guard values.count == parts.count else { return nil }
        return values + Array(repeating: 0, count: 3 - values.count)
    }

    func isNewer(than version: String, build: String) -> Bool {
        guard let new = Self.numbers(self.version), let old = Self.numbers(version),
              let nextBuild = Int(self.build), let currentBuild = Int(build) else { return false }
        for index in 0..<3 where new[index] != old[index] { return new[index] > old[index] }
        return nextBuild > currentBuild
    }
}

enum AppUpdateError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

enum AppUpdates {
    static let feed = URL(string: "https://raw.githubusercontent.com/hongson117/iSideload-releases/main/app-updates.json")!
    static func product(bundleID: String) -> String? {
        for product in ["isideload", "icontainer"] {
            let base = "com.hongson117." + product
            if bundleID == base || bundleID.hasPrefix(base + ".") { return product }
        }
        return nil
    }

    static func latest(product: String) async throws -> AppUpdateRelease? {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 64 * 1024 else {
            throw AppUpdateError.invalid("Chưa đọc được danh sách cập nhật từ GitHub.")
        }
        let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: data)
        guard manifest.schema == 1 else { throw AppUpdateError.invalid("Định dạng cập nhật chưa được hỗ trợ.") }
        guard let release = manifest.apps[product] else { return nil }
        try release.validate()
        let expected = product == "icontainer" ? "iContainer.ipa" : "iSideload.ipa"
        guard release.url.lastPathComponent == expected else { throw AppUpdateError.invalid("Bản cập nhật thuộc ứng dụng khác.") }
        return release
    }
}
