import SwiftUI

struct DeviceView: View {
    @EnvironmentObject var engine: Engine
    @State private var picking = false
    @State private var tick = 0
    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Tạo một lần trên máy tính (hoặc VPS qua Tailscale): cắm iPhone, tin cậy máy tính, rồi dùng idevice_pair / iloader / Jitterbug pair để xuất file. Gửi file qua AirDrop/Files rồi nhập ở đây.")
                }
                Section {
                    Label(engine.vpnActive ? "VPN loopback đang bật" : "VPN loopback đang tắt",
                          systemImage: engine.vpnActive ? "network" : "network.slash")
                        .foregroundStyle(engine.vpnActive ? .green : .orange).id(tick)
                    Button(LoopbackVPN.helperInstalled ? "Bật VPN trong LocalDevVPN" : "Tải LocalDevVPN (App Store)") { LoopbackVPN.turnOn() }
                } header: { Text("2. VPN loopback") } footer: {
                    Text("VPN chuyển gói tin tới 10.7.0.1 quay ngược lại chính máy, để iSideload nói chuyện với lockdownd như một máy tính. Apple ID miễn phí không ký được Network Extension nên iSideload dùng app LocalDevVPN miễn phí trên App Store.")
                }
                Section("3. Kiểm tra") {
                    Button("Kiểm tra kết nối thiết bị") { tick += 1; Task { await engine.checkDevice() } }
                    if !engine.deviceLine.isEmpty { Text(engine.deviceLine) }
                }
                Section {
                    Button("Tự ký lại iSideload (gia hạn 7 ngày)") { Task { await engine.refreshSelf() } }
                } header: { Text("4. Gia hạn chính iSideload") } footer: {
                    Text("Cần: đã đăng nhập Apple ID, có file ghép nối và VPN loopback đang bật. App sẽ tự thoát khi cài đè xong — mở lại là dùng tiếp 7 ngày mới.")
                }
            }
            .navigationTitle("Thiết bị")
            .sheet(isPresented: $picking) { DocumentPicker { engine.importPairing(from: $0) } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in tick += 1 }
        }
    }
}
