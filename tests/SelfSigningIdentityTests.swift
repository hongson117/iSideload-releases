import Foundation

@main
struct SelfSigningIdentityTests {
    static func main() {
        let data = Data(#"{"bundle_id":"com.hongson117.icontainer.A5CFR7SJU8","team_id":"A5CFR7SJU8","apple_id":"installer@example.com"}"#.utf8)
        let own = SelfSigningIdentity(bundleID: "com.hongson117.icontainer.A5CFR7SJU8", teamID: "A5CFR7SJU8", installerData: data)
        precondition(own.installerAppleID == "installer@example.com")
        precondition(own.accepts(teamIDs: ["OTHER12345", "A5CFR7SJU8"]))
        precondition(!own.accepts(teamIDs: ["OTHER12345"]))
        precondition(!own.accepts(teamIDs: []))
        let stale = SelfSigningIdentity(bundleID: "com.hongson117.icontainer.OTHER12345", teamID: "OTHER12345", installerData: data)
        precondition(stale.installerAppleID == nil, "An old install must not label a new team's account as owner")
        let unknown = SelfSigningIdentity(bundleID: own.bundleID, teamID: own.teamID, installerData: nil)
        precondition(unknown.installerAppleID == nil, "Never infer the installer from the first logged-in account")
        print("Self signing identity tests passed")
    }
}
