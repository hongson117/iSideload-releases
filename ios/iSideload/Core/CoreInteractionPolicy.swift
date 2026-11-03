import Foundation

/// Interaction belongs to the job, not a transient UIKit state during VPN hand-off.
enum CoreInteractionPolicy {
    static func configure(_ request: [String: Any], background: Bool) -> [String: Any] {
        var value = request
        value["interaction_mode"] = background ? "background" : "foreground"
        value["allow_interactive_prompts"] = !background
        value["allow_certificate_prompt"] = !background
        return value
    }

    static func allowsPrompts(_ request: [String: Any]) -> Bool {
        if let mode = request["interaction_mode"] as? String { return mode == "foreground" }
        return request["allow_interactive_prompts"] as? Bool ?? true
    }
}
