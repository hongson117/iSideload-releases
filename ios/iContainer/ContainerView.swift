#if !SICONTAINER_RUNNER
import SwiftUI

struct ContainerView: View {
    @EnvironmentObject private var engine: Engine
    @StateObject private var store = ContainerStore.shared
    @State private var picking = false
    @State private var preparing: ContainerGuest?
    @State private var launchingLocal: ContainerGuest?
    @State private var shortcutTarget: ContainerGuest?
    @State private var deleting: ContainerGuest?

    var body: some View {
        List {
            Section {
                Label("SIContainer · Bước 1 (1 Chính + 1 Phụ)", systemImage: "shippingbox.and.arrow.backward.fill")
                    .font(.headline)
                Text("Con Chính chuyên quản lý, ký DER và điều phối URL; Con Phụ 1 chạy app khách độc lập qua App Group dùng chung.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { picking = true } label: {
                    Label("Nhập IPA vào SIContainer", systemImage: "plus.app")
                }
            }

            Section("Trạng thái App Group & Slot Phụ 1") {
                Label(
                    store.sharedGroupAvailable ? "App Group dùng chung: Đã bật" : "App Group dùng chung: Chưa có quyền (Chế độ Ghim Slot)",
                    systemImage: store.sharedGroupAvailable ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(store.sharedGroupAvailable ? .green : .orange)

                if !store.sharedGroupID.isEmpty {
                    Text("Group: \(store.sharedGroupID)").font(.caption).foregroundStyle(.secondary)
                }

                if let r1 = store.runner1BundleID {
                    Label("Đã kết nối Phụ 1: \(r1)", systemImage: "link.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Label("Chưa ghi nhận probe từ SIContainer Phụ 1", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if store.runner1AliveInRAM {
                    let activeName = store.runner1ActiveGuestName ?? "Đang chờ lệnh"
                    Label("Phụ 1 đang sống trong RAM · App: \(activeName)", systemImage: "memorychip.fill")
                        .font(.caption).foregroundStyle(.blue)
                } else {
                    Label("Phụ 1 đang nghỉ (Cold / Sẵn sàng nạp mới)", systemImage: "moon.zzz")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if engine.hasBundledRunner1IPA {
                    Button {
                        Task { await engine.installBundledRunner1() }
                    } label: {
                        Label(
                            engine.installedRunner1App == nil ? "Cài SIContainer Phụ 1 ngay trên máy" : "Làm mới SIContainer Phụ 1",
                            systemImage: "square.and.arrow.down.on.square.fill"
                        )
                    }
                    .disabled(!engine.canSign)
                }

                Button {
                    store.probeRunner1()
                } label: {
                    Label("Kiểm tra kết nối 2 chiều với SIContainer Phụ 1", systemImage: "arrow.triangle.2.circlepath.circle")
                }
            }

            if let own = engine.selfApp {
                Section("Gia hạn SIContainer") {
                    if let date = own.expires {
                        Text("Hết hạn: " + date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let identity = engine.selfSigningIdentity {
                        Text(identity.description).font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("Nguồn ký", selection: Binding(get: {
                        let current = engine.signerOf(own)
                        return engine.signers.contains(current) ? current : ""
                    }, set: { if !$0.isEmpty { engine.syncSelfRecord(signer: $0) } })) {
                        Text("Chọn nguồn ký").tag("")
                        ForEach(engine.signers, id: \.self) { s in Text(engine.signerLabel(s)).tag(s) }
                    }
                    if let problem = engine.selfSignerProblem(engine.signerOf(own)) {
                        Text(problem).font(.footnote).foregroundStyle(.orange)
                    }
                    Button("Làm mới toàn bộ SIContainer") { Task { await engine.refreshSelf() } }
                        .disabled(!engine.canSign)
                }
            }

            Section("App bên trong · \(store.guests.count)") {
                if store.guests.isEmpty {
                    Text("Chưa có app. Nhập IPA iOS không mã hóa để bắt đầu.").foregroundStyle(.secondary)
                }
                ForEach(store.guests) { guest in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(guest.name.isEmpty ? guest.bundleID : guest.name, systemImage: "app.dashed")
                            .font(.headline)
                        Text("\(guest.bundleID) · \(guest.version)")
                            .font(.caption).foregroundStyle(.secondary)
                        if !(guest.embeddedComponents ?? []).isEmpty {
                            Label("IPA có extension/Watch · chạy app chính trên iPhone", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let slots = guest.preparedSlots, !slots.isEmpty {
                            Text("Đã chuẩn bị cho \(slots.count) Slot")
                                .font(.caption2).foregroundStyle(.green)
                        }
                        if guest.prepared && !guest.readyToLaunch {
                            Text("Cần Chuẩn bị lại; giữ nguyên dữ liệu app.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack(spacing: 8) {
                            Button(guest.prepared ? "Chuẩn bị lại" : "Chuẩn bị") { preparing = guest }
                            if guest.readyToLaunch {
                                Button {
                                    shortcutTarget = guest
                                } label: {
                                    Image(systemName: "plus.square.on.square")
                                }
                            }
                            Spacer()
                            if store.sharedGroupAvailable {
                                Button("Chạy (Phụ 1)") {
                                    store.launchInRunner1(guest)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!guest.readyToLaunch)
                            } else {
                                Button("Chạy cục bộ") {
                                    launchingLocal = guest
                                }
                                .disabled(!guest.readyToLaunch)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        if guest.readyToLaunch {
                            Button {
                                store.launchInRunner1(guest)
                            } label: {
                                Label("Chạy trên SIContainer Phụ 1", systemImage: "play.fill")
                            }
                            Button {
                                launchingLocal = guest
                            } label: {
                                Label("Chạy cục bộ trên Con Chính", systemImage: "iphone")
                            }
                            Button {
                                shortcutTarget = guest
                            } label: {
                                Label("Tạo Shortcut Màn hình chính", systemImage: "plus.square.on.square")
                            }
                        }
                        Button(role: .destructive) {
                            deleting = guest
                        } label: {
                            Label("Xóa app và dữ liệu", systemImage: "trash")
                        }
                    }
                    .swipeActions {
                        Button("Xóa", role: .destructive) { deleting = guest }
                    }
                }
            }

            Section("Hướng dẫn Bước 1 (1 Chính + 1 Phụ)") {
                Text("1. Cài cả SIContainer Chính và SIContainer Phụ 1 bằng cùng một Apple ID / chứng chỉ.\n2. Bấm 'Kiểm tra kết nối 2 chiều với SIContainer Phụ 1' để xác minh App Group dùng chung.\n3. Nhập IPA → Chọn Chuẩn bị → Chọn nguồn ký.\n4. Bấm 'Chạy (Phụ 1)' để chuyển thẳng sang Phụ 1 và mở app ngay (không cần đóng mở lại).\n5. Bấm biểu tượng Shortcut để đưa icon app ra thẳng Màn hình chính iOS.")
                    .font(.footnote)
            }
        }
        .navigationTitle("SIContainer")
        .disabled(store.working || engine.busy || engine.peerBusy)
        .refreshable { store.reload(); engine.syncSelfRecord() }
        .onAppear { store.reload() }
        .sheet(isPresented: $picking) {
            DocumentPicker { url in Task { await store.importIPA(url, engine: engine) } }
        }
        .confirmationDialog("Chọn nguồn ký cho app bên trong", isPresented: Binding(get: { preparing != nil }, set: { if !$0 { preparing = nil } }), titleVisibility: .visible) {
            ForEach(engine.signers, id: \.self) { signer in
                Button(engine.signerLabel(signer)) {
                    if let guest = preparing {
                        preparing = nil
                        Task { await store.prepare(guest, signer: signer, engine: engine) }
                    }
                }
            }
            Button("Thêm Apple ID hoặc chứng chỉ") { preparing = nil; engine.selectedTab = 3 }
            Button("Hủy", role: .cancel) { preparing = nil }
        } message: {
            Text("Nguồn ký phải khớp chứng chỉ đã cài SIContainer và SIContainer Phụ 1.")
        }
        .confirmationDialog("Tạo Shortcut ra Màn hình chính iOS", isPresented: Binding(get: { shortcutTarget != nil }, set: { if !$0 { shortcutTarget = nil } }), titleVisibility: .visible) {
            if let guest = shortcutTarget {
                Button("Cài hồ sơ WebClip (.mobileconfig - Icon chuẩn)") {
                    shortcutTarget = nil
                    store.openShortcutInstaller(for: guest, mode: "webclip")
                }
                Button("Mở trang Safari (Chia sẻ → Thêm vào MH chính)") {
                    shortcutTarget = nil
                    store.openShortcutInstaller(for: guest, mode: "safari")
                }
                Button("Sao chép URL Phím tắt (sicontainer://launch)") {
                    UIPasteboard.general.string = "sicontainer://launch?guest=\(guest.id)"
                    shortcutTarget = nil
                    store.message = "Đã sao chép URL: sicontainer://launch?guest=\(guest.id)"
                }
            }
            Button("Hủy", role: .cancel) { shortcutTarget = nil }
        } message: {
            Text("Chọn Hồ sơ WebClip để có icon chuẩn không viền, hoặc dùng trang Safari / Phím tắt iOS.")
        }
        .alert("Chạy cục bộ trên Con Chính?", isPresented: Binding(get: { launchingLocal != nil }, set: { if !$0 { launchingLocal = nil } })) {
            Button("Tiếp tục") {
                if let guest = launchingLocal {
                    launchingLocal = nil
                    store.launchLocalFallback(guest)
                }
            }
            Button("Hủy", role: .cancel) { launchingLocal = nil }
        } message: {
            Text("Chế độ dự phòng khi không dùng Slot Phụ: đóng SIContainer rồi mở lại từ màn hình chính trong 10 phút.")
        }
        .alert("Đã sẵn sàng mở app", isPresented: $store.readyToReopen) {
            Button("Đóng SIContainer để mở lại") { exit(0) }
        } message: {
            Text("Bấm Đóng rồi mở lại từ màn hình chính trong 10 phút.")
        }
        .alert("Xóa app và dữ liệu?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Xóa", role: .destructive) {
                if let guest = deleting {
                    deleting = nil
                    Task { await store.remove(guest, engine: engine) }
                }
            }
            Button("Hủy", role: .cancel) { deleting = nil }
        } message: {
            Text("Xóa bản app này cùng dữ liệu riêng của nó trong SIContainer.")
        }
        .alert("SIContainer", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
        .alert("Không hoàn tất", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
            Button("Sao chép lỗi") { UIPasteboard.general.string = store.failure; store.failure = nil }
            Button("OK") { store.failure = nil }
        } message: { Text(store.failure ?? "") }
    }
}
#endif
