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
                    step("3. Ghép nối máy này", done: engine.hasPairing,
                         detail: "Ghép nối lúc nhận app thuộc máy hỗ trợ. Máy này cần tạo bản ghi riêng để tự gia hạn.") {
                        engine.selectedTab = 2
                    }
                }
            } header: { Text("Thiết lập lần đầu") } footer: {
                Text("Xong các bước trên, bấm Làm mới iSideload để thử gia hạn. App tự mở LocalDevVPN khi cần kết nối.")
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
