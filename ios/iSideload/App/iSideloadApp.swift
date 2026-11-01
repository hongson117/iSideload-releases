import SwiftUI

@main
struct iSideloadApp: App {
    @StateObject private var engine = Engine()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .onOpenURL { engine.importIPA(from: $0) }
        }
    }
}
