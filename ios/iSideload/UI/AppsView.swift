import SwiftUI

struct AppsView: View {
    @EnvironmentObject var engine: Engine
    @State private var picking = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { picking = true } label: { Label("Chọn file IPA để cài", systemImage: "plus.app") }
                        .buttonStyle(GradientButtonStyle()).listRowBackground(Color.clear)
                } footer: {
                    Text("Apple ID miễn phí: tối đa 3 app sideload cùng lúc (tính cả iSideload), 10 App ID mỗi 7 ngày, app hết hạn sau 7 ngày — bấm Làm mới trước khi hết hạn.")
                }
                Section {
                    let lc = engine.liveContainerInstalled
                    Button(lc == nil ? "Cài LiveContainer" :
                           (!engine.lcLatest.isEmpty && engine.lcLatest != lc!.version ? "Cập nhật LiveContainer \(engine.lcLatest)" : "Cài lại LiveContainer (bản mới nhất)")) {
                        Task { await engine.installLiveContainer() }
                    }.disabled(engine.busy)
                    if let lc { Text("Đang cài \(lc.version)" + (engine.lcLatest.isEmpty ? "" : " · mới nhất \(engine.lcLatest)")).font(.footnote) }
                } header: { Text("LiveContainer") } footer: {
                    Text("Tải bản chính thức từ GitHub LiveContainer, ký bằng Apple ID của bạn. Cập nhật giữ nguyên dữ liệu. Được ký lại cùng các app khác.")
                }
                .task { await engine.checkLiveContainer() }
                Section("Đã sideload") {
                    if engine.apps.isEmpty { Text("Chưa có app nào.").foregroundStyle(.secondary) }
                    ForEach(engine.apps) { app in
                        HStack {
                            RoundedRectangle(cornerRadius: 10).fill(Theme.color(for: app.bundleID)).frame(width: 44, height: 44)
                                .overlay(Text(String(app.name.prefix(1))).font(.title2.bold()).foregroundStyle(.white))
                            VStack(alignment: .leading) {
                                Text(app.name).font(.headline)
                                Text(app.bundleID).font(.caption2).foregroundStyle(.secondary)
                                if let d = app.daysLeft {
                                    Text(d >= 0 ? "Còn \(d) ngày" : "Đã hết hạn").font(.caption).foregroundStyle(d <= 1 ? .red : .green)
                                } else { Text("Không rõ hạn").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Làm mới") { Task { await engine.refresh(app) } }.buttonStyle(.bordered).disabled(engine.busy)
                        }
                    }
                }
            }
            .navigationTitle("iSideload")
            .refreshable { await engine.refreshList() }
            .sheet(isPresented: $picking) { DocumentPicker { engine.importIPA(from: $0) } }
        }
    }
}
