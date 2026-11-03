import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @AppStorage("autoRefresh") private var autoRefresh = false
    @AppStorage("refreshDays") private var refreshDays = 2
    @AppStorage("fgRefresh") private var fgRefresh = true
    @AppStorage("vpnAutoOff") private var vpnAutoOff = true
    @AppStorage("otaRelay") private var otaRelay = ""
    @State private var notices = false
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
                    Toggle("Chỉ bật VPN khi cài/ký lại, xong tự tắt", isOn: $vpnAutoOff)
                } header: { Text("Địa chỉ VPN loopback") } footer: { Text("Mặc định 10.7.0.1 (LocalDevVPN). Khi bật tuỳ chọn, iContainer tự mở LocalDevVPN để bật trước mỗi lần cài/ký lại và tắt ngay khi xong (thành công hay lỗi) để không ảnh hưởng Tailscale/mạng thường. Ký lại chạy nền không bật/tắt được VPN (giới hạn iOS).") }
                Section {
                    Toggle("Tự ký lại mỗi ngày", isOn: $autoRefresh)
                        .onChange(of: autoRefresh) { _, on in
                            if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                            AutoRefresh.schedule()
                        }
                    Toggle("Tự ký lại khi mở app (app còn < 2 ngày)", isOn: $fgRefresh)
                    Stepper("Ký lại khi còn dưới \(refreshDays) ngày", value: $refreshDays, in: 1...7)
                    Text("Lần ký lại gần nhất: " + (AutoRefresh.lastRun?.formatted(date: .abbreviated, time: .shortened) ?? "chưa có"))
                        .font(.footnote)
                    Button("Ký lại tất cả ngay") { Task { await engine.refreshAll(includeSelf: true, onlyDue: false, background: false) } }
                } header: { Text("Tự ký lại") } footer: {
                    Text("iOS tự quyết định lúc chạy nền; tác vụ nền chỉ gia hạn các app khác khi LocalDevVPN đang bật. Để gia hạn cả iContainer: mở app và bấm Ký lại tất cả, hoặc dùng Phím tắt › Tự động hóa › Hằng ngày › Chạy ngay: Ký lại tất cả app. iContainer mở LocalDevVPN nếu cần và tự ký chính nó sau cùng; app có thể tự đóng khi iOS cài đè.")
                }
                Section {
                    TextField("https://api.palera.in/genPlist", text: $otaRelay)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("Relay manifest (chứng chỉ)") } footer: {
                    Text("App ký bằng chứng chỉ có sẵn cài kiểu KSign: không cần VPN. IPA phát từ chính iContainer (127.0.0.1), chỉ manifest đi qua relay HTTPS này. Để trống = mặc định; tự host: thư mục relay/ trong repo.")
                }
                Section("Phiên bản") {
                    Text("iContainer \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · core \(CoreCall.version) · \(Bundle.main.infoDictionary?["ISLGitSHA"] as? String ?? "")")
                    Button("Giấy phép phần mềm nguồn mở") { notices = true }
                }
            }
            .navigationTitle("Cài đặt")
            .sheet(isPresented: $notices) {
                NavigationStack {
                    ScrollView {
                        Text((Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
                            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "Xem thông tin giấy phép trong bản phát hành chính thức.")
                            .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }.navigationTitle("Giấy phép")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { notices = false } } }
                }
            }
        }
    }
}
