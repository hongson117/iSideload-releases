import SwiftUI

struct AccountView: View {
    @EnvironmentObject var engine: Engine
    @State private var email = ""
    @State private var password = ""
    var body: some View {
        NavigationStack {
            Form {
                if engine.signedIn {
                    Section("Đã đăng nhập") {
                        Text(engine.appleID)
                        if !engine.teamName.isEmpty { Text("Team: \(engine.teamName)").foregroundStyle(.secondary) }
                        Button("Đăng xuất", role: .destructive) { engine.signOut() }
                    }
                } else {
                    Section {
                        TextField("Apple ID (email)", text: $email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        SecureField("Mật khẩu", text: $password).textContentType(.password)
                        Button("Đăng nhập") { Task { await engine.signIn(email: email, password: password) } }
                            .buttonStyle(GradientButtonStyle()).disabled(email.isEmpty || password.isEmpty || engine.busy)
                    } footer: {
                        Text("Nên dùng một Apple ID phụ. Mật khẩu chỉ lưu trong Keychain của máy và chỉ gửi tới Apple. Sẽ có bước nhập mã 2FA.")
                    }
                }
                Section("Chứng chỉ phát triển") {
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
            .onAppear { if email.isEmpty { email = engine.appleID } }
        }
    }
}
