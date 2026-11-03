import Foundation

/// A one-use recipient credential is not written to the helper's account roster
/// or Keychain. The signing request uses it only for this install operation.
struct PeerSigningChoice {
    let account: String
    let oneUsePassword: String?

    static func resolve(useOneUse: Bool, saved: String, available: [String], entered: String, password: String) -> PeerSigningChoice? {
        if useOneUse {
            let account = entered.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !account.isEmpty && !password.isEmpty else { return nil }
            return PeerSigningChoice(account: account, oneUsePassword: password)
        }
        guard available.contains(saved) else { return nil }
        return PeerSigningChoice(account: saved, oneUsePassword: nil)
    }
}
