import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var store = SourceStore.shared
    @State private var newURL = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("https://…/source.json", text: $newURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Thêm") { let u = newURL; newURL = ""; Task { await store.add(u) } }.disabled(newURL.isEmpty)
                    }
                } header: { Text("Thêm nguồn") } footer: {
                    Text("Hỗ trợ nguồn định dạng AltStore/SideStore (JSON có danh sách apps). iSideload không kèm sẵn nguồn nào — chỉ thêm nguồn hợp pháp bạn tin tưởng.")
                }
                ForEach(store.sources) { s in
                    Section {
                        if let e = s.error { Text("Lỗi: \(e)").font(.footnote).foregroundStyle(.red) }
                        ForEach(s.apps) { a in
                            NavigationLink { SourceAppView(app: a) } label: { SourceAppRow(app: a) }
                        }
                    } header: {
                        HStack { Text(s.name); Spacer(); Button(role: .destructive) { store.remove(s.url) } label: { Image(systemName: "trash") } }
                    }
                }
            }
            .navigationTitle("Nguồn app")
            .refreshable { await store.reload() }
            .task { if store.sources.isEmpty { await store.reload() } }
        }
    }
}

struct SourceAppRow: View {
    @EnvironmentObject var engine: Engine
    let app: SourceApp
    var installed: SideloadedApp? { engine.apps.first { $0.bundleID == app.bundleIdentifier || $0.bundleID.hasPrefix(app.bundleIdentifier + ".") } }
    var body: some View {
        HStack {
            AsyncImage(url: app.icon) { $0.resizable() } placeholder: { RoundedRectangle(cornerRadius: 10).fill(Theme.color(for: app.bundleIdentifier)) }
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading) {
                Text(app.name).font(.headline)
                Text(app.latest?.version ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let i = installed, let v = app.latest, SourceStore.newer(v.version, than: i.version) {
                Text("Cập nhật").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(.orange, in: Capsule()).foregroundStyle(.white)
            } else if installed != nil { Text("Đã cài").font(.caption).foregroundStyle(.green) }
        }
    }
}

struct SourceAppView: View {
    @EnvironmentObject var engine: Engine
    let app: SourceApp
    var body: some View {
        List {
            Section { SourceAppRow(app: app); if !app.subtitle.isEmpty { Text(app.subtitle) }; if !app.developer.isEmpty { Text(app.developer).font(.footnote) } }
            Section("Phiên bản") {
                ForEach(app.versions, id: \.self) { v in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(v.version).font(.headline); Text(v.date.prefix(10)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Tải & cài") { Task { await engine.installFromSource(app, v) } }.buttonStyle(.borderedProminent).disabled(engine.busy)
                        }
                        if !v.notes.isEmpty { Text(v.notes).font(.caption).lineLimit(4) }
                    }
                }
            }
        }.navigationTitle(app.name)
    }
}
