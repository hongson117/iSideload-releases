import SwiftUI

struct PeerInstallView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var installer = PeerInstaller()
    @State private var account = ""
    @State private var confirmInstall = false
    @State private var bootstrap = false
    @State private var useOneUse = true
    @State private var receiverEmail = ""
    @State private var receiverPassword = ""

    private var signingChoice: PeerSigningChoice? {
        PeerSigningChoice.resolve(useOneUse: useOneUse, saved: account, available: engine.signedAccounts,
                                  entered: receiverEmail, password: receiverPassword)
    }
    private var signingAccount: String { signingChoice?.account ?? receiverEmail.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                Toggle("Cài tạm bằng tài khoản máy hỗ trợ", isOn: $bootstrap).disabled(installer.active)
                Text(bootstrap ? "Người nhận đăng nhập Apple ID riêng sau khi cài và chọn Thiết lập bản cá nhân. Khóa ký của tài khoản máy hỗ trợ không được chuyển sang máy nhận." : "Chọn Apple ID người nhận để ký bản đầu tiên. Người nhận dùng chính tài khoản đó để tự gia hạn.").font(.footnote).foregroundStyle(.secondary)
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
                    if useOneUse {
                        TextField(bootstrap ? "Apple ID máy hỗ trợ" : "Apple ID người nhận", text: $receiverEmail)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).textContentType(.username)
                        SecureField("Mật khẩu · chỉ dùng cho lượt cài này", text: $receiverPassword).textContentType(.password)
                        Text("Không lưu mật khẩu vào Keychain hoặc danh sách tài khoản trên máy hỗ trợ. Mã 2FA được hỏi trong quá trình ký nếu Apple yêu cầu.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !engine.signedAccounts.isEmpty {
                            Button("Dùng một tài khoản đã đăng nhập") { useOneUse = false; receiverPassword = "" }
                        }
                    } else {
                        Picker(bootstrap ? "Apple ID máy hỗ trợ" : "Apple ID của người nhận", selection: $account) {
                            Text("Chọn tài khoản").tag("")
                            ForEach(engine.signedAccounts, id: \.self) { Text($0).tag($0) }
                        }
                        Button(bootstrap ? "Nhập Apple ID khác cho lượt cài này" : "Nhập Apple ID của người nhận ngay tại đây") {
                            useOneUse = true; receiverEmail = ""; receiverPassword = ""
                        }
                    }
                    Button(peer.installedAt == nil ? "Cài iContainer lên máy này" : "Cài lại iContainer lên máy này") {
                        confirmInstall = true
                    }.disabled(installer.active || signingChoice == nil)
                } header: { Text("2. Xác nhận máy nhận và cài") } footer: {
                    Text("Chọn hoặc nhập Apple ID người nhận ngay ở đây để ký bản cài đầu tiên. Sau khi cài, người nhận đăng nhập chính tài khoản đó để tự gia hạn. App mới không được thêm vào danh sách app của máy hỗ trợ.")
                }.disabled(installer.active)
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
                    Label(installer.receiverSetupVerified ? (installer.receiverNeedsPersonalSetup ? "Đã cài bản khởi tạo" : "Cài và thiết lập thành công") : "Đã cài · cần hoàn tất thiết lập", systemImage: installer.receiverSetupVerified ? "checkmark.circle.fill" : "exclamationmark.triangle").foregroundStyle(installer.receiverSetupVerified ? .green : .orange)
                    Text("Trên máy nhận: Cài đặt › Cài đặt chung › VPN & Quản lý thiết bị › tin cậy tài khoản nhà phát triển.")
                    Text(installer.receiverNeedsPersonalSetup ? "Mở iContainer trên máy nhận, đăng nhập Apple ID riêng rồi chọn Thiết lập iContainer bằng tài khoản này. Cài bản cá nhân trước khi dùng tài khoản đó để tự gia hạn." : "Mở iContainer trên máy nhận và đăng nhập đúng Apple ID đã chọn ở bước cài. Bản đã thiết lập thành công có sẵn khóa ký và ghép nối; cài LocalDevVPN rồi Kiểm tra kết nối để tự gia hạn.")
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
        .onAppear {
            if account.isEmpty { account = installer.receiver?.installAccount ?? "" }
            if let previous = installer.receiver?.installedBootstrap { bootstrap = previous }
            if engine.signedAccounts.contains(account) { useOneUse = false }
            else { useOneUse = true; receiverEmail = installer.receiver?.installAccount ?? "" }
        }
        .onDisappear { receiverPassword = "" }
        .confirmationDialog("Cài iContainer lên \(installer.receiver?.name ?? "máy nhận")?",
                            isPresented: $confirmInstall, titleVisibility: .visible) {
            Button("Ký và cài bằng \(signingAccount)") {
                if let choice = signingChoice {
                    receiverPassword = ""
                    Task { await installer.install(account: choice.account, bootstrap: bootstrap, oneUsePassword: choice.oneUsePassword) }
                }
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text(bootstrap
                 ? "Máy nhận: \(installer.receiver?.ip ?? ""). Đây là bản khởi tạo ký bằng \(signingAccount). Người nhận đăng nhập tài khoản riêng và thiết lập bản cá nhân sau khi cài. Khóa ký của máy hỗ trợ không được chuyển sang."
                 : "Máy nhận: \(installer.receiver?.ip ?? ""). Apple ID người nhận: \(signingAccount). Người nhận sẽ dùng chính tài khoản này để tự gia hạn. Đổi tài khoản khi cài lại có thể tạo bản app riêng; bản cũ không tự bị gỡ. Giữ cả hai máy mở khóa và cùng Wi-Fi cho đến khi cài xong.")
        }
    }
}
