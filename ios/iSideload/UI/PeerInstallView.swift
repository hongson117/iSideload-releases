import SwiftUI

struct PeerInstallView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var installer = PeerInstaller()
    @State private var account = ""
    @State private var confirmInstall = false

    var body: some View {
        Form {
            Section {
                Label("Hai máy cùng Wi-Fi", systemImage: "wifi")
                Text("Máy nhận cần iOS/iPadOS 27 trở lên, đã bật Chế độ nhà phát triển và giữ màn hình mở khóa. Giữ iContainer mở trên máy này trong suốt quá trình.")
                Text("Dùng Wi-Fi trực tiếp giữa hai máy. LocalDevVPN không cần cho lượt cài này; nếu VPN chặn mạng cục bộ, hãy tắt trước khi bắt đầu.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Chuẩn bị") }

            Section {
                if installer.phase == .pairing {
                    ProgressView("Đang chờ máy nhận…")
                    if !installer.hostName.isEmpty { Text(installer.hostName).font(.headline).textSelection(.enabled) }
                    Text("Trên máy nhận: Cài đặt › Quyền riêng tư & Bảo mật › Chế độ nhà phát triển › Thiết bị khác. Chọn tên ở trên.")
                    if !installer.pin.isEmpty {
                        Text("Nhập mã này trên máy nhận:")
                        Text(installer.pin).font(.system(size: 38, weight: .bold, design: .monospaced))
                            .accessibilityLabel("Mã ghép nối \(installer.pin)")
                    }
                    Button("Hủy ghép nối", role: .cancel) { installer.cancelPairing() }
                } else {
                    Button {
                        Task { await installer.pair() }
                    } label: { Label("Ghép nối iPhone mới", systemImage: "plus.circle") }
                    .disabled(engine.busy)
                }
            } header: { Text("1. Ghép nối máy nhận") } footer: {
                Text("Không cần RC Pair trên máy nhận. Nếu không thấy tên: kiểm tra quyền Mạng cục bộ của iContainer và mạng Wi-Fi không bật cách ly thiết bị.")
            }

            if let peer = installer.receiver, installer.phase != .pairing {
                Section {
                    LabeledContent("Tên", value: peer.name)
                    LabeledContent("Thiết bị", value: peer.model)
                    LabeledContent("IP Wi-Fi", value: peer.ip)
                    Text(peer.udid).font(.caption.monospaced()).textSelection(.enabled)
                    Picker("Apple ID của người nhận", selection: $account) {
                        Text("Chọn tài khoản").tag("")
                        ForEach(engine.signedAccounts, id: \.self) { Text($0).tag($0) }
                    }.disabled(installer.active)
                    if engine.signedAccounts.isEmpty {
                        Text("Quay lại tab Tài khoản để đăng nhập Apple ID, rồi trở lại đây. Kết nối vừa ghép đã được lưu.")
                            .foregroundStyle(.orange)
                    }
                    Button(peer.installedAt == nil ? "Cài iContainer lên máy này" : "Cài lại iContainer lên máy này") {
                        confirmInstall = true
                    }.disabled(installer.active || !engine.signedAccounts.contains(account))
                } header: { Text("2. Xác nhận máy nhận và cài") } footer: {
                    Text("Chọn đúng Apple ID của người nhận để ký bản cài đầu tiên. Sau khi cài, người nhận đăng nhập chính tài khoản này để tự gia hạn. Nếu chưa có, thêm ở tab Tài khoản trước khi cài. App mới không được thêm vào danh sách của máy hỗ trợ.")
                }
            }

            if !installer.stage.isEmpty || installer.error != nil {
                Section {
                    if installer.phase == .installing {
                        ProgressView(value: installer.progress > 0 ? installer.progress : nil)
                    }
                    Text(installer.stage)
                    if let error = installer.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        Button("Sao chép lỗi") { UIPasteboard.general.string = error }
                    }
                } header: { Text("Tiến trình") }
            }

            if installer.phase == .installed {
                Section {
                    Label(installer.receiverSetupVerified ? "Cài và thiết lập thành công" : "Đã cài · cần hoàn tất thiết lập", systemImage: installer.receiverSetupVerified ? "checkmark.circle.fill" : "exclamationmark.triangle").foregroundStyle(installer.receiverSetupVerified ? .green : .orange)
                    Text("Trên máy nhận: Cài đặt › Cài đặt chung › VPN & Quản lý thiết bị › tin cậy tài khoản nhà phát triển.")
                    Text("Mở iContainer trên máy nhận và đăng nhập đúng Apple ID đã chọn ở bước cài. Bản đã thiết lập thành công có sẵn khóa ký và ghép nối; cài LocalDevVPN rồi Kiểm tra kết nối để tự gia hạn.")
                } header: { Text("3. Hoàn tất trên máy nhận") }
            }

            if let peer = installer.receiver, !installer.active {
                Section {
                    ShareLink(item: peer.recordURL) { Label("Xuất bản ghi ghép nối máy nhận", systemImage: "square.and.arrow.up") }
                } footer: { Text("Bản ghi cấp quyền kết nối máy nhận. Chỉ chia sẻ với máy chủ hoặc người quản trị bạn tin cậy. Không chứa mật khẩu Apple ID.") }
            }
        }
        .navigationTitle("Cài cho iPhone khác")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(installer.active)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { if account.isEmpty { account = installer.receiver?.installAccount ?? "" } }
        .confirmationDialog("Cài iContainer lên \(installer.receiver?.name ?? "máy nhận")?",
                            isPresented: $confirmInstall, titleVisibility: .visible) {
            Button("Ký và cài bằng \(account)") { Task { await installer.install(account: account) } }
            Button("Hủy", role: .cancel) {}
        } message: { Text("Máy nhận: \(installer.receiver?.ip ?? ""). Apple ID người nhận: \(account). Người nhận sẽ dùng chính tài khoản này để tự gia hạn. Đổi tài khoản khi cài lại có thể tạo bản app riêng; bản cũ không tự bị gỡ. Giữ cả hai máy mở khóa và cùng Wi-Fi cho đến khi cài xong.") }
    }
}
