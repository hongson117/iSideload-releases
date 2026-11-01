import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://ani.jkcoxson.com", text: $engine.anisetteURL).keyboardType(.URL).textInputAutocapitalization(.never)
                } header: { Text("Máy chủ anisette") } footer: {
                    Text("Để trống = tự thử lần lượt ani.jkcoxson.com → mac-ani.jkcoxson.com → ani.npeg.us → ani.sidestore.io.")
                }
                Section {
                    TextField(LoopbackVPN.defaultTarget, text: $engine.vpnTarget).keyboardType(.decimalPad)
                } header: { Text("Địa chỉ VPN loopback") } footer: { Text("Mặc định 10.7.0.1 (LocalDevVPN).") }
                Section("Phiên bản") {
                    Text("iSideload \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · core \(CoreCall.version) · \(Bundle.main.infoDictionary?["ISLGitSHA"] as? String ?? "")")
                }
            }
            .navigationTitle("Cài đặt")
        }
    }
}
