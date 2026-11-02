import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        TabView {
            AppsView().tabItem { Label("Ứng dụng", systemImage: "square.grid.2x2") }
            SourcesView().tabItem { Label("Nguồn", systemImage: "tray.full") }
            DeviceView().tabItem { Label("Thiết bị", systemImage: "iphone") }
            AccountView().tabItem { Label("Tài khoản", systemImage: "person.crop.circle") }
            SettingsView().tabItem { Label("Cài đặt", systemImage: "gear") }
        }
        .tint(Theme.accent)
        .overlay {
            if engine.busy {
                VStack(spacing: 12) {
                    ProgressView(value: engine.progress > 0 ? engine.progress : nil)
                    Text(engine.stage.isEmpty ? "Đang xử lý…" : engine.stage).font(.callout)
                }
                .padding(24).frame(maxWidth: 300)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .sheet(item: $engine.prompt) { PromptSheet(prompt: $0).interactiveDismissDisabled() }
        .alert("Lỗi", isPresented: Binding(get: { engine.errorText != nil }, set: { if !$0 { engine.errorText = nil } })) {
            Button("Sao chép") { UIPasteboard.general.string = engine.errorText; engine.errorText = nil }
            Button("OK", role: .cancel) { engine.errorText = nil }
        } message: { Text(engine.errorText ?? "") }
        .alert("Xong", isPresented: Binding(get: { engine.infoText != nil }, set: { if !$0 { engine.infoText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(engine.infoText ?? "") }
        .confirmationDialog("Cài IPA này — chọn tài khoản ký", isPresented: Binding(get: { engine.pendingIPA != nil && !engine.busy }, set: { if !$0 { engine.pendingIPA = nil } })) {
            ForEach(engine.signers, id: \.self) { sg in
                Button("Ký bằng \(engine.signerSummary(sg))") {
                    if let u = engine.pendingIPA { engine.pendingIPA = nil; engine.installSigner = sg; Task { await engine.install(ipa: u, signer: sg) } }
                }
            }
            if engine.signers.isEmpty { Button("Ký và cài") { if let u = engine.pendingIPA { engine.pendingIPA = nil; Task { await engine.install(ipa: u) } } } }
            Button("Huỷ", role: .cancel) { engine.pendingIPA = nil }
        }
    }
}
