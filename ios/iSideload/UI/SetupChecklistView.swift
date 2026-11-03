import SwiftUI

/// First-run steps live next to the self-refresh card, so a new phone is never a blank list.
struct SetupChecklistView: View {
    @EnvironmentObject var engine: Engine
    private var usesAppleID: Bool { engine.defaultSigner != "cert" }
    private var complete: Bool {
        engine.canSign && (!usesAppleID || (engine.hasPairing && LoopbackVPN.helperInstalled))
    }

    var body: some View {
        if !complete {
            Section {
                step("1. Chọn tài khoản ký", done: engine.canSign,
                     detail: "Đăng nhập Apple ID của bạn, hoặc nhập chứng chỉ có sẵn.") {
                    engine.selectedTab = 3
                }
                if usesAppleID {
                    step("2. Cài LocalDevVPN", done: LoopbackVPN.helperInstalled,
                         detail: "Ứng dụng miễn phí trên App Store, dùng khi ký/cài trên chính máy này.") {
                        UIApplication.shared.open(LoopbackVPN.appStoreURL)
                    }
                    step(engine.hasPairing ? "3. Kiểm tra kết nối máy này" : "3. Thiết lập file ghép đôi", done: engine.pairingVerified,
                         detail: engine.hasPairing ? "Đã có file. Bật LocalDevVPN rồi bấm Kiểm tra kết nối ở đầu tab Thiết bị; chưa cần ghép đôi lại." : "Bộ cài Windows/Mac RC2 tự đưa file vào app. Nếu cài cách khác, vào Thiết bị để xem cách thiết lập.") {
                        engine.selectedTab = 2
                    }
                }
            } header: { Text("Thiết lập lần đầu") } footer: {
                Text("Đã có file không đồng nghĩa đã kiểm tra kết nối. Mở tab Thiết bị, bật LocalDevVPN và kiểm tra trước khi thử gia hạn.")
            }
        }
    }

    private func step(_ title: String, done: Bool, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? .green : Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.disabled(engine.busy)
    }
}
