#if SICONTAINER_RUNNER
import SwiftUI
import UIKit

struct SIRunnerApp: App {
    @State private var summary: [String: Any] = ICReadProbeSummary() as? [String: Any] ?? [:]
    @State private var lastError: String? = ICLastLaunchError()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("SIContainer Phụ 1 (Runner Slot 1)") {
                        let groupOK = (summary["shared_group_available"] as? Bool) == true
                        Label(
                            groupOK ? "App Group dùng chung: Đã kích hoạt" : "App Group dùng chung: Chưa có quyền",
                            systemImage: groupOK ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(groupOK ? .green : .orange)
                        if let gid = summary["shared_group_id"] as? String, !gid.isEmpty {
                            Text("Group ID: \(gid)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let bid = summary["current_bundle_id"] as? String {
                            Text("Bundle ID: \(bid)").font(.caption).foregroundStyle(.secondary)
                        }
                        let managerProbe = summary["manager_probe"] as? [String: Any] ?? [:]
                        let managerSeen = (managerProbe["bundle_id"] as? String)?.isEmpty == false
                        Label(
                            managerSeen ? "Đã kết nối 2 chiều với SIContainer Chính" : "Chưa thấy dấu hiệu từ SIContainer Chính",
                            systemImage: managerSeen ? "link.circle.fill" : "dot.radiowaves.left.and.right"
                        )
                        .font(.subheadline)
                    }

                    if let err = lastError, !err.isEmpty {
                        Section("Lỗi mở app gần nhất") {
                            Text(err).font(.footnote).foregroundStyle(.red)
                            Button("Sao chép lỗi") { UIPasteboard.general.string = err }
                        }
                    }

                    Section("Điều khiển") {
                        Button {
                            ICRecordRoleProbe()
                            summary = ICReadProbeSummary() as? [String: Any] ?? [:]
                            if let u = URL(string: "sicontainer://probe-complete?slot=runner1") {
                                UIApplication.shared.open(u)
                            }
                        } label: {
                            Label("Xác nhận kết nối & Quay về SIContainer Chính", systemImage: "arrow.uturn.backward.circle.fill")
                        }
                        Button {
                            if let u = URL(string: "sicontainer://") {
                                UIApplication.shared.open(u)
                            }
                        } label: {
                            Label("Mở SIContainer Chính", systemImage: "shippingbox.fill")
                        }
                    }
                }
                .navigationTitle("SIContainer Phụ 1")
                .refreshable {
                    summary = ICReadProbeSummary() as? [String: Any] ?? [:]
                    lastError = ICLastLaunchError()
                }
                .onOpenURL { url in
                    ICRecordRoleProbe()
                    summary = ICReadProbeSummary() as? [String: Any] ?? [:]
                    lastError = ICLastLaunchError()
                    let host = url.host ?? ""
                    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    if host == "probe" {
                        if comps?.queryItems?.first(where: { $0.name == "return" })?.value == "1",
                           let back = URL(string: "sicontainer://probe-complete?slot=runner1") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                UIApplication.shared.open(back)
                            }
                        }
                    } else {
                        // A direct cold-start URL has no ticket yet. The runtime
                        // validates the guest, writes a one-shot ticket, and bounces
                        // so that the next process loads it before UIKit starts.
                        ICHandleRunnerURL(url)
                        lastError = ICLastLaunchError()
                    }
                }
            }
        }
    }
}
#endif
