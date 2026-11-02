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
                    Button { Task { await engine.exportCertToLiveContainer() } } label: {
                        Label("Xuất chứng chỉ cho LiveContainer", systemImage: "key.horizontal")
                    }.disabled(engine.busy)
                    if let lc { Text("Đang cài \(lc.version)" + (engine.lcLatest.isEmpty ? "" : " · mới nhất \(engine.lcLatest)")).font(.footnote) }
                } header: { Text("LiveContainer") } footer: {
                    Text("Tải bản chính thức từ GitHub LiveContainer, ký bằng Apple ID của bạn. Cập nhật giữ nguyên dữ liệu. Được ký lại cùng các app khác. Sau khi cài, chứng chỉ ký được tự gửi sang LiveContainer (chế độ JIT-less); bấm Xuất chứng chỉ nếu cần gửi lại.")
                }
                .task { await engine.checkLiveContainer() }
                if engine.apps.isEmpty && engine.signerGroups.isEmpty { Section("Đã sideload") { Text("Chưa có app nào.").foregroundStyle(.secondary) } }
                ForEach(engine.signerGroups, id: \.self) { sg in
                    let list = engine.apps.filter { engine.signerOf($0) == sg }
                    Section {
                        if list.isEmpty { Text("Chưa có app nào ký bằng danh tính này.").font(.footnote).foregroundStyle(.secondary) }
                        ForEach(list) { app in row(app, sg) }
                        if !list.isEmpty {
                            Button { Task { await engine.refreshGroup(sg) } } label: { Label("Ký lại tất cả", systemImage: "arrow.clockwise") }.disabled(engine.busy)
                        }
                    } header: { header(sg, list) }
                }
            }
            .navigationTitle("iSideload")
            .refreshable { await engine.refreshList() }
            .sheet(isPresented: $picking) { DocumentPicker { engine.importIPA(from: $0) } }
        }
    }

    @ViewBuilder func header(_ sg: String, _ list: [SideloadedApp]) -> some View {
        let exp = list.compactMap(\.expires).min()
        VStack(alignment: .leading, spacing: 2) {
            if sg == "cert" {
                let c = engine.importedCert?["certificate"] as? [String: Any] ?? [:]
                let nm = c["name"] as? String ?? ""
                let short = nm.range(of: #"\(([A-Z0-9]+)\)"#, options: .regularExpression).map { String(nm[$0].dropFirst().dropLast()) } ?? nm
                let ex = engine.importedExpiry.map { $0.formatted(.dateTime.day().month(.defaultDigits).year()) } ?? "?"
                Label("Chứng chỉ: \(short) · hết \(ex)", systemImage: "doc.badge.gearshape").lineLimit(1)
                Text("Team \(engine.team(of: sg))").font(.caption2)
            } else {
                let e = String(sg.dropFirst(6))
                Label(e, systemImage: "person.crop.circle")
                Text("Team \(engine.team(of: sg).isEmpty ? "?" : engine.team(of: sg)) · \(engine.slotsUsed(sg))/3 app · còn \(max(0, 10 - engine.appIDsUsed(e)))/10 App ID (7 ngày)" + (exp.map { " · cert/profile hết hạn " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")).font(.caption2)
                if !engine.signers.contains(sg) { Text("Chưa đăng nhập — đăng nhập lại để làm mới").font(.caption2).foregroundStyle(.red) }
            }
        }
    }

    @ViewBuilder func row(_ app: SideloadedApp, _ sg: String) -> some View {
        HStack {
            AppIconView(bundleID: app.bundleID, name: app.name, size: 44)
                .task { await engine.ensureIcon(app) }
            VStack(alignment: .leading) {
                Text(app.name).font(.headline)
                Text(app.bundleID).font(.caption2).foregroundStyle(.secondary)
                Text("Ký bởi: \(engine.signerLabel(sg))").font(.caption2).foregroundStyle(.secondary)
                if let d = app.daysLeft {
                    Text(d >= 0 ? "Còn \(d) ngày" : "Đã hết hạn").font(.caption).foregroundStyle(d <= 1 ? .red : .green)
                } else { Text("Không rõ hạn").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let (sa, v) = SourceStore.shared.update(for: app) {
                Button("Cập nhật \(v.version)") { Task { await engine.installFromSource(sa, v) } }.buttonStyle(.borderedProminent).tint(.orange).disabled(engine.busy)
            }
            Menu {
                Button("Làm mới") { Task { await engine.refreshAndPush(app) } }
                ForEach(engine.signers.filter { $0 != sg }, id: \.self) { t in
                    Button("Chuyển sang \(engine.signerLabel(t))") { Task { await engine.move(app, to: t) } }
                }
            } label: { Text("Làm mới") }.buttonStyle(.bordered).disabled(engine.busy)
        }
    }
}
