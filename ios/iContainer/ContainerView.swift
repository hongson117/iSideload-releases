import SwiftUI

struct ContainerView: View {
    @EnvironmentObject private var engine: Engine
    @StateObject private var store = ContainerStore.shared
    @State private var picking = false
    @State private var preparing: ContainerGuest?
    @State private var launching: ContainerGuest?
    @State private var deleting: ContainerGuest?

    var body: some View {
            List {
                Section {
                    Label("iContainer · bản thử 0.1", systemImage: "shippingbox.fill").font(.headline)
                    Text("Một app chứa chức năng ký của iSideload và chạy app bên trong. Chưa kiểm chứng trên iPhone thật.").font(.footnote).foregroundStyle(.secondary)
                    Button { picking = true } label: { Label("Nhập IPA vào Container", systemImage: "plus.app") }
                } footer: {
                    Text("Nhập vào Container không cài thêm icon và không dùng thêm slot. Quay về tab Ứng dụng để cài độc lập ra màn hình chính.")
                }
                if let own = engine.selfApp {
                    Section("Gia hạn iContainer") {
                        if let date = own.expires { Text("Hết hạn: " + date.formatted(date: .abbreviated, time: .shortened)) }
                        Picker("Nguồn ký", selection: Binding(get: {
                            let current = engine.signerOf(own)
                            return engine.signers.contains(current) ? current : ""
                        }, set: { if !$0.isEmpty { engine.syncSelfRecord(signer: $0) } })) {
                            Text("Chọn nguồn ký").tag("")
                            ForEach(engine.signers, id: \.self) { s in Text(engine.signerLabel(s)).tag(s) }
                        }
                        Button("Làm mới toàn bộ iContainer") { Task { await engine.refreshSelf() } }
                            .disabled(!engine.canSign)
                    }
                }
                Section("App bên trong · \(store.guests.count)") {
                    if store.guests.isEmpty { Text("Chưa có app. Nhập IPA iOS không mã hóa để bắt đầu.").foregroundStyle(.secondary) }
                    ForEach(store.guests) { guest in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(guest.name.isEmpty ? guest.bundleID : guest.name, systemImage: "app.dashed").font(.headline)
                            Text("\(guest.bundleID) · \(guest.version)").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(guest.prepared ? "Chuẩn bị lại" : "Chuẩn bị") { preparing = guest }
                                Spacer()
                                Button("Chạy") { launching = guest }.disabled(!guest.prepared)
                            }.buttonStyle(.bordered)
                        }.padding(.vertical, 4)
                        .swipeActions { Button("Xóa", role: .destructive) { deleting = guest } }
                    }
                }
                Section("Cách dùng") {
                    Text("1. Cài iContainer và thêm Apple ID hoặc chứng chỉ ở tab Tài khoản.\n2. Nhập IPA vào Container.\n3. Chọn Chuẩn bị, chọn đúng nguồn đã ký iContainer. Nếu chứng chỉ không khớp, làm mới iContainer bằng nguồn đó rồi mở lại.\n4. Chọn Chạy, đóng và mở lại iContainer trong 10 phút.\n5. Muốn về danh sách: dùng nút ↩ iContainer rồi mở lại app.").font(.footnote)
                    Text("App chạy chung tiến trình và quyền truy cập của iContainer. Chỉ mở IPA bạn tin cậy; bản thử chưa bảo đảm cách ly tài khoản, Keychain hoặc toàn bộ đường dẫn dữ liệu.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Container")
            .disabled(store.working || engine.busy || engine.peerBusy)
            .refreshable { store.reload(); engine.syncSelfRecord() }
            .sheet(isPresented: $picking) { DocumentPicker { url in Task { await store.importIPA(url, engine: engine) } } }
            .confirmationDialog("Chọn nguồn ký cho app bên trong", isPresented: Binding(get: { preparing != nil }, set: { if !$0 { preparing = nil } }), titleVisibility: .visible) {
                ForEach(engine.signers, id: \.self) { signer in
                    Button(engine.signerLabel(signer)) {
                        if let guest = preparing { preparing = nil; Task { await store.prepare(guest, signer: signer, engine: engine) } }
                    }
                }
                Button("Thêm Apple ID hoặc chứng chỉ") { preparing = nil; engine.selectedTab = 3 }
                Button("Hủy", role: .cancel) { preparing = nil }
            } message: { Text("Nguồn ký phải khớp chính xác chứng chỉ đã cài iContainer. Ứng dụng sẽ kiểm tra trước khi ký.") }
            .alert("Chạy app bên trong?", isPresented: Binding(get: { launching != nil }, set: { if !$0 { launching = nil } })) {
                Button("Tiếp tục") { if let guest = launching { launching = nil; store.launch(guest) } }
                Button("Hủy", role: .cancel) { launching = nil }
            } message: { Text("App này dùng chung môi trường của iContainer, bao gồm quyền có thể tiếp cận dữ liệu và thông tin tài khoản. Chỉ tiếp tục với IPA bạn tin cậy.") }
            .alert("Đã sẵn sàng mở app", isPresented: $store.readyToReopen) {
                Button("Đóng iContainer để mở lại") { exit(0) }
            } message: { Text("Bấm Đóng rồi mở lại iContainer từ màn hình chính trong 10 phút. Lần mở tiếp theo sẽ chạy app đã chọn. Nếu app lỗi, mở iContainer thêm lần nữa để về danh sách.") }
            .alert("Xóa app và dữ liệu?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Xóa", role: .destructive) { if let guest = deleting { deleting = nil; Task { await store.remove(guest, engine: engine) } } }
                Button("Hủy", role: .cancel) { deleting = nil }
            } message: { Text("Xóa bản app này cùng dữ liệu riêng của nó trong iContainer.") }
            .alert("Container", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                Button("OK") { store.message = nil }
            } message: { Text(store.message ?? "") }
            .alert("Không hoàn tất", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
                Button("Sao chép lỗi") { UIPasteboard.general.string = store.failure; store.failure = nil }
                Button("OK") { store.failure = nil }
            } message: { Text(store.failure ?? "") }
    }
}
