import SwiftUI

@main
struct iSideloadApp: App {
    @StateObject private var license: LicenseManager
    @StateObject private var engine = Engine()

    init() {
        LicenseManager.configure(.isideload)   // app id "isideload", codes ISL-…
        _license = StateObject(wrappedValue: LicenseManager.shared)
    }

    var body: some Scene {
        WindowGroup {
            LicenseGate(license) {
                ContentView()
                    .environmentObject(engine)
                    .onOpenURL { engine.importIPA(from: $0) }
            }
        }
    }
}
