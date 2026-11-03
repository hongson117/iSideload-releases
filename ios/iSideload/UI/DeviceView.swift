import SwiftUI

struct DeviceView: View {
    @EnvironmentObject var engine: Engine
    @State private var picking = false
    @State private var managingPairing = false
    @State private var tick = 0

    private var statusColor: Color {
        if engine.pairingVerified { return .green }
        if engine.pairingCheckError != nil || !engine.hasPairing { return .orange }
        return Theme.accent
    }

    var body: some View {
        NavigationStack {
            Form {
                peerInstallSection
                connectionSection
                Section {
                    Button("Làm mới iContainer") { Task { await engine.refreshSelf() } }
                        .disabled(engine.busy || !engine.canSign)
                    if !engine.canSign {
                        Button("Đăng nhập Apple ID hoặc nhập chứng chỉ") { engine.selectedTab = 3 }
                    }
                } header: { Text("Gia hạn iContainer") } footer: {
                    Text("Sau khi kiểm tra kết nối thành công, bấm Làm mới để thử gia hạn. iContainer có thể tự đóng khi iOS cài đè; mở lại để xem hạn ký mới.")
                }
                pairingSection
                Section {
                    DisclosureGroup("Vì sao mở lại app thấy chưa kiểm tra?") {
                        Text("Trạng thái kiểm tra được đặt lại khi mở lại hoặc cập nhật iContainer. File ghép đôi vẫn được giữ nếu mục trên báo Đã có file. Chỉ cần bật LocalDevVPN và bấm Kiểm tra kết nối; chưa cần tạo hay nhập lại file.")
                    }
                    DisclosureGroup("Đã cài bằng Windows hoặc Mac?") {
                        Text("Bộ cài iSideload cũ chưa tự chép file vào iContainer. Với bản thử này, xuất Remote Pairing cho chính iPhone này rồi dùng nút Nhập file ghép nối bên trên.")
                    }
                    DisclosureGroup("Đã cài bằng Sideloadly hoặc chưa có file?") {
                        Text("Xuất Remote Pairing của chính iPhone này bằng công cụ ghép nối trên máy tính rồi nhập vào iContainer. iOS 27+ có thể thử Ghép nối ngay trên máy ở phần Thiết lập. Giữ Wi-Fi bật và iPhone mở khóa.")
                    }
                } header: { Text("Hướng dẫn nhanh") }
            }
            .navigationTitle("Thiết bị")
            .sheet(isPresented: $picking) { DocumentPicker { engine.importPairing(from: $0) } }
            .onAppear { if !engine.hasPairing { managingPairing = true } }
            .onChange(of: engine.pairingActive) { _, active in
                if active { managingPairing = true }
                else if engine.hasPairing { managingPairing = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in tick += 1 }
        }
    }

    private var peerInstallSection: some View {
        Section {
            NavigationLink { PeerInstallView() } label: {
                Label("Cài cho iPhone khác", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.headline)
            }.disabled(engine.busy || engine.peerBusy)
        } header: { Text("Hỗ trợ máy khác") } footer: {
            Text("Máy nhận cần iOS 27+ và cùng Wi-Fi. Chọn Apple ID ký của người nhận; không cần RC Pair trên máy nhận.")
        }
    }

    private var connectionSection: some View {
        Section {
            Label(engine.pairingVerified ? "Đã kiểm tra kết nối thành công" :
                    (engine.pairingCheckError != nil ? "Kết nối chưa thành công" :
                        (engine.hasPairing ? "Đã có file ghép đôi" : "Cần thiết lập file ghép đôi")),
                  systemImage: engine.pairingVerified ? "checkmark.seal.fill" :
                    (engine.pairingCheckError != nil || !engine.hasPairing ? "exclamationmark.triangle" : "doc.badge.checkmark"))
                .foregroundStyle(statusColor)
            if engine.pairingVerified {
                Text("Lần kiểm tra vừa rồi đã thành công. Bạn có thể chuyển sang Làm mới iContainer bên dưới. Nếu vừa đổi hoặc tắt VPN, hãy kiểm tra lại.")
                    .font(.footnote)
                if !engine.deviceLine.isEmpty { Text(engine.deviceLine).font(.footnote).foregroundStyle(.secondary) }
            } else if engine.pairingCheckError != nil {
                Text("Giữ Wi-Fi bật, mở LocalDevVPN và bật kết nối, rồi quay lại thử nút bên dưới. Chỉ thiết lập lại file khi lỗi cho biết bản ghi không hợp lệ hoặc iPhone từ chối ghép đôi.")
                    .font(.footnote)
                DisclosureGroup("Xem lỗi lần kiểm tra") {
                    Text(engine.pairingCheckError ?? "").font(.caption).textSelection(.enabled)
                }
            } else if engine.hasPairing {
                Text("File đã sẵn trong app. Lần mở này chưa kiểm tra kết nối. Bật LocalDevVPN rồi bấm Kiểm tra kết nối thiết bị; chưa cần ghép đôi lại.")
                    .font(.footnote)
            } else {
                Text("Mở phần Thiết lập file ghép đôi bên dưới để nhập Remote Pairing của chính iPhone này, hoặc tự ghép nối trên iOS 27+.")
                    .font(.footnote)
            }
            Label(engine.vpnInterfaceUp ? "Đã phát hiện VPN đang bật" : "Bước 1: bật LocalDevVPN",
                  systemImage: engine.vpnInterfaceUp ? "network" : "network.slash")
                .font(.footnote).foregroundStyle(.secondary).id(tick)
            Button(LoopbackVPN.helperInstalled ? "Mở LocalDevVPN" : "Cài LocalDevVPN (App Store)") { LoopbackVPN.turnOn() }
                .disabled(engine.busy)
            Button {
                tick += 1
                Task { await engine.checkDevice() }
            } label: {
                Label("Kiểm tra kết nối thiết bị", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine.busy || !engine.hasPairing)
        } header: { Text("Kết nối máy này") } footer: {
            Text("VPN bật là bước chuẩn bị; nút Kiểm tra mới xác nhận iContainer kết nối được tới iPhone. Phần này dùng khi cài/gia hạn bằng Apple ID.")
        }
    }

    private var pairingSection: some View {
        Section {
            DisclosureGroup("Thiết lập hoặc thay file ghép đôi", isExpanded: $managingPairing) {
                if let kind = engine.pairingKind {
                    Text("Loại bản ghi: \(kind.rawValue)").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Chỉ dùng khi chưa có file hoặc kiểm tra báo bản ghi không còn hợp lệ. Dòng chưa kiểm tra sau khi mở app không có nghĩa đã mất ghép đôi.")
                    .font(.footnote)
                Button(engine.pairingActive ? "Đang chờ iPhone…" : "Ghép nối ngay trên máy (iOS 27+)") {
                    Task { await engine.pairOnDevice() }
                }.disabled(engine.busy || engine.pairingActive)
                if engine.pairingActive {
                    if engine.pairingPIN.isEmpty {
                        Text("Mở Cài đặt › Quyền riêng tư & Bảo mật › Chế độ nhà phát triển › Thiết bị khác, chọn iContainer. Giữ Wi-Fi bật.")
                            .font(.footnote)
                    } else {
                        Text("Nhập mã này trên iPhone:").font(.footnote)
                        Text(engine.pairingPIN).font(.system(size: 40, weight: .bold, design: .monospaced))
                    }
                }
                Button("Nhập file ghép nối (.plist / .rppair.plist)") { picking = true }.disabled(engine.busy)
                Text("Với iOS 26, ưu tiên bản ghi Remote Pairing tạo qua USB bằng bộ cài desktop. Bản ghi Lockdown cũ có thể không dùng được qua VPN trên iOS 26.4+.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Thiết lập file ghép đôi") }
    }
}
