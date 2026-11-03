import Foundation
@main struct PeerSigningChoiceTests {
    static func main() {
        precondition(PeerSigningChoice.resolve(useOneUse: false, saved: "", available: ["helper@example.com"], entered: "", password: "") == nil,
                     "Never silently use the helper's first account")
        let recipient = PeerSigningChoice.resolve(useOneUse: true, saved: "helper@example.com", available: ["helper@example.com"], entered: " Receiver@Example.com ", password: "test-only-password")!
        precondition(recipient.account == "receiver@example.com")
        precondition(recipient.oneUsePassword == "test-only-password")
        let saved = PeerSigningChoice.resolve(useOneUse: false, saved: "receiver@example.com", available: ["receiver@example.com"], entered: "other@example.com", password: "ignored")!
        precondition(saved.account == "receiver@example.com" && saved.oneUsePassword == nil)
        precondition(PeerSigningChoice.resolve(useOneUse: true, saved: "helper@example.com", available: ["helper@example.com"], entered: "receiver@example.com", password: "") == nil)
        print("Peer signing choice tests passed")
    }
}
