import Foundation

@main
struct LiveContainerSigningTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }
    static func main() throws {
        let ipa = URL(fileURLWithPath: "/tmp/livecontainer.ipa")
        let apple = "apple:test@example.test"
        let sources = ["cert", apple]
        let plan = try LiveContainerInstallPlan(ipa: ipa, upgrade: true, selectedSigner: apple, availableSigners: sources)
        try expect(plan.signer == apple, "Explicit Apple ID must win even when imported certificate is first")
        let imported = try LiveContainerInstallPlan(ipa: ipa, upgrade: true, selectedSigner: "cert", availableSigners: sources)
        try expect(imported.signer == "cert", "Imported certificate can be explicitly selected")
        for missing in [nil, "", "apple:logged-out@example.test"] as [String?] {
            do {
                _ = try LiveContainerInstallPlan(ipa: ipa, upgrade: true, selectedSigner: missing, availableSigners: sources)
                throw Failure.assertion("Must never silently fall back to default/old signer")
            } catch is LiveContainerInstallPlan.Invalid {}
        }
        let old = SideloadedApp(bundleID: "com.kdt.livecontainer", name: "LC", version: "1", expires: nil, ipaFile: nil, signer: "cert")
        let chosen = SideloadedApp(bundleID: "com.kdt.livecontainer.TESTTEAM01", name: "LC", version: "2", expires: nil, ipaFile: nil, signer: apple)
        let unrelated = SideloadedApp(bundleID: "com.kdt.livecontainer2", name: "Other", version: "1", expires: nil, ipaFile: nil, signer: "cert")
        let apps = [old, chosen, unrelated]
        try expect(LiveContainerSigning.latestInstalled(in: apps)?.signer == apple, "Do not export certificate of the older copy")
        try expect(LiveContainerSigning.latestInstalled(in: [chosen, old], activeBundleID: chosen.bundleID)?.signer == apple,
                   "Refreshing an older certificate-signed copy must not change the selected source")
        try expect(LiveContainerSigning.needsManualCertificateImport(apps: apps), "Multiple URL-scheme targets require manual import")
        try expect(!LiveContainerSigning.needsManualCertificateImport(apps: [chosen, unrelated]), "Single exact-family target may receive link")
        try expect(LiveContainerSigning.needsManualCertificateImport(apps: []), "Unknown target must not receive arbitrary default certificate")
        var unknown = chosen; unknown.signer = nil
        try expect(LiveContainerSigning.latestInstalled(in: [unknown])?.signer == nil, "Discovered app with unknown signer stays unknown")
        print("LiveContainer signing tests passed: explicit Apple ID/certificate selection, missing/expired choices, latest identity, ambiguous targets, unknown source")
    }
}
