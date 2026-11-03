import SwiftUI

struct AccountView: View {
    @EnvironmentObject var engine: Engine
    @State private var email = ""
    @State private var password = ""
    @State private var adding = false
    @State private var ownerAccount: String?
    @State private var p12: URL?
    @State private var p12Password = ""
    @State private var profiles: [URL] = []
    @State private var picker: PickKind?
    enum PickKind: Identifiable { case p12, profile; var id: Int { self == .p12 ? 0 : 1 } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(engine.accounts, id: \.self) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(a).font(.headline)
                                if a == engine.appleID { Text("chính").font(.caption2).padding(.horizontal, 6).background(Theme.accent.opacity(0.2), in: Capsule()) }
                                Spacer()
                                Menu {
                                    Button("Đăng nhập lại") { email = a; password = ""; adding = true }
                                    if engine.signedAccounts.contains(a) {
                                        Button("Thiết lập iContainer bằng Apple ID này") { ownerAccount = a }
                                    }
                                    if a != engine.appleID { Button("Đặt làm tài khoản chính") { engine.makeMain(a) } }
                                    Button("Đăng xuất", role: .destructive) { engine.signOut(a) }
                                } label: {
                                    Label("Tùy chọn tài khoản", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                                }.disabled(engine.busy)
                            }
                            Text(engine.signerSummary("apple:" + a)).font(.caption).foregroundStyle(.secondary)
                            if Keychain.load(a) == nil { Text("Cần đăng nhập lại").font(.caption).foregroundStyle(.red) }
                            else {
                                Button("Thiết lập iContainer bằng tài khoản này") { ownerAccount = a }
                                    .font(.subheadline).disabled(engine.busy || engine.peerBusy)
                            }
                        }
                        .swipeActions {
                            Button("Đăng xuất", role: .destructive) { engine.signOut(a) }
                            if a != engine.appleID { Button("Đặt làm chính") { engine.makeMain(a) }.tint(.blue) }
                        }
                    }
                    if adding || engine.accounts.isEmpty {
                        TextField("Apple ID (email)", text: $email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        SecureField("Mật khẩu", text: $password).textContentType(.password)
                        Button("Đăng nhập") {
                            let account = email.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await engine.signIn(email: account, password: password)
                                password = ""
                                if engine.errorText == nil && engine.signedAccounts.contains(account) { adding = false }
                            }
                        }
                            .buttonStyle(GradientButtonStyle()).disabled(email.isEmpty || password.isEmpty || engine.busy)
                        if !engine.accounts.isEmpty {
                            Button("Hủy thêm tài khoản", role: .cancel) { adding = false; email = ""; password = "" }
                        }
                    }
                    Button {
                        email = ""; password = ""; adding = true
                    } label: {
                        Label(engine.accounts.isEmpty ? "Thêm Apple ID" : "Thêm Apple ID khác", systemImage: "person.badge.plus")
                    }.disabled(engine.busy)
                } header: { Text("Apple ID · \(engine.accounts.count) tài khoản") } footer: {
                    Text("Có thể thêm Apple ID thứ hai và các tài khoản khác bằng nút Thêm Apple ID khác. Khi cài hoặc ký lại, chọn tài khoản muốn dùng. Apple ID miễn phí: iOS giới hạn 3 app tự ký trên mỗi máy (tính cả iContainer); mỗi Apple ID có 10 App ID mỗi 7 ngày. Mỗi app nhớ tài khoản đã ký; mật khẩu lưu trong Keychain.")
                }

                if let result = engine.preparedOwnerInstallation, let file = engine.preparedOwnerIPA {
                    Section {
                        Text(result["apple_id"] as? String ?? "").font(.headline)
                        Text("App ID: \(result["bundle_id"] as? String ?? "")").font(.caption).textSelection(.enabled)
                        Button("Cài bản cá nhân lên máy này") { Task { await engine.installPreparedOwner() } }
                            .disabled(engine.busy || engine.peerBusy)
                        ShareLink(item: file) { Label("Chia sẻ bản cài cho máy hỗ trợ", systemImage: "square.and.arrow.up") }
                    } header: { Text("Bản cài của bạn đã sẵn sàng") } footer: {
                        Text("Bản cài đã ký bằng tài khoản của bạn. Giữ bản hiện tại cho đến khi bản mới cài và mở thành công; mật khẩu không nằm trong file IPA.")
                    }
                }

                Section {
                    if let c = engine.importedCert {
                        let cert = c["certificate"] as? [String: Any] ?? [:]
                        Text(cert["name"] as? String ?? "Chứng chỉ").font(.headline)
                        Text("Team \(cert["team_id"] as? String ?? "?")" + ((cert["expires"] as? Double).map { " · hết hạn " + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? "")).font(.caption)
                        ForEach(Array(((c["profiles"] as? [[String: Any]]) ?? []).enumerated()), id: \.offset) { _, p in
                            VStack(alignment: .leading) {
                                Text(p["name"] as? String ?? "").font(.subheadline)
                                Text("\(p["app_id"] as? String ?? "") · \((p["has_device"] as? Bool).map { $0 ? "có UDID máy này" : "THIẾU UDID máy này" } ?? "chưa rõ UDID")").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        ForEach((c["warnings"] as? [String]) ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        Button("Thêm .mobileprovision") { picker = .profile }
                        Button("Xoá chứng chỉ", role: .destructive) { Task { await engine.clearImportedCert() } }
                    } else {
                        Button(p12 == nil ? "Chọn file .p12" : "File: \(p12!.lastPathComponent)") { picker = .p12 }
                        SecureField("Mật khẩu .p12", text: $p12Password)
                        Button("Chọn .mobileprovision (\(profiles.count))") { picker = .profile }
                        Button("Nhập chứng chỉ") { Task { await engine.importCert(p12: p12, password: p12Password, profiles: profiles); p12Password = ""; profiles = [] } }
                            .buttonStyle(GradientButtonStyle()).disabled(p12 == nil || profiles.isEmpty || engine.busy)
                    }
                } header: { Text("Chứng chỉ có sẵn") } footer: {
                    Text("Ký bằng chứng chỉ của bạn (.p12 + profile) thay cho Apple ID. Profile cần khớp chứng chỉ, còn hạn và cho phép thiết bị này. Để chuẩn bị app bên trong Container, chứng chỉ phải khớp chính xác bản iContainer đang chạy.")
                }

                Section("Chứng chỉ phát triển (tài khoản chính)") {
                    Button("Tải danh sách chứng chỉ") { Task { await engine.loadCerts() } }.disabled(!engine.signedIn)
                    ForEach(engine.certs.indices, id: \.self) { i in
                        let c = engine.certs[i]
                        HStack {
                            VStack(alignment: .leading) {
                                Text(c["machine"] as? String ?? "?")
                                Text(c["serial"] as? String ?? "").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Thu hồi", role: .destructive) { Task { await engine.revoke(c["serial"] as? String ?? "") } }
                        }
                    }
                }
            }
            .navigationTitle("Tài khoản")
            .confirmationDialog("Thiết lập iContainer bằng tài khoản của bạn", isPresented: Binding(get: { ownerAccount != nil }, set: { if !$0 { ownerAccount = nil } }), titleVisibility: .visible) {
                if let account = ownerAccount {
                    Button("Chuẩn bị bản ký bằng \(account)") {
                        ownerAccount = nil; Task { await engine.prepareOwnerInstallation(account: account) }
                    }
                }
                Button("Hủy", role: .cancel) { ownerAccount = nil }
            } message: {
                Text("App sẽ tạo bản cài thuộc Apple ID bạn chọn. Bản đang dùng được giữ nguyên trong bước chuẩn bị. Sau khi cài bản của mình, bạn dùng chính Apple ID đó để tự gia hạn.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { email = ""; password = ""; adding = true } label: {
                        Label("Thêm Apple ID", systemImage: "person.badge.plus")
                    }.disabled(engine.busy)
                }
            }
            .task { await engine.loadImportedCert() }
            .sheet(item: $picker) { k in
                DocumentPicker { u in
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(u.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    let sc = u.startAccessingSecurityScopedResource(); defer { if sc { u.stopAccessingSecurityScopedResource() } }
                    try? FileManager.default.copyItem(at: u, to: dest)
                    if k == .p12 { p12 = dest }
                    else if engine.importedCert != nil { Task { await engine.importCert(p12: nil, password: "", profiles: [dest]) } }
                    else { profiles.append(dest) }
                }
            }
        }
    }
}
