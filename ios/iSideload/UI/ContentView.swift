import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        TabView(selection: $engine.selectedTab) {
            AppsView().tabItem { Label("Ứng dụng", systemImage: "square.grid.2x2") }.tag(0)
            SourcesView().tabItem { Label("Nguồn", systemImage: "tray.full") }.tag(1)
            DeviceView().tabItem { Label("Thiết bị", systemImage: "iphone") }.tag(2)
            AccountView().tabItem { Label("Tài khoản", systemImage: "person.crop.circle") }.tag(3)
            SettingsView().tabItem { Label("Cài đặt", systemImage: "gear") }.tag(4)
        }
        .tint(Theme.accent)
        .overlay {
            if engine.busy && !engine.peerBusy {
                VStack(spacing: 12) {
                    ProgressView(value: engine.progress > 0 ? engine.progress : nil)
                    Text(engine.stage.isEmpty ? "Đang xử lý…" : engine.stage).font(.callout)
                }
                .padding(24).frame(maxWidth: 300)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .sheet(item: $engine.prompt) { PromptSheet(prompt: $0).interactiveDismissDisabled() }
        .sheet(item: $engine.liveContainerCertificateFile) { LiveContainerCertificateSheet(file: $0) }
        .alert("Lỗi", isPresented: Binding(get: { engine.errorText != nil }, set: { if !$0 { engine.errorText = nil } })) {
            if (engine.errorText ?? "").contains("LocalDevVPN") || (engine.errorText ?? "").contains("10.7.0.1") {
                Button("Mở LocalDevVPN") { engine.errorText = nil; LoopbackVPN.turnOn() }
            }
            if (engine.errorText ?? "").localizedCaseInsensitiveContains("chứng chỉ") || (engine.errorText ?? "").localizedCaseInsensitiveContains("certificate") {
                Button("Quản lý chứng chỉ") { engine.errorText = nil; engine.selectedTab = 4; engine.showCertificateManager = true }
            }
            Button("Sao chép") { UIPasteboard.general.string = engine.errorText; engine.errorText = nil }
            Button("OK", role: .cancel) { engine.errorText = nil }
        } message: { Text(engine.errorText ?? "") }
        .alert("Xong", isPresented: Binding(get: { engine.infoText != nil }, set: { if !$0 { engine.infoText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(engine.infoText ?? "") }
        .confirmationDialog("Cài IPA này — chọn tài khoản ký", isPresented: Binding(get: { engine.pendingIPA != nil && !engine.busy }, set: { if !$0 { engine.pendingIPA = nil } })) {
            ForEach(engine.signers, id: \.self) { sg in
                Button("Ký bằng \(engine.signerSummary(sg))") {
                    if let u = engine.pendingIPA { engine.pendingIPA = nil; engine.installSigner = sg; Task { await engine.installNow(u, signer: sg) } }
                }
            }
            Button("Huỷ", role: .cancel) { engine.pendingIPA = nil }
        }
    }
}
