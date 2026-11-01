import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @AppStorage("autoRefresh") private var autoRefresh = false
    @AppStorage("refreshDays") private var refreshDays = 6
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
                Section {
                    Toggle("Tự ký lại mỗi ngày", isOn: $autoRefresh)
                        .onChange(of: autoRefresh) { _, on in
                            if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                            AutoRefresh.schedule()
                        }
                    Stepper("Ký lại khi còn dưới \(refreshDays) ngày", value: $refreshDays, in: 1...7)
                    Text("Lần ký lại gần nhất: " + (AutoRefresh.lastRun?.formatted(date: .abbreviated, time: .shortened) ?? "chưa có"))
                        .font(.footnote)
                    Button("Ký lại tất cả ngay") { Task { await engine.refreshAll(includeSelf: true, onlyDue: false, background: false) } }
                } header: { Text("Tự ký lại") } footer: {
                    Text("iOS không đảm bảo chạy nền. Chắc chắn nhất: tạo Tự động hóa trong Phím tắt lúc giờ cố định, chạy \"Ký lại tất cả app\" (hoặc mở isideload://refresh). Cần LocalDevVPN đang bật.")
                }
                Section("Phiên bản") {
                    Text("iSideload \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · core \(CoreCall.version) · \(Bundle.main.infoDictionary?["ISLGitSHA"] as? String ?? "")")
                }
            }
            .navigationTitle("Cài đặt")
        }
    }
}
