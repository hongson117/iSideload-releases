import SwiftUI

struct PromptSheet: View {
    @EnvironmentObject var engine: Engine
    var prompt: CorePrompt
    @State private var text = ""
    @State private var selected = Set<String>()

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
                        let certs = prompt.payload["certs"] as? [[String: Any]] ?? []
                        ForEach(certs.indices, id: \.self) { i in
                            let serial = certs[i]["serial"] as? String ?? ""
                            Button {
                                if selected.contains(serial) { selected.remove(serial) } else { selected.insert(serial) }
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(serial) ? "checkmark.circle.fill" : "circle")
                                    Text(certs[i]["machine"] as? String ?? serial)
                                }
                            }
                        }
                    } header: { Text("Quá nhiều chứng chỉ") } footer: {
                        Text("Apple ID miễn phí chỉ có vài chứng chỉ phát triển. Chọn chứng chỉ cần thu hồi; app đã ký bằng nó sẽ không mở được nữa.")
                    }
                default:
                    Text("Yêu cầu không rõ")
                }
                Section {
                    Button("Tiếp tục") {
                        engine.answerPrompt(prompt.kind == "revoke" ? selected.joined(separator: ",") : text.trimmingCharacters(in: .whitespaces))
                    }
                    .buttonStyle(GradientButtonStyle())
                    .disabled(prompt.kind == "revoke" ? selected.isEmpty : text.isEmpty)
                    Button("Huỷ", role: .cancel) { engine.answerPrompt(nil) }
                }
            }
            .navigationTitle(prompt.kind == "2fa" ? "Mã xác minh 2 bước" : "Chứng chỉ")
        }
    }
}
