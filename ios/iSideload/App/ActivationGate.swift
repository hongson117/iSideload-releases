import SwiftUI
#if canImport(LicenseKit)
import LicenseKit
#endif

/// Activation hook: every feature sits behind this gate.
/// License server app id "isideload", codes prefixed "ISL-".
/// When /workspace/shared/LicenseKit is added as a package dependency in project.yml,
/// `canImport(LicenseKit)` turns on and the real check is used. Until then the gate is open.
enum ActivationConfig {
    static let appID = "isideload"
    static let codePrefix = "ISL-"
}

struct ActivationGate<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        #if canImport(LicenseKit)
        // TODO(LicenseKit): replace with the module's real gate view once its API is published.
        LicenseGate(appID: ActivationConfig.appID, codePrefix: ActivationConfig.codePrefix) { content() }
        #else
        content()
        #endif
    }
}
