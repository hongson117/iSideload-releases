import SwiftUI

@main
struct iSideloadApp: App {
    @StateObject private var license: LicenseManager
    @StateObject private var engine = Engine.shared
    @Environment(\.scenePhase) private var phase

    init() {
        LicenseManager.configure(.isideload)   // app id "isideload", codes ISL-…
        _license = StateObject(wrappedValue: LicenseManager.shared)
        AutoRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            LicenseGate(license) {
                ContentView()
                    .environmentObject(engine)
                    .onOpenURL { engine.handleURL($0) }
            }
        }
        .onChange(of: phase) { _, p in if p == .background { AutoRefresh.schedule() } }
    }
}
