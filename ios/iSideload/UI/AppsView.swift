import SwiftUI

struct AppsView: View {
    @EnvironmentObject var engine: Engine
    @State private var picking = false
    @State private var confirmDelete: SideloadedApp?
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
                        ForEach(list) { app in
                            row(app, sg).swipeActions(edge: .trailing) {
                                Button(role: .destructive) { confirmDelete = app } label: { Label("Gỡ", systemImage: "trash") }
                            }
                        }
                        if !list.isEmpty {
                            Button { Task { await engine.refreshGroup(sg) } } label: { Label("Ký lại tất cả", systemImage: "arrow.clockwise") }.disabled(engine.busy)
                        }
                    } header: { header(sg, list) }
                }
            }
            .navigationTitle("iSideload")
            .refreshable { await engine.refreshList() }
            .sheet(isPresented: $picking) { DocumentPicker { engine.importIPA(from: $0) } }
            .confirmationDialog("Gỡ \(confirmDelete?.name ?? "app")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                if let a = confirmDelete {
                    Button("Gỡ khỏi máy", role: .destructive) { Task { await engine.uninstall(a) } }
                    Button("Chỉ xoá khỏi danh sách") { engine.removeFromList(a); engine.infoText = "Đã xoá \(a.name) khỏi danh sách" }
                }
                Button("Huỷ", role: .cancel) {}
            } message: { Text("Dữ liệu của app sẽ bị xoá. iSideload ngừng ký lại app này và trả lại 1 slot.") }
            .alert("Profile chỉ cho 1 app", isPresented: Binding(get: { engine.explicitWarn != nil }, set: { if !$0 { engine.explicitWarn = nil } })) {
                Button("Vẫn cài (thay app cũ)", role: .destructive) { Task { await engine.confirmExplicit() } }
                Button("Huỷ", role: .cancel) { engine.explicitWarn = nil }
            } message: { Text("App ID cố định \(engine.importedSingleAppID ?? ""): \(engine.explicitReplaces) sẽ bị thay. Dùng profile wildcard (TEAM.*) để cài nhiều app.") }
            .alert("Không gỡ được trên máy", isPresented: Binding(get: { engine.uninstallFailed != nil }, set: { if !$0 { engine.uninstallFailed = nil } })) {
                if let a = engine.uninstallFailed {
                    Button("Xoá khỏi danh sách", role: .destructive) { engine.removeFromList(a); engine.uninstallFailed = nil }
                }
                Button("Để sau", role: .cancel) { engine.uninstallFailed = nil }
            } message: { Text("Hãy tự xoá icon \(engine.uninstallFailed?.name ?? "") trên màn hình chính, rồi xoá khỏi danh sách.") }
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
                Text("Team \(engine.team(of: sg)) · " + "\(list.count) app · không giới hạn").font(.caption2)
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
                Divider()
                Button(role: .destructive) { confirmDelete = app } label: { Label("Gỡ app", systemImage: "trash") }
            } label: { Text("Làm mới") }.buttonStyle(.bordered).disabled(engine.busy)
        }
    }
}
