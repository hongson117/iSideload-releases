import SwiftUI
import UIKit

struct LiveContainerCertificateSheet: View {
    let file: LiveContainerCertificateFile
    @Environment(\.dismiss) private var dismiss
    @State private var showPassword = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Nguồn chứng chỉ: \(file.sourceLabel)").font(.headline)
                    Text("Có nhiều bản LiveContainer được quản lý nên iSideload không tự gửi qua liên kết để tránh chọn nhầm bản nhận. Hãy nhập file dưới đây vào đúng bản vừa ký bằng nguồn này.")
                }
                Section("1. Lưu file chứng chỉ") {
                    ShareLink(item: file.url) { Label("Lưu file .p12 vào Tệp", systemImage: "square.and.arrow.up") }
                    Text("Chọn Lưu vào Tệp. Sau đó mở đúng bản LiveContainer, vào phần nhập chứng chỉ trong Cài đặt và chọn file đã lưu.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("2. Mật khẩu để nhập file") {
                    HStack {
                        Text(showPassword ? file.password : "••••••••").font(.body.monospaced())
                        Spacer()
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                            .accessibilityLabel(showPassword ? "Ẩn mật khẩu" : "Hiện mật khẩu")
                    }
                    Button(copied ? "Đã sao chép mật khẩu" : "Sao chép mật khẩu") {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": file.password]],
                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                        copied = true
                    }
                }
            }
            .navigationTitle("Nhập đúng chứng chỉ")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
    }
}
