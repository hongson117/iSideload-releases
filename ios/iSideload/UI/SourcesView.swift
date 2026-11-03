import SwiftUI
import UIKit

struct SourcesView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var store = SourceStore.shared
    @State private var selected: String? = nil          // nil = Tất cả
    @State private var query = ""
    @State private var limit = 40
    @State private var showAdd = false
    @State private var showManage = false

    struct Item: Identifiable, Hashable { let app: SourceApp; let source: String; var id: String { source + "|" + app.bundleIdentifier + "|" + app.name + "|" + (app.latest?.version ?? "") } }

    var filtered: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Item] = []
        for s in store.sources where selected == nil || s.url == selected {
            for a in s.apps where q.isEmpty || a.name.lowercased().contains(q) || a.bundleIdentifier.lowercased().contains(q) || a.developer.lowercased().contains(q) {
                out.append(Item(app: a, source: s.name))
            }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.sources.isEmpty && !store.loading { emptyState } else { list }
            }
            .navigationTitle("Nguồn")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Tìm theo tên hoặc bundle ID")
            .onChange(of: query) { _ in limit = 40 }
            .onChange(of: selected) { _ in limit = 40 }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { showManage = true } label: { Label("Quản lý", systemImage: "list.bullet") }.disabled(store.sources.isEmpty) }
                ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Label("Thêm nguồn", systemImage: "plus") } }
            }
            .sheet(isPresented: $showAdd) { AddSourceSheet() }
            .sheet(isPresented: $showManage) { ManageSourcesSheet() }
            .refreshable { await store.reload() }
            .task { await store.reloadIfStale() }
            .navigationDestination(for: Item.self) { SourceAppView(app: $0.app, sourceName: $0.source) }
        }
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Chưa có nguồn nào").font(.headline)
            Text("Nguồn là một danh sách app (định dạng AltStore/SideStore). Bấm + rồi dán link nguồn, ví dụ:\nhttps://repository.apptesters.org/")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
            Button { showAdd = true } label: { Label("Thêm nguồn", systemImage: "plus") }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Tất cả", store.sources.reduce(0) { $0 + $1.apps.count }, nil, selected == nil)
                ForEach(store.sources) { s in chip(s.name, s.apps.count, s.url, selected == s.url, error: s.error != nil) }
            }.padding(.horizontal).padding(.vertical, 4)
        }
    }
    func chip(_ title: String, _ n: Int, _ url: String?, _ on: Bool, error: Bool = false) -> some View {
        Button { selected = url } label: {
            HStack(spacing: 4) {
                if error { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(on ? .white : .orange) }
                Text(title).lineLimit(1)
                Text("\(n)").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                    .background((on ? Color.white : Color.secondary).opacity(0.25), in: Capsule())
            }
            .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
            .background(on ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
            .foregroundStyle(on ? .white : .primary)
        }.buttonStyle(.plain)
    }

    var list: some View {
        let items = filtered
        return List {
            Section { chips.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            if store.loading { HStack { ProgressView(); Text("Đang tải nguồn…").font(.footnote).foregroundStyle(.secondary) } }
            if let sel = selected, let s = store.sources.first(where: { $0.url == sel }), let e = s.error {
                Text("Lỗi tải nguồn: \(e)").font(.footnote).foregroundStyle(.red)
            }
            Section(query.isEmpty ? "\(items.count) app" : "\(items.count) kết quả cho “\(query)”") {
                ForEach(items.prefix(limit)) { it in
                    NavigationLink(value: it) {
                        SourceAppRow(app: it.app, sourceName: selected == nil && store.sources.count > 1 ? it.source : nil, chevron: false)
                    }
                }
                if items.count > limit {
                    Button("Xem thêm (\(items.count - limit) app nữa)") { limit += 60 }
                        .frame(maxWidth: .infinity).onAppear { limit += 60 }
                }
                if items.isEmpty && !store.loading { Text(query.isEmpty ? "Nguồn này chưa có app." : "Không tìm thấy app nào.").foregroundStyle(.secondary) }
            }
        }.listStyle(.insetGrouped)
    }
}

struct SourceAppRow: View {
    @EnvironmentObject var engine: Engine
    let app: SourceApp
    var sourceName: String? = nil
    var chevron = true
    var installed: SideloadedApp? { engine.apps.first { $0.bundleID == app.bundleIdentifier || $0.bundleID.hasPrefix(app.bundleIdentifier + ".") } }
    var body: some View {
        HStack(spacing: 12) {
            AppIconView(bundleID: app.bundleIdentifier, name: app.name, remote: app.icon, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline).lineLimit(1)
                Text([app.latest?.version ?? "", app.latest.map { $0.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file) : "" } ?? "", sourceName ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !app.subtitle.isEmpty { Text(app.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if let i = installed, let v = app.latest, SourceStore.newer(v.version, than: i.version) {
                Text("Cập nhật").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(.orange, in: Capsule()).foregroundStyle(.white)
            } else if installed != nil { Text("Đã cài").font(.caption).foregroundStyle(.green) }
            if chevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }.contentShape(Rectangle())
    }
}

struct SourceAppView: View {
    @EnvironmentObject var engine: Engine
    let app: SourceApp
    var sourceName: String = ""
    @State private var signer = ""
    @State private var showAll = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AppIconView(bundleID: app.bundleIdentifier, name: app.name, remote: app.icon, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title3.bold())
                        if !app.developer.isEmpty { Text(app.developer).font(.subheadline).foregroundStyle(.secondary) }
                        Text(app.bundleIdentifier).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        if !sourceName.isEmpty { Text("Nguồn: \(sourceName)").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if let v = app.latest {
                    LabeledContent("Phiên bản mới nhất", value: v.version)
                    if v.size > 0 { LabeledContent("Dung lượng", value: ByteCountFormatter.string(fromByteCount: Int64(v.size), countStyle: .file)) }
                }
            }
            Section("Ký bằng") {
                if engine.signers.isEmpty {
                    Text("Chưa có tài khoản ký — đăng nhập Apple ID hoặc nhập chứng chỉ ở tab Tài khoản.").font(.footnote).foregroundStyle(.red)
                } else {
                    Picker("Tài khoản", selection: $signer) {
                        ForEach(engine.signers, id: \.self) { Text(engine.signerSummary($0)).tag($0) }
                    }
                }
                if let v = app.latest {
                    Button { install(v) } label: { Label(engine.busy ? "Đang bận…" : "Tải & cài \(v.version)", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).disabled(engine.busy || engine.signers.isEmpty)
                }
            }
            let desc = !app.description.isEmpty ? app.description : app.subtitle
            if !desc.isEmpty { Section("Mô tả") { Text(desc).font(.footnote).lineLimit(showAll ? nil : 8); if desc.count > 400 { Button(showAll ? "Thu gọn" : "Xem thêm") { showAll.toggle() } } } }
            Section("Các phiên bản") {
                ForEach(app.versions, id: \.self) { v in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(v.version).font(.headline); Text(v.date.prefix(10)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Tải & cài") { install(v) }.buttonStyle(.bordered).disabled(engine.busy || engine.signers.isEmpty)
                        }
                        if !v.notes.isEmpty { Text(v.notes).font(.caption).lineLimit(4) }
                    }
                }
            }
        }
        .navigationTitle(app.name).navigationBarTitleDisplayMode(.inline)
        .onAppear { if signer.isEmpty || !engine.signers.contains(signer) { signer = engine.defaultSigner } }
    }
    func install(_ v: SourceVersion) { let sg = signer.isEmpty ? nil : signer; Task { await engine.installFromSource(app, v, signer: sg) } }
}

struct AddSourceSheet: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var store = SourceStore.shared
    @State private var url = ""
    @State private var working = false
    @State private var error: String?
    @State private var resolved: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("https://…/source.json hoặc trang web nguồn", text: $url)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Dán") { if let s = UIPasteboard.general.string { url = s.trimmingCharacters(in: .whitespacesAndNewlines) } }
                            .buttonStyle(.bordered)
                    }
                    Button { Task { await add() } } label: {
                        HStack { if working { ProgressView() }; Text(working ? "Đang kiểm tra…" : "Thêm nguồn") }.frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || working)
                } footer: {
                    Text("Ví dụ: https://repository.apptesters.org/")
                }
                if let e = error { Section { Text(e).foregroundStyle(.red).font(.footnote) } }
                if let r = resolved { Section { Label("Đã thêm: \(r)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote) } }
                Section("Hướng dẫn") {
                    Text("• Nguồn là link JSON theo chuẩn AltStore/SideStore (danh sách app + link tải IPA).")
                    Text("• Có thể dán link trang web: iContainer sẽ tự thử /source.json, /apps.json, /repo.json, /altstore.json và tìm link nguồn trong trang.")
                    Text("• Nút “Add to AltStore/SideStore” trên web thường chứa link nguồn — nhấn giữ để sao chép rồi dán vào đây.")
                    Text("• iContainer không kèm sẵn nguồn nào. Chỉ thêm nguồn bạn tin tưởng và cài app bạn có quyền sử dụng.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Thêm nguồn").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } } }
        }
    }
    func add() async {
        working = true; error = nil; resolved = nil
        defer { working = false }
        do {
            let r = try await store.add(url)
            resolved = r; url = ""
            try? await Task.sleep(nanoseconds: 900_000_000); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ManageSourcesSheet: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var store = SourceStore.shared
    @State private var renaming: AppSource?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.sources) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            if let i = s.icon { AsyncImage(url: i) { $0.resizable() } placeholder: { Color.gray.opacity(0.2) }.frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6)) }
                            Text(s.name).font(.headline)
                            Spacer(); Text("\(s.apps.count) app").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(store.entries.first { $0.url == s.url }?.resolved ?? s.url).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        if let e = s.error { Text(e).font(.caption2).foregroundStyle(.red) }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.remove(s.url) } label: { Label("Xoá", systemImage: "trash") }
                        Button { renaming = s; newName = s.name } label: { Label("Đổi tên", systemImage: "pencil") }.tint(.blue)
                    }
                    .swipeActions(edge: .leading) {
                        Button { Task { await store.reload(only: s.url) } } label: { Label("Làm mới", systemImage: "arrow.clockwise") }.tint(.green)
                    }
                    .contextMenu {
                        Button { Task { await store.reload(only: s.url) } } label: { Label("Làm mới", systemImage: "arrow.clockwise") }
                        Button { renaming = s; newName = s.name } label: { Label("Đổi tên", systemImage: "pencil") }
                        Button { UIPasteboard.general.string = store.entries.first { $0.url == s.url }?.resolved ?? s.url } label: { Label("Sao chép link", systemImage: "doc.on.doc") }
                        Button(role: .destructive) { store.remove(s.url) } label: { Label("Xoá", systemImage: "trash") }
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
                .onDelete { idx in idx.map { store.sources[$0].url }.forEach(store.remove) }
                Section { Text("Vuốt trái để đổi tên/xoá, vuốt phải để làm mới, bấm Sửa để sắp xếp.").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("Quản lý nguồn").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Xong") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .bottomBar) { Button { Task { await store.reload() } } label: { Label(store.loading ? "Đang làm mới…" : "Làm mới tất cả", systemImage: "arrow.clockwise") }.disabled(store.loading) }
            }
            .alert("Đổi tên nguồn", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Tên", text: $newName)
                Button("Lưu") { if let r = renaming { store.rename(r.url, to: newName) }; renaming = nil }
                Button("Huỷ", role: .cancel) { renaming = nil }
            }
        }
    }
}
