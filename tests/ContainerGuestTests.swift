import Foundation

@main
struct ContainerGuestTests {
    static func main() throws {
        let base: [String: Any] = ["id":"F2DBEB83-E500-4345-994A-FB7DCD729186", "bundle_id":"example.calendar", "name":"Calendar", "version":"1", "prepared":true]
        func decode(_ value: [String: Any]) throws -> ContainerGuest {
            try JSONDecoder().decode(ContainerGuest.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let old = try decode(base)
        precondition(old.prepared && !old.readyToLaunch, "Old prepared copies must be re-prepared before dlopen")
        var previous = base; previous["preparation_revision"] = 2
        let xmlOnly = try decode(previous)
        precondition(!xmlOnly.readyToLaunch, "XML-only signatures require preparation again")
        var fixed = base; fixed["preparation_revision"] = 3
        let fresh = try decode(fixed)
        precondition(fresh.readyToLaunch && fresh.id == old.id && fresh.bundleID == old.bundleID)
        fixed["prepared_slots"] = ["com.hongson117.sicontainer.BSV5CJQF89", "com.hongson117.sicontainer.runner1.BSV5CJQF89"]
        let multiSlot = try decode(fixed)
        precondition(multiSlot.isPrepared(forSlotBundleID: "com.hongson117.sicontainer.runner1.BSV5CJQF89"))
        precondition(!multiSlot.isPrepared(forSlotBundleID: "com.hongson117.sicontainer.runner2.BSV5CJQF89"))
        fixed["prepared"] = false
        let unfinished = try decode(fixed)
        precondition(!unfinished.readyToLaunch)
        print("Guest preparation cache migration tests passed")
    }
}
