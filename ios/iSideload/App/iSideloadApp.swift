import SwiftUI

@main
struct iSideloadApp: App {
    @StateObject private var engine = Engine()
    var body: some Scene {
        WindowGroup {
            ActivationGate { ContentView() }
                .environmentObject(engine)
                .onOpenURL { engine.importIPA(from: $0) }
        }
    }
}
