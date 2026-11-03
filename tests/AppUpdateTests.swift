import Foundation

@main
struct AppUpdateTests {
    static func main() throws {
        let url = URL(string: "https://github.com/hongson117/iSideload-releases/releases/download/v1.2.4-rc2/iSideload.ipa")!
        let release = AppUpdateRelease(version: "1.2.4", build: "7", url: url, sha256: String(repeating: "a", count: 64), bytes: 6_000_000)
        try release.validate()
        precondition(release.isNewer(than: "1.2.4", build: "6"))
        precondition(!release.isNewer(than: "1.2.4", build: "7"))
        precondition(!release.isNewer(than: "1.2.4", build: "8"))
        precondition(release.isNewer(than: "1.2.3", build: "99"))
        precondition(!release.isNewer(than: "1.2.10", build: "1"))
        precondition(!release.isNewer(than: "2.0.0", build: "1"))
        for invalid in ["1..2", "1.2-rc", "1.2.3.4", "", "-1.2", "1.x"] {
            precondition(!release.isNewer(than: invalid, build: "1"))
        }
        for bad in ["http://github.com/hongson117/iSideload-releases/releases/download/v1/iSideload.ipa",
                    "https://github.com/other/iSideload-releases/releases/download/v1/iSideload.ipa",
                    "https://github.com.evil.test/hongson117/iSideload-releases/releases/download/v1/iSideload.ipa",
                    "https://github.com/hongson117/iSideload-releases/releases/download/v1/iSideload.ipa?redirect=x",
                    "https://github.com/hongson117/iSideload-releases/releases/download/v1/extra/iSideload.ipa"] {
            let unsafe = AppUpdateRelease(version: release.version, build: release.build, url: URL(string: bad)!, sha256: release.sha256, bytes: release.bytes)
            do { try unsafe.validate(); preconditionFailure("Accepted an untrusted release URL") } catch {}
        }
        precondition(AppUpdates.product(bundleID: "com.hongson117.icontainer.PERSONAL12") == "icontainer")
        precondition(AppUpdates.product(bundleID: "com.hongson117.sicontainer.PERSONAL12") == "sicontainer")
        precondition(AppUpdates.product(bundleID: "com.hongson117.isideload.PERSONAL12") == "isideload")
        precondition(AppUpdates.product(bundleID: "com.hongson117.icontainerFake") == nil)
        let encoded = try JSONEncoder().encode(release)
        let decoded = try JSONDecoder().decode(AppUpdateRelease.self, from: encoded)
        precondition(decoded == release)
        print("App update policy tests passed: trust, version ordering, owner families, VPN-pending payload serialization")
    }
}
