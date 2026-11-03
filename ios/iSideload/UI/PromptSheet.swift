import SwiftUI

struct PromptSheet: View {
    @EnvironmentObject var engine: Engine
    var prompt: CorePrompt
    @State private var text = ""
    @State private var selected = Set<String>()
    @State private var confirmCurrent = false

    private var certificateRows: [[String: Any]] { prompt.payload["certs"] as? [[String: Any]] ?? [] }
    private var selectedCurrent: Bool {
        certificateRows.contains { row in
            row["protected"] as? Bool == true && selected.contains(row["serial"] as? String ?? "")
        }
    }
    private func submitRevocation(allowCurrent: Bool) {
        let answer: [String: Any] = ["serials": selected.sorted(), "allow_current": allowCurrent]
        guard let data = try? JSONSerialization.data(withJSONObject: answer), let value = String(data: data, encoding: .utf8) else { return }
        engine.answerPrompt(value)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch prompt.kind {
                case "__none":
                    Section {
                        TextField("Code", text: $text).keyboardType(.numberPad).font(.largeTitle.monospacedDigit())
                    } footer: { Text(" ") }
                case "2fa":
                    Section {
                        TextField("Mã 6 số", text: $text).keyboardType(.numberPad).textContentType(.oneTimeCode)
                            .font(.largeTitle.monospacedDigit())
                    } footer: {
                        VStack(alignment: .leading) {
                            if let e = prompt.payload["last_error"] as? String, !e.isEmpty { Text(e).foregroundStyle(.red) }
                            Text(prompt.payload["sms"] as? Bool == true ? "Nhập mã Apple gửi qua SMS." : "Nhập mã hiện trên thiết bị Apple tin cậy khác của bạn.")
                        }
                    }
                    Section {
                        Button("Gửi mã qua SMS") { engine.answerPrompt("sms") }
                        Button("Gửi lại mã") { engine.answerPrompt("resend") }
                    }
                case "revoke":
                    Section {
                        if let account = prompt.payload["account"] as? String { LabeledContent("Apple ID", value: account) }
                        if let team = prompt.payload["team_id"] as? String { LabeledContent("Team", value: team) }
                        let certs = certificateRows
                        ForEach(certs.indices, id: \.self) { i in
                            let serial = certs[i]["serial"] as? String ?? ""
                            Button {
                                if selected.contains(serial) { selected.remove(serial) } else { selected.insert(serial) }
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(serial) ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: 4) {
                                        let titles = [certs[i]["machine"] as? String, certs[i]["name"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
                                        Text(titles.first ?? "Chứng chỉ phát triển").font(.headline)
                                        Text(serial).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        if let expires = certs[i]["expires"] as? Double {
                                            Text("Hết hạn: " + Date(timeIntervalSince1970: expires).formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        if certs[i]["protected"] as? Bool == true {
                                            Label("Liên quan bản app đang chạy", systemImage: "exclamationmark.shield")
                                                .font(.caption).foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                        }
                    } header: { Text("Apple đã đủ chứng chỉ phát triển") } footer: {
                        Text("Chọn chứng chỉ cũ không còn cần rồi bấm Thu hồi và ký tiếp. Tác vụ đang làm sẽ tiếp tục sau khi thu hồi. Các app hoặc thiết bị khác dùng chứng chỉ đó có thể cần ký lại. Chứng chỉ liên quan app hiện tại được đánh dấu và cần xác nhận riêng.")
                    }
                default:
                    Text("Yêu cầu không rõ")
                }
                Section {
                    Button(prompt.kind == "revoke" ? "Thu hồi và ký tiếp" : "Tiếp tục") {
                        if prompt.kind == "revoke" {
                            if selectedCurrent { confirmCurrent = true }
                            else { submitRevocation(allowCurrent: false) }
                        } else { engine.answerPrompt(text.trimmingCharacters(in: .whitespaces)) }
                    }
                    .buttonStyle(GradientButtonStyle())
                    .disabled(prompt.kind == "revoke" ? selected.isEmpty : text.isEmpty)
                    Button("Huỷ", role: .cancel) { engine.answerPrompt(nil) }
                }
            }
            .navigationTitle(prompt.kind == "2fa" ? "Mã xác minh 2 bước" : "Chứng chỉ")
            .alert("Thu hồi chứng chỉ liên quan app đang chạy?", isPresented: $confirmCurrent) {
                Button("Thu hồi và tiếp tục", role: .destructive) { submitRevocation(allowCurrent: true) }
                Button("Quay lại chọn chứng chỉ", role: .cancel) {}
            } message: {
                Text("Chứng chỉ đã chọn nằm trong profile của bản app hiện tại. Thu hồi có thể khiến app này hoặc app khác dùng cùng chứng chỉ không mở lại được cho đến khi ký/cài lại. Chỉ tiếp tục nếu bạn muốn thu hồi đúng chứng chỉ này.")
            }
        }
    }
}
