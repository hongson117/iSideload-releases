import SwiftUI

struct AppsView: View {
    @EnvironmentObject var engine: Engine
    @State private var picking = false
    @State private var confirmDelete: SideloadedApp?
    @State private var choosingLCSigner = false
    @State private var confirmingLCCertificate = false

    private var lcSourceDescription: String {
        guard let signer = engine.lcSigner else { return "Chưa xác định nguồn ký của bản LiveContainer đang cài." }
        return "Nguồn ký hiện tại: " + (signer == "cert" ? engine.signerLabel(signer) : "Apple ID · " + engine.signerLabel(signer))
    }
    var body: some View {
        NavigationStack {
            List {
                SetupChecklistView()
                if let app = engine.selfApp {
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "iphone.and.arrow.forward").font(.title).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("iContainer · máy này").font(.headline)
                                Text("Phiên bản \(app.version)").font(.caption).foregroundStyle(.secondary)
                                if let expiry = app.expires {
                                    Text("Hết hạn: " + expiry.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(expiry <= Date().addingTimeInterval(86400) ? .red : .secondary)
                                } else {
                                    Text("Chưa đọc được hạn ký từ iOS").font(.caption).foregroundStyle(.secondary)
                                }
                                if let identity = engine.selfSigningIdentity {
                                    Text(identity.description).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !engine.signers.isEmpty {
                            Picker("Tài khoản gia hạn", selection: Binding(
                                get: { let current = engine.signerOf(app); return engine.signers.contains(current) ? current : "" },
                                set: { value in if !value.isEmpty { engine.syncSelfRecord(signer: value) } }
                            )) {
                                Text("Chọn tài khoản ký").tag("")
                                ForEach(engine.signers, id: \.self) { Text(engine.signerLabel($0)).tag($0) }
                            }.disabled(engine.busy)
                        }
                        if let problem = engine.selfSignerProblem(engine.signerOf(app)) {
                            Text(problem).font(.footnote).foregroundStyle(.orange)
                        }
                        if let release = engine.appUpdate {
                            Button { Task { await engine.updateApplication() } } label: {
                                Label("Cập nhật phiên bản \(release.label)", systemImage: "arrow.down.app")
                            }.disabled(engine.busy || engine.peerBusy || engine.updatingApp)
                        }
                        Button {
                            Task { await engine.refreshSelf() }
                        } label: { Label("Làm mới iContainer", systemImage: "arrow.clockwise") }
                        .disabled(engine.busy || !engine.canSign)
                        Button("Ký lại tất cả app (iContainer sau cùng)") {
                            Task { await engine.refreshAll(includeSelf: true, onlyDue: false, background: false) }
                        }.disabled(engine.busy || !engine.canSign)
                    } header: { Text("Gia hạn iContainer") } footer: {
                        Text("Không cần giữ IPA gốc. iContainer đóng gói chính bản đang chạy để làm mới; app có thể tự đóng khi iOS cài đè. Mở lại và kiểm tra hạn ký mới.")
                    }
                }
                Section {
                    Button { picking = true } label: { Label("Chọn file IPA để cài", systemImage: "plus.app") }
                        .buttonStyle(GradientButtonStyle()).listRowBackground(Color.clear)
                    NavigationLink { PeerInstallView() } label: {
                        Label("Cài cho iPhone khác", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }.disabled(engine.busy || engine.peerBusy)
                } footer: {
                    Text("Apple ID miễn phí: tối đa 3 app sideload cùng lúc (tính cả iContainer), 10 App ID mỗi 7 ngày, app hết hạn sau 7 ngày — bấm Làm mới trước khi hết hạn.")
                }
                #if ICONTAINER
                Section {
                    NavigationLink {
                        ContainerView()
                    } label: {
                        Label("Mở Container · chạy app bên trong", systemImage: "shippingbox")
                    }
                } header: { Text("Container tích hợp") } footer: {
                    Text("Nhập IPA vào iContainer để chạy bên trong, không cần cài LiveContainer riêng. Nút Chọn file IPA để cài ở trên vẫn cài app độc lập ra màn hình chính như trước.")
                }
                #else
                Section {
                    let lc = engine.liveContainerInstalled
                    Button(lc == nil ? "Cài LiveContainer" :
                           (!engine.lcLatest.isEmpty && engine.lcLatest != lc!.version ? "Cập nhật LiveContainer \(engine.lcLatest)" : "Cài lại LiveContainer (bản mới nhất)")) {
                        choosingLCSigner = true
                    }.disabled(engine.busy)
                    Button { confirmingLCCertificate = true } label: {
                        Label("Gửi lại chứng chỉ đang dùng", systemImage: "key.horizontal")
                    }.disabled(engine.busy)
                    if let lc { Text("Đang cài \(lc.version)" + (engine.lcLatest.isEmpty ? "" : " · mới nhất \(engine.lcLatest)")).font(.footnote) }
                    if lc != nil { Text(lcSourceDescription).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("LiveContainer") } footer: {
                    Text("Mỗi lần cài/cài lại đều hỏi nguồn ký: chọn Apple ID hoặc chứng chỉ .p12 đã nhập. LiveContainer nhận đúng chứng chỉ của nguồn bạn chọn. Đổi nguồn có thể tạo bản app khác; dữ liệu bản cũ không tự chuyển sang bản mới.")
                }
                .task { await engine.checkLiveContainer() }
                #endif
                if engine.apps.isEmpty && engine.signerGroups.isEmpty { Section("Đã sideload") { Text("Chưa có app nào.").foregroundStyle(.secondary) } }
                ForEach(engine.signerGroups, id: \.self) { sg in
                    let list = engine.apps.filter { !engine.isSelf($0) && engine.signerOf($0) == sg }
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
            .navigationTitle("iContainer")
            .onAppear { engine.syncSelfRecord() }
            .refreshable { await engine.refreshList() }
            .sheet(isPresented: $picking) { DocumentPicker { engine.importIPA(from: $0) } }
            .confirmationDialog("Chọn nguồn ký LiveContainer", isPresented: $choosingLCSigner, titleVisibility: .visible) {
                ForEach(engine.signers, id: \.self) { signer in
                    Button(signer == "cert" ? "Dùng chứng chỉ đã nhập (.p12)" : "Dùng Apple ID · \(engine.signerLabel(signer))") {
                        Task { await engine.installLiveContainer(signer: signer) }
                    }
                }
                Button("Đăng nhập Apple ID hoặc nhập chứng chỉ khác") { engine.selectedTab = 3 }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text(lcSourceDescription + "\nLựa chọn này dùng để ký app và chuyển chứng chỉ tương ứng. Đổi nguồn ký có thể tạo thêm bản LiveContainer; sao lưu dữ liệu bản cũ trước khi chuyển.")
            }
            .confirmationDialog("Gửi lại chứng chỉ cho LiveContainer?", isPresented: $confirmingLCCertificate, titleVisibility: .visible) {
                if engine.lcSigner != nil {
                    Button("Gửi chứng chỉ của nguồn đang dùng") { Task { await engine.exportCertToLiveContainer() } }
                }
                Button("Cài lại và chọn nguồn ký khác") { choosingLCSigner = true }
                Button("Hủy", role: .cancel) {}
            } message: { Text(lcSourceDescription + "\nMuốn đổi nguồn chứng chỉ, chọn cài lại để ký LiveContainer bằng nguồn mới.") }
            .confirmationDialog("Gỡ \(confirmDelete?.name ?? "app")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                if let a = confirmDelete {
                    Button("Gỡ khỏi máy", role: .destructive) { Task { await engine.uninstall(a) } }
                    Button("Chỉ xoá khỏi danh sách") { engine.removeFromList(a); engine.infoText = "Đã xoá \(a.name) khỏi danh sách" }
                }
                Button("Huỷ", role: .cancel) {}
            } message: { Text("Dữ liệu của app sẽ bị xoá. iContainer ngừng ký lại app này và trả lại 1 slot.") }
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
                let ex = (engine.importedExpiry ?? exp).map { $0.formatted(.dateTime.day().month(.defaultDigits).year()) } ?? "…"
                Label(short.isEmpty ? "Chứng chỉ có sẵn · hết \(ex)" : "Chứng chỉ: \(short) · hết \(ex)", systemImage: "doc.badge.gearshape").lineLimit(1)
                Text((engine.team(of: sg).isEmpty ? "" : "Team \(engine.team(of: sg)) · ") + "\(list.count) app · không giới hạn").font(.caption2)
                    .task { if engine.importedCert == nil { await engine.loadImportedCert() } }
            } else {
                let e = String(sg.dropFirst(6))
                Label(e, systemImage: "person.crop.circle")
                Text("Team \(engine.team(of: sg).isEmpty ? "?" : engine.team(of: sg)) · \(engine.slotsUsed(sg)) app đã ghi nhận · còn \(max(0, 10 - engine.appIDsUsed(e)))/10 App ID (7 ngày)" + (exp.map { " · cert/profile hết hạn " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")).font(.caption2)
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
