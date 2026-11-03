import Foundation

@main
struct CoreInteractionPolicyTests {
    static func main() {
        // A foreground job resumed from VPN must replace an old inactive-state snapshot.
        let resumed = CoreInteractionPolicy.configure(["op": "install", "allow_certificate_prompt": false], background: false)
        precondition(CoreInteractionPolicy.allowsPrompts(resumed))
        precondition(resumed["allow_certificate_prompt"] as? Bool == true)
        let background = CoreInteractionPolicy.configure(resumed, background: true)
        precondition(!CoreInteractionPolicy.allowsPrompts(background))
        precondition(background["allow_certificate_prompt"] as? Bool == false)
        precondition(background["op"] as? String == "install")
        // Explicit background mode wins even if a legacy flag was incorrectly true.
        precondition(!CoreInteractionPolicy.allowsPrompts(["interaction_mode": "background", "allow_interactive_prompts": true]))
        print("Foreground VPN resume and background prompt isolation tests passed")
    }
}
