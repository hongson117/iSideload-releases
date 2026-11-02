import SwiftUI

struct DeviceView: View {
    @EnvironmentObject var engine: Engine
    @State private var picking = false
    @State private var tick = 0
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        PeerInstallView()
                    } label: {
                        Label("Cài cho iPhone khác", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }
                    .disabled(engine.busy)
                } footer: {
                    Text("Cài iSideload cho máy mới chạy iOS 27+ ở cùng Wi-Fi. Máy nhận không cần RC Pair hay máy tính.")
                }
                Section {
                    Label(engine.hasPairing ? "Đã có file ghép nối" : "Chưa có file ghép nối",
                          systemImage: engine.hasPairing ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .foregroundStyle(engine.hasPairing ? .green : .orange)
                    Button(engine.pairingActive ? "Đang chờ iPhone…" : "Ghép nối ngay trên máy (iOS 27+)") {
                        Task { await engine.pairOnDevice() }
                    }.disabled(engine.pairingActive)
                    if engine.pairingActive {
                        if engine.pairingPIN.isEmpty {
                            Text("Mở Cài đặt › Quyền riêng tư & Bảo mật › Chế độ nhà phát triển › Thiết bị khác, chọn \"iSideload\". Giữ Wi-Fi bật.")
                                .font(.footnote)
                        } else {
                            Text("Nhập mã này trên iPhone:").font(.footnote)
                            Text(engine.pairingPIN).font(.system(size: 40, weight: .bold, design: .monospaced))
                        }
                    }
                    Button("Nhập file ghép nối (.plist / .rppair.plist)") { picking = true }
                } header: { Text("1. File ghép nối") } footer: {
                    Text("iOS 27+: bấm Ghép nối ngay trên máy rồi làm theo hướng dẫn trong Cài đặt. Máy vừa nhận iSideload từ máy khác vẫn cần bước này để tự gia hạn. Với iOS cũ, nhập bản ghi đã tạo từ máy tính.")
                }
                Section {
                    Label(engine.vpnInterfaceUp ? "VPN loopback đang bật" : "VPN loopback đang tắt",
                          systemImage: engine.vpnInterfaceUp ? "network" : "network.slash")
                        .foregroundStyle(engine.vpnInterfaceUp ? .green : .orange).id(tick)
                    Button(LoopbackVPN.helperInstalled ? "Bật VPN trong LocalDevVPN" : "Tải LocalDevVPN (App Store)") { LoopbackVPN.turnOn() }
                } header: { Text("2. VPN loopback") } footer: {
                    Text("VPN chuyển gói tin tới 10.7.0.1 quay ngược lại chính máy, để iSideload nói chuyện với lockdownd như một máy tính. Apple ID miễn phí không ký được Network Extension nên iSideload dùng app LocalDevVPN miễn phí trên App Store.")
                }
                Section("3. Kiểm tra") {
                    Button("Kiểm tra kết nối thiết bị") { tick += 1; Task { await engine.checkDevice() } }
                    if !engine.deviceLine.isEmpty { Text(engine.deviceLine) }
                }
                Section {
                    Button("Làm mới iSideload") { Task { await engine.refreshSelf() } }.disabled(engine.busy || !engine.canSign)
                } header: { Text("4. Gia hạn chính iSideload") } footer: {
                    Text("Cùng chức năng với nút Làm mới ở tab Ứng dụng. Khi dùng Apple ID cần đã tự ghép nối; iSideload sẽ mở LocalDevVPN nếu cần. Sau khi cài đè, mở lại app để kiểm tra ngày hết hạn.")
                }
            }
            .navigationTitle("Thiết bị")
            .sheet(isPresented: $picking) { DocumentPicker { engine.importPairing(from: $0) } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in tick += 1 }
        }
    }
}
