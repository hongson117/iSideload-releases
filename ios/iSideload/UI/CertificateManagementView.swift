import SwiftUI

struct CertificateManagementView: View {
    @EnvironmentObject var engine: Engine
    @State private var account = ""
    @State private var choice: Choice?
    @State private var confirm = false
    @State private var confirmCurrent = false

    private struct Choice {
        let serial: String
        let account: String
        let team: String
        let current: Bool
    }
    private func revoke(allowCurrent: Bool) {
        guard let selected = choice else { return }
        choice = nil
        Task { await engine.revoke(selected.serial, account: selected.account, team: selected.team, allowCurrent: allowCurrent) }
    }

    var body: some View {
        Form {
            Section {
                if engine.signedAccounts.isEmpty {
                    Text("Vào tab Tài khoản và đăng nhập Apple ID cần quản lý chứng chỉ.")
                } else {
                    Picker("Apple ID", selection: $account) {
                        ForEach(engine.signedAccounts, id: \.self) { Text($0).tag($0) }
                    }.disabled(engine.busy || engine.peerBusy)
                    if engine.certificateTeams.count > 1 {
                        Picker("Team", selection: Binding(get: { engine.certificateTeam }, set: { team in
                            Task { await engine.loadCerts(account: account, team: team) }
                        })) {
                            ForEach(engine.certificateTeams.indices, id: \.self) { index in
                                let team = engine.certificateTeams[index]
                                Text(team["name"] as? String ?? "Team").tag(team["id"] as? String ?? "")
                            }
                        }.disabled(engine.busy || engine.peerBusy)
                    } else if !engine.certificateTeam.isEmpty {
                        LabeledContent("Team", value: engine.certificateTeam)
                    }
                    Button("Tải lại danh sách chứng chỉ") {
                        Task { await engine.loadCerts(account: account, team: engine.certificateTeam) }
                    }.disabled(engine.busy || engine.peerBusy || account.isEmpty)
                }
            } header: { Text("Tài khoản quản lý") } footer: {
                Text("Chọn đúng Apple ID và Team đã dùng ký. Thu hồi chỉ tác động chứng chỉ được chọn; các app dùng chứng chỉ đó có thể cần ký lại.")
            }
            Section {
                if !engine.busy && engine.certs.isEmpty && !engine.certificateTeam.isEmpty {
                    Text("Không có chứng chỉ phát triển trong Team này.").foregroundStyle(.secondary)
                }
                ForEach(engine.certs.indices, id: \.self) { index in
                    let cert = engine.certs[index]
                    VStack(alignment: .leading, spacing: 6) {
                        Text((cert["machine"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                             ?? cert["name"] as? String ?? "Chứng chỉ phát triển").font(.headline)
                        Text(cert["serial"] as? String ?? "").font(.caption.monospaced()).textSelection(.enabled)
                        if let expires = cert["expires"] as? Double {
                            Text("Hết hạn: " + Date(timeIntervalSince1970: expires).formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        }
                        if cert["protected"] as? Bool == true {
                            Label("Đang ký bản iContainer này", systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                        }
                        Button("Thu hồi chứng chỉ này", role: .destructive) {
                            choice = Choice(serial: cert["serial"] as? String ?? "", account: engine.certificateAccount,
                                            team: engine.certificateTeam, current: cert["protected"] as? Bool == true)
                            confirm = true
                        }.disabled(engine.busy || engine.peerBusy || engine.certificateAccount != account || engine.certificateTeam.isEmpty)
                    }
                }
            } header: { Text("Chứng chỉ phát triển") } footer: {
                Text("Khi đang ký mà hết chỗ chứng chỉ, iContainer sẽ cho chọn Thu hồi và ký tiếp. Tác vụ nền sẽ dừng để bạn mở app xử lý; không tự thu hồi chứng chỉ còn hạn.")
            }
        }
        .navigationTitle("Quản lý chứng chỉ")
        .task {
            if account.isEmpty { account = engine.signedAccounts.contains(engine.appleID) ? engine.appleID : (engine.signedAccounts.first ?? "") }
            if !account.isEmpty { await engine.loadCerts(account: account) }
        }
        .onChange(of: account) { previous, next in
            if !previous.isEmpty, previous != next { Task { await engine.loadCerts(account: next) } }
        }
        .confirmationDialog("Thu hồi chứng chỉ đã chọn?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Thu hồi chứng chỉ", role: .destructive) {
                if choice?.current == true { confirmCurrent = true } else { revoke(allowCurrent: false) }
            }
            Button("Hủy", role: .cancel) { choice = nil }
        } message: {
            Text("Apple ID: \(choice?.account ?? "")\nTeam: \(choice?.team ?? "")\nSerial: \(choice?.serial ?? "")\nCác app dùng chứng chỉ này có thể cần ký lại.")
        }
        .alert("Chứng chỉ này đang ký iContainer", isPresented: $confirmCurrent) {
            Button("Thu hồi chứng chỉ đang dùng", role: .destructive) { revoke(allowCurrent: true) }
            Button("Giữ chứng chỉ", role: .cancel) { choice = nil }
        } message: {
            Text("Thu hồi có thể khiến iContainer và app dùng chung chứng chỉ không mở lại được cho đến khi ký/cài lại. Chỉ tiếp tục nếu bạn muốn thu hồi đúng chứng chỉ đang đánh dấu.")
        }
    }
}
